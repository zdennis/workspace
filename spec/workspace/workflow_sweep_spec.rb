require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::WorkflowSweep do
  around do |example|
    Dir.mktmpdir("wf-sweep") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

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
  let(:panes) { FakeWorkflowPanes.new }
  let(:composer) { FakeStepComposer.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: notes) }
  let(:engine) do
    Workspace::WorkflowEngine.new(store: store, resources: resources, composer: composer, panes: panes,
      checker: ->(**) { {exit_code: 0, timed_out: false} }, commands_config: commands_config, lineage: lineage, git: git, guard: guard,
      excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, clock: -> { now.first })
  end
  let(:pressed) { [] }
  let(:interrupt_error) { [nil] }
  let(:interrupter) do
    lambda do |workspace, pane, keys|
      raise interrupt_error.first if interrupt_error.first
      pressed << [workspace, pane, keys]
    end
  end
  subject(:sweep) { described_class.new(store: store, engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first }) }

  before do
    FileUtils.mkdir_p(worktree)
    RepoTemplate.copy(:workflow_engine_app, to: worktree) do |root|
      system("git", "-C", root, "init", "-q", "-b", "feature/x", exception: true)
      system("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
    end
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def flow(stall: "20m", timeout: "1h", on_timeout: "warn", on_fail: nil)
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      #{"stall: #{stall}" if stall}
      steps:
        build:
          prompt: Build it.
          produces: [out.md]
          context: continue
          #{"timeout: #{timeout}" if timeout}
          on_timeout: #{on_timeout}
          #{"on_fail: {goto: build, max: 1, context: continue}" if on_fail}
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  def looping
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "loop", source: "global", path: "/defs/loop.yml")
      steps:
        plan:
          prompt: Plan it.
          context: continue
        build:
          prompt: Build it.
          context: continue
          timeout: 1h
          on_timeout: fail
          on_fail: {goto: plan, max: 1, context: continue}
    YAML
  end

  def begin_run(definition = flow)
    engine.start(definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def artifact(name = "out.md", content: "done\n")
    path = File.join(worktree, ".workflow", "wr_1", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.utime(now.first, now.first, path)
  end

  def advance(seconds) = now[0] += seconds

  def pane_shows(state, idle_seconds: 0, kind: "claude")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => kind, "state" => state, "idle_seconds" => idle_seconds, "state_since" => now.first.utc.iso8601}
  end

  def events(run_id = "wr_1") = File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line) }

  def types(run_id = "wr_1") = events(run_id).map { |each| each["type"] }

  def only_row(rows)
    expect(rows.size).to eq(1)
    rows.first
  end

  describe "a step whose agent ended its turn unseen" do
    before do
      begin_run
      advance(1500)
      pane_shows("idle", idle_seconds: 1500)
    end

    it "decides the step as a turn's end would, and records the stall and the recovery before the step's own events" do
      artifact
      row = only_row(sweep.call)

      expect(row).to include("outcome" => "evaluated", "cause" => "idle_turn_over", "action" => "evaluate", "run_id" => "wr_1", "step" => "build")
      expect(types.last(5)).to eq(%w[step_stalled step_recovered step_passed step_dispatching step_dispatched])
      stalled = events.find { |each| each["type"] == "step_stalled" }
      expect(stalled).to include("step" => "build", "attempt" => 1, "cause" => "idle_turn_over", "idle_for" => 1500)
      expect(events.find { |each| each["type"] == "step_recovered" }).to include("step" => "build", "attempt" => 1, "action" => "evaluated")
      expect(store.find("wr_1")).to include("current" => "verify", "state" => "running")
    end

    it "does nothing a second time, and writes no second event" do
      artifact
      sweep.call
      before = events

      row = only_row(sweep.call)

      expect(row["outcome"]).to eq("nothing")
      expect(events).to eq(before)
    end

    it "leaves a step whose files are missing held, and a second pass leaves the hold alone" do
      row = only_row(sweep.call)
      expect(row["outcome"]).to eq("evaluated")
      expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_incomplete")
      before = events
      held = store.find("wr_1")["reason"]

      second = only_row(sweep.call)

      expect(second).to include("outcome" => "nothing", "reason" => "held")
      expect(events).to eq(before)
      expect(store.find("wr_1")["reason"]).to eq(held)
    end

    it "treats a file that is there but empty as the same kind of hold (details.invalid), not a failure" do
      artifact(content: "")
      sweep.call

      reason = store.find("wr_1")["reason"]
      expect(reason).to include("code" => "turn_ended_incomplete")
      expect(reason["details"]["invalid"]).to eq([{"file" => File.join(worktree, ".workflow", "wr_1", "out.md"), "rule" => "empty"}])
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "held")
      expect(store.find("wr_1")["steps"]["build"]["state"]).to eq("running")
    end

    it "does nothing while the pane has been idle for less than the stall" do
      pane_shows("idle", idle_seconds: 300)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "idle")
      expect(types).not_to include("step_stalled")
    end

    it "does nothing when the definition sets no stall" do
      FileUtils.rm_rf(runs_dir)
      ids.replace(%w[wr_1 wr_2])
      now[0] = Time.utc(2026, 10, 4, 12, 0, 0)
      begin_run(flow(stall: nil))
      advance(1500)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "idle")
      expect(types).not_to include("step_stalled")
    end

    it "does nothing while the agent is working" do
      pane_shows("working", idle_seconds: 2)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    end

    it "does not decide a step the pane asks a person about" do
      pane_shows("waiting", idle_seconds: 2000)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "prompt")
    end

    it "reports and does not change anything with dry_run" do
      artifact
      before = [store.find("wr_1"), events]

      row = only_row(sweep.call(dry_run: true))

      expect(row).to include("outcome" => "dry_run", "action" => "evaluate", "cause" => "idle_turn_over")
      expect([store.find("wr_1"), events]).to eq(before)
    end

    it "leaves the run alone when the caller is its own agent" do
      artifact

      row = only_row(sweep.call(allow: ->(_run) { "this process runs under pane %5" }))

      expect(row).to include("outcome" => "nothing", "reason" => "refused", "message" => "this process runs under pane %5")
      expect(types).not_to include("step_stalled")
    end

    it "does not decide a step again that a resume got to first (the run moved on between the read and the change)" do
      panes.on_row = -> do
        panes.on_row = nil
        engine.resume("wr_1", from: "build")
      end
      artifact

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "moved_on")
      expect(types).not_to include("step_stalled")
      expect(store.find("wr_1")["steps"]["build"]["attempts"].size).to eq(2)
    end

    it "skips a run another process is changing, and looks at it on the next pass" do
      lock = nil
      panes.on_row = -> do
        lock = File.open(File.join(runs_dir, "wr_1.lock"), File::RDWR | File::CREAT)
        lock.flock(File::LOCK_EX)
        panes.on_row = nil
      end
      artifact

      busy = only_row(sweep.call)
      lock.close
      again = only_row(sweep.call)

      expect(busy).to include("outcome" => "nothing", "reason" => "busy")
      expect(again["outcome"]).to eq("evaluated")
    end
  end

  describe "a step with a live park, or a check running" do
    before do
      begin_run
      advance(1500)
      pane_shows("idle", idle_seconds: 1500)
    end

    it "leaves a live park alone" do
      engine.park("wr_1", turn_over: {"step" => "build", "attempt" => 1})
      before = [store.find("wr_1"), events]

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "parked")
      expect([store.find("wr_1"), events]).to eq(before)
    end

    it "leaves a step that is checking alone" do
      definition = Workspace::WorkflowDefinition.parse("stall: 20m\nsteps:\n  build:\n    prompt: B\n    status: {run: \"true\"}\n", id: "chk", source: "global", path: "/d/chk.yml")
      engine.cancel("wr_1")
      FileUtils.mkdir_p(File.join(runs_dir, ".."))
      ids.replace(%w[wr_2])
      checking = Workspace::WorkflowEngine.new(store: store, resources: resources, composer: composer, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
        commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, clock: -> { now.first })
      checking.start(definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      store.update("wr_2") { |run| run["steps"]["build"]["state"] = "checking" }
      advance(1500)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "checking")
    end

    it "leaves a run waiting at a gate alone" do
      definition = Workspace::WorkflowDefinition.parse("stall: 20m\nsteps:\n  build:\n    prompt: B\n    gate: approve\n", id: "g", source: "global", path: "/d/g.yml")
      engine.cancel("wr_1")
      ids.replace(%w[wr_2])
      engine.start(definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      engine.turn_ended("wr_2", pane: "%5")

      expect(only_row(sweep.call)).to include("run_id" => "wr_2", "outcome" => "nothing", "reason" => "not_running")
    end
  end

  describe "a pane or agent that is gone" do
    before do
      begin_run
      advance(300)
    end

    it "records the stall once and keeps the run as it is, however often it runs" do
      panes.stale << "wr_1"
      before = store.find("wr_1")

      first = only_row(sweep.call)
      second = only_row(sweep.call)

      expect(first).to include("outcome" => "recorded", "cause" => "pane_gone", "action" => "record")
      expect(second).to include("outcome" => "nothing", "reason" => "already_recorded", "cause" => "pane_gone")
      expect(events.count { |each| each["type"] == "step_stalled" }).to eq(1)
      expect(events.find { |each| each["type"] == "step_stalled" }).to include("step" => "build", "attempt" => 1, "cause" => "pane_gone", "pane" => "%5")
      expect(store.find("wr_1").except("sweep")).to eq(before)
      expect(store.find("wr_1")["state"]).to eq("running")
    end

    it "records an agent that has left its pane as a shell" do
      pane_shows("idle", idle_seconds: 120, kind: "shell")

      expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => "agent_gone")
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_recorded")
      expect(events.count { |each| each["type"] == "step_stalled" }).to eq(1)
    end

    it "records again for a new attempt, since the marks belong to one attempt" do
      pane_shows("idle", idle_seconds: 120, kind: "shell")
      sweep.call
      engine.resume("wr_1", from: "build")

      expect(only_row(sweep.call)).to include("outcome" => "recorded", "attempt" => 2)
    end

    it "reports it with dry_run and records nothing" do
      panes.stale << "wr_1"

      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "action" => "record", "cause" => "pane_gone")
      expect(types).not_to include("step_stalled")
    end
  end

  describe "agentd not running" do
    before do
      begin_run
      advance(1500)
      panes.daemon = false
    end

    it "starts the daemon and leaves the pane to the next pass, since a new daemon's reading is not evidence" do
      pane_shows("idle", idle_seconds: 1500)
      artifact

      first = only_row(sweep.call)

      expect(panes.respawns).to eq(["app.worktree-x"])
      expect(first).to include("outcome" => "respawned")
      expect(events.select { |each| each["type"] == "step_stalled" }.map { |each| each["cause"] }).to eq(%w[daemon_down])
      expect(events.find { |each| each["type"] == "step_recovered" }).to include("action" => "daemon_respawned")
      expect(store.find("wr_1")["current"]).to eq("build")

      expect(only_row(sweep.call)).to include("outcome" => "evaluated")
      expect(events.select { |each| each["type"] == "step_stalled" }.map { |each| each["cause"] }).to eq(%w[daemon_down idle_turn_over])
    end

    it "writes nothing and starts nothing on a second pass after a successful start" do
      pane_shows("working", idle_seconds: 1)
      sweep.call
      before = events

      sweep.call

      expect(events).to eq(before)
      expect(panes.respawns.size).to eq(1)
    end

    it "does not act on a pane in the pass that started the daemon, even past an on_timeout: fail timeout" do
      store.update("wr_1") { |run| run["definition"]["steps"][0].merge!("timeout" => 60, "on_timeout" => "fail") }
      pane_shows("working", idle_seconds: 0)

      expect(only_row(sweep.call)).to include("outcome" => "respawned")
      expect(pressed).to be_empty
      expect(store.find("wr_1")["steps"]["build"]["attempts"].size).to eq(1)
    end

    it "writes the recovery when a start succeeds after an earlier pass failed, once" do
      panes.respawn_result = {ok: false, detail: "later"}
      sweep.call
      panes.respawn_result = {ok: true}
      sweep.call
      sweep.call

      expect(events.count { |each| each["type"] == "step_stalled" }).to eq(1)
      expect(events.count { |each| each["type"] == "step_recovered" }).to eq(1)
      expect(panes.respawns.size).to eq(2)
    end

    it "starts no daemon for a workspace with no tmux session, and says so without failing" do
      store.update("wr_1") { |run| run["steps"]["build"]["state"] = "checking" }
      panes.session = false

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "workspace_stopped")
      expect(panes.respawns).to be_empty
      expect(types).not_to include("step_stalled")
    end

    it "does not start a daemon that is running" do
      panes.daemon = true
      pane_shows("working", idle_seconds: 1)

      sweep.call

      expect(panes.respawns).to be_empty
    end

    it "starts the daemon once for a workspace with several runs" do
      pane_shows("working", idle_seconds: 1)
      second = Dir.mktmpdir("wf-sweep2")
      allow(lock_namespace).to receive(:resolve).with(cwd: second).and_return(key: "ns", display: "app", dir: lock_dir)
      engine.start(definition: flow, workspace: "app.worktree-x", worktree: second, inputs: {}, pane: "%6")

      sweep.call

      expect(panes.respawns.size).to eq(1)
      %w[wr_1 wr_2].each do |id|
        expect(events(id).select { |each| each["type"] == "step_recovered" }.map { |each| each["action"] }).to eq(["daemon_respawned"])
      end
    ensure
      FileUtils.rm_rf(second) if second
    end

    it "reports a daemon that can't be started, records it once and tries again on the next pass" do
      panes.respawn_result = {ok: false, detail: "no tmux session"}

      first = only_row(sweep.call)
      second = only_row(sweep.call)

      expect(first).to include("outcome" => "failed", "reason" => "daemon_not_started", "cause" => "daemon_down")
      expect(first["message"]).to include("no tmux session")
      expect(second["outcome"]).to eq("failed")
      expect(panes.respawns.size).to eq(2)
      expect(events.count { |each| each["type"] == "step_stalled" }).to eq(1)
      expect(types).not_to include("step_recovered")
    end

    it "only reports with dry_run" do
      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "action" => "respawn_daemon")
      expect(panes.respawns).to be_empty
    end

    it "starts a daemon for a run that waits for a lock, too" do
      store.update("wr_1") do |run|
        run["state"] = "waiting"
        run["steps"]["build"]["state"] = "waiting"
        run["reason"] = {"code" => "waiting_lock", "since" => "2026-10-04T12:00:00Z", "details" => {}}
      end

      expect(only_row(sweep.call)).to include("outcome" => "respawned")
    end
  end

  describe "a step past its timeout" do
    it "does nothing for warn, as before" do
      begin_run
      advance(3700)
      pane_shows("working", idle_seconds: 2)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "timed_out")
      expect(pressed).to be_empty
      expect(types).not_to include("step_stalled")
    end

    it "does nothing for a definition stored before on_timeout and stall existed" do
      begin_run
      store.update("wr_1") do |run|
        run["definition"].delete("stall")
        run["definition"]["steps"].each { |step| step.delete("on_timeout") }
      end
      advance(3700)
      pane_shows("working", idle_seconds: 2)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "timed_out")
      pane_shows("idle", idle_seconds: 3000)
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "idle")
    end

    it "interrupts the agent once for the attempt" do
      engine.start(definition: flow(on_timeout: "interrupt"), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      advance(3700)
      pane_shows("working", idle_seconds: 2)

      first = only_row(sweep.call)
      second = only_row(sweep.call)

      expect(first).to include("outcome" => "interrupted", "action" => "interrupt", "cause" => "timed_out")
      expect(pressed).to eq([["app.worktree-x", "%5", Workspace::AgentProvider.find("claude").interrupt_keys]])
      expect(second).to include("outcome" => "nothing", "reason" => "already_interrupted")
      expect(events("wr_1").map { |each| each["type"] }.last(2)).to eq(%w[step_stalled step_recovered])
      expect(events("wr_1").last).to include("action" => "interrupted")
      expect(events("wr_1").count { |each| each["type"] == "step_stalled" }).to eq(1)
    end

    it "decides the step on a later pass once the interrupted agent is idle, with no stall configured" do
      engine.start(definition: flow(stall: nil, on_timeout: "interrupt"), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      advance(3700)
      pane_shows("working", idle_seconds: 2)
      sweep.call
      File.write(File.join(worktree, ".workflow", "wr_1", "out.md"), "done\n").tap { FileUtils.touch(File.join(worktree, ".workflow", "wr_1", "out.md"), mtime: now.first) }
      pane_shows("idle", idle_seconds: 5)

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "evaluated", "cause" => "interrupted")
      expect(store.find("wr_1")["current"]).to eq("verify")
    end

    it "releases the claim when the keys can't be pressed, so the next pass tries again" do
      engine.start(definition: flow(on_timeout: "interrupt"), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      advance(3700)
      pane_shows("working", idle_seconds: 2)
      interrupt_error[0] = Workspace::Error.new("no such pane", code: "no_such_pane")

      failed = only_row(sweep.call)
      interrupt_error[0] = nil
      retried = only_row(sweep.call)

      expect(failed).to include("outcome" => "failed", "reason" => "interrupt_failed")
      expect(retried["outcome"]).to eq("interrupted")
      expect(events("wr_1").count { |each| each["type"] == "step_stalled" }).to eq(1)
    end

    it "fails the step after pressing the interrupt keys, and the failure follows on_fail" do
      engine.start(definition: looping, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")
      advance(3700)
      pane_shows("working", idle_seconds: 2)

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "timed_out", "action" => "fail", "cause" => "timed_out")
      expect(pressed.size).to eq(1)
      run = store.find("wr_1")
      expect(run["steps"]["build"]["attempts"].map { |each| [each["n"], each["outcome"], each["code"]] }).to eq([[1, "failed", "step_timed_out"]])
      expect(run["current"]).to eq("plan")
      expect(run["steps"]["plan"]["attempts"].size).to eq(2)
      expect(run["loops"]).to eq("build->plan" => 1)
      expect(events("wr_1").map { |each| each["type"] }).to include("step_stalled", "step_recovered", "step_failed", "step_looped")
    end

    it "stops the run for a person when on_fail has nothing left, naming step_timed_out" do
      engine.start(definition: flow(on_timeout: "fail"), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      advance(3700)
      pane_shows("working", idle_seconds: 2)

      sweep.call
      second = only_row(sweep.call)

      run = store.find("wr_1")
      expect(run["reason"]).to include("code" => "failed_check")
      expect(run["reason"]["details"]).to include("cause" => "timeout", "code" => "step_timed_out", "code_source" => "engine", "timeout" => 3600)
      expect(second).to include("outcome" => "nothing", "reason" => "not_running")
      expect(events("wr_1").count { |each| each["type"] == "step_stalled" }).to eq(1)
    end

    it "decides an idle agent past its timeout rather than failing finished work" do
      engine.start(definition: flow(stall: nil, on_timeout: "fail"), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      FileUtils.mkdir_p(File.join(worktree, ".workflow", "wr_1"))
      advance(3700)
      File.write(File.join(worktree, ".workflow", "wr_1", "out.md"), "done\n")
      pane_shows("idle", idle_seconds: 600)

      expect(only_row(sweep.call)).to include("outcome" => "evaluated")
      expect(store.find("wr_1")["current"]).to eq("verify")
    end

    it "does nothing for a step with no timeout" do
      engine.start(definition: flow(timeout: nil), workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      advance(90_000)
      pane_shows("working", idle_seconds: 2)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    end
  end

  def flow_with(on_timeout:, **options)
    ids.replace(%w[wr_1 wr_2])
    begin_run(flow(on_timeout: on_timeout, **options))
  end

  describe "the interrupt, claimed under the lock, pressed outside it and confirmed under it" do
    before do
      flow_with(on_timeout: "interrupt")
      advance(3700)
      pane_shows("working", idle_seconds: 2)
    end

    it "presses nothing when the run moved on before the claim" do
      panes.on_row = -> do
        panes.on_row = nil
        engine.resume("wr_1", from: "build")
      end

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "moved_on")
      expect(pressed).to be_empty
      expect(store.find("wr_1")["sweep"]).to be_nil
    end

    it "presses nothing and gives the claim back when the pane changed after the claim" do
      calls = 0
      panes.on_row = -> do
        calls += 1
        pane_shows("idle", idle_seconds: 9) if calls == 2
      end

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "pane_changed")
      expect(pressed).to be_empty
      expect(store.find("wr_1")["sweep"]).not_to have_key("interrupt")
    end

    it "presses nothing when the pane is no longer this run's" do
      calls = 0
      panes.on_row = -> do
        calls += 1
        panes.unbind("wr_1") if calls == 2
      end

      expect(only_row(sweep.call)).to include("reason" => "pane_changed")
      expect(pressed).to be_empty
    end

    it "writes the recovery and releases the claim even when another process holds the run while the keys are pressed" do
      holder = nil
      interrupt = interrupter
      allow(self).to receive(:interrupter).and_return(lambda do |workspace, pane, keys|
        holder = Thread.new { store.update("wr_1") { sleep 0.3 } }
        sleep 0.1
        interrupt.call(workspace, pane, keys)
      end)

      expect(only_row(sweep.call)).to include("outcome" => "interrupted")
      holder.join
      expect(events.last).to include("type" => "step_recovered", "action" => "interrupted")
      expect(store.find("wr_1")["sweep"]["interrupt"]["state"]).to eq("sent")
    end

    it "leaves a claim another process took over alone when a slow process reports back" do
      claim, at = engine.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 3700, timeout: 3600)
      expect(claim).to eq(:claimed)
      store.update("wr_1") { |run| run["sweep"]["interrupt"] = {"state" => "pending", "at" => "2026-10-04T13:02:00Z"} }

      expect(engine.interrupt_sent("wr_1", step: "build", attempt: 1, claim_at: at, sent: false)).to eq(:taken_over)
      expect(engine.interrupt_sent("wr_1", step: "build", attempt: 1, claim_at: at, sent: true)).to eq(:taken_over)
      expect(store.find("wr_1")["sweep"]["interrupt"]).to eq("state" => "pending", "at" => "2026-10-04T13:02:00Z")
      expect(types).not_to include("step_recovered")
    end

    it "takes over a pending claim older than a minute and leaves a fresh one" do
      store.update("wr_1") do |run|
        run["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {}, "recovered" => {}, "interrupt" => {"state" => "pending", "at" => (now.first - 20).utc.iso8601}}
      end
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "already_interrupted")

      store.update("wr_1") { |run| run["sweep"]["interrupt"]["at"] = (now.first - 90).utc.iso8601 }
      expect(only_row(sweep.call)).to include("outcome" => "interrupted")
      expect(pressed.size).to eq(1)
    end

    it "does not decide the step on a pane idle for less than the floor, nor on a pane that changed" do
      sweep.call
      pane_shows("idle", idle_seconds: 2)
      expect(only_row(sweep.call)).to include("outcome" => "nothing")
      expect(types).not_to include("step_passed")

      pane_shows("idle", idle_seconds: 30)
      calls = 0
      panes.on_row = -> do
        calls += 1
        pane_shows("working", idle_seconds: 1) if calls == 2
      end
      expect(only_row(sweep.call)).to include("reason" => "pane_changed")
      expect(types).not_to include("step_passed")
    end
  end

  describe "on_timeout: fail" do
    def failing(produces: true)
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "loop", source: "global", path: "/defs/loop.yml")
        steps:
          plan:
            prompt: Plan it.
            context: continue
          build:
            prompt: Build it.
            context: continue
            #{"produces: [out.md]" if produces}
            timeout: 1h
            on_timeout: fail
            on_fail: {goto: plan, max: 2, context: continue}
      YAML
    end

    def to_build
      begin_run(failing)
      engine.turn_ended("wr_1", pane: "%5")
      advance(3700)
    end

    it "fails a step that an idle agent left incomplete, with step_timed_out, and follows on_fail" do
      to_build
      pane_shows("idle", idle_seconds: 600)

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "timed_out", "cause" => "idle_turn_over")
      expect(store.find("wr_1")["steps"]["build"]["attempts"].first).to include("outcome" => "failed", "code" => "step_timed_out")
      expect(store.find("wr_1")["current"]).to eq("plan")
    end

    it "fails a step already held on turn_ended_incomplete, T3's invalid file included" do
      to_build
      artifact_path = File.join(worktree, ".workflow", "wr_1", "out.md")
      File.write(artifact_path, "")
      engine.resume("wr_1", turn_over: {"step" => "build", "attempt" => 1})
      expect(store.find("wr_1")["reason"]["details"]["invalid"]).not_to be_nil

      expect(only_row(sweep.call)).to include("outcome" => "timed_out")
      expect(store.find("wr_1")["steps"]["build"]["attempts"].first["code"]).to eq("step_timed_out")
    end

    it "leaves a turn_ended_background hold alone" do
      to_build
      store.update("wr_1") { |run| run["reason"] = {"code" => "turn_ended_background", "since" => now.first.utc.iso8601, "seen_at" => now.first.utc.iso8601, "details" => {}} }

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "held")
    end

    it "leaves a held step alone under interrupt and warn" do
      %w[interrupt warn].each do |action|
        FileUtils.rm_rf(runs_dir)
        FileUtils.rm_rf(archive_dir)
        ids.replace(%w[wr_1])
        now[0] = Time.utc(2026, 10, 4, 12, 0, 0)
        begin_run(flow(on_timeout: action))
        advance(3700)
        pane_shows("idle", idle_seconds: 600)
        engine.resume("wr_1", turn_over: {"step" => "build", "attempt" => 1})

        expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "held")
        engine.cancel("wr_1")
      end
    end

    it "acts on the new attempt after a pass back, with the old marks not suppressing it, and repeats nothing" do
      to_build
      pane_shows("working", idle_seconds: 1)
      sweep.call
      expect(store.find("wr_1")["current"]).to eq("plan")
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["current"]).to eq("build")
      advance(3700)
      pane_shows("working", idle_seconds: 1)

      second = only_row(sweep.call)
      third = only_row(sweep.call)

      expect(second).to include("outcome" => "timed_out", "attempt" => 2)
      expect(events.count { |each| each["type"] == "step_stalled" && each["attempt"] == 2 }).to eq(1)
      expect(events.count { |each| each["type"] == "step_stalled" }).to eq(2)
      expect(third["outcome"]).to eq("nothing")
      expect(pressed.size).to eq(2)
    end

    it "carries on to fail after a press that landed but whose failure did not, instead of waiting forever" do
      to_build
      pane_shows("working", idle_seconds: 1)
      store.update("wr_1") do |run|
        run["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {}, "recovered" => {}, "interrupt" => {"state" => "sent", "at" => now.first.utc.iso8601}}
      end

      expect(only_row(sweep.call)).to include("outcome" => "timed_out")
      expect(pressed).to be_empty
    end
  end

  describe "a step whose line was not delivered" do
    let(:busy) { {ok: false, code: "pane_busy", message: "pane %5 is busy"} }

    before do
      panes.kick_result = busy
      begin_run
      pane_shows("idle", idle_seconds: 600)
    end

    def attempts = store.find("wr_1")["steps"]["build"]["attempts"]

    it "waits out the backoff, then types the line again and marks the failed attempt" do
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "backoff")
      expect(panes.kicks.size).to eq(1)

      advance(61)
      panes.kick_result = {ok: true}
      row = only_row(sweep.call)

      expect(row).to include("outcome" => "redelivered", "cause" => "undelivered", "action" => "redeliver")
      expect(panes.kicks.size).to eq(2)
      expect(attempts.map { |each| each["redelivered"] }).to eq([true, nil])
      expect(store.find("wr_1")).to include("state" => "running", "reason" => nil)
      expect(events.find { |each| each["type"] == "step_stalled" }).to include("cause" => "undelivered", "retry" => 1, "of" => 3, "code" => "pane_busy")
      expect(events.find { |each| each["type"] == "step_recovered" }).to include("action" => "redelivered")
    end

    it "backs off longer after each failed retry and stops after the definition's limit" do
      [60, 300, 900].each_with_index do |wait, index|
        advance(wait - 1)
        expect(only_row(sweep.call)).to include("reason" => "backoff")
        advance(1)
        expect(only_row(sweep.call)).to include("reason" => "not_delivered", "action" => "redeliver")
        expect(attempts.size).to eq(index + 2)
      end

      advance(10_000)
      first = only_row(sweep.call)
      expect(first).to include("outcome" => "recorded", "cause" => "redelivery_exhausted")
      expect(only_row(sweep.call)).to include("reason" => "already_recorded")
      expect(panes.kicks.size).to eq(4)
      expect(store.find("wr_1")["reason"]).to include("code" => "waiting_you")
    end

    it "does not count retried attempts against max_attempts" do
      engine.cancel("wr_1")
      ids.replace(%w[wr_2])
      panes.kick_result = busy
      definition = Workspace::WorkflowDefinition.parse(<<~YAML, id: "tight", source: "global", path: "/defs/tight.yml")
        max_attempts: 3
        steps:
          plan:
            prompt: Plan it.
            context: continue
          build:
            prompt: Build it.
            context: continue
            on_fail: {goto: plan, max: 1, context: continue}
      YAML
      begin_run(definition)
      advance(61)
      panes.kick_result = {ok: true}
      sweep.call

      expect(store.find("wr_2")["steps"]["plan"]["attempts"].map { |each| each["redelivered"] }).to eq([true, nil])
      engine.turn_ended("wr_2", pane: "%5")
      engine.report("wr_2", status: "fail")
      engine.turn_ended("wr_2", pane: "%5")

      expect(store.find("wr_2")).to include("current" => "plan", "state" => "running")
      expect(store.find("wr_2")["steps"]["plan"]["attempts"].size).to eq(3)
    end

    it "leaves a pane that is not idle alone" do
      advance(61)
      pane_shows("working")

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "pane_busy")
      expect(panes.kicks.size).to eq(1)
    end

    it "leaves a pane that has not been idle for the floor alone" do
      advance(61)
      pane_shows("idle", idle_seconds: 1)

      expect(only_row(sweep.call)).to include("reason" => "pane_busy")
      expect(panes.kicks.size).to eq(1)
    end

    it "starts a daemon that is not running and retries on the next pass" do
      advance(61)
      panes.daemon = false

      expect(only_row(sweep.call)).to include("outcome" => "respawned")
      expect(panes.kicks.size).to eq(1)

      panes.kick_result = {ok: true}
      expect(only_row(sweep.call)).to include("outcome" => "redelivered")
    end

    it "changes nothing under --dry-run" do
      advance(61)

      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "action" => "redeliver")
      expect(panes.kicks.size).to eq(1)
      expect(attempts.size).to eq(1)
    end

    it "leaves the run alone when allow refuses" do
      advance(61)

      expect(only_row(sweep.call(allow: ->(_run) { "own pane" }))).to include("reason" => "refused")
      expect(panes.kicks.size).to eq(1)
    end

    it "does not retry when a resume got there first" do
      advance(61)
      panes.kick_result = {ok: true}
      engine.resume("wr_1")

      expect(engine.redeliver("wr_1", step: "build", attempt: 1)).to eq(:moved_on)
      expect(attempts.size).to eq(2)
    end

    it "does not retry beside a live park" do
      advance(61)
      engine.park("wr_1")

      expect(only_row(sweep.call)).to include("reason" => "parked")
      expect(panes.kicks.size).to eq(1)
    end

    it "does not retry a gone pane, a daemon's unconfirmed prompt, or a code a retry cannot help" do
      advance(61)
      %w[pane_gone run_unbound error not_delivered connection_failed unreadable_reply].each do |code|
        store.update("wr_1") { |stored| stored["reason"]["details"]["error"] = code }
        run = store.find("wr_1")
        expect(Workspace::WorkflowEngine.redelivery(run, now.first)).to be_nil
      end
      store.update("wr_1") { |stored| stored["reason"]["details"].merge!("error" => "pane_busy", "reason" => "prompt_unconfirmed") }
      run = store.find("wr_1")
      expect(Workspace::WorkflowEngine.redelivery(run, now.first)).to be_nil
    end

    it "retries a no_daemon failure, which is raised before anything is sent" do
      store.update("wr_1") { |stored| stored["reason"]["details"]["error"] = "no_daemon" }
      run = store.find("wr_1")
      advance(61)

      expect(Workspace::WorkflowEngine.redelivery(run, now.first)).to include(state: :due)
    end

    it "reports a retry whose line is refused again as not delivered, with no step_recovered" do
      advance(61)
      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "not_delivered", "action" => "redeliver")
      expect(types).not_to include("step_recovered")
      expect(attempts.map { |each| each["redelivery"] }).to eq([nil, 1])
      expect(store.find("wr_1")["reason"]["details"]).to include("error" => "pane_busy")
    end

    it "counts again from zero after a person's resume whose line is also not delivered" do
      [60, 300, 900].each do |wait|
        advance(wait)
        expect(only_row(sweep.call)).to include("reason" => "not_delivered")
      end
      advance(10_000)
      expect(only_row(sweep.call)).to include("cause" => "redelivery_exhausted")

      engine.resume("wr_1")
      expect(store.find("wr_1")["reason"]["code"]).to eq("waiting_you")
      expect(attempts.last["redelivery"]).to be_nil
      advance(59)
      expect(only_row(sweep.call)).to include("reason" => "backoff")
      advance(2)
      expect(only_row(sweep.call)).to include("reason" => "not_delivered", "action" => "redeliver")
    end

    context "when the retry lands in a lock wait" do
      let(:lock_busy) { [false] }
      let(:locked) do
        Workspace::WorkflowDefinition.parse(<<~YAML, id: "locked", source: "global", path: "/defs/locked.yml")
          steps:
            build:
              prompt: Build it.
              context: continue
              uses: [test-db]
        YAML
      end

      before do
        engine.cancel("wr_1")
        ids.replace(%w[wr_2])
        allow(resources).to receive(:acquire).and_wrap_original do |original, **args|
          next original.call(**args) unless lock_busy.first
          {status: :ok, released: [], acquired: [], handed_over: [], waiting: {name: "test-db", position: 1, total: 1, holder: {}}}
        end
        begin_run(locked)
      end

      def attempts2 = store.find("wr_2")["steps"]["build"]["attempts"]

      it "reports waiting_lock without step_recovered, keeps the count for the ticked attempt, and stops at the limit" do
        [60, 300, 900].each_with_index do |wait, index|
          advance(wait)
          lock_busy[0] = true
          expect(only_row(sweep.call)).to include("reason" => "waiting_lock", "cause" => "undelivered")
          expect(types("wr_2")).not_to include("step_recovered")
          expect(store.find("wr_2")["steps"]["build"]["redelivery_pending"]).to eq(index + 1)

          lock_busy[0] = false
          engine.tick("wr_2")
          expect(attempts2.last["redelivery"]).to eq(index + 1)
          expect(store.find("wr_2")["steps"]["build"]).not_to have_key("redelivery_pending")
        end

        advance(10_000)
        expect(only_row(sweep.call)).to include("cause" => "redelivery_exhausted")
        expect(panes.kicks.size).to eq(5)
      end

      it "starts the count again after a person's resume during the wait" do
        advance(60)
        lock_busy[0] = true
        sweep.call
        engine.resume("wr_2")

        expect(store.find("wr_2")["steps"]["build"]).not_to have_key("redelivery_pending")
        lock_busy[0] = false
        engine.tick("wr_2")
        expect(attempts2.last["redelivery"]).to be_nil
      end
    end

    it "does not retry a connection_failed raised after the request was sent" do
      engine.cancel("wr_1")
      ids.replace(%w[wr_2])
      panes.kick_result = {ok: false, code: "connection_failed", message: "no reply"}
      begin_run
      advance(10_000)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "not_running")
      expect(panes.kicks.size).to eq(2)
    end

    it "records a gone pane and retries nothing" do
      advance(61)
      panes.stale << "wr_1"

      expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => "pane_gone")
      expect(only_row(sweep.call)).to include("reason" => "already_recorded")
      expect(panes.kicks.size).to eq(1)
    end

    it "does nothing for a run stored with redeliver: 0" do
      advance(61)
      store.update("wr_1") { |stored| stored["definition"]["redeliver"] = 0 }

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "not_running")
      expect(panes.kicks.size).to eq(1)
    end

    it "does nothing for a run stored without the key" do
      advance(61)
      store.update("wr_1") { |stored| stored["definition"].delete("redeliver") }

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "not_running")
      expect(panes.kicks.size).to eq(1)
    end
  end

  describe "a resume landing between the read and the change" do
    before do
      flow_with(on_timeout: "fail")
      advance(3700)
    end

    it "keeps time_out from failing the new attempt" do
      attempt = 1
      engine.resume("wr_1", from: "build")

      expect(engine.time_out("wr_1", step: "build", attempt: attempt, elapsed: 4000, timeout: 3600)).to eq(:moved_on)
      expect(store.find("wr_1")["steps"]["build"]["state"]).to eq("running")
    end

    it "keeps claim_interrupt from claiming the new attempt" do
      engine.resume("wr_1", from: "build")

      expect(engine.claim_interrupt("wr_1", step: "build", attempt: 1, elapsed: 4000, timeout: 3600)).to eq(:moved_on)
    end

    it "keeps note_stall from recording against the new attempt" do
      engine.resume("wr_1", from: "build")

      expect(engine.note_stall("wr_1", step: "build", attempt: 1, cause: "pane_gone")).to eq(:moved_on)
      expect(types).not_to include("step_stalled")
    end

    it "keeps recover from deciding a step a plain resume already decided" do
      pane_shows("idle", idle_seconds: 600)
      panes.on_row = -> do
        panes.on_row = nil
        engine.resume("wr_1", turn_over: {"step" => "build", "attempt" => 1})
      end

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "moved_on")
      expect(types).not_to include("step_stalled")
    end
  end

  describe "runs that are not shaped as the sweep expects" do
    before { begin_run }

    it "reads a run stored before the sweep, with no sweep key and no delivery mark" do
      store.update("wr_1") do |run|
        run.delete("sweep")
        run["steps"]["build"]["attempts"].each { |each| each.delete("delivery") }
      end
      pane_shows("working", idle_seconds: 1)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "healthy")
    end

    it "reports a running step with no attempt, without failing" do
      store.update("wr_1") { |run| run["steps"]["build"]["attempts"] = [] }
      pane_shows("working", idle_seconds: 1)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "no_attempt")
    end

    it "reports an unreadable run file as a failed row" do
      File.write(File.join(runs_dir, "wr_bad.json"), "{")
      pane_shows("working", idle_seconds: 1)

      rows = sweep.call

      expect(rows.map { |each| each["outcome"] }).to contain_exactly("nothing", "failed")
      expect(rows.find { |each| each["outcome"] == "failed" }).to include("reason" => "unreadable_run", "run_id" => "wr_bad")
    end

    it "reports a program that is missing as tool_unavailable, naming it" do
      panes.on_row = -> { raise Errno::ENOENT, "tmux" }

      expect(only_row(sweep.call)).to include("outcome" => "failed", "reason" => "tool_unavailable")
      expect(only_row(sweep.call)["message"]).to include("tmux")
    end

    it "lets a real bug raise instead of calling the run unreadable" do
      panes.on_row = -> { raise NoMethodError, "undefined method" }

      expect { sweep.call }.to raise_error(NoMethodError)
    end
  end

  describe "scope" do
    it "looks at one run, one workspace, or every run going" do
      begin_run
      other = Dir.mktmpdir("wf-sweep3")
      allow(lock_namespace).to receive(:resolve).with(cwd: other).and_return(key: "ns", display: "app", dir: lock_dir)
      engine.start(definition: flow, workspace: "other", worktree: other, inputs: {}, pane: "%6")
      pane_shows("working", idle_seconds: 1)

      expect(sweep.call.map { |each| each["run_id"] }).to contain_exactly("wr_1", "wr_2")
      expect(sweep.call(workspace: "other").map { |each| each["run_id"] }).to eq(["wr_2"])
      expect(sweep.call(run: "wr_1").map { |each| each["run_id"] }).to eq(["wr_1"])
      expect { sweep.call(run: "wr_9") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_run") }
    ensure
      FileUtils.rm_rf(other) if other
    end

    it "reports a finished run as finished" do
      begin_run
      engine.cancel("wr_1")

      expect(only_row(sweep.call(run: "wr_1"))).to include("outcome" => "nothing", "reason" => "finished")
    end
  end

  describe "a retry whose wait is over while the token budget is used" do
    let(:budgeted) do
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "back", source: "global", path: "/defs/back.yml")
        budget: {tokens: 1000}
        steps:
          plan:
            prompt: Plan it.
            context: continue
          build:
            prompt: Build it.
            context: continue
            on_fail: {goto: plan, max: 2, context: continue, backoff: 5m}
      YAML
    end

    before do
      begin_run(budgeted)
      engine.turn_ended("wr_1", pane: "%5")
      engine.report("wr_1", status: "fail", summary: "no")
      engine.turn_ended("wr_1", pane: "%5")
      store.update("wr_1") { |run| run["steps"]["build"]["attempts"].first["usage"] = {"input_tokens" => 5000} }
      advance(300)
    end

    it "says the budget held the retry, as no failure, and the next pass says so too" do
      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "budget_spent", "cause" => "retry_backoff", "action" => "retry", "step" => "build")
      expect(row["message"]).to include("token budget is used", "--extra-tokens")
      expect(store.find("wr_1")).to include("state" => "waiting").and(satisfy { |run| run["reason"]["code"] == "budget_spent" })
      expect(types).not_to include("step_stalled")
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "budget_spent")
      expect(types.count("budget_spent")).to eq(1)
    end
  end

  describe "a failed step waiting out an on_fail backoff" do
    let(:backing_off) do
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "back", source: "global", path: "/defs/back.yml")
        stall: 1m
        steps:
          plan:
            prompt: Plan it.
            context: continue
          build:
            prompt: Build it.
            context: continue
            timeout: 1m
            on_timeout: fail
            on_fail: {goto: plan, max: 2, context: continue, backoff: 5m}
      YAML
    end

    before do
      begin_run(backing_off)
      engine.turn_ended("wr_1", pane: "%5")
      engine.report("wr_1", status: "fail", summary: "no")
      engine.turn_ended("wr_1", pane: "%5")
    end

    it "is not stalled: nothing is recorded or acted on before the time, whatever the idle and timeout rules say" do
      advance(299)
      pane_shows("idle", idle_seconds: 5000)

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "backoff", "cause" => "retry_backoff", "step" => "build")
      expect(row["message"]).to include("starts again at 2026-10-04T12:05:00Z", "in 1 seconds")
      expect(types).not_to include("step_stalled")
      expect(store.find("wr_1")).to include("current" => "build", "state" => "waiting")
    end

    it "starts the retry once the time has passed, with no daemon needed to decide, and a second pass does nothing" do
      advance(300)
      pane_shows("idle")

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "retried", "cause" => "retry_backoff", "action" => "retry", "step" => "build")
      expect(store.find("wr_1")).to include("current" => "plan", "state" => "running", "reason" => nil)
      expect(store.find("wr_1")).not_to have_key("backoff")
      expect(types.last(3)).to eq(%w[step_retry_started step_dispatching step_dispatched])
      expect(only_row(sweep.call)["reason"]).not_to eq("backoff")
    end

    it "reports what it would do under --dry-run and changes nothing" do
      advance(300)
      before = store.find("wr_1")

      row = only_row(sweep.call(dry_run: true))

      expect(row).to include("outcome" => "dry_run", "action" => "retry", "cause" => "retry_backoff")
      expect(store.find("wr_1")).to eq(before)
    end

    it "leaves the retry alone when the caller refuses, and when a resume got there first" do
      advance(300)
      expect(only_row(sweep.call(allow: ->(_run) { "not this one" }))).to include("outcome" => "nothing", "reason" => "refused")
      expect(store.find("wr_1")).to include("state" => "waiting")

      engine.resume("wr_1")
      expect(only_row(sweep.call)["outcome"]).to eq("nothing")
      expect(store.find("wr_1")["current"]).to eq("plan")
      expect(panes.kicks.size).to eq(3)
    end

    it "starts a dead daemon first when the retry is due, spends nothing, and retries on the next pass" do
      panes.daemon = false
      advance(300)
      before = store.find("wr_1")

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "respawned", "cause" => "daemon_down")
      expect(panes.respawns).to eq(["app.worktree-x"])
      expect(store.find("wr_1")).to eq(before)
      expect(types).not_to include("step_stalled")
      expect(only_row(sweep.call)).to include("outcome" => "retried", "cause" => "retry_backoff")
    end

    it "only reports the respawn under --dry-run" do
      panes.daemon = false
      advance(300)
      before = store.find("wr_1")

      expect(only_row(sweep.call(dry_run: true))).to include("outcome" => "dry_run", "action" => "respawn_daemon")
      expect(panes.respawns).to eq([])
      expect(store.find("wr_1")).to eq(before)
    end

    it "needs no daemon before the time: the wait is read from the file" do
      panes.daemon = false
      advance(10)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "backoff")
      expect(panes.respawns).to eq([])
    end

    it "hands a due retry whose line meets a busy pane to the sweep's redelivery, which types it later" do
      advance(300)
      panes.kick_result = {ok: false, code: "pane_busy", message: "pane %5 is busy"}
      pane_shows("idle", idle_seconds: 600)

      expect(only_row(sweep.call)).to include("outcome" => "retried")
      expect(store.find("wr_1")).to include("current" => "plan", "state" => "waiting")
      expect(store.find("wr_1")["reason"]["details"]).to include("kind" => "dispatch", "error" => "pane_busy")
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "backoff", "cause" => "undelivered")

      advance(61)
      panes.kick_result = {ok: true}
      expect(only_row(sweep.call)).to include("outcome" => "redelivered", "cause" => "undelivered")
      expect(store.find("wr_1")).to include("current" => "plan", "state" => "running")
    end

    it "says a due retry was held when the pane id was reused, as nothing and not as retried or failed" do
      panes.changed << "%5"
      advance(300)

      row = only_row(sweep.call)

      expect(row).to include("outcome" => "nothing", "reason" => "retry_blocked", "cause" => "retry_backoff", "action" => "retry")
      expect(row["message"]).to include("--pane")
      expect(store.find("wr_1")["backoff"]).to include("blocked" => "pane_changed")
      expect(panes.kicks.size).to eq(2)
      expect(types).to include("step_retry_blocked")
    end

    it "leaves a retry that was held because its pane is gone to a person" do
      panes.gone << "%5"
      advance(300)
      engine.tick("wr_1")
      held = store.find("wr_1")
      expect(held["backoff"]).to include("blocked" => "pane_gone")

      row = only_row(sweep.call)
      expect(row).to include("outcome" => "nothing", "reason" => "retry_blocked")
      expect(store.find("wr_1")).to eq(held)
    end

    it "does nothing for a run cancelled during the wait" do
      engine.cancel("wr_1")
      advance(300)

      expect(only_row(sweep.call(run: "wr_1"))).to include("outcome" => "nothing", "reason" => "finished")
    end
  end
end
