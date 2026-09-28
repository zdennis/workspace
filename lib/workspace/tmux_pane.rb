module Workspace
  # Resolves a pane specification to a tmux pane index.
  #
  # Spec forms accepted:
  #   nil / :bottom / "bottom"       → last pane in the window
  #   Integer                        → zero-based pane index (validated against live panes)
  #   String matching /\A\d+\z/      → same as Integer
  #   String matching /\A\d+\.\d+\z/ → "window.pane" (as shown by `workspace sessions`/tmux); window overrides the window: kwarg
  #   String matching /\A%\d+\z/     → a tmux pane id (as shown by `workspace sessions --json`'s pane_id); searched
  #                                     across the whole session, so it resolves regardless of window
  #   Any other String               → case-insensitive title search via Tmux#find_pane_by_title
  #
  # @example
  #   TmuxPane.new("Claude Code", tmux: tmux).target("my-session")  # → "0.1"
  #   TmuxPane.new(2, tmux: tmux).resolve("my-session")             # → 2
  #   TmuxPane.new("bottom", tmux: tmux).resolve("my-session")      # → last index
  #   TmuxPane.new("1.2", tmux: tmux).resolve("my-session")         # → 2 (window "1")
  #   TmuxPane.new("%19", tmux: tmux).resolve("my-session")         # → 2 (window "1")
  class TmuxPane
    # Matches a tmux pane id, e.g. "%19".
    PANE_ID = /\A%\d+\z/

    # @param spec [nil, :bottom, Integer, String] pane selector
    # @param tmux [Workspace::Tmux] tmux operations
    def initialize(spec, tmux:)
      @spec = spec
      @tmux = tmux
    end

    # Resolves the spec to a zero-based pane index.
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [Integer] zero-based pane index
    # @raise [Workspace::Error] if pane cannot be found or is out of range
    def resolve(session_name, window: "0")
      window, spec = split_window_pane(window)
      return resolve_pane_id(spec, session_name)[:index] if spec.is_a?(String) && spec.match?(PANE_ID)

      pane_list = @tmux.panes(session_name, window: window)
      raise Workspace::Error, "No panes found for session '#{session_name}'" if pane_list.empty?

      case spec
      when nil, :bottom, "bottom"
        pane_list.last
      when Integer
        validate_index!(spec, pane_list, session_name)
        spec
      when /\A\d+\z/
        index = spec.to_i
        validate_index!(index, pane_list, session_name)
        index
      else
        index = @tmux.find_pane_by_title(session_name, spec.to_s, window: window)
        unless index
          raise Workspace::Error,
            "No pane matching #{spec.inspect} found in session '#{session_name}'"
        end
        index
      end
    end

    # Returns a qualified tmux pane target string (e.g. "0.1").
    #
    # @param session_name [String] tmux session name
    # @param window [String] window index (default "0")
    # @return [String] target in "window.pane" form
    # @raise [Workspace::Error] if pane cannot be found or is out of range
    def target(session_name, window: "0")
      window, spec = split_window_pane(window)
      if spec.is_a?(String) && spec.match?(PANE_ID)
        detail = resolve_pane_id(spec, session_name)
        return "#{detail[:window]}.#{detail[:index]}"
      end
      "#{window}.#{resolve(session_name, window: window)}"
    end

    private

    # Finds a pane by tmux pane id, searching the whole session (not just one
    # window) so the caller doesn't need to know which window it's in. Errors
    # rather than falling through to another session's pane of the same id.
    #
    # @return [Hash] the pane's details (:id, :window, :index, ...)
    # @raise [Workspace::Error] if no pane with that id exists in this session
    def resolve_pane_id(spec, session_name)
      detail = @tmux.pane_details(session_name, window: nil).find { |d| d[:id] == spec }
      unless detail
        raise Workspace::Error, "No pane with id #{spec} in session '#{session_name}'"
      end
      detail
    end

    # Splits a "window.pane" spec into its window and pane parts, so the window
    # embedded in the spec overrides the given default. Returns [window, spec] unchanged
    # for any other spec form.
    def split_window_pane(window)
      if @spec.is_a?(String) && @spec =~ /\A(\d+)\.(\d+)\z/
        [$1, $2.to_i]
      else
        [window, @spec]
      end
    end

    def validate_index!(index, pane_list, session_name)
      return if pane_list.include?(index)
      raise Workspace::Error,
        "Pane #{index} does not exist for '#{session_name}' " \
        "(available: #{pane_list.join(", ")})"
    end
  end
end
