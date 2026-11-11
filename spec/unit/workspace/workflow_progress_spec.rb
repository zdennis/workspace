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
      run = progress.finish(run_hash("parked" => {"id" => "p1"}, "backoff" => {"to" => "plan"}, "budget_hold" => {}, "reason" => {"code" => "waiting_you"}), "cancelled")

      expect(run.to_h).not_to include("parked", "backoff", "budget_hold")
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
end
