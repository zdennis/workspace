require "digest"
require "json"
require "securerandom"

module Workspace
  # Rewrites frontmatter keys of one spine stage file: any set of `status`, `note` and `owner`, plus
  # `updated` and `updated_by` on every write. It keeps every other byte (line endings, a BOM, comments,
  # unknown keys, lists). The file is read again from its raw bytes each time, since {SpineFile}
  # keeps line spans, not offsets, and the new bytes go out through a temp file in the same folder,
  # an fsync and a rename.
  #
  # The caller serialises writers (`spine set` holds a per-workspace lock); this class also checks
  # that the file did not change between its read and the rename, and starts over once if it did.
  class SpineWriter
    # What one {#write} did.
    #
    # @!attribute changed [Boolean] whether the file was written
    # @!attribute previous [String] the status before, canonical (`unknown` when the file had none)
    # @!attribute status [String] the status after
    # @!attribute note [String, nil] the note after
    # @!attribute owner [String, nil] the owner after
    # @!attribute previous_note [String, nil] the note before
    # @!attribute previous_owner [String, nil] the owner before
    # @!attribute revision [String] the file's revision after (the current one when nothing changed)
    Result = Struct.new(:changed, :previous, :status, :note, :owner, :previous_note, :previous_owner, :revision, keyword_init: true)

    # What one {#check} did.
    #
    # @!attribute changed [Boolean] whether the file was written
    # @!attribute items [Array<Hash>] every `## Done when` item after: `{"n", "text", "done"}`
    # @!attribute changed_items [Array<Integer>] the numbers of the items whose box changed
    # @!attribute revision [String] the file's revision after (the current one when nothing changed)
    CheckResult = Struct.new(:changed, :items, :changed_items, :revision, keyword_init: true)

    # What one {#goal} did.
    #
    # @!attribute created [Boolean] whether `goal.md` was made
    # @!attribute changed [Boolean] whether the file was written (also true when created)
    # @!attribute title [String] the title after
    # @!attribute previous [String, nil] the title before
    # @!attribute revision [String] the file's revision after
    GoalResult = Struct.new(:created, :changed, :title, :previous, :revision, keyword_init: true)

    # The box at the start of a `## Done when` item line.
    BOX = /\A- \[[ xX]\]/n
    private_constant :BOX

    # A value written without quotes: plain words and the punctuation common in a short note.
    # It starts with a letter, so a number, a date or a hex value is quoted.
    BARE = /\A[A-Za-z][A-Za-z0-9 ._,;()\/%@+=-]*\z/
    private_constant :BARE

    # Words a YAML reader would take for something other than text.
    NOT_TEXT = /\A(?:true|false|null|yes|no|on|off|y|n)\z/i
    private_constant :NOT_TEXT

    # @param path [String] absolute path of the stage file
    # @param relative [String] its name below `spine/`, for messages
    # @param values [Hash{String => String, nil}] the keys to set: `status` (canonical), `note` and `owner`;
    #   nil or empty removes `note` or `owner`. A `status` that changes also clears the note unless `note` is given.
    # @param by [String] the `updated_by` label
    # @param updated [String] the `updated` time, UTC ISO
    # @param if_revision [String, nil] refuse unless the file's revision is this
    # @return [Result]
    # @raise [Workspace::Error] `stale_revision` (details `revision`, `status`) or `spine_unwritable` (details `file`, `reason`:
    #   `link`, `not_a_file`, `too_large`, `not_utf8`, `no_frontmatter`, `missing`, `unreadable_result`, `io_error` or `changed_while_writing`)
    def write(path, relative:, values:, by:, updated:, if_revision: nil)
      2.times do
        bytes, info = read(path, relative)
        file = SpineFile.parse(bytes, relative: relative)
        raise unwritable(relative, "not_utf8", "#{relative} isn't text, so its frontmatter can't be updated safely.") unless file.read?
        raise unwritable(relative, "no_frontmatter", "#{relative} has no frontmatter block closed within #{SpineFile::MAX_FRONTMATTER_LINES} lines, so it can't be updated safely.") unless file.frontmatter_lines
        verify_revision(file, relative, if_revision)

        previous = file.status
        edits, after = edits_for(file, values, by, updated, previous)
        return Result.new(changed: false, previous: previous, status: previous, note: file.value("note"), owner: file.value("owner"), previous_note: file.value("note"), previous_owner: file.value("owner"), revision: file.revision) if edits.empty?

        rewritten = edits.reduce(bytes) { |current, (key, value)| apply(current, key, value) }
        unless reads_back?(rewritten, after)
          raise unwritable(relative, "unreadable_result", "#{relative} would not read as asked after the change (its frontmatter is at a size limit), so nothing was written.")
        end
        next unless replace_unless_changed(path, relative, rewritten, info)
        return Result.new(changed: true, previous: previous, status: after["status"], note: after["note"], owner: after["owner"], previous_note: file.value("note"), previous_owner: file.value("owner"),
          revision: Digest::SHA256.hexdigest(rewritten)[0, 8])
      end
      raise unwritable(relative, "changed_while_writing", "#{relative} kept changing while it was being written. Nothing was changed; try again.")
    end

    # Ticks or unticks items of the `## Done when` checklist of one stage file. Only the `[ ]` or `[x]` of each
    # item's line changes; the frontmatter (`updated` too) and every other byte stay. An item already in the
    # asked state is left alone, and when none changes nothing is written.
    #
    # @param path [String] absolute path of the stage file
    # @param relative [String] its name below `spine/`, for messages
    # @param numbers [Array<Integer>] 1-based positions in the checklist, as `show` lists them
    # @param done [Boolean] true to tick, false to untick
    # @param if_revision [String, nil] refuse unless the file's revision is this
    # @return [CheckResult]
    # @raise [Workspace::Error] `unknown_item` (details `item`, `total`), `stale_revision`, or `spine_unwritable` as {#write}
    def check(path, relative:, numbers:, done:, if_revision: nil)
      2.times do
        bytes, info = read(path, relative)
        file = SpineFile.parse(bytes, relative: relative)
        raise unwritable(relative, "not_utf8", "#{relative} isn't text, so its checklist can't be updated safely.") unless file.read?
        verify_revision(file, relative, if_revision)
        if (bad = numbers.find { |n| n < 1 || n > file.items.size })
          raise Workspace::Error.new("#{relative} has #{file.items.size} Done when #{(file.items.size == 1) ? "item" : "items"}; there is no item #{bad}.",
            code: "unknown_item", details: {"item" => bad, "total" => file.items.size, "file" => relative})
        end

        todo = numbers.uniq.sort.reject { |n| file.items[n - 1]["done"] == done }
        return check_result(file.items, [], file.revision) if todo.empty?

        lines = bytes.lines
        todo.each do |n|
          index = file.items[n - 1]["line"] - 1
          unless lines[index]&.match?(BOX)
            raise unwritable(relative, "unreadable_result", "Item #{n} of #{relative} is not where it was read, so nothing was written.")
          end
          lines[index] = lines[index].sub(BOX, done ? "- [x]".b : "- [ ]".b)
        end
        rewritten = lines.join
        after = SpineFile.parse(rewritten, relative: relative)
        expected = file.items.each_with_index.map { |item, i| todo.include?(i + 1) ? done : item["done"] }
        unless after.read? && after.items.map { |item| item["done"] } == expected
          raise unwritable(relative, "unreadable_result", "#{relative} would not read as asked after the change, so nothing was written.")
        end
        next unless replace_unless_changed(path, relative, rewritten, info)
        return check_result(after.items, todo, Digest::SHA256.hexdigest(rewritten)[0, 8])
      end
      raise unwritable(relative, "changed_while_writing", "#{relative} kept changing while it was being written. Nothing was changed; try again.")
    end

    # Sets the `title:` of `goal.md`, keeping every other byte of an existing file. A missing file is made
    # (`spine: 1`, `title:`, a `# TEXT` heading); the make fails rather than replace a file that appeared meanwhile.
    #
    # @param path [String] absolute path of `goal.md`
    # @param relative [String] its name below `spine/`, for messages
    # @param title [String] one line, already checked
    # @param if_revision [String, nil] refuse unless the file's revision is this (a missing file has none)
    # @return [GoalResult]
    # @raise [Workspace::Error] `stale_revision` or `spine_unwritable` as {#write}
    def goal(path, relative:, title:, if_revision: nil)
      2.times do
        missing = begin
          File.lstat(path)
          false
        rescue Errno::ENOENT
          true
        rescue SystemCallError => e
          raise unwritable(relative, "io_error", "#{relative} can't be read: #{e.message}")
        end
        if missing
          if if_revision
            raise Workspace::Error.new("#{relative} doesn't exist, so it has no revision #{if_revision}.", code: "stale_revision", details: {"revision" => nil, "status" => nil})
          end
          made = create_goal(path, relative, title)
          return made if made
          next
        end
        bytes, info = read(path, relative)
        file = SpineFile.parse(bytes, relative: relative)
        raise unwritable(relative, "not_utf8", "#{relative} isn't text, so its frontmatter can't be updated safely.") unless file.read?
        raise unwritable(relative, "no_frontmatter", "#{relative} has no frontmatter block closed within #{SpineFile::MAX_FRONTMATTER_LINES} lines, so it can't be updated safely.") unless file.frontmatter_lines
        verify_revision(file, relative, if_revision)

        previous = file.value("title")
        return GoalResult.new(created: false, changed: false, title: title, previous: previous, revision: file.revision) if previous == title

        rewritten = apply(bytes, "title", title)
        unless SpineFile.parse(rewritten).then { |w| w.read? && w.value("title") == title }
          raise unwritable(relative, "unreadable_result", "#{relative} would not read as asked after the change (its frontmatter is at a size limit), so nothing was written.")
        end
        next unless replace_unless_changed(path, relative, rewritten, info)
        return GoalResult.new(created: false, changed: true, title: title, previous: previous, revision: Digest::SHA256.hexdigest(rewritten)[0, 8])
      end
      raise unwritable(relative, "changed_while_writing", "#{relative} kept changing while it was being written. Nothing was changed; try again.")
    end

    private

    def verify_revision(file, relative, if_revision)
      return unless if_revision && if_revision.downcase != file.revision
      raise Workspace::Error.new("#{relative} changed: its revision is #{file.revision}, not #{if_revision}.",
        code: "stale_revision", details: {"revision" => file.revision, "status" => file.status})
    end

    # @return [GoalResult, nil] nil when the file appeared while it was being made
    def create_goal(path, relative, title)
      text = "---\nspine: 1\ntitle: #{format_value("title", title)}\n---\n\n# #{title}\n"
      parsed = SpineFile.parse(text)
      unless parsed.read? && parsed.value("title") == title
        raise unwritable(relative, "unreadable_result", "#{relative} would not read as asked, so nothing was written.")
      end
      temp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o644) do |io|
        io.binmode
        io.write(text)
        io.fsync
      end
      begin
        File.link(temp, path)
      rescue Errno::EEXIST
        return nil
      end
      sync_directory(File.dirname(path))
      GoalResult.new(created: true, changed: true, title: title, previous: nil, revision: Digest::SHA256.hexdigest(text)[0, 8])
    rescue SystemCallError => e
      raise unwritable(relative, "io_error", "#{relative} can't be written: #{e.message}")
    ensure
      File.unlink(temp) if temp && File.exist?(temp)
    end

    def check_result(items, changed_items, revision)
      CheckResult.new(changed: !changed_items.empty?, changed_items: changed_items, revision: revision,
        items: items.each_with_index.map { |item, i| {"n" => i + 1, "text" => item["text"], "done" => item["done"]} })
    end

    # @return [Array(Hash, Hash)] the keys to write (empty when nothing would change) and the status, note and owner they leave
    def edits_for(file, values, by, updated, previous)
      status = values["status"] || previous
      wanted = {"note" => file.value("note"), "owner" => file.value("owner")}
      wanted["note"] = nil if values.key?("status") && previous != status
      %w[note owner].each { |key| wanted[key] = blank(values[key]) if values.key?(key) }
      edits = {}
      edits["status"] = status if values.key?("status") && previous != status
      %w[note owner].each do |key|
        edits[key] = wanted[key] || :delete if wanted[key] != file.value(key)
      end
      return [{}, nil] if edits.empty?

      edits["updated"] = updated
      edits["updated_by"] = by
      [edits, {"status" => status}.merge(wanted)]
    end

    def blank(text)
      (text.nil? || text.empty?) ? nil : text
    end

    # @return [String] +bytes+ with the one key set, added at the end of the block, or removed (value :delete).
    #   The lines that belong to the key go with it (its list items and indented continuation lines), and so does a
    #   second copy of the key, which a YAML reader would take over the first.
    def apply(bytes, key, value)
      file = SpineFile.parse(bytes)
      lines = bytes.lines
      if (span = file.key_span(key))
        limit = file.frontmatter_lines.last
        gone = owned_lines(lines, span.first, limit, span)
        file.warnings.select { |w| w["code"] == "duplicate_key" && w["value"] == key }.each do |w|
          gone += [w["line"]] + owned_lines(lines, w["line"], limit, nil)
        end
        lines[span.first - 1] = (value == :delete) ? nil : "#{key}: #{format_value(key, value)}".b + line_ending(lines[span.first - 1])
        gone.each { |number| lines[number - 1] = nil }
        lines.compact!
      elsif value != :delete
        last = file.frontmatter_lines.last
        lines.insert(last, "#{key}: #{format_value(key, value)}".b + line_ending(lines[last - 1]))
      end
      lines.join
    end

    # The 1-based numbers of the lines after +first+ that belong to its key: the ones right below it that are
    # indented or are list items, and the items inside +span+ (a comment may sit between two items).
    def owned_lines(lines, first, limit, span)
      owned = []
      number = first + 1
      while number <= limit && lines[number - 1].match?(/\A(?:[ \t]|-(?:[ \t]|\r?\n\z))/n)
        owned << number
        number += 1
      end
      owned |= ((span.first + 1)..span.last).select { |n| lines[n - 1].match?(/\A[ \t]*-/n) } if span
      owned
    end

    # Whether {SpineFile} reads the status, note and owner in +after+ from +bytes+: added lines can push the
    # closing `---` past the line limit or a key past the key limit, where the reader would not see them.
    def reads_back?(bytes, after)
      written = SpineFile.parse(bytes)
      written.read? && !written.frontmatter_lines.nil? && written.status == after["status"] &&
        written.value("note") == after["note"] && written.value("owner") == after["owner"]
    end

    def line_ending(line)
      line.end_with?("\r\n".b) ? "\r\n".b : "\n".b
    end

    # Timestamps and the canonical statuses go bare; text goes bare when a YAML reader would take it as text too,
    # else as a double-quoted JSON string, which both readers understand.
    def format_value(key, value)
      return value if key == "updated" || key == "status"
      (value.match?(BARE) && !value.match?(NOT_TEXT) && !value.end_with?(" ")) ? value : JSON.generate(value)
    end

    def read(path, relative)
      stat = File.lstat(path)
      raise unwritable(relative, "link", "#{relative} is a link, so it isn't written.") if stat.symlink?
      raise unwritable(relative, "not_a_file", "#{relative} is not a regular file, so it isn't written.") unless stat.file?

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |io|
        info = io.stat
        raise unwritable(relative, "not_a_file", "#{relative} is not a regular file, so it isn't written.") unless info.file?
        raise too_large(relative) if info.size > SpineFile::MAX_BYTES
        io.binmode
        bytes = io.read(SpineFile::MAX_BYTES + 1) || "".b
        raise too_large(relative) if bytes.bytesize > SpineFile::MAX_BYTES
        [bytes, info]
      end
    rescue Errno::ELOOP
      raise unwritable(relative, "link", "#{relative} is a link, so it isn't written.")
    rescue Errno::ENOENT
      raise unwritable(relative, "missing", "#{relative} is gone.")
    rescue SystemCallError => e
      raise unwritable(relative, "io_error", "#{relative} can't be read: #{e.message}")
    end

    def too_large(relative)
      unwritable(relative, "too_large", "#{relative} is over #{SpineFile::MAX_BYTES} bytes, so its frontmatter can't be updated safely.")
    end

    # @return [Boolean] false, with nothing renamed, when the file is no longer the one that was read
    def replace_unless_changed(path, relative, bytes, info)
      temp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      File.open(temp, flags, info.mode & 0o777) do |io|
        io.binmode
        io.write(bytes)
        io.chmod(info.mode & 0o7777)
        io.fsync
      end
      now = File.lstat(path)
      return false unless now.file? && now.ino == info.ino && now.size == info.size && now.mtime == info.mtime
      File.rename(temp, path)
      sync_directory(File.dirname(path))
      true
    rescue SystemCallError => e
      raise unwritable(relative, "io_error", "#{relative} can't be written: #{e.message}")
    ensure
      File.unlink(temp) if temp && File.exist?(temp)
    end

    def sync_directory(dir)
      File.open(dir, File::RDONLY, &:fsync)
    rescue SystemCallError
      nil
    end

    def unwritable(relative, reason, message)
      Workspace::Error.new(message, code: "spine_unwritable", details: {"file" => relative, "reason" => reason})
    end
  end
end
