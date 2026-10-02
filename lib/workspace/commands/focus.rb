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
      # @param tmux [Workspace::Tmux, nil] names a headless project's tmux session in the error;
      #   selects the pane for `pane:`
      # @param pane_locator [Workspace::PaneLocator, nil] validates `pane:`
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, tmux: nil, pane_locator: nil, output: $stdout)
        @state = state
        @window_manager = window_manager
        @tmux = tmux
        @pane_locator = pane_locator
        @output = output
      end

      # Focuses the given project's iTerm window, optionally shaking or highlighting it.
      #
      # @param project [String] project name
      # @param shake [Boolean] whether to shake the window after focusing
      # @param highlight [String, nil] color to highlight the window, or nil to skip
      # @param pane [String, nil] a pane id ("%19") or "window.pane" ("0.1") to select
      #   once the window is up front; checked before anything is focused
      # @return [String, nil] the selected pane's id, or nil without +pane+
      # @raise [Workspace::Error] if no window is found, or the project runs headless;
      #   for +pane+, the {Workspace::PaneLocator} codes, or `focus_failed` when tmux
      #   couldn't select it (the window is already in front)
      def call(project, shake: false, highlight: nil, pane: nil)
        @state.load
        raise Workspace::Error, Focus.headless_message(project, @tmux) if @state.dig(project, "headless")
        located = pane && locate_pane(project, pane)
        window_id = @state.dig(project, "iterm_window_id")

        unless window_id && window_id != 0
          raise Workspace::Error,
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects."
        end

        @output.puts(located ? "Focusing #{project}, pane #{located[:id]}..." : "Focusing #{project}...")
        unless @window_manager.focus_by_id(window_id, highlight: highlight)
          raise Workspace::Error,
            "iTerm window #{window_id} no longer exists for '#{project}'\n" \
            "Run 'workspace launch #{project}' to relaunch."
        end

        @window_manager.shake_by_id(window_id) if shake
        select_pane(project, located) if located
        located && located[:id]
      end

      private

      def locate_pane(project, pane)
        raise Workspace::Error, "focus --pane is not available in this build" unless @pane_locator && @tmux
        @pane_locator.locate(project, pane)
      end

      def select_pane(project, located)
        return if @tmux.select_pane(located[:session], located)
        raise Workspace::Error.new("tmux couldn't select pane #{located[:id]} of '#{project}'; its window is in front.",
          code: "focus_failed", details: {"pane" => located[:id], "workspace" => project})
      end
    end
  end
end
