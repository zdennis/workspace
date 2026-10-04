require "optparse"
require "json"
require "fileutils"
require "time"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
module Workspace
  # Raised for runtime errors in workspace operations.
  #
  # Besides the message, an error carries the machine-readable parts of the
  # `--json` error envelope (see {JsonEnvelope}): a stable {#code} from
  # {ErrorCodes}, {#details} and an optional {#retry}.
  class Error < StandardError
    # @return [Hash, nil] the flags that turn this refusal into a forced run, as
    #   `{"flags" => [...], "destructive" => bool}`
    attr_reader :retry

    # @param message [String, nil]
    # @param code [String, nil] a key of {ErrorCodes::REGISTRY}; nil uses the class's code
    # @param details [Hash, nil] machine data for the envelope's `details`
    # @param retry_with [Hash, nil] the envelope's `retry`
    def initialize(message = nil, code: nil, details: nil, retry_with: nil)
      super(message)
      @code = code
      @details = details
      @retry = retry_with
    end

    # @return [String] the stable error code; `"error"` unless a subclass or the raiser names one
    def code
      @code || "error"
    end

    # @return [Hash] machine data about the failure; `{}` when there is none
    def details
      @details || {}
    end
  end

  # Raised for invalid usage or missing required arguments.
  class UsageError < Error
    # @return [String] `"usage"`
    def code
      @code || "usage"
    end
  end

  # Raised when a config file exists but can't be parsed as a YAML mapping.
  class ConfigParseError < Error
    # @return [String] path of the file that failed to parse
    attr_reader :path

    # @return [String] why the file couldn't be used
    attr_reader :reason

    # @param path [String] the config file
    # @param reason [String] why it couldn't be used
    def initialize(path, reason)
      @path = path
      @reason = reason
      super("Cannot parse #{path}: #{reason}.")
    end

    # @return [String] `"config_parse"`
    def code
      @code || "config_parse"
    end

    # @return [Hash] the file's `path` and the parse `reason`
    def details
      {"path" => path, "reason" => reason}
    end
  end

  # Raised when a worktree can't be removed because it has unsaved work
  # (or git couldn't tell whether it does).
  class UnsavedWorkError < Error
    # @return [Hash, Symbol] the Git#unsaved_work result: a Hash, or :unknown
    attr_reader :unsaved

    # @param message [String, nil] error message
    # @param unsaved [Hash, Symbol] the Git#unsaved_work result
    def initialize(message = nil, unsaved: :unknown)
      super(message)
      @unsaved = unsaved
    end

    # @param unsaved [Hash, Symbol] a Git#unsaved_work result
    # @return [String] a one-phrase description of the unsaved work
    def self.describe(unsaved)
      return "git couldn't check it for unsaved work" if unsaved == :unknown
      "#{unsaved[:changed_files]} changed file(s) and #{unsaved[:unpushed_commits]} " \
        "unpushed commit(s) on #{unsaved[:branch] || "HEAD"}"
    end

    # @return [String] a one-phrase description of the unsaved work
    def summary
      self.class.describe(unsaved)
    end

    # @return [String] `"unsaved_unknown"` when git couldn't check, else `"unsaved_work"`
    def code
      @code || ((unsaved == :unknown) ? "unsaved_unknown" : "unsaved_work")
    end

    # @return [Hash] the counts behind the refusal; `{}` when git couldn't check
    def details
      return {} if unsaved == :unknown
      unsaved.to_h { |key, value| [key.to_s, value] }
    end

    # @return [Hash] `--force` discards the unsaved work
    def retry
      @retry || {"flags" => ["--force"], "destructive" => true}
    end
  end
end

