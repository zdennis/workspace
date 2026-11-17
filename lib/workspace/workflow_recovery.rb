require "time"

module Workspace
  # What wakes or puts right a run nothing else will move: the periodic {#tick} (a backoff that is over, a lock
  # wait, a background hold that ran out, a check that never reported back) and the sweep's acts on a step it found
  # stalled ({#note_stall}, {#note_recovery}, {#recover}, {#time_out}, {#redeliver}, {#retry_backoff},
  # {#claim_interrupt}, {#interrupt_sent}). Each change is made under the run's lock for the step and attempt the
  # sweep saw, and each cause is recorded once per attempt in the run's `sweep` marks. What follows goes through
  # {WorkflowDispatch}, {WorkflowProgress} and {WorkflowEvaluation}.
  class WorkflowRecovery
    # Seconds a pending interrupt claim holds before another sweep may take it over ({WorkflowTransitions::INTERRUPT_CLAIM_SECONDS}).
    INTERRUPT_CLAIM_SECONDS = WorkflowTransitions::INTERRUPT_CLAIM_SECONDS

    # The stall causes an infra retry restarts the step for ({#note_stall} with +infra_retry+).
    INFRA_RETRY_CAUSES = %w[pane_gone agent_gone].freeze

    # Refusals a person's own act holds (a pause), or that pass in a moment (a line being typed): the claim leaves
    # the retry scheduled instead of giving it up.
    INFRA_RETRY_HELD = %w[run_paused step_still_working].freeze

    # The one form of an infra retry's claimant, as stored in its mark's `claimed_by`.
    #
    # @param claimant [Hash] "pid" (Integer) and "started" (String), with String or Symbol keys
    # @return [Hash{String=>Object}] "pid" and "started"
    # @raise [ArgumentError] when either is missing
    def self.infra_retry_claimant(claimant)
      pid = claimant.is_a?(Hash) ? claimant["pid"] || claimant[:pid] : nil
      started = claimant.is_a?(Hash) ? claimant["started"] || claimant[:started] : nil
      unless pid.is_a?(Integer) && started.is_a?(String) && !started.empty?
        raise ArgumentError, "an infra retry's claimant needs an Integer pid and a String started, got #{claimant.inspect}"
      end
      {"pid" => pid, "started" => started}
    end

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] gets the `step_recovered` line of a redelivery
    # @param dispatch [Workspace::WorkflowDispatch] starts a step again after a lock wait or a failed delivery
    # @param progress [Workspace::WorkflowProgress] starts a retry and fails a step that timed out
    # @param evaluation [Workspace::WorkflowEvaluation] decides a step whose turn ended, and runs its check
    # @param holder_alive [#call, nil] given a review round's delivery `holder`, whether that process still runs, so a
    #   lapsed round is delivered again only once its holder is gone (nil takes every holder as alive)
    # @param panes [Workspace::WorkflowPanes, nil] says whether a review pane's turn is proven over ({WorkflowPanes#main_turn_over?})
    #   or the pane is gone, and whether a `continue_pending` pane is idle and still the process marked, read with the
    #   run's lock not yet taken; nil takes every such pane as done and types no continue line
    # @param downtime [Workspace::WorkflowDowntime, nil] its spans are cut from the review round clocks a tick reads (nil: none)
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, progress:, evaluation:, holder_alive: nil, panes: nil, downtime: nil, clock: -> { Time.now })
      @downtime = downtime
      @change = change
      @store = store
      @dispatch = dispatch
      @progress = progress
      @evaluation = evaluation
      @holder_alive = holder_alive
      @panes = panes
      @clock = clock
    end

    # The periodic look at a run nothing else will wake: one whose `on_fail` backoff is over starts its retry, one
    # waiting for a lock asks for it again (a review round's through {WorkflowProgress#restart_review}), a hold for background tasks that passed
    # {WorkflowTransitions::BACKGROUND_HOLD} becomes a `turn_ended_incomplete` stop, a check that never
    # reported back (its process died) is run again, and so is the end of a review round whose revision was being
    # computed again when its process died ({WorkflowTransitions.lost_round?}; {WorkflowEvaluation#review_ended},
    # which tries it once more, then stops `review_incomplete`). A review round whose delivery failed (after its
    # backoff) or lapsed with its holder gone is delivered again ({WorkflowProgress#redeliver_round}), spending one of
    # its `redeliveries`; once they are spent (or the failure is one no delivery gets past) the round stops
    # `review_incomplete` instead. A slow delivery whose holder is alive is left alone. A delivered round the sweep
    # pressed for a time limit whose turn has not ended {WorkflowTransitions.press_wait} after the newest press
    # ({WorkflowTransitions.unanswered_round?}) is decided on the verdicts written (`step_stalled` cause
    # `interrupt_unanswered`), stopping `review_incomplete` when they fall short, so no scheduled sweep is needed for it
    # to end. A `continue_pending` mark an unpause left ({WorkflowDecisions#unpause}) gets its one continue line once
    # the pane proves idle (read before the lock is taken): the mark is dropped under the lock and the line typed
    # after it ({WorkflowDispatch#type_continue}, which puts the mark back when the line is refused); a pane whose
    # process is no longer the one marked drops the mark with nothing typed, and so does a mark older than
    # {WorkflowTransitions::PARK_SECONDS} (`how: "expired"`). Does nothing while another process is changing the run.
    #
    # @param run_id [String]
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [WorkflowRun, nil] the run afterwards; nil when nothing was done
    def tick(run_id, actor:)
      follow = nil
      acted = false
      alive = holder_alive_once
      # Read before the lock is taken: no tmux or daemon call is made under it.
      typed = typed_pane_over(run_id, alive)
      ready = continue_ready(run_id)
      stops = @downtime&.spans(@clock.call) || []
      continuing = nil
      run = @change.call(run_id, actor: actor, cause: "tick", nonblocking: true) do |read, ctx|
        stored = read.thawed
        case WorkflowTransitions.wakeable?(stored, @clock.call, alive: alive, stops: stops)
        when :continue
          continuing = take_continue(stored, ready)
          acted = !continuing.nil?
          continuing = nil if continuing == :dropped
        when :continue_expired
          acted = true
          expire_continue(stored)
        when :backoff
          acted = true
          start_retry(stored, ctx, "backoff_ended")
        when :infra_retry
          # `workflow advance` restarts the agent outside the lock (tmux and daemon calls); tick does nothing.
          nil
        when :lock
          acted = true
          # A review round waiting for its `review.uses` asks for the lock again through the round's own start, never
          # an author attempt; still taken, nothing changes.
          if stored.dig("steps", stored["current"], "state") == "reviewing"
            stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
          else
            dispatch(stored, ctx, "lock_ended")
          end
        when :background
          acted = true
          expire_background(stored)
        when :round
          acted = true
          stored.replace(@evaluation.review_ended(stored, ctx: ctx).thawed)
        when :unanswered
          acted = true
          decide_unanswered(stored, ctx)
        when :review
          acted = redeliver_round(stored, ctx, alive, typed, stops) == :acted
        when :check
          acted = true
          evaluate(stored, ctx)
        end
        follow = ctx
        WorkflowRun.from_h(stored)
      end
      return nil unless run && acted
      if continuing
        @dispatch.type_continue(run_id, continuing, workspace: run.workspace, text: WorkflowTransitions.continue_line(run.to_h), actor: actor, cause: "tick")
        return run
      end
      @evaluation.finish_follow_ups(run_id, follow, run)
    end

    # Records that the step stands in a stall the sweep found, once for each attempt and cause, and changes
    # nothing else. Does not wait for another process that is changing the run.
    #
    # With +infra_retry+, a `pane_gone` or `agent_gone` stall noted for the first time also schedules an automatic
    # restart of the step in the same change, once per attempt: the `infra_retry` sweep mark (`cause`, `n`, `max`,
    # `scheduled_at`, `due`; `n` is the step's {WorkflowTransitions.infra_retries} plus one, `due` is `scheduled_at` plus
    # {WorkflowTransitions::REDELIVER_BACKOFF} entry `n - 1`) and an `infra_retry_scheduled` event (`step`, `attempt`,
    # `cause`, `n`, `max`, `due`). When `n` would pass `max` the same change gives the retry up instead, as
    # {#give_up_infra_retry} does with reason `retries_spent`: a given-up mark (`n` the step's count) and an
    # `infra_retries_exhausted` event, so a crash cannot leave the stall recorded and the exhaustion not.
    #
    # @param run_id [String]
    # @param step [String] the step the sweep saw the run on
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param cause [String] `pane_gone`, `agent_gone` or `daemon_down`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @param infra_retry [Hash{Symbol=>Integer}, nil] `{max:}`, the `workflows.infra_retry.max` to schedule under; nil schedules nothing
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :scheduled (recorded, with a retry scheduled), :exhausted (recorded, with the retries given up as
    #   spent), :recorded, :repeat (this cause was recorded for the
    #   attempt already), :moved_on (the run is elsewhere now) or :busy (another process is changing the run)
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def note_stall(run_id, actor:, step:, attempt:, cause:, data: {}, infra_retry: nil)
      sweep_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, running: false) do |stored|
        next :repeat unless mark_stall(stored, cause, data)
        (infra_retry && schedule_infra_retry(stored, cause, infra_retry.fetch(:max))) || :recorded
      end
    end

    # Records that a step's infra retry will not happen: `given_up` (`at`, `reason`) on the current attempt's
    # `infra_retry` mark, or a given-up mark when there is none (the sweep's `retries_spent`, with the step's count as
    # `n`), and an `infra_retries_exhausted` event (`step`, `attempt`, `cause`, `n`, `max`, `reason`), once per
    # attempt. Waits for the run's lock. The run stays as it is, stalled and resumable.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param cause [String] `pane_gone` or `agent_gone`
    # @param reason [String] why, e.g. `retries_spent`, `no_session`, `agent_not_ready` or a refusal's error code
    # @param max [Integer, nil] the max to record on a mark written here (a mark that exists keeps its own)
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :repeat (given up, or ended, already) or :moved_on
    def give_up_infra_retry(run_id, actor:, step:, attempt:, cause:, reason:, max: nil)
      sweep_change(run_id, actor: actor, cause: "infra_retry", step: step, attempt: attempt, running: false, blocking: true) do |stored|
        give_up(stored, cause, reason, max) ? :recorded : :repeat
      end
    end

    # Takes the right to restart a step whose infra retry is due, under the run's lock, before any pane is split or
    # daemon asked, so one due retry is restarted by one process. A claim younger than
    # {WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW} whose claimant +alive+ says still runs holds; an older one, or one
    # whose claimant is gone, is taken over as the next retry. Every refusal the run alone can answer gives the retry
    # up in the same change ({#give_up_infra_retry}): `claim_lost` for a claim taken over at `max`, +refusal+'s error
    # code, and `agent_kind_unsupported` for a run whose newest closed attempt recorded an agent other than Claude Code
    # (a run with none recorded is taken as Claude Code). A refusal that does not last ({INFRA_RETRY_HELD}: a pause, a
    # line being typed) or a resume parked on the run leaves the retry scheduled and answers :not_due, so it wakes again
    # once the hold is over. Otherwise `claimed_at` and `claimed_by` are written into the
    # mark, the step's `infra_retries` count is raised to the retry's `n`, and an `infra_retry_claimed` event (`step`,
    # `attempt`, `cause`, `n`, `max`, and `taken_over: true` for a claim taken over) is recorded.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claimant [Hash] the claiming process: "pid" and "started" ({.infra_retry_claimant})
    # @param alive [#call, nil] given a claim's `claimed_by`, whether that process still runs; nil takes it as alive
    # @param refusal [#call] given the stored run, the {Workspace::Error} a restart of it would be refused with, or nil
    #   ({WorkflowDecisions#restart_refusal})
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, Integer), Array(Symbol, String), Symbol] [:claimed, n]; [:gave_up, reason]; :not_due (no
    #   retry due, its claim held, a hold that does not last, or the run elsewhere)
    # @raise [ArgumentError] for a +claimant+ without both "pid" and "started"
    def claim_infra_retry(run_id, actor:, step:, attempt:, claimant:, alive:, refusal:)
      claimant = self.class.infra_retry_claimant(claimant)
      outcome = sweep_change(run_id, actor: actor, cause: "infra_retry", step: step, attempt: attempt, running: false, blocking: true) do |stored|
        info = WorkflowTransitions.infra_retry(stored, @clock.call)
        state = info&.fetch(:state)
        state = :stale_claim if state == :claimed && alive && !alive.call(info[:claimed_by])
        next :not_due unless %i[due stale_claim].include?(state)
        claim_or_give_up(stored, info, state == :stale_claim, claimant, refusal)
      end
      (outcome == :moved_on) ? :not_due : outcome
    end

    # Gives back a claimed infra retry whose restart was refused because the step's agent is at work again
    # (`step_still_working`), once per mark: the step's `infra_retries` count is lowered by one, the claim cleared,
    # `released: 1` set and `due` moved one wait ({WorkflowTransitions::REDELIVER_BACKOFF} entry `n - 1`) from now, with
    # an `infra_retry_released` event (`step`, `attempt`, `cause`, `n`, `due`). A mark released once already is given up
    # instead, with `reason: still_working`, and the count is not given back again. Only the claimant may release.
    # Waits for the run's lock.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claimant [Hash] "pid" and "started" of the process that claimed the retry
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol, Array(Symbol, String)] :released; [:gave_up, "still_working"]; :not_claimant (no mark, a given-up
    #   or ended one, or another process's claim; nothing is changed) or :moved_on
    # @raise [ArgumentError] for a +claimant+ without both "pid" and "started"
    def release_infra_retry(run_id, actor:, step:, attempt:, claimant:)
      claimant = self.class.infra_retry_claimant(claimant)
      sweep_change(run_id, actor: actor, cause: "infra_retry", step: step, attempt: attempt, running: false, blocking: true) do |stored|
        mark = WorkflowTransitions.sweep_marks(stored)["infra_retry"]
        state = WorkflowTransitions.infra_retry(stored, @clock.call)&.fetch(:state)
        next :not_claimant unless %i[claimed stale_claim].include?(state) && mark["claimed_by"] == claimant
        if mark["released"]
          give_up(stored, mark["cause"], "still_working", nil)
          next [:gave_up, "still_working"]
        end
        release(stored, mark)
        :released
      end
    end

    # Records that the sweep put right a stall it noted, once for each attempt and cause, and only for a cause
    # that was noted. Waits for the run's lock, so the record is not dropped for a busy run.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param cause [String] the cause given to {#note_stall}
    # @param action [String] e.g. `daemon_respawned`
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, actor:, step:, attempt:, cause:, action:)
      sweep_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        next :repeat unless WorkflowTransitions.sweep_marks(stored).dig("stalled", cause)
        mark_recovery(stored, cause, action) ? :recorded : :repeat
      end
    end

    # Ends the current attempt's open stalls ({WorkflowTransitions::STALL_CAUSES}) in a run being changed under its
    # lock, as {#note_recovery} ends one: the `recovered` mark, the stall's `until` and a `step_recovered` event for
    # each cause not yet recovered. For a change already under way, such as a person's resume that keeps the attempt.
    #
    # @param run [Hash{String=>Object}] the stored run being changed, written in place
    # @param action [String] the `step_recovered` action, e.g. `resumed`
    # @return [void]
    def close_stalls(run, action:)
      WorkflowTransitions.open_stalls(run).each { |cause| mark_recovery(run, cause, action) }
    end

    # Decides a step whose agent has ended its turn without anyone seeing it, as a resume does when it is given
    # the same proof (+turn_over+). Does nothing unless the run is still on that step and attempt, `running`, with
    # no reason and no park, so a resume that got there first stands.
    #
    # @param run_id [String]
    # @param turn_over [Hash{String=>Object}] "step" and "attempt": the pane's agent was seen to have ended its turn on that attempt
    # @param cause [String] why the sweep acts, e.g. `idle_turn_over`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @param fail_if_incomplete [Hash, nil] "elapsed" and "timeout" of a step past its `timeout:` with `on_timeout: fail`:
    #   when the decision is a `turn_ended_incomplete` stop, the step is failed with `step_timed_out` instead
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, actor:, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      sweep_change(run_id, actor: actor, cause: cause, step: turn_over["step"], attempt: turn_over["attempt"], running: true) do |stored, ctx|
        mark_stall(stored, cause, data)
        mark_recovery(stored, cause, "evaluated")
        evaluate(stored, ctx)
        next :evaluated unless fail_if_incomplete && stored.dig("reason", "code") == "turn_ended_incomplete"
        fail_timed_out(stored, fail_if_incomplete["elapsed"], fail_if_incomplete["timeout"], ctx)
        :timed_out
      end
    end

    # Fails a step that ran past its `timeout:`, by the road a failed check takes (`on_fail`, then a stop for a
    # person), with `details.code` `step_timed_out`. A step held on `turn_ended_incomplete` is failed too. Waits
    # for the run's lock: it follows {#claim_interrupt} and {#interrupt_sent} when keys were pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, actor:, step:, attempt:, elapsed:, timeout:)
      sweep_change(run_id, actor: actor, cause: "timeout", step: step, attempt: attempt, running: :or_incomplete, blocking: true) do |stored, ctx|
        fail_timed_out(stored, elapsed, timeout, ctx)
        :timed_out
      end
    end

    # Types a step's line again after a delivery that failed, as the sweep's retry. Does nothing unless the run is
    # still on that step and attempt and {WorkflowTransitions.redelivery} says a retry is due, so a resume, a park
    # or a cancel that got there first stands. The failed attempt is marked `redelivered` (it no longer counts
    # against `max_attempts`), the cause `undelivered` is recorded once for it, and a new attempt starts exactly as
    # a resume starts one; the typing itself goes through {WorkflowPanes#kick}, which refuses a pane that is not idle.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the failed attempt the sweep saw
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :redelivered, :waiting_lock, :not_delivered, :moved_on or :busy
    def redeliver(run_id, actor:, step:, attempt:)
      outcome = :moved_on
      run = @change.call(run_id, actor: actor, cause: "redelivery", nonblocking: true) do |read, ctx|
        stored = read.thawed
        next unless sweep_target?(stored, step, attempt, false)
        info = WorkflowTransitions.redelivery(stored, @clock.call)
        next unless info && info[:state] == :due
        mark_stall(stored, "undelivered", {"code" => info[:code], "retry" => info[:retries] + 1, "of" => info[:limit]})
        step_state(stored)["attempts"].last["redelivered"] = true
        # Stamped on the next attempt by {WorkflowDispatch#dispatch}, which may be one `tick` starts after a lock wait.
        step_state(stored)["redelivery_pending"] = info[:retries] + 1
        outcome = :started
        @dispatch.dispatch(stored, ctx: ctx, cause: "redelivery", budgeted: false)
      end
      return :busy unless run
      return outcome unless outcome == :started
      # The line has been typed (or refused) by now: say what became of it.
      return :waiting_lock if run.reason&.dig("code") == "waiting_lock"
      return :not_delivered if run.step(step).last_attempt.outcome == "not_delivered"
      @store.record_event(run_id, "step_recovered", "step" => step, "attempt" => attempt, "action" => "redelivered", "actor" => actor, "cause" => "redelivery", "from_state" => nil, "to_state" => nil)
      :redelivered
    end

    # Acts on a review round the sweep found stalled in its review pane, as the sweep's act. Does nothing unless the
    # run is still on that step, attempt and round, `reviewing` with no reason and no park, its round delivered (no
    # mark), not being judged, and recorded in +pane+, so a turn's end, a resume or a cancel that got there first
    # stands. A `step_stalled` line (with `round`) is written, then by +cause+:
    #
    # - `idle_turn_over`: the review turn ended unseen; the round is decided as a turn's end decides it
    #   ({WorkflowEvaluation#review_ended})
    # - `pane_gone` (the review pane closed) or `agent_gone` (its agent exited to a shell): decided the same way, so
    #   verdicts already written count, and a round they leave short stops `review_incomplete`
    # - `interrupt_unanswered`: the sweep pressed the interrupt for every time limit due and the review pane still
    #   works long after; the round is decided on the verdicts written (it was interrupted, so no reviewer runs again),
    #   and stops `review_incomplete` with its window kept when they fall short
    # - `server_restarted`: the tmux server the pane was on is gone (a new one may reuse the pane id); the round is
    #   delivered again as {#tick} would ({WorkflowProgress#redeliver_round}, in a new window), or stops
    #   `review_incomplete` once its `redeliveries` are spent
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the reviewed attempt
    # @param round [Integer]
    # @param pane [String] the review pane the sweep read
    # @param cause [String] `idle_turn_over`, `interrupted`, `pane_gone`, `agent_gone`, `interrupt_unanswered` or `server_restarted`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :evaluated, :stopped (`server_restarted` with `redeliver` spent, or an `interrupt_unanswered`
    #   round that stands stopped for a person once its verdicts were read, the revision read again first when there is
    #   a revision reader), :redelivered, :moved_on or :busy
    def review_stalled(run_id, actor:, step:, attempt:, round:, pane:, cause:, data: {})
      outcome = :moved_on
      follow = nil
      run = @change.call(run_id, actor: actor, cause: cause, nonblocking: true) do |read, ctx|
        stored = read.thawed
        next unless round_target?(stored, step, attempt, round, pane)
        @change.event(stored, "step_stalled", {"step" => step, "attempt" => attempt, "round" => round, "pane" => pane, "cause" => cause}.merge(data))
        outcome = if cause == "server_restarted"
          server_restarted(stored, ctx, pane)
        elsif cause == "interrupt_unanswered"
          # Pressed for every time limit due and still at work: a review that finished by now still counts, and a
          # round its verdicts leave short stops for a person.
          # The answer is read from the run once the follow-ups ran: with a revision reader the round is only marked
          # here, and decided after the lock is given up.
          adopt(stored, @evaluation.review_ended(stored, ctx: ctx))
          :unanswered
        else
          # Verdicts written before the pane closed or its agent exited still count: the round is tallied as its
          # turn's end would tally it, and stops `review_incomplete` only when they fall short.
          adopt(stored, @evaluation.review_ended(stored, ctx: ctx))
          :evaluated
        end
        follow = ctx
        WorkflowRun.from_h(stored)
      end
      return :busy unless run
      after = @evaluation.finish_follow_ups(run_id, follow, run)
      return outcome unless outcome == :unanswered
      (after || run).reason ? :stopped : :evaluated
    end

    # Starts an `on_fail` retry whose backoff is over, as the sweep's act. Does nothing unless the run is still on
    # that step and attempt and {WorkflowTransitions.backoff} says the wait is over, so a resume, a cancel or a
    # tick that got there first stands.
    #
    # @param run_id [String]
    # @param step [String] the failed step the sweep saw
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :retried, :blocked (the pane is no longer the run's; the run waits for a person, nothing is
    #   spent), :held (the token budget is used; the run waits for a person), :moved_on or :busy
    def retry_backoff(run_id, actor:, step:, attempt:)
      outcome = :moved_on
      run = @change.call(run_id, actor: actor, cause: "backoff_ended", nonblocking: true) do |read, ctx|
        next unless sweep_target?(read.to_h, step, attempt, false)
        next unless WorkflowTransitions.backoff(read.to_h, @clock.call)&.fetch(:state) == :due
        retried = @progress.start_retry(read, ctx: ctx, cause: "backoff_ended")
        outcome = if retried.backoff&.dig("blocked") then :blocked
        elsif retried.budget_hold || retried.timeout_hold then :held
        else :retried
        end
        retried
      end
      run ? outcome : :busy
    end

    # Takes the right to interrupt a step past its `timeout:`, as a pending mark, so two sweeps at once press the
    # keys once. A pending mark older than {INTERRUPT_CLAIM_SECONDS} can be taken over. Follow it with
    # {#interrupt_sent}, with the lock given up while the keys are pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param elapsed [Numeric] seconds since the attempt began
    # @param timeout [Numeric] the step's `timeout:`
    # @param cause [String] `timed_out` (the step's `timeout:`), `run_timed_out` (the run's `timeout_action: interrupt`) or
    #   `budget_spent` (the run's token budget); each keeps its own mark ({WorkflowTransitions::INTERRUPT_MARK_KEYS}), so
    #   all may be due on one attempt; the sweep presses once per attempt, and that press serves every cause
    # @param details [Hash{String=>Object}, nil] what the `step_stalled` event carries besides the cause; by default
    #   `elapsed` and `timeout`, and `budget_spent` gives `used`, `allowance` and `live`
    # @param budget [Hash{Symbol=>Integer}, nil] for `budget_spent` only: `tokens` (the attempt's live figure), `used` and
    #   `allowance`, written on the attempt as `budget_interrupt` in the same change as the claim, so a retry that a
    #   hook-driven advance starts before {#interrupt_sent} is still held when the transcript tail cannot give the
    #   attempt's `usage` ({WorkflowBudget.reading}); other causes ignore it
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#interrupt_sent}; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, actor:, step:, attempt:, elapsed:, timeout:, cause: "timed_out", details: nil, budget: nil)
      at = nil
      details ||= {"elapsed" => elapsed.round, "timeout" => timeout}
      key = interrupt_key(cause)
      outcome = sweep_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, running: true) do |stored|
        marks = sweep_marks_for(stored)
        next :repeat if interrupt_held?(marks[key])
        at = now_iso
        marks[key] = {"state" => "pending", "at" => at}
        mark_stall(stored, cause, details)
        record_budget_interrupt(stored, budget, at) if cause == "budget_spent" && budget
        :claimed
      end
      (outcome == :claimed) ? [:claimed, at] : outcome
    end

    # Ends a {#claim_interrupt}. Sent: the mark becomes `sent`, and with +record+ the recovery is written. Not
    # sent: the claim is given back, so a later sweep tries again, and a `budget_spent` claim's `budget_interrupt`
    # record is dropped from the attempt, since no keys were pressed. Waits for the run's lock, so neither is dropped.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claim_at [String] the `at` {#claim_interrupt} gave; a claim another process took over since is left as it is
    # @param sent [Boolean] whether the keys were pressed
    # @param record [Boolean] write `step_recovered` (false when a {#time_out} follows and writes its own)
    # @param cause [String] the cause given to {#claim_interrupt}
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, actor:, step:, attempt:, claim_at:, sent:, record: true, cause: "timed_out")
      key = interrupt_key(cause)
      sweep_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        marks = sweep_marks_for(stored)
        next :taken_over unless marks.dig(key, "at") == claim_at
        unless sent
          marks.delete(key)
          step_state(stored)["attempts"].last&.delete("budget_interrupt") if cause == "budget_spent"
          next :released
        end
        marks[key] = {"state" => "sent", "at" => now_iso}
        mark_recovery(stored, cause, "interrupted") if record
        :recorded
      end
    end

    # Takes the right to interrupt a review round's pane past a time limit, as a pending mark on the round itself
    # ({WorkflowTransitions.round_sweep_marks}), so two sweeps at once press the keys once, and the reviewed attempt's
    # own marks (its author's interrupt) never stand for the round's. Each cause has its own mark, so the round's
    # `review.timeout` and the run's deadline each press once for the round. A pending mark older than
    # {INTERRUPT_CLAIM_SECONDS} can be taken over. Writes `step_stalled` (with the round) once per cause. Does nothing
    # unless the run is still on that step, attempt and round, delivered and undecided in +pane+. Follow it with
    # {#round_interrupt_sent}, with the lock given up while the keys are pressed.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the reviewed attempt
    # @param round [Integer]
    # @param pane [String] the review pane the sweep read
    # @param elapsed [Numeric] seconds used: the round's since its start, or the run's machine time
    # @param timeout [Numeric] the limit passed: the round's `review.timeout` or the run's `timeout:`
    # @param cause [String] `review_timed_out` or `run_timed_out`
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#round_interrupt_sent}; or
    #   :repeat, :moved_on or :busy
    def claim_round_interrupt(run_id, actor:, step:, attempt:, round:, pane:, elapsed:, timeout:, cause:)
      at = nil
      key = WorkflowTransitions::ROUND_INTERRUPT_KEYS.fetch(cause)
      outcome = round_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, round: round, pane: pane, strict: true) do |stored, found|
        marks = (found["sweep"] ||= {})
        next :repeat if interrupt_held?(marks[key])
        at = now_iso
        marks[key] = {"state" => "pending", "at" => at}
        stalled = (marks["stalled"] ||= {})
        unless stalled.key?(cause)
          stalled[cause] = at
          @change.event(stored, "step_stalled", {"step" => step, "attempt" => attempt, "round" => round, "pane" => pane, "cause" => cause,
                                                 "elapsed" => elapsed.round, "timeout" => timeout})
        end
        :claimed
      end
      (outcome == :claimed) ? [:claimed, at] : outcome
    end

    # Ends a {#claim_round_interrupt}. Sent: the mark becomes `sent` and `step_recovered` (action `interrupted`, with
    # the round) is written once; the round's turn the press ends is decided as any review turn's end is, on the
    # verdicts written, and runs no reviewer again ({WorkflowTransitions.round_interrupted}). Not sent: the claim is
    # given back, so a later sweep tries again. Waits for the run's lock, so neither is dropped; acts while the run is
    # on that step, attempt and round in +pane+, whether or not the round's end is being judged by now.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param round [Integer]
    # @param pane [String]
    # @param claim_at [String] the `at` {#claim_round_interrupt} gave; a claim another process took over since is left as it is
    # @param sent [Boolean] whether the keys were pressed
    # @param cause [String] the cause given to {#claim_round_interrupt}
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def round_interrupt_sent(run_id, actor:, step:, attempt:, round:, pane:, claim_at:, sent:, cause:)
      key = WorkflowTransitions::ROUND_INTERRUPT_KEYS.fetch(cause)
      round_change(run_id, actor: actor, cause: cause, step: step, attempt: attempt, round: round, pane: pane, strict: false, blocking: true) do |stored, found|
        marks = (found["sweep"] ||= {})
        next :taken_over unless marks.dig(key, "at") == claim_at
        unless sent
          marks.delete(key)
          next :released
        end
        marks[key] = {"state" => "sent", "at" => now_iso}
        recovered = (marks["recovered"] ||= {})
        unless recovered.key?(cause)
          recovered[cause] = now_iso
          @change.event(stored, "step_recovered", {"step" => step, "attempt" => attempt, "round" => round, "pane" => pane, "action" => "interrupted", "cause" => cause})
        end
        :recorded
      end
    end

    private

    # One change to the round the sweep read: the block gets the stored run and its round, changed in place, and
    # returns the outcome. +strict+ needs the round as {#round_target?} does (delivered, undecided, not being judged);
    # otherwise the run on that step, attempt and round in that pane with no stop is enough.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    def round_change(run_id, actor:, cause:, step:, attempt:, round:, pane:, strict:, blocking: false)
      outcome = :moved_on
      run = @change.call(run_id, actor: actor, cause: cause, nonblocking: !blocking) do |read|
        stored = read.thawed
        next unless strict ? round_target?(stored, step, attempt, round, pane) : same_round?(stored, step, attempt, round, pane)
        outcome = yield stored, step_state(stored)["review"]
        WorkflowRun.from_h(stored)
      end
      run ? outcome : :busy
    end

    # The run is on that step, attempt and round, in that pane, with no stop for a person.
    def same_round?(run, step, attempt, round, pane)
      return false if run["current"] != step || run["reason"] || run["parked"]
      state = step_state(run)
      found = state["review"]
      state["state"] == "reviewing" && state["attempts"].last&.fetch("n", nil) == attempt && found.is_a?(Hash) &&
        found["round"] == round && found["pane"] == pane && found["ended_at"].nil?
    end

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    # One change the sweep makes under the run's lock. The block returns the outcome (a check it registers on its
    # context is run after the lock is given up), and is run only for the step and attempt the sweep saw (and,
    # with +running+, only while that step reads `running` with no park and no line still on its way, and no
    # reason: +running+ `:or_incomplete` allows a `turn_ended_incomplete` stop). Without +blocking+ a run another
    # process is changing is :busy.
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    def sweep_change(run_id, actor:, cause:, step:, attempt:, running:, blocking: false)
      outcome = :moved_on
      follow = nil
      run = @change.call(run_id, actor: actor, cause: cause, nonblocking: !blocking) do |read, ctx|
        next unless sweep_target?(read.to_h, step, attempt, running)
        stored = read.thawed
        outcome = yield stored, ctx
        follow = ctx
        WorkflowRun.from_h(stored)
      end
      return :busy unless run
      @evaluation.finish_follow_ups(run_id, follow, run)
      outcome
    end

    def sweep_target?(run, step, attempt, running) = WorkflowTransitions.sweep_target?(run, step, attempt, running, @clock.call)

    # {#holder_alive} asked at most once per holder in one tick, so deciding to wake and then what to do reads the
    # process table once.
    def holder_alive_once
      return nil unless @holder_alive
      seen = {}
      ->(holder) { seen.fetch(holder) { seen[holder] = @holder_alive.call(holder) } }
    end

    # For a round whose line may have been typed, what its review pane shows, as :state: `:restarted` (the tmux server
    # the round recorded is gone, so a pane id the new one reuses is not the review pane), `:over` (the pane is gone,
    # its agent exited to a shell, or its turn is proven over), `:waiting` (Claude Code waits for an answer), `:busy`
    # (Claude Code at work, or sub-agents running: the line arrived), `:unreachable` (no agent daemon answers), else
    # `:unknown`; with the :pane, :round and
    # :started_at of the round it was read for. Nil for any other run. Never raises.
    # Before the lock: whether the `continue_pending` mark's pane is ready for its continue line (`:ready`, the mark
    # it was read for), its process is no longer the one marked (`:stale`), or neither yet (nil, which a pid tmux
    # can't name is too).
    def continue_ready(run_id)
      return nil unless @panes
      run = @store.run(run_id).to_h
      mark = run["continue_pending"]
      return nil if run["paused"] || WorkflowTransitions.continue_state(run, @clock.call) != :due
      pid = @panes.pane_pid(run["workspace"], mark["pane"])
      # tmux that lists nothing proves nothing: the mark waits, for the gone-pane path or its expiry to clear.
      return nil if pid.nil?
      return [:stale, mark] if pid != mark["pid"]
      ready = (mark["kind"] == "claude") ? @panes.main_turn_over?(run["workspace"], mark["pane"]) : @panes.idle?(run["workspace"], mark["pane"])
      ready ? [:ready, mark] : nil
    rescue Workspace::Error, SystemCallError
      nil
    end

    # Under the lock: drops the pending mark the read before it judged, when it is still the same mark. Answers the
    # mark to type the line for, :dropped for a stale mark, or nil when nothing changed (the pane not yet idle).
    def take_continue(run, ready)
      verdict, mark = ready
      return nil unless verdict && run["continue_pending"] == mark
      run.delete("continue_pending")
      how = (verdict == :stale) ? "pane_replaced" : "pane_idle"
      @change.event(run, "continue_pending_ended", {"step" => mark["step"], "attempt" => mark["attempt"], "pane" => mark["pane"], "how" => how})
      (verdict == :stale) ? :dropped : mark
    end

    # A pending continue line whose pane never proved idle within {WorkflowTransitions::PARK_SECONDS}: the mark goes
    # and nothing is typed; a step that stays stuck is the sweep's stall to handle.
    def expire_continue(run)
      mark = run.delete("continue_pending")
      @change.event(run, "continue_pending_ended", {"step" => mark["step"], "attempt" => mark["attempt"], "pane" => mark["pane"], "how" => "expired"})
    end

    def typed_pane_over(run_id, alive)
      return nil unless @panes
      run = @store.run(run_id)
      round = run.steps[run.current]&.review
      return nil unless round.is_a?(Hash) && round["pane"].is_a?(String)
      return nil unless WorkflowTransitions.typed_round?(round, @clock.call, alive: alive)
      pane = round["pane"]
      {pane: pane, round: round["round"], started_at: round["started_at"], state: typed_pane_state(run.workspace, pane, round["server_pid"])}
    rescue Workspace::Error, SystemCallError
      nil
    end

    def typed_pane_state(workspace, pane, server_pid)
      return :restarted if @panes.review_pane_state(workspace, pane, server_pid) == :server_restarted
      return :over if @panes.pane_gone?(pane, workspace: workspace)
      row = @panes.pane_row(workspace, pane)
      return :over if WorkflowPanes.agent_gone_row?(row)
      if row.is_a?(Hash) && row["kind"] == "claude"
        return :waiting if row["state"] == "waiting"
        return :busy if row["state"] == "working" || Array(row["subagents"]).any?
      end
      return :over if @panes.main_turn_over?(workspace, pane)
      @panes.daemon_running?(workspace) ? :unknown : :unreachable
    end

    # The round the sweep read is still the run's, delivered and undecided, in the pane it read.
    def round_target?(run, step, attempt, round, pane)
      return false if run["parked"] || run["reason"] || run["current"] != step
      state = step_state(run)
      found = state["review"]
      state["state"] == "reviewing" && state["attempts"].last&.fetch("n", nil) == attempt && found.is_a?(Hash) &&
        found["round"] == round && found["pane"] == pane && !found["recompute"] && found["ended_at"].nil? &&
        # A round whose line may have been typed is decided by its pane as a delivered one is.
        (found["delivery"].nil? || WorkflowTransitions.typed_round?(found, @clock.call, alive: holder_alive_once))
    end

    # A round due to be delivered again ({WorkflowTransitions.round_redelivery}) is delivered; one whose deliveries
    # again are spent stops `review_incomplete`. A round still waiting out its backoff is left.
    def redeliver_round(run, ctx, alive, typed = nil, stops = [])
      info = WorkflowTransitions.round_redelivery(run, @clock.call, alive: alive)
      return unless info
      # A line that may have been typed (an agent daemon that restarted while it typed) may have a finished review
      # behind it: the round is judged as a turn's end would judge it, the verdicts written count, and only the
      # reviewers still missing run again while deliveries are left. Only once the review pane's turn is proven over
      # (or the pane is gone): a reviewer still at work is waited for, and its own Stop may judge the round first.
      round = step_state(run)["review"]
      if info[:state] != :waiting && WorkflowTransitions.round_may_have_typed?(round, info[:mark])
        decision = (@panes && round["pane"]) ? judge_typed(run, round, typed, stops) : :judge
        return :waiting if decision == :wait
        if decision == :restart
          # Its window went with the old server: delivered again in a new one, the old server's panes dropped, as the
          # sweep's `server_restarted` does.
          server_restarted(run, ctx, round["pane"])
        elsif decision == :stop
          # A reviewer still at work past the review's timeout: a rerun would only meet that working pane again.
          stop_round(run, ctx, "the review pane #{round["pane"]} was still at work at twice the round's review timeout, " \
            "after its delivery failed (#{round.dig("failure", "code") || "lapsed"}), and no workflow sweep interrupted it; " \
            "a resume starts a fresh round and closes this window, stopping any reviewer still at work there, so look at the window first")
        else
          # Pressed and still at work past its wait: recorded as the sweep's `interrupt_unanswered` is.
          note_unanswered(run, round) if decision == :unanswered
          adopt(run, @evaluation.review_ended(run, ctx: ctx))
        end
        return :acted
      end
      case info[:state]
      when :due then adopt(run, @progress.redeliver_round(run, ctx: ctx))
      when :exhausted then stop_round(run, ctx, undelivered_problem(step_state(run)["review"], info))
      else return :waiting
      end
      :acted
    end

    # What becomes of a round whose line may have been typed, from what its review pane showed before the lock (read
    # for this same round): `:judge` (its verdicts read), `:unanswered` (read as well, after a press its reviewer did
    # not answer, recorded as `interrupt_unanswered`), `:restart` (its tmux server restarted: delivered again in a new
    # window, as {#review_stalled}'s `server_restarted`), `:stop` (`review_incomplete`) or `:wait`. Its turn proven
    # over, the pane gone or a shell where the agent was: judged at once. An agent at work in it (the line arrived):
    # waited for until the review's own `timeout` has passed since the line went out, then stopped, since a rerun
    # would meet the same working pane. Waiting for an answer (a permission prompt, a question): never judged by a
    # wait, since `workflow status` shows it waiting for a person. An agent daemon that can't be reached: waited for
    # until the review's timeout, then judged. Anything else (no row from the daemon, an idle pane whose turn is not
    # proven over, a reading for another round): judged once {WorkflowTransitions.typed_wait_over?} says so.
    def judge_typed(run, round, typed, stops)
      state = (typed && typed[:pane] == round["pane"] && typed[:round] == round["round"] && typed[:started_at] == round["started_at"]) ? typed[:state] : :unknown
      now = @clock.call
      case state
      when :over then :judge
      when :restarted then :restart
      when :waiting then :wait
      when :busy then busy_typed(run, round, now, stops)
      when :unreachable then WorkflowTransitions.typed_review_timed_out?(run, round, now, stops: stops) ? :judge : :wait
      else WorkflowTransitions.typed_wait_over?(run, round, now, stops: stops) ? :judge : :wait
      end
    end

    # A reviewer at work in a round whose line may have been typed is pressed by the sweep past the review's timeout,
    # through the round's own claim ({WorkflowReviewSweep}), and the turn that ends is judged; so it is waited for, and
    # stopped here only once twice that timeout has passed with no press ({WorkflowTransitions.typed_press_missed?}:
    # no sweep is running). Pressed and still at work {WorkflowTransitions.press_wait} after the newest press, it is
    # judged: interrupted, its verdicts decide it or it stops `review_incomplete`, with no reviewer run again.
    def busy_typed(run, round, now, stops)
      if WorkflowTransitions.round_interrupted(round, now)
        return WorkflowTransitions.press_unanswered?(run, round, now, stops: stops) ? :unanswered : :wait
      end
      WorkflowTransitions.typed_press_missed?(run, round, now, stops: stops) ? :stop : :wait
    end

    # A delivered round pressed and unanswered ({WorkflowTransitions.unanswered_round?}): recorded as the sweep's
    # `interrupt_unanswered` is, then decided on its verdicts ({WorkflowEvaluation#review_ended}).
    def decide_unanswered(run, ctx)
      note_unanswered(run, step_state(run)["review"])
      adopt(run, @evaluation.review_ended(run, ctx: ctx))
    end

    # The `step_stalled` line of a press its reviewer did not answer, as {#review_stalled} writes it for the sweep.
    def note_unanswered(run, round)
      waited = (@clock.call - WorkflowTransitions.round_last_press(round)).round
      @change.event(run, "step_stalled", {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil), "round" => round["round"],
                                          "pane" => round["pane"], "cause" => "interrupt_unanswered", "waited" => waited})
    end

    # The window went with its server, so the delivery again opens a new one ({WorkflowProgress#redeliver_round}
    # `new_server`); it counts against `redeliver` as a tick's does.
    def server_restarted(run, ctx, pane)
      retries = step_state(run)["review"]["redeliveries"].to_i
      limit = WorkflowDefinition.redeliver(run["definition"])
      if retries >= limit
        stop_round(run, ctx, "the tmux server review pane #{pane} was on was restarted, and the round was delivered again #{retries} time#{"s" unless retries == 1}, its `redeliver` limit")
        return :stopped
      end
      adopt(run, @progress.redeliver_round(run, ctx: ctx, new_server: true))
      :redelivered
    end

    def undelivered_problem(round, info)
      failure = round["failure"]
      what = failure.is_a?(Hash) ? "its delivery failed (#{failure["code"]}: #{failure["message"]})" : "its delivery lapsed and the process delivering it is gone"
      return "the round could not be delivered: #{what}, which delivering it again cannot get past" if info[:retries] < info[:limit]
      "the round could not be delivered: #{what}, and it was delivered again #{info[:retries]} time#{"s" unless info[:retries] == 1}, its `redeliver` limit"
    end

    # The round stops for a person as an incomplete one does ({WorkflowProgress#decide_review}); its window is kept.
    def stop_round(run, ctx, problem)
      adopt(run, @progress.decide_review(run, {outcome: :incomplete, reviews: [], problem: problem}, ctx: ctx))
    end

    def sweep_marks_for(run)
      marks = WorkflowTransitions.sweep_marks(run)
      return marks unless marks.empty?
      run["sweep"] = {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil), "stalled" => {}, "recovered" => {}}
    end

    def record_budget_interrupt(run, budget, at)
      attempt = step_state(run)["attempts"].last
      return unless attempt
      attempt["budget_interrupt"] = {"tokens" => budget[:tokens], "used" => budget[:used], "allowance" => budget[:allowance], "at" => at}
    end

    def interrupt_key(cause) = WorkflowTransitions::INTERRUPT_MARK_KEYS.fetch(cause, "interrupt")

    def interrupt_held?(claim)
      return false unless claim
      return true if claim["state"] == "sent"
      @clock.call - Time.iso8601(claim["at"].to_s) < INTERRUPT_CLAIM_SECONDS
    rescue ArgumentError
      false
    end

    # Writes the cause once for each attempt; false when this attempt has it already.
    def mark_stall(run, cause, data)
      stalled = (sweep_marks_for(run)["stalled"] ||= {})
      return false if stalled.key?(cause)
      stalled[cause] = stamp = now_iso
      open_stall(run, cause, stamp)
      @change.event(run, "step_stalled", sweep_event(run, {"cause" => cause}.merge(data)))
      true
    end

    def mark_recovery(run, cause, action)
      recovered = (sweep_marks_for(run)["recovered"] ||= {})
      close_stall(run, cause)
      # The claimant's own restart is the retry's outcome: it closes this attempt, and the new one has no mark.
      end_infra_retry(run, cause, action) unless action == "restarted"
      return false if recovered.key?(cause)
      recovered[cause] = now_iso
      @change.event(run, "step_recovered", sweep_event(run, "action" => action, "cause" => cause))
      true
    end

    # Writes the `infra_retry` mark and its `infra_retry_scheduled` event for a stall just noted (:scheduled), or,
    # when this retry would pass +max+, gives the retry up as `retries_spent` (:exhausted); nil when the cause is not
    # one a restart gets past or the attempt has a mark already.
    def schedule_infra_retry(run, cause, max)
      marks = sweep_marks_for(run)
      return nil unless INFRA_RETRY_CAUSES.include?(cause) && !marks.key?("infra_retry") && max.is_a?(Integer)
      n = WorkflowTransitions.infra_retries(run, run["current"]) + 1
      return (give_up(run, cause, "retries_spent", max) ? :exhausted : nil) if n > max
      at = @clock.call
      due = (at + WorkflowTransitions.infra_retry_wait(n)).utc.iso8601
      marks["infra_retry"] = {"cause" => cause, "n" => n, "max" => max, "scheduled_at" => at.utc.iso8601, "due" => due}
      @change.event(run, "infra_retry_scheduled", sweep_event(run, "cause" => cause, "n" => n, "max" => max, "due" => due))
      :scheduled
    end

    # Sets `given_up` on the current attempt's mark (writing one when there is none) and records
    # `infra_retries_exhausted`; false when the mark has given up or ended already.
    def give_up(run, cause, reason, max)
      marks = sweep_marks_for(run)
      mark = marks["infra_retry"]
      return false if mark.is_a?(Hash) && (mark["given_up"] || mark["ended"])
      mark = marks["infra_retry"] = {"cause" => cause, "n" => WorkflowTransitions.infra_retries(run, run["current"]), "max" => max} unless mark.is_a?(Hash)
      mark["given_up"] = {"at" => now_iso, "reason" => reason}
      @change.event(run, "infra_retries_exhausted", sweep_event(run, "cause" => mark["cause"], "n" => mark["n"], "max" => mark["max"], "reason" => reason))
      true
    end

    # Under the lock, for a due retry or a claim to take over: leaves it for a hold that does not last, gives up on
    # the first lasting refusal, else claims.
    def claim_or_give_up(run, info, taken_over, claimant, refusal)
      return :not_due if WorkflowTransitions.parked(run, @clock.call) == :waiting
      reason = if taken_over && info[:max].is_a?(Integer) && info[:n] >= info[:max]
        "claim_lost"
      else
        refusal.call(run)&.code || ("agent_kind_unsupported" unless restartable_agent?(run))
      end
      return :not_due if INFRA_RETRY_HELD.include?(reason)
      if reason
        give_up(run, info[:cause], reason, nil)
        return [:gave_up, reason]
      end
      n = taken_over ? info[:n] + 1 : info[:n]
      mark = WorkflowTransitions.sweep_marks(run)["infra_retry"]
      mark.merge!("n" => n, "claimed_at" => now_iso, "claimed_by" => claimant)
      run["infra_retries"] = {} unless run["infra_retries"].is_a?(Hash)
      run["infra_retries"][run["current"]] = n
      @change.event(run, "infra_retry_claimed", sweep_event(run, "cause" => mark["cause"], "n" => n, "max" => mark["max"])
        .merge(taken_over ? {"taken_over" => true} : {}))
      [:claimed, n]
    end

    def release(run, mark)
      step = run["current"]
      run["infra_retries"][step] = [WorkflowTransitions.infra_retries(run, step) - 1, 0].max if run["infra_retries"].is_a?(Hash)
      mark.delete("claimed_at")
      mark.delete("claimed_by")
      mark["released"] = 1
      mark["due"] = (@clock.call + WorkflowTransitions.infra_retry_wait(mark["n"].is_a?(Integer) ? mark["n"] : 1)).utc.iso8601
      @change.event(run, "infra_retry_released", sweep_event(run, "cause" => mark["cause"], "n" => mark["n"], "due" => mark["due"]))
    end

    # A stall that ends without a restart ends the retry scheduled for it, once; a given-up retry is over already.
    def end_infra_retry(run, cause, action)
      mark = WorkflowTransitions.sweep_marks(run)["infra_retry"]
      return unless mark.is_a?(Hash) && mark["cause"] == cause && !mark["ended"] && !mark["given_up"]
      mark["ended"] = {"at" => now_iso, "reason" => action}
      @change.event(run, "infra_retry_ended", sweep_event(run, "cause" => cause, "n" => mark["n"], "reason" => action))
    end

    # Only Claude Code panes are restarted (the dispatch types `/clear`). The run's agent is the one its newest closed
    # attempt recorded; a run with none recorded yet is taken as Claude Code.
    def restartable_agent?(run)
      attempts = run["steps"].values.flat_map { |state| Array(state["attempts"]) }.grep(Hash)
      latest = attempts.select { |each| each["ended_at"].is_a?(String) && each.dig("agent", "kind").is_a?(String) }.max_by { |each| each["ended_at"] }
      latest.nil? || latest.dig("agent", "kind") == "claude"
    end

    def open_stall(run, cause, since)
      return unless WorkflowTransitions::STALL_CAUSES.include?(cause)
      attempt = step_state(run)["attempts"].last
      (attempt["stalls"] ||= []) << {"cause" => cause, "since" => since} if attempt
    end

    def close_stall(run, cause)
      return unless WorkflowTransitions::STALL_CAUSES.include?(cause)
      entry = step_state(run)["attempts"].last&.fetch("stalls", nil)&.reverse&.find { |e| e["cause"] == cause && !e.key?("until") }
      entry["until"] = now_iso if entry
    end

    def fail_timed_out(run, elapsed, timeout, ctx)
      mark_stall(run, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
      mark_recovery(run, "timed_out", "failed")
      failure = {"cause" => "timeout", "timeout" => timeout, "elapsed" => elapsed.round}.merge(WorkflowTransitions.code_for("step_timed_out", nil))
      adopt(run, @progress.fail_step(run, failure, ctx: ctx))
    end

    def sweep_event(run, data)
      {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)}.merge(data)
    end

    def now_iso
      @clock.call.utc.iso8601
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def start_retry(run, ctx, cause) = adopt(run, @progress.start_retry(run, ctx: ctx, cause: cause))

    def dispatch(run, ctx, cause, **options) = adopt(run, @dispatch.dispatch(run, ctx: ctx, cause: cause, **options))

    def evaluate(run, ctx) = adopt(run, @evaluation.evaluate(run, ctx: ctx))

    # No turn ended, so the step is neither passed nor checked: the hold only becomes the stop it was hiding,
    # with a `since` of its own.
    def expire_background(run)
      held = run["reason"]["details"]
      details = held.slice("step", "attempt", "missing", "stale", "invalid").merge("background_tasks" => held["tasks"])
      run["reason"] = {"code" => "turn_ended_incomplete", "since" => now_iso, "details" => details}
    end
  end
end
