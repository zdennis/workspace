require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"

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
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
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
  let(:events) { [] }
  let(:event_log) do
    log = instance_double(Workspace::EventLog)
    allow(log).to receive(:record) { |type:, project:, data:| events << [type, project, data] }
    log
  end
  let(:stopped) { [] }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}) }
  subject(:engine) do
    described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, excludes: Workspace::GitExclude.new(git: git),
      env_stopper: ->(**args) { stopped << args }, event_log: event_log, task_store: task_store, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    system("git", "-C", worktree, "init", "-q", "-b", "feature/x", exception: true)
    system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
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

  def start(definition = three_steps, inputs: {"task" => "X-1"}, pane: "%5", workspace: "app.worktree-x", **rest)
    engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, **rest)
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
      commands_config: commands_config, lineage: lineage, git: git, excludes: Workspace::GitExclude.new(git: git),
      clock: -> { now.first }, **overrides)
  end

  def lock_holder(name)
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status(name).dig(name, "holder")
  end

  def history(run_id = "wr_1")
    File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line)["type"] }
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
    it "writes the run, the first step's instructions and the pane's binding, then types one line into the pane" do
      run = start(note: "Keep it small.")
      prompt = File.join(worktree, ".workflow", "wr_1", "steps", "plan.1.prompt.md")

      expect(run).to include("id" => "wr_1", "workflow" => "flow", "workspace" => "app.worktree-x", "project" => "app",
        "worktree" => worktree, "task" => "t1", "inputs" => {"task" => "X-1"}, "state" => "running", "current" => "plan",
        "pane" => "%5", "reason" => nil, "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"),
        "definition_source" => "global", "definition_sha256" => three_steps.sha256)
      expect(run["definition"]).to eq(three_steps.to_h)
      expect(run["steps"]["plan"]).to eq("state" => "running", "attempts" => [
        {"n" => 1, "started_at" => "2026-10-04T12:00:00.000Z", "context" => [], "prompt_file" => prompt}
      ])
      expect(File.read(prompt)).to eq(
        "Work on X-1 in app.worktree-x on feature/x.\n\n" \
        "Write #{worktree}/.workflow/wr_1/plan.md for run wr_1.\n\n" \
        "This step is finished when your turn ends and these files exist, written during this attempt: #{worktree}/.workflow/wr_1/plan.md.\n\n" \
        "Note for this run: Keep it small.\n"
      )
      expect(panes.bound).to eq("%5" => {workspace: "app.worktree-x", run_id: "wr_1", step: "plan", attempt: 1,
                                         instructions: prompt, artifacts: File.join(worktree, ".workflow", "wr_1")})
      expect(panes.kicks).to eq([{workspace: "app.worktree-x", pane: "%5", text: "Read #{prompt} and follow it.", fresh: true}])
      expect(store.find("wr_1")).to eq(run)
      expect(history).to eq(%w[run_started step_dispatched])
    end

    it "keeps its files out of `git status`, in a real repository" do
      start

      status, = Open3.capture2("git", "-C", worktree, "status", "--porcelain")
      expect(status).to eq("")
      expect(File.read(File.join(worktree, ".git", "info", "exclude")).lines.map(&:chomp)).to include("/.workflow/")
    end

    it "composes the default packs, then the workflow's and the step's layers, for the run's checkout" do
      start

      expect(composer.calls.last).to include(packs: nil, cwd: worktree, attempt: [])
      expect(composer.calls.last[:workflow]).to eq("name" => "flow", "include" => [], "text" => "Work on X-1 in app.worktree-x on feature/x.")
      expect(composer.calls.last[:step]).to include("name" => "plan", "include" => [])
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

    it "refuses an input the workflow doesn't have" do
      expect { start(inputs: {"task" => "X", "colour" => "red"}) }
        .to raise_error(Workspace::UsageError, 'Workflow flow has no input "colour" (inputs: task).')
    end

    it "refuses a workflow whose check names a command the project has not set" do
      commands[:test] = nil

      expect { start }.to raise_error(Workspace::Error, /checks a step with the project's test command, and app has none\. Set it with: workspace config set commands\.test "COMMAND" --name app/) { |error|
        expect(error.code).to eq("workflow_command_unset")
        expect(error.details).to eq("workflow" => "flow", "project" => "app", "commands" => ["test"])
      }
      expect(store.active).to eq([])
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
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(a_string_ending_with("b.1.prompt.md"), anything, anything).and_raise(Errno::ENOSPC)

      run = engine.turn_ended("wr_1")

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
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(a_string_ending_with("b.1.prompt.md"), anything, anything)
        .and_raise(Encoding::UndefinedConversionError, "\"\\xC3\" from ASCII-8BIT to UTF-8")

      run = engine.turn_ended("wr_1")

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

    it "runs the step's check with the project's command while the step is `checking`, outside the run's lock" do
      to_verify
      events.clear

      run = engine.turn_ended("wr_1", pane: "%5")

      log = File.join(worktree, ".workflow", "wr_1", "steps", "verify.1.check.log")
      expect(check_calls).to eq([{command: "bundle exec rspec", cwd: worktree, timeout: 300.0, log: log, state_during: "checking"}])
      expect(run["steps"]["verify"]["attempts"].last["check"]).to eq("started_at" => "2026-10-04T12:00:00Z", "log" => log,
        "ended_at" => "2026-10-04T12:00:00Z", "exit_code" => 0, "timed_out" => false)
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
      expect(history.last(4)).to eq(%w[check_finished step_failed step_looped step_dispatched])
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
        "max_attempts" => 6, "cause" => "check", "exit_code" => 2, "timed_out" => false,
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
        commands_config: commands_config, lineage: lineage, git: git, excludes: Workspace::GitExclude.new(git: git), clock: -> { now.first })

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
        commands_config: commands_config, lineage: lineage, git: git, excludes: Workspace::GitExclude.new(git: git), clock: -> { now.first })

      run = moved.turn_ended("wr_1", pane: "%5")

      expect(run).to include("state" => "running", "current" => "build")
      expect(run["steps"]["verify"]["state"]).to eq("checking")
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
        "holder" => {"run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-a", "worktree" => worktree, "kind" => "run"}
      })
      expect(panes.kicks.size).to eq(1)
      expect(events.last(2).map(&:first)).to eq(%w[lock_wait_started workflow_changed])
      expect(events[-2]).to eq(["lock_wait_started", "app", {"lock" => "test-db", "run_id" => "wr_2", "step" => "verify",
                                                             "workspace" => "app.worktree-b", "position" => 1,
                                                             "holder" => {"pane" => "%5", "worktree" => worktree, "run_id" => "wr_1", "step" => "verify"}}])
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
      failing = described_class.new(store: store, resources: resources, composer: composer, panes: panes, checker: checker,
        commands_config: commands_config, lineage: lineage, git: git, excludes: Workspace::GitExclude.new(git: git),
        env_stopper: ->(**) { raise Workspace::Error, "Could not read the lock store" }, clock: -> { now.first })
      two = definition("steps:\n  a:\n    prompt: P\n    uses: [devenv]\n  b:\n    prompt: P\n")
      failing.start(definition: two, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
      Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
        .delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 500, started: "start-500", pgid: 500})

      run = failing.turn_ended("wr_1")

      expect(run).to include("current" => "b", "state" => "running", "reason" => nil)
      expect(panes.kicks.size).to eq(2)
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
    end

    it "refuses to approve or reject a run that is not at a gate" do
      [-> { engine.approve("wr_1") }, -> { engine.reject("wr_1", note: "no") }].each do |call|
        expect(&call).to raise_error(Workspace::Error, "Run wr_1 is not waiting at a gate (step plan is running).") { |error|
          expect(error.code).to eq("gate_not_waiting")
          expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "state" => "running")
        }
      end
    end

    it "runs the gated step again when rejected, with the note" do
      engine.turn_ended("wr_1", pane: "%5")

      run = engine.reject("wr_1", note: "Too big; split it.")

      expect(run).to include("state" => "running", "current" => "plan", "reason" => nil)
      expect(run["steps"]["plan"]).not_to have_key("gate")
      expect(run["steps"]["plan"]["attempts"].last).to include("n" => 2, "context" => ["The plan step was rejected at its gate: Too big; split it."])
      expect(File.read(run["steps"]["plan"]["attempts"].last["prompt_file"])).to include("The plan step was rejected at its gate: Too big; split it.")
    end

    it "refuses to reject to a step after the gated one" do
      engine.turn_ended("wr_1", pane: "%5")

      expect { engine.reject("wr_1", note: "no", to: "build") }
        .to raise_error(Workspace::UsageError, '--to must be plan or a step before it (plan), got "build".')
      expect(store.find("wr_1")["steps"]["plan"]["gate"]["state"]).to eq("waiting")
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
      panes.kick_result = nil
      allow(panes).to receive(:kick).and_raise(Interrupt)
      expect { start }.to raise_error(Interrupt)
      left = store.find("wr_1")
      expect(left).to include("state" => "waiting", "artifacts_dir" => File.join(worktree, ".workflow", "wr_1"))
      expect(left["reason"]).to include("code" => "waiting_you")
      expect(left["reason"]["details"]).to include("kind" => "dispatch", "error" => "not_started")
      allow(panes).to receive(:kick).and_call_original
      panes.kick_result = {ok: true}

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

  describe "#tick for a check that never reported back" do
    it "runs it again once it is past its time limit, and not before" do
      to_verify
      store.update("wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => "2026-10-04T12:00:00Z"}
      end
      now[0] += 300

      expect(engine.tick("wr_1")).to be_nil

      now[0] += 61
      expect(engine.tick("wr_1")["state"]).to eq("completed")
    end
  end

  describe "a check whose run moves on while it runs" do
    it "is told to stop once the run is cancelled, on another step, or on another attempt, and not before" do
      to_verify
      engine.turn_ended("wr_1", pane: "%5")
      stop_when = stop_whens.last
      to_checking = lambda do |attempt: 1|
        store.update("wr_2") do |run|
          run["current"] = "verify"
          run["steps"]["verify"] = {"state" => "checking", "attempts" => [{"n" => attempt, "started_at" => "2026-10-04T12:00:00Z"}]}
        end
      end

      # The first run is finished by now: its check, were it still going, is not wanted.
      expect(stop_when.call).to be true

      start(pane: "%6")
      second = engine_with.send(:finish_check, "wr_2", {"step" => "verify", "attempt" => 1, "command" => "true", "timeout" => 5, "log" => "x", "cwd" => worktree})
      expect(second).to include("id" => "wr_2")
      wanted = stop_whens.last
      expect(wanted.call).to be true # wr_2 is on plan, not checking verify

      to_checking.call
      expect(wanted.call).to be false
      to_checking.call(attempt: 2)
      expect(wanted.call).to be true
      to_checking.call
      store.update("wr_2") { |run| run["current"] = "build" }
      expect(wanted.call).to be true
    end

    it "is told to stop when the run is cancelled while it runs, though the run still reads as checking that attempt" do
      to_verify
      asked = nil
      cancelling = lambda do |stop_when:, **|
        before = stop_when.call
        engine.cancel("wr_1")
        asked = [before, stop_when.call]
        {exit_code: nil, timed_out: false, error: "stopped: the run moved on"}
      end

      engine_with(checker: cancelling).turn_ended("wr_1", pane: "%5")

      expect(asked).to eq([false, true])
      expect(store.find("wr_1")["steps"]["verify"]).to include("state" => "checking")
    end

    it "is not stopped for a run file that can't be read just then" do
      to_verify
      engine.turn_ended("wr_1", pane: "%5")
      allow(store).to receive(:find).and_raise(Workspace::Error, "Could not access the workflow run store")

      expect(stop_whens.last.call).to be false
    end
  end

  describe "#tick while another process is changing the run" do
    it "does nothing and does not wait" do
      locked = definition("steps:\n  verify:\n    prompt: P\n    uses: [test-db]\n")
      start(locked, inputs: {}, pane: "%5", workspace: "app.worktree-a")
      start(locked, inputs: {}, pane: "%6", workspace: "app.worktree-b")
      engine.cancel("wr_1")

      File.open(File.join(runs_dir, "wr_2.lock"), File::RDWR | File::CREAT) do |held|
        held.flock(File::LOCK_EX)
        # A tick that waited for the lock would wait for this spec, for good.
        expect(Timeout.timeout(5) { engine.tick("wr_2") }).to be_nil
      end
      expect(store.find("wr_2")["reason"]["code"]).to eq("waiting_lock")
    end
  end

  describe "#report" do
    it "records what the agent says on its attempt and moves nothing" do
      start
      events.clear

      result = engine.report("wr_1", status: "pass", summary: "Plan written.")

      expect(result).to eq("run_id" => "wr_1", "step" => "plan", "attempt" => 1,
        "reported" => {"status" => "pass", "summary" => "Plan written.", "at" => "2026-10-04T12:00:00Z"})
      expect(store.find("wr_1")["steps"]["plan"]["attempts"].last["reported"])
        .to eq("status" => "pass", "summary" => "Plan written.", "at" => "2026-10-04T12:00:00Z")
      expect(store.find("wr_1")["steps"]["plan"]["state"]).to eq("running")
      expect(events).to eq([])
    end

    it "takes a report while the step's check runs" do
      to_verify
      store.update("wr_1") { |run| run["steps"]["verify"]["state"] = "checking" }

      expect(engine.report("wr_1", status: "pass")).to include("step" => "verify")
    end

    it "refuses when the step is not being worked on" do
      start
      artifact("plan.md")
      engine.turn_ended("wr_1", pane: "%5")

      expect { engine.report("wr_1", status: "pass") }
        .to raise_error(Workspace::Error, "Step plan of run wr_1 is passed, so there is nothing to report on.") { |error|
          expect(error.code).to eq("step_not_running")
          expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "state" => "passed")
        }
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
      allow(store).to receive(:update).and_wrap_original do |original, id, **options, &block|
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
      %i[cancel tick turn_ended approve].each do |verb|
        expect { engine.public_send(verb, "wr_1") }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("unknown_run")
          expect(error.details).to eq("run_id" => "wr_1", "path" => path)
        }
      end
    end
  end
end
