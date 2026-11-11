require "spec_helper"
require "tmpdir"
require "stringio"

# The workflow engine over a real run store in a temporary directory and a FakeGit, so nothing
# starts a process. The examples that need a real checkout stay in spec/system.
RSpec.describe Workspace::WorkflowEngine do
  around do |example|
    Dir.mktmpdir("wf-engine") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:worktree) { File.join(@dir, "app") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2 wr_3] }
  let(:store) { Interceptable.subclass(Workspace::WorkflowRunStore, :update, :find).new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { InterruptibleWorkflowPanes.new }
  let(:composer) { FakeStepComposer.new }
  let(:check_results) { [] }
  let(:check_calls) { [] }
  let(:stop_whens) { [] }
  let(:checker) do
    lambda do |stop_when:, **args|
      stop_whens << stop_when
      check_calls << args.merge(state_during: store.find("wr_1")["steps"][store.find("wr_1")["current"]]["state"])
      check_results.shift || {exit_code: 0, timed_out: false}
    end
  end
  let(:commands) { {test: "bundle exec rspec", lint: nil} }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: commands) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:events) { [] }
  let(:event_log) do
    log = instance_double(Workspace::EventLog)
    allow(log).to receive(:record) { |type:, project:, data:| events << [type, project, data] }
    log
  end
  let(:stopped) { [] }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}) }
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir}) }
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: notes) }
  let(:workspace_known) { ->(_name) { false } }
  subject(:engine) { build_engine }

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  # The one place an engine is built; an example that needs another collaborator passes it here.
  def build_engine(**overrides)
    Workspace::WorkflowEngine.new(store: store, resources: resources, composer: composer, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note,
      env_stopper: ->(**args) { stopped << args }, workspace_known: workspace_known, event_log: event_log, task_store: task_store, clock: -> { now.first }, **overrides)
  end

  def definition(yaml, id: "flow")
    Workspace::WorkflowDefinition.parse(yaml, id: id, source: "global", path: "/defs/#{id}.yml")
  end

  let(:three_steps) do
    definition(<<~YAML)
      inputs:
        task: {required: true}
      instructions: Work on {{inputs.task}} in {{workspace}} on {{branch}}.
      steps:
        plan:
          prompt: Write {{artifacts}}/plan.md for run {{run}}.
          produces: [plan.md]
          gate: approve
        build:
          prompt: Build it.
          uses: [test-db]
          context: continue
        verify:
          prompt: Verify it.
          include: [review]
          uses: [test-db]
          status: {command: test, timeout: 5m}
          on_fail: {goto: build, max: 2, context: fresh}
    YAML
  end

  # One run per checkout: the first run of a spec is in +worktree+, a run for another pane or workspace in a checkout of its own.
  def start(definition = three_steps, inputs: {"task" => "X-1"}, pane: "%5", workspace: "app.worktree-x", checkout: nil, **rest)
    path = (checkout || (pane == "%5" && workspace == "app.worktree-x")) ? worktree : FileUtils.mkdir_p("#{worktree}-#{pane.delete("%")}-#{workspace}").first
    allow(lock_namespace).to receive(:resolve).with(cwd: path).and_return(key: "ns", display: "app", dir: lock_dir)
    engine.start(definition: definition, workspace: workspace, worktree: path, inputs: inputs, pane: pane, **rest)
  end

  def artifact(name, run_id = "wr_1")
    path = File.join(worktree, ".workflow", run_id, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    # Written at the spec's own time, which is what an attempt's start is compared with.
    File.utime(now.first, now.first, path)
    path
  end

  def engine_with(**overrides)
    build_engine(**overrides)
  end

  def lock_holder(name)
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status(name).dig(name, "holder")
  end

  def history(run_id = "wr_1")
    File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line)["type"] }
  end

  def history_lines(run_id = "wr_1")
    File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line) }
  end

  # Takes a run past its gated first step, to the build step.
  def to_build
    start
    artifact("plan.md")
    engine.turn_ended("wr_1", pane: "%5")
    engine.approve("wr_1")
  end

  def to_verify
    to_build
    engine.turn_ended("wr_1", pane: "%5")
  end

  describe "the attempt ledger" do
    let(:ledger_flow) do
      definition("steps:\n  plan:\n    prompt: Plan.\n    produces: [plan.md]\n    status: {command: test, timeout: 5m}\n")
    end
    let(:plan) { File.join(worktree, ".workflow", "wr_1", "plan.md") }

    def attempt
      store.find("wr_1")["steps"]["plan"]["attempts"].last
    end

    it "records the definition, the prompt, the packs and HEAD when the attempt begins" do
      start(ledger_flow, inputs: {})

      expect(attempt["head"]).to eq("before" => "1" * 40, "after" => nil)
      expect(attempt["definition_sha256"]).to eq(store.find("wr_1")["definition_sha256"])
      expect(attempt["prompt_sha256"]).to eq(Digest::SHA256.file(attempt["prompt_file"]).hexdigest)
      expect(attempt["packs"]).to eq([{"ref" => "play/binding", "sha256" => "b" * 64}])
    end

    it "records HEAD after, each output's hash and size, and the check command that ran, when the attempt ends" do
      start(ledger_flow, inputs: {})
      artifact("plan.md")
      allow(guard).to receive(:head).and_return("2" * 40)
      commands[:test] = "bin/test --first"
      engine.turn_ended("wr_1", pane: "%5")
      commands[:test] = "bin/test --drifted"

      done = attempt
      expect(done["outcome"]).to eq("passed")
      expect(done["head"]).to eq("before" => "1" * 40, "after" => "2" * 40)
      expect(done["outputs"]).to eq([{"file" => "plan.md", "sha256" => Digest::SHA256.hexdigest("done\n"), "bytes" => 5}])
      expect(done["check"]["command"]).to eq("bin/test --first")
    end

    it "records a failed attempt too" do
      start(ledger_flow, inputs: {})
      artifact("plan.md")
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt).to include("outcome" => "failed", "code" => "check_failed", "head" => {"before" => "1" * 40, "after" => "1" * 40})
      expect(attempt["outputs"].first).to include("file" => "plan.md", "bytes" => 5)
    end

    # A run stored before the strict check passes a link; the record must not follow it.
    def link_output
      store.update("wr_1") { |run| run["definition"].delete("produces_check") }
      FileUtils.mkdir_p(File.dirname(plan))
      target = File.join(@dir, "elsewhere.md")
      File.write(target, "outside\n")
      File.utime(now.first, now.first, target)
      File.symlink(target, plan)
    end

    it "reads a linked output as nil, never following the link, when the step passes" do
      start(ledger_flow, inputs: {})
      link_output
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt["outcome"]).to eq("passed")
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => nil}])
    end

    it "reads a linked output as nil, never following the link, when the step fails" do
      start(ledger_flow, inputs: {})
      link_output
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt["outcome"]).to eq("failed")
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => nil}])
    end

    context "with a hash cap of 3 bytes" do
      subject(:engine) { build_engine(attempt_record: Workspace::WorkflowAttemptRecord.new(guard: guard, clock: -> { now.first }, max_hash_bytes: 3)) }

      it "records a file past the size cap by its size alone" do
        start(ledger_flow, inputs: {})
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")

        expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => 5, "too_large" => true}])
      end
    end

    it "records no outputs for a step with no produces" do
      start(definition("steps:\n  plan:\n    prompt: Plan.\n    status: {command: test, timeout: 5m}\n"), inputs: {})
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt["outputs"]).to eq([])
    end

    it "leaves check.command out when the project sets no command" do
      start(ledger_flow, inputs: {})
      commands[:test] = nil
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt["check"]).not_to have_key("command")
    end

    it "closes the open attempt when the run is cancelled" do
      start(ledger_flow, inputs: {})
      artifact("plan.md")
      allow(guard).to receive(:head).and_return("3" * 40)
      engine.cancel("wr_1")

      expect(attempt["head"]).to eq("before" => "1" * 40, "after" => "3" * 40)
      expect(attempt["outputs"].first).to include("file" => "plan.md", "bytes" => 5)
    end

    it "closes the open attempt when the workspace is killed, with nil fields for a checkout that is gone" do
      start(ledger_flow, inputs: {})
      allow(guard).to receive(:head).and_return(nil)
      engine.workspace_killed("app.worktree-x")

      expect(store.find("wr_1")["state"]).to eq("cancelled")
      expect(attempt["head"]).to eq("before" => "1" * 40, "after" => nil)
      expect(attempt["outputs"]).to eq([{"file" => "plan.md", "sha256" => nil, "bytes" => nil}])
    end

    it "never fails a cancel because the record could not be made" do
      start(ledger_flow, inputs: {})
      allow(guard).to receive(:head).and_raise("boom")

      expect(engine.cancel("wr_1")["state"]).to eq("cancelled")
    end

    it "gives no end fields to an attempt that was not delivered" do
      panes.kick_result = {ok: false, code: "not_delivered", message: "may still be in the input box", reason: "prompt_unconfirmed"}
      start(ledger_flow, inputs: {})

      expect(attempt["outcome"]).to eq("not_delivered")
      expect(attempt["code"]).to eq("not_delivered")
      expect(attempt).not_to include("outputs")
      expect(attempt["head"]).to eq("before" => "1" * 40, "after" => nil)
    end

    it "closes an attempt stored without the new fields, and leaves the other fields alone" do
      start(ledger_flow, inputs: {})
      store.update("wr_1") { |run| run["steps"]["plan"]["attempts"].last.reject! { |key, _| %w[head packs prompt_sha256 definition_sha256].include?(key) } }
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(attempt).to include("outcome" => "passed", "head" => {"before" => nil, "after" => "1" * 40})
      expect(attempt).not_to include("packs", "prompt_sha256", "definition_sha256")
    end
  end

  describe "the history an attempt keeps" do
    # [where, code, until?] for every entry of the run, attempts in order then the run's own list.
    def entries(id = "wr_1")
      run = store.find(id)
      from_attempts = run["steps"].flat_map do |step, state|
        state["attempts"].flat_map { |attempt| Array(attempt["reasons"]).map { |e| ["#{step}.#{attempt["n"]}", e["code"], e["until"]] } }
      end
      # The first entry of the run's own list is the `not_started` reason that create sets; the dispatch ends it.
      own = Array(run["reasons"])
      own = own.drop(1) if own.first && own.first["since"] == run["created_at"] && own.first["code"] == "waiting_you"
      from_attempts + own.map { |e| ["run:#{e["step"]}", e["code"], e["until"]] }
    end

    it "records the first reason, set in create, when the run is never dispatched" do
      run = start(three_steps, dispatch: false)

      expect(run["reasons"]).to match([include("code" => "waiting_you", "step" => "plan", "until" => nil)])
    end

    it "keeps a gate's wait on the attempt it ended, closes it on approve, and ignores a tick while it stands" do
      start
      artifact("plan.md")
      now[0] += 5
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 5
      engine.tick("wr_1")
      engine.tick("wr_1")

      expect(entries).to eq([["plan.1", "waiting_you", nil]])

      now[0] += 50
      engine.approve("wr_1")
      expect(store.find("wr_1")["steps"]["plan"]["attempts"].first["reasons"]).to eq([{"code" => "waiting_you", "since" => "2026-10-04T12:00:05Z", "until" => "2026-10-04T12:01:00Z"}])
    end

    it "closes a gate's wait on reject, and the rerun opens no entry of its own" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 10
      engine.reject("wr_1", note: "Too big.")

      expect(entries).to eq([["plan.1", "waiting_you", "2026-10-04T12:00:10Z"]])
    end

    it "keeps a wait for a lock on the run, with its step, until the step starts" do
      locked = definition("steps:\n  verify:\n    prompt: P\n    uses: [test-db]\n")
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      now[0] += 10
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
      engine.cancel("wr_1")
      now[0] += 30
      engine.tick("wr_2")

      expect(entries("wr_2")).to eq([["run:verify", "waiting_lock", "2026-10-04T12:00:40Z"]])
    end

    it "keeps a failed check on the attempt that failed, until a person resumes" do
      check_results << {exit_code: 1, timed_out: false}
      one = definition("steps:\n  verify:\n    prompt: P\n    status: {command: test, timeout: 5m}\n")
      start(one, inputs: {})
      now[0] += 5
      engine.turn_ended("wr_1", pane: "%5")
      expect(entries).to eq([["verify.1", "failed_check", nil]])

      now[0] += 5
      engine.resume("wr_1")
      expect(entries).to eq([["verify.1", "failed_check", "2026-10-04T12:00:10Z"]])
    end

    it "opens no entry when on_fail sends the run straight back" do
      to_verify
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")

      expect(entries.reject { |where, *| where == "plan.1" }).to eq([])
    end

    it "closes an open attempt's reason on cancel and when the workspace is killed" do
      one = definition("steps:\n  a:\n    prompt: P\n    produces: [a.md]\n")
      start(one, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      expect(entries).to eq([["a.1", "turn_ended_incomplete", nil]])
      now[0] += 7
      engine.cancel("wr_1")
      expect(entries).to eq([["a.1", "turn_ended_incomplete", "2026-10-04T12:00:07Z"]])

      start(one, inputs: {}, pane: "%6", workspace: "app.worktree-y")
      engine.turn_ended("wr_2", pane: "%6")
      engine.workspace_killed("app.worktree-y")
      expect(entries("wr_2")).to eq([["a.1", "turn_ended_incomplete", "2026-10-04T12:00:07Z"]])
    end

    it "records a parked resume and closes it when it is released" do
      panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
      start(three_steps.then { definition("steps:\n  work:\n    prompt: P\n") }, inputs: {})
      panes.kick_result = {ok: true}
      id = engine.park("wr_1")["parked"]["id"]
      expect(entries.map { |_, code, finish| [code, finish] }).to include(["parked", nil])
      now[0] += 9
      engine.release_park("wr_1", id)

      expect(entries.select { |_, code, _| code == "parked" }).to all(satisfy { |entry| entry.last })
    end

    it "keeps one entry for a wait a park interrupted and gave back (round 2, 7)" do
      check_results << {exit_code: 1, timed_out: false}
      one = definition("steps:\n  verify:\n    prompt: P\n    status: {command: test, timeout: 5m}\n")
      start(one, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 5
      engine.park("wr_1")
      expect(entries).to eq([["verify.1", "failed_check", "2026-10-04T12:00:05Z"], ["run:verify", "parked", nil]])

      now[0] += 5
      store.update("wr_1") { |run| run.delete("parked") }
      engine.tick("wr_1")
      engine.cancel("wr_1") if entries.none? { |_, code, finish| code == "failed_check" && finish.nil? }
      expect(entries.count { |_, code, _| code == "failed_check" }).to eq(1)
    end

    it "closes a failed-check entry on a resume to another step" do
      check_results << {exit_code: 1, timed_out: false}
      two = definition("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n    status: {command: test, timeout: 5m}\n")
      start(two, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 3
      engine.resume("wr_1", from: "a")

      expect(entries).to eq([["b.1", "failed_check", "2026-10-04T12:00:03Z"]])
    end

    it "reads a run stored without session, agent, usage or reasons through report, approve and cancel" do
      start(three_steps)
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      store.update("wr_1") do |run|
        run.delete("reasons")
        run["steps"].each_value { |state| state["attempts"].each { |attempt| %w[session agent usage reasons].each { |key| attempt.delete(key) } } }
      end

      expect { engine.approve("wr_1") }.not_to raise_error
      expect { engine.report("wr_1", status: "pass", summary: "ok") }.not_to raise_error
      expect { engine.cancel("wr_1") }.not_to raise_error
      expect(store.find("wr_1")["state"]).to eq("cancelled")
    end
  end

  describe "alerts.workflow" do
    let(:sent) { [] }
    let(:alert_settings) { {notify: "notify-me", workflow: %w[gate failed stalled finished]} }
    let(:error_stream) { StringIO.new }
    let(:alert_config) { instance_double(Workspace::AlertConfig, for_workspace: alert_settings) }
    let(:spawner) { ->(_argv, env, _log) { sent << env } }
    let(:alerts) { Workspace::WorkflowAlerts.new(alert_config: alert_config, spawner: ->(*args) { spawner.call(*args) }, error_output: error_stream) }
    subject(:engine) { build_engine(event_log: event_log, task_store: task_store, alerts: alerts) }

    def events_sent
      sent.map { |env| env["WORKSPACE_ALERT_EVENT"] }
    end

    it "alerts when a step starts waiting at a gate, with the run in the environment" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(sent.size).to eq(1)
      expect(sent.first).to include("WORKSPACE_ALERT" => "workflow", "WORKSPACE_ALERT_EVENT" => "gate", "WORKSPACE_ALERT_RUN_ID" => "wr_1",
        "WORKSPACE_ALERT_WORKSPACE" => "app.worktree-x", "WORKSPACE_ALERT_STEP" => "plan")
      expect(sent.first["WORKSPACE_ALERT_TEXT"]).to include("app.worktree-x", "wr_1", "waiting for you")
    end

    it "does not alert again when the waiting run is changed without leaving the gate" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      sent.clear

      engine.note_stall("wr_1", step: "plan", attempt: 1, cause: "pane_gone")
      engine.tick("wr_1")

      expect(events_sent).to eq(%w[stalled])
    end

    it "alerts once when the loops are spent and the check's failure waits for a person, not for each retry" do
      to_verify
      sent.clear
      3.times { check_results << {exit_code: 2, timed_out: false} }
      2.times do
        engine.turn_ended("wr_1", pane: "%5")
        engine.turn_ended("wr_1", pane: "%5")
      end
      expect(events_sent).to eq([])

      engine.turn_ended("wr_1", pane: "%5")

      expect(events_sent).to eq(%w[failed])
      expect(sent.first["WORKSPACE_ALERT_REASON"]).to eq("failed_check")
      expect(sent.first["WORKSPACE_ALERT_STEP"]).to eq("verify")
    end

    it "alerts once when the run finishes" do
      to_verify
      sent.clear
      engine.turn_ended("wr_1", pane: "%5")

      expect(events_sent).to eq(%w[finished])
      expect(sent.first["WORKSPACE_ALERT_TEXT"]).not_to include(" at ")
    end

    it "alerts for a stall the sweep notes once for each attempt and cause" do
      to_build
      sent.clear
      3.times { engine.note_stall("wr_1", step: "build", attempt: 1, cause: "agent_gone") }
      engine.note_stall("wr_1", step: "build", attempt: 1, cause: "daemon_down")

      expect(events_sent).to eq(%w[stalled stalled])
      expect(sent.first["WORKSPACE_ALERT_CAUSE"]).to eq("agent_gone")
    end

    it "sends nothing while an on_fail retry waits out its backoff, since a retry is coming" do
      waiting = definition("max_attempts: 3\nsteps:\n  build:\n    prompt: B\n  verify:\n    prompt: V\n    status: bin/check\n    on_fail: {goto: build, max: 2, backoff: 2m}\n")
      start(waiting, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")

      expect(store.find("wr_1")["reason"]["code"]).to eq("retry_backoff")
      expect(sent).to eq([])
    end

    it "sends nothing for a change that raises, nor for a cancel" do
      start
      expect { engine.approve("wr_1") }.to raise_error(Workspace::Error)
      engine.cancel("wr_1")

      expect(sent).to eq([])
    end

    it "sends only the events alerts.workflow names" do
      alert_settings[:workflow] = %w[finished]
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(sent).to eq([])
    end

    it "sends nothing with alerts.workflow unset, or with no notify command" do
      alert_settings[:workflow] = []
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      expect(sent).to eq([])

      alert_settings.merge!(workflow: %w[gate finished], notify: nil)
      engine.approve("wr_1")
      artifact("build.md")
      engine.resume("wr_1", from: "plan")

      expect(sent).to eq([])
    end

    it "escapes values from the run file and never passes a next action" do
      start
      store.update("wr_1") { |run| run["workspace"] = "evil\e[31m\nname" }
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      env = sent.first
      expect(env["WORKSPACE_ALERT_WORKSPACE"]).to eq("evil\\e[31m\\nname")
      expect(env.keys.grep(/NEXT|ACTION/)).to eq([])
    end

    it "reports a notifier that raises and still completes the change" do
      allow(self).to receive(:spawner).and_return(->(*) { raise "boom" })
      start
      artifact("plan.md")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run.dig("steps", "plan", "gate", "state")).to eq("waiting")
      expect(error_stream.string).to include("could not send alerts for wr_1", "boom")
    end

    it "reports an unreadable alert setting and still completes the change" do
      allow(alert_config).to receive(:for_workspace).and_raise(Workspace::Error, "cannot read")
      start
      artifact("plan.md")

      expect(engine.turn_ended("wr_1", pane: "%5")["state"]).to eq("waiting")
      expect(error_stream.string).to include("cannot read")
    end

    it "fires after the run lock is given up" do
      free = nil
      allow(self).to receive(:spawner).and_return(->(*) { free = !store.update("wr_1", nonblocking: true) { |run| run }.nil? })
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(free).to eq(true)
    end

    it "keeps working for a run stored before the setting, with no sweep marks" do
      start
      store.update("wr_1") { |run| run.delete("sweep") }
      artifact("plan.md")

      expect(engine.turn_ended("wr_1", pane: "%5")["state"]).to eq("waiting")
    end
  end

  describe "#start" do
    it "stores the resolved definition of a workflow that extends another, so editing the parent later changes nothing in the run" do
      defs = FileUtils.mkdir_p(File.join(@dir, "defs")).first
      File.write(File.join(defs, "base.yml"), "steps:\n  plan:\n    prompt: Plan it.\n    produces: [plan.md]\n")
      File.write(File.join(defs, "kid.yml"), "extends: base\nsteps:\n  more:\n    prompt: More.\n    produces: [more.md]\n")
      catalog = Workspace::WorkflowCatalog.new(config: instance_double(Workspace::Config, workflows_dir: defs, builtin_workflows_dir: File.join(@dir, "none")))
      kid = catalog.find("kid")

      start(kid, inputs: {})
      File.write(File.join(defs, "base.yml"), "steps:\n  plan:\n    prompt: Plan it differently.\n    produces: [plan.md]\n")
      stored = store.find("wr_1")

      expect(stored["definition"]).to eq(kid.to_h.merge("produces_check" => "strict"))
      expect(stored["definition"]["steps"].map { |step| step["prompt"] }).to eq(["Plan it.", "More."])
      expect(stored["definition_sha256"]).to eq(kid.resolved_sha256)
      expect(catalog.find("kid").resolved_sha256).not_to eq(stored["definition_sha256"])
    end

    it "writes the run, the first step's instructions and the pane's binding, then types one line into the pane" do
      run = start(note: "Keep it small.")
      prompt = File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.prompt.md")

      expect(run).to include("id" => "wr_1", "workflow" => "flow", "workspace" => "app.worktree-x", "project" => "app",
        "worktree" => worktree, "task" => "t1", "inputs" => {"task" => "X-1"}, "state" => "running", "current" => "plan",
        "pane" => "%5", "reason" => nil, "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"),
        "definition_source" => "global", "definition_sha256" => three_steps.sha256)
      expect(run["definition"]).to eq(three_steps.to_h.merge("produces_check" => "strict"))
      expect(run["steps"]["plan"]).to include("state" => "running")
      expect(run["steps"]["plan"]["attempts"].size).to eq(1)
      expect(run["steps"]["plan"]["attempts"].first).to include("n" => 1, "started_at" => "2026-10-04T12:00:00.000Z", "context" => [], "prompt_file" => prompt)
      expect(File.read(prompt)).to eq(
        "Work on X-1 in app.worktree-x on feature/x.\n\n" \
        "Write #{worktree}/.workflow/wr_1/plan.md for run wr_1.\n\n" \
        "This step is finished when your turn ends and these files exist as non-empty regular files (not links), written during this attempt: #{worktree}/.workflow/wr_1/plan.md.\n\n" \
        "Note for this run: Keep it small.\n"
      )
      expect(panes.bound).to eq("%5" => {workspace: "app.worktree-x", run_id: "wr_1", step: "plan", attempt: 1,
                                         instructions: prompt, artifacts: File.join(worktree, ".workflow", "wr_1")})
      expect(panes.kicks).to eq([{workspace: "app.worktree-x", pane: "%5", text: "Read #{prompt} and follow it.", fresh: true, run_id: "wr_1"}])
      expect(store.find("wr_1")).to eq(run)
      expect(history).to eq(%w[run_started step_dispatching step_dispatched])
    end

    it "composes the default packs, then the workflow's and the step's layers, for the run's checkout" do
      start

      expect(composer.calls.last).to include(packs: nil, cwd: worktree, attempt: [])
      expect(composer.calls.last[:workflow]).to eq("name" => "flow", "include" => [], "text" => "Work on X-1 in app.worktree-x on feature/x.")
      expect(composer.calls.last[:step]).to include("name" => "plan", "include" => [])
    end

    it "leaves the dev pack out of a step that uses devenv, which already holds the environment" do
      start(definition("steps:\n  a:\n    prompt: P\n    uses: [dev-env]\n"), inputs: {})

      expect(composer.calls.last).to include(skip: %w[dev])
    end

    it "leaves no pack out of a step that does not use devenv" do
      start

      expect(composer.calls.last).to include(skip: [])
    end

    it "hands the composer the binding the pane is about to get, to follow the binding pack" do
      start

      artifacts = File.join(worktree, ".workflow", "wr_1")
      expect(composer.calls.last[:binding]).to eq("kind" => "run", "id" => "wr_1", "workspace" => "app.worktree-x", "step" => "plan",
        "attempt" => 1, "instructions" => File.join(artifacts, "steps", "plan.1.prompt.md"), "artifacts" => artifacts)
      expect(panes.bound["%5"]).to include(run_id: "wr_1", step: "plan", attempt: 1,
        instructions: composer.calls.last[:binding]["instructions"], artifacts: artifacts)
    end

    it "announces the run on the shared event log" do
      start

      expect(events).to eq([["workflow_changed", "app.worktree-x",
        {"run_id" => "wr_1", "workflow" => "flow", "workspace" => "app.worktree-x", "state" => "running", "step" => "plan", "reason" => nil}]])
    end

    it "refuses a missing required input, naming it, and creates nothing" do
      expect { start(inputs: {}) }.to raise_error(Workspace::Error, "Workflow flow needs input task. Pass --input task=VALUE.") { |error|
        expect(error.code).to eq("input_required")
        expect(error.details).to eq("workflow" => "flow", "inputs" => [{"name" => "task", "description" => nil}])
      }
      expect(store.active).to eq([])
      expect(panes.kicks).to eq([])
    end

    describe "unsafe paths" do
      let(:gated) do
        definition(<<~YAML)
          steps:
            a:
              prompt: P
              produces: [a.md]
              gate: approve
        YAML
      end

      def refusal(**args)
        engine.preflight(definition: three_steps, workspace: "app.worktree-x", worktree: worktree, inputs: {"task" => "X-1"}, **args)
        nil
      rescue Workspace::Error => e
        e
      end

      it "refuses a checkout that does not exist yet when it holds a quote" do
        error = refusal(checkout: "/p/a'b")

        expect(error.code).to eq("unsafe_checkout_path")
        expect(error.details).to include("characters" => ["single quote"], "path_kind" => "checkout")
        expect(error.message).not_to include("/p/a'b")
      end

      it "refuses start with an unsafe worktree" do
        expect { engine.start(definition: three_steps, workspace: "app.worktree-x", worktree: "/p/a'b", inputs: {"task" => "X-1"}, pane: "%5") }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unsafe_checkout_path") }
      end

      it "names an invisible character" do
        expect(refusal(checkout: "/p/a‮b").details["characters"]).to eq(["U+202E"])
      end

      it "does not refuse a missing checkout, or one equal to the worktree" do
        expect(refusal(checkout: nil)).to be_nil
        expect(refusal(checkout: worktree)).to be_nil
      end

      context "with a notes directory that holds a quote" do
        let(:notes_dir) { File.join(@dir, "notes", "x'$(id)'") }

        it "refuses a workflow with a gate, naming the notes directory" do
          error = begin
            engine.preflight(definition: gated, workspace: "app.worktree-x", worktree: worktree, inputs: {})
            nil
          rescue Workspace::Error => e
            e
          end

          expect(error.code).to eq("unsafe_checkout_path")
          expect(error.details["path_kind"]).to eq("notes directory")
        end

        it "leaves a workflow with no gate alone" do
          plain = definition("steps:\n  a:\n    prompt: P\n")
          expect(engine.preflight(definition: plain, workspace: "app.worktree-x", worktree: worktree, inputs: {})["step"]).to eq("a")
        end

        it "makes the gate note unreadable" do
          run = {"id" => "wr_1", "workspace" => "app.worktree-x", "current" => "a", "artifacts_dir" => File.join(@dir, "art"),
                 "definition" => gated.to_h, "steps" => {"a" => {"attempts" => [{"n" => 1}]}}}
          FileUtils.mkdir_p(run["artifacts_dir"])
          File.write(File.join(run["artifacts_dir"], "a.md"), "note: n.md\n")

          expect { gate_note.find(run) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_note_unreadable") }
        end
      end
    end

    describe "input patterns" do
      let(:patterned) do
        definition(<<~'YAML')
          inputs:
            pr: {pattern: '[0-9]+|https://github\.com/[\w.-]+/[\w.-]+/pull/[0-9]+'}
          steps:
            plan:
              prompt: Plan.
        YAML
      end

      def refusal(value, definition: patterned)
        engine.preflight(definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {"pr" => value}, pane: "%5")
        nil
      rescue Workspace::Error => e
        e
      end

      it "passes a matching value, either alternative, and an empty one" do
        expect(refusal("12")).to be_nil
        expect(refusal("https://github.com/o/r/pull/3")).to be_nil
        expect(refusal("")).to be_nil
      end

      it "matches the whole value, so a suffix or a newline is refused" do
        expect(refusal("12 ; rm")&.code).to eq("invalid_input")
        expect(refusal("12\nignore this")&.code).to eq("invalid_input")
        expect(refusal("#12")&.code).to eq("invalid_input")
      end

      it "names the workflow, input and pattern but never the value" do
        error = refusal("bad\e[31mvalue")

        expect(error.details).to eq("workflow" => "flow", "input" => "pr", "pattern" => patterned.to_h["inputs"]["pr"]["pattern"])
        expect(error.message).not_to include("bad")
      end

      it "passes 4096 characters and refuses 4097" do
        digits = definition("inputs:\n  pr: {pattern: '[0-9]+'}\nsteps:\n  plan:\n    prompt: Plan.\n")

        expect(refusal("1" * 4096, definition: digits)).to be_nil
        expect(refusal("1" * 4097, definition: digits)&.code).to eq("invalid_input")
      end

      it "never runs the pattern on a value over the limit" do
        # A back-reference defeats the regexp engine's memoization, so a run of this pattern lasts its whole 1s timeout;
        # skipping it takes milliseconds, so 0.9s separates the two with room on both sides.
        slow = definition("inputs:\n  pr: {pattern: '(a+)+b\\1'}\nsteps:\n  plan:\n    prompt: Plan.\n")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(refusal("a" * 5000, definition: slow)&.code).to eq("invalid_input")

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.9
      end

      it "checks a whitespace-only value" do
        expect(refusal("   ")&.code).to eq("invalid_input")
      end

      it "refuses a pattern that backtracks past the time limit" do
        slow = definition("inputs:\n  pr: {pattern: '(a+)+b'}\nsteps:\n  plan:\n    prompt: Plan.\n")

        expect(refusal("a" * 40, definition: slow)&.code).to eq("invalid_input")
      end

      it "refuses start before any run exists" do
        expect { start(patterned, inputs: {"pr" => "x"}) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_input") }
        expect(store.active).to eq([])
        expect(panes.kicks).to eq([])
      end
    end

    it "refuses an input the workflow doesn't have" do
      expect { start(inputs: {"task" => "X", "colour" => "red"}) }
        .to raise_error(Workspace::UsageError, 'Workflow flow has no input "colour" (inputs: task).')
    end

    it "refuses a workflow whose check names a command the project has not set" do
      commands[:test] = nil

      expect { start }.to raise_error(Workspace::Error, /checks steps with the project's test command, and app has none\..*workspace config set commands\.test "COMMAND" --name app/m) { |error|
        expect(error.code).to eq("workflow_command_unset")
        expect(error.details).to eq("workflow" => "flow", "project" => "app", "commands" => ["test"],
          "steps" => [{"step" => "verify", "command" => "test", "via" => "status"}])
      }
      expect(store.active).to eq([])
    end

    describe "a require: exec program" do
      let(:exec_path) { File.join(@dir, "bin") }
      let(:exec_line) { "check --flag" }
      let(:flow) do
        definition(<<~YAML)
          steps:
            build:
              prompt: Build it.
              require:
                - exec: #{exec_line.inspect}
        YAML
      end

      def make_program(path, mode: 0o755)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#!/bin/sh\n")
        File.chmod(mode, path)
        path
      end

      def refused(code)
        expect { start(flow, inputs: {}) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq(code)
          yield error if block_given?
        }
        expect(store.active).to eq([])
        expect(Dir.exist?(File.join(worktree, ".workflow"))).to be(false)
      end

      # Sets only PATH and HOME on the real ENV, and puts them back after the example.
      before do
        FileUtils.mkdir_p(worktree)
        @saved_env = ENV.to_h.slice("PATH", "HOME")
        ENV["PATH"] = exec_path
        ENV["HOME"] = @dir
      end

      after { @saved_env.each { |key, value| ENV[key] = value } }

      it "refuses a bare name that is not on PATH, naming the step and program" do
        refused("workflow_program_missing") do |error|
          expect(error.details).to include("workflow" => "flow", "program" => "check",
            "steps" => [{"step" => "build", "program" => "check", "problem" => "is not on PATH"}])
        end
      end

      it "starts when the bare name is on PATH" do
        make_program(File.join(exec_path, "check"))
        expect { start(flow, inputs: {}) }.not_to raise_error
      end

      context "with an absolute path" do
        let(:exec_line) { File.join(@dir, "tools", "check") }

        it "refuses one that is not executable" do
          make_program(exec_line, mode: 0o644)
          refused("workflow_program_missing") { |error| expect(error.details["steps"].first["problem"]).to match(/not executable/) }
        end

        it "refuses a directory" do
          FileUtils.mkdir_p(exec_line)
          refused("workflow_program_missing") { |error| expect(error.details["steps"].first["problem"]).to match(/not a file/) }
        end
      end

      context "with a ~/ path" do
        let(:exec_line) { "~/tools/check" }

        it "starts when the file exists under HOME" do
          make_program(File.join(@dir, "tools", "check"))
          expect { start(flow, inputs: {}) }.not_to raise_error
        end
      end

      context "with a relative path" do
        let(:exec_line) { "script/check" }

        it "refuses one missing from the checkout" do
          refused("workflow_program_missing")
        end

        it "starts when the checkout holds it" do
          make_program(File.join(worktree, "script", "check"))
          expect { start(flow, inputs: {}) }.not_to raise_error
        end

        it "does not judge it in preflight for a checkout that is not made yet" do
          expect { engine.preflight(definition: flow, workspace: "app", worktree: worktree, inputs: {}, tree: nil, checkout: File.join(@dir, "new")) }.not_to raise_error
        end
      end

      context "with {{changed.tests}}" do
        let(:exec_line) { "check -- {{changed.tests}}" }

        before { make_program(File.join(exec_path, "check")) }

        it "refuses when commands.test_files is empty" do
          allow(commands_config).to receive(:test_files).with("app.worktree-x").and_return([])
          refused("workflow_test_files_unset") { |error| expect(error.details).to include("workflow" => "flow", "workspace" => "app.worktree-x", "steps" => ["build"]) }
        end

        it "starts when commands.test_files is set" do
          allow(commands_config).to receive(:test_files).with("app.worktree-x").and_return(["spec/**/*_spec.rb"])
          expect { start(flow, inputs: {}) }.not_to raise_error
        end
      end
    end

    describe "a require: command" do
      let(:flow) do
        definition(<<~YAML)
          steps:
            build:
              prompt: Build it.
              status: {command: test}
              require:
                - command: lint
                  optional: #{optional}
            ship:
              prompt: Ship it.
              require:
                - command: test
        YAML
      end
      let(:optional) { false }

      it "refuses when only a require: command is unset, naming its step and listing the others" do
        commands[:test] = "rake"
        expect { start(flow, inputs: {}) }.to raise_error(Workspace::Error, /step build \(require: command: lint\): workspace config set commands\.lint "COMMAND" --name app/) { |error|
          expect(error.code).to eq("workflow_command_unset")
          expect(error.details).to include("commands" => ["lint"], "steps" => [{"step" => "build", "command" => "lint", "via" => "require"}])
        }
        expect(store.active).to eq([])
      end

      it "lists every unset command, each with its step" do
        commands[:test] = nil
        expect { start(flow, inputs: {}) }.to raise_error(Workspace::Error) { |error|
          expect(error.details["steps"]).to eq([
            {"step" => "build", "command" => "test", "via" => "status"},
            {"step" => "build", "command" => "lint", "via" => "require"},
            {"step" => "ship", "command" => "test", "via" => "require"}
          ])
          expect(error.message).to include("commands.test").and include("commands.lint").and include("step ship")
        }
      end

      it "refuses when only the status: command is unset" do
        commands[:test] = nil
        commands[:lint] = "standardrb"
        expect { start(flow, inputs: {}) }.to raise_error(Workspace::Error) { |error|
          expect(error.details["steps"]).to include("step" => "build", "command" => "test", "via" => "status")
          expect(error.details["commands"]).to eq(["test"])
        }
      end

      context "with optional: true" do
        let(:optional) { true }

        it "does not count an unset optional command" do
          commands[:test] = "rake"
          expect { start(flow, inputs: {}) }.not_to raise_error
        end

        it "still counts the status: command" do
          commands[:test] = nil
          expect { start(flow, inputs: {}) }.to raise_error(Workspace::Error) { |error| expect(error.details["commands"]).to eq(["test"]) }
        end
      end
    end

    it "refuses a pane that already runs a workflow, and takes it once that run has ended" do
      start

      expect { start }.to raise_error(Workspace::Error, /Pane %5 is already running workflow run wr_1/) { |error|
        expect(error.code).to eq("pane_has_run")
        expect(error.details).to eq("pane" => "%5", "run_id" => "wr_1")
      }

      engine.cancel("wr_1")
      expect(start["id"]).to eq("wr_2")
    end

    describe "one run per checkout" do
      it "refuses a second run on the checkout, even from another pane, naming the holder and the cancel command" do
        start

        expect { start(pane: "%6", checkout: worktree) }.to raise_error(Workspace::Error, /Checkout .*app already has workflow run wr_1 at step/) { |error|
          expect(error.code).to eq("checkout_has_run")
          expect(error.details).to include("run_id" => "wr_1", "worktree" => File.realpath(worktree), "step" => "plan",
            "state" => "running", "next" => ["workspace workflow cancel wr_1"])
        }
        expect(store.active.size).to eq(1)
      end

      it "matches the checkout by real path, through a symlink" do
        start
        link = File.join(@dir, "link-to-app")
        File.symlink(worktree, link)

        expect { engine.start(definition: three_steps, workspace: "app.worktree-x", worktree: link, inputs: {"task" => "X-1"}, pane: "%6") }
          .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("checkout_has_run") }
      end

      it "refuses in preflight too, and takes the checkout once the run is cancelled, failed or completed" do
        start

        expect { engine.preflight(definition: three_steps, workspace: "app.worktree-x", worktree: worktree, inputs: {"task" => "X-1"}, pane: "%6") }
          .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("checkout_has_run") }

        engine.cancel("wr_1")
        expect(start(pane: "%6", checkout: worktree)["id"]).to eq("wr_2")
      end

      it "ignores a stored run with no worktree, or one whose path is gone" do
        store.create({"state" => "running", "current" => "a", "steps" => {"a" => {"state" => "running", "attempts" => []}},
                      "definition" => {"steps" => [{"id" => "a"}]}, "created_at" => "t"})
        store.create({"state" => "running", "worktree" => File.join(@dir, "gone"), "current" => "a", "steps" => {"a" => {"state" => "running", "attempts" => []}},
                      "definition" => {"steps" => [{"id" => "a"}]}, "created_at" => "t"})

        expect(start(pane: "%6", checkout: worktree)["id"]).to eq("wr_3")
      end

      describe "#run_on_checkout" do
        it "returns the active run on the checkout, through a symlinked path" do
          start
          link = File.join(@dir, "link-to-app")
          File.symlink(worktree, link)

          expect(engine.run_on_checkout(link)["id"]).to eq("wr_1")
          expect(engine.run_on_checkout(worktree)["id"]).to eq("wr_1")
        end

        it "skips a finished run" do
          start
          engine.cancel("wr_1")

          expect(engine.run_on_checkout(worktree)).to be_nil
        end

        it "skips a run whose path is gone, a run with no worktree, and a path that does not exist" do
          store.create({"state" => "running", "worktree" => File.join(@dir, "gone"), "current" => "a", "steps" => {"a" => {"state" => "running", "attempts" => []}},
                        "definition" => {"steps" => [{"id" => "a"}]}, "created_at" => "t"})
          store.create({"state" => "running", "current" => "a", "steps" => {"a" => {"state" => "running", "attempts" => []}},
                        "definition" => {"steps" => [{"id" => "a"}]}, "created_at" => "t"})

          expect(engine.run_on_checkout(worktree)).to be_nil
          expect(engine.run_on_checkout(File.join(@dir, "nowhere"))).to be_nil
        end
      end

      it "does not refuse a target path that does not exist, or none" do
        start

        [File.join(@dir, "nowhere"), nil].each do |tree|
          expect(engine.preflight(definition: three_steps, workspace: "app.worktree-x", worktree: worktree, tree: tree, inputs: {"task" => "X-1"})).to include("step" => "plan")
        end
      end

      it "is not raised by resume, which is the run itself" do
        start
        panes.unbind("wr_1")

        expect { engine.resume("wr_1", pane: "%5") }.not_to raise_error
      end
    end

    it "refuses a pack that can't be read before it creates the run" do
      ghost = definition("steps:\n  a:\n    prompt: P\n    include: [ghost]\n")

      expect { start(ghost, inputs: {}) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("unknown_library_entry") }
      expect(store.active).to eq([])
    end

    it "leaves a run that waits for a person when the pane is gone, holding nothing" do
      locked = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n")
      panes.kick_result = {ok: false, code: "no_such_pane", message: "no pane %5 in tmux session app"}

      run = start(locked, inputs: {})

      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to eq("code" => "pane_gone", "since" => "2026-10-04T12:00:00Z",
        "details" => {"kind" => "dispatch", "step" => "a", "pane" => "%5", "workspace" => "app.worktree-x",
                      "error" => "no_such_pane", "message" => "no pane %5 in tmux session app"})
      expect(run["steps"]["a"]).to include("state" => "waiting")
      expect(run["steps"]["a"]["attempts"].last).to include("outcome" => "not_delivered")
      expect(lock_holder("test-db")).to be_nil
    end

    it "takes a pane whose last run ended and left its binding behind" do
      start
      engine.cancel("wr_1")
      panes.bind(workspace: "app.worktree-x", pane: "%5", run_id: "wr_1", step: "plan", attempt: 1, instructions: "x", artifacts: "y")

      expect(start["id"]).to eq("wr_2")
    end

    it "leaves the run waiting for a person, holding nothing, when the pane can't be bound" do
      locked = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n")
      panes.bind_error = Workspace::Error.new("Pane %5 is in tmux session other, not app.", code: "wrong_session")

      run = start(locked, inputs: {})

      expect(run["reason"]).to include("code" => "pane_gone")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "wrong_session", "message" => "Pane %5 is in tmux session other, not app.")
      expect(run["steps"]["a"]).to include("state" => "waiting")
      expect(run["steps"]["a"]["attempts"].map { |attempt| attempt["outcome"] }).to eq(["not_delivered"])
      expect(panes.kicks).to eq([])
      expect(lock_holder("test-db")).to be_nil
    end

    it "leaves the run waiting for a person when a later step's pack can't be read" do
      ghost = definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    include: [ghost]\n    uses: [test-db]\n")
      start(ghost, inputs: {})

      run = engine.turn_ended("wr_1")

      expect(run).to include("current" => "b", "state" => "waiting")
      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "unknown_library_entry", "message" => "No library entry named ghost.")
      expect(panes.kicks.size).to eq(1)
      expect(lock_holder("test-db")).to be_nil
    end

    it "does not bring back a checkout that was removed: nothing is written and no lock is taken" do
      to_build_ready = definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    uses: [test-db]\n")
      start(to_build_ready, inputs: {})
      FileUtils.rm_rf(worktree)

      run = engine.turn_ended("wr_1")

      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "message" => "the checkout #{worktree} is gone")
      expect(File.exist?(worktree)).to be false
      expect(lock_holder("test-db")).to be_nil
    end

    it "leaves the run waiting for a person when the step's instructions can't be written" do
      start(definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n"), inputs: {})
      full = lambda do |path, text, **options|
        raise Errno::ENOSPC if path.end_with?("b.1.prompt.md")
        File.write(path, text, **options)
      end

      run = engine_with(prompt_writer: full).turn_ended("wr_1")

      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "error")
      expect(run["reason"]["details"]["message"]).to match(/No space left on device/)
      expect(panes.kicks.size).to eq(1)
    end

    it "types nothing into a pane its binding no longer stands for, and takes no lock" do
      two = definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    uses: [test-db]\n    context: continue\n")
      start(two, inputs: {})
      panes.stale << "wr_1"

      run = engine.resume("wr_1", from: "b")

      expect(run["reason"]).to include("code" => "pane_gone")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "pane_gone", "pane" => "%5")
      expect(panes.kicks.size).to eq(1)
      expect(lock_holder("test-db")).to be_nil
    end

    it "leaves the run waiting for a person when its run file does not keep it alive to the lock store" do
      locked = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n")
      allow(liveness).to receive(:run_alive?).and_return(false)

      run = start(locked, inputs: {})

      expect(run["reason"]["details"]).to include("kind" => "dispatch", "message" => "run wr_1 has no run file, so it can hold no lock")
      expect(panes.kicks).to eq([])
    end

    it "stores a message from tmux or the daemon that is not valid text without failing the run's write" do
      panes.kick_result = {ok: false, code: "pane_busy", message: (+"pane \xFF did not go quiet").force_encoding("UTF-8")}

      reason = start["reason"]

      expect(reason["details"]["message"]).to eq("pane � did not go quiet")
      expect(store.find("wr_1")["reason"]).to eq(reason)
    end

    it "says a person is needed when the line could not be typed for another reason" do
      panes.kick_result = {ok: false, code: "pane_busy", message: "pane %5 did not go quiet"}

      reason = start["reason"]

      expect(reason["code"]).to eq("waiting_you")
      expect(reason["details"]).to include("kind" => "dispatch", "error" => "pane_busy", "message" => "pane %5 did not go quiet")
    end
  end

  describe "run from a process with no UTF-8 locale" do
    let(:french) { definition("instructions: Travaille sur {{inputs.task}} (café).\ninputs:\n  task: {}\nsteps:\n  a:\n    prompt: Écris {{artifacts}}/a.md.\n    produces: [a.md]\n  b:\n    prompt: Vérifie.\n") }

    it "starts a run, writes its step file as UTF-8 and reads the run back, with non-ASCII text in the definition, an input and a note" do
      without_utf8_locale do
        run = start(french, inputs: {"task" => "déjà vu"}, note: "naïve")
        prompt = run["steps"]["a"]["attempts"].last["prompt_file"]

        expect(run).to include("state" => "running", "reason" => nil)
        expect(File.read(prompt, encoding: "UTF-8")).to include("Travaille sur déjà vu (café).", "Écris ", "Note for this run: naïve")
        artifact("a.md")
        expect(engine.turn_ended("wr_1")).to include("current" => "b", "state" => "running")
        expect(engine.resume("wr_1", note: "encore", from: "a")["steps"]["a"]["attempts"].last["context"]).to eq(["Note from the person who resumed the run: encore"])
        expect(engine.cancel("wr_1")["state"]).to eq("cancelled")
      end
      expect(store.find("wr_1")["inputs"]).to eq("task" => "déjà vu")
    end

    it "starts a run and names its task, read from the real task store holding a non-ASCII title" do
      tasks = Workspace::TaskStore.new(dir: File.join(@dir, "tasks"), error_output: StringIO.new)
      task = tasks.start(workspace: "app.worktree-x", title: "tâche — première")

      run = without_utf8_locale { engine_with(task_store: tasks, event_log: event_log).start(definition: french, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5") }

      expect(run).to include("state" => "running", "task" => task["id"])
    end

    it "starts a run without a task id when the task store can't be read as text" do
      broken = instance_double(Workspace::TaskStore)
      allow(broken).to receive(:active_for).and_raise(Encoding::InvalidByteSequenceError, "\"\\xC3\" on US-ASCII")

      run = engine_with(task_store: broken).start(definition: french, workspace: "app", worktree: worktree, inputs: {}, pane: "%5")

      expect(run).to include("state" => "running", "task" => nil)
    end

    it "takes the `invalid byte sequence` a string method raises on such text as the same failure, and lets any other ArgumentError through" do
      bytes = Object.new
      def bytes.compose(**) = raise(ArgumentError, "invalid byte sequence in US-ASCII")
      bug = Object.new
      def bug.compose(**) = raise(ArgumentError, "wrong number of arguments (given 1, expected 0)")

      expect { engine_with(composer: bytes).start(definition: french, workspace: "app", worktree: worktree, inputs: {}, pane: "%5") }
        .to raise_error(Workspace::Error, /could not be put together.*\(ArgumentError\)/)
      expect { engine_with(composer: bug).start(definition: french, workspace: "app", worktree: worktree, inputs: {}, pane: "%5") }
        .to raise_error(ArgumentError, /wrong number/)
      expect(store.active).to eq([])
    end

    it "leaves a run waiting for a person, holding nothing, when a step's file can't be written as UTF-8" do
      start(definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    uses: [test-db]\n"), inputs: {})
      unconvertible = lambda do |path, text, **options|
        raise Encoding::UndefinedConversionError, "\"\\xC3\" from ASCII-8BIT to UTF-8" if path.end_with?("b.1.prompt.md")
        File.write(path, text, **options)
      end

      run = engine_with(prompt_writer: unconvertible).turn_ended("wr_1")

      expect(run["reason"]["details"]).to include("kind" => "dispatch")
      expect(lock_holder("test-db")).to be_nil
      expect(store.find("wr_1")).to eq(run)
    end

    it "refuses to start, with a workspace error and nothing left behind, when the instructions can't be put together" do
      clashing = Object.new
      def clashing.compose(**) = raise(Encoding::CompatibilityError, "incompatible character encodings: US-ASCII and UTF-8")

      expect { engine_with(composer: clashing).start(definition: french, workspace: "app", worktree: worktree, inputs: {}, pane: "%5") }
        .to raise_error(Workspace::Error, /the step's instructions could not be put together: a pack, a prompt or a path is not UTF-8 text \(Encoding::CompatibilityError\)/)
      expect(store.active).to eq([])
    end

    it "leaves a run waiting for a person, holding nothing, when a later step's instructions can't be put together" do
      start(definition("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    uses: [test-db]\n"), inputs: {})
      allow(composer).to receive(:compose).and_raise(Encoding::CompatibilityError, "incompatible character encodings: US-ASCII and UTF-8")

      run = engine.turn_ended("wr_1")

      expect(run["reason"]["details"]).to include("kind" => "dispatch")
      expect(run["reason"]["details"]["message"]).to match(/could not be put together/)
      expect(lock_holder("test-db")).to be_nil
      expect(store.find("wr_1")).to eq(run)
    end
  end

  describe "#preflight" do
    it "reports what a start would do and writes nothing" do
      checked = engine.preflight(definition: three_steps, workspace: "app.worktree-x", worktree: worktree, inputs: {"task" => "X-1"}, pane: "%5")

      expect(checked).to eq("workflow" => "flow", "workspace" => "app.worktree-x", "project" => "app", "step" => "plan",
        "pane" => "%5", "inputs" => {"task" => "X-1"}, "packs" => ["play/binding"])
      expect(Dir.exist?(runs_dir)).to be false
      expect(Dir.exist?(File.join(worktree, ".workflow"))).to be false
      expect(panes.kicks).to eq([])
    end
  end

  describe "#render" do
    def render(step = "plan", inputs: {"task" => "X-1"}, flow: three_steps)
      engine.render(definition: flow, step: step, workspace: "app.worktree-x", worktree: worktree, inputs: inputs)
    end

    it "composes the text a delivered attempt of the step is written with, under the preview run" do
      rendered = render("plan")
      composer.calls.clear
      start
      delivered = File.read(File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.prompt.md"))

      expect(rendered["text"]).to eq(delivered.gsub("wr_1", "wr_preview"))
      expect(rendered).to include("run" => "wr_preview", "artifacts_dir" => File.join(worktree, ".workflow", "wr_preview"),
        "instructions" => File.join(worktree, ".workflow", "wr_preview", "steps", "plan.1.prompt.md"), "gate" => "approve")
    end

    it "hands the composer what a delivery hands it, except the run's id and directory" do
      render("verify")
      rendered_call = composer.calls.last
      to_verify
      delivered_call = composer.calls.last

      expect(rendered_call.except(:binding)).to eq(delivered_call.except(:binding).merge(attempt: []))
      expect(rendered_call[:binding]).to eq(delivered_call[:binding].merge("id" => "wr_preview", "attempt" => 1,
        "instructions" => File.join(worktree, ".workflow", "wr_preview", "steps", "verify.1.prompt.md"),
        "artifacts" => File.join(worktree, ".workflow", "wr_preview")))
    end

    it "renders a later step, not just the first, with its packs" do
      rendered = render("verify")

      expect(rendered).to include("step" => "verify", "packs" => %w[play/binding play/review], "gate" => nil)
      expect(rendered["text"]).to include("Verify it.", "Work on X-1")
    end

    it "writes nothing and touches no pane, run or lock" do
      render("plan")

      expect(Dir.exist?(runs_dir)).to be false
      expect(Dir.exist?(File.join(worktree, ".workflow"))).to be false
      expect(Dir.exist?(lock_dir)).to be false
      expect(panes.kicks).to eq([])
      expect(panes.bound).to eq({})
      expect(events).to eq([])
    end

    it "refuses an unknown step, listing the steps" do
      expect { render("nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_step")
        expect(e.details).to eq("workflow" => "flow", "step" => "nope", "steps" => %w[plan build verify])
      }
    end

    it "refuses a missing required input as a start does" do
      expect { render("plan", inputs: {}) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("input_required") }
    end

    it "refuses an input the workflow does not have, and one that misses its pattern" do
      expect { render("plan", inputs: {"task" => "x", "other" => "y"}) }.to raise_error(Workspace::UsageError, /no input "other"/)
      patterned = definition("inputs:\n  task: {required: true, pattern: '[A-Z]+-[0-9]+'}\nsteps:\n  a:\n    prompt: Do {{inputs.task}}.\n")
      expect { render("a", inputs: {"task" => "nope"}, flow: patterned) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_input") }
    end

    it "passes the composer's refusal of a pack it can't read" do
      ghost = definition("steps:\n  a:\n    prompt: P\n    include: [ghost]\n")

      expect { render("a", inputs: {}, flow: ghost) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
    end
  end

  describe "#check_plan" do
    def plan_for(step, flow: three_steps)
      engine.check_plan(definition: flow, step: step, worktree: worktree)
    end

    it "gives the project's command, the step's timeout as whole seconds and HEAD, and writes nothing" do
      expect(plan_for("verify")).to include("workflow" => "flow", "step" => "verify", "command" => "bundle exec rspec", "timeout" => 300,
        "base_sha" => "1" * 40, "run" => "wr_preview")
      expect(plan_for("verify")["timeout"]).to be_an(Integer)
      expect(Dir.exist?(runs_dir)).to be false
      expect(Dir.exist?(File.join(worktree, ".workflow"))).to be false
      expect(Dir.exist?(lock_dir)).to be false
      expect(events).to eq([])
    end

    it "uses a run: command as it is, with the default timeout, and needs no input" do
      flow = definition("inputs:\n  task: {required: true}\nsteps:\n  a:\n    prompt: P\n    status: {run: 'test -f x'}\n")

      expect(plan_for("a", flow: flow)).to include("command" => "test -f x", "timeout" => Workspace::WorkflowDefinition::DEFAULT_CHECK_TIMEOUT)
    end

    it "reads the command for the project the lineage names, as a run does, not for the workspace given" do
      asked = []
      allow(commands_config).to receive(:for_project) { |name| asked << name && commands }
      flow = definition("steps:\n  a:\n    prompt: P\n    produces: [a.md]\n    status: {command: test}\n")
      plan_for("a", flow: flow)
      checked = asked.dup
      asked.clear
      start(flow, inputs: {})

      expect(checked).to eq(["app"])
      expect(asked.uniq).to eq(checked)
    end

    it "is not in a checkout inside the .git directory" do
      allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app", git_common_dir: File.join(worktree, ".git")))
      flow = definition("steps:\n  a:\n    prompt: P\n    status: {run: 'true'}\n")
      inside = engine.check_plan(definition: flow, step: "a", worktree: File.join(worktree, ".git", "hooks"))

      expect(inside["in_checkout"]).to be false
      expect(plan_for("a", flow: flow)["in_checkout"]).to be true
    end

    it "refuses a step with no status and an unknown step" do
      expect { plan_for("plan") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("step_without_status") }
      expect { plan_for("nope") }.to raise_error(Workspace::Error) { |e| expect([e.code, e.details["steps"]]).to eq(["unknown_step", %w[plan build verify]]) }
    end

    it "refuses an unset project command with start's details" do
      lint = definition("steps:\n  a:\n    prompt: P\n    status: {command: lint}\n")

      expect { plan_for("a", flow: lint) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("workflow_command_unset")
        expect(e.details["steps"]).to eq([{"step" => "a", "command" => "lint", "via" => "status"}])
      }
    end

    it "prints a --name command with a placeholder that fails if pasted only when the lineage project is a workspace that exists" do
      lint = definition("steps:\n  a:\n    prompt: P\n    status: {command: lint}\n")
      asked = []
      known = ->(name) { (asked << name) && true }
      named = engine_with(workspace_known: known)

      expect { named.check_plan(definition: lint, step: "a", worktree: worktree) }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to include('workspace config set commands.lint "<lint command>" --name app')
      }
      expect(asked).to eq(["app"])
      expect { plan_for("a", flow: lint) }.to raise_error(Workspace::Error) { |e|
        expect(e.message).to include("Set commands.lint in this project's workspace.")
        expect(e.message).not_to include("--name")
        expect(e.message).not_to include("workspace add")
      }
    end
  end

  describe "waiting for a lock" do
    let(:locked) { definition("steps:\n  verify:\n    prompt: P\n    uses: [test-db]\n") }

    before do
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      now[0] += 10
    end

    it "queues the run behind the holder, types nothing, and says who it waits for" do
      run = start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")

      expect(run["state"]).to eq("waiting")
      expect(run["steps"]["verify"]).to eq("state" => "waiting", "attempts" => [])
      expect(run["reason"]).to eq("code" => "waiting_lock", "since" => "2026-10-04T12:00:10Z", "details" => {
        "resource" => "test-db", "step" => "verify", "position" => 1, "total" => 2,
        "holder" => {"run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-a", "worktree" => "#{worktree}-5-app.worktree-a", "kind" => "run"}
      })
      expect(panes.kicks.size).to eq(1)
      expect(events.last(2).map(&:first)).to eq(%w[lock_wait_started workflow_changed])
      expect(events[-2]).to eq(["lock_wait_started", "app", {"lock" => "test-db", "run_id" => "wr_2", "step" => "verify",
                                                             "workspace" => "app.worktree-b", "position" => 1,
                                                             "holder" => {"pane" => "%5", "worktree" => "#{worktree}-5-app.worktree-a", "run_id" => "wr_1", "step" => "verify"}}])
    end

    it "does nothing on a tick while the lock is still held, and records the wait once" do
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
      events.clear
      now[0] += 5

      run = engine.tick("wr_2")

      expect(run["reason"]).to include("code" => "waiting_lock", "since" => "2026-10-04T12:00:10Z")
      expect(events).to eq([])
    end

    it "starts the step on the tick after the lock is free, and records how long it waited" do
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
      engine.cancel("wr_1")
      events.clear
      now[0] += 30

      run = engine.tick("wr_2")

      expect(run).to include("state" => "running", "reason" => nil)
      expect(lock_holder("test-db")).to include("run_id" => "wr_2")
      expect(panes.kicks.last).to include(pane: "%6")
      expect(events.first).to eq(["lock_acquired", "app", {"lock" => "test-db", "run_id" => "wr_2", "step" => "verify",
                                                           "workspace" => "app.worktree-b", "waited_seconds" => 30}])
    end

    it "says who holds the lock when it is an agent, by pid" do
      engine.cancel("wr_1")
      Workspace::LockStore.new(dir: lock_dir, liveness: liveness, clock: -> { now.first.to_i })
        .acquire("test-db", identity: {kind: "agent", pid: 4242, started: "start-4242", worktree: "/src/other", pane: "%2"}, waiter_pid: 4242, waiter_started: "start-4242")

      run = start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")

      expect(run["reason"]["details"]["holder"]).to eq("worktree" => "/src/other", "pid" => 4242, "kind" => "agent")
    end

    it "does nothing on a tick for a run that waits for nothing" do
      expect(engine.tick("wr_1")).to be_nil
    end
  end

  describe "a lock given up while the run's dev environment still runs" do
    it "has that environment stopped, so nobody queues behind one no step uses" do
      two = definition("steps:\n  a:\n    prompt: P\n    uses: [devenv]\n  b:\n    prompt: P\n")
      start(two, inputs: {})
      Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
        .delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 500, started: "start-500", pgid: 500})

      engine.turn_ended("wr_1")

      expect(stopped).to eq([{run_id: "wr_1", worktree: worktree}])
      expect(lock_holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "starts the next step all the same when the environment can't be stopped" do
      failing = engine_with(env_stopper: ->(**) { raise Workspace::Error, "Could not read the lock store" })
      two = definition("steps:\n  a:\n    prompt: P\n    uses: [devenv]\n  b:\n    prompt: P\n")
      failing.start(definition: two, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
        .delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 500, started: "start-500", pgid: 500})

      run = failing.turn_ended("wr_1")

      expect(run).to include("current" => "b", "state" => "running", "reason" => nil)
      expect(panes.kicks.size).to eq(2)
    end
  end

  describe "a step's line typed outside the run's lock" do
    it "stores the attempt as running and delivering before the line is typed, and clears the mark once it is" do
      seen = nil
      allow(panes).to receive(:kick) do |**args|
        seen = store.find("wr_1")
        panes.kicks << args
        {ok: true}
      end

      run = start

      expect(seen).to include("state" => "running", "reason" => nil)
      expect(seen["steps"]["plan"]).to include("state" => "running")
      expect(seen["steps"]["plan"]["attempts"].last).to include("n" => 1, "delivery" => "delivering")
      expect(run["steps"]["plan"]["attempts"].last).not_to have_key("delivery")
      expect(panes.bound["%5"]).to include(run_id: "wr_1", step: "plan", attempt: 1)
    end

    it "leaves a running attempt when the process dies while the daemon answers, which a turn's end then decides" do
      panes.kick_error = Interrupt
      expect { start }.to raise_error(Interrupt)
      left = store.find("wr_1")
      expect(left).to include("state" => "running", "reason" => nil)
      expect(left["steps"]["plan"]["attempts"].last).to include("n" => 1, "delivery" => "delivering")

      artifact("plan.md")
      run = engine.turn_ended("wr_1", pane: "%5", turn_started: now.first + 5)

      expect(run["steps"]["plan"]).to include("state" => "passed")
      expect(run["steps"]["plan"]["attempts"].last).to include("outcome" => "passed").and(satisfy { |attempt| !attempt.key?("delivery") })
      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("kind" => "gate")
    end

    it "does not type the line again for a resume while another process is still delivering it" do
      resumed = nil
      allow(panes).to receive(:kick) do |**args|
        panes.kicks << args
        resumed = engine.resume("wr_1", turn_over: {"step" => "plan", "attempt" => 1})
        {ok: true}
      end

      start

      expect(panes.kicks.size).to eq(1)
      expect(resumed["unchanged"]).to eq("step plan's line is still being delivered to pane %5")
      expect(store.find("wr_1")["steps"]["plan"]["attempts"].size).to eq(1)
    end

    it "decides a step left delivering past the delivery window when its pane's turn is over, without typing again" do
      panes.kick_error = Interrupt
      expect { start }.to raise_error(Interrupt)
      panes.kick_error = nil
      now[0] += Workspace::WorkflowEngine::DELIVERY_WINDOW + 1

      expect(engine.resume("wr_1")["unchanged"]).to eq("an agent is working on step plan")
      run = engine.resume("wr_1", turn_over: {"step" => "plan", "attempt" => 1})

      expect(panes.kicks).to be_empty
      expect(run["reason"]).to include("code" => "turn_ended_incomplete")
      expect(run["steps"]["plan"]["attempts"].last).not_to have_key("delivery")
    end

    it "types the line again in a new attempt only when asked to, with --from" do
      panes.kick_error = Interrupt
      expect { start }.to raise_error(Interrupt)
      panes.kick_error = nil

      run = engine.resume("wr_1", from: "plan")

      expect(panes.kicks.size).to eq(1)
      expect(run["steps"]["plan"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
      expect(run["steps"]["plan"]["attempts"].last).not_to have_key("delivery")
    end

    it "lets a cancel made while the line is on its way stand" do
      allow(panes).to receive(:kick) do |**args|
        panes.kicks << args
        engine.cancel("wr_1")
        {ok: false, code: "not_delivered", message: "nope"}
      end

      run = start

      expect(run).to include("state" => "cancelled", "cancelled_by" => "cancel")
      expect(panes.bound).to be_empty
      expect(history).to include("run_cancelled", "step_dispatched")
    end

    it "changes nothing when the answer comes for an attempt a turn's end already settled" do
      allow(panes).to receive(:kick) do |**args|
        panes.kicks << args
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")
        {ok: false, code: "connection_failed", message: "late"}
      end

      run = start

      expect(run["steps"]["plan"]).to include("state" => "passed")
      expect(run["reason"]["details"]).to include("kind" => "gate")
    end

    it "makes the run wait with the error when the line could not be typed" do
      panes.kick_result = {ok: false, code: "pane_busy", message: "the agent in pane %5 is in the middle of a turn"}

      run = start

      expect(run).to include("state" => "waiting")
      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "pane_busy", "message" => "the agent in pane %5 is in the middle of a turn")
      expect(run["steps"]["plan"]).to include("state" => "waiting")
      expect(run["steps"]["plan"]["attempts"].last).to include("outcome" => "not_delivered").and(satisfy { |attempt| !attempt.key?("delivery") })
      expect(history.last(2)).to eq(%w[step_dispatching step_dispatched])
    end

    it "records the daemon's answer once, with whether the line landed" do
      panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
      start
      panes.kick_result = {ok: true}
      engine.resume("wr_1")

      dispatched = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |each| each["type"] == "step_dispatched" }
      expect(dispatched.map { |each| each.slice("attempt", "delivered") }).to eq([{"attempt" => 1, "delivered" => false}, {"attempt" => 2, "delivered" => true}])
    end

    it "delivers the next step's line outside the lock when a gate is approved" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      seen = nil
      allow(panes).to receive(:kick) do |**args|
        seen = store.find("wr_1")
        {ok: true}
      end

      run = engine.approve("wr_1")

      expect(seen["current"]).to eq("build")
      expect(seen["steps"]["build"]["attempts"].last).to include("delivery" => "delivering")
      expect(run["steps"]["build"]["attempts"].last).not_to have_key("delivery")
      expect(run).to include("state" => "running", "reason" => nil)
    end

    it "makes the run wait, never leaving the mark, when the kick raises something unexpected" do
      allow(panes).to receive(:kick).and_raise(IOError, "closed stream")

      run = start

      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "error", "message" => "closed stream")
      expect(run["steps"]["plan"]["attempts"].last).not_to have_key("delivery")
    end

    it "makes the run wait with the error when the kick raises" do
      allow(panes).to receive(:kick).and_raise(Workspace::Error.new("socket gone", code: "no_daemon"))

      run = start

      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "no_daemon", "message" => "socket gone")
    end
  end

  describe "#turn_ended" do
    it "leaves the step when a file it produces is missing, and says which" do
      start
      now[0] += 60

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["state"]).to eq("waiting")
      expect(run["steps"]["plan"]["state"]).to eq("running")
      expect(run["reason"]).to eq("code" => "turn_ended_incomplete", "since" => "2026-10-04T12:01:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "missing" => [File.join(worktree, ".workflow", "wr_1", "plan.md")], "stale" => []})
      expect(panes.kicks.size).to eq(1)
    end

    it "passes the step at a later turn's end, once the file is there" do
      start
      engine.turn_ended("wr_1", pane: "%5")
      artifact("plan.md")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["steps"]["plan"]).to include("state" => "passed")
      expect(run["steps"]["plan"]["attempts"].last).to include("outcome" => "passed")
    end

    it "ignores a turn that ended in a pane the run is not bound to" do
      start
      artifact("plan.md")

      expect(engine.turn_ended("wr_1", pane: "%9")["steps"]["plan"]["state"]).to eq("running")
    end

    it "ignores a turn that ends while the run waits at a gate" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      events.clear

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]["details"]["kind"]).to eq("gate")
      expect(events).to eq([])
      expect(history.count("step_passed")).to eq(1)
      expect(history.count("gate_waiting")).to eq(1)
    end

    describe "told when the turn that ended began" do
      # The bare `build` step of three_steps: nothing but the turn's end decides it.
      before do
        to_build
        now[0] += 30
      end

      it "ignores the end of a turn that was already under way when the step's line was typed" do
        before = history

        run = engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 11, 59, 59, 999_000))

        expect(run).to include("current" => "build", "state" => "running", "reason" => nil)
        expect(run["steps"]["build"]["state"]).to eq("running")
        expect(panes.kicks.size).to eq(2)
        expect(history).to eq(before)
      end

      it "counts the end of a turn that began when the step's attempt did, or after" do
        started = Time.iso8601(store.find("wr_1")["steps"]["build"]["attempts"].last["started_at"])

        expect(engine.turn_ended("wr_1", pane: "%5", turn_started: started)["current"]).to eq("verify")
      end

      it "counts a turn's end the daemon names no start for, as a daemon from before the upgrade sends it" do
        expect(engine.turn_ended("wr_1", pane: "%5")["current"]).to eq("verify")
      end

      it "leaves a step whose own turn's end was dropped to `resume`, which decides it once the pane's agent is seen idle" do
        engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 11, 0, 0))
        expect(store.find("wr_1")).to include("state" => "running", "reason" => nil)

        run = engine.resume("wr_1", turn_over: {"step" => "build", "attempt" => 1})

        expect(run).to include("current" => "verify", "state" => "running")
      end
    end

    describe "a repeat of one stop" do
      let(:first_since) { "2026-10-04T12:01:00Z" }

      before do
        start
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5")
        events.clear
        now[0] += 60
      end

      it "keeps the reason's since and announces nothing when the daemon names no turn start" do
        before = store.find("wr_1")["reason"]

        engine.turn_ended("wr_1", pane: "%5")

        expect(store.find("wr_1")["reason"]).to eq(before)
        expect(before["since"]).to eq(first_since)
        expect(events).to eq([])
      end

      it "keeps the since when the turn began before the stop was recorded" do
        before = store.find("wr_1")["reason"]

        engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 12, 0, 30))
        engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 12, 1, 0, 500_000))

        expect(store.find("wr_1")["reason"]).to eq(before)
        expect(events).to eq([])
      end

      it "gives a stop after a later turn a since of its own" do
        engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 12, 1, 30))

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_incomplete", "since" => "2026-10-04T12:02:00Z")
        expect(events.map(&:first)).to eq(["workflow_changed"])
      end

      it "gives a new attempt a new since" do
        engine.resume("wr_1", from: "plan", pane: "%5")
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5")

        expect(store.find("wr_1")["reason"]).to include("since" => "2026-10-04T12:03:00Z")
        expect(store.find("wr_1")["reason"]["details"]["attempt"]).to eq(2)
      end

      it "gives a stop after a pane-less resume a new since" do
        engine.resume("wr_1")

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_incomplete", "since" => "2026-10-04T12:02:00Z")
      end

      it "stores a changed missing list and keeps the since" do
        File.utime(Time.utc(2026, 10, 4, 11, 0, 0), Time.utc(2026, 10, 4, 11, 0, 0), artifact("plan.md"))

        engine.turn_ended("wr_1", pane: "%5")

        reason = store.find("wr_1")["reason"]
        expect(reason["since"]).to eq(first_since)
        expect(reason["details"]).to include("missing" => [], "stale" => [File.join(worktree, ".workflow", "wr_1", "plan.md")])
      end
    end

    describe "a step with require:" do
      let(:flow) do
        definition(<<~YAML)
          steps:
            prep:
              prompt: Prepare.
            build:
              prompt: Build it.
              produces: [build.md]
              require:
                - commits: 1
                - tracked_clean: true
              status: {run: "true"}
              on_fail: {goto: prep, max: 1}
        YAML
      end
      let(:commit_counts) { [1] }

      before do
        allow(guard).to receive(:commits_since) { commit_counts.first }
        allow(guard).to receive(:dirty_paths).and_return([])
        allow(guard).to receive(:operation_in_progress?).and_return(false)
        start(flow, inputs: {})
        engine.turn_ended("wr_1", pane: "%5")
        artifact("build.md")
      end

      it "passes to the status check once every proof holds, counting from the attempt's recorded HEAD" do
        run = engine.turn_ended("wr_1", pane: "%5")

        expect(guard).to have_received(:commits_since).with(worktree, "1" * 40)
        expect(run["steps"]["build"]["state"]).to eq("passed")
        expect(check_calls.size).to eq(1)
      end

      it "fails the step as require_commits from the engine, sends it along on_fail and skips the status check" do
        commit_counts[0] = 0

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run).to include("current" => "prep", "loops" => {"build->prep" => 1})
        expect(run["steps"]["build"]["attempts"].last).to include("outcome" => "failed", "code" => "require_commits")
        expect(run["steps"]["prep"]["attempts"].last["context"].join).to include("a required proof failed (commits): required 1 commit since 1111111, found 0")
        expect(check_calls).to eq([])
      end

      it "keeps the failed attempt's code when the retry begins, and the retry has none" do
        commit_counts[0] = 0

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["steps"]["build"]["attempts"].last["code"]).to eq("require_commits")
        expect(run["steps"]["prep"]["attempts"].last).not_to have_key("code")
      end

      it "stops the run with the code, source and what was found when no loop is left" do
        store.update("wr_1") { |stored| stored["definition"]["steps"][1]["on_fail"] = nil }
        commit_counts[0] = 0

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["state"]).to eq("waiting")
        expect(run["reason"]["details"]).to include("code" => "require_commits", "code_source" => "engine", "cause" => "require", "require" => "commits",
          "required" => 1, "found" => 0, "detail" => "required 1 commit since 1111111, found 0")
      end

      it "fails as unproven when the attempt has no recorded starting commit" do
        store.update("wr_1") do |stored|
          stored["definition"]["steps"][1]["on_fail"] = nil
          stored["steps"]["build"]["attempts"].last.delete("head")
        end

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["reason"]["details"]).to include("code" => "require_commits", "unproven" => true)
        expect(guard).not_to have_received(:commits_since)
      end

      it "fails on a dirty tracked tree with the paths" do
        store.update("wr_1") { |stored| stored["definition"]["steps"][1]["on_fail"] = nil }
        allow(guard).to receive(:dirty_paths).and_return(["a.rb"])

        expect(engine.turn_ended("wr_1", pane: "%5")["reason"]["details"]).to include("code" => "require_tracked_clean", "paths" => ["a.rb"])
      end

      it "lets a reported failure win and checks no proof" do
        engine.report("wr_1", status: "fail", summary: "gave up")
        run = engine.turn_ended("wr_1", pane: "%5")

        expect(guard).not_to have_received(:commits_since)
        expect(run["steps"]["build"]["attempts"].last["outcome"]).to eq("failed")
      end

      it "holds on a missing produces file before looking at any proof" do
        FileUtils.rm(File.join(worktree, ".workflow", "wr_1", "build.md"))

        engine.turn_ended("wr_1", pane: "%5")

        expect(guard).not_to have_received(:commits_since)
      end

      it "does not apply to a run stored before require existed" do
        store.update("wr_1") { |stored| stored["definition"]["steps"][1].delete("require") }
        commit_counts[0] = 0

        engine.turn_ended("wr_1", pane: "%5")

        expect(guard).not_to have_received(:commits_since)
        expect(check_calls.size).to eq(1)
      end

      it "reserves the require codes so step done --code can't forge them" do
        expect(described_class::ENGINE_CODES).to include("require_commits", "require_nonempty", "require_plan_status", "require_tracked_clean", "require_command", "require_inbox_item", "require_remote_unchanged", "require_remote_unreachable", "require_exec")
      end
    end

    describe "a produces file that is not a non-empty regular file" do
      let(:plan) { File.join(worktree, ".workflow", "wr_1", "plan.md") }

      def invalid_details
        store.find("wr_1")["reason"]["details"]["invalid"]
      end

      before do
        start
        FileUtils.mkdir_p(File.dirname(plan))
        now[0] += 60
      end

      it "marks a new run strict in its stored definition" do
        expect(store.find("wr_1")["definition"]).to include("produces_check" => "strict")
      end

      it "holds the step on an empty file, naming the rule and the file" do
        File.write(plan, "")
        File.utime(now.first, now.first, plan)

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["steps"]["plan"]["state"]).to eq("running")
        expect(run["reason"]).to include("code" => "turn_ended_incomplete")
        expect(run["reason"]["details"]).to include("missing" => [], "stale" => [])
        expect(invalid_details).to eq([{"file" => plan, "rule" => "empty"}])
      end

      it "holds the step on a directory" do
        FileUtils.mkdir_p(plan)

        engine.turn_ended("wr_1", pane: "%5")

        expect(invalid_details).to eq([{"file" => plan, "rule" => "not_regular_file"}])
      end

      it "holds the step on a symlink to a real file, never following it" do
        target = File.join(worktree, "elsewhere.md")
        File.write(target, "content\n")
        File.symlink(target, plan)

        engine.turn_ended("wr_1", pane: "%5")

        expect(invalid_details).to eq([{"file" => plan, "rule" => "symlink"}])
      end

      it "holds the step on a dangling symlink as a link, not as missing" do
        File.symlink(File.join(worktree, "nowhere.md"), plan)

        engine.turn_ended("wr_1", pane: "%5")

        expect(invalid_details).to eq([{"file" => plan, "rule" => "symlink"}])
        expect(store.find("wr_1")["reason"]["details"]["missing"]).to eq([])
      end

      it "passes once the file is a regular file with content" do
        File.write(plan, "")
        engine.turn_ended("wr_1", pane: "%5")
        artifact("plan.md")

        expect(engine.turn_ended("wr_1", pane: "%5")["steps"]["plan"]["state"]).to eq("passed")
      end

      it "keeps the exists-only check for a run stored without the marker" do
        store.update("wr_1") { |run| run["definition"].delete("produces_check") }
        File.write(plan, "")
        File.utime(now.first, now.first, plan)

        expect(engine.turn_ended("wr_1", pane: "%5")["steps"]["plan"]["state"]).to eq("passed")
      end

      it "keeps invalid in the turn_ended_incomplete stop a background hold expires into" do
        File.write(plan, "")
        tasks = [{"id" => "b1a2c3d4e", "type" => "shell"}]
        engine.turn_ended("wr_1", pane: "%5", background: tasks)
        expect(store.find("wr_1")["reason"]["code"]).to eq("turn_ended_background")
        now[0] += 91 * 60

        run = engine.tick("wr_1")

        expect(run["reason"]["code"]).to eq("turn_ended_incomplete")
        expect(run["reason"]["details"]).to include("invalid" => [{"file" => plan, "rule" => "empty"}], "background_tasks" => tasks)
      end

      it "lists a missing, a stale and an invalid file once each, in the right list" do
        store.update("wr_1") { |run| run["definition"]["steps"].find { |step| step["id"] == "plan" }["produces"] = %w[missing.md stale.md empty.md link.md] }
        dir = File.join(worktree, ".workflow", "wr_1")
        FileUtils.mkdir_p(dir)
        old = Time.utc(2026, 10, 4, 11, 0, 0)
        File.write(File.join(dir, "stale.md"), "old\n")
        File.write(File.join(dir, "empty.md"), "")
        File.symlink(File.join(dir, "stale.md"), File.join(dir, "link.md"))
        [File.join(dir, "stale.md"), File.join(dir, "empty.md")].each { |file| File.utime(old, old, file) }

        details = engine.turn_ended("wr_1", pane: "%5")["reason"]["details"]

        expect(details["missing"]).to eq([File.join(dir, "missing.md")])
        expect(details["stale"]).to eq([File.join(dir, "stale.md")])
        expect(details["invalid"]).to eq([{"file" => File.join(dir, "empty.md"), "rule" => "empty"}, {"file" => File.join(dir, "link.md"), "rule" => "symlink"}])
      end
    end

    describe "a turn that ended with background tasks listed" do
      let(:tasks) { [{"id" => "b1a2c3d4e", "type" => "shell"}, {"id" => "k12345678", "type" => "subagent"}] }

      before do
        start
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", background: tasks)
      end

      it "holds the step as turn_ended_background with the tasks and when they were seen" do
        expect(store.find("wr_1")["reason"]).to eq("code" => "turn_ended_background", "since" => "2026-10-04T12:01:00Z", "seen_at" => "2026-10-04T12:01:00Z",
          "details" => {"step" => "plan", "attempt" => 1, "missing" => [File.join(worktree, ".workflow", "wr_1", "plan.md")], "stale" => [], "tasks" => tasks})
        expect(store.find("wr_1")["state"]).to eq("waiting")
      end

      it "announces one workflow_changed across three Stops that list the same tasks" do
        events.clear
        2.times do
          now[0] += 60
          engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: tasks)
        end

        reason = store.find("wr_1")["reason"]
        expect(reason).to include("since" => "2026-10-04T12:01:00Z", "seen_at" => "2026-10-04T12:03:00Z")
        expect(events).to eq([])
      end

      it "announces one workflow_changed across Stops whose task lists shrink and reorder" do
        events.clear
        [[tasks.last], [tasks.last, tasks.first], tasks].each do |listed|
          now[0] += 60
          engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: listed)
        end

        expect(store.find("wr_1")["reason"]["details"]["tasks"]).to eq(tasks)
        expect(events).to eq([])
      end

      it "fires no event when the missing list of a hold changes" do
        store.update("wr_1") { |run| run["reason"]["details"]["missing"] = [] }
        events.clear
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: tasks)

        expect(store.find("wr_1")["reason"]["details"]["missing"]).not_to eq([])
        expect(events).to eq([])
      end

      it "announces a hold as running with the turn_ended_background reason" do
        events.clear
        store.update("wr_1") { |run| run["reason"] = nil }
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: tasks)

        expect(events.map(&:last)).to include(a_hash_including("state" => "running", "reason" => "turn_ended_background"))
        expect(store.find("wr_1")["state"]).to eq("waiting")
      end

      it "drops the hold on a pane-less resume and re-evaluates with nothing listed" do
        engine.resume("wr_1")

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_incomplete")
      end

      it "shows turn_ended_incomplete once, with a since of its own, on a Stop with no tasks" do
        events.clear
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", background: [])
        engine.turn_ended("wr_1", pane: "%5", background: [])

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_incomplete", "since" => "2026-10-04T12:02:00Z")
        expect(events.map(&:first).count("workflow_changed")).to eq(1)
      end

      describe "from a recorded Stop payload, through the hook boundary and the CLI's flags" do
        def background_from(payload)
          env = {"TMUX_PANE" => "%5"}
          sent = nil
          server_path = File.join(@dir, "agent.sock")
          server = UNIXServer.new(server_path)
          config = instance_double(Workspace::Config, agent_socket_path: server_path)
          tmux = instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_layout: nil, server_pid_for_pane: nil)
          listener = Thread.new do
            client = server.accept
            sent = JSON.parse(client.gets)
            client.puts(JSON.generate("ok" => true))
            client.close
          end
          Workspace::Commands::SessionEvent.new(config: config, tmux: tmux, input: StringIO.new(JSON.generate(payload)), env: env).call(workspace: nil, agent: nil)
          listener.join(2)
          sent["background_tasks"]
        ensure
          server&.close
        end

        let(:stop) do
          {"hook_event_name" => "Stop", "session_id" => "s1", "cwd" => "/x", "background_tasks" => [
            {"id" => "b1a2c3d4e", "type" => "shell", "description" => "dev server", "command" => "bin/dev"},
            {"id" => "k12345678", "type" => "subagent", "description" => "reviewer"},
            {"id" => "d1", "type" => "dream"}
          ]}
        end

        it "holds across several turn ends with no reason shown" do
          background = background_from(stop)
          expect(background).to eq([{"id" => "b1a2c3d4e", "type" => "shell"}, {"id" => "k12345678", "type" => "subagent"}])

          3.times do
            now[0] += 60
            engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: background)
          end

          expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_background", "since" => "2026-10-04T12:01:00Z")
          expect(store.find("wr_1")["reason"]["details"]["tasks"]).to eq(background)
        end

        it "shows turn_ended_incomplete when the Stop lists an empty array" do
          background = background_from(stop.merge("background_tasks" => []))
          engine.turn_ended("wr_1", pane: "%5", background: background)

          expect(background).to eq([])
          expect(store.find("wr_1")["reason"]["code"]).to eq("turn_ended_incomplete")
        end
      end

      it "keeps the since when the turn began after it" do
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", turn_started: Time.utc(2026, 10, 4, 12, 1, 30), background: tasks)

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_background", "since" => "2026-10-04T12:01:00Z")
      end

      it "leaves a hold 89 minutes old alone" do
        now[0] += 88 * 60

        expect(engine.tick("wr_1")).to be_nil
        expect(store.find("wr_1")["reason"]["code"]).to eq("turn_ended_background")
      end

      it "turns a hold 91 minutes old into a turn_ended_incomplete stop that shows, with the tasks" do
        now[0] += 91 * 60
        run = engine.tick("wr_1")

        expect(run["reason"]).to eq("code" => "turn_ended_incomplete", "since" => "2026-10-04T13:32:00Z",
          "details" => {"step" => "plan", "attempt" => 1, "missing" => [File.join(worktree, ".workflow", "wr_1", "plan.md")], "stale" => [], "background_tasks" => tasks})
        expect(run["state"]).to eq("waiting")
        expect(run["steps"]["plan"]["state"]).to eq("running")
        expect(events.map(&:first)).to include("workflow_changed")
      end

      it "expires a hold whose seen_at can't be read" do
        store.update("wr_1") { |run| run["reason"]["seen_at"] = "t" }

        expect(engine.tick("wr_1")["reason"]["code"]).to eq("turn_ended_incomplete")
      end

      it "pushes the expiry out when a Stop at minute 80 lists tasks again" do
        now[0] += 79 * 60
        engine.turn_ended("wr_1", pane: "%5", turn_started: now[0] - 10, background: tasks)
        now[0] += 11 * 60

        expect(engine.tick("wr_1")).to be_nil
        expect(store.find("wr_1")["reason"]["code"]).to eq("turn_ended_background")

        now[0] += 80 * 60
        expect(engine.tick("wr_1")["reason"]["code"]).to eq("turn_ended_incomplete")
      end

      it "holds again, with the reason hidden, on a Stop that lists tasks after expiry" do
        now[0] += 91 * 60
        engine.tick("wr_1")
        now[0] += 60
        engine.turn_ended("wr_1", pane: "%5", background: tasks)

        expect(store.find("wr_1")["reason"]).to include("code" => "turn_ended_background", "since" => "2026-10-04T13:33:00Z")
      end

      it "passes the step when its files exist, whatever is listed" do
        artifact("plan.md")
        now[0] += 60
        run = engine.turn_ended("wr_1", pane: "%5", background: tasks)

        expect(run["steps"]["plan"]["state"]).to eq("passed")
        expect(run["reason"]).not_to include("code" => "turn_ended_background")
      end

      it "fails the step on a reported fail, whatever is listed" do
        engine.report("wr_1", status: "fail", summary: "no")
        run = engine.turn_ended("wr_1", pane: "%5", background: tasks)

        expect(run["reason"]).not_to include("code" => "turn_ended_background")
      end
    end

    it "ignores a turn that ends while the run waits for a lock" do
      locked = definition("steps:\n  verify:\n    prompt: P\n    uses: [test-db]\n")
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")

      run = engine.turn_ended("wr_2", pane: "%6")

      expect(run["reason"]["code"]).to eq("waiting_lock")
      expect(run["steps"]["verify"]).to eq("state" => "waiting", "attempts" => [])
    end

    it "keeps the step's locks while it waits for a file the turn did not leave" do
      holding = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n    produces: [a.md]\n")
      start(holding, inputs: {})

      run = engine.turn_ended("wr_1")

      expect(run["reason"]["code"]).to eq("turn_ended_incomplete")
      expect(lock_holder("test-db")).to include("run_id" => "wr_1")
    end

    it "does not count a file an earlier attempt left: the step has to write it again" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 60
      engine.reject("wr_1", note: "Too big; split it.")
      plan = File.join(worktree, ".workflow", "wr_1", "plan.md")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]).to include("code" => "turn_ended_incomplete")
      expect(run["reason"]["details"]).to include("attempt" => 2, "missing" => [], "stale" => [plan])
      expect(File.read(run["steps"]["plan"]["attempts"].last["prompt_file"])).to include("written during this attempt")

      artifact("plan.md")
      expect(engine.turn_ended("wr_1", pane: "%5")["steps"]["plan"]).to include("state" => "passed")
    end

    it "takes the next step's resources before typing its line, and continues the conversation when the step says so" do
      to_build

      expect(lock_holder("test-db")).to include("kind" => "run", "run_id" => "wr_1", "step" => "build", "workflow" => "flow",
        "workspace" => "app.worktree-x", "pane" => "%5")
      expect(panes.kicks.last).to include(fresh: false, text: "Read #{File.join(worktree, ".workflow", "wr_1", "steps", "build.1.prompt.md")} and follow it.")
      expect(panes.bound["%5"]).to include(step: "build", attempt: 1)
    end
  end
end
