# frozen_string_literal: true

require "json"

module Workspace
  # The agent daemon's side of a +restart_agent+ message: checks it, claims the
  # named pane and starts the worker that clears the agent and types the prompt.
  #
  # Nothing here guesses the pane: a caller that could only say "the Claude
  # pane" could clear the wrong agent in a workspace running several.
  #
  # Everything that can be checked at once is checked before replying: the pane
  # exists and runs an agent, no pipeline stage is running on it (unless
  # "force"), a /clear on it could be confirmed from its status-line readings,
  # and no other restart is running on it. The waiting and typing then happen on
  # a worker thread, so the accept loop keeps serving hook events meanwhile.
  # With "wait", the worker sends the outcome on the caller's connection instead
  # of an immediate "started" reply.
  class AgentdRestartDesk
    # Longest confirm wait a restart_agent message may ask for, in seconds.
    MAX_TIMEOUT = 600

    # A pane named as "window.pane", optionally prefixed with its session.
    PANE_TARGET = /\A(?:(?<session>[^:]+):)?(?<window>\d+)\.(?<index>\d+)\z/
    private_constant :PANE_TARGET

    # Session monitor pane kinds restart_agent will type /clear into: the
    # providers marked restartable (Claude Code and Codex), and a pane not
    # identified yet.
    RESTARTABLE_KINDS = AgentProvider.restartable_kinds.freeze
    private_constant :RESTARTABLE_KINDS

    # The reply to a +restart_agent+ message that arrives before the daemon has
    # built its parts, so there is no context reader to confirm a /clear with.
    #
    # @param message [Hash] the parsed +restart_agent+ message
    # @return [Hash] the error reply
    def self.refusal_before_start(message)
      missing_prompt(message) || context_unavailable
    end

    # @return [Hash, nil] the +missing_prompt+ reply, or nil when the message has a prompt
    def self.missing_prompt(message)
      prompt = message["prompt"]
      return nil if prompt.is_a?(String) && !prompt.strip.empty?
      AgentProtocol.error("missing_prompt", "restart_agent needs a non-empty \"prompt\"")
    end

    # @return [Hash] the +context_unavailable+ reply
    def self.context_unavailable
      AgentProtocol.error("context_unavailable", "this agent can't read context usage, so a /clear couldn't be confirmed")
    end

    # @param workspace [String] the workspace the daemon serves; a +session:window.pane+ target may name it
    # @param session_name [String] the workspace's tmux session
    # @param pane_details [#call] answers the details of every pane of the session (+:id+, +:window+, +:index+)
    # @param monitor [Workspace::SessionMonitor, nil] says what each pane runs and what its hooks report
    # @param context_reader [Workspace::ContextReader, nil] reads a pane's context use; nil refuses every restart
    # @param registry [Workspace::RestartRegistry] holds the pane's claim and starts the worker thread
    # @param runner [Workspace::RestartRunner] runs one restart on the worker thread
    # @param pipeline_ref [#call] pane index (window 0) to the work item whose stage runs on it, or nil
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, session_name:, pane_details:, monitor:, context_reader:, registry:, runner:, pipeline_ref:,
      logger: Workspace::Logger.new)
      @workspace = workspace
      @session_name = session_name
      @pane_details = pane_details
      @monitor = monitor
      @context_reader = context_reader
      @registry = registry
      @runner = runner
      @pipeline_ref = pipeline_ref
      @logger = logger
    end

    # Answers one +restart_agent+ message: an error reply, or a "started" reply
    # (unless the caller waits) and a worker started on the claimed pane.
    #
    # @param message [Hash] the parsed message: +"pane"+, +"prompt"+, and optional +"timeout"+,
    #   +"force"+, +"wait"+ and +"run_id"+
    # @param client [#puts, #close, nil] the connection to answer on
    # @return [Symbol, nil] +:handed_off+ when the worker owns +client+
    def handle(message, client)
      started, error = start(message)
      return reply_to(client, error) if error

      pane_id = started["pane_id"]
      spawned = false
      begin
        timeout = started["confirm_timeout"]
        started = started.except("confirm_timeout")
        wait = message["wait"] == true
        reply_to(client, started) unless wait
        @registry.start_worker(pane_id) do
          @runner.run(started, message["prompt"], message["force"] == true,
            timeout, wait ? client : nil, run_id: message["run_id"])
        end
        spawned = true
      ensure
        # A pane left claimed with no worker would refuse every later
        # restart on it until the daemon restarts.
        @registry.abandon_pending(pane_id) unless spawned
      end
      wait ? :handed_off : nil
    end

    private

    # Validates a restart_agent message and claims its pane.
    #
    # @return [Array(Hash, Hash)] the "started" reply, or nil and the error reply
    def start(message)
      missing = self.class.missing_prompt(message)
      return [nil, missing] if missing
      return [nil, self.class.context_unavailable] unless @context_reader
      timeout = timeout_for(message["timeout"])
      unless timeout
        return [nil, error("bad_timeout", "\"timeout\" must be a number of seconds from 1 to #{MAX_TIMEOUT}")]
      end

      detail, refusal = resolve_pane(message["pane"])
      return [nil, refusal] if refusal
      pane_id = detail[:id]
      target = "#{detail[:window]}.#{detail[:index]}"

      kind = @monitor&.pane_kind(pane_id)
      if kind == "shell"
        # The agent may have started since the last scan; look once more.
        @monitor.rescan_pane(pane_id)
        kind = @monitor.pane_kind(pane_id)
      end
      if kind == "shell"
        return [nil, error("not_an_agent", "pane #{target} (#{pane_id}) is running a shell, not a coding agent", target)]
      end
      # /clear is the clear command of Claude Code and Codex; another agent
      # would take it as a prompt. A pane the monitor hasn't identified yet is let through.
      if kind && !RESTARTABLE_KINDS.include?(kind)
        label = AgentProvider.find(kind)&.label || kind
        return [nil, error("unsupported_agent",
          "pane #{target} (#{pane_id}) is running #{label}; restart_agent only restarts Claude Code and Codex, whose /clear it types", target)]
      end

      ref = (detail[:window] == 0) ? @pipeline_ref.call(detail[:index]) : nil
      if ref && message["force"] != true
        return [nil, error("pane_in_pipeline",
          "#{ref} has a pipeline stage running on pane #{target}; clearing it would leave the stage unfinished. " \
          "Pass --force to restart it anyway", target).merge("work_item_ref" => ref)]
      end

      # The usage needn't be known, only confirmable: a pane that has no
      # reading at all is let through once the monitor knows it's Claude,
      # whose first status-line render after /clear confirms it. A
      # freshly launched Claude pane may not have rendered its status
      # line yet, so NO_READING is expected there; an unknown-kind pane
      # with no reading is refused with FIX_HINT instead of guessed at.
      # A pane whose hooks reach this daemon is let through whatever the reading
      # says: its SessionStart with source clear confirms the clear
      # (AgentRestart.hooks?, also checked by AgentRestart#call). The rest mirrors
      # AgentRestart.confirmable? (lib/workspace/agent_restart.rb) — keep both in
      # sync if this changes.
      # Looked up as `sessions` and `handoff check` do: a reading recorded
      # without $TMUX_PANE is keyed by the agent's pid, not the pane id.
      reading = @context_reader.read(pane_id: pane_id, agent_pid: @monitor&.agent_pid(pane_id), kind: kind)
      confirmable = AgentRestart.hooks?(@monitor&.delivery_facts(pane_id)) ||
        (AgentRestart.confirmable?(reading) &&
          (reading[:error] != ContextReasons::NO_READING || kind == "claude"))
      unless confirmable
        return [nil, error("context_unknown",
          "can't read context usage for pane #{target} (#{reading[:error]}), so a /clear couldn't be confirmed; " \
          "nothing was typed", target).merge("reason" => reading[:error], "fix" => ContextReasons.fix_hint(kind))]
      end

      claimed = @registry.claim_pending(pane_id)
      return [nil, error("restart_in_progress", "a restart is already running on pane #{target}", target)] unless claimed

      started = AgentProtocol.ok(status: "started", pane: target, pane_id: pane_id,
        context_pct: reading[:pct], confirm_timeout: timeout)
      if ref
        started = started.merge("warning" => "#{ref} has a pipeline stage running on this pane; " \
          "it will only finish if the new conversation prints its sentinel")
      end
      [started, nil]
    end

    def error(code, message, pane = nil)
      pane ? AgentProtocol.error(code, message, pane: pane) : AgentProtocol.error(code, message)
    end

    # @return [Numeric, nil] the confirm timeout, the default when absent,
    #   or nil when the value is out of range
    def timeout_for(value)
      return AgentRestart::CONFIRM_TIMEOUT if value.nil?
      return nil unless value.is_a?(Numeric) && value >= 1 && value <= MAX_TIMEOUT
      value
    end

    # Resolves an explicit pane: a tmux pane id ("%12"), "window.pane"
    # ("0.1"), "session:window.pane", or a bare pane index in window 0.
    #
    # @return [Array(Hash, Hash)] the pane's details, or nil and an error reply
    def resolve_pane(spec)
      spec = spec.to_s.strip
      return [nil, error("missing_pane", "restart_agent needs a \"pane\": a pane id (%12), window.pane (0.1), or a pane index")] if spec.empty?

      details = @pane_details.call
      detail =
        if spec.match?(Workspace::TmuxPane::PANE_ID)
          details.find { |d| d[:id] == spec }
        elsif (match = PANE_TARGET.match(spec))
          session = match[:session]
          if session && ![@session_name, @workspace].any? { |own| WorkspaceName.same?(own, session) }
            return [nil, error("wrong_session", "pane #{spec} is not in this workspace's tmux session (#{@session_name})")]
          end
          details.find { |d| d[:window] == match[:window].to_i && d[:index] == match[:index].to_i }
        elsif spec.match?(/\A\d+\z/)
          details.find { |d| d[:window] == 0 && d[:index] == spec.to_i }
        else
          return [nil, error("bad_pane", "#{spec.inspect} is not a pane id (%12), window.pane (0.1), session:window.pane, or a pane index")]
        end
      return [nil, error("no_such_pane", "no pane #{spec} in tmux session #{@session_name}")] unless detail
      [detail, nil]
    end

    # Answers on the connection the message arrived on. A fire-and-forget
    # sender that has already hung up is not an error worth reporting.
    def reply_to(client, payload)
      client&.puts(payload.to_json)
      nil
    rescue SystemCallError, IOError => e
      @logger.debug { "no one was listening for the reply: #{e.message}" }
      nil
    end
  end
end
