require "time"

module Workspace
  # Decides a step whose agent's turn ended ({#turn_ended}, {#evaluate}): an agent's `fail` report, the step's
  # `guard:` (and the repository config warning), its `produces` files, then its `require:` proofs and `status:`
  # check, a proof or check that needs time run with the run's lock given up ({#finish_check}). Also records what
  # the agent says about its attempt ({#report}). A passed or failed step goes on through {WorkflowProgress}.
  # Each method that takes a run leaves it as it is and returns the run afterwards.
  class WorkflowEvaluation
    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = (WorkflowGuard::CODES + [WorkflowGuard::CONFIG_CHANGED] + WorkflowRequire::PROOFS.map { |name| "require_#{name}" } + %w[require_remote_unreachable require_unknown check_failed check_timed_out check_error reported step_timed_out review_rejected review_incomplete review_stale review_tampered review_guard review_no_change]).freeze

    # The default recorded with the ask a stated `needs_input` makes.
    ASK_DEFAULT = "workflow held; no default taken"

    # The most of a failed check's log the `report_code` reading looks at.
    CHECK_CODE_TAIL_BYTES = 4096

    # How many times the end of one round has its revision computed again: the first, and one more after a
    # recompute that never reported back ({WorkflowTransitions.lost_round?}); past it the round stops `review_incomplete`.
    REVISION_TRIES = 2

    # What {#report} recorded: the run, its step and attempt, and the stored report ("status", "summary", "code", "at").
    Reported = Data.define(:run_id, :step, :attempt, :reported)

    # The tally used when none is given (an engine built without one, as a spec's or the simulator's; `build_cli` gives
    # {WorkflowReviewTally}): it reads no verdicts, so every round it is asked about is incomplete.
    class NoReviewTally
      # @param run [WorkflowRun] the run, on a step being reviewed
      # @param step [Hash{String=>Object}] the step's definition
      # @param round [Hash{String=>Object}] the step's round
      # @return [Hash{Symbol=>Object}] :outcome `:incomplete`, :reviews and :problem
      def call(run:, step:, round:)
        {outcome: :incomplete, reviews: [], problem: "no reader of verdicts is set up, so the round's verdicts were not read"}
      end
    end

    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] reads the run while a check runs outside its lock
    # @param progress [Workspace::WorkflowProgress] passes or fails the step once it is decided
    # @param panes [Workspace::WorkflowPanes] names the pane the run is bound to
    # @param checker [Workspace::WorkflowCheck] runs a step's `status:` command
    # @param require_check [Workspace::WorkflowRequire] checks a step's `require:` proofs
    # @param guard [Workspace::WorkflowGuard] checks a guarded step against the run's base and reads config changes
    # @param commands_config [Workspace::CommandsConfig] the project's `commands.test`/`commands.lint`
    # @param inbox_for [#call, nil] given a workspace name, its inbox store, for a guard's warning (default: no item)
    # @param review_round [#call, nil] given the run id and the review round a change registered, runs it with the lock given up and answers the run afterwards (default: nothing runs)
    # @param review_tally [#call, nil] given `run:`, `step:` and `round:`, the round's outcome and the reviews it read ({WorkflowReviewTally};
    #   default: {NoReviewTally})
    # @param review_closer [#call, nil] given the run id and an ended round's "step", "round" and "pane", closes its review
    #   window with the lock given up; it must not raise (default: none, so the window stays open)
    # @param round_rerun [Workspace::WorkflowRoundRerun, nil] has a round after a rejected one checked for an unchanged revision
    #   before it is delivered (default: none, so every round registered is delivered)
    # @param review_revision [#call, nil] given `run:`, `step:` and `stop_when:`, the revision of what the round judges now
    #   ({WorkflowReviewRevision}), computed again with the lock given up when a round ends (default: none, and the
    #   round is tallied at once, under the lock that saw it end)
    # @param transcript [#last_assistant_message, nil] reads the last assistant message of a transcript path ({TranscriptSummary}), for the
    #   status line a turn ended with (default: none, so no status is read)
    # @param ask_for [#call, nil] given a workspace name, its ask store ({AskStore}), where a stated `needs_input` with a detail
    #   records one `workspace ask` entry (default: none, so none is recorded)
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, progress:, panes:, checker:, require_check:, guard:, commands_config:, inbox_for: nil, ask_for: nil, review_round: nil, review_tally: nil, review_closer: nil,
      review_revision: nil, round_rerun: nil, transcript: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @progress = progress
      @panes = panes
      @checker = checker
      @require_check = require_check
      @guard = guard
      @commands_config = commands_config
      @inbox_for = inbox_for
      @ask_for = ask_for
      @review_round = review_round
      @review_tally = review_tally || NoReviewTally.new
      @review_closer = review_closer
      @review_revision = review_revision
      @round_rerun = round_rerun
      @transcript = transcript
      @clock = clock
    end

    # The agent's turn ended in the run's pane: decides whether the current step is done. A step with a
    # `status:` check has it run here, outside the run's lock, so a long check never blocks a `cancel`.
    # On a step being reviewed only the round's review pane counts: its turn's end decides the round
    # ({#review_ended}), and a turn's end in the author's pane changes nothing. A turn's end for an attempt whose line a
    # pause kept from being typed (`pause_hold` kind `delivery` naming it) changes nothing either: the agent never got
    # the step, so whatever turn ended (a person typing in the pane) is not the step's. A turn's end that is decided
    # drops a `pause --interrupt` continue mark (`paused.interrupt`, `continue_pending`): no continue line follows it.
    #
    # @param run_id [String]
    # @param pane [String, nil] the pane the turn ended in; an event from a pane the run is not bound to changes nothing
    # @param turn_started [Time, nil] when the turn that ended began; one that began before the step's attempt did decides nothing
    # @param stopped_at [Time, nil] when the turn's end was seen; one from before the attempt began decides nothing
    # @param background [Array<Hash>] the background tasks the agent still listed when its turn ended
    # @param transcript_path [String, nil] the hook payload's transcript; the status line its last assistant message ends with is stored
    #   on the attempt as `status_report` (stored only, nothing is judged by it)
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [WorkflowRun] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, actor:, pane: nil, turn_started: nil, stopped_at: nil, background: [], transcript_path: nil)
      follow = nil
      status_report = read_status_report(transcript_path)
      run = @change.call(run_id, actor: actor, cause: "turn_ended") do |read, ctx|
        stored = read.to_h
        next if stored["parked"]
        state = step_state(stored)
        next if held_delivery?(stored, state)
        if state["state"] == "reviewing"
          next unless review_turn?(stored, state["review"], pane, turn_started, stopped_at)
          judged = review_ended(read, ctx: ctx)
          follow = ctx
          next judged
        end
        next unless state["state"] == "running"
        next if pane && bound_pane(stored) != pane
        next if turn_started && turn_started < Time.iso8601(state["attempts"].last["started_at"])
        next if stopped_at && stopped_at < Time.iso8601(state["attempts"].last["started_at"])
        judged = evaluate(without_continue_marks(read), ctx: ctx, turn_started: turn_started, background: background, status_report: status_report)
        follow = ctx
        judged
      end
      finish_follow_ups(run_id, follow, run)
    end

    # Records what the agent says about its current attempt. Nothing moves until the turn ends.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @param actor [String] who makes the change, one of {WorkflowRunChange::ACTORS}
    # @return [Reported]
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, actor:, status:, summary: nil, code: nil)
      result = nil
      @change.call(run_id, actor: actor, cause: "report") do |read|
        stored = read.thawed
        state = step_state(stored)
        unless %w[running checking].include?(state["state"])
          raise Workspace::Error.new("Step #{stored["current"]} of run #{run_id} is #{state["state"]}, so there is nothing to report on.",
            code: "step_not_running", details: {"run_id" => run_id, "step" => stored["current"], "state" => state["state"]})
        end
        attempt = state["attempts"].last
        attempt["reported"] = {"status" => status, "summary" => summary, "code" => code, "at" => now_iso}.reject { |key, value| key == "code" && value.nil? }
        event(stored, "step_reported", "step" => stored["current"], "attempt" => attempt["n"], "status" => status)
        result = Reported.new(run_id: run_id, step: stored["current"], attempt: attempt["n"], reported: attempt["reported"])
        WorkflowRun.from_h(stored)
      end
      result
    end

    # Decides a step whose turn ended. Registers the proof or check to run outside the lock on +ctx+, when the
    # step has one and nothing else already decided it. A stop seen again (the same code, step and attempt)
    # keeps its `since`, so a repeat raises no second notice; a turn that began after the stop was recorded is a
    # new stop. The stored `since` is whole seconds, so a turn that began in the same second is the same stop.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context
    # @param turn_started [Time, nil]
    # @param background [Array<Hash>] see {#turn_ended}
    # @return [WorkflowRun] the run afterwards
    def evaluate(run, ctx:, turn_started: nil, background: [], status_report: nil)
      work = WorkflowRun.from_h(run).thawed
      judge(work, ctx, turn_started, background, status_report: status_report)
      WorkflowRun.from_h(work)
    end

    # Decides the step a person's `resume --accept-guard` took a guard stop on, as {#evaluate} would with the guard
    # left out: its `produces` files, its `require:` proofs (one run outside the lock registered on +ctx+) and its
    # `status:` check (registered on +ctx+, run by {#finish_check}). The stopped attempt already ended, so it is marked
    # `guard_accepted` (the guard's code) and is never finished again: when the rest passes, now or once
    # {#finish_check} applies a result, it reads `overridden` ({WorkflowProgress#pass_overridden}); when it does not,
    # the step stops with that reason (`turn_ended_incomplete`, or `failed_check` with the proof's or check's code).
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, re-baselined, on the failed step; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context
    # @return [WorkflowRun] the run afterwards
    def evaluate_accepted(run, ctx:)
      work = WorkflowRun.from_h(run).thawed
      guard = work.dig("reason", "details", "guard")
      step_state(work)["attempts"].last["guard_accepted"] = guard
      work["reason"] = nil
      work["state"] = "running"
      judge(work, ctx, nil, [], guard: false)
      WorkflowRun.from_h(work)
    end

    # The review round of the step being reviewed ended. With a revision reader the round is marked (`recompute`:
    # its `started_at` and `try`) and registered on +ctx+ ({WorkflowRunChange::Context#review_end}): its revision is
    # computed again with the lock given up, and {#finish_follow_ups} decides it. A round already tried
    # {REVISION_TRIES} times stops `review_incomplete`. Without a reader the tally reads the round now and the step
    # is decided through {WorkflowProgress#decide_review}.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on a step being reviewed; left as it is
    # @param ctx [Workspace::WorkflowRunChange::Context] the change's context
    # @return [WorkflowRun] the run afterwards
    def review_ended(run, ctx:)
      read = WorkflowRun.from_h(run)
      guarded = round_guard(read, ctx)
      return guarded if guarded
      return tally_round(read, ctx) unless @review_revision
      work = read.thawed
      state = step_state(work)
      round = state["review"]
      tries = round["recompute"].is_a?(Hash) ? round["recompute"]["try"].to_i : 0
      if tries >= REVISION_TRIES
        round.delete("recompute")
        problem = "the round's revision was computed again #{tries} times and none reported back"
        return @progress.decide_review(work, {outcome: :incomplete, reviews: [], problem: problem}, ctx: ctx)
      end
      round["recompute"] = {"started_at" => now_iso, "try" => tries + 1}
      ctx.review_end({"step" => work["current"], "attempt" => state["attempts"].last["n"], "round" => round["round"], "try" => tries + 1})
      WorkflowRun.from_h(work)
    end

    # The one place a change's follow-ups run, once its lock is given up: the review window of an ended round it
    # registered is closed first, then the check or proof it registered runs, then the ended round whose revision
    # it registered is decided ({#review_ended}), then the review round it registered.
    # Every caller of {WorkflowRunChange#call} whose block can register one ends with it.
    #
    # @param run_id [String]
    # @param ctx [WorkflowRunChange::Context, nil] the change's context; nil when the change did not run
    # @param run [WorkflowRun] the run the change returned
    # @return [WorkflowRun] the run afterwards
    def finish_follow_ups(run_id, ctx, run)
      return run unless ctx
      @review_closer.call(run_id, ctx.close_review) if ctx.close_review && @review_closer
      run = finish_check(run_id, ctx.check, ctx.actor, ctx.cause) if ctx.check
      return finish_review_end(run_id, ctx.review_end, ctx.actor, ctx.cause) if ctx.review_end
      review = ctx.review
      review ? start_round(run_id, review, run) : run
    end

    # Runs what {#evaluate} registered with the run's lock given up, and whatever comes after it: a proof can be
    # followed by another proof or the `status:` check. A review round the chain's last change registered (a passed
    # step that has reviewers) runs once the chain ends.
    #
    # @param run_id [String]
    # @param check [Hash{String=>Object}] the proof or check {#evaluate} registered on its context
    # @param cause [String] the cause of that change; its results carry it too
    # @param actor [String] the actor of the change that registered the check; its results carry it too
    # @return [WorkflowRun] the run afterwards; as stored when it was cancelled while the check ran
    def finish_check(run_id, check, actor, cause)
      run = nil
      review = nil
      while check
        run, check, registered = apply_check(run_id, check, run_check(run_id, check), actor, cause)
        review = registered if registered
      end
      review ? start_round(run_id, review, run) : run
    rescue Workspace::Error => e
      # Cancelled while the check ran: there is nothing left to decide.
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    private

    # Whether the current attempt's line is the one a pause holds untyped ({WorkflowDispatch#deliver}).
    def held_delivery?(run, state)
      hold = run["pause_hold"]
      hold.is_a?(Hash) && hold["kind"] == "delivery" && hold["step"] == run["current"] && hold["attempt"] == state["attempts"].last&.fetch("n", nil)
    end

    # A turn of the attempt ended, so nothing is left to continue: the pane was working again (a person typed into
    # it, or the interrupt did not stop the turn), and the turn is decided as any other.
    def without_continue_marks(read)
      stored = read.to_h
      return read unless stored.key?("continue_pending") || stored.dig("paused", "interrupt")
      work = WorkflowRun.from_h(read).thawed
      work.delete("continue_pending")
      work["paused"].delete("interrupt") if work["paused"].is_a?(Hash)
      WorkflowRun.from_h(work)
    end

    # Puts the phase answer +changed+ (a WorkflowRun) into the run Hash being changed in place.
    def adopt(run, changed) = run.replace(changed.thawed)

    # Runs the review round a change registered, with the lock given up, once {WorkflowRoundRerun#check_revision} has
    # had a round after a rejected one judged against the revision the rejection judged: the same one stops the round
    # `review_no_change` and nothing is delivered; another is handed to the delivery, which judges that revision.
    def start_round(run_id, review, run)
      return run unless @review_round
      checked = @round_rerun ? @round_rerun.check_revision(run_id, review) : {}
      return checked[:run] if checked[:run]
      pending = checked[:revision] ? review.merge("revision" => checked[:revision]) : review
      @review_round.call(run_id, pending) || run
    rescue Workspace::Error => e
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # Computes the ended round's revision again with the lock given up, then, under the lock and only while the run
    # still waits for this recompute ({WorkflowTransitions.round_recompute_wanted?}), decides the round: a revision that can't be computed stops
    # `review_incomplete`, one that differs from the revision the round was delivered with stops `review_stale` (no
    # loop, no further round), and an unchanged one is tallied. What that decision registers is followed up in turn.
    def finish_review_end(run_id, pending, actor, cause)
      read = @store.run(run_id)
      step = read.definition["steps"].find { |each| each["id"] == pending["step"] }
      answer = @review_revision.call(run: read, step: step, stop_when: -> { !round_still_wanted?(run_id, pending) })
      follow = nil
      run = @change.call(run_id, actor: actor, cause: cause) do |current, ctx|
        next unless WorkflowTransitions.round_recompute_wanted?(current, pending)
        follow = ctx
        judge_round(current, answer, ctx)
      end
      finish_follow_ups(run_id, follow, run)
    rescue Workspace::Error => e
      raise unless e.code == "run_not_active"
      @store.run(run_id)
    end

    # The checkout against the snapshot the round began with, before anything is recomputed or tallied (a round with no
    # snapshot, begun before the guard existed or by an engine built without one, is not checked). A changed
    # checkout stops the round `review_guard` and an unreadable one `review_incomplete`, never a pass; neither loops
    # through `on_fail`, and the round's record ends `review_guard` or `review_incomplete`.
    #
    # @return [WorkflowRun, nil] the run afterwards when the round was stopped; nil when it goes on
    def round_guard(read, ctx)
      snapshot = step_state(read.to_h)["review"]&.dig("snapshot")
      return nil unless snapshot.is_a?(Hash)
      found = @guard.round_check(read.worktree, snapshot, base: read)
      return nil unless found
      tally = if found["unread"]
        {outcome: :incomplete, reviews: [], problem: "the checkout could not be compared with the round's start (#{found["unread"].join(", ")} unread)"}
      else
        {outcome: :review_guard, reviews: [], changed: found["changed"], snapshot_head: found["snapshot_head"], head: found["head"]}
      end
      @progress.decide_review(read, tally, ctx: ctx)
    end

    def judge_round(read, answer, ctx)
      work = read.thawed
      round = step_state(work)["review"]
      round.delete("recompute")
      if answer[:problem]
        return @progress.decide_review(work, {outcome: :incomplete, reviews: [], problem: "the round's revision could not be computed again: #{answer[:problem]}"}, ctx: ctx)
      end
      delivered = round["revision"]
      if delivered.is_a?(String) && !delivered.empty? && answer[:revision] != delivered
        return @progress.decide_review(work, {outcome: :stale, reviews: [], revision: delivered, revision_now: answer[:revision]}, ctx: ctx)
      end
      tally_round(WorkflowRun.from_h(work), ctx)
    end

    def tally_round(read, ctx)
      stored = read.to_h
      tally = @review_tally.call(run: read, step: step_def(stored), round: step_state(stored)["review"])
      @progress.decide_review(read, tally, ctx: ctx)
    end

    # {WorkflowTransitions.round_recompute_wanted?} read from the store, for a command running outside the lock; a run that can't be read is still wanted.
    def round_still_wanted?(run_id, pending)
      WorkflowTransitions.round_recompute_wanted?(@store.run(run_id), pending)
    rescue Workspace::Error, SystemCallError
      true
    end

    # Whether a turn's end is the end of the running round's review turn: in the round's own pane, begun no earlier
    # than the round, with the round not stopped and its end not already being judged. In a window cleared for the
    # round (one an earlier round left, `clear_from`), a turn counts when it began at or after the confirmed clear
    # (`cleared_at`, else, once the line is delivered, `clear_from`): a turn a person had there before ends with the
    # clear and is not the reviewers', and while the line is still being typed no turn counts.
    # A turn whose start the daemon does not know (it restarted during the round) counts once it stopped at or after
    # the delivery (`delivered_at`); before a delivery is recorded it does not.
    def review_turn?(run, round, pane, turn_started, stopped_at)
      return false if run["reason"] || !round.is_a?(Hash) || round["recompute"] || pane.nil? || round["pane"] != pane
      started = Time.iso8601(round["started_at"].to_s)
      return cleared_turn?(round, turn_started, stopped_at) if round["clear_from"]
      !(turn_started && turn_started < started) && !(stopped_at && stopped_at < started)
    rescue ArgumentError
      false
    end

    def cleared_turn?(round, turn_started, stopped_at)
      if turn_started
        # Until the line is delivered the clear is not known to have happened: a turn a person had in the window
        # then, begun after the clear was decided, would otherwise count.
        from = round["cleared_at"] || (round["delivered_at"] && round["clear_from"])
        return !from.nil? && turn_started >= Time.iso8601(from.to_s)
      end
      !round["delivered_at"].nil? && !stopped_at.nil? && stopped_at >= Time.iso8601(round["delivered_at"].to_s)
    rescue ArgumentError
      false
    end

    def judge(run, ctx, turn_started, background, guard: true, status_report: nil)
      step = step_def(run)
      state = step_state(run)
      attempt = state["attempts"].last
      attempt["status_report"] = status_report if status_report
      # A turn that ended on the attempt shows its line reached the agent.
      attempt.delete("delivery")
      attempt.delete("proofs")
      reported = attempt["reported"]
      if reported && reported["status"] == "fail"
        fail_step(run, {"cause" => "reported", "summary" => reported["summary"]}.merge(code_for("reported", reported["code"])), ctx)
        return
      end
      return if status_hold(run, step, state, attempt, turn_started, status_report)
      if guard && step["guard"]
        found = guard_check(run, step)
        if found
          fail_step(run, found, ctx)
          return
        end
      end
      files = step["produces"].map { |file| File.join(run["artifacts_dir"], file) }
      strict = WorkflowProduced.strict?(run["definition"])
      found = files.to_h { |file| [file, WorkflowProduced.inspect_file(file, strict: strict)] }
      missing = files.reject { |file| found[file].exists }
      invalid = files.select { |file| found[file].exists && found[file].rule }.map { |file| {"file" => file, "rule" => found[file].rule} }
      # A file an earlier attempt left does not count: the step has to write it again.
      started = Time.iso8601(attempt["started_at"])
      stale = files.select { |file| found[file].exists && found[file].rule.nil? && found[file].mtime < started }
      if missing.any? || invalid.any? || stale.any?
        state["state"] = "running"
        run["state"] = "waiting"
        details = {"step" => step["id"], "attempt" => attempt["n"], "missing" => missing, "stale" => stale}
        details["invalid"] = invalid if invalid.any?
        run["reason"] = if background.any? || stated_running?(attempt, status_report)
          # Every notification starts a new turn and a hold is hidden, so its `since` stays. A turn that says it is
          # still running, with no task listed, waits the same way: the next turn or the sweep decides it.
          stop_reason(run["reason"], nil, "turn_ended_background", details.merge("tasks" => background)).merge("seen_at" => now_iso)
        else
          stop_reason(run["reason"], turn_started, "turn_ended_incomplete", details)
        end
        return
      end
      require_and_status(run, step, state, attempt, ctx)
    end

    # Only the current turn's +stated+ report counts, never the one stored on the attempt from an earlier turn: a
    # resume, the sweep and recovery judge with none and must see none.
    #
    # A stated `needs_input` or `stuck` holds the run with `waiting_agent_input`, whatever the checks would say. An
    # out-of-band `reported` outcome wins over the line, so a step with one is never held by it. The step stays
    # `running`; a resume decides it as a turn's end would.
    #
    # @return [Boolean] whether the run was held
    def status_hold(run, step, state, attempt, turn_started, stated)
      return false if attempt["reported"] || !stated.is_a?(Hash) || !%w[needs_input stuck].include?(stated["state"])
      state["state"] = "running"
      run["state"] = "waiting"
      details = {"step" => step["id"], "attempt" => attempt["n"], "state" => stated["state"], "detail" => stated["detail"].to_s}
      run["reason"] = stop_reason(run["reason"], turn_started, "waiting_agent_input", details)
      record_ask(run, attempt, stated)
      true
    end

    # A stated `needs_input` with a detail records one `workspace ask` entry, so it shows in `sessions` and the derived
    # inbox rows. `asked_input` on the attempt keeps a repeat judging of the same hold from recording another; it is
    # set only once the entry is written. `stuck` states a reason, not a question, so it records none.
    def record_ask(run, attempt, stated)
      return unless @ask_for && stated["state"] == "needs_input" && !attempt["asked_input"]
      question = stated["detail"].to_s.strip
      return if question.empty?
      @ask_for.call(run["workspace"]).add(question: question, default: ASK_DEFAULT, pane: run["pane"], worktree: run["worktree"])
      attempt["asked_input"] = true
    rescue Workspace::Error, SystemCallError
      nil
    end

    # Whether the turn that just ended said `running` and no out-of-band report overrides it.
    def stated_running?(attempt, stated)
      !attempt["reported"] && stated.is_a?(Hash) && stated["state"] == "running"
    end

    # What comes after the step's files: its `require:` entries from +from+ in order, then its `status:`
    # check. Registers the next thing to run outside the lock (a proof or the check) on +ctx+; none once the step is decided.
    def require_and_status(run, step, state, attempt, ctx, from: 0)
      if step["require"].to_a.any?
        unmet = @require_check.check(run: run, step: step, attempt: attempt, from: from)
        while unmet&.key?("skipped")
          skipped = unmet["skipped"]
          (attempt["proofs"] ||= []).reject! { |each| each["skipped"] && each["index"] == skipped["index"] }
          attempt["proofs"] << skipped.merge("started_at" => now_iso, "ended_at" => now_iso)
          unmet = @require_check.check(run: run, step: step, attempt: attempt, from: skipped["index"] + 1)
        end
        if unmet&.key?("outside")
          ctx.check(start_proof(run, step, state, attempt, unmet["outside"]))
          return
        end
        if unmet
          fail_step(run, WorkflowTransitions.require_failure(unmet), ctx)
          return
        end
      end
      unless step["status"]
        adopt(run, pass_step(run, ctx))
        return
      end

      command = step["status"]["run"] || @commands_config.for_project(run["project"])[step["status"]["command"].to_sym]
      log = File.join(run["artifacts_dir"], "steps", "#{step["id"]}.#{attempt["n"]}.check.log")
      attempt["check"] = {"started_at" => now_iso, "log" => log}
      attempt["check"]["command"] = command if command
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      ctx.check({"step" => step["id"], "attempt" => attempt["n"], "command" => command, "timeout" => step["status"]["timeout"], "log" => log,
                 "cwd" => run["worktree"], "role" => step["status"]["command"]})
    end

    # A proof takes the step to `checking` like a `status:` check, so a resume, a cancel, a tick and {#wanted?}
    # treat it as one. Its record stays open (no `ended_at`) until it is applied, or a next {#evaluate} starts over.
    # A proof's {WorkflowRequire::FACTS_KEY} (what an `exec` proof read of the run under the lock) goes to {WorkflowRequire#run_outside} only.
    def start_proof(run, step, state, attempt, pending)
      (attempt["proofs"] ||= []) << pending.except(WorkflowRequire::FACTS_KEY).merge("started_at" => now_iso)
      state["state"] = "checking"
      run["state"] = "running"
      run["reason"] = nil
      {"step" => step["id"], "attempt" => attempt["n"], "cwd" => run["worktree"], "proof" => pending}
    end

    def run_check(run_id, check)
      stop_when = -> { !wanted?(run_id, check) }
      return @require_check.run_outside(check["proof"], cwd: check["cwd"], env: check_env(run_id), stop_when: stop_when) if check["proof"]
      return {exit_code: nil, timed_out: false, error: "the project's #{check["role"]} command is not set"} unless check["command"]
      @checker.call(command: check["command"], cwd: check["cwd"], timeout: check["timeout"], log: check["log"], stop_when: stop_when, env: check_env(run_id))
    end

    # What a `status:` check is told about its run. `WORKSPACE_RUN_BASE_SHA` is
    # empty for a run with no recorded commit (an unborn branch, or a run made before it was kept).
    # Every inherited `GIT_*` variable is removed, so a caller's `GIT_DIR`, `GIT_INDEX_FILE` or
    # `GIT_CONFIG_*` can't steer the check.
    def check_env(run_id)
      WorkflowCheck.env_for(@store.run(run_id))
    end

    # Whether the run still waits for this check: it is still on that step and
    # attempt, checking. A cancel, a kill or a `resume --from` ends that, and
    # the check is stopped instead of running on beside the lock's next holder.
    # So does a park: only a `--from` parks over a check, and that restarts the step. So does a proof run again.
    def wanted?(run_id, check)
      run = @store.run(run_id)
      step = run.steps.fetch(check["step"])
      attempt = step.last_attempt
      !run.parked && !WorkflowRunStore::TERMINAL_STATES.include?(run.state) && run.current == check["step"] &&
        step.state == "checking" && attempt.n == check["attempt"] &&
        (!check["proof"] || !open_proof(attempt.to_h, check).nil?)
    rescue Workspace::Error, SystemCallError
      true
    end

    # @return [Array] the run afterwards, and what to run next outside the lock, or nil
    def apply_check(run_id, check, result, actor, cause)
      following = nil
      review = nil
      run = @change.call(run_id, actor: actor, cause: cause) do |read, ctx|
        next if read.parked
        stored = read.thawed
        state = step_state(stored)
        attempt = state["attempts"].last
        # The run moved on while the check ran (a resume, a reject): its result decides nothing.
        next unless stored["current"] == check["step"] && state["state"] == "checking" && attempt["n"] == check["attempt"]
        if check["proof"]
          apply_proof(stored, attempt, check, result, ctx)
          following = ctx.check
          review = ctx.review
          next WorkflowRun.from_h(stored)
        end
        attempt["check"].merge!("ended_at" => now_iso, "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
          "error" => result[:error]).compact!
        event(stored, "check_finished", "step" => check["step"], "attempt" => check["attempt"], "exit_code" => result[:exit_code])
        if result[:exit_code] == 0
          passed = pass_step(stored, ctx)
          review = ctx.review
          next passed
        end
        code = if result[:timed_out]
          "check_timed_out"
        else
          result[:error] ? "check_error" : "check_failed"
        end
        failure = {"cause" => "check", "exit_code" => result[:exit_code], "timed_out" => result[:timed_out],
                   "error" => result[:error], "log" => check["log"]}.compact.merge(code_for(code, nil))
        if code == "check_failed"
          failure = failure.merge(reported_check_code(step_def(stored)["status"], check["log"]) || {})
        end
        @progress.fail_step(stored, failure, ctx: ctx)
      end
      [run, following, review]
    end

    # Records a proof's result; a passed one goes on to the next `require:` entry. A proof run again (a tick or a
    # resume took it for lost) has a new token, so a late result of the old run matches nothing and is dropped.
    def apply_proof(run, attempt, check, result, ctx)
      record = open_proof(attempt, check)
      return unless record
      record.merge!(result["record"].merge("ended_at" => now_iso))
      unmet = result["unmet"]
      event(run, "proof_finished", "step" => check["step"], "attempt" => check["attempt"], "proof" => record["proof"], "passed" => unmet.nil?)
      if unmet
        fail_step(run, WorkflowTransitions.require_failure(unmet), ctx)
        return
      end
      require_and_status(run, step_def(run), step_state(run), attempt, ctx, from: check["proof"]["index"] + 1)
    end

    def open_proof(attempt, check)
      Array(attempt["proofs"]).find { |each| each["token"] == check["proof"]["token"] && !each.key?("ended_at") }
    end

    def fail_step(run, failure, ctx)
      adopt(run, @progress.fail_step(run, failure, ctx: ctx))
    end

    # An attempt whose guard stop a person accepted ended already: it passes `overridden`, with no second finish.
    def pass_step(run, ctx)
      return @progress.pass_overridden(run, ctx: ctx) if step_state(run)["attempts"].last["guard_accepted"]
      @progress.pass_step(run, ctx: ctx)
    end

    def guard_check(run, step)
      found = @guard.check(run["worktree"], run, step["guard"])
      note_config_change(run, step)
      return nil unless found
      {"cause" => "guard", "guard" => found["code"], "paths" => found["paths"], "base_sha" => found["base_sha"], "head" => found["head"]}
        .compact.merge(code_for(found["code"], nil))
    rescue => e
      {"cause" => "check", "error" => "the guard could not run (#{e.class})"}.merge(code_for("check_error", nil))
    end

    # A changed repository config is a warning and the step goes on. `guard_config_seen` holds the reading last
    # warned of, so each distinct change warns once, on the attempt that first saw it, whatever steps follow; a
    # config back at the base's reading clears it. It is set only once the attempt holds the warning, so one that
    # could not be recorded is tried again at the next guarded step. A warning that can't be recorded must not stop the step.
    def note_config_change(run, step)
      found = @guard.config_change(run["worktree"], run, seen: run["guard_config_seen"])
      return unless found
      return run.delete("guard_config_seen") unless found["code"]
      attempt = step_state(run)["attempts"].last
      (attempt["warnings"] ||= []) << {"code" => found["code"], "at" => now_iso, "message" => config_warning(found)}
      run["guard_config_seen"] = found["reading"]
      event(run, "guard_warning", "step" => step["id"], "attempt" => attempt["n"], "code" => found["code"], "inbox" => post_config_warning(run, step, attempt, found))
    rescue
      nil
    end

    def config_warning(found)
      return "this run started before the config was read this way, so the difference may be no change at all; the run went on" if found["old_format"]
      "#{WorkflowTransitions::GUARD_TEXT.fetch(found["code"])}; the run went on"
    end

    # One item per run, whatever the number of changes; a later change opens it again if it was closed. Under the run's lock, as `inbox_item` reads.
    #
    # @return [Boolean] whether the item was written
    def post_config_warning(run, step, attempt, found)
      return false unless @inbox_for
      workspace = run["workspace"]
      @inbox_for.call(workspace).upsert({
        "type" => "alert", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
        "title" => "Workflow run #{run["id"]}: the repository's config changed",
        "body" => "At step #{step["id"]} (attempt #{attempt["n"]}): #{config_warning(found)}. Check `git -C #{run["worktree"]} config --list` if you did not expect it; `workspace workflow status #{run["id"]}` lists every warning.",
        "source" => {"kind" => "workflow", "ref" => run["id"], "url" => nil},
        "dedupe_key" => "workflow-guard:#{run["id"]}:#{found["code"]}",
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"run_id" => run["id"], "step" => step["id"], "attempt" => attempt["n"]}, "expires_at" => nil, "note" => nil
      }, reopen: true)
      true
    rescue Workspace::Error, SystemCallError
      false
    end

    # A step whose `status:` sets `report_code: true` may name its own failure code in the log's
    # last `code: <name>` line, so a check can tell one failure from another (a plan edited during
    # review from an ordinary rejected vote). A code the engine already hands out never comes from
    # a log, and a log whose tail names none leaves the plain `check_failed` standing. The tail is
    # read as a plain file, never through a link, and nothing here raises.
    def reported_check_code(status, log)
      return nil unless status.is_a?(Hash) && status["report_code"] == true
      line = check_log_last_line(log).to_s.strip
      match = line.match(/\Acode: (\S+)\z/)
      return nil if match.nil? || ENGINE_CODES.include?(match[1])
      {"code" => match[1], "code_source" => "check"}
    end

    def check_log_last_line(log)
      return nil unless log.is_a?(String)
      file = File.lstat(log)
      return nil unless file.file?
      opened = File.open(log, "rb")
      opened.seek([0, file.size - CHECK_CODE_TAIL_BYTES].max)
      opened.read.to_s.lines.reverse.find { |each| !each.strip.empty? }
    rescue SystemCallError, IOError
      nil
    ensure
      opened&.close
    end

    def stop_reason(stored, turn_started, code, details) = WorkflowTransitions.stop_reason(stored, turn_started, code, details, now_iso)

    def code_for(engine_code, agent_code) = WorkflowTransitions.code_for(engine_code, agent_code)

    def event(run, type, data = {}) = @change.event(run, type, data)

    def bound_pane(run)
      @panes.pane_of(run["id"]) || run["pane"]
    end

    def step_def(run)
      run["definition"]["steps"].find { |step| step["id"] == run["current"] }
    end

    def step_state(run)
      run["steps"].fetch(run["current"])
    end

    # The status line the last assistant message of +path+ ends with, as the attempt stores it; nil when there is no reader,
    # no path, no message or no line.
    def read_status_report(path)
      return nil unless @transcript && path
      message = @transcript.last_assistant_message(path)
      parsed = WorkflowReportedStatus.parse(message && message["text"])
      parsed && {"state" => parsed[:state], "detail" => parsed[:detail], "at" => now_iso}
    end

    def now_iso
      @clock.call.utc.iso8601
    end
  end
end
