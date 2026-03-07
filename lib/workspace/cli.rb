require "optparse"

module Workspace
  # Command-line interface for the workspace CLI.
  # Receives all collaborators via constructor injection and dispatches
  # subcommands via a case statement.
  class CLI
    # @param config [Workspace::Config] configuration for path lookups
    # @param state [Workspace::State] state persistence
    # @param iterm [Workspace::ITerm] iTerm automation
    # @param tmux [Workspace::Tmux] tmux session operations
    # @param git [Workspace::Git] git operations
    # @param project_config [Workspace::ProjectConfig] project config management
    # @param window_layout [Workspace::WindowLayout] window positioning
    # @param doctor [Workspace::Doctor] dependency checking
    # @param output [IO] output stream for user-facing messages
    # @param error_output [IO] error output stream for warnings and errors
    # @param input [IO] input stream for interactive prompts
    def initialize(config:, state:, iterm:, window_manager:, tmux:, git:, project_config:, window_layout:, doctor:, output: $stdout, error_output: $stderr, input: $stdin)
      @config = config
      @state = state
      @iterm = iterm
      @window_manager = window_manager
      @tmux = tmux
      @git = git
      @project_config = project_config
      @window_layout = window_layout
      @doctor = doctor
      @output = output
      @error_output = error_output
      @input = input
    end

    # Parses the subcommand from argv and dispatches to the appropriate method.
    #
    # @param argv [Array<String>] command-line arguments
    # @return [void]
    def run(argv)
      args = argv.dup
      subcommand = args.shift

      case subcommand
      when "init"
        cmd_init(args)
      when "doctor"
        cmd_doctor(args)
      when "launch"
        cmd_launch(args)
      when "start"
        cmd_start(args)
      when "add", "add-project"
        cmd_add(args)
      when "kill"
        cmd_kill(args)
      when "relaunch"
        cmd_relaunch(args)
      when "focus"
        cmd_focus(args)
      when "list-projects"
        cmd_list_projects(args)
      when "list"
        cmd_list(args)
      when "status"
        cmd_status(args)
      when "whereis"
        cmd_whereis(args)
      when "help", "--help", "-h", nil
        main_help
      else
        @error_output.puts "Unknown subcommand: #{subcommand}"
        @error_output.puts
        main_help
        exit 1
      end
    rescue UsageError => e
      @error_output.puts e.message
      exit 1
    rescue Error => e
      @error_output.puts "Error: #{e.message}"
      exit 1
    end

    private

    def main_help
      @output.puts <<~HELP
        Usage: workspace <subcommand> [options]

        Subcommands:
          init            Install tmuxinator templates and create config directory
          doctor          Check that all required dependencies are installed
          launch          Launch tmuxinator projects in iTerm windows
          start           Create a worktree and launch it (from JIRA key, PR URL, or branch)
          add             Add a tmuxinator config for a project directory
          kill            Kill active workspace projects and their tmux sessions
          relaunch        Kill and relaunch all active workspace projects
          focus           Bring a project's tmux window to the front and shake it
          list-projects   List all available tmuxinator projects
          list            List currently active (launched) projects
          status          Show detailed state of tracked launcher sessions
          whereis         Print the workspace installation directory
          help            Show this help message

        Run 'workspace <subcommand> --help' for subcommand-specific help.
      HELP
    end

    def cmd_launch(args)
      reattach = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace launch [options] <project1> [project2] ..."
        opts.separator ""
        opts.separator "Launch tmuxinator projects in iTerm2, each in its own window."
        opts.separator "Reuses existing launcher panes when available."
        opts.separator "Windows are arranged left-to-right with slight overlap."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--reattach", "Reattach to existing tmux sessions, preserving session state.") do
          reattach = true
        end
        opts.separator ""
        opts.separator "Note: --reattach uses tmux -CC attach which may trigger an iTerm dialog."
        opts.separator "To suppress it, set iTerm > Settings > General > tmux >"
        opts.separator "  'When attaching, restore windows' to 'Always'."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      projects = args.map do |arg|
        name, root = @project_config.resolve_project_arg(arg)
        if root
          @project_config.create(name, root)
        else
          name
        end
      end

      Commands::Launch.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        project_config: @project_config,
        window_layout: @window_layout,
        output: @output
      ).call(projects, reattach: reattach)
    end

    def cmd_start(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace start <jira-key|jira-url|pr-url|branch>"
        opts.separator ""
        opts.separator "Create a git worktree and launch it as a workspace project."
        opts.separator ""
        opts.separator "Accepts:"
        opts.separator "  PROJ-123                                  JIRA issue key (used as branch name)"
        opts.separator "  https://mycompany.atlassian.net/.../123   JIRA URL (extracts issue key)"
        opts.separator "  https://github.com/.../pull/471           GitHub PR URL (fetches branch name)"
        opts.separator "  user/PROJ-123                             Branch name (used as-is)"
        opts.separator ""
        opts.separator "The worktree is created in .worktrees/ under the project root."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      launch_command = Commands::Launch.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        project_config: @project_config,
        window_layout: @window_layout,
        output: @output
      )
      start_command = Commands::Start.new(
        git: @git,
        project_config: @project_config,
        launch_command: launch_command,
        output: @output,
        input: @input
      )
      start_command.call(args.first)
    end

    def cmd_kill(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace kill [project1] [project2] ..."
        opts.separator ""
        opts.separator "Kill workspace projects and their tmux sessions."
        opts.separator "If no projects are specified, kills all active workspace projects."
      end
      parser.parse!(args)

      Commands::Kill.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        output: @output,
        error_output: @error_output
      ).call(args)
    end

    def cmd_focus(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace focus <project>"
        opts.separator ""
        opts.separator "Bring the project's tmux window to the front and shake it."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      Commands::Focus.new(
        state: @state,
        window_manager: @window_manager,
        output: @output
      ).call(args.first)
    end

    def cmd_init(args)
      dry_run = false
      force = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace init [options]"
        opts.separator ""
        opts.separator "Set up workspace by installing tmuxinator templates and creating"
        opts.separator "the config directory if it doesn't exist."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--dry-run", "Show what would be done without making changes") do
          dry_run = true
        end
        opts.on("-f", "--force", "Overwrite existing templates even if they differ") do
          force = true
        end
      end
      parser.parse!(args)

      Commands::Init.new(
        config: @config,
        output: @output,
        error_output: @error_output
      ).call(dry_run: dry_run, force: force)
    end

    def cmd_doctor(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace doctor"
        opts.separator ""
        opts.separator "Check that all required dependencies are installed and configured."
      end
      parser.parse!(args)

      @doctor.run
    end

    def cmd_relaunch(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace relaunch"
        opts.separator ""
        opts.separator "Kill all active workspace projects and relaunch them."
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        @error_output.puts "No active workspace projects to relaunch."
        exit 1
      end

      projects = @state.keys.dup
      @output.puts "Will relaunch: #{projects.join(", ")}"

      cmd_kill([])

      sleep 2

      cmd_launch(projects.dup)
    end

    def cmd_add(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace add <path> [path2] ..."
        opts.separator ""
        opts.separator "Add tmuxinator configs for project directories."
        opts.separator "Uses the directory name as the project name."
        opts.separator "Does nothing if a config already exists."
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      args.each do |arg|
        name, root = @project_config.resolve_project_arg(arg)
        root ||= File.expand_path(arg)
        unless File.directory?(root)
          @error_output.puts "Error: Not a directory: #{root}"
          next
        end
        @project_config.create(name, root)
      end
    end

    def cmd_list_projects(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace list-projects"
        opts.separator ""
        opts.separator "List all available tmuxinator projects."
      end
      parser.parse!(args)

      @project_config.available_projects.each { |name| @output.puts name }
    end

    def cmd_list(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace list"
        opts.separator ""
        opts.separator "List currently active (launched) projects."
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        @output.puts "No active projects."
        return
      end

      existing = @iterm.find_existing_sessions(@state)
      active = @state.keys.select { |p| existing.key?(p) }

      if active.empty?
        @output.puts "No active projects."
      else
        active.sort.each { |p| @output.puts p }
      end
    end

    def cmd_status(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace status"
        opts.separator ""
        opts.separator "Show detailed state of tracked launcher sessions."
      end
      parser.parse!(args)

      @state.load
      if @state.empty?
        @output.puts "No tracked sessions."
        return
      end

      existing = @iterm.find_existing_sessions(@state)
      @state.each do |project, info|
        alive = existing.key?(project) ? "alive" : "gone"
        @output.puts "  #{project}: #{info["unique_id"]} [#{alive}]"
      end
    end

    def cmd_whereis(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace whereis"
        opts.separator ""
        opts.separator "Print the workspace installation directory."
      end
      parser.parse!(args)

      @output.puts @config.workspace_dir
    end
  end
end
