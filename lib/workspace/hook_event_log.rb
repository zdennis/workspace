require "json"
require "time"
require "fileutils"

module Workspace
  # One agent daemon's high-rate log of hook events: `<dir>/<workspace>.jsonl`,
  # one typed JSON line per tool start and finish, permission request, the end
  # of each wait for a person's answer (`permission_resolved`, inferred from the
  # next event, since Claude Code sends nothing on deny or Esc), notification
  # (its type only, never its text), sub-agent start and stop, session start
  # and end, and prompt submitted, plus the `agent_status` lines agents post
  # (`agent status post`). `workspace events` reads it, together with the
  # lifecycle event log, which never sees these lines.
  #
  # Each daemon has its own file, so the daemon is its only writer (two overlap
  # for a moment across a restart, with different boot ids) and a busy
  # workspace never rotates another's lines away. Every line carries the
  # daemon's `boot_id` and a `seq` that starts at 1 for each boot, so a reader
  # can tell a missed line from a restarted daemon. A line that can't be
  # written still uses its `seq`, so the reader sees that it is missing.
  #
  # Only names, ids, a checkout-relative path, a pass or fail flag, a
  # duration, a sub-agent's short description (cut to 120 characters) and a
  # tool call's `input` summary ({ToolInputSummary}: one line, 4096 bytes) and,
  # for a review pane's write of a verdict file, the file's `sha256` (64 hex
  # characters, anything else dropped) are written: never a prompt, a whole command, tool output, or file contents.
  #
  # An append that leaves the file over the rotation threshold renames it to
  # `<file>.1`, replacing the one before; nothing is truncated, so a reader
  # holding the old file reads it to its end.
  class HookEventLog
    # The file size (bytes) past which an append rotates it.
    DEFAULT_ROTATE_THRESHOLD = 5 * 1_048_576

    # The line types this log writes.
    TYPES = %w[tool_started tool_finished permission_requested permission_resolved notification subagent_started subagent_stopped session_started session_ended prompt_submitted agent_status workflow_advance_started workflow_run_skipped workflow_sweep_started workflow_process_exited].freeze

    # The lines each forwarded session event becomes.
    LINES = {
      "tool_start" => %w[tool_started],
      "subagent_start" => %w[tool_started subagent_started],
      "tool_use" => %w[tool_finished],
      "permission_request" => %w[permission_requested],
      "notification" => %w[notification],
      "subagent_stop" => %w[subagent_stopped],
      "session_start" => %w[session_started],
      "session_end" => %w[session_ended],
      "user_prompt" => %w[prompt_submitted]
    }.freeze

    # Tool starts remembered for a finish's duration; the oldest go first.
    MAX_OPEN_TOOLS = 512

    # Permission requests waiting for an answer; the oldest go first.
    MAX_PENDING_PERMISSIONS = 512

    # The events that end every pending permission request of a pane.
    INTERRUPTING = %w[user_prompt session_start session_end].freeze

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
    # @param max_open_tools [Integer] tool starts remembered for a finish's duration
    # @param max_pending_permissions [Integer] permission requests remembered until they end
    # @param logger [Workspace::Logger] debug logger
    def initialize(dir:, workspace:, boot_id:, clock: Time, monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
      rotate_threshold: DEFAULT_ROTATE_THRESHOLD, max_open_tools: MAX_OPEN_TOOLS,
      max_pending_permissions: MAX_PENDING_PERMISSIONS, logger: Workspace::Logger.new)
      @dir = dir
      @workspace = workspace
      @boot_id = boot_id
      @clock = clock
      @monotonic = monotonic
      @rotate_threshold = rotate_threshold
      @max_open_tools = max_open_tools
      @max_pending_permissions = max_pending_permissions
      @logger = logger
      # A name that would leave the directory writes nothing.
      @path = (File.basename(workspace) == workspace && !workspace.start_with?(".")) ? self.class.path_for(dir, workspace) : nil
      @seq = 0
      @open_tools = {}
      @pending_permissions = {}
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
      pane_id = event["pane_id"]
      return [] unless pane_id.is_a?(String)
      event = event.merge("event" => "permission_request") if approval_notification?(event)
      types = LINES[event["event"]] || []
      # A sub-agent the agent names itself (Codex) started with no tool call.
      types -= ["tool_started"] if event["event"] == "subagent_start" && event["subagent_id"]

      @lock.synchronize do
        resolved = resolve_permissions(event).filter_map { |fields| write_line("permission_resolved", pane_id, fields) }
        written = types.flat_map do |type|
          line = write_line(type, pane_id, fields_for(type, event))
          [line, (write_policy_resolution(pane_id, event) if line && type == "permission_requested")]
        end
        resolved + written.compact
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
      when "permission_requested"
        note_permission(event) unless policy_decided?(event)
        permission_fields(event)
      when "subagent_started"
        {"agent_id" => text(event["subagent_id"], MAX_ID), "tool_use_id" => text(event["tool_use_id"], MAX_ID),
         "description" => text(event["description"], MAX_DESCRIPTION), "subagent_type" => text(event["subagent_type"], MAX_NAME)}
      when "subagent_stopped" then {"agent_id" => text(event["agent_id"], MAX_ID)}
      when "notification" then {"notification_type" => text(event["notification_type"], MAX_NAME), "agent_id" => text(event["agent_id"], MAX_ID)}
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
      input = ToolInputSummary.cap(event["input"])
      fields["input"] = input if input
      sha256 = event["sha256"]
      fields["sha256"] = sha256 if sha256.is_a?(String) && sha256.match?(/\A\h{64}\z/)
      fields
    end

    def note_start(event)
      id = event["tool_use_id"]
      return unless id.is_a?(String)
      @open_tools.delete(@open_tools.keys.first) while @open_tools.size >= @max_open_tools
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

    # Codex's approval prompt reaches the daemon as a notification, so the
    # session monitor opens its wait; `session-event` marks it with this type.
    def approval_notification?(event)
      event["event"] == "notification" && event["notification_type"] == "permission_request"
    end

    def permission_fields(event)
      fields = {"tool" => text(event["tool"], MAX_NAME), "agent_id" => text(event["agent_id"], MAX_ID)}
      input = ToolInputSummary.cap(event["input"])
      fields["input"] = input if input
      rule = text(event["rule"], MAX_ID)
      fields["rule"] = rule if rule
      fields
    end

    # A request the permission policy answered with allow or deny: no dialog
    # shows, so nothing is pending and nothing later can resolve it.
    def policy_decided?(event)
      %w[allow deny].include?(event["decision"])
    end

    def write_policy_resolution(pane_id, event)
      return nil unless policy_decided?(event)

      write_line("permission_resolved", pane_id, permission_fields(event).merge(
        "outcome" => (event["decision"] == "allow") ? "approved" : "denied", "by" => "policy", "wait_ms" => 0
      ))
    end

    def note_permission(event)
      @pending_permissions.delete(@pending_permissions.keys.first) while @pending_permissions.size >= @max_pending_permissions
      @pending_permissions[[event["pane_id"], text(event["agent_id"], MAX_ID)]] = {fields: permission_fields(event), started: @monotonic.call}
    end

    # The pending requests this event ends, as `permission_resolved` fields,
    # by the rule {PaneEvents} clears its own requests by. Claude Code sends
    # nothing for a deny or an Esc, so `denied` and `interrupted` are read from
    # the event that came next, which `by` names.
    def resolve_permissions(event)
      pane_id = event["pane_id"]
      agent_id = text(event["agent_id"], MAX_ID)
      ended = case event["event"]
      when *INTERRUPTING then @pending_permissions.keys.select { |key| key[0] == pane_id }.map { |key| [key, "interrupted"] }
      when "stop", "turn_failed" then agent_id ? [] : [[[pane_id, nil], "denied"]]
      when "subagent_stop" then agent_id ? [[[pane_id, agent_id], "denied"]] : []
      when "tool_use"
        pending = @pending_permissions[[pane_id, agent_id]]
        (pending && pending[:fields]["tool"] == text(event["tool"], MAX_NAME)) ? [[[pane_id, agent_id], "approved"]] : []
      when "permission_request" then [[[pane_id, agent_id], "superseded"]]
      else []
      end
      ended.filter_map do |key, outcome|
        pending = @pending_permissions.delete(key)
        next unless pending
        pending[:fields].merge("outcome" => outcome, "by" => event["event"], "wait_ms" => ((@monotonic.call - pending[:started]) * 1000).round)
      end
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
