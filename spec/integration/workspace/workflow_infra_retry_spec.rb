require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# The pane side PaneDispatch gives the retry: every spawn makes the next pane, ready at once.
class InfraRetrySpawns
  attr_reader :spawns, :closed
  attr_accessor :on_spawn

  def initialize
    @spawns = []
    @closed = []
    @next = 9
  end

  def session_live?(_name) = true

  def spawn(name, kind)
    @spawns << [name, kind]
    @on_spawn&.call
    pane = "%#{@next}"
    @next += 1
    Workspace::PaneDispatch::Spawned.new(pane: pane, ready: Workspace::AgentReadiness::Result.new(ready: true), label: "Claude Code", closed: false)
  end

  def close_unused(_name, id, window: nil)
    @closed << id
    true
  end
end

# WorkflowInfraRetry over a real engine and run store in a temporary directory, with fake panes, a fake pane
# dispatch and a fake clock, so nothing spawns: two advances racing for one due retry, and one `agent_gone` run
# from the sweep's schedule through `workflow advance` to a new attempt in a new pane.
RSpec.describe Workspace::WorkflowInfraRetry do
  around do |example|
    Dir.mktmpdir("wf-infra-retry-call") do |dir|
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
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:dispatch) { InfraRetrySpawns.new }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:agent_commands) { instance_double(Workspace::AgentCommands, kind: "claude") }
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
    Workspace::WorkflowSweep.new(store: store, engine: engine, panes: panes, interrupter: ->(*) {}, reviews: reviews,
      infra_retry_max: -> { 2 }, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def retrier(pid) = described_class.new(engine: engine, store: store, dispatch: dispatch, lock_holder: liveness, agent_commands: agent_commands, pid: pid, clock: -> { now.first })

  def run = stored_run(store, "wr_1")

  def events(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  # A run whose agent in %5 exited to a shell, scheduled by the sweep, with the clock past its 60s wait.
  def due_agent_gone_run
    definition = Workspace::WorkflowDefinition.parse("max_attempts: 5\nsteps:\n  build:\n    prompt: Build it.\n", id: "flow", source: "global", path: "/defs/flow.yml")
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
    now[0] += 600
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "shell", "state" => "idle", "idle_seconds" => 120}
    expect(sweep.call.first).to include("cause" => "agent_gone", "action" => "infra_retry_scheduled")
    now[0] += 61
    expect(Workspace::WorkflowTransitions.wakeable?(run, now.first)).to eq(:infra_retry)
  end

  it "lets only one of two advances on one due retry spawn a pane, the other finding the claim held" do
    due_agent_gone_run
    second = nil
    dispatch.on_spawn = -> { second ||= retrier(5151).call(store.run("wr_1")) }
    snapshot = store.run("wr_1")

    expect(retrier(4242).call(snapshot)).to eq([:restarted, 1, "%9"])
    expect(second).to eq(:not_due)
    # The first advance's snapshot, read again by a late advance, names an attempt the run has left.
    expect(retrier(6161).call(snapshot)).to eq(:not_due)

    expect(dispatch.spawns).to eq([["app.worktree-x", "claude"]])
    expect(dispatch.closed).to be_empty
    expect(events("infra_retry_claimed").size).to eq(1)
    expect(events("infra_retry_claimed").first).to include("n" => 1, "cause" => "agent_gone")
  end

  it "walks one agent_gone run from the sweep's schedule through workflow advance to a new attempt in the new pane" do
    due_agent_gone_run
    command = Workspace::Commands::Workflow.new(lint: nil, catalog: nil, engine: engine, status: nil, store: store, panes: panes, files: nil, run_files: nil,
      process_tree: nil, lock_holder: liveness, infra_retry: retrier(4242), clock: -> { now.first }, output: StringIO.new)
    kicks_before = panes.kicks.size

    expect(command.advance(run: "wr_1")).to be_nil

    attempts = run["steps"]["build"]["attempts"]
    expect(attempts.map { |each| each["n"] }).to eq([1, 2])
    expect(attempts.first["outcome"]).to eq("interrupted")
    expect(attempts.last).to include("retry_of" => 1)
    expect(attempts.last).not_to have_key("redelivered")
    expect(run["pane"]).to eq("%9")
    expect(panes.pane_of("wr_1")).to eq("%9")
    expect(Workspace::WorkflowTransitions.infra_retries(run, "build")).to eq(1)
    expect(panes.kicks.drop(kicks_before).map { |kick| kick[:pane] }).to all(eq("%9"))
    expect(events("run_resumed").last).to include("restart_step" => true, "infra_retry" => 1, "actor" => "daemon")
    expect(Workspace::WorkflowTransitions.wakeable?(run, now.first)).not_to eq(:infra_retry)
  end
end
