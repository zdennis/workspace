require "spec_helper"

RSpec.describe Workspace::WorkflowDecisions do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs, finished: finished) }
  let(:finished) { [] }
  let(:progress) { RecordingProgress.new }
  let(:dispatch) { RecordingDispatch.new(busy: ["%9"]) }
  let(:evaluation) { RecordingEvaluation.new(store.runs) }
  let(:attempt_record) { RecordingAttemptRecord.new }
  let(:gate_note) { RecordingGateNote.new }
  let(:panes) { RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, runs_on: {"%3" => "wr_1"}) }

  def decisions
    described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
      attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: -> { now })
  end

  def run_hash(id: "wr_1", current: "plan", state: "running", gate: nil, reason: nil, max_attempts: 5, extra: {})
    plan = {"state" => (current == "plan") ? state : "passed", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}]}
    plan["gate"] = gate if gate && current == "plan"
    build = {"state" => (current == "build") ? state : "pending", "attempts" => []}
    build["attempts"] << {"n" => 1, "started_at" => "2026-11-10T11:30:00Z"} if current == "build"
    build["gate"] = gate if gate && current == "build"
    {"id" => id, "workflow" => "flow", "workspace" => "app", "worktree" => "/work/app", "artifacts_dir" => "/work/app/.workflow/#{id}",
     "state" => "running", "current" => current, "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => reason,
     "definition" => {"id" => "flow", "max_attempts" => max_attempts,
                      "steps" => [{"id" => "plan", "produces" => ["plan.md"], "gate" => true}, {"id" => "build", "produces" => [], "gate" => true}]},
     "steps" => {"plan" => plan, "build" => build}}.merge(extra)
  end

  def stored(hash = run_hash)
    store.runs[hash["id"]] = hash
  end

  def waiting_gate = {"state" => "waiting", "since" => "2026-11-10T11:50:00Z"}

  def failed_check = {"code" => "failed_check", "since" => "2026-11-10T11:55:00Z", "details" => {"cause" => "check", "exit_code" => 1, "code" => "check_failed"}}

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def error_for
    yield
  rescue Workspace::Error, Workspace::UsageError => e
    e
  end

  describe "#approve" do
    it "passes the waiting gate with the note and goes on to the next step, answering a WorkflowRun" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      run = decisions.approve("wr_1", note: "looks right")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(run.steps["plan"].gate).to eq("state" => "approved", "since" => "2026-11-10T11:50:00Z", "at" => "2026-11-10T12:00:00Z", "note" => "looks right")
      expect(run.pending_context).to eq(["The plan step was approved with this note: looks right"])
      expect(change.events).to eq([["wr_1", "gate_approved", {"step" => "plan", "note" => "looks right"}]])
      expect(progress.calls).to eq([[:advance, "plan"]])
    end

    it "records the gate's note and its sha256 when the caller read the same revision" do
      gate_note = RecordingGateNote.new(found: {"name" => "plan-note.md", "path" => "/notes/plan-note.md", "sha256" => "abc123"})
      stored(run_hash(state: "passed", gate: waiting_gate))

      run = described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: -> { now }).approve("wr_1", note_sha256: "abc123")

      expect(run.steps["plan"].gate["file"]).to eq("path" => "/notes/plan-note.md", "sha256" => "abc123")
      expect(run.pending_context).to eq(["The approved note is /notes/plan-note.md, sha256 abc123."])
      expect(change.events).to eq([["wr_1", "gate_approved", {"step" => "plan", "sha256" => "abc123"}]])
    end

    it "refuses a note that changed since the caller read it and leaves the run as it was" do
      gate_note = RecordingGateNote.new(found: {"name" => "plan-note.md", "path" => "/notes/plan-note.md", "sha256" => "new"})
      before = deep_copy(stored(run_hash(state: "passed", gate: waiting_gate)))

      error = error_for do
        described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
          attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: -> { now }).approve("wr_1", note_sha256: "old")
      end

      expect(error.code).to eq("stale_revision")
      expect(error.details).to include("revision" => "new", "path" => "/notes/plan-note.md", "step" => "plan", "attempt" => 1)
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
      expect(progress.calls).to be_empty
    end

    it "refuses a sha256 for a gate that names no note" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      expect(error_for { decisions.approve("wr_1", note_sha256: "abc") }.code).to eq("gate_note_unreadable")
    end

    it "refuses a gate the run is not at before the guard is asked" do
      stored(run_hash(state: "passed", gate: waiting_gate))
      asked = []

      error = error_for { decisions.approve("wr_1", step: "build", guard: ->(run) { asked << run }) }

      expect(error.code).to eq("gate_not_waiting")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1, "state" => "passed", "expected_step" => "build", "expected_attempt" => nil)
      expect(asked).to be_empty
    end
  end

  describe "#reject" do
    it "sends the run back to an earlier step with the note and starts it" do
      stored(run_hash(current: "build", state: "passed", gate: waiting_gate))

      run = decisions.reject("wr_1", note: "the plan misses a case", to: "plan")

      expect(run.current).to eq("plan")
      expect(run.steps["build"].gate).to include("state" => "rejected", "note" => "the plan misses a case", "attempt" => 1)
      expect(run.pending_context).to eq(["The build step was rejected at its gate: the plan misses a case"])
      expect(change.events).to eq([["wr_1", "gate_rejected", {"step" => "build", "to" => "plan", "note" => "the plan misses a case"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}]])
      expect(change.deliveries).to eq([{"step" => "plan"}])
    end

    it "refuses a --to past the gated step" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      expect { decisions.reject("wr_1", note: "no", to: "build") }.to raise_error(Workspace::UsageError, /--to must be plan or a step before it \(plan\)/)
      expect(dispatch.calls).to be_empty
    end

    it "refuses a run that has spent its attempts unless --extra-attempts covers it, and records what was added" do
      stored(run_hash(state: "passed", gate: waiting_gate, max_attempts: 1))

      error = error_for { decisions.reject("wr_1", note: "again") }
      expect(error.code).to eq("attempts_spent")
      expect(error.details).to eq("run_id" => "wr_1", "attempts" => 1, "max_attempts" => 1, "step" => "plan", "needed" => 1)

      run = decisions.reject("wr_1", note: "again", extra_attempts: 1)
      expect(run.extra_attempts).to eq(1)
      expect(change.events.first).to eq(["wr_1", "attempts_extended", {"extra" => 1, "extra_attempts" => 1, "max_attempts" => 2}])
    end
  end

  describe "#resume" do
    it "leaves alone a step an agent is working on and says why, in a frozen Resumed" do
      before = deep_copy(stored)

      resumed = decisions.resume("wr_1")

      expect(resumed).to be_a(described_class::Resumed)
      expect(resumed).to be_frozen
      expect(resumed.unchanged).to eq("an agent is working on step plan")
      expect(resumed.run.to_h).to eq(before)
      expect(change.events).to be_empty
      expect(dispatch.calls).to be_empty
    end

    it "runs a failed step again, telling it what failed" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting"}))

      resumed = decisions.resume("wr_1")

      expect(resumed.unchanged).to be_nil
      expect(resumed.run.pending_context.first).to start_with("The last attempt of this step failed: ")
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "failed"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}]])
    end

    it "decides a running step whose turn ended, and runs the check it registers once the change is done" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"step" => "plan", "attempt" => 1})
      stored(run_hash(reason: {"code" => "turn_ended_incomplete", "since" => "2026-11-10T11:58:00Z", "details" => {}}))

      resumed = described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: -> { now }).resume("wr_1")

      expect(evaluation.calls).to eq([[:evaluate, "plan"], [:finish_check, "wr_1", {"step" => "plan", "attempt" => 1}]])
      expect(resumed.run.reason).to be_nil
      expect(resumed.unchanged).to be_nil
    end

    it "starts again at the step --from names" do
      stored

      resumed = decisions.resume("wr_1", from: "build")

      expect(resumed.run.current).to eq("build")
      expect(change.events).to eq([["wr_1", "run_resumed", {"from" => "build"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}]])
    end

    it "skips a retry's wait and starts the retry" do
      backoff = {"until" => "2026-11-10T13:00:00Z", "to" => "plan", "text" => "it failed", "pane" => "%3"}
      stored(run_hash(state: "failed", extra: {"backoff" => backoff, "state" => "waiting"}))

      resumed = decisions.resume("wr_1")

      expect(resumed.unchanged).to be_nil
      expect(progress.calls).to eq([[:retry_pane_problem, "plan", {proven: false, pane: nil}], [:start_retry, "plan", backoff, {proven: false, budgeted: true}]])
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "failed", "backoff" => "skipped"}]])
      expect(resumed.run.backoff).to be_nil
    end

    it "holds a retry whose pane is no longer the run's, writing no event, and says why" do
      progress = RecordingProgress.new(pane_problem: {code: "pane_gone", message: "pane %3 is gone"})
      stored(run_hash(state: "failed", extra: {"backoff" => {"until" => "2026-11-10T13:00:00Z", "to" => "plan"}, "state" => "waiting"}))

      resumed = described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, clock: -> { now }).resume("wr_1")

      expect(resumed.unchanged).to eq("pane %3 is gone")
      expect(progress.calls.last).to eq([:hold_retry, "plan", {code: "pane_gone", message: "pane %3 is gone"}, {pane: "%3"}])
      expect(change.events).to be_empty
      expect(dispatch.calls).to be_empty
    end

    it "releases a run its token budget held into its step, with the held context" do
      stored(run_hash(state: "failed", extra: {"budget_hold" => {"context" => "fresh", "pane" => "%3"}, "state" => "waiting"}))

      resumed = decisions.resume("wr_1")

      expect(resumed.run.budget_hold).to be_nil
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "budget" => "released"}]])
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {context: "fresh", budgeted: true, retry_of: nil}])
    end

    it "moves the run to a pane a person names, and refuses one another run has before writing anything" do
      before = deep_copy(stored)

      expect(error_for { decisions.resume("wr_1", pane: "%9") }.code).to eq("pane_has_run")
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty

      resumed = decisions.resume("wr_1", pane: "%8")
      expect(resumed.run.pane).to eq("%8")
      expect(panes.calls).to eq([[:unbind, "wr_1"]])
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {context: nil, budgeted: true, retry_of: nil}])
    end

    it "takes over from a parked resume" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => {"id" => "p1", "pane" => "%3"}}))

      resumed = decisions.resume("wr_1")

      expect(dispatch.calls.first).to eq([:drop_park, "wr_1", "taken_over", {}])
      expect(resumed.run.parked).to be_nil
    end

    it "refuses a resume that would start an attempt the run has none left for" do
      stored(run_hash(state: "failed", reason: failed_check, max_attempts: 1))

      expect(error_for { decisions.resume("wr_1") }.code).to eq("attempts_spent")
      expect(decisions.resume("wr_1", extra_attempts: 2).run.extra_attempts).to eq(2)
    end
  end

  describe "#apply_resume" do
    it "leaves the run it is given as it is and registers the line on the context" do
      hash = stored(run_hash(state: "failed", reason: failed_check))
      before = deep_copy(hash)
      ctx = Workspace::WorkflowRunChange::Context.new

      resumed = decisions.apply_resume(hash, ctx: ctx, from: nil, note: "try again", pane: nil, turn_over: nil, budget: false)

      expect(hash).to eq(before)
      expect(resumed.run.pending_context.last).to eq("Note from the person who resumed the run: try again")
      expect(ctx.delivery).to eq("step" => "plan")
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {context: nil, budgeted: false, retry_of: nil}])
    end
  end

  describe "#refuse_resume" do
    it "refuses a run at a gate when no step is named" do
      error = error_for { decisions.refuse_resume(Workspace::WorkflowRun.from_h(run_hash(state: "passed", gate: waiting_gate))) }

      expect(error.code).to eq("gate_waiting")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan")
    end

    it "refuses a step the workflow does not have, and lets a known one through" do
      expect { decisions.refuse_resume(run_hash, from: "ship") }.to raise_error(Workspace::UsageError, 'No step "ship" in workflow flow (plan, build).')
      expect { decisions.refuse_resume(run_hash(state: "passed", gate: waiting_gate), from: "plan") }.not_to raise_error
    end
  end

  describe "#refuse_budget" do
    let(:spent) do
      run_hash(state: "failed").tap do |hash|
        hash["definition"]["budget"] = {"tokens" => 100}
        hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:10:00Z", "usage" => {"input_tokens" => 150})
      end
    end

    it "refuses a run whose token budget is used up unless --extra-tokens covers it" do
      error = error_for { decisions.refuse_budget(spent, extra_attempts: nil, extra_tokens: 50) }

      expect(error.code).to eq("budget_spent")
      expect(error.message).to include("(150 of 100 tokens)", "(51 is the least)")
      expect { decisions.refuse_budget(spent, extra_attempts: nil, extra_tokens: 51) }.not_to raise_error
    end

    it "refuses spent attempts first" do
      spent["definition"]["max_attempts"] = 1

      expect(error_for { decisions.refuse_budget(spent, extra_attempts: nil, extra_tokens: nil) }.code).to eq("attempts_spent")
    end
  end

  describe "#cancel" do
    it "closes the open attempt, ends the run and records who ended it" do
      stored

      run = decisions.cancel("wr_1")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(attempt_record.calls).to eq([[:abandon, "wr_1"]])
      expect(progress.calls).to eq([[:finish, "wr_1", "cancelled"]])
      expect(run.state).to eq("cancelled")
      expect(run.cancelled_by).to eq("cancel")
      expect(run.steps["plan"].last_attempt.outcome).to eq("abandoned")
      expect(change.events).to eq([["wr_1", "run_cancelled", {"cause" => "cancel"}]])
    end
  end

  describe "#workspace_killed" do
    it "cancels the killed workspace's runs, and no other's, as a kill" do
      stored(run_hash(id: "wr_1", extra: {"workspace" => "app.worktree-a"}))
      stored(run_hash(id: "wr_2", extra: {"workspace" => "app.worktree-b"}))

      expect(decisions.workspace_killed("app.worktree-a")).to eq("cancelled" => ["wr_1"], "failed" => [])
      expect(store.runs["wr_1"]).to include("state" => "cancelled", "cancelled_by" => "kill")
      expect(store.runs["wr_2"]["state"]).to eq("running")
    end

    context "when a run can't be ended" do
      let(:finished) { ["wr_1"] }

      it "names it and ends the others" do
        stored(run_hash(id: "wr_1", extra: {"workspace" => "app.worktree-a"}))
        stored(run_hash(id: "wr_2", extra: {"workspace" => "app.worktree-a"}))

        expect(decisions.workspace_killed("app.worktree-a")).to eq("cancelled" => ["wr_2"], "failed" => ["wr_1"])
      end
    end

    it "raises nothing when the runs can't be listed" do
      allow(store).to receive(:going).and_raise(NoMethodError, "undefined method for nil")

      expect(decisions.workspace_killed("app")).to eq("cancelled" => [], "failed" => [])
    end
  end
end
