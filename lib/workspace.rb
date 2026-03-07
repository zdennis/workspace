require "optparse"
require "open3"
require "json"
require "fileutils"
require_relative "workspace/config"
require_relative "workspace/state"
require_relative "workspace/git"
require_relative "workspace/doctor"
require_relative "workspace/tmux"
require_relative "workspace/project_config"
require_relative "workspace/iterm"

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

    missing = projects.reject { |p| PROJECT_CONFIG.exists?(p) }
    unless missing.empty?
      warn "Error: No tmuxinator config found for:"
      missing.each { |name| warn "  - #{name} (expected #{TMUXINATOR_DIR}/#{name}.yml)" }
      exit 1
    end

    # Step 1: Ensure the tmux server is running
    TMUX.start_server

    # Step 2: Load state and check which sessions still exist
    state = load_state
    existing = find_existing_sessions(state)

    reuse_projects = projects.select { |p| existing.key?(p) }
    new_projects = projects.reject { |p| existing.key?(p) }

    # Step 3: Relaunch in existing panes
    reuse_projects.each do |project|
      uid = existing[project]
      puts "Reusing existing pane for #{project}..."
      result = relaunch_in_session(uid, project, reattach: reattach)
      if result != "ok"
        warn "  Warning: Session for #{project} disappeared, will create new pane"
        new_projects << project
        state.delete(project)
      end
    end

    # Step 4: Create new panes for projects that need them
    if new_projects.any?
      puts "Creating #{new_projects.size} new launcher pane(s)..."
      new_session_ids = create_launcher_panes(new_projects, state: state, reattach: reattach)

      new_session_ids.each do |project, uid|
        state[project] = {"unique_id" => uid}
        puts "  Created pane for #{project} (#{uid})"
      end
    end

    # Step 5: Save state
    save_state(state)

    # Step 6: Wait for tmux sessions to exist, then rename their windows.
    # The tmux session name may differ from the config name (e.g., worktree
    # configs abbreviate "worktree" to "wt" and replace dots with dashes).
    puts "Waiting for tmux sessions..."
    window_prefix = "workspace"
    max_wait = 30
    elapsed = 0
    sessions_ready = []

    # Build a mapping of config name -> tmux session name
    session_names = projects.map { |p| [p, tmux_session_name_for(p)] }.to_h

    while sessions_ready.size < projects.size && elapsed < max_wait
      sleep 1
      elapsed += 1
      existing_tmux = TMUX.sessions
      projects.each do |project|
        next if sessions_ready.include?(project)
        tmux_name = session_names[project]
        if existing_tmux.include?(tmux_name)
          TMUX.rename_window(tmux_name, 0, "#{window_prefix}-#{tmux_name}")
          sessions_ready << project
          puts "  Session ready: #{project} (tmux: #{tmux_name})"
        end
      end
    end

    not_found = projects - sessions_ready
    if not_found.any?
      warn "Warning: Timed out waiting for sessions: #{not_found.join(", ")}"
    end

    # Give iTerm a moment to sync the renamed titles
    sleep 1

    # Step 7: Wait for all project windows to appear and save their IDs.
    # First check if we already have a saved window ID that still exists.
    # Then fall back to searching by window title (only reliable right after
    # rename, before user switches tabs).
    puts "Waiting for project windows to appear..."
    found = {}

    # Check saved window IDs first
    projects.each do |project|
      saved_id = state.dig(project, "iterm_window_id")
      next unless saved_id
      if ITERM.window_exists?(saved_id)
        found[project] = saved_id.to_s
        puts "  Found window for #{project} (saved ID)"
      end
    end

    # Poll for remaining windows by title
    max_window_wait = 30
    window_elapsed = 0
    while found.size < projects.size && window_elapsed < max_window_wait
      sleep 1
      window_elapsed += 1
      projects.each do |project|
        next if found.key?(project)
        tmux_name = session_names[project]
        title_to_find = "#{window_prefix}-#{tmux_name}"
        result = ITERM.find_window_by_title(title_to_find)
        if result
          found[project] = result
          state[project] ||= {}
          state[project]["iterm_window_id"] = result.to_i
          puts "  Found window for #{project}"
        end
      end
    end

    missing_windows = projects.reject { |p| found.key?(p) }
    if missing_windows.any?
      warn "Warning: Could not find windows for: #{missing_windows.join(", ")}"
    end

    # Save state with window IDs
    save_state(state)

    # Step 8: Stagger all found windows left-to-right on the active screen.
    # This runs after all windows have appeared so the final positions aren't
    # overwritten by tmuxinator's own window-tool positioning.
    puts "Arranging windows..."
    screen_info, _ = Open3.capture2(WINDOW_TOOL, "active-screen")
    screen_x, screen_y, screen_w, screen_h = screen_info.strip.split("\t").map(&:to_i)

    window_width = (screen_w * 0.22).to_i
    window_height = (screen_h * 0.9).to_i
    y_pos = screen_y + ((screen_h - window_height) / 2).to_i

    total_width_needed = window_width * projects.size
    spacing = if total_width_needed > screen_w
      ((screen_w - window_width).to_f / [projects.size - 1, 1].max).to_i
    else
      window_width
    end

    start_x = screen_x + ((screen_w - (spacing * (projects.size - 1) + window_width)) / 2).to_i

    projects.each_with_index do |project, i|
      window_id = found[project]
      next unless window_id

      x_pos = start_x + (spacing * i)
      ITERM.set_window_bounds(window_id, x_pos, y_pos, window_width, window_height)
      puts "  Positioned #{project} at #{x_pos},#{y_pos} (#{window_width}x#{window_height})"
    end

    puts "Done! Launched #{projects.size} project(s)."
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

    project = args.first

    # Look up the saved iTerm window ID from state
    state = load_state
    window_id = state.dig(project, "iterm_window_id")

    unless window_id
      result = ITERM.find_window_for_project(project)
      if result
        window_id = result.to_i
        state[project] ||= {}
        state[project]["iterm_window_id"] = window_id
        save_state(state)
      end
    end

    unless window_id
      warn "Error: No iTerm window found for '#{project}'"
      warn "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
      exit 1
    end

    puts "Focusing #{project}..."
    result = ITERM.focus_and_shake(window_id)
    if result == "not_found"
      warn "Error: iTerm window #{window_id} no longer exists for '#{project}'"
      warn "Run 'workspace launch #{project}' to relaunch."
      exit 1
    end
  end

  def kill_workspace(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace kill [project1] [project2] ..."
      opts.separator ""
      opts.separator "Kill workspace projects and their tmux sessions."
      opts.separator "If no projects are specified, kills all active workspace projects."
    end
    parser.parse!(args)

    state = load_state
    if state.empty?
      puts "No active workspace projects."
      return []
    end

    # Determine which projects to kill
    projects = if args.empty?
      state.keys
    else
      args.select { |p| state.key?(p) }.tap do |found|
        not_found = args - found
        not_found.each { |p| warn "Warning: '#{p}' is not an active workspace project" }
      end
    end

    if projects.empty?
      puts "No matching workspace projects to kill."
      return []
    end

    # Save the list of projects before killing (for relaunch)
    killed_projects = projects.dup

    # Find the launcher window BEFORE killing tmux sessions, since killing
    # sessions may change the state of launcher panes.
    existing = find_existing_sessions(state)
    launcher_uids = projects.filter_map { |p| existing[p] }
    launcher_window_ids_to_close = []
    if launcher_uids.any?
      live_sessions = iterm_session_map
      # Group launcher panes by their window
      candidate_window_ids = launcher_uids.filter_map { |uid| live_sessions[uid] }.uniq
      candidate_window_ids.each do |wid|
        # Find all tracked projects that have launcher panes in this window
        sessions_in_window = live_sessions.select { |_, w| w == wid }.keys
        tracked_in_window = state.select { |_, info| sessions_in_window.include?(info["unique_id"]) }.keys
        # Only close the window if ALL tracked projects in it are being killed
        if (tracked_in_window - projects).empty?
          launcher_window_ids_to_close << wid
        end
      end
    end

    # Kill tmux sessions (this also closes the tmux -CC iTerm windows)
    projects.each do |project|
      if tmux_sessions.include?(project)
        puts "Killing tmux session: #{project}"
        TMUX.kill_session(project)
      end
    end

    # Close launcher windows only if all their tracked projects are being killed
    launcher_window_ids_to_close.each do |wid|
      puts "Closing launcher window #{wid}"
      ITERM.close_window(wid)
    end

    # Clear iterm_window_id for killed projects but keep unique_id.
    # The launcher pane is still alive (idle at a shell prompt after the tmux
    # session was killed). Keeping the unique_id lets the next launch reuse it
    # instead of creating a new window.
    projects.each do |p|
      state[p]&.delete("iterm_window_id")
    end
    save_state(state)

    puts "Killed #{killed_projects.size} project(s): #{killed_projects.join(", ")}"
    killed_projects
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

  # --- Worktree / start helpers ---

  def sanitize_for_filesystem(name)
    GIT.sanitize_for_filesystem(name)
  end

  def git_root
    GIT.root
  end

  def git_default_branch
    GIT.default_branch
  end

  def git_current_branch
    GIT.current_branch
  end

  def git_branch_exists?(name)
    GIT.branch_exists?(name)
  end

  def git_local_branch_exists?(name)
    GIT.local_branch_exists?(name)
  end

  def git_remote_branch_exists?(name)
    GIT.remote_branch_exists?(name)
  end

  def git_fetch_remote_branches
    GIT.fetch_remote_branches
  end

  def git_find_matching_branches(pattern)
    GIT.find_matching_branches(pattern)
  end

  def git_worktree_exists?(path)
    GIT.worktree_exists?(path)
  end

  def parse_start_input(input)
    GIT.parse_start_input(input)
  end

  def resolve_branch_from_pr(pr_url)
    GIT.resolve_branch_from_pr(pr_url)
  end

  def prompt_branch_selection(matches, pattern)
    GIT.prompt_branch_selection(matches, pattern)
  end

  def prompt_base_branch
    GIT.prompt_base_branch
  end

  def create_worktree_config(project_name, worktree_name, worktree_path, branch_name)
    PROJECT_CONFIG.create_worktree(project_name, worktree_name, worktree_path, branch_name)
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

    root = git_root
    unless root
      warn "Error: Not inside a git repository."
      exit 1
    end

    project_name = File.basename(root).sub(/^\.+/, "")
    input = args.first
    parsed = parse_start_input(input)

    # Resolve to a branch name
    case parsed[:type]
    when :pr_url
      puts "Fetching PR details..."
      branch_name = resolve_branch_from_pr(parsed[:value])
      puts "PR branch: #{branch_name}"
    when :jira_key
      branch_name = parsed[:value]
    when :branch
      branch_name = parsed[:value]
    end

    worktree_dir_name = sanitize_for_filesystem(branch_name)
    worktree_path = File.join(root, ".worktrees", worktree_dir_name)

    # Check if worktree already exists
    if git_worktree_exists?(worktree_path)
      puts "Worktree already exists at: #{worktree_path}"
      config_name = create_worktree_config(project_name, worktree_dir_name, worktree_path, branch_name)
      puts "Launching #{config_name}..."
      launch([config_name])
      return
    end

    # Fetch and check for branch
    puts "Fetching remote branches..."
    if git_branch_exists?(branch_name)
      puts "Branch '#{branch_name}' exists."
    else
      # Fuzzy match against remote branches
      matches = git_find_matching_branches(branch_name)
      if matches.any?
        if matches.size == 1 && matches.first == branch_name
          branch_name = matches.first
          puts "Found exact remote match: #{branch_name}"
        else
          selected = prompt_branch_selection(matches, branch_name)
          if selected
            branch_name = selected
            worktree_dir_name = sanitize_for_filesystem(branch_name)
            worktree_path = File.join(root, ".worktrees", worktree_dir_name)
            puts "Using branch: #{branch_name}"
          else
            base = prompt_base_branch
            unless base
              puts "Cancelled."
              return
            end
            puts "Will create '#{branch_name}' from '#{base}'"
          end
        end
      else
        # No matches at all
        base = prompt_base_branch
        unless base
          puts "Cancelled."
          return
        end
        puts "Will create '#{branch_name}' from '#{base}'"
      end
    end

    # Create .worktrees directory
    worktrees_dir = File.join(root, ".worktrees")
    Dir.mkdir(worktrees_dir) unless File.directory?(worktrees_dir)

    # Create the worktree
    base_branch = defined?(base) ? base : nil
    GIT.create_worktree(worktree_path, branch_name, base: base_branch)
    puts "Worktree created at: #{worktree_path}"

    # Ensure .worktrees is in .gitignore
    gitignore = File.join(root, ".gitignore")
    if File.exist?(gitignore)
      unless File.read(gitignore).include?(".worktrees")
        File.open(gitignore, "a") { |f| f.puts ".worktrees" }
        puts "Added .worktrees to .gitignore"
      end
    end

    # Create tmuxinator config and launch
    config_name = create_worktree_config(project_name, worktree_dir_name, worktree_path, branch_name)
    puts "Launching #{config_name}..."
    launch([config_name])
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
