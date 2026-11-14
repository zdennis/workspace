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
    # @param holder_alive [#call, nil] given a review round's delivery `holder`, whether that process still runs, so a
    #   lapsed round is delivered again only once its holder is gone (nil takes every holder as alive)
    # @param panes [Workspace::WorkflowPanes, nil] says whether a review pane's turn is proven over ({WorkflowPanes#main_turn_over?})
    #   or the pane is gone, read with the run's lock not yet taken; nil takes every such pane as done
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, progress:, evaluation:, holder_alive: nil, panes: nil, clock: -> { Time.now })
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
    # `review_incomplete` instead. A slow delivery whose holder is alive is left alone. Does nothing while another
    # process is changing the run.
    #
    # @param run_id [String]
    # @return [WorkflowRun, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      follow = nil
      acted = false
      alive = holder_alive_once
      # Read before the lock is taken: no tmux or daemon call is made under it.
      typed = typed_pane_over(run_id, alive)
      run = @change.call(run_id, nonblocking: true) do |read, ctx|
        stored = read.thawed
        case WorkflowTransitions.wakeable?(stored, @clock.call, alive: alive)
        when :backoff
          acted = true
          start_retry(stored, ctx)
        when :lock
          acted = true
          # A review round waiting for its `review.uses` asks for the lock again through the round's own start, never
          # an author attempt; still taken, nothing changes.
          if stored.dig("steps", stored["current"], "state") == "reviewing"
            stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
          else
            dispatch(stored, ctx)
          end
        when :background
          acted = true
          expire_background(stored)
        when :round
          acted = true
          stored.replace(@evaluation.review_ended(stored, ctx: ctx).thawed)
        when :review
          acted = redeliver_round(stored, ctx, alive, typed) == :acted
        when :check
          acted = true
          evaluate(stored, ctx)
        end
        follow = ctx
        WorkflowRun.from_h(stored)
      end
      return nil unless run && acted
      @evaluation.finish_follow_ups(run_id, follow, run)
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
        stored = read.thawed
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

    # Acts on a review round the sweep found stalled in its review pane, as the sweep's act. Does nothing unless the
    # run is still on that step, attempt and round, `reviewing` with no reason and no park, its round delivered (no
    # mark), not being judged, and recorded in +pane+, so a turn's end, a resume or a cancel that got there first
    # stands. A `step_stalled` line (with `round`) is written, then by +cause+:
    #
    # - `idle_turn_over`: the review turn ended unseen; the round is decided as a turn's end decides it
    #   ({WorkflowEvaluation#review_ended})
    # - `pane_gone` (the review pane closed) or `agent_gone` (its agent exited to a shell): decided the same way, so
    #   verdicts already written count, and a round they leave short stops `review_incomplete`
    # - `server_restarted`: the tmux server the pane was on is gone (a new one may reuse the pane id); the round is
    #   delivered again as {#tick} would ({WorkflowProgress#redeliver_round}, in a new window), or stops
    #   `review_incomplete` once its `redeliveries` are spent
    #
    # @param run_id [String]
    # @param step [String]
    # @param attempt [Integer, nil] the reviewed attempt
    # @param round [Integer]
    # @param pane [String] the review pane the sweep read
    # @param cause [String] `idle_turn_over`, `pane_gone`, `agent_gone` or `server_restarted`
    # @param data [Hash{String=>Object}] more for the `step_stalled` event
    # @return [Symbol] :evaluated, :stopped (`server_restarted` with `redeliver` spent), :redelivered, :moved_on or :busy
    def review_stalled(run_id, step:, attempt:, round:, pane:, cause:, data: {})
      outcome = :moved_on
      follow = nil
      run = @change.call(run_id, nonblocking: true) do |read, ctx|
        stored = read.thawed
        next unless round_target?(stored, step, attempt, round, pane)
        @change.event(stored, "step_stalled", {"step" => step, "attempt" => attempt, "round" => round, "pane" => pane, "cause" => cause}.merge(data))
        outcome = if cause == "server_restarted"
          server_restarted(stored, ctx, pane)
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
      @evaluation.finish_follow_ups(run_id, follow, run)
      outcome
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
    # @param cause [String] `timed_out` (the step's `timeout:`) or `run_timed_out` (the run's `timeout_action: interrupt`);
    #   each keeps its own mark, so both may be due on one attempt and each presses once
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`] to hand to {#interrupt_sent}; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:, cause: "timed_out")
      at = nil
      key = interrupt_key(cause)
      outcome = sweep_change(run_id, step: step, attempt: attempt, running: true) do |stored|
        marks = sweep_marks_for(stored)
        next :repeat if interrupt_held?(marks[key])
        at = now_iso
        marks[key] = {"state" => "pending", "at" => at}
        mark_stall(stored, cause, {"elapsed" => elapsed.round, "timeout" => timeout})
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
    # @param cause [String] the cause given to {#claim_interrupt}
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true, cause: "timed_out")
      key = interrupt_key(cause)
      sweep_change(run_id, step: step, attempt: attempt, running: false, blocking: true) do |stored|
        marks = sweep_marks_for(stored)
        next :taken_over unless marks.dig(key, "at") == claim_at
        unless sent
          marks.delete(key)
          next :released
        end
        marks[key] = {"state" => "sent", "at" => now_iso}
        mark_recovery(stored, cause, "interrupted") if record
        :recorded
      end
    end

    private

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    # One change the sweep makes under the run's lock. The block returns the outcome (a check it registers on its
    # context is run after the lock is given up), and is run only for the step and attempt the sweep saw (and,
    # with +running+, only while that step reads `running` with no park and no line still on its way, and no
    # reason: +running+ `:or_incomplete` allows a `turn_ended_incomplete` stop). Without +blocking+ a run another
    # process is changing is :busy.
    def sweep_change(run_id, step:, attempt:, running:, blocking: false)
      outcome = :moved_on
      follow = nil
      run = @change.call(run_id, nonblocking: !blocking) do |read, ctx|
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

    # For a round whose line may have been typed, what its review pane shows, as :state: `:over` (the pane is gone,
    # its agent exited to a shell, or its turn is proven over), `:waiting` (Claude Code waits for an answer), `:busy`
    # (Claude Code at work, or sub-agents running: the line arrived), `:unreachable` (no agent daemon answers), else
    # `:unknown`; with the :pane, :round and
    # :started_at of the round it was read for. Nil for any other run. Never raises.
    def typed_pane_over(run_id, alive)
      return nil unless @panes
      run = @store.run(run_id)
      round = run.steps[run.current]&.review
      return nil unless round.is_a?(Hash) && round["pane"].is_a?(String)
      return nil unless WorkflowTransitions.typed_round?(round, @clock.call, alive: alive)
      pane = round["pane"]
      {pane: pane, round: round["round"], started_at: round["started_at"], state: typed_pane_state(run.workspace, pane)}
    rescue Workspace::Error, SystemCallError
      nil
    end

    def typed_pane_state(workspace, pane)
      return :over if @panes.pane_gone?(pane)
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
    def redeliver_round(run, ctx, alive, typed = nil)
      info = WorkflowTransitions.round_redelivery(run, @clock.call, alive: alive)
      return unless info
      # A line that may have been typed (an agent daemon that restarted while it typed) may have a finished review
      # behind it: the round is judged as a turn's end would judge it, the verdicts written count, and only the
      # reviewers still missing run again while deliveries are left. Only once the review pane's turn is proven over
      # (or the pane is gone): a reviewer still at work is waited for, and its own Stop may judge the round first.
      round = step_state(run)["review"]
      if info[:state] != :waiting && WorkflowTransitions.round_may_have_typed?(round, info[:mark])
        decision = (@panes && round["pane"]) ? judge_typed(run, round, typed) : :judge
        return :waiting if decision == :wait
        if decision == :stop
          # A reviewer still at work past the review's timeout: a rerun would only meet that working pane again.
          stop_round(run, ctx, "the review pane #{round["pane"]} was still at work when the round's review timeout passed, after its delivery failed (#{round.dig("failure", "code") || "lapsed"})")
        else
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
    # for this same round): `:judge` (its verdicts read), `:stop` (`review_incomplete`) or `:wait`. Its turn proven
    # over, the pane gone or a shell where the agent was: judged at once. An agent at work in it (the line arrived):
    # waited for until the review's own `timeout` has passed since the line went out, then stopped, since a rerun
    # would meet the same working pane. Waiting for an answer (a permission prompt, a question): never judged by a
    # wait, since `workflow status` shows it waiting for a person. An agent daemon that can't be reached: waited for
    # until the review's timeout, then judged. Anything else (no row from the daemon, an idle pane whose turn is not
    # proven over, a reading for another round): judged once {WorkflowTransitions.typed_wait_over?} says so.
    def judge_typed(run, round, typed)
      state = (typed && typed[:pane] == round["pane"] && typed[:round] == round["round"] && typed[:started_at] == round["started_at"]) ? typed[:state] : :unknown
      now = @clock.call
      case state
      when :over then :judge
      when :waiting then :wait
      when :busy then WorkflowTransitions.typed_review_timed_out?(run, round, now) ? :stop : :wait
      when :unreachable then WorkflowTransitions.typed_review_timed_out?(run, round, now) ? :judge : :wait
      else WorkflowTransitions.typed_wait_over?(run, round, now) ? :judge : :wait
      end
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

    def interrupt_key(cause) = (cause == "run_timed_out") ? "run_interrupt" : "interrupt"

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

    def start_retry(run, ctx) = adopt(run, @progress.start_retry(run, ctx: ctx))

    def dispatch(run, ctx, **options) = adopt(run, @dispatch.dispatch(run, ctx: ctx, **options))

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
