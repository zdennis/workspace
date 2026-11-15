require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The sweep over a run whose main pane's agent turn ended on an API error: a real engine over a tmpdir store, a
# stubbed guard and a git stand-in (the setup of the golden run spec), so nothing spawns.
RSpec.describe Workspace::WorkflowSweep, "a failed turn" do
  around do |example|
    Dir.mktmpdir("wf-sweep-failed") do |dir|
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
  let(:entries) { {} }
  let(:asked) { [] }

  def sweep_with(turn_failed_after: 1800)
    interrupter = ->(*args) { pressed << args }
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    described_class.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews,
      turn_failed_after: -> { turn_failed_after },
      recovery_entry: ->(workspace, pane) {
        asked << [workspace, pane]
        entries[pane]
      },
      clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def flow(timeout: nil, on_timeout: "warn")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      steps:
        build:
          prompt: Build it.
          context: continue
          #{"timeout: #{timeout}" if timeout}
          on_timeout: #{on_timeout}
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  def begin_run(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def failed_since(seconds_ago, state: "idle", session: "s1")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => state, "idle_seconds" => seconds_ago,
                        "state_since" => now.first.utc.iso8601, "session_id" => session, "turn_failed" => true,
                        "turn_failed_since" => (now.first - seconds_ago).utc.iso8601}
  end

  # A recovery entry that gave up at +at+ (by default just now, after any failure the pane shows).
  def given_up(at: now.first, session: "s1")
    {"session_id" => session, "phase" => "gave_up", "attempts" => 12, "gave_up_at" => at.utc.iso8601(3)}
  end

  def advance(seconds) = now[0] += seconds

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def stalls = events.select { |each| each["type"] == "step_stalled" }

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  it "records one turn_failed stall over two passes once the failure is past the threshold" do
    begin_run
    advance(2000)
    failed_since(1900)
    entries["%5"] = {"session_id" => "s1", "phase" => "watching", "attempts" => 4, "failed_at" => (now.first - 1900).utc.iso8601}
    sweep = sweep_with

    first = only_row(sweep.call)
    second = only_row(sweep.call)

    expect(first).to include("outcome" => "recorded", "cause" => "turn_failed", "action" => "record", "step" => "build")
    expect(first["message"]).to include("31m ago", "recovery attempt 4 of 12 (watching)")
    expect(second).to include("outcome" => "nothing", "reason" => "already_recorded", "cause" => "turn_failed")
    expect(stalls.size).to eq(1)
    expect(stalls.first).to include("step" => "build", "attempt" => 1, "cause" => "turn_failed", "pane" => "%5",
      "since" => (now.first - 1900).utc.iso8601, "recovery_phase" => "watching", "recovery_attempts" => 4)
    expect(asked.first).to eq(["app.worktree-x", "%5"])
  end

  it "records the stall at once when the pane's recovery gave up, before the threshold" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = given_up
    sweep = sweep_with

    sweep.call
    row = only_row(sweep.call)

    expect(row).to include("reason" => "already_recorded", "cause" => "turn_failed")
    expect(stalls.size).to eq(1)
    expect(stalls.first).to include("recovery_phase" => "gave_up", "recovery_attempts" => 12)
  end

  it "records nothing before the threshold while recovery goes on, and says so" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = {"session_id" => "s1", "phase" => "waiting", "attempts" => 1}

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "turn_failed")
    expect(row["message"]).to include("3m ago", "recovery attempt 1 of 12 (waiting)", "after 30m")
    expect(stalls).to be_empty
  end

  it "fails the step past its timeout with on_timeout: fail, before the threshold and with recovery still going" do
    begin_run(flow(timeout: "10m", on_timeout: "fail"))
    advance(700)
    failed_since(200)
    entries["%5"] = {"session_id" => "s1", "phase" => "waiting", "attempts" => 1}

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
    expect(stored_run(store, "wr_1")["steps"]["build"]["attempts"].first).to include("outcome" => "failed", "code" => "step_timed_out")
    expect(stalls.map { |each| each["cause"] }).not_to include("turn_failed")
    expect(pressed).to be_empty
  end

  it "fails the step past its timeout with on_timeout: fail when the recovery gave up" do
    begin_run(flow(timeout: "10m", on_timeout: "fail"))
    advance(700)
    failed_since(200)
    entries["%5"] = given_up

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "timed_out", "cause" => "timed_out")
    expect(stored_run(store, "wr_1")["steps"]["build"]["attempts"].first).to include("outcome" => "failed", "code" => "step_timed_out")
    expect(pressed).to be_empty
  end

  it "does not count a give-up stamped before the failure the pane shows" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = given_up(at: now.first - 3 * 3600)

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "turn_failed")
    expect(row["message"]).to include("no recovery under way")
    expect(stalls).to be_empty
  end

  it "counts a give-up stamped after the failure" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = given_up(at: now.first - 150)

    expect(only_row(sweep_with.call)).to include("outcome" => "recorded", "cause" => "turn_failed")
  end

  it "does not count a give-up with no gave_up_at, written before the stamp existed" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = given_up.except("gave_up_at")

    expect(only_row(sweep_with.call)).to include("outcome" => "nothing", "reason" => "turn_failed")
    expect(stalls).to be_empty
  end

  it "reads a failure time ahead of the clock as just now" do
    begin_run
    advance(300)
    failed_since(-60)

    expect(only_row(sweep_with.call)["message"]).to include("error 0s ago")
  end

  it "records the stall and presses nothing when it is past its timeout with on_timeout: interrupt" do
    begin_run(flow(timeout: "30m", on_timeout: "interrupt"))
    advance(2000)
    failed_since(1900, state: "working")

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "recorded", "cause" => "turn_failed")
    expect(stalls.size).to eq(1)
    expect(pressed).to be_empty
  end

  it "ignores a recovery entry of another session and falls back to the threshold" do
    begin_run
    advance(300)
    failed_since(200)
    entries["%5"] = given_up(session: "old")
    sweep = sweep_with

    early = only_row(sweep.call)
    advance(1700)
    late = only_row(sweep.call)

    expect(early).to include("reason" => "turn_failed")
    expect(early["message"]).to include("no recovery under way")
    expect(late).to include("outcome" => "recorded", "cause" => "turn_failed")
    expect(stalls.first).to include("recovery_phase" => nil, "recovery_attempts" => nil)
  end

  it "still records a recovery that gave up when the threshold is off" do
    begin_run
    advance(5000)
    failed_since(4900)
    sweep = sweep_with(turn_failed_after: nil)

    expect(only_row(sweep.call)).to include("reason" => "turn_failed")
    entries["%5"] = given_up
    expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => "turn_failed")
    expect(stalls.size).to eq(1)
  end
end
