require "spec_helper"

RSpec.describe Workspace::WorkflowProgress do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new(going: going) }
  let(:going) { [] }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:dispatch) { RecordingDispatch.new }
  let(:attempt_record) { RecordingAttemptRecord.new }
  let(:panes) { RecordingWorkflowPanes.new }
  let(:log_tail) { RecordingLogTail.new }

  subject(:progress) do
    described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })
  end

  def steps(**overrides)
    [{"id" => "plan", "produces" => ["plan.md"]}.merge(overrides), {"id" => "build", "produces" => []}]
  end

  def run_hash(definition_steps: steps, **overrides)
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => "/work", "artifacts_dir" => "/work/.workflow/wr_1",
     "state" => "running", "current" => "plan", "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => nil,
     "definition" => {"id" => "flow", "max_attempts" => 5, "steps" => definition_steps},
     "steps" => {"plan" => {"state" => "checking", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00.000Z"}]},
                 "build" => {"state" => "pending", "attempts" => []}}}.merge(overrides)
  end

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def ctx = Workspace::WorkflowRunChange::Context.new

  describe "#pass_step" do
    it "ends the attempt as passed with what the record adds, and starts the next step, leaving the run given alone" do
      given = run_hash
      before = deep_copy(given)
      context = ctx

      run = progress.pass_step(given, ctx: context)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(before)
      expect(run.step("plan").state).to eq("passed")
      expect(run.step("plan").last_attempt.to_h).to eq("n" => 1, "started_at" => "2026-11-10T11:00:00.000Z", "ended_at" => "2026-11-10T12:00:00Z",
        "outcome" => "passed", "outputs" => [])
      expect(run.current).to eq("build")
      expect(context.delivery).to eq("step" => "build")
      expect(attempt_record.calls).to eq([[:finish, "wr_1", "plan", 1]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}]])
      expect(change.events).to eq([["wr_1", "step_passed", {"step" => "plan", "attempt" => 1}]])
    end

    it "waits at the step's gate for a person, with its locks given up" do
      context = ctx

      run = progress.pass_step(run_hash(definition_steps: steps("gate" => "approve")), ctx: context)

      expect(run.current).to eq("plan")
      expect(run.step("plan").to_h["gate"]).to eq("state" => "waiting", "since" => "2026-11-10T12:00:00Z")
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "waiting_you", "since" => "2026-11-10T12:00:00Z",
        "details" => {"kind" => "gate", "step" => "plan", "artifacts" => ["/work/.workflow/wr_1/plan.md"]})
      expect(context.delivery).to be_nil
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
      expect(change.events.map { |event| event[1] }).to eq(%w[step_passed gate_waiting])
    end
  end

  describe "#advance" do
    it "starts the step after the current one" do
      run = progress.advance(run_hash, ctx: ctx)

      expect(run.current).to eq("build")
      expect(dispatch.calls.map(&:first)).to eq([:dispatch])
    end

    it "completes the run after its last step" do
      run = progress.advance(run_hash("current" => "build"), ctx: ctx)

      expect(run.state).to eq("completed")
      expect(run.to_h["ended_at"]).to eq("2026-11-10T12:00:00Z")
      expect(change.events).to eq([["wr_1", "run_completed", {}]])
    end
  end

  describe "#finish" do
    it "drops the park, the retry wait and the budget hold, gives up the locks and frees the pane" do
      run = progress.finish(run_hash("parked" => {"id" => "p1"}, "backoff" => {"to" => "plan"}, "budget_hold" => {}, "timeout_hold" => {}, "reason" => {"code" => "waiting_you"}), "cancelled")

      expect(run.to_h).not_to include("parked", "backoff", "budget_hold", "timeout_hold")
      expect(run.to_h).to include("state" => "cancelled", "reason" => nil, "ended_at" => "2026-11-10T12:00:00Z")
      expect(dispatch.calls).to eq([[:drop_park, "wr_1", "ended", {}], [:release, "wr_1"]])
      expect(panes.calls).to eq([[:unbind, "wr_1"]])
    end
  end

  describe "#fail_step" do
    let(:failure) { {"cause" => "check", "exit_code" => 1, "log" => "/work/check.log", "code" => "check_failed", "code_source" => "engine"} }

    it "stops the run for a person when the step has no on_fail" do
      run = progress.fail_step(run_hash, failure, ctx: ctx)

      expect(run.step("plan").state).to eq("failed")
      expect(run.step("plan").last_attempt.to_h).to include("ended_at" => "2026-11-10T12:00:00Z", "outcome" => "failed", "code" => "check_failed", "outputs" => [])
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "failed_check", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "loops" => {}, "attempts" => 1, "max_attempts" => 5}.merge(failure))
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
      expect(change.events).to eq([["wr_1", "step_failed", {"step" => "plan", "attempt" => 1, "cause" => "check", "exit_code" => 1}]])
    end

    it "goes back along on_fail at once, telling the target step what failed with the log's tail" do
      on_fail = {"goto" => "plan", "max" => 2, "context" => "fresh", "log_tail" => 20}
      context = ctx

      run = progress.fail_step(run_hash(definition_steps: steps("on_fail" => on_fail)), failure, ctx: context)

      text = "The plan step failed and sent the run back to this step (time 1 of 2): #{Workspace::WorkflowTransitions.failure_text(failure)}. " \
        "Its files are in /work/.workflow/wr_1. Fix what it found.\n\nthe last 20 lines of /work/check.log"
      expect(run.to_h["loops"]).to eq("plan->plan" => 1)
      expect(run.pending_context).to eq([text])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: "fresh", budgeted: true, retry_of: {"text" => text}}]])
      expect(log_tail.calls).to eq([[:block, "/work/check.log", {lines: 20}]])
      expect(context.delivery).to eq("step" => "plan")
      expect(change.events.last).to eq(["wr_1", "step_looped", {"from" => "plan", "to" => "plan", "count" => 1}])
    end

    it "waits out an on_fail backoff with nothing held, keeping the pane it began in" do
      panes = RecordingWorkflowPanes.new(bound: {"wr_1" => "%4"})
      progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })
      on_fail = {"goto" => "plan", "max" => 2, "backoff" => 30}
      context = ctx

      run = progress.fail_step(run_hash(definition_steps: steps("on_fail" => on_fail)), failure.except("log"), ctx: context)

      expect(run.backoff).to include("until" => "2026-11-10T12:00:30Z", "to" => "plan", "pane" => "%4", "identity" => "identity-of-wr_1")
      expect(run.reason).to include("code" => "retry_backoff")
      expect(run.reason["details"]).to include("until" => "2026-11-10T12:00:30Z", "seconds" => 30)
      expect(run.state).to eq("waiting")
      expect(context.delivery).to be_nil
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
      expect(panes.calls).to eq([[:unbind, "wr_1"]])
    end

    it "stops with details.limit step when the loop's target step has spent its own cap" do
      definition = [{"id" => "plan", "max_attempts" => 1, "produces" => []}, {"id" => "build", "produces" => [], "on_fail" => {"goto" => "plan", "max" => 3}}]
      run = run_hash(:definition_steps => definition, "current" => "build")
      run["steps"]["plan"]["attempts"] = [{"n" => 1, "ended_at" => "2026-11-10T11:00:00Z"}]
      run["steps"]["build"] = {"state" => "checking", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:30:00.000Z"}]}

      run = progress.fail_step(run, failure, ctx: ctx)

      expect(run.state).to eq("waiting")
      expect(run.reason["code"]).to eq("failed_check")
      expect(run.reason["details"]).to include("step" => "build", "limit" => "step", "limit_step" => "plan")
      expect(run.to_h["loops"]).to eq({})
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
    end

    it "stops instead of looping on a code on_fail excepts" do
      on_fail = {"goto" => "plan", "max" => 2, "except" => ["check_failed"]}

      run = progress.fail_step(run_hash(definition_steps: steps("on_fail" => on_fail)), failure, ctx: ctx)

      expect(run.reason["code"]).to eq("failed_check")
      expect(dispatch.calls.map(&:first)).to eq([:release])
    end
  end

  describe "#start_retry" do
    let(:waiting) { {"until" => "2026-11-10T11:59:00Z", "to" => "plan", "context" => "fresh", "text" => "it failed", "pane" => "%3", "identity" => "id-3"} }

    it "takes the run's wait off it and starts the target step with the kept text" do
      context = ctx

      run = progress.start_retry(run_hash("backoff" => waiting, "reason" => {"code" => "retry_backoff"}), ctx: context)

      expect(run.backoff).to be_nil
      expect(run.pending_context).to eq(["it failed"])
      expect(run.reason).to be_nil
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: "fresh", budgeted: true, retry_of: {"pane" => "%3", "identity" => "id-3", "text" => "it failed"}}]])
      expect(panes.calls).to eq([[:same_pane?, "%3", "id-3"]])
      expect(change.events).to eq([["wr_1", "step_retry_started", {"from" => "plan", "to" => "plan"}]])
    end

    it "holds the retry when its pane is gone, keeping the wait marked blocked" do
      panes = RecordingWorkflowPanes.new(gone: ["%3"])
      progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })

      run = progress.start_retry(run_hash("backoff" => waiting), ctx: ctx)

      expect(run.backoff).to eq(waiting.merge("blocked" => "pane_gone"))
      expect(run.reason["code"]).to eq("pane_gone")
      expect(dispatch.calls).to be_empty
    end

    it "starts a wait already taken off the run in a pane a person named, without comparing it" do
      progress.start_retry(run_hash, waiting.merge("pane" => nil), ctx: ctx, proven: true, budgeted: false)

      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: "fresh", budgeted: false, retry_of: {"pane" => nil, "identity" => "id-3", "text" => "it failed"}}]])
      expect(panes.calls).to be_empty
    end
  end

  describe "#hold_retry" do
    let(:waiting) { {"to" => "plan", "pane" => "%3"} }
    let(:problem) { {code: "pane_changed", message: "pane %3 can't be shown to be the pane the run was in (it may be fine)"} }

    it "makes the run wait for a person, naming the pane, and writes step_retry_blocked" do
      run = progress.hold_retry(run_hash, waiting, problem, pane: "%5")

      expect(run.backoff).to eq(waiting.merge("blocked" => "pane_changed"))
      expect(run.reason).to eq("code" => "waiting_you", "since" => "2026-11-10T12:00:00Z",
        "details" => {"kind" => "dispatch", "step" => "plan", "pane" => "%5", "workspace" => "app", "error" => "pane_changed",
                      "message" => "the retry of step plan was not started: #{problem[:message]}. Or cancel the run."})
      expect(change.events).to eq([["wr_1", "step_retry_blocked", {"from" => "plan", "to" => "plan", "code" => "pane_changed"}]])
    end

    it "changes nothing for the same hold again" do
      held = progress.hold_retry(run_hash, waiting, problem)
      change.events.clear

      expect(progress.hold_retry(held, waiting, problem)).to eq(held)
      expect(change.events).to be_empty
    end
  end

  describe "#retry_pane_problem" do
    it "names another run still going on the pane" do
      panes = RecordingWorkflowPanes.new(runs_on: {"%3" => "wr_9"})
      going << "wr_9"
      progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })

      expect(progress.retry_pane_problem(run_hash, {"pane" => "%3"})).to eq(code: "pane_has_run",
        message: "pane %3 is now running workflow run wr_9. Name another agent pane with `workflow resume --pane PANE`")
    end

    it "says a pane that does not look like the one the wait began in has changed, and nothing for one that does" do
      panes = RecordingWorkflowPanes.new(same: false)
      progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })

      expect(progress.retry_pane_problem(run_hash, {"pane" => "%3", "identity" => "id-3"})[:code]).to eq("pane_changed")
      expect(described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: RecordingWorkflowPanes.new, log_tail: log_tail)
        .retry_pane_problem(run_hash, {"pane" => "%3", "identity" => "id-3"})).to be_nil
    end
  end

  describe "a step with a review" do
    let(:review) { {"from" => %w[skeptic tester], "need" => 2, "must" => [], "max_rounds" => 6} }

    def reviewing_hash(**overrides)
      run_hash(:definition_steps => steps("review" => review), "state" => "running").tap do |hash|
        hash["steps"]["plan"] = {"state" => "reviewing", "review_rounds" => 1,
                                 "review" => {"round" => 1, "delivery" => nil, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "pending" => %w[skeptic tester], "redeliveries" => 0},
                                 "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00.000Z", "ended_at" => "2026-11-10T11:20:00Z", "outcome" => "checks_passed", "outputs" => []}]}
      end.merge(overrides)
    end

    it "ends the attempt as checks_passed and starts round 1 of the review instead of passing" do
      context = ctx

      run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: context)

      state = run.step("plan")
      expect(run.current).to eq("plan")
      expect(run.state).to eq("running")
      expect(run.reason).to be_nil
      expect(state.state).to eq("reviewing")
      expect(state.last_attempt.to_h).to eq("n" => 1, "started_at" => "2026-11-10T11:00:00.000Z", "ended_at" => "2026-11-10T12:00:00Z",
        "outcome" => "checks_passed", "outputs" => [])
      expect(state.review_rounds).to eq(1)
      expect(state.review).to eq("round" => 1, "delivery" => "delivering", "started_at" => "2026-11-10T12:00:00.000Z", "pending" => %w[skeptic tester], "redeliveries" => 0)
      expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
      expect(context.delivery).to be_nil
      expect(attempt_record.calls).to eq([[:finish, "wr_1", "plan", 1]])
      expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 1}]])
      expect(change.events.map { |event| event[1] }).to eq(%w[step_checks_passed review_started])
    end

    it "counts each round the step starts, never resetting" do
      given = run_hash(definition_steps: steps("review" => review))
      given["steps"]["plan"]["review_rounds"] = 2

      run = progress.pass_step(given, ctx: ctx)

      expect(run.step("plan").review_rounds).to eq(3)
      expect(run.step("plan").review["round"]).to eq(3)
    end

    describe "the round's directory" do
      it "is made by the tally as the round starts, before the round is registered" do
        tally = RecordingReviewTally.new
        context = ctx

        progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_tally: tally, clock: -> { now })
        progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: context)

        expect(tally.calls).to eq([[:open_round, "wr_1", 1]])
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
      end

      it "already there stops the run review_tampered, the round spent and recorded, and a resume starts a fresh one" do
        tally = RecordingReviewTally.new(opened: {code: "review_tampered", problem: "it was there"})
        progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_tally: tally, clock: -> { now })
        context = ctx

        run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: context)

        state = run.step("plan")
        expect(context.review).to be_nil
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "review_tampered", "details" => {"step" => "plan", "attempt" => 1, "round" => 1, "problem" => "it was there"})
        expect(state.state).to eq("reviewing")
        expect(state.review_rounds).to eq(1)
        expect(state.review).to include("round" => 1, "delivery" => nil, "recorded" => true, "ended_at" => "2026-11-10T12:00:00Z")
        expect(state.last_attempt.to_h["rounds"].map { |each| each.slice("round", "ended") }).to eq([{"round" => 1, "ended" => "review_tampered"}])
        expect(change.events.last).to eq(["wr_1", "review_ended", {"step" => "plan", "attempt" => 1, "round" => 1, "outcome" => "review_tampered"}])

        resumed = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_tally: RecordingReviewTally.new, clock: -> { now })
        again = ctx
        after = resumed.restart_review(run, ctx: again)

        expect(after.step("plan").review_rounds).to eq(2)
        expect(after.step("plan").last_attempt.to_h["rounds"].size).to eq(1)
        expect(again.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
      end

      it "is not made for a held round" do
        tally = RecordingReviewTally.new
        progress = described_class.new(change: change, store: store, dispatch: RecordingDispatch.new(holds: "budget_spent"), attempt_record: attempt_record,
          panes: panes, log_tail: log_tail, review_tally: tally, clock: -> { now })

        progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)

        expect(tally.calls).to be_empty
      end
    end

    it "passes an attempt a round already decided without reviewing it again" do
      given = run_hash(definition_steps: steps("review" => review))
      given["steps"]["plan"]["attempts"][0]["review_outcome"] = {"round" => 1, "passed" => true}
      context = ctx

      run = progress.pass_step(given, ctx: context)

      expect(run.step("plan").state).to eq("passed")
      expect(run.current).to eq("build")
      expect(context.review).to be_nil
    end

    it "rewrites an approved round's attempt as passed, without finishing it again, and goes on to the next step" do
      reviews = [{"reviewer" => "skeptic", "verdict" => "approve"}]
      recorded = [{"reviewer" => "skeptic", "verdict" => "approve", "isolation" => "review_pane"}]
      context = ctx

      run = progress.decide_review(reviewing_hash, {outcome: :approved, reviews: reviews, approvals: 2, need: 2, must: []}, ctx: context)

      expect(run.step("plan").state).to eq("passed")
      expect(run.step("plan").review).to be_nil
      expect(run.step("plan").review_rounds).to eq(1)
      expect(run.step("plan").last_attempt.to_h).to include("outcome" => "passed", "reviews" => recorded, "ended_at" => "2026-11-10T11:20:00Z",
        "review_outcome" => {"round" => 1, "approvals" => 2, "need" => 2, "must" => [], "passed" => true})
      expect(run.step("plan").last_attempt.to_h["rounds"]).to eq([{"round" => 1, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "ended_at" => "2026-11-10T12:00:00Z",
                                                                   "session" => nil, "agent" => nil, "usage" => nil, "ended" => "approved", "reviews" => recorded}])
      # The round is recorded; the attempt is not finished a second time.
      expect(attempt_record.calls).to eq([[:finish_round, "wr_1", 1]])
      expect(run.current).to eq("build")
      expect(context.delivery).to eq("step" => "build")
      expect(change.events.map { |event| event[1] }).to eq(%w[review_ended step_passed])
      expect(change.events.first).to eq(["wr_1", "review_ended", {"step" => "plan", "attempt" => 1, "round" => 1, "outcome" => "approved"}])
    end

    it "waits at the gate after an approved round" do
      given = reviewing_hash
      given["definition"]["steps"][0]["gate"] = "approve"

      run = progress.decide_review(given, {outcome: :approved, reviews: []}, ctx: ctx)

      expect(run.state).to eq("waiting")
      expect(run.reason["code"]).to eq("waiting_you")
      expect(run.step("plan").to_h["gate"]).to eq("state" => "waiting", "since" => "2026-11-10T12:00:00Z")
    end

    it "fails a rejected round's attempt and step and stops the run with review_rejected" do
      reviews = [{"reviewer" => "skeptic", "verdict" => "reject", "isolation" => "review_pane"}]

      run = progress.decide_review(reviewing_hash, {outcome: :rejected, reviews: [{"reviewer" => "skeptic", "verdict" => "reject"}]}, ctx: ctx)

      expect(run.step("plan").state).to eq("failed")
      expect(run.step("plan").review).to be_nil
      expect(run.step("plan").last_attempt.to_h).to include("outcome" => "failed", "code" => "review_rejected", "reviews" => reviews,
        "review_outcome" => {"round" => 1, "approvals" => nil, "need" => nil, "must" => nil, "passed" => false})
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "review_rejected", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "round" => 1, "reviews" => reviews})
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
      expect(run.step("plan").last_attempt.to_h["rounds"].map { |each| each.slice("round", "ended", "reviews") }).to eq([{"round" => 1, "ended" => "rejected", "reviews" => reviews}])
      expect(attempt_record.calls).to eq([[:finish_round, "wr_1", 1]])
    end

    it "keeps an incomplete round's step reviewing and its attempt checks_passed, and stops with review_incomplete" do
      run = progress.decide_review(reviewing_hash, {outcome: :incomplete, reviews: [], problem: "no verdict from tester"}, ctx: ctx)

      state = run.step("plan")
      expect(state.state).to eq("reviewing")
      expect(state.last_attempt.outcome).to eq("checks_passed")
      expect(state.review).to include("round" => 1, "delivery" => nil, "ended_at" => "2026-11-10T12:00:00Z", "reviews" => [], "recorded" => true)
      expect(state.last_attempt.to_h["rounds"].map { |each| each.slice("round", "ended", "reviews") }).to eq([{"round" => 1, "ended" => "incomplete", "reviews" => []}])
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "review_incomplete", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "round" => 1, "reviews" => [], "problem" => "no verdict from tester"})
    end

    it "stops a stale round with review_stale, keeping the step reviewing and registering no further round" do
      context = ctx
      run = progress.decide_review(reviewing_hash, {outcome: :stale, reviews: [], revision: "rev1", revision_now: "rev2"}, ctx: context)

      state = run.step("plan")
      expect(state.state).to eq("reviewing")
      expect(state.review).to include("recorded" => true)
      expect(state.last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["stale"])
      expect(run.reason).to eq("code" => "review_stale", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "round" => 1, "revision" => "rev1", "revision_now" => "rev2"})
      expect(context.review).to be_nil
      expect(context.delivery).to be_nil
    end

    describe "#end_round" do
      let(:attempt_record) { RecordingAttemptRecord.new(round_usage: {"input_tokens" => 40, "output_tokens" => 2}) }

      it "records the round with its usage on the reviewed attempt, unbinds the reviewer and registers the window to close" do
        given = reviewing_hash
        before = deep_copy(given)
        context = ctx

        run = progress.end_round(given, how: "cancelled", ctx: context)

        expect(given).to eq(before)
        state = run.step("plan")
        expect(state.review).to be_nil
        expect(state.state).to eq("reviewing")
        expect(state.review_rounds).to eq(1)
        expect(state.last_attempt.outcome).to eq("checks_passed")
        expect(state.last_attempt.to_h["rounds"]).to eq([{"round" => 1, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "ended_at" => "2026-11-10T12:00:00Z",
                                                          "session" => nil, "agent" => nil, "usage" => {"input_tokens" => 40, "output_tokens" => 2}, "ended" => "cancelled"}])
        expect(attempt_record.calls).to eq([[:finish_round, "wr_1", 1]])
        expect(panes.calls).to eq([[:unbind, "wr_1", {role: "reviewer"}]])
        expect(context.close_review).to eq("step" => "plan", "round" => 1, "pane" => "%9")
        expect(change.events).to eq([["wr_1", "review_ended", {"step" => "plan", "attempt" => 1, "round" => 1, "outcome" => "cancelled"}]])
      end

      it "copies the verdict rows an ended round read, and writes no second review_ended for it" do
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("ended_at" => "2026-11-10T11:40:00Z", "reviews" => [{"reviewer" => "skeptic", "verdict" => "approve"}])

        run = progress.end_round(given, how: "resumed", ctx: ctx, close: false)

        expect(run.step("plan").last_attempt.to_h["rounds"].last).to include("ended" => "resumed",
          "reviews" => [{"reviewer" => "skeptic", "verdict" => "approve", "isolation" => "review_pane"}])
        expect(change.events).to be_empty
        expect(panes.calls).to be_empty
      end

      it "adds the verdict copies to the reviewed attempt's evidence after what is there, and keeps them out of the round record" do
        copy = {"name" => "plan.1.r1.review.skeptic.md", "kind" => "review", "sha256" => "abc", "bytes" => 3}
        progress = described_class.new(change: change, store: store, dispatch: dispatch, panes: panes, log_tail: log_tail, clock: -> { now },
          attempt_record: RecordingAttemptRecord.new(round_evidence: [copy]))
        given = reviewing_hash
        prompt = {"name" => "plan.1.prompt.md", "kind" => "prompt", "sha256" => "def", "bytes" => 9}
        given["steps"]["plan"]["attempts"][0]["evidence"] = [prompt]

        run = progress.decide_review(given, {outcome: :approved, reviews: [{"reviewer" => "skeptic", "verdict" => "approve"}]}, ctx: ctx)

        attempt = run.step("plan").last_attempt.to_h
        expect(attempt["evidence"]).to eq([prompt, copy])
        expect(attempt["rounds"].last).not_to have_key("evidence")
      end

      it "leaves the attempt's evidence alone for a round that copied nothing" do
        given = reviewing_hash

        run = progress.end_round(given, how: "cancelled", ctx: ctx)

        expect(run.step("plan").last_attempt.to_h).not_to have_key("evidence")
      end

      it "adds no second record for a round its tally already recorded" do
        decided = progress.decide_review(reviewing_hash, {outcome: :incomplete, reviews: []}, ctx: ctx)

        run = progress.end_round(decided, how: "cancelled", ctx: ctx)

        expect(run.step("plan").last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["incomplete"])
      end

      it "changes nothing on a step with no round" do
        given = run_hash

        expect(progress.end_round(given, how: "cancelled", ctx: ctx).to_h).to eq(given)
        expect(attempt_record.calls).to be_empty
      end
    end

    describe "#restart_review" do
      let(:stopped) { reviewing_hash("state" => "waiting", "reason" => {"code" => "review_incomplete", "since" => "2026-11-10T11:55:00Z", "details" => {}}) }

      it "ends a stopped round, keeping its window, and starts a fresh one that spends a round" do
        context = ctx

        run = progress.restart_review(stopped, ctx: context)

        state = run.step("plan")
        expect(state.review_rounds).to eq(2)
        expect(state.review).to eq("round" => 2, "delivery" => "delivering", "started_at" => "2026-11-10T12:00:00.000Z", "pending" => %w[skeptic tester], "redeliveries" => 0)
        expect(state.last_attempt.to_h["rounds"].map { |each| each.slice("round", "ended") }).to eq([{"round" => 1, "ended" => "resumed"}])
        expect(run.state).to eq("running")
        expect(run.reason).to be_nil
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
        expect(context.close_review).to be_nil
        expect(panes.calls).to be_empty
        expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 2}]])
      end

      it "delivers a round whose delivery failed again as the same round, its redelivery count started again" do
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("delivery" => "failed", "redeliveries" => 2, "holder" => {"pid" => 1})
        context = ctx

        run = progress.restart_review(given, ctx: context)

        state = run.step("plan")
        expect(state.review_rounds).to eq(1)
        expect(state.review).to eq("round" => 1, "delivery" => "delivering", "pane" => "%9", "started_at" => "2026-11-10T12:00:00.000Z",
          "pending" => %w[skeptic tester], "redeliveries" => 0)
        expect(state.last_attempt.to_h["rounds"]).to eq([{"round" => 1, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "ended_at" => "2026-11-10T12:00:00Z",
                                                          "session" => nil, "agent" => nil, "usage" => nil, "ended" => "redelivered"}])
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
        expect(change.events).to eq([["wr_1", "review_started", {"step" => "plan", "attempt" => 1, "round" => 1, "again" => true}]])
      end
    end

    describe "a round start past the token budget or the run's timeout" do
      %w[budget_spent run_timed_out].each do |code|
        context "held with #{code}" do
          let(:dispatch) { RecordingDispatch.new(holds: code) }

          it "keeps the step reviewing with the round named and no delivery, spends no round and registers nothing" do
            context = ctx

            run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: context)

            state = run.step("plan")
            expect(run.state).to eq("waiting")
            expect(run.reason).to include("code" => code, "details" => include("review_round" => 1))
            expect(run.to_h[(code == "budget_spent") ? "budget_hold" : "timeout_hold"]).to eq("review_round" => 1)
            expect(state.state).to eq("reviewing")
            expect(state.review).to eq("round" => 1, "delivery" => nil)
            expect(state.review_rounds).to be_nil
            expect(state.last_attempt.outcome).to eq("checks_passed")
            expect(context.review).to be_nil
            expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 1}]])
            expect(change.events.map { |event| event[1] }).to eq(%w[step_checks_passed])
          end
        end
      end

      context "with a spent budget" do
        let(:dispatch) { RecordingDispatch.new(holds: "budget_spent") }

        it "holds a fresh round after a stopped one, the stopped round recorded and the next one not spent" do
          stopped = reviewing_hash("state" => "waiting", "reason" => {"code" => "review_incomplete", "since" => "2026-11-10T11:55:00Z", "details" => {}})

          run = progress.restart_review(stopped, ctx: ctx)

          state = run.step("plan")
          expect(run.reason["code"]).to eq("budget_spent")
          expect(state.review).to eq("round" => 2, "delivery" => nil)
          expect(state.review_rounds).to eq(1)
          expect(state.last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["resumed"])
        end

        it "delivers a round whose delivery failed again as the same round without asking the limits" do
          given = reviewing_hash
          given["steps"]["plan"]["review"]["delivery"] = "failed"
          context = ctx

          run = progress.restart_review(given, ctx: context)

          expect(run.state).to eq("running")
          expect(run.step("plan").review).to include("round" => 1, "delivery" => "delivering")
          expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
          expect(dispatch.calls).to be_empty
        end
      end

      it "starts the held round itself on the resume that released it, spending that round" do
        held = reviewing_hash("state" => "running", "reason" => nil)
        held["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil}
        context = ctx

        run = progress.restart_review(held, ctx: context)

        state = run.step("plan")
        expect(state.review_rounds).to eq(2)
        expect(state.review).to include("round" => 2, "delivery" => "delivering", "started_at" => "2026-11-10T12:00:00.000Z")
        expect(state.last_attempt.to_h["rounds"]).to be_nil
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
        expect(change.events).to eq([["wr_1", "review_started", {"step" => "plan", "attempt" => 1, "round" => 2}]])
      end

      it "ends a held round on cancel with no round record and no review_ended, still closing the window" do
        held = reviewing_hash
        held["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil}
        context = ctx

        run = progress.end_round(held, how: "cancelled", ctx: context)

        expect(run.step("plan").review).to be_nil
        expect(run.step("plan").last_attempt.to_h["rounds"]).to be_nil
        expect(attempt_record.calls).to be_empty
        expect(change.events).to be_empty
        expect(context.close_review).to eq("step" => "plan", "round" => 2, "pane" => nil)
      end
    end
  end
end
