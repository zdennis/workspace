require "optparse"
require "open3"
require "json"
require "fileutils"
require_relative "workspace/config"
require_relative "workspace/state"

# Workspace CLI for managing tmuxinator-based development workspaces in iTerm2.
#
# All methods are module functions, callable as Workspace.method_name.
# This is a temporary scaffolding approach -- later phases will extract
# these into proper classes.
module Workspace
  module_function

  CONFIG = Config.new

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

  # Resolve a project argument: if it looks like a path (contains / or is .),
  # expand it and derive the project name from the directory name.
  # Returns [project_name, project_root] or [arg, nil] if it's just a name.
  def resolve_project_arg(arg)
    if arg == "." || arg.include?("/") || File.directory?(arg)
      root = File.expand_path(arg)
      name = File.basename(root)
      [name, root]
    else
      [arg, nil]
    end
  end

  # Create a tmuxinator config from the template. Returns the project name.
  def create_project_config(name, root)
    config_path = File.join(TMUXINATOR_DIR, "#{name}.yml")
    if File.exist?(config_path)
      puts "Config already exists: #{config_path}"
      return name
    end

    unless File.exist?(TMUXINATOR_TEMPLATE)
      warn "Error: Template not found: #{TMUXINATOR_TEMPLATE}"
      exit 1
    end

    template = File.read(TMUXINATOR_TEMPLATE)
    content = template
      .gsub("{{PROJECT_NAME}}", name)
      .gsub("{{PROJECT_ROOT}}", root)
      .gsub("{{CONFIG_PATH}}", config_path)

    File.write(config_path, content)
    puts "Created config: #{config_path}"
    name
  end

  # Read the tmux session name from a tmuxinator config file.
  # The config filename (minus .yml) may differ from the tmux session name
  # (e.g., worktree configs use abbreviated names for tmux).
  def tmux_session_name_for(config_name)
    config_path = File.join(TMUXINATOR_DIR, "#{config_name}.yml")
    return config_name unless File.exist?(config_path)
    File.readlines(config_path).each do |line|
      if line.match?(/^name:\s/)
        return line.split(/\s+/, 2).last.strip
      end
    end
    config_name
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
    output, _ = Open3.capture2(WINDOW_TOOL, "list")
    output.lines.map { |line| line.strip.split("\t", 4) }
  end

  # Returns a hash of { unique_id => window_id } for all iTerm sessions
  def iterm_session_map
    script = <<~APPLESCRIPT
      tell application "iTerm2"
        set output to ""
        repeat with w in every window
          set wid to id of w
          repeat with t in every tab of w
            repeat with s in every session of t
              set output to output & unique ID of s & "\\t" & wid & "\\n"
            end repeat
          end repeat
        end repeat
        return output
      end tell
    APPLESCRIPT
    output = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
    result = {}
    output.each_line do |line|
      uid, wid = line.strip.split("\t")
      result[uid] = wid if uid && wid
    end
    result
  end

  # Find which tracked sessions still exist in iTerm
  def find_existing_sessions(state)
    return {} if state.empty?
    live_sessions = iterm_session_map
    existing = {}
    state.each do |project, info|
      uid = info["unique_id"]
      if uid && live_sessions.key?(uid)
        existing[project] = uid
      end
    end
    existing
  end

  # Find the launcher window ID by checking which window contains tracked sessions
  def find_launcher_window_id(state)
    live_sessions = iterm_session_map
    state.each do |_project, info|
      uid = info["unique_id"]
      next unless uid
      wid = live_sessions[uid]
      return wid if wid
    end
    nil
  end

  # Create new launcher panes for projects, returning { project => unique_id }
  # Reuses an existing launcher window if one exists, otherwise creates a new one.
  def create_launcher_panes(projects, state: {}, reattach: false)
    return {} if projects.empty?

    commands = projects.map { |p| [p, tmux_command_for(p, reattach: reattach)] }.to_h

    # Check if there's an existing launcher window we can add panes to
    launcher_wid = find_launcher_window_id(state)

    panes = {}
    if launcher_wid
      # Use keystrokes to split panes in the existing launcher window.
      # This avoids the tmux -CC integration dialog that AppleScript's
      # split command triggers on tmux -CC sessions.
      projects.each_with_index do |project, i|
        sleep 1 if i > 0
        script = <<~APPLESCRIPT
          tell application "iTerm2"
            activate
            set targetWindow to window id #{launcher_wid}
            select targetWindow

            -- Send Cmd+Shift+D to split horizontally
            tell application "System Events"
              tell process "iTerm2"
                keystroke "d" using {shift down, command down}
              end tell
            end tell

            delay 0.5

            -- The new split pane is now the current session
            tell current session of targetWindow
              write text "#{commands[project]}"
              return unique ID
            end tell
          end tell
        APPLESCRIPT
        uid = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
        panes[project] = uid unless uid.empty?
      end
    else
      # No existing launcher window — create a new one
      first, *rest = projects
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          set output to ""
          set launcherWindow to (create window with default profile)
          tell current session of launcherWindow
            write text "#{commands[first]}"
            set output to output & unique ID of (current session of launcherWindow) & "\\t" & "#{first}" & "\\n"
      APPLESCRIPT

      rest.each_with_index do |project, i|
        script += <<~APPLESCRIPT
          delay 1
          set newSession#{i} to split horizontally with default profile
          tell newSession#{i}
            write text "#{commands[project]}"
          end tell
          set output to output & unique ID of newSession#{i} & "\\t" & "#{project}" & "\\n"
        APPLESCRIPT
      end

      script += <<~APPLESCRIPT
          end tell
        end tell
      APPLESCRIPT

      output = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
      output.each_line do |line|
        uid, proj = line.strip.split("\t")
        panes[proj] = uid if uid && proj
      end
    end
    panes
  end

  # Send tmuxinator command to an existing session
  def relaunch_in_session(unique_id, project, reattach: false)
    cmd = tmux_command_for(project, reattach: reattach)
    script = <<~APPLESCRIPT
      tell application "iTerm2"
        repeat with w in every window
          repeat with t in every tab of w
            repeat with s in every session of t
              if unique ID of s is "#{unique_id}" then
                tell s
                  write text "#{cmd}"
                end tell
                return "ok"
              end if
            end repeat
          end repeat
        end repeat
        return "not_found"
      end tell
    APPLESCRIPT
    `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
  end

  def tmux_sessions
    `tmux list-sessions -F '\#{session_name}' 2>/dev/null`.strip.lines.map(&:strip)
  end

  def tmux_command_for(project, reattach: false)
    if reattach && tmux_sessions.include?(project)
      "tmux -CC attach -t #{project}"
    else
      "tmuxinator start #{project} --attach"
    end
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

    missing = projects.reject { |p| File.exist?(File.join(TMUXINATOR_DIR, "#{p}.yml")) }
    unless missing.empty?
      warn "Error: No tmuxinator config found for:"
      missing.each { |name| warn "  - #{name} (expected #{TMUXINATOR_DIR}/#{name}.yml)" }
      exit 1
    end

    # Step 1: Ensure the tmux server is running
    system("tmux", "start-server")

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
      existing_tmux = `tmux list-sessions -F '\#{session_name}' 2>/dev/null`.strip.lines.map(&:strip)
      projects.each do |project|
        next if sessions_ready.include?(project)
        tmux_name = session_names[project]
        if existing_tmux.include?(tmux_name)
          system("tmux", "rename-window", "-t", "#{tmux_name}:0", "#{window_prefix}-#{tmux_name}")
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
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          try
            set w to window id #{saved_id}
            return "ok"
          on error
            return "not_found"
          end try
        end tell
      APPLESCRIPT
      result = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
      if result == "ok"
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
        script = <<~APPLESCRIPT
          tell application "iTerm2"
            repeat with w in every window
              if name of w contains "#{title_to_find}" then
                return id of w as string
              end if
            end repeat
            return "not_found"
          end tell
        APPLESCRIPT
        result = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
        if result != "not_found"
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
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          set targetWindow to window id #{window_id}
          set bounds of targetWindow to {#{x_pos}, #{y_pos}, #{x_pos + window_width}, #{y_pos + window_height}}
        end tell
      APPLESCRIPT
      system("osascript", "-e", script)
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

    # If no saved window ID, try a live search:
    # 1. Check window titles for workspace-$project or $project
    # 2. Check pane/session names within each window for workspace-$project,
    #    [$project], or $project (like worktree-iterm does)
    unless window_id
      window_prefix = "workspace"
      title_to_find = "#{window_prefix}-#{project}"
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          -- First pass: window titles matching workspace-prefixed name
          repeat with w in every window
            if name of w contains "#{title_to_find}" then
              return id of w as string
            end if
          end repeat
          -- Second pass: pane/session names matching workspace-prefixed name or [project]
          repeat with w in every window
            repeat with t in every tab of w
              repeat with s in every session of t
                set sName to name of s
                if sName contains "#{title_to_find}" or sName contains "[#{project}]" then
                  return id of w as string
                end if
              end repeat
            end repeat
          end repeat
          return "not_found"
        end tell
      APPLESCRIPT
      result = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
      if result != "not_found"
        window_id = result.to_i
        # Save it for next time
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

    script = <<~APPLESCRIPT
      tell application "iTerm2"
        try
          set targetWindow to window id #{window_id}
        on error
          return "not_found"
        end try
        activate
        select targetWindow

        -- shake
        tell targetWindow
          set winBounds to bounds
          set curX to item 1 of winBounds
          set curY to item 2 of winBounds
          set winWidth to (item 3 of winBounds) - curX
          set winHeight to (item 4 of winBounds) - curY
          set shakeOffset to 12
          repeat 6 times
            set bounds to {curX + shakeOffset, curY, curX + winWidth + shakeOffset, curY + winHeight}
            delay 0.04
            set bounds to {curX - shakeOffset, curY, curX + winWidth - shakeOffset, curY + winHeight}
            delay 0.04
          end repeat
          set bounds to {curX, curY, curX + winWidth, curY + winHeight}
        end tell
        return "ok"
      end tell
    APPLESCRIPT

    puts "Focusing #{project}..."
    result = `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
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
        system("tmux", "kill-session", "-t", project)
      end
    end

    # Close launcher windows only if all their tracked projects are being killed
    launcher_window_ids_to_close.each do |wid|
      puts "Closing launcher window #{wid}"
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          try
            close (window id #{wid})
          end try
        end tell
      APPLESCRIPT
      system("osascript", "-e", script)
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

    Dir.glob(File.join(TMUXINATOR_DIR, "*.yml"))
      .map { |f| File.basename(f, ".yml") }
      .reject { |n| n.match?(/^project-.*template$/) }
      .sort
      .each { |name| puts name }
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
    name.gsub(%r{[/\\:*?"<>|]}, "-").gsub(/-{2,}/, "-").gsub(/^-|-$/, "")
  end

  def git_root
    root = `git rev-parse --show-toplevel 2>/dev/null`.strip
    root.empty? ? nil : root
  end

  def git_default_branch
    # Try origin/HEAD first, fall back to main/master
    ref = `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.strip
    return ref.sub("refs/remotes/origin/", "") unless ref.empty?
    `git rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 && echo main || echo master`.strip
  end

  def git_current_branch
    `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
  end

  def git_branch_exists?(name)
    system("git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}") ||
      system("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{name}")
  end

  def git_local_branch_exists?(name)
    system("git", "show-ref", "--verify", "--quiet", "refs/heads/#{name}")
  end

  def git_remote_branch_exists?(name)
    system("git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{name}")
  end

  def git_fetch_remote_branches
    `git fetch --prune 2>/dev/null`
    `git branch -r 2>/dev/null`.lines.map { |l| l.strip.sub("origin/", "") }.reject { |b| b.include?("->") }
  end

  def git_find_matching_branches(pattern)
    remote_branches = git_fetch_remote_branches
    # Exact match first
    exact = remote_branches.select { |b| b == pattern }
    return exact unless exact.empty?

    # Contains match
    contains = remote_branches.select { |b| b.include?(pattern) }
    return contains unless contains.empty?

    # Case-insensitive contains
    remote_branches.select { |b| b.downcase.include?(pattern.downcase) }
  end

  def git_worktree_exists?(path)
    worktrees = `git worktree list --porcelain 2>/dev/null`
    worktrees.include?("worktree #{path}")
  end

  def parse_start_input(input)
    # JIRA URL: https://mycompany.atlassian.net/browse/PROJ-123
    if input.match?(%r{https?://.*atlassian\.net/browse/([A-Z]+-\d+)})
      key = input.match(%r{/browse/([A-Z]+-\d+)})[1]
      return {type: :jira_key, value: key}
    end

    # GitHub PR URL: https://github.com/owner/repo/pull/123
    if input.match?(%r{https?://github\.com/.+/.+/pull/\d+})
      return {type: :pr_url, value: input}
    end

    # JIRA key: PROJ-123
    if input.match?(/\A[A-Z]+-\d+\z/)
      return {type: :jira_key, value: input}
    end

    # Branch name: anything else
    {type: :branch, value: input}
  end

  def resolve_branch_from_pr(pr_url)
    # Extract owner/repo and PR number
    match = pr_url.match(%r{github\.com/([^/]+/[^/]+)/pull/(\d+)})
    unless match
      warn "Error: Could not parse PR URL: #{pr_url}"
      exit 1
    end
    repo = match[1]
    pr_number = match[2]

    output = `gh pr view #{pr_number} --repo #{repo} --json headRefName --jq .headRefName 2>/dev/null`.strip
    if output.empty?
      warn "Error: Could not fetch PR ##{pr_number} from #{repo}"
      warn "Make sure you have access and `gh` is authenticated."
      exit 1
    end
    output
  end

  def prompt_branch_selection(matches, pattern)
    puts ""
    puts "Multiple remote branches match '#{pattern}':"
    puts ""
    matches.each_with_index do |branch, i|
      puts "  #{i + 1}) #{branch}"
    end
    puts "  0) None — create a new branch instead"
    puts ""
    print "Choose [1-#{matches.size}, 0]: "
    choice = $stdin.gets&.strip&.to_i
    if choice && choice > 0 && choice <= matches.size
      matches[choice - 1]
    end
  end

  def prompt_base_branch
    default_branch = git_default_branch
    current = git_current_branch

    if current == default_branch
      return default_branch
    end

    puts ""
    puts "Branch does not exist. Create from:"
    puts ""
    puts "  1) #{default_branch} (default branch)"
    puts "  2) #{current} (current branch)"
    puts "  3) Cancel"
    puts ""
    print "Choose [1/2/3]: "
    choice = $stdin.gets&.strip
    case choice
    when "1", ""
      default_branch
    when "2"
      current
    end
  end

  def create_worktree_config(project_name, worktree_name, worktree_path, branch_name)
    # tmux session names can't have dots, so sanitize
    tmux_session_name = "#{project_name}.wt-#{sanitize_for_filesystem(worktree_name)}"
      .tr(".", "-")
    config_name = "#{project_name}.worktree-#{sanitize_for_filesystem(worktree_name)}"
    config_path = File.join(TMUXINATOR_DIR, "#{config_name}.yml")

    if File.exist?(config_path)
      puts "Config already exists: #{config_path}"
      return config_name
    end

    unless File.exist?(TMUXINATOR_WORKTREE_TEMPLATE)
      warn "Error: Worktree template not found: #{TMUXINATOR_WORKTREE_TEMPLATE}"
      exit 1
    end

    template = File.read(TMUXINATOR_WORKTREE_TEMPLATE)
    content = template
      .gsub("{{TMUX_SESSION_NAME}}", tmux_session_name)
      .gsub("{{WORKTREE_PATH}}", worktree_path)
      .gsub("{{PROJECT_NAME}}", project_name)
      .gsub("{{WORKTREE_BRANCH}}", branch_name)
      .gsub("{{DISPLAY_NAME}}", "#{project_name}/#{worktree_name}")
      .gsub("{{CONFIG_PATH}}", config_path)

    File.write(config_path, content)
    puts "Created config: #{config_path}"
    config_name
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

    # Build and run git worktree add command
    cmd = ["git", "worktree", "add"]
    if git_branch_exists?(branch_name)
      cmd += [worktree_path, branch_name]
    else
      cmd += ["-b", branch_name, worktree_path]
      cmd << base if defined?(base) && base
    end

    puts "Running: #{cmd.join(" ")}"
    _, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      warn "Error creating worktree: #{stderr}"
      exit 1
    end
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

  def check_command(name, version_flag: "--version", version_pattern: /(\d+)/, min_major: nil, install_hint: nil)
    path = `which #{name} 2>/dev/null`.strip
    if path.empty?
      return {found: false, install_hint: install_hint}
    end

    version_str = nil
    major = nil
    if version_flag
      output = `#{name} #{version_flag} 2>/dev/null`.strip
      match = output.match(version_pattern)
      if match
        major = match[1].to_i
        version_str = "#{major}+"
      end
    end

    if min_major && major && major < min_major
      return {found: true, version: version_str, outdated: true, min_version: "#{min_major}+", install_hint: install_hint}
    end

    {found: true, version: version_str}
  end

  def check_app(name, bundle_id:, install_hint:)
    result = `mdfind "kMDItemCFBundleIdentifier == '#{bundle_id}'" 2>/dev/null`.strip
    if result.empty?
      {found: false, install_hint: install_hint}
    else
      {found: true}
    end
  end

  def doctor(args)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: workspace doctor"
      opts.separator ""
      opts.separator "Check that all required dependencies are installed and configured."
    end
    parser.parse!(args)

    puts "workspace doctor"
    puts ""

    issues = 0

    checks = [
      {
        name: "ruby",
        check: -> { check_command("ruby", version_pattern: /(\d+)/, min_major: 3, install_hint: "Install via rbenv, asdf, or https://www.ruby-lang.org/en/downloads/") }
      },
      {
        name: "tmux",
        check: -> { check_command("tmux", version_flag: "-V", version_pattern: /(\d+)/, min_major: 3, install_hint: "brew install tmux") }
      },
      {
        name: "tmuxinator",
        check: -> { check_command("tmuxinator", version_flag: "version", version_pattern: /(\d+)/, install_hint: "brew install tmuxinator") }
      },
      {
        name: "iTerm2",
        check: -> { check_app("iTerm2", bundle_id: "com.googlecode.iterm2", install_hint: "https://iterm2.com/") }
      },
      {
        name: "window-tool",
        check: -> { check_command("window-tool", version_flag: nil, install_hint: "https://github.com/zdennis/window-tool") }
      },
      {
        name: "git",
        check: -> { check_command("git", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install git") }
      },
      {
        name: "gh",
        check: -> { check_command("gh", version_pattern: /(\d+)/, min_major: 2, install_hint: "brew install gh") }
      },
      {
        name: "ascii-banner",
        check: -> { check_command("ascii-banner", version_flag: nil, install_hint: "https://github.com/zdennis/homebrew-bin/blob/main/docs/README.ascii-banner.md") }
      }
    ]

    checks.each do |entry|
      result = entry[:check].call
      if result[:found]
        if result[:outdated]
          puts "  ✗  #{entry[:name]} (found #{result[:version]}, need #{result[:min_version]})"
          puts "     ↳ install: #{result[:install_hint]}"
          issues += 1
        elsif result[:version]
          puts "  ✓  #{entry[:name]} (#{result[:version]})"
        else
          puts "  ✓  #{entry[:name]}"
        end
      else
        puts "  ✗  #{entry[:name]} (not found)"
        puts "     ↳ install: #{result[:install_hint]}"
        issues += 1
      end
    end

    # Check templates
    templates = ["project-template.yml", "project-worktree-template.yml"]
    all_installed = templates.all? { |t| File.exist?(File.join(TMUXINATOR_DIR, t)) }

    if all_installed
      puts "  ✓  templates installed"
    else
      missing = templates.reject { |t| File.exist?(File.join(TMUXINATOR_DIR, t)) }
      puts "  ✗  templates (missing: #{missing.join(", ")})"
      puts "     ↳ fix: run 'workspace init' to install them"
      issues += 1
    end

    puts ""
    if issues > 0
      puts "#{issues} issue(s) found."
      exit 1
    else
      puts "Everything looks good!"
    end
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
