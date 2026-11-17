require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The sweep scheduling a step's infra retries and recording their exhaustion through a real engine over a tmpdir
# store, with fake panes and a fake clock, so nothing spawns. The claim and the restart are the engine's own calls,
# as `workflow advance` makes them.
RSpec.describe Workspace::WorkflowSweep, "scheduling infra retries" do
  around do |example|
    Dir.mktmpdir("wf-sweep-infra") do |dir|
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
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir), wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:claimant) { {"pid" => 4242, "started" => "Sun Oct  4 12:00:00 2026"} }
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
      checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {},
      workspace_known: ->(_name) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first })
  end
  let(:sweep) do
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: ->(*) {}, clock: -> { now.first })
    described_class.new(store: store, engine: engine, panes: panes, interrupter: ->(*) {}, reviews: reviews,
      infra_retry_max: -> { 2 }, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def begin_run
    definition = Workspace::WorkflowDefinition.parse("max_attempts: 5\nsteps:\n  build:\n    prompt: Build it.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def run = stored_run(store, "wr_1")

  def events(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  def working
    panes.stale.delete("wr_1")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
  end

  def stand(cause)
    if cause == "pane_gone"
      panes.stale << "wr_1"
    else
      panes.rows["%5"] = {"pane_id" => "%5", "kind" => "shell", "state" => "idle", "idle_seconds" => 120}
    end
  end

  # What `workflow advance` does once the retry is due: claim it under the lock, then restart the step.
  def claim_and_restart
    attempt = run["steps"]["build"]["attempts"].last["n"]
    expect(engine.claim_infra_retry("wr_1", actor: "daemon", step: "build", attempt: attempt, claimant: claimant, alive: ->(_) { true }).first).to eq(:claimed)
    working
    engine.resume("wr_1", actor: "daemon", restart_step: true, bound: "unknown", infra_retry: claimant, pane: "%5")
  end

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  %w[agent_gone pane_gone].each do |cause|
    it "schedules #{cause} restarts 60s then 300s out, then records infra_retries_exhausted once" do
      begin_run
      working
      now[0] += 600
      stand(cause)

      expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => cause, "action" => "infra_retry_scheduled")
      expect(events("infra_retry_scheduled").last).to include("cause" => cause, "n" => 1, "max" => 2, "due" => "2026-10-04T12:11:00Z")

      now[0] += 60
      claim_and_restart
      now[0] += 600
      stand(cause)
      expect(only_row(sweep.call)).to include("action" => "infra_retry_scheduled")
      expect(events("infra_retry_scheduled").last).to include("n" => 2, "due" => "2026-10-04T12:26:00Z")

      now[0] += 300
      claim_and_restart
      now[0] += 600
      stand(cause)
      expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => cause, "action" => "infra_retries_exhausted")
      2.times do
        now[0] += 300
        expect(only_row(sweep.call)).to include("reason" => "already_recorded")
      end

      expect(events("infra_retry_scheduled").size).to eq(2)
      expect(events("infra_retries_exhausted")).to contain_exactly(include("cause" => cause, "n" => 2, "max" => 2, "reason" => "retries_spent", "attempt" => 3))
      expect(Workspace::WorkflowTransitions.infra_retry(run, now.first)).to include(state: :exhausted)
      # One change: the attempt's stall and its exhaustion are written together, in that order.
      last_two = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["attempt"] == 3 }.map { |line| line["type"] }
      expect(last_two.last(2)).to eq(%w[step_stalled infra_retries_exhausted])
    end
  end
end
