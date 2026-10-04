module Workspace
  # Names the workflow run the calling pane is bound to, so a command run by
  # that run's own agent can tell the run's locks from somebody else's:
  # `dev up` then works under the run's `devenv` hold, and `lock acquire`
  # reports a lock the run already holds, instead of queueing behind it.
  #
  # Only a binding made for this pane's own tmux session and slot counts
  # (see {PaneBindings#stale?}).
  class BoundRun
    # @param pane_bindings [Workspace::PaneBindings] the pane-to-subject bindings
    # @param tmux [Workspace::Tmux] looks up the pane's session and slot
    # @param env [Hash] environment lookup (TMUX_PANE)
    def initialize(pane_bindings:, tmux:, env: ENV)
      @pane_bindings = pane_bindings
      @tmux = tmux
      @env = env
    end

    # Never raises: a pane whose binding can't be checked counts as unbound.
    #
    # @return [String, nil] the run id, or nil when this process is not in a
    #   pane bound to a run
    def run_id
      pane = @env["TMUX_PANE"]
      return nil if pane.nil? || pane.empty?
      entry = @pane_bindings.binding_for(pane)
      return nil unless entry && entry["kind"] == "run"
      return nil if @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane))
      entry["id"]
    rescue Workspace::Error, SystemCallError
      nil
    end
  end
end
