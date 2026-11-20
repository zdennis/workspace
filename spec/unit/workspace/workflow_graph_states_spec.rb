require "spec_helper"
require "json"

RSpec.describe Workspace::WorkflowGraphStates do
  def fixture(name)
    JSON.parse(File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs", "#{name}.json")))
  end

  def mark(hash)
    run = Workspace::WorkflowRun.from_h(hash)
    described_class.mark(Workspace::WorkflowGraph.build(run.definition).to_h, run)
  end

  def nodes(model)
    model["nodes"].to_h { |node| [node["id"], node.slice("state", "passes", "attempts")] }
  end

  def fail_edge(model, from)
    model["edges"].find { |edge| edge["kind"] == "fail" && edge["from"] == from }
  end

  describe "looped_twice.json, an rpiv run whose verify failed twice and sent it back to implement" do
    let(:model) { mark(fixture("looped_twice")) }

    it "marks implement passed with three passes: its stored state, not its history" do
      expect(nodes(model)["implement"]).to eq("state" => "passed", "passes" => 3, "attempts" => 3)
    end

    it "marks verify current with three attempts and no pass (two fails and the running one)" do
      expect(nodes(model)["verify"]).to eq("state" => "current", "passes" => 0, "attempts" => 3)
    end

    it "puts the run's loop count on the verify -> implement fail edge" do
      expect(fail_edge(model, "verify")).to include("to" => "implement", "loops" => 2)
    end

    it "marks the steps and the gate before the loop passed and leaves the terminals unmarked" do
      expect(nodes(model).slice("research", "plan", "plan.gate")).to eq("research" => {"state" => "passed", "passes" => 1, "attempts" => 1},
        "plan" => {"state" => "passed", "passes" => 1, "attempts" => 1}, "plan.gate" => {"state" => "passed"})
      expect(nodes(model).slice(".start", ".end")).to eq(".start" => {}, ".end" => {})
    end

    it "keeps the model's keys and order, and is frozen" do
      expect(model.keys).to eq(%w[nodes edges legend])
      expect(model["nodes"].map { |node| node["id"] }).to eq(%w[.start research plan plan.gate implement verify .end])
      expect(model).to be_frozen
      expect(model["nodes"].last).to be_frozen
    end
  end

  it "marks a gate waiting for a person waiting, with its passed step and the next step pending (waiting_gate.json)" do
    marked = nodes(mark(fixture("waiting_gate")))

    expect(marked).to include("build" => {"state" => "passed", "passes" => 1, "attempts" => 1}, "build.gate" => {"state" => "waiting"},
      "test" => {"state" => "pending", "passes" => 0, "attempts" => 0})
  end

  it "marks a step in a live review round current and its review waiting (reviewing.json)" do
    marked = nodes(mark(fixture("reviewing")))

    expect(marked["build"]).to eq("state" => "current", "passes" => 0, "attempts" => 1)
    expect(marked["build.review"]).to eq("state" => "waiting")
    expect(marked["build.gate"]).to eq("state" => "pending")
  end

  it "marks every node of a completed run passed, with no loops taken (completed.json)" do
    model = mark(fixture("completed"))

    expect(model["nodes"].filter_map { |node| node["state"] }.uniq).to eq(["passed"])
    expect(fail_edge(model, "test")["loops"]).to eq(0)
  end

  it "marks a legacy run with no workflow key from its stored definition (legacy_minimal.json)" do
    hash = fixture("legacy_minimal")
    hash.delete("workflow")

    expect(nodes(mark(hash))).to include("build" => {"state" => "passed", "passes" => 1, "attempts" => 1}, "build.gate" => {"state" => "passed"},
      "test" => {"state" => "passed", "passes" => 1, "attempts" => 1})
  end

  it "counts an overridden attempt as a pass" do
    hash = fixture("completed")
    hash["steps"]["build"]["attempts"] = [{"n" => 1, "outcome" => "failed"}, {"n" => 2, "outcome" => "overridden"}]

    expect(nodes(mark(hash))["build"]).to eq("state" => "passed", "passes" => 1, "attempts" => 2)
  end

  describe "states a fixture does not hold" do
    let(:base) { fixture("waiting_gate") }

    def with(build: {}, run: {})
      base.merge(run).merge("steps" => base["steps"].merge("build" => base["steps"]["build"].merge(build)))
    end

    it "marks the run's current step waiting while the run waits on it (a hold, a backoff)" do
      marked = nodes(mark(with(build: {"state" => "failed"}.merge("gate" => nil), run: {"state" => "waiting"})))

      expect(marked["build"]["state"]).to eq("waiting")
    end

    it "marks a failed step that is not current failed" do
      marked = nodes(mark(with(build: {"state" => "failed"}, run: {"current" => "test", "state" => "running"})))

      expect(marked["build"]["state"]).to eq("failed")
    end

    it "marks a rejected gate failed, or pending while its step runs again" do
      rejected = {"gate" => {"state" => "rejected"}}

      expect(nodes(mark(with(build: rejected.merge("state" => "passed"))))["build.gate"]).to eq("state" => "failed")
      expect(nodes(mark(with(build: rejected.merge("state" => "running"))))["build.gate"]).to eq("state" => "pending")
    end

    it "marks a gate rejected --to another step pending while the run goes on, and failed once the run ended" do
      rejected = {"gate" => {"state" => "rejected"}, "state" => "passed"}

      expect(nodes(mark(with(build: rejected, run: {"current" => "test", "state" => "running"})))["build.gate"]).to eq("state" => "pending")
      expect(nodes(mark(with(build: rejected, run: {"current" => "test", "state" => "cancelled"})))["build.gate"]).to eq("state" => "failed")
    end

    it "marks the in-flight step of a run that ended failed, not current" do
      marked = nodes(mark(with(build: {"state" => "running", "gate" => nil}, run: {"state" => "cancelled"})))

      expect(marked["build"]["state"]).to eq("failed")
    end
  end

  describe "a review" do
    let(:base) { fixture("reviewing") }

    def review_of(build)
      hash = base.merge("steps" => base["steps"].merge("build" => base["steps"]["build"].merge(build)))
      nodes(mark(hash))["build.review"]["state"]
    end

    it "is passed when the last attempt's round approved" do
      expect(review_of("state" => "passed", "review" => nil, "attempts" => [{"n" => 1, "outcome" => "passed", "review_outcome" => {"passed" => true}}])).to eq("passed")
    end

    it "is failed when the last round rejected and the step is not running again" do
      expect(review_of("state" => "failed", "review" => nil, "attempts" => [{"n" => 1, "outcome" => "failed", "review_outcome" => {"passed" => false}}])).to eq("failed")
    end

    it "is pending once the step runs a new attempt after a rejection" do
      attempts = [{"n" => 1, "outcome" => "failed", "review_outcome" => {"passed" => false}}, {"n" => 2}]
      expect(review_of("state" => "running", "review" => nil, "attempts" => attempts)).to eq("pending")
    end

    it "is failed when its round stopped without deciding" do
      expect(review_of("review" => {"round" => 1, "ended_at" => "2026-01-01T00:00:01Z"})).to eq("failed")
    end

    it "is waiting when its round is held" do
      expect(review_of("review" => {"round" => 1, "held" => "budget"})).to eq("waiting")
    end
  end

  describe "a run of a definition with a fan_out group" do
    let(:hash) do
      fixture("looped_twice").merge(
        "definition" => WorkflowGraphGolden::GROUPED.merge("id" => "demo"),
        "current" => "test", "state" => "running", "loops" => {"checks->plan" => 2},
        "steps" => {"plan" => {"state" => "passed", "attempts" => []}, "lint" => {"state" => "passed", "attempts" => []},
                    "test" => {"state" => "running", "attempts" => []}}
      )
    end
    let(:model) { mark(hash) }

    it "marks each sibling's state and leaves the fork and join unmarked" do
      expect(nodes(model).slice("lint", "test", "checks.group", "checks.join")).to eq(
        "lint" => {"state" => "passed", "passes" => 0, "attempts" => 0}, "test" => {"state" => "current", "passes" => 0, "attempts" => 0},
        "checks.group" => {}, "checks.join" => {}
      )
    end

    it "counts the group's loops from its join edge and a sibling's own goto from its own key" do
      expect(fail_edge(model, "checks.join")).to include("loop_key" => "checks->plan", "loops" => 2)
      expect(fail_edge(model, "lint")["loops"]).to eq(0)
    end
  end
end
