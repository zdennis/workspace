require "json"
require "time"

module Workspace
  module Commands
    # `workspace events`: the lifecycle event log and every agent daemon's
    # hook event file, read as one stream (see {Workspace::EventStream}).
    #
    # It only reads files, so a slow reader never makes a daemon wait.
    class Events
      # `events --json`'s schema version.
      JSON_SCHEMA_VERSION = 1

      # Seconds between reads while following.
      POLL_INTERVAL = 0.25

      # Reads between looks for daemon files that appeared (about 2 seconds).
      DISCOVER_EVERY = 8

      # Line types printed whatever --types says, since they are about the stream itself.
      STREAM_TYPES = %w[gap follow_started].freeze

      # Fields left out of a readable line: the envelope and the stream's own.
      HIDDEN_FIELDS = %w[type at timestamp workspace project data source cursor boot_id seq].freeze

      # @param stream_factory [#call] builds a new {Workspace::EventStream}
      # @param output [IO] where lines are printed
      # @param clock [#now] time source, for follow_started
      # @param sleeper [#call] waits the given seconds between reads
      def initialize(stream_factory:, output: $stdout, clock: Time, sleeper: ->(seconds) { sleep(seconds) })
        @stream_factory = stream_factory
        @output = output
        @clock = clock
        @sleeper = sleeper
      end

      # @param follow [Boolean] keep reading until stopped
      # @param json [Boolean] JSON instead of readable lines
      # @param types [Array<String>] only these types (empty for all)
      # @param since [String, nil] a cursor a line printed; resume after it
      # @param max_polls [Integer, nil] stop following after this many reads (for tests)
      # @return [void]
      # @raise [Workspace::EventStream::InvalidCursor] when +since+ can't be read
      def call(follow: false, json: false, types: [], since: nil, max_polls: nil)
        stream = @stream_factory.call
        gaps = stream.open(cursor: since, at: follow ? :end : :start)
        follow ? follow_stream(stream, gaps, json, types, max_polls) : print_once(stream, gaps, json, types)
      end

      private

      def print_once(stream, gaps, json, types)
        lines = gaps + select(stream.read(discover: false), types)
        lines.concat(select(stream.read(discover: false), types)) while stream.more?
        if json
          @output.puts JSON.generate("schema_version" => JSON_SCHEMA_VERSION, "ok" => true, "events" => lines, "cursor" => stream.cursor_string)
        else
          lines.each { |line| @output.puts format(line) }
        end
      end

      def follow_stream(stream, gaps, json, types, max_polls)
        started = {"type" => "follow_started", "at" => @clock.now.utc.iso8601(3), "source" => "stream", "cursor" => stream.cursor_string}
        emit([started, *gaps], json)
        polls = 0
        loop do
          polls += 1
          emit(select(stream.read(discover: (polls % DISCOVER_EVERY).zero?), types), json)
          break if max_polls && polls >= max_polls
          @sleeper.call(POLL_INTERVAL) unless stream.more?
        end
      rescue Errno::EPIPE, Interrupt
        nil
      rescue SystemCallError, IOError => e
        raise Workspace::Error, "could not read the event files (#{e.message})"
      end

      def emit(lines, json)
        return if lines.empty?
        lines.each { |line| @output.puts(json ? JSON.generate(line) : format(line)) }
        @output.flush
      end

      def select(lines, types)
        return lines if types.empty?
        lines.select { |line| types.include?(line["type"]) || STREAM_TYPES.include?(line["type"]) }
      end

      # `at  workspace  type  key=value ...`, with control characters blanked.
      def format(line)
        fields = line["data"].is_a?(Hash) ? line["data"] : line.except(*HIDDEN_FIELDS)
        details = fields.filter_map { |key, value| "#{key}=#{format_value(value)}" unless value.nil? }
        [line["at"], line["workspace"] || "-", line["type"], *details].join("  ").gsub(/[[:cntrl:]]+/, " ")
      end

      def format_value(value)
        return JSON.generate(value) unless value.is_a?(String)
        (value.include?(" ") || value.include?("=")) ? value.inspect : value
      end
    end
  end
end
