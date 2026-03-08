require "optparse"
require "json"
require "fileutils"
require_relative "workspace/version"
require_relative "workspace/logger"
require_relative "workspace/config"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/project_config"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_layout"
require_relative "workspace/project_settings"
require_relative "workspace/hook_runner"
require_relative "workspace/commands/init"
require_relative "workspace/commands/launch"
require_relative "workspace/commands/kill"
require_relative "workspace/commands/focus"
require_relative "workspace/commands/start"
require_relative "workspace/commands/stop"
require_relative "workspace/commands/tile"
require_relative "workspace/commands/resize"
require_relative "workspace/commands/layout"
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
    state = State.new(config: config, logger: logger)
    iterm = ITerm.new(config: config, output: output, logger: logger)
    window_manager = WindowManager.new(config: config, logger: logger)
    tmux = Tmux.new(config: config, logger: logger)
    git = Git.new(output: output, input: input, logger: logger)
    project_config = ProjectConfig.new(config: config, git: git, output: output)
    window_layout = WindowLayout.new(window_manager: window_manager, config: config, output: output, logger: logger)
    doctor = Doctor.new(config: config, output: output)
    project_settings = ProjectSettings.new(config: config)
    hook_runner = HookRunner.new(project_settings: project_settings, project_config: project_config, output: output, error_output: error_output, logger: logger)

    # Pre-build command objects so CLI delegates rather than constructs
    kill_command = Commands::Kill.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, output: output, error_output: error_output)
    start_command = Commands::Start.new(git: git, project_config: project_config, launch_command: launch_command, output: output, input: input)
    stop_command = Commands::Stop.new(git: git, project_config: project_config, kill_command: kill_command, output: output, input: input)
    focus_command = Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    init_command = Commands::Init.new(config: config, output: output, error_output: error_output)

    CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      launch_command: launch_command,
      kill_command: kill_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      logger: logger,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
