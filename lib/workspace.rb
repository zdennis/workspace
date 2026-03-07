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
require_relative "workspace/window_layout"
require_relative "workspace/commands/launch"
require_relative "workspace/commands/kill"
require_relative "workspace/commands/focus"
require_relative "workspace/commands/start"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
#
# All methods are module functions, callable as Workspace.method_name.
# This is a temporary scaffolding approach -- later phases will extract
# these into proper classes.
module Workspace
  class Error < StandardError; end

  class UsageError < Error; end

  module_function

  CONFIG = Config.new
  GIT = Git.new
  TMUX = Tmux.new(config: CONFIG)
  PROJECT_CONFIG = ProjectConfig.new(config: CONFIG, git: GIT)
  ITERM = ITerm.new(config: CONFIG)
  WINDOW_LAYOUT = WindowLayout.new(iterm: ITERM, config: CONFIG)

  WORKSPACE_DIR = CONFIG.workspace_dir
  TMUXINATOR_DIR = CONFIG.tmuxinator_dir
  TMUXINATOR_TEMPLATE = CONFIG.project_template_path
  TMUXINATOR_WORKTREE_TEMPLATE = CONFIG.worktree_template_path
  WINDOW_TOOL = CONFIG.window_tool
  STATE_FILE = CONFIG.state_file

  # Entry point for the CLI. Dispatches to the appropriate subcommand.
  #
  # @param argv [Array<String>] command-line arguments
  # @return [void]
  def run(argv)
    args = argv.dup
    subcommand = args.shift

    case subcommand
    when "init"
      init(args)
    when "doctor"
      doctor(args)
    when "launch"
      launch(args)
    when "start"
      start_worktree(args)
    when "add", "add-project"
      add_project(args)
    when "kill"
      kill_workspace(args)
    when "relaunch"
      relaunch(args)
    when "focus"
      focus(args)
    when "list-projects"
      list_projects(args)
    when "list"
      list_active(args)
    when "status"
      status(args)
    when "whereis"
      whereis(args)
    when "help", "--help", "-h", nil
      main_help
    else
      warn "Unknown subcommand: #{subcommand}"
      $stderr.puts
      main_help
      exit 1
    end
  end

  def main_help
    puts <<~HELP
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

  def resolve_project_arg(arg)
    PROJECT_CONFIG.resolve_project_arg(arg)
  end

  def create_project_config(name, root)
    PROJECT_CONFIG.create(name, root)
  end

  def tmux_session_name_for(config_name)
    TMUX.session_name_for(config_name)
  end

  def load_state
    State.new(config: CONFIG).load.to_h
  end

  def save_state(state)
    s = State.new(config: CONFIG)
    state.each { |k, v| s[k] = v }
    s.save
  end

  def iterm_window_titles
    ITERM.window_titles
  end

  def iterm_session_map
    ITERM.session_map
  end

  def find_existing_sessions(state)
    ITERM.find_existing_sessions(state)
  end

  def find_launcher_window_id(state)
    ITERM.find_launcher_window_id(state)
  end

  def create_launcher_panes(projects, state: {}, reattach: false)
    return {} if projects.empty?
    commands = projects.map { |p| [p, tmux_command_for(p, reattach: reattach)] }.to_h
    launcher_wid = find_launcher_window_id(state)
    ITERM.create_launcher_panes(projects, commands, launcher_wid: launcher_wid)
  end

  def relaunch_in_session(unique_id, project, reattach: false)
    cmd = tmux_command_for(project, reattach: reattach)
    ITERM.relaunch_in_session(unique_id, cmd)
  end

  def tmux_sessions
    TMUX.sessions
  end

  def tmux_command_for(project, reattach: false)
    TMUX.command_for(project, reattach: reattach)
  end

  def launch(args)
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

    if args.empty?
      warn parser.help
      exit 1
    end

    # Resolve path arguments: create configs on the fly for directories
    projects = args.map do |arg|
      name, root = resolve_project_arg(arg)
      if root
        create_project_config(name, root)
      else
        name
      end
    end

    launch_command = Commands::Launch.new(
      state: State.new(config: CONFIG),
      iterm: ITERM,
      tmux: TMUX,
      project_config: PROJECT_CONFIG,
      window_layout: WINDOW_LAYOUT
    )
    launch_command.call(projects, reattach: reattach)
  rescue Workspace::Error => e
    warn "Error: #{e.message}"
    exit 1
  end

  def status(args)
    state = load_state
    if state.empty?
      puts "No tracked sessions."
      return
    end

    existing = find_existing_sessions(state)
    state.each do |project, info|
      alive = existing.key?(project) ? "alive" : "gone"
      puts "  #{project}: #{info["unique_id"]} [#{alive}]"
    end
  end

  def focus(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace focus <project>"
      opts.separator ""
      opts.separator "Bring the project's tmux window to the front and shake it."
    end
    parser.parse!(args)

    if args.empty?
      warn parser.help
      exit 1
    end

    focus_command = Commands::Focus.new(
      state: State.new(config: CONFIG),
      iterm: ITERM
    )
    focus_command.call(args.first)
  rescue Workspace::Error => e
    warn "Error: #{e.message}"
    exit 1
  end

  def kill_workspace(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace kill [project1] [project2] ..."
      opts.separator ""
      opts.separator "Kill workspace projects and their tmux sessions."
      opts.separator "If no projects are specified, kills all active workspace projects."
    end
    parser.parse!(args)

    kill_command = Commands::Kill.new(
      state: State.new(config: CONFIG),
      iterm: ITERM,
      tmux: TMUX
    )
    kill_command.call(args)
  end

  def list_projects(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace list-projects"
      opts.separator ""
      opts.separator "List all available tmuxinator projects."
    end
    parser.parse!(args)

    PROJECT_CONFIG.available_projects.each { |name| puts name }
  end

  def list_active(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace list"
      opts.separator ""
      opts.separator "List currently active (launched) projects."
    end
    parser.parse!(args)

    state = load_state
    if state.empty?
      puts "No active projects."
      return
    end

    existing = find_existing_sessions(state)
    active = state.keys.select { |p| existing.key?(p) }

    if active.empty?
      puts "No active projects."
    else
      active.sort.each { |p| puts p }
    end
  end

  def add_project(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace add <path> [path2] ..."
      opts.separator ""
      opts.separator "Add tmuxinator configs for project directories."
      opts.separator "Uses the directory name as the project name."
      opts.separator "Does nothing if a config already exists."
    end
    parser.parse!(args)

    if args.empty?
      warn parser.help
      exit 1
    end

    args.each do |arg|
      name, root = resolve_project_arg(arg)
      root ||= File.expand_path(arg)
      unless File.directory?(root)
        warn "Error: Not a directory: #{root}"
        next
      end
      create_project_config(name, root)
    end
  end

  def start_worktree(args)
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

    if args.empty?
      warn parser.help
      exit 1
    end

    launch_command = Commands::Launch.new(
      state: State.new(config: CONFIG),
      iterm: ITERM,
      tmux: TMUX,
      project_config: PROJECT_CONFIG,
      window_layout: WINDOW_LAYOUT
    )
    start_command = Commands::Start.new(
      git: GIT,
      project_config: PROJECT_CONFIG,
      launch_command: launch_command
    )
    start_command.call(args.first)
  rescue Workspace::Error => e
    warn "Error: #{e.message}"
    exit 1
  end

  def whereis(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace whereis"
      opts.separator ""
      opts.separator "Print the workspace installation directory."
    end
    parser.parse!(args)

    puts WORKSPACE_DIR
  end

  def doctor(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace doctor"
      opts.separator ""
      opts.separator "Check that all required dependencies are installed and configured."
    end
    parser.parse!(args)

    Doctor.new(config: CONFIG).run
  rescue Workspace::Error
    exit 1
  end

  def init(args)
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

    templates = [
      "project-template.yml",
      "project-worktree-template.yml"
    ]

    puts "workspace init#{" (dry run)" if dry_run}"
    puts ""

    # Step 1: Create tmuxinator config directory
    if File.directory?(TMUXINATOR_DIR)
      puts "  exists  #{TMUXINATOR_DIR}"
    elsif dry_run
      puts "  create  #{TMUXINATOR_DIR}"
    else
      FileUtils.mkdir_p(TMUXINATOR_DIR)
      puts "  create  #{TMUXINATOR_DIR}"
    end

    # Step 2: Copy templates
    templates.each do |template|
      src = File.join(WORKSPACE_DIR, template)
      dest = File.join(TMUXINATOR_DIR, template)

      unless File.exist?(src)
        warn "  error   #{template} not found in #{WORKSPACE_DIR}"
        next
      end

      if File.exist?(dest)
        if FileUtils.identical?(src, dest)
          puts "  skip    #{template} (already up to date)"
        elsif force
          FileUtils.cp(src, dest) unless dry_run
          puts "  update  #{template} -> #{dest}"
        else
          puts "  skip    #{template} (already exists, use --force to overwrite)"
        end
      elsif dry_run
        puts "  copy    #{template} -> #{dest}"
      else
        FileUtils.cp(src, dest)
        puts "  copy    #{template} -> #{dest}"
      end
    end

    puts ""
    if dry_run
      puts "No changes made (dry run)."
    else
      puts "Done! Workspace is ready to use."
    end
  end

  def relaunch(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace relaunch"
      opts.separator ""
      opts.separator "Kill all active workspace projects and relaunch them."
    end
    parser.parse!(args)

    state = load_state
    if state.empty?
      warn "No active workspace projects to relaunch."
      exit 1
    end

    projects = state.keys.dup
    puts "Will relaunch: #{projects.join(", ")}"

    # Kill everything
    kill_workspace([])

    # Brief pause for cleanup
    sleep 2

    # Relaunch
    launch(projects.dup)
  end
end
