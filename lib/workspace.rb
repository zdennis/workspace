require "optparse"
require "json"
require "fileutils"
require "time"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
module Workspace
  # Raised for runtime errors in workspace operations.
  class Error < StandardError; end

  # Raised for invalid usage or missing required arguments.
  class UsageError < Error; end

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
  end
end

require_relative "workspace/version"
require_relative "workspace/warn"
require_relative "workspace/logger"
require_relative "workspace/config"
require_relative "workspace/event_log"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/which"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/tmux_pane"
require_relative "workspace/project_config"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_layout"
require_relative "workspace/project_settings"
require_relative "workspace/process_tree"
require_relative "workspace/agent_readiness"
require_relative "workspace/workspace_lineage"
require_relative "workspace/duration"
require_relative "workspace/dev_config"
require_relative "workspace/lock_namespace"
require_relative "workspace/lock_holder"
require_relative "workspace/lock_audit_log"
require_relative "workspace/lock_store"
require_relative "workspace/lock_config"
require_relative "workspace/lock_idle_tracker"
require_relative "workspace/lock_reaper"
require_relative "workspace/lock_enforcer"
require_relative "workspace/notifier"
require_relative "workspace/alert_config"
require_relative "workspace/context_reasons"
require_relative "workspace/context_store"
require_relative "workspace/context_reader"
require_relative "workspace/statusline_renderer"
require_relative "workspace/ask_store"
require_relative "workspace/session_monitor"
require_relative "workspace/agent_provider"
require_relative "workspace/file_backup"
require_relative "workspace/process_group_terminator"
require_relative "workspace/process_holder_stopper"
require_relative "workspace/dev_runner"
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
require_relative "workspace/commands/capture"
require_relative "workspace/commands/lock"
require_relative "workspace/commands/dev"
require_relative "workspace/commands/parent"
require_relative "workspace/commands/config"
require_relative "workspace/commands/statusline"
require_relative "workspace/commands/ask"
require_relative "workspace/work_coordinator_client"
require_relative "workspace/pipeline_config"
require_relative "workspace/pipeline_state"
require_relative "workspace/sentinel_poller"
require_relative "workspace/commands/agent"
require_relative "workspace/run_result"
require_relative "workspace/run_result_store"
require_relative "workspace/commands/run_and_report"
require_relative "workspace/cli"

module Workspace
  # Assembles the full dependency graph and returns a ready-to-run CLI instance.
  #
  # @param output [IO] output stream for user-facing messages
  # @param error_output [IO] error output stream for warnings and errors
  # @param input [IO] input stream for interactive prompts
  # @param logger [Workspace::Logger, nil] debug logger (created automatically if nil)
  # @return [Workspace::CLI] a fully-wired CLI instance
  def self.build_cli(output: $stdout, error_output: $stderr, input: $stdin, logger: nil)
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
    doctor = Doctor.new(config: config, state: state, hook_installer: hook_installer, project_detector: project_detector, git: git, pipeline_config: pipeline_config, output: output)

    # Pre-build command objects so CLI delegates rather than constructs
    stop_command = Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    agent_readiness = AgentReadiness.new(tmux: tmux, process_tree: ProcessTree.new(logger: logger), logger: logger)
    launch_command = Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, pipeline_config: pipeline_config, agent_readiness: agent_readiness, output: output, error_output: error_output)
    lineage = WorkspaceLineage.new
    start_command = Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, lineage: lineage, hook_installer: hook_installer, output: output, input: input)
    kill_command = Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: input)
    finish_command = Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, error_output: error_output, input: input)
    focus_command = Commands::Focus.new(state: state, window_manager: window_manager, output: output)
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

    run_result_store = RunResultStore.new(config: config)
    run_and_report_command = Commands::RunAndReport.new(run_result_store: run_result_store)
    capture_command = Commands::Capture.new(tmux: tmux, output: output, error_output: error_output)

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
    lock_holder = LockHolder.new(process_tree: process_tree)
    sessions_command = Commands::Sessions.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      project_config: project_config, output: output, error_output: error_output)
    lock_idle_tracker = LockIdleTracker.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger)
    lock_enforcer = LockEnforcer.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, logger: logger)
    session_event_command = Commands::SessionEvent.new(config: config, tmux: tmux, input: input, error_output: error_output, logger: logger,
      lock_idle_tracker: lock_idle_tracker, lock_enforcer: lock_enforcer)
    process_group_terminator = ProcessGroupTerminator.new
    lock_command = Commands::Lock.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
      terminator: process_group_terminator, dev_config: dev_config, lock_config: lock_config, output: output, error_output: error_output)
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
      output: output,
      error_output: error_output
    )
    parent_command = Commands::Parent.new(lineage: lineage, project_config: project_config, output: output)
    config_command = Commands::Config.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output)

    context_store = ContextStore.new(path: config.context_store_path, logger: logger)
    context_reader = ContextReader.new(context_store: context_store, project_settings: project_settings, tmux: tmux, logger: logger,
      lock_holder: lock_holder)
    statusline_command = Commands::Statusline.new(context_store: context_store, renderer: StatuslineRenderer.new(logger: logger),
      project_settings: project_settings, logger: logger, output: output, input: input, terminator: process_group_terminator,
      lock_holder: lock_holder)

    alert_config = AlertConfig.new(project_settings: project_settings, project_config: project_config,
      lineage: lineage, error_output: error_output)
    ask_command = Commands::Ask.new(config: config, project_detector: project_detector, alert_config: alert_config,
      output: output, error_output: error_output)

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
      lock_reaper: LockReaper.new(lock_namespace: lock_namespace, lock_holder: LockHolder.new(process_tree: process_tree),
        terminator: process_group_terminator, interval: reap_interval, logger: logger, error_output: error_output),
      alert_config: alert_config,
      ps_timeout: ps_timeout,
      context_reader: context_reader,
      logger: logger,
      output: output,
      error_output: error_output
    )

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
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      agent_command: agent_command,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: config_command,
      statusline_command: statusline_command,
      ask_command: ask_command,
      logger: logger,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
