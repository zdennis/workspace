require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The sweep ending a stall whose cause has cleared on the step's own pane, so the step and run clocks run again:
# a real engine over a tmpdir store, fake panes and a fake clock, so nothing spawns.
RSpec.describe Workspace::WorkflowSweep, "ending a stall" do
  around do |example|
    Dir.mktmpdir("wf-sweep-close") do |dir|
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
  let(:pressed) { [] }
  let(:sweep) do
    interrupter = ->(*args) { pressed << args }
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    described_class.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews,
      turn_failed_after: -> { 1800 }, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def flow(step_timeout: "2h", run_timeout: nil)
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      #{"timeout: #{run_timeout}\ntimeout_action: interrupt" if run_timeout}
      steps:
        build:
          prompt: Build it.
          context: continue
          #{"timeout: #{step_timeout}\n    on_timeout: fail" if step_timeout}
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  def begin_run(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def advance(seconds) = now[0] += seconds

  def working
    panes.stale.delete("wr_1")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
  end

  def shell = panes.rows["%5"] = {"pane_id" => "%5", "kind" => "shell", "state" => "idle", "idle_seconds" => 120}

  def failed_turn
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "idle", "idle_seconds" => 1900, "turn_failed" => true,
                        "turn_failed_since" => (now.first - 1900).utc.iso8601}
  end

  # What brings each cause about and keeps it standing on a later pass.
  def stand(cause)
    case cause
    when "pane_gone" then panes.stale << "wr_1"
    when "agent_gone" then shell
    else failed_turn
    end
  end

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def recoveries = events.select { |each| each["type"] == "step_recovered" }

  def attempt = stored_run(store, "wr_1")["steps"]["build"]["attempts"].first

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  # Works an hour, stalls on +cause+ and stands stalled for 3h.
  def stall_for_three_hours(cause, definition = flow)
    begin_run(definition)
    working
    advance(3600)
    stand(cause)
    expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => cause)
    advance(3 * 3600)
  end

  {"pane_gone" => "pane_back", "agent_gone" => "agent_back", "turn_failed" => "turn_recovered"}.each do |cause, action|
    context "after a #{cause} stall" do
      it "records #{action} and the stall's until once the cause has cleared, and goes on with the pass" do
        stall_for_three_hours(cause)
        working

        row = only_row(sweep.call)

        expect(row).to include("outcome" => "nothing", "reason" => "healthy")
        expect(recoveries).to contain_exactly(include("cause" => cause, "action" => action, "step" => "build", "attempt" => 1))
        expect(attempt["stalls"]).to eq([{"cause" => cause, "since" => (now.first - 3 * 3600).utc.iso8601, "until" => now.first.utc.iso8601}])
        expect(stored_run(store, "wr_1")["sweep"]["recovered"]).to include(cause => now.first.utc.iso8601)
      end

      it "times the step out with on_timeout: fail once it works past 2h of active time" do
        stall_for_three_hours(cause)
        working
        sweep.call
        advance(1800)
        expect(only_row(sweep.call)).to include("reason" => "healthy")
        advance(1900)

        row = only_row(sweep.call)

        expect(row).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
        expect(pressed).to eq([["app.worktree-x", "%5", Workspace::AgentProvider.find("claude").interrupt_keys]])
        expect(attempt).to include("outcome" => "failed", "code" => "step_timed_out")
      end

      it "reaches spent and presses for a run with timeout_action: interrupt" do
        stall_for_three_hours(cause, flow(step_timeout: nil, run_timeout: "2h"))
        working
        sweep.call
        advance(3700)

        row = only_row(sweep.call)

        expect(row).to include("outcome" => "interrupted", "cause" => "run_timed_out", "action" => "interrupt")
        expect(pressed.size).to eq(1)
      end

      it "ends nothing while the cause still stands" do
        stall_for_three_hours(cause)
        stand(cause) unless cause == "pane_gone"

        row = only_row(sweep.call)

        expect(row).to include("reason" => "already_recorded", "cause" => cause)
        expect(recoveries).to be_empty
        expect(attempt["stalls"]).to eq([{"cause" => cause, "since" => (now.first - 3 * 3600).utc.iso8601}])
      end

      it "writes nothing on a dry run" do
        stall_for_three_hours(cause)
        working
        before = stored_run(store, "wr_1")

        expect(only_row(sweep.call(dry_run: true))).to include("reason" => "healthy")
        expect(stored_run(store, "wr_1")).to eq(before)
        expect(recoveries).to be_empty
      end
    end
  end

  %w[agent_gone turn_failed].each do |cause|
    it "ends no #{cause} stall when the daemon gives no row for the pane" do
      stall_for_three_hours(cause)
      panes.rows.delete("%5")

      row = only_row(sweep.call)

      expect(row).to include("reason" => "unknown")
      expect(recoveries).to be_empty
      expect(attempt["stalls"].first).not_to have_key("until")
    end
  end

  it "reads the pane row once in a pass that ends a stall and then looks at the step" do
    stall_for_three_hours("turn_failed")
    working
    reads = 0
    panes.on_row = -> { reads += 1 }

    sweep.call

    expect(reads).to eq(1)
  end

  it "stops at a moved_on row when the run read again after the close has moved on, marking nothing on it" do
    stall_for_three_hours("agent_gone")
    working
    panes.on_row = -> { edit_run(store, "wr_1") { |run| run["steps"]["build"]["state"] = "reviewing" } }

    row = only_row(sweep.call)

    expect(row).to include("outcome" => "nothing", "reason" => "moved_on")
    expect(events.select { |each| each["type"] == "step_stalled" }.map { |each| each["cause"] }).to eq(["agent_gone"])
    expect(pressed).to be_empty
  end

  it "writes no resumed close for a resume that starts a new attempt" do
    stall_for_three_hours("agent_gone")
    working

    engine.resume("wr_1", actor: "person", from: "build")

    expect(recoveries).to be_empty
  end

  it "ends the attempt's open stall when a person resumes it in the same attempt" do
    stall_for_three_hours("agent_gone")
    working

    engine.resume("wr_1", actor: "person", turn_over: {"step" => "build", "attempt" => 1})

    expect(recoveries).to contain_exactly(include("cause" => "agent_gone", "action" => "resumed", "attempt" => 1))
    expect(attempt["stalls"]).to eq([{"cause" => "agent_gone", "since" => (now.first - 3 * 3600).utc.iso8601, "until" => now.first.utc.iso8601}])
  end
end
