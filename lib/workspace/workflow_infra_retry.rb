module Workspace
  # Restarts a step whose pane closed (`pane_gone`) or whose agent exited (`agent_gone`) once its infra retry is
  # due, for `workflow advance`. The retry is claimed under the run's lock first ({WorkflowEngine#claim_infra_retry}),
  # so one due retry is restarted by one process; every tmux and daemon call comes after, with the lock given up. The
  # winner splits a new Claude Code pane ({PaneDispatch#spawn}; nothing is typed into the pane or shell the old agent
  # left, which a person may be using) and restarts the step in it ({WorkflowEngine#resume} with `restart_step`,
  # always `bound: "unknown"`, so the restart still needs the stall open). A restart that is refused closes the pane
  # it made: a working agent gives the claim back ({WorkflowEngine#release_infra_retry}), a retry no longer claimed
  # by this process stops there, and anything else gives the retry up ({WorkflowEngine#give_up_infra_retry}) with the
  # refusal's code. A restart that raised after it was stored (the line is typed after the lock is given up) keeps
  # its pane: the run is read again before any pane is closed.
  class WorkflowInfraRetry
    # The actor every change is made as.
    ACTOR = "daemon"

    # The one agent kind a retry restarts: dispatch types `/clear` into a fresh conversation, which only Claude Code reads.
    AGENT_KIND = "claude"

    # @param engine [Workspace::WorkflowEngine] claims, restarts, releases and gives up the retry
    # @param store [Workspace::WorkflowRunStore] reads the run again after a restart that raised
    # @param dispatch [Workspace::PaneDispatch] whether the workspace's session runs, the new pane and its close
    # @param lock_holder [Workspace::LockHolder] this process's start time, and whether a claimant still runs
    # @param agent_commands [Workspace::AgentCommands] the workspace's configured `agent.kind`
    # @param pid [Integer] this process's pid, the claimant's
    # @param clock [#call] returns the current Time
    def initialize(engine:, store:, dispatch:, lock_holder:, agent_commands:, pid: Process.pid, clock: -> { Time.now })
      @engine = engine
      @store = store
      @dispatch = dispatch
      @lock_holder = lock_holder
      @agent_commands = agent_commands
      @pid = pid
      @clock = clock
    end

    # Restarts the run's current step for its due infra retry, if this process wins the claim.
    #
    # @param run [Workspace::WorkflowRun] the stored run, one {WorkflowTransitions.wakeable?} reads as `:infra_retry`
    # @return [Array, Symbol] [:restarted, n, pane]; [:gave_up, reason]; what {WorkflowEngine#release_infra_retry}
    #   answers for a working agent (:released: the claim given back, due again one wait later); :not_claimed (the restart found the retry no longer claimed by this
    #   process: its stall ended, or another process took the claim over); :unconfirmed (the restart raised and the run
    #   could not be read again: the new pane is kept and nothing given up, the claim left to go stale); :not_due (no retry due, or
    #   another process holds it: nothing spawned); :no_claimant (this process's start time can't be read: nothing done)
    # @raise [StandardError] an error from the restart that is not a {Workspace::Error} and left the run unrestarted,
    #   after the new pane is closed and the retry given up with `restart_error` (both skipped when the run can't be
    #   read again), so the advance fails and is logged as any other does
    def call(run)
      stored = run.to_h
      info = WorkflowTransitions.infra_retry(stored, @clock.call) or return :not_due
      claimant = own_claimant or return :no_claimant
      step = stored["current"]
      attempt = stored.dig("steps", step, "attempts")&.last&.fetch("n", nil)
      target = {run_id: run.id, workspace: run.workspace, step: step, attempt: attempt, cause: info[:cause], claimant: claimant}
      claim = @engine.claim_infra_retry(run.id, actor: ACTOR, step: step, attempt: attempt, claimant: claimant, alive: method(:alive?))
      return claim unless claim.is_a?(Array) && claim.first == :claimed
      restart(target, claim.last)
    end

    private

    def restart(target, n)
      return give_up(target, "no_session") if @dispatch.session_live?(target[:workspace]) == false
      return give_up(target, "agent_kind_unsupported") unless @agent_commands.kind(target[:workspace]) == AGENT_KIND
      spawned = spawn(target)
      return spawned unless spawned.is_a?(PaneDispatch::Spawned)
      resume(target, spawned.pane, n)
    end

    # A new pane whose agent is ready, or what was given up: `agent_not_ready` (the pane closed, or left open on a
    # custom tmux socket), `agent_waiting_<screen>` (kept at a sign-in, trust or approval screen for a person) or
    # `spawn_failed` (no pane was made).
    def spawn(target)
      spawned = @dispatch.spawn(target[:workspace], AGENT_KIND)
      return spawned if spawned.ready?
      give_up(target, spawned.waiting ? "agent_waiting_#{spawned.waiting}" : "agent_not_ready")
    rescue Workspace::Error => e
      give_up(target, e.details.key?("pane_id") ? "agent_not_ready" : "spawn_failed")
    end

    def resume(target, pane, n)
      @engine.resume(target[:run_id], actor: ACTOR, restart_step: true, bound: "unknown", infra_retry: target[:claimant], pane: pane)
      [:restarted, n, pane]
    rescue Workspace::Error => e
      case restarted?(target, pane)
      when true then return [:restarted, n, pane]
      when nil then return :unconfirmed
      end
      @dispatch.close_unused(target[:workspace], pane)
      case e.code
      when "step_still_working"
        @engine.release_infra_retry(target[:run_id], actor: ACTOR, step: target[:step], attempt: target[:attempt], claimant: target[:claimant])
      when "infra_retry_not_claimed" then :not_claimed
      else give_up(target, e.code || "restart_refused")
      end
    rescue => e
      stored = restarted?(target, pane)
      return [:restarted, n, pane] if stored
      if stored == false
        @dispatch.close_unused(target[:workspace], pane)
        give_up(target, "restart_error")
      end
      raise e
    end

    # Whether the restart was stored before it raised: the run is past the claimed attempt, or bound to the new pane.
    # nil when the run can't be read: the pane is then kept, as the run may be using it.
    def restarted?(target, pane)
      run = @store.run(target[:run_id]).to_h
      attempt = run.dig("steps", target[:step], "attempts")&.last&.fetch("n", nil)
      run["current"] != target[:step] || attempt != target[:attempt] || run["pane"] == pane
    rescue Workspace::Error, SystemCallError
      nil
    end

    def give_up(target, reason)
      @engine.give_up_infra_retry(target[:run_id], actor: ACTOR, step: target[:step], attempt: target[:attempt], cause: target[:cause], reason: reason)
      [:gave_up, reason]
    end

    def own_claimant
      started = @lock_holder.start_time(@pid)
      (started.is_a?(String) && !started.empty?) ? {"pid" => @pid, "started" => started} : nil
    rescue Workspace::Error
      nil
    end

    # A process table that can't be read leaves the claim held: a live claimant is never taken over.
    def alive?(claimed_by)
      @lock_holder.alive?(pid: claimed_by["pid"], started: claimed_by["started"])
    rescue Workspace::Error
      true
    end
  end
end
