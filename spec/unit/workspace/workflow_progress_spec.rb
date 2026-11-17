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

  def ctx = Workspace::WorkflowRunChange::Context.new("engine", "test")

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
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "next_step", context: nil, budgeted: true, retry_of: nil}]])
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

    it "clears the passed step's infra retry count and keeps the other steps'" do
      run = progress.pass_step(run_hash("infra_retries" => {"plan" => 2, "build" => 1}), ctx: ctx)

      expect(run.infra_retries).to eq("build" => 1)
      expect(Workspace::WorkflowTransitions.infra_retries(run.to_h, "plan")).to eq(0)
    end

    it "passes a run stored without infra retry counts" do
      expect(progress.pass_step(run_hash, ctx: ctx).infra_retries).to be_nil
    end
  end

  describe "#pass_overridden" do
    def guard_stopped(definition_steps: steps)
      run = run_hash(:definition_steps => definition_steps, "state" => "waiting",
        "reason" => {"code" => "failed_check", "since" => "2026-11-10T11:55:00Z", "details" => {"cause" => "guard", "guard" => "head_moved"}})
      run["steps"]["plan"] = {"state" => "failed", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00.000Z", "ended_at" => "2026-11-10T11:55:00Z", "outcome" => "failed", "code" => "head_moved"}]}
      run
    end

    it "marks the failed attempt overridden without finishing it again and starts the next step" do
      context = ctx

      run = progress.pass_overridden(guard_stopped, ctx: context)

      expect(run.step("plan").state).to eq("passed")
      expect(run.step("plan").last_attempt.to_h).to eq("n" => 1, "started_at" => "2026-11-10T11:00:00.000Z", "ended_at" => "2026-11-10T11:55:00Z",
        "outcome" => "overridden", "code" => "head_moved")
      expect(attempt_record.calls).to be_empty
      expect(run.current).to eq("build")
      expect(context.delivery).to eq("step" => "build")
      expect(change.events).to eq([["wr_1", "step_passed", {"step" => "plan", "attempt" => 1}]])
    end

    it "still waits at the step's gate" do
      context = ctx

      run = progress.pass_overridden(guard_stopped(definition_steps: steps("gate" => "approve")), ctx: context)

      expect(run.current).to eq("plan")
      expect(run.step("plan").to_h["gate"]).to eq("state" => "waiting", "since" => "2026-11-10T12:00:00Z")
      expect(run.reason).to include("code" => "waiting_you", "details" => include("kind" => "gate", "step" => "plan"))
      expect(context.delivery).to be_nil
      expect(change.events.map { |event| event[1] }).to eq(%w[step_passed gate_waiting])
    end
  end

  describe "an attempt whose guard stop a person accepted" do
    let(:review) { {"from" => %w[skeptic tester], "need" => 2, "must" => [], "max_rounds" => 6} }

    def accepted(definition_steps: steps)
      run_hash(definition_steps: definition_steps).tap do |hash|
        hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:55:00Z", "outcome" => "failed", "code" => "head_moved", "guard_accepted" => "head_moved")
      end
    end

    it "with a review: makes the step reviewing and starts its round, the attempt overridden and not finished again" do
      context = ctx

      run = progress.pass_overridden(accepted(definition_steps: steps("review" => review)), ctx: context)

      state = run.step("plan")
      expect(state.state).to eq("reviewing")
      expect(state.last_attempt.outcome).to eq("overridden")
      expect(state.review).to include("round" => 1, "delivery" => "delivering")
      expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
      expect(attempt_record.calls).to be_empty
      expect(change.events.map { |event| event[1] }).to eq(%w[review_started])
    end

    it "keeps overridden when the review round then approves it" do
      given = progress.pass_overridden(accepted(definition_steps: steps("review" => review)), ctx: ctx)

      run = progress.decide_review(given, {outcome: :approved, reviews: [], approvals: 2, need: 2, must: []}, ctx: ctx)

      expect(run.step("plan").state).to eq("passed")
      expect(run.step("plan").last_attempt.outcome).to eq("overridden")
    end

    it "fails on a later check with its own code, keeping the attempt's end as the guard recorded it" do
      run = progress.fail_step(accepted, {"cause" => "check", "exit_code" => 1, "code" => "check_failed"}, ctx: ctx)

      expect(run.step("plan").state).to eq("failed")
      expect(run.step("plan").last_attempt.to_h).to include("ended_at" => "2026-11-10T11:55:00Z", "outcome" => "failed", "code" => "check_failed")
      expect(attempt_record.calls).to be_empty
      expect(run.reason).to include("code" => "failed_check")
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
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "loop", context: "fresh", budgeted: true, retry_of: {"text" => text}}]])
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

    it "loops back to the step before on a failure the default can retry, telling it what failed" do
      definition = [{"id" => "plan", "produces" => ["plan.md"]}, {"id" => "build", "produces" => []}]
      run = run_hash(definition_steps: definition, "current" => "build")
      run["steps"]["build"] = {"state" => "checking", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:30:00.000Z"}]}
      context = ctx

      run = progress.fail_step(run, failure, ctx: context)

      text = "The build step failed and sent the run back to this step (time 1): #{Workspace::WorkflowTransitions.failure_text(failure)}. " \
        "Its files are in /work/.workflow/wr_1. Fix what it found."
      expect(run.current).to eq("plan")
      expect(run.state).to eq("running")
      expect(run.to_h["loops"]).to eq("build->plan" => 1)
      expect(run.pending_context).to eq([text])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "loop", context: nil, budgeted: true, retry_of: {"text" => text}}]])
      expect(log_tail.calls).to be_empty
      expect(change.events.last).to eq(["wr_1", "step_looped", {"from" => "build", "to" => "plan", "count" => 1}])
    end

    it "stops for a person when the default loop's failure is infrastructural" do
      definition = [{"id" => "plan", "produces" => ["plan.md"]}, {"id" => "build", "produces" => []}]
      run = run_hash(definition_steps: definition, "current" => "build")
      run["steps"]["build"] = {"state" => "checking", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:30:00.000Z"}]}

      run = progress.fail_step(run, {"cause" => "guard", "code" => "head_moved"}, ctx: ctx)

      expect(run.state).to eq("waiting")
      expect(run.reason["code"]).to eq("failed_check")
      expect(run.current).to eq("build")
      expect(dispatch.calls.map(&:first)).to eq([:release])
    end

    it "stops for a person when the step says on_fail: stop" do
      run = progress.fail_step(run_hash(definition_steps: steps("on_fail" => "stop")), failure, ctx: ctx)

      expect(run.state).to eq("waiting")
      expect(run.reason["code"]).to eq("failed_check")
      expect(dispatch.calls.map(&:first)).to eq([:release])
    end
  end

  describe "#start_retry" do
    let(:waiting) { {"until" => "2026-11-10T11:59:00Z", "to" => "plan", "context" => "fresh", "text" => "it failed", "pane" => "%3", "identity" => "id-3"} }

    it "takes the run's wait off it and starts the target step with the kept text" do
      context = ctx

      run = progress.start_retry(run_hash("backoff" => waiting, "reason" => {"code" => "retry_backoff"}), ctx: context, cause: "backoff_ended")

      expect(run.backoff).to be_nil
      expect(run.pending_context).to eq(["it failed"])
      expect(run.reason).to be_nil
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "backoff_ended", context: "fresh", budgeted: true, retry_of: {"pane" => "%3", "identity" => "id-3", "text" => "it failed"}}]])
      expect(panes.calls).to eq([[:same_pane?, "%3", "id-3"]])
      expect(change.events).to eq([["wr_1", "step_retry_started", {"from" => "plan", "to" => "plan"}]])
    end

    it "holds the retry when its pane is gone, keeping the wait marked blocked" do
      panes = RecordingWorkflowPanes.new(gone: ["%3"])
      progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail, clock: -> { now })

      run = progress.start_retry(run_hash("backoff" => waiting), ctx: ctx, cause: "backoff_ended")

      expect(run.backoff).to eq(waiting.merge("blocked" => "pane_gone"))
      expect(run.reason["code"]).to eq("pane_gone")
      expect(dispatch.calls).to be_empty
    end

    it "starts a wait already taken off the run in a pane a person named, without comparing it" do
      progress.start_retry(run_hash, waiting.merge("pane" => nil), ctx: ctx, cause: "backoff_ended", proven: true, budgeted: false)

      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "backoff_ended", context: "fresh", budgeted: false, retry_of: {"pane" => nil, "identity" => "id-3", "text" => "it failed"}}]])
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
      expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 1}], [:hold_round_lock, "wr_1", {round: 1, step_state: "reviewing"}]])
      expect(change.events.map { |event| event[1] }).to eq(%w[step_checks_passed review_started])
    end

    it "holds round 1 on a paused run, marking it held by the pause and spending nothing" do
      context = ctx
      given = run_hash(definition_steps: steps("review" => review)).merge("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})

      run = progress.pass_step(given, ctx: context)

      expect(run.step("plan").review).to eq("round" => 1, "delivery" => nil, "held" => "paused")
      expect(run.step("plan").to_h["review_rounds"]).to be_nil
      expect(run.to_h["pause_hold"]).to eq("kind" => "round", "review_round" => 1)
      expect(run.state).to eq("waiting")
      expect(context.review).to be_nil
      expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 1}]])
    end

    it "counts each round the step starts, never resetting" do
      given = run_hash(definition_steps: steps("review" => review))
      given["steps"]["plan"]["review_rounds"] = 2

      run = progress.pass_step(given, ctx: ctx)

      expect(run.step("plan").review_rounds).to eq(3)
      expect(run.step("plan").review["round"]).to eq(3)
    end

    describe "the checkout's snapshot" do
      it "is stored on the round as it starts" do
        guard = RecordingGuard.new(head: "b" * 40, tree: "c" * 64)
        progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          guard: guard, clock: -> { now })

        run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)

        expect(run.step("plan").review["snapshot"]).to eq("head" => "b" * 40, "tree_sha256" => "c" * 64)
        expect(guard.calls).to eq([[:round_snapshot, run.worktree]])
      end

      it "is not taken for a held round" do
        guard = RecordingGuard.new
        held = described_class.new(change: change, store: store, dispatch: RecordingDispatch.new(holds: "budget_spent"), attempt_record: attempt_record,
          panes: panes, log_tail: log_tail, guard: guard, clock: -> { now })
        held.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)

        expect(guard.calls).to be_empty
      end

      it "is taken again for a redelivered round, so an edit between the deliveries is not a change" do
        guard = RecordingGuard.new(head: "d" * 40, tree: "e" * 64)
        again = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          guard: guard, clock: -> { now })
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("delivery" => "failed", "snapshot" => {"head" => "a" * 40, "tree_sha256" => "t" * 64})

        run = again.restart_review(given, ctx: ctx)

        expect(run.step("plan").review["snapshot"]).to eq("head" => "d" * 40, "tree_sha256" => "e" * 64)
        expect(guard.calls).to eq([[:round_snapshot, run.worktree]])
      end

      it "is taken for a held round when it starts" do
        guard = RecordingGuard.new(head: "d" * 40, tree: "e" * 64)
        again = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          guard: guard, clock: -> { now })
        held = reviewing_hash("state" => "running", "reason" => nil)
        held["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => "budget_spent"}

        run = again.restart_review(held, ctx: ctx)

        expect(run.step("plan").review["snapshot"]).to eq("head" => "d" * 40, "tree_sha256" => "e" * 64)
        expect(guard.calls).to eq([[:round_snapshot, run.worktree]])
      end

      it "is left out when no guard is set up" do
        run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)

        expect(run.step("plan").review).not_to have_key("snapshot")
      end
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

    describe "a round past max_rounds" do
      it "never starts: the step stays reviewing with the round held, nothing is registered and the run stops review_rounds_spent" do
        given = run_hash(definition_steps: steps("review" => review.merge("max_rounds" => 2)))
        # Two rounds spent on earlier attempts (a gate's reject, `--from` or an `on_fail` loop never reset the count).
        given["steps"]["plan"]["review_rounds"] = 2
        tally = RecordingReviewTally.new
        progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_tally: tally, clock: -> { now })
        context = ctx

        run = progress.pass_step(given, ctx: context)

        state = run.step("plan")
        expect(state.state).to eq("reviewing")
        expect(state.last_attempt.outcome).to eq("checks_passed")
        expect(state.review_rounds).to eq(2)
        expect(state.review).to eq("round" => 3, "delivery" => nil, "held" => "review_rounds_spent")
        expect(run.state).to eq("waiting")
        expect(run.reason).to eq("code" => "review_rounds_spent", "since" => "2026-11-10T12:00:00Z",
          "details" => {"step" => "plan", "attempt" => 1, "round" => 3, "rounds" => 2, "max_rounds" => 2})
        expect(context.review).to be_nil
        expect(tally.calls).to be_empty
        expect(dispatch.calls).to eq([[:release, "wr_1"]])
        expect(change.events.map { |event| event[1] }).to eq(%w[step_checks_passed review_rounds_spent])
      end

      it "is not started by a resume of a stopped round either" do
        given = reviewing_hash("state" => "waiting", "reason" => {"code" => "review_incomplete", "since" => "2026-11-10T11:50:00Z", "details" => {}})
        given["steps"]["plan"]["review_rounds"] = 6
        context = ctx

        run = progress.restart_review(given, ctx: context)

        expect(run.reason["code"]).to eq("review_rounds_spent")
        expect(run.step("plan").review).to include("round" => 7, "held" => "review_rounds_spent")
        expect(context.review).to be_nil
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

    describe "a rejected round" do
      let(:rows) do
        [{"reviewer" => "skeptic", "verdict" => "reject", "counted" => true, "path" => "reviews/plan.1.r1/skeptic.md"},
          {"reviewer" => "tester", "verdict" => "approve", "counted" => true, "path" => "reviews/plan.1.r1/tester.md"}]
      end
      let(:tally) { {outcome: :rejected, reviews: rows, approvals: 1, need: 2, must: ["skeptic"]} }

      def rejected_hash(rounds: 1, **overrides)
        reviewing_hash(**overrides).tap do |hash|
          hash["steps"]["plan"]["review_rounds"] = rounds
          hash["steps"]["plan"]["review"].merge!("round" => rounds, "window" => "@7")
        end
      end

      it "fails the attempt and starts the step again as a new attempt told the verdicts and each counted write-up" do
        context = ctx

        run = progress.decide_review(rejected_hash, tally, ctx: context)

        expect(run.step("plan").last_attempt.to_h).to include("outcome" => "failed", "code" => "review_rejected",
          "review_outcome" => {"round" => 1, "approvals" => 1, "need" => 2, "must" => ["skeptic"], "passed" => false})
        line = "Review round 1 of 6 rejected the plan step: need 2 of 2 with skeptic; got skeptic reject, tester approve. Address every reviewer's concern and say how."
        text = [line, "the write-up at /work/.workflow/wr_1/reviews/plan.1.r1/skeptic.md", "the write-up at /work/.workflow/wr_1/reviews/plan.1.r1/tester.md"].join("\n\n")
        expect(run.pending_context).to eq([text])
        expect(log_tail.calls).to eq([[:writeup, "/work/.workflow/wr_1/reviews/plan.1.r1/skeptic.md"], [:writeup, "/work/.workflow/wr_1/reviews/plan.1.r1/tester.md"]])
        expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "review_rejected", context: nil, budgeted: true, retry_of: {"text" => text, "attempt" => 1}}]])
        expect(context.delivery).to eq("step" => "plan")
        expect(run.reason).to be_nil
        expect(change.events.map { |event| event[1] }).to eq(%w[review_ended step_failed review_retry])
        expect(change.events.last).to eq(["wr_1", "review_retry", {"step" => "plan", "attempt" => 1, "round" => 1, "rounds" => 1, "max_rounds" => 6}])
      end

      it "starts the retry with the review's context and leaves out a verdict that did not count" do
        given = rejected_hash
        given["definition"]["steps"][0]["review"] = review.merge("context" => "continue")
        rows[1].merge!("counted" => false, "problem" => "unproven")

        progress.decide_review(given, tally, ctx: ctx)

        expect(dispatch.calls.first[2][:context]).to eq("continue")
        expect(dispatch.calls.first[2][:retry_of]["text"]).to include("got skeptic reject, tester no counted verdict.")
        expect(log_tail.calls).to eq([[:writeup, "/work/.workflow/wr_1/reviews/plan.1.r1/skeptic.md"]])
      end

      it "keeps the window and its reviewer's binding (so the write guard still holds) for the next round, named on the step" do
        context = ctx

        run = progress.decide_review(rejected_hash, tally, ctx: context)

        expect(panes.calls).to be_empty
        expect(context.close_review).to be_nil
        expect(run.step("plan").to_h["review_window"]).to eq("round" => 1, "window" => "@7", "pane" => "%9")
      end

      it "stops the run review_rejected once the step has spent max_rounds" do
        run = progress.decide_review(rejected_hash(rounds: 6), tally, ctx: ctx)

        expect(run.state).to eq("waiting")
        expect(run.step("plan").state).to eq("failed")
        expect(run.reason).to eq("code" => "review_rejected", "since" => "2026-11-10T12:00:00Z",
          "details" => {"step" => "plan", "attempt" => 1, "round" => 6, "reviews" => run.step("plan").last_attempt.reviews,
                        "rounds" => 6, "max_rounds" => 6, "limit" => "rounds"})
        expect(dispatch.calls).to eq([[:release, "wr_1"]])
        expect(run.pending_context).to be_empty
        expect(run.step("plan").to_h["review_window"]).to include("window" => "@7")
        expect(run.to_h["review_retry"]).to include("step" => "plan", "attempt" => 1, "round" => 6, "context" => nil)
        expect(run.to_h["review_retry"]["text"]).to start_with("Review round 6 of 6 rejected the plan step")
      end

      it "closes the window a rejected round kept when a --from ends the step, which has no round of its own" do
        rejected = progress.decide_review(rejected_hash(rounds: 6), tally, ctx: ctx)
        context = ctx

        run = progress.end_round(rejected, how: "from", ctx: context)

        expect(context.close_review).to eq("workspace" => "app", "step" => "plan", "round" => 6, "pane" => "%9")
        expect(panes.calls).to eq([[:unbind, "wr_1", {role: "reviewer"}]])
        expect(run.step("plan").to_h).not_to have_key("review_window")
      end

      it "stops on the step's own max_attempts before its rounds, and on the run's before the step's" do
        step_capped = rejected_hash(rounds: 6)
        step_capped["definition"]["steps"][0]["max_attempts"] = 1

        run = progress.decide_review(step_capped, tally, ctx: ctx)

        expect(run.reason["details"]).to include("limit" => "step", "attempts" => 1, "max_attempts" => 1, "rounds" => 6)

        run_capped = rejected_hash
        run_capped["definition"]["max_attempts"] = 1
        run_capped["definition"]["steps"][0]["max_attempts"] = 1

        run = progress.decide_review(run_capped, tally, ctx: ctx)

        expect(run.reason).to include("code" => "review_rejected", "details" => include("limit" => "run", "attempts" => 1, "max_attempts" => 1))
      end
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

    describe "an incomplete round with deliveries left" do
      let(:rows) do
        [{"reviewer" => "skeptic", "verdict" => "approve", "counted" => true, "path" => "reviews/plan.1.r1/skeptic.md"},
          {"reviewer" => "tester", "verdict" => nil, "counted" => false, "problem" => "missing", "path" => "reviews/plan.1.r1/tester.md"}]
      end

      def rerunnable(**overrides)
        reviewing_hash(**overrides).tap do |hash|
          hash["definition"]["redeliver"] = 2
          hash["steps"]["plan"]["review"].merge!("revision" => "rev1", "window" => "@7", "clear_from" => "2026-11-10T11:30:00.000Z",
            "cleared_at" => "2026-11-10T11:30:01.000Z", "delivered_at" => "2026-11-10T11:30:02.000Z")
        end
      end

      it "runs only the reviewers whose verdicts did not count again in the same round, spending a delivery and keeping the counted rows" do
        context = ctx

        run = progress.decide_review(rerunnable, {outcome: :incomplete, reviews: rows, problem: "no counted verdict from tester (missing)"}, ctx: context)

        state = run.step("plan")
        expect(run.state).to eq("running")
        expect(run.reason).to be_nil
        expect(state.state).to eq("reviewing")
        expect(state.to_h["review_rounds"]).to eq(1)
        expect(state.review).to include("round" => 1, "delivery" => "delivering", "rerun" => %w[tester], "reruns" => 1, "redeliveries" => 1,
          "pending" => %w[tester], "reviews" => [rows.first], "uncleared" => true, "revision" => "rev1", "window" => "@7", "pane" => "%9")
        expect(state.review).not_to include("clear_from", "cleared_at", "delivered_at", "ended_at", "recorded")
        expect(state.last_attempt.to_h["rounds"].map { |each| each.slice("round", "ended", "reviews") }).to eq([{"round" => 1, "ended" => "rerun", "reviews" => rows.map { |row| row.merge("isolation" => "review_pane") }}])
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1, "revision" => "rev1")
        expect(context.close_review).to be_nil
        expect(change.events.map { |event| event[1] }).to eq(%w[review_ended review_rerun])
        expect(change.events.last.last).to eq("step" => "plan", "attempt" => 1, "round" => 1, "reviewers" => %w[tester], "rerun" => 1, "redelivery" => 1)
      end

      it "stops review_incomplete once the round's deliveries are spent, naming no reviewer to run again" do
        given = rerunnable
        given["steps"]["plan"]["review"].merge!("redeliveries" => 2, "rerun" => %w[tester], "reruns" => 2)

        run = progress.decide_review(given, {outcome: :incomplete, reviews: rows, problem: "no counted verdict from tester (missing)"}, ctx: ctx)

        expect(run.reason).to include("code" => "review_incomplete")
        expect(run.step("plan").review).not_to have_key("rerun")
        expect(run.step("plan").review).to include("reruns" => 2)
      end

      it "drops the old server's panes with the pane and window when the round is delivered again on a restarted tmux server" do
        given = rerunnable
        given["steps"]["plan"]["review"].merge!("panes" => %w[%9], "server_pid" => "100", "delivery" => "failed")

        run = progress.redeliver_round(given, ctx: ctx, new_server: true)

        expect(run.step("plan").review).not_to include("pane", "panes", "window", "server_pid")
      end

      it "runs no reviewer again in a round the sweep interrupted for a time limit, and says why it stopped, its window kept" do
        %w[interrupt run_interrupt].each do |key|
          given = rerunnable
          given["steps"]["plan"]["review"]["sweep"] = {key => {"state" => "sent", "at" => "2026-11-10T11:59:00Z"}}
          context = ctx

          run = progress.decide_review(given, {outcome: :incomplete, reviews: rows, problem: "no counted verdict from tester (missing)"}, ctx: context)

          expect(run.reason).to include("code" => "review_incomplete")
          expect(run.step("plan").review).not_to include("rerun")
          expect(context.review).to be_nil
          expect(context.close_review).to be_nil
          problem = run.reason.dig("details", "problem")
          expect(problem).to include("so the sweep interrupted the review pane", "did not decide it: no counted verdict from tester (missing)", "Its window is kept")
          expect(problem).to include((key == "interrupt") ? "past its 1800 second review timeout" : "a resume needs --extra-time")
        end
      end

      it "stops review_incomplete for a round problem no rerun gets past" do
        broken = rows.map { |row| row.merge("counted" => false, "problem" => "no_review_pane") }

        run = progress.decide_review(rerunnable, {outcome: :incomplete, reviews: broken, problem: "x"}, ctx: ctx)

        expect(run.reason).to include("code" => "review_incomplete")
      end
    end

    describe "a round stopped review_no_change ({WorkflowRoundRerun#stop_no_change})" do
      let(:round_rerun) { Workspace::WorkflowRoundRerun.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, clock: -> { now }) }

      def delivering
        reviewing_hash.tap do |hash|
          hash["steps"]["plan"]["review_rounds"] = 2
          hash["steps"]["plan"]["review"].merge!("round" => 2, "delivery" => "delivering", "holder" => {"pid" => 1}).delete("pane")
        end
      end

      it "on resume delivers the same round, spending it, its revision accepted and nothing recorded" do
        stopped = round_rerun.stop_no_change(delivering, revision: "rev1", rejected: {"revision" => "rev1", "round" => 1, "attempt" => 1})
        context = ctx

        run = progress.restart_review(stopped, ctx: context)

        state = run.step("plan")
        expect(run.reason).to be_nil
        expect(state.to_h["review_rounds"]).to eq(2)
        expect(state.review).to include("round" => 2, "delivery" => "delivering", "accept_revision" => true, "redeliveries" => 0)
        expect(state.review).not_to have_key("no_change")
        expect(state.last_attempt.to_h["rounds"]).to be_nil
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
      end

      context "when the round's review.uses lock is taken as it is resumed" do
        let(:dispatch) { RecordingDispatch.new(lock_waits: "test-db") }

        it "waits as waiting_lock with the same round named and held, nothing spent, and its release comes back to that round" do
          stopped = round_rerun.stop_no_change(delivering, revision: "rev1", rejected: {"revision" => "rev1", "round" => 1, "attempt" => 1})
          context = ctx

          run = progress.restart_review(stopped, ctx: context)

          state = run.step("plan")
          expect(run.reason).to include("code" => "waiting_lock")
          expect(state.to_h["review_rounds"]).to eq(1)
          expect(state.review).to include("round" => 2, "no_change" => true, "held" => "waiting_lock", "delivery" => nil)
          expect(context.review).to be_nil
          expect(dispatch.calls.map(&:first)).to include(:hold_round, :hold_round_lock)
        end
      end

      context "when the token budget is spent as it is resumed" do
        let(:dispatch) { RecordingDispatch.new(holds: "budget_spent") }

        it "holds the same round, spending nothing" do
          stopped = round_rerun.stop_no_change(delivering, revision: "rev1", rejected: {"revision" => "rev1", "round" => 1, "attempt" => 1})

          run = progress.restart_review(stopped, ctx: ctx)

          expect(run.reason).to include("code" => "budget_spent")
          expect(run.to_h["budget_hold"]).to eq("review_round" => 2)
          expect(run.step("plan").to_h["review_rounds"]).to eq(1)
          expect(run.step("plan").review).to include("round" => 2, "no_change" => true, "held" => "budget_spent")
        end
      end

      it "is ended with no record by a cancel or resume --from" do
        stopped = round_rerun.stop_no_change(delivering, revision: "rev1", rejected: {"revision" => "rev1", "round" => 1, "attempt" => 1})

        run = progress.end_round(stopped, how: "from", ctx: ctx)

        expect(run.step("plan").last_attempt.to_h["rounds"]).to be_nil
        expect(run.step("plan").review).to be_nil
      end
    end

    describe "with a review summary" do
      let(:summary) { RecordingReviewSummary.new }
      let(:progress) do
        described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_summary: summary, clock: -> { now })
      end
      let(:approved) { {outcome: :approved, reviews: [], approvals: 2, need: 2, must: []} }

      # Decides with a context of its own and runs what it registered to follow the lock, as WorkflowRunChange#call does.
      def decide(given, tally, subject = progress)
        context = ctx
        run = subject.decide_review(given, tally, ctx: context)
        @registered = context.after_locks.size
        context.after_locks.each { |each| each.call(run) }
        run
      end

      def gated_hash = reviewing_hash.tap { |hash| hash["definition"]["steps"].find { |step| step["id"] == "plan" }["gate"] = "approve" }

      it "writes the round's summary before the decision and posts the item after it, naming the summary in the outcome and the round's record" do
        given = reviewing_hash
        given["steps"]["plan"]["review"]["revision"] = "rev1"

        run = decide(given, approved)

        attempt = run.step("plan").attempts.first.to_h
        expect(attempt["review_outcome"]).to include("summary" => "/runs/wr_1/reviews/plan.1.r1/summary.md")
        expect(attempt["rounds"].last["summary"]).to eq("path" => "/runs/wr_1/reviews/plan.1.r1/summary.md", "sha256" => "s" * 64)
        expect(summary.calls.map(&:first)).to eq(%i[write notify])
        expect(@registered).to eq(1)
        expect(summary.calls.first[2]).to include(round: 1, outcome: :approved, decided: include("revision" => "rev1", "need" => 2))
        expect(summary.calls.last).to eq([:notify, "plan", {attempt: 1, round: 1, outcome: :approved, summary: {"path" => "/runs/wr_1/reviews/plan.1.r1/summary.md", "sha256" => "s" * 64}, reason: nil}])
      end

      it "names the summary on the gate a passing round waits at, and the item sees the gate" do
        run = decide(gated_hash, approved)

        expect(run.reason).to include("code" => "waiting_you", "details" => include("kind" => "gate", "summary" => "/runs/wr_1/reviews/plan.1.r1/summary.md"))
        expect(summary.calls.last[2]).to include(reason: "waiting_you")
      end

      it "writes and posts for a round that stops, but not for a rerun of its missing reviewers" do
        rows = [{"reviewer" => "skeptic", "counted" => true}, {"reviewer" => "tester", "counted" => false, "problem" => "missing"}]
        rerunnable = reviewing_hash.tap { |hash| hash["definition"]["redeliver"] = 1 }

        decide(rerunnable, {outcome: :incomplete, reviews: rows, problem: "x"})
        expect(summary.calls).to be_empty

        run = decide(reviewing_hash, {outcome: :incomplete, reviews: rows, problem: "x"})
        expect(run.reason).to include("code" => "review_incomplete")
        expect(summary.calls.map(&:first)).to eq(%i[write notify])
        expect(summary.calls.first[2]).to include(outcome: :incomplete, problem: "x")
        expect(run.step("plan").last_attempt.to_h["rounds"].last).to have_key("summary")
      end

      it "posts nothing under the run's lock: the item waits on the context until the lock is given up" do
        context = ctx

        progress.decide_review(reviewing_hash, approved, ctx: context)

        expect(summary.calls.map(&:first)).to eq(%i[write])
        expect(context.after_locks.size).to eq(1)
      end

      it "names no summary on the outcome when it could not be written, and still posts" do
        unwritten = RecordingReviewSummary.new({"problem" => "no directory"})
        subject = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          review_summary: unwritten, clock: -> { now })

        run = decide(gated_hash, approved, subject)

        expect(run.step("plan").last_attempt.to_h["review_outcome"]).not_to have_key("summary")
        expect(run.reason["details"]).not_to have_key("summary")
        expect(unwritten.calls.map(&:first)).to eq(%i[write notify])
      end
    end

    it "records the revision a decided round judged in its review_outcome" do
      given = reviewing_hash
      given["steps"]["plan"]["review"]["revision"] = "rev1"

      run = progress.decide_review(given, {outcome: :approved, reviews: [], approvals: 2, need: 2, must: []}, ctx: ctx)

      expect(run.step("plan").last_attempt.to_h["review_outcome"]).to include("revision" => "rev1")
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
        expect(context.close_review).to eq("workspace" => "app", "step" => "plan", "round" => 1, "pane" => "%9")
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
        expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 2}], [:hold_round_lock, "wr_1", {round: 2, step_state: "reviewing"}]])
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

    describe "#redeliver_round" do
      it "delivers the round again as the same round, spending one more of its redeliveries and keeping the window a failure kept" do
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("delivery" => "failed", "redeliveries" => 1, "window" => "@7", "holder" => {"pid" => 1},
          "failure" => {"code" => "agent_not_ready"}, "sweep" => {"interrupt" => {"state" => "sent", "at" => "2026-11-10T11:00:00Z"}})
        context = ctx

        run = progress.redeliver_round(given, ctx: context)

        state = run.step("plan")
        expect(state.review_rounds).to eq(1)
        expect(state.review).to include("round" => 1, "delivery" => "delivering", "window" => "@7", "started_at" => "2026-11-10T12:00:00.000Z", "redeliveries" => 2)
        expect(state.review).not_to include("failure", "holder", "sweep")
        expect(state.last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["redelivered"])
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1)
        expect(change.events).to eq([["wr_1", "review_started", {"step" => "plan", "attempt" => 1, "round" => 1, "again" => true, "redelivery" => 2}]])
        expect(dispatch.calls).to be_empty
      end

      it "changes nothing on a paused run and records no hold: the round's failed mark is what the tick acts on after the unpause" do
        given = reviewing_hash.merge("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})
        given["steps"]["plan"]["review"].merge!("delivery" => "failed", "redeliveries" => 1)
        context = ctx

        run = progress.redeliver_round(given, ctx: context, new_server: true)

        expect(run.to_h).to eq(given)
        expect(context.review).to be_nil
        expect(change.events).to be_empty
      end

      it "changes nothing on a paused run's round still open in restart_review, recording no hold and giving up no lock" do
        given = reviewing_hash.merge("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})
        given["steps"]["plan"]["review"]["delivery"] = "failed"
        context = ctx

        run = progress.restart_review(given, ctx: context)

        expect(run.to_h).to eq(given)
        expect(context.review).to be_nil
        expect(dispatch.calls).to be_empty
        expect(change.events).to be_empty
      end

      context "with a rerun a pause held" do
        def paused_rerun(**overrides)
          reviewing_hash(**overrides).tap do |hash|
            hash["steps"]["plan"]["review"] = {"round" => 1, "delivery" => nil, "held" => "paused_rerun", "pane" => "%9", "window" => "@7",
                                               "rerun" => %w[tester], "pending" => %w[tester], "redeliveries" => 1, "reruns" => 1, "revision" => "rev2",
                                               "snapshot" => {"head" => "a" * 40, "tree_sha256" => "t" * 64}}
            hash["steps"]["plan"]["attempts"].last["rounds"] = [{"round" => 1, "ended" => "rerun"}]
          end
        end

        it "is left as it is by restart_review while paused" do
          given = paused_rerun("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})

          expect(progress.restart_review(given, ctx: ctx).to_h).to eq(given)
          expect(dispatch.calls).to be_empty
        end

        it "is delivered by restart_review as the same round, keeping its redeliveries, revision and snapshot, with no second record" do
          context = ctx
          guard = RecordingGuard.new(head: "d" * 40, tree: "e" * 64)
          progress = described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
            guard: guard, holder: -> { {"pid" => 7} }, clock: -> { now })

          run = progress.restart_review(paused_rerun, ctx: context)

          state = run.step("plan")
          expect(run.state).to eq("running")
          expect(state.review_rounds).to eq(1)
          expect(state.review).to include("round" => 1, "delivery" => "delivering", "started_at" => "2026-11-10T12:00:00.000Z", "holder" => {"pid" => 7},
            "rerun" => %w[tester], "pending" => %w[tester], "redeliveries" => 1, "reruns" => 1, "revision" => "rev2",
            "snapshot" => {"head" => "a" * 40, "tree_sha256" => "t" * 64})
          expect(state.review).not_to have_key("held")
          expect(state.last_attempt.to_h["rounds"]).to eq([{"round" => 1, "ended" => "rerun"}])
          expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 1, "revision" => "rev2")
          expect(change.events).to eq([["wr_1", "review_started", {"step" => "plan", "attempt" => 1, "round" => 1, "again" => true}]])
          expect(guard.calls).to be_empty
          expect(dispatch.calls).to be_empty
        end

        it "ends on a cancel with no second record and no review_ended, closing its window" do
          context = ctx

          run = progress.end_round(paused_rerun, how: "cancelled", ctx: context)

          expect(run.step("plan").review).to be_nil
          expect(run.step("plan").last_attempt.to_h["rounds"]).to eq([{"round" => 1, "ended" => "rerun"}])
          expect(change.events).to be_empty
          expect(context.close_review).to include("step" => "plan", "round" => 1)
        end
      end
    end

    describe "#redeliver_round with a new tmux server" do
      it "drops the round's pane, window and server so a new window opens, and keeps the pane on the redelivered record" do
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("window" => "@7", "server_pid" => "100")

        run = progress.redeliver_round(given, ctx: ctx, new_server: true)

        state = run.step("plan")
        expect(state.review).not_to include("pane", "window", "server_pid")
        expect(state.review).to include("delivery" => "delivering", "redeliveries" => 1)
        expect(state.last_attempt.to_h["rounds"].last).to include("pane" => "%9", "ended" => "redelivered")
      end
    end

    describe "the review window" do
      it "unbinds the reviewer and registers the window to close when the round approves, a gate or not" do
        context = ctx

        progress.decide_review(reviewing_hash, {outcome: :approved, reviews: []}, ctx: context)

        expect(panes.calls).to eq([[:unbind, "wr_1", {role: "reviewer"}]])
        expect(context.close_review).to eq("workspace" => "app", "step" => "plan", "round" => 1, "pane" => "%9")
      end

      it "closes, on approval, the window an earlier round left, and forgets it" do
        given = reviewing_hash
        given["steps"]["plan"]["review_window"] = {"round" => 1, "window" => "@7"}
        context = ctx

        run = progress.decide_review(given, {outcome: :approved, reviews: []}, ctx: context)

        expect(context.close_review).to include("step" => "plan", "round" => 1)
        expect(run.step("plan").to_h).not_to have_key("review_window")
      end

      it "keeps, named on the step, the window of a round a resume ends for a fresh one" do
        given = reviewing_hash("state" => "waiting", "reason" => {"code" => "review_incomplete", "since" => "2026-11-10T11:50:00Z", "details" => {}})
        given["steps"]["plan"]["review"]["window"] = "@7"
        context = ctx

        run = progress.restart_review(given, ctx: context)

        expect(run.step("plan").to_h["review_window"]).to eq("round" => 1, "window" => "@7", "pane" => "%9")
        expect(context.close_review).to be_nil
        expect(context.review).to include("round" => 2)
      end

      it "keeps the window and the reviewer of a round that stops for a person" do
        context = ctx

        progress.decide_review(reviewing_hash, {outcome: :incomplete, reviews: []}, ctx: context)

        expect(panes.calls).to be_empty
        expect(context.close_review).to be_nil
      end

      it "closes every window of a reviewed run as it ends, after a reject left its step failed" do
        rejected = progress.decide_review(reviewing_hash, {outcome: :rejected, reviews: []}, ctx: ctx)
        context = ctx

        run = progress.finish(rejected, "cancelled", ctx: context)

        expect(run.state).to eq("cancelled")
        expect(context.close_review).to eq("workspace" => "app", "step" => nil, "round" => nil, "pane" => nil)
      end

      it "registers no close at the end of a run no step of which had a round, nor without a context" do
        context = ctx

        progress.finish(run_hash, "completed", ctx: context)
        progress.finish(reviewing_hash, "cancelled")

        expect(context.close_review).to be_nil
      end

      it "registers no close for a held first round, which never opened a window" do
        held = reviewing_hash
        held["steps"]["plan"].merge!("review_rounds" => 0, "review" => {"round" => 1, "delivery" => nil, "held" => "waiting_lock"})
        context = ctx

        run = progress.end_round(held, how: "from", ctx: context)

        expect(run.step("plan").review).to be_nil
        expect(context.close_review).to be_nil
        expect(panes.calls).to be_empty
      end
    end

    describe "the round's holder" do
      let(:holder) { {"pid" => 4321, "started" => "Tue Nov 10 11:59:00 2026"} }

      subject(:progress) do
        described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, panes: panes, log_tail: log_tail,
          holder: -> { holder }, clock: -> { now })
      end

      it "is the process that starts the round, stored on its delivery mark" do
        run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)

        expect(run.step("plan").review).to include("delivery" => "delivering", "holder" => holder)
      end

      it "is the process that delivers a failed round again, in place of the one before" do
        given = reviewing_hash
        given["steps"]["plan"]["review"].merge!("delivery" => "failed", "holder" => {"pid" => 1}, "failure" => {"code" => "no_daemon"})

        run = progress.restart_review(given, ctx: ctx)

        expect(run.step("plan").review).to include("delivery" => "delivering", "holder" => holder)
        expect(run.step("plan").review).not_to have_key("failure")
      end
    end

    describe "a round waiting for its review.uses" do
      let(:dispatch) { RecordingDispatch.new(lock_waits: "review-db") }

      it "waits on waiting_lock with the round named and held, spends no round and registers nothing" do
        context = ctx

        run = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: context)

        state = run.step("plan")
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "waiting_lock", "details" => include("resource" => "review-db", "review_round" => 1))
        expect(state.state).to eq("reviewing")
        expect(state.review).to eq("round" => 1, "delivery" => nil, "held" => "waiting_lock")
        expect(state.review_rounds).to be_nil
        expect(context.review).to be_nil
        expect(dispatch.calls).to eq([[:hold_round, "wr_1", {round: 1}], [:hold_round_lock, "wr_1", {round: 1, step_state: "reviewing"}]])
      end

      it "asks the lock again on a wake, still the same round, never ending it as a stopped one" do
        waiting = progress.pass_step(run_hash(definition_steps: steps("review" => review)), ctx: ctx)
        context = ctx

        run = progress.restart_review(waiting, ctx: context)

        expect(run.step("plan").review).to eq("round" => 1, "delivery" => nil, "held" => "waiting_lock")
        expect(run.step("plan").last_attempt.to_h["rounds"]).to be_nil
        expect(context.review).to be_nil
      end

      context "once the lock is free" do
        let(:dispatch) { RecordingDispatch.new }

        it "starts that round on the wake, spending it then" do
          waiting = reviewing_hash("state" => "waiting", "reason" => {"code" => "waiting_lock", "since" => "2026-11-10T11:55:00Z", "details" => {"review_round" => 2}})
          waiting["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => "waiting_lock"}
          context = ctx

          run = progress.restart_review(waiting, ctx: context)

          expect(run.step("plan").review_rounds).to eq(2)
          expect(run.step("plan").review).to include("round" => 2, "delivery" => "delivering")
          expect(run.reason).to be_nil
          expect(run.state).to eq("running")
          expect(run.step("plan").last_attempt.to_h["rounds"]).to be_nil
          expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
        end
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
            expect(state.review).to eq("round" => 1, "delivery" => nil, "held" => code)
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
          expect(state.review).to eq("round" => 2, "delivery" => nil, "held" => "budget_spent")
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
        held["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => "budget_spent"}
        context = ctx

        run = progress.restart_review(held, ctx: context)

        state = run.step("plan")
        expect(state.review_rounds).to eq(2)
        expect(state.review).to include("round" => 2, "delivery" => "delivering", "started_at" => "2026-11-10T12:00:00.000Z")
        expect(state.last_attempt.to_h["rounds"]).to be_nil
        expect(context.review).to eq("step" => "plan", "attempt" => 1, "round" => 2)
        expect(change.events).to eq([["wr_1", "review_started", {"step" => "plan", "attempt" => 1, "round" => 2}]])
      end

      it "ends a held round on cancel with no round record and no review_ended, closing a window an earlier round left by its mark" do
        held = reviewing_hash
        held["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => "budget_spent"}
        context = ctx

        run = progress.end_round(held, how: "cancelled", ctx: context)

        expect(run.step("plan").review).to be_nil
        expect(run.step("plan").last_attempt.to_h["rounds"]).to be_nil
        expect(attempt_record.calls).to be_empty
        expect(change.events).to be_empty
        expect(context.close_review).to eq("workspace" => "app", "step" => "plan", "round" => 2, "pane" => nil)
        expect(panes.calls).to eq([[:unbind, "wr_1", {role: "reviewer"}]])
      end
    end
  end
end
