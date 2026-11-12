require "securerandom"
require "time"

module Workspace
  # A person's commands on a run: passing or turning down a gate ({#approve}, {#reject}), getting a run that is
  # not moving going again ({#resume}, refused first by {#refuse_resume}), and ending it ({#cancel},
  # {#workspace_killed}). A resume that can't be typed yet is parked on the run ({#park}), then carried out
  # ({#release_park}) or ended ({#park_failed}). A command that starts an attempt is held to the run's attempt
  # allowance and token budget, which `--extra-attempts` and `--extra-tokens` raise. What follows goes through
  # {WorkflowProgress}, {WorkflowDispatch} and {WorkflowEvaluation}. Each method that takes a run leaves it as it
  # is and returns the run afterwards.
  class WorkflowDecisions
    # What a resume or a park did: the run afterwards, and why nothing was done (a sentence), or nil when it acted.
    Resumed = Data.define(:run, :unchanged)

    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = 3600

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] lists the runs going, for {#workspace_killed}
    # @param progress [Workspace::WorkflowProgress] goes on past a gate, ends a run and starts or holds a retry
    # @param dispatch [Workspace::WorkflowDispatch] starts a step, checks a pane and drops a park
    # @param evaluation [Workspace::WorkflowEvaluation] decides a step a resume looks at again, and runs its check
    # @param attempt_record [Workspace::WorkflowAttemptRecord] closes the open attempt of a run that is cancelled
    # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
    # @param panes [Workspace::WorkflowPanes] finds, binds and unbinds the run's pane
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, progress:, dispatch:, evaluation:, attempt_record:, gate_note:, panes:, clock: -> { Time.now })
      @change = change
      @store = store
      @progress = progress
      @dispatch = dispatch
      @evaluation = evaluation
      @attempt_record = attempt_record
      @gate_note = gate_note
      @panes = panes
      @clock = clock
    end

    # Passes a gate: the run goes on to the step after the gated one. When the gated step's first file names a
    # note (`note: <file>`), the note's sha256 is recorded with the approval and named in the next step's
    # instructions. Every check runs under the run's lock, in this order: the gate is waiting (at +step+ and
    # +attempt+ when given), +guard+, then the note. A refusal leaves the run file as it was.
    #
    # @param run_id [String]
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `stale_revision`, `gate_note_unreadable`, and what +guard+ raises
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @change.call(run_id) do |read, ctx|
        stored = WorkflowRun.deep_thaw(read.to_h)
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        file = gate_file(stored, note_sha256)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        gate["file"] = file if file
        event(stored, "gate_approved", with_note({"step" => stored["current"]}, note).merge(file ? {"sha256" => file["sha256"]} : {}))
        stored["pending_context"] << "The #{stored["current"]} step was approved with this note: #{note}" if note
        stored["pending_context"] << "The approved note is #{file["path"]}, sha256 #{file["sha256"]}." if file
        @progress.advance(stored, ctx: ctx)
      end
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note.
    #
    # @param run_id [String]
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `attempts_spent`, `budget_spent`, and what +guard+ raises
    # @raise [Workspace::UsageError] when +to+ is not the gated step or one before it
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil)
      @change.call(run_id) do |read, ctx|
        stored = WorkflowRun.deep_thaw(read.to_h)
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        # The step runs again, which is a new attempt.
        spend_attempts(stored, extra_attempts)
        spend_tokens(stored, extra_tokens)
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil))
        event(stored, "gate_rejected", with_note({"step" => stored["current"], "to" => target}, note))
        stored["pending_context"] << "The #{stored["current"]} step was rejected at its gate: #{note}"
        stored["current"] = target
        @dispatch.dispatch(stored, ctx: ctx)
      end
    end

    # Gets a run that is not moving going again: asks for its lock again, runs a failed or undelivered step
    # again, looks again at a step whose turn ended without its files or without the daemon seeing it, and
    # moves the run to another pane when its own is gone. A step an agent is working on, and a check that is
    # still running, are left alone. A resume that acts takes over from a parked one; one that does nothing leaves it.
    #
    # @param run_id [String]
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was seen to have ended
    #   its turn on that attempt, so the step, if the run is still on that attempt and it reads `running`, is decided now
    # @param extra_attempts [Integer, nil] raises the run's attempt allowance by this much, kept in the run and
    #   recorded as `attempts_extended`; applied only when the resume starts an attempt
    # @param extra_tokens [Integer, nil] raises the run's token budget by this much, kept in the run and recorded
    #   as `budget_extended`; applied only when the resume starts an attempt
    # @return [Resumed] the run afterwards, and why nothing was done when it did nothing
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` or `budget_spent` when the resume would
    #   start an attempt the run has no allowance left for
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      check = nil
      unchanged = nil
      run = @change.call(run_id) do |read, ctx|
        resumed = apply_resume(read, ctx: ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens)
        unchanged = resumed.unchanged
        check = ctx.check
        resumed.run
      end
      Resumed.new(run: check ? @evaluation.finish_check(run_id, check) : run, unchanged: unchanged)
    end

    # Stores a resume for later, with the same arguments as {#resume}: no attempt, no binding, no new lock. What the
    # run already has stays, and {#release_park} carries it out. A live park stays as it is, so repeating the call
    # can't extend the wait; one past its limit is replaced.
    #
    # @param run_id [String]
    # @param from [String, nil] see {#resume}
    # @param note [String, nil] see {#resume}; stored in the run, never in an event
    # @param pane [String, nil] see {#resume}
    # @param turn_over [Hash{String=>Object}, nil] see {#resume}
    # @param extra_attempts [Integer, nil] see {#resume}; applied when the park is released
    # @param extra_tokens [Integer, nil] see {#resume}; applied when the park is released
    # @return [Resumed] the run afterwards, and why nothing was stored when nothing was
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent` or `budget_spent` as {#resume}
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      unchanged = nil
      run = @change.call(run_id) do |read|
        stored = WorkflowRun.deep_thaw(read.to_h)
        refuse_resume(stored, from: from)
        if WorkflowTransitions.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id) if pane && @panes.run_on(pane) != run_id
        refuse_budget(stored, extra_attempts: extra_attempts, extra_tokens: extra_tokens) if WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
        drop_park(stored, "expired")
        store_park(stored, {"from" => from, "note" => note, "pane" => pane, "turn_over" => turn_over}.merge(extra_attempts ? {"extra_attempts" => extra_attempts} : {}).merge(extra_tokens ? {"extra_tokens" => extra_tokens} : {}),
          expires_at: (@clock.call + PARK_SECONDS).utc.iso8601)
        WorkflowRun.from_h(stored)
      end
      Resumed.new(run: run, unchanged: unchanged)
    end

    # Carries out a parked resume, in one change with taking it off the run. A park typed again after a busy pane
    # (`retries` above 0) is not held to the allowance and budget a second time: its attempt was counted then.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @return [Resumed] the run afterwards, and why the resume did nothing (its note kept for the next attempt), or nil
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id)
      check = nil
      unchanged = nil
      run = @change.call(run_id) do |read, ctx|
        parked = read.parked
        next unless parked && parked["id"] == id
        stored = WorkflowRun.deep_thaw(read.to_h)
        stored.delete("parked")
        resumed = apply_resume(stored, ctx: ctx, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"],
          extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"], budget: parked["retries"].to_i.zero?)
        stored = WorkflowRun.deep_thaw(resumed.run.to_h)
        unchanged = resumed.unchanged
        check = ctx.check
        stored["pending_context"] << WorkflowRun.resume_note(parked["note"]) if unchanged && parked["note"]
        event(stored, "resume_parked_ended", {"step" => stored["current"], "how" => unchanged ? "unchanged" : "released"}
          .merge(unchanged ? {"detail" => unchanged} : {}))
        if ctx.delivery
          step_state(stored)["attempts"].last["after_park"] = {"expires_at" => parked["expires_at"], "pane" => ctx.delivery["pane"], "retries" => parked["retries"]}
        end
        WorkflowRun.from_h(stored)
      end
      Resumed.new(run: check ? @evaluation.finish_check(run_id, check) : run, unchanged: unchanged)
    end

    # Ends a park that can't be released, and leaves the run waiting for a person. The step and what it holds stay,
    # so a `running` step keeps its attempt and a later resume decides it. A lock the run queued for is given up,
    # since the run would no longer use it. A run waiting at a gate keeps its gate reason, so approve and reject stay
    # open; the failure is in the `resume_parked_ended` event.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`
    # @param message [String]
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:)
      @change.call(run_id) do |read|
        stored = WorkflowRun.deep_thaw(read.to_h)
        next unless stored.dig("parked", "id") == id
        if step_state(stored).dig("gate", "state") == "waiting"
          drop_park(stored, "failed", "error" => code, "message" => message)
          next WorkflowRun.from_h(stored)
        end
        target = park_target(stored)
        case stored.dig("reason", "code")
        when "waiting_lock" then @dispatch.release(stored)
        when "failed_check" then stored["pending_context"].unshift(last_failure(stored))
        end
        drop_park(stored, "failed")
        stored["state"] = "waiting"
        stored["reason"] = {"code" => WorkflowDispatch::PANE_GONE_CODES.include?(code) ? "pane_gone" : "waiting_you", "since" => now_iso,
                            "details" => {"kind" => "dispatch", "step" => stored["current"], "pane" => target, "workspace" => stored["workspace"], "error" => code, "message" => message}}
        WorkflowRun.from_h(stored)
      end
    end

    # What {#resume} refuses, checked without changing anything, so a caller can refuse before it starts a daemon
    # or picks a pane.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run that has not finished
    # @param from [String, nil] the step a resume would start again at
    # @return [void]
    # @raise [Workspace::Error] code `gate_waiting` for a run at a gate when no step is named (approve or reject it)
    # @raise [Workspace::UsageError] for a step the workflow doesn't have
    def refuse_resume(run, from: nil)
      run = WorkflowRun.from_h(run).to_h
      if from
        return if step_ids(run).include?(from)
        raise UsageError, "No step #{from.to_s[0, 60].inspect} in workflow #{run["workflow"]} (#{step_ids(run).join(", ")})."
      end
      return unless step_state(run).dig("gate", "state") == "waiting"
      raise Workspace::Error.new("Run #{run["id"]} is waiting at the #{run["current"]} gate. Approve or reject it, or pass --from STEP.",
        code: "gate_waiting", details: {"run_id" => run["id"], "step" => run["current"]})
    end

    # Ends a run: closes its open attempt, gives up its resources and frees its pane.
    #
    # @param run_id [String]
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      @change.call(run_id) do |read|
        ended = WorkflowRun.deep_thaw(@progress.finish(@attempt_record.abandon(read), "cancelled").to_h)
        ended["cancelled_by"] = cause
        event(ended, "run_cancelled", "cause" => cause)
        WorkflowRun.from_h(ended)
      end
    end

    # Ends every run of a workspace that was killed, so none of them goes on holding a lock for a checkout that
    # is gone. Never raises: a run whose file is malformed is reported, and the others are still ended.
    #
    # @param workspace [String]
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and "failed", the ids of the
    #   runs that could not be
    def workspace_killed(workspace)
      result = {"cancelled" => [], "failed" => []}
      @store.going.select { |run| run.workspace == workspace }.each do |run|
        cancel(run.id, cause: "kill")
        result["cancelled"] << run.id
      rescue
        result["failed"] << run.id
      end
      result
    rescue
      result
    end

    private

    # The body of {#resume}, inside a change the caller holds (a released park is one). Refusals come first, so a
    # refused resume leaves the run and its pane as they were. A check to run outside the lock is registered on +ctx+.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context
    # @param from [String, nil] see {#resume}
    # @param note [String, nil] see {#resume}
    # @param pane [String, nil] see {#resume}
    # @param turn_over [Hash{String=>Object}, nil] see {#resume}
    # @param extra_attempts [Integer, nil] see {#resume}
    # @param extra_tokens [Integer, nil] see {#resume}
    # @param budget [Boolean] false for a parked resume typed again after a busy pane: its attempt was counted then,
    #   so the allowance and budget are not asked again
    # @return [Resumed] the run afterwards, and why nothing was done, or nil
    # @raise [Workspace::Error] as {#resume}
    def apply_resume(run, ctx:, from:, note:, pane:, turn_over:, extra_attempts: nil, extra_tokens: nil, budget: true)
      work = WorkflowRun.deep_thaw(WorkflowRun.from_h(run).to_h)
      unchanged = resume_in(work, ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, budget: budget)
      Resumed.new(run: WorkflowRun.from_h(work), unchanged: unchanged)
    end

    # Refuses an attempt the run has no allowance left for: `attempts_spent` when +extra_attempts+ does not cover
    # the overrun, then `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it.
    # Changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param extra_attempts [Integer, nil]
    # @param extra_tokens [Integer, nil]
    # @return [void]
    # @raise [Workspace::Error] code `attempts_spent` or `budget_spent`
    def refuse_budget(run, extra_attempts:, extra_tokens:)
      run = WorkflowRun.from_h(run).to_h
      refuse_spent(run, extra_attempts)
      refuse_over_budget(run, extra_tokens)
    end

    def resume_in(stored, ctx, from:, note:, pane:, turn_over:, extra_attempts:, extra_tokens:, budget:)
      refuse_resume(stored, from: from)
      state = step_state(stored)
      # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
      unchanged = (from || stored["budget_hold"]) ? nil : left_alone(stored, state, pane, turn_over)
      return unchanged if unchanged
      # A wait whose pane would not take the retry is held before anything is written: no rebind, note, event or reset.
      held = held_by_pane(stored, pane, from)
      return held if held
      # A pane another run has is refused first, so a refusal after this point logs nothing.
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      # Only a resume that starts an attempt is held to the budget (not a parked one typed again after a
      # busy pane: its attempt was counted then); decided before anything is written.
      starting = budget && WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
      spend_attempts(stored, extra_attempts, needed: starting)
      spend_tokens(stored, extra_tokens, needed: starting)
      # A person's resume starts the sweep's retry count again, also for a retry waiting on a lock.
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      # Dropping a park replaces the run's nested Hashes.
      state = step_state(stored)
      stored["pending_context"] << WorkflowRun.resume_note(note) if note
      held = stored.delete("budget_hold")
      drop_retry_text(stored, held) if held && from
      if held && !from
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released")
        stored["reason"] = nil
        dispatch(stored, ctx, context: held["context"], budgeted: budget)
        return nil
      end
      # A resume skips the wait of a retry; `--from` goes elsewhere and drops it.
      waiting_retry = stored.delete("backoff")
      # A stored wait that names no step to go back to is dropped; the failed step is resumed as it stands.
      waiting_retry = nil unless waiting_retry.is_a?(Hash) && waiting_retry["to"].is_a?(String)
      if waiting_retry && !from
        event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"], "backoff" => "skipped")
        stored.replace(WorkflowRun.deep_thaw(@progress.start_retry(stored, waiting_retry, ctx: ctx, proven: !pane.nil?, budgeted: budget).to_h))
        return held_retry_sentence(stored)
      end
      if from
        event(stored, "run_resumed", "from" => from)
        stored["current"] = from
        dispatch(stored, ctx, budgeted: budget)
        return nil
      end
      event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"])
      stored["pending_context"].unshift(last_failure(stored)) if state["state"] == "failed" && stored.dig("reason", "code") == "failed_check"
      case state["state"]
      when "running"
        if pane
          dispatch(stored, ctx, budgeted: budget)
        else
          stored["reason"] = nil
          evaluate(stored, ctx)
        end
      when "checking" then evaluate(stored, ctx)
      when "passed" then stored.replace(WorkflowRun.deep_thaw(@progress.advance(stored, ctx: ctx).to_h))
      else dispatch(stored, ctx, budgeted: budget)
      end
      nil
    end

    # `--from` goes elsewhere: the text that told the held step why it was sent back is not for the step named.
    def drop_retry_text(run, hold)
      index = hold["text"].is_a?(String) ? run["pending_context"].index(hold["text"]) : nil
      run["pending_context"].delete_at(index) if index
    end

    # Refuses with `attempts_spent` when the allowance is used up and +extra+ does not cover the overrun: the
    # attempt about to start must fit, so +extra+ must be at least made minus allowed plus one.
    def refuse_spent(run, extra)
      made = WorkflowTransitions.attempts_made(run)
      allowed = WorkflowTransitions.attempt_allowance(run)
      needed = WorkflowTransitions.extra_attempts_needed(run)
      return if made < allowed || (extra && extra >= needed)
      raise Workspace::Error.new("Run #{run["id"]} has spent max_attempts (#{made} of #{allowed}). Pass --extra-attempts #{needed} to continue.",
        code: "attempts_spent", details: {"run_id" => run["id"], "attempts" => made, "max_attempts" => allowed, "step" => run["current"], "needed" => needed})
    end

    # The budget step of a person's resume or reject: refused before anything changes; +extra+ is added to the
    # run and recorded when the action goes on.
    def spend_attempts(run, extra, needed: true)
      return unless needed
      refuse_spent(run, extra)
      return unless extra
      run["extra_attempts"] = run["extra_attempts"].to_i + extra
      event(run, "attempts_extended", "extra" => extra, "extra_attempts" => run["extra_attempts"], "max_attempts" => WorkflowTransitions.attempt_allowance(run))
    end

    # Refuses with `budget_spent` when the token budget is used up and +extra+ does not cover the overrun (the least
    # is used minus the allowance plus one). A run without a budget is never refused.
    def refuse_over_budget(run, extra)
      reading = WorkflowBudget.reading(run, live: false)
      return unless reading && reading["spent"]
      return if extra && extra >= reading["needed"]
      raise Workspace::Error.new("Run #{run["id"]} has used its token budget (#{reading["used"]} of #{reading["allowance"]} tokens#{" at least" if reading["uncounted"].positive?}). Pass --extra-tokens #{reading["suggested"]} to continue (#{reading["needed"]} is the least).",
        code: "budget_spent", details: WorkflowTransitions.budget_details(run, reading))
    end

    # The token step of a person's resume or reject, as {#spend_attempts} is for attempts.
    def spend_tokens(run, extra, needed: true)
      return unless needed
      refuse_over_budget(run, extra)
      return unless extra && WorkflowBudget.reading(run)
      run["extra_tokens"] = run["extra_tokens"].to_i + extra
      event(run, "budget_extended", "extra" => extra, "extra_tokens" => run["extra_tokens"], "allowance" => WorkflowBudget.reading(run, live: false)["allowance"])
    end

    # A run held by its budget types into the pane it had when the attempt would have started. As for a retry's wait,
    # that pane must still be the run's (a person's +pane+ is the proof); nothing is written, so a refusal costs nothing.
    def held_budget_pane(stored, pane)
      hold = stored["budget_hold"]
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = @progress.retry_pane_problem(stored, hold, pane: pane || @panes.pane_of(stored["id"]) || hold["pane"], proven: !pane.nil?)
      problem && problem[:message].sub(/\.\z/, "")
    end

    # The read-only decision of a resume over a retry's wait: the sentence saying why the retry can't start in the
    # pane it would use (an explicit +pane+ counts as proven), after recording the hold once; nil when it can start
    # or the run waits out no (readable) backoff.
    def held_by_pane(stored, pane, from)
      return held_budget_pane(stored, pane) if stored["budget_hold"].is_a?(Hash)
      waiting = stored["backoff"]
      return nil if from || !(waiting.is_a?(Hash) && waiting["to"].is_a?(String))
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = @progress.retry_pane_problem(stored, waiting, pane: pane, proven: !pane.nil?)
      return nil unless problem
      stored.replace(WorkflowRun.deep_thaw(@progress.hold_retry(stored, waiting, problem, pane: pane || bound_pane(stored)).to_h))
      held_retry_sentence(stored)
    end

    # Why a resume that skipped the wait still started nothing; nil when the retry started.
    def held_retry_sentence(run)
      return nil unless run.dig("backoff", "blocked")
      run.dig("reason", "details", "message").to_s.sub(/\.\z/, "")
    end

    def last_failure(run)
      "The last attempt of this step failed: #{WorkflowTransitions.failure_text(run["reason"]["details"])}."
    end

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over) = WorkflowTransitions.left_alone(run, state, pane, turn_over, @clock.call, -> { bound_pane(run) })

    def rebind(run, pane)
      check_pane(pane, run["id"]) unless @panes.run_on(pane) == run["id"]
      @panes.unbind(run["id"])
      run["pane"] = pane
    end

    # +run_id+ is the run asking, which a park of its own can't refuse; see {WorkflowDispatch#check_pane}.
    def check_pane(pane, run_id) = @dispatch.check_pane(pane, run_id: run_id)

    # The waiting gate of the run's step; with +step+ (and +attempt+), only when the
    # run is at that step (and attempt), so a stale button can't pass a later gate.
    def waiting_gate(run, step: nil, attempt: nil)
      state = step_state(run)
      gate = state["gate"]
      current = state["attempts"].last&.fetch("n", nil)
      waiting = gate && gate["state"] == "waiting"
      return gate if waiting && (step.nil? || step == run["current"]) && (attempt.nil? || attempt == current)
      message = if step
        "Run #{run["id"]} is not waiting at the gate of step #{step.to_s[0, 60]}#{", attempt #{attempt}," if attempt} " \
          "(step #{run["current"]}, attempt #{current.inspect}, is #{state["state"]}#{" and waits at its gate" if waiting}). " \
          "Read `workspace workflow status #{run["id"]}` again."
      else
        "Run #{run["id"]} is not waiting at a gate (step #{run["current"]} is #{state["state"]})."
      end
      raise Workspace::Error.new(message,
        code: "gate_not_waiting",
        details: {"run_id" => run["id"], "step" => run["current"], "attempt" => current, "state" => state["state"],
                  "expected_step" => step, "expected_attempt" => attempt})
    end

    # The note the approval is of, as {"path", "sha256"}: hashed once here, compared with
    # what the caller read when it says, and recorded as read.
    def gate_file(run, note_sha256)
      found = @gate_note.find(run)
      if note_sha256
        raise @gate_note.missing(run) unless found
        unless found["sha256"] == note_sha256
          raise Workspace::Error.new("The note #{found["path"]} changed since that revision: its sha256 is now #{found["sha256"]}. " \
            "Read it again before you approve.",
            code: "stale_revision",
            details: {"revision" => found["sha256"], "path" => found["path"], "run_id" => run["id"], "step" => run["current"],
                      "attempt" => step_state(run)["attempts"].last&.fetch("n", nil)})
        end
      end
      found&.slice("path", "sha256")
    end

    # A gate event carries the person's note only when one was given.
    def with_note(data, note)
      note.to_s.strip.empty? ? data : data.merge("note" => note)
    end

    def park_target(run)
      run["parked"]["pane"] || bound_pane(run)
    end

    # +request+ is what a resume would be given: "from", "note", "pane", "turn_over".
    def store_park(run, request, expires_at:)
      run.replace(WorkflowRun.deep_thaw(WorkflowRun.from_h(run).with_park(request, id: SecureRandom.hex(8), requested_at: now_iso, expires_at: expires_at, retries: 0).to_h))
      event(run, "resume_parked", {"step" => run["current"], "pane" => request["pane"] || bound_pane(run), "from" => request["from"],
                                   "has_note" => !request["note"].nil?})
    end

    # Takes a park off the run however it ended; see {WorkflowDispatch#drop_park}.
    def drop_park(run, how, extra = {})
      run.replace(WorkflowRun.deep_thaw(@dispatch.drop_park(run, how, extra).to_h)) if run.key?("parked")
    end

    def dispatch(run, ctx, **options)
      run.replace(WorkflowRun.deep_thaw(@dispatch.dispatch(run, ctx: ctx, **options).to_h))
    end

    def evaluate(run, ctx)
      run.replace(WorkflowRun.deep_thaw(@evaluation.evaluate(run, ctx: ctx).to_h))
    end

    def event(run, type, data = {}) = @change.event(run, type, data)

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    def step_ids(run)
      run["definition"]["steps"].map { |step| step["id"] }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
