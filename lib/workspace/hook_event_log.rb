require "json"
require "time"
require "fileutils"

module Workspace
  # One agent daemon's high-rate log of hook events: `<dir>/<workspace>.jsonl`,
  # one typed JSON line per tool start and finish, sub-agent start and stop,
  # session start and end, and prompt submitted, plus the `agent_status` lines
  # agents post (`agent status post`). `workspace events` reads it,
  # together with the lifecycle event log, which never sees these lines.
  #
  # Each daemon has its own file, so the daemon is its only writer (two overlap
  # for a moment across a restart, with different boot ids) and a busy
  # workspace never rotates another's lines away. Every line carries the
  # daemon's `boot_id` and a `seq` that starts at 1 for each boot, so a reader
  # can tell a missed line from a restarted daemon. A line that can't be
  # written still uses its `seq`, so the reader sees that it is missing.
  #
  # Only names, ids, a checkout-relative path, a pass or fail flag, a
  # duration and a sub-agent's short description (cut to 120 characters) are
  # written: never a prompt, command, tool input or output.
  #
  # An append that leaves the file over the rotation threshold renames it to
  # `<file>.1`, replacing the one before; nothing is truncated, so a reader
  # holding the old file reads it to its end.
  class HookEventLog
    # The file size (bytes) past which an append rotates it.
    DEFAULT_ROTATE_THRESHOLD = 5 * 1_048_576

    # The line types this log writes.
    TYPES = %w[tool_started tool_finished subagent_started subagent_stopped session_started session_ended prompt_submitted agent_status].freeze

    # The lines each forwarded session event becomes.
    LINES = {
      "tool_start" => %w[tool_started],
      "subagent_start" => %w[tool_started subagent_started],
      "tool_use" => %w[tool_finished],
      "subagent_stop" => %w[subagent_stopped],
      "session_start" => %w[session_started],
      "session_end" => %w[session_ended],
      "user_prompt" => %w[prompt_submitted]
    }.freeze

    # Tool starts remembered for a finish's duration; the oldest go first.
    MAX_OPEN_TOOLS = 512

    # Longest value written for a name or id, a path, and a description.
    MAX_NAME = 64
    MAX_ID = 128
    MAX_PATH = 1024
    MAX_DESCRIPTION = 120

    # @param dir [String] the directory every daemon's file lives in
    # @param workspace [String] the workspace this daemon serves, as resolved
    # @return [String] the path of that workspace's file
    def self.path_for(dir, workspace)
      File.join(dir, "#{workspace}.jsonl")
    end

    # @param dir [String] directory holding every daemon's file
    # @param workspace [String] the workspace this daemon serves
    # @param boot_id [String] identifies this daemon's run
    # @param clock [#now] time source
    # @param monotonic [#call] seconds on a monotonic clock, for durations
    # @param rotate_threshold [Integer] size in bytes past which an append rotates
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, workspace:, boot_id:, clock: Time, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      rotate_threshold: DEFAULT_ROTATE_THRESHOLD, logger: Workspace::Logger.new)
      @dir = dir
      @workspace = workspace
      @boot_id = boot_id
      @clock = clock
      @monotonic = monotonic
      @rotate_threshold = rotate_threshold
      @logger = logger
      # A name that would leave the directory writes nothing.
      @path = (File.basename(workspace) == workspace && !workspace.start_with?(".")) ? self.class.path_for(dir, workspace) : nil
      @seq = 0
      @open_tools = {}
      @lock = Mutex.new
    end

    # @return [String, nil] the file this log appends to
    attr_reader :path

    # @return [String] this daemon's boot id
    attr_reader :boot_id

    # Writes the lines one forwarded session event stands for. Never raises.
    #
    # @param event [Hash] a "session_event" message, as `session-event` sends it
    # @return [Array<Hash>] the lines written
    def record(event)
      types = LINES[event["event"]]
      pane_id = event["pane_id"]
      return [] unless types && pane_id.is_a?(String)
      # A sub-agent the agent names itself (Codex) started with no tool call.
      types -= ["tool_started"] if event["event"] == "subagent_start" && event["subagent_id"]

      @lock.synchronize do
        types.filter_map { |type| write_line(type, pane_id, fields_for(type, event)) }
      end
    rescue => e
      @logger.debug { "hook_event_log: could not record (#{e.class}: #{e.message})" }
      []
    end

    # Writes one line of a type in {TYPES}. Never raises.
    #
    # @param type [String] the line's type
    # @param pane_id [String] the tmux pane the line is about
    # @param fields [Hash] the type's own fields
    # @return [Hash, nil] the line written, or nil when it wasn't
    def append(type, pane_id, fields)
      return nil unless TYPES.include?(type)
      @lock.synchronize { write_line(type, pane_id, fields) }
    end

    private

    # Each line is written or not on its own, so a failed write still uses its
    # seq and the next line goes out.
    def write_line(type, pane_id, fields)
      return nil unless @path
      write(type, pane_id, fields)
    rescue => e
      @logger.debug { "hook_event_log: could not write #{type} (#{e.class}: #{e.message})" }
      nil
    end

    def fields_for(type, event)
      case type
      when "tool_started"
        note_start(event)
        tool_fields(event)
      when "tool_finished"
        tool_fields(event).merge("ok" => event["ok"] != false, "duration_ms" => duration(event))
      when "subagent_started"
        {"agent_id" => text(event["subagent_id"], MAX_ID), "tool_use_id" => text(event["tool_use_id"], MAX_ID),
         "description" => text(event["description"], MAX_DESCRIPTION), "subagent_type" => text(event["subagent_type"], MAX_NAME)}
      when "subagent_stopped" then {"agent_id" => text(event["agent_id"], MAX_ID)}
      when "session_started" then {"kind" => text(event["kind"], MAX_NAME), "source" => text(event["source"], MAX_NAME)}
      when "session_ended" then {"kind" => text(event["kind"], MAX_NAME), "reason" => text(event["reason"], MAX_NAME)}
      else {}
      end
    end

    def tool_fields(event)
      fields = {"tool" => text(event["tool"], MAX_NAME), "tool_use_id" => text(event["tool_use_id"], MAX_ID),
                "agent_id" => text(event["agent_id"], MAX_ID)}
      path = text(event["path"], MAX_PATH)
      fields["path"] = path if path
      fields
    end

    def note_start(event)
      id = event["tool_use_id"]
      return unless id.is_a?(String)
      @open_tools.delete(@open_tools.keys.first) while @open_tools.size >= MAX_OPEN_TOOLS
      @open_tools[[event["pane_id"], id]] = @monotonic.call
    end

    # The payload's own duration when it has one, else the time since this
    # daemon saw the tool start; nil when it saw no start.
    def duration(event)
      started = event["tool_use_id"].is_a?(String) && @open_tools.delete([event["pane_id"], event["tool_use_id"]])
      given = event["duration_ms"]
      return given.round if given.is_a?(Numeric) && given >= 0
      ((@monotonic.call - started) * 1000).round if started
    end

    def text(value, limit)
      return nil unless value.is_a?(String)
      cleaned = value.scrub.gsub(/[[:cntrl:]]+/, " ").strip[0, limit]
      cleaned unless cleaned.empty?
    end

    def write(type, pane_id, fields)
      @seq += 1
      line = {"type" => type, "at" => @clock.now.utc.iso8601(3), "workspace" => @workspace, "pane_id" => pane_id,
              "boot_id" => @boot_id, "seq" => @seq}.merge(fields)
      @dir_made ||= FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| f.syswrite(JSON.generate(line) + "\n") }
      rotate_if_large
      line
    end

    # Only one process rotates: the lock is taken without waiting, and the
    # size is checked again once it is held.
    def rotate_if_large
      return unless File.size(@path) > @rotate_threshold
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        File.rename(@path, "#{@path}.1") if File.exist?(@path) && File.size(@path) > @rotate_threshold
      end
    rescue SystemCallError => e
      @logger.debug { "hook_event_log: could not rotate (#{e.class}: #{e.message})" }
    end
  end
end
