module Workspace
  # Refuses a file write a review pane has no business making, from the
  # PreToolUse `session-event` hook beside {LockEnforcer} and {WorkflowDeny}.
  #
  # In a pane bound as a reviewer (`role: reviewer`), an Edit, Write,
  # MultiEdit, NotebookEdit or apply_patch is refused unless it comes from a
  # sub-agent (the hook payload has an `agent_id`) and names a file directly in the
  # round's own directory ({ReviewRoundPath}), other than the engine's `summary.md`. The pane's main thread only
  # orchestrates its sub-agents: it writes nothing, not even a verdict file.
  #
  # A tripwire, not a sandbox (Bash is not covered here; the run's `deny:`
  # list is). A pane with no binding costs one read of the bindings file, and a
  # stale reviewer binding is skipped. An unreadable binding allows the call;
  # once a live reviewer binding is found, an error in the check refuses it.
  class ReviewWriteGuard
    TOOLS = %w[Edit Write MultiEdit NotebookEdit apply_patch].freeze

    # @param pane_bindings [Workspace::PaneBindings] the pane-to-subject bindings
    # @param tmux [Workspace::Tmux] looks up the pane's session, slot and server, to skip a stale binding
    # @param env [Hash] environment lookup (TMUX_PANE)
    # @param event_log [Workspace::EventLog, nil] gets `review_write_denied`
    # @param logger [Workspace::Logger] debug logger
    def initialize(pane_bindings:, tmux:, env: ENV, event_log: nil, logger: Workspace::Logger.new)
      @pane_bindings = pane_bindings
      @tmux = tmux
      @env = env
      @event_log = event_log
      @logger = logger
    end

    # @param tool_name [String, nil] the payload's tool_name
    # @param tool_input [Object] the payload's tool_input
    # @param cwd [String, nil] the hook's working directory
    # @param agent_id [String, nil] the payload's sub-agent id; nil for the main thread
    # @return [String, nil] a deny message for stderr, or nil to allow the call
    def check(tool_name:, tool_input:, cwd:, agent_id:)
      return nil unless TOOLS.include?(tool_name)
      pane = @env["TMUX_PANE"].to_s
      entry = live_reviewer(pane)
      return nil unless entry

      reason = begin
        refusal(entry, tool_name, tool_input, cwd, agent_id)
      rescue => e
        @logger.debug { "session-event: review write check failed (#{e.class}: #{e.message})" }
        "check_failed"
      end
      return nil unless reason
      record(entry, tool_name, tool_input, reason)
      "denied: this is a review pane for run #{entry["id"]}, step #{entry["step"]}, round #{entry["round"]}: #{MESSAGES.fetch(reason)}"
    end

    MESSAGES = {
      "main_thread" => "the review pane's main thread (no sub-agent id) writes no files; a reviewer sub-agent writes the verdict. Report this and stop.",
      "outside_round" => "a reviewer writes only its round's verdict files. Report this and stop.",
      "check_failed" => "the write could not be checked, so it is refused. Report this and stop."
    }.freeze
    private_constant :MESSAGES

    private

    # The pane's reviewer binding, unless it is stale (another session, or another tmux server).
    # A read that fails counts as no binding, so an error here never stops a tool.
    def live_reviewer(pane)
      return nil if pane.empty?
      entry = @pane_bindings.binding_for(pane)
      return nil unless entry.is_a?(Hash) && entry["kind"] == "run" && entry["role"] == "reviewer"
      return nil if @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
      entry
    rescue => e
      @logger.debug { "session-event: review binding read failed (#{e.class}: #{e.message})" }
      nil
    end

    def refusal(entry, tool_name, tool_input, cwd, agent_id)
      return "main_thread" if agent_id.nil?
      return "outside_round" if tool_name == "apply_patch" || !ReviewRoundPath.reviewer?(entry)
      raw = tool_input.is_a?(Hash) ? (tool_input["file_path"] || tool_input["notebook_path"]) : nil
      ReviewRoundPath.verdict_path(entry, raw, cwd, direct: true) ? nil : "outside_round"
    end

    def record(entry, tool_name, tool_input, reason)
      raw = tool_input.is_a?(Hash) ? (tool_input["file_path"] || tool_input["notebook_path"]) : nil
      path = raw.is_a?(String) ? TerminalText.escape(raw[0, 300]) : nil
      @event_log&.record(type: "review_write_denied", project: entry["workspace"],
        data: {"run_id" => entry["id"], "workspace" => entry["workspace"], "step" => entry["step"], "round" => entry["round"],
               "tool" => tool_name, "path" => path, "reason" => reason})
    rescue => e
      @logger.debug { "session-event: review_write_denied not recorded (#{e.class}: #{e.message})" }
    end
  end
end