require_relative "workspace/version"
require_relative "workspace/error_codes"
require_relative "workspace/output_gate"
require_relative "workspace/json_envelope"
require_relative "workspace/prompt_input"
require_relative "workspace/warn"
require_relative "workspace/logger"
require_relative "workspace/config"
require_relative "workspace/config_schema"
require_relative "workspace/config_schema_docs"
require_relative "workspace/event_log"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/which"
require_relative "workspace/launch_mode"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/tmux_pane"
require_relative "workspace/pane_locator"
require_relative "workspace/pane_bindings"
require_relative "workspace/library_store"
require_relative "workspace/library"
require_relative "workspace/library_installer"
require_relative "workspace/commands_config"
require_relative "workspace/instruction_composer"
require_relative "workspace/project_config"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_layout"
require_relative "workspace/project_settings"
require_relative "workspace/config_file"
require_relative "workspace/config_report"
require_relative "workspace/tmuxinator_report"
require_relative "workspace/process_tree"
require_relative "workspace/liveness"
require_relative "workspace/agent_readiness"
require_relative "workspace/agent_restart"
require_relative "workspace/workspace_lineage"
require_relative "workspace/project_catalog"
require_relative "workspace/agent_snapshot_client"
require_relative "workspace/project_agents"
require_relative "workspace/project_facts"
require_relative "workspace/duration"
require_relative "workspace/dev_config"
require_relative "workspace/lock_namespace"
require_relative "workspace/bound_run"
require_relative "workspace/run_liveness"
require_relative "workspace/lock_holder"
require_relative "workspace/lock_audit_log"
require_relative "workspace/lock_store"
require_relative "workspace/lock_config"
require_relative "workspace/lock_idle_tracker"
require_relative "workspace/lock_reaper"
require_relative "workspace/lock_enforcer"
require_relative "workspace/notifier"
require_relative "workspace/alert_config"
require_relative "workspace/handoff_config"
require_relative "workspace/context_reasons"
require_relative "workspace/context_store"
require_relative "workspace/context_reader"
require_relative "workspace/statusline_renderer"
require_relative "workspace/ask_store"
require_relative "workspace/task_store"
require_relative "workspace/pull_request_status"
require_relative "workspace/transcript_summary"
require_relative "workspace/session_ledger"
require_relative "workspace/transcript_label"
require_relative "workspace/session_monitor"
require_relative "workspace/agent_provider"
require_relative "workspace/file_backup"
require_relative "workspace/process_group_terminator"
require_relative "workspace/process_holder_stopper"
require_relative "workspace/dev_runner"
require_relative "workspace/run_resources"
require_relative "workspace/hook_installer"
require_relative "workspace/hook_runner"
require_relative "workspace/project_detector"
require_relative "workspace/commands/sessions"
require_relative "workspace/commands/session_event"
require_relative "workspace/commands/init"
require_relative "workspace/commands/claude"
require_relative "workspace/commands/launch"
require_relative "workspace/commands/kill"
require_relative "workspace/commands/finish"
require_relative "workspace/commands/focus"
require_relative "workspace/commands/start"
require_relative "workspace/commands/stop"
require_relative "workspace/commands/tile"
require_relative "workspace/commands/resize"
require_relative "workspace/commands/layout"
require_relative "workspace/commands/repair"
require_relative "workspace/commands/cleanup"
require_relative "workspace/commands/prune"
require_relative "workspace/commands/lookup"
require_relative "workspace/commands/update_pane_command"
require_relative "workspace/commands/run"
require_relative "workspace/commands/send"
require_relative "workspace/commands/capture"
require_relative "workspace/commands/lock"
require_relative "workspace/commands/dev"
require_relative "workspace/commands/capabilities"
require_relative "workspace/commands/parent"
require_relative "workspace/commands/projects"
require_relative "workspace/commands/review"
require_relative "workspace/commands/restore"
require_relative "workspace/commands/snapshot"
require_relative "workspace/commands/project_actions"
require_relative "workspace/commands/config"
require_relative "workspace/commands/statusline"
require_relative "workspace/commands/restart_agent"
require_relative "workspace/commands/ensure_agent"
require_relative "workspace/commands/daemon"
require_relative "workspace/commands/ui"
require_relative "workspace/commands/binding"
require_relative "workspace/commands/library"
require_relative "workspace/commands/instructions"
require_relative "workspace/commands/handoff"
require_relative "workspace/commands/ask"
require_relative "workspace/commands/wait_until_content"
require_relative "workspace/work_coordinator_client"
require_relative "workspace/pipeline_config"
require_relative "workspace/pipeline_state"
require_relative "workspace/sentinel_poller"
require_relative "workspace/commands/agent"
require_relative "workspace/run_result"
require_relative "workspace/run_result_cleaner"
require_relative "workspace/run_result_store"
require_relative "workspace/commands/run_and_report"
require_relative "workspace/cli"

