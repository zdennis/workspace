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
  let(:guard) { RecordingGuard.new(head: "b" * 40) }
  let(:panes) { RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, runs_on: {"%3" => "wr_1"}) }
  let(:interrupter) { ->(*) { raise Workspace::Error, "no key presser in this spec" } }

  def decisions
    described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
      attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now })
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

      run = decisions.approve("wr_1", actor: "person", note: "looks right")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(run.steps["plan"].gate).to eq("state" => "approved", "since" => "2026-11-10T11:50:00Z", "at" => "2026-11-10T12:00:00Z", "note" => "looks right")
      expect(run.pending_context).to eq(["The plan step was approved with this note: looks right"])
      expect(change.events).to eq([["wr_1", "gate_approved", {"step" => "plan", "note" => "looks right"}]])
      expect(progress.calls).to eq([[:advance, "plan"]])
    end

    it "hands the actor it was given to the change" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      decisions.approve("wr_1", actor: "person")

      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false, actor: "person", cause: "approve"}]])
    end

    it "records the gate's note and its sha256 when the caller read the same revision" do
      gate_note = RecordingGateNote.new(found: {"name" => "plan-note.md", "path" => "/notes/plan-note.md", "sha256" => "abc123"})
      stored(run_hash(state: "passed", gate: waiting_gate))

      run = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).approve("wr_1", actor: "person", note_sha256: "abc123")

      expect(run.steps["plan"].gate["file"]).to eq("path" => "/notes/plan-note.md", "sha256" => "abc123")
      expect(run.pending_context).to eq(["The approved note is /notes/plan-note.md, sha256 abc123."])
      expect(change.events).to eq([["wr_1", "gate_approved", {"step" => "plan", "sha256" => "abc123"}]])
    end

    it "refuses a note that changed since the caller read it and leaves the run as it was" do
      gate_note = RecordingGateNote.new(found: {"name" => "plan-note.md", "path" => "/notes/plan-note.md", "sha256" => "new"})
      before = deep_copy(stored(run_hash(state: "passed", gate: waiting_gate)))

      error = error_for do
        described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
          attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).approve("wr_1", actor: "person", note_sha256: "old")
      end

      expect(error.code).to eq("stale_revision")
      expect(error.details).to include("revision" => "new", "path" => "/notes/plan-note.md", "step" => "plan", "attempt" => 1)
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
      expect(progress.calls).to be_empty
    end

    it "refuses a sha256 for a gate that names no note" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      expect(error_for { decisions.approve("wr_1", actor: "person", note_sha256: "abc") }.code).to eq("gate_note_unreadable")
    end

    it "refuses a gate the run is not at before the guard is asked" do
      stored(run_hash(state: "passed", gate: waiting_gate))
      asked = []

      error = error_for { decisions.approve("wr_1", actor: "person", step: "build", guard: ->(run) { asked << run }) }

      expect(error.code).to eq("gate_not_waiting")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1, "state" => "passed", "expected_step" => "build", "expected_attempt" => nil)
      expect(asked).to be_empty
    end
  end

  describe "#reject" do
    it "hands the actor it was given to the change" do
      stored(run_hash(current: "build", state: "passed", gate: waiting_gate))

      decisions.reject("wr_1", actor: "person", note: "no", to: "plan")

      expect(change.calls.map(&:last)).to eq([{nonblocking: false, actor: "person", cause: "reject"}])
    end

    it "sends the run back to an earlier step with the note and starts it" do
      stored(run_hash(current: "build", state: "passed", gate: waiting_gate))

      run = decisions.reject("wr_1", actor: "person", note: "the plan misses a case", to: "plan")

      expect(run.current).to eq("plan")
      expect(run.steps["build"].gate).to include("state" => "rejected", "note" => "the plan misses a case", "attempt" => 1)
      expect(run.pending_context).to eq(["The build step was rejected at its gate: the plan misses a case"])
      expect(change.events).to eq([["wr_1", "gate_rejected", {"step" => "build", "to" => "plan", "note" => "the plan misses a case"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "gate_rejected", context: nil, budgeted: true, retry_of: nil}]])
      expect(change.deliveries).to eq([{"step" => "plan"}])
    end

    it "refuses a --to past the gated step" do
      stored(run_hash(state: "passed", gate: waiting_gate))

      expect { decisions.reject("wr_1", actor: "person", note: "no", to: "build") }.to raise_error(Workspace::UsageError, /--to must be plan or a step before it \(plan\)/)
      expect(dispatch.calls).to be_empty
    end

    it "refuses a run that has spent its attempts unless --extra-attempts covers it, and records what was added" do
      stored(run_hash(state: "passed", gate: waiting_gate, max_attempts: 1))

      error = error_for { decisions.reject("wr_1", actor: "person", note: "again") }
      expect(error.code).to eq("attempts_spent")
      expect(error.details).to eq("run_id" => "wr_1", "attempts" => 1, "max_attempts" => 1, "step" => "plan", "needed" => 1)

      run = decisions.reject("wr_1", actor: "person", note: "again", extra_attempts: 1)
      expect(run.extra_attempts).to eq(1)
      expect(change.events.first).to eq(["wr_1", "attempts_extended", {"extra" => 1, "extra_attempts" => 1, "max_attempts" => 2}])
    end
  end

  describe "a step's own max_attempts" do
    def capped(state:, run_cap: 5, **opts)
      hash = run_hash(state: state, max_attempts: run_cap, **opts)
      hash["definition"]["steps"][0]["max_attempts"] = 1
      stored(hash)
    end

    it "refuses a reject to the spent step with step_attempts_spent, and --extra-attempts raises both caps once" do
      capped(state: "passed", gate: waiting_gate)

      error = error_for { decisions.reject("wr_1", actor: "person", note: "again") }
      expect(error.code).to eq("step_attempts_spent")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempts" => 1, "max_attempts" => 1, "needed" => 1)

      run = decisions.reject("wr_1", actor: "person", note: "again", extra_attempts: 1)
      expect(run.extra_attempts).to eq(1)
      expect(run.steps["plan"].to_h["extra_attempts"]).to eq(1)
      expect(change.events.first).to eq(["wr_1", "attempts_extended", {"extra" => 1, "extra_attempts" => 1, "max_attempts" => 6, "step" => "plan", "step_extra_attempts" => 1, "step_max_attempts" => 2}])
    end

    it "does not refuse a reject to an earlier step that has no cap" do
      hash = run_hash(state: "passed", current: "build", gate: waiting_gate, max_attempts: 5)
      hash["definition"]["steps"][1]["max_attempts"] = 1
      stored(hash)

      expect(decisions.reject("wr_1", actor: "person", note: "again", to: "plan")).to be_a(Workspace::WorkflowRun)
    end

    it "names the run's cap first when both are spent" do
      capped(state: "passed", gate: waiting_gate, run_cap: 1)

      expect(error_for { decisions.reject("wr_1", actor: "person", note: "x") }.code).to eq("attempts_spent")
    end

    it "names the step's need when --extra-attempts covers only the run's cap" do
      hash = run_hash(state: "failed", reason: failed_check, max_attempts: 2)
      hash["definition"]["steps"][0]["max_attempts"] = 1
      hash["steps"]["plan"]["attempts"] << {"n" => 2}
      hash["steps"]["plan"]["attempts"] << {"n" => 3}
      stored(hash)

      expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("attempts_spent")
      error = error_for { decisions.resume("wr_1", actor: "person", extra_attempts: 2) }
      expect(error.code).to eq("step_attempts_spent")
      expect(error.details["needed"]).to eq(3)
      expect(decisions.resume("wr_1", actor: "person", extra_attempts: 3).run.extra_attempts).to eq(3)
    end

    it "refuses a resume of the spent step and accepts it once with --extra-attempts, naming the new need after" do
      capped(state: "failed", reason: failed_check)

      error = error_for { decisions.resume("wr_1", actor: "person") }
      expect(error.code).to eq("step_attempts_spent")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempts" => 1, "max_attempts" => 1, "needed" => 1)
      expect(decisions.resume("wr_1", actor: "person", extra_attempts: 1).run.steps["plan"].to_h["extra_attempts"]).to eq(1)
    end

    it "checks --from against the step it goes to" do
      capped(state: "failed", reason: failed_check, current: "build")

      expect(error_for { decisions.resume("wr_1", actor: "person", from: "plan") }.details).to include("step" => "plan")
    end

    it "refuses a park for the spent step" do
      capped(state: "failed", reason: failed_check)

      expect(error_for { decisions.park("wr_1", actor: "person") }.code).to eq("step_attempts_spent")
    end
  end

  describe "#resume" do
    it "leaves alone a step an agent is working on and says why, in a frozen Resumed" do
      before = deep_copy(stored)

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed).to be_a(described_class::Resumed)
      expect(resumed).to be_frozen
      expect(resumed.unchanged).to eq("an agent is working on step plan")
      expect(resumed.run.to_h).to eq(before)
      expect(change.events).to be_empty
      expect(dispatch.calls).to be_empty
    end

    it "hands the actor it was given to the change" do
      stored

      decisions.resume("wr_1", actor: "person")

      expect(change.calls.map(&:last)).to eq([{nonblocking: false, actor: "person", cause: "resume"}])
    end

    def reviewing_run(reason: nil)
      run = run_hash(state: "reviewing", extra: reason ? {"state" => "waiting"} : {})
      run["reason"] = reason
      run["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:50:00Z", "outcome" => "checks_passed")
      run["steps"]["plan"]["review_rounds"] = 1
      run["steps"]["plan"]["review"] = {"round" => 1, "delivery" => nil, "started_at" => "2026-11-10T11:50:00.000Z", "pane" => "%7"}
      run
    end

    def review_incomplete = {"code" => "review_incomplete", "since" => "2026-11-10T11:55:00Z", "details" => {}}

    it "leaves a live review round alone" do
      before = deep_copy(stored(reviewing_run))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed.unchanged).to eq("the review round of step plan is still running")
      expect(resumed.run.to_h).to eq(before)
      expect(progress.calls).to be_empty
      expect(evaluation.calls).to be_empty
    end

    context "with a round whose delivery mark lapsed" do
      let(:holder) { {"pid" => 41, "started" => "Tue Nov 10 11:00:00 2026"} }
      let(:alive) { [] }
      let(:seen) { [] }

      def lapsed
        reviewing_run.tap do |run|
          run["steps"]["plan"]["review"].merge!("delivery" => "delivering", "started_at" => "2026-11-10T11:50:00.000Z", "holder" => holder)
          run["steps"]["plan"]["review"].delete("pane")
        end
      end

      def decisions
        described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation, attempt_record: attempt_record,
          gate_note: gate_note, panes: panes, guard: guard, holder_alive: ->(found) { (seen << found) && alive.include?(found["pid"]) }, clock: -> { now })
      end

      it "takes over a round whose holder is gone, delivering it again" do
        stored(lapsed)

        resumed = decisions.resume("wr_1", actor: "person")

        expect(resumed.unchanged).to be_nil
        expect(seen).to eq([holder])
        expect(progress.calls).to eq([[:restart_review, "plan"]])
        expect(evaluation.calls).to eq([[:review_round, "wr_1", {"step" => "plan"}]])
      end

      it "leaves a slow delivery alone while its holder still runs" do
        alive << 41
        before = deep_copy(stored(lapsed))

        resumed = decisions.resume("wr_1", actor: "person")

        expect(resumed.unchanged).to eq("the review round of step plan is still running")
        expect(resumed.run.to_h).to eq(before)
        expect(progress.calls).to be_empty
      end

      it "asks nothing of a holder whose mark has not lapsed" do
        stored(lapsed.tap { |run| run["steps"]["plan"]["review"]["started_at"] = "2026-11-10T11:59:30.000Z" })

        expect(decisions.resume("wr_1", actor: "person").unchanged).to eq("the review round of step plan is still running")
        expect(seen).to be_empty
      end
    end

    it "restarts a stopped round and never starts the author again, nor asks the attempt allowance" do
      stored(reviewing_run(reason: review_incomplete).merge("definition" => run_hash(max_attempts: 1)["definition"]))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed.unchanged).to be_nil
      expect(progress.calls).to eq([[:restart_review, "plan"]])
      expect(dispatch.calls).to be_empty
      expect(evaluation.calls).to eq([[:review_round, "wr_1", {"step" => "plan"}]])
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "reviewing"}]])
    end

    describe "a step that has spent its review rounds" do
      def capped(run, rounds: 2)
        run["definition"]["steps"][0]["review"] = {"from" => %w[skeptic], "need" => 1, "max_rounds" => 2}
        run["steps"]["plan"]["review_rounds"] = rounds
        run
      end

      def rejected_run
        run = run_hash(state: "failed", extra: {"state" => "waiting"})
        run["reason"] = {"code" => "review_rejected", "since" => "2026-11-10T11:55:00Z", "details" => {"step" => "plan", "limit" => "rounds"}}
        run["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:50:00Z", "outcome" => "failed", "code" => "review_rejected")
        capped(run)
      end

      it "refuses a resume of a stopped round as review_rounds_spent, changing nothing" do
        before = deep_copy(stored(capped(reviewing_run(reason: review_incomplete))))

        error = error_for { decisions.resume("wr_1", actor: "person") }

        expect(error.code).to eq("review_rounds_spent")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "rounds" => 2, "max_rounds" => 2, "needed" => 1)
        expect(error.message).to include("has spent its review rounds (2 of 2 max_rounds)", "--extra-rounds 1", "workflow cancel wr_1")
        expect(store.runs["wr_1"]).to eq(before)
        expect(progress.calls).to be_empty
        expect(change.events).to be_empty
      end

      it "names the least --extra-rounds, and refuses one that falls short" do
        stored(capped(reviewing_run(reason: review_incomplete), rounds: 3))

        expect(error_for { decisions.resume("wr_1", actor: "person", extra_rounds: 1) }.details).to include("rounds" => 3, "needed" => 2)
        expect(progress.calls).to be_empty
        expect(change.events).to be_empty
      end

      it "restarts a stopped round once --extra-rounds covers the overrun, keeping the extra in the step and recording it" do
        stored(capped(reviewing_run(reason: review_incomplete)))

        decisions.resume("wr_1", actor: "person", extra_rounds: 1)

        expect(progress.calls).to eq([[:restart_review, "plan"]])
        expect(store.runs["wr_1"]["steps"]["plan"]["extra_rounds"]).to eq(1)
        expect(change.events).to include(["wr_1", "review_rounds_extended", {"step" => "plan", "extra" => 1, "extra_rounds" => 1, "max_rounds" => 3}])
        expect(Workspace::WorkflowTransitions.review_rounds_allowance(store.runs["wr_1"], "plan")).to eq(3)
      end

      it "adds the extra rounds to the allowance again on a later resume" do
        run = capped(reviewing_run(reason: review_incomplete), rounds: 3)
        run["steps"]["plan"]["extra_rounds"] = 1
        stored(run)

        decisions.resume("wr_1", actor: "person", extra_rounds: 2)

        expect(store.runs["wr_1"]["steps"]["plan"]["extra_rounds"]).to eq(3)
      end

      it "runs the author again for a step a review rejected once --extra-rounds covers the overrun" do
        stored(rejected_run)

        decisions.resume("wr_1", actor: "person", extra_rounds: 1)

        expect(store.runs["wr_1"]["steps"]["plan"]["extra_rounds"]).to eq(1)
        expect(dispatch.calls).not_to be_empty
      end

      it "ignores --extra-rounds on a step with rounds left: nothing added, no event, and a repeat does not stack" do
        stored(capped(reviewing_run(reason: review_incomplete), rounds: 1))

        decisions.resume("wr_1", actor: "person", extra_rounds: 2)

        expect(store.runs["wr_1"]["steps"]["plan"]).not_to have_key("extra_rounds")
        expect(change.events.map { |event| event[1] }).not_to include("review_rounds_extended")
      end

      it "with --from checks a spent reviewed step against --extra-rounds, and keeps today's behaviour with none" do
        run = capped(run_hash(state: "failed", extra: {"state" => "waiting"}))
        stored(run)

        expect { decisions.resume("wr_1", actor: "person", from: "plan") }.not_to raise_error
        error = error_for { decisions.resume("wr_1", actor: "person", from: "plan", extra_rounds: 0) }
        expect(error.code).to eq("review_rounds_spent")
        expect(error.details).to include("step" => "plan", "needed" => 1)
      end

      it "with --from credits --extra-rounds only to a spent step" do
        stored(capped(run_hash(state: "failed", extra: {"state" => "waiting"})))
        decisions.resume("wr_1", actor: "person", from: "plan", extra_rounds: 1)
        expect(store.runs["wr_1"]["steps"]["plan"]["extra_rounds"]).to eq(1)

        stored(capped(run_hash(state: "failed", extra: {"state" => "waiting"}), rounds: 1))
        decisions.resume("wr_1", actor: "person", from: "plan", extra_rounds: 1)
        expect(store.runs["wr_1"]["steps"]["plan"]).not_to have_key("extra_rounds")
      end

      it "parks the resume with its extra rounds, and carries them out when the park is released" do
        stored(rejected_run)

        decisions.park("wr_1", actor: "person", extra_rounds: 1)

        expect(store.runs["wr_1"]["parked"]).to include("extra_rounds" => 1)
      end

      it "is a usage error for a step with no review, and with --accept-guard" do
        stored(run_hash(state: "failed", extra: {"state" => "waiting"}))

        expect { decisions.resume("wr_1", actor: "person", extra_rounds: 1) }.to raise_error(Workspace::UsageError, /has no review: to extend/)
        expect { decisions.resume("wr_1", actor: "person", extra_rounds: 1, accept_guard: true, note: "x") }.to raise_error(Workspace::UsageError, /--extra-rounds/)
      end

      it "refuses a resume of the round held at the cap" do
        run = capped(reviewing_run(reason: {"code" => "review_rounds_spent", "since" => "2026-11-10T11:55:00Z", "details" => {}}))
        run["steps"]["plan"]["review"] = {"round" => 3, "delivery" => nil, "held" => "review_rounds_spent"}
        stored(run)

        expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("review_rounds_spent")
      end

      it "still restarts a stopped round while a round is left" do
        stored(capped(reviewing_run(reason: review_incomplete), rounds: 1))

        decisions.resume("wr_1", actor: "person")

        expect(progress.calls).to eq([[:restart_review, "plan"]])
      end

      it "refuses a plain resume of a step a review rejected with every round spent, and a park of one" do
        stored(rejected_run)

        expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("review_rounds_spent")
        expect(error_for { decisions.park("wr_1", actor: "person") }.code).to eq("review_rounds_spent")
        expect(dispatch.calls).to be_empty
      end

      it "starts the retry a rejection stopped by an attempt limit kept, once --extra-attempts lets it" do
        run = rejected_run
        run["steps"]["plan"]["review_rounds"] = 1
        run["reason"]["details"]["limit"] = "step"
        run["review_retry"] = {"step" => "plan", "attempt" => 1, "round" => 1, "context" => "continue", "text" => "Review round 1 of 2 rejected the plan step"}
        stored(run)

        resumed = decisions.resume("wr_1", actor: "person", extra_attempts: 1)

        expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {cause: "resume", context: "continue", budgeted: true, retry_of: {"text" => "Review round 1 of 2 rejected the plan step", "attempt" => 1}}])
        expect(resumed.run.pending_context).to eq(["Review round 1 of 2 rejected the plan step"])
        expect(resumed.run.to_h).not_to have_key("review_retry")
      end

      it "drops the kept retry on --from, and closes the window the rejected round kept when --from goes to another step" do
        run = rejected_run
        run["review_retry"] = {"step" => "plan", "attempt" => 1, "text" => "the verdicts"}
        run["steps"]["plan"]["review_window"] = {"round" => 2, "window" => "@7", "pane" => "%7"}
        stored(run)

        resumed = decisions.resume("wr_1", actor: "person", from: "build")

        expect(progress.calls).to eq([[:end_round, "plan", {how: "from", close: true}]])
        expect(resumed.run.to_h).not_to have_key("review_retry")
        expect(resumed.run.pending_context).to be_empty
      end

      it "drops, on --from, a review retry that waited for a lock, and takes its text out of the pending context" do
        run = run_hash(state: "waiting", extra: {"state" => "waiting"})
        run["reason"] = {"code" => "waiting_lock", "since" => "2026-11-10T11:55:00Z", "details" => {"resource" => "db", "step" => "plan"}}
        run["pending_context"] = ["keep me", "the verdicts"]
        run["retry_of_pending"] = {"step" => "plan", "attempt" => 1, "context" => "fresh", "text" => "the verdicts"}
        stored(run)

        resumed = decisions.resume("wr_1", actor: "person", from: "build")

        expect(resumed.run.to_h).not_to have_key("retry_of_pending")
        expect(resumed.run.pending_context).to eq(["keep me"])
      end

      it "lets --from go on" do
        stored(rejected_run)

        decisions.resume("wr_1", actor: "person", from: "plan")

        expect(dispatch.calls.map(&:first)).to eq([:dispatch])
      end
    end

    it "ends the round with its window closed before --from starts the step named, keeping review_rounds" do
      stored(reviewing_run(reason: review_incomplete))

      resumed = decisions.resume("wr_1", actor: "person", from: "plan")

      expect(progress.calls).to eq([[:end_round, "plan", {how: "from", close: true}]])
      expect(dispatch.calls.map(&:first)).to eq([:dispatch])
      expect(resumed.run.steps["plan"].to_h).not_to have_key("review")
      expect(resumed.run.steps["plan"].to_h["review_rounds"]).to eq(1)
      expect(evaluation.calls).to eq([[:close_review, "wr_1", {"step" => "plan", "round" => 1}]])
    end

    it "ends a live round too when --from goes elsewhere" do
      stored(reviewing_run)

      decisions.resume("wr_1", actor: "person", from: "plan")

      expect(progress.calls).to eq([[:end_round, "plan", {how: "from", close: true}]])
    end

    describe "a review round held by the token budget or the run's timeout" do
      def held_round(hold, code, definition = {})
        run = reviewing_run(reason: {"code" => code, "since" => "2026-11-10T11:55:00Z", "details" => {"review_round" => 2}})
        run["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => code}
        run["steps"]["plan"]["attempts"][0]["usage"] = {"input_tokens" => 150}
        run["definition"].merge!("max_attempts" => 1).merge!(definition)
        run.merge(hold => {"review_round" => 2})
      end

      it "refuses a resume until --extra-tokens covers the budget, then starts that round, not an attempt, asking no attempt allowance" do
        stored(held_round("budget_hold", "budget_spent", "budget" => {"tokens" => 100}))
        before = deep_copy(store.runs["wr_1"])

        expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("budget_spent")
        expect(error_for { decisions.resume("wr_1", actor: "person", extra_tokens: 50) }.code).to eq("budget_spent")
        expect(store.runs["wr_1"]).to eq(before)

        resumed = decisions.resume("wr_1", actor: "person", extra_tokens: 51)

        expect(resumed.unchanged).to be_nil
        expect(resumed.run.budget_hold).to be_nil
        expect(resumed.run.extra_tokens).to eq(51)
        expect(progress.calls).to eq([[:restart_review, "plan"]])
        expect(dispatch.calls).to be_empty
        expect(evaluation.calls).to eq([[:review_round, "wr_1", {"step" => "plan"}]])
        expect(change.events.map { |event| event[1] }).to eq(%w[budget_extended run_resumed])
        expect(change.events.last).to eq(["wr_1", "run_resumed", {"step" => "plan", "budget" => "released", "review_round" => 2}])
      end

      it "refuses a resume until --extra-time covers the timeout, then starts that round" do
        stored(held_round("timeout_hold", "run_timed_out", "timeout" => 1800))

        expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("run_timed_out")

        resumed = decisions.resume("wr_1", actor: "person", extra_seconds: 1801)

        expect(resumed.run.timeout_hold).to be_nil
        expect(resumed.run.extra_seconds).to eq(1801)
        expect(progress.calls).to eq([[:restart_review, "plan"]])
        expect(dispatch.calls).to be_empty
      end

      context "when the author's pane is no longer the run's" do
        let(:progress) { RecordingProgress.new(pane_problem: {code: "pane_gone", message: "pane %3 is gone."}) }

        it "starts the round anyway, since the round types into its own window" do
          stored(held_round("budget_hold", "budget_spent", "budget" => {"tokens" => 100}))

          expect(decisions.resume("wr_1", actor: "person", extra_tokens: 51).unchanged).to be_nil
          expect(progress.calls).to eq([[:restart_review, "plan"]])
        end
      end

      it "holds a fresh round after a stopped one to the budget too" do
        stopped = reviewing_run(reason: review_incomplete)
        stopped["steps"]["plan"]["attempts"][0]["usage"] = {"input_tokens" => 150}
        stopped["definition"]["budget"] = {"tokens" => 100}
        stored(stopped)

        expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("budget_spent")
        decisions.resume("wr_1", actor: "person", extra_tokens: 51)
        expect(progress.calls).to eq([[:restart_review, "plan"]])
      end
    end

    it "runs a failed step again, telling it what failed" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting"}))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed.unchanged).to be_nil
      expect(resumed.run.pending_context.first).to start_with("The last attempt of this step failed: ")
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "failed"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}]])
    end

    it "follows up a review round the change registered, once the change is done" do
      evaluation = RecordingEvaluation.new(store.runs, review: {"round" => 1})
      stored(run_hash(reason: {"code" => "turn_ended_incomplete", "since" => "2026-11-10T11:58:00Z", "details" => {}}))

      described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).resume("wr_1", actor: "person")

      expect(evaluation.calls).to eq([[:evaluate, "plan"], [:review_round, "wr_1", {"round" => 1}]])
    end

    it "decides a running step whose turn ended, and runs the check it registers once the change is done" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"step" => "plan", "attempt" => 1})
      stored(run_hash(reason: {"code" => "turn_ended_incomplete", "since" => "2026-11-10T11:58:00Z", "details" => {}}))

      resumed = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).resume("wr_1", actor: "person")

      expect(evaluation.calls).to eq([[:evaluate, "plan"], [:finish_check, "wr_1", {"step" => "plan", "attempt" => 1}]])
      expect(resumed.run.reason).to be_nil
      expect(resumed.unchanged).to be_nil
    end

    it "starts again at the step --from names" do
      stored

      resumed = decisions.resume("wr_1", actor: "person", from: "build")

      expect(resumed.run.current).to eq("build")
      expect(change.events).to eq([["wr_1", "run_resumed", {"from" => "build"}]])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}]])
    end

    it "skips a retry's wait and starts the retry" do
      backoff = {"until" => "2026-11-10T13:00:00Z", "to" => "plan", "text" => "it failed", "pane" => "%3"}
      stored(run_hash(state: "failed", extra: {"backoff" => backoff, "state" => "waiting"}))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed.unchanged).to be_nil
      expect(progress.calls).to eq([[:retry_pane_problem, "plan", {proven: false, pane: nil}], [:start_retry, "plan", backoff, {cause: "resume", proven: false, budgeted: true}]])
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "failed", "backoff" => "skipped"}]])
      expect(resumed.run.backoff).to be_nil
    end

    it "holds a retry whose pane is no longer the run's, writing no event, and says why" do
      progress = RecordingProgress.new(pane_problem: {code: "pane_gone", message: "pane %3 is gone"})
      stored(run_hash(state: "failed", extra: {"backoff" => {"until" => "2026-11-10T13:00:00Z", "to" => "plan"}, "state" => "waiting"}))

      resumed = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).resume("wr_1", actor: "person")

      expect(resumed.unchanged).to eq("pane %3 is gone")
      expect(progress.calls.last).to eq([:hold_retry, "plan", {code: "pane_gone", message: "pane %3 is gone"}, {pane: "%3"}])
      expect(change.events).to be_empty
      expect(dispatch.calls).to be_empty
    end

    it "releases a run its token budget held into its step, with the held context" do
      stored(run_hash(state: "failed", extra: {"budget_hold" => {"context" => "fresh", "pane" => "%3"}, "state" => "waiting"}))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(resumed.run.budget_hold).to be_nil
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "budget" => "released"}]])
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {cause: "resume", context: "fresh", budgeted: true, retry_of: nil}])
    end

    it "releases a held retry of a step a review rejected as a retry_of that attempt" do
      stored(run_hash(state: "failed", extra: {"budget_hold" => {"context" => "fresh", "pane" => "%3", "text" => "the verdicts", "retry_of" => 1}, "state" => "waiting"}))

      decisions.resume("wr_1", actor: "person")

      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {cause: "resume", context: "fresh", budgeted: true, retry_of: {"text" => "the verdicts", "attempt" => 1}}])
    end

    it "releases a run its timeout held into its step, with the held context, and with --extra-time records the extension" do
      timed = run_hash(state: "failed", extra: {"timeout_hold" => {"context" => "fresh", "pane" => "%3"}, "state" => "waiting"})
      timed["definition"]["timeout"] = 1800
      stored(timed)

      error = error_for { decisions.resume("wr_1", actor: "person") }
      expect(error.code).to eq("run_timed_out")
      expect(error.message).to include("its time limit (1h 0m of 30m)", "--extra-time 45m", "(1801s is the least)")
      expect(error.details).to include("run_id" => "wr_1", "step" => "plan", "needed" => 1801, "suggested" => 2700, "limit" => 1800, "kind" => "timeout")
      expect(error_for { decisions.resume("wr_1", actor: "person", extra_seconds: 1800) }.code).to eq("run_timed_out")
      expect(change.events).to be_empty

      resumed = decisions.resume("wr_1", actor: "person", extra_seconds: 1801)

      expect(resumed.run.timeout_hold).to be_nil
      expect(resumed.run.extra_seconds).to eq(1801)
      expect(change.events).to eq([["wr_1", "time_extended", {"extra" => 1801, "extra_seconds" => 1801, "limit" => 3601}],
        ["wr_1", "run_resumed", {"step" => "plan", "budget" => "released"}]])
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {cause: "resume", context: "fresh", budgeted: true, retry_of: nil}])
    end

    it "names both needs when the token budget and the timeout are both spent, and clears both holds with both flags" do
      held = {"context" => "fresh", "pane" => "%3"}
      both = run_hash(state: "failed", extra: {"budget_hold" => held, "timeout_hold" => held, "state" => "waiting"})
      both["definition"].merge!("timeout" => 1800, "budget" => {"tokens" => 100})
      both["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:10:00Z", "usage" => {"input_tokens" => 150})
      stored(both)

      error = error_for { decisions.resume("wr_1", actor: "person", extra_tokens: 51) }
      expect(error.code).to eq("run_timed_out")
      error = error_for { decisions.resume("wr_1", actor: "person") }
      expect(error.code).to eq("budget_spent")
      expect(error.message).to include("token budget (150 of 100 tokens) and its time limit", "--extra-tokens 100000 and --extra-time 45m", "the least is 51 for --extra-tokens, 1801s for --extra-time")
      expect(error.details["run_timed_out"]).to include("needed" => 1801)

      resumed = decisions.resume("wr_1", actor: "person", extra_tokens: 51, extra_seconds: 1801)

      expect(resumed.run.budget_hold).to be_nil
      expect(resumed.run.timeout_hold).to be_nil
      expect(resumed.run).to have_attributes(extra_tokens: 51, extra_seconds: 1801)
    end

    it "moves the run to a pane a person names, and refuses one another run has before writing anything" do
      before = deep_copy(stored)

      expect(error_for { decisions.resume("wr_1", actor: "person", pane: "%9") }.code).to eq("pane_has_run")
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty

      resumed = decisions.resume("wr_1", actor: "person", pane: "%8")
      expect(resumed.run.pane).to eq("%8")
      expect(panes.calls).to eq([[:unbind, "wr_1"]])
      expect(dispatch.calls.last).to eq([:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}])
    end

    it "takes over from a parked resume" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => {"id" => "p1", "pane" => "%3"}}))

      resumed = decisions.resume("wr_1", actor: "person")

      expect(dispatch.calls.first).to eq([:drop_park, "wr_1", "taken_over", {}])
      expect(resumed.run.parked).to be_nil
    end

    it "refuses a resume that would start an attempt the run has none left for" do
      stored(run_hash(state: "failed", reason: failed_check, max_attempts: 1))

      expect(error_for { decisions.resume("wr_1", actor: "person") }.code).to eq("attempts_spent")
      expect(decisions.resume("wr_1", actor: "person", extra_attempts: 2).run.extra_attempts).to eq(2)
    end
  end

  describe "#refuse_resume" do
    def guard_stop(guard) = {"code" => "failed_check", "details" => {"cause" => "guard", "guard" => guard, "code" => guard}}

    def no_base(reason) = run_hash(state: "failed", reason: reason).merge("base_sha" => nil)

    it "refuses every form of resume and park after no_commit with no base commit, changing nothing" do
      before = deep_copy(stored(no_base(guard_stop("no_commit"))))

      [{}, {extra_attempts: 2}, {extra_tokens: 100}, {extra_seconds: 60}, {from: "plan"}, {from: "build"}].each do |options|
        [:resume, :park].each do |verb|
          error = error_for { (verb == :resume) ? decisions.resume("wr_1", actor: "person", **options) : decisions.park("wr_1", actor: "person", **options) }
          expect(error.code).to eq("guard_cannot_pass")
          expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "guard" => "no_commit")
        end
      end
      expect(dispatch.calls).to be_empty
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    it "refuses to release a parked resume once the run is stopped that way" do
      before = deep_copy(stored(no_base(guard_stop("no_commit")).merge("state" => "waiting", "parked" => {"id" => "p1", "retries" => 0, "expires_at" => "2026-11-10T13:00:00Z"})))

      error = error_for { decisions.release_park("wr_1", "p1", actor: "person") }

      expect(error.code).to eq("guard_cannot_pass")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "guard" => "no_commit")
      expect(dispatch.calls).to be_empty
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    %w[head_moved hooks_changed hidden_changed no_commit].each do |guard|
      it "still resumes after #{guard} when the run has a base commit" do
        stored(run_hash(state: "failed", reason: guard_stop(guard)).merge("base_sha" => "a" * 40))

        expect { decisions.refuse_resume(store.runs["wr_1"]) }.not_to raise_error
        expect { decisions.refuse_resume(store.runs["wr_1"], from: "plan") }.not_to raise_error
        expect(decisions.resume("wr_1", actor: "person")).to be_a(described_class::Resumed)
      end
    end

    it "still resumes after a plain failed check even with no base commit" do
      expect { decisions.refuse_resume(no_base(failed_check)) }.not_to raise_error
    end

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

  describe "#resume with accept_guard" do
    def guard_stop(guard) = {"code" => "failed_check", "since" => "2026-11-10T11:55:00Z", "details" => {"cause" => "guard", "guard" => guard, "code" => guard}}

    def guard_stopped(guard = "head_moved", base_sha: "a" * 40, max_attempts: 5)
      run = run_hash(state: "failed", reason: guard_stop(guard), max_attempts: max_attempts, extra: {"state" => "waiting", "base_sha" => base_sha, "base_guard" => {"config_sha256" => "old"}})
      run["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:55:00Z", "outcome" => "failed", "code" => guard)
      stored(run)
    end

    def accepted_line(guard, sha) = "A person accepted the `#{guard}` stop on `plan`; the guard now measures from HEAD `#{sha[0, 12]}`."

    def decisions_with(guard) = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
      attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now })

    it "takes the checkout as the new base in one reading, records the note and has the rest of the step judged without the guard" do
      guard_stopped

      resumed = decisions.resume("wr_1", actor: "person", accept_guard: true, note: "I rebased on purpose.", caller_pane: "%1")

      run = resumed.run
      expect(resumed.unchanged).to be_nil
      expect(run.base_sha).to eq("b" * 40)
      expect(run.to_h["base_guard"]).to eq("config_sha256" => "c", "hooks_sha256" => "h", "hidden_sha256" => "x", "accepted_tree_sha256" => "t" * 64)
      expect(guard.calls).to eq([[:base, "/work/app", {accept_tree: true}]])
      expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"]])
      expect(run.steps["plan"].attempts.last.to_h).to include("outcome" => "failed", "guard_accepted" => "head_moved")
      expect(progress.calls).to be_empty
      expect(dispatch.calls).to be_empty
      expect(run.pending_context).to eq([accepted_line("head_moved", "b" * 40), "Note from the person who resumed the run: I rebased on purpose."])
      expect(change.events).to eq([
        ["wr_1", "guard_overridden", {"step" => "plan", "attempt" => 1, "guard" => "head_moved", "old_base_sha" => "a" * 40, "new_base_sha" => "b" * 40,
                                      "note" => "I rebased on purpose.", "pane" => "%1", "retry" => false}],
        ["wr_1", "run_resumed", {"step" => "plan", "state" => "failed", "accept_guard" => "head_moved"}]
      ])
    end

    it "runs the stopped step again with --retry, as a new attempt held to max_attempts" do
      guard_stopped("tracked_changed", max_attempts: 1)

      error = error_for { decisions.resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "keep the edits") }
      expect(error.code).to eq("attempts_spent")
      expect(guard.calls).to be_empty
      expect(change.events).to be_empty

      run = decisions.resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "keep the edits", extra_attempts: 1).run

      expect(run.base_sha).to eq("b" * 40)
      expect(run.extra_attempts).to eq(1)
      expect(run.steps["plan"].attempts.last.outcome).to eq("failed")
      expect(progress.calls).to be_empty
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}]])
      expect(change.deliveries).to eq([{"step" => "plan"}])
      expect(run.pending_context).to eq([accepted_line("tracked_changed", "b" * 40), "Note from the person who resumed the run: keep the edits"])
      expect(change.events.map { |event| event[1] }).to eq(%w[attempts_extended guard_overridden run_resumed])
      expect(change.events[1][2]).to include("retry" => true, "guard" => "tracked_changed")
      expect(change.events[2][2]).to eq("from" => "plan", "accept_guard" => "tracked_changed")
    end

    it "accepts no_commit with no base commit, taking HEAD as the base once there is one" do
      guard_stopped("no_commit", base_sha: nil)

      run = decisions.resume("wr_1", actor: "person", accept_guard: true, note: "committed now").run

      expect(run.base_sha).to eq("b" * 40)
      expect(change.events.first[2]).to include("old_base_sha" => nil, "new_base_sha" => "b" * 40)
      expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"]])
    end

    it "accepts no_commit with no base commit and still no HEAD: the step passes with the note and no base" do
      guard_stopped("no_commit", base_sha: nil)
      no_head = RecordingGuard.new(head: nil)

      run = decisions_with(no_head).resume("wr_1", actor: "person", accept_guard: true, note: "empty repo").run

      expect(run.base_sha).to be_nil
      expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"]])
      expect(run.pending_context).to eq(["A person accepted the `no_commit` stop on `plan`; the checkout has no commit, so the guard has no HEAD to measure from.",
        "Note from the person who resumed the run: empty repo"])
    end

    it "accepts no_commit on an unborn branch without --retry (no accepted tree to read), and refuses --retry as guard_cannot_pass" do
      guard_stopped("no_commit", base_sha: nil)
      unborn = RecordingGuard.new(head: nil, tree: nil, found: {"code" => "no_commit", "paths" => []})

      error = error_for { decisions_with(unborn).resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "mine") }
      expect(error.code).to eq("guard_cannot_pass")
      expect(change.events).to be_empty

      run = decisions_with(unborn).resume("wr_1", actor: "person", accept_guard: true, note: "empty repo").run
      expect(run.base_sha).to be_nil
      expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"]])
      expect(change.events.map { |e| e[1] }).to include("guard_overridden")
    end

    it "fails the step with the reason its other checks give, the guard_overridden event and the note kept" do
      guard_stopped
      missing = {"code" => "turn_ended_incomplete", "since" => "2026-11-10T12:00:00Z", "details" => {"step" => "plan", "missing" => ["/work/app/.workflow/wr_1/plan.md"]}}
      evaluation = RecordingEvaluation.new(store.runs, reason: missing)
      run = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).resume("wr_1", actor: "person", accept_guard: true, note: "mine").run

      expect(run.reason).to eq(missing)
      expect(progress.calls).to be_empty
      expect(run.pending_context.last).to eq("Note from the person who resumed the run: mine")
      expect(change.events.map { |event| event[1] }).to eq(%w[guard_overridden run_resumed])
    end

    it "runs a check the evaluation registers outside the lock, through finish_follow_ups" do
      guard_stopped
      evaluation = RecordingEvaluation.new(store.runs, check: {"step" => "plan", "attempt" => 1, "command" => "rake"})
      described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).resume("wr_1", actor: "person", accept_guard: true, note: "mine")

      expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"], [:finish_check, "wr_1", {"step" => "plan", "attempt" => 1, "command" => "rake"}]])
    end

    it "refuses with guard_base_unreadable when the tree can't be read, keeping the stored base" do
      before = deep_copy(guard_stopped("tracked_changed"))

      error = error_for { decisions_with(RecordingGuard.new(head: "b" * 40, tree: nil)).resume("wr_1", actor: "person", accept_guard: true, note: "mine") }

      expect(error.code).to eq("guard_base_unreadable")
      expect(error.details["unread"]).to eq(["accepted_tree_sha256"])
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
      expect(evaluation.calls).to be_empty
    end

    [["head"], ["hooks_sha256"], ["hidden_sha256"]].each do |unread|
      it "refuses with guard_base_unreadable, retryable, when #{unread.first} can't be read, keeping the stored base" do
        before = deep_copy(guard_stopped)

        error = error_for { decisions_with(RecordingGuard.new(head: "b" * 40, unread: unread)).resume("wr_1", actor: "person", accept_guard: true, note: "mine") }

        expect(error.code).to eq("guard_base_unreadable")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "guard" => "head_moved", "unread" => unread)
        expect(error.retry).to eq("flags" => [], "destructive" => false)
        expect(store.runs["wr_1"]).to eq(before)
        expect(change.events).to be_empty
        expect(evaluation.calls).to be_empty
      end
    end

    {"no_commit" => /still has no commit/, "operation_in_progress" => /still under way: finish or abort it first/}.each do |code, message|
      it "refuses --retry with guard_cannot_pass while #{code} would stop the retry again, and accepts without it" do
        guard_stopped(code)
        guard = RecordingGuard.new(head: "b" * 40, found: {"code" => code, "paths" => []})
        before = deep_copy(store.runs["wr_1"])

        error = error_for { decisions_with(guard).resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "mine") }

        expect(error.code).to eq("guard_cannot_pass")
        expect(error.message).to match(message)
        expect(error.details).to include("guard" => code, "retry" => true)
        expect(store.runs["wr_1"]).to eq(before)
        expect(change.events).to be_empty
        expect(dispatch.calls).to be_empty

        decisions_with(guard).resume("wr_1", actor: "person", accept_guard: true, note: "mine")
        expect(evaluation.calls).to eq([[:evaluate_accepted, "plan"]])
      end
    end

    it "lets --retry go on when the guard from the new base finds something a retry can put right" do
      guard_stopped("head_moved")
      guard = RecordingGuard.new(head: "b" * 40, found: {"code" => "tracked_changed", "paths" => ["a.rb"]})

      decisions_with(guard).resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "mine")

      expect(guard.calls.map(&:first)).to eq(%i[base check])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}]])
    end

    it "moves the run to a pane given, refusing one another run holds before anything is changed" do
      guard_stopped
      before = deep_copy(store.runs["wr_1"])

      error = error_for { decisions.resume("wr_1", actor: "person", accept_guard: true, note: "mine", pane: "%9") }
      expect(error.code).to eq("pane_has_run")
      expect(store.runs["wr_1"]).to eq(before)
      expect(guard.calls).to be_empty
      expect(change.events).to be_empty

      run = decisions.resume("wr_1", actor: "person", accept_guard: true, note: "mine", pane: "%7").run
      expect(run.pane).to eq("%7")
      expect(panes.calls).to include([:unbind, "wr_1"])
      expect(dispatch.calls).to include([:check_pane, "%7", {run_id: "wr_1"}])
    end

    it "takes over from a parked resume" do
      guard_stopped["parked"] = {"id" => "p0", "pane" => "%3", "requested_at" => "2026-11-10T11:00:00Z", "expires_at" => "2026-11-10T13:00:00Z", "retries" => 0}

      run = decisions.resume("wr_1", actor: "person", accept_guard: true, note: "mine").run

      expect(dispatch.calls.first).to eq([:drop_park, "wr_1", "taken_over", {}])
      expect(run.parked).to be_nil
    end

    it "refuses a run no guard stopped with guard_not_stopped, changing nothing" do
      before = deep_copy(stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting"})))

      error = error_for { decisions.resume("wr_1", actor: "person", accept_guard: true, note: "why") }

      expect(error.code).to eq("guard_not_stopped")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "reason" => "failed_check", "guard" => nil)
      expect(store.runs["wr_1"]).to eq(before)
      expect(guard.calls).to be_empty
      expect(change.events).to be_empty
      expect(error_for { decisions.refuse_resume(run_hash, note: "why", accept_guard: true) }.code).to eq("guard_not_stopped")
    end

    it "refuses the flags that can't go together before the run is read" do
      guard_stopped
      [
        [{accept_guard: true}, "--accept-guard needs --note WHY"],
        [{accept_guard: true, note: "  "}, "--accept-guard needs --note WHY"],
        [{guard_retry: true, note: "why"}, "--retry is for"],
        [{accept_guard: true, guard_retry: true, from: "plan", note: "why"}, "--retry runs the stopped step again; --from can't go with it."],
        [{accept_guard: true, from: "plan", note: "why"}, "--from can't go with it."]
      ].each do |options, message|
        expect { decisions.resume("wr_1", actor: "person", **options) }.to raise_error(Workspace::UsageError, Regexp.new(Regexp.escape(message)))
        expect { decisions.refuse_resume(store.runs["wr_1"], **options) }.to raise_error(Workspace::UsageError, Regexp.new(Regexp.escape(message)))
      end
      expect(change.events).to be_empty
    end
  end

  describe "#park" do
    def park_of(at, pane: "%5") = {"id" => "p0", "pane" => pane, "requested_at" => "2026-11-10T11:00:00Z", "expires_at" => at, "retries" => 0}

    it "refuses a step being reviewed, with --from too, and stores nothing" do
      run = run_hash(state: "reviewing", extra: {"state" => "waiting", "reason" => {"code" => "review_incomplete", "since" => "2026-11-10T11:55:00Z", "details" => {}}})
      run["steps"]["plan"]["review"] = {"round" => 1, "delivery" => nil, "started_at" => "2026-11-10T11:50:00.000Z"}
      before = deep_copy(stored(run))

      [nil, "plan"].each do |from|
        error = error_for { decisions.park("wr_1", actor: "person", from: from) }

        expect(error.code).to eq("step_reviewing")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan")
        expect(error.message).to include("Run `workspace workflow resume wr_1#{" --from plan" if from}` from another terminal.")
      end
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    it "stores the resume on the run for later, as a frozen Resumed, and types nothing" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting"}))

      resumed = decisions.park("wr_1", actor: "person", note: "later", extra_tokens: 10)

      expect(resumed).to be_a(described_class::Resumed)
      expect(resumed).to be_frozen
      expect(resumed.unchanged).to be_nil
      expect(resumed.run.parked).to include("from" => nil, "note" => "later", "pane" => nil, "turn_over" => nil, "extra_tokens" => 10,
        "requested_at" => "2026-11-10T12:00:00Z", "expires_at" => "2026-11-10T13:00:00Z", "retries" => 0)
      expect(resumed.run.parked).not_to have_key("extra_attempts")
      expect(change.events).to eq([["wr_1", "resume_parked", {"step" => "plan", "pane" => "%3", "from" => nil, "has_note" => true}]])
      expect(dispatch.calls).to be_empty
    end

    it "leaves a live park as it is and says which pane it waits for" do
      before = deep_copy(stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => park_of("2026-11-10T12:30:00Z")})))

      resumed = decisions.park("wr_1", actor: "person", from: "build")

      expect(resumed.unchanged).to eq("a resume is already parked for pane %5")
      expect(resumed.run.to_h).to eq(before)
      expect(change.events).to be_empty
    end

    it "replaces a park past its limit" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => park_of("2026-11-10T11:30:00Z")}))

      resumed = decisions.park("wr_1", actor: "person", pane: "%8")

      expect(dispatch.calls).to eq([[:check_pane, "%8", {run_id: "wr_1"}], [:drop_park, "wr_1", "expired", {}]])
      expect(resumed.run.parked).to include("pane" => "%8", "expires_at" => "2026-11-10T13:00:00Z")
      expect(resumed.run.parked["id"]).not_to eq("p0")
      expect(change.events).to eq([["wr_1", "resume_parked", {"step" => "plan", "pane" => "%8", "from" => nil, "has_note" => false}]])
    end

    it "stores nothing for a step an agent is working on, and says why" do
      before = deep_copy(stored)

      resumed = decisions.park("wr_1", actor: "person")

      expect(resumed.unchanged).to eq("an agent is working on step plan")
      expect(resumed.run.to_h).to eq(before)
      expect(change.events).to be_empty
    end

    it "refuses what a resume refuses, and a pane another run has, before storing anything" do
      before = deep_copy(stored)

      expect(error_for { decisions.park("wr_1", actor: "person", from: "ship") }).to be_a(Workspace::UsageError)
      expect(error_for { decisions.park("wr_1", actor: "person", pane: "%9") }.code).to eq("pane_has_run")
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    context "when the resume would start an attempt" do
      let(:spent) do
        run_hash(state: "failed", reason: failed_check).tap do |hash|
          hash["definition"]["budget"] = {"tokens" => 100}
          hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:10:00Z", "usage" => {"input_tokens" => 150})
        end
      end

      it "refuses a run whose token budget is used up unless --extra-tokens covers it" do
        stored(spent)

        error = error_for { decisions.park("wr_1", actor: "person", extra_tokens: 50) }
        expect(error.code).to eq("budget_spent")
        expect(error.message).to include("(150 of 100 tokens)", "(51 is the least)")
        expect(store.runs["wr_1"]).not_to have_key("parked")

        expect(decisions.park("wr_1", actor: "person", extra_tokens: 51).run.parked).to include("extra_tokens" => 51)
      end

      it "refuses a run whose timeout is used up unless --extra-time covers it, storing the seconds in the park" do
        timed = run_hash(state: "failed", reason: failed_check)
        timed["definition"]["timeout"] = 1800
        stored(timed)

        error = error_for { decisions.park("wr_1", actor: "person", extra_seconds: 100) }
        expect(error.code).to eq("run_timed_out")
        expect(store.runs["wr_1"]).not_to have_key("parked")

        expect(decisions.park("wr_1", actor: "person", extra_seconds: 1801).run.parked).to include("extra_seconds" => 1801)
      end

      it "refuses spent attempts first" do
        spent["definition"]["max_attempts"] = 1
        stored(spent)

        expect(error_for { decisions.park("wr_1", actor: "person") }.code).to eq("attempts_spent")
      end
    end

    context "when the resume would not start an attempt" do
      it "asks nothing of the allowance or the token budget" do
        waiting_lock = {"code" => "waiting_lock", "since" => "2026-11-10T11:55:00Z", "details" => {}}
        hash = run_hash(state: "pending", reason: waiting_lock, max_attempts: 1)
        hash["definition"]["budget"] = {"tokens" => 100}
        hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:10:00Z", "usage" => {"input_tokens" => 150})
        stored(hash)

        resumed = decisions.park("wr_1", actor: "person")

        expect(resumed.unchanged).to be_nil
        expect(resumed.run.parked).to include("retries" => 0)
      end
    end
  end

  describe "#release_park" do
    def parked(retries: 0, note: nil, id: "p1")
      {"id" => id, "from" => nil, "note" => note, "pane" => nil, "turn_over" => nil, "requested_at" => "2026-11-10T11:00:00Z",
       "expires_at" => "2026-11-10T13:00:00Z", "retries" => retries}
    end

    it "follows up a review round the released resume registered" do
      evaluation = RecordingEvaluation.new(store.runs, review: {"round" => 1})
      stored(run_hash(state: "checking", extra: {"parked" => parked}))

      described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).release_park("wr_1", "p1", actor: "person")

      expect(evaluation.calls).to eq([[:evaluate, "plan"], [:review_round, "wr_1", {"round" => 1}]])
    end

    it "carries out the parked resume in the same change, and marks the attempt it started" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting", "parked" => parked}))

      resumed = decisions.release_park("wr_1", "p1", actor: "person")

      expect(resumed).to be_a(described_class::Resumed)
      expect(resumed.unchanged).to be_nil
      expect(resumed.run.parked).to be_nil
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: true, retry_of: nil}]])
      expect(change.events).to eq([["wr_1", "run_resumed", {"step" => "plan", "state" => "failed"}],
        ["wr_1", "resume_parked_ended", {"step" => "plan", "how" => "released"}]])
      expect(resumed.run.steps["plan"].last_attempt.to_h["after_park"]).to eq("expires_at" => "2026-11-10T13:00:00Z", "pane" => nil, "retries" => 0)
    end

    it "raises the step and run allowances by exactly the parked --extra-attempts, once, and writes attempts_extended once" do
      hash = run_hash(state: "failed", reason: failed_check, max_attempts: 5, extra: {"state" => "waiting"})
      hash["definition"]["steps"][0]["max_attempts"] = 1
      stored(hash)
      parked_resume = decisions.park("wr_1", actor: "person", extra_attempts: 1)
      expect(parked_resume.run.parked).to include("extra_attempts" => 1)
      expect(store.runs["wr_1"]).not_to have_key("extra_attempts")

      resumed = decisions.release_park("wr_1", parked_resume.run.parked["id"], actor: "person")

      expect(resumed.run.extra_attempts).to eq(1)
      expect(resumed.run.steps["plan"].to_h["extra_attempts"]).to eq(1)
      expect(change.events.count { |each| each[1] == "attempts_extended" }).to eq(1)
    end

    it "does not hold a park typed again after a busy pane to the allowance, since its attempt was counted then" do
      stored(run_hash(state: "failed", reason: failed_check, max_attempts: 1, extra: {"parked" => parked(retries: 1, note: "try again")}))

      resumed = decisions.release_park("wr_1", "p1", actor: "person")

      expect(resumed.run.pending_context.last).to eq("Note from the person who resumed the run: try again")
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: false, retry_of: nil}]])
    end

    context "on its first try, when the resume would start an attempt" do
      def spent_run(max_attempts: 5, tokens: nil)
        hash = run_hash(state: "failed", reason: failed_check, max_attempts: max_attempts, extra: {"state" => "waiting", "parked" => parked})
        hash["definition"]["budget"] = {"tokens" => tokens} if tokens
        hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:10:00Z", "usage" => {"input_tokens" => 150})
        stored(hash)
      end

      it "refuses with attempts_spent and leaves the run parked" do
        spent_run(max_attempts: 1)
        before = deep_copy(store.runs["wr_1"]["parked"])

        expect(error_for { decisions.release_park("wr_1", "p1", actor: "person") }.code).to eq("attempts_spent")
        expect(store.runs["wr_1"]["parked"]).to eq(before)
        expect(dispatch.calls).to be_empty
      end

      it "holds a run past its timeout on its first release, and starts the attempt unheld when typed again after a busy pane" do
        timed = spent_run
        timed["definition"]["timeout"] = 1800
        expect(error_for { decisions.release_park("wr_1", "p1", actor: "person") }.code).to eq("run_timed_out")
        expect(dispatch.calls).to be_empty

        timed["parked"]["retries"] = 1
        resumed = decisions.release_park("wr_1", "p1", actor: "person")

        expect(resumed.unchanged).to be_nil
        expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "resume", context: nil, budgeted: false, retry_of: nil}]])
      end

      it "refuses with budget_spent and leaves the run parked" do
        spent_run(tokens: 100)
        before = deep_copy(store.runs["wr_1"]["parked"])

        expect(error_for { decisions.release_park("wr_1", "p1", actor: "person") }.code).to eq("budget_spent")
        expect(store.runs["wr_1"]["parked"]).to eq(before)
        expect(dispatch.calls).to be_empty
      end
    end

    it "keeps the note for the next attempt when the resume does nothing, and says why" do
      stored(run_hash(extra: {"parked" => parked(note: "look again")}))

      resumed = decisions.release_park("wr_1", "p1", actor: "person")

      expect(resumed.unchanged).to eq("an agent is working on step plan")
      expect(resumed.run.parked).to be_nil
      expect(resumed.run.pending_context).to eq(["Note from the person who resumed the run: look again"])
      expect(change.events).to eq([["wr_1", "resume_parked_ended", {"step" => "plan", "how" => "unchanged", "detail" => "an agent is working on step plan"}]])
      expect(dispatch.calls).to be_empty
    end

    it "runs the check the resume registers once the change is done" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"step" => "plan", "attempt" => 1})
      stored(run_hash(state: "checking", extra: {"parked" => parked}))

      resumed = described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now }).release_park("wr_1", "p1", actor: "person")

      expect(evaluation.calls).to eq([[:evaluate, "plan"], [:finish_check, "wr_1", {"step" => "plan", "attempt" => 1}]])
      expect(resumed.unchanged).to be_nil
    end

    it "changes nothing for a park of another id" do
      before = deep_copy(stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => parked})))

      resumed = decisions.release_park("wr_1", "p2", actor: "person")

      expect(resumed.unchanged).to be_nil
      expect(resumed.run.to_h).to eq(before)
      expect(change.events).to be_empty
      expect(dispatch.calls).to be_empty
    end
  end

  describe "#park_failed" do
    def parked = {"id" => "p1", "pane" => "%5", "requested_at" => "2026-11-10T11:00:00Z", "expires_at" => "2026-11-10T13:00:00Z", "retries" => 0}

    it "ends the park, gives up a lock the run queued for and leaves the run waiting for a person, as a WorkflowRun" do
      waiting_lock = {"code" => "waiting_lock", "since" => "2026-11-10T11:55:00Z", "details" => {}}
      stored(run_hash(state: "pending", reason: waiting_lock, extra: {"parked" => parked}))

      run = decisions.park_failed("wr_1", "p1", code: "parked_timeout", message: "too long", actor: "person")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(dispatch.calls).to eq([[:release, "wr_1"], [:drop_park, "wr_1", "failed", {}]])
      expect(run.parked).to be_nil
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "waiting_you", "since" => "2026-11-10T12:00:00Z",
        "details" => {"kind" => "dispatch", "step" => "plan", "pane" => "%5", "workspace" => "app", "error" => "parked_timeout", "message" => "too long"})
    end

    it "names a gone pane as pane_gone" do
      stored(run_hash(state: "failed", extra: {"parked" => parked.merge("pane" => nil)}))

      run = decisions.park_failed("wr_1", "p1", code: "no_such_pane", message: "gone", actor: "person")

      expect(run.reason["code"]).to eq("pane_gone")
      expect(run.reason["details"]["pane"]).to eq("%3")
    end

    it "reads no_such_pane as waiting_you when the caller says the pane is not gone" do
      stored(run_hash(state: "failed", extra: {"parked" => parked.merge("pane" => nil)}))

      run = decisions.park_failed("wr_1", "p1", code: "no_such_pane", message: "gone", actor: "person", gone: false)

      expect(run.reason["code"]).to eq("waiting_you")
      expect(run.reason["details"]["error"]).to eq("no_such_pane")
    end

    it "reads any code as pane_gone when the caller says the pane is gone" do
      stored(run_hash(state: "failed", extra: {"parked" => parked.merge("pane" => nil)}))

      run = decisions.park_failed("wr_1", "p1", code: "pane_busy", message: "busy", actor: "person", gone: true)

      expect(run.reason["code"]).to eq("pane_gone")
    end

    it "tells a failed step's next attempt what failed" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"parked" => parked}))

      run = decisions.park_failed("wr_1", "p1", code: "pane_busy", message: "busy", actor: "person")

      expect(run.pending_context.first).to start_with("The last attempt of this step failed: ")
    end

    it "keeps a gate's reason, so approve and reject stay open, and names the failure in the park's end" do
      gate_reason = {"code" => "waiting_you", "since" => "2026-11-10T11:50:00Z", "details" => {"kind" => "gate"}}
      stored(run_hash(state: "passed", gate: waiting_gate, reason: gate_reason, extra: {"parked" => parked}))

      run = decisions.park_failed("wr_1", "p1", code: "pane_gone", message: "gone", actor: "person")

      expect(dispatch.calls).to eq([[:drop_park, "wr_1", "failed", {"error" => "pane_gone", "message" => "gone"}]])
      expect(run.reason).to eq(gate_reason)
      expect(run.state).to eq("running")
    end

    context "when the run has finished" do
      let(:finished) { ["wr_1"] }

      it "raises run_not_active" do
        stored(run_hash(state: "failed", extra: {"parked" => parked}))

        expect(error_for { decisions.park_failed("wr_1", "p1", code: "pane_gone", message: "gone", actor: "person") }.code).to eq("run_not_active")
      end
    end

    it "changes nothing for a park of another id" do
      before = deep_copy(stored(run_hash(state: "failed", extra: {"parked" => parked})))

      expect(decisions.park_failed("wr_1", "p2", code: "pane_gone", message: "gone", actor: "person").to_h).to eq(before)
      expect(dispatch.calls).to be_empty
    end
  end

  describe "#cancel" do
    it "hands the actor it was given to the change, and kills as that actor too" do
      stored

      decisions.cancel("wr_1", actor: "person")

      expect(change.calls.map(&:last)).to eq([{nonblocking: false, actor: "person", cause: "cancel"}])
    end

    it "closes the open attempt, ends the run and records who ended it" do
      stored

      run = decisions.cancel("wr_1", actor: "person")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(attempt_record.calls).to eq([[:abandon, "wr_1"]])
      expect(progress.calls).to eq([[:finish, "wr_1", "cancelled"]])
      expect(run.state).to eq("cancelled")
      expect(run.cancelled_by).to eq("cancel")
      expect(run.steps["plan"].last_attempt.outcome).to eq("cancelled")
      expect(change.events).to eq([["wr_1", "run_cancelled", {"cause" => "cancel"}]])
    end

    it "ends the run that the attempt record closed, not the one it was given" do
      stored

      decisions.cancel("wr_1", actor: "person")

      expect(progress.finished.map { |run| run.steps["plan"].last_attempt.outcome }).to eq(["cancelled"])
    end

    it "ends a step's review round before the run: the round's usage recorded, the reviewer unbound and the window closed" do
      run = run_hash(state: "reviewing")
      run["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:50:00Z", "outcome" => "checks_passed")
      run["steps"]["plan"]["review"] = {"round" => 1, "delivery" => nil, "started_at" => "2026-11-10T11:50:00.000Z", "pane" => "%7"}
      stored(run)

      cancelled = decisions.cancel("wr_1", actor: "person")

      expect(progress.calls).to eq([[:end_round, "plan", {how: "cancelled", close: true}], [:finish, "wr_1", "cancelled"]])
      expect(progress.finished.first.steps["plan"].to_h).not_to have_key("review")
      expect(cancelled.steps["plan"].last_attempt.outcome).to eq("checks_passed")
      expect(evaluation.calls).to eq([[:close_review, "wr_1", {"step" => "plan", "round" => 1}]])
    end

    it "ends a run with no open attempt" do
      stored(run_hash.tap { |hash| hash["steps"]["plan"]["attempts"] = [] })

      run = decisions.cancel("wr_1", actor: "person")

      expect(attempt_record.calls).to eq([[:abandon, "wr_1"]])
      expect(run.state).to eq("cancelled")
      expect(run.steps["plan"].attempts).to be_empty
      expect(change.events).to eq([["wr_1", "run_cancelled", {"cause" => "cancel"}]])
    end
  end

  describe "#workspace_killed" do
    it "cancels the killed workspace's runs, and no other's, as a kill" do
      stored(run_hash(id: "wr_1", extra: {"workspace" => "app.worktree-a"}))
      stored(run_hash(id: "wr_2", extra: {"workspace" => "app.worktree-b"}))

      expect(decisions.workspace_killed("app.worktree-a", actor: "person")).to eq("cancelled" => ["wr_1"], "failed" => [])
      expect(store.runs["wr_1"]).to include("state" => "cancelled", "cancelled_by" => "kill")
      expect(store.runs["wr_2"]["state"]).to eq("running")
    end

    context "when a run can't be ended" do
      let(:finished) { ["wr_1"] }

      it "names it and ends the others" do
        stored(run_hash(id: "wr_1", extra: {"workspace" => "app.worktree-a"}))
        stored(run_hash(id: "wr_2", extra: {"workspace" => "app.worktree-a"}))

        expect(decisions.workspace_killed("app.worktree-a", actor: "person")).to eq("cancelled" => ["wr_2"], "failed" => ["wr_1"])
      end
    end

    it "raises nothing when the runs can't be listed" do
      allow(store).to receive(:going).and_raise(NoMethodError, "undefined method for nil")

      expect(decisions.workspace_killed("app", actor: "person")).to eq("cancelled" => [], "failed" => [])
    end
  end

  describe "#pause" do
    it "stores the pause with who and why, and records run_paused" do
      stored(run_hash)

      run = decisions.pause("wr_1", actor: "person", text: "lunch").run

      expect(run.paused).to eq("since" => "2026-11-10T12:00:00Z", "by" => "person", "text" => "lunch")
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false, actor: "person", cause: "pause"}]])
      expect(change.events).to eq([["wr_1", "run_paused", {"step" => "plan", "text" => "lunch"}]])
    end

    it "keeps the stored reason under the pause" do
      stored(run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting"}))

      run = decisions.pause("wr_1", actor: "person").run

      expect(run.reason).to eq(failed_check)
      expect(change.events).to eq([["wr_1", "run_paused", {"step" => "plan"}]])
    end

    it "drops a parked resume as paused" do
      stored(run_hash(extra: {"parked" => {"id" => "p0", "pane" => "%3", "requested_at" => "2026-11-10T11:00:00Z", "expires_at" => "2026-11-10T13:00:00Z", "retries" => 0}}))

      run = decisions.pause("wr_1", actor: "person").run

      expect(run.parked).to be_nil
      expect(dispatch.calls).to eq([[:drop_park, "wr_1", "paused", {}]])
    end

    it "keeps a continue_pending an earlier unpause left, for the next unpause" do
      pending_mark = {"pane" => "%3", "pid" => 41, "kind" => "claude", "step" => "plan", "attempt" => 1, "since" => "2026-11-10T11:30:00Z"}
      stored(run_hash(extra: {"continue_pending" => pending_mark}))

      run = decisions.pause("wr_1", actor: "person").run

      expect(run.continue_pending).to eq(pending_mark)
    end

    it "refuses a run already paused and changes nothing" do
      before = deep_copy(stored(run_hash(extra: {"paused" => {"since" => "2026-11-10T11:00:00Z", "by" => "person"}})))

      error = error_for { decisions.pause("wr_1", actor: "person") }

      expect(error.code).to eq("already_paused")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "since" => "2026-11-10T11:00:00Z", "by" => "person")
      expect(error.message).to include("workspace workflow unpause wr_1")
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    context "when the run has finished" do
      let(:finished) { ["wr_1"] }

      it "refuses it as run_not_active" do
        stored(run_hash)

        expect(error_for { decisions.pause("wr_1", actor: "person") }.code).to eq("run_not_active")
      end
    end

    describe "with interrupt" do
      let(:presses) { [] }
      let(:interrupter) { ->(workspace, pane, keys) { presses << [workspace, pane, keys] } }
      let(:working) { {"%3" => {"pane_id" => "%3", "kind" => "claude", "state" => "working"}} }

      def interrupting(panes, interrupter: self.interrupter)
        described_class.new(change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
          attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, interrupter: interrupter, clock: -> { now })
      end

      def panes_with(rows: working, pids: {"%3" => 41}, **rest)
        RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, runs_on: {"%3" => "wr_1"}, rows: rows, pids: pids, **rest)
      end

      it "presses the agent's interrupt keys once in a working pane and marks the turn it stopped" do
        stored(run_hash)

        paused = interrupting(panes_with).pause("wr_1", actor: "person", interrupt: true)

        expect(presses).to eq([["app", "%3", ["Escape"]]])
        expect(paused.interrupted).to be(true)
        expect(paused.run.paused["interrupt"]).to eq("pane" => "%3", "pid" => 41, "kind" => "claude", "step" => "plan", "attempt" => 1)
        expect(paused.run.steps["plan"].attempts.size).to eq(1)
        expect(paused.run.steps["plan"].last_attempt.to_h).not_to include("delivery", "ended_at")
        expect(change.events).to eq([["wr_1", "run_paused", {"step" => "plan", "interrupt" => true}]])
      end

      it "presses nothing and marks nothing in an idle pane, with no pane, or without interrupt" do
        [panes_with(rows: {"%3" => {"pane_id" => "%3", "kind" => "claude", "state" => "idle"}}),
          RecordingWorkflowPanes.new(rows: working, pids: {"%3" => 41}),
          panes_with(pids: {})].each do |panes|
          store.runs.clear
          stored(run_hash)
          paused = interrupting(panes).pause("wr_1", actor: "person", interrupt: true)
          expect(paused.interrupted).to be(false)
          expect(paused.run.paused).not_to have_key("interrupt")
        end
        store.runs.clear
        stored(run_hash)
        expect(interrupting(panes_with).pause("wr_1", actor: "person").interrupted).to be(false)
        expect(presses).to be_empty
      end

      it "presses nothing on a step that is not running" do
        stored(run_hash(state: "passed", gate: waiting_gate))

        paused = interrupting(panes_with).pause("wr_1", actor: "person", interrupt: true)

        expect(presses).to be_empty
        expect(paused.interrupted).to be(false)
      end

      it "drops the mark again when the press fails, recording why" do
        stored(run_hash)
        failing = ->(*) { raise Workspace::Error.new("the daemon refused", code: "pane_waiting") }

        paused = interrupting(panes_with, interrupter: failing).pause("wr_1", actor: "person", interrupt: true)

        expect(paused.interrupted).to be(false)
        expect(paused.run.paused).to include("by" => "person")
        expect(paused.run.paused).not_to have_key("interrupt")
        expect(change.events.last).to eq(["wr_1", "pause_interrupt_failed", {"step" => "plan", "attempt" => 1, "pane" => "%3", "message" => "the daemon refused"}])
      end
    end
  end

  describe "a paused run's resume and park" do
    def paused_run = run_hash(state: "failed", reason: failed_check, extra: {"state" => "waiting", "paused" => {"since" => "2026-11-10T11:00:00Z", "by" => "person"}})

    it "refuses a resume, a resume --from and a park with run_paused, naming workflow unpause" do
      before = deep_copy(stored(paused_run))

      [-> { decisions.resume("wr_1", actor: "person") }, -> { decisions.resume("wr_1", actor: "person", from: "plan") },
        -> { decisions.park("wr_1", actor: "person") }].each do |command|
        error = error_for { command.call }
        expect(error.code).to eq("run_paused")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "since" => "2026-11-10T11:00:00Z", "by" => "person")
        expect(error.message).to include("Run `workspace workflow unpause wr_1` first.")
      end
      expect(store.runs["wr_1"]).to eq(before)
      expect(dispatch.calls).to be_empty
    end

    it "refuses in refuse_resume, before a daemon is started" do
      expect(error_for { decisions.refuse_resume(paused_run) }.code).to eq("run_paused")
    end
  end

  describe "#unpause" do
    def pause_of = {"since" => "2026-11-10T11:00:00Z", "by" => "person"}

    def paused(hash = run_hash, hold: nil)
      hash["paused"] = pause_of
      hash["pause_hold"] = hold if hold
      stored(hash)
    end

    def unpaused_event(action, held = nil) = ["wr_1", "run_unpaused", {"step" => "plan", "action" => action, "held" => held}.compact]

    def decisions_over(panes)
      described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation,
        attempt_record: attempt_record, gate_note: gate_note, panes: panes, guard: guard, clock: -> { now })
    end

    it "refuses a run that is not paused and changes nothing" do
      before = deep_copy(stored(run_hash))

      error = error_for { decisions.unpause("wr_1", actor: "person") }

      expect(error.code).to eq("not_paused")
      expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "state" => "running")
      expect(store.runs["wr_1"]).to eq(before)
      expect(change.events).to be_empty
    end

    it "answers a frozen Unpaused naming the branch taken and the kind of dispatch held" do
      paused(run_hash(state: "passed", extra: {"state" => "waiting"}), hold: {"kind" => "attempt", "cause" => "next_step"})

      unpaused = decisions.unpause("wr_1", actor: "person")

      expect(unpaused).to be_a(described_class::Unpaused)
      expect(unpaused).to be_frozen
      expect(unpaused.run).to be_a(Workspace::WorkflowRun)
      expect(unpaused.run.paused).to be_nil
      expect([unpaused.action, unpaused.held]).to eq(["dispatch", "attempt"])
    end

    it "answers action none and no held kind when nothing was held or done" do
      paused

      unpaused = decisions.unpause("wr_1", actor: "person")

      expect([unpaused.action, unpaused.held]).to eq(["none", nil])
    end

    it "starts a held attempt with what its dispatch was given" do
      paused(run_hash(state: "passed", extra: {"state" => "waiting"}),
        hold: {"kind" => "attempt", "cause" => "review_rejected", "context" => "fresh", "budgeted" => false, "pane" => "%3", "identity" => "id", "text" => "why", "retry_of" => 1})

      run = decisions.unpause("wr_1", actor: "person").run

      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "review_rejected", context: "fresh", budgeted: false,
                                                         retry_of: {"pane" => "%3", "identity" => "id", "text" => "why", "attempt" => 1}}]])
      expect(run.paused).to be_nil
      expect(run.to_h).not_to have_key("pause_hold")
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false, actor: "person", cause: "unpause"}]])
      expect(change.events).to eq([unpaused_event("dispatch", "attempt")])
    end

    it "starts a held round through restart_review" do
      hash = run_hash(state: "reviewing", extra: {"state" => "waiting"})
      hash["steps"]["plan"]["review"] = {"round" => 2, "delivery" => nil, "held" => "paused"}
      paused(hash, hold: {"kind" => "round", "review_round" => 2})

      decisions.unpause("wr_1", actor: "person")

      expect(progress.calls).to eq([[:restart_review, "plan"]])
      expect(evaluation.calls).to eq([[:review_round, "wr_1", {"step" => "plan"}]])
      expect(change.events).to eq([unpaused_event("round", "round")])
    end

    it "delivers a held rerun through restart_review" do
      hash = run_hash(state: "reviewing", extra: {"state" => "waiting"})
      hash["steps"]["plan"]["review"] = {"round" => 1, "delivery" => nil, "held" => Workspace::WorkflowRoundRerun::PAUSED_RERUN}
      paused(hash, hold: {"kind" => "round", "cause" => "rerun", "step" => "plan", "attempt" => 1, "review_round" => 1, "rerun" => ["a"]})

      decisions.unpause("wr_1", actor: "person")

      expect(progress.calls).to eq([[:restart_review, "plan"]])
      expect(change.events).to eq([unpaused_event("rerun", "round")])
    end

    it "types a held line for the same attempt, marking it delivering again from now" do
      delivery = {"step" => "plan", "attempt" => 1, "pane" => "%3", "text" => "Read it."}
      paused(run_hash, hold: {"kind" => "delivery", "step" => "plan", "attempt" => 1, "delivery" => delivery})

      run = decisions.unpause("wr_1", actor: "person").run

      expect(change.deliveries).to eq([delivery])
      expect(run.steps["plan"].attempts.size).to eq(1)
      expect(run.steps["plan"].last_attempt.to_h).to include("delivery" => "delivering", "delivering_since" => "2026-11-10T12:00:00.000Z")
      expect(dispatch.calls).to be_empty
      expect(change.events).to eq([unpaused_event("deliver", "delivery")])
    end

    it "drops a held line whose attempt has ended, typing nothing" do
      hash = run_hash(state: "failed", extra: {"state" => "waiting"})
      hash["steps"]["plan"]["attempts"].last["ended_at"] = "2026-11-10T11:30:00Z"
      paused(hash, hold: {"kind" => "delivery", "step" => "plan", "attempt" => 1, "delivery" => {"step" => "plan"}})

      run = decisions.unpause("wr_1", actor: "person").run

      expect(change.deliveries).to be_empty
      expect(run.to_h).not_to have_key("pause_hold")
      expect(change.events).to eq([unpaused_event("none", "delivery")])
    end

    it "makes the run wait on pane_gone when the open attempt's pane is gone" do
      paused

      run = decisions_over(RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, gone: ["%3"], idle: ["%3"])).unpause("wr_1", actor: "person").run

      expect(run.state).to eq("waiting")
      expect(run.reason).to include("code" => "pane_gone", "details" => include("pane" => "%3", "step" => "plan", "kind" => "dispatch"))
      expect(run.steps["plan"].state).to eq("running")
      expect(evaluation.calls).to be_empty
      expect(change.events).to eq([unpaused_event("pane_gone")])
    end

    it "decides the open attempt when its pane's turn is over" do
      paused

      decisions_over(RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, idle: ["%3"])).unpause("wr_1", actor: "person")

      expect(evaluation.calls).to eq([[:evaluate, "plan"]])
      expect(change.events).to eq([unpaused_event("evaluate")])
    end

    it "leaves alone an attempt whose line is still on its way" do
      hash = run_hash
      hash["steps"]["plan"]["attempts"].last.merge!("delivery" => "delivering", "started_at" => "2026-11-10T11:59:30Z")
      paused(hash)

      decisions_over(RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, idle: ["%3"])).unpause("wr_1", actor: "person")

      expect(evaluation.calls).to be_empty
      expect(change.events).to eq([unpaused_event("none")])
    end

    it "leaves an agent still working alone" do
      paused

      run = decisions.unpause("wr_1", actor: "person").run

      expect(run.paused).to be_nil
      expect(run.state).to eq("running")
      expect(evaluation.calls).to be_empty
      expect(dispatch.calls).to be_empty
      expect(change.deliveries).to be_empty
      expect(change.events).to eq([unpaused_event("none")])
    end

    describe "after pause --interrupt" do
      def mark(pid: 41, kind: "claude") = {"pane" => "%3", "pid" => pid, "kind" => kind, "step" => "plan", "attempt" => 1}

      def interrupted(extra = {})
        hash = run_hash
        hash["steps"]["plan"]["attempts"].last["prompt_file"] = "/work/app/.workflow/wr_1/plan.1.md"
        hash["paused"] = pause_of.merge("interrupt" => mark)
        stored(hash.merge(extra))
      end

      def panes_with(**rest) = RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, pids: {"%3" => 41}, **rest)

      it "types one continue line into the idle pane, adding no attempt and spending nothing" do
        interrupted

        unpaused = decisions_over(panes_with(turn_over: ["%3"], idle: ["%3"])).unpause("wr_1", actor: "person")

        expect(dispatch.calls).to eq([[:type_continue, "wr_1", "%3", {workspace: "app", actor: "person", cause: "unpause",
                                                                      text: "Continue step plan. Your instructions are still in /work/app/.workflow/wr_1/plan.1.md."}]])
        expect([unpaused.action, unpaused.continued, unpaused.warning]).to eq(["continue", true, nil])
        expect(unpaused.run.steps["plan"].attempts.size).to eq(1)
        expect(unpaused.run.to_h).not_to have_key("continue_pending")
        expect(unpaused.run.to_h).not_to have_key("extra_attempts")
        expect(evaluation.calls).to be_empty
        expect(change.events).to eq([unpaused_event("continue")])
      end

      def over_dispatch(dispatch)
        described_class.new(interrupter: interrupter, change: change, store: store, progress: progress, dispatch: dispatch, evaluation: evaluation, attempt_record: attempt_record,
          gate_note: gate_note, panes: panes_with(turn_over: ["%3"]), guard: guard, clock: -> { now })
      end

      it "reads a refused continue line the dispatch put back as pending, with the refusal as a warning, not an error" do
        interrupted
        dispatch = RecordingDispatch.new(continue_kick: {ok: false, code: "pane_busy", message: "the agent is in the middle of a turn", pending: true})

        unpaused = over_dispatch(dispatch).unpause("wr_1", actor: "person")

        expect([unpaused.action, unpaused.continued]).to eq(["continue", "pending"])
        expect(unpaused.warning).to eq("the continue line was not typed into pane %3: the agent is in the middle of a turn")
        expect(dispatch.calls.first[2]).to eq("%3")
        expect(dispatch.calls.first.dig(3, :cause)).to eq("unpause")
      end

      it "hands the dispatch the mark with since now, and answers false for a line no tick will retry (a gone pane)" do
        interrupted
        dispatch = RecordingDispatch.new(continue_kick: {ok: false, code: "pane_gone", message: "gone", pending: false})
        marks = []
        allow(dispatch).to receive(:type_continue).and_wrap_original { |original, run_id, mark, **kw| marks << mark && original.call(run_id, mark, **kw) }

        unpaused = over_dispatch(dispatch).unpause("wr_1", actor: "person")

        expect(unpaused.continued).to be(false)
        expect(marks).to eq([mark.merge("since" => "2026-11-10T12:00:00Z")])
      end

      it "goes by idle? for an agent other than Claude Code" do
        interrupted("paused" => pause_of.merge("interrupt" => mark(kind: "codex")))

        expect(decisions_over(panes_with(idle: ["%3"])).unpause("wr_1", actor: "person").action).to eq("continue")
      end

      it "types nothing before the pane proves idle and leaves the mark as continue_pending" do
        interrupted

        unpaused = decisions_over(panes_with(idle: ["%3"])).unpause("wr_1", actor: "person")

        expect(dispatch.calls).to be_empty
        expect(evaluation.calls).to be_empty
        expect([unpaused.action, unpaused.continued]).to eq(["continue_pending", "pending"])
        expect(unpaused.run.to_h["continue_pending"]).to eq(mark.merge("since" => "2026-11-10T12:00:00Z"))
        expect(change.events).to eq([unpaused_event("continue_pending")])
      end

      it "reads a continue_pending a second pause kept, and types its line" do
        hash = run_hash
        hash["steps"]["plan"]["attempts"].last["prompt_file"] = "/p.md"
        paused(hash.merge("continue_pending" => mark.merge("since" => "2026-11-10T11:30:00Z")))

        unpaused = decisions_over(panes_with(turn_over: ["%3"])).unpause("wr_1", actor: "person")

        expect(unpaused.action).to eq("continue")
        expect(unpaused.run.to_h).not_to have_key("continue_pending")
        expect(dispatch.calls.map(&:first)).to eq([:type_continue])
      end

      it "ignores a mark whose pane's process changed and falls through to the idle branch" do
        interrupted

        unpaused = decisions_over(RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, pids: {"%3" => 99}, turn_over: ["%3"], idle: ["%3"])).unpause("wr_1", actor: "person")

        expect(unpaused.action).to eq("evaluate")
        expect(dispatch.calls).to be_empty
        expect(evaluation.calls).to eq([[:evaluate, "plan"]])
        expect(unpaused.run.to_h).not_to have_key("continue_pending")
      end

      it "keeps the mark as continue_pending, typing nothing, when tmux names no pid for the pane" do
        interrupted

        unpaused = decisions_over(RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}, pids: {}, turn_over: ["%3"], idle: ["%3"])).unpause("wr_1", actor: "person")

        expect([unpaused.action, unpaused.continued]).to eq(["continue_pending", "pending"])
        expect(unpaused.run.to_h["continue_pending"]).to eq(mark.merge("since" => "2026-11-10T12:00:00Z"))
        expect(dispatch.calls).to be_empty
        expect(evaluation.calls).to be_empty
      end

      it "ignores a mark for an attempt that has ended" do
        hash = interrupted
        hash["steps"]["plan"]["attempts"].last["ended_at"] = "2026-11-10T11:50:00Z"
        hash["steps"]["plan"]["state"] = "failed"

        unpaused = decisions_over(panes_with(turn_over: ["%3"])).unpause("wr_1", actor: "person")

        expect(unpaused.action).to eq("none")
        expect(dispatch.calls).to be_empty
      end

      it "makes the run wait on pane_gone when the marked pane is gone" do
        interrupted

        expect(decisions_over(panes_with(gone: ["%3"])).unpause("wr_1", actor: "person").action).to eq("pane_gone")
        expect(dispatch.calls).to be_empty
      end
    end

    it "leaves a gate waiting, its reason shown again" do
      reason = {"code" => "waiting_you", "since" => "2026-11-10T11:50:00Z", "details" => {"kind" => "gate"}}
      paused(run_hash(state: "passed", gate: waiting_gate, reason: reason, extra: {"state" => "waiting"}))

      run = decisions.unpause("wr_1", actor: "person").run

      expect(run.reason).to eq(reason)
      expect(progress.calls).to be_empty
      expect(change.events).to eq([unpaused_event("none")])
    end
  end
end
