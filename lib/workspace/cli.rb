require "optparse"
require "securerandom"

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
    def initialize(config:, state:, iterm:, window_manager:, tmux:, git:, project_config:, window_layout:, doctor:, project_settings:, hook_runner:, output: $stdout, error_output: $stderr, input: $stdin)
      @config = config
      @state = state
      @iterm = iterm
      @window_manager = window_manager
      @tmux = tmux
      @git = git
      @project_config = project_config
      @window_layout = window_layout
      @doctor = doctor
      @project_settings = project_settings
      @hook_runner = hook_runner
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
      when "stop"
        cmd_stop(args)
      when "add", "add-project"
        cmd_add(args)
      when "kill"
        cmd_kill(args)
      when "relaunch"
        cmd_relaunch(args)
      when "focus"
        cmd_focus(args)
      when "tile"
        cmd_tile(args)
      when "resize"
        cmd_resize(args)
      when "layout"
        cmd_layout(args)
      when "list-projects"
        cmd_list_projects(args)
      when "list"
        cmd_list(args)
      when "status"
        cmd_status(args)
      when "whereis"
        cmd_whereis(args)
      when "alfred"
        cmd_alfred(args)
      when "version", "--version", "-v"
        @output.puts "workspace #{Workspace::VERSION}"
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
          stop            Kill a worktree project and remove its worktree (auto-detects from cwd)
          add             Add a tmuxinator config for a project directory
          kill            Kill active workspace projects and their tmux sessions
          relaunch        Kill and relaunch all active workspace projects
          focus           Bring a project's iTerm window to the front
          tile            Tile all windows for a project across the screen
          resize          Resize tmux panes for a running project
          layout          Save/restore tmux pane layouts (auto-saved before resize)
          list-projects   List all available tmuxinator projects
          list            List currently active (launched) projects
          status          Show detailed state of tracked launcher sessions
          whereis         Print the workspace installation directory
          alfred          Manage the Alfred workflow for workspace focus
          help            Show this help message

        Run 'workspace <subcommand> --help' for subcommand-specific help.
      HELP
    end

    def cmd_launch(args)
      reattach = false
      prompt = nil
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
        opts.on("--prompt PROMPT", "Send an initial prompt to Claude in each project") do |p|
          prompt = p
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

      prompts = prompt ? projects.each_with_object({}) { |p, h| h[p] = prompt } : {}

      Commands::Launch.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        project_config: @project_config,
        window_layout: @window_layout,
        output: @output
      ).call(projects, reattach: reattach, prompts: prompts)

      projects.each { |p| @hook_runner.run(p, "post_launch") }
    end

    def cmd_start(args)
      prompt = nil
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace start [options] <jira-key|jira-url|pr-url|branch>"
        opts.separator ""
        opts.separator "Create a git worktree and launch it as a workspace project."
        opts.separator ""
        opts.separator "Accepts:"
        opts.separator "  PROJ-123                                  JIRA issue key (used as branch name)"
        opts.separator "  https://mycompany.atlassian.net/.../123   JIRA URL (extracts issue key)"
        opts.separator "  https://github.com/.../pull/471           GitHub PR URL (fetches branch name)"
        opts.separator "  https://github.com/.../issues/123         GitHub issue URL (branch: issue-123)"
        opts.separator "  user/PROJ-123                             Branch name (used as-is)"
        opts.separator ""
        opts.separator "Options:"
        opts.on("--prompt PROMPT", "Send an initial prompt to Claude after launching") do |p|
          prompt = p
        end
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
      start_command.call(args.first, prompt: prompt)
      # post_start hook — project name not easily available here,
      # so hooks for start should use post_launch (which fires from Launch)
    end

    def cmd_stop(args)
      force = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace stop [project]"
        opts.separator ""
        opts.separator "Kill a worktree project's session and remove its git worktree."
        opts.separator "The inverse of 'workspace start'."
        opts.separator ""
        opts.separator "If no project is specified, detects the current worktree project"
        opts.separator "from a .workspace-project marker file in the working directory."
        opts.separator ""
        opts.separator "Options:"
        opts.on("-f", "--force", "Skip confirmation and force worktree removal") do
          force = true
        end
      end
      parser.parse!(args)

      kill_command = Commands::Kill.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        output: @output,
        error_output: @error_output
      )
      stop_command = Commands::Stop.new(
        git: @git,
        project_config: @project_config,
        kill_command: kill_command,
        output: @output,
        input: @input
      )
      project = stop_command.call(args.first, force: force)
      @hook_runner.run(project, "post_stop") if project
    end

    def cmd_kill(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace kill [project1] [project2] ..."
        opts.separator ""
        opts.separator "Kill workspace projects and their tmux sessions."
        opts.separator "If no projects are specified, kills all active workspace projects."
      end
      parser.parse!(args)

      killed = Commands::Kill.new(
        state: @state,
        iterm: @iterm,
        window_manager: @window_manager,
        tmux: @tmux,
        output: @output,
        error_output: @error_output
      ).call(args)

      killed.each { |p| @hook_runner.run(p, "post_kill") }
    end

    def cmd_focus(args)
      shake = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace focus [options] <project>"
        opts.separator ""
        opts.separator "Bring the project's iTerm window to the front."
        opts.separator ""
        opts.separator "Options:"
        opts.on("--shake", "Shake the window after focusing") do
          shake = true
        end
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      project = args.first
      Commands::Focus.new(
        state: @state,
        window_manager: @window_manager,
        output: @output
      ).call(project, shake: shake)

      @hook_runner.run(project, "post_focus")
    end

    def cmd_tile(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace tile <project>"
        opts.separator ""
        opts.separator "Tile all active windows for a project across the screen."
        opts.separator "Matches the base project and all its worktree sessions."
        opts.separator ""
        opts.separator "Example:"
        opts.separator "  workspace tile window-tool    # tiles window-tool + all window-tool.worktree-* windows"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.empty?

      Commands::Tile.new(
        state: @state,
        window_manager: @window_manager,
        window_layout: @window_layout,
        output: @output
      ).call(args.first)
    end

    def cmd_resize(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace resize <project> <pane-spec>"
        opts.separator ""
        opts.separator "Resize tmux panes for a running workspace project."
        opts.separator ""
        opts.separator "Pane spec is a comma-separated list of sizes, one per pane:"
        opts.separator "  Rows:       10 or 10h     (absolute row count)"
        opts.separator "  Percentage: 50%           (percentage of window height)"
        opts.separator "  Skip:       (empty)       (leave pane as-is)"
        opts.separator ""
        opts.separator "Examples:"
        opts.separator "  workspace resize myproject 15%,,35%      # pane 0=15%, skip 1, pane 2=35%"
        opts.separator "  workspace resize myproject 10h,80%,20%   # pane 0=10 rows, 1=80%, 2=20%"
        opts.separator "  workspace resize myproject 33%,33%,33%   # equal thirds"
      end
      parser.parse!(args)

      raise UsageError, parser.help if args.size < 2

      project = args[0]
      spec = args[1]

      layout_command = Commands::Layout.new(
        state: @state,
        tmux: @tmux,
        output: @output
      )
      Commands::Resize.new(
        tmux: @tmux,
        layout_command: layout_command,
        output: @output,
        error_output: @error_output
      ).call(project, spec)

      @hook_runner.run(project, "post_resize")
    end

    def cmd_layout(args)
      subcommand = args.shift

      case subcommand
      when "save"
        raise UsageError, layout_help_text if args.empty?
        project = args[0]
        name = args[1] || Commands::Layout::DEFAULT_NAME
        Commands::Layout.new(state: @state, tmux: @tmux, output: @output).save(project, name)
      when "restore"
        raise UsageError, layout_help_text if args.empty?
        project = args[0]
        name = args[1] || Commands::Layout::DEFAULT_NAME
        Commands::Layout.new(state: @state, tmux: @tmux, output: @output).restore(project, name)
      when "list"
        raise UsageError, layout_help_text if args.empty?
        Commands::Layout.new(state: @state, tmux: @tmux, output: @output).list(args[0])
      when "help", "--help", "-h", nil
        layout_help
      else
        raise UsageError, "Unknown layout subcommand: #{subcommand}\n\n" + layout_help_text
      end
    end

    def layout_help
      @output.puts layout_help_text
    end

    def layout_help_text
      <<~HELP
        Usage: workspace layout <subcommand> <project> [name]

        Subcommands:
          save <project> [name]      Save the current pane layout (default name: 'default')
          restore <project> [name]   Restore a saved layout (default name: 'default')
          list <project>             List saved layouts for a project

        Layouts are auto-saved as '_before_resize' whenever you run 'workspace resize',
        so you can always undo with: workspace layout restore <project> _before_resize

        Examples:
          workspace layout save myproject           # save as 'default'
          workspace layout save myproject coding    # save as 'coding'
          workspace layout restore myproject        # restore 'default'
          workspace layout list myproject           # show saved layouts
      HELP
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

      live_ids = @window_manager.live_window_ids
      active = @state.keys.select { |p| live_ids.include?(@state.dig(p, "iterm_window_id")) }

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

    def cmd_alfred(args)
      subcommand = args.shift

      case subcommand
      when "install"
        alfred_install(args)
      when "uninstall"
        alfred_uninstall(args)
      when "info"
        alfred_info(args)
      when "help", "--help", "-h", nil
        alfred_help
      else
        raise UsageError, "Unknown alfred subcommand: #{subcommand}\n\n" + alfred_help_text
      end
    end

    def alfred_help
      @output.puts alfred_help_text
    end

    def alfred_help_text
      <<~HELP
        Usage: workspace alfred <subcommand>

        Subcommands:
          install     Install or update the Alfred workflow
          uninstall   Remove the Alfred workflow
          info        Show workflow installation status

        The workflow lets you type 'wf' in Alfred to list and focus
        active workspace projects. Assign a hotkey in Alfred Preferences
        > Workflows > Workspace Focus.
      HELP
    end

    def alfred_workflows_dir
      File.expand_path("~/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows")
    end

    def alfred_source_dir
      File.join(@config.workspace_dir, "extensions", "alfred", "workspace-focus")
    end

    def find_installed_workflow
      dir = alfred_workflows_dir
      return nil unless File.directory?(dir)

      plist = Dir.glob(File.join(dir, "*/info.plist")).find do |p|
        File.read(p).include?("com.zdennis.workspace-focus")
      end
      plist ? File.dirname(plist) : nil
    end

    def alfred_install(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred install"
        opts.separator ""
        opts.separator "Install or update the Alfred workflow for workspace focus."
        opts.separator "Copies workflow files to Alfred's preferences directory."
      end
      parser.parse!(args)

      unless File.directory?(alfred_workflows_dir)
        raise Error, "Alfred workflows directory not found at #{alfred_workflows_dir}\nIs Alfred installed?"
      end

      unless File.directory?(alfred_source_dir)
        raise Error, "Alfred workflow source not found at #{alfred_source_dir}"
      end

      existing = find_installed_workflow
      if existing
        target_dir = existing
        @output.puts "Updating existing workflow..."
      else
        workflow_id = "user.workflow.#{SecureRandom.uuid.upcase}"
        target_dir = File.join(alfred_workflows_dir, workflow_id)
        FileUtils.mkdir_p(target_dir)
        @output.puts "Installing new workflow..."
      end

      %w[info.plist list_projects.rb focus_project.rb].each do |file|
        src = File.join(alfred_source_dir, file)
        dst = File.join(target_dir, file)
        FileUtils.cp(src, dst)
        FileUtils.chmod(0o755, dst) if file.end_with?(".rb")
      end

      @output.puts "Installed to #{target_dir}"
      @output.puts "Type 'wf' in Alfred to list active workspace projects."
    end

    def alfred_uninstall(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred uninstall"
        opts.separator ""
        opts.separator "Remove the Alfred workflow for workspace focus."
      end
      parser.parse!(args)

      target_dir = find_installed_workflow
      unless target_dir
        @output.puts "Workspace Focus workflow is not installed."
        return
      end

      @output.print "Remove workflow from #{target_dir}? [y/N] "
      answer = @input.gets&.strip
      unless answer&.match?(/\Ay(es)?\z/i)
        @output.puts "Cancelled."
        return
      end

      FileUtils.rm_rf(target_dir)
      @output.puts "Removed."
    end

    def alfred_info(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: workspace alfred info"
        opts.separator ""
        opts.separator "Show the installation status of the Alfred workflow."
      end
      parser.parse!(args)

      unless File.directory?(alfred_workflows_dir)
        @output.puts "Alfred is not installed."
        return
      end

      target_dir = find_installed_workflow
      if target_dir
        @output.puts "Workspace Focus workflow is installed."
        @output.puts "Location: #{target_dir}"
        @output.puts "Keyword: wf"
      else
        @output.puts "Workspace Focus workflow is not installed."
        @output.puts "Run 'workspace alfred install' to install it."
      end
    end
  end
end