module Workspace
  # Assembles the full dependency graph and returns a ready-to-run CLI instance.
  #
  # @param output [IO] output stream for user-facing messages
  # @param error_output [IO] error output stream for warnings and errors
  # @param input [IO] input stream for interactive prompts
  # @param env [Hash] environment; `WORKSPACE_NO_INPUT` makes every prompt fail instead of waiting
  # @param logger [Workspace::Logger, nil] debug logger (created automatically if nil)
  # @return [Workspace::CLI] a fully-wired CLI instance
  def self.build_cli(output: $stdout, error_output: $stderr, input: $stdin, env: ENV, logger: nil)
    input = PromptInput.new(input, no_input: PromptInput.env_truthy?(env))
    # Every collaborator writes through the gate, so a `--json` action can send their text to stderr.
    output = OutputGate.new(output)
    logger ||= Logger.new(output: error_output, enabled: ENV.key?("WORKSPACE_DEBUG"))
    config = Config.new
    project_settings = ProjectSettings.new(config: config)
    event_log = EventLog.new(config: config, project_settings: project_settings, error_output: error_output, logger: logger)
    state = State.new(config: config, event_log: event_log, logger: logger)
    iterm = ITerm.new(config: config, output: output, logger: logger)
    window_manager = WindowManager.new(config: config, logger: logger)
    tmux = Tmux.new(config: config, logger: logger)
    git = Git.new(output: output, input: input, logger: logger)
    project_config = ProjectConfig.new(config: config, git: git, output: output)
    window_layout = WindowLayout.new(window_manager: window_manager, config: config, output: output, logger: logger)
    hook_runner = HookRunner.new(project_settings: project_settings, project_config: project_config, output: output, error_output: error_output, logger: logger)
    project_detector = ProjectDetector.new(state: state, project_config: project_config)
    file_backup = FileBackup.new(output: output)
    hook_installer = HookInstaller.new(backup: file_backup, output: output, input: input)
    pipeline_config = PipelineConfig.new(config: config)
    launch_mode = LaunchMode.new(project_settings: project_settings)
    doctor = Doctor.new(config: config, state: state, hook_installer: hook_installer, project_detector: project_detector, git: git, pipeline_config: pipeline_config, launch_mode: launch_mode, project_settings: project_settings, output: output)

    # Pre-build command objects so CLI delegates rather than constructs
    stop_command = Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    agent_readiness = AgentReadiness.new(tmux: tmux, process_tree: ProcessTree.new(logger: logger), logger: logger)
    ensure_agent_command = Commands::EnsureAgent.new(config: config, pipeline_config: pipeline_config, error_output: error_output)
    pane_locator = PaneLocator.new(tmux: tmux)
    pane_bindings = PaneBindings.new(path: config.pane_bindings_path, logger: logger, error_output: error_output)
    binding_command = Commands::Binding.new(bindings: pane_bindings, locator: pane_locator, tmux: tmux, output: output)
    launch_command = Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, pipeline_config: pipeline_config, agent_ensurer: ensure_agent_command, agent_readiness: agent_readiness, binder: binding_command, output: output, error_output: error_output)
    lineage = WorkspaceLineage.new
    task_store = TaskStore.new(dir: config.task_dir, error_output: error_output)
    library = Library.new(config: config, lineage: lineage, project_config: project_config)
    library_installer = LibraryInstaller.new(git: git)
    start_command = Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, lineage: lineage, hook_installer: hook_installer, task_store: task_store, event_log: event_log, library: library, library_installer: library_installer, output: output, input: input)
    kill_command = Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, task_store: task_store, event_log: event_log, output: output, input: input)
    finish_command = Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, error_output: error_output, input: input)
    send_command = Commands::Send.new(locator: pane_locator, tmux: tmux, output: output)
    focus_command = Commands::Focus.new(state: state, window_manager: window_manager, tmux: tmux, pane_locator: pane_locator, output: output)
    tile_command = Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    init_command = Commands::Init.new(config: config, hook_installer: hook_installer, output: output, error_output: error_output, input: input)
    repair_command = Commands::Repair.new(state: state, iterm: iterm, window_manager: window_manager, output: output)
    cleanup_command = Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
    prune_command = Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command, output: output, input: input)
    claude_command = Commands::Claude.new(state: state, tmux: tmux, output: output, error_output: error_output)
    lookup_command = Commands::Lookup.new(project_config: project_config, output: output)
    update_pane_command = Commands::UpdatePaneCommand.new(config: config, project_config: project_config, output: output, input: input)
    run_command = Commands::Run.new(
      tmux: tmux,
      state: state,
      window_manager: window_manager,
      output: output,
      error_output: error_output
    )

    run_result_cleaner = RunResultCleaner.new(
      dir: config.run_results_dir,
      live_projects: -> {
        state.load
        Liveness.new(tmux: tmux).call(state.keys).reject { |_, alive| alive == false }.keys
      },
      logger: logger
    )
    run_result_store = RunResultStore.new(config: config, cleaner: run_result_cleaner)
    run_and_report_command = Commands::RunAndReport.new(run_result_store: run_result_store)
    capture_command = Commands::Capture.new(tmux: tmux, output: output, error_output: error_output)
    wait_until_content_command = Commands::WaitUntilContent.new(tmux: tmux, output: output, error_output: error_output)

    lock_namespace = LockNamespace.new(config: config, lineage: lineage)
    dev_config = DevConfig.new(project_settings: project_settings)
    lock_config = LockConfig.new(project_settings: project_settings, error_output: error_output)
    # Resolved once, from cwd's project, since a CLI run and the long-lived
    # `agent` daemon it may spawn both belong to a single project.
    cwd_project_name = begin
      lineage.resolve(cwd: Dir.pwd).name
    rescue Workspace::Error
      nil
    end
    ps_timeout = cwd_project_name ? lock_config.ps_timeout_for(cwd_project_name) : ProcessTree::DEFAULT_TIMEOUT
    reap_interval = cwd_project_name ? lock_config.reap_interval_for(cwd_project_name) : LockReaper::DEFAULT_INTERVAL
    process_tree = ProcessTree.new(logger: logger, timeout: ps_timeout)
    run_liveness = RunLiveness.new(dir: config.workflow_runs_dir)
    lock_holder = LockHolder.new(process_tree: process_tree, run_liveness: run_liveness)
    agent_snapshot_client = AgentSnapshotClient.new(config: config)
    sessions_command = Commands::Sessions.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      project_config: project_config, snapshot_client: agent_snapshot_client, output: output, error_output: error_output)
    lock_idle_tracker = LockIdleTracker.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger)
    lock_enforcer = LockEnforcer.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger)
    session_ledger = SessionLedger.new(path: File.join(config.state_dir, "ledger.jsonl"), logger: logger)
    session_event_command = Commands::SessionEvent.new(config: config, tmux: tmux, input: input, output: output, error_output: error_output, logger: logger,
      lock_idle_tracker: lock_idle_tracker, lock_enforcer: lock_enforcer, session_ledger: session_ledger, pane_bindings: pane_bindings)
    process_group_terminator = ProcessGroupTerminator.new
    bound_run = BoundRun.new(pane_bindings: pane_bindings, tmux: tmux)
    lock_command = Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      terminator: process_group_terminator, dev_config: dev_config, lock_config: lock_config, event_log: event_log,
      bound_run: bound_run, output: output, error_output: error_output)
    dev_runner = DevRunner.new(liveness: lock_holder, output: output)
    dev_command = Commands::Dev.new(
      lock_namespace: lock_namespace,
      lock_holder: lock_holder,
      lineage: lineage,
      dev_config: dev_config,
      dev_runner: dev_runner,
      terminator: process_group_terminator,
      tmux: tmux,
      executable: File.expand_path("../bin/workspace", __dir__),
      event_log: event_log,
      bound_run: bound_run,
      output: output,
      error_output: error_output
    )
    capabilities_command = Commands::Capabilities.new(config: config, output: output)
    daemon_command = Commands::Daemon.new(config: config, project_config: project_config, ensure_agent: ensure_agent_command, process_tree: ProcessTree.new(logger: logger), output: output)
    ui_command = Commands::Ui.new(output: output)
    library_command = Commands::Library.new(library: library, output: output, input: input)
    commands_config = CommandsConfig.new(project_settings: project_settings)
    instruction_composer = InstructionComposer.new(library: library, lineage: lineage,
      commands_config: commands_config, pane_bindings: pane_bindings)
    instructions_command = Commands::Instructions.new(composer: instruction_composer, bindings: binding_command, output: output)
    parent_command = Commands::Parent.new(lineage: lineage, project_config: project_config, output: output)
    project_catalog = ProjectCatalog.new(project_config: project_config, git: git)
    project_facts = ProjectFacts.new(tmux: tmux, state: state, config: config, lock_namespace: lock_namespace,
      lock_holder: lock_holder, dev: dev_command, agents: ProjectAgents.new(client: agent_snapshot_client),
      git: git, catalog: project_catalog, error_output: error_output)
    projects_command = Commands::Projects.new(catalog: project_catalog, tmux: tmux, facts: project_facts, output: output, error_output: error_output)
    snapshot_command = Commands::Snapshot.new(catalog: project_catalog, facts: project_facts, tmux: tmux, state: state, config: config,
      snapshot_client: agent_snapshot_client, sessions: sessions_command, git: git, pull_request_status: PullRequestStatus.new,
      ask_store_for: ->(workspace) { AskStore.new(path: config.ask_state_path(workspace), error_output: error_output) },
      output: output, error_output: error_output)
    review_command = Commands::Review.new(catalog: project_catalog, git: git, snapshot_client: agent_snapshot_client, task_store: task_store,
      ask_store_for: ->(workspace) { AskStore.new(path: config.ask_state_path(workspace), error_output: error_output) }, session_ledger: session_ledger, transcript_summary: TranscriptSummary.new, pull_request_status: PullRequestStatus.new,
      output: output, error_output: error_output)
    # Hook output goes to stderr so it never lands in the JSON on stdout.
    json_hook_runner = HookRunner.new(project_settings: project_settings, project_config: project_config, output: error_output, error_output: error_output, logger: logger)
    project_actions_command = Commands::ProjectActions.new(catalog: project_catalog, stop_command: stop_command, kill_command: kill_command,
      state: state, tmux: tmux, git: git, lock_namespace: lock_namespace, lock_holder: lock_holder,
      hook_runner: hook_runner, json_hook_runner: json_hook_runner, output: output, error_output: error_output, input: input)
    config_command = Commands::Config.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, event_log: event_log, output: output)
    config_report = ConfigReport.new(project_settings: project_settings, project_config: project_config)
    tmuxinator_report = TmuxinatorReport.new(config: config, tmux: tmux)
    restore_command = Commands::Restore.new(ledger: session_ledger, tmux: tmux, pane_bindings: pane_bindings, tmuxinator_report: tmuxinator_report,
      process_tree: process_tree, agent_ensurer: ensure_agent_command, output: output, error_output: error_output)

    context_store = ContextStore.new(path: config.context_store_path, logger: logger)
    context_reader = ContextReader.new(context_store: context_store, project_settings: project_settings, tmux: tmux, logger: logger,
      lock_holder: lock_holder)
    statusline_command = Commands::Statusline.new(context_store: context_store, renderer: StatuslineRenderer.new(logger: logger),
      project_settings: project_settings, logger: logger, output: output, input: input, terminator: process_group_terminator,
      lock_holder: lock_holder)

    alert_config = AlertConfig.new(project_settings: project_settings, project_config: project_config,
      lineage: lineage, error_output: error_output)
    ask_command = Commands::Ask.new(config: config, project_detector: project_detector, alert_config: alert_config,
      pane_sender: send_command, event_log: event_log, output: output, error_output: error_output)

    work_coordinator_client = WorkCoordinatorClient.new(
      socket_path: config.work_coordinator_socket,
      status_socket_path: config.work_coordinator_status_socket,
      logger: logger
    )
    agent_command = Commands::Agent.new(
      config: config,
      tmux: tmux,
      work_coordinator_client: work_coordinator_client,
      pipeline_config: pipeline_config,
      # Its own LockHolder: the reaper runs on the monitor thread, and a
      # LockHolder's snapshot scope is per-instance, not per-thread.
      lock_reaper: LockReaper.new(lock_namespace: lock_namespace, lock_holder: LockHolder.new(process_tree: process_tree, run_liveness: run_liveness),
        terminator: process_group_terminator, interval: reap_interval, logger: logger, error_output: error_output),
      alert_config: alert_config,
      ps_timeout: ps_timeout,
      event_log: event_log,
      context_reader: context_reader,
      label_reader: TranscriptLabel.new,
      task_store: task_store,
      logger: logger,
      output: output,
      error_output: error_output
    )

    restart_agent_command = Commands::RestartAgent.new(config: config, output: output)
    handoff_config = HandoffConfig.new(project_settings: project_settings, project_config: project_config,
      lineage: lineage, error_output: error_output)
    handoff_command = Commands::Handoff.new(config: config, tmux: tmux, handoff_config: handoff_config,
      restart_agent_command: restart_agent_command, output: output, error_output: error_output)

    CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
      launch_command: launch_command,
      kill_command: kill_command,
      finish_command: finish_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      repair_command: repair_command,
      cleanup_command: cleanup_command,
      prune_command: prune_command,
      claude_command: claude_command,
      lookup_command: lookup_command,
      update_pane_command: update_pane_command,
      run_command: run_command,
      run_result_store: run_result_store,
      run_and_report_command: run_and_report_command,
      capture_command: capture_command,
      wait_until_content_command: wait_until_content_command,
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      projects_command: projects_command,
      capabilities_command: capabilities_command,
      daemon_command: daemon_command,
      ui_command: ui_command,
      binding_command: binding_command,
      library_command: library_command,
      library: library,
      instructions_command: instructions_command,
      review_command: review_command,
      restore_command: restore_command,
      snapshot_command: snapshot_command,
      project_actions_command: project_actions_command,
      agent_command: agent_command,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: config_command,
      config_report: config_report,
      tmuxinator_report: tmuxinator_report,
      statusline_command: statusline_command,
      ask_command: ask_command,
      launch_mode: launch_mode,
      liveness: Liveness.new(tmux: tmux),
      restart_agent_command: restart_agent_command,
      send_command: send_command,
      ensure_agent_command: ensure_agent_command,
      handoff_command: handoff_command,
      logger: logger,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
