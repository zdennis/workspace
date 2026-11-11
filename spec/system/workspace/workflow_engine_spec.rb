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
  let(:store) { Interceptable.subclass(Workspace::WorkflowRunStore, :change, :run).new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
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
      check_calls << args.merge(state_during: stored_run(store, "wr_1")["steps"][stored_run(store, "wr_1")["current"]]["state"])
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
        expect(stored_run(store, "wr_1")["base_sha"]).to eq(run["base_sha"])
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
      edit_run(store, "wr_1") { |stored| stored.delete("base_sha") }

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
      expect(stored_run(store, "wr_1")["state"]).to eq("completed")
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
      expect(stored_run(store, "wr_1")["base_guard"]).to eq(run["base_guard"])
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
        edit_run(store, "wr_1") { |run| run["base_guard"] = run["base_guard"].except("config_format").merge("config_sha256" => "0" * 64) }

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

      expect(stored_run(store, "wr_1")["base_sha"]).to eq(base)
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
        expect(going_runs(store)).to eq([])
      end
    end
  end
end
