require "open3"

module Workspace
  # Manages iTerm2 window operations: finding, focusing, positioning, and closing windows.
  # Separated from session/pane lifecycle (handled by ITerm).
  class WindowManager
    # @param config [Workspace::Config] configuration for window_tool path
    # @param logger [Workspace::Logger] debug logger
    def initialize(config:, logger: Workspace::Logger.new)
      @config = config
      @logger = logger
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
            if name of w = "#{title}" then
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
            if name of w = "#{title_to_find}" then
              return id of w as string
            end if
          end repeat
          -- Second pass: pane/session names matching workspace-prefixed name or [project]
          repeat with w in every window
            repeat with t in every tab of w
              repeat with s in every session of t
                set sName to name of s
                if sName = "#{title_to_find}" or sName = "[#{project}]" then
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

    # @param window_id [String, Integer] window ID (CGWindowID)
    # @param highlight [String, nil] color to highlight the window after focusing
    # @return [Boolean] whether the window was focused
    def focus_by_id(window_id, highlight: nil)
      args = [@config.window_tool, "focus", "id=#{window_id}"]
      if highlight
        args += ["+", "highlight", "id=#{window_id}", "--color", highlight]
      end
      @logger.debug { "window_manager: focus #{args.join(" ")}" }
      _, _, status = Open3.capture3(*args)
      @logger.debug { "window_manager: focus result=#{status.success?}" }
      status.success?
    end

    # @param window_id [String, Integer] window ID (CGWindowID)
    # @return [Boolean] whether the window was shaken
    def shake_by_id(window_id)
      _, _, status = Open3.capture3(@config.window_tool, "shake", "id=#{window_id}")
      status.success?
    end

    # @return [Set<Integer>] set of window IDs for all current iTerm windows
    # @raise [Workspace::Error] if window-tool fails
    def live_window_ids
      require "json"
      @logger.debug { "window_manager: listing live window IDs" }
      output, _, status = Open3.capture3(@config.window_tool, "list", "--json")
      unless status.success?
        raise Workspace::Error, "window-tool list failed. Is window-tool installed?"
      end
      windows = JSON.parse(output)
      ids = Set.new(windows.map { |w| w["window_id"].to_i })
      @logger.debug { "window_manager: found #{ids.size} live window(s)" }
      ids
    end

    # Returns the current bounds for all requested windows in a single call.
    #
    # @param window_ids [Array<Integer, String>] window IDs to look up
    # @return [Hash<Integer, Hash>] map of window_id => {x:, y:, width:, height:}
    def all_window_bounds(window_ids)
      require "json"
      output, _, status = Open3.capture3(@config.window_tool, "list", "--json")
      return {} unless status.success?

      windows = JSON.parse(output)
      id_set = Set.new(window_ids.map(&:to_i))
      result = {}
      windows.each do |w|
        wid = w["window_id"].to_i
        if id_set.include?(wid)
          result[wid] = {x: w["x"], y: w["y"], width: w["width"], height: w["height"]}
        end
      end
      result
    end

    # @param window_id [String, Integer] window ID (CGWindowID)
    # @param x [Integer] x position
    # @param y [Integer] y position
    # @param width [Integer] window width
    # @param height [Integer] window height
    # @return [void]
    def set_window_bounds(window_id, x, y, width, height)
      @logger.debug { "window_manager: move id=#{window_id} to #{x},#{y} #{width}x#{height}" }
      system(@config.window_tool, "move", "id=#{window_id}", x.to_s, y.to_s, width.to_s, height.to_s)
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
      @logger.debug { "window_manager: executing AppleScript (#{script.lines.first&.strip}...)" }
      stdout, _ = Open3.capture3("osascript", "-e", script)
      @logger.debug { "window_manager: AppleScript result=#{stdout.strip.inspect}" }
      stdout.strip
    end
  end
end
