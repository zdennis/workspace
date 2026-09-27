require "json"
require "time"

module Workspace
  # Append-only event log for workspace state changes and agent activity.
  # Events are stored as JSONL (one JSON object per line).
  # The event log is the source of truth; the state file is a materialized view.
  #
  # State events (launches, kills, ...) are replayed into the state file.
  # Activity events (dispatches, stage completions and failures, lock waits,
  # per-pane agent state changes) are written with {#record} and ignored by
  # {#reconstruct}; they are there to be read back with `workspace event-log
  # show`, and the latest {AGENT_STATE} per pane lets a restarted agent
  # daemon pick up each pane's state where the last one left off.
  #
  # Each event is written with one `write(2)` to a file opened with
  # `O_APPEND`, so lines from several processes never interleave.
  class EventLog
    DEFAULT_COMPACT_THRESHOLD = 1_048_576 # 1MB

    # Activity event type for a pane's agent changing state.
    AGENT_STATE = "agent_state"

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
      line = JSON.generate(event) + "\n"
      File.open(@config.event_log_file, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |f|
        f.syswrite(line)
      end
    end

    # Appends an activity event. Never raises: a log that can't be written
    # warns once on the error stream and the caller carries on.
    #
    # @param type [String] event type (e.g., "dispatched", "lock_wait_started")
    # @param project [String] project the activity belongs to
    # @param data [Hash] event payload
    # @return [Boolean] whether the event was written
    def record(type:, project:, data: {})
      append(type: type, project: project, data: data)
      true
    rescue SystemCallError, IOError, JSON::GeneratorError, EncodingError => e
      @logger.debug { "event_log: could not record #{type} (#{e.class}: #{e.message})" }
      unless @warned_record
        @warned_record = true
        begin
          Warn.puts(@error_output, "Warning: could not write to the event log (#{e.message}); activity is not being recorded.")
        rescue IOError, SystemCallError
          nil
        end
      end
      false
    end

    # The latest {AGENT_STATE} event for each pane of a project, as a
    # restarted agent daemon needs them.
    #
    # @param project [String] project name
    # @return [Hash{String => Hash}] pane id => that pane's last agent_state data
    def latest_agent_states(project)
      events.each_with_object({}) do |event, latest|
        next unless event["type"] == AGENT_STATE && event["project"] == project
        data = event["data"]
        latest[data["pane_id"]] = data if data.is_a?(Hash) && data["pane_id"]
      end
    end

    # Reads all events from the log file.
    #
    # @return [Array<Hash>] list of event hashes
    def events
      return [] unless File.exist?(@config.event_log_file)
      File.readlines(@config.event_log_file).filter_map do |line|
        stripped = line.strip
        next if stripped.empty?
        event = JSON.parse(stripped)
        raise JSON::ParserError, "not an event object" unless event.is_a?(Hash)
        event
      rescue JSON::ParserError
        @logger.debug { "event_log: skipping corrupt line: #{stripped[0..100]}" }
        unless @warned_corrupt
          @error_output.puts "Warning: Corrupt event log line(s) skipped. Run with WORKSPACE_DEBUG=1 for details."
          @warned_corrupt = true
        end
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

    # Compacts the log by rewriting it with one event per active project,
    # plus the latest {AGENT_STATE} of each pane whose agent is still there.
    # All other activity history is dropped.
    #
    # @return [Hash] the compacted state
    def compact
      state = reconstruct
      pane_states = latest_pane_states
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
        pane_states.each { |event| f.puts JSON.generate(event) }
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

    # States that mean the pane has no agent any more, so nothing to carry
    # across a compaction.
    GONE_STATES = ["closed", "exited"].freeze
    private_constant :GONE_STATES

    def latest_pane_states
      latest = {}
      events.each do |event|
        next unless event["type"] == AGENT_STATE && event["data"].is_a?(Hash)
        latest[[event["project"], event["data"]["pane_id"]]] = event
      end
      latest.values.reject { |event| GONE_STATES.include?(event["data"]["state"]) }
    end

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
