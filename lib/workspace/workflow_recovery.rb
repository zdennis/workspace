require "time"

module Workspace
  # What wakes or puts right a run nothing else will move: the periodic {#tick} (a backoff that is over, a lock
  # wait, a background hold that ran out, a check that never reported back) and the sweep's acts on a step it found
  # stalled ({#note_stall}, {#note_recovery}, {#recover}, {#time_out}, {#redeliver}, {#retry_backoff},
  # {#claim_interrupt}, {#interrupt_sent}). Each change is made under the run's lock for the step and attempt the
  # sweep saw, and each cause is recorded once per attempt in the run's `sweep` marks. What follows goes through
  # {WorkflowDispatch}, {WorkflowProgress} and {WorkflowEvaluation}.
  class WorkflowRecovery
    # Seconds a pending interrupt claim holds before another sweep may take it over: the process that took it
    # died between the claim and the press.
    INTERRUPT_CLAIM_SECONDS = 60

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] gets the `step_recovered` line of a redelivery
    # @param dispatch [Workspace::WorkflowDispatch] starts a step again after a lock wait or a failed delivery
    # @param progress [Workspace::WorkflowProgress] starts a retry and fails a step that timed out
    # @param evaluation [Workspace::WorkflowEvaluation] decides a step whose turn ended, and runs its check
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, progress:, evaluation:, clock: -> { Time.now })
      @change = change
      @store = store
      @dispatch = dispatch
      @progress = progress
      @evaluation = evaluation
      @clock = clock
    end

    # The periodic look at a run nothing else will wake: one whose `on_fail` backoff is over starts its retry, one
    # waiting for a lock asks for it again, a hold for background tasks that passed
    # {WorkflowTransitions::BACKGROUND_HOLD} becomes a `turn_ended_incomplete` stop, and a check that never
    # reported back (its process died) is run again. Does nothing while another process is changing the run.
    #
    # @param run_id [String]
    # @return [WorkflowRun, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      check = nil
      acted = false
      run = @change.call(run_id, nonblocking: true) do |read, ctx|
        stored = read.to_mutable_h
        case WorkflowTransitions.wakeable?(stored, @clock.call)
        when :backoff
          acted = true
          start_retry(stored, ctx)
        when :lock
          acted = true
          dispatch(stored, ctx)
        when :background
          acted = true
          expire_background(stored)
        when :check
          acted = true
          evaluate(stored, ctx)
        end
        check = ctx.check
        WorkflowRun.from_h(stored)
      end
      return nil unless run && acted
      check ? @evaluation.finish_check(run_id, check) : run
    end

    # Records that the step stands in a stall the sweep found, once for each attempt and cause, and changes
    # nothing else. Does not wait for another process that is changing the run.
    #
    # @param run_id [String]
    # @param step [String] the step the sweep saw the run on
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param cause [String] `pane_gone`, `agent_gone` or `daemon_down`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @return [Symbol] :recorded, :repeat (this cause was recorded for the attempt already), :moved_on (the run
    #   is elsewhere now) or :busy (another process is changing the run)
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def note_stall(run_id, step:, attempt:, cause:, data: {})
      sweep_change(run_id, step: step, attempt: attempt, running: false) { |stored| mark_stall(stored, cause, data) ? :recorded : :repeat }
    end

    # Records that the sweep put right a stall it noted, once for each attempt and cause, and only for a cause
    # that was noted. Waits for the run's lock, so the record is not dropped for a busy run.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param cause [String] the cause given to {#note_stall}
    # @param action [String] e.g. `daemon_respawned`
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, step:, attempt:, cause:, action:)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        next :repeat unless WorkflowTransitions.sweep_marks(stored).dig("stalled", cause)
        mark_recovery(stored, cause, action) ? :recorded : :repeat
      end
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
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      sweep_change(run_id, step: turn_over["step"], attempt: turn_over["attempt"], running: true) do |stored, ctx|
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
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, step:, attempt:, elapsed:, timeout:)
      sweep_change(run_id, step: step, attempt: attempt, running: :or_incomplete, blocking: true) do |stored, ctx|
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
    # @return [Symbol] :redelivered, :waiting_lock, :not_delivered, :moved_on or :busy
    def redeliver(run_id, step:, attempt:)
      outcome = :moved_on
      run = @change.call(run_id, nonblocking: true) do |read, ctx|
        stored = read.to_mutable_h
        next unless sweep_target?(stored, step, attempt, false)
        info = WorkflowTransitions.redelivery(stored, @clock.call)
        next unless info && info[:state] == :due
        mark_stall(stored, "undelivered", {"code" => info[:code], "retry" => info[:retries] + 1, "of" => info[:limit]})
        step_state(stored)["attempts"].last["redelivered"] = true
        # Stamped on the next attempt by {WorkflowDispatch#dispatch}, which may be one `tick` starts after a lock wait.
        step_state(stored)["redelivery_pending"] = info[:retries] + 1
        outcome = :started
        @dispatch.dispatch(stored, ctx: ctx, budgeted: false)
      end
      return :busy unless run
      return outcome unless outcome == :started
      # The line has been typed (or refused) by now: say what became of it.
      return :waiting_lock if run.reason&.dig("code") == "waiting_lock"
      return :not_delivered if run.step(step).last_attempt.outcome == "not_delivered"
      @store.record_event(run_id, "step_recovered", "step" => step, "attempt" => attempt, "action" => "redelivered")
      :redelivered
    end

    # Starts an `on_fail` retry whose backoff is over, as the sweep's act. Does nothing unless the run is still on
    # that step and attempt and {WorkflowTransitions.backoff} says the wait is over, so a resume, a cancel or a
    # tick that got there first stands.
    #
    # @param run_id [String]
    # @param step [String] the failed step the sweep saw
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @return [Symbol] :retried, :blocked (the pane is no longer the run's; the run waits for a person, nothing is
    #   spent), :held (the token budget is used; the run waits for a person), :moved_on or :busy
    def retry_backoff(run_id, step:, attempt:)
      outcome = :moved_on
      run = @change.call(run_id, nonblocking: true) do |read, ctx|
        next unless sweep_target?(read.to_h, step, attempt, false)
        next unless WorkflowTransitions.backoff(read.to_h, @clock.call)&.fetch(:state) == :due
        retried = @progress.start_retry(read, ctx: ctx)
        outcome = if retried.backoff&.dig("blocked") then :blocked
        elsif retried.budget_hold then :held
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
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#interrupt_sent}; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:)
      at = nil
      outcome = sweep_change(run_id, step: step, attempt: attempt, running: true) do |stored|
        marks = sweep_marks_for(stored)
        next :repeat if interrupt_held?(marks["interrupt"])
        at = now_iso
        marks["interrupt"] = {"state" => "pending", "at" => at}
        mark_stall(stored, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
        :claimed
      end
      (outcome == :claimed) ? [:claimed, at] : outcome
    end

    # Ends a {#claim_interrupt}. Sent: the mark becomes `sent`, and with +record+ the recovery is written. Not
    # sent: the claim is given back, so a later sweep tries again. Waits for the run's lock, so neither is dropped.
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil]
    # @param claim_at [String] the `at` {#claim_interrupt} gave; a claim another process took over since is left as it is
    # @param sent [Boolean] whether the keys were pressed
    # @param record [Boolean] write `step_recovered` (false when a {#time_out} follows and writes its own)
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        marks = sweep_marks_for(stored)
        next :taken_over unless marks.dig("interrupt", "at") == claim_at
        unless sent
          marks.delete("interrupt")
          next :released
        end
        marks["interrupt"] = {"state" => "sent", "at" => now_iso}
        mark_recovery(stored, "timed_out", "interrupted") if record
        :recorded
      end
    end

    private

    # One change the sweep makes under the run's lock. The block returns the outcome (a check it registers on its
    # context is run after the lock is given up), and is run only for the step and attempt the sweep saw (and,
    # with +running+, only while that step reads `running` with no park and no line still on its way, and no
    # reason: +running+ `:or_incomplete` allows a `turn_ended_incomplete` stop). Without +blocking+ a run another
    # process is changing is :busy.
    def sweep_change(run_id, step:, attempt:, running:, blocking: false)
      outcome = :moved_on
      check = nil
      run = @change.call(run_id, nonblocking: !blocking) do |read, ctx|
        next unless sweep_target?(read.to_h, step, attempt, running)
        stored = read.to_mutable_h
        outcome = yield stored, ctx
        check = ctx.check
        WorkflowRun.from_h(stored)
      end
      return :busy unless run
      @evaluation.finish_check(run_id, check) if check
      outcome
    end

    def sweep_target?(run, step, attempt, running) = WorkflowTransitions.sweep_target?(run, step, attempt, running, @clock.call)

    def sweep_marks_for(run)
      marks = WorkflowTransitions.sweep_marks(run)
      return marks unless marks.empty?
      run["sweep"] = {"step" => run["current"], "attempt" => step_state(run)["attempts"].last&.fetch("n", nil), "stalled" => {}, "recovered" => {}}
    end

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
      stalled[cause] = now_iso
      @change.event(run, "step_stalled", sweep_event(run, {"cause" => cause}.merge(data)))
      true
    end

    def mark_recovery(run, cause, action)
      recovered = (sweep_marks_for(run)["recovered"] ||= {})
      return false if recovered.key?(cause)
      recovered[cause] = now_iso
      @change.event(run, "step_recovered", sweep_event(run, "action" => action))
      true
    end

    def fail_timed_out(run, elapsed, timeout, ctx)
      mark_stall(run, "timed_out", {"elapsed" => elapsed.round, "timeout" => timeout})
      mark_recovery(run, "timed_out", "failed")
      failure = {"cause" => "timeout", "timeout" => timeout, "elapsed" => elapsed.round}.merge(WorkflowTransitions.code_for("step_timed_out", nil))
      run.replace(@progress.fail_step(run, failure, ctx: ctx).to_mutable_h)
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

    def start_retry(run, ctx) = run.replace(@progress.start_retry(run, ctx: ctx).to_mutable_h)

    def dispatch(run, ctx, **options) = run.replace(@dispatch.dispatch(run, ctx: ctx, **options).to_mutable_h)

    def evaluate(run, ctx) = run.replace(@evaluation.evaluate(run, ctx: ctx).to_mutable_h)

    # No turn ended, so the step is neither passed nor checked: the hold only becomes the stop it was hiding,
    # with a `since` of its own.
    def expire_background(run)
      held = run["reason"]["details"]
      details = held.slice("step", "attempt", "missing", "stale", "invalid").merge("background_tasks" => held["tasks"])
      run["reason"] = {"code" => "turn_ended_incomplete", "since" => now_iso, "details" => details}
    end
  end
end
