require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The sweep pressing interrupt when a run's spent tokens plus its running attempt's live figure reach the budget:
# a real engine over a tmpdir store, fake panes, a fake live reader and a fake clock, so nothing spawns.
RSpec.describe Workspace::WorkflowSweep, "a token budget with action: interrupt" do
  around do |example|
    Dir.mktmpdir("wf-sweep-budget") do |dir|
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
  let(:ids) { %w[wr_1 wr_2] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir), wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:git) do
    Class.new do
      def worktree_branch(_path) = "feature/x"

      def common_dir_from_files(_path) = nil
    end.new
  end
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
      checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40),
      excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {},
      workspace_known: ->(_name) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first })
  end
  # The running attempt's live tokens, as the spec sets them, and every prune it was asked for.
  let(:live) do
    Class.new do
      attr_accessor :value
      attr_reader :pruned, :reads

      def initialize
        @pruned = []
        @reads = 0
      end

      def reading(_run, now:)
        @reads += 1
        @value
      end

      def prune(going_ids) = @pruned << going_ids
    end.new
  end
  let(:pressed) { [] }
  let(:sweep) do
    interrupter = ->(*args) { pressed << args }
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    described_class.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews,
      live_usage: live, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def flow(action: "interrupt", run_timeout: nil, step_timeout: nil, on_timeout: "interrupt")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      budget: {tokens: 1000, action: #{action}}
      #{"timeout: #{run_timeout}\ntimeout_action: interrupt" if run_timeout}
      steps:
        build:
          prompt: Build it.
          context: continue
          #{"timeout: #{step_timeout}\n    on_timeout: #{on_timeout}" if step_timeout}
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  def begin_run(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    advance(600)
  end

  def advance(seconds) = now[0] += seconds

  def pane_shows(state, idle_seconds: 0)
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => state, "idle_seconds" => idle_seconds, "state_since" => now.first.utc.iso8601}
  end

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def run_file = stored_run(store, "wr_1")

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  def keys = Workspace::AgentProvider.find("claude").interrupt_keys

  it "does nothing while spent plus live is below the allowance" do
    begin_run
    pane_shows("working")
    live.value = 999

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    expect(pressed).to be_empty
  end

  it "presses once when spent plus live reaches the allowance, and records the live figure on the attempt" do
    begin_run
    pane_shows("working")
    live.value = 1000

    first = only_row(sweep.call)
    second = only_row(sweep.call)

    expect(first).to include("outcome" => "interrupted", "action" => "interrupt", "cause" => "budget_spent",
      "message" => "the run has used 1000 of its 1000 token budget")
    expect(second).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "budget_spent")
    expect(pressed).to eq([["app.worktree-x", "%5", keys]])
    stalled = events.select { |each| each["type"] == "step_stalled" }
    expect(stalled.size).to eq(1)
    expect(stalled.first).to include("cause" => "budget_spent", "used" => 0, "allowance" => 1000, "live" => 1000)
    expect(stalled.first).not_to have_key("elapsed")
    run = run_file
    expect(run["sweep"]["budget_interrupt"]["state"]).to eq("sent")
    expect(run["sweep"]).not_to have_key("interrupt")
    expect(run["steps"]["build"]["attempts"].last["budget_interrupt"]).to include("tokens" => 1000, "used" => 0, "allowance" => 1000)
    expect(run["state"]).to eq("running")
  end

  it "does nothing when the live figure can't be read" do
    begin_run
    pane_shows("working")
    live.value = nil

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    expect(pressed).to be_empty
  end

  it "never presses, nor reads the live figure, for action: stop" do
    begin_run(flow(action: "stop"))
    pane_shows("working")
    live.value = 5000

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    expect(pressed).to be_empty
    expect(live.reads).to eq(0)
  end

  %w[interrupt run_interrupt budget_interrupt].each do |key|
    it "reports already_interrupted when this attempt's #{key} mark stands, and presses nothing" do
      begin_run
      edit_run(store, "wr_1") do |run|
        run["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {}, "recovered" => {}, key => {"state" => "sent", "at" => now.first.utc.iso8601}}
      end
      pane_shows("working")
      live.value = 1200

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "budget_spent")
      expect(pressed).to be_empty
      expect(run_file["steps"]["build"]["attempts"].last).not_to have_key("budget_interrupt")
    end
  end

  it "presses for the run's timeout first when both are due, and that one press serves the budget" do
    begin_run(flow(run_timeout: "5m"))
    pane_shows("working")
    live.value = 1000

    expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "run_timed_out")
    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "run_timed_out")
    expect(pressed.size).to eq(1)
    expect(run_file["sweep"]).not_to have_key("budget_interrupt")
  end

  describe "one press for every cause, whichever comes due first" do
    it "does not press again for a step timeout that comes due after the budget's press" do
      begin_run(flow(step_timeout: "1h"))
      pane_shows("working")
      live.value = 1000
      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "budget_spent")
      advance(3600)
      pane_shows("working")

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "timed_out")
      expect(pressed.size).to eq(1)
      expect(run_file["sweep"]).not_to have_key("interrupt")
    end

    it "fails an on_timeout: fail step after the budget's press without pressing again" do
      begin_run(flow(step_timeout: "1h", on_timeout: "fail"))
      pane_shows("working")
      live.value = 1000
      sweep.call
      advance(3600)
      pane_shows("working")

      expect(only_row(sweep.call)).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
      expect(pressed.size).to eq(1)
    end

    it "does not press again for a step timeout that comes due after the run timeout's press" do
      begin_run(flow(action: "stop", run_timeout: "5m", step_timeout: "1h"))
      pane_shows("working")
      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "run_timed_out")
      advance(3600)
      pane_shows("working")

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "timed_out")
      expect(pressed.size).to eq(1)
    end

    it "presses for the budget when the step is past an on_timeout: warn timeout" do
      begin_run(flow(step_timeout: "5m", on_timeout: "warn"))
      pane_shows("working")
      live.value = 1000

      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "budget_spent")
      expect(pressed.size).to eq(1)
    end
  end

  it "says not_working when the agent is not at work" do
    begin_run
    pane_shows("idle", idle_seconds: 2)
    live.value = 1000

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "not_working", "cause" => "budget_spent")
    expect(pressed).to be_empty
  end

  it "reports on a dry run without claiming" do
    begin_run
    pane_shows("working")
    live.value = 1000

    expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "cause" => "budget_spent", "action" => "interrupt")
    expect(pressed).to be_empty
    run = run_file
    expect(Workspace::WorkflowEngine.sweep_marks(run)).not_to have_key("budget_interrupt")
    expect(run["steps"]["build"]["attempts"].last).not_to have_key("budget_interrupt")
  end

  it "decides a turn that is over with no mark as idle_turn_over" do
    begin_run
    pane_shows("idle", idle_seconds: 30)
    live.value = 1000

    expect(only_row(sweep.call)).to include("outcome" => "evaluated", "cause" => "idle_turn_over")
    expect(pressed).to be_empty
  end

  it "decides a turn ended by its press as interrupted" do
    begin_run
    pane_shows("working")
    live.value = 1000
    sweep.call
    pane_shows("idle", idle_seconds: 30)

    expect(only_row(sweep.call)).to include("outcome" => "evaluated", "cause" => "interrupted")
  end

  it "prunes the live caches to the going runs once per pass, and not on a pass naming one run" do
    begin_run
    pane_shows("working")
    live.value = 0
    sweep.call
    sweep.call(run: "wr_1")

    expect(live.pruned).to eq([["wr_1"]])
  end
end
