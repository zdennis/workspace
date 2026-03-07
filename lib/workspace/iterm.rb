require "open3"

module Workspace
  # Consolidates all iTerm2 AppleScript automation into a single class.
  # Manages session discovery, pane creation, window focusing, and bounds setting.
  class ITerm
    # @param config [Workspace::Config] configuration for window_tool path
    # @param output [IO] output stream for user-facing messages
    def initialize(config:, output: $stdout)
      @config = config
      @output = output
    end

    # @return [Hash{String => String}] mapping of unique_id to window_id for all iTerm sessions
    def session_map
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
      output = execute_applescript(script)
      result = {}
      output.each_line do |line|
        uid, wid = line.strip.split("\t")
        result[uid] = wid if uid && wid
      end
      result
    end

    # @return [Array<Array<String>>] parsed window-tool list output
    def window_titles
      output, _ = Open3.capture2(@config.window_tool, "list")
      output.lines.map { |line| line.strip.split("\t", 4) }
    end

    # @param state [#each] state object or hash with project => {"unique_id" => ...} entries
    # @param live_sessions [Hash, nil] optional pre-fetched session_map for testing
    # @return [Hash{String => String}] mapping of project name to unique_id for live sessions
    def find_existing_sessions(state, live_sessions: nil)
      return {} if state_empty?(state)
      live_sessions ||= session_map
      existing = {}
      state.each do |project, info|
        uid = info["unique_id"]
        existing[project] = uid if uid && live_sessions.key?(uid)
      end
      existing
    end

    # @param state [#each] state object or hash with project => {"unique_id" => ...} entries
    # @param live_sessions [Hash, nil] optional pre-fetched session_map for testing
    # @return [String, nil] window ID of the launcher window, or nil
    def find_launcher_window_id(state, live_sessions: nil)
      live_sessions ||= session_map
      state.each do |_project, info|
        uid = info["unique_id"]
        next unless uid
        wid = live_sessions[uid]
        return wid if wid
      end
      nil
    end

    # @param projects [Array<String>] project names to create panes for
    # @param commands [Hash{String => String}] mapping of project name to shell command
    # @param launcher_wid [String, nil] existing launcher window ID to add panes to
    # @return [Hash{String => String}] mapping of project name to unique_id
    def create_launcher_panes(projects, commands, launcher_wid: nil)
      return {} if projects.empty?

      panes = {}
      if launcher_wid
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
          uid = execute_applescript(script)
          panes[project] = uid unless uid.empty?
        end
      else
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

        output = execute_applescript(script)
        output.each_line do |line|
          uid, proj = line.strip.split("\t")
          panes[proj] = uid if uid && proj
        end
      end
      panes
    end

    # @param unique_id [String] session unique ID
    # @param command [String] shell command to send
    # @return [String] "ok" or "not_found"
    def relaunch_in_session(unique_id, command)
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          repeat with w in every window
            repeat with t in every tab of w
              repeat with s in every session of t
                if unique ID of s is "#{unique_id}" then
                  tell s
                    write text "#{command}"
                  end tell
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "not_found"
        end tell
      APPLESCRIPT
      execute_applescript(script)
    end

    # @param window_id [String, Integer] iTerm window ID
    # @return [Boolean] whether the window exists
    def window_exists?(window_id)
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          try
            set w to window id #{window_id}
            return "ok"
          on error
            return "not_found"
          end try
        end tell
      APPLESCRIPT
      execute_applescript(script) == "ok"
    end

    # @param title [String] window title to search for
    # @return [String, nil] window ID string or nil
    def find_window_by_title(title)
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          repeat with w in every window
            if name of w contains "#{title}" then
              return id of w as string
            end if
          end repeat
          return "not_found"
        end tell
      APPLESCRIPT
      result = execute_applescript(script)
      (result == "not_found") ? nil : result
    end

    # @param project [String] project name
    # @return [String, nil] window ID string or nil
    def find_window_for_project(project)
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
      result = execute_applescript(script)
      (result == "not_found") ? nil : result
    end

    # @param window_id [String, Integer] iTerm window ID
    # @return [String] "ok" or "not_found"
    def focus_and_shake(window_id)
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
      execute_applescript(script)
    end

    # @param window_id [String, Integer] iTerm window ID
    # @param x [Integer] x position
    # @param y [Integer] y position
    # @param width [Integer] window width
    # @param height [Integer] window height
    # @return [void]
    def set_window_bounds(window_id, x, y, width, height)
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          set targetWindow to window id #{window_id}
          set bounds of targetWindow to {#{x}, #{y}, #{x + width}, #{y + height}}
        end tell
      APPLESCRIPT
      system("osascript", "-e", script)
    end

    # @param window_id [String, Integer] iTerm window ID
    # @return [void]
    def close_window(window_id)
      script = <<~APPLESCRIPT
        tell application "iTerm2"
          try
            close (window id #{window_id})
          end try
        end tell
      APPLESCRIPT
      system("osascript", "-e", script)
    end

    private

    # @param script [String] AppleScript code to execute
    # @return [String] stripped output from osascript
    def execute_applescript(script)
      `osascript -e '#{script.gsub("'", "'\\''")}'`.strip
    end

    # @param state [#empty?, #each] state-like object
    # @return [Boolean]
    def state_empty?(state)
      if state.respond_to?(:empty?)
        state.empty?
      else
        false
      end
    end
  end
end
