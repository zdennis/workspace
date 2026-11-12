require "time"

module Workspace
  # What follows a step's outcome: a passed step waits at its gate or the run goes on to the next step
  # ({#pass_step}, {#advance}) and completes after the last; a failed step goes back along its `on_fail`,
  # at once or after a backoff, or stops the run for a person ({#fail_step}); a backoff's retry starts
  # ({#start_retry}) or is held when its pane is no longer the run's ({#hold_retry}); {#finish} ends a run.
  # Each method takes the stored run, leaves it as it is and returns the run afterwards; a step it starts
  # goes through {WorkflowDispatch#dispatch}.
  class WorkflowProgress
    # @param change [Workspace::WorkflowRunChange] writes the run's history
    # @param store [Workspace::WorkflowRunStore] says whether the run another pane holds is still going
    # @param dispatch [Workspace::WorkflowDispatch] starts a step, gives up the run's locks and drops a park
    # @param attempt_record [Workspace::WorkflowAttemptRecord] records what each attempt ended with
    # @param panes [Workspace::WorkflowPanes] finds, compares and unbinds the run's pane
    # @param log_tail [Workspace::WorkflowLogTail] reads the end of a failed check's log for `on_fail`'s `log_tail`
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, attempt_record:, panes:, log_tail:, clock: -> { Time.now })
      @change = change
      @store = store
      @dispatch = dispatch
      @attempt_record = attempt_record
      @panes = panes
      @log_tail = log_tail
      @clock = clock
    end

    # Ends the current attempt as passed. A gated step then waits for a person with its locks given up;
    # any other goes on ({#advance}).
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being checked; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context, which gets the next step's line
    # @return [WorkflowRun] the run afterwards
    def pass_step(run, ctx:) = over(run) { |work| pass(work, ctx) }

    # Starts the step after the current one, or completes the run after the last.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def advance(run, ctx:) = over(run) { |work| go_on(work, ctx) }

    # Ends the run: drops its park, retry wait and budget hold, gives up its locks and frees its pane.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param state [String] the run's end state, "completed" or "cancelled"
    # @return [WorkflowRun] the run afterwards
    def finish(run, state) = over(run) { |work| end_run(work, state) }

    # Ends the current attempt as failed. The step goes back along its `on_fail` while it has loops left
    # and the run has attempts left (after the `on_fail` backoff, when it sets one); otherwise the run
    # stops and waits for a person with the reason `failed_check`.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param failure [Hash{String=>Object}] why: "cause", "code" and what the reason's details carry
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def fail_step(run, failure, ctx:) = over(run) { |work| fail_in(work, failure, ctx) }

    # Ends an `on_fail` retry's wait: tells the target step what failed (the text kept when the step failed)
    # and starts it, as the loop would have without a backoff. Held instead ({#hold_retry}) when the pane
    # the retry would type into is no longer the run's.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param waiting [Hash{String=>Object}, nil] the wait, already taken off the run; nil takes the run's `backoff`
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @param proven [Boolean] the pane is one a person named, so its identity is not compared (it must still
    #   exist and not belong to another run)
    # @param budgeted [Boolean] false starts the attempt even when the token budget is used up
    # @return [WorkflowRun] the run afterwards
    def start_retry(run, waiting = nil, ctx:, proven: false, budgeted: true)
      over(run) { |work| retry_in(work, waiting || work.delete("backoff"), ctx, proven, budgeted) }
    end

    # Keeps a retry from starting without spending it: the wait is kept, marked `blocked` so a tick or the
    # sweep leaves it, and the run waits for a person. The same hold again (same code, same pane) changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param waiting [Hash{String=>Object}] the wait
    # @param problem [Hash{Symbol=>String}] :code and :message from {#retry_pane_problem}
    # @param pane [String, nil] the pane the reason names; nil names the run's bound pane
    # @return [WorkflowRun] the run afterwards
    def hold_retry(run, waiting, problem, pane: nil) = over(run) { |work| hold_in(work, waiting, problem, pane || bound_pane(work)) }

    # Why the pane a waiting retry would type into is no longer the run's: another run took it, tmux no
    # longer has it, or it can't be shown to be the pane the wait began in. Changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param waiting [Hash{String=>Object}] the wait ("pane" and "identity" it began with)
    # @param proven [Boolean] see {#start_retry}
    # @param pane [String, nil] the pane to judge; nil judges the run's bound pane
    # @return [Hash{Symbol=>String}, nil] :code (`pane_has_run`, `pane_gone` or `pane_changed`) and :message; nil when the retry can start
    def retry_pane_problem(run, waiting, proven: false, pane: nil)
      run = WorkflowRun.from_h(run).to_h
      pane ||= bound_pane(run)
      return nil unless pane
      other = @panes.run_on(pane)
      if other && other != run["id"] && @store.going?(other)
        return {code: "pane_has_run", message: "pane #{pane} is now running workflow run #{other}. Name another agent pane with `workflow resume --pane PANE`"}
      end
      return {code: "pane_gone", message: "pane #{pane} is gone. Name another agent pane with `workflow resume --pane PANE`"} if @panes.pane_gone?(pane)
      # A pane a person named for the resume was checked then; the wait's facts are about the pane it began in.
      return nil if proven || (waiting["pane"] && waiting["pane"] != pane)
      return nil if @panes.same_pane?(pane, waiting["identity"])
      reason = waiting["identity"] ? "does not look like the pane the run was in (a tmux restart reuses pane ids, and closing a pane beside it renumbers it; it may be fine)" : "can't be shown to be the pane the run was in (it may be fine)"
      {code: "pane_changed", message: "pane #{pane} #{reason}. Name it with `--pane #{pane}` to resume in it"}
    end

    private

    # A working copy of the run for the block to change, returned as a new run.
    def over(run)
      work = WorkflowRun.deep_thaw(WorkflowRun.from_h(run).to_h)
      yield work
      WorkflowRun.from_h(work)
    end

    def pass(run, ctx)
      ended = step_state(run)["attempts"].last.merge("ended_at" => now_iso, "outcome" => "passed")
      record_end(run, ended)
      state = step_state(run)
      state["state"] = "passed"
      event(run, "step_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      return go_on(run, ctx) unless step_def(run)["gate"]

      @dispatch.release(run)
      state["gate"] = {"state" => "waiting", "since" => now_iso}
      run["state"] = "waiting"
      run["reason"] = reason("waiting_you", "kind" => "gate", "step" => run["current"],
        "artifacts" => step_def(run)["produces"].map { |file| File.join(run["artifacts_dir"], file) })
      event(run, "gate_waiting", "step" => run["current"])
    end

    def go_on(run, ctx)
      ids = step_ids(run)
      following = ids[ids.index(run["current"]) + 1]
      return complete(run) unless following
      run["current"] = following
      dispatch(run, ctx, {})
    end

    def complete(run)
      end_run(run, "completed")
      event(run, "run_completed")
    end

    def end_run(run, state)
      run.replace(WorkflowRun.deep_thaw(@dispatch.drop_park(run, "ended").to_h)) if run.key?("parked")
      run.delete("backoff")
      run.delete("budget_hold")
      @dispatch.release(run)
      @panes.unbind(run["id"])
      run["state"] = state
      run["reason"] = nil
      run["ended_at"] = now_iso
    end

    def fail_in(run, failure, ctx)
      step = step_def(run)
      ended = step_state(run)["attempts"].last.merge("ended_at" => now_iso, "outcome" => "failed")
      ended["code"] = failure["code"] if failure["code"].is_a?(String)
      record_end(run, ended)
      state = step_state(run)
      attempt = state["attempts"].last
      state["state"] = "failed"
      event(run, "step_failed", {"step" => step["id"], "attempt" => attempt["n"]}.merge(failure.slice("cause", "exit_code")))
      on_fail = step["on_fail"]
      attempts = WorkflowTransitions.attempts_made(run)
      next_move = WorkflowTransitions.after_failure(run, failure)
      if next_move[:kind] == :loop
        run["loops"][next_move[:edge]] = next_move[:count]
        text = loop_context(run, step, on_fail, failure, next_move[:count])
        wait = next_move[:wait]
        event(run, "step_looped", {"from" => step["id"], "to" => next_move[:to], "count" => next_move[:count]}.merge(wait ? {"backoff" => wait} : {}))
        return wait_to_retry(run, step, on_fail, text, wait, attempt) if wait
        run["pending_context"] << text
        run["current"] = next_move[:to]
        return dispatch(run, ctx, {context: on_fail["context"], retry_of: {"text" => text}})
      end
      @dispatch.release(run)
      run["state"] = "waiting"
      run["reason"] = reason("failed_check", {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                                              "attempts" => attempts, "max_attempts" => WorkflowTransitions.attempt_allowance(run)}.merge(failure))
    end

    # No attempt, pane binding or lock is held while the retry waits: the run reads `waiting` with the reason
    # `retry_backoff`, and the step stays `failed` until {#start_retry}.
    def wait_to_retry(run, step, on_fail, text, wait, attempt)
      @dispatch.release(run)
      pane = bound_pane(run)
      identity = @panes.identity(run["id"])
      @panes.unbind(run["id"])
      time = (@clock.call + wait).utc.iso8601
      run["backoff"] = {"until" => time, "to" => on_fail["goto"], "context" => on_fail["context"], "text" => text, "pane" => pane, "identity" => identity}.compact
      run["state"] = "waiting"
      run["reason"] = reason("retry_backoff", {"step" => step["id"], "attempt" => attempt["n"], "to" => on_fail["goto"], "until" => time,
                                               "seconds" => wait, "loops" => run["loops"]})
    end

    def retry_in(run, waiting, ctx, proven, budgeted)
      problem = retry_pane_problem(run, waiting, proven: proven)
      return hold_in(run, waiting, problem, bound_pane(run)) if problem
      to = waiting["to"]
      run["pending_context"] << waiting["text"] if waiting["text"].is_a?(String)
      event(run, "step_retry_started", "from" => run["current"], "to" => to)
      run["current"] = to
      run["reason"] = nil
      dispatch(run, ctx, {context: waiting["context"], budgeted: budgeted, retry_of: waiting.slice("pane", "identity", "text")})
    end

    def hold_in(run, waiting, problem, pane)
      held = run["backoff"]
      same = held.is_a?(Hash) && held["blocked"] == problem[:code] && run.dig("reason", "details", "pane") == pane &&
        run.dig("reason", "details", "error") == problem[:code]
      return if same
      run["backoff"] = waiting.merge("blocked" => problem[:code])
      run["reason"] = reason((problem[:code] == "pane_gone") ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"], "error" => problem[:code],
         "message" => "the retry of step #{waiting["to"]} was not started: #{problem[:message]}. Or cancel the run."})
      event(run, "step_retry_blocked", "from" => run["current"], "to" => waiting["to"], "code" => problem[:code])
    end

    def loop_context(run, step, on_fail, failure, count)
      text = "The #{step["id"]} step failed and sent the run back to this step (time #{count} of #{on_fail["max"]}): #{WorkflowTransitions.failure_text(failure)}. " \
        "Its files are in #{run["artifacts_dir"]}. Fix what it found."
      lines = WorkflowDefinition.log_tail(on_fail)
      tail = (lines && failure["log"].is_a?(String)) ? @log_tail.block(failure["log"], lines: lines) : nil
      tail ? "#{text}\n\n#{tail}" : text
    end

    # Stores the ended attempt with what {WorkflowAttemptRecord#finish} adds to it.
    def record_end(run, ended)
      step = step_def(run)
      step_state(run)["attempts"][-1] = ended
      finished = @attempt_record.finish(run: run, step: step, attempt: ended)
      run.replace(WorkflowRun.deep_thaw(WorkflowRun.from_h(run).with_attempt(step["id"], finished).to_h))
    end

    def dispatch(run, ctx, options)
      run.replace(WorkflowRun.deep_thaw(@dispatch.dispatch(run, ctx: ctx, **options).to_h))
    end

    def event(run, type, data = {}) = @change.event(run, type, data)

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    def step_ids(run)
      run["definition"]["steps"].map { |step| step["id"] }
    end

    def step_def(run)
      run["definition"]["steps"].find { |step| step["id"] == run["current"] }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def reason(code, details)
      {"code" => code, "since" => now_iso, "details" => details}
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
