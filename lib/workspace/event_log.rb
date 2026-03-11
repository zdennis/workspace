require "json"
require "time"

module Workspace
  # Append-only event log for workspace state changes.
  # Events are stored as JSONL (one JSON object per line).
  # The event log is the source of truth; the state file is a materialized view.
  class EventLog
    DEFAULT_COMPACT_THRESHOLD = 10_240 # 10KB

    # @param config [Workspace::Config] configuration for file paths
    # @param project_settings [Workspace::ProjectSettings, nil] for reading global config
    # @param error_output [IO] error output stream for warnings (stderr)
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, project_settings: nil, error_output: $stderr, logger: Workspace::Logger.new)
      @config = config
      @project_settings = project_settings
      @error_output = error_output
      @logger = logger
    end

    # Appends an event to the log file.
    #
    # @param type [String] event type (e.g., "launched", "killed", "state_set")
    # @param project [String] project name
    # @param data [Hash] event payload (unique_id, iterm_window_id, etc.)
    # @return [void]
    def append(type:, project:, data: {})
      event = {
        "timestamp" => Time.now.utc.iso8601(3),
        "type" => type,
        "project" => project,
        "data" => data
      }
      @logger.debug { "event_log: append #{type} for #{project}" }
      File.open(@config.event_log_file, "a") { |f| f.puts JSON.generate(event) }
    end

    # Reads all events from the log file.
    #
    # @return [Array<Hash>] list of event hashes
    def events
      return [] unless File.exist?(@config.event_log_file)
      File.readlines(@config.event_log_file).filter_map do |line|
        stripped = line.strip
        next if stripped.empty?
        JSON.parse(stripped)
      rescue JSON::ParserError
        @logger.debug { "event_log: skipping corrupt line" }
        nil
      end
    end

    # Replays the event log to reconstruct the current state.
    #
    # @return [Hash] project_name => {data}
    def reconstruct
      state = {}
      events.each do |event|
        project = event["project"]
        case event["type"]
        when "state_set", "launched", "window_discovered", "repaired", "migrated", "compacted"
          state[project] ||= {}
          state[project].merge!(event["data"]) if event["data"]
        when "state_removed", "killed", "stopped", "pruned"
          state.delete(project)
        end
      end
      state
    end

    # Compacts the log by rewriting it with one event per active project.
    #
    # @return [Hash] the compacted state
    def compact
      state = reconstruct
      @logger.debug { "event_log: compacting #{size} bytes to #{state.size} project(s)" }
      tmp = "#{@config.event_log_file}.tmp"
      timestamp = Time.now.utc.iso8601(3)
      File.open(tmp, "w") do |f|
        state.each do |project, data|
          event = {
            "timestamp" => timestamp,
            "type" => "compacted",
            "project" => project,
            "data" => data
          }
          f.puts JSON.generate(event)
        end
      end
      File.rename(tmp, @config.event_log_file)
      state
    end

    # @return [Integer] file size in bytes, 0 if file does not exist
    def size
      return 0 unless File.exist?(@config.event_log_file)
      File.size(@config.event_log_file)
    end

    # @return [Boolean] whether the event log file exists
    def exists?
      File.exist?(@config.event_log_file)
    end

    # Warns the user if the event log exceeds the size threshold.
    #
    # @return [void]
    def warn_if_large
      threshold = compact_threshold
      return unless size > threshold
      kb = (size / 1024.0).round(1)
      @error_output.puts "Note: Event log is #{kb}KB. Run 'workspace event-log compact' to compact it."
    end

    # Returns the configured compaction threshold in bytes.
    # Reads from global config `event_log_compact_threshold` (e.g., "10kb", "1mb").
    # Falls back to DEFAULT_COMPACT_THRESHOLD.
    #
    # @return [Integer] threshold in bytes
    def compact_threshold
      return DEFAULT_COMPACT_THRESHOLD unless @project_settings
      raw = @project_settings.load_global["event_log_compact_threshold"]
      return DEFAULT_COMPACT_THRESHOLD unless raw
      parse_size(raw.to_s)
    rescue
      DEFAULT_COMPACT_THRESHOLD
    end

    private

    # Parses a human-readable size string into bytes.
    # Supports: "10kb", "1mb", "500b", "1024" (plain number = bytes).
    #
    # @param str [String] size string
    # @return [Integer] size in bytes
    def parse_size(str)
      str = str.strip.downcase
      case str
      when /\A(\d+(?:\.\d+)?)\s*kb\z/
        ($1.to_f * 1024).to_i
      when /\A(\d+(?:\.\d+)?)\s*mb\z/
        ($1.to_f * 1024 * 1024).to_i
      when /\A(\d+(?:\.\d+)?)\s*gb\z/
        ($1.to_f * 1024 * 1024 * 1024).to_i
      when /\A(\d+(?:\.\d+)?)\s*b?\z/
        $1.to_i
      else
        DEFAULT_COMPACT_THRESHOLD
      end
    end
  end
end
