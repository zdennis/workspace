require "spec_helper"
require "tmpdir"

# A fan_out group's dispatch through the real engine over a real run store in a temporary directory: every sibling
# starts at once, each in its own author pane with its own binding, attempt and line. FakeWorkflowPanes stands in for
# tmux and the agent daemon, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine do
  around do |example|
    Dir.mktmpdir("wf-fan-out") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after { EventKeysCheck.verify!(runs_dir, archive_dir) }

  let(:worktree) { File.join(@dir, "app") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { "wr_1" }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:composer) { FakeStepComposer.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  subject(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: composer, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def definition(yaml) = Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")

  let(:checks) do
    <<~YAML
      checks:
        checkout: shared
        fan_out:
          lint:
            prompt: Lint the change.
            produces: [lint.md]
          test:
            prompt: Test the change.
            produces: [test.md]
    YAML
  end
  let(:report) { "report:\n  prompt: Report.\n" }
  let(:mid_chain) { definition("steps:\n  plan:\n    prompt: Plan.\n    produces: [plan.md]\n#{(checks + report).gsub(/^/, "  ")}") }
  let(:first_group) { definition("steps:\n#{(checks + report).gsub(/^/, "  ")}") }

  def start(definition, **rest)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5", **rest)
  end

  def run = stored_run(store, "wr_1")

  def to_checks
    start(mid_chain)
    path = File.join(worktree, ".workflow", "wr_1", "plan.md")
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
  end

  # Each sibling's attempt, binding and typed line, as the fan-out left them.
  def expect_both_started
    expect(panes.spawns).to eq(["app.worktree-x"])
    expect(panes.bound.transform_values { |entry| entry.slice(:run_id, :step, :attempt, :role) }).to eq(
      "%5" => {run_id: "wr_1", step: "lint", attempt: 1}, "%101" => {run_id: "wr_1", step: "test", attempt: 1}
    )
    %w[lint test].each do |step|
      attempts = run["steps"][step]["attempts"]
      expect(attempts.map { |attempt| attempt["n"] }).to eq([1])
      expect(attempts.first).not_to have_key("delivery")
      expect(attempts.first["prompt_file"]).to end_with("/steps/#{step}.1.prompt.md")
      expect(File.read(attempts.first["prompt_file"])).to include("#{step.capitalize} the change.")
      expect(run["steps"][step]["state"]).to eq("running")
    end
    expect(panes.kicks.last(2).map { |kick| [kick[:pane], kick[:text]] }).to eq([
      ["%5", "Read #{run["steps"]["lint"]["attempts"].first["prompt_file"]} and follow it."],
      ["%101", "Read #{run["steps"]["test"]["attempts"].first["prompt_file"]} and follow it."]
    ])
    expect(run["steps"]["lint"]["pane"]).to eq("%5")
    expect(run["steps"]["test"]["pane"]).to eq("%101")
    expect(run).to include("state" => "running", "pane" => "%5")
    expect(run["steps"]["report"]).to eq("state" => "pending", "attempts" => [])
  end

  it "starts both siblings of a group in the middle of the chain once the step before it passes, each in its own pane" do
    to_checks

    expect(run["steps"]["plan"]["state"]).to eq("passed")
    expect_both_started
    dispatched = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == "step_dispatching" }
    expect(dispatched.map { |line| [line["step"], line["pane"], line["cause"]] }).to eq([["plan", "%5", "first"], ["lint", "%5", "next_step"], ["test", "%101", "next_step"]])
  end

  it "starts both siblings of a group that is the workflow's first step when the run starts" do
    start(first_group)

    expect_both_started
    expect(run["steps"]["lint"]["reason"]).to be_nil
  end

  it "starts both siblings of a group that is the workflow's first step when a run that never started is resumed" do
    start(first_group, dispatch: false)
    expect(panes.kicks).to be_empty

    engine.resume("wr_1", actor: "person")

    expect_both_started
  end

  it "leaves only the sibling whose pane is gone waiting, and the other sibling and the run going" do
    start(mid_chain)
    panes.queue_kicks({ok: true}, {ok: false, code: "pane_gone", message: "pane %101 is gone"})
    panes.gone << "%101"
    path = File.join(worktree, ".workflow", "wr_1", "plan.md")
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)

    engine.turn_ended("wr_1", actor: "agent", pane: "%5")

    expect(run["steps"]["test"]["state"]).to eq("waiting")
    expect(run["steps"]["test"]["reason"]).to include("code" => "pane_gone", "details" => include("step" => "test", "pane" => "%101"))
    expect(run["steps"]["test"]["attempts"].first).to include("outcome" => "not_delivered", "code" => "pane_gone")
    expect(run["steps"]["lint"]["state"]).to eq("running")
    expect(run["steps"]["lint"]["attempts"].first).not_to have_key("outcome")
    expect(run["steps"]["lint"]["reason"]).to be_nil
    expect(run["state"]).to eq("running")
    expect(panes.kicks.map { |kick| kick[:pane] }).to eq(%w[%5 %5 %101])
    expect(panes.kicks[1][:text]).to eq("Read #{run["steps"]["lint"]["attempts"].first["prompt_file"]} and follow it.")
  end

  describe "a sibling's turn end" do
    before { start(first_group) }

    def finish(step, pane, **rest)
      path = File.join(worktree, ".workflow", "wr_1", "#{step}.md")
      File.write(path, "done\n")
      File.utime(now.first, now.first, path)
      engine.turn_ended("wr_1", actor: "agent", pane: pane, **rest)
    end

    it "evaluates the step of the pane it ended in, whichever sibling the cursor is on" do
      expect(run["current"]).to eq("test")

      finish("lint", "%5", step: "lint")
      expect(run["steps"]["lint"]["state"]).to eq("passed")
      expect(run["steps"]["test"]["state"]).to eq("running")

      finish("test", "%101", step: "test")
      expect(run["steps"]["test"]["state"]).to eq("passed")
      expect(run["steps"]["lint"]["state"]).to eq("passed")
    end

    # Pins the cursor's meaning for now, until the group's join (T9) replaces group progression: after a sibling
    # passes, progress puts the cursor back on the sibling still running (the last one dispatched), not on the one
    # just evaluated. The nudger, status and deny read it.
    it "leaves the cursor on the sibling still running after the other passes" do
      expect(run["current"]).to eq("test")

      finish("lint", "%5", step: "lint")

      expect(run["steps"]["lint"]["state"]).to eq("passed")
      expect(run["steps"]["test"]["state"]).to eq("running")
      expect(run["current"]).to eq("test")
    end

    it "finds the sibling from the pane's binding when no step is named" do
      finish("lint", "%5")

      expect(run["steps"]["lint"]["state"]).to eq("passed")
      expect(run["steps"]["test"]["state"]).to eq("running")
    end

    it "ignores a pane that is not bound to the run, and a pane that is not the named step's" do
      finish("lint", "%999")
      finish("lint", "%101", step: "lint")

      expect(run["steps"]["lint"]["state"]).to eq("running")
      expect(run["steps"]["test"]["state"]).to eq("running")
    end
  end
end
