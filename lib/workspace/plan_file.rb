require "json"
require "fileutils"
require "time"

module Workspace
  # One workspace's plan: `IMPLEMENTATION_PLAN.md` in its notes directory, read
  # as a counted checklist. The parser never fails. Whatever the text holds, it
  # returns the tasks it could read, the counts, and `warnings` for the lines it
  # could not read cleanly.
  #
  # The convention:
  #
  # - Optional frontmatter between two `---` lines at the top of the file, with
  #   `plan: 1`, `title`, `status` (`active`, `paused` or `done`) and `owner_pane`.
  #   It is read line by line, `key: value`, not as YAML, so a stray colon in a
  #   title can't make the file unreadable.
  # - A task is a column-0 line `- [S] ID Title` under a `## Tasks` heading. `S` is
  #   a space (to do), `~` (in progress), `x` or `X` (done), `-` (skipped) or `!`
  #   (blocked). Skipped and blocked tasks end ` -- reason`.
  # - A task may end with an owner comment, `<!-- owner: %19 -->`: the tmux pane
  #   working it. Older readers strip it like any other comment, so the line still
  #   reads as the same plain task.
  # - Not counted: indented checkboxes, fenced code, HTML comments, and anything
  #   after the next `#` or `##` heading (such as `## Task details`).
  # - A task's phase is the nearest heading above it that is not `Tasks`.
  #
  # A line that looks like a task but has no id is still counted (warning
  # `no_id`), as is one with an unknown box character (`bad_state`, counted as
  # to do) and a repeated id (`duplicate_id`), so the counts never hide work.
  class PlanFile
    # The file's name in the notes directory.
    FILE_NAME = "IMPLEMENTATION_PLAN.md"

    # Bytes read; a longer file is cut at its last whole line below this.
    MAX_BYTES = 1_048_576

    # Values `status:` may hold.
    STATUSES = %w[active paused done].freeze

    # The state each box character stands for.
    BOX_STATES = {" " => "todo", "~" => "in_progress", "x" => "done", "X" => "done", "-" => "skipped", "!" => "blocked"}.freeze

    # The states a task may be in, in the order the counts list them.
    TASK_STATES = %w[done in_progress skipped blocked todo].freeze

    ID = /\A(?=.*\d)[A-Za-z0-9][A-Za-z0-9._-]*\z/
    private_constant :ID

    KEY_LINE = /\A([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*\z/
    private_constant :KEY_LINE

    # A tmux pane id, the only value an owner comment may hold.
    PANE_ID = /\A%\d+\z/

    # The box character written for each state.
    STATE_BOXES = {"todo" => " ", "in_progress" => "~", "done" => "x", "skipped" => "-", "blocked" => "!"}.freeze

    OWNER_COMMENT = /<!--\s*owner\s*:(.*?)-->/i
    private_constant :OWNER_COMMENT

    # One task line.
    #
    # @!attribute id [String, nil] the first word when it looks like an id (it has a digit); nil otherwise
    # @!attribute title [String] the rest of the line, without a trailing ` -- reason`
    # @!attribute state [String] one of {TASK_STATES}
    # @!attribute reason [String, nil] the text after ` -- ` on a skipped or blocked task
    # @!attribute phase [String, nil] the nearest heading above that is not `Tasks`
    # @!attribute line [Integer] the 1-based line number in the file
    # @!attribute owner [String, nil] the pane id in the line's `<!-- owner: %19 -->` comment; nil without one
    Task = Struct.new(:id, :title, :state, :reason, :phase, :line, :owner, keyword_init: true) do
      # @return [Hash] the task as `plan status --json` lists it
      def to_h
        {"id" => id, "title" => title, "state" => state, "reason" => reason, "phase" => phase, "line" => line, "owner" => owner}
      end
    end

    # @return [Hash{String => String}] frontmatter keys as written (`plan`, `title`, `status`, `owner_pane`, and any other)
    attr_reader :frontmatter

    # @return [Range, nil] the 1-based line numbers of the frontmatter's `key: value` area (between the `---` lines); nil without frontmatter
    attr_reader :frontmatter_lines

    # @return [Integer, nil] the 1-based line number of the `status:` line, nil when there is none
    attr_reader :status_line

    # @param key [String] a frontmatter key
    # @return [Integer, nil] the 1-based line number of the last `key:` line, nil when there is none
    def key_line(key) = @key_lines[key]

    # @return [Array<Task>] the tasks in file order
    attr_reader :tasks

    # @return [Array<Hash>] `{"code", "line", "message"}`; `line` is nil for a warning about the whole file
    attr_reader :warnings

    # @return [String, nil] `mtime_ns:size` of the file read (nil for text that did not come from a file)
    attr_reader :signature

    # @return [String, nil] the file's modification time, UTC, to the second
    attr_reader :updated_at

    # Parses plan text.
    #
    # @param text [String] the file's text
    # @param truncated [Boolean] whether the text is only the start of a longer file
    # @param signature [String, nil] see {#signature}
    # @param updated_at [String, nil] see {#updated_at}
    # @param warnings [Array<Hash>] warnings found before parsing, e.g. a read problem
    # @return [PlanFile]
    def self.parse(text, truncated: false, signature: nil, updated_at: nil, warnings: [])
      new(text, truncated: truncated, signature: signature, updated_at: updated_at, warnings: warnings)
    end

    # Reads and parses a plan file.
    #
    # @param path [String] the plan's absolute path
    # @return [PlanFile, nil] nil when there is no file; a file that can't be read gives an empty plan with an `unreadable` warning
    def self.read(path)
      File.open(path, "rb") do |file|
        stat = file.stat
        raise Errno::EISDIR, path if stat.directory?
        bytes = file.read(MAX_BYTES + 1) || +""
        truncated = bytes.bytesize > MAX_BYTES
        bytes = bytes.byteslice(0, MAX_BYTES) if truncated
        if truncated
          cut = bytes.rindex("\n")
          bytes = cut ? bytes.byteslice(0, cut + 1) : +""
        end
        mtime = stat.mtime
        signature = signature_for(stat)
        parse(bytes.force_encoding(Encoding::UTF_8).scrub, truncated: truncated, signature: signature,
          updated_at: mtime.utc.iso8601)
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    rescue SystemCallError => e
      parse("", warnings: [warning("unreadable", nil, "The plan file can't be read: #{e.message}")])
    end

    # Sets `status:` in the frontmatter. Only that line changes, or one line is added, or a
    # frontmatter block with `plan: 1` and the status is added when the file has none.
    # Nothing is written when the status already reads that way (an absent `status:` reads `active`).
    #
    # @param path [String] the plan's absolute path
    # @param status [String] one of {STATUSES}
    # @return [Boolean] whether the file changed
    # @raise [Errno::ENOENT] when there is no file
    # @raise [Workspace::Error] code `plan_write_conflict` when the file changed under the write twice
    def self.set_status(path, status)
      return false if status == "active" && frontmatter_of(path)["status"].nil?
      set_frontmatter(path, "status", status)
    end

    # Sets `owner_pane:` in the frontmatter like {.set_status}.
    #
    # @param path [String] the plan's absolute path
    # @param pane [String] a tmux pane id such as `%19`
    # @return [Boolean] whether the file changed
    # @raise (see .set_status)
    def self.set_owner_pane(path, pane)
      set_frontmatter(path, "owner_pane", pane, quote: true)
    end

    # Writes one frontmatter key through a temp file and a rename. The file is read whole (the
    # 1 MB read limit does not apply), and if it changed between the read and the rename, for
    # instance because an agent edited it, the edit is made again on what is there now. A file
    # that changes under a second try is left alone.
    def self.set_frontmatter(path, key, value, quote: false)
      rewrite(path) { |bytes| with_frontmatter_value(bytes, key, value, quote) }
    end
    private_class_method :set_frontmatter

    # Leaves an owner as it is in {.set_task}.
    KEEP = Object.new.freeze

    # Rewrites one task's line: its box character, its owner comment, or both. Every other byte
    # of the line and of the file stays as it is; a ` -- reason` is not added or removed. Written
    # like {.set_status}: whole file read, temp file and rename, one retry when the file changed
    # under the write. The new text is parsed again before it is written, and a line that would
    # not read back as asked (an owner inside a comment left open, say) is refused.
    #
    # @param path [String] the plan's absolute path
    # @param id [String] the task's id (the first task with it when the id is repeated)
    # @param state [String, nil] one of {TASK_STATES}; nil leaves the box as it is
    # @param owner [String, nil, KEEP] a pane id such as `%19` to set, nil to remove the comment, {KEEP} to leave it
    # @return [Boolean] whether the file changed
    # @raise [Errno::ENOENT] when there is no file
    # @raise [Workspace::Error] code `unknown_task` when no task has the id, `plan_write_conflict` as {.set_status};
    #   a plain error when the line is not UTF-8 or would not read back as asked
    def self.set_task(path, id, state: nil, owner: KEEP)
      raise ArgumentError, "unknown state #{state.inspect}" if state && !STATE_BOXES.key?(state)
      raise ArgumentError, "owner must be a pane id" unless owner.equal?(KEEP) || owner.nil? || owner.to_s.match?(PANE_ID)
      rewrite(path) { |bytes| with_task_line(bytes, path, id, state, owner) }
    end

    # The read, change and rename loop every writer goes through.
    def self.rewrite(path)
      target = File.realpath(path)
      2.times do
        bytes, signature = File.open(target, "rb") { |file| [file.read, signature_for(file.stat)] }
        updated = yield(bytes)
        return false if updated.nil?
        return true if replace_unless_changed(target, updated, signature)
      end
      raise Workspace::Error.new("The plan #{path} changed while it was being written. Nothing was changed; try again.",
        code: "plan_write_conflict", details: {"path" => path})
    end
    private_class_method :rewrite

    # @return [String, nil] the new bytes, nil when the line already reads that way
    def self.with_task_line(bytes, path, id, state, owner)
      plan = parse(bytes.dup.force_encoding(Encoding::UTF_8).scrub)
      task = plan.tasks.find { |candidate| candidate.id == id }
      raise unknown_task(path, id) unless task

      lines = bytes.lines
      raw = lines[task.line - 1]
      ending = line_ending(raw)
      text = raw.byteslice(0, raw.bytesize - ending.bytesize).dup.force_encoding(Encoding::UTF_8)
      raise Workspace::Error.new("Line #{task.line} of the plan #{path} is not valid UTF-8, so it was not changed.", details: {"path" => path}) unless text.valid_encoding?

      updated = text
      updated = updated.sub(/\A- \[.\]/) { "- [#{STATE_BOXES.fetch(state)}]" } if state && task.state != state
      updated = with_owner(updated, owner) unless owner.equal?(KEEP)
      return nil if updated == text

      lines[task.line - 1] = updated.b + ending
      result = lines.join
      reread = parse(result.dup.force_encoding(Encoding::UTF_8).scrub)
      check = reread.tasks.find { |candidate| candidate.id == id }
      reads_back = reread.tasks.size == plan.tasks.size && check && (state.nil? || check.state == state) && (owner.equal?(KEEP) || check.owner == owner)
      unless reads_back
        raise Workspace::Error.new("Line #{task.line} of the plan #{path} can't be rewritten to read that way (an open or nested comment?), so nothing was changed.",
          details: {"path" => path, "line" => task.line})
      end
      result
    end
    private_class_method :with_task_line

    # Replaces the first owner comment, drops any others, or adds one at the end of the line.
    def self.with_owner(text, owner)
      found = false
      updated = text.gsub(/([ \t]*)#{OWNER_COMMENT}/o) do
        keep = owner && !found
        found = true
        keep ? "#{$1}<!-- owner: #{owner} -->" : ""
      end
      return updated if owner.nil? || found
      "#{text.sub(/[ \t]+\z/, "")} <!-- owner: #{owner} -->"
    end
    private_class_method :with_owner

    # @param path [String]
    # @param id [String]
    # @return [Workspace::Error] code `unknown_task`
    def self.unknown_task(path, id)
      Workspace::Error.new("No task #{id} in the plan #{path}.", code: "unknown_task", details: {"path" => path, "task" => id})
    end

    def self.frontmatter_of(path)
      read(path)&.frontmatter || raise(Errno::ENOENT, path)
    end
    private_class_method :frontmatter_of

    # @return [String, nil] the new bytes, nil when the key already holds the value
    def self.with_frontmatter_value(bytes, key, value, quote)
      plan = parse(bytes.dup.force_encoding(Encoding::UTF_8).scrub)
      return nil if plan.frontmatter.key?(key) && plan.frontmatter[key] == value
      lines = bytes.lines
      text = "#{key}: #{quote ? JSON.generate(value) : value}".b
      if (number = plan.key_line(key))
        lines[number - 1] = text + line_ending(lines[number - 1])
      elsif plan.frontmatter_lines
        closing = plan.frontmatter_lines.last
        lines.insert(closing, text + line_ending(lines[closing - 1]).then { |e| e.empty? ? "\n" : e })
      else
        bom = lines.first.to_s.start_with?("\xEF\xBB\xBF".b) ? "\xEF\xBB\xBF".b : "".b
        lines[0] = lines.first.to_s.delete_prefix(bom)
        lines.unshift(bom + "---\nplan: 1\n".b + text + "\n---\n".b)
      end
      lines.join
    end
    private_class_method :with_frontmatter_value

    def self.line_ending(line)
      return "\r\n".b if line.end_with?("\r\n".b)
      line.end_with?("\n".b) ? "\n".b : "".b
    end
    private_class_method :line_ending

    def self.signature_for(stat)
      "#{stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec}:#{stat.size}"
    end
    private_class_method :signature_for

    # @return [Boolean] false when the file's signature is no longer +signature+, with nothing renamed
    def self.replace_unless_changed(target, bytes, signature)
      temp = "#{target}.#{Process.pid}.tmp"
      File.binwrite(temp, bytes)
      File.chmod(File.stat(target).mode & 0o7777, temp)
      return false unless signature_for(File.stat(target)) == signature
      File.rename(temp, target)
      true
    ensure
      FileUtils.rm_f(temp) if temp
    end
    private_class_method :replace_unless_changed

    # @param code [String]
    # @param line [Integer, nil]
    # @param message [String]
    # @return [Hash] a warning entry
    def self.warning(code, line, message)
      {"code" => code, "line" => line, "message" => message}
    end

    # A double-quoted value is read as JSON would (so `\"` works), and kept as written when it is not valid JSON;
    # single quotes are stripped. Shared with {SpineFile}, which reads the same frontmatter dialect.
    #
    # @param value [String] the text after `key:`
    # @return [String]
    def self.unquote_value(value)
      if value.match?(/\A".*"\z/m)
        begin
          return JSON.parse(value)
        rescue JSON::ParserError
          return value[1..-2]
        end
      end
      value.sub(/\A'(.*)'\z/) { $1 }
    end

    # The plan's path in a notes directory.
    #
    # @param dir [String] the notes directory
    # @return [String]
    def self.path_in(dir) = File.join(dir, FILE_NAME)

    # @return [String, nil] `title:` from the frontmatter
    def title = frontmatter["title"]

    # @return [String, nil] `owner_pane:` from the frontmatter, nil when blank
    def owner_pane = frontmatter["owner_pane"]

    # @return [String] `active`, `paused` or `done`; `active` when `status:` is absent or not one of them
    def status = STATUSES.include?(frontmatter["status"]) ? frontmatter["status"] : "active"

    # @return [Hash{String => Integer}] `total`, `done`, `in_progress`, `skipped`, `blocked`, `todo` and
    #   `left` (`todo + in_progress + blocked`)
    def counts
      @counts ||= begin
        by_state = TASK_STATES.to_h { |state| [state, tasks.count { |task| task.state == state }] }
        {"total" => tasks.size}.merge(by_state).merge("left" => by_state["todo"] + by_state["in_progress"] + by_state["blocked"])
      end
    end

    # @return [Integer] the share of tasks done or skipped, rounded to a whole percent; 0 with no tasks
    def percent
      return 0 if tasks.empty?
      ((counts["done"] + counts["skipped"]) * 100.0 / tasks.size).round
    end

    # @return [Hash, nil] `{"id", "title", "phase"}` of the first in-progress task, else the first to do; nil when none
    def current
      task = tasks.find { |t| t.state == "in_progress" } || tasks.find { |t| t.state == "todo" }
      task && {"id" => task.id, "title" => task.title, "phase" => task.phase}
    end

    private_class_method :new

    def initialize(text, truncated:, signature:, updated_at:, warnings:)
      @signature = signature
      @updated_at = updated_at
      @tasks = []
      @warnings = warnings.dup
      @frontmatter = {}
      @key_lines = {}
      @seen = {}
      lines = text.to_s.split("\n", -1).map { |line| line.chomp("\r") }
      lines[0] = lines[0].delete_prefix("\uFEFF") if lines.first
      body_from = read_frontmatter(lines)
      read_body(lines, body_from)
      @warnings << self.class.warning("truncated", nil, "The plan file is longer than #{MAX_BYTES} bytes; only the start was read.") if truncated
      @warnings = @warnings.each_with_index.sort_by { |w, i| [w["line"] || Float::INFINITY, i] }.map(&:first)
    end

    private

    # Reads the frontmatter block and returns the index of the first body line.
    def read_frontmatter(lines)
      return 0 unless lines.first.to_s.rstrip == "---"
      close = (1...lines.size).find { |i| %w[--- ...].include?(lines[i].rstrip) }
      return 0 unless close && (1...close).any? { |i| lines[i].match?(KEY_LINE) }
      @frontmatter_lines = 2..close
      (1...close).each do |i|
        match = lines[i].match(KEY_LINE)
        next unless match
        value = unquote(match[2])
        @frontmatter[match[1]] = value.empty? ? nil : value
        @key_lines[match[1]] = i + 1
        @status_line = i + 1 if match[1] == "status"
      end
      status = @frontmatter["status"]
      if status && !STATUSES.include?(status)
        @warnings << self.class.warning("bad_state", @status_line, "status '#{status}' is not active, paused or done; reading it as active.")
      end
      close + 1
    end

    def unquote(value) = self.class.unquote_value(value)

    def read_body(lines, first)
      fence = nil
      in_comment = false
      in_tasks = false
      phase = nil
      (first...lines.size).each do |index|
        line = lines[index]
        if in_comment
          in_comment = !line.include?("-->")
          next
        end
        if fence
          fence = nil if closes_fence?(line, fence)
          next
        end
        if (opening = line.match(/\A {0,3}(`{3,}|~{3,})/))
          fence = [opening[1][0], opening[1].size]
          next
        end
        raw = line
        line, in_comment = strip_comments(line)
        if (heading = line.match(/\A(\#{1,6})(?:\s+(.*?))?(?:\s+\#+)?\s*\z/))
          level = heading[1].size
          if level <= 2
            in_tasks = level == 2 && heading[2].to_s.casecmp?("Tasks")
            phase = nil
          elsif in_tasks
            phase = heading[2]
          end
          next
        end
        read_task(line, raw, index + 1, phase) if in_tasks
      end
    end

    def closes_fence?(line, fence)
      match = line.match(/\A {0,3}(`{3,}|~{3,})\s*\z/)
      match && match[1][0] == fence[0] && match[1].size >= fence[1]
    end

    # The text of the line outside HTML comments, and whether a comment is still open after it.
    def strip_comments(line)
      line = line.gsub(/<!--.*?-->/, "")
      start = line.index("<!--")
      start ? [line[0, start], true] : [line, false]
    end

    def read_task(line, raw, number, phase)
      match = line.match(/\A- \[(.)\](?:\s+(.*))?\z/)
      return unless match
      owner = read_owner(raw, number)
      rest = match[2].to_s.strip
      state = BOX_STATES[match[1]]
      unless state
        @warnings << self.class.warning("bad_state", number, "'[#{match[1]}]' is not a task state; use [ ] [~] [x] [-] or [!]. Counted as to do.")
        state = "todo"
      end
      id, title = split_id(rest)
      @warnings << self.class.warning("no_id", number, "No task id: start the task with an id such as T1.") unless id
      if id && @seen[id]
        @warnings << self.class.warning("duplicate_id", number, "Task id #{id} is already used on line #{@seen[id]}.")
      end
      @seen[id] ||= number if id
      reason = nil
      if %w[skipped blocked].include?(state)
        title, reason = split_reason(title)
        @warnings << self.class.warning("missing_reason", number, "A #{state} task ends with ' -- reason'.") unless reason
      end
      @tasks << Task.new(id: id, title: title, state: state, reason: reason, phase: phase, line: number, owner: owner)
    end

    # The pane id in the line's first closed `<!-- owner: ... -->` comment.
    def read_owner(raw, number)
      comment = raw.scan(/<!--(.*?)-->/).flatten.find { |text| text.match?(/\A\s*owner\s*:/i) }
      return unless comment
      value = comment.sub(/\A\s*owner\s*:/i, "").strip
      return if value.empty?
      return value if value.match?(PANE_ID)
      @warnings << self.class.warning("bad_owner", number, "Owner '#{value[0, 40]}' is not a tmux pane id such as %19; the task has no owner.")
      nil
    end

    def split_id(rest)
      word, title = rest.split(/\s+/, 2)
      word = word.to_s.delete_suffix(":")
      return [nil, rest] unless word.match?(ID)
      [word, title.to_s.strip]
    end

    def split_reason(title)
      if (match = title.match(/\A(.*?)(?:\s+|\A)--\s+(\S.*)\z/m))
        [match[1].strip, match[2].strip]
      else
        [title.sub(/\s*--\z/, ""), nil]
      end
    end
  end
end
