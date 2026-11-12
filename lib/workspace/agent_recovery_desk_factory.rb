# frozen_string_literal: true

module Workspace
  # Builds the {Workspace::AgentRecoveryDesk} for one workspace on the agent
  # daemon's behalf: the +agent_recovery_desk_factory+ of {Commands::Agent}.
  # {.assemble} builds the desk's parts over one workspace's collaborators.
  class AgentRecoveryDeskFactory
    # Builds the desk over its parts: {RecoveryFacts}, {RecoveryOutcomes}, {RecoveryIntake},
    # {RecoveryConfirmer}, {RecoveryAttemptRunner} and {RecoveryAttempts}.
    #
    # @param panes [Workspace::PaneFactory] builds the pane to read, press a key in and type into; the pane list
    #   is read only to look a pane up ({RecoveryFacts#pane_detail})
    # @param workspace [String] the workspace the daemon serves; events and items go under it
    # @param session_name [String] the workspace's tmux session
    # @param session_monitor [Workspace::SessionMonitor] pane facts
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param transcript [Workspace::TranscriptSummary] reads the last turn record
    # @param stopper [Workspace::AgentStopper] finds the agent's process and sends the SIGINT
    # @param detector [Workspace::AgentDetector] the workspace's way to name the agent
    # @param process_tree [Workspace::ProcessTree] reads the fresh snapshots the process checks use
    # @param ledger [Workspace::SessionLedger] the session open in a pane, and its directory
    # @param resume_command [Workspace::AgentResumeCommand] builds the resume line
    # @param prompt_typer [Workspace::PromptTyper] the input line check, and the message's typing
    # @param readiness [Workspace::AgentReadiness] waits for a resumed agent
    # @param marker [Workspace::RecoveryStopMarker] says a stop is ours
    # @param inbox [#call] answers the workspace's {InboxStore}
    # @param delivery_lock [Mutex] held while typing, shared with the daemon's other deliveries
    # @param event_log [Workspace::EventLog, nil] where attempts and give-ups are recorded
    # @param restarting [#call] given a pane id, whether a restart holds the pane
    # @param claim_restart [#call] given a pane id, claims it; returns a token, or nil when it is held
    # @param release_restart [#call] given a pane id and a token, releases that claim
    # @param rebind_queue [#call] given a pane id and the monitor's agent pid, moves the pane's
    #   queued prompts to that agent
    # @param clock [#now] time source
    # @param sleeper [#call] sleeps the given seconds
    # @param spawn [#call] runs the given block on its own thread
    # @param steps [Workspace::AgentRecoverySteps] picks the runner of steps 2 to 5 for each kind of attempt
    # @param max_attempts [Integer] attempts after which the desk gives up
    # @param logger [Workspace::Logger] debug logger
    # @return [Workspace::AgentRecoveryDesk]
    def self.assemble(panes:, workspace:, session_name:, session_monitor:, store:, transcript:, stopper:, detector:,
      process_tree:, ledger:, resume_command:, prompt_typer:, readiness:, marker:, inbox:, delivery_lock:, event_log: nil,
      restarting: ->(_pane_id) { false }, claim_restart: ->(_pane_id) { Object.new },
      release_restart: ->(_pane_id, _token) {}, rebind_queue: ->(_pane_id, _agent_pid) {}, clock: Time,
      sleeper: ->(seconds) { sleep(seconds) }, spawn: ->(&block) { Thread.new(&block) }, steps: AgentRecoverySteps.new,
      max_attempts: AgentRecoveryStore::MAX_ATTEMPTS, logger: Workspace::Logger.new)
      facts = RecoveryFacts.new(panes: panes, process_tree: process_tree, stopper: stopper, detector: detector, ledger: ledger,
        transcript: transcript, session_monitor: session_monitor, prompt_typer: prompt_typer, clock: clock, sleeper: sleeper,
        logger: logger)
      attempt_runner = RecoveryAttemptRunner.new(panes: panes, session_name: session_name, store: store, facts: facts,
        session_monitor: session_monitor, readiness: readiness, detector: detector, marker: marker, prompt_typer: prompt_typer,
        delivery_lock: delivery_lock, restarting: restarting, rebind_queue: rebind_queue, clock: clock, sleeper: sleeper)
      outcomes = RecoveryOutcomes.new(workspace: workspace, store: store, facts: facts, inbox: inbox, runner: attempt_runner,
        event_log: event_log, max_attempts: max_attempts, clock: clock, logger: logger)
      intake = RecoveryIntake.new(store: store, session_monitor: session_monitor, facts: facts, rebind_queue: rebind_queue,
        report_give_up: outcomes.method(:report_give_up), resolve: outcomes.method(:resolve), max_attempts: max_attempts,
        clock: clock, spawn: spawn, logger: logger)
      confirmer = RecoveryConfirmer.new(workspace: workspace, store: store, facts: facts, session_monitor: session_monitor,
        marker: marker, clear: outcomes.method(:clear), report_give_up: outcomes.method(:report_give_up),
        resolve: outcomes.method(:resolve), event_log: event_log, max_attempts: max_attempts, clock: clock)
      attempts = RecoveryAttempts.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner,
        steps: steps, stopper: stopper, marker: marker,
        resume_command: ->(**line) { resume_command.call(workspace: workspace, **line) }, delivery_lock: delivery_lock,
        claim_restart: claim_restart, release_restart: release_restart, spawn: spawn, clock: clock, logger: logger)
      AgentRecoveryDesk.new(facts: facts, intake: intake, confirmer: confirmer, runner: attempts, outcomes: outcomes,
        store: store, restarting: restarting, clock: clock, logger: logger)
    end

    # What the daemon hands over for the desk's own parts.
    DAEMON_PARTS = %i[delivery_lock event_log restarting claim_restart release_restart rebind_queue].freeze

    # @param tmux [Workspace::Tmux]
    # @param config [Workspace::Config]
    # @param recovery_config [Workspace::AgentRecoveryConfig] says whether recovery is on for a workspace
    # @param agent_commands [Workspace::AgentCommands] names the workspace's agent kind and programs
    # @param process_tree [Workspace::ProcessTree]
    # @param ledger [Workspace::SessionLedger]
    # @param resume_command [Workspace::AgentResumeCommand]
    # @param readiness [Workspace::AgentReadiness]
    # @param marker [Workspace::RecoveryStopMarker]
    # @param logger [#debug]
    # @param error_output [IO]
    # @param transcript [#last_turn_record] reads transcripts, shared by every desk built (default {Workspace::TranscriptSummary})
    # @param stopper [Workspace::AgentStopper] default one over +process_tree+; shared by every desk built (it holds no per-pane state)
    # @param assembler [#call] given the workspace's collaborators, builds the desk (default {.assemble})
    def initialize(tmux:, config:, recovery_config:, agent_commands:, process_tree:, ledger:, resume_command:,
      readiness:, marker:, logger:, error_output:, transcript: TranscriptSummary.new, stopper: AgentStopper.new(process_tree: process_tree),
      assembler: AgentRecoveryDeskFactory.method(:assemble))
      @tmux = tmux
      @config = config
      @recovery_config = recovery_config
      @agent_commands = agent_commands
      @process_tree = process_tree
      @ledger = ledger
      @resume_command = resume_command
      @readiness = readiness
      @marker = marker
      @logger = logger
      @error_output = error_output
      @transcript = transcript
      @stopper = stopper
      @assembler = assembler
    end

    # @param given [Hash] +workspace:+, +session_name:+, +session_monitor:+ and the daemon's {DAEMON_PARTS}
    # @return [Workspace::AgentRecoveryDesk, nil] nil with recovery off or for a workspace whose agent is not Claude Code
    def call(**given)
      workspace = given.fetch(:workspace)
      return nil unless @recovery_config.enabled?(workspace) && @agent_commands.kind(workspace) == "claude"
      session_monitor = given.fetch(:session_monitor)
      panes = PaneFactory.new(tmux: @tmux, session_name: given.fetch(:session_name))
      @assembler.call(panes: panes, workspace: workspace, session_name: given.fetch(:session_name), session_monitor: session_monitor,
        store: AgentRecoveryStore.new(path: @config.agent_recovery_path(workspace)), transcript: @transcript,
        stopper: @stopper, detector: @agent_commands.detector(workspace),
        process_tree: @process_tree, ledger: @ledger, resume_command: @resume_command,
        prompt_typer: PromptTyper.new(panes: panes, session_monitor: session_monitor, logger: @logger),
        readiness: @readiness, marker: @marker,
        inbox: -> { InboxStore.new(path: @config.inbox_path("workspace", workspace), scope: "workspace:#{workspace}", error_output: @error_output) },
        logger: @logger, **given.slice(*DAEMON_PARTS))
    end
  end
end
