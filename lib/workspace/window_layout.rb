require "open3"
require "json"

module Workspace
  # Calculates and applies window positions for arranging project windows
  # across the active screen.
  class WindowLayout
    # @param window_manager [Workspace::WindowManager] window operations for setting bounds
    # @param config [Workspace::Config] configuration for window_tool path
    # @param output [IO] output stream for user-facing messages
    # @param logger [Workspace::Logger] debug logger
    def initialize(window_manager:, config:, output: $stdout, logger: Workspace::Logger.new)
      @window_manager = window_manager
      @config = config
      @output = output
      @logger = logger
    end

    # Arranges project windows left-to-right on the active screen.
    #
    # @param project_window_ids [Array<Hash>] array of {project:, window_id:} hashes
    # @return [void]
    def arrange(project_window_ids)
      apply_layout(project_window_ids, method(:calculate_positions), "Positioned")
    end

    # Tiles project windows side-by-side, preserving current sizes.
    # Only shrinks windows proportionally if they wouldn't all fit on screen.
    # A single window is focused without resizing.
    #
    # @param project_window_ids [Array<Hash>] array of {project:, window_id:} hashes
    # @return [void]
    def tile(project_window_ids)
      return if project_window_ids.empty?

      if project_window_ids.size == 1
        @output.puts "  Tiled #{project_window_ids.first[:project]} (single window, no resize)"
        return
      end

      screen_json, status = Open3.capture2(@config.window_tool, "active-screen", "--json")
      unless status.success?
        raise Workspace::Error, "Could not detect screen geometry. Is window-tool installed?"
      end
      screen = JSON.parse(screen_json)
      screen_x, screen_y, screen_w, screen_h = screen.values_at("x", "y", "width", "height")

      window_ids = project_window_ids.map { |e| e[:window_id] }
      bounds_map = @window_manager.all_window_bounds(window_ids)
      default_bounds = {x: 0, y: 0, width: 400, height: 600}
      current_bounds = project_window_ids.map { |entry|
        bounds_map[entry[:window_id].to_i] || default_bounds
      }

      positions = calculate_tile_positions(
        screen_x: screen_x, screen_y: screen_y,
        screen_w: screen_w, screen_h: screen_h,
        current_bounds: current_bounds
      )

      project_window_ids.each_with_index do |entry, i|
        pos = positions[i]
        @window_manager.set_window_bounds(entry[:window_id], pos[:x], pos[:y], pos[:width], pos[:height])
        @output.puts "  Tiled #{entry[:project]} at #{pos[:x]},#{pos[:y]} (#{pos[:width]}x#{pos[:height]})"
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

    # Pure math: calculates tiled positions preserving current window sizes.
    # Windows are arranged left-to-right. If the total width exceeds the screen,
    # all windows are shrunk proportionally to fit.
    #
    # @param screen_x [Integer] screen x offset
    # @param screen_y [Integer] screen y offset
    # @param screen_w [Integer] screen width
    # @param screen_h [Integer] screen height
    # @param current_bounds [Array<Hash>] array of {x:, y:, width:, height:} for each window
    # @return [Array<Hash>] array of {x:, y:, width:, height:} hashes
    def calculate_tile_positions(screen_x:, screen_y:, screen_w:, screen_h:, current_bounds:)
      return [] if current_bounds.empty?

      widths = current_bounds.map { |b| b[:width] }
      heights = current_bounds.map { |b| b[:height] }
      total_width = widths.sum

      if total_width > screen_w
        scale = screen_w.to_f / total_width
        widths = widths.map { |w| (w * scale).to_i }
        heights = heights.map { |h| (h * scale).to_i }
      end

      x_cursor = screen_x
      current_bounds.each_with_index.map do |_, i|
        pos = {
          x: x_cursor,
          y: screen_y + ((screen_h - heights[i]) / 2).to_i,
          width: widths[i],
          height: heights[i]
        }
        x_cursor += widths[i]
        pos
      end
    end

    private

    def apply_layout(project_window_ids, calculator, verb)
      return if project_window_ids.empty?

      @logger.debug { "window_layout: fetching active screen geometry" }
      screen_json, status = Open3.capture2(@config.window_tool, "active-screen", "--json")
      unless status.success?
        raise Workspace::Error, "Could not detect screen geometry. Is window-tool installed?"
      end
      screen = JSON.parse(screen_json)
      @logger.debug { "window_layout: screen geometry #{screen.inspect}" }
      screen_x, screen_y, screen_w, screen_h = screen.values_at("x", "y", "width", "height")

      positions = calculator.call(
        screen_x: screen_x, screen_y: screen_y,
        screen_w: screen_w, screen_h: screen_h,
        count: project_window_ids.size
      )

      project_window_ids.each_with_index do |entry, i|
        pos = positions[i]
        @window_manager.set_window_bounds(entry[:window_id], pos[:x], pos[:y], pos[:width], pos[:height])
        @output.puts "  #{verb} #{entry[:project]} at #{pos[:x]},#{pos[:y]} (#{pos[:width]}x#{pos[:height]})"
      end
    end
  end
end
