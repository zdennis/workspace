require "spec_helper"

RSpec.describe Workspace::WorkflowRecovery do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:busy) { [] }
  let(:change) { RecordingRunChange.new(store.runs, busy: busy) }
  let(:dispatch) { RecordingDispatch.new }
  let(:progress) { RecordingProgress.new }
  let(:evaluation) { RecordingEvaluation.new(store.runs) }
  let(:clock_at) { [now] }

  def recovery
    described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { clock_at.first })
  end

  def run_hash(state: "running", step_state: "running", reason: nil, attempt: {}, extra: {})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "worktree" => "/work/app", "artifacts_dir" => "/work/app/.workflow/wr_1",
     "state" => state, "current" => "build", "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => reason,
     "definition" => {"id" => "flow", "max_attempts" => 5, "redeliver" => 2,
                      "steps" => [{"id" => "build", "produces" => [], "status" => {"command" => "rake", "timeout" => 60}}]},
     "steps" => {"build" => {"state" => step_state, "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}.merge(attempt)]}}}.merge(extra)
  end

  def stored(hash = run_hash)
    store.runs[hash["id"]] = hash
  end

  def backoff_wait(until_at: "2026-11-10T11:59:00Z")
    {"until" => until_at, "to" => "build", "text" => "try again", "context" => []}
  end

  def undelivered
    run_hash(state: "waiting", step_state: "waiting",
      reason: {"code" => "waiting_you", "since" => "2026-11-10T11:00:05Z", "details" => {"kind" => "dispatch", "error" => "pane_busy"}},
      attempt: {"outcome" => "not_delivered", "ended_at" => "2026-11-10T11:00:05Z"})
  end

  def event_types = change.events.map { |_, type, data| [type, data] }

  describe "#tick" do
    it "starts the retry of a backoff that is over and answers a WorkflowRun" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait}))

      run = recovery.tick("wr_1")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(progress.calls).to eq([[:start_retry, "build", backoff_wait, {proven: false, budgeted: true}]])
      expect(store.runs["wr_1"]).not_to have_key("backoff")
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: true}]])
    end

    it "asks again for the lock a run waits on" do
      stored(run_hash(state: "waiting", reason: {"code" => "waiting_lock", "details" => {}}))

      recovery.tick("wr_1")

      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}]])
      expect(change.deliveries).to eq([{"step" => "build"}])
    end

    it "turns a background hold that ran out into a turn_ended_incomplete stop" do
      hold = {"code" => "turn_ended_background", "since" => "2026-11-10T09:00:00Z", "seen_at" => "2026-11-10T10:00:00Z",
              "details" => {"step" => "build", "attempt" => 1, "missing" => ["out.md"], "tasks" => [{"id" => "t1"}], "other" => 1}}
      stored(run_hash(reason: hold))

      run = recovery.tick("wr_1")

      expect(run.reason).to eq("code" => "turn_ended_incomplete", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "build", "attempt" => 1, "missing" => ["out.md"], "background_tasks" => [{"id" => "t1"}]})
    end

    it "runs again a check that never reported back, the check outside the lock" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"kind" => "status"})
      stored(run_hash(step_state: "checking", attempt: {"check" => {"started_at" => "2026-11-10T11:00:00Z"}}))

      run = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now }).tick("wr_1")

      expect(run.id).to eq("wr_1")
      expect(evaluation.calls).to eq([[:evaluate, "build"], [:finish_check, "wr_1", {"kind" => "status"}]])
    end

    it "answers nil for a run nothing wakes" do
      stored

      expect(recovery.tick("wr_1")).to be_nil
      expect(progress.calls + dispatch.calls + evaluation.calls).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers nil" do
        stored(run_hash(state: "waiting", reason: {"code" => "waiting_lock", "details" => {}}))

        expect(recovery.tick("wr_1")).to be_nil
        expect(dispatch.calls).to be_empty
      end
    end
  end

  describe "#note_stall" do
    it "records a cause once for the attempt" do
      stored

      expect(recovery.note_stall("wr_1", step: "build", attempt: 1, cause: "pane_gone", data: {"pane" => "%3"})).to eq(:recorded)
      expect(recovery.note_stall("wr_1", step: "build", attempt: 1, cause: "pane_gone")).to eq(:repeat)

      expect(event_types).to eq([["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "pane_gone", "pane" => "%3"}]])
      expect(store.runs["wr_1"]["sweep"]).to eq("step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => "2026-11-10T12:00:00Z"}, "recovered" => {})
    end

    it "changes nothing once the run is on another attempt" do
      stored

      expect(recovery.note_stall("wr_1", step: "build", attempt: 2, cause: "pane_gone")).to eq(:moved_on)
      expect(change.events).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy" do
        stored

        expect(recovery.note_stall("wr_1", step: "build", attempt: 1, cause: "pane_gone")).to eq(:busy)
      end
    end
  end

  describe "#note_recovery" do
    it "records the recovery only of a cause that was noted, and waits for the lock" do
      stored

      expect(recovery.note_recovery("wr_1", step: "build", attempt: 1, cause: "daemon_down", action: "daemon_respawned")).to eq(:repeat)
      recovery.note_stall("wr_1", step: "build", attempt: 1, cause: "daemon_down")
      expect(recovery.note_recovery("wr_1", step: "build", attempt: 1, cause: "daemon_down", action: "daemon_respawned")).to eq(:recorded)

      expect(event_types.last).to eq(["step_recovered", {"step" => "build", "attempt" => 1, "action" => "daemon_respawned"}])
      expect(change.calls.first).to eq([:call, "wr_1", {nonblocking: false}])
    end
  end

  describe "#recover" do
    it "decides a turn that ended unseen and runs the check it registers" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"kind" => "status"})
      stored

      outcome = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now })
        .recover("wr_1", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over")

      expect(outcome).to eq(:evaluated)
      expect(evaluation.calls).to eq([[:evaluate, "build"], [:finish_check, "wr_1", {"kind" => "status"}]])
      expect(event_types.map(&:first)).to eq(%w[step_stalled step_recovered])
    end

    it "fails a step past its timeout when the decision is a turn_ended_incomplete stop" do
      evaluation = RecordingEvaluation.new(store.runs, reason: {"code" => "turn_ended_incomplete", "details" => {}})
      stored

      outcome = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now })
        .recover("wr_1", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over", fail_if_incomplete: {"elapsed" => 900.4, "timeout" => 600})

      expect(outcome).to eq(:timed_out)
      expect(progress.calls).to eq([[:fail_step, "build", {"cause" => "timeout", "timeout" => 600, "elapsed" => 900, "code" => "step_timed_out", "code_source" => "engine"}]])
    end

    it "leaves a step that is no longer running alone" do
      stored(run_hash(step_state: "checking"))

      expect(recovery.recover("wr_1", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over")).to eq(:moved_on)
      expect(evaluation.calls).to be_empty
    end
  end

  describe "#time_out" do
    it "fails a step held on turn_ended_incomplete with step_timed_out" do
      stored(run_hash(reason: {"code" => "turn_ended_incomplete", "details" => {}}))

      expect(recovery.time_out("wr_1", step: "build", attempt: 1, elapsed: 700, timeout: 600)).to eq(:timed_out)

      expect(progress.calls).to eq([[:fail_step, "build", {"cause" => "timeout", "timeout" => 600, "elapsed" => 700, "code" => "step_timed_out", "code_source" => "engine"}]])
      expect(event_types).to eq([
        ["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "timed_out", "elapsed" => 700, "timeout" => 600}],
        ["step_recovered", {"step" => "build", "attempt" => 1, "action" => "failed"}]
      ])
      expect(store.runs["wr_1"]["steps"]["build"]["state"]).to eq("failed")
    end
  end

  describe "#redeliver" do
    let(:dispatch) { RecordingDispatch.new(appends: true) }

    it "marks the failed attempt redelivered, starts a new one outside the budget and records the recovery" do
      stored(undelivered)

      expect(recovery.redeliver("wr_1", step: "build", attempt: 1)).to eq(:redelivered)

      build = store.runs["wr_1"]["steps"]["build"]
      expect(build["attempts"].first).to include("redelivered" => true)
      expect(build["redelivery_pending"]).to eq(1)
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: false, retry_of: nil}]])
      expect(event_types).to eq([["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "undelivered", "code" => "pane_busy", "retry" => 1, "of" => 2}]])
      expect(store.events).to eq([["wr_1", "step_recovered", {"step" => "build", "attempt" => 1, "action" => "redelivered"}]])
    end

    context "when the line was refused again" do
      let(:dispatch) { RecordingDispatch.new }

      it "answers :not_delivered and records no recovery" do
        stored(undelivered)

        expect(recovery.redeliver("wr_1", step: "build", attempt: 1)).to eq(:not_delivered)
        expect(store.events).to be_empty
      end
    end

    it "does nothing before the retry is due" do
      clock_at.replace([Time.utc(2026, 11, 10, 11, 0, 30)])
      stored(undelivered)

      expect(recovery.redeliver("wr_1", step: "build", attempt: 1)).to eq(:moved_on)
      expect(dispatch.calls).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy" do
        stored(undelivered)

        expect(recovery.redeliver("wr_1", step: "build", attempt: 1)).to eq(:busy)
      end
    end
  end

  describe "#retry_backoff" do
    it "starts a retry whose wait is over" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait}))

      expect(recovery.retry_backoff("wr_1", step: "build", attempt: 1)).to eq(:retried)
      expect(progress.calls.map(&:first)).to eq([:start_retry])
    end

    it "answers :held when the retry is held on the token budget" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait, "budget_hold" => {"to" => "build"}}))

      expect(recovery.retry_backoff("wr_1", step: "build", attempt: 1)).to eq(:held)
    end

    it "leaves a wait that is not over" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait(until_at: "2026-11-10T12:05:00Z")}))

      expect(recovery.retry_backoff("wr_1", step: "build", attempt: 1)).to eq(:moved_on)
      expect(progress.calls).to be_empty
    end
  end

  describe "#claim_interrupt and #interrupt_sent" do
    it "claims the interrupt once and records it sent" do
      stored

      outcome = recovery.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 700, timeout: 600)
      expect(outcome).to eq([:claimed, "2026-11-10T12:00:00Z"])
      expect(recovery.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 700, timeout: 600)).to eq(:repeat)

      expect(recovery.interrupt_sent("wr_1", step: "build", attempt: 1, claim_at: outcome.last, sent: true)).to eq(:recorded)
      expect(store.runs["wr_1"]["sweep"]["interrupt"]).to eq("state" => "sent", "at" => "2026-11-10T12:00:00Z")
      expect(event_types.map(&:first)).to eq(%w[step_stalled step_recovered])
    end

    it "lets a later sweep take over a pending claim past its hold" do
      stored
      recovery.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 700, timeout: 600)
      clock_at.replace([now + described_class::INTERRUPT_CLAIM_SECONDS + 1])

      expect(recovery.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 761, timeout: 600)).to eq([:claimed, "2026-11-10T12:01:01Z"])
    end

    it "gives a claim back when the keys were not pressed, and leaves one taken over" do
      stored
      _, at = recovery.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 700, timeout: 600)

      expect(recovery.interrupt_sent("wr_1", step: "build", attempt: 1, claim_at: "2026-11-10T11:00:00Z", sent: true)).to eq(:taken_over)
      expect(recovery.interrupt_sent("wr_1", step: "build", attempt: 1, claim_at: at, sent: false)).to eq(:released)
      expect(store.runs["wr_1"]["sweep"]).not_to have_key("interrupt")
    end
  end
end
