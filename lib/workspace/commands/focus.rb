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
        title = "workspace-#{project}"

        @output.puts "Focusing #{project}..."
        unless @window_manager.focus_by_title(title)
          raise Workspace::Error,
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
        end

        @window_manager.shake_by_title(title) if shake
      end
    end
  end
end
