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
  # `O_APPEND`, so lines from several processes never interleave. Appends
  # hold a shared `flock` on a sidecar lock file and {#compact} holds it
  # exclusively, so no append lands in the old file while compact is
  # rewriting it.
  #
  # An append that leaves the log over {DEFAULT_ROTATE_THRESHOLD} rotates it:
  # under the same exclusive lock the log is renamed to `<log>.1` (older
  # rotated files shift to `.2`, `.3`, and the one past {KEEP_ROTATED} is
  # deleted) and a new file, seeded with the compacted state, is renamed into
  # place. A reader that tails the log sees a new inode, as it does after
  # {#compact}, and starts over on the new file.
  class EventLog
    DEFAULT_COMPACT_THRESHOLD = 1_048_576 # 1MB

    # The log size (bytes) past which an append rotates it.
    DEFAULT_ROTATE_THRESHOLD = 10 * 1_048_576

    # How many rotated files (`<log>.1` .. `<log>.N`) are kept.
    KEEP_ROTATED = 3

    # Seconds a rotation waits for the log's lock before leaving the rotation
    # to the next append over the threshold.
    ROTATE_LOCK_WAIT = 1

    # Activity event type for a pane's agent changing state.
    AGENT_STATE = "agent_state"

    # Activity event type for an alert sent for a pane. Its data's `kind`
    # is "idle" or "waiting"; an event without one is an idle alert.
    AGENT_ALERT = "agent_alert"

    # Event types {#reconstruct} replays into state.
    STATE_EVENT_TYPES = ["state_set", "launched", "window_discovered", "repaired", "migrated", "compacted",
      "state_removed", "killed", "stopped", "pruned"].freeze

    # Seconds an append or a compact waits for the log's lock. An append
    # that can't get it in time writes anyway rather than lose the event.
    LOCK_WAIT = 5

    # A pane's agent_state that changed longer ago than this (seconds) is
    # dropped by {#compact}.
    AGENT_STATE_MAX_AGE = 7 * 24 * 60 * 60

    # @param config [Workspace::Config] configuration for file paths
    # @param project_settings [Workspace::ProjectSettings, nil] for reading global config
    # @param error_output [IO] error output stream for warnings (stderr)
    # @param logger [Workspace::Logger] debug logger
    # @param clock [#now] time source, injected for deterministic tests
    # @param rotate_threshold [Integer] log size in bytes past which an append rotates it
    # @param keep_rotated [Integer] how many rotated files to keep
    def initialize(config:, project_settings: nil, error_output: $stderr, logger: Workspace::Logger.new, clock: Time,
      rotate_threshold: DEFAULT_ROTATE_THRESHOLD, keep_rotated: KEEP_ROTATED)
      @rotate_threshold = rotate_threshold
      @keep_rotated = keep_rotated
      @config = config
      @project_settings = project_settings
      @error_output = error_output
      @logger = logger
      @clock = clock
    end

    # Appends an event to the log file.
    #
    # @param type [String] event type (e.g., "launched", "killed", "state_set")
    # @param project [String] project name
    # @param data [Hash] event payload (unique_id, iterm_window_id, etc.)
    # @return [void]
    def append(type:, project:, data: {})
      event = {
        "timestamp" => @clock.now.utc.iso8601(3),
        "type" => type,
        "project" => project,
        "data" => data
      }
      @logger.debug { "event_log: append #{type} for #{project}" }
      line = JSON.generate(event) + "\n"
      with_lock(File::LOCK_SH) do |locked|
        @logger.debug { "event_log: lock not taken, appending #{type} without it" } unless locked
        # A writer that died mid-line leaves no newline; starting a fresh
        # line keeps this event from being glued onto the torn one.
        line = "\n#{line}" if torn_tail?
        File.open(@config.event_log_file, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |f|
          f.syswrite(line)
        end
      end
      rotate_if_large
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
      latest_by_pane(AGENT_STATE, project)
    end

    # The latest idle {AGENT_ALERT} of each pane of a project, and its latest
    # waiting one per agent, so a restarted agent daemon doesn't alert again
    # for the same idle stretch or wait.
    #
    # @param project [String] project name
    # @return [Hash{String => Hash}] pane id => {"idle" => data,
    #   "waiting" => {agent id (nil for the main agent) => data}}
    def latest_agent_alerts(project)
      events.each_with_object({}) do |event, latest|
        next unless event["type"] == AGENT_ALERT && event["project"] == project
        data = event["data"]
        next unless data.is_a?(Hash) && data["pane_id"]
        pane = (latest[data["pane_id"]] ||= {})
        if data["kind"] == "waiting"
          (pane["waiting"] ||= {})[data["agent_id"]] = data
        else
          pane["idle"] = data
        end
      end
    end

    # Reads all events from the log file. A log that can't be read warns
    # once on the error stream and reads as empty.
    #
    # @return [Array<Hash>] list of event hashes
    def events
      read_events
    rescue SystemCallError, IOError => e
      warn_unreadable(e)
      []
    end

    # Whether the log holds any event {#reconstruct} replays. A log that
    # can't be read counts as holding some, so nothing is written over it.
    #
    # @return [Boolean]
    def state_events?
      read_events.any? { |event| STATE_EVENT_TYPES.include?(event["type"]) }
    rescue SystemCallError, IOError => e
      warn_unreadable(e)
      true
    end

    # Replays the event log to reconstruct the current state.
    #
    # @param strict [Boolean] raise on a log that can't be read, instead of
    #   warning and reading it as empty
    # @return [Hash] project_name => {data}
    # @raise [Workspace::Error] if +strict+ and the log can't be read
    def reconstruct(strict: false)
      return replay(events) unless strict
      begin
        replay(read_events)
      rescue SystemCallError, IOError => e
        raise Error, "could not read the event log #{@config.event_log_file} (#{e.message})"
      end
    end

    # Compacts the log by rewriting it with one event per active project,
    # plus the latest {AGENT_STATE} of each pane whose agent is still there,
    # in a project that is still active, and that changed within
    # {AGENT_STATE_MAX_AGE}; the latest idle {AGENT_ALERT} of each of those
    # panes; and, for each of those panes still waiting, the latest waiting
    # alert per agent sent during that wait. All other activity history is
    # dropped.
    #
    # @return [Hash] the compacted state
    # @raise [Workspace::Error] if the log is busy, or can't be read or rewritten
    def compact
      with_lock(File::LOCK_EX) do |locked|
        raise Error, "the event log is busy (another workspace process holds its lock); try again" unless locked
        rewrite
      end
    rescue SystemCallError, IOError => e
      raise Error, "could not compact the event log: #{e.message}"
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

    # Reads every event, raising if the file can't be read.
    def read_events
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

    def warn_unreadable(error)
      @logger.debug { "event_log: could not read (#{error.class}: #{error.message})" }
      return if @warned_unreadable
      @warned_unreadable = true
      Warn.puts(@error_output, "Warning: could not read the event log (#{error.message}); treating it as empty.")
    rescue IOError, SystemCallError
      nil
    end

    def latest_by_pane(type, project)
      events.each_with_object({}) do |event, latest|
        next unless event["type"] == type && event["project"] == project
        data = event["data"]
        latest[data["pane_id"]] = data if data.is_a?(Hash) && data["pane_id"]
      end
    end

    def replay(all)
      state = {}
      all.each do |event|
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

    # Runs with the lock held exclusively. Reads with {#read_events}, so a
    # log that can't be read is never rewritten as empty.
    def rewrite(rotate: false)
      all = read_events
      state = replay(all)
      pane_states = latest_pane_states(all, state)
      @logger.debug { "event_log: compacting #{size} bytes to #{state.size} project(s)" }
      tmp = "#{@config.event_log_file}.#{Process.pid}.tmp"
      remove(tmp)
      timestamp = @clock.now.utc.iso8601(3)
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
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
      shift_rotated if rotate
      File.rename(tmp, @config.event_log_file)
      state
    ensure
      remove(tmp) if tmp
    end

    # Rotates the log once it is over the threshold. Never raises: the append
    # that triggered it has already been written, and a log that can't rotate
    # just keeps growing until the next try. The size is checked again under
    # the exclusive lock, so of several processes that notice at once only the
    # first rotates, and one that can't get the lock leaves it to the others.
    def rotate_if_large
      return unless size > @rotate_threshold
      with_lock(File::LOCK_EX, wait: ROTATE_LOCK_WAIT) do |locked|
        next unless locked && size > @rotate_threshold
        @logger.debug { "event_log: rotating #{size} bytes" }
        rewrite(rotate: true)
      end
    rescue => e
      @logger.debug { "event_log: could not rotate (#{e.class}: #{e.message})" }
    end

    # Moves each rotated file up one number, dropping the oldest, then links
    # the log as `.1`. The log is linked, not renamed, so its path never stops
    # existing: a reader (which takes no lock) never sees a missing log, and the
    # rename that follows swaps in the new one in a single step. Nothing is
    # truncated: a writer or tail holding the old file keeps a coherent file.
    # The link is made first, so a filesystem that can't link fails before
    # any rotated file has moved or been dropped.
    def shift_rotated
      log = @config.event_log_file
      pending = "#{log}.#{Process.pid}.rotating"
      remove(pending)
      File.link(log, pending)
      remove("#{log}.#{@keep_rotated}")
      (@keep_rotated - 1).downto(1) do |n|
        File.rename("#{log}.#{n}", "#{log}.#{n + 1}") if File.exist?("#{log}.#{n}")
      end
      File.rename(pending, "#{log}.1")
    ensure
      remove(pending) if pending
    end

    def remove(path)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end

    # The agent_state events to keep, followed by the alert events of the
    # panes they belong to.
    def latest_pane_states(all, state)
      states = {}
      alerts = {}
      all.each do |event|
        data = event["data"]
        next unless data.is_a?(Hash)
        key = [event["project"], data["pane_id"]]
        case event["type"]
        when AGENT_STATE then states[key] = event
        when AGENT_ALERT
          alert_key = (data["kind"] == "waiting") ? ["waiting", data["agent_id"]] : ["idle"]
          alerts[key + alert_key] = event
        end
      end
      cutoff = @clock.now - AGENT_STATE_MAX_AGE
      states.reject! do |(project, _), event|
        GONE_STATES.include?(event["data"]["state"]) || !state.key?(project) ||
          older_than?(event["data"]["since"], cutoff)
      end
      states.values + alerts.select { |key, event| keep_alert?(states[key.first(2)], event) }.values
    end

    # An idle alert is kept for any kept pane; a waiting one only while the
    # pane is still in the wait it was sent for.
    def keep_alert?(pane_state, alert)
      return false unless pane_state
      return true unless alert["data"]["kind"] == "waiting"
      pane_state["data"]["state"] == "waiting" &&
        !older_than?(alert["data"]["waiting_since"], Time.iso8601(pane_state["data"]["since"].to_s) - 0.002)
    rescue ArgumentError
      true
    end

    # A time that can't be read is kept rather than guessed at.
    def older_than?(time, cutoff)
      Time.iso8601(time.to_s) < cutoff
    rescue ArgumentError
      false
    end

    # Yields whether the lock was taken: false if the lock file can't be
    # opened or the lock isn't free within {LOCK_WAIT}. Closing the file
    # releases the lock.
    def with_lock(mode, wait: LOCK_WAIT)
      lock = begin
        File.open("#{@config.event_log_file}.lock", File::RDWR | File::CREAT, 0o600)
      rescue SystemCallError => e
        @logger.debug { "event_log: can't open the lock file (#{e.class}: #{e.message})" }
        nil
      end
      yield(lock ? acquire(lock, mode, wait) : false)
    ensure
      lock&.close
    end

    def acquire(lock, mode, wait)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      until lock.flock(mode | File::LOCK_NB)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      true
    end

    # Whether the log's last byte is anything but a newline.
    def torn_tail?
      File.open(@config.event_log_file, "rb") do |f|
        length = f.size
        length > 0 && f.pread(1, length - 1) != "\n"
      end
    rescue SystemCallError, IOError
      false
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
