require "open3"

module Workspace
  # Manages iTerm2 session and pane lifecycle via AppleScript.
  # Window operations (find, focus, position, close) are handled by WindowManager.
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

    private

    # @param script [String] AppleScript code to execute
    # @return [String] stripped output from osascript
    def execute_applescript(script)
      stdout, _ = Open3.capture3("osascript", "-e", script)
      stdout.strip
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
