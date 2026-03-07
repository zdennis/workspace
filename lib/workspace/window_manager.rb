require "open3"

module Workspace
  # Manages iTerm2 window operations: finding, focusing, positioning, and closing windows.
  # Separated from session/pane lifecycle (handled by ITerm).
  class WindowManager
    # @param config [Workspace::Config] configuration for window_tool path
    def initialize(config:)
      @config = config
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

    # @return [Array<Array<String>>] parsed window-tool list output
    def window_titles
      output, _ = Open3.capture2(@config.window_tool, "list")
      output.lines.map { |line| line.strip.split("\t", 4) }
    end

    private

    # @param script [String] AppleScript code to execute
    # @return [String] stripped output from osascript
    def execute_applescript(script)
      stdout, _ = Open3.capture3("osascript", "-e", script)
      stdout.strip
    end
  end
end
