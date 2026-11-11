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
end
