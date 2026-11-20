require "time"

module Workspace
  # What follows a step's outcome: a passed step waits at its gate or the run goes on to the next step
  # ({#pass_step}, {#advance}) and completes after the last; a failed step goes back along its `on_fail`,
  # at once or after a backoff, or stops the run for a person ({#fail_step}); a backoff's retry starts
  # ({#start_retry}) or is held when its pane is no longer the run's ({#hold_retry}); {#finish} ends a run.
  # A step with a `review:` does not pass on its own checks: its attempt ends `checks_passed` and the step is
  # `reviewing` while a review round runs ({#pass_step}); the round's outcome decides it ({#decide_review}). A person's
  # resume starts the round again ({#restart_review}), and a cancel or `resume --from` ends it undecided ({#end_round}).
  # A rejected round starts the step again as a new attempt told what the reviewers wrote, while the step has rounds
  # (`review.max_rounds`) and the run and step have attempts left; no round starts past `max_rounds`.
  # Every round start is held, as an attempt start is, while the token budget or the run's timeout is used up, and
  # waits while a lock its `review.uses` names is taken. An approved round, an ended one and a run that ends unbind
  # the reviewer and register the review window to close once the lock is given up; a rejected or stopped round keeps
  # the window for the next round.
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
    # @param guard [#round_snapshot, nil] takes the checkout's snapshot as each round starts ({WorkflowGuard#round_snapshot});
    #   nil takes none, and the round is never checked against one
    # @param holder [#call, nil] answers the process that delivers a round this change starts (its "pid" and
    #   "started"), stored on the round as its `holder` while it is delivered; nil stores none
    # @param round_rerun [Workspace::WorkflowRoundRerun, nil] runs an incomplete round's missing reviewers again, records each
    #   round that ends and stores each delivery's holder; nil builds one over +change+, +store+, +dispatch+, +attempt_record+,
    #   +holder+ and +clock+, as {Workspace.build_workflow_engine} does but with no revision reader, which only
    #   {WorkflowRoundRerun#check_revision} (evaluation's, never progress's) reads
    # @param review_summary [Workspace::WorkflowReviewSummary, nil] writes each decided round's `summary.md` and posts the run and
    #   step's inbox item; nil writes and posts none
    # @param rejection [Workspace::WorkflowRejection, nil] the retry a rejected round starts; nil builds one over +change+,
    #   +dispatch+ and +log_tail+
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, attempt_record:, panes:, log_tail:, review_tally: nil, guard: nil, holder: nil, round_rerun: nil, review_summary: nil, rejection: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @dispatch = dispatch
      @attempt_record = attempt_record
      @panes = panes
      @log_tail = log_tail
      @review_tally = review_tally
      @guard = guard
      @review_summary = review_summary
      @rounds = round_rerun || WorkflowRoundRerun.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, holder: holder, clock: clock)
      @rejection = rejection || WorkflowRejection.new(change: change, dispatch: dispatch, log_tail: log_tail)
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

    # Passes a step whose last attempt already ended failed on a guard a person accepted (`resume --accept-guard`),
    # once the rest of its checks passed ({WorkflowEvaluation#evaluate_accepted}): the attempt's outcome becomes
    # `overridden`, with no second {WorkflowAttemptRecord#finish}, and the step goes on as {#pass_step} would take
    # it on: its review round, its gate, else the next step.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on that step (failed, or checking); left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def pass_overridden(run, ctx:) = over(run) { |work| override(work, ctx) }

    # Decides the review round of the step being reviewed. The attempt the round reviewed already ended
    # (`checks_passed`); its outcome is rewritten, with no second {WorkflowAttemptRecord#finish}, and
    # `review_outcome` (`round`, `approvals`, `need`, `must`, `passed`) and `reviews` added. Approved: the step passes, as {#pass_step} would pass it, to its gate or
    # the next step, unbinding the reviewer and registering the review window to close on +ctx+. Rejected: the attempt
    # and step fail, the window and its reviewer's binding are kept (named by the step's `review_window`); the step starts
    # again as a new attempt (`retry_of` the rejected one, with the step's `review.context`) whose context holds a line
    # naming the round and each verdict and each counted reviewer's write-up ({WorkflowLogTail#writeup}), and its next
    # review is a new round. The run stops for a person with `review_rejected` instead, `details.limit` saying why,
    # when the run's `max_attempts` is spent ("run"), else the step's own ("step"), else its `max_rounds` ("rounds"),
    # keeping the retry as the run's `review_retry` for a resume ({WorkflowRejection#retry_for}).
    # Incomplete: while the round has deliveries left (its `redeliveries` under the definition's `redeliver`) and the
    # verdicts that did not count each fell short on their own (missing, broken, unproven, a log gap after an agent
    # daemon restart; not a round problem, {WorkflowReviewTally::ROUND_PROBLEMS}), only those reviewers run again in
    # the same round and directory (`rerun`), one delivery spent, the counted verdicts kept; the part that ran is
    # recorded in the attempt's `rounds` (`ended: rerun`). Otherwise the step stays `reviewing`, the round is marked
    # ended, and the run stops with `review_incomplete`; its window is kept for the person to look at.
    # Stale (what the round judged changed while it ran): as incomplete, but the run stops with `review_stale`; it
    # never loops and starts no further round, and a resume starts a fresh one on the new revision. Guard (the
    # checkout changed under the round, see {WorkflowGuard#round_check}): the same, stopping with `review_guard`.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param tally [Hash{Symbol=>Object}] the round's tally: :outcome (`:approved`, `:rejected`, `:incomplete`, `:stale` or `:review_guard`),
    #   :reviews (the rows it read), :approvals, :need and :must when it counted them, for an incomplete one :problem,
    #   and for a stale one :revision (the round's delivered revision) and :revision_now, and for a changed checkout (`:review_guard`) :changed ("head", "tree"), :snapshot_head and :head
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def decide_review(run, tally, ctx:) = over(run) { |work| decide_in(work, tally, ctx) }

    # A person's resume of the step being reviewed. A round stopped `review_no_change` ({WorkflowRoundRerun#stop_no_change}) is delivered
    # as the same round, spending it again, with its unchanged revision accepted. A round that stopped for a person (a
    # stored reason, or a round already marked ended) is ended ({#end_round}, its window kept for the next round) and
    # a fresh round starts, which spends one of the step's rounds. A round whose delivery failed or lapsed is delivered again as the same
    # round, its redelivery count started again. A rerun a pause held (`held: "paused_rerun"`) is delivered as the same
    # round with no new record, its redeliveries, revision and snapshot kept: the one replay of that hold. Never starts an attempt. On a paused run a round start is held
    # ({WorkflowDispatch#hold_round}), and a round still open is left as it is with no hold.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] gets the round to run
    # @return [WorkflowRun] the run afterwards
    def restart_review(run, ctx:) = over(run) { |work| restart_in(work, ctx) }

    # Delivers the round of the step being reviewed again, as {WorkflowRecovery#tick} does for a delivery that failed
    # or lapsed ({WorkflowTransitions.round_redelivery}): the lapsed delivery is recorded (`ended: redelivered`), and the
    # same round is delivered with a new start and one more of its `redeliveries` spent, so the definition's
    # `redeliver` caps how often a tick does it (a person's {#restart_review} starts the count again). A paused run
    # changes nothing and records no hold: the round's own failed or lapsed mark already says it is to be delivered
    # again, and the first tick after the unpause does it.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] gets the round to run
    # @param new_server [Boolean] the round's window went with a restarted tmux server: the lapsed delivery's record
    #   keeps its pane, and the round delivered again drops its pane, window and server, so a new window opens
    # @return [WorkflowRun] the run afterwards
    def redeliver_round(run, ctx:, new_server: false)
      over(run) do |work|
        next if work["paused"]
        # The panes of the old server go too: a pane id the new server reuses must prove no verdict.
        drop = new_server ? %w[pane panes window server_pid] : []
        deliver_again(work, ctx, step_state(work)["review"]["redeliveries"].to_i + 1, drop)
      end
    end

    # Ends the round of the step being reviewed without a decision: the round's record ({WorkflowAttemptRecord#finish_round},
    # with how it ended and the verdict rows the round already read) is added to the reviewed attempt's `rounds`, and
    # the step's `review` is taken off. With +close+, the reviewer's binding is removed and the review window is
    # registered on +ctx+ to close; a step with no round but a window a rejected round kept (`review_window`) has that
    # window closed. A round that never started (held for the budget, the timeout or a lock) has no
    # record and no window of its own: only a window an earlier round of the step left is closed, and the first
    # round registers none. The step's state and `review_rounds` are left as they are. A step with no
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

    # Ends the run: drops its park, retry wait, budget and timeout holds, and its pause, what the pause held and a pending continue line, gives up its locks and frees its panes.
    # A run any of whose steps had a review round registers all its review windows to close on +ctx+, in place of a
    # close of one step's window the change registered.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] left as it is
    # @param state [String] the run's end state, "completed" or "cancelled"
    # @param ctx [Workspace::WorkflowRunChange::Context, nil] the change's context; nil registers no close
    # @return [WorkflowRun] the run afterwards
    def finish(run, state, ctx: nil) = over(run) { |work| end_run(work, state, ctx) }

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
    # @param cause [String] why the retry starts, written on its `step_dispatching`: `backoff_ended`, or `resume` when a person skips the wait
    # @return [WorkflowRun] the run afterwards
    def start_retry(run, waiting = nil, ctx:, cause:, proven: false, budgeted: true)
      over(run) do |work|
        # A fan_out sibling's slots are left as they are: {#retry_in} hands a sibling to its group's join.
        waiting ||= WorkflowRun.slots(work, work["current"]).delete("backoff") unless grouped?(work, work["current"])
        retry_in(work, waiting, ctx, proven, budgeted, cause)
      end
    end

    # The join of a fan_out group: the one check that runs after each sibling's attempt ends (passed, failed, or at
    # its gate), and here when a timer or a person wakes it. It takes the first of these that fits:
    #
    # 1. The group is not at rest ({WorkflowTransitions.group_at_rest?}: a sibling at work, owing an attempt, held, or
    #    waiting out a deferred move's backoff): nothing moves. The run reads `running` while a sibling works, with the
    #    cursor on the sibling at work dispatched last; else `waiting`, with the cursor on the first sibling held.
    # 2. A sibling carries a deferred failure move (`pending_move`): the first one, in step order, is applied, and only
    #    that one. Its target sibling runs again (cause `loop`), told what failed. A target that is failed with no run
    #    owed, or out of attempts, or that could not be started, is not run: the moving sibling's move is marked failed,
    #    with the target left as it was, and the join goes on down this list.
    # 3. Failed siblings are owed their run after a move was applied ({WorkflowTransitions.relay_owed?}): each runs
    #    again (cause `next_step`), all in one change, while the run and that sibling have attempts left.
    # 4. Every sibling passed: the step after the group starts (the group's last sibling's position plus one, never
    #    read from the cursor), or the run completes after the last.
    # 5. Otherwise the group failed (its `on_fail: stop`): every failed sibling stores its `failed_check` reason, the
    #    cursor goes to the first, and the run waits for a person. This is the only place a group's failure sets the
    #    run's state.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] gets the lines of the steps the join starts
    # @param group [String, nil] the group's id; nil joins each group a sibling of which carries a deferred move
    # @return [WorkflowRun] the run afterwards
    def join(run, ctx:, group: nil)
      over(run) do |work|
        groups = group ? [group] : WorkflowDefinition.group_steps(work["definition"]).select { |_, ids| ids.any? { |id| WorkflowRun.slot(work, id, "pending_move") } }.keys
        groups.each { |each| join_in(work, ctx, each) }
      end
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
      return {code: "pane_gone", message: "pane #{pane} is gone. Name another agent pane with `workflow resume --pane PANE`"} if @panes.pane_gone?(pane, workspace: run["workspace"])
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

    def override(run, ctx)
      state = step_state(run)
      state["attempts"].last["outcome"] = "overridden"
      WorkflowRun.slots(run, run["current"])["reason"] = nil
      return passed(run, ctx) unless WorkflowDefinition.review(step_def(run))
      state["state"] = "reviewing"
      begin_round(run, ctx)
    end

    # The step passed: its gate, else the next step.
    def passed(run, ctx)
      state = step_state(run)
      state["state"] = "passed"
      run["infra_retries"].delete(run["current"]) if run["infra_retries"].is_a?(Hash)
      event(run, "step_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      return go_on(run, ctx) unless step_def(run)["gate"]

      @dispatch.release(run)
      state["gate"] = {"state" => "waiting", "since" => now_iso}
      run["state"] = "waiting"
      details = {"kind" => "gate", "step" => run["current"], "artifacts" => step_def(run)["produces"].map { |file| File.join(run["artifacts_dir"], file) }}
      summary = state["attempts"].last.dig("review_outcome", "summary")
      details["summary"] = summary if summary.is_a?(String)
      WorkflowRun.slots(run, run["current"])["reason"] = reason("waiting_you", details)
      event(run, "gate_waiting", "step" => run["current"])
      # A sibling at its gate holds its group's join; the join says whether the run still runs (another sibling at work).
      join_in(run, ctx, group_id(run, run["current"])) if grouped?(run, run["current"])
    end

    # The author's turn passed every check; the attempt ends now, so its usage counts and its step timeout stops.
    def begin_review(run, ctx)
      record_end(run, step_state(run)["attempts"].last.merge("ended_at" => now_iso, "outcome" => "checks_passed"))
      state = step_state(run)
      state["state"] = "reviewing"
      event(run, "step_checks_passed", "step" => run["current"], "attempt" => state["attempts"].last["n"])
      begin_round(run, ctx)
    end

    # The one start of a review round: the round is spent here, and its delivery is registered on +ctx+. A round past
    # the step's `max_rounds` never starts ({#rounds_spent}), whoever starts it. A round is
    # held first, as an attempt is, when the token budget or the run's timeout is used up ({WorkflowDispatch#hold_round}),
    # then while a lock its `review.uses` names is taken ({WorkflowDispatch#hold_round_lock}, which also gives up the
    # step's own `uses:`): the step stays `reviewing` with the round named, marked `held`, and no delivery; the round
    # is not spent, and nothing is registered. The checkout's snapshot is taken here, under the lock that saw the
    # author's checks pass, so whatever moves the tree from then on, before the window opens too, stops the round.
    def begin_round(run, ctx)
      state = step_state(run)
      round = state["review_rounds"].to_i + 1
      return rounds_spent(run, round) if WorkflowTransitions.review_rounds_spent?(run, run["current"])
      held = @dispatch.hold_round(run, round: round) || @dispatch.hold_round_lock(run, round: round, step_state: state["state"])
      return hold_round(run, held, round) if held
      state["review_rounds"] = round
      state["review"] = {"round" => round, "delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3),
                         "pending" => WorkflowDefinition.review(step_def(run))["from"].dup, "redeliveries" => 0}
      @rounds.hold(state["review"])
      state["review"]["snapshot"] = @guard.round_snapshot(run["worktree"], base: run) if @guard
      run["state"] = "running"
      WorkflowRun.slots(run, run["current"])["reason"] = nil
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

    # A round past the step's `max_rounds` never starts: the step stays `reviewing` with the round named and held
    # (`review_rounds_spent`), nothing is spent or registered, and the run stops for a person. A resume is refused
    # while the rounds stay spent; `--from` or a cancel goes on.
    def rounds_spent(run, round)
      details = {"step" => run["current"], "attempt" => step_state(run)["attempts"].last["n"], "round" => round,
                 "rounds" => step_state(run)["review_rounds"].to_i, "max_rounds" => WorkflowTransitions.review_rounds_allowance(run, run["current"])}
      step_state(run)["review"] = {"round" => round, "delivery" => nil, "held" => "review_rounds_spent"}
      event(run, "review_rounds_spent", details)
      stop_review(run, "review_rounds_spent", details)
    end

    # A held round has no delivery and no start: its release goes through {#begin_round} for the same round. `held`
    # is the reason that kept it (`budget_spent`, `run_timed_out`, `waiting_lock`, `waiting_you` for a lock store
    # that could not be read, or `paused`).
    def hold_round(run, held, round)
      run.replace(held.thawed)
      step_state(run)["review"] = {"round" => round, "delivery" => nil, "held" => held_code(run)}
    end

    # What kept a held round: the pause ({WorkflowDispatch#hold_paused}, which stores no reason), else the reason.
    def held_code(run) = run["paused"] ? "paused" : WorkflowRun.slot_dig(run, run["current"], "reason", "code")

    # A round a hold kept from starting (its `held` mark, set by {#hold_round}): it never ran, so it has no record,
    # usage, review_ended or window of its own. Not read from `delivery: null`, which a delivered round has too.
    def held_round?(round) = round.is_a?(Hash) && round.key?("held") && !paused_rerun?(round)

    # A rerun a pause held ({WorkflowRoundRerun#rerun}): the round ran, and only its rerun's delivery waits. Not a
    # held round: it is never started as a fresh one, and its end adds no second record.
    def paused_rerun?(round) = round.is_a?(Hash) && round["held"] == WorkflowRoundRerun::PAUSED_RERUN

    # Unbinds the reviewer and registers the window to close once the lock is given up. The closer finds the window
    # by its `@workspace-review` mark, so a round that recorded no pane yet is closed too.
    def close_review(run, ctx, round)
      @panes.unbind(run["id"], role: "reviewer")
      step_state(run).delete("review_window")
      ctx.close_review({"workspace" => run["workspace"], "step" => run["current"], "round" => round["round"], "pane" => round["pane"]})
    end

    # The step's `review_window` names the window a round left for the next one, so the sweep never takes it for an
    # orphan while the step's author works or its next round is held.
    def record_window(run, round)
      return unless round.is_a?(Hash) && round["window"]
      step_state(run)["review_window"] = {"round" => round["round"], "window" => round["window"], "pane" => round["pane"]}.compact
    end

    # A round that ends here (not a rerun of its missing reviewers) has its summary written before its decision, and
    # the run and step's inbox item registered on +ctx+ to post once the lock is given up.
    def decide_in(run, tally, ctx)
      state = step_state(run)
      round = state["review"] || {}
      rerun = @rounds.rerun_names(run, round, tally)
      return adopt(run, @rounds.rerun(run, reviews: Array(tally[:reviews]), names: rerun, ctx: ctx)) if rerun
      step = run["current"]
      attempt = state["attempts"].last["n"]
      decided = {"round" => round["round"], "approvals" => tally[:approvals], "need" => tally[:need], "must" => tally[:must], "passed" => tally[:outcome] == :approved}
      # The revision judged, so the next round can tell an author's retry that changed nothing ({WorkflowRoundRerun#stop_no_change}).
      decided["revision"] = round["revision"] if round["revision"].is_a?(String)
      summary = if @review_summary && round["round"].is_a?(Integer)
        @review_summary.write(run, round: round["round"], outcome: tally[:outcome], decided: decided, reviews: Array(tally[:reviews]), problem: tally[:problem])
      end
      # A gate after a passing round names the summary as its note ({WorkflowGateNote#find}).
      decided["summary"] = summary["path"] if summary&.key?("path")
      decide_round(run, tally, ctx, decided, summary)
      return unless summary
      # Posted once the run's lock is given up, from the run as stored: the item says what the run does now.
      ctx.after_lock { |stored| @review_summary.notify(stored.to_h, step: step, attempt: attempt, round: round["round"], outcome: tally[:outcome], summary: summary) }
    end

    def decide_round(run, tally, ctx, decided, summary)
      state = step_state(run)
      round = state["review"] || {}
      attempt = state["attempts"].last
      reviews = Array(tally[:reviews])
      details = {"step" => run["current"], "attempt" => attempt["n"], "round" => round["round"]}
      outcome = tally[:outcome]
      event(run, "review_ended", details.merge("outcome" => outcome.to_s))
      # Every round that ends, decided or not, adds one record to the attempt's `rounds`: the one list its usage is read from.
      ended = round.merge("delivery" => nil, "ended_at" => now_iso, "reviews" => reviews)
      attempt = @rounds.with_round(run, attempt, ended, outcome.to_s)
      attempt["rounds"].last["summary"] = summary if summary
      # The rows as recorded, each with its `isolation`.
      reviews = attempt["rounds"].last.fetch("reviews", reviews)
      case outcome
      when :approved
        state.delete("review")
        # Closed whether or not a gate follows: the verdicts are on disk and in the attempt.
        close_review(run, ctx, round)
        # An attempt that passed only once a person accepted its guard stop stays `overridden`.
        passed_as = attempt["guard_accepted"] ? "overridden" : "passed"
        state["attempts"][-1] = attempt.merge("outcome" => passed_as, "review_outcome" => decided, "reviews" => reviews)
        passed(run, ctx)
      when :rejected
        state.delete("review")
        # Kept, idle, for the next round, which clears it; a run that ends closes it. Its reviewer stays bound to this
        # round until the next round binds it, so the write guard still holds for a sub-agent left running.
        record_window(run, round)
        state["attempts"][-1] = attempt.merge("outcome" => "failed", "code" => "review_rejected", "review_outcome" => decided, "reviews" => reviews)
        state["state"] = "failed"
        event(run, "step_failed", "step" => run["current"], "attempt" => attempt["n"], "cause" => "review")
        limit = WorkflowTransitions.rejection_limit(run)
        again = @rejection.retry_for(run, attempt: attempt["n"], round: round["round"], decided: decided, reviews: reviews, max_rounds: limit["max_rounds"])
        if limit["limit"]
          # Kept for the resume that goes on (`--extra-attempts`): it starts the retry this rejection would have.
          WorkflowRun.slots(run, run["current"])["review_retry"] = again
          return stop_review(run, "review_rejected", details.merge("reviews" => reviews).merge(limit))
        end
        adopt(run, @rejection.start(run, again, rounds: limit, ctx: ctx))
      else
        state["attempts"][-1] = attempt
        # Marked recorded, so the resume or cancel that ends it later adds no second record. A stopped round runs no
        # reviewer again, so it names none as `rerun`.
        state["review"] = ended.except("rerun").merge("recorded" => true)
        if outcome == :stale
          stop_review(run, "review_stale", details.merge("revision" => tally[:revision], "revision_now" => tally[:revision_now]))
        elsif outcome == :review_guard
          stop_review(run, "review_guard", details.merge("changed" => tally[:changed], "snapshot_head" => tally[:snapshot_head], "head" => tally[:head]).compact)
        else
          stop_review(run, "review_incomplete", details.merge("reviews" => reviews, "problem" => incomplete_problem(run, round, tally[:problem])).compact)
        end
      end
    end

    # An incomplete round's problem; for one the sweep interrupted for a time limit, what was interrupted and why first.
    def incomplete_problem(run, round, problem)
      cause = WorkflowTransitions.round_interrupted(round, @clock.call)
      return problem unless cause
      why = if cause == "run_timed_out"
        "the run used its time limit while the round was reviewed, so the sweep interrupted the review pane; a resume needs --extra-time"
      else
        "the round ran past its #{WorkflowTransitions.review_timeout(run).round} second review timeout, so the sweep interrupted the review pane"
      end
      "#{why}, and the verdicts written by then did not decide it#{": #{problem}" if problem}. Its window is kept: look at it first, since a resume starts a fresh round and closes it"
    end

    def restart_in(run, ctx)
      state = step_state(run)
      round = state["review"]
      # The round the unchanged revision stopped is spent now, judging that revision as the person asked. It is held,
      # as any round start is, for the token budget, the run's timeout and its `review.uses`: still the same round,
      # its `no_change` mark kept (its directory is made already), nothing spent, and its release comes back here.
      if round.is_a?(Hash) && round["no_change"]
        held = @dispatch.hold_round(run, round: round["round"]) || @dispatch.hold_round_lock(run, round: round["round"], step_state: state["state"])
        if held
          run.replace(held.thawed)
          step_state(run)["review"] = round.merge("delivery" => nil, "held" => held_code(run))
          return
        end
        state["review_rounds"] = round["round"]
        state["review"] = round.except("no_change", "held").merge("accept_revision" => true)
        WorkflowRun.slots(run, run["current"])["reason"] = nil
        return deliver_again(run, ctx, 0, record: false)
      end
      # A rerun a pause held (its part that ran already recorded and spent) is delivered as the same round, never
      # started as a fresh one; while paused nothing changes.
      if paused_rerun?(round)
        return if run["paused"]
        return deliver_rerun(run, ctx)
      end
      # A held round (a budget, timeout or lock hold, `waiting_lock` included) starts through its one start, which asks
      # the lock again; it never counts as a stopped round, so no round is spent on a lock wait.
      if held_round?(round)
        state.delete("review")
        return begin_round(run, ctx)
      end
      stopped = WorkflowRun.slot(run, run["current"], "reason") && WorkflowRun.slot_dig(run, run["current"], "reason", "code") != "waiting_lock"
      unless round.is_a?(Hash) && !stopped && round["ended_at"].nil?
        end_round_in(run, "resumed", ctx, false)
        return begin_round(run, ctx)
      end
      # A paused run changes nothing on a round still open, holding no lock back from its reviewers and recording no
      # hold: the round's own marks say what it needs, and the first tick after the unpause acts on them.
      return if run["paused"]
      # A person's resume starts the redelivery count again.
      deliver_again(run, ctx, 0)
    end

    # The lapsed delivery's time is recorded as a round record of its own (`ended: redelivered`), so its usage
    # is kept, and the round starts its clock again: a delivery mark is judged from `started_at`. The window id a
    # failed delivery kept stays on the round, so the sweep never takes that window for an orphan.
    def deliver_again(run, ctx, redeliveries, drop = [], record: true)
      state = step_state(run)
      round = state["review"]
      add_round_record(run, round, "redelivered") if record
      # The earlier delivery's own marks go: a turn's end is judged from this delivery's (`clear_from` excepted: a
      # line an earlier delivery typed into a cleared window may be the reviewers' turn, so its clear still counts),
      # and its time limits start again, so the sweep's interrupt marks (`sweep`) go too.
      state["review"] = round.except("holder", "failure", "delivered_at", "cleared_at", "kick_at", "sweep", *drop).merge("delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3), "redeliveries" => redeliveries)
      @rounds.hold(state["review"])
      state["review"]["snapshot"] = @guard.round_snapshot(run["worktree"], base: run) if @guard
      run["state"] = "running"
      attempt = state["attempts"].last["n"]
      data = {"step" => run["current"], "attempt" => attempt, "round" => round["round"], "again" => true}
      data["redelivery"] = redeliveries if redeliveries.positive?
      event(run, "review_started", data)
      ctx.review({"step" => run["current"], "attempt" => attempt, "round" => round["round"]})
    end

    # The one delivery of a rerun a pause held ({WorkflowRoundRerun#rerun}), as that rerun would have made it: its
    # `redeliveries` (spent when it was held), revision and checkout snapshot are the round's as stored, so the
    # verdicts already written still match and `redeliver` still caps it; only `held` goes, and the delivery, its
    # start and its holder are set.
    def deliver_rerun(run, ctx)
      state = step_state(run)
      round = state["review"].except("held").merge("delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3))
      state["review"] = round
      @rounds.hold(round)
      run["state"] = "running"
      WorkflowRun.slots(run, run["current"])["reason"] = nil
      details = {"step" => run["current"], "attempt" => state["attempts"].last["n"], "round" => round["round"]}
      event(run, "review_started", details.merge("again" => true))
      ctx.review(details.merge("revision" => round["revision"]).compact)
    end

    def end_round_in(run, how, ctx, close)
      state = step_state(run)
      round = state["review"]
      # A step a round rejected has no round, only the window it kept: closed when asked.
      return close_review(run, ctx, state["review_window"]) if !round.is_a?(Hash) && close && state["review_window"].is_a?(Hash)
      return unless round.is_a?(Hash)
      attempt = state["attempts"].last
      # A round an unchanged revision stopped delivered nothing, as a held one: no record, no review_ended.
      held = held_round?(round) || paused_rerun?(round) || round["no_change"] == true
      add_round_record(run, round, how) unless round["recorded"] || held
      state.delete("review")
      # A round a tally already ended wrote its `review_ended`.
      event(run, "review_ended", "step" => run["current"], "attempt" => attempt["n"], "round" => round["round"], "outcome" => how) unless round["ended_at"] || held
      return record_window(run, round) unless close
      # A held round opened no window; only an earlier round of the step can have left one.
      return if held && state["review_rounds"].to_i.zero?
      close_review(run, ctx, round)
    end

    def add_round_record(run, round, how)
      state = step_state(run)
      state["attempts"][-1] = @rounds.with_round(run, state["attempts"].last, round, how)
    end

    def stop_review(run, code, details)
      @dispatch.release(run)
      run["state"] = "waiting"
      WorkflowRun.slots(run, run["current"])["reason"] = reason(code, details)
    end

    def go_on(run, ctx)
      # A fan_out sibling never moves the run on by itself: its group's join decides what comes next. A passed sibling
      # going on (its gate approved, say) holds nothing any more, so the reason its gate stored goes.
      if grouped?(run, run["current"])
        WorkflowRun.slots(run, run["current"])["reason"] = nil if step_state(run)["state"] == "passed"
        return join_in(run, ctx, group_id(run, run["current"]))
      end
      ids = step_ids(run)
      following = ids[ids.index(run["current"]) + 1]
      return complete(run, ctx) unless following
      run["current"] = following
      dispatch(run, ctx, "next_step", {entering: true})
    end

    def complete(run, ctx)
      end_run(run, "completed", ctx)
      event(run, "run_completed")
    end

    # The run-level {WorkflowRun::PER_STEP_KEYS} slots an ended run drops: every one but its reason (set to nil
    # below), its reason history, and the pending context (kept, as an ended run always has).
    # The run-level `sweep` marks stay too, as an ended run has always kept them; a step's own are dropped with its other slots.
    ENDED_RUN_SLOTS = (WorkflowRun::PER_STEP_KEYS - %w[reason reasons pending_context sweep]).freeze

    def end_run(run, state, ctx)
      adopt(run, @dispatch.drop_park(run, "ended")) if run.key?("parked")
      # A run that ends ends its pause: no finished run reads `paused`, and what the pause held is not started.
      run.delete("paused")
      ENDED_RUN_SLOTS.each { |key| run.delete(key) }
      @dispatch.release(run)
      @panes.unbind(run["id"])
      # Every window a round of the run left, of any step: the closer finds them by their mark, a step of nil naming
      # them all, so this takes the place of a close of one step's window the same change registered.
      reviewed = run["steps"].values.any? { |each| each.is_a?(Hash) && each["review_rounds"].to_i.positive? }
      # A fan_out sibling's kept failure details (`failed_reason`, read only by its group's join) go with the run too.
      run["steps"].each_value { |each| %w[review_window failed_reason].each { |key| each.delete(key) } if each.is_a?(Hash) }
      ctx.close_review({"workspace" => run["workspace"], "step" => nil, "round" => nil, "pane" => nil}) if ctx && reviewed
      # A step's own slots go too, from every step, so an ended run reads as no step mid-retry or held.
      WorkflowRun.drop_step_slots(run)
      run["state"] = state
      run["reason"] = nil
      run["ended_at"] = now_iso
    end

    def fail_in(run, failure, ctx)
      step = step_def(run)
      last = step_state(run)["attempts"].last
      # An attempt whose guard stop a person accepted ended when the guard stopped it: its end is not recorded twice.
      again = last["guard_accepted"] && last["ended_at"]
      ended = last.merge("ended_at" => again ? last["ended_at"] : now_iso, "outcome" => "failed")
      ended["code"] = failure["code"] if failure["code"].is_a?(String)
      again ? (step_state(run)["attempts"][-1] = ended) : record_end(run, ended)
      state = step_state(run)
      attempt = state["attempts"].last
      state["state"] = "failed"
      event(run, "step_failed", {"step" => step["id"], "attempt" => attempt["n"]}.merge(failure.slice("cause", "exit_code")))
      on_fail = step["on_fail"]
      attempts = WorkflowTransitions.attempts_made(run)
      next_move = WorkflowTransitions.after_failure(run, failure, step: step["id"])
      return defer_failure(run, step, failure, next_move, ctx) if grouped?(run, step["id"])
      if next_move[:kind] == :loop
        run["loops"][next_move[:edge]] = next_move[:count]
        text = loop_context(run, step, on_fail, failure, next_move[:count])
        wait = next_move[:wait]
        event(run, "step_looped", {"from" => step["id"], "to" => next_move[:to], "count" => next_move[:count]}.merge(wait ? {"backoff" => wait} : {}))
        return wait_to_retry(run, step, on_fail, text, wait, attempt) if wait
        WorkflowRun.add_context(run, next_move[:to], text)
        run["current"] = next_move[:to]
        return dispatch(run, ctx, "loop", {context: on_fail.is_a?(Hash) ? on_fail["context"] : nil, retry_of: {"text" => text}})
      end
      @dispatch.release(run)
      run["state"] = "waiting"
      details = {"step" => step["id"], "attempt" => attempt["n"], "loops" => run["loops"],
                 "attempts" => attempts, "max_attempts" => WorkflowTransitions.attempt_allowance(run)}
      if next_move[:limit] == :step
        details["limit"] = "step"
        details["limit_step"] = next_move[:step]
      end
      WorkflowRun.slots(run, step["id"])["reason"] = reason("failed_check", details.merge(failure))
    end

    # No attempt, pane binding or lock is held while the retry waits: the run reads `waiting` with the reason
    # `retry_backoff`, and the step stays `failed` until {#start_retry}. Never for a fan_out sibling, whose wait is
    # part of its deferred move ({#defer_failure}).
    def wait_to_retry(run, step, on_fail, text, wait, attempt)
      @dispatch.release(run)
      pane = bound_pane(run, step["id"])
      identity = @panes.identity(run["id"])
      @panes.unbind(run["id"])
      time = (@clock.call + wait).utc.iso8601
      slots = WorkflowRun.slots(run, step["id"])
      slots["backoff"] = {"until" => time, "to" => on_fail["goto"], "context" => on_fail["context"], "text" => text, "pane" => pane, "identity" => identity}.compact
      run["state"] = "waiting"
      slots["reason"] = reason("retry_backoff", {"step" => step["id"], "attempt" => attempt["n"], "to" => on_fail["goto"], "until" => time,
                                               "seconds" => wait, "loops" => run["loops"]})
    end

    def retry_in(run, waiting, ctx, proven, budgeted, cause)
      # A fan_out sibling's failure move is its group join's to apply ({#join}): no retry moves a sibling, so no
      # second mover types into a target the join owns.
      return join_in(run, ctx, group_id(run, run["current"])) if grouped?(run, run["current"])
      problem = retry_pane_problem(run, waiting, proven: proven)
      return hold_in(run, waiting, problem, bound_pane(run)) if problem
      to = waiting["to"]
      from = run["current"]
      WorkflowRun.add_context(run, to, waiting["text"]) if waiting["text"].is_a?(String)
      event(run, "step_retry_started", "from" => from, "to" => to)
      run["current"] = to
      WorkflowRun.slots(run, from)["reason"] = nil
      dispatch(run, ctx, cause, {context: waiting["context"], budgeted: budgeted, retry_of: waiting.slice("pane", "identity", "text")})
    end

    def hold_in(run, waiting, problem, pane)
      slots = WorkflowRun.slots(run, run["current"])
      held = slots["backoff"]
      same = held.is_a?(Hash) && held["blocked"] == problem[:code] && slots.dig("reason", "details", "pane") == pane &&
        slots.dig("reason", "details", "error") == problem[:code]
      return if same
      slots["backoff"] = waiting.merge("blocked" => problem[:code])
      slots["reason"] = reason((problem[:code] == "pane_gone") ? "pane_gone" : "waiting_you",
        {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"], "error" => problem[:code],
         "message" => "the retry of step #{waiting["to"]} was not started: #{problem[:message]}. Or cancel the run."})
      event(run, "step_retry_blocked", "from" => run["current"], "to" => waiting["to"], "code" => problem[:code])
    end

    # A fan_out sibling's failure, decided as any step's ({WorkflowTransitions.after_failure}, for the sibling itself)
    # but not acted on here: a granted move spends its loop now and is kept as the sibling's `pending_move` ("to",
    # "context", "text", "count", and "until" for a backoff, whose wait shows as the sibling's `retry_backoff`
    # reason), and the attempt records it as its `move`; the sibling's failure details are kept as its
    # `failed_reason` for the group's failure path. Nothing else moves: no pane is typed into, no other sibling
    # changes, and the run's state is the join's to say.
    def defer_failure(run, step, failure, next_move, ctx)
      id = step["id"]
      state = step_state(run)
      attempt = state["attempts"].last
      on_fail = step["on_fail"]
      details = {"step" => id, "attempt" => attempt["n"], "loops" => run["loops"].dup,
                 "attempts" => WorkflowTransitions.attempts_made(run), "max_attempts" => WorkflowTransitions.attempt_allowance(run)}
      if next_move[:limit] == :step
        details["limit"] = "step"
        details["limit_step"] = next_move[:step]
      end
      if next_move[:kind] == :loop
        count = next_move[:count]
        run["loops"][next_move[:edge]] = count
        text = loop_context(run, step, on_fail, failure, count)
        wait = next_move[:wait]
        event(run, "step_looped", {"from" => id, "to" => next_move[:to], "count" => count}.merge(wait ? {"backoff" => wait} : {}))
        move = {"to" => next_move[:to], "context" => on_fail.is_a?(Hash) ? on_fail["context"] : nil, "text" => text, "count" => count}
        slots = WorkflowRun.slots(run, id)
        if wait
          time = (@clock.call + wait).utc.iso8601
          move["until"] = time
          slots["reason"] = reason("retry_backoff", {"step" => id, "attempt" => attempt["n"], "to" => next_move[:to], "until" => time,
                                                     "seconds" => wait, "loops" => run["loops"].dup})
        end
        slots["pending_move"] = move.compact
        attempt["move"] = {"to" => next_move[:to], "count" => count}
      end
      state["failed_reason"] = details.merge(failure)
      join_in(run, ctx, group_id(run, id))
    end

    def join_in(run, ctx, group)
      ids = WorkflowDefinition.group_steps(run["definition"])[group] || []
      return if ids.empty?
      now = @clock.call
      return hold_join(run, ids, now) unless WorkflowTransitions.group_at_rest?(run, ids, now)
      mover = ids.find { |id| WorkflowRun.slot(run, id, "pending_move").is_a?(Hash) }
      return apply_move(run, ctx, group, mover) if mover
      owed = ids.select { |id| WorkflowTransitions.relay_owed?(run, id) }
      return relay(run, ctx, owed) if owed.any?
      return after_group(run, ctx, ids) if ids.all? { |id| run.dig("steps", id, "state") == "passed" }
      fail_group(run, ids, group)
    end

    # Branch 1: nothing moves. While a sibling works the run runs, its cursor on the sibling at work dispatched last;
    # else it waits, its cursor on the first sibling that holds the group (a gate, a hold, a move's backoff).
    def hold_join(run, ids, now)
      busy = ids.select { |id| WorkflowTransitions::SIBLING_BUSY.include?(run.dig("steps", id, "state")) }
      if busy.any?
        # A paused or parked run keeps the state its pause or park gave it.
        run["state"] = "running" unless run["paused"] || run["parked"]
        run["current"] = busy.each_with_index.max_by { |id, index| [Array(run.dig("steps", id, "attempts")).last&.fetch("started_at", nil).to_s, index] }.first
      else
        run["state"] = "waiting"
        # The sibling whose wait ends first (a deferred move's or a backoff's `until`), else the first not at rest, so
        # a reader of the cursor's step sees the soonest wake first.
        owed = ids.reject { |id| WorkflowTransitions.sibling_at_rest?(run, id, now) }
        run["current"] = owed.each_with_index.min_by { |id, index| [wait_until(run, id) || "~", index] }&.first || ids.first
      end
    end

    # When +id+'s wait ends, as stored (ISO 8601): its deferred move's `until`, else its backoff's; nil for neither.
    def wait_until(run, id)
      [WorkflowRun.slot_dig(run, id, "pending_move", "until"), WorkflowRun.slot_dig(run, id, "backoff", "until")].find { |each| each.is_a?(String) }
    end

    # Branch 2: the first deferred move, and only it. The move's slot (its wait with it) goes whether or not it applies.
    def apply_move(run, ctx, group, mover)
      slots = WorkflowRun.slots(run, mover)
      move = slots.delete("pending_move")
      slots["reason"] = nil if slots.dig("reason", "code") == "retry_backoff"
      to = move["to"]
      problem = move_problem(run, to)
      return move_failed(run, ctx, group, mover, to, problem) if problem
      target = run["steps"][to]
      was = target["state"]
      made = target["attempts"].size
      WorkflowRun.add_context(run, to, move["text"]) if move["text"].is_a?(String)
      event(run, "step_retry_started", "from" => mover, "to" => to)
      run["current"] = to
      dispatch(run, ctx, "loop", {context: move["context"], retry_of: {"text" => move["text"]}.compact})
      target = run["steps"][to]
      last = target["attempts"].last
      if target["attempts"].size > made && last["outcome"] == "not_delivered"
        # The target could not be started (its pane is gone): it is left as it was, and the move fails instead.
        target["state"] = was
        WorkflowRun.slots(run, to)["reason"] = nil
        return move_failed(run, ctx, group, mover, to, last["code"] || "not_delivered")
      end
      target.delete("failed_reason")
    end

    # Why a deferred move can't run its target: the target failed with no run owed to it (its own retries are spent,
    # and running it would pass the caps every other path keeps), or the run or the target has no attempt left.
    def move_problem(run, to)
      return "target_failed" if run.dig("steps", to, "state") == "failed" && !WorkflowTransitions.relay_owed?(run, to)
      return "attempts_spent" if WorkflowTransitions.attempts_spent?(run) || WorkflowTransitions.step_attempts_spent?(run, to)
      nil
    end

    # A move that could not be applied: the moving sibling's attempt records why (its `move` marked `failed`, so no
    # run is owed it) and the join goes on, to the group's failure path when nothing else is left.
    def move_failed(run, ctx, group, mover, to, code)
      state = run["steps"][mover]
      attempt = state["attempts"].last
      attempt["move"] = (attempt["move"] || {"to" => to}).merge("failed" => code)
      state["failed_reason"] = (state["failed_reason"] || {"step" => mover, "attempt" => attempt["n"]}).merge("move" => {"to" => to, "error" => code})
      event(run, "step_retry_blocked", "from" => mover, "to" => to, "code" => code)
      join_in(run, ctx, group)
    end

    # Branch 3: each failed sibling owed its run starts again, in one change, while the run and it have attempts left.
    def relay(run, ctx, owed)
      owed.each do |id|
        next unless WorkflowTransitions.relay_owed?(run, id)
        run["steps"][id].delete("failed_reason")
        run["current"] = id
        dispatch(run, ctx, "next_step", {})
      end
    end

    # Branch 4: the step after the group, by the group's place in the definition; the cursor names only the sibling
    # dispatched last.
    def after_group(run, ctx, ids)
      steps = step_ids(run)
      following = steps[steps.index(ids.last) + 1]
      return complete(run, ctx) unless following
      run["current"] = following
      dispatch(run, ctx, "next_step", {entering: true})
    end

    # Branch 5: the group failed. Each failed sibling stores its `failed_check` reason (its own failure's details,
    # with the group and every failed sibling named), and the run waits for a person on the first.
    def fail_group(run, ids, group)
      failed = ids.reject { |id| run.dig("steps", id, "state") == "passed" }
      @dispatch.release(run)
      run["state"] = "waiting"
      failed.each do |id|
        state = run["steps"][id]
        details = state.delete("failed_reason") || {"step" => id, "attempt" => Array(state["attempts"]).last&.fetch("n", nil)}
        details = details.merge("group" => group, "failed" => failed, "loops" => run["loops"].dup,
          "attempts" => WorkflowTransitions.attempts_made(run), "max_attempts" => WorkflowTransitions.attempt_allowance(run))
        move = Array(state["attempts"]).last&.fetch("move", nil)
        # A run that was owed and never made, for the sibling's own cap.
        if move.is_a?(Hash) && !move.key?("failed") && WorkflowTransitions.step_attempts_spent?(run, id)
          details["limit"] = "step"
          details["limit_step"] = id
        end
        WorkflowRun.slots(run, id)["reason"] = reason("failed_check", details)
      end
      run["current"] = failed.first
    end

    # Whether +step_id+ is a fan_out sibling ({WorkflowRun.step_scoped?}).
    def grouped?(run, step_id) = WorkflowRun.step_scoped?(run, step_id)

    # The id of the fan_out group +step_id+ is a sibling of.
    def group_id(run, step_id) = run["definition"]["steps"].find { |step| step["id"] == step_id }["group"]

    def loop_context(run, step, on_fail, failure, count)
      cap = on_fail.is_a?(Hash) ? " of #{on_fail["max"]}" : ""
      text = "The #{step["id"]} step failed and sent the run back to this step (time #{count}#{cap}): #{WorkflowTransitions.failure_text(failure)}. " \
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

    def dispatch(run, ctx, cause, options)
      adopt(run, @dispatch.dispatch(run, ctx: ctx, cause: cause, **options))
    end

    def event(run, type, data = {}) = @change.event(run, type, data)

    # The pane the run's author agent works in; for a step of a group, that step's own binding, then its recorded pane.
    def bound_pane(run, step_id = nil)
      return @panes.pane_of(run["id"]) || run["pane"] unless WorkflowRun.step_scoped?(run, step_id)
      @panes.pane_of(run["id"], step: step_id) || WorkflowRun.slot(run, step_id, "pane")
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
