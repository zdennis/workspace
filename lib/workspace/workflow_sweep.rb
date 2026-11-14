require "time"

module Workspace
  # One pass over the runs still going, acting on the ones that have stopped
  # without anything noticing. It needs no agent daemon: it reads the run files
  # and the panes, asks the daemon only for what a pane shows, and starts a
  # daemon that is not running.
  #
  # For a run whose step reads `running`, in this order:
  #
  # - the run's pane is gone: records `step_stalled` (cause `pane_gone`); the
  #   run keeps its checkout until someone resumes or cancels it
  # - the workspace's daemon is not running: starts it (`step_stalled` cause
  #   `daemon_down`, then `step_recovered` action `daemon_respawned`, written
  #   whenever a start succeeds and the recovery is not yet written) and goes no
  #   further for that run in this pass, since a new daemon's reading is not
  #   evidence; a start that fails is tried again on the next pass and recorded
  #   once. A workspace with no tmux session gets no daemon (`workspace_stopped`)
  # - the step is held (it has a reason), is still being delivered, or its pane
  #   waits for a person: left alone. The one exception is a step past its
  #   `timeout` with `on_timeout: fail` that is held on `turn_ended_incomplete`:
  #   it is failed (`step_timed_out`). A `turn_ended_background` hold has its own
  #   90-minute limit and is never touched
  # - the pane shows a shell where the agent was: records cause `agent_gone`
  # - the agent's turn is over (the daemon says so, read again just before the
  #   change, and idle for a few seconds) and the pane has been idle for the
  #   definition's `stall`, or the step is past its `timeout` and has
  #   `on_timeout` `interrupt` or `fail`, or the run has used its `timeout:` (either
  #   `timeout_action`, since the hold only comes at the next attempt's start), or
  #   the sweep interrupted it earlier:
  #   decides the step as {WorkflowEngine#resume} does when given the same proof
  #   (`step_stalled` cause `idle_turn_over`, `step_recovered` action
  #   `evaluated`); with `on_timeout: fail`, a decision that is a
  #   `turn_ended_incomplete` stop fails the step instead
  # - the agent is working and the step is past its `timeout`: `interrupt`
  #   claims the interrupt under the run's lock, presses the agent's interrupt
  #   keys with the lock given up, and confirms under the lock (action
  #   `interrupted`); `fail` does the same and then fails the step (action
  #   `failed`, `details.code` `step_timed_out`); `warn` does nothing, and writes
  #   nothing, as before
  # - the agent is working and the run has used its definition's `timeout:` with
  #   `timeout_action: interrupt` (and no step timeout is due with an action of
  #   its own, which presses once for both): the same claim, press and confirm
  #   under the cause `run_timed_out` and its own mark, never failing the step;
  #   the turn then ends and the next attempt's start holds the run as
  #   `run_timed_out`
  #
  # For a run whose step waits on a line that was never delivered (`not_delivered`, a failure a later try can
  # get past), see {WorkflowEngine.redelivery}: once the backoff (1, 5, then 15 minutes after the failed attempt
  # ended) is over, the daemon is running and the pane shows an idle agent, the line is typed again
  # (`step_stalled` cause `undelivered`, `step_recovered` action `redelivered`, `redeliver` times at most, the
  # definition's key). A retried attempt does not count against `max_attempts`. When the retries run out the
  # run stays as it was, waiting for a person, and the sweep records `redelivery_exhausted` once.
  #
  # For a run whose failed step waits out an `on_fail` `backoff` ({WorkflowEngine.backoff}): before the time, nothing
  # (reason `backoff`, no stall is recorded); after it, the retry starts as a tick or a resume would start it
  # (outcome `retried`).
  #
  # For a run whose step reads `reviewing` (a review round), in this order: a round stopped for a person (any
  # stored reason but `waiting_lock`) is left alone and gets no daemon; a missing daemon is started; a round whose
  # end was being judged when its process died is handed to {WorkflowEngine#tick} (cause `lost_round`); a round
  # waiting for its `review.uses` is left to {WorkflowEngine#tick}; a round whose delivery failed (after the
  # backoff an undelivered line waits) or lapsed with its delivering process gone is handed to
  # {WorkflowEngine#tick}, which delivers it again or, its `redeliver` spent, stops it `review_incomplete` (cause
  # `round_undelivered`), unless its line may have been typed ({WorkflowTransitions.typed_round?}): that one is read
  # in its review pane as below, and past {WorkflowTransitions.typed_wait_over?} handed to {WorkflowEngine#tick}
  # (cause `round_maybe_typed`); a round still being delivered is left alone; then the round's review pane is read, on
  # positive evidence only ({WorkflowPanes#review_pane_state}; a tmux that can't be read, or a round that recorded
  # no tmux server, decides neither gone nor restarted, and the daemon's pane row decides the rest): gone (cause `pane_gone`), its agent exited to a shell (cause `agent_gone`),
  # lost with a restarted tmux server (cause `server_restarted`, delivered again in a new window, counted against
  # `redeliver`), waiting for an answer (left alone), or its turn over and idle for the definition's `stall`
  # (cause `idle_turn_over`). A gone pane, a gone agent and an idle turn are decided as the review turn's end
  # decides them, so verdicts already written count and a round left short stops `review_incomplete`. The idle
  # turn is not told from one whose Stop listed background tasks (the daemon's pane row does not carry them), so a
  # reviewer that left a sub-agent running past `stall` is decided on what it has written. Each writes
  # `step_stalled` with the round.
  #
  # Review windows no round uses ({WorkflowReviewOrphans}: the run is over, or its round does not record the window)
  # are closed, one row each (outcome `closed`, cause `orphan_review_window`), in the workspace given, the named
  # run's, or every tmux session; a window of another run store is left out, and one whose run this store does not
  # have is reported (`nothing`, reason `unconfirmed`) and never closed.
  #
  # A run with a live park, a step that is checking, or no step being worked
  # on is left alone, except that a missing daemon is started for it. Every
  # change goes through {WorkflowEngine} under the run's own lock, and only
  # when the run is still on the step and attempt the sweep read, so a resume
  # or a turn's end that got there first stands. A cause is recorded once for
  # each attempt, and a second pass finds the marks the first left.
  #
  # A small window remains: the pane is read, then the lock is taken, and an
  # agent that starts a new turn in between is not seen. The attempt check, the
  # idle floor and the second reading just before the change keep it to a
  # moment; a turn that begins after the check is decided as if it had ended.
  class WorkflowSweep
    # Seconds after an attempt starts during which an idle pane is not taken for one whose turn is over.
    IDLE_GRACE = WorkflowStatus::IDLE_GRACE

    # Seconds a pane must have been idle before the sweep treats its turn as over, on every branch.
    IDLE_FLOOR = 5

    # @param store [Workspace::WorkflowRunStore]
    # @param engine [Workspace::WorkflowEngine] makes every change to a run
    # @param panes [Workspace::WorkflowPanes] says whether a run's pane and daemon are there and what the pane shows
    # @param interrupter [#call] presses keys in a pane (`workspace`, `pane`, `keys`); raises {Workspace::Error} when it can't
    # @param orphans [Workspace::WorkflowReviewOrphans, nil] finds and closes review windows no round uses; nil closes none
    # @param holder_alive [#call, nil] given a review round's delivery `holder`, whether that process still runs (nil
    #   takes every holder as alive, so a lapsed round with a holder is left alone)
    # @param clock [#call] returns the current Time
    def initialize(store:, engine:, panes:, interrupter:, orphans: nil, holder_alive: nil, clock: -> { Time.now })
      @store = store
      @orphans = orphans
      @holder_alive = holder_alive
      @engine = engine
      @panes = panes
      @interrupter = interrupter
      @clock = clock
    end

    # @param run [String, nil] only this run (a finished one is reported as such)
    # @param workspace [String, nil] only this workspace's runs
    # @param dry_run [Boolean] decide and report; change and press nothing
    # @param allow [#call, nil] given a stored run before the sweep changes it or presses keys in its pane;
    #   returns nil to go on or a sentence to leave the run alone
    # @return [Array<Hash>] one row per run looked at, and one `failed` row (`unreadable_run`) for each run file
    #   that can't be read when no run or workspace is named, and one row for each review window it closes:
    #   "workspace", "outcome" (`nothing`, `recorded`,
    #   `evaluated`, `interrupted`, `timed_out`, `respawned`, `redelivered`, `retried`, `stopped` (a review round stopped
    #   for a person), `closed` (an orphan review window), `failed`, `dry_run`), "reason" (for a retry also `backoff`, `pane_busy`,
    #   `not_delivered`, `waiting_lock`), "message", "run_id",
    #   "step", "attempt", "cause", "action"
    # @raise [Workspace::Error] code `unknown_run` for a +run+ that does not exist
    def call(run: nil, workspace: nil, dry_run: false, allow: nil)
      runs = run ? [@store.run(run)] : @store.going
      runs = runs.select { |each| each.workspace == workspace } if workspace
      pass = {dry_run: dry_run, allow: allow, down: {}, daemons: {}}
      rows = runs.map { |each| sweep_run(each, pass) }
      rows += unreadable_rows unless run || workspace
      # Every session of the default tmux server unless a workspace or a run narrows the pass.
      rows + orphan_rows(run, workspace || (run && runs.first&.workspace), pass)
    end

    private

    def unreadable_rows
      @store.unreadable.map do |path|
        {"workspace" => nil, "outcome" => "failed", "reason" => "unreadable_run", "run_id" => File.basename(path, ".json"), "step" => nil, "attempt" => nil,
         "cause" => nil, "action" => nil,
         "message" => "The run file #{path} can't be read, so its run is not looked at. What it held stays held: free a lock with `workspace lock clear NAME`, or delete the file."}
      end
    end

    # Asked once for each workspace in a pass, so every run of one that was down hears of it, though
    # the first run's pass has started the daemon by the time the next is looked at.
    def daemon_down?(workspace, pass)
      pass[:down].fetch(workspace) { pass[:down][workspace] = !@panes.daemon_running?(workspace) }
    end

    def sweep_run(run, pass)
      return row(run, "nothing", reason: "finished", message: "the run has ended") if WorkflowRunStore::TERMINAL_STATES.include?(run.state)
      state = run.steps.fetch(run.current)
      running = state.state == "running"
      backoff = WorkflowEngine.backoff(run.to_h, @clock.call)
      return sweep_backoff(run, backoff, pass) if backoff
      return blocked_row(run) if run.backoff&.dig("blocked") && run.state == "waiting"
      return budget_row(run) if (run.budget_hold || run.timeout_hold) && run.state == "waiting"
      reviewing = state.state == "reviewing"
      # A round stopped for a person waits for that person: no daemon is started for it, and nothing reads its pane.
      return review_held_row(run) if reviewing && run.reason && run.reason["code"] != "waiting_lock"
      daemon_needed = running || reviewing || state.state == "checking" || run.parked || run.reason&.dig("code") == "waiting_lock"
      if running && !@panes.alive?(run.id)
        pane = run.pane
        return note(run, pass, "pane_gone", "pane #{pane} is gone, so nothing will end this step. The run keeps its checkout until it is resumed (`workspace workflow resume #{run.id}`) or cancelled.", "pane" => pane)
      end
      redelivery = WorkflowEngine.redelivery(run.to_h, @clock.call)
      return sweep_undelivered(run, redelivery, pass) if redelivery
      return respawn(run, pass) if daemon_needed && daemon_down?(run.workspace, pass)
      return row(run, "nothing", reason: "parked", message: "a resume is parked; it is carried out when the pane's turn ends") if run.parked
      return row(run, "nothing", reason: "checking", message: "the step's check is running") if state.state == "checking"
      return sweep_lost_round(run, pass) if state.state == "reviewing" && WorkflowEngine.lost_round?(run.to_h, @clock.call)
      return sweep_reviewing(run, state, pass) if reviewing
      return row(run, "nothing", reason: "not_running", message: "no agent is working on step #{run.current} (#{state.state})") unless running
      sweep_running(run, state, pass)
    rescue Workspace::Error => e
      return row(run, "nothing", reason: "finished", message: "the run ended while it was being looked at") if e.code == "run_not_active"
      row(run, "failed", reason: e.code || "error", message: e.message.lines.first.to_s.strip)
    rescue KeyError, TypeError => e
      row(run, "failed", reason: "unreadable_run", message: "the run file is not shaped as a run is (#{e.class}: #{e.message.lines.first.to_s.strip})")
    rescue SystemCallError => e
      program = e.message[/ - (\S+)/, 1]
      row(run, "failed", reason: "tool_unavailable", message: "could not run #{program || "a program the sweep needs"}: #{e.message.lines.first.to_s.strip}. Put it on PATH.")
    end

    # The step failed and its `on_fail` retry waits out a `backoff`: not a stall. Once the time has come the retry
    # starts, as a tick or a resume would start it.
    def sweep_backoff(run, info, pass)
      what = "step #{run.current} failed; step #{info[:to]} starts again at #{info[:until]}"
      return row(run, "nothing", reason: "backoff", cause: "retry_backoff", message: "#{what} (in #{info[:wait]} seconds)") if info[:state] == :waiting
      message = "#{what}, and that time has passed"
      # A retry types a line, which only a running daemon's turn end follows up; the next pass retries after a respawn.
      return respawn(run, pass, notes: false) if daemon_down?(run.workspace, pass)
      return row(run, "dry_run", message: message, cause: "retry_backoff", action: "retry") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "retry_backoff") if refusal
      outcome = @engine.retry_backoff(run.id, step: run.current, attempt: attempt_of(run))
      return blocked_row(run) if outcome == :blocked
      return budget_row(run, cause: "retry_backoff", action: "retry") if outcome == :held
      engine_row(run, outcome, "retried", cause: "retry_backoff", message: message, action: "retry")
    end

    # A round whose line may have been typed, past the short wait: {WorkflowEngine#tick} judges it unless its review
    # pane shows a reviewer at work (until the review's timeout) or waiting for an answer.
    def sweep_typed_round(run, what, pass)
      message = "#{what} may have been typed before its delivery failed or lapsed; its verdicts are read once its review pane is done"
      return row(run, "dry_run", message: message, cause: "round_maybe_typed", action: "evaluate") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "round_maybe_typed") if refusal
      return engine_row(run, :evaluated, "evaluated", cause: "round_maybe_typed", message: message, action: "evaluate") if @engine.tick(run.id)
      row(run, "nothing", reason: "reviewing", cause: "round_maybe_typed",
        message: "#{what} may have been typed and its review pane is still at work or waiting for an answer (or another process is changing the run); the next pass looks again")
    end

    # The end of a review round was being judged and its process died before it reported back: not a stall. The
    # judging is handed to {WorkflowEngine#tick}, which runs it once more.
    def sweep_lost_round(run, pass)
      message = "the end of step #{run.current}'s review round was being judged and nothing reported back"
      return row(run, "dry_run", message: message, cause: "lost_round", action: "judge_again") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "lost_round") if refusal
      outcome = @engine.tick(run.id) ? :judged : :busy
      engine_row(run, outcome, "judged_again", cause: "lost_round", message: message, action: "judge_again")
    end

    def review_held_row(run)
      round = run.step(run.current)&.review
      what = (round.is_a?(Hash) && round["round"]) ? "review round #{round["round"]} of step #{run.current}" : "the review of step #{run.current}"
      row(run, "nothing", reason: "held", message: "#{what} stopped (#{run.reason&.dig("code")}); a person decides it")
    end

    # The step reads `reviewing` with no stop for a person, and the daemon is running.
    def sweep_reviewing(run, state, pass)
      round = state.review
      return row(run, "nothing", reason: "reviewing", message: "step #{run.current} is being reviewed") unless round.is_a?(Hash) && round["round"]
      what = "review round #{round["round"]} of step #{run.current}"
      return row(run, "nothing", reason: "waiting_lock", message: "#{what} waits for a lock its review.uses names; it starts once the lock is free") if run.reason
      now = @clock.call
      # A round whose line may have been typed is read in its review pane like a delivered one: its pane, agent and
      # idle turn decide it, never a delivery again.
      typed = WorkflowTransitions.typed_round?(round, now, alive: @holder_alive)
      redelivery = typed ? nil : WorkflowTransitions.round_redelivery(run.to_h, now, alive: @holder_alive)
      return sweep_round_undelivered(run, what, round, redelivery, pass) if redelivery
      return row(run, "nothing", reason: "delivering", message: "#{what} is still being delivered") if round["delivery"] == "delivering" && !typed
      # Past the short wait, the engine's tick decides it from its pane (so a setup with only the sweep, no daemon
      # timer, decides it too); it still waits for a reviewer at work or a prompt.
      return sweep_typed_round(run, what, pass) if typed && WorkflowTransitions.typed_wait_over?(run.to_h, round, now)
      return row(run, "nothing", reason: "reviewing", message: "the end of #{what} is being judged") if round["recompute"]
      pane = round["pane"]
      return row(run, "nothing", reason: "reviewing", message: "#{what} is being reviewed") unless pane
      case @panes.review_pane_state(run.workspace, pane, round["server_pid"])
      when :gone
        return review_stall(run, round, pass, pane, "pane_gone", "review pane #{pane} of #{what} is gone, so nothing will end the round; its verdicts are read now, and it stops for a person (review_incomplete) when they fall short")
      when :server_restarted
        return review_stall(run, round, pass, pane, "server_restarted", "the tmux server review pane #{pane} of #{what} was on was restarted; the round is delivered again in a new window")
      end
      # With no answer from tmux (unreachable, or no server recorded to rule out a reused pane id) nothing is decided
      # on the pane being gone or its server restarted; what the daemon's pane row shows still decides the rest.
      shown = @panes.pane_row(run.workspace, pane)
      return row(run, "nothing", reason: "unknown", message: "the agent daemon did not say what review pane #{pane} shows") unless shown
      if WorkflowPanes.agent_gone_row?(shown)
        return review_stall(run, round, pass, pane, "agent_gone", "review pane #{pane} of #{what} shows a shell: its agent has exited; its verdicts are read now, and it stops for a person (review_incomplete) when they fall short")
      end
      return row(run, "nothing", reason: "prompt", message: "review pane #{pane} waits for an answer") if shown["state"] == "waiting"
      idle_for = shown["idle_seconds"].to_i
      stall = WorkflowDefinition.stall(run.definition)
      return row(run, "nothing", reason: "reviewing", message: "#{what} is being reviewed") unless review_turn_over?(shown, round, now) && stall && idle_for >= stall
      review_stall(run, round, pass, pane, "idle_turn_over", "the review turn in pane #{pane} ended and nothing decided #{what} (idle for #{idle_for} seconds)", {"idle_for" => idle_for})
    end

    # The review pane's turn is over, idle past the floor, and the round was delivered long enough ago that an idle
    # pane is not one the line has yet to reach.
    def review_turn_over?(shown, round, now)
      return false unless WorkflowPanes.turn_over?(shown, now) && shown["idle_seconds"].to_i >= IDLE_FLOOR
      now - Time.iso8601((round["delivered_at"] || round["started_at"]).to_s) >= IDLE_GRACE
    rescue ArgumentError
      false
    end

    # A review round's delivery failed or lapsed ({WorkflowTransitions.round_redelivery}): the delivery again, or the
    # stop once it is spent, is {WorkflowEngine#tick}'s.
    def sweep_round_undelivered(run, what, round, info, pass)
      failure = round["failure"]
      how = failure.is_a?(Hash) ? "was not delivered (#{failure["code"]})" : "was not delivered and the process delivering it is gone"
      if info[:state] == :waiting
        return row(run, "nothing", reason: "backoff", cause: "round_undelivered", message: "#{what} #{how}; it is delivered again (#{info[:retries] + 1} of #{info[:limit]}) in #{info[:wait]} seconds")
      end
      exhausted = info[:state] == :exhausted
      message = exhausted ? "#{what} #{how}, and it can't be delivered again (#{info[:retries]} of #{info[:limit]}); it stops for a person (review_incomplete)" : "#{what} #{how}; delivering it again (#{info[:retries] + 1} of #{info[:limit]})"
      action = exhausted ? "stop" : "redeliver"
      return row(run, "dry_run", message: message, cause: "round_undelivered", action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "round_undelivered") if refusal
      outcome = @engine.tick(run.id) ? :done : :busy
      engine_row(run, outcome, exhausted ? "stopped" : "redelivered", cause: "round_undelivered", message: message, action: action)
    end

    # A round stalled in its review pane: the change is {WorkflowEngine#review_stalled}'s. A turn's end is read again just before it.
    def review_stall(run, round, pass, pane, cause, message, data = {})
      action = (cause == "server_restarted") ? "redeliver" : "evaluate"
      return row(run, "dry_run", message: message, cause: cause, action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      if cause == "idle_turn_over"
        fresh = @panes.pane_row(run.workspace, pane)
        unless fresh && WorkflowPanes.turn_over?(fresh, @clock.call) && fresh["idle_seconds"].to_i >= IDLE_FLOOR
          return row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows the review turn over; the next pass looks again", cause: cause)
        end
      elsif cause == "agent_gone"
        unless WorkflowPanes.agent_gone_row?(@panes.pane_row(run.workspace, pane))
          return row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows a shell; the next pass looks again", cause: cause)
        end
      end
      outcome = @engine.review_stalled(run.id, step: run.current, attempt: attempt_of(run), round: round["round"], pane: pane, cause: cause, data: data)
      engine_row(run, outcome, {evaluated: "evaluated", stopped: "stopped", redelivered: "redelivered"}.fetch(outcome, outcome.to_s), cause: cause, message: message, action: action)
    end

    # The review windows no round uses, in the workspace looked at (every session when none is named), closed.
    def orphan_rows(run_id, workspace, pass)
      return [] unless @orphans
      return [] if run_id && workspace.nil?
      @orphans.find(workspace: workspace).filter_map do |orphan|
        next if run_id && orphan[:run_id] != run_id
        orphan_row(orphan, pass)
      end
    end

    def orphan_row(orphan, pass)
      message = "review window #{orphan[:window]} (pane #{orphan[:pane]}, round #{orphan[:round]} of step #{orphan[:step]}) is left over: #{WorkflowReviewOrphans::WHY.fetch(orphan[:why])}"
      base = {"workspace" => orphan[:workspace] || orphan[:session], "run_id" => orphan[:run_id], "step" => orphan[:step], "attempt" => nil, "cause" => "orphan_review_window"}
      unless orphan[:closable]
        return base.merge("outcome" => "nothing", "reason" => "unconfirmed", "action" => nil,
          "message" => "#{message}; it may be another state directory's, so it is left. Close it by hand (tmux kill-window -t #{orphan[:window]}) if it is left over")
      end
      return base.merge("outcome" => "dry_run", "reason" => nil, "message" => message, "action" => "close_window") if pass[:dry_run]
      # A run no one knows is named by its id and session alone, so a caller bound to it is still refused.
      refusal = pass[:allow]&.call(orphan[:run] || WorkflowRun.from_h("id" => orphan[:run_id], "workspace" => orphan[:session]))
      return base.merge("outcome" => "nothing", "reason" => "refused", "message" => refusal, "action" => nil) if refusal
      return base.merge("outcome" => "closed", "reason" => nil, "message" => "#{message}; closed", "action" => "close_window") if @orphans.close(orphan)
      base.merge("outcome" => "failed", "reason" => "close_failed", "message" => "#{message}, and tmux could not close it", "action" => "close_window")
    end

    # The retry's wait is over but the token budget is used: not a failure, and the sweep cannot raise the budget.
    def budget_row(run, **rest)
      round = (run.budget_hold || run.timeout_hold)&.dig("review_round")
      held = round ? "review round #{round} of step #{run.current}" : "step #{run.current}"
      if run.reason&.dig("code") == "run_timed_out"
        return row(run, "nothing", reason: "run_timed_out", message: "#{held} was not started: the run's time limit is used. Resume it with --extra-time DURATION (see `workspace workflow status #{run.id}`) or cancel it", **rest)
      end
      row(run, "nothing", reason: "budget_spent", message: "#{held} was not started: the run's token budget is used. Resume it with --extra-tokens N#{" and --extra-time DURATION" if run.reason&.dig("details", "run_timed_out")} (see `workspace workflow status #{run.id}`) or cancel it", **rest)
    end

    # The pane the retry would type into is no longer the run's. Not a failure: the sweep cannot fix it, and a person can.
    def blocked_row(run)
      row(run, "nothing", reason: "retry_blocked", cause: "retry_backoff", action: "retry",
        message: "the retry of step #{run.backoff&.dig("to")} is held: its pane is no longer the run's. Resume the run with --pane for another agent pane, or cancel it")
    end

    # The step waits on a line that was not delivered, and {WorkflowEngine.redelivery} says where a retry stands.
    def sweep_undelivered(run, info, pass)
      pane = run.pane
      what = "step #{run.current}'s line was not delivered to pane #{pane} (#{info[:code]})"
      case info[:state]
      when :exhausted
        return note(run, pass, "redelivery_exhausted", "#{what}, and it was retried #{info[:retries]} time#{"s" unless info[:retries] == 1}; resume the run (`workspace workflow resume #{run.id}`) once the pane is ready", "code" => info[:code], "retries" => info[:retries])
      when :waiting
        return row(run, "nothing", reason: "backoff", cause: "undelivered", message: "#{what}; retry #{info[:retries] + 1} of #{info[:limit]} in #{info[:wait]} seconds")
      end
      unless @panes.alive?(run.id)
        return note(run, pass, "pane_gone", "pane #{pane} is gone, so #{what} cannot be retried. The run keeps its checkout until it is resumed (`workspace workflow resume #{run.id}`) or cancelled.", "pane" => pane)
      end
      return respawn(run, pass) if daemon_down?(run.workspace, pass)
      shown = pane && @panes.pane_row(run.workspace, pane)
      return row(run, "nothing", reason: "unknown", cause: "undelivered", message: "#{what}; the agent daemon did not say what pane #{pane} shows") unless shown
      unless WorkflowPanes.turn_over?(shown, @clock.call) && shown["idle_seconds"].to_i >= IDLE_FLOOR
        return row(run, "nothing", reason: "pane_busy", cause: "undelivered", message: "#{what}; pane #{pane} is not idle, so nothing is typed. The next pass looks again")
      end
      message = "#{what}; typing it again (retry #{info[:retries] + 1} of #{info[:limit]})"
      return row(run, "dry_run", message: message, cause: "undelivered", action: "redeliver") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "undelivered") if refusal
      outcome = @engine.redeliver(run.id, step: run.current, attempt: attempt_of(run))
      case outcome
      when :not_delivered
        row(run, "nothing", reason: "not_delivered", cause: "undelivered", action: "redeliver", message: "#{message}, but it was not delivered again; the next retry waits out a longer backoff")
      when :waiting_lock
        row(run, "nothing", reason: "waiting_lock", cause: "undelivered", action: "redeliver", message: "#{message}, but the step is waiting for a lock it uses; it is typed when the lock is free")
      else engine_row(run, outcome, "redelivered", cause: "undelivered", message: message, action: "redeliver")
      end
    end

    # The step reads `running` and its pane is there.
    def sweep_running(run, state, pass)
      attempt = state.last_attempt
      return row(run, "nothing", reason: "no_attempt", message: "step #{run.current} reads running and has no attempt; resume the run") unless attempt
      begin
        started = Time.iso8601(attempt.started_at.to_s)
      rescue ArgumentError
        return row(run, "failed", reason: "unreadable_run", message: "the attempt has no readable start time")
      end
      elapsed = @clock.call - started
      step = run.definition["steps"].find { |each| each["id"] == run.current }
      timeout = step["timeout"]
      timed_out = timeout.is_a?(Numeric) && elapsed > timeout
      on_timeout = WorkflowDefinition.on_timeout(step)

      if run.reason
        return time_out(run, attempt, pass, elapsed, timeout, nil) if timed_out && on_timeout == "fail" && run.reason&.dig("code") == "turn_ended_incomplete"
        return row(run, "nothing", reason: "held", message: "step #{run.current} is held (#{run.reason&.dig("code")}); a person decides it")
      end
      return row(run, "nothing", reason: "delivering", message: "the step's line is still on its way to the pane") if WorkflowEngine.delivery(attempt.to_h, @clock.call) == :delivering
      pane = @panes.pane_of(run.id)
      shown = @panes.pane_row(run.workspace, pane)
      return row(run, "nothing", reason: "unknown", message: "the agent daemon did not say what pane #{pane} shows") unless shown
      if WorkflowPanes.agent_gone_row?(shown)
        return note(run, pass, "agent_gone", "pane #{pane} shows a shell: the agent has exited, so nothing will end this step. Resume the run to start it again.", "pane" => pane)
      end
      return row(run, "nothing", reason: "prompt", message: "pane #{pane} waits for an answer") if shown["state"] == "waiting"

      stall = WorkflowDefinition.stall(run.definition)
      idle_for = shown["idle_seconds"].to_i
      deadline = WorkflowDeadline.reading(run, @clock.call)
      run_spent = deadline && deadline["spent"]
      run_due = run_spent && deadline["action"] == "interrupt"
      if WorkflowPanes.turn_over?(shown, @clock.call) && elapsed >= IDLE_GRACE && idle_for >= IDLE_FLOOR
        marks = WorkflowEngine.sweep_marks(run.to_h)
        cause = if marks.dig("interrupt", "state") == "sent" || marks.dig("run_interrupt", "state") == "sent" then "interrupted"
        elsif (stall && idle_for >= stall) || (timed_out && on_timeout != "warn") || run_spent then "idle_turn_over"
        end
        return row(run, "nothing", reason: "idle", message: "the agent's turn is over; the step is decided once it has been idle for the definition's stall") unless cause
        return evaluate(run, attempt, pass, pane, shown, cause, idle_for, (timed_out && on_timeout == "fail") ? {"elapsed" => elapsed, "timeout" => timeout} : nil)
      end
      return row(run, "nothing", reason: "healthy", message: nil) unless timed_out || run_due
      if timed_out && on_timeout == "warn" && !run_due
        return row(run, "nothing", reason: "timed_out", message: "step #{run.current} is past its #{timeout} second timeout (on_timeout: warn)")
      end
      unless timed_out && on_timeout != "warn"
        return press_for_run_deadline(run, attempt, pass, shown, pane, deadline)
      end
      return row(run, "nothing", reason: "not_working", message: "step #{run.current} is past its timeout, but pane #{pane} does not show the agent working") unless shown["state"] == "working"
      press_and_confirm(run, attempt, pass, shown, pane, elapsed, timeout, then_fail: on_timeout == "fail")
    end

    def note(run, pass, cause, message, data = {})
      return row(run, "nothing", reason: "already_recorded", message: message, cause: cause) if WorkflowEngine.sweep_marks(run.to_h).dig("stalled", cause)
      return row(run, "dry_run", message: message, cause: cause, action: "record") if pass[:dry_run]
      outcome = @engine.note_stall(run.id, step: run.current, attempt: attempt_of(run), cause: cause, data: data)
      engine_row(run, outcome, "recorded", cause: cause, message: message, action: "record")
    end

    # Starts the workspace's daemon. The run is not acted on again in this pass.
    def respawn(run, pass, notes: true)
      workspace = run.workspace
      message = "the agent daemon of '#{workspace}' is not running, so no turn's end is seen"
      unless @panes.session_live?(workspace)
        return row(run, "nothing", reason: "workspace_stopped", cause: "daemon_down", message: "#{message}, and the workspace has no tmux session, so none is started")
      end
      return row(run, "dry_run", message: message, cause: "daemon_down", action: "respawn_daemon") if pass[:dry_run]
      started = (pass[:daemons][workspace] ||= @panes.respawn_daemon(workspace))
      attempt = attempt_of(run)
      @engine.note_stall(run.id, step: run.current, attempt: attempt, cause: "daemon_down", data: {"workspace" => workspace}) if notes
      unless started[:ok]
        return row(run, "failed", reason: "daemon_not_started", cause: "daemon_down", action: "respawn_daemon",
          message: "#{message}, and it could not be started#{": #{started[:detail]}" if started[:detail]}")
      end
      @engine.note_recovery(run.id, step: run.current, attempt: attempt, cause: "daemon_down", action: "daemon_respawned") if notes
      row(run, "respawned", cause: "daemon_down", action: "respawn_daemon", message: "#{message}; it is running again, and the pane is read on the next pass")
    end

    def evaluate(run, attempt, pass, pane, shown, cause, idle_for, fail_if_incomplete)
      message = "the agent's turn ended and nothing decided step #{run.current} (idle for #{idle_for} seconds)"
      return row(run, "dry_run", message: message, cause: cause, action: "evaluate") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      # The proof is read again just before the change, so it is as fresh as the lock allows.
      fresh = @panes.pane_row(run.workspace, pane)
      unless fresh && fresh["kind"] == shown["kind"] && WorkflowPanes.turn_over?(fresh, @clock.call) && fresh["idle_seconds"].to_i >= IDLE_FLOOR
        return row(run, "nothing", reason: "pane_changed", message: "pane #{pane} no longer shows the agent's turn over; the next pass looks again", cause: cause)
      end
      outcome = @engine.recover(run.id, turn_over: {"step" => run.current, "attempt" => attempt.n}, cause: cause,
        data: {"idle_for" => idle_for}, fail_if_incomplete: fail_if_incomplete)
      engine_row(run, outcome, (outcome == :timed_out) ? "timed_out" : "evaluated", cause: cause, message: message, action: "evaluate")
    end

    # Claims under the run's lock, presses with it given up, confirms under it. For `fail` the confirmation is the failure itself.
    # With +cause+ `run_timed_out` it is the run's `timeout_action: interrupt`: its own mark and cause, so a step's
    # `on_timeout: interrupt` on the same attempt does not collide; +elapsed+ is the machine time used and +timeout+
    # the run's limit. It never fails the step, and the run is held by the next attempt's start, as for `hold`.
    def press_and_confirm(run, attempt, pass, shown, pane, elapsed, timeout, then_fail:, cause: "timed_out")
      message = if cause == "run_timed_out"
        "the run has used #{elapsed.round} seconds of its #{timeout} second time limit"
      else
        "step #{run.current} is #{elapsed.round} seconds in, past its #{timeout} second timeout"
      end
      action = then_fail ? "fail" : "interrupt"
      held = WorkflowEngine.sweep_marks(run.to_h)[(cause == "run_timed_out") ? "run_interrupt" : "interrupt"]
      return time_out(run, attempt, pass, elapsed, timeout, nil) if then_fail && held && held["state"] == "sent"
      keys = AgentProvider.find(shown["kind"].to_s)&.interrupt_keys.to_a
      if keys.empty?
        return row(run, "nothing", reason: "no_interrupt_key", cause: cause, message: "#{message}, and workspace knows no interrupt key for #{shown["kind"] || "this agent"}")
      end
      return row(run, "dry_run", message: message, cause: cause, action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      step_ref = {step: run.current, attempt: attempt.n}
      claim, claim_at = @engine.claim_interrupt(run.id, **step_ref, elapsed: elapsed, timeout: timeout, cause: cause)
      unless claim == :claimed
        return row(run, "nothing", reason: "already_interrupted", message: message, cause: cause) if claim == :repeat
        return engine_row(run, claim, "interrupted", cause: cause, message: message, action: action)
      end
      unless still_working?(run, pane, shown)
        @engine.interrupt_sent(run.id, **step_ref, claim_at: claim_at, sent: false, cause: cause)
        return row(run, "nothing", reason: "pane_changed", message: "pane #{pane} no longer shows the agent working in this run; nothing was pressed", cause: cause)
      end
      failure = press(run, pane, keys)
      @engine.interrupt_sent(run.id, **step_ref, claim_at: claim_at, sent: failure.nil?, record: !then_fail, cause: cause)
      return row(run, "failed", reason: "interrupt_failed", message: "could not interrupt pane #{pane}: #{failure}", cause: cause, action: action) if failure
      return row(run, "interrupted", message: message, cause: cause, action: action) unless then_fail
      time_out(run, attempt, pass, elapsed, timeout, "the agent was interrupted")
    end

    def press_for_run_deadline(run, attempt, pass, shown, pane, deadline)
      unless shown["state"] == "working"
        return row(run, "nothing", reason: "not_working", cause: "run_timed_out", message: "the run's time limit is used, but pane #{pane} does not show the agent working")
      end
      press_and_confirm(run, attempt, pass, shown, pane, deadline["used"], deadline["limit"], then_fail: false, cause: "run_timed_out")
    end

    # Read just before the press: the same agent still works in the pane, and the pane is still this run's.
    def still_working?(run, pane, shown)
      fresh = @panes.pane_row(run.workspace, pane)
      !fresh.nil? && fresh["state"] == "working" && fresh["kind"] == shown["kind"] && @panes.run_on(pane) == run.id
    end

    def time_out(run, attempt, pass, elapsed, timeout, note)
      message = "step #{run.current} is #{elapsed.round} seconds in, past its #{timeout} second timeout#{" (#{note})" if note}"
      return row(run, "dry_run", message: message, cause: "timed_out", action: "fail") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "timed_out") if refusal
      outcome = @engine.time_out(run.id, step: run.current, attempt: attempt.n, elapsed: elapsed, timeout: timeout)
      engine_row(run, outcome, "timed_out", cause: "timed_out", message: message, action: "fail")
    end

    # nil once the keys are pressed; otherwise why they were not.
    def press(run, pane, keys)
      @interrupter.call(run.workspace, pane, keys)
      nil
    rescue Workspace::Error => e
      e.message.lines.first.to_s.strip
    end

    # The engine's answer for a change the sweep tried, as a row.
    def engine_row(run, outcome, done, **rest)
      case outcome
      when :repeat then row(run, "nothing", reason: "already_recorded", **rest.except(:action))
      when :moved_on then row(run, "nothing", reason: "moved_on", **rest.except(:action), message: "the run moved on while it was being looked at; nothing was changed")
      when :busy then row(run, "nothing", reason: "busy", **rest.except(:action), message: "another process is changing the run; the next pass looks again")
      else row(run, done, **rest)
      end
    end

    def attempt_of(run)
      run.step(run.current)&.last_attempt&.n
    end

    def row(run, outcome, reason: nil, message: nil, cause: nil, action: nil)
      {"workspace" => run.workspace, "outcome" => outcome, "reason" => reason, "message" => message, "run_id" => run.id,
       "step" => run.current, "attempt" => attempt_of(run), "cause" => cause, "action" => action}
    end
  end
end
