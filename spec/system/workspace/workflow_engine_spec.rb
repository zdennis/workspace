require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"
require "socket"

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
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  # Recording a base takes about a dozen git calls, which only the examples about the guard and
  # base_sha need; the rest get a base that does not look at the checkout.
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
  subject(:engine) do
    described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note,
      env_stopper: ->(**args) { stopped << args }, workspace_known: workspace_known, event_log: event_log, task_store: task_store, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    RepoTemplate.copy(:workflow_engine_app, to: worktree) do |root|
      system("git", "-C", root, "init", "-q", "-b", "feature/x", exception: true)
      system("git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
    end
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
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
    described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note,
      clock: -> { now.first }, **overrides)
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

  describe "#start" do
    it "keeps its files out of `git status`, in a real repository" do
      start

      status, = Open3.capture2("git", "-C", worktree, "status", "--porcelain")
      expect(status).to eq("")
      expect(File.read(File.join(worktree, ".git", "info", "exclude")).lines.map(&:chomp)).to include("/.workflow/")
    end
  end

  it "keeps the reason a busy pane gave in the run's reason details" do
    panes.kick_result = {ok: false, code: "pane_busy", message: "pane %5 kept changing", reason: "background_activity"}

    expect(start["reason"]["details"]).to include("error" => "pane_busy", "reason" => "background_activity")
  end

  it "keeps what a moving screen lacked in the reason's details and the dispatch event" do
    panes.kick_result = {ok: false, code: "pane_busy", message: "kept changing", reason: "background_activity", proof_missing: "main_tool_after_stop"}

    run = start

    expect(run["reason"]["details"]).to include("proof_missing" => "main_tool_after_stop")
    event = File.readlines(store.events_path(run["id"])).map { |line| JSON.parse(line) }.find { |e| e["type"] == "step_dispatched" }
    expect(event).to include("delivered" => false, "proof_missing" => "main_tool_after_stop")
  end

  it "puts a delivery's warning in the dispatch event" do
    panes.kick_result = {ok: true, warning: "background work may be lost"}

    run = start

    event = File.readlines(store.events_path(run["id"])).map { |line| JSON.parse(line) }.find { |e| e["type"] == "step_dispatched" }
    expect(event).to include("delivered" => true, "warning" => "background work may be lost")
  end

  it "puts the warning of a /clear typed over a running sub-agent in the dispatch event" do
    text = "a sub-agent was still running in pane %5 when /clear was typed and may be lost; fake unverified"
    panes.kick_result = {ok: true, warning: text}

    run = start

    event = File.readlines(store.events_path(run["id"])).map { |line| JSON.parse(line) }.find { |e| e["type"] == "step_dispatched" }
    expect(event).to include("delivered" => true, "warning" => text)
  end

  it "reads as waiting on a person when a prompt is unconfirmed" do
    panes.kick_result = {ok: false, code: "not_delivered", message: "may still be in the input box", reason: "prompt_unconfirmed"}

    run = start

    expect(run["reason"]).to include("code" => "waiting_you")
    expect(run["reason"]["details"]).to include("reason" => "prompt_unconfirmed")
  end

  describe "#turn_ended" do
    context "with the real guard" do
      let(:guard) { Workspace::WorkflowGuard.new }

      it "records the checkout's HEAD as base_sha when the run starts" do
        run = start

        expect(run["base_sha"]).to eq(`git -C #{worktree} rev-parse HEAD`.strip)
        expect(store.find("wr_1")["base_sha"]).to eq(run["base_sha"])
      end

      it "runs the step's check with the project's command while the step is `checking`, outside the run's lock" do
        to_verify
        events.clear

        run = engine.turn_ended("wr_1", pane: "%5")

        log = File.join(worktree, ".workflow", "wr_1", "steps", "verify.1.check.log")
        env = ENV.keys.grep(/\AGIT_/).to_h { |name| [name, nil] }.merge("WORKSPACE_RUN_ID" => "wr_1", "WORKSPACE_RUN_ARTIFACTS" => File.join(worktree, ".workflow", "wr_1"),
          "WORKSPACE_RUN_BASE_SHA" => `git -C #{worktree} rev-parse HEAD`.strip)
        expect(check_calls).to eq([{command: "bundle exec rspec", cwd: worktree, timeout: 300.0, log: log, env: env, state_during: "checking"}])
        expect(run["steps"]["verify"]["attempts"].last["check"]).to eq("started_at" => "2026-10-04T12:00:00Z", "log" => log, "command" => "bundle exec rspec",
          "ended_at" => "2026-10-04T12:00:00Z", "exit_code" => 0, "timed_out" => false)
      end
    end

    it "gives a check an empty WORKSPACE_RUN_BASE_SHA for a run made before base_sha was kept" do
      to_verify
      store.update("wr_1") { |stored| stored.delete("base_sha") }

      engine.turn_ended("wr_1", pane: "%5")

      expect(check_calls.last[:env]).to include("WORKSPACE_RUN_BASE_SHA" => "")
    end

    it "completes the run when its last step passes: locks released, pane freed, run archived" do
      to_verify
      events.clear

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "completed", "reason" => nil, "ended_at" => "2026-10-04T12:00:00Z")
      expect(lock_holder("test-db")).to be_nil
      expect(panes.bound).to eq({})
      expect(Dir.children(runs_dir)).to eq([])
      expect(store.find("wr_1")["state"]).to eq("completed")
      expect(events.map(&:first)).to eq(%w[workflow_changed lock_released workflow_changed])
      expect(events[1]).to eq(["lock_released", "app", {"lock" => "test-db", "run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-x"}])
      expect(history.last(3)).to eq(%w[check_finished step_passed run_completed])
    end

    it "keeps a lock both steps use, from one step to the next" do
      to_build
      events.clear

      engine.turn_ended("wr_1", pane: "%5")

      expect(lock_holder("test-db")).to include("run_id" => "wr_1", "step" => "verify")
      expect(events.map(&:first)).not_to include("lock_released", "lock_acquired")
    end

    it "sends a step whose check fails back along on_fail, with what failed in the next attempt's instructions" do
      to_verify
      check_results << {exit_code: 1, timed_out: false}

      run = engine.turn_ended("wr_1", pane: "%5")

      log = File.join(worktree, ".workflow", "wr_1", "steps", "verify.1.check.log")
      expect(run).to include("state" => "running", "current" => "build", "loops" => {"verify->build" => 1}, "reason" => nil)
      expect(run["steps"]["verify"]).to include("state" => "failed")
      expect(run["steps"]["build"]["attempts"].last).to include("n" => 2, "context" => [
        "The verify step failed and sent the run back to this step (time 1 of 2): its check exited 1 (log: #{log}). " \
        "Its files are in #{File.join(worktree, ".workflow", "wr_1")}. Fix what it found."
      ])
      # build says `context: continue`; the jump's own `context: fresh` wins.
      expect(panes.kicks.last).to include(fresh: true)
      expect(history.last(5)).to eq(%w[check_finished step_failed step_looped step_dispatching step_dispatched])
    end

    it "delivers a retry as its own attempt: the prompt file and the binding carry the attempt number" do
      to_verify
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")

      second = File.join(worktree, ".workflow", "wr_1", "steps", "build.2.prompt.md")
      expect(File.exist?(second)).to be true
      expect(File.exist?(File.join(worktree, ".workflow", "wr_1", "steps", "build.1.prompt.md"))).to be true
      expect(composer.calls.last[:binding]).to include("step" => "build", "attempt" => 2, "instructions" => second)
      expect(panes.bound["%5"]).to include(step: "build", attempt: 2, instructions: second)
      expect(panes.kicks.last[:text]).to eq("Read #{second} and follow it.")
    end

    it "stops the run for a person once the loops are spent, holding nothing, with the check's log" do
      to_verify
      3.times { check_results << {exit_code: 2, timed_out: false} }
      2.times do
        engine.turn_ended("wr_1", pane: "%5")
        engine.turn_ended("wr_1", pane: "%5")
      end

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting", "current" => "verify")
      expect(run["reason"]["code"]).to eq("failed_check")
      expect(run["reason"]["details"]).to eq("step" => "verify", "attempt" => 3, "loops" => {"verify->build" => 2}, "attempts" => 7,
        "max_attempts" => 6, "cause" => "check", "exit_code" => 2, "timed_out" => false, "code" => "check_failed", "code_source" => "engine",
        "log" => File.join(worktree, ".workflow", "wr_1", "steps", "verify.3.check.log"))
      expect(lock_holder("test-db")).to be_nil
      expect(panes.bound["%5"]).to include(step: "verify", attempt: 3)
    end

    it "stops looping when the run has used its attempts, though loops are left" do
      capped = definition(<<~YAML)
        max_attempts: 3
        steps:
          build: {prompt: Build.}
          verify:
            prompt: Verify.
            status: bin/check
            on_fail: {goto: build, max: 5}
      YAML
      start(capped, inputs: {})
      2.times { check_results << {exit_code: 1, timed_out: false} }
      engine.turn_ended("wr_1")
      engine.turn_ended("wr_1")
      engine.turn_ended("wr_1")

      run = engine.turn_ended("wr_1")

      expect(check_calls.map { |call| call[:command] }).to eq(%w[bin/check bin/check])
      expect(run["reason"]).to include("code" => "failed_check")
      expect(run["reason"]["details"]).to include("loops" => {"verify->build" => 1}, "attempts" => 4, "max_attempts" => 3)
    end

    it "fails a step with no on_fail whose check exits non-zero, and waits for a person" do
      plain = definition("steps:\n  a:\n    prompt: P\n    status: bin/check\n")
      start(plain, inputs: {})
      check_results << {exit_code: 1, timed_out: false}

      run = engine.turn_ended("wr_1")

      expect(run).to include("state" => "waiting", "current" => "a")
      expect(run["reason"]["details"]).to include("cause" => "check", "exit_code" => 1, "code" => "check_failed", "code_source" => "engine")
    end

    describe "a failed check's report_code" do
      def tally_def(on_fail_text, status_body)
        definition(<<~YAML)
          steps:
            plan:
              prompt: Plan.
            tally:
              prompt: Tally.
              status:
          #{status_body}
          #{on_fail_text}
        YAML
      end

      def with_log(name, text)
        path = File.join(worktree, ".workflow", "wr_1", "steps", name)
        File.write(path, text)
        check_results << {exit_code: 1, timed_out: false}
        engine.turn_ended("wr_1")
      end

      it "takes the failure code from the log's last line when the step's status sets report_code, and loops on it" do
        start(tally_def("    on_fail: {goto: plan, max: 2}", "      report_code: true\n      run: bin/check\n"), inputs: {})
        engine.turn_ended("wr_1")

        run = with_log("tally.1.check.log", "the plan moved under the review\ncode: stale_plan_revision\n")

        expect(run["steps"]["tally"]["attempts"].last).to include("code" => "stale_plan_revision")
        expect(run).to include("state" => "running", "current" => "plan", "loops" => {"tally->plan" => 1})
      end

      it "ignores the log's last line when the step's status sets no report_code" do
        start(tally_def("    on_fail: {goto: plan, max: 2}", "      run: bin/check\n"), inputs: {})
        engine.turn_ended("wr_1")

        run = with_log("tally.1.check.log", "code: stale_plan_revision\n")

        expect(run["steps"]["tally"]["attempts"].last).to include("code" => "check_failed")
      end

      it "ignores a line that names a code the engine hands out itself, or no code at all" do
        start(tally_def("    on_fail: {goto: plan, max: 2}", "      report_code: true\n      run: bin/check\n"), inputs: {})
        engine.turn_ended("wr_1")

        reserved = with_log("tally.1.check.log", "code: check_error\n")

        expect(reserved["steps"]["tally"]["attempts"].last).to include("code" => "check_failed")
        engine.turn_ended("wr_1")

        absent = with_log("tally.1.check.log", "the check found nothing to name\n")

        expect(absent["steps"]["tally"]["attempts"].last).to include("code" => "check_failed")
      end

      it "stops instead of looping when the reported code is in on_fail's except, and counts no loop" do
        start(tally_def("    on_fail: {goto: plan, max: 2, except: [stale_plan_revision]}", "      report_code: true\n      run: bin/check\n"), inputs: {})
        engine.turn_ended("wr_1")

        run = with_log("tally.1.check.log", "code: stale_plan_revision\n")

        expect(run).to include("state" => "waiting", "current" => "tally", "loops" => {})
        expect(run["reason"]).to include("code" => "failed_check")
        expect(run["reason"]["details"]).to include("code" => "stale_plan_revision", "code_source" => "check")
      end
    end

    it "fails a step its agent reported failed, without running the check" do
      to_verify
      engine.report("wr_1", status: "fail", summary: "two specs still red")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(check_calls).to eq([])
      expect(run["current"]).to eq("build")
      expect(run["steps"]["build"]["attempts"].last["context"].first).to include("its agent reported failure: two specs still red")
    end

    it "fails a step with no way back and waits for a person" do
      plain = definition("steps:\n  a:\n    prompt: P\n    status: bin/check\n")
      start(plain, inputs: {})
      check_results << {exit_code: nil, timed_out: true}

      run = engine.turn_ended("wr_1")

      expect(run["reason"]["details"]).to include("cause" => "check", "timed_out" => true)
      expect(run["reason"]["details"]).not_to have_key("exit_code")
    end

    it "decides nothing, and does not raise, when the run was cancelled while its check ran" do
      to_verify
      cancelling = lambda do |**|
        engine.cancel("wr_1")
        {exit_code: 0, timed_out: false}
      end
      slow = described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: cancelling,
        commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, clock: -> { now.first })

      expect(slow.turn_ended("wr_1", pane: "%5")).to include("state" => "cancelled")
    end

    it "fails a step whose project lost its check command after the run started" do
      to_verify
      commands[:test] = nil

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(check_calls).to eq([])
      expect(run["current"]).to eq("build")
      expect(run["steps"]["build"]["attempts"].last["context"].first).to include("its check could not be run (the project's test command is not set)")
    end

    it "drops a check's result when the run moved on while it ran" do
      to_verify
      slow = lambda do |**|
        engine.resume("wr_1", from: "build")
        {exit_code: 0, timed_out: false}
      end
      moved = described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: slow,
        commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, clock: -> { now.first })

      run = moved.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "running", "current" => "build")
      expect(run["steps"]["verify"]["state"]).to eq("checking")
    end
  end

  describe "a gate" do
    before do
      start
      artifact("plan.md")
    end

    it "holds the run after the step passes, with what to read, until a person approves" do
      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting", "current" => "plan")
      expect(run["steps"]["plan"]).to include("state" => "passed", "gate" => {"state" => "waiting", "since" => "2026-10-04T12:00:00Z"})
      expect(run["reason"]).to eq("code" => "waiting_you", "since" => "2026-10-04T12:00:00Z",
        "details" => {"kind" => "gate", "step" => "plan", "artifacts" => [File.join(worktree, ".workflow", "wr_1", "plan.md")]})
      expect(panes.kicks.size).to eq(1)
      expect(history.last(2)).to eq(%w[step_passed gate_waiting])
    end

    it "gives up the step's locks while it waits at the gate" do
      gated = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n    gate: approve\n")
      engine.cancel("wr_1")
      start(gated, inputs: {})
      events.clear

      run = engine.turn_ended("wr_2")

      expect(run["reason"]["details"]).to include("kind" => "gate")
      expect(lock_holder("test-db")).to be_nil
      expect(events.map(&:first)).to eq(%w[lock_released workflow_changed])
    end

    it "goes on to the next step when approved, with the note in its instructions" do
      engine.turn_ended("wr_1", pane: "%5")

      run = engine.approve("wr_1", note: "Skip the migration.")

      expect(run).to include("state" => "running", "current" => "build", "reason" => nil)
      expect(run["steps"]["plan"]["gate"]).to include("state" => "approved", "note" => "Skip the migration.")
      expect(run["steps"]["build"]["attempts"].last["context"]).to eq(["The plan step was approved with this note: Skip the migration."])
      expect(history_lines.find { |line| line["type"] == "gate_approved" }).to include("step" => "plan", "note" => "Skip the migration.")
    end

    it "leaves note off the gate_approved event when the note is blank" do
      engine.turn_ended("wr_1", pane: "%5")

      engine.approve("wr_1", note: "  ")

      expect(history_lines.find { |line| line["type"] == "gate_approved" }).not_to have_key("note")
    end

    it "refuses to approve or reject a run that is not at a gate" do
      [-> { engine.approve("wr_1") }, -> { engine.reject("wr_1", note: "no") }].each do |call|
        expect(&call).to raise_error(Workspace::Error, "Run wr_1 is not waiting at a gate (step plan is running).") { |error|
          expect(error.code).to eq("gate_not_waiting")
          expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1, "state" => "running",
            "expected_step" => nil, "expected_attempt" => nil)
        }
      end
    end

    it "runs the gated step again when rejected, with the note" do
      engine.turn_ended("wr_1", pane: "%5")

      run = engine.reject("wr_1", note: "Too big; split it.")

      expect(run).to include("state" => "running", "current" => "plan", "reason" => nil)
      expect(run["steps"]["plan"]["gate"]).to include("state" => "rejected", "attempt" => 1)
      expect(run["steps"]["plan"]["attempts"].last).to include("n" => 2, "context" => ["The plan step was rejected at its gate: Too big; split it."])
      expect(File.read(run["steps"]["plan"]["attempts"].last["prompt_file"])).to include("The plan step was rejected at its gate: Too big; split it.")
      expect(history_lines.find { |line| line["type"] == "gate_rejected" }).to include("step" => "plan", "to" => "plan", "note" => "Too big; split it.")
    end

    it "refuses to reject to a step after the gated one" do
      engine.turn_ended("wr_1", pane: "%5")

      expect { engine.reject("wr_1", note: "no", to: "build") }
        .to raise_error(Workspace::UsageError, '--to must be plan or a step before it (plan), got "build".')
      expect(store.find("wr_1")["steps"]["plan"]["gate"]["state"]).to eq("waiting")
    end
  end

  describe "a gate's guards" do
    let(:run_file) { File.join(runs_dir, "wr_1.json") }
    let(:note_path) { File.join(notes_dir, "2026-10-29-pr-7-feedback.md") }
    let(:note_sha) { Digest::SHA256.hexdigest("# Triage\n\nF1: fix.\n") }

    # The gated step's first file names the note on its first line, as the pr-feedback triage step writes it.
    def gate_at(first_line = "note: 2026-10-29-pr-7-feedback.md")
      start
      File.write(artifact("plan.md"), "#{first_line}\nfix 1, answer 0\n")
      FileUtils.mkdir_p(notes_dir)
      File.write(note_path, "# Triage\n\nF1: fix.\n")
      engine.turn_ended("wr_1", pane: "%5")
    end

    def unchanged
      before = File.binread(run_file)
      yield
      expect(File.binread(run_file)).to eq(before)
    end

    it "approves at the step and attempt the caller saw" do
      gate_at

      run = engine.approve("wr_1", step: "plan", attempt: 1)

      expect(run).to include("current" => "build", "state" => "running")
    end

    it "refuses a wrong step or attempt with gate_not_waiting, naming both, and leaves the run file as it was" do
      gate_at

      {["build", nil] => ["build", nil], ["plan", 2] => ["plan", 2]}.each do |(step, attempt), (expected_step, expected_attempt)|
        unchanged do
          expect { engine.approve("wr_1", step: step, attempt: attempt) }
            .to raise_error(Workspace::Error, /Run wr_1 is not waiting at the gate of step #{expected_step}/) { |error|
              expect(error.code).to eq("gate_not_waiting")
              expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1, "state" => "passed",
                "expected_step" => expected_step, "expected_attempt" => expected_attempt)
            }
          expect { engine.reject("wr_1", note: "no", step: step, attempt: attempt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_not_waiting") }
        end
      end
    end

    it "refuses an approval from before a reject once the gate waits again, on a later attempt" do
      gate_at
      engine.reject("wr_1", note: "Again.", step: "plan", attempt: 1)
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["steps"]["plan"]["gate"]["state"]).to eq("waiting")

      unchanged do
        expect { engine.approve("wr_1", step: "plan", attempt: 1) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("gate_not_waiting")
          expect(error.details).to include("step" => "plan", "attempt" => 2, "expected_attempt" => 1)
        }
      end
      expect(engine.approve("wr_1", step: "plan", attempt: 2)).to include("current" => "build")
    end

    it "rejects at the step and attempt the caller saw, back to the step it names" do
      gated = definition("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n    gate: approve\n")
      start(gated, inputs: {})
      engine.turn_ended("wr_1")
      engine.turn_ended("wr_1")

      run = engine.reject("wr_1", note: "Start over.", to: "a", step: "b", attempt: 1)

      expect(run["current"]).to eq("a")
      expect(run["steps"]["a"]["attempts"].size).to eq(2)
    end

    it "asks the guard after the step checks, under the run's lock, and changes nothing when it refuses" do
      gate_at
      seen = []
      refuse = ->(stored) {
        seen << stored["current"]
        raise Workspace::Error.new("refused", code: "bound_pane")
      }

      expect { engine.approve("wr_1", step: "build", guard: refuse) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_not_waiting") }
      expect(seen).to eq([])
      unchanged do
        expect { engine.approve("wr_1", step: "plan", attempt: 1, guard: refuse) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("bound_pane") }
        expect { engine.reject("wr_1", note: "no", guard: refuse) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("bound_pane") }
      end
      expect(seen).to eq(%w[plan plan])
    end

    it "records the note's sha256 with the approval, and names it in the next step's instructions" do
      gate_at

      run = engine.approve("wr_1", note: "Skip F2.")

      expect(run["steps"]["plan"]["gate"]).to include("state" => "approved", "file" => {"path" => note_path, "sha256" => note_sha})
      expect(run["steps"]["build"]["attempts"].last["context"]).to eq(["The plan step was approved with this note: Skip F2.",
        "The approved note is #{note_path}, sha256 #{note_sha}."])
      expect(history_lines.find { |line| line["type"] == "gate_approved" }).to include("sha256" => note_sha)
    end

    it "approves a gate whose first file names no note as before, recording no file" do
      gate_at("fix 1")

      run = engine.approve("wr_1")

      expect(run["steps"]["plan"]["gate"]).not_to have_key("file")
      expect(run["steps"]["build"]["attempts"].last["context"]).to eq([])
    end

    it "refuses with gate_note_unreadable a note that is missing, a link, or not a plain file name, and leaves the run file as it was" do
      gate_at
      File.delete(note_path)
      unchanged do
        expect { engine.approve("wr_1") }.to raise_error(Workspace::Error, /The gate of step plan in run wr_1 has no note that can be read/) { |error|
          expect(error.code).to eq("gate_note_unreadable")
          expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1, "name" => "2026-10-29-pr-7-feedback.md", "path" => note_path)
        }
      end

      File.write(File.join(notes_dir, "real.md"), "x")
      File.symlink(File.join(notes_dir, "real.md"), note_path)
      unchanged { expect { engine.approve("wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_note_unreadable") } }

      File.write(File.join(worktree, ".workflow", "wr_1", "plan.md"), "note: sub/2026-10-29-pr-7-feedback.md\n")
      unchanged { expect { engine.approve("wr_1") }.to raise_error(Workspace::Error, /is not a plain file name/) { |e| expect(e.code).to eq("gate_note_unreadable") } }
    end

    it "approves with --note-sha256 when the note still has that hash, recording that hash" do
      gate_at

      run = engine.approve("wr_1", step: "plan", attempt: 1, note_sha256: note_sha)

      expect(run["steps"]["plan"]["gate"]["file"]).to eq("path" => note_path, "sha256" => note_sha)
    end

    it "refuses --note-sha256 for a note that changed with stale_revision, naming its hash now, and leaves the run file as it was" do
      gate_at
      File.write(note_path, "# Triage\n\nF1: decline.\n")
      now_sha = Digest::SHA256.hexdigest("# Triage\n\nF1: decline.\n")

      unchanged do
        expect { engine.approve("wr_1", note_sha256: note_sha) }.to raise_error(Workspace::Error, /The note #{Regexp.escape(note_path)} changed since that revision/) { |error|
          expect(error.code).to eq("stale_revision")
          expect(error.details).to eq("revision" => now_sha, "path" => note_path, "run_id" => "wr_1", "step" => "plan", "attempt" => 1)
        }
      end
    end

    it "refuses --note-sha256 on a gate that names no note with gate_note_unreadable" do
      gate_at("fix 1")

      unchanged do
        expect { engine.approve("wr_1", note_sha256: note_sha) }.to raise_error(Workspace::Error, /has no `note:` line/) { |error|
          expect(error.code).to eq("gate_note_unreadable")
        }
      end
    end

    it "checks the step before the note: a stale button on a changed note is gate_not_waiting" do
      gate_at
      File.write(note_path, "changed")

      expect { engine.approve("wr_1", step: "plan", attempt: 3, note_sha256: note_sha) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_not_waiting") }
    end
  end

  describe "#reject to an earlier step" do
    it "goes back to that step" do
      gated = definition("steps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n    gate: approve\n")
      start(gated, inputs: {})
      engine.turn_ended("wr_1")
      engine.turn_ended("wr_1")

      run = engine.reject("wr_1", note: "Start over.", to: "a")

      expect(run["current"]).to eq("a")
      expect(run["steps"]["a"]["attempts"].size).to eq(2)
    end
  end

  describe "#resume" do
    it "refuses a run at a gate, which is approved or rejected instead" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error, /waiting at the plan gate\. Approve or reject it, or pass --from STEP/) { |error|
        expect(error.code).to eq("gate_waiting")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan")
      }
    end

    it "leaves the run in its pane when it refuses, though another pane was named" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect { engine.resume("wr_1", pane: "%8") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gate_waiting") }
      expect { engine.resume("wr_1", pane: "%8", from: "deploy") }.to raise_error(Workspace::UsageError)

      expect(panes.bound.keys).to eq(["%5"])
      expect(store.find("wr_1")).to include("pane" => "%5", "pending_context" => [])
    end

    it "runs a failed step again, with the note" do
      plain = definition("steps:\n  a:\n    prompt: P\n    uses: [test-db]\n    status: bin/check\n")
      start(plain, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1")

      run = engine.resume("wr_1", note: "The fixture was stale; fixed.")

      expect(run).to include("state" => "running", "reason" => nil)
      expect(run["steps"]["a"]["attempts"].last).to include("n" => 2, "context" => [
        "The last attempt of this step failed: its check exited 1 (log: #{File.join(worktree, ".workflow", "wr_1", "steps", "a.1.check.log")}).",
        "Note from the person who resumed the run: The fixture was stale; fixed."
      ])
      expect(lock_holder("test-db")).to include("run_id" => "wr_1")
    end

    it "types an undelivered step's line again" do
      panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
      start
      panes.kick_result = {ok: true}

      run = engine.resume("wr_1")

      expect(run).to include("state" => "running", "reason" => nil)
      expect(run["steps"]["plan"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
    end

    it "tells the next attempt what an undelivered one would have been told" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
      engine.approve("wr_1", note: "Skip the migration.")
      panes.kick_result = {ok: true}

      attempts = engine.resume("wr_1")["steps"]["build"]["attempts"]

      expect(attempts.map { |attempt| attempt["context"] }).to eq([["The plan step was approved with this note: Skip the migration."]] * 2)
      expect(attempts.first["outcome"]).to eq("not_delivered")
    end

    it "looks again at a step whose turn ended without its files" do
      start
      engine.turn_ended("wr_1", pane: "%5")
      artifact("plan.md")

      expect(engine.resume("wr_1")["steps"]["plan"]["state"]).to eq("passed")
    end

    it "leaves alone a step an agent is working on" do
      start
      events.clear

      before = history

      run = engine.resume("wr_1")

      expect(run["unchanged"]).to eq("an agent is working on step plan")
      expect(run["steps"]["plan"]["attempts"].size).to eq(1)
      expect(panes.kicks.size).to eq(1)
      expect(events).to eq([])
      expect(history).to eq(before)
      expect(store.find("wr_1")).not_to have_key("unchanged")
    end

    describe "a step that reads running while its pane's agent is idle (the turn ended unseen)" do
      it "passes the step when its files are there" do
        start
        artifact("plan.md")

        run = engine.resume("wr_1", turn_over: {"step" => "plan", "attempt" => 1})

        expect(run).not_to have_key("unchanged")
        expect(run["steps"]["plan"]).to include("state" => "passed")
        expect(history).to include("run_resumed")
      end

      it "says which file is missing when one is" do
        start

        expect(engine.resume("wr_1", turn_over: {"step" => "plan", "attempt" => 1})["reason"]).to include("code" => "turn_ended_incomplete")
      end

      it "runs the step's check" do
        to_verify

        expect(engine.resume("wr_1", turn_over: {"step" => "verify", "attempt" => 1})["state"]).to eq("completed")
        expect(check_calls.size).to eq(1)
      end

      it "decides nothing when the run has moved to another step or attempt since the turn's end was seen" do
        to_build

        [{"step" => "plan", "attempt" => 1}, {"step" => "build", "attempt" => 2}].each do |seen|
          run = engine.resume("wr_1", turn_over: seen)

          expect(run["unchanged"]).to eq("an agent is working on step build")
          expect(run).to include("current" => "build")
        end
        expect(panes.kicks.size).to eq(2)
      end
    end

    it "leaves a check that is still running alone, and starts no second one" do
      to_verify
      store.update("wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => "2026-10-04T12:00:00Z"}
      end
      before = history

      run = engine.resume("wr_1")

      expect(run["unchanged"]).to eq("the check of step verify is still running")
      expect(check_calls).to eq([])
      expect(history).to eq(before)
    end

    it "moves no pane and keeps no note when it does nothing" do
      to_verify
      store.update("wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => "2026-10-04T12:00:00Z"}
      end

      expect(engine.resume("wr_1", pane: "%9", note: "hello")["unchanged"]).to eq("the check of step verify is still running")
      expect(store.find("wr_1")).to include("pane" => "%5", "pending_context" => [])
      expect(panes.bound.keys).to eq(["%5"])

      store.update("wr_1") { |run| run["steps"]["verify"]["state"] = "running" }
      expect(engine.resume("wr_1", note: "hello")["unchanged"]).to eq("an agent is working on step verify")
      expect(store.find("wr_1")["pending_context"]).to eq([])
    end

    it "goes on from a step that passed and never got its next step started" do
      to_build
      store.update("wr_1") { |run| run["steps"]["build"]["state"] = "passed" }

      expect(engine.resume("wr_1")).to include("current" => "verify", "state" => "running")
    end

    it "leaves a waiting gate when a step is named" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect(engine.resume("wr_1", from: "build")).to include("current" => "build", "state" => "running")
    end

    it "starts a run whose `workflow run` was interrupted before its first step was under way" do
      panes.bind_error = Interrupt
      expect { start }.to raise_error(Interrupt)
      left = store.find("wr_1")
      expect(left).to include("state" => "waiting", "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"))
      expect(left["reason"]).to include("code" => "waiting_you")
      expect(left["reason"]["details"]).to include("kind" => "dispatch", "error" => "not_started")
      panes.bind_error = nil

      run = engine.resume("wr_1")

      expect(run).to include("state" => "running", "reason" => nil)
      expect(run["steps"]["plan"]["state"]).to eq("running")
    end

    it "starts a run whose file has no artifacts directory, as an older interrupted start left it" do
      start
      store.update("wr_1") do |run|
        run.delete("artifacts_dir")
        run["steps"]["plan"] = {"state" => "pending", "attempts" => []}
      end

      run = engine.resume("wr_1")

      expect(run).to include("state" => "running", "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"))
    end

    it "tells the next attempt that the last one's check ran past its time limit" do
      plain = definition("steps:\n  a:\n    prompt: P\n    status: bin/check\n")
      start(plain, inputs: {})
      check_results << {exit_code: nil, timed_out: true}
      engine.turn_ended("wr_1")

      context = engine.resume("wr_1")["steps"]["a"]["attempts"].last["context"]

      expect(context).to eq(["The last attempt of this step failed: its check ran past its time limit " \
        "(log: #{File.join(worktree, ".workflow", "wr_1", "steps", "a.1.check.log")})."])
    end

    it "moves the run to another pane and starts the step there" do
      start

      run = engine.resume("wr_1", pane: "%8")

      expect(run["pane"]).to eq("%8")
      expect(events.last.first).to eq("workflow_changed")
      expect(panes.bound.keys).to eq(["%8"])
      expect(panes.kicks.last).to include(pane: "%8")
      expect(run["steps"]["plan"]["attempts"].size).to eq(2)
    end

    it "refuses to move the run to a pane another run is using" do
      start
      start(definition("steps:\n  a:\n    prompt: P\n"), inputs: {}, pane: "%6")

      expect { engine.resume("wr_1", pane: "%6") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("pane_has_run") }
      expect(panes.bound.keys).to eq(%w[%5 %6])
    end

    it "starts again from a named step, and refuses one the workflow doesn't have" do
      to_verify

      expect { engine.resume("wr_1", from: "deploy") }.to raise_error(Workspace::UsageError, 'No step "deploy" in workflow flow (plan, build, verify).')
      expect(engine.resume("wr_1", from: "build")).to include("current" => "build", "state" => "running")
    end

    it "runs a check again whose result never came back" do
      to_verify
      store.update("wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => "2026-10-04T11:00:00Z"}
      end

      expect(engine.resume("wr_1")["state"]).to eq("completed")
    end
  end

  describe "the attempt budget on resume and reject" do
    let(:one_attempt) { definition("max_attempts: 1\nsteps:\n  a:\n    prompt: P\n    status: bin/check\n") }

    def failed_run
      start(one_attempt, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1")
    end

    it "refuses a resume that would start an attempt once max_attempts is spent, and changes nothing" do
      failed_run
      before = store.find("wr_1")
      lines = history_lines.size

      expect { engine.resume("wr_1", note: "again") }.to raise_error(Workspace::Error, /spent max_attempts \(1 of 1\)\. Pass --extra-attempts 1 to continue/) { |error|
        expect(error.code).to eq("attempts_spent")
        expect(error.details).to eq("run_id" => "wr_1", "attempts" => 1, "max_attempts" => 1, "step" => "a", "needed" => 1)
      }

      expect(store.find("wr_1")).to eq(before)
      expect(history_lines.size).to eq(lines)
    end

    it "refuses --from the same way" do
      failed_run

      expect { engine.resume("wr_1", from: "a") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
    end

    it "goes on with --extra-attempts, keeps the allowance in the run and records it" do
      failed_run

      run = engine.resume("wr_1", extra_attempts: 1)

      expect(run).to include("state" => "running", "extra_attempts" => 1)
      expect(run["definition"]["max_attempts"]).to eq(1)
      expect(history_lines.find { |line| line["type"] == "attempts_extended" }).to include("extra" => 1, "extra_attempts" => 1, "max_attempts" => 2)
    end

    it "makes a later failure check the raised allowance" do
      failed_run
      engine.resume("wr_1", extra_attempts: 1)
      check_results << {exit_code: 1, timed_out: false}

      run = engine.turn_ended("wr_1")

      expect(run["reason"]["details"]).to include("attempts" => 2, "max_attempts" => 2)
      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
      expect(engine.resume("wr_1", extra_attempts: 3)["extra_attempts"]).to eq(4)
    end

    it "adds --extra-attempts even when the budget is not spent" do
      roomy = definition("max_attempts: 5\nsteps:\n  a:\n    prompt: P\n    status: bin/check\n")
      start(roomy, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1")

      expect(engine.resume("wr_1", extra_attempts: 2)).to include("extra_attempts" => 2)
    end

    it "does not count an attempt the sweep typed again" do
      failed_run
      store.update("wr_1") { |stored| stored["steps"]["a"]["attempts"].last["redelivered"] = true }

      expect(engine.resume("wr_1")).to include("state" => "running")
    end

    it "answers unchanged, not a refusal, when the resume starts no attempt" do
      start(one_attempt, inputs: {})

      run = engine.resume("wr_1")

      expect(run["unchanged"]).to match(/an agent is working on step a/)
      expect(run).not_to have_key("extra_attempts")
      expect(engine.resume("wr_1", extra_attempts: 2)).not_to have_key("extra_attempts")
    end

    it "does not refuse a check being decided from a turn that is over" do
      start(one_attempt, inputs: {})
      check_results << {exit_code: 0, timed_out: false}

      run = engine.resume("wr_1", turn_over: {"step" => "a", "attempt" => 1})

      expect(run["state"]).to eq("completed")
    end

    it "refuses a reject once max_attempts is spent, and goes on with --extra-attempts" do
      gated = definition("max_attempts: 1\nsteps:\n  plan:\n    prompt: P\n    produces: [plan.md]\n    gate: approve\n")
      start(gated, inputs: {})
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      before = store.find("wr_1")

      expect { engine.reject("wr_1", note: "no") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
      expect(store.find("wr_1")).to eq(before)

      run = engine.reject("wr_1", note: "no", extra_attempts: 1)

      expect(run).to include("state" => "running", "extra_attempts" => 1)
    end

    def two_attempts = definition("max_attempts: 2\nsteps:\n  a:\n    prompt: P\n    status: bin/check\n")

    def add_attempts(count)
      store.update("wr_1") { |stored| count.times { |n| stored["steps"]["a"]["attempts"] << {"n" => 10 + n, "outcome" => "failed"} } }
    end

    it "keeps no extra_attempts key on a first attempt or an old run, which is still refused when spent" do
      start(one_attempt, inputs: {})
      expect(store.find("wr_1")).not_to have_key("extra_attempts")
      expect(store.find("wr_1")["steps"]["a"]["attempts"].size).to eq(1)

      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1")

      expect(store.find("wr_1")).not_to have_key("extra_attempts")
      expect(described_class.attempts_spent?(store.find("wr_1"))).to be(true)
      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
      expect(described_class.attempts_spent?({"definition" => {}, "steps" => {}})).to be(false)
    end

    it "needs an --extra-attempts that covers the overrun, and says how much" do
      failed_run
      add_attempts(2)

      expect { engine.resume("wr_1", extra_attempts: 2) }.to raise_error(Workspace::Error, /\(3 of 1\)\. Pass --extra-attempts 3 to continue/) { |error|
        expect(error.details).to include("needed" => 3)
      }
      expect(store.find("wr_1")).not_to have_key("extra_attempts")
      expect(engine.resume("wr_1", extra_attempts: 3)).to include("extra_attempts" => 3)
    end

    it "measures the minimum against a stored extra_attempts: one below is refused, exactly at it goes on" do
      failed_run
      engine.resume("wr_1", extra_attempts: 1)
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1")
      add_attempts(2)
      # made 4 of an allowance of 2 (1 plus 1 stored): at least 3 more is needed
      expect(described_class.extra_attempts_needed(store.find("wr_1"))).to eq(3)

      expect { engine.resume("wr_1", extra_attempts: 2) }.to raise_error(Workspace::Error) { |error| expect(error.details).to include("needed" => 3, "max_attempts" => 2) }
      expect(engine.resume("wr_1", extra_attempts: 3)).to include("extra_attempts" => 4)
    end

    it "takes --extra-attempts with --from" do
      failed_run

      expect(engine.resume("wr_1", from: "a", extra_attempts: 1)).to include("state" => "running", "extra_attempts" => 1)
    end

    it "logs and changes nothing when the named pane belongs to another run" do
      failed_run
      start(one_attempt, inputs: {}, pane: "%8", workspace: "app.worktree-b")
      before = store.find("wr_1")
      lines = history_lines.size

      expect { engine.resume("wr_1", pane: "%8", extra_attempts: 1) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("pane_has_run") }

      expect(store.find("wr_1")).to eq(before)
      expect(history_lines.size).to eq(lines)
    end

    it "holds a resume during an on_fail backoff to the budget, and ends the wait with --extra-attempts" do
      waiting = definition("max_attempts: 3\nsteps:\n  build:\n    prompt: B\n  verify:\n    prompt: V\n    status: bin/check\n    on_fail: {goto: build, max: 2, backoff: 2m}\n")
      start(waiting, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["reason"]["code"]).to eq("retry_backoff")
      store.update("wr_1") { |stored| stored["definition"]["max_attempts"] = 2 }
      before = store.find("wr_1")

      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
      expect(store.find("wr_1")).to eq(before)

      run = engine.resume("wr_1", extra_attempts: 1)

      expect(run).to include("state" => "running", "current" => "build", "extra_attempts" => 1)
      expect(run).not_to have_key("backoff")
      expect(run["loops"]).to eq("verify->build" => 1)
    end

    it "lets on_fail retry up to the raised allowance, and no further" do
      looping = definition("max_attempts: 2\nsteps:\n  build:\n    prompt: B\n  verify:\n    prompt: V\n    status: bin/check\n    on_fail: {goto: build, max: 9}\n")
      start(looping, inputs: {})
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")
      run = engine.turn_ended("wr_1", pane: "%5")
      expect(run["reason"]["details"]).to include("attempts" => 2, "max_attempts" => 2)

      engine.resume("wr_1", extra_attempts: 2)
      check_results << {exit_code: 1, timed_out: false}
      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "running", "current" => "build", "reason" => nil)
      engine.turn_ended("wr_1", pane: "%5")
      check_results << {exit_code: 1, timed_out: false}
      run = engine.turn_ended("wr_1", pane: "%5")
      expect(run["reason"]["details"]).to include("attempts" => 5, "max_attempts" => 4)
      expect(run["state"]).to eq("waiting")
    end

    describe "a parked resume" do
      it "keeps the flag in the park, applies it on release, and records it once" do
        failed_run

        parked = engine.park("wr_1", extra_attempts: 1)

        expect(parked["parked"]).to include("extra_attempts" => 1)
        expect(parked).not_to have_key("extra_attempts")
        run = engine.release_park("wr_1", parked["parked"]["id"])
        expect(run).to include("state" => "running", "extra_attempts" => 1)
        expect(history_lines.count { |line| line["type"] == "attempts_extended" }).to eq(1)
      end

      it "is not charged again when the line could not be typed and the park is made again" do
        failed_run
        id = engine.park("wr_1", extra_attempts: 1)["parked"]["id"]
        panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}

        run = engine.release_park("wr_1", id)

        expect(run["parked"]).to include("retries" => 1)
        expect(run["parked"]).not_to have_key("extra_attempts")
        expect(run["extra_attempts"]).to eq(1)
        panes.kick_result = {ok: true}

        run = engine.release_park("wr_1", run["parked"]["id"])

        expect(run).to include("state" => "running", "extra_attempts" => 1)
        expect(history_lines.count { |line| line["type"] == "attempts_extended" }).to eq(1)
      end

      it "raises on release when the budget filled in the meantime, and stays parked" do
        start(two_attempts, inputs: {})
        check_results << {exit_code: 1, timed_out: false}
        engine.turn_ended("wr_1")
        id = engine.park("wr_1")["parked"]["id"]
        add_attempts(1)

        expect { engine.release_park("wr_1", id) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }

        expect(store.find("wr_1")["parked"]["id"]).to eq(id)
      end
    end

    it "refuses a resume parked for a spent run, at park time" do
      failed_run

      expect { engine.park("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("attempts_spent") }
    end
  end

  describe "#cancel" do
    it "ends the run: locks released, pane freed, run archived, and nothing more can happen to it" do
      to_build

      run = engine.cancel("wr_1")

      expect(run).to include("state" => "cancelled", "cancelled_by" => "cancel", "reason" => nil, "ended_at" => "2026-10-04T12:00:00Z")
      expect(lock_holder("test-db")).to be_nil
      expect(panes.bound).to eq({})
      expect(history.last).to eq("run_cancelled")
      expect { engine.cancel("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_not_active") }
      expect { engine.turn_ended("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_not_active") }
    end
  end

  describe "evidence copies" do
    let(:evidence_dir) { File.join(@dir, "state", ".workflows", "evidence") }
    let(:evidence) { Workspace::WorkflowEvidence.new(dir: evidence_dir) }
    subject(:engine) { engine_with(attempt_record: Workspace::WorkflowAttemptRecord.new(guard: guard, evidence: evidence)) }
    let(:steps_dir) { File.join(worktree, ".workflow", "wr_1", "steps") }
    let(:copies) { File.join(evidence_dir, "wr_1") }

    def attempts(step)
      store.find("wr_1")["steps"][step]["attempts"]
    end

    it "keeps the prompt of an attempt that was not delivered, and nothing else" do
      panes.kick_result = {ok: false, code: "not_delivered", message: "no", reason: "prompt_unconfirmed"}
      start

      entries = attempts("plan").last["evidence"]
      expect(entries.map { |e| [e["kind"], e["name"]] }).to eq([["prompt", "plan.1.prompt.md"]])
      expect(File.read(File.join(copies, "plan.1.prompt.md"))).to eq(File.read(File.join(steps_dir, "plan.1.prompt.md")))
    end

    it "copies the prompt before delivery, so an agent that rewrites it later can be told from the copy" do
      start
      prompt = File.join(steps_dir, "plan.1.prompt.md")
      recorded = attempts("plan").last["evidence"].first["sha256"]
      File.write(prompt, "rewritten by the agent")

      expect(recorded).to eq(attempts("plan").last["prompt_sha256"])
      expect(Digest::SHA256.file(File.join(copies, "plan.1.prompt.md")).hexdigest).to eq(recorded)
    end

    it "keeps distinct evidence for a passed step, a failed one and its retry" do
      to_verify
      File.write(File.join(steps_dir, "verify.1.check.log"), "first failure")
      check_results << {exit_code: 1, timed_out: false}
      engine.turn_ended("wr_1", pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")
      File.write(File.join(steps_dir, "verify.2.check.log"), "second pass")
      engine.turn_ended("wr_1", pane: "%5")

      names = Dir.children(copies).sort
      expect(names).to include("plan.1.prompt.md", "plan.1.out.0.plan.md", "build.1.prompt.md", "build.2.prompt.md",
        "verify.1.prompt.md", "verify.1.check.log", "verify.2.prompt.md", "verify.2.check.log")
      expect(File.read(File.join(copies, "verify.1.check.log"))).to eq("first failure")
      expect(attempts("verify").first).to include("outcome" => "failed")
      expect(attempts("verify").first["evidence"].map { |e| e["name"] }).to eq(%w[verify.1.prompt.md verify.1.check.log])
      expect(attempts("verify").last["evidence"].last).to include("name" => "verify.2.check.log", "sha256" => Digest::SHA256.hexdigest("second pass"))
    end

    it "copies on a cancel and leaves the directory alone afterwards" do
      start
      artifact("plan.md")
      engine.cancel("wr_1")

      expect(attempts("plan").last["evidence"].map { |e| e["name"] }).to eq(%w[plan.1.prompt.md plan.1.out.0.plan.md])
      expect(Dir.children(copies).sort).to eq(%w[plan.1.out.0.plan.md plan.1.prompt.md])
    end

    it "reads missing and raises nothing when a killed workspace's artifacts are gone" do
      start
      FileUtils.rm_rf(File.join(worktree, ".workflow"))

      expect { engine.workspace_killed("app.worktree-x") }.not_to raise_error
      expect(store.find("wr_1")["state"]).to eq("cancelled")
      expect(attempts("plan").last["evidence"].map { |e| e["problem"] }.compact).to eq(%w[missing])
    end
  end

  describe "#workspace_killed" do
    it "ends the killed workspace's runs and no other's, though the checkout is gone" do
      start(workspace: "app.worktree-a", pane: "%5")
      start(workspace: "app.worktree-b", pane: "%6")
      allow(lock_namespace).to receive(:resolve).and_raise(Workspace::Error, "not a git repository")

      expect(engine.workspace_killed("app.worktree-a")).to eq("cancelled" => ["wr_1"], "failed" => [])

      expect(store.find("wr_1")).to include("state" => "cancelled", "cancelled_by" => "kill")
      expect(store.find("wr_2")["state"]).to eq("running")
      expect(liveness.run_alive?("wr_1")).to be false
    end

    it "does not raise when the run store can't be read" do
      allow(store).to receive(:active).and_raise(NoMethodError, "undefined method for nil")

      expect(engine.workspace_killed("app")).to eq("cancelled" => [], "failed" => [])
    end

    it "ends the other runs, and names the one it could not end, when ending one raises" do
      start(workspace: "app.worktree-a", pane: "%5")
      start(workspace: "app.worktree-a", pane: "%6")
      store.on(:update) do |original, id, **options, &block|
        raise NoMethodError, "undefined method 'fetch' for nil" if id == "wr_1"
        original.call(id, **options, &block)
      end

      expect(engine.workspace_killed("app.worktree-a")).to eq("cancelled" => ["wr_2"], "failed" => ["wr_1"])
      expect(store.find("wr_2")["state"]).to eq("cancelled")
    end

    it "leaves alone a run whose file can't be read as a run: the lock store still counts it as going" do
      start(workspace: "app.worktree-a", pane: "%5")
      path = File.join(runs_dir, "wr_1.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).except("steps")))

      expect(engine.workspace_killed("app.worktree-a")).to eq("cancelled" => [], "failed" => [])
      expect(liveness.run_alive?("wr_1")).to be true
      {
        cancel: -> { engine.cancel("wr_1") },
        tick: -> { engine.tick("wr_1") },
        turn_ended: -> { engine.turn_ended("wr_1") },
        approve: -> { engine.approve("wr_1") }
      }.each_value do |call_verb|
        expect { call_verb.call }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("unknown_run")
          expect(error.details).to eq("run_id" => "wr_1", "path" => path)
        }
      end
    end
  end
  describe "the guard" do
    let(:guard) { Workspace::WorkflowGuard.new }

    let(:guarded) do
      definition(<<~YAML)
        steps:
          diagnose:
            prompt: Look.
            produces: [note.md]
            guard: unchanged
          fix:
            prompt: Fix.
            guard: config
      YAML
    end

    def commit_in_worktree
      system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "agent", exception: true)
    end

    it "stores the base commit and the snapshot beside it" do
      run = start(guarded, inputs: {})

      expect(run["base_sha"]).to eq(`git -C #{worktree} rev-parse HEAD`.strip)
      expect(run["base_guard"].keys).to eq(%w[config_sha256 hooks_sha256 hidden_sha256 config_format filter_sha256])
      expect(store.find("wr_1")["base_guard"]).to eq(run["base_guard"])
    end

    it "fails a guarded step with the guard's code before it looks for the step's files" do
      start(guarded, inputs: {})
      commit_in_worktree

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting")
      expect(run["reason"]["code"]).to eq("failed_check")
      expect(run["reason"]["details"]).to include("cause" => "guard", "guard" => "head_moved", "code" => "head_moved", "code_source" => "engine", "paths" => [],
        "base_sha" => run["base_sha"])
      expect(run["steps"]["diagnose"]["attempts"].last).to include("outcome" => "failed")
    end

    it "stops instead of looping when on_fail's except lists guard, and counts no loop" do
      excepted = definition(<<~YAML)
        steps:
          plan:
            prompt: Plan.
            guard: unchanged
          tally:
            prompt: Tally.
            guard: unchanged
            on_fail: {goto: plan, max: 2, except: [guard]}
      YAML
      start(excepted, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      commit_in_worktree

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting", "current" => "tally", "loops" => {})
      expect(run["reason"]["code"]).to eq("failed_check")
      expect(run["reason"]["details"]).to include("cause" => "guard", "code" => "head_moved")
      expect(run["steps"]["tally"]["attempts"].size).to eq(1)
      expect(run["steps"]["plan"]["attempts"].size).to eq(1)
    end

    describe "a changed repository config" do
      let(:inbox_path) { File.join(worktree, "..", "inbox-#{File.basename(worktree)}.json") }
      let(:inbox) { Workspace::InboxStore.new(path: inbox_path) }
      subject(:engine) { engine_with(inbox_for: ->(_workspace) { inbox }) }

      after { FileUtils.rm_f([inbox_path, "#{inbox_path}.lock"]) }

      def set_config(key, value)
        system("git", "-C", worktree, "config", key, value, exception: true)
      end

      def warnings(run)
        run["steps"].values.flat_map { |state| state["attempts"].flat_map { |attempt| Array(attempt["warnings"]) } }
      end

      def to_second_step
        artifact("note.md")
        engine.turn_ended("wr_1", pane: "%5")
      end

      it "passes the step, records the warning on the attempt, and posts one inbox item" do
        start(guarded, inputs: {})
        set_config("core.fsmonitor", "true")

        run = to_second_step

        expect(run["current"]).to eq("fix")
        expect(run["steps"]["diagnose"]["attempts"].last).to include("outcome" => "passed", "warnings" => [include("code" => "config_changed")])
        expect(inbox.list.map { |item| item.slice("type", "dedupe_key") }).to eq([{"type" => "alert", "dedupe_key" => "workflow-guard:wr_1:config_changed"}])
        expect(inbox.list.first["links"]).to include("run_id" => "wr_1", "step" => "diagnose", "attempt" => 1)
        expect(store.events("wr_1")["events"].map { |each| each["type"] }).to include("guard_warning")
      end

      it "warns once, not again at the next step" do
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        to_second_step

        run = engine.turn_ended("wr_1", pane: "%5")
        expect(warnings(run).size).to eq(1)
        expect(run["state"]).to eq("completed")
        expect(inbox.list.size).to eq(1)
      end

      it "warns of a second, different change on the same item" do
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        to_second_step
        set_config("alias.y", "log")

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(warnings(run).size).to eq(2)
        expect(inbox.list.size).to eq(1)
      end

      it "says nothing when the config came back to the base's reading, and forgets the last warning" do
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        to_second_step
        system("git", "-C", worktree, "config", "--unset", "alias.x", exception: true)

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(warnings(run).size).to eq(1)
        expect(run).not_to have_key("guard_config_seen")
      end

      it "goes on when the inbox cannot be written, the warning still on the attempt" do
        failing = engine_with(inbox_for: ->(_workspace) { raise "inbox is gone" })
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        artifact("note.md")

        run = failing.turn_ended("wr_1", pane: "%5")

        expect(run["current"]).to eq("fix")
        expect(run["steps"]["diagnose"]["attempts"].last).to include("outcome" => "passed", "warnings" => [include("code" => "config_changed")])
      end

      it "tries again at the next guarded step when the warning could not be recorded" do
        reads = 0
        flaky = Class.new(SimpleDelegator) do
          define_method(:config_change) do |*args, **kwargs|
            # The first reading carries a code the warning text does not know, so building the warning fails.
            ((reads += 1) == 1) ? {"code" => "unknown_code", "reading" => "r"} : super(*args, **kwargs)
          end
        end.new(guard)
        flaky_engine = engine_with(guard: flaky, inbox_for: ->(_workspace) { inbox })
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        artifact("note.md")

        run = flaky_engine.turn_ended("wr_1", pane: "%5")
        expect(run["current"]).to eq("fix")
        expect(run).not_to have_key("guard_config_seen")

        run = flaky_engine.turn_ended("wr_1", pane: "%5")

        expect(run["steps"]["fix"]["attempts"].last["warnings"].size).to eq(1)
      end

      it "says nothing of another branch's section" do
        start(guarded, inputs: {})
        set_config("branch.other.workspace-created", "true")

        expect(warnings(to_second_step)).to eq([])
        expect(inbox.list).to eq([])
      end

      it "warns and still fails when the hooks changed too" do
        start(guarded, inputs: {})
        set_config("core.hooksPath", "/tmp/planted-hooks")

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["reason"]["details"]).to include("code" => "hooks_changed", "cause" => "guard")
        expect(warnings(run).map { |each| each["code"] }).to eq(["config_changed"])
      end

      it "warns at most for a run whose digest was made the old way" do
        start(guarded, inputs: {})
        store.update("wr_1") { |run| run["base_guard"] = run["base_guard"].except("config_format").merge("config_sha256" => "0" * 64) }

        run = to_second_step

        expect(run["current"]).to eq("fix")
        expect(warnings(run)).to match([include("code" => "config_changed", "message" => a_string_matching(/may be no change/))])
        run = engine.turn_ended("wr_1", pane: "%5")
        expect(run["state"]).to eq("completed")
        expect(warnings(run).size).to eq(1)
      end

      it "goes on when the inbox can't be written" do
        failing = engine_with(inbox_for: ->(_workspace) { raise Errno::EACCES })
        start(guarded, inputs: {})
        set_config("alias.x", "status")
        artifact("note.md")

        run = failing.turn_ended("wr_1", pane: "%5")

        expect(run["current"]).to eq("fix")
        expect(warnings(run).size).to eq(1)
      end

      it "never refuses a start for it: a preflight has no base to differ from" do
        set_config("alias.x", "status")

        expect { engine.preflight(definition: guarded, workspace: "app", worktree: worktree, inputs: {}) }.not_to raise_error
      end
    end

    it "fails with tracked_changed and names the paths" do
      start(guarded, inputs: {})
      File.write(File.join(worktree, "README"), "x\n")
      system("git", "-C", worktree, "add", "README", exception: true)

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]["details"]).to include("code" => "tracked_changed", "paths" => ["README"])
    end

    it "words the failure for the next attempt when a step loops back" do
      looping = definition(<<~YAML)
        steps:
          one:
            prompt: One.
          two:
            prompt: Two.
            guard: unchanged
            on_fail: {goto: one, max: 1}
      YAML
      start(looping, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      commit_in_worktree

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["current"]).to eq("one")
      expect(run["steps"]["one"]["attempts"].last["context"].first).to match(/HEAD moved from \h{12} to \h{12} since the run started/)
    end

    it "passes a guarded step nothing moved in, once its files exist" do
      start(guarded, inputs: {})
      artifact("note.md")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["current"]).to eq("fix")
    end

    it "skips the guard when the agent reported a failure, with the agent's code" do
      start(guarded, inputs: {})
      commit_in_worktree
      engine.report("wr_1", status: "fail", summary: "No repro.", code: "not_reproduced")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]["details"]).to include("cause" => "reported", "summary" => "No repro.", "code" => "not_reproduced", "code_source" => "agent")
      expect(run["reason"]["details"]).not_to have_key("guard")
      expect(run["steps"]["diagnose"]["attempts"].last["reported"]).to include("code" => "not_reproduced")
    end

    it "gives a report with no code the engine's code `reported`" do
      start(guarded, inputs: {})
      engine.report("wr_1", status: "fail", summary: "Stuck.")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]["details"]).to include("code" => "reported", "code_source" => "engine")
      expect(run["steps"]["diagnose"]["attempts"].last["reported"]).not_to have_key("code")
    end

    it "checks only the config scope at a `guard: config` step, so a commit passes" do
      start(guarded, inputs: {})
      artifact("note.md")
      engine.turn_ended("wr_1", pane: "%5")
      commit_in_worktree
      File.write(File.join(worktree, ".git", "hooks", "pre-commit"), "#!/bin/sh\n")

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run["reason"]["details"]).to include("code" => "hooks_changed")
    end

    it "fails the step as check_error, rather than leaving the run stuck, when the guard raises" do
      exploding = instance_double(Workspace::WorkflowGuard, base: {"base_sha" => nil, "base_guard" => {}}, head: nil)
      allow(exploding).to receive(:check).and_raise(Encoding::CompatibilityError)
      raising = engine_with(guard: exploding)
      run = store.create({"workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => worktree, "state" => "running", "current" => "diagnose",
                          "definition" => guarded.to_h, "steps" => {"diagnose" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => now.first.iso8601(3)}]},
                                                                    "fix" => {"state" => "pending", "attempts" => []}},
                          "inputs" => {}, "loops" => {}, "pending_context" => [], "artifacts_dir" => File.join(worktree, ".workflow", "wr_1")})
      panes.bind(workspace: "app", pane: "%5", run_id: run["id"])

      result = raising.turn_ended(run["id"], pane: "%5")

      expect(result["state"]).to eq("waiting")
      expect(result["reason"]["details"]).to include("cause" => "check", "code" => "check_error", "code_source" => "engine")
      expect(result["reason"]["details"]["error"]).to eq("the guard could not run (Encoding::CompatibilityError)")
    end

    it "never records a new base_sha when a failed step is resumed" do
      start(guarded, inputs: {})
      commit_in_worktree
      base = engine.turn_ended("wr_1", pane: "%5")["base_sha"]

      engine.resume("wr_1")

      expect(store.find("wr_1")["base_sha"]).to eq(base)
    end

    describe "#preflight" do
      def preflight(definition = guarded, **options)
        engine.preflight(definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, **options)
      end

      it "passes a clean checkout, and an untracked file" do
        File.write(File.join(worktree, "untracked.txt"), "x\n")

        expect(preflight["workflow"]).to eq("flow")
      end

      it "refuses a changed tracked file as dirty_worktree, naming it" do
        File.write(File.join(worktree, "README"), "x\n")
        system("git", "-C", worktree, "add", "README", exception: true)
        system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "readme", exception: true)
        File.write(File.join(worktree, "README"), "changed\n")

        expect { preflight }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("dirty_worktree")
          expect(error.details).to eq("path" => worktree, "guard" => "tracked_changed", "files" => ["README"])
        }
      end

      it "refuses an unborn branch with guard no_commit" do
        fresh = File.join(@dir, "fresh")
        FileUtils.mkdir_p(fresh)
        system("git", "-C", fresh, "init", "-q", "-b", "main", exception: true)
        allow(lock_namespace).to receive(:resolve).with(cwd: fresh).and_return(key: "ns", display: "app", dir: lock_dir)

        expect { engine.preflight(definition: guarded, workspace: "app", worktree: fresh, inputs: {}) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("dirty_worktree")
          expect(error.details).to include("guard" => "no_commit")
        }
      end

      it "skips the look with tree: nil" do
        File.write(File.join(worktree, ".git", "MERGE_HEAD"), "x\n")

        expect(preflight(tree: nil)["workflow"]).to eq("flow")
      end

      it "looks only at a definition with a `guard: unchanged` step" do
        File.write(File.join(worktree, ".git", "MERGE_HEAD"), "x\n")
        config_only = definition("steps:\n  only:\n    prompt: Go.\n    guard: config\n")

        expect(preflight(config_only)["workflow"]).to eq("flow")
      end

      it "is what `start` refuses through" do
        File.write(File.join(worktree, ".git", "MERGE_HEAD"), "x\n")

        expect { start(guarded, inputs: {}) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("dirty_worktree") }
        expect(store.active).to eq([])
      end
    end
  end

  describe "a parked resume" do
    let(:single) { definition("steps:\n  work:\n    prompt: P\n    produces: [out.md]\n") }
    let(:checked) { definition("steps:\n  work:\n    prompt: P\n    status: {command: test}\n") }
    let(:locked) { definition("steps:\n  verify:\n    prompt: P\n    uses: [test-db]\n") }

    def parked(id = "wr_1") = store.find(id)["parked"]

    def attempts(id = "wr_1")
      store.find(id)["steps"].values.sum { |state| state["attempts"].size }
    end

    def event_of(type, id = "wr_1")
      history_lines(id).reverse.find { |line| line["type"] == type }
    end

    def undelivered(code = "pane_busy", definition = single)
      panes.kick_result = {ok: false, code: code, message: "the pane is busy"}
      start(definition, inputs: {})
      panes.kick_result = {ok: true}
    end

    def failed_run
      check_results << {exit_code: 1, timed_out: false}
      start(checked, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
    end

    def incomplete_run
      start(single, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
    end

    def lock_waiting_run
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
    end

    def checking_run(started_at: now.first.iso8601)
      to_verify
      store.update("wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => started_at}
      end
    end

    describe "#park" do
      it "stores a request and no attempt, with a limit an hour on" do
        undelivered

        run = engine.park("wr_1", note: "look again", pane: "%5", turn_over: {"step" => "work", "attempt" => 1})

        expect(run["parked"]).to include("from" => nil, "note" => "look again", "pane" => "%5", "turn_over" => {"step" => "work", "attempt" => 1},
          "requested_at" => "2026-10-04T12:00:00Z", "expires_at" => "2026-10-04T13:00:00Z", "retries" => 0)
        expect(run["parked"]["id"]).to match(/\A\h+\z/)
        expect(run).not_to have_key("unchanged")
        expect(attempts).to eq(1)
        expect(run["reason"]).to include("code" => "waiting_you")
      end

      it "keeps what a running step has: its attempt, binding and locks" do
        to_build
        store.update("wr_1") { |run| run["reason"] = {"code" => "turn_ended_incomplete", "since" => "t", "details" => {}} }
        kicks = panes.kicks.size

        engine.park("wr_1")

        expect(panes.kicks.size).to eq(kicks)
        expect(panes.pane_of("wr_1")).to eq("%5")
        expect(lock_holder("test-db")).to include("run_id" => "wr_1")
      end

      it "writes resume_parked without the note, and announces the change" do
        undelivered
        events.clear

        engine.park("wr_1", from: "work", note: "the secret word", pane: "%5")

        expect(event_of("resume_parked")).to include("step" => "work", "pane" => "%5", "from" => "work", "has_note" => true)
        expect(File.read(store.events_path("wr_1"))).not_to include("secret")
        expect(events.map(&:first)).to eq(["workflow_changed"])
        expect(events.first.last).to include("reason" => nil)
      end

      it "refuses what resume refuses, first" do
        start
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")

        expect { engine.park("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gate_waiting") }
        expect { engine.park("wr_1", from: "nope") }.to raise_error(Workspace::UsageError)
        expect(parked).to be_nil
      end

      it "stores nothing for a resume that would do nothing" do
        start

        run = engine.park("wr_1")

        expect(run["unchanged"]).to eq("an agent is working on step plan")
        expect(run).not_to have_key("parked")
      end

      it "skips left_alone for --from" do
        start

        expect(engine.park("wr_1", from: "plan")["parked"]).to include("from" => "plan")
      end

      it "answers unchanged for a second park and keeps the first as it was" do
        undelivered
        first = engine.park("wr_1", note: "first")["parked"]
        now[0] += 60

        run = engine.park("wr_1", note: "second", pane: "%9")

        expect(run["unchanged"]).to eq("a resume is already parked for pane %5")
        expect(parked).to eq(first)
      end

      it "answers unchanged for a second --from park too, and names the park's own pane" do
        undelivered
        first = engine.park("wr_1", from: "work", pane: "%7")["parked"]
        now[0] += 60

        run = engine.park("wr_1", from: "work")

        expect(run["unchanged"]).to eq("a resume is already parked for pane %7")
        expect(parked).to eq(first)
      end

      it "replaces a park past its limit that no tick settled, keeping its note" do
        undelivered
        first = engine.park("wr_1", note: "old note")["parked"]
        now[0] += described_class::PARK_SECONDS + 1

        run = engine.park("wr_1")

        expect(run["parked"]["id"]).not_to eq(first["id"])
        expect(run["parked"]["expires_at"]).to eq("2026-10-04T14:00:01Z")
        expect(run["pending_context"]).to eq(["Note from the person who resumed the run: old note"])
        expect(event_of("resume_parked_ended")).to include("how" => "expired")
      end

      it "refuses a pane another run has, now and not an hour from now" do
        undelivered
        panes.bind(workspace: "other", pane: "%9", run_id: "wr_2")
        store.on(:find) { |original, id| (id == "wr_2") ? {"state" => "running"} : original.call(id) }

        expect { engine.park("wr_1", pane: "%9") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("pane_has_run") }
        expect(parked).to be_nil
      end

      it "does not refuse the run's own pane" do
        undelivered

        expect(engine.park("wr_1", pane: "%5")["parked"]).to include("pane" => "%5")
      end

      it "takes a check that never reported back, as a resume does" do
        checking_run(started_at: "2026-10-04T10:00:00Z")

        expect(engine.park("wr_1")["parked"]).not_to be_nil
      end

      it "leaves a check still running alone, unless --from" do
        checking_run

        expect(engine.park("wr_1")["unchanged"]).to eq("the check of step verify is still running")
        expect(engine.park("wr_1", from: "build")["parked"]).to include("from" => "build")
      end
    end

    describe "what holds off while parked" do
      {
        "failed" => :failed_run, "waiting" => :undelivered, "turn_ended_incomplete" => :incomplete_run
      }.each do |name, setup|
        it "decides nothing on a Stop on a #{name} run" do
          send(setup)
          engine.park("wr_1")
          before = store.find("wr_1")

          engine.turn_ended("wr_1", pane: "%5")

          expect(store.find("wr_1").except("updated_at")).to eq(before.except("updated_at"))
        end
      end

      it "decides nothing on a Stop on a waiting_lock run" do
        lock_waiting_run
        engine.park("wr_2")
        before = store.find("wr_2")

        engine.turn_ended("wr_2", pane: "%6")

        expect(store.find("wr_2").except("updated_at")).to eq(before.except("updated_at"))
      end

      it "dispatches nothing on a tick of a lock-waiting run, even with the lock free" do
        lock_waiting_run
        engine.park("wr_2")
        engine.cancel("wr_1")
        kicks = panes.kicks.size

        expect(engine.tick("wr_2")).to be_nil

        expect(panes.kicks.size).to eq(kicks)
        expect(attempts("wr_2")).to eq(0)
      end

      it "reruns no lost check on a tick" do
        checking_run(started_at: "2026-10-04T10:00:00Z")
        engine.park("wr_1")

        expect(engine.tick("wr_1")).to be_nil
        expect(check_calls).to eq([])
      end

      it "survives a Stop and three ticks with no attempt added" do
        undelivered
        engine.park("wr_1")
        before = attempts

        engine.turn_ended("wr_1", pane: "%5")
        3.times do
          now[0] += 15
          engine.tick("wr_1")
        end

        expect(attempts).to eq(before)
        expect(parked).not_to be_nil
        expect(panes.kicks.size).to eq(1)
      end

      it "ignores a check's result and stops the check" do
        to_verify
        stops = []
        parking = lambda do |stop_when:, **|
          stops << stop_when.call
          engine.park("wr_1", from: "build")
          stops << stop_when.call
          {exit_code: 0, timed_out: false}
        end

        engine_with(checker: parking).turn_ended("wr_1", pane: "%5")

        expect(stops).to eq([false, true])
        expect(history).not_to include("check_finished")
        expect(store.find("wr_1")["steps"]["verify"]["state"]).to eq("checking")
        expect(parked).to include("from" => "build")
      end

      describe "a Stop from before the attempt began" do
        it "decides nothing with no turn_started" do
          start(single, inputs: {})
          artifact("out.md")

          run = engine.turn_ended("wr_1", pane: "%5", stopped_at: now.first - 1)

          expect(run["steps"]["work"]["state"]).to eq("running")
          expect(run["state"]).to eq("running")
        end

        it "decides as usual once the Stop is after it" do
          start(single, inputs: {})
          artifact("out.md")

          expect(engine.turn_ended("wr_1", pane: "%5", stopped_at: now.first + 1)["state"]).to eq("completed")
        end
      end
    end

    describe "#release_park" do
      it "does nothing for a stale id" do
        undelivered
        engine.park("wr_1")
        before = store.find("wr_1")

        run = engine.release_park("wr_1", "stale")

        expect(run).not_to have_key("unchanged")
        expect(store.find("wr_1").except("updated_at")).to eq(before.except("updated_at"))
        expect(panes.kicks.size).to eq(1)
      end

      it "dispatches, and the note reaches the attempt in no event" do
        undelivered
        id = engine.park("wr_1", note: "the secret word")["parked"]["id"]

        run = engine.release_park("wr_1", id)

        expect(run).to include("state" => "running", "reason" => nil)
        expect(run).not_to have_key("parked")
        expect(run["steps"]["work"]["attempts"].last["context"]).to eq(["Note from the person who resumed the run: the secret word"])
        expect(panes.kicks.size).to eq(2)
        expect(event_of("resume_parked_ended")).to include("how" => "released", "step" => "work")
        expect(File.read(store.events_path("wr_1"))).not_to include("secret")
      end

      it "carries out --from" do
        to_build
        id = engine.park("wr_1", from: "plan")["parked"]["id"]

        run = engine.release_park("wr_1", id)

        expect(run).to include("current" => "plan", "state" => "running")
        expect(run["steps"]["plan"]["attempts"].size).to eq(2)
      end

      it "carries out --pane" do
        undelivered
        id = engine.park("wr_1", pane: "%8")["parked"]["id"]

        run = engine.release_park("wr_1", id)

        expect(run["pane"]).to eq("%8")
        expect(panes.kicks.last).to include(pane: "%8")
      end

      it "carries out a stored turn_over, which decides the step" do
        start(single, inputs: {})
        artifact("out.md")
        id = engine.park("wr_1", turn_over: {"step" => "work", "attempt" => 1})["parked"]["id"]

        expect(engine.release_park("wr_1", id)["state"]).to eq("completed")
      end

      it "records a release that did nothing and keeps the note" do
        start(single, inputs: {})
        artifact("out.md")
        id = engine.park("wr_1", from: "work", note: "keep me")["parked"]["id"]
        store.update("wr_1") { |run| run["parked"]["from"] = nil }

        run = engine.release_park("wr_1", id)

        expect(run["unchanged"]).to eq("an agent is working on step work")
        expect(run).not_to have_key("parked")
        expect(run["pending_context"]).to eq(["Note from the person who resumed the run: keep me"])
        expect(event_of("resume_parked_ended")).to include("how" => "unchanged", "detail" => "an agent is working on step work")
      end

      it "leaves the park when the resume is refused" do
        undelivered
        id = engine.park("wr_1", from: "work")["parked"]["id"]
        store.update("wr_1") { |run| run["parked"]["from"] = "nope" }

        expect { engine.release_park("wr_1", id) }.to raise_error(Workspace::UsageError)

        expect(parked).to include("id" => id)
        expect(history).not_to include("resume_parked_ended")
      end

      it "takes the after_park mark off an attempt that was delivered" do
        undelivered
        id = engine.park("wr_1")["parked"]["id"]

        run = engine.release_park("wr_1", id)

        expect(run["steps"]["work"]["attempts"].last).not_to have_key("after_park")
      end

      it "marks the attempt while its line is on its way" do
        undelivered
        id = engine.park("wr_1", pane: "%5")["parked"]["id"]
        seen = nil
        allow(panes).to receive(:kick) do
          seen = store.find("wr_1")["steps"]["work"]["attempts"].last
          {ok: true}
        end

        engine.release_park("wr_1", id)

        expect(seen["after_park"]).to eq("expires_at" => "2026-10-04T13:00:00Z", "pane" => "%5", "retries" => 0)
      end
    end

    describe "a release that could not be typed" do
      def release_failing(code)
        panes.kick_result = {ok: false, code: code, message: "busy"}
        engine.release_park("wr_1", parked["id"])
      end

      %w[pane_busy restart_in_progress].each do |code|
        it "parks again on #{code} with the same limit, and keeps the note for the next attempt" do
          undelivered
          first = engine.park("wr_1", from: "work", note: "keep me", pane: "%5")["parked"]
          now[0] += 60

          run = release_failing(code)

          expect(run["parked"]).to include("expires_at" => first["expires_at"], "retries" => 1, "from" => nil, "note" => nil, "pane" => nil, "turn_over" => nil)
          expect(run["parked"]["id"]).not_to eq(first["id"])
          expect(run["pending_context"]).to eq(["Note from the person who resumed the run: keep me"])
          expect(run["steps"]["work"]["attempts"].last).to include("outcome" => "not_delivered").and(satisfy { |attempt| !attempt.key?("after_park") })
          expect(event_of("resume_parked")).to include("retry" => true, "pane" => "%5", "from" => nil, "has_note" => false)
        end
      end

      it "stops at the fourth failure, which stays the failure it is" do
        undelivered
        engine.park("wr_1")

        3.times { |n| expect(release_failing("pane_busy")["parked"]).to include("retries" => n + 1) }
        run = release_failing("pane_busy")

        expect(run).not_to have_key("parked")
        expect(run["reason"]["details"]).to include("error" => "pane_busy")
      end

      it "does not park again past the limit" do
        undelivered
        engine.park("wr_1")
        now[0] += described_class::PARK_SECONDS + 1

        expect(release_failing("pane_busy")).not_to have_key("parked")
      end

      it "does not park again on any other code" do
        undelivered
        engine.park("wr_1")

        run = release_failing("no_such_pane")

        expect(run).not_to have_key("parked")
        expect(run["reason"]).to include("code" => "pane_gone")
      end

      it "does not park a failed delivery that no park released" do
        undelivered

        expect(engine.resume("wr_1").tap { |run| expect(run["state"]).to eq("running") }).not_to have_key("parked")
        panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}

        expect(engine.resume("wr_1", from: "work")).not_to have_key("parked")
      end
    end

    describe "what ends a park" do
      it "a resume from elsewhere takes over, and the note stays for the attempt" do
        undelivered
        engine.park("wr_1", note: "parked note")

        run = engine.resume("wr_1", note: "own note")

        expect(run).not_to have_key("parked")
        expect(run["steps"]["work"]["attempts"].last["context"]).to eq(["Note from the person who resumed the run: parked note",
          "Note from the person who resumed the run: own note"])
        expect(event_of("resume_parked_ended")).to include("how" => "taken_over")
      end

      it "a resume from elsewhere that does nothing leaves the park" do
        start
        id = engine.park("wr_1", from: "plan")["parked"]["id"]

        run = engine.resume("wr_1")

        expect(run["unchanged"]).to eq("an agent is working on step plan")
        expect(parked).to include("id" => id)
      end

      it "approve moves on, and the note reaches the next step" do
        start
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")
        engine.park("wr_1", from: "plan", note: "parked note")

        run = engine.approve("wr_1")

        expect(run).not_to have_key("parked")
        expect(run["steps"]["build"]["attempts"].last["context"]).to eq(["Note from the person who resumed the run: parked note"])
        expect(event_of("resume_parked_ended")).to include("how" => "moved_on")
      end

      it "reject moves on, and the note reaches the step that runs again" do
        start
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")
        engine.park("wr_1", from: "plan", note: "parked note")

        run = engine.reject("wr_1", note: "no")

        expect(run).not_to have_key("parked")
        expect(run["steps"]["plan"]["attempts"].last["context"]).to eq(["The plan step was rejected at its gate: no",
          "Note from the person who resumed the run: parked note"])
        expect(event_of("resume_parked_ended")).to include("how" => "moved_on")
      end

      it "cancel ends it" do
        undelivered
        engine.park("wr_1")

        run = engine.cancel("wr_1")

        expect(run).not_to have_key("parked")
        expect(event_of("resume_parked_ended")).to include("how" => "ended")
      end

      it "a kill ends it" do
        undelivered
        engine.park("wr_1")

        engine.workspace_killed("app.worktree-x")

        expect(store.find("wr_1")).to include("state" => "cancelled").and(satisfy { |run| !run.key?("parked") })
      end
    end

    describe "#park_failed" do
      it "does nothing for a stale id" do
        undelivered
        engine.park("wr_1")
        before = store.find("wr_1")

        engine.park_failed("wr_1", "stale", code: "pane_gone", message: "gone")

        expect(store.find("wr_1").except("updated_at")).to eq(before.except("updated_at"))
      end

      it "leaves a running step and its attempt to be decided as usual" do
        to_build
        store.update("wr_1") { |run| run["reason"] = {"code" => "turn_ended_incomplete", "since" => "t", "details" => {}} }
        id = engine.park("wr_1", note: "keep me")["parked"]["id"]

        run = engine.park_failed("wr_1", id, code: "parked_timeout", message: "too long")

        expect(run).not_to have_key("parked")
        expect(run["state"]).to eq("waiting")
        expect(run["reason"]).to include("code" => "waiting_you")
        expect(run["reason"]["details"]).to eq("kind" => "dispatch", "step" => "build", "pane" => "%5", "workspace" => "app.worktree-x",
          "error" => "parked_timeout", "message" => "too long")
        expect(run["pending_context"]).to eq(["Note from the person who resumed the run: keep me"])
        expect(run["steps"]["build"]).to include("state" => "running")
        expect(lock_holder("test-db")).to include("run_id" => "wr_1")
        expect(event_of("resume_parked_ended")).to include("how" => "failed")

        expect(engine.turn_ended("wr_1", pane: "%5")["current"]).to eq("verify")
      end

      it "moves a failed step's failure into the pending context for the next attempt" do
        failed_run
        id = engine.park("wr_1")["parked"]["id"]

        run = engine.park_failed("wr_1", id, code: "not_an_agent", message: "the agent has exited")

        expect(run["pending_context"].first).to start_with("The last attempt of this step failed: its check exited 1")
        expect(run["reason"]["details"]).to include("error" => "not_an_agent", "kind" => "dispatch")
        expect(run["steps"]["work"]).to include("state" => "failed")
      end

      it "keeps the gate reason of a run waiting at a gate, and records the failure in the event" do
        start
        artifact("plan.md")
        engine.turn_ended("wr_1", pane: "%5")
        before = store.find("wr_1")["reason"]
        id = engine.park("wr_1", from: "plan", pane: "%9")["parked"]["id"]

        run = engine.park_failed("wr_1", id, code: "parked_timeout", message: "too long")

        expect(run).not_to have_key("parked")
        expect(run["reason"]).to eq(before)
        expect(run["reason"]["details"]).to include("kind" => "gate")
        expect(run["steps"]["plan"]["gate"]).to include("state" => "waiting")
        expect(event_of("resume_parked_ended")).to include("how" => "failed", "error" => "parked_timeout", "message" => "too long")
      end

      it "leaves a waiting step waiting" do
        undelivered
        id = engine.park("wr_1", pane: "%7")["parked"]["id"]

        run = engine.park_failed("wr_1", id, code: "parked_timeout", message: "too long")

        expect(run["steps"]["work"]).to include("state" => "waiting")
        expect(run["reason"]["details"]).to include("pane" => "%7", "error" => "parked_timeout")
      end

      it "reads a code for a gone pane as pane_gone" do
        undelivered
        id = engine.park("wr_1")["parked"]["id"]

        expect(engine.park_failed("wr_1", id, code: "pane_gone", message: "gone")["reason"]).to include("code" => "pane_gone")
      end

      it "gives up the queue place of a waiting_lock run, so the lock can't go to a run that won't use it" do
        lock_waiting_run
        id = engine.park("wr_2")["parked"]["id"]

        engine.park_failed("wr_2", id, code: "parked_timeout", message: "too long")
        engine.cancel("wr_1")

        expect(lock_holder("test-db")).to be_nil
      end
    end

    describe "#check_pane through a second run" do
      it "refuses a pane a park with no pane of its own targets" do
        undelivered
        engine.park("wr_1")
        panes.unbind("wr_1")

        expect { start(single, inputs: {}) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("pane_has_run") }
      end

      it "does not refuse a run its own park" do
        undelivered
        engine.park("wr_1")
        panes.unbind("wr_1")

        expect(engine.resume("wr_1", pane: "%5")).to include("state" => "running")
      end

      it "refuses a pane a park names, for a rebind by another run" do
        undelivered
        engine.park("wr_1", pane: "%8")
        store.update("wr_1") { |run| run["pane"] = "%5" }
        start(single, inputs: {}, pane: "%6")
        store.update("wr_2") { |run| run["reason"] = {"code" => "pane_gone", "since" => "t", "details" => {}} }

        expect { engine.resume("wr_2", pane: "%8") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("pane_has_run") }
      end

      it "does not count a park past its limit" do
        undelivered
        engine.park("wr_1")
        panes.unbind("wr_1")
        now[0] += described_class::PARK_SECONDS + 1

        expect(start(single, inputs: {}, workspace: "app.worktree-y")["id"]).to eq("wr_2")
      end
    end

    describe "a --from park over a checking step" do
      def parked_over_check
        checking_run
        engine.park("wr_1", from: "build")["parked"]["id"]
      end

      it "names the unrecorded check in the timeout message" do
        message = described_class.park_timeout_message("%5", checking: true)

        expect(message).to include("A check that finished while this was parked was not recorded; resume the run to run it again.")
        expect(described_class.park_timeout_message("%5")).not_to include("not recorded")
        expect(described_class.park_timeout_message("%5")).to start_with("the turn in pane %5 did not end within 1 hour, so nothing was typed.")
      end

      it "waits for a person after the timeout, and a plain resume is then allowed" do
        id = parked_over_check
        engine.park_failed("wr_1", id, code: "parked_timeout", message: described_class.park_timeout_message("%5", checking: true))

        expect(engine.tick("wr_1")).to be_nil
        expect(store.find("wr_1")["reason"]["details"]).to include("error" => "parked_timeout")

        run = engine.resume("wr_1")

        expect(run).not_to have_key("unchanged")
        expect(check_calls.size).to eq(1)
        expect(run["state"]).to eq("completed")
      end

      it "allows a plain resume once the park is past its limit, unsettled" do
        parked_over_check
        now[0] += described_class::PARK_SECONDS + 1

        run = engine.resume("wr_1")

        expect(run).not_to have_key("unchanged")
        expect(run).not_to have_key("parked")
      end
    end
  end

  describe "a rejected gate's record" do
    let(:two_steps) do
      definition(<<~YAML)
        steps:
          first:
            prompt: One.
          second:
            prompt: Two.
            gate: approve
          third:
            prompt: Three.
      YAML
    end

    def to_second_gate
      start(two_steps, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      engine.turn_ended("wr_1", pane: "%5")
    end

    it "stays during the first run again, and is gone after a resume of a failed rerun" do
      to_second_gate
      engine.reject("wr_1", note: "No.")

      expect(store.find("wr_1")["steps"]["second"]["gate"]).to include("state" => "rejected", "attempt" => 1)
      engine.report("wr_1", status: "fail", summary: "x")
      engine.turn_ended("wr_1", pane: "%5")
      engine.resume("wr_1")

      expect(store.find("wr_1")["steps"]["second"]).not_to have_key("gate")
    end

    it "is replaced by a waiting gate when the rerun passes" do
      to_second_gate
      engine.reject("wr_1", note: "No.")

      engine.turn_ended("wr_1", pane: "%5")

      expect(store.find("wr_1")["steps"]["second"]["gate"]).to include("state" => "waiting")
    end

    it "stays on the gated step after `reject --to` an earlier step, until that step runs again twice" do
      to_second_gate
      engine.reject("wr_1", note: "Redo.", to: "first")

      expect(store.find("wr_1")["steps"]["second"]["gate"]).to include("state" => "rejected", "attempt" => 1)
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["steps"]["second"]["gate"]).to include("state" => "rejected")
      expect(store.find("wr_1")["steps"]["second"]["attempts"].size).to eq(2)
    end
  end

  describe "the token budget" do
    let(:usages) { [] }
    let(:recorder) do
      queue = usages
      Class.new(Workspace::WorkflowAttemptRecord) do
        define_method(:finish) do |run:, step:, attempt:|
          done = super(run: run, step: step, attempt: attempt)
          queue.empty? ? done : Workspace::WorkflowRun::Attempt.from_h(done.to_h.merge("usage" => queue.shift))
        end
      end.new(guard: guard)
    end
    subject(:engine) { engine_with(attempt_record: recorder) }

    let(:two_steps) { definition("budget: {tokens: 1000}\nsteps:\n  a:\n    prompt: A\n    status: bin/check\n  b:\n    prompt: B\n    status: bin/check\n") }
    let(:three_checked) { definition("budget: {tokens: 1000}\nsteps:\n  a:\n    prompt: A\n    status: bin/check\n  b:\n    prompt: B\n    status: bin/check\n  c:\n    prompt: C\n    status: bin/check\n") }
    let(:looping) { definition("budget: {tokens: 1000}\nsteps:\n  build:\n    prompt: B\n  verify:\n    prompt: V\n    status: bin/check\n    on_fail: {goto: build, max: 3, context: fresh}\n") }
    let(:waiting_loop) { definition("budget: {tokens: 1000}\nsteps:\n  build:\n    prompt: B\n  verify:\n    prompt: V\n    status: bin/check\n    on_fail: {goto: build, max: 3, backoff: 2m}\n") }
    let(:gated) { definition("budget: {tokens: 1000}\nsteps:\n  plan:\n    prompt: P\n    produces: [plan.md]\n    gate: approve\n  build:\n    prompt: B\n") }
    let(:unbudgeted) { definition("steps:\n  a:\n    prompt: A\n    status: bin/check\n  b:\n    prompt: B\n    status: bin/check\n") }

    def tokens(count) = {"input_tokens" => count, "output_tokens" => 0}

    def respend(count, step: "a")
      store.update("wr_1") { |stored| stored["steps"][step]["attempts"].first["usage"] = tokens(count) }
    end

    def fail_check = (check_results << {exit_code: 1, timed_out: false})

    def kinds = history_lines.map { |line| line["type"] }

    # Step a passes with +used+ tokens; step b's line could not be typed.
    def undelivered_b(used = 300)
      usages << tokens(used)
      start(two_steps, inputs: {})
      panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}
      engine.turn_ended("wr_1", pane: "%5")
      panes.kick_result = {ok: true}
    end

    it "holds the next step once the budget is used, starts nothing, and keeps the step as it was" do
      usages << tokens(1200)
      start(two_steps, inputs: {})

      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting", "current" => "b")
      expect(run["reason"]).to include("code" => "budget_spent")
      expect(run["reason"]["details"]).to include("step" => "b", "used" => 1200, "allowance" => 1000, "needed" => 201, "suggested" => 100_000, "counted" => 1, "uncounted" => 0)
      expect(run["steps"]["b"]).to eq("state" => "pending", "attempts" => [])
      expect(run["budget_hold"]).to eq("pane" => "%5", "identity" => {"session" => "app", "pane_slot" => "app:0.1"})
      expect(panes.kicks.size).to eq(1)
      expect(kinds).to include("budget_spent")
    end

    it "lets the next step start while the budget has room, and runs a definition without a budget as before" do
      usages << tokens(400)
      start(two_steps, inputs: {})
      expect(engine.turn_ended("wr_1", pane: "%5")).to include("state" => "running", "current" => "b")

      usages << tokens(9_000_000)
      start(unbudgeted, inputs: {}, pane: "%6", workspace: "app.worktree-y")
      engine.turn_ended("wr_2", pane: "%6")
      expect(store.find("wr_2")).to include("state" => "running", "current" => "b").and(satisfy { |run| !run.key?("budget_hold") })
    end

    it "refuses a resume until --extra-tokens covers the overrun, then starts the held step" do
      usages << tokens(1200)
      start(two_steps, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      before = store.find("wr_1")
      lines = history_lines.size

      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error, /used its token budget \(1200 of 1000 tokens\)\. Pass --extra-tokens 100000 to continue \(201 is the least\)/) { |error|
        expect(error.code).to eq("budget_spent")
        expect(error.details).to include("run_id" => "wr_1", "step" => "b", "used" => 1200, "allowance" => 1000, "needed" => 201, "suggested" => 100_000, "tokens" => 1000, "extra_tokens" => 0)
      }
      expect { engine.resume("wr_1", extra_tokens: 200) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
      expect(store.find("wr_1")).to eq(before)
      expect(history_lines.size).to eq(lines)

      run = engine.resume("wr_1", extra_tokens: 201)

      expect(run).to include("state" => "running", "current" => "b", "extra_tokens" => 201, "reason" => nil)
      expect(run).not_to have_key("budget_hold")
      expect(run["steps"]["b"]["attempts"].map { |attempt| attempt["n"] }).to eq([1])
      expect(panes.kicks.size).to eq(2)
      expect(run["definition"]["budget"]).to eq("tokens" => 1000, "action" => "stop")
      expect(history_lines.find { |line| line["type"] == "budget_extended" }).to include("extra" => 201, "extra_tokens" => 201, "allowance" => 1201)
    end

    it "keeps the failure text and the fresh context of a retry the budget stopped" do
      usages.push(tokens(100), tokens(1500))
      start(looping, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      fail_check
      run = engine.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "waiting", "current" => "build", "loops" => {"verify->build" => 1})
      expect(run["reason"]["code"]).to eq("budget_spent")
      expect(run["budget_hold"]).to include("context" => "fresh", "pane" => "%5", "identity" => {"session" => "app", "pane_slot" => "app:0.1"}, "text" => a_string_matching(/sent the run back/))
      expect(run["pending_context"].join).to include("The verify step failed")
      expect(panes.kicks.size).to eq(2)
      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
      expect(store.find("wr_1")["budget_hold"]).to include("context" => "fresh")

      resumed = engine.resume("wr_1", extra_tokens: 601)

      expect(resumed).to include("state" => "running", "current" => "build")
      expect(resumed["steps"]["build"]["attempts"].last["context"].join).to include("The verify step failed")
      expect(panes.kicks.last).to include(fresh: true)
      expect(resumed["loops"]).to eq("verify->build" => 1)
    end

    describe "an on_fail retry after a backoff" do
      before do
        usages.push(tokens(100), tokens(1500))
        start(waiting_loop, inputs: {})
        engine.turn_ended("wr_1", pane: "%5")
        fail_check
        engine.turn_ended("wr_1", pane: "%5")
        expect(store.find("wr_1")["reason"]["code"]).to eq("retry_backoff")
        now[0] += 121
      end

      it "is held on a tick instead of starting" do
        run = engine.tick("wr_1")

        expect(run).to include("state" => "waiting", "current" => "build")
        expect(run["reason"]["code"]).to eq("budget_spent")
        expect(run).not_to have_key("backoff")
        expect(run["budget_hold"]).to include("pane" => "%5", "identity" => {"session" => "app", "pane_slot" => "app:0.1"})
        expect(panes.kicks.size).to eq(2)
        expect(engine.resume("wr_1", extra_tokens: 601)).to include("state" => "running", "current" => "build")
      end

      it "is held when the sweep's #retry_backoff starts it" do
        expect(engine.retry_backoff("wr_1", step: "verify", attempt: 1)).to eq(:held)

        expect(store.find("wr_1")["reason"]["code"]).to eq("budget_spent")
        expect(panes.kicks.size).to eq(2)
      end

      it "keeps the pane claim of the wait, so another run cannot take the pane while the hold stands" do
        engine.tick("wr_1")

        expect { start(waiting_loop, inputs: {}, pane: "%5", workspace: "app.worktree-b") }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("pane_has_run")
          expect(error.details).to include("run_id" => "wr_1")
        }
      end

      it "is not released into a pane tmux reused for another pane, until the person names the pane" do
        engine.tick("wr_1")
        panes.changed << "%5"
        before = store.find("wr_1")

        resumed = engine.resume("wr_1", extra_tokens: 601)

        expect(resumed["unchanged"]).to include("tmux restart")
        expect(store.find("wr_1")).to eq(before)
        expect(panes.kicks.size).to eq(2)
        expect(engine.resume("wr_1", pane: "%5", extra_tokens: 601)).to include("state" => "running", "current" => "build", "extra_tokens" => 601)
      end

      it "holds a resume --from over a reused pane or a pane another run took, as a plain resume is held" do
        engine.tick("wr_1")
        panes.changed << "%5"
        before = store.find("wr_1")

        expect(engine.resume("wr_1", from: "build", extra_tokens: 601)["unchanged"]).to include("tmux restart")
        expect(store.find("wr_1")).to eq(before)

        start(waiting_loop, inputs: {}, pane: "%5", workspace: "app.worktree-b")
        panes.changed.clear
        kicks = panes.kicks.size
        before = store.find("wr_1")

        expect(engine.resume("wr_1", from: "build", extra_tokens: 601)["unchanged"]).to include("wr_2")
        expect(store.find("wr_1")).to eq(before)
        expect(panes.kicks.size).to eq(kicks)
      end

      it "follows a binding that restore moved: a plain resume goes to the bound pane, not the stored one" do
        engine.tick("wr_1")
        panes.changed << "%5"
        panes.bound["%7"] = {run_id: "wr_1", workspace: "app.worktree-x"}

        run = engine.resume("wr_1", extra_tokens: 601)

        expect(run).to include("state" => "running", "current" => "build")
        expect(run).not_to have_key("unchanged")
      end

      it "lets resume --from with --pane name a pane tmux reused as the proof, and goes on in it" do
        engine.tick("wr_1")
        panes.changed << "%5"

        run = engine.resume("wr_1", from: "build", pane: "%5", extra_tokens: 601)

        expect(run).to include("state" => "running", "current" => "build", "extra_tokens" => 601)
        expect(run).not_to have_key("unchanged")
        expect(panes.kicks.last).to include(pane: "%5")
      end

      it "is not released into a pane another run took after the hold lost its claim" do
        engine.tick("wr_1")
        panes.changed << "%5"
        start(waiting_loop, inputs: {}, pane: "%5", workspace: "app.worktree-b")
        panes.changed.clear
        kicks = panes.kicks.size
        before = store.find("wr_1")

        resumed = engine.resume("wr_1", extra_tokens: 601)

        expect(resumed["unchanged"]).to include("wr_2")
        expect(store.find("wr_1")).to eq(before)
        expect(panes.kicks.size).to eq(kicks)
      end

      it "alerts once when the hold begins, and not again for a tick, a refused resume or a sweep's look" do
        sent = []
        settings = {notify: "notify-me", workflow: %w[failed]}
        alerts = Workspace::WorkflowAlerts.new(alert_config: instance_double(Workspace::AlertConfig, for_workspace: settings), spawner: ->(_argv, env, _log) { sent << env })
        watched = engine_with(attempt_record: recorder, alerts: alerts)

        watched.tick("wr_1")
        watched.tick("wr_1")
        expect { watched.resume("wr_1") }.to raise_error(Workspace::Error)
        expect(watched.retry_backoff("wr_1", step: "verify", attempt: 1)).to eq(:moved_on)

        expect(sent.size).to eq(1)
        expect(sent.first).to include("WORKSPACE_ALERT_EVENT" => "failed", "WORKSPACE_ALERT_REASON" => "budget_spent", "WORKSPACE_ALERT_STEP" => "build")
        expect(sent.first["WORKSPACE_ALERT_TEXT"]).to include("token budget")
      end

      it "is refused to a resume that skips the wait, until --extra-tokens covers it" do
        now[0] -= 121
        before = store.find("wr_1")

        expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
        expect(store.find("wr_1")).to eq(before)

        expect(engine.resume("wr_1", extra_tokens: 601)).to include("state" => "running", "current" => "build", "extra_tokens" => 601)
      end
    end

    it "alerts when a passed step cannot go on, with the same event a failed check uses" do
      sent = []
      alerts = Workspace::WorkflowAlerts.new(alert_config: instance_double(Workspace::AlertConfig, for_workspace: {notify: "n", workflow: %w[failed]}), spawner: ->(_argv, env, _log) { sent << env })
      usages << tokens(1200)
      start(two_steps, inputs: {})

      engine_with(attempt_record: recorder, alerts: alerts).turn_ended("wr_1", pane: "%5")

      expect(sent.map { |env| env["WORKSPACE_ALERT_REASON"] }).to eq(["budget_spent"])
    end

    it "does not hold a line the sweep types again, which spent nothing new" do
      undelivered_b
      respend(5000)
      now[0] += 61
      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }

      expect(engine.redeliver("wr_1", step: "b", attempt: 1)).to eq(:redelivered)

      run = store.find("wr_1")
      expect(run).to include("state" => "running")
      expect(run).not_to have_key("budget_hold")
      expect(run["steps"]["b"]["attempts"].last).to include("n" => 2, "redelivery" => 1)
    end

    it "does not hold a step that was queued for a lock when the lock is given up" do
      usages << tokens(100)
      locked = definition("budget: {tokens: 1000}\nsteps:\n  verify:\n    prompt: P\n    uses: [test-db]\n")
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
      store.update("wr_2") { |stored| stored["steps"]["verify"]["attempts"] << {"n" => 1, "outcome" => "failed", "ended_at" => now.first.iso8601, "usage" => tokens(5000)} }
      expect(Workspace::WorkflowBudget.reading(store.find("wr_2"))["spent"]).to be(true)
      engine.cancel("wr_1")
      now[0] += 30

      run = engine.tick("wr_2")

      expect(run).to include("state" => "running", "reason" => nil)
      expect(run).not_to have_key("budget_hold")
      expect(lock_holder("test-db")).to include("run_id" => "wr_2")
    end

    it "takes the retry's text off a step that --from names instead, and keeps it when the held step goes on" do
      usages.push(tokens(100), tokens(1500))
      start(looping, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      fail_check
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["pending_context"].join).to include("sent the run back")

      run = engine.resume("wr_1", from: "verify", extra_tokens: 601)

      expect(run["current"]).to eq("verify")
      expect(run["steps"]["verify"]["attempts"].last["context"].join).not_to include("sent the run back")
    end

    it "does the same for a hold that followed a backoff" do
      usages.push(tokens(100), tokens(1500))
      start(waiting_loop, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      fail_check
      engine.turn_ended("wr_1", pane: "%5")
      now[0] += 121
      engine.tick("wr_1")
      expect(store.find("wr_1")["pending_context"].join).to include("sent the run back")

      run = engine.resume("wr_1", from: "verify", extra_tokens: 601)

      expect(run["steps"]["verify"]["attempts"].last["context"].join).not_to include("sent the run back")
    end

    describe "a resume that starts no attempt, with the budget used" do
      def spent_passed_a
        usages << tokens(1500)
        start(two_steps, inputs: {})
        store.update("wr_1") do |run|
          attempt = run["steps"]["a"]["attempts"].first
          attempt.merge!("outcome" => "passed", "ended_at" => now.first.iso8601, "usage" => tokens(1500))
          run["steps"]["a"]["state"] = "passed"
          run["state"] = "waiting"
          run["reason"] = nil
        end
      end

      def expect_not_charged(run)
        expect(run).not_to have_key("extra_tokens")
        expect(history).not_to include("budget_extended")
      end

      it "moves a passed step on without a refusal, holds the next step, and ignores --extra-tokens" do
        spent_passed_a

        run = engine.resume("wr_1", extra_tokens: 5)

        expect(run).to include("current" => "b")
        expect(run["reason"]["code"]).to eq("budget_spent")
        expect_not_charged(run)
      end

      it "looks at a check that never reported without a refusal, and ignores --extra-tokens" do
        spent_passed_a
        store.update("wr_1") do |run|
          run["steps"]["a"]["state"] = "checking"
          run["steps"]["a"]["attempts"].first["check"] = {"started_at" => "2026-10-04T10:00:00Z"}
          run["steps"]["a"]["attempts"].first.delete("outcome")
        end

        run = engine.resume("wr_1", extra_tokens: 5)

        expect(run["steps"]["a"]["state"]).to eq("passed")
        expect_not_charged(run)
      end

      it "asks for a lock again without a refusal, and ignores --extra-tokens" do
        locked = definition("budget: {tokens: 1000}\nsteps:\n  verify:\n    prompt: P\n    uses: [test-db]\n")
        start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
        start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
        store.update("wr_2") { |run| run["steps"]["verify"]["attempts"] << {"n" => 1, "outcome" => "failed", "usage" => tokens(5000)} }

        run = engine.resume("wr_2", extra_tokens: 5)

        expect(run["reason"]["code"]).to eq("waiting_lock")
        expect(run).not_to have_key("extra_tokens")
        expect(history("wr_2")).not_to include("budget_extended")
      end
    end

    it "counts the attempt a --pane resume replaces, which has tokens and no outcome, so it cannot slip past the budget" do
      start(two_steps, inputs: {})
      store.update("wr_1") { |run| run["steps"]["a"]["attempts"].first["usage"] = tokens(1500) }
      before = store.find("wr_1")

      expect { engine.resume("wr_1", pane: "%5") }.to raise_error(Workspace::Error) { |error|
        expect(error.code).to eq("budget_spent")
        expect(error.details).to include("used" => 1500, "uncounted" => 0)
      }
      expect(store.find("wr_1")).to eq(before)

      run = engine.resume("wr_1", pane: "%5", extra_tokens: 501)

      expect(run["steps"]["a"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
      expect(run).to include("state" => "running", "extra_tokens" => 501)
    end

    it "refuses --from while the budget is used, and starts the step again with --extra-tokens" do
      usages << tokens(1500)
      start(two_steps, inputs: {})
      fail_check
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["reason"]["code"]).to eq("failed_check")

      expect { engine.resume("wr_1", from: "a") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
      expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }

      expect(engine.resume("wr_1", from: "a", extra_tokens: 501)).to include("state" => "running", "current" => "a", "extra_tokens" => 501)
    end

    it "refuses a reject past the budget, and holds the step after an approve" do
      usages << tokens(1500)
      start(gated, inputs: {})
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")
      expect(store.find("wr_1")["reason"]).to include("code" => "waiting_you")

      expect { engine.reject("wr_1", note: "again") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
      expect(store.find("wr_1")["steps"]["plan"]["gate"]["state"]).to eq("waiting")

      approved = engine.approve("wr_1")

      expect(approved).to include("state" => "waiting", "current" => "build")
      expect(approved["reason"]["code"]).to eq("budget_spent")
      expect(approved["steps"]["plan"]["gate"]["state"]).to eq("approved")
    end

    it "takes --extra-tokens on a reject" do
      usages << tokens(1500)
      start(gated, inputs: {})
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      run = engine.reject("wr_1", note: "again", extra_tokens: 501)

      expect(run).to include("state" => "running", "current" => "plan", "extra_tokens" => 501)
    end

    describe "a parked resume" do
      it "is refused at park time while the budget is used, and carries --extra-tokens to the release" do
        undelivered_b
        respend(5000)

        expect { engine.park("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
        expect(store.find("wr_1")).not_to have_key("parked")

        parked = engine.park("wr_1", extra_tokens: 4001)

        expect(parked["parked"]).to include("extra_tokens" => 4001)
        expect(parked).not_to have_key("extra_tokens")
        expect(engine.release_park("wr_1", parked["parked"]["id"])).to include("state" => "running", "extra_tokens" => 4001)
        expect(history_lines.count { |line| line["type"] == "budget_extended" }).to eq(1)
      end

      it "is refused on release when the budget filled in the meantime, and stays parked" do
        undelivered_b
        id = engine.park("wr_1")["parked"]["id"]
        respend(5000)

        expect { engine.release_park("wr_1", id) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }

        expect(store.find("wr_1")["parked"]["id"]).to eq(id)
      end

      it "is not charged or held again when the line could not be typed and the park is made again" do
        undelivered_b
        respend(5000)
        parked = engine.park("wr_1", extra_tokens: 4001)["parked"]
        panes.kick_result = {ok: false, code: "pane_busy", message: "busy"}

        again = engine.release_park("wr_1", parked["id"])

        expect(again["parked"]).to include("retries" => 1)
        expect(again["parked"]).not_to have_key("extra_tokens")
        panes.kick_result = {ok: true}
        respend(99_000)

        run = engine.release_park("wr_1", again["parked"]["id"])

        expect(run).to include("state" => "running", "extra_tokens" => 4001)
        expect(run).not_to have_key("budget_hold")
        expect(history_lines.count { |line| line["type"] == "budget_extended" }).to eq(1)
      end
    end

    describe "attempts whose usage is null" do
      it "does not stop a run none of whose attempts could be counted" do
        usages << nil
        start(two_steps, inputs: {})

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run).to include("state" => "running", "current" => "b")
        expect(Workspace::WorkflowBudget.reading(run)).to include("used" => 0, "counted" => 0, "uncounted" => 1, "measured" => false, "spent" => false)
      end

      it "stops when what was counted is already over, and says how many attempts were not" do
        usages.push(nil, tokens(1500))
        start(three_checked, inputs: {})
        engine.turn_ended("wr_1", pane: "%5")

        run = engine.turn_ended("wr_1", pane: "%5")

        expect(run["reason"]["code"]).to eq("budget_spent")
        expect(run["reason"]["details"]).to include("used" => 1500, "counted" => 1, "uncounted" => 1)
        expect { engine.resume("wr_1") }.to raise_error(Workspace::Error, /1500 of 1000 tokens at least/)
      end
    end

    it "drops the hold when the run is cancelled" do
      usages << tokens(1200)
      start(two_steps, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")

      expect(engine.cancel("wr_1")).to include("state" => "cancelled").and(satisfy { |run| !run.key?("budget_hold") })
    end

    it "ignores --extra-tokens for a run without a budget" do
      usages << tokens(100)
      start(unbudgeted, inputs: {})
      engine.turn_ended("wr_1", pane: "%5")
      fail_check
      engine.turn_ended("wr_1", pane: "%5")

      expect(engine.resume("wr_1", extra_tokens: 5)).not_to have_key("extra_tokens")
    end
  end
end
