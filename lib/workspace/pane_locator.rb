module Workspace
  # Resolves a caller's pane reference to one live pane of a workspace's own
  # tmux session, for commands that type into or focus a pane (`agent-run
  # send`, `focus --pane`, `ask answer --deliver`).
  #
  # Stricter than {TmuxPane}, on purpose: there is no default pane, no title
  # search, and no bare index, so a caller can't land on a pane it didn't
  # name. Only a pane id (`%19`) or `window.pane` (`0.1`) is accepted, and the
  # pane must belong to the workspace's session, so an id from another
  # session or a stale id is an error rather than a different pane.
  class PaneLocator
    # Matches `window.pane`, e.g. "0.1".
    WINDOW_PANE = /\A(\d+)\.(\d+)\z/

    # @param tmux [Workspace::Tmux] tmux session and pane lookups
    def initialize(tmux:)
      @tmux = tmux
    end

    # @param project [String] workspace name
    # @param spec [String] a pane id ("%19") or "window.pane" ("0.1")
    # @return [Hash] the pane's details (`:id`, `:window`, `:index`, ...) plus `:session`
    # @raise [Workspace::Error] code `bad_pane` for any other form, `no_session`
    #   when the workspace has no tmux session, `wrong_session` when the pane id
    #   belongs to another session, `no_such_pane` when no pane matches
    def locate(project, spec)
      spec = spec.to_s.strip
      by_id = spec.match?(TmuxPane::PANE_ID)
      window_pane = WINDOW_PANE.match(spec)
      unless by_id || window_pane
        raise Workspace::Error.new("#{spec.inspect} is not a pane id (%19) or window.pane (0.1).",
          code: "bad_pane", details: {"pane" => spec})
      end

      session = @tmux.session_name_for(project)
      unless @tmux.sessions.include?(session)
        raise Workspace::Error.new("No active tmux session for '#{project}'.\nRun 'workspace launch #{project}' to start it.",
          code: "no_session", details: {"workspace" => project})
      end

      panes = @tmux.pane_details(session, window: nil)
      detail = if by_id
        panes.find { |d| d[:id] == spec }
      else
        panes.find { |d| d[:window] == window_pane[1].to_i && d[:index] == window_pane[2].to_i }
      end
      return detail.merge(session: session) if detail

      owner = by_id ? @tmux.session_name_for_pane(spec) : nil
      if owner && owner != session
        raise Workspace::Error.new("Pane #{spec} belongs to tmux session '#{owner}', not '#{session}' (workspace '#{project}').",
          code: "wrong_session", details: {"pane" => spec, "workspace" => project, "session" => session})
      end
      raise Workspace::Error.new("No pane #{spec} in tmux session '#{session}' (workspace '#{project}').",
        code: "no_such_pane", details: {"pane" => spec, "workspace" => project})
    end
  end
end
