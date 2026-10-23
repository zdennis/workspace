module Workspace
  # The pane steps the commands that get an agent working on something share (`plan start` and
  # `spine start`): reading the panes from the agent daemon, picking the main agent pane, refusing a
  # pane that is busy, splitting a new pane and waiting for its agent, typing the text, and binding
  # the pane to the play it was sent. What is worked on, and what is written about it, stays with the
  # caller; this class names it only in messages (`noun`, such as "task" or "stage").
  class PaneDispatch
    # The agent kinds text may be sent to, and a spawn may start: every {AgentProvider}.
    AGENT_KINDS = AgentProvider.all.map(&:key).freeze

    # The agent kinds a main agent pane may run.
    MAIN_KINDS = %w[claude codex].freeze

    # The words for each waiting reason in a message.
    SCREEN_NAMES = {"sign_in" => "sign-in", "trust" => "folder trust", "approval" => "approval"}.freeze

    # Seconds the agent daemon may take to answer.
    DAEMON_TIMEOUT = 1.0

    # What {#spawn} did: the new pane's id and the {AgentReadiness::Result} of the wait.
    # +closed+ is true when the agent was never ready and the new pane was closed again. +waiting+ is
    # `sign_in`, `trust` or `approval` when the agent sits at that screen; the pane is then kept open
    # for the person to finish it.
    Spawned = Struct.new(:pane, :ready, :label, :closed, :waiting, keyword_init: true) do
      # @return [Boolean] whether the agent was ready for text in time
      def ready? = ready.ready?
    end

    # @param snapshot_client [Workspace::AgentSnapshotClient] reads the panes' states from the daemon
    # @param sender [Workspace::Commands::Send] finds and types into a pane
    # @param binder [Workspace::Commands::Binding] binds a pane to a play
    # @param library [Workspace::Library] words a play's binding
    # @param runner [Workspace::Commands::Run] splits a new pane and starts an agent in it
    # @param main_agent [Workspace::MainAgent] says which command starts a fresh agent of a kind for the workspace
    # @param readiness [Workspace::AgentReadiness] waits for that agent before text is typed
    # @param project_config [Workspace::ProjectConfig] says where a workspace's checkout is
    # @param tmux [Workspace::Tmux] names the workspace's session
    # @param prompt_timeout [Numeric] seconds a new agent may take to be ready
    # @param agent_commands [Workspace::AgentCommands, nil] says which program names count as an agent
    #   when a spawned one is waited for; nil knows only the providers' executables
    def initialize(snapshot_client:, sender:, binder:, library:, runner:, readiness:, main_agent:, tmux:, project_config:,
      prompt_timeout: AgentReadiness::DEFAULT_TIMEOUT, agent_commands: nil)
      @agent_commands = agent_commands
      @snapshot_client = snapshot_client
      @sender = sender
      @binder = binder
      @library = library
      @runner = runner
      @main_agent = main_agent
      @readiness = readiness
      @tmux = tmux
      @project_config = project_config
      @prompt_timeout = prompt_timeout
    end

    # @return [Numeric] seconds a new agent may take to be ready
    attr_reader :prompt_timeout

    # @param name [String] the workspace
    # @return [Boolean, nil] whether its tmux session runs; nil when that can't be told (a custom tmux
    #   socket, or tmux did not answer), which callers treat as running
    def session_live?(name)
      return nil if @tmux.custom_socket_option(name)
      @tmux.sessions(strict: true).include?(@tmux.session_name_for(name))
    rescue Workspace::Error, SystemCallError
      nil
    end

    # @param name [String] the workspace
    # @return [Array<Hash>] the daemon's pane rows (`pane_id`, `kind`, `state`, ...)
    # @raise [Workspace::Error] `no_daemon` when the agent daemon does not answer
    def panes(name)
      Array(@snapshot_client.fetch(name, timeout: DAEMON_TIMEOUT)["panes"])
    rescue AgentSnapshotClient::Unavailable => e
      raise Workspace::Error.new(e.message, code: "no_daemon", details: {"workspace" => name})
    end

    # @param name [String] the workspace
    # @param spec [String] a pane id or `window.pane` of the workspace's session
    # @param panes [Array<Hash>] from {#panes}
    # @return [Hash] the daemon's row for that pane, or `{"pane_id" => id}` when it lists none
    # @raise [Workspace::Error] the {Workspace::PaneLocator} codes
    def named(name, spec, panes)
      id = @sender.locate(name, spec)[:id]
      panes.find { |candidate| candidate["pane_id"] == id } || {"pane_id" => id}
    end

    # The Claude Code or Codex pane +preferred+ names, else the first one.
    #
    # @param name [String] the workspace
    # @param panes [Array<Hash>] from {#panes}
    # @param preferred [String, nil] a pane id to pick when it is one of them
    # @param what [String] what would be sent, for the message ("the plan")
    # @return [Hash] the pane's row
    # @raise [Workspace::Error] `no_agent_pane` when no pane runs Claude Code or Codex
    def main_pane(name, panes, preferred:, what:)
      agents = panes.select { |pane| MAIN_KINDS.include?(pane["kind"]) && pane["pane_id"] }
      agents.find { |pane| pane["pane_id"] == preferred } || agents.first ||
        raise(Workspace::Error.new("No pane of '#{name}' runs Claude Code or Codex, so there is nowhere to send #{what}.",
          code: "no_agent_pane", details: {"workspace" => name}))
    end

    # @param name [String] the workspace
    # @param pane [Hash] the pane's row
    # @param noun [String] what was to be typed ("task", "stage")
    # @return [void]
    # @raise [Workspace::Error] `no_agent_pane` when the pane runs no coding agent the daemon knows
    def require_agent(name, pane, noun)
      return if AGENT_KINDS.include?(pane["kind"])
      raise Workspace::Error.new("Pane #{pane["pane_id"]} of '#{name}' runs no coding agent the agent daemon knows, so the #{noun} was not typed into it.",
        code: "no_agent_pane", details: {"workspace" => name, "pane" => pane["pane_id"]})
    end

    # @param name [String] the workspace
    # @param pane [Hash] the pane's row
    # @param noun [String] what was to be typed ("task", "stage")
    # @return [void]
    # @raise [Workspace::Error] `pane_busy` when the pane waits on a person or works (`details.state`)
    def refuse_busy(name, pane, noun)
      id = pane["pane_id"]
      if pane["state"] == "waiting"
        raise Workspace::Error.new("Pane #{id} of '#{name}' is waiting for an answer, so nothing was typed. Answer it, then start the #{noun} again.",
          code: "pane_busy", details: {"workspace" => name, "pane" => id, "state" => "waiting"})
      end
      return unless pane["state"] == "working"
      raise Workspace::Error.new("Pane #{id} of '#{name}' is working on something else, so nothing was typed. Send the #{noun} to another pane, " \
        "or use --spawn.", code: "pane_busy", details: {"workspace" => name, "pane" => id, "state" => "working"})
    end

    # Splits a new pane, starts an agent of +kind+ in it, and waits until it is ready for text.
    #
    # @param name [String] the workspace
    # @param kind [String] one of {AGENT_KINDS}
    # @return [Spawned]
    # @raise [ArgumentError] for a kind that is not one of {AGENT_KINDS}, before any pane is made
    # @raise [Workspace::Error] what {Workspace::Commands::Run#call} raises
    def spawn(name, kind)
      provider = AgentProvider.find(kind) || raise(ArgumentError, "unknown agent kind #{kind.inspect}")
      id = @runner.call(name, @main_agent.spawn_command(name, kind), split: true,
        cwd: @project_config.project_root_for(name))
      begin
        ready = @readiness.wait(@tmux.session_name_for(name), deadline: @readiness.deadline_in(@prompt_timeout), only_pane: id, **(@agent_commands&.detector_options(name) || {}))
      rescue Workspace::Error => e
        closed = close_unused(name, id)
        raise Workspace::Error.new(e.message, code: e.code, details: e.details.merge("pane_id" => id, "pane_closed" => closed), retry_with: e.retry)
      end
      return Spawned.new(pane: id, ready: ready, label: provider.label, closed: false) if ready.ready?
      waiting = provider.waiting_screen(@tmux.capture_screen(id))&.fetch(:reason)
      closed = waiting ? false : close_unused(name, id)
      Spawned.new(pane: id, ready: ready, label: provider.label, closed: closed, waiting: waiting)
    end

    # The human message for a spawn whose agent was not ready.
    #
    # @param spawned [Spawned]
    # @param noun [String] what was to be typed ("task", "stage")
    # @param written [String] what was not done, after "nothing was"
    # @return [String]
    def not_ready_message(spawned, noun, written: "typed")
      lead = "Started #{spawned.label} in new pane #{spawned.pane}, but it was not ready for the #{noun} in #{prompt_timeout}s (#{spawned.ready.reason}); nothing was #{written}"
      if spawned.waiting
        "#{lead}. The pane was left open: finish the #{SCREEN_NAMES.fetch(spawned.waiting, spawned.waiting)} screen in it, then start the #{noun} again."
      else
        "#{lead}#{", and the pane was closed" if spawned.closed}."
      end
    end

    # @param spawned [Spawned]
    # @return [Hash] the failure's `details`: `pane_id`, `pane_closed` and, for a kept pane, `waiting`
    def not_ready_details(spawned)
      details = {"pane_id" => spawned.pane, "pane_closed" => spawned.closed}
      spawned.waiting ? details.merge("waiting" => spawned.waiting) : details
    end

    # Closes a pane {#spawn} made, when its agent never became ready and nothing was typed into it.
    # A workspace on a custom tmux socket keeps its pane: pane ids repeat across servers and the close
    # would go to the default one.
    # @param name [String] the workspace
    # @param id [String] the new pane
    # @return [Boolean] whether it was closed
    def close_unused(name, id)
      return false if @tmux.custom_socket_option(name)
      @tmux.close_pane(id)
    end

    # @param name [String] the workspace
    # @param pane [String] a pane id
    # @param body [String, nil] text to type and submit
    # @param keys [Array<String>, nil] tmux key names to press instead
    # @return [Hash] what {Workspace::Commands::Send#deliver} returns
    # @raise [Workspace::Error] the codes of {Workspace::Commands::Send#deliver}
    def deliver(name, pane, body: nil, keys: nil)
      keys ? @sender.deliver(name: name, pane: pane, keys: keys) : @sender.deliver(name: name, pane: pane, body: body)
    end

    # Binds the pane to the play it was sent. A pane bound to a run or review keeps that binding; a
    # play binding keeps its packs, and +packs+ are added. A +focus+ (what was sent) is repeated by the
    # SessionStart hook after a `/clear`.
    #
    # @param name [String] the workspace
    # @param pane [String] a pane id
    # @param play [Hash, nil] from {Workspace::Library#play} or {Workspace::Library#pack}; nil binds the first of +packs+ as the play
    # @param focus [String, nil]
    # @param packs [Array<String>] pack names sent with it
    # @return [String, nil] a note when the pane could not be bound
    def bind_play(name, pane, play, focus: nil, packs: [])
      existing = @binder.live(pane: pane)
      return if existing && existing["kind"] != "play"
      all = (Array(existing && existing["packs"]) + packs).uniq
      fields = if play
        @library.play_binding(play, packs: all)
      else
        @library.packs_binding(all).except("keep_existing")
      end
      fields = fields.merge("focus" => focus) if focus
      @binder.bind(workspace: name, pane: pane, **fields)
      nil
    rescue Workspace::Error, SystemCallError => e
      "Sent, but could not bind pane #{pane} to the play (#{e.message})."
    end
  end
end
