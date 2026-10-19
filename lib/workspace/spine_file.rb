require "digest"
require "set"
require "time"

module Workspace
  # One file of a workspace's plan spine (a stage file such as `30-implement.md`, or `goal.md`),
  # read without following links and never failing. Whatever the bytes hold, the result carries
  # the values it could read and `warnings` for what it could not.
  #
  # The frontmatter is the dialect {PlanFile} reads (a block between two `---` lines, read line by
  # line as `key: value`, not as YAML) plus two list forms: `key: [a, b]` on one line, or `key:`
  # followed by indented `- a` lines. Repeated keys keep the first. The body is read for one
  # thing: the column-0 `- [ ]` and `- [x]` lines under a `## Done when` heading.
  #
  # {SpineTree} walks the folder; `spine set` uses {#revision}, {#path}, {#frontmatter_lines} and
  # {#key_span} to find the lines it rewrites.
  class SpineFile
    # Bytes read; the file's revision still covers every byte.
    MAX_BYTES = 65_536

    # The closing `---` must be on one of the first this many lines.
    MAX_FRONTMATTER_LINES = 100

    # Keys read from one frontmatter block.
    MAX_KEYS = 40

    # Longest key, in characters.
    MAX_KEY = 64

    # Longest scalar value or list item, in characters, unless {VALUE_LIMITS} says otherwise.
    MAX_VALUE = 500

    # Items read from one list.
    MAX_LIST = 20

    # Per-key value limits that differ from {MAX_VALUE}.
    VALUE_LIMITS = {"title" => 120, "description" => 300, "note" => 300}.freeze

    # The longest body {#body_excerpt} returns, in bytes.
    MAX_BODY = 16_384

    # The format version this code reads; a file that says `spine: 2` or more is still read.
    FORMAT = 1

    # The statuses a stage may have, as written by tools.
    STATUSES = %w[not_started in_progress blocked completed skipped].freeze

    # Words read as a status, after lowercasing and reading `-` and spaces as `_`.
    STATUS_ALIASES = {
      "todo" => "not_started", "pending" => "not_started", "planned" => "not_started", "open" => "not_started",
      "active" => "in_progress", "started" => "in_progress", "doing" => "in_progress", "wip" => "in_progress",
      "stuck" => "blocked",
      "done" => "completed", "complete" => "completed", "finished" => "completed", "closed" => "completed",
      "skip" => "skipped", "n/a" => "skipped", "wontdo" => "skipped"
    }.freeze

    KEY_LINE = /\A([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*\z/
    private_constant :KEY_LINE

    LIST_ITEM = /\A[ \t]*-(?:[ \t]+(.*?))?\s*\z/
    private_constant :LIST_ITEM

    # @param code [String] one of the warning codes in docs/README.spine.md
    # @param line [Integer, nil] 1-based line in the file; nil for the whole file
    # @param message [String]
    # @param value [String, nil] the offending value, for the codes that name one
    # @return [Hash] a warning entry
    def self.warning(code, line, message, value: nil)
      entry = {"code" => code, "line" => line, "message" => message}
      entry["value"] = value if value
      entry
    end

    # Reads a file without following a link.
    #
    # @param path [String] absolute path
    # @param relative [String] the path below `spine/` that is reported as the file's name
    # @return [SpineFile] with {#read?} false and a `link` or `not_a_file` warning when the path is not a regular file
    def self.read(path, relative: File.basename(path))
      stat = File.lstat(path)
      return refused(path, relative, "link", "#{relative} is a link, so it isn't read.") if stat.symlink?
      return refused(path, relative, "not_a_file", "#{relative} is not a regular file, so it isn't read.") unless stat.file?

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        info = file.stat
        return refused(path, relative, "not_a_file", "#{relative} is not a regular file, so it isn't read.") unless info.file?
        digest = Digest::SHA256.new
        head = +"".b
        total = 0
        while (chunk = file.read(MAX_BYTES))
          digest << chunk
          total += chunk.bytesize
          head << chunk.byteslice(0, MAX_BYTES - head.bytesize) if head.bytesize < MAX_BYTES
        end
        new(path: path, relative: relative, bytes: head, revision: digest.hexdigest[0, 8],
          modified_at: info.mtime.utc.iso8601, truncated: total > MAX_BYTES)
      end
    rescue Errno::ELOOP
      refused(path, relative, "link", "#{relative} is a link, so it isn't read.")
    rescue SystemCallError => e
      refused(path, relative, "not_a_file", "#{relative} can't be read: #{e.message}")
    end

    def self.refused(path, relative, code, message)
      new(path: path, relative: relative, bytes: nil, revision: nil, modified_at: nil, truncated: false,
        warnings: [warning(code, nil, message)])
    end
    private_class_method :refused

    # Parses bytes already in memory (specs, and callers that have the file's text).
    #
    # @param bytes [String] the file's bytes
    # @param relative [String] the name to report
    # @return [SpineFile]
    def self.parse(bytes, relative: "stage.md")
      new(path: nil, relative: relative, bytes: bytes.b, revision: Digest::SHA256.hexdigest(bytes.b)[0, 8],
        modified_at: nil, truncated: false)
    end

    # @return [String, nil] absolute path of the file; nil for bytes parsed in memory
    attr_reader :path

    # @return [String] the file's name below `spine/`, e.g. `30-implement/10-api.md`
    attr_reader :relative

    # @return [String, nil] first 8 hex digits of the SHA-256 of all of the file's bytes; nil when the file was not read
    attr_reader :revision

    # @return [String, nil] the file's modification time, UTC, to the second
    attr_reader :modified_at

    # @return [Hash{String => String, Array<String>, nil}] frontmatter values by key, in file order; nil for an empty value
    attr_reader :frontmatter

    # @return [Range, nil] the 1-based line numbers between the `---` lines; nil without frontmatter
    attr_reader :frontmatter_lines

    # @return [Array<Hash>] `{"code", "line", "message"}` and `"value"` for the codes that name one, ordered by line
    attr_reader :warnings

    # @return [Array<Hash>] the `## Done when` items: `{"text", "done", "line"}`
    attr_reader :items

    # @return [Boolean] whether only the first {MAX_BYTES} bytes were read
    attr_reader :truncated

    # @return [Boolean] whether the file was read as text: false for a link, a non-file or non-UTF-8 bytes
    def read? = @read

    # @param key [String]
    # @return [Range, nil] the 1-based lines of `key:` and its list items; nil when the key is not in the frontmatter
    def key_span(key) = @key_spans[key]

    # @param key [String]
    # @return [String, nil] a scalar value, nil when the key is absent, empty or a list
    def value(key)
      found = @frontmatter[key]
      found.is_a?(String) ? found : nil
    end

    # @param key [String]
    # @return [Array<String>] a list value; a scalar is a list of one, an absent or empty key an empty list
    def list(key)
      found = @frontmatter[key]
      case found
      when Array then found
      when String then [found]
      else []
      end
    end

    # @return [Integer] the `spine:` format number, {FORMAT} when absent or not a number
    def format_version
      raw = value("spine")
      raw&.match?(/\A\d+\z/) ? raw.to_i : FORMAT
    end

    # @return [String, nil] the word `status:` holds, nil when absent or empty
    def status_raw = value("status")

    # @return [String] one of {STATUSES}, or `unknown`
    def status = self.class.canonical_status(status_raw)

    # Reads a status word the way a stage file is read.
    #
    # @param raw [String, nil] a status or an alias, in any case, with `-` or spaces for `_`
    # @return [String] one of {STATUSES}, or `unknown` for nil and for a word that is neither
    def self.canonical_status(raw)
      return "unknown" unless raw
      word = raw.downcase.gsub(/[-\s]+/, "_")
      return word if STATUSES.include?(word)
      STATUS_ALIASES.fetch(word, "unknown")
    end

    # The text after the frontmatter (the whole text without frontmatter), from the bytes read.
    #
    # @return [String, nil] nil when the file was not read as text
    attr_reader :body

    # The body cut to {MAX_BODY} bytes on a character boundary.
    #
    # @return [Array(String, Boolean), nil] the text and whether it was cut; nil when the file was not read as text
    def body_excerpt
      return nil unless @body
      return [@body, @truncated] if @body.bytesize <= MAX_BODY
      cut = @body.byteslice(0, MAX_BODY).force_encoding(Encoding::UTF_8)
      cut = cut.byteslice(0, cut.bytesize - 1).force_encoding(Encoding::UTF_8) until cut.valid_encoding?
      [cut, true]
    end

    # @return [Hash] `total`, `done` and `items` of the `## Done when` checklist
    def done_when
      {"total" => @items.size, "done" => @items.count { |item| item["done"] }, "items" => @items}
    end

    # Adds a warning found by the caller (the tree), keeping the list ordered by line.
    #
    # @param entry [Hash] from {.warning}
    # @return [void]
    def add_warning(entry)
      @warnings << entry
      order_warnings
    end

    private_class_method :new

    def initialize(path:, relative:, bytes:, revision:, modified_at:, truncated:, warnings: [])
      @path = path
      @relative = relative
      @revision = revision
      @modified_at = modified_at
      @truncated = truncated
      @warnings = warnings.dup
      @frontmatter = {}
      @key_spans = {}
      @items = []
      @long_lists = Set.new
      @read = false
      read_text(bytes, truncated) if bytes
      order_warnings
    end

    private

    def order_warnings
      @warnings = @warnings.each_with_index.sort_by { |w, i| [w["line"] || Float::INFINITY, i] }.map(&:first)
    end

    def read_text(bytes, truncated)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      text = text.byteslice(0, text.bytesize - 1).force_encoding(Encoding::UTF_8) while truncated && !text.valid_encoding? && text.bytesize > MAX_BYTES - 4
      unless text.valid_encoding?
        @warnings << self.class.warning("not_utf8", nil, "#{@relative} isn't text, so it isn't read.")
        return
      end
      @read = true
      @warnings << self.class.warning("too_large", nil, "Only the first #{MAX_BYTES} bytes of #{@relative} were read.") if truncated
      lines = text.split("\n", -1).map { |line| line.chomp("\r") }
      lines[0] = lines[0].delete_prefix("﻿") if lines.first
      first = read_frontmatter(lines)
      @body = lines[first..].join("\n")
      read_body(lines, first)
      @warnings << self.class.warning("newer_format", @key_spans["spine"]&.first, "#{@relative} is written for spine format #{format_version}; this reads format #{FORMAT}.") if format_version > FORMAT
    end

    # Reads the frontmatter block and returns the index of the first body line.
    def read_frontmatter(lines)
      unless lines.first.to_s.rstrip == "---"
        @warnings << self.class.warning("no_frontmatter", nil, "#{@relative} has no frontmatter, so its status is unknown.")
        return 0
      end
      close = (1...[lines.size, MAX_FRONTMATTER_LINES].min).find { |i| %w[--- ...].include?(lines[i].rstrip) }
      unless close
        @warnings << self.class.warning("no_frontmatter", 1, "The frontmatter of #{@relative} has no closing --- within #{MAX_FRONTMATTER_LINES} lines, so it isn't read.")
        return 0
      end
      @frontmatter_lines = 2..close
      read_keys(lines, close)
      close + 1
    end

    def read_keys(lines, close)
      current = nil
      (1...close).each do |index|
        line = lines[index]
        number = index + 1
        next if line.strip.empty? || line.lstrip.start_with?("#")

        if (match = line.match(KEY_LINE))
          current = read_key(match[1], match[2], number)
        elsif (item = line.match(LIST_ITEM)) && current
          next if current == :skip
          add_item(current, item[1].to_s, number)
        else
          @warnings << self.class.warning("bad_line", number, "Line #{number} of #{@relative} isn't read: it is not `key: value` or a list item.")
        end
      end
    end

    # @return [String, Symbol, nil] the key a list may follow, :skip for a key whose list items are ignored, else nil
    def read_key(key, raw, number)
      if key.size > MAX_KEY
        @warnings << self.class.warning("clipped", number, "Line #{number} of #{@relative}: the key is longer than #{MAX_KEY} characters, so the line isn't read.")
        return :skip
      end
      if @frontmatter.key?(key)
        @warnings << self.class.warning("duplicate_key", number, "`#{key}` is already set on line #{@key_spans[key].first} of #{@relative}; the first is kept.", value: key)
        return :skip
      end
      if @frontmatter.size >= MAX_KEYS
        @warnings << self.class.warning("clipped", number, "#{@relative} has more than #{MAX_KEYS} keys; the rest aren't read.") unless @keys_clipped
        @keys_clipped = true
        return :skip
      end

      @key_spans[key] = number..number
      if raw.empty?
        @frontmatter[key] = nil
        return key
      end
      if raw.start_with?("[") && raw.end_with?("]")
        @frontmatter[key] = []
        split_inline(raw[1...-1]).each { |item| add_item(key, item, number) }
        return nil
      end
      value = fold(PlanFile.unquote_value(raw))
      @frontmatter[key] = value.empty? ? nil : clip(key, value, number)
      nil
    end

    def add_item(key, text, number)
      list = (@frontmatter[key] ||= [])
      @key_spans[key] = @key_spans[key].first..number
      item = fold(PlanFile.unquote_value(text.strip))
      return if item.empty?
      if list.size >= MAX_LIST
        @warnings << self.class.warning("clipped", number, "`#{key}` in #{@relative} has more than #{MAX_LIST} items; the rest aren't read.", value: key) if @long_lists.add?(key)
        return
      end
      list << clip(key, item, number, limit: MAX_VALUE)
    end

    # Splits `a, "b, c", d` on the commas outside quotes.
    def split_inline(text)
      items = []
      buffer = +""
      quote = nil
      text.each_char do |char|
        if quote
          quote = nil if char == quote
          buffer << char
        elsif char == '"' || char == "'"
          quote = char
          buffer << char
        elsif char == ","
          items << buffer
          buffer = +""
        else
          buffer << char
        end
      end
      items << buffer
      items.map(&:strip).reject(&:empty?)
    end

    # One line: control characters become spaces, format characters (such as bidi overrides) go.
    def fold(text)
      text.gsub(/\p{Cf}/, "").gsub(/[\p{Cc}\p{Z}\s]+/, " ").strip
    end

    def clip(key, text, number, limit: VALUE_LIMITS.fetch(key, MAX_VALUE))
      return text if text.size <= limit
      @warnings << self.class.warning("clipped", number, "`#{key}` in #{@relative} is longer than #{limit} characters; it was cut.", value: key)
      text[0, limit]
    end

    # The checklist under `## Done when`: column-0 boxes only, nothing in fenced code or HTML comments.
    def read_body(lines, first)
      fence = nil
      in_comment = false
      in_section = false
      (first...lines.size).each do |index|
        line = lines[index]
        if in_comment
          in_comment = !line.include?("-->")
          next
        end
        if fence
          fence = nil if (m = line.match(/\A {0,3}(`{3,}|~{3,})\s*\z/)) && m[1][0] == fence[0] && m[1].size >= fence[1]
          next
        end
        if (opening = line.match(/\A {0,3}(`{3,}|~{3,})/))
          fence = [opening[1][0], opening[1].size]
          next
        end
        line = line.gsub(/<!--.*?-->/, "")
        if (start = line.index("<!--"))
          line = line[0, start]
          in_comment = true
        end
        if (heading = line.match(/\A(\#{1,6})(?:\s+(.*?))?(?:\s+\#+)?\s*\z/))
          in_section = heading[1].size == 2 && heading[2].to_s.casecmp?("Done when")
        elsif in_section && (box = line.match(/\A- \[([ xX])\](?:\s+(.*))?\z/))
          text = fold(box[2].to_s)
          if text.size > MAX_VALUE
            @warnings << self.class.warning("clipped", index + 1, "Line #{index + 1} of #{@relative} is longer than #{MAX_VALUE} characters; it was cut.")
            text = text[0, MAX_VALUE]
          end
          @items << {"text" => text, "done" => box[1] != " ", "line" => index + 1}
        end
      end
    end
  end
end
