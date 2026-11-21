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
    #   pane bound to a run, as its author or as its reviewer (the `deny:` tripwire covers both)
    def run_id
      entry = live_entry
      entry && entry["id"]
    end

    # Like {#run_id}, but a binding that can't be checked raises instead of counting as unbound, for a reader that
    # must not act as if a run were absent when it could not tell.
    #
    # @return [String, nil] the run id, or nil when the pane is not bound to a run
    # @raise [Workspace::Error, SystemCallError] when the binding can't be read or checked
    def run_id_strict
      entry = read_entry
      entry && entry["id"]
    end

    # The run only if the pane is the step's own agent's, not a review pane: a review
    # pane holds no locks and runs no dev environment, so `dev up`, `lock acquire` and
    # `promote` must not treat it as the run's author.
    #
    # @return [String, nil] the run id, or nil for an unbound pane or a reviewer's
    def author_run_id
      entry = live_entry
      (entry && entry["role"] != "reviewer") ? entry["id"] : nil
    end

    # @return [String, nil] the step the pane's binding was made for, when it records one; nil for an unbound pane
    def step
      step = live_entry&.fetch("step", nil)
      (step.is_a?(String) && !step.empty?) ? step : nil
    end

    private

    def live_entry
      read_entry
    rescue Workspace::Error, SystemCallError
      nil
    end

    def read_entry
      pane = @env["TMUX_PANE"]
      return nil if pane.nil? || pane.empty?
      entry = @pane_bindings.binding_for(pane)
      return nil unless entry && entry["kind"] == "run"
      return nil if @pane_bindings.stale?(entry, session: @tmux.session_name_for_pane(pane), pane_slot: @tmux.pane_slot(pane),
        server_pid: -> { @tmux.server_pid_for_pane(pane) })
      entry
    end
  end
end
