require "open3"

module Workspace
  # Calculates and applies window positions for arranging project windows
  # across the active screen.
  class WindowLayout
    # @param window_manager [Workspace::WindowManager] window operations for setting bounds
    # @param config [Workspace::Config] configuration for window_tool path
    # @param output [IO] output stream for user-facing messages
    def initialize(window_manager:, config:, output: $stdout)
      @window_manager = window_manager
      @config = config
      @output = output
    end

    # Arranges project windows left-to-right on the active screen.
    #
    # @param project_window_ids [Array<Hash>] array of {project:, window_id:} hashes
    # @return [void]
    def arrange(project_window_ids)
      return if project_window_ids.empty?

      require "json"
      screen_json, _ = Open3.capture2(@config.window_tool, "active-screen", "--json")
      screen = JSON.parse(screen_json)
      screen_x, screen_y, screen_w, screen_h = screen.values_at("x", "y", "width", "height")

      positions = calculate_positions(
        screen_x: screen_x, screen_y: screen_y,
        screen_w: screen_w, screen_h: screen_h,
        count: project_window_ids.size
      )

      project_window_ids.each_with_index do |entry, i|
        pos = positions[i]
        @window_manager.set_window_bounds(entry[:window_id], pos[:x], pos[:y], pos[:width], pos[:height])
        @output.puts "  Positioned #{entry[:project]} at #{pos[:x]},#{pos[:y]} (#{pos[:width]}x#{pos[:height]})"
      end
    end

    # Pure math: calculates window positions for a given screen and count.
    #
    # @param screen_x [Integer] screen x offset
    # @param screen_y [Integer] screen y offset
    # @param screen_w [Integer] screen width
    # @param screen_h [Integer] screen height
    # @param count [Integer] number of windows to position
    # @return [Array<Hash>] array of {x:, y:, width:, height:} hashes
    def calculate_positions(screen_x:, screen_y:, screen_w:, screen_h:, count:)
      return [] if count == 0

      window_width = (screen_w * 0.22).to_i
      window_height = (screen_h * 0.9).to_i
      y_pos = screen_y + ((screen_h - window_height) / 2).to_i

      total_width_needed = window_width * count
      spacing = if total_width_needed > screen_w
        ((screen_w - window_width).to_f / [count - 1, 1].max).to_i
      else
        window_width
      end

      start_x = screen_x + ((screen_w - (spacing * (count - 1) + window_width)) / 2).to_i

      count.times.map do |i|
        {
          x: start_x + (spacing * i),
          y: y_pos,
          width: window_width,
          height: window_height
        }
      end
    end
  end
end
