require "json"

module Workspace
  # Reads the lifecycle event log and every agent daemon's hook event file as
  # one stream, and keeps the cursor that resumes it.
  #
  # Each file is a source. A source remembers the file it is reading (by
  # inode), the offset just past the last line read, and that line's time; a
  # hook source also its `boot_id` and `seq`. The cursor is all of them,
  # encoded so readers treat it as opaque. Lines are only read, so a slow
  # reader never makes a writer wait.
  #
  # A file that was rotated or replaced (`event-log compact`) while a source
  # was reading it is read to its end, through the handle already open, and
  # the source goes on in the new file with only the lines after the last
  # one's time: that skips the compacted seed a lifecycle rotation writes.
  class EventStream
    # A cursor this stream can't read.
    class InvalidCursor < UsageError
      def initialize(message = "That cursor can't be read; pass one an events line printed, or leave out --since.")
        super(message, code: "invalid_cursor")
      end
    end

    # The prefix naming the cursor's format.
    CURSOR_PREFIX = "1."

    # The lines `gap` gives as its reason.
    GAP_NOT_RETAINED = "cursor_not_retained"

    # @param state [Hash] the sources' positions
    # @return [String] the cursor: {CURSOR_PREFIX}, then base64url (no padding) of the JSON
    def self.encode_cursor(state)
      CURSOR_PREFIX + [JSON.generate(state)].pack("m0").tr("+/", "-_").delete("=")
    end

    # @param cursor [String] a cursor {.encode_cursor} made
    # @return [Object] the JSON inside it
    # @raise [ArgumentError, JSON::ParserError] when it isn't one
    def self.decode_cursor(cursor)
      body = cursor.delete_prefix(CURSOR_PREFIX).tr("-_", "+/")
      JSON.parse((body + "=" * (-body.length % 4)).unpack1("m0"))
    end

    # @param lifecycle_path [String] the lifecycle event log
    # @param lifecycle_rotated [Integer] how many rotated copies it keeps (`.1` .. `.N`)
    # @param hook_dir [String] the directory holding every daemon's hook event file
    # @param clock [#now] time source, for the time of gap lines
    def initialize(lifecycle_path:, hook_dir:, lifecycle_rotated: EventLog::KEEP_ROTATED, clock: Time)
      @lifecycle_path = lifecycle_path
      @lifecycle_rotated = lifecycle_rotated
      @hook_dir = hook_dir
      @clock = clock
      @sources = {}
    end

    # Opens every source: from the cursor when given one, else at the end of
    # each file (+at: :end+) or at the start of what is kept (+at: :start+;
    # the current lifecycle file and each daemon's `.1` and current file).
    #
    # @param cursor [String, nil] a cursor a line of this stream carried
    # @param at [Symbol] :end or :start, for a stream with no cursor
    # @return [Array<Hash>] gap lines for sources the cursor is older than
    # @raise [InvalidCursor] when the cursor can't be read
    def open(cursor: nil, at: :end)
      parts = cursor ? decode(cursor) : nil
      gaps = []
      add_source("lifecycle", Source.new(kind: :lifecycle, workspace: nil, path: @lifecycle_path, rotated: @lifecycle_rotated))
      hook_names.each { |name| add_source("hook:#{name}", hook_source(name)) }

      @sources.each do |key, source|
        part = parts && part_for(parts, key)
        if part
          gaps << gap_line(source) unless source.resume(part)
        elsif parts
          source.start_at_beginning(all: true)
        elsif at == :end
          source.start_at_end
        else
          source.start_at_beginning(all: source.kind == :hook)
        end
      end
      @sources.reject! { |_, source| source.gone? }
      gaps.each { |gap| gap["cursor"] = cursor_string }
    end

    # Reads every complete line written since the last call, oldest first
    # across sources, each with the cursor as it stands after it. Daemon files
    # that appeared since are read from their start.
    #
    # @param discover [Boolean] look for daemon files that appeared since
    # @return [Array<Hash>] the lines, each with `source` and `cursor` added
    def read(discover: true)
      if discover
        (hook_names - @sources.keys.filter_map { |key| key.delete_prefix("hook:") if key.start_with?("hook:") }).each do |name|
          source = hook_source(name)
          source.start_at_beginning(all: true)
          add_source("hook:#{name}", source)
        end
      end
      pending = @sources.to_h { |key, source| [key, source.read_lines] }
      lines = merge(pending)
      @sources.reject! { |_, source| source.gone? }
      lines
    end

    # @return [Boolean] whether the last {#read} left lines it will return next time
    def more?
      @sources.each_value.any?(&:more?)
    end

    # @return [String] the cursor for everything read so far
    def cursor_string
      state = {"h" => {}}
      @sources.each do |key, source|
        part = source.position
        next unless part
        if source.kind == :lifecycle
          state["l"] = part
        else
          state["h"][source.workspace] = part
        end
      end
      self.class.encode_cursor(state)
    end

    private

    def add_source(key, source)
      @sources[key] = source
    end

    def hook_source(name)
      Source.new(kind: :hook, workspace: name, path: HookEventLog.path_for(@hook_dir, name), rotated: 1)
    end

    def hook_names
      Dir.children(@hook_dir).filter_map { |file| file[/\A(.+)\.jsonl(?:\.1)?\z/, 1] }.uniq.sort
    rescue SystemCallError
      []
    end

    def part_for(parts, key)
      (key == "lifecycle") ? parts["l"] : parts["h"][key.delete_prefix("hook:")]
    end

    def decode(cursor)
      raise InvalidCursor unless cursor.is_a?(String) && cursor.start_with?(CURSOR_PREFIX)
      state = self.class.decode_cursor(cursor)
      raise InvalidCursor unless state.is_a?(Hash) && state.fetch("h", {}).is_a?(Hash)
      parts = [state["l"], *state.fetch("h", {}).values].compact
      raise InvalidCursor unless parts.all? { |part| part.is_a?(Hash) && part["i"].is_a?(Integer) && part["o"].is_a?(Integer) && part["o"] >= 0 }
      {"l" => state["l"], "h" => state.fetch("h", {})}
    rescue ArgumentError, JSON::ParserError
      raise InvalidCursor
    end

    def gap_line(source)
      {"type" => "gap", "at" => @clock.now.utc.iso8601(3), "source" => source.kind.to_s, "workspace" => source.workspace,
       "reason" => GAP_NOT_RETAINED}
    end

    # Takes the oldest next line of any source each time, so lines keep the
    # order they have in their own file however the sources interleave.
    def merge(pending)
      out = []
      loop do
        key, lines = pending.reject { |_, lines| lines.empty? }.min_by { |_, lines| lines.first[:time].to_s }
        break unless key
        entry = lines.shift
        @sources[key].commit(entry[:position])
        out << entry[:line].merge("cursor" => cursor_string)
      end
      out
    end

    # One file and its rotated copies, read forward.
    class Source
      # How much of a file's end is read for its last line's time.
      TAIL_BYTES = 65_536

      # Most bytes one read takes from a source; the rest waits for the next read.
      MAX_READ = 1_048_576

      attr_reader :kind, :workspace

      def initialize(kind:, workspace:, path:, rotated:)
        @kind = kind
        @workspace = workspace
        @path = path
        @rotated = (1..rotated).map { |n| "#{path}.#{n}" }
        @queue = []
        @io = nil
        @committed = nil
        @gone = false
      end

      # The current file, then its rotated copies, newest first.
      def files
        [@path, *@rotated]
      end

      # Files are opened as soon as the source starts, so the position is in
      # the file that was there then, whatever replaces it before the first read.
      def start_at_end
        @queue = [[@path, :end, nil]]
        open_next
        @committed = @io && {"i" => @ino, "o" => @offset, "t" => last_time_in(@io, @offset)}
        @last_time = @committed&.dig("t")
      end

      # Every kept file oldest first, or (+all: false+) only the current one.
      def start_at_beginning(all:, after: nil)
        chosen = all ? files.reverse : [@path]
        @queue = chosen.select { |file| File.exist?(file) }.map { |file| [file, 0, after] }
        @queue = [[@path, 0, after]] if @queue.empty?
        open_next
      end

      # @return [Boolean] false when the cursor's file is no longer kept
      def resume(part)
        @committed = part
        if kind == :hook && files.none? { |file| File.exist?(file) }
          @gone = true
          return true
        end
        index = files.index { |file| (s = stat(file)) && s.ino == part["i"] && s.size >= part["o"] }
        unless index
          start_at_beginning(all: true, after: (kind == :hook) ? part : part["t"])
          return false
        end
        newer = files.first(index).reverse.select { |file| File.exist?(file) }
        @queue = [[files[index], part["o"], nil], *newer.map { |file| [file, 0, newer_after(part["t"])] }]
        @queue << [@path, 0, newer_after(part["t"])] unless @queue.any? { |file, _, _| file == @path }
        open_next
        return true if @ino == part["i"]
        # The file rotated between the stat and the open: try again from what is there now.
        close_and_continue
        @resumes = (@resumes || 0) + 1
        return resume(part) if @resumes < 3
        start_at_beginning(all: true, after: (kind == :hook) ? part : part["t"])
        false
      end

      # @return [Boolean] whether the last read stopped at its size limit with more to read
      def more?
        @more
      end

      def gone?
        @gone
      end

      def commit(position)
        @committed = position
      end

      # @return [Hash, nil] this source's part of the cursor
      def position
        @committed
      end

      # Complete lines from where the source stands, each with the position just past it.
      def read_lines
        out = []
        @more = false
        budget = MAX_READ
        loop do
          open_next if @io.nil?
          break unless @io
          before = @offset
          out.concat(read_available(budget))
          budget -= @offset - before
          if @hit_limit || budget <= 0
            @more = true
            break
          end
          step = advance_past_eof
          # The file was rotated or replaced: a line may have reached the old
          # file after the last read, so it is read once more before moving on.
          out.concat(read_available(MAX_READ)) if step == :replaced
          if @hit_limit
            # Still more in the old file: leave the move to the new one for the next read.
            @queue.clear
            @more = true
            break
          end
          break unless step
          close_and_continue
        end
        out
      end

      private

      # The time of the file's last complete line, read from its tail, so a
      # cursor taken before any line is read still filters a replaced file.
      def last_time_in(io, size)
        return nil if size.zero?
        tail = io.pread([size, TAIL_BYTES].min, [size - TAIL_BYTES, 0].max)
        tail.split("\n").reverse_each do |raw|
          line = parse(raw)
          time = line && line_time(line)
          return time if time
        end
        nil
      rescue SystemCallError, IOError
        nil
      end

      def stat(file)
        File.stat(file)
      rescue SystemCallError
        nil
      end

      def open_next
        while (entry = @queue.first)
          file, offset, after = entry
          io = begin
            File.open(file, "rb")
          rescue SystemCallError
            nil
          end
          unless io
            # The current file not there yet is waited for, unless all of a
            # daemon's files are gone; a rotated copy that is gone is skipped.
            if file == @path
              @gone = true if kind == :hook && files.none? { |name| File.exist?(name) }
              @queue = [[@path, 0, newer_after(@last_time)]] if offset == :end
              return
            end
            @queue.shift
            next
          end
          @queue.shift
          @io = io
          @ino = io.stat.ino
          @offset = (offset == :end) ? io.size : offset
          @after = after
          @last_time ||= @committed&.dig("t")
          return
        end
      end

      def read_available(limit = MAX_READ)
        @io.seek(@offset)
        chunk = @io.read(limit) || ""
        @hit_limit = chunk.bytesize >= limit
        last = chunk.rindex("\n")
        unless last
          # A line longer than the limit can't be read whole; it is passed over.
          @offset += chunk.bytesize if chunk.bytesize >= limit
          return []
        end
        out = []
        position = @offset
        chunk[0..last].each_line do |raw|
          position += raw.bytesize
          line = parse(raw)
          next unless line
          time = line_time(line)
          @last_time = time if time
          next if skip?(line, time)
          out << {line: decorate(line), time: time, position: position_for(line, position, time)}
        end
        @offset = position
        out
      end

      # At the end of the open file: true when there is a newer file to go on to.
      def advance_past_eof
        return true unless @queue.empty?
        current = stat(@path)
        if current.nil? && kind == :hook && files.none? { |file| File.exist?(file) }
          # The workspace's files were removed: the source ends, and leaves the cursor.
          @gone = true
          @io.close
          @io = nil
          return false
        end
        return false if current.nil? || current.ino == @ino
        # The file was rotated or replaced; what follows it starts after the last line read.
        if kind == :hook && (rotated = stat(@rotated.first)) && rotated.ino != @ino
          @queue << [@rotated.first, 0, nil]
        end
        @queue << [@path, 0, newer_after(@last_time)]
        :replaced
      end

      # A file that comes after the one a source was reading: a daemon's holds
      # only newer lines, while a lifecycle log rotated or compacted into place
      # starts with a seed of older ones, which the last line's time skips.
      def newer_after(time)
        (kind == :lifecycle) ? time : nil
      end

      # Lines a source has already passed: in a lifecycle file, any up to the
      # last time read; after a gap in a daemon's file, any up to the cursor's
      # seq in its boot, or before its time in another boot. Times are compared
      # as strings, which works because every writer uses UTC with milliseconds.
      def skip?(line, time)
        return false unless @after && time
        return time <= @after unless @after.is_a?(Hash)
        if line["boot_id"] == @after["b"] && line["seq"].is_a?(Integer) && @after["s"].is_a?(Integer)
          line["seq"] <= @after["s"]
        else
          @after["t"].is_a?(String) && time < @after["t"]
        end
      end

      def close_and_continue
        @io&.close
        @io = nil
        true
      end

      def parse(raw)
        line = JSON.parse(raw.dup.force_encoding(Encoding::UTF_8).scrub)
        line.is_a?(Hash) ? line : nil
      rescue JSON::ParserError
        nil
      end

      def line_time(line)
        time = (kind == :lifecycle) ? line["timestamp"] : line["at"]
        time.is_a?(String) ? time : nil
      end

      def decorate(line)
        if kind == :lifecycle
          data = line["data"].is_a?(Hash) ? line["data"] : {}
          workspace = data["workspace"].is_a?(String) ? data["workspace"] : line["project"]
          line.merge("source" => "lifecycle", "at" => line["timestamp"], "workspace" => workspace)
        else
          line.merge("source" => "hook")
        end
      end

      def position_for(line, offset, time)
        part = {"i" => @ino, "o" => offset, "t" => time}
        if kind == :hook
          part["b"] = line["boot_id"]
          part["s"] = line["seq"]
        end
        part
      end
    end
  end
end
