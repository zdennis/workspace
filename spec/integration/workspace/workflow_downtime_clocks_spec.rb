require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The run, step and round clocks leaving out the machine's downtime: a real engine, sweep and status over a tmpdir
# store and a real WorkflowDowntime, with fake panes and a fake clock, so nothing spawns.
RSpec.describe Workspace::WorkflowDowntime, "on the workflow clocks" do
  around do |example|
    Dir.mktmpdir("wf-downtime-clocks") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after { EventKeysCheck.verify!(runs_dir, archive_dir) }

  let(:worktree) { File.join(@dir, "app") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:heartbeat_path) { File.join(@dir, "state", "heartbeat") }
  let(:downtime_path) { File.join(@dir, "state", "downtime.jsonl") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir), wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  # Five hours: the half-hour steps between beats below are the machine at work, the 9h gaps are downtime.
  let(:downtime_after) { 5 * 3600 }
  let(:downtime) do
    described_class.new(heartbeat_path: heartbeat_path, downtime_path: downtime_path, downtime_after: -> { downtime_after }, clock: -> { now.first })
  end
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
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first }, downtime: downtime)
  end
  let(:pressed) { [] }
  let(:sweep) do
    interrupter = ->(*args) { pressed << args }
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    Workspace::WorkflowSweep.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews,
      turn_failed_after: -> { 1800 }, clock: -> { now.first }, downtime: downtime)
  end
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:status) do
    Workspace::WorkflowStatus.new(store: store, panes: panes, snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { instance_double(Workspace::AskStore, list: []) },
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), clock: -> { now.first }, downtime: downtime)
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
    allow(snapshot_client).to receive(:fetch) { {"panes" => panes.rows.values} }
  end

  def flow(step_timeout: nil, on_timeout: "fail", run_timeout: nil, action: "hold")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      #{"timeout: #{run_timeout}\ntimeout_action: #{action}" if run_timeout}
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

  def begin_run(definition)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def advance(seconds) = now[0] += seconds

  # Half an hour of the machine at work, ending in a beat.
  def work_half_hour
    advance(1800)
    downtime.beat
  end

  def working
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
  end

  def idle
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "idle", "idle_seconds" => 120, "state_since" => (now.first - 120).utc.iso8601}
  end

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  def deadline = status.run("wr_1")["runs"].first["deadline"]

  def end_turn = engine.turn_ended("wr_1", actor: "agent", pane: "%5")

  it "reads about 1h used of an 8h timeout for a run started 10h ago with a 9h downtime span, and starts the next step" do
    begin_run(flow(run_timeout: "8h"))
    downtime.beat
    work_half_hour
    advance(9 * 3600)
    downtime.beat
    work_half_hour

    expect(File.readlines(downtime_path).size).to eq(1)
    expect(deadline).to include("limit" => 8 * 3600, "spent" => false)
    expect(deadline["used"]).to be_within(1).of(3600)
    expect(end_turn).to include("state" => "running", "current" => "verify")
  end

  it "does not time out a 2h step started before the gap on the next sweep, and times it out past 2h of active time" do
    begin_run(flow(step_timeout: "2h"))
    working
    downtime.beat
    work_half_hour
    advance(9 * 3600)
    working

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    expect(File.readlines(downtime_path).size).to eq(1)

    work_half_hour
    work_half_hour
    work_half_hour
    expect(only_row(sweep.call)).to include("reason" => "healthy")
    advance(60)

    expect(only_row(sweep.call)).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
  end

  it "cuts an open gap (a heartbeat 9h old, no span recorded) on the first reading" do
    begin_run(flow(run_timeout: "8h"))
    downtime.beat
    work_half_hour
    work_half_hour
    advance(9 * 3600)

    expect(File.exist?(downtime_path)).to be(false)
    expect(deadline["used"]).to be_within(1).of(3600)
    expect(end_turn).to include("state" => "running", "current" => "verify")
  end

  it "raises the limit over active time with resume --extra-time" do
    begin_run(flow(run_timeout: "1h"))
    downtime.beat
    work_half_hour
    advance(9 * 3600)
    downtime.beat
    work_half_hour
    work_half_hour

    held = end_turn
    expect(held).to include("state" => "waiting", "current" => "verify")
    expect(held["reason"]).to include("code" => "run_timed_out")
    expect(held["reason"]["details"]).to include("limit" => 3600, "needed" => 1801, "suggested" => 2700)

    expect { engine.resume("wr_1", actor: "person", extra_seconds: 1800) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_timed_out") }
    run = engine.resume("wr_1", actor: "person", extra_seconds: 1801)

    expect(run).to include("state" => "running", "current" => "verify", "extra_seconds" => 1801)
    expect(deadline).to include("limit" => 5401, "spent" => false)
  end

  context "with no heartbeat and no spans" do
    it "times a step out with on_timeout: fail on wall time" do
      begin_run(flow(step_timeout: "2h"))
      working
      advance(2 * 3600 + 1)

      expect(only_row(sweep.call)).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
    end

    it "only warns for on_timeout: warn" do
      begin_run(flow(step_timeout: "2h", on_timeout: "warn"))
      working
      advance(2 * 3600 + 1)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "timed_out")
      expect(pressed).to be_empty
    end

    it "holds the next step once the run's timeout is used" do
      begin_run(flow(run_timeout: "8h"))
      advance(9 * 3600)

      expect(deadline).to include("spent" => true)
      expect(deadline["used"]).to be_within(1).of(9 * 3600)
      run = end_turn
      expect(run).to include("state" => "waiting", "current" => "verify")
      expect(run["reason"]).to include("code" => "run_timed_out")
    end

    it "presses for a run with timeout_action: interrupt" do
      begin_run(flow(run_timeout: "2h", action: "interrupt"))
      working
      advance(2 * 3600 + 1)

      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "run_timed_out", "action" => "interrupt")
    end
  end

  describe "a review round" do
    def review(round = {})
      begin_run(flow)
      edit_run(store, "wr_1") do |run|
        run["steps"]["build"].merge!("state" => "reviewing", "review_rounds" => 1,
          "review" => {"round" => 1, "delivery" => nil, "started_at" => now.first.utc.iso8601(3), "delivered_at" => now.first.utc.iso8601(3),
                       "pane" => "%9", "window" => "@9", "server_pid" => "100", "redeliveries" => 0}.merge(round))
      end
      panes.bind(workspace: "app.worktree-x", pane: "%9", run_id: "wr_1", role: "reviewer")
    end

    def review_pane_working
      panes.rows["%9"] = {"pane_id" => "%9", "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601, "review" => "wr_1:build:1"}
    end

    it "is not past its review.timeout in active time after a 9h gap, and is pressed once it is" do
      review
      downtime.beat
      advance(9 * 3600)
      review_pane_working

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(pressed).to be_empty

      advance(Workspace::WorkflowReviewSpec::DEFAULT_TIMEOUT + 1)
      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "review_timed_out")
    end

    it "is not lost through lost_round? from the sweep while its recompute mark's age is downtime" do
      review("recompute" => {"started_at" => now.first.utc.iso8601, "try" => 1})
      downtime.beat
      advance(9 * 3600)

      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "nothing", "reason" => "reviewing")

      advance(Workspace::WorkflowTransitions::DELIVERY_WINDOW + 1)
      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "cause" => "lost_round", "action" => "judge_again")
    end

    context "pressed for its 30m review.timeout just before a 1h gap" do
      let(:downtime_after) { 600 }
      let(:spawned) { [] }
      let(:nudger) do
        Workspace::WorkflowNudger.new(store: store, panes: panes, executable: "/ws/bin/workspace", log_path: ->(w) { "/log/#{w}.log" },
          spawner: ->(argv, _log) { spawned << argv }, clock: -> { now.first }, downtime: downtime, error_output: StringIO.new)
      end

      before do
        review("sweep" => {"interrupt" => {"state" => "sent", "at" => now.first.utc.iso8601}})
        downtime.beat
        advance(3600)
      end

      it "is not unanswered on wake: the nudger starts no advance and a tick decides nothing" do
        expect(Workspace::WorkflowTransitions.unanswered_round?(stored_run(store, "wr_1"), now.first)).to be(true)
        expect(Workspace::WorkflowEngine.wakeable?(stored_run(store, "wr_1"), now.first, stops: downtime.spans)).to be_nil

        nudger.tick("app.worktree-x")
        expect(spawned.select { |argv| argv.include?("advance") }).to be_empty
        expect(engine.tick("wr_1", actor: "daemon")).to be_nil
        expect(stored_run(store, "wr_1")["reason"]).to be_nil
      end

      it "is unanswered once 30m of active time has passed since the press" do
        downtime.beat
        3.times do
          advance(500)
          downtime.beat
        end
        expect(Workspace::WorkflowEngine.wakeable?(stored_run(store, "wr_1"), now.first, stops: downtime.spans)).to be_nil
        advance(301)

        expect(Workspace::WorkflowEngine.wakeable?(stored_run(store, "wr_1"), now.first, stops: downtime.spans)).to eq(:unanswered)
      end
    end
  end
end
