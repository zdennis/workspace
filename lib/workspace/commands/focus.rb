module Workspace
  module Commands
    # Brings a project's iTerm window to the front, optionally shaking or highlighting it.
    class Focus
      # Why an iTerm-only command can't act on a headless project, and how to
      # reach its session instead.
      #
      # @param project [String]
      # @param tmux [Workspace::Tmux, nil] names the tmux session, when given
      # @return [String]
      def self.headless_message(project, tmux)
        session = tmux ? tmux.session_name_for(project) : project
        "'#{project}' runs headless, so it has no iTerm window.\n" \
          "Attach to its tmux session instead: tmux attach -t #{session}"
      end

      # @param state [Workspace::State] state persistence
      # @param window_manager [Workspace::WindowManager] iTerm window operations
      # @param tmux [Workspace::Tmux, nil] names a headless project's tmux session in the error
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, tmux: nil, output: $stdout)
        @state = state
        @window_manager = window_manager
        @tmux = tmux
        @output = output
      end

      # Focuses the given project's iTerm window, optionally shaking or highlighting it.
      #
      # @param project [String] project name
      # @param shake [Boolean] whether to shake the window after focusing
      # @param highlight [String, nil] color to highlight the window, or nil to skip
      # @return [void]
      # @raise [Workspace::Error] if no window is found, or the project runs headless
      def call(project, shake: false, highlight: nil)
        @state.load
        raise Workspace::Error, Focus.headless_message(project, @tmux) if @state.dig(project, "headless")
        window_id = @state.dig(project, "iterm_window_id")

        unless window_id && window_id != 0
          raise Workspace::Error,
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
        end

        @output.puts "Focusing #{project}..."
        unless @window_manager.focus_by_id(window_id, highlight: highlight)
          raise Workspace::Error,
            "iTerm window #{window_id} no longer exists for '#{project}'\n" \
            "Run 'workspace launch #{project}' to relaunch."
        end

        @window_manager.shake_by_id(window_id) if shake
      end
    end
  end
end
