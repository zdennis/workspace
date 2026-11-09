require "spec_helper"
require "json"

# The fixtures in spec/fixtures/workflow_runs are run files the real engine wrote under the simulator (fixed
# clock and run id, the temporary directory replaced by /tmp/workspace-simulate, each prompt_sha256 by a token).
# parked, swept_stall, budget_hold_extended, attempt_detail, cancelled, legacy_minimal and unknown_keys are those
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
    expect(names).to include("waiting_gate", "running_attempt", "parked", "retry_backoff", "budget_spent", "budget_hold_extended",
      "swept_stall", "attempt_detail", "completed", "cancelled", "legacy_minimal", "unknown_keys")
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

    it "reads nil for every key of an empty run" do
      given = described_class.from_h({})

      expect(described_class::KEYS.map { |key| given.method(key).call }).to all(be_nil)
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

    it "reuses a Hash that is already frozen all the way down" do
      parsed = JSON.parse(text("parked"), freeze: true)

      expect(described_class.from_h(parsed).to_h).to be(parsed)
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
end
