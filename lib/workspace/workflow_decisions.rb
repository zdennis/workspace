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
    # @param guard [Workspace::WorkflowGuard] takes the checkout as it is now as the run's base, for `resume --accept-guard`
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, progress:, dispatch:, evaluation:, attempt_record:, gate_note:, panes:, guard:, clock: -> { Time.now })
      @change = change
      @store = store
      @progress = progress
      @dispatch = dispatch
      @evaluation = evaluation
      @attempt_record = attempt_record
      @gate_note = gate_note
      @panes = panes
      @guard = guard
      @clock = clock
    end

    # Passes a gate: the run goes on to the step after the gated one. When the gated step's first file names a
    # note (`note: <file>`), the note's sha256 is recorded with the approval and named in the next step's
    # instructions. Every check runs under the run's lock, in this order: the gate is waiting (at +step+ and
    # +attempt+ when given), +guard+, then the note. A refusal leaves the run file as it was.
    #
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `stale_revision`, `gate_note_unreadable`, and what +guard+ raises
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @change.call(run_id) do |read, ctx|
        stored = read.thawed
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
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @param extra_seconds [Integer, nil] added to the run's timeout (see {#resume})
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `attempts_spent`, `budget_spent`, `run_timed_out`, and what +guard+ raises
    # @raise [Workspace::UsageError] when +to+ is not the gated step or one before it
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil)
      @change.call(run_id) do |read, ctx|
        stored = read.thawed
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        unless ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        # The step runs again, which is a new attempt.
        spend_attempts(stored, extra_attempts, target: target)
        spend_limits(stored, extra_tokens, extra_seconds)
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
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was seen to have ended
    #   its turn on that attempt, so the step, if the run is still on that attempt and it reads `running`, is decided now
    # @param extra_attempts [Integer, nil] raises the run's attempt allowance by this much, kept in the run and
    #   recorded as `attempts_extended`; applied only when the resume starts an attempt
    # @param extra_tokens [Integer, nil] raises the run's token budget by this much, kept in the run and recorded
    #   as `budget_extended`; applied only when the resume starts an attempt or a review round
    # @param extra_seconds [Integer, nil] raises the run's timeout by this many seconds, kept in the run (`extra_seconds`)
    #   and recorded as `time_extended`; applied only when the resume starts an attempt or a review round
    # @param accept_guard [Boolean] take a guard stop ({WorkflowTransitions.acceptable_guard}) as a person's decision:
    #   the checkout as it is now becomes the run's base (`base_sha`, `base_guard`), a `guard_overridden` event records
    #   +note+ (required), and the rest of the step's evaluation runs with the guard left out
    #   ({WorkflowEvaluation#evaluate_accepted}): the attempt reads `overridden` and the step passes only when its
    #   `produces`, `require:` and `status:` pass too
    # @param guard_retry [Boolean] with +accept_guard+: run the stopped step again instead, a new attempt held to the allowance and budget
    # @param caller_pane [String, nil] the pane the person ran the command in, recorded on `guard_overridden`
    # @return [Resumed] the run afterwards, and why nothing was done when it did nothing
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` or `budget_spent` when the resume would
    #   start an attempt the run has no allowance left for; `budget_spent` or `run_timed_out` when it would start a
    #   review round (one a hold kept back, or a fresh one after a stopped round) past the budget or the timeout;
    #   with +accept_guard+, `guard_base_unreadable` (retryable, nothing changed) when the checkout can't be read as a
    #   new base, and with +guard_retry+ `guard_cannot_pass` when the retry would stop on `no_commit` or
    #   `operation_in_progress` again
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil,
      accept_guard: false, guard_retry: false, caller_pane: nil)
      refuse_guard_flags(from: from, note: note, accept_guard: accept_guard, guard_retry: guard_retry)
      follow = nil
      unchanged = nil
      run = @change.call(run_id) do |read, ctx|
        follow = ctx
        if accept_guard
          next accept_guard_stop(read, ctx, note: note, pane: pane, guard_retry: guard_retry, caller_pane: caller_pane,
            extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds)
        end
        resumed = apply_resume(read, ctx: ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds)
        unchanged = resumed.unchanged
        resumed.run
      end
      Resumed.new(run: @evaluation.finish_follow_ups(run_id, follow, run), unchanged: unchanged)
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
    # @param extra_seconds [Integer, nil] see {#resume}; applied when the park is released
    # @return [Resumed] the run afterwards, and why nothing was stored when nothing was
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent` or `budget_spent` as {#resume}; `step_reviewing` for a step being reviewed (a park
    #   would hold back the review pane's turn end, which decides the round)
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil)
      unchanged = nil
      run = @change.call(run_id) do |read|
        stored = read.thawed
        refuse_resume(stored, from: from)
        refuse_reviewing_park(stored, from)
        if WorkflowTransitions.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id) if pane && @panes.run_on(pane) != run_id
        refuse_budget(stored, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, from: from) if WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
        drop_park(stored, "expired")
        store_park(stored, {"from" => from, "note" => note, "pane" => pane, "turn_over" => turn_over}.merge(extra_attempts ? {"extra_attempts" => extra_attempts} : {}).merge(extra_tokens ? {"extra_tokens" => extra_tokens} : {}).merge(extra_seconds ? {"extra_seconds" => extra_seconds} : {}),
          expires_at: (@clock.call + PARK_SECONDS).utc.iso8601)
        WorkflowRun.from_h(stored)
      end
      Resumed.new(run: run, unchanged: unchanged)
    end

    # Carries out a parked resume, in one change with taking it off the run. A park typed again after a busy pane
    # (`retries` above 0) is not held to the allowance and budget a second time: its attempt was counted then.
    #
    # @param id [String] the park's id; any other changes nothing
    # @return [Resumed] the run afterwards, and why the resume did nothing (its note kept for the next attempt), or nil
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id)
      follow = nil
      unchanged = nil
      run = @change.call(run_id) do |read, ctx|
        parked = read.parked
        next unless parked && parked["id"] == id
        refuse_unrecoverable_guard(read.to_h)
        stored = read.thawed
        stored.delete("parked")
        resumed = apply_resume(stored, ctx: ctx, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"],
          extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"], extra_seconds: parked["extra_seconds"], budget: parked["retries"].to_i.zero?)
        stored = resumed.run.thawed
        unchanged = resumed.unchanged
        follow = ctx
        stored["pending_context"] << WorkflowRun.resume_note(parked["note"]) if unchanged && parked["note"]
        event(stored, "resume_parked_ended", {"step" => stored["current"], "how" => unchanged ? "unchanged" : "released"}
          .merge(unchanged ? {"detail" => unchanged} : {}))
        if ctx.delivery
          step_state(stored)["attempts"].last["after_park"] = {"expires_at" => parked["expires_at"], "pane" => ctx.delivery["pane"], "retries" => parked["retries"]}
        end
        WorkflowRun.from_h(stored)
      end
      Resumed.new(run: @evaluation.finish_follow_ups(run_id, follow, run), unchanged: unchanged)
    end

    # Ends a park that can't be released; the run waits for a person. The step and what it holds stay (a `running`
    # step keeps its attempt for a later resume); a lock the run queued for is given up. A run at a gate keeps its
    # gate reason, so approve and reject stay open; the failure is in the `resume_parked_ended` event.
    #
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`, with +message+
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:)
      @change.call(run_id) do |read|
        stored = read.thawed
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

    # What {#resume} refuses, checked without changing anything, so a caller can refuse before it starts a daemon.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run that has not finished
    # @param from [String, nil] the step a resume would start again at
    # @param note [String, nil] the resume's note, which +accept_guard+ needs
    # @param accept_guard [Boolean] see {#resume}
    # @param guard_retry [Boolean] see {#resume}
    # @return [void]
    # @raise [Workspace::Error] code `gate_waiting` for a run at a gate when no step is named (approve or reject it);
    #   code `guard_cannot_pass` for a run stopped on a guard no resume can pass ({WorkflowTransitions.guard_unrecoverable?})
    #   unless +accept_guard+; code `guard_not_stopped` with +accept_guard+ for a run no guard stopped
    # @raise [Workspace::UsageError] for a step the workflow doesn't have, and for +accept_guard+ without a +note+,
    #   +guard_retry+ without +accept_guard+, or +accept_guard+ with +from+
    def refuse_resume(run, from: nil, note: nil, accept_guard: false, guard_retry: false)
      refuse_guard_flags(from: from, note: note, accept_guard: accept_guard, guard_retry: guard_retry)
      run = WorkflowRun.from_h(run).to_h
      return refuse_not_guard_stopped(run) if accept_guard
      refuse_unrecoverable_guard(run)
      if from
        return if step_ids(run).include?(from)
        raise UsageError, "No step #{from.to_s[0, 60].inspect} in workflow #{run["workflow"]} (#{step_ids(run).join(", ")})."
      end
      return unless step_state(run).dig("gate", "state") == "waiting"
      raise Workspace::Error.new("Run #{run["id"]} is waiting at the #{run["current"]} gate. Approve or reject it, or pass --from STEP.",
        code: "gate_waiting", details: {"run_id" => run["id"], "step" => run["current"]})
    end

    # Ends a run: closes its open attempt, gives up its resources and frees its pane. A step being reviewed has no
    # open attempt; its round is ended instead ({WorkflowProgress#end_round}: its usage and the verdicts it read
    # recorded on the reviewed attempt), and its review window is closed once the lock is given up.
    #
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      follow = nil
      run = @change.call(run_id) do |read, ctx|
        follow = ctx
        read = @progress.end_round(read, how: "cancelled", ctx: ctx) if read.current_step&.state == "reviewing"
        ended = @progress.finish(@attempt_record.abandon(read), "cancelled").thawed
        ended["cancelled_by"] = cause
        event(ended, "run_cancelled", "cause" => cause)
        WorkflowRun.from_h(ended)
      end
      @evaluation.finish_follow_ups(run_id, follow, run)
    end

    # Ends every run of a workspace that was killed, so none goes on holding a lock for a checkout that is gone.
    # Never raises: a run whose file is malformed is reported, and the others are still ended.
    #
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and "failed", the ones that could not be
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

    def adopt(run, changed) = run.replace(changed.thawed)

    # The flags of a guard acceptance that can't go together, refused before the run is read.
    def refuse_guard_flags(from:, note:, accept_guard:, guard_retry:)
      raise UsageError, "--retry is for `workflow resume RUN --accept-guard --note WHY`." if guard_retry && !accept_guard
      return unless accept_guard
      raise UsageError, "--accept-guard needs --note WHY: the reason is recorded and given to the next attempt." if note.to_s.strip.empty?
      raise UsageError, "--retry runs the stopped step again; --from can't go with it." if guard_retry && from
      raise UsageError, "--accept-guard judges the stopped step again without its guard, or runs it again with --retry; --from can't go with it." if from
    end

    def refuse_not_guard_stopped(run)
      return if WorkflowTransitions.guard_acceptable?(run)
      reason = run["reason"].is_a?(Hash) ? run["reason"] : {}
      raise Workspace::Error.new("Run #{run["id"]} is not stopped by a guard (step #{run["current"]}, reason #{reason["code"] || "none"}), so there is no guard stop to accept.",
        code: "guard_not_stopped", details: {"run_id" => run["id"], "step" => run["current"], "reason" => reason["code"], "guard" => reason.dig("details", "guard")})
    end

    # The body of {#resume} with +accept_guard+, inside the change: every refusal first, then the checkout as it is
    # now becomes the run's base and `guard_overridden` records the note. Only the guard is accepted: without
    # +guard_retry+ the rest of the step's evaluation runs with the guard left out ({WorkflowEvaluation#evaluate_accepted}),
    # so a missing `produces` file, an unmet `require:` proof or a failing `status:` check still stops the step.
    def accept_guard_stop(read, ctx, note:, pane:, guard_retry:, caller_pane:, extra_attempts:, extra_tokens:, extra_seconds:)
      stored = read.thawed
      refuse_resume(stored, note: note, accept_guard: true, guard_retry: guard_retry)
      guard = WorkflowTransitions.acceptable_guard(stored)
      step = stored["current"]
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      if guard_retry
        refuse_spent(stored, extra_attempts, target: step)
        refuse_over_limits(stored, extra_tokens, extra_seconds)
      end
      base = @guard.base(stored["worktree"], accept_tree: true)
      refuse_unusable_base(stored, guard, base)
      refuse_hopeless_retry(stored, guard, base) if guard_retry
      if guard_retry
        spend_attempts(stored, extra_attempts, target: step)
        spend_limits(stored, extra_tokens, extra_seconds)
      end
      old_sha = stored["base_sha"]
      stored["base_sha"] = base["base_sha"]
      stored["base_guard"] = base["base_guard"]
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      event(stored, "guard_overridden", {"step" => step, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil), "guard" => guard,
                                         "old_base_sha" => old_sha, "new_base_sha" => stored["base_sha"], "note" => note,
                                         "pane" => caller_pane, "retry" => guard_retry})
      stored["pending_context"] << WorkflowTransitions.guard_accepted_line(guard, step, stored["base_sha"])
      stored["pending_context"] << WorkflowRun.resume_note(note)
      if guard_retry
        event(stored, "run_resumed", "from" => step, "accept_guard" => guard)
        dispatch(stored, ctx, budgeted: true)
      else
        event(stored, "run_resumed", "step" => step, "state" => "failed", "accept_guard" => guard)
        adopt(stored, @evaluation.evaluate_accepted(stored, ctx: ctx))
      end
      WorkflowRun.from_h(stored)
    end

    # A base the guard can't measure from (HEAD unread though the branch has commits, or the hooks or hidden-file
    # reading missing) would stop every later guarded step, or pass one it should not; nothing is changed.
    def refuse_unusable_base(run, guard, base)
      unread = Array(base["unread"])
      return if unread.empty?
      raise Workspace::Error.new("Run #{run["id"]}: the checkout could not be read as a new base (#{unread.join(", ")}), so the #{guard} stop was not accepted and the run's base is unchanged. Try again; if it keeps failing, check `git -C #{run["worktree"]} status`.",
        code: "guard_base_unreadable", details: {"run_id" => run["id"], "step" => run["current"], "guard" => guard, "unread" => unread}, retry_with: {"flags" => [], "destructive" => false})
    end

    # A retry measured from the new base would stop the same way while the cause is still there: no commit to measure
    # from, or a rebase, merge or other operation still under way.
    def refuse_hopeless_retry(run, guard, base)
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      found = @guard.check(run["worktree"], base, step["guard"] || "unchanged")
      code = found && found["code"]
      fix = {"no_commit" => "the branch still has no commit: commit something first, or accept the stop without --retry",
             "operation_in_progress" => "a rebase, merge, cherry-pick or bisect is still under way: finish or abort it first"}[code]
      return unless fix
      raise Workspace::Error.new("Run #{run["id"]}: a retry of #{run["current"]} would stop on #{code} again, since #{fix}.",
        code: "guard_cannot_pass", details: {"run_id" => run["id"], "step" => run["current"], "guard" => code, "accepted" => guard, "retry" => true})
    end

    # A park is refused on a step being reviewed: while one stands, the review pane's turn end decides nothing.
    def refuse_reviewing_park(run, from)
      return unless step_state(run)["state"] == "reviewing"
      command = "workspace workflow resume #{run["id"]}#{" --from #{from}" if from}"
      raise Workspace::Error.new("Run #{run["id"]} is reviewing step #{run["current"]}, so a resume can't be parked for later from this pane. " \
        "Run `#{command}` from another terminal.",
        code: "step_reviewing", details: {"run_id" => run["id"], "step" => run["current"]})
    end

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
    # @param extra_seconds [Integer, nil] see {#resume}
    # @param budget [Boolean] false for a parked resume typed again after a busy pane: its attempt was counted then,
    #   so the allowance and budget are not asked again
    # @return [Resumed] the run afterwards, and why nothing was done, or nil
    # @raise [Workspace::Error] as {#resume}
    def apply_resume(run, ctx:, from:, note:, pane:, turn_over:, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, budget: true)
      work = WorkflowRun.from_h(run).thawed
      unchanged = resume_in(work, ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, budget: budget)
      Resumed.new(run: WorkflowRun.from_h(work), unchanged: unchanged)
    end

    # Refuses an attempt the run has no allowance left for: `attempts_spent` when +extra_attempts+ does not cover
    # the run's overrun, then `step_attempts_spent` for the target step's own cap, then `budget_spent` when the
    # token budget is used up and +extra_tokens+ does not cover it, or `run_timed_out` likewise for the timeout and
    # +extra_seconds+. Changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}]
    # @param extra_attempts [Integer, nil]
    # @param extra_tokens [Integer, nil]
    # @param extra_seconds [Integer, nil]
    # @param from [String, nil] the step a resume would start again at
    # @return [void]
    # @raise [Workspace::Error] code `attempts_spent`, `step_attempts_spent`, `budget_spent` or `run_timed_out`
    def refuse_budget(run, extra_attempts:, extra_tokens:, extra_seconds: nil, from: nil)
      run = WorkflowRun.from_h(run).to_h
      refuse_spent(run, extra_attempts, target: WorkflowTransitions.target_step(run, from: from))
      refuse_over_limits(run, extra_tokens, extra_seconds)
    end

    def resume_in(stored, ctx, from:, note:, pane:, turn_over:, extra_attempts:, extra_tokens:, extra_seconds:, budget:)
      refuse_resume(stored, from: from)
      state = step_state(stored)
      # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
      unchanged = (from || hold_of(stored)) ? nil : left_alone(stored, state, pane, turn_over)
      return unchanged if unchanged
      # A wait whose pane would not take the retry is held before anything is written: no rebind, note, event or reset.
      held = held_by_pane(stored, pane, from)
      return held if held
      # A pane another run has is refused first, so a refusal after this point logs nothing.
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      # Only a resume that starts an attempt is held to the budget (not a parked one typed again after a
      # busy pane: its attempt was counted then); decided before anything is written.
      starting = budget && WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
      # A review round is not an attempt, so it asks no attempt allowance; it is held to the budget and the timeout.
      round = budget && WorkflowTransitions.starts_round?(stored, from: from)
      spend_attempts(stored, extra_attempts, needed: starting, target: WorkflowTransitions.target_step(stored, from: from))
      spend_limits(stored, extra_tokens, extra_seconds, needed: starting || round)
      # A person's resume starts the sweep's retry count again, also for a retry waiting on a lock.
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      # Dropping a park replaces the run's nested Hashes.
      state = step_state(stored)
      stored["pending_context"] << WorkflowRun.resume_note(note) if note
      held = stored.delete("budget_hold")
      time_held = stored.delete("timeout_hold")
      held ||= time_held
      drop_retry_text(stored, held) if held && from
      if held&.key?("review_round") && !from
        # The held round starts now, never the author: the release goes through the round's one start.
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released", "review_round" => held["review_round"])
        stored["reason"] = nil
        stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
        return nil
      end
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
        adopt(stored, @progress.start_retry(stored, waiting_retry, ctx: ctx, proven: !pane.nil?, budgeted: budget))
        return held_retry_sentence(stored)
      end
      if from
        # The round under way ends first, its window closed, so no reviewer goes on judging work the run left.
        stored.replace(@progress.end_round(stored, how: "from", ctx: ctx).thawed) if state["state"] == "reviewing"
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
      # A round is not an attempt: a resume never starts the author again on a step being reviewed, only its round.
      when "reviewing" then stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
      when "passed" then adopt(stored, @progress.advance(stored, ctx: ctx))
      else dispatch(stored, ctx, budgeted: budget)
      end
      nil
    end

    # `--from` goes elsewhere: the text that told the held step why it was sent back is not for the step named.
    def drop_retry_text(run, hold)
      index = hold["text"].is_a?(String) ? run["pending_context"].index(hold["text"]) : nil
      run["pending_context"].delete_at(index) if index
    end

    # Refuses with `attempts_spent` when the allowance is used up and +extra+ is under made minus allowed plus one, then with
    # `step_attempts_spent` when +target+'s own cap is used up and +extra+ does not cover it.
    def refuse_spent(run, extra, target: nil)
      made = WorkflowTransitions.attempts_made(run)
      allowed = WorkflowTransitions.attempt_allowance(run)
      needed = WorkflowTransitions.extra_attempts_needed(run)
      covered = extra && extra >= needed
      unless made < allowed || covered
        raise Workspace::Error.new("Run #{run["id"]} has spent max_attempts (#{made} of #{allowed}). Pass --extra-attempts #{needed} to continue.",
          code: "attempts_spent", details: {"run_id" => run["id"], "attempts" => made, "max_attempts" => allowed, "step" => run["current"], "needed" => needed})
      end
      return unless target && WorkflowTransitions.step_attempts_spent?(run, target)
      step_needed = WorkflowTransitions.step_extra_attempts_needed(run, target)
      return if extra && extra >= step_needed
      step_made = WorkflowTransitions.step_attempts_made(run, target)
      step_allowed = WorkflowTransitions.step_allowance(run, target)
      raise Workspace::Error.new("Step #{target} of run #{run["id"]} has spent its max_attempts (#{step_made} of #{step_allowed}). Pass --extra-attempts #{step_needed} to continue.",
        code: "step_attempts_spent", details: {"run_id" => run["id"], "step" => target, "attempts" => step_made, "max_attempts" => step_allowed, "needed" => step_needed})
    end

    # The attempt step of a person's resume or reject: refused before anything changes, else +extra+ added to the run's
    # allowance and +target+'s own one (when it has a cap) and recorded.
    def spend_attempts(run, extra, needed: true, target: nil)
      return unless needed
      refuse_spent(run, extra, target: target)
      return unless extra
      run["extra_attempts"] = run["extra_attempts"].to_i + extra
      payload = {"extra" => extra, "extra_attempts" => run["extra_attempts"], "max_attempts" => WorkflowTransitions.attempt_allowance(run)}
      if target && WorkflowTransitions.step_allowance(run, target)
        state = run["steps"][target]
        state["extra_attempts"] = state["extra_attempts"].to_i + extra
        payload.merge!("step" => target, "step_extra_attempts" => state["extra_attempts"], "step_max_attempts" => WorkflowTransitions.step_allowance(run, target))
      end
      event(run, "attempts_extended", payload)
    end

    # The hold a resume ends: the token budget's, else the timeout's (both hold the same record).
    def hold_of(run)
      [run["budget_hold"], run["timeout_hold"]].find { |hold| hold.is_a?(Hash) }
    end

    # A run stopped by `no_commit` with no base_sha compares every guarded step to a nil base, so any attempt, from
    # any step, fails the same way; only a cancel goes on. Every other guard stop passes again once the checkout is
    # put back, and resumes normally.
    def refuse_unrecoverable_guard(run)
      return unless WorkflowTransitions.guard_unrecoverable?(run)
      raise Workspace::Error.new("Run #{run["id"]} stopped at #{run["current"]} on the no_commit guard and has no base commit, so no plain resume can pass it. Run `workflow resume #{run["id"]} --accept-guard --note WHY` to pass the step anyway, or `workflow cancel #{run["id"]}` and start a new run once the branch has a commit.",
        code: "guard_cannot_pass", details: {"run_id" => run["id"], "step" => run["current"], "guard" => "no_commit"})
    end

    # What a spent token budget refuses with, or nil: not spent, or +extra+ covers the overrun (the least is used
    # minus the allowance plus one). A run without a budget is never refused.
    def budget_shortfall(run, extra)
      reading = WorkflowBudget.reading(run, live: false)
      return nil unless reading && reading["spent"]
      return nil if extra && extra >= reading["needed"]
      reading
    end

    # What a spent run timeout refuses with, or nil: not spent, or +extra+ seconds cover the overrun.
    def deadline_shortfall(run, extra)
      reading = WorkflowDeadline.reading(run, @clock.call)
      return nil unless reading && reading["spent"]
      return nil if extra && extra >= reading["needed"]
      reading
    end

    # Refuses with `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it, and with
    # `run_timed_out` when the run's timeout is used up and +extra_seconds+ does not cover it. With both short the
    # refusal is `budget_spent` and names both needs (the time one under `details.run_timed_out`).
    def refuse_over_limits(run, extra_tokens, extra_seconds)
      reading = budget_shortfall(run, extra_tokens)
      deadline = deadline_shortfall(run, extra_seconds)
      return unless reading || deadline
      used = []
      pass = []
      least = []
      if reading
        used << "its token budget (#{reading["used"]} of #{reading["allowance"]} tokens#{" at least" if reading["uncounted"].positive?})"
        pass << "--extra-tokens #{reading["suggested"]}"
        least << [reading["needed"].to_s, "--extra-tokens"]
      end
      if deadline
        used << "its time limit (#{Duration.humanize(deadline["used"].to_f)} of #{Duration.humanize(deadline["limit"].to_f)})"
        pass << "--extra-time #{Duration.flag(deadline["suggested"])}"
        least << [Duration.flag(deadline["needed"]), "--extra-time"]
      end
      needs = (least.size == 1) ? "(#{least[0][0]} is the least)" : "(the least is #{least.map { |amount, flag| "#{amount} for #{flag}" }.join(", ")})"
      message = "Run #{run["id"]} has used #{used.join(" and ")}. Pass #{pass.join(" and ")} to continue #{needs}."
      if reading
        details = WorkflowTransitions.budget_details(run, reading)
        details["run_timed_out"] = WorkflowTransitions.deadline_details(run, deadline) if deadline
        raise Workspace::Error.new(message, code: "budget_spent", details: details)
      end
      raise Workspace::Error.new(message, code: "run_timed_out", details: WorkflowTransitions.deadline_details(run, deadline))
    end

    # The limits step of a person's resume or reject, as {#spend_attempts} is for attempts: refused first, then
    # +extra_tokens+ is added to the run's token budget and +extra_seconds+ to its timeout (each only when the run has
    # one) and recorded.
    def spend_limits(run, extra_tokens, extra_seconds, needed: true)
      return unless needed
      refuse_over_limits(run, extra_tokens, extra_seconds)
      if extra_tokens && WorkflowBudget.reading(run)
        run["extra_tokens"] = run["extra_tokens"].to_i + extra_tokens
        event(run, "budget_extended", "extra" => extra_tokens, "extra_tokens" => run["extra_tokens"], "allowance" => WorkflowBudget.reading(run, live: false)["allowance"])
      end
      return unless extra_seconds && WorkflowDeadline.reading(run, @clock.call)
      run["extra_seconds"] = run["extra_seconds"].to_i + extra_seconds
      event(run, "time_extended", "extra" => extra_seconds, "extra_seconds" => run["extra_seconds"],
        "limit" => WorkflowDeadline.reading(run, @clock.call)["limit"])
    end

    # A run held by its budget types into the pane it had when the attempt would have started. As for a retry's wait,
    # that pane must still be the run's (a person's +pane+ is the proof); nothing is written, so a refusal costs nothing.
    def held_attempt_pane(stored, pane)
      hold = hold_of(stored)
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = @progress.retry_pane_problem(stored, hold, pane: pane || @panes.pane_of(stored["id"]) || hold["pane"], proven: !pane.nil?)
      problem && problem[:message].sub(/\.\z/, "")
    end

    # Why a retry's wait can't start in the pane it would use (an explicit +pane+ is proven), after recording the
    # hold once; nil when it can start or the run waits out no (readable) backoff.
    def held_by_pane(stored, pane, from)
      # A held review round types into its own review window, not the author's pane.
      return nil if WorkflowTransitions.round_hold?(stored)
      return held_attempt_pane(stored, pane) if hold_of(stored)
      waiting = stored["backoff"]
      return nil if from || !(waiting.is_a?(Hash) && waiting["to"].is_a?(String))
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = @progress.retry_pane_problem(stored, waiting, pane: pane, proven: !pane.nil?)
      return nil unless problem
      adopt(stored, @progress.hold_retry(stored, waiting, problem, pane: pane || bound_pane(stored)))
      held_retry_sentence(stored)
    end

    # Why a resume that skipped the wait still started nothing; nil when the retry started.
    def held_retry_sentence(run)
      return nil unless run.dig("backoff", "blocked")
      run.dig("reason", "details", "message").to_s.sub(/\.\z/, "")
    end

    def last_failure(run) = "The last attempt of this step failed: #{WorkflowTransitions.failure_text(run["reason"]["details"])}."

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over) = WorkflowTransitions.left_alone(run, state, pane, turn_over, @clock.call, -> { bound_pane(run) })

    def rebind(run, pane)
      check_pane(pane, run["id"]) unless @panes.run_on(pane) == run["id"]
      @panes.unbind(run["id"])
      run["pane"] = pane
    end

    # +run_id+ is the run asking, which a park of its own can't refuse; see {WorkflowDispatch#check_pane}.
    def check_pane(pane, run_id) = @dispatch.check_pane(pane, run_id: run_id)

    # The waiting gate of the run's step; with +step+ (and +attempt+), only when the run is there, so a stale button can't pass a later gate.
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

    # The note the approval is of, as {"path", "sha256"}: hashed once, compared with what the caller read, recorded as read.
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
    def with_note(data, note) = note.to_s.strip.empty? ? data : data.merge("note" => note)
    def park_target(run) = run["parked"]["pane"] || bound_pane(run)

    # +request+ is what a resume would be given: "from", "note", "pane", "turn_over".
    def store_park(run, request, expires_at:)
      adopt(run, WorkflowRun.from_h(run).with_park(request, id: SecureRandom.hex(8), requested_at: now_iso, expires_at: expires_at, retries: 0))
      event(run, "resume_parked", {"step" => run["current"], "pane" => request["pane"] || bound_pane(run), "from" => request["from"],
                                   "has_note" => !request["note"].nil?})
    end

    # Takes a park off the run however it ended; see {WorkflowDispatch#drop_park}.
    def drop_park(run, how, extra = {})
      adopt(run, @dispatch.drop_park(run, how, extra)) if run.key?("parked")
    end

    def dispatch(run, ctx, **options) = adopt(run, @dispatch.dispatch(run, ctx: ctx, **options))
    def evaluate(run, ctx) = adopt(run, @evaluation.evaluate(run, ctx: ctx))
    def event(run, type, data = {}) = @change.event(run, type, data)
    def bound_pane(run) = @panes.pane_of(run["id"]) || run["pane"]
    def step_ids(run) = run["definition"]["steps"].map { |step| step["id"] }
    def step_state(run) = run["steps"].fetch(run["current"])
    def now_iso = @clock.call.utc.iso8601
  end
end
