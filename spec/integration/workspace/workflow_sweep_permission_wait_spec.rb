require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The sweep over a run whose step's pane waits at a permission dialog nobody answers: a real engine over a tmpdir
# store, a stubbed guard and a git stand-in (the setup of the turn_failed sweep spec), so nothing spawns.
RSpec.describe Workspace::WorkflowSweep, "a permission dialog nobody answers" do
  around do |example|
    Dir.mktmpdir("wf-sweep-dialog") do |dir|
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
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first }, alerts: alerts)
  end
  let(:alerted) { [] }
  let(:alerts) do
    Workspace::WorkflowAlerts.new(alert_config: instance_double(Workspace::AlertConfig, for_workspace: {notify: "notify-me", workflow: %w[failed]}),
      spawner: ->(_argv, env, _log) { alerted << env })
  end
  let(:pressed) { [] }
  let(:limit_reads) { [] }

  def sweep_with(limit: 3600, spans: [])
    interrupter = ->(*args) { pressed << args }
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    downtime = double("downtime", beat: nil, spans: spans)
    described_class.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews, downtime: downtime,
      permission_wait_limit: -> {
        limit_reads << limit
        limit
      },
      clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  # The step's on_fail would loop back to plan: the dialog's failure must stop the run anyway.
  def flow(timeout: nil, on_timeout: "warn")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      steps:
        plan:
          prompt: Plan it.
          context: continue
        build:
          prompt: Build it.
          context: continue
          #{"timeout: #{timeout}" if timeout}
          on_timeout: #{on_timeout}
          on_fail:
            goto: plan
            max: 3
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  def begin_run(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
    expect(run["current"]).to eq("build")
  end

  def iso(seconds_ago) = (now.first - seconds_ago).utc.iso8601

  # The pane row the daemon gives for +waits+ (`[agent_id, permission, seconds_ago]` each), the pane quiet for
  # +idle+ seconds (by default since the oldest wait opened).
  def pane_waits(*waits, idle: nil, message: nil)
    oldest = waits.map(&:last).max
    reason = (waits.any? { |each| each[1] }) ? "waiting_permission" : "waiting_prompt"
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "waiting", "idle_seconds" => idle || oldest,
                        "state_since" => iso(oldest), "waiting_reason" => reason, "waiting_since" => iso(oldest),
                        "waiting_seconds" => oldest, "waiting_message" => message,
                        "waits" => waits.map { |id, permission, ago| {"agent_id" => id, "tool" => nil, "input" => nil, "permission" => permission, "since" => iso(ago)} }}
  end

  def dialog_since(seconds_ago, reason: "waiting_permission", idle: nil)
    pane_waits([nil, reason == "waiting_permission", seconds_ago], idle: idle)
  end

  def advance(seconds) = now[0] += seconds

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def stalls = events.select { |each| each["type"] == "step_stalled" }

  def run = stored_run(store, "wr_1")

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  it "says how long the pane has waited and when the step stops, before the limit, and writes nothing" do
    begin_run
    advance(1800)
    dialog_since(1200)

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
    expect(row["message"]).to eq("pane %5 has waited 20m at a permission dialog; the step fails and the run stops once it has waited 1h 0m (workflows.permission_wait_limit)")
    expect(stalls).to be_empty
    expect(run["state"]).to eq("running")
  end

  it "fails the step with permission_wait_timeout and stops the run past the limit, whatever on_fail says, pressing nothing" do
    begin_run
    kicks = panes.kicks.size
    advance(4000)
    dialog_since(3700)

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "timed_out", "cause" => "permission_wait", "action" => "fail", "step" => "build", "attempt" => 1)
    expect(row["message"]).to eq("pane %5 waited 1h 1m at a permission dialog (limit 1h 0m); the step failed and the run stopped with it still open. " \
      "Deny or close it (or stop the agent) before `workspace workflow resume wr_1`: allowed, the old attempt carries on without the run's locks and its work is ignored")
    expect(alerted.map { |env| env["WORKSPACE_ALERT_EVENT"] }).to eq(["failed"])
    expect(alerted.first).to include("WORKSPACE_ALERT_RUN_ID" => "wr_1", "WORKSPACE_ALERT_STEP" => "build")
    expect(run["state"]).to eq("waiting")
    expect(run.dig("steps", "build", "state")).to eq("failed")
    expect(run["reason"]).to include("code" => "failed_check")
    expect(run.dig("reason", "details")).to include("code" => "permission_wait_timeout", "code_source" => "engine",
      "cause" => "permission_wait", "pane" => "%5", "waited" => 3700, "limit" => 3600)
    expect(run["loops"]).to eq({})
    expect(stalls.map { |each| each["cause"] }).to eq(["permission_wait"])
    expect(events.find { |each| each["type"] == "step_recovered" }).to include("cause" => "permission_wait", "action" => "failed")
    expect(pressed).to be_empty
    expect(panes.kicks.size).to eq(kicks)
  end

  it "does not count the time the machine was down" do
    begin_run
    advance(4000)
    dialog_since(3700)
    spans = [{"since" => (now.first - 3000).utc.iso8601, "until" => (now.first - 1000).utc.iso8601}]

    row = only_row(sweep_with(spans: spans).call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
    expect(row["message"]).to include("has waited 28m at")
    expect(run["state"]).to eq("running")
  end

  it "leaves the run alone when the dialog closed or another opened between the two reads" do
    begin_run
    advance(4000)
    dialog_since(3700)
    reads = 0
    panes.on_row = -> do
      reads += 1
      dialog_since(0) if reads == 2
    end

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "permission_wait")
    expect(stalls).to be_empty
    expect(run["state"]).to eq("running")
  end

  it "reports the act and writes nothing on a dry run" do
    begin_run
    advance(4000)
    dialog_since(3700)
    before = [run, events]

    row = only_row(sweep_with.call(dry_run: true))

    expect(row).to include("outcome" => "dry_run", "cause" => "permission_wait", "action" => "fail")
    expect([run, events]).to eq(before)
  end

  it "leaves the run alone when allow refuses it" do
    begin_run
    advance(4000)
    dialog_since(3700)

    row = only_row(sweep_with.call(allow: ->(_run) { "the run's own pane" }))

    expect(row).to include("outcome" => "nothing", "reason" => "refused", "message" => "the run's own pane", "cause" => "permission_wait")
    expect(run["state"]).to eq("running")
  end

  it "reads no limit and acts on nothing in a budget-only pass" do
    begin_run
    advance(4000)
    dialog_since(3700)

    expect(sweep_with.call(budget_only: true)).to be_empty
    expect(limit_reads).to be_empty
    expect(run["state"]).to eq("running")
  end

  it "never stops a step whose pane waits on a question for a person" do
    begin_run
    advance(90_000)
    dialog_since(89_000, reason: "waiting_prompt")

    expect(only_row(sweep_with.call)).to include("outcome" => "nothing", "reason" => "prompt")
    expect(run["state"]).to eq("running")
  end

  it "says no limit is set when the limit is off" do
    begin_run
    advance(90_000)
    dialog_since(89_000)

    row = only_row(sweep_with(limit: nil).call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
    expect(row["message"]).to end_with("; no limit is set (workflows.permission_wait_limit)")
  end

  it "fails the step the same way when its own timeout with on_timeout: fail runs out at a dialog, the limit off" do
    begin_run(flow(timeout: 600, on_timeout: "fail"))
    advance(700)
    dialog_since(300)

    row = only_row(sweep_with(limit: nil).call)

    expect(row).to include("outcome" => "timed_out", "cause" => "permission_wait", "action" => "fail")
    expect(row["message"]).to start_with("pane %5 waited 5m at a permission dialog (past the step's 10m timeout); the step failed and the run stopped with it still open.")
    expect(run["state"]).to eq("waiting")
    expect(run.dig("reason", "details")).to include("code" => "permission_wait_timeout", "elapsed" => 700, "timeout" => 600)
    expect(pressed).to be_empty
  end
  it "measures from the oldest permission wait, not an older question to the person" do
    begin_run
    advance(4000)
    pane_waits([nil, false, 3700], ["a1", true, 300])

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
    expect(row["message"]).to start_with("pane %5 has waited 5m at a permission dialog;")
    expect(run["state"]).to eq("running")
  end

  it "leaves alone a wait past the limit while the pane shows output: a sub-agent's wait left after it was gone" do
    begin_run
    advance(4000)
    pane_waits(["a1", true, 3700], idle: 5)

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission", "cause" => "permission_wait")
    expect(row["message"]).to include("showed output 5 seconds ago (it must be quiet for 10m)", "a sub-agent that is gone")
    expect(stalls).to be_empty
    expect(run["state"]).to eq("running")
  end

  it "leaves the run alone when the pane showed output between the two reads" do
    begin_run
    advance(4000)
    dialog_since(3700)
    reads = 0
    panes.on_row = -> do
      reads += 1
      panes.rows["%5"] = panes.rows["%5"].merge("idle_seconds" => 3) if reads == 2
    end

    expect(only_row(sweep_with.call)).to include("outcome" => "nothing", "reason" => "pane_changed")
    expect(run["state"]).to eq("running")
  end

  it "stops a run whose pane sits at an agent's waiting screen past the limit, as for a dialog, naming no other wait's message" do
    begin_run
    advance(4000)
    pane_waits(["screen", false, 3700], message: "sign in")

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "timed_out", "cause" => "permission_wait", "action" => "fail")
    expect(row["message"]).to start_with("pane %5 waited 1h 1m at a waiting screen (limit 1h 0m);")
    expect(run.dig("reason", "details")).to include("code" => "permission_wait_timeout", "screen" => true)
  end

  it "fails a step past its timeout with on_timeout: fail at a waiting screen, the limit off" do
    begin_run(flow(timeout: 600, on_timeout: "fail"))
    advance(700)
    pane_waits(["screen", false, 300])

    expect(only_row(sweep_with(limit: nil).call)).to include("outcome" => "timed_out", "cause" => "permission_wait")
    expect(run.dig("reason", "details")).to include("code" => "permission_wait_timeout", "timeout" => 600)
  end

  it "says the age is unknown when the wait has no readable start, and acts only on the step's timeout" do
    begin_run
    advance(90_000)
    dialog_since(89_000)
    panes.rows["%5"]["waits"].first["since"] = "not a time"

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
    expect(row["message"]).to eq("pane %5 waits (for how long is unknown: the wait has no readable start) at a permission dialog; only the step's own timeout can stop it")
  end

  it "answers moved_on when the run moved on between the sweep's read and its change" do
    begin_run
    advance(4000)
    dialog_since(3700)
    reads = 0
    panes.on_row = -> do
      reads += 1
      engine.turn_ended("wr_1", actor: "agent", pane: "%5") if reads == 2
    end

    row = only_row(sweep_with.call)

    expect(row).to include("outcome" => "nothing", "reason" => "moved_on", "cause" => "permission_wait")
    expect(run["current"]).to eq("verify")
    expect(stalls).to be_empty
  end
  it "stops once the pane has been quiet for the window after a redraw minutes after the dialog opened" do
    begin_run
    advance(4000)
    pane_waits([nil, true, 3700], idle: 500)
    sweep = sweep_with

    expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "waiting_permission", "cause" => "permission_wait")

    advance(100)
    panes.rows["%5"]["idle_seconds"] = 600
    row = only_row(sweep.call)

    expect(row).to include("outcome" => "timed_out", "cause" => "permission_wait")
    expect(run.dig("reason", "details")).to include("code" => "permission_wait_timeout", "waited" => 3800)
  end
end
