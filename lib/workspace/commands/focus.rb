module Workspace
  module Commands
    # Brings a project's iTerm window to the front, optionally shaking it.
    class Focus
      # @param state [Workspace::State] state persistence
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, output: $stdout)
        @state = state
        @window_manager = window_manager
        @output = output
      end

      # Focuses the given project's iTerm window, optionally shaking it.
      #
      # @param project [String] project name
      # @param shake [Boolean] whether to shake the window after focusing
      # @return [void]
      # @raise [Workspace::Error] if no window is found
      def call(project, shake: false)
        @state.load
        window_id = @state.dig(project, "iterm_window_id")

        unless window_id
          raise Workspace::Error,
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
        end

        @output.puts "Focusing #{project}..."
        unless @window_manager.focus_by_id(window_id)
          raise Workspace::Error,
            "iTerm window #{window_id} no longer exists for '#{project}'\n" \
            "Run 'workspace launch #{project}' to relaunch."
        end

        @window_manager.shake_by_id(window_id) if shake
      end
    end
  end
end
