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
      iterm_windows.key?(window_id.to_i)
    end

    # @param title [String] window title to search for (exact project name match)
    # @return [String, nil] window ID string or nil
    def find_window_by_title(title)
      pattern = /#{Regexp.escape(title)}(?=[\s\[\]]|$)/
      best_id = nil
      best_len = Float::INFINITY
      iterm_windows.each do |wid, wname|
        if wname.match?(pattern) && wname.length < best_len
          best_id = wid.to_s
          best_len = wname.length
        end
      end
      best_id
    end

    # @param project [String] project name
    # @return [String, nil] window ID string or nil
    def find_window_for_project(project)
      title_to_find = "workspace-#{project}"
      find_window_by_title(title_to_find)
    end

    # Returns all iTerm2 windows as a hash of window_id => title.
    # Uses window-tool for fast, reliable window enumeration.
    #
    # @return [Hash<Integer, String>] map of window_id => title
    def iterm_windows
      require "json"
      output, _, status = Open3.capture3(@config.window_tool, "list", "--app", "iTerm2", "--json")
      return {} unless status.success?

      windows = JSON.parse(output)
      result = {}
      windows.each do |w|
        result[w["window_id"].to_i] = w["title"].to_s
      end
      result
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
      output, _, status = Open3.capture3(@config.window_tool, "list", "--app", "iTerm2", "--json")
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
      output, _, status = Open3.capture3(@config.window_tool, "list", "--app", "iTerm2", "--json")
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
  end
end
