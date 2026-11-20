require "securerandom"
require "time"

module Workspace
  # A person's commands on a run: passing or turning down a gate ({#approve}, {#reject}), getting a run that is
  # not moving going again ({#resume}, refused first by {#refuse_resume}), and ending it ({#cancel},
  # {#workspace_killed}). A resume that can't be typed yet is parked on the run ({#park}), then carried out
  # ({#release_park}) or ended ({#park_failed}). A person can stop a run from starting anything new ({#pause}) and
  # let it go on ({#unpause}), which does what the pause held. A command that starts an attempt is held to the run's attempt
  # allowance and token budget, which `--extra-attempts` and `--extra-tokens` raise. What follows goes through
  # {WorkflowProgress}, {WorkflowDispatch} and {WorkflowEvaluation}. Each method that takes a run leaves it as it
  # is and returns the run afterwards.
  class WorkflowDecisions
    # What a resume or a park did: the run afterwards, and why nothing was done (a sentence), or nil when it acted.
    Resumed = Data.define(:run, :unchanged)

    # What a pause did: the run afterwards, and whether `--interrupt` pressed the agent's interrupt keys
    # (`interrupted`; false when nothing was pressed or the press failed), and why a press failed (`warning`).
    Paused = Data.define(:run, :interrupted, :warning) do
      def initialize(run:, interrupted:, warning: nil) = super
    end

    # What an unpause did: the run afterwards, the branch it took (`action`, as on `run_unpaused`), the kind of
    # dispatch the pause held (`held`: `attempt`, `round` or `delivery`; nil when none), and the continue line of a
    # turn `pause --interrupt` stopped (`continued`: true when typed, false when the pane refused it, with the reason
    # as `warning`; "pending" when the tick types it once the pane is idle; nil when none applies).
    Unpaused = Data.define(:run, :action, :held, :continued, :warning)

    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = WorkflowTransitions::PARK_SECONDS

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] lists the runs going, for {#workspace_killed}
    # @param progress [Workspace::WorkflowProgress] goes on past a gate, ends a run and starts or holds a retry
    # @param dispatch [Workspace::WorkflowDispatch] starts a step, checks a pane and drops a park
    # @param evaluation [Workspace::WorkflowEvaluation] decides a step a resume looks at again, and runs its check
    # @param attempt_record [Workspace::WorkflowAttemptRecord] closes the open attempt of a run that is cancelled
    # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
    # @param panes [Workspace::WorkflowPanes] finds, binds and unbinds the run's pane
    # @param guard [Workspace::WorkflowGuard] takes the checkout as it is now as the run's base, for `resume --accept-guard`
    # @param holder_alive [#call, nil] given a review round's delivery `holder` ("pid", "started"), whether that process
    #   still runs: a round whose mark lapsed is delivered again by a resume only once its holder is gone; nil takes
    #   every holder as alive
    # @param interrupter [#call] presses keys in a pane (`workspace`, `pane`, `keys`), for `pause --interrupt`; raises
    #   {Workspace::Error} when it can't, and the pause then drops its interrupt mark
    # @param recovery [Workspace::WorkflowRecovery, nil] ends the open stalls of an attempt a resume keeps ({WorkflowRecovery#close_stalls}); nil ends none
    # @param downtime [Workspace::WorkflowDowntime, nil] its spans are cut from the run's timeout clock (nil: none)
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, progress:, dispatch:, evaluation:, attempt_record:, gate_note:, panes:, guard:, interrupter:, recovery: nil, holder_alive: nil,
      downtime: nil, clock: -> { Time.now })
      @downtime = downtime
      @recovery = recovery
      @change = change
      @store = store
      @progress = progress
      @dispatch = dispatch
      @evaluation = evaluation
      @attempt_record = attempt_record
      @gate_note = gate_note
      @panes = panes
      @guard = guard
      @holder_alive = holder_alive
      @interrupter = interrupter
      @clock = clock
    end

    # Passes a gate: the run goes on to the step after the gated one. When the gated step's first file names a
    # note (`note: <file>`), the note's sha256 is recorded with the approval and named in the next step's
    # instructions. Every check runs under the run's lock, in this order: the gate is waiting (at +step+ and
    # +attempt+ when given), +guard+, then the note. A refusal leaves the run file as it was. A +step+ that is a
    # fan_out sibling under way is approved whichever sibling the cursor is on: its gate is the one checked, and the
    # group's join decides what comes next.
    #
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `stale_revision`, `gate_note_unreadable`, and what +guard+ raises
    def approve(run_id, actor:, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @change.call(run_id, actor: actor, cause: "approve") do |read, ctx|
        stored = WorkflowTransitions.at_step(read.thawed, step)
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        file = gate_file(stored, note_sha256)
        gate.merge!("state" => "approved", "at" => now_iso, "note" => note)
        gate["file"] = file if file
        event(stored, "gate_approved", with_note({"step" => stored["current"]}, note).merge(file ? {"sha256" => file["sha256"]} : {}))
        WorkflowRun.add_context(stored, stored["current"], "The #{stored["current"]} step was approved with this note: #{note}") if note
        WorkflowRun.add_context(stored, stored["current"], "The approved note is #{file["path"]}, sha256 #{file["sha256"]}.") if file
        @progress.advance(stored, ctx: ctx)
      end
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note. A +step+ that is a fan_out
    # sibling under way is rejected as {#approve} approves one, and only that sibling runs again: +to+ must name it.
    #
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @param extra_seconds [Integer, nil] added to the run's timeout (see {#resume})
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`, `attempts_spent`, `budget_spent`, `run_timed_out`, and what +guard+ raises
    # @raise [Workspace::UsageError] when +to+ is not the gated step or one before it
    def reject(run_id, actor:, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil)
      @change.call(run_id, actor: actor, cause: "reject") do |read, ctx|
        stored = WorkflowTransitions.at_step(read.thawed, step)
        gate = waiting_gate(stored, step: step, attempt: attempt)
        guard&.call(stored)
        target = to || stored["current"]
        ids = step_ids(stored)
        # A fan_out sibling runs beside its fellows, so a step before it may be one still at work: only it runs again.
        if WorkflowRun.step_scoped?(stored, stored["current"])
          unless target == stored["current"]
            raise UsageError, "--to must be #{stored["current"]}: a fan_out sibling's gate sends back only that sibling, got #{target.to_s[0, 60].inspect}."
          end
        elsif !ids.first(ids.index(stored["current"]) + 1).include?(target)
          raise UsageError, "--to must be #{stored["current"]} or a step before it (#{ids.first(ids.index(stored["current"]) + 1).join(", ")}), got #{target.to_s[0, 60].inspect}."
        end
        # The step runs again, which is a new attempt.
        spend_attempts(stored, extra_attempts, target: target)
        spend_limits(stored, extra_tokens, extra_seconds)
        gate.merge!("state" => "rejected", "at" => now_iso, "note" => note, "attempt" => step_state(stored)["attempts"].last&.fetch("n", nil))
        event(stored, "gate_rejected", with_note({"step" => stored["current"], "to" => target}, note))
        WorkflowRun.add_context(stored, target, "The #{stored["current"]} step was rejected at its gate: #{note}")
        stored["current"] = target
        @dispatch.dispatch(stored, ctx: ctx, cause: "gate_rejected")
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
    # @param extra_rounds [Integer, nil] raises the allowance of review rounds of the step the resume goes to (the
    #   current one, or +from+) by this much, kept in the step (`extra_rounds`) and recorded as `review_rounds_extended`;
    #   applied when the resume acts, and needed when the step has spent its `max_rounds` (see {#refuse_rounds_spent})
    # @param accept_guard [Boolean] take a guard stop ({WorkflowTransitions.acceptable_guard}) as a person's decision:
    #   the checkout as it is now becomes the run's base (`base_sha`, `base_guard`), a `guard_overridden` event records
    #   +note+ (required), and the rest of the step's evaluation runs with the guard left out
    #   ({WorkflowEvaluation#evaluate_accepted}): the attempt reads `overridden` and the step passes only when its
    #   `produces`, `require:` and `status:` pass too
    # @param guard_retry [Boolean] with +accept_guard+: run the stopped step again instead, a new attempt held to the allowance and budget
    # @param caller_pane [String, nil] the pane the person ran the command in, recorded on `guard_overridden`
    # @param restart_step [Boolean] start the current step again as a new attempt (see {#restart_in}): its open attempt is
    #   closed as `interrupted` (`step_interrupted`: `step`, `attempt`, `pane`, `usage_counted`), and the new one, `retry_of`
    #   it, starts in a fresh conversation with a brief of HEAD and the plan's tasks; +pane+ is the pane to start it in
    #   (nil: the bound one). Not with +from+, +accept_guard+, +guard_retry+, +turn_over+ or +extra_rounds+
    # @param bound [String, nil] with +restart_step+, what the caller saw of the bound pane: `gone`, `shell`, `failed`,
    #   `idle`, `busy` or `unknown` (nil reads `unknown`), seen before the run lock is taken, so a turn that starts in
    #   between is not caught; see {WorkflowTransitions.restart_refusal}
    # @param reboot_recovery [Hash, nil] with +restart_step+ (UsageError without), `{"workspace" => name, "attempt" => n}` of a
    #   reboot recovery: under the run's lock it is refused `no_open_attempt` when the open attempt is no longer `n` (nil
    #   checks none), and `infra_retry_not_claimed` while the step's infra retry is claimed (a live claim: the claimant
    #   restarts it); once every refusal has passed, the run's `reboot_recoveries` rises by one and `reboot_recovered`
    #   (`workspace`, `outcome` `restarted`, `count`) is queued in the same change
    # @param infra_retry [Hash, nil] with +restart_step+, the claimant ("pid", "started") of the step's infra retry
    #   ({WorkflowRecovery#claim_infra_retry}): the restart is that retry, refused with `infra_retry_not_claimed` unless the
    #   current attempt's retry is claimed (or its claim stale) by this claimant, and its `run_resumed` carries `infra_retry` (the
    #   retry's `n`); a claimant without both "pid" and "started" raises ArgumentError
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}; any actor but `daemon` also clears the
    #   step's `infra_retries` count, so a person's resume gives the run a fresh set of automatic retries
    # @param step [String, nil] with +restart_step+, a fan_out sibling under way to restart instead of the cursor's step
    #   (its own pane and slots; the other siblings are left as they are); nil, or a step in no group, is the cursor's
    # @return [Resumed] the run afterwards, and why nothing was done when it did nothing
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` or `budget_spent` when the resume would
    #   start an attempt the run has no allowance left for; `budget_spent` or `run_timed_out` when it would start a
    #   review round (one a hold kept back, or a fresh one after a stopped round) past the budget or the timeout;
    #   with +accept_guard+, `guard_base_unreadable` (retryable, nothing changed) when the checkout can't be read as a
    #   new base, and with +guard_retry+ `guard_cannot_pass` when the retry would stop on `no_commit` or
    #   `operation_in_progress` again; `review_rounds_spent` when it would start a review round past the step's
    #   `max_rounds`, or start again a step a review rejected with every round spent; with +restart_step+, also
    #   `no_open_attempt`, `step_still_working`, `pane_has_run` and `restart_not_closed`; with +infra_retry+, `infra_retry_not_claimed`
    def resume(run_id, actor:, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil,
      extra_rounds: nil, accept_guard: false, guard_retry: false, caller_pane: nil, restart_step: false, bound: nil, infra_retry: nil, reboot_recovery: nil, step: nil)
      refuse_guard_flags(from: from, note: note, accept_guard: accept_guard, guard_retry: guard_retry, extra_rounds: extra_rounds, restart_step: restart_step, turn_over: turn_over)
      raise UsageError, "step names the fan_out sibling a restart starts again; it needs restart_step." if step && !restart_step
      raise UsageError, "infra_retry is the claimant of an automatic restart; it needs restart_step." if infra_retry && !restart_step
      raise UsageError, "reboot_recovery is the workspace of a recovery restart; it needs restart_step." if reboot_recovery && !restart_step
      infra_retry &&= WorkflowRecovery.infra_retry_claimant(infra_retry)
      follow = nil
      unchanged = nil
      run = @change.call(run_id, actor: actor, cause: "resume") do |read, ctx|
        follow = ctx
        read = WorkflowRun.from_h(named_step(read.thawed, step)) if step
        step = read.current
        changed = if restart_step
          restart_in(read, ctx, note: note, pane: pane, bound: bound, infra_retry: infra_retry, reboot_recovery: reboot_recovery,
            extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds)
        elsif accept_guard
          accept_guard_stop(read, ctx, note: note, pane: pane, guard_retry: guard_retry, caller_pane: caller_pane,
            extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds)
        else
          resumed = apply_resume(read, ctx: ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, extra_rounds: extra_rounds)
          unchanged = resumed.unchanged
          resumed.run
        end
        (actor == "daemon" || unchanged) ? changed : fresh_infra_retries(changed, step)
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
    # @param extra_rounds [Integer, nil] see {#resume}; applied when the park is released
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Resumed] the run afterwards, and why nothing was stored when nothing was
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent`, `budget_spent` or `review_rounds_spent` as {#resume}; `step_reviewing` for a step being reviewed (a park
    #   would hold back the review pane's turn end, which decides the round)
    def park(run_id, actor:, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil)
      unchanged = nil
      run = @change.call(run_id, actor: actor, cause: "park") do |read|
        stored = read.thawed
        refuse_resume(stored, from: from)
        refuse_reviewing_park(stored, from)
        refuse_rounds_spent(stored, from, extra_rounds)
        if WorkflowTransitions.parked(stored, @clock.call) == :waiting
          unchanged = "a resume is already parked for pane #{park_target(stored)}"
          next
        end
        unchanged = from ? nil : left_alone(stored, step_state(stored), pane, turn_over)
        next if unchanged
        check_pane(pane, run_id) if pane && @panes.run_on(pane) != run_id
        refuse_budget(stored, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, from: from) if WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
        drop_park(stored, "expired")
        store_park(stored, {"from" => from, "note" => note, "pane" => pane, "turn_over" => turn_over}.merge(extra_attempts ? {"extra_attempts" => extra_attempts} : {}).merge(extra_tokens ? {"extra_tokens" => extra_tokens} : {}).merge(extra_seconds ? {"extra_seconds" => extra_seconds} : {}).merge(extra_rounds ? {"extra_rounds" => extra_rounds} : {}),
          expires_at: (@clock.call + PARK_SECONDS).utc.iso8601)
        WorkflowRun.from_h(stored)
      end
      Resumed.new(run: run, unchanged: unchanged)
    end

    # Carries out a parked resume, in one change with taking it off the run. A park typed again after a busy pane
    # (`retries` above 0) is not held to the allowance and budget a second time: its attempt was counted then. A
    # release that changed something clears the step's `infra_retries` count, as a person's {#resume} does.
    #
    # @param id [String] the park's id; any other changes nothing
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Resumed] the run afterwards, and why the resume did nothing (its note kept for the next attempt), or nil
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id, actor:)
      follow = nil
      unchanged = nil
      run = @change.call(run_id, actor: actor, cause: "release_park") do |read, ctx|
        parked = read.parked
        next unless parked && parked["id"] == id
        refuse_unrecoverable_guard(read.to_h)
        stored = read.thawed
        stored.delete("parked")
        resumed = apply_resume(stored, ctx: ctx, from: parked["from"], note: parked["note"], pane: parked["pane"], turn_over: parked["turn_over"],
          extra_attempts: parked["extra_attempts"], extra_tokens: parked["extra_tokens"], extra_seconds: parked["extra_seconds"], extra_rounds: parked["extra_rounds"], budget: parked["retries"].to_i.zero?)
        stored = resumed.run.thawed
        unchanged = resumed.unchanged
        follow = ctx
        WorkflowRun.add_context(stored, stored["current"], WorkflowRun.resume_note(parked["note"])) if unchanged && parked["note"]
        event(stored, "resume_parked_ended", {"step" => stored["current"], "how" => unchanged ? "unchanged" : "released"}
          .merge(unchanged ? {"detail" => unchanged} : {}))
        if ctx.delivery
          step_state(stored)["attempts"].last["after_park"] = {"expires_at" => parked["expires_at"], "pane" => ctx.delivery["pane"], "retries" => parked["retries"]}
        end
        # The park is a person's resume, so its release starts the step's infra retries again as {#resume} does.
        unchanged ? WorkflowRun.from_h(stored) : fresh_infra_retries(WorkflowRun.from_h(stored), read.current)
      end
      Resumed.new(run: @evaluation.finish_follow_ups(run_id, follow, run), unchanged: unchanged)
    end

    # Ends a park that can't be released; the run waits for a person. The step and what it holds stay (a `running`
    # step keeps its attempt for a later resume); a lock the run queued for is given up. A run at a gate keeps its
    # gate reason, so approve and reject stay open; the failure is in the `resume_parked_ended` event.
    #
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`, with +message+
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @param gone [Boolean] whether the pane is confirmed gone; by default whether +code+ is one of {WorkflowDispatch::PANE_GONE_CODES}
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:, actor:, gone: WorkflowDispatch::PANE_GONE_CODES.include?(code))
      @change.call(run_id, actor: actor, cause: "park_failed") do |read|
        stored = read.thawed
        next unless stored.dig("parked", "id") == id
        if step_state(stored).dig("gate", "state") == "waiting"
          drop_park(stored, "failed", "error" => code, "message" => message)
          next WorkflowRun.from_h(stored)
        end
        target = park_target(stored)
        case slot_dig(stored, "reason", "code")
        when "waiting_lock" then @dispatch.release(stored)
        when "failed_check" then WorkflowRun.add_context(stored, stored["current"], last_failure(stored), first: true)
        end
        drop_park(stored, "failed")
        stored["state"] = "waiting"
        slots(stored)["reason"] = {"code" => gone ? "pane_gone" : "waiting_you", "since" => now_iso,
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
    # @raise [Workspace::Error] code `run_paused` for a paused run (unpause it first)
    def refuse_resume(run, from: nil, note: nil, accept_guard: false, guard_retry: false)
      refuse_guard_flags(from: from, note: note, accept_guard: accept_guard, guard_retry: guard_retry)
      run = WorkflowRun.from_h(run).to_h
      refuse_paused(run)
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

    # Why a restart of the run's current step would be refused, checked without changing anything, as {#resume} with
    # +restart_step+ checks it before it closes the attempt: the run's own refusals ({#refuse_resume}), the restart rule
    # with the bound pane unknown ({WorkflowTransitions.restart_refusal}: an open attempt whose line is not being typed,
    # with a `pane_gone` or `agent_gone` stall open), then the attempt allowance, budget and timeout ({#refuse_budget},
    # with no extras). For an infra retry's claim ({WorkflowRecovery#claim_infra_retry}), so nothing is spawned for a
    # restart that would be refused.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run that has not finished
    # @param bound [String] what the caller knows of the bound pane, as {#resume}'s +bound+ (`workflow recover` asks
    #   with `gone`: the pane its restore brings back is judged later)
    # @return [Workspace::Error, nil] the refusal (e.g. code `run_paused`, `gate_waiting`, `no_open_attempt`,
    #   `step_still_working`, `attempts_spent`, `step_attempts_spent`, `budget_spent` or `run_timed_out`), or nil
    def restart_refusal(run, bound: "unknown")
      run = WorkflowRun.from_h(run).to_h
      refuse_resume(run)
      refusal = WorkflowTransitions.restart_refusal(run, step_state(run), @clock.call, bound)
      return refusal if refusal
      refuse_budget(run, extra_attempts: nil, extra_tokens: nil)
      nil
    rescue Workspace::Error => e
      e
    end

    # Ends a run: closes its open attempt, gives up its resources and frees its pane. A step being reviewed has no
    # open attempt; its round is ended instead ({WorkflowProgress#end_round}: its usage and the verdicts it read
    # recorded on the reviewed attempt), and its review window is closed once the lock is given up.
    #
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, actor:, cause: "cancel")
      follow = nil
      run = @change.call(run_id, actor: actor, cause: cause) do |read, ctx|
        follow = ctx
        read = @progress.end_round(read, how: "cancelled", ctx: ctx) if read.current_step&.state == "reviewing"
        ended = @progress.finish(@attempt_record.abandon(read), "cancelled", ctx: ctx).thawed
        ended["cancelled_by"] = cause
        event(ended, "run_cancelled", "cause" => cause)
        WorkflowRun.from_h(ended)
      end
      @evaluation.finish_follow_ups(run_id, follow, run)
    end

    # Ends every run of a workspace that was killed, so none goes on holding a lock for a checkout that is gone.
    # Never raises: a run whose file is malformed is reported, and the others are still ended.
    #
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and "failed", the ones that could not be
    def workspace_killed(workspace, actor:)
      result = {"cancelled" => [], "failed" => []}
      @store.going.select { |run| run.workspace == workspace }.each do |run|
        cancel(run.id, actor: actor, cause: "kill")
        result["cancelled"] << run.id
      rescue
        result["failed"] << run.id
      end
      result
    rescue
      result
    end

    # Pauses a run: from now on it starts nothing new (no attempt, retry, review round or typed line), each dispatch
    # held being kept as its `pause_hold` ({WorkflowDispatch#hold_paused}). What is under way goes on: a turn that
    # ends is decided, a round's verdicts are counted, a gate can be approved or rejected. The run's reason stays
    # under the pause, shown again once it ends. A parked resume is dropped (`how: "paused"`). A pending continue
    # line (`continue_pending`, left by an earlier unpause) is kept for the next unpause.
    #
    # With +interrupt+, the agent's interrupt keys ({AgentProvider#interrupt_keys}) are pressed once, with the run's
    # lock given up, but only into the run's own bound pane while its attempt is open and `running` and the daemon
    # shows the pane `working`. Only then is `paused.interrupt` written ("pane", "pid" (the pane's process),
    # "kind", "step", "attempt"), which {#unpause} reads to type one continue line. A press that fails drops the mark
    # again. The attempt stays open and `running`: no attempt is added and no delivery is marked. While a fan_out group
    # is under way every sibling at work is pressed in its own pane, the cursor's first: the first press's mark is
    # `paused.interrupt` as above and each other one is in `paused.interrupts`.
    #
    # @param text [String, nil] why, kept with the pause and on `run_paused`
    # @param interrupt [Boolean] also stop the agent's turn
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Paused] the run afterwards and whether the keys were pressed
    # @raise [Workspace::Error] code `already_paused`, `unknown_run` or `run_not_active`
    def pause(run_id, actor:, text: nil, interrupt: false)
      press = nil
      presses = []
      run = @change.call(run_id, actor: actor, cause: "pause") do |read|
        refuse_already_paused(read.to_h)
        stored = read.thawed
        drop_park(stored, "paused")
        adopt(stored, WorkflowRun.from_h(stored).with_paused(since: now_iso, by: actor, text: text))
        presses = interrupt ? interrupt_targets(stored) : []
        press = presses.first
        stored["paused"]["interrupt"] = press.except("keys") if press
        stored["paused"]["interrupts"] = presses.drop(1).map { |each| each.except("keys") } if presses.size > 1
        event(stored, "run_paused", with_text({"step" => stored["current"]}, text).merge(press ? {"interrupt" => true} : {}))
        WorkflowRun.from_h(stored)
      end
      return Paused.new(run: run, interrupted: false) unless press
      failures = presses.map { |each| press_keys(run, each) }
      return Paused.new(run: run, interrupted: true) if failures.none?
      presses.zip(failures).each { |each, failure| run = interrupt_failed(run_id, each, failure, actor) if failure }
      Paused.new(run: run, interrupted: failures.any?(&:nil?), warning: failures.compact.first)
    end

    # Ends a pause and does what it held, never through {#resume} (which would start nothing without a pane, or a
    # new attempt with one). In this order, the first that applies:
    #
    # 1. a held attempt or review round (`pause_hold` kind `attempt` or `round`) is started as it would have been,
    #    spending what it would have spent;
    # 2. a held line (kind `delivery`) is typed for the same attempt, which adds no attempt;
    # 3. with nothing held and the step's attempt open and `running`: a bound pane that is gone makes the run wait
    #    on `pane_gone`;
    # 4. a turn `pause --interrupt` stopped (`paused.interrupt`, or a `continue_pending` an earlier unpause left,
    #    naming this step, attempt and pane, and the pane's process still the one marked) gets one continue line
    #    ({WorkflowTransitions::CONTINUE_LINE}) once its pane is proven idle ({WorkflowPanes#main_turn_over?} for
    #    Claude Code, {WorkflowPanes#idle?} for another agent), typed with the lock given up
    #    ({WorkflowDispatch#type_continue}); a pane not yet proven idle (an Escape sends no Stop) has the mark moved to
    #    `continue_pending` and the tick types the line ({WorkflowRecovery#tick}). A process that is not the one
    #    marked (the pane was replaced) drops the mark and the next branch applies;
    # 5. a pane whose turn is proven over has the step decided now, as a resume with a turn's end does;
    # 6. an agent still working is left alone, and so is anything else (a gate, a round under way, a retry's
    #    backoff, a lost check): the reason the pause hid shows again and the next tick acts on it.
    #
    # `run_unpaused` names which (`action`: `dispatch`, `round`, `rerun`, `deliver`, `pane_gone`, `continue`,
    # `continue_pending`, `evaluate`, `none`).
    #
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Unpaused] the run afterwards, the branch taken, the kind of dispatch held and the continue line's outcome
    # @raise [Workspace::Error] code `not_paused`, `unknown_run` or `run_not_active`; what a held attempt's start raises
    def unpause(run_id, actor:)
      follow = nil
      action = nil
      held = nil
      mark = nil
      run = @change.call(run_id, actor: actor, cause: "unpause") do |read, ctx|
        follow = ctx
        refuse_not_paused(read.to_h)
        marks = [read.to_h.dig("paused", "interrupt"), *Array(read.to_h.dig("paused", "interrupts"))].grep(Hash)
        siblings = WorkflowTransitions.under_way_siblings(read.to_h) - [read.current]
        mark = marks.find { |each| each["step"] == read.current } || (marks.first if siblings.empty?) || read.continue_pending_for(read.current)
        stored = read.drop_paused.thawed
        slots(stored).delete("continue_pending")
        hold = slots(stored).delete("pause_hold")
        held = hold.is_a?(Hash) ? hold["kind"] : nil
        action = unpause_action(stored, hold.is_a?(Hash) ? hold : nil, mark).to_s
        event(stored, "run_unpaused", {"step" => stored["current"], "action" => action, "held" => held}.compact)
        apply_unpause(stored, ctx, action.to_sym, hold, mark)
        unpause_siblings(stored, ctx, siblings, marks)
        WorkflowRun.from_h(stored)
      end
      continued, warning = continue_after_unpause(run, action, mark, actor)
      Unpaused.new(run: @evaluation.finish_follow_ups(run_id, follow, run), action: action, held: held, continued: continued, warning: warning)
    end

    private

    # The rest of {#unpause} while a fan_out group is under way: each other sibling still under way, read on its own
    # step, takes the branch that applies to it. What it held starts, or its held line is typed, as for the cursor's
    # step; a sibling `pause --interrupt` stopped (its mark in `paused.interrupts`, or its own `continue_pending`)
    # gets its continue line through its own `continue_pending`, which the tick types once its pane proves idle. The
    # cursor goes back to the step it was on unless a sibling's change moved the run past the group.
    def unpause_siblings(stored, ctx, siblings, marks)
      cursor = stored["current"]
      siblings.each do |id|
        break if WorkflowRunStore::TERMINAL_STATES.include?(stored["state"]) || !WorkflowRun.step_scoped?(stored, stored["current"])
        next unless WorkflowTransitions.under_way?(stored, id)
        stored["current"] = id
        pending = slots(stored).delete("continue_pending")
        hold = slots(stored).delete("pause_hold")
        mark = marks.find { |each| each["step"] == id } || pending
        action = unpause_action(stored, hold.is_a?(Hash) ? hold : nil, mark)
        if %i[continue continue_pending].include?(action)
          slots(stored)["continue_pending"] = mark.merge("since" => mark["since"] || now_iso)
        else
          apply_unpause(stored, ctx, action, hold, mark)
        end
      end
      stored["current"] = cursor if WorkflowRun.step_scoped?(stored, stored["current"])
    end

    # +run+ read on the fan_out sibling +step+ names ({WorkflowTransitions.at_step}); the cursor's own step reads as it is.
    # A step that is neither (unknown, in no group, or with no state yet) is refused rather than taken for the cursor's.
    def named_step(run, step)
      view = WorkflowTransitions.at_step(run, step)
      return view unless view.equal?(run) && step != run["current"]
      raise UsageError, "Step #{step.to_s[0, 60].inspect} of run #{run["id"]} is not a fan_out sibling under way, so it can't be restarted on its own; " \
        "the run's step is #{run["current"]}."
    end

    # Where `pause --interrupt` presses: {#interrupt_target} of the cursor's step, then of each other fan_out sibling under way.
    def interrupt_targets(run) = WorkflowTransitions.step_views(run).filter_map { |view| interrupt_target(view) }

    def refuse_already_paused(run)
      paused = run["paused"]
      return unless paused
      raise Workspace::Error.new("Run #{run["id"]} is already paused (since #{paused["since"]}, by #{paused["by"]}). Run `workspace workflow unpause #{run["id"]}` to let it go on.",
        code: "already_paused", details: {"run_id" => run["id"], "step" => run["current"], "since" => paused["since"], "by" => paused["by"]})
    end

    def refuse_not_paused(run)
      return if run["paused"]
      raise Workspace::Error.new("Run #{run["id"]} is not paused, so there is nothing to unpause.",
        code: "not_paused", details: {"run_id" => run["id"], "step" => run["current"], "state" => run["state"]})
    end

    # A resume or park of a paused run would start what the pause holds back.
    def refuse_paused(run)
      paused = run["paused"]
      return unless paused
      raise Workspace::Error.new("Run #{run["id"]} is paused (since #{paused["since"]}, by #{paused["by"]}), so it can't be resumed. Run `workspace workflow unpause #{run["id"]}` first.",
        code: "run_paused", details: {"run_id" => run["id"], "step" => run["current"], "since" => paused["since"], "by" => paused["by"]})
    end

    # Which branch of {#unpause} applies to the run as it stands, its pause taken off; +hold+ is its `pause_hold`.
    # A hold the run has moved past (its step or attempt no longer the one held) is dropped and the later branches apply.
    def unpause_action(run, hold, mark)
      case hold&.fetch("kind", nil)
      when "attempt" then return :dispatch
      when "round" then return held_round_action(run, hold) || open_attempt_action(run, mark)
      when "delivery" then return held_delivery_matches?(run, hold) ? :deliver : open_attempt_action(run, mark)
      end
      open_attempt_action(run, mark)
    end

    # A held round start (`held: "paused"`, or a `no_change` round the pause held) or a held rerun
    # (`held: "paused_rerun"`) of the round the hold names, on the step still being reviewed.
    def held_round_action(run, hold)
      state = step_state(run)
      round = state["review"]
      return nil unless state["state"] == "reviewing" && round.is_a?(Hash) && round["round"] == hold["review_round"]
      if hold["cause"] == "rerun"
        (round["held"] == WorkflowRoundRerun::PAUSED_RERUN) ? :rerun : nil
      else
        (round["held"] == "paused") ? :round : nil
      end
    end

    def held_delivery_matches?(run, hold)
      state = step_state(run)
      attempt = state["attempts"].last
      run["current"] == hold["step"] && state["state"] == "running" && attempt.is_a?(Hash) && attempt["n"] == hold["attempt"] &&
        attempt["ended_at"].nil? && hold["delivery"].is_a?(Hash)
    end

    # Branches 3 to 6 of {#unpause}: the step's attempt open and `running`, nothing held. A line still on its way
    # (another process typing it) is left alone.
    def open_attempt_action(run, mark)
      state = step_state(run)
      attempt = state["attempts"].last
      return :none unless state["state"] == "running" && attempt.is_a?(Hash) && attempt["ended_at"].nil?
      return :none if WorkflowTransitions.delivery(attempt, @clock.call) == :delivering
      pane = bound_pane(run)
      return :none unless pane
      return :pane_gone if @panes.pane_gone?(pane, workspace: run["workspace"])
      case continue_for(run, mark, pane)
      when :same then return continue_ready?(run["workspace"], pane, mark["kind"]) ? :continue : :continue_pending
      when :unread then return :continue_pending
      end
      return :evaluate if @panes.idle?(run["workspace"], pane)
      :none
    end

    # Whether the mark names this step's open attempt in the pane bound now, and that pane's process: `:same` (the
    # one marked), `:unread` (tmux named no pid, which proves nothing, so the mark is kept), or nil (no such mark,
    # or another process: the pane was replaced and the mark is dropped).
    def continue_for(run, mark, pane)
      return nil unless WorkflowTransitions.continue_mark?(run, mark) && mark["pane"] == pane && !mark["pid"].nil?
      pid = @panes.pane_pid(run["workspace"], pane)
      return :unread if pid.nil?
      (pid == mark["pid"]) ? :same : nil
    end

    # Whether the pane's agent is proven idle, so a continue line can go: an Escape sends Claude Code no Stop, which
    # {WorkflowPanes#main_turn_over?} allows for once the pane has been quiet a while; another agent goes by the daemon's state.
    def continue_ready?(workspace, pane, kind)
      (kind == "claude") ? @panes.main_turn_over?(workspace, pane) : @panes.idle?(workspace, pane)
    end

    # Where `pause --interrupt` presses: the run's own bound pane, its attempt open and `running` and the daemon
    # showing it `working`, with keys known for its agent and a process tmux can name. Nil presses nothing.
    def interrupt_target(run)
      state = step_state(run)
      attempt = state["attempts"].last
      return nil unless state["state"] == "running" && attempt.is_a?(Hash) && attempt["ended_at"].nil?
      pane = bound_pane_of(run)
      return nil unless pane && @panes.run_on(pane) == run["id"]
      row = @panes.pane_row(run["workspace"], pane)
      return nil unless row.is_a?(Hash) && row["state"] == "working"
      keys = AgentProvider.find(row["kind"].to_s)&.interrupt_keys.to_a
      pid = @panes.pane_pid(run["workspace"], pane)
      return nil if keys.empty? || pid.nil?
      {"pane" => pane, "pid" => pid, "kind" => row["kind"], "step" => run["current"], "attempt" => attempt["n"], "keys" => keys}
    end

    # nil once the keys are pressed; otherwise why they were not.
    def press_keys(run, press)
      @interrupter.call(run.workspace, press["pane"], press["keys"])
      nil
    rescue Workspace::Error => e
      e.message.lines.first.to_s.strip
    end

    # The press failed: the mark goes, so {#unpause} does not type a continue line into a turn nothing stopped.
    def interrupt_failed(run_id, press, failure, actor)
      @change.call(run_id, actor: actor, cause: "pause") do |read|
        stored = read.thawed
        stored["paused"].delete("interrupt") if stored["paused"].is_a?(Hash) && stored.dig("paused", "interrupt", "pid") == press["pid"]
        stored["paused"]["interrupts"].reject! { |each| each.is_a?(Hash) && each["pid"] == press["pid"] } if stored.dig("paused", "interrupts").is_a?(Array)
        event(stored, "pause_interrupt_failed", {"step" => press["step"], "attempt" => press["attempt"], "pane" => press["pane"], "message" => failure})
        WorkflowRun.from_h(stored)
      end
    rescue Workspace::Error => e
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # Types the continue line of branch 4 once the unpause's lock is given up: [continued, warning]. A line the pane
    # refused (or a pause that came first) is put back as `continue_pending` by {WorkflowDispatch#type_continue},
    # so it reads "pending", with the refusal as the warning; only a pane that is gone answers false.
    def continue_after_unpause(run, action, mark, actor)
      case action
      when "continue"
        kick = @dispatch.type_continue(run.id, mark.merge("since" => mark["since"] || now_iso), workspace: run.workspace, text: WorkflowTransitions.continue_line(run.to_h),
          actor: actor, cause: "unpause")
        return [true, nil] if kick[:ok]
        warning = "the continue line was not typed into pane #{mark["pane"]}: #{kick[:message] || kick[:code]}"
        [kick[:pending] ? "pending" : false, warning]
      when "continue_pending" then ["pending", nil]
      else [nil, nil]
      end
    end

    def apply_unpause(run, ctx, action, hold, mark)
      case action
      when :dispatch
        dispatch(run, ctx, hold["cause"] || "resume", context: hold["context"], budgeted: hold.fetch("budgeted", true), retry_of: held_retry_of(hold))
      when :round, :rerun
        run.replace(@progress.restart_review(run, ctx: ctx).thawed)
      when :deliver
        attempt = step_state(run)["attempts"].last
        attempt["delivery"] = "delivering"
        attempt["delivering_since"] = @clock.call.utc.iso8601(3)
        ctx.deliver(hold["delivery"])
      when :pane_gone
        pane = bound_pane(run)
        run["state"] = "waiting"
        slots(run)["reason"] = {"code" => "pane_gone", "since" => now_iso,
                         "details" => {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"],
                                       "error" => "pane_gone", "message" => "pane #{pane} is gone"}}
      when :continue_pending
        slots(run)["continue_pending"] = mark.merge("since" => mark["since"] || now_iso)
      when :evaluate
        slots(run)["reason"] = nil
        evaluate(run, ctx)
      end
    end

    # The `retry_of` a held attempt's start is given again, from what its hold kept ({WorkflowDispatch#dispatch}).
    def held_retry_of(hold)
      given = {"pane" => hold["pane"], "identity" => hold["identity"], "text" => hold["text"], "attempt" => hold["retry_of"]}.compact
      given.empty? ? nil : given
    end

    def adopt(run, changed) = run.replace(changed.thawed)

    # The flags of a guard acceptance that can't go together, refused before the run is read.
    def refuse_guard_flags(from:, note:, accept_guard:, guard_retry:, extra_rounds: nil, restart_step: false, turn_over: nil)
      if restart_step
        raise UsageError, "--restart-step starts the current step again; --from can't go with it." if from
        raise UsageError, "--restart-step starts the current step again; --accept-guard and --retry can't go with it." if accept_guard || guard_retry
        raise UsageError, "--restart-step starts a new attempt and no review round; --extra-rounds can't go with it." if extra_rounds
        raise UsageError, "--restart-step starts a new attempt; a turn's end (turn_over) can't go with it." if turn_over
      end
      raise UsageError, "--retry is for `workflow resume RUN --accept-guard --note WHY`." if guard_retry && !accept_guard
      return unless accept_guard
      raise UsageError, "--extra-rounds adds review rounds to a resume; --accept-guard starts none." if extra_rounds
      raise UsageError, "--accept-guard needs --note WHY: the reason is recorded and given to the next attempt." if note.to_s.strip.empty?
      raise UsageError, "--retry runs the stopped step again; --from can't go with it." if guard_retry && from
      raise UsageError, "--accept-guard judges the stopped step again without its guard, or runs it again with --retry; --from can't go with it." if from
    end

    def refuse_not_guard_stopped(run)
      return if WorkflowTransitions.guard_acceptable?(run)
      reason = slot(run, "reason").is_a?(Hash) ? slot(run, "reason") : {}
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
      WorkflowRun.add_context(stored, stored["current"], WorkflowTransitions.guard_accepted_line(guard, step, stored["base_sha"]))
      WorkflowRun.add_context(stored, stored["current"], WorkflowRun.resume_note(note))
      if guard_retry
        event(stored, "run_resumed", "from" => step, "accept_guard" => guard)
        dispatch(stored, ctx, "resume", budgeted: true)
      else
        event(stored, "run_resumed", "step" => step, "state" => "failed", "accept_guard" => guard)
        adopt(stored, @evaluation.evaluate_accepted(stored, ctx: ctx))
      end
      WorkflowRun.from_h(stored)
    end

    # The body of {#resume} with +restart_step+, inside the change. Every refusal comes first, so a refused restart
    # changes nothing: the run's own ({#refuse_resume}), the restart rule ({WorkflowTransitions.restart_refusal}),
    # another run's +pane+, then the attempt allowance, budget and timeout. The open attempt is then closed as
    # `interrupted` against the run as it is, so its usage is read from the old pane's session, before the run moves
    # to +pane+. Its stalls end (`restarted`), and the new attempt (`retry_of` the closed one) starts in a fresh
    # conversation with {WorkflowPrompt.interrupted_brief} first in its instructions, then the note.
    def restart_in(read, ctx, note:, pane:, bound:, extra_attempts:, extra_tokens:, extra_seconds:, infra_retry: nil, reboot_recovery: nil)
      stored = read.thawed
      retry_n = infra_retry && claimed_retry(stored, infra_retry)
      refuse_resume(stored)
      state = step_state(stored)
      refusal = WorkflowTransitions.restart_refusal(stored, state, @clock.call, bound || "unknown")
      raise refusal if refusal
      step = stored["current"]
      n = state["attempts"].last["n"]
      refuse_reboot_recovery(stored, n, reboot_recovery) if reboot_recovery && !infra_retry
      old_pane = bound_pane(stored)
      moving = pane && pane != old_pane
      check_other_pane(pane, stored["id"]) if moving
      refuse_budget(stored, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds)
      spend_attempts(stored, extra_attempts, target: step)
      spend_limits(stored, extra_tokens, extra_seconds)
      # Against the run as it is, before any rebind: the usage is read from the old pane's session.
      adopt(stored, @attempt_record.abandon(stored, outcome: "interrupted"))
      closed = step_state(stored)["attempts"].last
      # `abandon` never raises: an attempt it could not close is still open here.
      unless closed["n"] == n && closed["ended_at"]
        raise Workspace::Error.new("Attempt #{n} of step #{step} of run #{stored["id"]} could not be closed, so the step was not restarted. Run the command again. Nothing was changed.",
          code: "restart_not_closed", details: {"run_id" => stored["id"], "step" => step, "attempt" => n})
      end
      event(stored, "step_interrupted", "step" => step, "attempt" => n, "pane" => old_pane, "usage_counted" => !closed["usage"].nil?)
      @recovery&.close_stalls(stored, action: "restarted")
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if moving
      drop_park(stored, "taken_over")
      WorkflowRun.add_context(stored, stored["current"], interrupted_brief(stored, closed), first: true)
      WorkflowRun.add_context(stored, stored["current"], WorkflowRun.resume_note(note)) if note
      count_reboot_recovery(stored, reboot_recovery) if reboot_recovery
      event(stored, "run_resumed", {"step" => step, "state" => "running", "restart_step" => true}.merge(retry_n ? {"infra_retry" => retry_n} : {}))
      dispatch(stored, ctx, "resume", context: "fresh", budgeted: true, retry_of: {"attempt" => n})
      WorkflowRun.from_h(stored)
    end

    # A reboot recovery restarts only the attempt it saw, and never one whose infra retry another process has claimed.
    def refuse_reboot_recovery(stored, n, reboot_recovery)
      ids = {"run_id" => stored["id"], "step" => stored["current"]}
      expected = reboot_recovery["attempt"]
      if expected && expected != n
        raise Workspace::Error.new("Step #{stored["current"]} of run #{stored["id"]} is on attempt #{n} now, not attempt #{expected}, so it was not restarted. Nothing was changed.",
          code: "no_open_attempt", details: ids.merge("state" => step_state(stored)["state"], "attempt" => n, "expected" => expected))
      end
      info = WorkflowTransitions.infra_retry(stored, @clock.call)
      return unless info && info[:state] == :claimed
      raise Workspace::Error.new("Step #{stored["current"]} of run #{stored["id"]} has its infra retry claimed by another process, which restarts it, so it was not restarted. Nothing was changed.",
        code: "infra_retry_not_claimed", details: ids.merge("pid" => info[:claimed_by]&.dig("pid")))
    end

    # Raises the run's `reboot_recoveries` by one and queues `reboot_recovered` with the new count, once the restart is certain.
    def count_reboot_recovery(stored, reboot_recovery)
      stored["reboot_recoveries"] = stored["reboot_recoveries"].to_i + 1
      event(stored, "reboot_recovered", "workspace" => reboot_recovery["workspace"], "outcome" => "restarted", "count" => stored["reboot_recoveries"])
    end

    # The `n` of the current attempt's infra retry when +claimant+ holds its claim ({WorkflowTransitions.infra_retry}
    # reads `:claimed` or `:stale_claim`); refuses `infra_retry_not_claimed` otherwise, also for a retry whose stall ended.
    def claimed_retry(run, claimant)
      info = WorkflowTransitions.infra_retry(run, @clock.call)
      return info[:n] if info && %i[claimed stale_claim].include?(info[:state]) && info[:claimed_by] == claimant
      raise Workspace::Error.new("Step #{run["current"]} of run #{run["id"]} has no infra retry claimed by process #{claimant["pid"]}, so it was not restarted. Nothing was changed.",
        code: "infra_retry_not_claimed", details: {"run_id" => run["id"], "step" => run["current"], "pid" => claimant["pid"]})
    end

    # A person's resume starts the step's automatic infra retries again; the run's `max_attempts` and budget still cap them.
    def fresh_infra_retries(run, step)
      return run unless run.to_h["infra_retries"].is_a?(Hash) && run.to_h["infra_retries"].key?(step)
      stored = run.thawed
      stored["infra_retries"].delete(step)
      WorkflowRun.from_h(stored)
    end

    # The brief a restarted attempt starts from: HEAD as the closed attempt left it, HEAD at its start, and the tasks of
    # the workspace's plan (none when it has no notes directory or no plan file).
    def interrupted_brief(run, closed)
      dir = @gate_note.notes_dir_of(run["workspace"])
      plan = dir && PlanFile.read(File.join(dir, PlanFile::FILE_NAME))
      WorkflowPrompt.interrupted_brief(head: closed.dig("head", "after"), head_before: closed.dig("head", "before"), tasks: plan&.tasks)
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

    # A resume that would start a review round past the step's `max_rounds` (a stopped or held round of the step being
    # reviewed), or start again a step whose last round rejected it with every round spent, is refused before anything
    # changes: its next review could not start. +extra_rounds+ at least {WorkflowTransitions.review_extra_rounds_needed}
    # lets it through ({#spend_rounds} adds them). `--from` is not refused for want of it, but a +extra_rounds+ that falls
    # short of what a spent target step needs is. +extra_rounds+ for a step with no `review:` is a usage error.
    def refuse_rounds_spent(run, from, extra_rounds = nil)
      target = from || run["current"]
      if extra_rounds && WorkflowTransitions.review_rounds_allowance(run, target).nil?
        raise UsageError, "--extra-rounds adds review rounds, and step #{target} of run #{run["id"]} has no review: to extend."
      end
      return unless rounds_short?(run, from)
      needed = WorkflowTransitions.review_extra_rounds_needed(run, target)
      return if extra_rounds && extra_rounds >= needed
      return if from && extra_rounds.nil?
      rounds = run.dig("steps", target, "review_rounds").to_i
      allowed = WorkflowTransitions.review_rounds_allowance(run, target)
      raise Workspace::Error.new("Step #{target} of run #{run["id"]} has spent its review rounds (#{rounds} of #{allowed} max_rounds), so no further round can start. " \
        "Pass --extra-rounds #{needed} to go on, or `workflow resume #{run["id"]} --from STEP` (the review of #{target} stops again (review_rounds_spent) once its author attempt passes), or `workflow cancel #{run["id"]}`.",
        code: "review_rounds_spent", details: {"run_id" => run["id"], "step" => target, "rounds" => rounds, "max_rounds" => allowed, "needed" => needed})
    end

    # Whether the resume goes to a step with no round left: without +from+ when a plain resume is refused for it, with
    # +from+ when the step it names has spent its rounds.
    def rounds_short?(run, from)
      from ? WorkflowTransitions.review_rounds_spent?(run, from) : WorkflowTransitions.rounds_refuse_resume?(run)
    end

    # Adds +extra+ to the review round allowance of the step the resume goes to and records it, only when that step
    # has spent its rounds ({#refuse_rounds_spent} has said whether +extra+ is enough); otherwise the flag is ignored,
    # as `--extra-attempts` is for a resume that starts no attempt.
    def spend_rounds(run, extra, from)
      return unless extra && rounds_short?(run, from)
      target = from || run["current"]
      state = run["steps"].fetch(target)
      state["extra_rounds"] = state["extra_rounds"].to_i + extra
      event(run, "review_rounds_extended", "step" => target, "extra" => extra, "extra_rounds" => state["extra_rounds"],
        "max_rounds" => WorkflowTransitions.review_rounds_allowance(run, target))
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
    # @param extra_rounds [Integer, nil] see {#resume}
    # @param budget [Boolean] false for a parked resume typed again after a busy pane: its attempt was counted then,
    #   so the allowance and budget are not asked again
    # @return [Resumed] the run afterwards, and why nothing was done, or nil
    # @raise [Workspace::Error] as {#resume}
    def apply_resume(run, ctx:, from:, note:, pane:, turn_over:, extra_attempts: nil, extra_tokens: nil, extra_seconds: nil, extra_rounds: nil, budget: true)
      work = WorkflowRun.from_h(run).thawed
      unchanged = resume_in(work, ctx, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens, extra_seconds: extra_seconds, extra_rounds: extra_rounds, budget: budget)
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

    def resume_in(stored, ctx, from:, note:, pane:, turn_over:, extra_attempts:, extra_tokens:, extra_seconds:, extra_rounds:, budget:)
      refuse_resume(stored, from: from)
      state = step_state(stored)
      # Decided before anything is changed: a resume that does nothing moves no pane and keeps no note.
      unchanged = (from || hold_of(stored)) ? nil : left_alone(stored, state, pane, turn_over)
      return unchanged if unchanged
      # A wait whose pane would not take the retry is held before anything is written: no rebind, note, event or reset.
      held = held_by_pane(stored, pane, from)
      return held if held
      refuse_rounds_spent(stored, from, extra_rounds)
      # A pane another run has is refused first, so a refusal after this point logs nothing.
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      # Only a resume that starts an attempt is held to the budget (not a parked one typed again after a
      # busy pane: its attempt was counted then); decided before anything is written.
      starting = budget && WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
      # A review round is not an attempt, so it asks no attempt allowance; it is held to the budget and the timeout.
      round = budget && WorkflowTransitions.starts_round?(stored, from: from)
      spend_attempts(stored, extra_attempts, needed: starting, target: WorkflowTransitions.target_step(stored, from: from))
      spend_limits(stored, extra_tokens, extra_seconds, needed: starting || round)
      spend_rounds(stored, extra_rounds, from)
      # A resume that keeps the attempt ends its stalls, so its clocks run again; a new attempt's start ends them anyway.
      @recovery&.close_stalls(stored, action: "resumed") unless WorkflowTransitions.starts_attempt?(stored, from: from, pane: pane)
      # A person's resume starts the sweep's retry count again, also for a retry waiting on a lock.
      stored["steps"].each_value { |each| each.delete("redelivery_pending") }
      rebind(stored, pane) if pane
      drop_park(stored, "taken_over")
      # Dropping a park replaces the run's nested Hashes.
      state = step_state(stored)
      WorkflowRun.add_context(stored, stored["current"], WorkflowRun.resume_note(note)) if note
      held = slots(stored).delete("budget_hold")
      time_held = slots(stored).delete("timeout_hold")
      held ||= time_held
      drop_retry_text(stored, held) if held && from
      if held&.key?("review_round") && !from
        # The held round starts now, never the author: the release goes through the round's one start.
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released", "review_round" => held["review_round"])
        slots(stored)["reason"] = nil
        stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
        return nil
      end
      if held && !from
        event(stored, "run_resumed", "step" => stored["current"], "budget" => "released")
        slots(stored)["reason"] = nil
        dispatch(stored, ctx, "resume", context: held["context"], budgeted: budget, retry_of: held.key?("retry_of") ? held.slice("text").merge("attempt" => held["retry_of"]) : nil)
        return nil
      end
      # A resume skips the wait of a retry; `--from` goes elsewhere and drops it.
      waiting_retry = slots(stored).delete("backoff")
      # A stored wait that names no step to go back to is dropped; the failed step is resumed as it stands.
      waiting_retry = nil unless waiting_retry.is_a?(Hash) && waiting_retry["to"].is_a?(String)
      if waiting_retry && !from
        event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"], "backoff" => "skipped")
        adopt(stored, @progress.start_retry(stored, waiting_retry, ctx: ctx, cause: "resume", proven: !pane.nil?, budgeted: budget))
        return held_retry_sentence(stored)
      end
      # The retry a rejection stopped by a limit kept: started by a plain resume, dropped by `--from`.
      again = slots(stored).delete("review_retry")
      if from
        # So is a review retry that waited for a lock, with the text it put in the pending context.
        waited = slots(stored).delete("retry_of_pending")
        drop_retry_text(stored, waited) if waited.is_a?(Hash)
        # The round under way ends first, its window closed, so no reviewer goes on judging work the run left; so
        # does the window a rejected round kept, when the run goes to another step.
        kept = state["review_window"].is_a?(Hash) && from != stored["current"]
        stored.replace(@progress.end_round(stored, how: "from", ctx: ctx).thawed) if state["state"] == "reviewing" || kept
        event(stored, "run_resumed", "from" => from)
        stored["current"] = from
        dispatch(stored, ctx, "resume", budgeted: budget)
        return nil
      end
      event(stored, "run_resumed", "step" => stored["current"], "state" => state["state"])
      WorkflowRun.add_context(stored, stored["current"], last_failure(stored), first: true) if state["state"] == "failed" && slot_dig(stored, "reason", "code") == "failed_check"
      case state["state"]
      when "running"
        if pane
          dispatch(stored, ctx, "resume", budgeted: budget)
        else
          slots(stored)["reason"] = nil
          evaluate(stored, ctx)
        end
      when "checking" then evaluate(stored, ctx)
      # A round is not an attempt: a resume never starts the author again on a step being reviewed, only its round.
      when "reviewing" then stored.replace(@progress.restart_review(stored, ctx: ctx).thawed)
      when "passed" then adopt(stored, @progress.advance(stored, ctx: ctx))
      else
        # A step a review rejected starts the retry the rejection kept: its verdicts and write-ups, `retry_of` it.
        if again.is_a?(Hash) && again["step"] == stored["current"] && again["text"].is_a?(String)
          WorkflowRun.add_context(stored, stored["current"], again["text"])
          dispatch(stored, ctx, "resume", context: again["context"], budgeted: budget, retry_of: again.slice("text", "attempt"))
        else
          dispatch(stored, ctx, "resume", budgeted: budget)
        end
      end
      nil
    end

    # `--from` goes elsewhere: the text that told the held step why it was sent back is not for the step named.
    def drop_retry_text(run, hold)
      index = hold["text"].is_a?(String) ? slot(run, "pending_context").index(hold["text"]) : nil
      slot(run, "pending_context").delete_at(index) if index
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
      [slot(run, "budget_hold"), slot(run, "timeout_hold")].find { |hold| hold.is_a?(Hash) }
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
    def deadline_shortfall(run, extra, stops)
      reading = WorkflowDeadline.reading(run, @clock.call, stops: stops)
      return nil unless reading && reading["spent"]
      return nil if extra && extra >= reading["needed"]
      reading
    end

    # Refuses with `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it, and with
    # `run_timed_out` when the run's timeout is used up and +extra_seconds+ does not cover it. With both short the
    # refusal is `budget_spent` and names both needs (the time one under `details.run_timed_out`).
    def refuse_over_limits(run, extra_tokens, extra_seconds, stops = downtime_stops)
      reading = budget_shortfall(run, extra_tokens)
      deadline = deadline_shortfall(run, extra_seconds, stops)
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
      stops = downtime_stops
      refuse_over_limits(run, extra_tokens, extra_seconds, stops)
      if extra_tokens && WorkflowBudget.reading(run)
        run["extra_tokens"] = run["extra_tokens"].to_i + extra_tokens
        event(run, "budget_extended", "extra" => extra_tokens, "extra_tokens" => run["extra_tokens"], "allowance" => WorkflowBudget.reading(run, live: false)["allowance"])
      end
      return unless extra_seconds && WorkflowDeadline.reading(run, @clock.call, stops: stops)
      run["extra_seconds"] = run["extra_seconds"].to_i + extra_seconds
      event(run, "time_extended", "extra" => extra_seconds, "extra_seconds" => run["extra_seconds"],
        "limit" => WorkflowDeadline.reading(run, @clock.call, stops: stops)["limit"])
    end

    def downtime_stops
      @downtime&.spans(@clock.call) || []
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
      waiting = slot(stored, "backoff")
      return nil if from || !(waiting.is_a?(Hash) && waiting["to"].is_a?(String))
      check_pane(pane, stored["id"]) if pane && @panes.run_on(pane) != stored["id"]
      problem = @progress.retry_pane_problem(stored, waiting, pane: pane, proven: !pane.nil?)
      return nil unless problem
      adopt(stored, @progress.hold_retry(stored, waiting, problem, pane: pane || bound_pane(stored)))
      held_retry_sentence(stored)
    end

    # Why a resume that skipped the wait still started nothing; nil when the retry started.
    def held_retry_sentence(run)
      return nil unless slot_dig(run, "backoff", "blocked")
      slot_dig(run, "reason", "details", "message").to_s.sub(/\.\z/, "")
    end

    def last_failure(run) = "The last attempt of this step failed: #{WorkflowTransitions.failure_text(slot(run, "reason")["details"])}."

    # Why {#resume} does nothing for the step as it stands; nil when it acts.
    def left_alone(run, state, pane, turn_over) = WorkflowTransitions.left_alone(run, state, pane, turn_over, @clock.call, -> { bound_pane(run) }, alive: @holder_alive)

    def rebind(run, pane)
      check_other_pane(pane, run["id"])
      if WorkflowRun.step_scoped?(run, run["current"])
        @panes.unbind(run["id"], step: run["current"])
      else
        @panes.unbind(run["id"])
      end
      WorkflowRun.slots(run, run["current"])["pane"] = pane
    end

    # Refuses +pane+ when another run has it; the run's own pane is never refused.
    def check_other_pane(pane, run_id)
      check_pane(pane, run_id) unless @panes.run_on(pane) == run_id
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
      message = if step && step != run["current"] && WorkflowRun.step_scoped?(run, run["current"])
        # A fan_out run read on the named sibling has its cursor there; one still elsewhere was given no sibling it has.
        "Run #{run["id"]} is not waiting at the gate of step #{step.to_s[0, 60]}: it has no such step under way " \
          "(the run's step #{run["current"]} is #{state["state"]}). Read `workspace workflow status #{run["id"]}` again."
      elsif step
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
    def with_text(data, text) = text.to_s.strip.empty? ? data : data.merge("text" => text)
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

    def dispatch(run, ctx, cause, **options) = adopt(run, @dispatch.dispatch(run, ctx: ctx, cause: cause, **options))
    def evaluate(run, ctx) = adopt(run, @evaluation.evaluate(run, ctx: ctx))
    def event(run, type, data = {}) = @change.event(run, type, data)
    def bound_pane(run) = bound_pane_of(run) || WorkflowRun.slot(run, run["current"], "pane")
    # The pane bound for the cursor's step: a fan_out sibling's own binding, else the run's first author pane.
    def bound_pane_of(run) = WorkflowRun.step_scoped?(run, run["current"]) ? @panes.pane_of(run["id"], step: run["current"]) : @panes.pane_of(run["id"])
    def step_ids(run) = run["definition"]["steps"].map { |step| step["id"] }
    def step_state(run) = run["steps"].fetch(run["current"])
    # The Hash the current step's {WorkflowRun::PER_STEP_KEYS} slots are written into ({WorkflowRun.slots}).
    def slots(run) = WorkflowRun.slots(run, run["current"])
    # One of the current step's slots ({WorkflowRun.slot}).
    def slot(run, key) = WorkflowRun.slot(run, run["current"], key)
    # {#slot} dug into ({WorkflowRun.slot_dig}).
    def slot_dig(run, key, *path) = WorkflowRun.slot_dig(run, run["current"], key, *path)
    def now_iso = @clock.call.utc.iso8601
  end
end
