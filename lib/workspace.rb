require "optparse"
require "json"
require "fileutils"
require_relative "workspace/config"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/project_config"
require_relative "workspace/iterm"
require_relative "workspace/window_manager"
require_relative "workspace/window_layout"
require_relative "workspace/commands/init"
require_relative "workspace/commands/launch"
require_relative "workspace/commands/kill"
require_relative "workspace/commands/focus"
require_relative "workspace/commands/start"
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
  # @return [Workspace::CLI] a fully-wired CLI instance
  def self.build_cli(output: $stdout, error_output: $stderr, input: $stdin)
    config = Config.new
    state = State.new(config: config)
    iterm = ITerm.new(config: config, output: output)
    window_manager = WindowManager.new(config: config)
    tmux = Tmux.new(config: config)
    git = Git.new(output: output, input: input)
    project_config = ProjectConfig.new(config: config, git: git, output: output)
    window_layout = WindowLayout.new(window_manager: window_manager, config: config, output: output)
    doctor = Doctor.new(config: config, output: output)

    CLI.new(
      config: config,
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      git: git,
      project_config: project_config,
      window_layout: window_layout,
      doctor: doctor,
      output: output,
      error_output: error_output,
      input: input
    )
  end
end
