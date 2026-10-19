require "spec_helper"

# A port of the app's src/core/spine/inferred.test.ts.
RSpec.describe Workspace::SpineInferred do
  let(:facts_class) { Workspace::SpineEvaluator::Facts }
  let(:no_facts) { facts_class.new }

  def input(plan: nil, runs: [], review_ready: false, ship: true)
    described_class::Input.new(plan: plan, runs: runs, review_ready: review_ready, ship: ship)
  end

  def counts(**over)
    {"total" => 4, "done" => 0, "in_progress" => 0, "skipped" => 0, "blocked" => 0, "todo" => 4, "left" => 4}.merge(over.transform_keys(&:to_s))
  end

  # The app's planOf: a plan under way, owned by %3.
  def plan_of(**over)
    {"exists" => true, "state" => "working", "owner_pane" => "%3",
     "counts" => counts(total: 4, done: 1, in_progress: 1, todo: 2, left: 3)}.merge(over.transform_keys(&:to_s))
  end

  def empty_plan = plan_of(state: "empty", owner_pane: nil, counts: counts(total: 0, todo: 0, left: 0))

  def pr(state, checks) = Workspace::SpineEvaluator::PrFact.new(state: state, checks: checks)

  def statuses(inp, facts = no_facts) = described_class.stages(inp, facts).to_h { |s| [s["id"], s["state"]] }

  def step(id, state) = {"id" => id, "state" => state}

  def run(steps:, step: "research", pane: "%9") = {"step" => step, "pane" => pane, "steps" => steps}

  it "gives the six stages in order, each marked inferred, with no file" do
    stages = described_class.stages(input, no_facts)

    expect(stages.map { |s| [s["id"], s["title"], s["kind"], s["number"]] }).to eq([
      ["research", "Research", "research", 10], ["plan", "Plan", "plan", 20], ["implement", "Implement", "implement", 30],
      ["verify", "Verify", "verify", 40], ["review", "Review", "review", 50], ["ship", "Ship", "ship", 60]
    ])
    expect(stages).to all(include("inferred" => true, "file" => nil))
    expect(stages.map { |s| s["source"] }).to eq(%w[plan plan plan pr review pr])
  end

  it "shapes each stage as a stage read from a file is shaped, before the verdict keys" do
    file_stage = Workspace::SpineTree::Stage.new(path: "x", id: "x", number: 10, level: 0, file: nil, relative: nil, children: [],
      warnings: [], kind: "custom", depends_on: [], gates: [])

    expect(described_class::Stage.new(kind: "plan", number: 20, status: "unknown", gates: []).to_h.keys).to eq(file_stage.to_h.keys)
  end

  it "leaves Ship out on the project's own checkout" do
    ids = described_class.stages(input(ship: false), no_facts).map { |s| s["id"] }

    expect(ids).not_to include("ship")
    expect(ids.size).to eq(5)
  end

  it "reads Research, Plan and Implement as unknown before the plan is read" do
    expect(statuses(input)).to include("research" => "unknown", "plan" => "unknown", "implement" => "unknown")
  end

  def missing_plan = {"exists" => false, "counts" => counts(total: 0, todo: 0, left: 0), "state" => "empty", "owner_pane" => nil}

  [
    ["no plan file", -> { missing_plan }, {"research" => "not_started", "plan" => "not_started", "implement" => "not_started"}],
    ["an empty plan is being drafted", -> { empty_plan }, {"research" => "skipped", "plan" => "in_progress", "implement" => "not_started"}],
    ["tasks never started wait for approval", -> { plan_of(state: "idle", counts: counts) },
      {"research" => "skipped", "plan" => "in_progress", "implement" => "not_started"}],
    ["work under way", -> { plan_of }, {"research" => "skipped", "plan" => "completed", "implement" => "in_progress"}],
    ["a blocked task", -> { plan_of(state: "blocked", counts: counts(done: 3, blocked: 1, todo: 0, left: 1)) },
      {"plan" => "completed", "implement" => "blocked"}],
    ["every task done", -> { plan_of(state: "done", counts: counts(done: 3, skipped: 1, todo: 0, left: 0)) },
      {"plan" => "completed", "implement" => "completed"}]
  ].each do |name, plan, expected|
    it "from the plan: #{name}" do
      expect(statuses(input(plan: instance_exec(&plan)))).to include(expected)
    end
  end

  it "gives Implement the plan's owner pane, so its owner state shows" do
    facts = facts_class.new(panes: [Workspace::SpineEvaluator::Pane.new(pane: "%3", waiting: false, working: true, since: 10)])

    implement = described_class.stages(input(plan: plan_of(owner_pane: "%3")), facts).find { |s| s["id"] == "implement" }

    expect(implement).to include("owner" => "%3", "owner_state" => "working", "owner_since" => 10)
  end

  [
    ["plan done, checks pass", :done, "pass", "completed"],
    ["plan open, checks pass", :open, "pass", "not_started"],
    ["checks running", :done, "pending", "in_progress"],
    ["checks failing", :done, "fail", "blocked"],
    ["checks failing mid-plan", :open, "fail", "blocked"],
    ["no checks", :done, "none", "not_started"],
    ["gh not read", :done, nil, "not_started"]
  ].each do |name, which, checks, expected|
    it "reads Verify from the checks: #{name}" do
      plan = (which == :done) ? plan_of(state: "done", counts: counts(done: 4, todo: 0, left: 0)) : plan_of
      facts = facts_class.new(pr: checks && pr("open", checks))

      expect(statuses(input(plan: plan), facts)["verify"]).to eq(expected)
    end
  end

  it "has Review under way once the review agent is done and the branch is ahead" do
    expect(statuses(input(review_ready: true))["review"]).to eq("in_progress")
    expect(statuses(input)["review"]).to eq("not_started")
  end

  it "has Ship follow the pull request and carry the default gates" do
    facts = facts_class.new(pr: pr("open", "fail"), git: Workspace::SpineEvaluator::GitFact.new(upstream: true, ahead: 0))

    ship = described_class.stages(input, facts).find { |s| s["id"] == "ship" }

    expect(ship["state"]).to eq("in_progress")
    expect(ship["gate_results"].map { |g| [g["gate"], g["result"]] }).to eq([%w[pushed pass], %w[pr pass], %w[ci fail], %w[merged fail]])
    expect(statuses(input)["ship"]).to eq("not_started")
  end

  it "has a merged pull request complete Review and Ship and pass over the rest" do
    stages = described_class.stages(input(plan: plan_of), facts_class.new(pr: pr("merged", "none")))

    expect(stages.to_h { |s| [s["id"], s["state"]] }).to eq(
      "research" => "skipped", "plan" => "completed", "implement" => "skipped", "verify" => "skipped",
      "review" => "completed", "ship" => "completed"
    )
    expect(stages.to_h { |s| [s["id"], s["source"]] }).to include("plan" => "plan", "implement" => "pr", "review" => "pr")
    expect(Workspace::SpineEvaluator.current(stages)).to be_nil
  end

  it "has a workflow run's steps outrank the plan, with the run's pane on its step" do
    r = run(step: "implement", pane: "%8", steps: [step("research", "passed"), step("plan", "passed"), step("implement", "running"), step("verify", "pending")])

    stages = described_class.stages(input(plan: missing_plan, runs: [r]), no_facts)
    by = stages.to_h { |s| [s["id"], s] }

    expect(by.values_at("research", "plan", "implement", "verify").map { |s| s["status"] }).to eq(%w[completed completed in_progress not_started])
    expect(by["implement"]).to include("owner" => "%8", "source" => "workflow")
    expect(by["plan"]["owner"]).to be_nil
    expect(Workspace::SpineEvaluator.current(stages)).to eq("implement")
  end

  it "reads a failed step as blocked, and ignores a run with no stage steps" do
    done = plan_of(state: "done", counts: counts(done: 4, todo: 0, left: 0))
    expect(statuses(input(plan: done, runs: [run(steps: [step("verify", "failed")])]))["verify"]).to eq("blocked")

    other = run(steps: [step("lint", "running")])
    with_plan = run(steps: [step("plan", "waiting")])
    expect(statuses(input(plan: missing_plan, runs: [other, with_plan]))["plan"]).to eq("in_progress")
  end

  describe "#infer" do
    let(:store) { instance_double(Workspace::WorkflowRunStore) }
    let(:panes) { instance_double(Workspace::WorkflowPanes) }
    let(:git) { instance_double(Workspace::Git) }
    let(:plan_state) { Workspace::PlanState.new }
    subject(:inferred) { described_class.new(workflow_store: store, workflow_panes: panes, git: git, plan_state: plan_state) }

    let(:stored_run) do
      {"id" => "wr_1", "workspace" => "api", "current" => "plan", "pane" => "%2",
       "definition" => {"steps" => [{"id" => "research"}, {"id" => "plan"}]},
       "steps" => {"research" => {"state" => "passed"}, "plan" => {"state" => "running"}}}
    end

    def result(plan:, panes: nil, asks: [], review: nil, review_ahead: nil, pr: nil)
      readings = Workspace::SpineFacts::Readings.new(plan: plan, panes: panes, asks: asks, review_ahead: review_ahead, review: true)
      Workspace::SpineFacts::Result.new(facts: Workspace::SpineEvaluator::Facts.new(review: review, pr: pr), sources: {}, reasons: {}, readings: readings)
    end

    before do
      allow(store).to receive(:active).and_return([stored_run, stored_run.merge("id" => "wr_2", "workspace" => "web")])
      allow(panes).to receive(:pane_of).with("wr_1").and_return("%7")
      allow(git).to receive(:checkout_layout).with("/src/api").and_return({toplevel: "/src/api", common_dir: "/src/.git", linked: true})
    end

    it "reads the workspace's runs with their bound pane, and a linked worktree ships" do
      stages = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: :missing))
      by = stages.to_h { |s| [s["id"], s] }

      expect(by["plan"]).to include("status" => "in_progress", "owner" => "%7", "source" => "workflow")
      expect(by["research"]["status"]).to eq("completed")
      expect(by["implement"]["status"]).to eq("not_started")
      expect(by).to have_key("ship")
    end

    it "falls back to the run's own pane, and leaves Ship out of a main checkout" do
      allow(panes).to receive(:pane_of).and_return(nil)
      allow(git).to receive(:checkout_layout).and_return({toplevel: "/src/api", common_dir: "/src/api/.git", linked: false})

      stages = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: :missing))

      expect(stages.find { |s| s["id"] == "plan" }["owner"]).to eq("%2")
      expect(stages.map { |s| s["id"] }).not_to include("ship")
    end

    it "treats a broken checkout as a main checkout" do
      allow(store).to receive(:active).and_return([])
      allow(git).to receive(:checkout_layout).and_return({toplevel: "/src/api", common_dir: nil, linked: true, broken: true})

      stages = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: :missing))

      expect(stages.map { |s| s["source"] }).to eq(%w[plan plan plan pr review])
    end

    it "derives the plan's state from the owner pane, so a working owner starts Implement" do
      allow(store).to receive(:active).and_return([])
      plan = Workspace::PlanFile.parse("---\nowner_pane: \"%3\"\n---\n## Tasks\n- [ ] T1 One\n- [ ] T2 Two\n")

      idle = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: plan, panes: [{"pane_id" => "%3", "state" => "idle"}]))
      working = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: plan, panes: [{"pane_id" => "%3", "state" => "working"}]))

      expect(idle.find { |s| s["id"] == "implement" }["status"]).to eq("not_started")
      expect(working.find { |s| s["id"] == "implement" }).to include("status" => "in_progress", "owner" => "%3")
    end

    it "reads unknown stages when the plan file could not be read" do
      allow(store).to receive(:active).and_return([])

      stages = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: nil))

      expect(stages.find { |s| s["id"] == "research" }["status"]).to eq("unknown")
    end

    it "is ready for review only when the agent is done and the branch is ahead" do
      allow(store).to receive(:active).and_return([])
      done = Workspace::SpineEvaluator::ReviewFact.new(agent_done: true, changes_requested: false)
      review = ->(res) { inferred.infer(workspace: "api", checkout: "/src/api", result: res).find { |s| s["id"] == "review" }["status"] }

      expect(review.call(result(plan: :missing, review: done, review_ahead: 2))).to eq("in_progress")
      expect(review.call(result(plan: :missing, review: done, review_ahead: nil))).to eq("not_started")
      expect(review.call(result(plan: :missing, review: nil, review_ahead: 2))).to eq("not_started")
    end

    it "reads no runs when the run store can't be read" do
      allow(store).to receive(:active).and_raise(Errno::EACCES)

      stages = inferred.infer(workspace: "api", checkout: "/src/api", result: result(plan: :missing))

      expect(stages.find { |s| s["id"] == "plan" }["source"]).to eq("plan")
    end
  end
end
