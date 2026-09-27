require "optparse"
require "json"
require "fileutils"
require "time"
require_relative "workspace/version"
require_relative "workspace/warn"
require_relative "workspace/logger"
require_relative "workspace/config"
require_relative "workspace/event_log"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/tmux_pane"
require_relative "workspace/project_config"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_layout"
require_relative "workspace/project_settings"
require_relative "workspace/process_tree"
require_relative "workspace/workspace_lineage"
require_relative "workspace/duration"
require_relative "workspace/dev_config"
require_relative "workspace/lock_namespace"
require_relative "workspace/lock_holder"
require_relative "workspace/lock_store"
require_relative "workspace/lock_config"
require_relative "workspace/lock_idle_tracker"
require_relative "workspace/lock_enforcer"
require_relative "workspace/session_monitor"
require_relative "workspace/agent_provider"
require_relative "workspace/file_backup"
require_relative "workspace/process_group_terminator"
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
require_relative "workspace/work_coordinator_client"
require_relative "workspace/pipeline_config"
require_relative "workspace/pipeline_state"
require_relative "workspace/sentinel_poller"
require_relative "workspace/commands/agent"
require_relative "workspace/run_result"
require_relative "workspace/run_result_store"
require_relative "workspace/commands/run_and_report"
require_relative "workspace/cli"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
module Workspace
  # Raised for runtime errors in workspace operations.
  class Error < StandardError; end

  # Raised for invalid usage or missing required arguments.
  class UsageError < Error; end

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
    doctor = Doctor.new(config: config, state: state, hook_installer: hook_installer, project_detector: project_detector, output: output)

    # Pre-build command objects so CLI delegates rather than constructs
    kill_command = Commands::Kill.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
    lineage = WorkspaceLineage.new
    start_command = Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, lineage: lineage, output: output, input: input)
    stop_command = Commands::Stop.new(git: git, project_config: project_config, project_settings: project_settings, kill_command: kill_command, project_detector: project_detector, output: output, input: input)
    focus_command = Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    sessions_command = Commands::Sessions.new(config: config, output: output, error_output: error_output)
    init_command = Commands::Init.new(config: config, hook_installer: hook_installer, output: output, error_output: error_output, input: input)
    repair_command = Commands::Repair.new(state: state, iterm: iterm, window_manager: window_manager, output: output)
    cleanup_command = Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
    prune_command = Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, kill_command: kill_command, output: output, input: input)
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
    lock_holder = LockHolder.new
    dev_config = DevConfig.new(project_settings: project_settings)
    lock_config = LockConfig.new(project_settings: project_settings, error_output: error_output)
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

    work_coordinator_client = WorkCoordinatorClient.new(
      socket_path: config.work_coordinator_socket,
      status_socket_path: config.work_coordinator_status_socket,
      logger: logger
    )
    pipeline_config = PipelineConfig.new(config: config)
    agent_command = Commands::Agent.new(
      config: config,
      tmux: tmux,
      work_coordinator_client: work_coordinator_client,
      pipeline_config: pipeline_config,
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
      logger: logger,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
