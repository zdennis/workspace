require "time"

module Workspace
  # What follows a step's outcome: a passed step waits at its gate or the run goes on to the next step
  # ({#pass_step}, {#advance}) and completes after the last; a failed step goes back along its `on_fail`,
  # at once or after a backoff, or stops the run for a person ({#fail_step}); a backoff's retry starts
  # ({#start_retry}) or is held when its pane is no longer the run's ({#hold_retry}); {#finish} ends a run.
  # A step with a `review:` does not pass on its own checks: its attempt ends `checks_passed` and the step is
  # `reviewing` while a review round runs ({#pass_step}); the round's outcome decides it ({#decide_review}). A person's
  # resume starts the round again ({#restart_review}), and a cancel or `resume --from` ends it undecided ({#end_round}).
  # Every round start is held, as an attempt start is, while the token budget or the run's timeout is used up.
  # Each method takes the stored run, leaves it as it is and returns the run afterwards; a step it starts
  # goes through {WorkflowDispatch#dispatch}.
  class WorkflowProgress
    # @param change [Workspace::WorkflowRunChange] writes the run's history
    # @param store [Workspace::WorkflowRunStore] says whether the run another pane holds is still going
    # @param dispatch [Workspace::WorkflowDispatch] starts a step, gives up the run's locks and drops a park
    # @param attempt_record [Workspace::WorkflowAttemptRecord] records what each attempt ended with
    # @param panes [Workspace::WorkflowPanes] finds, compares and unbinds the run's pane
    # @param log_tail [Workspace::WorkflowLogTail] reads the end of a failed check's log for `on_fail`'s `log_tail`
    # @param review_tally [#open_round, nil] makes each round's directory as the round starts ({WorkflowReviewTally#open_round});
    #   nil makes none
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, attempt_record:, panes:, log_tail:, review_tally: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @dispatch = dispatch
      @attempt_record = attempt_record
      @panes = panes
      @log_tail = log_tail
      @review_tally = review_tally
      @clock = clock
    end

    # Ends the current attempt as passed. A gated step then waits for a person with its locks given up;
    # any other goes on ({#advance}). A step with a `review:` whose attempt no round has decided ends the attempt
    # `checks_passed` instead and starts a review round: the step reads `reviewing`, its `review` holds the round
    # ("round", "delivery", "started_at", "pending", "redeliveries"), and the round is registered on +ctx+ to run
    # once the lock is given up. A spent token budget or timeout holds the round instead (`budget_spent`,
    # `run_timed_out`): the step stays `reviewing` and its `review` names the round with no delivery.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being checked; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context, which gets the next step's line
    # @return [WorkflowRun] the run afterwards
    def pass_step(run, ctx:) = over(run) { |work| pass(work, ctx) }

    # Decides the review round of the step being reviewed. The attempt the round reviewed already ended
    # (`checks_passed`); its outcome is rewritten, with no second {WorkflowAttemptRecord#finish}, and
    # `review_outcome` (`round`, `approvals`, `need`, `must`, `passed`) and `reviews` added. Approved: the step passes, as {#pass_step} would pass it, to its gate or
    # the next step. Rejected: the attempt and step fail and the run stops for a person with `review_rejected`.
    # Incomplete: the step stays `reviewing`, the round is marked ended, and the run stops with `review_incomplete`.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param tally [Hash{Symbol=>Object}] the round's tally: :outcome (`:approved`, `:rejected` or `:incomplete`),
    #   :reviews (the rows it read), :approvals, :need and :must when it counted them, and, for an incomplete one, :problem
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def decide_review(run, tally, ctx:) = over(run) { |work| decide_in(work, tally, ctx) }

    # A person's resume of the step being reviewed. A round that stopped for a person (a stored reason, or a round
    # already marked ended) is ended ({#end_round}, its window kept for the next round) and a fresh round starts,
    # which spends one of the step's rounds. A round whose delivery failed or lapsed is delivered again as the same
    # round, its redelivery count started again. Never starts an attempt.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] gets the round to run
    # @return [WorkflowRun] the run afterwards
    def restart_review(run, ctx:) = over(run) { |work| restart_in(work, ctx) }

    # Ends the round of the step being reviewed without a decision: the round's record ({WorkflowAttemptRecord#finish_round},
    # with how it ended and the verdict rows the round already read) is added to the reviewed attempt's `rounds`, and
    # the step's `review` is taken off. With +close+, the reviewer's binding is removed and the review window is
    # registered on +ctx+ to close. The step's state and `review_rounds` are left as they are. A step with no
    # round changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param how [String] why the round ended: "cancelled", "from" (a `resume --from`) or "resumed" (a fresh round follows)
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @param close [Boolean] unbind the reviewer and close the window; false keeps both for the next round
    # @return [WorkflowRun] the run afterwards
    def end_round(run, how:, ctx:, close: true) = over(run) { |work| end_round_in(work, how, ctx, close) }

    # Starts the step after the current one, or completes the run after the last.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def advance(run, ctx:) = over(run) { |work| go_on(work, ctx) }

    # Ends the run: drops its park, retry wait and budget and timeout holds, gives up its locks and frees its pane.
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

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    # A working copy of the run for the block to change, returned as a new run.
    def over(run)
      work = WorkflowRun.from_h(run).thawed
      yield work
      WorkflowRun.from_h(work)
    end

    def pass(run, ctx)
      last = step_state(run)["attempts"].last
      # An attempt a round already decided (a gate approved after it, a resume) is never reviewed again.
      return begin_review(run, ctx) if WorkflowDefinition.review(step_def(run)) && !last.key?("review_outcome")
      record_end(run, last.merge("ended_at" => now_iso, "outcome" => "passed"))
      passed(run, ctx)
    end

    # The step passed: its gate, else the next step.
    def passed(run, ctx)
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

    # The author's turn passed every check; the attempt ends now, so its usage counts and its step timeout stops.
    def begin_review(run, ctx)
      record_end(run, step_state(run)["attempts"].last.merge("ended_at" => now_iso, "outcome" => "checks_passed"))
      state = step_state(run)
      state["state"] = "reviewing"
      event(run, "step_checks_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      begin_round(run, ctx)
    end

    # The one start of a review round: the round is spent here, and its delivery is registered on +ctx+. A round is
    # held first, as an attempt is, when the token budget or the run's timeout is used up ({WorkflowDispatch#hold_round}):
    # the step stays `reviewing` with the round named and no delivery, the round is not spent, and nothing is registered.
    def begin_round(run, ctx)
      state = step_state(run)
      round = state["review_rounds"].to_i + 1
      held = @dispatch.hold_round(run, round: round)
      return hold_round(run, held, round) if held
      state["review_rounds"] = round
      state["review"] = {"round" => round, "delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3),
                         "pending" => WorkflowDefinition.review(step_def(run))["from"].dup, "redeliveries" => 0}
      run["state"] = "running"
      run["reason"] = nil
      attempt = state["attempts"].last["n"]
      event(run, "review_started", "step" => run["current"], "attempt" => attempt, "round" => round)
      opened = @review_tally&.open_round(run: run, round: round)
      return refuse_round(run, opened) if opened
      ctx.review({"step" => run["current"], "attempt" => attempt, "round" => round})
    end

    # A round whose directory could not be made for it (`review_tampered`: something was already there) never runs:
    # it is spent and ended, with its record, and the run stops for a person, whose resume starts a fresh round.
    def refuse_round(run, opened)
      state = step_state(run)
      ended = state["review"].merge("delivery" => nil, "ended_at" => now_iso)
      add_round_record(run, ended, opened[:code])
      state["review"] = ended.merge("recorded" => true)
      details = {"step" => run["current"], "attempt" => state["attempts"].last["n"], "round" => ended["round"]}
      event(run, "review_ended", details.merge("outcome" => opened[:code]))
      stop_review(run, opened[:code], details.merge("problem" => opened[:problem]))
    end

    # A held round has no delivery and no start: its release goes through {#begin_round} for the same round.
    def hold_round(run, held, round)
      run.replace(held.thawed)
      step_state(run)["review"] = {"round" => round, "delivery" => nil}
    end

    # A round a budget or timeout hold kept from starting: it never ran, so it has no record, usage or review_ended.
    def held_round?(round) = round.is_a?(Hash) && round["started_at"].nil?

    def decide_in(run, tally, ctx)
      state = step_state(run)
      round = state["review"] || {}
      attempt = state["attempts"].last
      reviews = Array(tally[:reviews])
      details = {"step" => run["current"], "attempt" => attempt["n"], "round" => round["round"]}
      outcome = tally[:outcome]
      event(run, "review_ended", details.merge("outcome" => outcome.to_s))
      decided = {"round" => round["round"], "approvals" => tally[:approvals], "need" => tally[:need], "must" => tally[:must], "passed" => outcome == :approved}
      # Every round that ends, decided or not, adds one record to the attempt's `rounds`: the one list its usage is read from.
      ended = round.merge("delivery" => nil, "ended_at" => now_iso, "reviews" => reviews)
      attempt = attempt.merge("rounds" => Array(attempt["rounds"]) + [round_record(run, ended, outcome.to_s)])
      case outcome
      when :approved
        state.delete("review")
        state["attempts"][-1] = attempt.merge("outcome" => "passed", "review_outcome" => decided, "reviews" => reviews)
        passed(run, ctx)
      when :rejected
        state.delete("review")
        state["attempts"][-1] = attempt.merge("outcome" => "failed", "code" => "review_rejected", "review_outcome" => decided, "reviews" => reviews)
        state["state"] = "failed"
        event(run, "step_failed", "step" => run["current"], "attempt" => attempt["n"], "cause" => "review")
        stop_review(run, "review_rejected", details.merge("reviews" => reviews))
      else
        state["attempts"][-1] = attempt
        # Marked recorded, so the resume or cancel that ends it later adds no second record.
        state["review"] = ended.merge("recorded" => true)
        stop_review(run, "review_incomplete", details.merge("reviews" => reviews, "problem" => tally[:problem]).compact)
      end
    end

    def restart_in(run, ctx)
      state = step_state(run)
      round = state["review"]
      if held_round?(round)
        state.delete("review")
        return begin_round(run, ctx)
      end
      unless round.is_a?(Hash) && run["reason"].nil? && round["ended_at"].nil?
        end_round_in(run, "resumed", ctx, false)
        return begin_round(run, ctx)
      end
      # The lapsed delivery's time is recorded as a round record of its own (`ended: redelivered`), so its usage
      # is kept, and the round starts its clock again: a delivery mark is judged from `started_at`.
      add_round_record(run, round, "redelivered")
      state["review"] = round.except("holder").merge("delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3), "redeliveries" => 0)
      run["state"] = "running"
      attempt = state["attempts"].last["n"]
      event(run, "review_started", "step" => run["current"], "attempt" => attempt, "round" => round["round"], "again" => true)
      ctx.review({"step" => run["current"], "attempt" => attempt, "round" => round["round"]})
    end

    def end_round_in(run, how, ctx, close)
      state = step_state(run)
      round = state["review"]
      return unless round.is_a?(Hash)
      attempt = state["attempts"].last
      held = held_round?(round)
      add_round_record(run, round, how) unless round["recorded"] || held
      state.delete("review")
      # A round a tally already ended wrote its `review_ended`.
      event(run, "review_ended", "step" => run["current"], "attempt" => attempt["n"], "round" => round["round"], "outcome" => how) unless round["ended_at"] || held
      return unless close
      @panes.unbind(run["id"], role: "reviewer")
      ctx.close_review({"step" => run["current"], "round" => round["round"], "pane" => round["pane"]})
    end

    # The record of a round that ended (or a delivery of it that lapsed): {WorkflowAttemptRecord#finish_round} with
    # how it ended, and the verdict rows the round read when there are any.
    def round_record(run, round, how)
      record = @attempt_record.finish_round(run: run, round: round).merge("ended" => how)
      record["reviews"] = round["reviews"] if round["reviews"]
      record
    end

    def add_round_record(run, round, how)
      state = step_state(run)
      attempt = state["attempts"].last
      state["attempts"][-1] = attempt.merge("rounds" => Array(attempt["rounds"]) + [round_record(run, round, how)])
    end

    def stop_review(run, code, details)
      @dispatch.release(run)
      run["state"] = "waiting"
      run["reason"] = reason(code, details)
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
      adopt(run, @dispatch.drop_park(run, "ended")) if run.key?("parked")
      run.delete("backoff")
      run.delete("budget_hold")
      run.delete("timeout_hold")
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
      details = {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                 "attempts" => attempts, "max_attempts" => WorkflowTransitions.attempt_allowance(run)}
      if next_move[:limit] == :step
        details["limit"] = "step"
        details["limit_step"] = next_move[:step]
      end
      run["reason"] = reason("failed_check", details.merge(failure))
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
      adopt(run, WorkflowRun.from_h(run).with_attempt(step["id"], finished))
    end

    def dispatch(run, ctx, options)
      adopt(run, @dispatch.dispatch(run, ctx: ctx, **options))
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
