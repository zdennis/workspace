module Workspace
  # Refuses a file write a reflection pane has no business making, from the
  # PreToolUse `session-event` hook beside {LockEnforcer}, {WorkflowDeny} and
  # {ReviewWriteGuard}.
  #
  # In a pane bound as `kind: reflection`, an Edit, Write, MultiEdit,
  # NotebookEdit or apply_patch is refused unless it names the one file
  # `<workflow evidence dir>/<run id>/reflection.md`, with no link on the way
  # down to it. Unlike the review guard it lets the main thread write: the
  # pane's agent writes the file itself. The allowed path comes from
  # {Config#workflow_evidence_dir} and the binding's `id` (checked against
  # {RunLiveness::ID_PATTERN}); the binding's `artifacts` is never trusted, since
  # `workspace binding set` can write any value.
  #
  # A tripwire, not a sandbox (Bash is not covered). A pane with no binding
  # costs one read of the bindings file, and a stale binding is skipped. An
  # unreadable binding allows the call; once a live reflection binding is found,
  # an error in the check refuses it.
  class ReflectionWriteGuard
    TOOLS = %w[Edit Write MultiEdit NotebookEdit apply_patch].freeze
    FILE_NAME = "reflection.md"

    # @param pane_bindings [Workspace::PaneBindings] the pane-to-subject bindings
    # @param tmux [Workspace::Tmux] looks up the pane's session, slot and server, to skip a stale binding
    # @param config [Workspace::Config] gives the workflow evidence directory
    # @param env [Hash] environment lookup (TMUX_PANE)
    # @param event_log [Workspace::EventLog, nil] gets `reflection_write_denied`
    # @param logger [Workspace::Logger] debug logger
    def initialize(pane_bindings:, tmux:, config:, env: ENV, event_log: nil, logger: Workspace::Logger.new)
      @pane_bindings = pane_bindings
      @tmux = tmux
      @config = config
      @env = env
      @event_log = event_log
      @logger = logger
    end

    # @param tool_name [String, nil] the payload's tool_name
    # @param tool_input [Object] the payload's tool_input
    # @param cwd [String, nil] the hook's working directory
    # @param agent_id [String, nil] the payload's sub-agent id; accepted so the call matches the chain, not used
    # @return [String, nil] a deny message for stderr, or nil to allow the call
    def check(tool_name:, tool_input:, cwd:, agent_id: nil)
      return nil unless TOOLS.include?(tool_name)
      pane = @env["TMUX_PANE"].to_s
      entry = reflection_binding(pane)
      return nil unless entry

      allowed = nil
      reason = begin
        return nil if stale?(entry, pane)
        allowed = allowed_path(entry)
        refusal(allowed, tool_name, tool_input, cwd)
      rescue => e
        @logger.debug { "session-event: reflection write check failed (#{e.class}: #{e.message})" }
        "check_failed"
      end
      return nil unless reason
      record(entry, tool_name, tool_input, reason)
      target = allowed ? "write only #{TerminalText.escape(allowed)}" : "no file can be written"
      "denied: this is a reflection pane for run #{TerminalText.escape(entry["id"].to_s[0, 100])}: #{MESSAGES.fetch(reason)} (#{target}). " \
        "To end this restriction run `workspace binding clear --pane #{pane}`, or close the pane."
    end

    MESSAGES = {
      "outside_file" => "a reflection pane writes only its run's reflection.md. Report this and stop.",
      "bad_id" => "the binding's run id is not a valid run id, so no write is allowed.",
      "check_failed" => "the write could not be checked, so it is refused."
    }.freeze
    private_constant :MESSAGES

    private

    # The pane's reflection binding. A read that fails counts as no binding, so an
    # unreadable store never stops a tool; a failure after this point does.
    def reflection_binding(pane)
      return nil if pane.empty?
      entry = @pane_bindings.binding_for(pane)
      (entry.is_a?(Hash) && entry["kind"] == "reflection") ? entry : nil
    rescue => e
      @logger.debug { "session-event: reflection binding read failed (#{e.class}: #{e.message})" }
      nil
    end

    # Whether the binding is stale (another session, or another tmux server).
    def stale?(entry, pane)
      @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
    end

    def allowed_path(entry)
      id = entry["id"]
      return nil unless id.is_a?(String) && RunLiveness::ID_PATTERN.match?(id)
      File.join(File.expand_path(@config.workflow_evidence_dir), id, FILE_NAME)
    end

    def refusal(allowed, tool_name, tool_input, cwd)
      return "bad_id" unless allowed
      raw = raw_path(tool_name, tool_input)
      return "outside_file" if tool_name == "apply_patch" || !cwd.is_a?(String) || cwd.empty? || !raw.is_a?(String) || raw.empty? || raw.match?(/[[:cntrl:]]/) || raw.end_with?("/")
      return "outside_file" unless File.expand_path(raw, cwd) == allowed
      return "outside_file" if ReviewRoundPath.linked_below?(File.dirname(File.dirname(File.dirname(allowed))), allowed, include_base: false)
      nil
    end

    # The path the tool names: `notebook_path` for NotebookEdit, `file_path` for the rest. Both
    # keys present and different gives :ambiguous, which is refused.
    def raw_path(tool_name, tool_input)
      return nil unless tool_input.is_a?(Hash)
      file, notebook = tool_input["file_path"], tool_input["notebook_path"]
      return :ambiguous if file && notebook && file != notebook
      (tool_name == "NotebookEdit") ? notebook : file
    end

    def record(entry, tool_name, tool_input, reason)
      raw = raw_path(tool_name, tool_input)
      path = raw.is_a?(String) ? TerminalText.escape(raw[0, 300]) : nil
      @event_log&.record(type: "reflection_write_denied", project: entry["workspace"],
        data: {"run_id" => entry["id"], "workspace" => entry["workspace"], "tool" => tool_name, "path" => path, "reason" => reason})
    rescue => e
      @logger.debug { "session-event: reflection_write_denied not recorded (#{e.class}: #{e.message})" }
    end
  end
end
