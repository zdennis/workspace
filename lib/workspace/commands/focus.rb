module Workspace
  module Commands
    # Brings a project's iTerm window to the front and shakes it.
    # Looks up saved window IDs from state, falls back to live search.
    class Focus
      # @param state [Workspace::State] state persistence
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, output: $stdout)
        @state = state
        @window_manager = window_manager
        @output = output
      end

      # Focuses the given project's iTerm window and shakes it.
      #
      # @param project [String] project name
      # @return [void]
      # @raise [Workspace::Error] if no window is found or it has disappeared
      def call(project)
        @state.load
        window_id = @state.dig(project, "iterm_window_id")

        unless window_id
          result = @window_manager.find_window_for_project(project)
          if result
            window_id = result.to_i
            @state[project] = (@state[project] || {}).merge("iterm_window_id" => window_id)
            @state.save
          end
        end

        unless window_id
          raise Workspace::Error,
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
        end

        @output.puts "Focusing #{project}..."
        result = @window_manager.focus_and_shake(window_id)
        if result == "not_found"
          raise Workspace::Error,
            "iTerm window #{window_id} no longer exists for '#{project}'\n" \
            "Run 'workspace launch #{project}' to relaunch."
        end
      end
    end
  end
end
