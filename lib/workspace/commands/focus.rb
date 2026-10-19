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
      # @param window_liveness [Workspace::WindowLiveness, nil] tells which tracked windows iTerm still has; needed for `cycle`
      # @param output [IO] output stream for user-facing messages
      def initialize(state:, window_manager:, tmux: nil, pane_locator: nil, window_liveness: nil, output: $stdout)
        @state = state
        @window_manager = window_manager
        @tmux = tmux
        @pane_locator = pane_locator
        @window_liveness = window_liveness
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
      # @raise [Workspace::Error] `no_window` if none is recorded, `window_gone` if iTerm no longer has it,
      #   or the project runs headless;
      #   for +pane+, the {Workspace::PaneLocator} codes, or `focus_failed` when tmux
      #   couldn't select it (the window is already in front)
      def call(project, shake: false, highlight: nil, pane: nil)
        @state.load
        raise Workspace::Error, Focus.headless_message(project, @tmux) if @state.dig(project, "headless")
        located = pane && locate_pane(project, pane)
        window_id = @state.dig(project, "iterm_window_id")

        unless window_id && window_id != 0
          raise Workspace::Error.new(
            "No iTerm window found for '#{project}'\n" \
            "Run 'workspace launch #{project}' first, or 'workspace status' to see tracked projects.",
            code: "no_window", details: {"workspace" => project}
          )
        end

        @output.puts(located ? "Focusing #{project}, pane #{located[:id]}..." : "Focusing #{project}...")
        unless @window_manager.focus_by_id(window_id, highlight: highlight)
          raise Workspace::Error.new(
            "iTerm window #{window_id} no longer exists for '#{project}'\n" \
            "Run 'workspace launch #{project}' to relaunch.",
            code: "window_gone", details: {"workspace" => project, "iterm_window_id" => window_id}
          )
        end

        @window_manager.shake_by_id(window_id) if shake
        select_pane(project, located) if located
        located && located[:id]
      end

      # Focuses the next tracked project (by name) that has a live iTerm window
      # after the one in front, wrapping around. With none of them in front,
      # starts from the first (the last with +reverse+).
      #
      # @param reverse [Boolean] go to the previous project instead
      # @param shake [Boolean]
      # @param highlight [String, nil]
      # @return [String] the project focused
      # @raise [Workspace::Error] `no_windows_to_cycle` when no tracked project has a live window;
      #   otherwise the codes of {#call}
      def cycle(reverse: false, shake: false, highlight: nil)
        @state.load
        raise Workspace::Error, "focus --cycle is not available in this build" unless @window_liveness
        live = @window_liveness.call(@state.to_h)
        names = live.select { |_, alive| alive }.keys.sort
        if names.empty?
          raise Workspace::Error.new(
            "No tracked workspace has a live iTerm window to cycle to.\n" \
            "Run 'workspace launch PROJECT' first, or 'workspace status' to see tracked projects.",
            code: "no_windows_to_cycle", details: {}
          )
        end
        names.reverse! if reverse
        current = front_project(names)
        target = current ? names[(names.index(current) + 1) % names.size] : names.first
        call(target, shake: shake, highlight: highlight)
        target
      end

      private

      def front_project(names)
        by_window = names.to_h { |name| [@state.dig(name, "iterm_window_id").to_i, name] }
        @window_manager.window_ids_front_to_back.each do |id|
          return by_window[id] if by_window.key?(id)
        end
        nil
      rescue Workspace::Error
        nil
      end

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
