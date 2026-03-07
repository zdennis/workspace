module Workspace
  module Commands
    # Tiles all active windows for a project (base + worktrees) across the screen.
    # Windows are arranged as equal-width columns filling the full screen.
    class Tile
      # @param state [Workspace::State] state persistence
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param window_layout [Workspace::WindowLayout] window positioning
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, window_layout:, output: $stdout)
        @state = state
        @window_manager = window_manager
        @window_layout = window_layout
        @output = output
      end

      # Tiles all windows matching the given project prefix.
      #
      # @param project [String] project name prefix (matches base + worktrees)
      # @return [void]
      # @raise [Workspace::Error] if no matching windows are found
      def call(project)
        @state.load
        live_ids = @window_manager.live_window_ids

        matching = @state.keys.select { |key|
          key == project || key.start_with?("#{project}.")
        }.select { |key|
          live_ids.include?(@state.dig(key, "iterm_window_id"))
        }.sort

        if matching.empty?
          raise Workspace::Error,
            "No active windows found for '#{project}'.\n" \
            "Run 'workspace list' to see active projects."
        end

        @output.puts "Tiling #{matching.size} window(s) for #{project}..."

        entries = matching.map { |key|
          {project: key, window_id: @state.dig(key, "iterm_window_id")}
        }

        @window_layout.tile(entries)

        matching.each { |key| @window_manager.focus_by_id(@state.dig(key, "iterm_window_id")) }

        @output.puts "Done."
      end
    end
  end
end
