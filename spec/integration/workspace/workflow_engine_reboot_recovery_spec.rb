require "spec_helper"
require "tmpdir"

# A restart-step resume that carries `reboot_recovery` counts on the run and records `reboot_recovered`, over a real
# run store in a temporary directory, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine do
  around do |example|
    Dir.mktmpdir("wf-reboot-recovery") do |dir|
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
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { InterruptibleWorkflowPanes.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, round_snapshot: {"head" => "1" * 40, "tree_sha256" => "t" * 64}, round_check: nil) }
  let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:recorder) { UsageAttemptRecord.new(guard: guard, clock: -> { now.first }) }
  let(:flow) { Workspace::WorkflowDefinition.parse("max_attempts: 5\nsteps:\n  build:\n    prompt: Build it.\n    produces: [out.md]\n", id: "flow", source: "global", path: "/defs/flow.yml") }

  subject(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {}, workspace_known: ->(_) { false }, event_log: event_log,
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), attempt_record: recorder, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
    engine.start(actor: "person", definition: flow, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def run = stored_run(store, "wr_1")

  def recover(bound: "shell") = engine.resume("wr_1", actor: "daemon", restart_step: true, bound: bound, reboot_recovery: {"workspace" => "app.worktree-x"})

  def lines(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  def run_bytes = [File.binread(File.join(runs_dir, "wr_1.json")), File.binread(store.events_path("wr_1"))]

  it "reads 0 recoveries on a run that has none" do
    expect(Workspace::WorkflowRun.from_h(run).reboot_recoveries).to eq(0)
  end

  it "counts each restart and writes a reboot_recovered event for it" do
    recover
    expect(run["reboot_recoveries"]).to eq(1)
    recover
    expect(run["reboot_recoveries"]).to eq(2)

    expect(lines("reboot_recovered").map { |e| e.slice("workspace", "outcome", "count", "actor") }).to eq([
      {"workspace" => "app.worktree-x", "outcome" => "restarted", "count" => 1, "actor" => "daemon"},
      {"workspace" => "app.worktree-x", "outcome" => "restarted", "count" => 2, "actor" => "daemon"}
    ])
    expect(Workspace::WorkflowRun.from_h(run).reboot_recoveries).to eq(2)
  end

  it "does not count a plain restart" do
    engine.resume("wr_1", actor: "person", restart_step: true, bound: "shell")

    expect(run).not_to have_key("reboot_recoveries")
    expect(lines("reboot_recovered")).to be_empty
  end

  it "changes nothing when the restart is refused for a closed attempt" do
    edit_run(store, "wr_1") { |stored| stored["steps"]["build"]["attempts"].last["ended_at"] = "2026-10-04T12:00:30Z" }
    before = run_bytes

    expect { recover }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_open_attempt") }

    expect(run_bytes).to eq(before)
  end

  it "changes nothing when the restart is refused for a paused run" do
    engine.pause("wr_1", actor: "person")
    before = run_bytes

    expect { recover }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_paused") }

    expect(run_bytes).to eq(before)
  end

  it "changes nothing when the restart is refused because the agent is still working" do
    before = run_bytes

    expect { recover(bound: "busy") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("step_still_working") }

    expect(run_bytes).to eq(before)
    expect(lines("reboot_recovered")).to be_empty
  end

  it "changes nothing when the open attempt is no longer the one the recovery saw" do
    before = run_bytes

    expect { engine.resume("wr_1", actor: "person", restart_step: true, bound: "idle", reboot_recovery: {"workspace" => "app.worktree-x", "attempt" => 7}) }
      .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["expected"], e.details["attempt"]]).to eq(["no_open_attempt", 7, 1]) }

    expect(run_bytes).to eq(before)
  end

  it "restarts when the open attempt is the one the recovery saw" do
    engine.resume("wr_1", actor: "person", restart_step: true, bound: "idle", reboot_recovery: {"workspace" => "app.worktree-x", "attempt" => 1})

    expect(run["reboot_recoveries"]).to eq(1)
  end

  it "changes nothing while another process holds a live claim on the step's infra retry" do
    edit_run(store, "wr_1") do |stored|
      stored["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => now.first.utc.iso8601},
                         "infra_retry" => {"cause" => "pane_gone", "n" => 1, "max" => 2, "due" => now.first.utc.iso8601,
                                           "claimed_at" => now.first.utc.iso8601, "claimed_by" => {"pid" => 42, "started" => "s"}}}
    end
    before = run_bytes

    expect { recover(bound: "idle") }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details["pid"]]).to eq(["infra_retry_not_claimed", 42]) }

    expect(run_bytes).to eq(before)
    expect(lines("reboot_recovered")).to be_empty
  end

  it "restarts over a stale infra retry claim" do
    edit_run(store, "wr_1") do |stored|
      stored["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => (now.first - 900).utc.iso8601},
                         "infra_retry" => {"cause" => "pane_gone", "n" => 1, "max" => 2, "due" => (now.first - 800).utc.iso8601,
                                           "claimed_at" => (now.first - 700).utc.iso8601, "claimed_by" => {"pid" => 42, "started" => "s"}}}
    end

    recover(bound: "idle")

    expect(run["reboot_recoveries"]).to eq(1)
  end

  it "answers restart_refusal with the bound pane the caller gives" do
    expect(engine.restart_refusal(store.run("wr_1"))&.code).to eq("step_still_working")
    expect(engine.restart_refusal(store.run("wr_1"), bound: "gone")).to be_nil
  end

  context "when the run has spent its attempts" do
    let(:flow) { Workspace::WorkflowDefinition.parse("max_attempts: 1\nsteps:\n  build:\n    prompt: Build it.\n    produces: [out.md]\n", id: "flow", source: "global", path: "/defs/flow.yml") }
    let(:restore) { double("restore") }
    let(:config) { instance_double(Workspace::WorkflowConfig, recover_max_per_run: 2) }
    let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: worktree) }

    def workflow_recover
      Workspace::WorkflowRecover.new(store: store, engine: engine, restore: restore, readiness: double("readiness"), panes: panes,
        liveness: ->(names) { names.to_h { |name| [name, false] } }, project_config: project_config, config: config,
        session_name: ->(name) { name }, sleeper: ->(_) {}, clock: -> { now.first })
    end

    it "refuses the restart as attempts_spent through WorkflowRecover, restoring nothing, in a real run and a dry run" do
      before = run_bytes
      [false, true].each do |dry_run|
        result = workflow_recover.call(dry_run: dry_run) { {} }
        expect(result[:results].map { |row| row.values_at("run_id", "outcome", "reason") }).to eq([["wr_1", "refused", "attempts_spent"]])
        expect(result).to include(status: "failed", exit_code: 1)
      end
      expect(run_bytes).to eq(before)
    end
  end

  it "raises a UsageError for reboot_recovery without restart_step" do
    expect { engine.resume("wr_1", actor: "daemon", reboot_recovery: {"workspace" => "app.worktree-x"}) }
      .to raise_error(Workspace::UsageError, /needs restart_step/)
  end
end
