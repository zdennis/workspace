# frozen_string_literal: true

module Workspace
  # Builds the {Workspace::AgentRecoveryDesk} for one workspace on the agent
  # daemon's behalf: the +agent_recovery_desk_factory+ of {Commands::Agent}.
  class AgentRecoveryDeskFactory
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
    # @param desk_class [#new] builds the desk (default {Workspace::AgentRecoveryDesk})
    def initialize(tmux:, config:, recovery_config:, agent_commands:, process_tree:, ledger:, resume_command:,
      readiness:, marker:, logger:, error_output:, transcript: TranscriptSummary.new, stopper: AgentStopper.new(process_tree: process_tree),
      desk_class: AgentRecoveryDesk)
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
      @desk_class = desk_class
    end

    # @param given [Hash] +workspace:+, +session_name:+, +session_monitor:+ and the daemon's {DAEMON_PARTS}
    # @return [Workspace::AgentRecoveryDesk, nil] nil with recovery off or for a workspace whose agent is not Claude Code
    def call(**given)
      workspace = given.fetch(:workspace)
      return nil unless @recovery_config.enabled?(workspace) && @agent_commands.kind(workspace) == "claude"
      session_monitor = given.fetch(:session_monitor)
      @desk_class.new(tmux: @tmux, workspace: workspace, session_name: given.fetch(:session_name), session_monitor: session_monitor,
        store: AgentRecoveryStore.new(path: @config.agent_recovery_path(workspace)), transcript: @transcript,
        stopper: @stopper, detector: @agent_commands.detector(workspace),
        process_tree: @process_tree, ledger: @ledger, resume_command: @resume_command,
        prompt_typer: PromptTyper.new(tmux: @tmux, session_monitor: session_monitor, logger: @logger),
        readiness: @readiness, marker: @marker,
        inbox: -> { InboxStore.new(path: @config.inbox_path("workspace", workspace), scope: "workspace:#{workspace}", error_output: @error_output) },
        logger: @logger, **given.slice(*DAEMON_PARTS))
    end
  end
end
