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
