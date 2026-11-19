require "spec_helper"
require "json"

# The fixtures in spec/fixtures/workflow_runs are run files the real engine wrote under the simulator (fixed
# clock and run id, the temporary directory replaced by /tmp/workspace-simulate, each prompt_sha256 by a token).
# reviewing, parked, swept_stall, budget_hold_extended, attempt_detail, cancelled, legacy_minimal, unknown_keys and looped_twice are those
# files with the keys the simulator never writes added or removed by hand, in the shapes the engine writes them.
RSpec.describe Workspace::WorkflowRun do
  let(:dir) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs") }
  let(:names) { Dir.children(dir).select { |each| each.end_with?(".json") }.map { |each| File.basename(each, ".json") }.sort }

  def text(name)
    File.read(File.join(dir, "#{name}.json"))
  end

  def run(name)
    described_class.from_h(JSON.parse(text(name)))
  end

  it "has a fixture for each state a run is stored in" do
    expect(names).to include("waiting_gate", "running_attempt", "parked", "retry_backoff", "budget_spent", "run_timed_out", "budget_hold_extended",
      "swept_stall", "attempt_detail", "completed", "cancelled", "legacy_minimal", "unknown_keys", "reviewing")
  end

  it "gives back every fixture byte for byte" do
    Dir.children(dir).select { |each| each.end_with?(".json") }.each do |file|
      name = File.basename(file, ".json")
      expect(JSON.pretty_generate(run(name).to_h)).to eq(text(name)), "#{name} changed in a round trip"
    end
  end

  it "keeps keys it has no reader for, in their order" do
    given = run("unknown_keys")

    expect(given.to_h.keys.first).to eq("aa_first")
    expect(given.to_h.keys.last).to eq("zz_future")
    expect(given.to_h["zz_future"]).to eq("b" => 1, "a" => [1, {"x" => nil}])
    expect(given.steps.values.first.to_h["note_to_self"]).to eq("kept")
    expect(given.steps.values.first.attempts.first.to_h["new_measure"]).to eq(3.5)
  end

  describe "readers" do
    it "read a step being reviewed: its round, the rounds spent and the attempt that ended checks_passed" do
      step = run("reviewing").step("build")

      expect(step.state).to eq("reviewing")
      expect(step.review).to eq("round" => 1, "delivery" => "delivering", "started_at" => "2026-01-01T00:00:00.000Z", "pending" => ["skeptic"], "redeliveries" => 0)
      expect(step.review_rounds).to eq(1)
      expect(step.last_attempt.outcome).to eq("checks_passed")
      expect(step.last_attempt.review_outcome).to be_nil
    end

    it "read the run's own keys" do
      given = run("running_attempt")

      expect(given).to have_attributes(id: "wr_simulated", workflow: "demo", title: "Demo", workspace: "simulation",
        state: "running", current: "build", pane: "%sim", loops: {}, pending_context: [], schema_version: 1)
      expect(given.worktree).to eq("/tmp/workspace-simulate/checkout")
      expect(given.definition["steps"].map { |each| each["id"] }).to eq(%w[build test])
    end

    it "read the parts that hang on a run" do
      expect(run("parked").parked).to include("id" => "0123456789abcdef", "from" => "running")
      expect(run("retry_backoff").backoff).to include("to" => "build", "until" => "2026-01-01T00:02:02Z")
      expect(run("retry_backoff").reason["code"]).to eq("retry_backoff")
      expect(run("budget_hold_extended")).to have_attributes(extra_tokens: 100000, extra_attempts: 2)
      expect(run("budget_hold_extended").budget_hold).to include("pane" => "%sim")
      expect(run("swept_stall").sweep).to include("step" => "build", "attempt" => 1)
      expect(run("swept_stall").guard_config_seen).to eq("0123456789abcdef")
      expect(run("cancelled").cancelled_by).to eq("workspace_killed")
      expect(run("completed")).to have_attributes(state: "completed", ended_at: run("completed").to_h["ended_at"])
    end

    it "read steps, the current step and a gate" do
      given = run("waiting_gate")

      expect(given.steps.keys).to eq(%w[build test])
      expect(given.step("build")).to have_attributes(state: "passed")
      expect(given.current_step).to be(given.step("build"))
      expect(given.step("build")).to be_gate_waiting
      expect(given.step("test")).not_to be_gate_waiting
      expect(given.step("nope")).to be_nil
    end

    it "read an attempt's keys" do
      attempt = run("attempt_detail").step("build").last_attempt

      expect(attempt).to have_attributes(n: 1, outcome: "passed", agent: "claude", prompt_sha256: "<PROMPT_SHA>")
      expect(attempt.usage).to include("input_tokens" => 1200)
      expect(attempt.head).to eq("before" => "1" * 40, "after" => "2" * 40)
      expect(attempt.evidence.first).to include("kind" => "output", "bytes" => 29)
      expect(attempt.reasons.first).to include("code" => "waiting_you")
      expect(attempt.session).to include("source" => "startup")
      expect(attempt.proofs.first).to include("name" => "commits")
      expect(attempt.remote).to eq("unread" => "unreachable")
      expect(attempt.reported).to include("status" => "pass")
      expect(run("budget_spent").step("test").last_attempt.check).to be_a(Hash)
    end

    it "read nil from an attempt that predates a key" do
      attempt = run("legacy_minimal").step("build").last_attempt

      expect(attempt).to have_attributes(n: 1, evidence: nil, reasons: nil, prompt_sha256: nil, outputs: nil)
      expect(run("legacy_minimal")).to have_attributes(base_guard: nil, definition_sha256: nil, reasons: nil)
    end

    it "give the attempts of a step in order" do
      given = run("budget_spent")

      expect(given.step("build").attempts.map(&:n)).to eq([1, 2])
      expect(given.step("build").last_attempt.n).to eq(2)
      expect(given.step("test").attempts.map(&:n)).to eq([1])
    end
  end

  describe "#summary" do
    it "gives what a file outside workflow may know" do
      summary = run("budget_spent").summary(reads_plan_again: true)

      expect(summary).to have_attributes(id: "wr_simulated", workflow: "demo", title: "Demo", workspace: "simulation",
        worktree: "/tmp/workspace-simulate/checkout", state: "waiting", step: "test", attempt: 1, pane: "%sim",
        reads_plan_again: true)
      expect(summary.step_states).to eq([{"id" => "build", "state" => "passed"}, {"id" => "test", "state" => "failed"}])
    end

    it "has no attempt for a step that was not started" do
      summary = described_class.from_h("current" => "a", "steps" => {"a" => {"state" => "pending", "attempts" => []}}).summary

      expect(summary).to have_attributes(attempt: nil, reads_plan_again: nil, step_states: [])
    end
  end

  describe ".from_h of a Hash with keys missing" do
    it "gives nil readers and never raises" do
      [{}, {"id" => "wr_x"}, {"steps" => nil}, {"steps" => {"a" => nil}}, {"steps" => {"a" => {"attempts" => nil}}},
        {"steps" => {"a" => {"attempts" => [nil, 3]}}}, {"definition" => "x"}, nil, "text"].each do |partial|
        given = nil
        expect { given = described_class.from_h(partial) }.not_to raise_error
        expect { [given.state, given.current_step, given.summary, given.steps.values.map(&:last_attempt)] }.not_to raise_error
      end
    end

    it "reads the review keys of an attempt and a step, nil when absent" do
      given = described_class.from_h({"steps" => {"a" => {"review" => {"round" => 2}, "review_rounds" => 2,
                                                          "attempts" => [{"n" => 1, "reviews" => [{"reviewer" => "x"}], "review_outcome" => "passed", "retry_of" => 1}]}, "b" => {}}})

      expect(given.step("a").review).to eq("round" => 2)
      expect(given.step("a").review_rounds).to eq(2)
      expect(given.step("a").last_attempt.reviews).to eq([{"reviewer" => "x"}])
      expect(given.step("a").last_attempt.review_outcome).to eq("passed")
      expect(given.step("a").last_attempt.retry_of).to eq(1)
      expect([given.step("b").review, given.step("b").review_rounds]).to eq([nil, nil])
    end

    it "reads 0 for a reboot_recoveries that is not an Integer" do
      expect(described_class.from_h({"reboot_recoveries" => "2"}).reboot_recoveries).to eq(0)
      expect(described_class.from_h({"reboot_recoveries" => 2}).reboot_recoveries).to eq(2)
    end

    it "reads nil for every key of an empty run" do
      given = described_class.from_h({})

      expect((described_class::KEYS - %w[reboot_recoveries]).map { |key| given.method(key).call }).to all(be_nil)
      expect(given.reboot_recoveries).to eq(0)
      expect(given.steps).to eq({})
      expect(given.current_step).to be_nil
      expect(given.to_h).to eq({})
    end

    it "gives a partial Hash back as it was" do
      partial = {"id" => "wr_x", "state" => "running", "steps" => {"a" => {"state" => "running"}}}

      expect(described_class.from_h(partial).to_h).to eq(partial)
      expect(described_class.from_h(partial).step("a").attempts).to eq([])
    end
  end

  describe "frozenness" do
    it "freezes the run, its steps, its attempts and every Hash under them" do
      given = run("attempt_detail")
      attempt = given.step("build").last_attempt

      expect([given, given.steps, given.step("build"), given.step("build").attempts, attempt]).to all(be_frozen)
      expect(given.to_h).to be_frozen
      expect(given.definition["steps"]).to be_frozen
      expect(attempt.usage).to be_frozen
      expect(attempt.evidence.first["name"]).to be_frozen
      expect { given.to_h["state"] = "x" }.to raise_error(FrozenError)
    end

    it "leaves the Hash it was given alone" do
      given = {"id" => "wr_x", "steps" => {"a" => {"attempts" => [{"n" => 1}]}}}
      described_class.from_h(given)

      expect(given).not_to be_frozen
      expect(given["steps"]["a"]["attempts"].first).not_to be_frozen
    end

    it "gives an unfrozen deep copy of #to_h through #thawed, equal to it and sharing nothing with it" do
      given = run("attempt_detail")
      copy = given.thawed

      expect(copy).to eq(given.to_h)
      expect(copy.keys).to eq(given.to_h.keys)
      expect([copy, copy["steps"], copy["steps"]["build"]["attempts"], copy["steps"]["build"]["attempts"].last, copy["state"]]).to all(satisfy { |each| !each.frozen? })
      copy["steps"]["build"]["attempts"].last["outcome"] = "changed"
      expect(given.step("build").last_attempt.to_h["outcome"]).not_to eq("changed")
    end

    it "gives a new copy on each #thawed call, so a change to one copy never reaches the next" do
      given = run("attempt_detail")
      first = given.thawed
      first["state"] << "-changed"
      first["steps"]["build"]["attempts"].clear

      expect(given.thawed).to eq(given.to_h)
    end

    it "reuses a Hash that is already frozen all the way down" do
      parsed = JSON.parse(text("parked"), freeze: true)

      expect(described_class.from_h(parsed).to_h).to be(parsed)
    end
  end

  describe "the parts that hang on a run" do
    {
      "parked" => [Workspace::WorkflowRun::Park, "parked"],
      "retry_backoff" => [Workspace::WorkflowRun::Backoff, "backoff"],
      "budget_hold_extended" => [Workspace::WorkflowRun::BudgetHold, "budget_hold"],
      "swept_stall" => [Workspace::WorkflowRun::SweepMarks, "sweep"]
    }.each do |fixture, (klass, key)|
      it "gives back #{key} of #{fixture} as it is stored" do
        stored = run(fixture).to_h[key]
        given = klass.from_h(stored)

        expect(given.to_h).to eq(stored)
        expect(JSON.generate(given.to_h)).to eq(JSON.generate(stored))
        expect(given.to_h.keys).to eq(stored.keys)
        expect(given.to_h).to be_frozen
      end
    end

    it "reads each key and keeps the ones it has no reader for" do
      park = Workspace::WorkflowRun::Park.from_h(run("parked").parked)
      backoff = Workspace::WorkflowRun::Backoff.from_h(run("retry_backoff").backoff)
      marks = Workspace::WorkflowRun::SweepMarks.from_h(run("swept_stall").sweep.merge("future" => 1))

      expect(park).to have_attributes(id: "0123456789abcdef", from: "running")
      expect(backoff).to have_attributes(to: "build", until: "2026-01-01T00:02:02Z")
      expect(marks).to have_attributes(step: "build", attempt: 1)
      expect(marks.to_h["future"]).to eq(1)
      expect(Workspace::WorkflowRun::BudgetHold.from_h(run("budget_hold_extended").budget_hold).pane).to eq("%sim")
    end

    it "reads a missing or non-Hash value as empty" do
      [Workspace::WorkflowRun::Park, Workspace::WorkflowRun::Backoff, Workspace::WorkflowRun::BudgetHold, Workspace::WorkflowRun::SweepMarks].each do |klass|
        [nil, "x", []].each do |bad|
          given = klass.from_h(bad)
          expect(given.to_h).to eq({})
          expect(klass::KEYS.map { |each| given.method(each).call }.compact).to eq([])
        end
      end
    end

    it "compares by what they hold" do
      a = Workspace::WorkflowRun::Park.from_h("id" => "x")

      expect(a).to eq(Workspace::WorkflowRun::Park.from_h("id" => "x"))
      expect(a).not_to eq(Workspace::WorkflowRun::Backoff.from_h("id" => "x"))
      expect(a.hash).to eq(Workspace::WorkflowRun::Park.from_h("id" => "x").hash)
    end
  end

  describe "equality" do
    it "compares runs by what they hold" do
      expect(run("parked")).to eq(run("parked"))
      expect(run("parked")).not_to eq(run("swept_stall"))
      expect(run("parked").hash).to eq(run("parked").hash)
      expect(run("parked").step("build")).to eq(run("parked").step("build"))
    end
  end

  describe "Attempt#refusal" do
    it "reads the stored refusal, nil when the attempt has none" do
      expect(Workspace::WorkflowRun::Attempt.from_h("n" => 1, "refusal" => {"error" => "pane_busy"}).refusal).to eq("error" => "pane_busy")
      expect(Workspace::WorkflowRun::Attempt.from_h("n" => 1).refusal).to be_nil
    end
  end

  describe "Attempt#thawed" do
    it "gives an unfrozen deep copy that changes nothing in the attempt" do
      attempt = Workspace::WorkflowRun::Attempt.from_h("n" => 1, "head" => {"before" => "a"}, "packs" => [{"ref" => "x"}])
      copy = attempt.thawed
      copy["head"]["before"] << "b"
      copy["packs"] << {}

      expect([copy, copy["head"], copy["packs"], copy["packs"].first]).to all(satisfy { |each| !each.frozen? })
      expect(attempt.to_h).to eq("n" => 1, "head" => {"before" => "a"}, "packs" => [{"ref" => "x"}])
    end
  end

  describe "#with_attempt" do
    let(:given) do
      described_class.from_h("id" => "wr_1", "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1}, {"n" => 2, "outcome" => nil}]}})
    end

    it "replaces the step's attempt with the same n and leaves the run it was called on alone" do
      changed = given.with_attempt("plan", Workspace::WorkflowRun::Attempt.from_h("n" => 2, "outcome" => "passed"))

      expect(changed.to_h).to eq("id" => "wr_1", "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1}, {"n" => 2, "outcome" => "passed"}]}})
      expect(changed).to be_frozen
      expect(given.step("plan").last_attempt.outcome).to be_nil
    end

    it "appends a retry's new attempt to a step that already has attempts" do
      changed = given.with_attempt("plan", Workspace::WorkflowRun::Attempt.from_h("n" => 3))

      expect(changed.step("plan").attempts.map(&:n)).to eq([1, 2, 3])
    end

    it "makes the step's attempts list when the step has none" do
      changed = given.with_attempt("build", Workspace::WorkflowRun::Attempt.from_h("n" => 1))

      expect(changed.step("build").attempts.map(&:to_h)).to eq([{"n" => 1}])
    end
  end

  describe "#with_park" do
    it "parks the request under the id and times given, as a new run, keeping the request first" do
      given = described_class.from_h("id" => "wr_1", "current" => "plan")

      parked = given.with_park({"from" => nil, "note" => "hi", "pane" => "%3", "turn_over" => nil}, id: "p1", requested_at: "t0", expires_at: "t1", retries: 2)

      expect(parked.parked).to eq("from" => nil, "note" => "hi", "pane" => "%3", "turn_over" => nil, "id" => "p1", "requested_at" => "t0", "expires_at" => "t1", "retries" => 2)
      expect(parked.to_h.keys).to eq(%w[id current parked])
      expect(given.parked).to be_nil
    end
  end

  describe "#drop_park" do
    it "takes the park off and carries its note to the pending context, leaving the run it was called on alone" do
      given = described_class.from_h("id" => "wr_1", "parked" => {"id" => "p1", "note" => "look at the flaky spec"}, "pending_context" => ["earlier"])

      dropped = given.drop_park

      expect(dropped.to_h).to eq("id" => "wr_1", "pending_context" => ["earlier", "Note from the person who resumed the run: look at the flaky spec"])
      expect(given.parked).to include("id" => "p1")
    end

    it "adds nothing for a park with no note" do
      expect(described_class.from_h("parked" => {"id" => "p1"}, "pending_context" => []).drop_park.to_h).to eq("pending_context" => [])
    end
  end
  describe "#with_paused and #drop_paused" do
    it "stores the pause with its text only when given, and takes it off, leaving the run it was called on alone" do
      given = described_class.from_h("id" => "wr_1")

      paused = given.with_paused(since: "t0", by: "zach", text: "lunch")

      expect(paused.paused).to eq("since" => "t0", "by" => "zach", "text" => "lunch")
      expect(given.with_paused(since: "t0", by: "zach").paused).to eq("since" => "t0", "by" => "zach")
      expect(paused.drop_paused.to_h).to eq("id" => "wr_1")
      expect(given.paused).to be_nil
    end
  end

  describe "per-step slots" do
    def from_hash(hash) = described_class.from_h(hash)

    it "round-trips a run with per-step keys byte for byte, frozen all the way down" do
      hash = {"id" => "r", "reason" => {"code" => "run"}, "steps" => {
        "s1" => {"state" => "running", "reason" => {"code" => "a"}, "backoff" => {"until" => "t"}, "pending_move" => {"to" => "s2"}},
        "s2" => {"state" => "pending", "pending_context" => ["x"], "budget_hold" => {"text" => "t"}}
      }}

      given = from_hash(hash)
      expect(JSON.pretty_generate(given.to_h)).to eq(JSON.pretty_generate(hash))
      expect(given.reason_for("s1")).to be_frozen
      expect(given.pending_move_for("s1")).to be_frozen
    end

    it "reads the run-level value when the step lacks the key, and the step's own value when it has it" do
      given = from_hash("reason" => {"code" => "run"}, "steps" => {"s1" => {"state" => "running"}, "s2" => {"reason" => {"code" => "own"}}})

      expect(given.reason_for("s1")).to eq("code" => "run")
      expect(given.reason_for("s2")).to eq("code" => "own")
    end

    it "reads the step's own nil, without falling back, when the step holds the key with a nil value" do
      given = from_hash("reason" => {"code" => "run"}, "steps" => {"s1" => {"reason" => nil}})

      expect(given.reason_for("s1")).to be_nil
    end

    it "falls back to the run-level backoff of an old run file" do
      given = run("retry_backoff")

      expect(given.backoff).not_to be_nil
      expect(given.step("build").to_h).not_to have_key("backoff")
      expect(given.backoff_for("build")).to eq(given.backoff)
    end

    it "reads nil, without raising, when nothing holds the key" do
      expect(from_hash({}).reason_for("s1")).to be_nil
      expect(from_hash("steps" => {"s1" => {}}).backoff_for("missing")).to be_nil
      expect(from_hash("steps" => "bad").pending_move_for("s1")).to be_nil
      expect(from_hash("steps" => {"s1" => "bad"}).timeout_hold_for("s1")).to be_nil
      expect(from_hash(nil).budget_hold_for(nil)).to be_nil
    end

    it "defines a reader for every per-step key" do
      given = from_hash("steps" => {"s1" => {}})

      expect(given.reason_for("s1")).to be_nil
      expect(given.reasons_for("s1")).to be_nil
      expect(given.backoff_for("s1")).to be_nil
      expect(given.pending_context_for("s1")).to be_nil
      expect(given.continue_pending_for("s1")).to be_nil
      expect(given.pause_hold_for("s1")).to be_nil
      expect(given.retry_of_pending_for("s1")).to be_nil
      expect(given.dispatch_cause_pending_for("s1")).to be_nil
      expect(given.review_retry_for("s1")).to be_nil
      expect(given.pending_move_for("s1")).to be_nil
      expect(given.budget_hold_for("s1")).to be_nil
      expect(given.timeout_hold_for("s1")).to be_nil
      expect(described_class::PER_STEP_KEYS.length).to eq(12)
    end

    it "reads two steps' values independently" do
      given = from_hash("steps" => {"s1" => {"pending_move" => {"to" => "a"}, "pause_hold" => 1}, "s2" => {"pending_move" => {"to" => "b"}}})

      expect(given.pending_move_for("s1")).to eq("to" => "a")
      expect(given.pending_move_for("s2")).to eq("to" => "b")
      expect(given.pause_hold_for("s1")).to eq(1)
      expect(given.pause_hold_for("s2")).to be_nil
    end
  end

  describe "the slot placement rule" do
    def grouped_run
      {"id" => "r", "current" => "lint", "reason" => nil, "pending_context" => [],
       "definition" => {"steps" => [{"id" => "plan"}, {"id" => "lint", "group" => "checks"}, {"id" => "test", "group" => "checks"}]},
       "steps" => {"plan" => {"state" => "passed"}, "lint" => {"state" => "running"}, "test" => {"state" => "running"}}}
    end

    it "scopes a step whose definition entry names a group, and no other" do
      run = grouped_run

      expect(described_class.step_scoped?(run, "lint")).to be(true)
      expect(described_class.step_scoped?(run, "test")).to be(true)
      expect(described_class.step_scoped?(run, "plan")).to be(false)
      expect(described_class.step_scoped?(run, "missing")).to be(false)
      expect(described_class.step_scoped?(run, nil)).to be(false)
      expect(described_class.step_scoped?({"definition" => {"steps" => [{"id" => "a", "group" => ""}]}}, "a")).to be(false)
      expect(described_class.step_scoped?({"definition" => {"steps" => [{"id" => "a", "group" => 7}]}}, "a")).to be(false)
      expect(described_class.step_scoped?({"definition" => "bad"}, "a")).to be(false)
      expect(described_class.step_scoped?(nil, "a")).to be(false)
    end

    described_class::PER_STEP_KEYS.each do |key|
      it "keeps a grouped step's #{key} under its own step, so a sibling's write leaves it alone" do
        run = grouped_run

        described_class.slots(run, "lint")[key] = {"from" => "lint"}
        described_class.slots(run, "test")[key] = {"from" => "test"}

        expect(run["steps"]["lint"][key]).to eq("from" => "lint")
        expect(run["steps"]["test"][key]).to eq("from" => "test")
        expect(run).not_to have_key(key) unless %w[reason pending_context].include?(key)
        frozen = described_class.from_h(run).to_h
        expect(described_class.slot(frozen, "lint", key)).to eq("from" => "lint")
        expect(described_class.slot(frozen, "test", key)).to eq("from" => "test")
      end

      it "writes an ungrouped step's #{key} at the top level of the run, as a run without groups has it" do
        run = grouped_run

        described_class.slots(run, "plan")[key] = {"from" => "plan"}

        expect(run[key]).to eq("from" => "plan")
        expect(run["steps"]["plan"]).not_to have_key(key)
      end
    end

    it "leaves the run-level reason and pending context of an ungrouped step alone when a grouped step writes its own" do
      run = grouped_run.merge("reason" => {"code" => "run"}, "pending_context" => ["run line"])

      described_class.slots(run, "lint")["reason"] = {"code" => "lint"}
      described_class.add_context(run, "lint", "lint line")

      expect(run["reason"]).to eq("code" => "run")
      expect(run["pending_context"]).to eq(["run line"])
      expect(run["steps"]["lint"]).to include("reason" => {"code" => "lint"}, "pending_context" => ["lint line"])
    end

    it "makes the step hash a grouped step lacks, and never one for an ungrouped step" do
      run = grouped_run
      run["steps"].delete("test")

      described_class.slots(run, "test")["backoff"] = {"to" => "test"}
      described_class.slots(run, "plan")["backoff"] = {"to" => "plan"}

      expect(run["steps"]["test"]).to eq("backoff" => {"to" => "test"})
      expect(run["steps"]["plan"]).to eq("state" => "passed")
    end

    it "reads with slot and slot_dig as the readers do, and tells whether the slot holds a key" do
      run = grouped_run.merge("reason" => {"code" => "run", "details" => {"step" => "plan"}})
      run["steps"]["lint"]["reason"] = {"code" => "lint", "details" => {"step" => "lint"}}
      run["steps"]["test"]["continue_pending"] = nil

      expect(described_class.slot(run, "lint", "reason")).to eq("code" => "lint", "details" => {"step" => "lint"})
      expect(described_class.slot(run, "test", "reason")).to eq("code" => "run", "details" => {"step" => "plan"})
      expect(described_class.slot_dig(run, "lint", "reason", "details", "step")).to eq("lint")
      expect(described_class.slot_dig(run, "plan", "backoff", "to")).to be_nil
      expect { described_class.slot_dig(run.merge("reason" => "text"), "plan", "reason", "code") }.to raise_error(TypeError)
      expect(described_class.slot_key?(run, "test", "continue_pending")).to be(true)
      expect(described_class.slot_key?(run, "lint", "continue_pending")).to be(false)
      expect(described_class.slot_key?(run, "plan", "reason")).to be(true)
    end

    it "adds pending context lines after the others, or first" do
      run = grouped_run

      described_class.add_context(run, "lint", "second")
      described_class.add_context(run, "lint", "first", first: true)
      described_class.add_context(run, "plan", "for plan")

      expect(run["steps"]["lint"]["pending_context"]).to eq(%w[first second])
      expect(run["pending_context"]).to eq(["for plan"])
    end

    it "drops every step's own slots but its reason history, and leaves the run-level slots to the caller" do
      run = grouped_run.merge("backoff" => {"to" => "plan"})
      described_class::PER_STEP_KEYS.each do |key|
        run["steps"]["lint"][key] = {"k" => key}
        run["steps"]["test"][key] = {"k" => key}
      end

      described_class.drop_step_slots(run)

      expect(run["steps"]["lint"]).to eq("state" => "running", "reasons" => {"k" => "reasons"})
      expect(run["steps"]["test"]).to eq("state" => "running", "reasons" => {"k" => "reasons"})
      expect(run["backoff"]).to eq("to" => "plan")
      expect(described_class.drop_step_slots({"steps" => "bad"})).to eq("steps" => "bad")
    end

    it "carries a dropped park's note to a grouped current step's own pending context" do
      run = described_class.from_h(grouped_run.merge("parked" => {"id" => "p1", "note" => "careful"}))

      dropped = run.drop_park

      expect(dropped.pending_context_for("lint")).to eq([described_class.resume_note("careful")])
      expect(dropped.pending_context).to eq([])
    end
  end

  describe Workspace::WorkflowRun::Step, "review predicates" do
    def step(state, review) = described_class.from_h({"state" => state, "review" => review}.compact)

    it "reads a round under way as live, a held one as held and an ended one as stopped" do
      expect(step("reviewing", {"round" => 1, "delivery" => "delivering"})).to have_attributes(review_live?: true, review_held?: false, review_stopped?: false)
      expect(step("reviewing", {"round" => 2, "held" => "budget_spent"})).to have_attributes(review_live?: false, review_held?: true, review_stopped?: false)
      expect(step("reviewing", {"round" => 1, "ended_at" => "t"})).to have_attributes(review_live?: false, review_held?: false, review_stopped?: true)
    end

    it "does not read a failed delivery, another state or no round as live" do
      expect(step("reviewing", {"round" => 1, "delivery" => "failed"}).review_live?).to be(false)
      expect(step("running", {"round" => 1}).review_live?).to be(false)
      expect(step("reviewing", nil)).to have_attributes(review_live?: false, review_held?: false, review_stopped?: false)
    end
  end
end
