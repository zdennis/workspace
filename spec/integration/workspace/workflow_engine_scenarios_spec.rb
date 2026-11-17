require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Engine features no preset sets (on_fail backoff and log_tail, the token budget, the run timeout, a step's
# on_timeout, stall and redeliver) walked through on throwaway definitions. Events and states are asserted, not
# goldens. The first group plays the simulator; the second runs a real sweep over fake panes.
RSpec.describe "engine scenarios on a throwaway definition" do
  describe "in the simulator" do
    let(:base) { File.realpath(Dir.mktmpdir("wf-scenarios")) }
    # Kept until the example ends, so the run's store and prompt files can be read after the simulation.
    let(:tmpdir) { ->(prefix, &block) { block.call(Dir.mktmpdir(prefix, base)) } }
    let(:answers) { [] }
    let(:elapse) { {} }
    let(:stores) { [] }
    let(:people) { [] }
    let(:simulator) do
      factory = lambda do |**parts|
        stores << parts[:store]
        PersonAtTheRun.new(Workspace.build_workflow_engine(**parts), store: parts[:store], clock: parts[:clock], answers: answers, elapse: elapse).tap { |person| people << person }
      end
      Workspace::WorkflowSimulator.new(engine_factory: factory, tmpdir: tmpdir)
    end

    after { FileUtils.rm_rf(base) }

    def definition(top: "", on_fail: "{goto: build, max: 1, log_tail: 5, backoff: 2m}")
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "file", path: nil)
        schema_version: 1
        id: flow
        title: Flow
        #{top}
        steps:
          build:
            prompt: Build it.
            produces: [build.md]
          verify:
            prompt: Verify it.
            produces: [verify.md]
            status: {run: "true"}
            on_fail: #{on_fail}
      YAML
    end

    def play(definition, steps)
      script = Workspace::WorkflowSimScript.parse(JSON.generate("steps" => steps), definition: definition.to_h, source: "s.yml")
      simulator.call(definition: definition, script: script)
    end

    def person = people.first

    def types(result) = result["transitions"].map { |each| each["type"] }

    def events(result, type) = result["transitions"].select { |each| each["type"] == type }

    def outcomes(result, id) = result["steps"].find { |each| each["id"] == id }["attempts"].map { |each| each["outcome"] }

    def prompt(step, attempt)
      Dir.glob(File.join(base, "workspace-simulate*", "checkout", ".workflow", Workspace::WorkflowSimulator::RUN_ID, "steps", "#{step}.#{attempt}.prompt.md")).first.then { |file| File.read(file) }
    end

    it "waits out an on_fail backoff, hands the retry the check's log tail, and reads a flaky check and a resume through stats" do
      # verify's check fails on attempts 1 and 2: the first sends the run back to build after a 2 minute backoff,
      # the second spends on_fail's one loop, so the run stops at failed_check for a person. The resume names no
      # step, so the engine records it against verify.
      answers.push({on: "failed_check", resume: {}})
      result = play(definition, "verify" => [{"check" => "fail", "log" => "FLAKY-LINE-ONE\nFLAKY-LINE-TWO"}, {"check" => "fail", "log" => "again"}, {}])

      expect(person.answered).to eq([["failed_check", {}]])
      expect(result["outcome"]).to eq("completed")
      expect(outcomes(result, "build")).to eq(%w[passed passed])
      expect(outcomes(result, "verify")).to eq(%w[failed failed passed])
      looped = events(result, "step_looped")
      expect(looped.size).to eq(1)
      expect(looped.first).to include("backoff" => 120)
      wait = events(result, "simulated_wait")
      expect(wait.size).to eq(1)
      expect(types(result).index("step_looped")).to be < types(result).index("simulated_wait")
      expect(types(result).index("simulated_wait")).to be < types(result).index("step_retry_started")
      expect(prompt("build", 2)).to include("FLAKY-LINE-ONE", "FLAKY-LINE-TWO")

      # No engine path records a run_resumed with no step, so one is seeded as an old run's history would hold it.
      store = stores.first
      store.record_event(Workspace::WorkflowSimulator::RUN_ID, "run_resumed", {})
      stats = Workspace::WorkflowStats.new(store: store).read(workflow: "flow")

      expect(stats["steps"].find { |each| each["step"] == "verify" }).to include("attempts" => 3, "failed" => 2, "passed" => 1, "resumes" => 1)
      expect(stats["steps"].find { |each| each["step"] == "build" }["resumes"]).to eq(0)
      expect(stats["unattributed_resumes"]).to eq(1)
    end

    it "holds the next attempt when the token budget is spent, and starts it on a resume with extra tokens" do
      answers.push({on: "budget_spent", resume: {extra_tokens: 5000}})
      result = play(definition(top: "budget: {tokens: 1000}"), "build" => [{"tokens" => 1200}])

      expect(person.answered).to eq([["budget_spent", {extra_tokens: 5000}]])
      expect(events(result, "budget_spent").size).to eq(1)
      expect(types(result).index("budget_spent")).to be < types(result).rindex("step_dispatching")
      expect(types(result)).to include("run_resumed")
      expect(result["budget"]).to include("used" => 1200, "allowance" => 6000, "spent" => false)
      expect(result["outcome"]).to eq("completed")
    end

    it "holds the next attempt when the run's time is used, and starts it on a resume with extra seconds" do
      elapse[["build", 1]] = 2 * 3600
      answers.push({on: "run_timed_out", resume: {extra_seconds: 2 * 3600}})
      result = play(definition(top: "timeout: 1h"), {})

      expect(person.answered).to eq([["run_timed_out", {extra_seconds: 2 * 3600}]])
      expect(types(result)).to include("run_timed_out", "run_resumed")
      expect(types(result).index("run_timed_out")).to be < types(result).index("run_resumed")
      expect(events(result, "step_dispatching").map { |each| each["step"] }).to eq(%w[build verify])
      expect(result["outcome"]).to eq("completed")
    end
  end

  describe "in a sweep" do
    around do |example|
      Dir.mktmpdir("wf-scenarios-sweep") do |dir|
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
    let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
    let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir), wall_clock: -> { now.first.to_i }) }
    let(:panes) { FakeWorkflowPanes.new }
    let(:git) do
      Class.new do
        def worktree_branch(_path) = "feature/x"

        def common_dir_from_files(_path) = nil
      end.new
    end
    let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
    let(:engine) do
      Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
        checker: ->(**) { {exit_code: 0, timed_out: false} },
        commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}),
        lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
        guard: instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40),
        excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {},
        workspace_known: ->(_name) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
        task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first })
    end
    let(:pressed) { [] }
    let(:sweep) do
      interrupter = ->(*args) { pressed << args }
      reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
      Workspace::WorkflowSweep.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews, clock: -> { now.first })
    end

    before do
      FileUtils.mkdir_p(worktree)
      allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
    end

    def flow(top: "", step: "")
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
        #{top}
        steps:
          build:
            prompt: Build it.
            context: continue
            #{step}
          verify:
            prompt: Verify it.
            context: continue
      YAML
    end

    def begin_run(definition)
      engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    end

    def advance(seconds) = now[0] += seconds

    def pane_shows(state, idle_seconds: 0)
      panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => state, "idle_seconds" => idle_seconds, "state_since" => now.first.utc.iso8601}
    end

    def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

    def run_file = stored_run(store, "wr_1")

    def only_row(rows)
      expect(rows.size).to eq(1)
      rows.first
    end

    def keys = Workspace::AgentProvider.find("claude").interrupt_keys

    it "presses the interrupt keys for a step past its timeout with on_timeout: interrupt" do
      begin_run(flow(step: "timeout: 1h\n    on_timeout: interrupt"))
      pane_shows("working")
      advance(3601)

      expect(only_row(sweep.call)).to include("outcome" => "interrupted", "cause" => "timed_out", "action" => "interrupt")
      expect(pressed).to eq([["app.worktree-x", "%5", keys]])
      expect(events.map { |each| each["type"] }).to include("step_stalled")
      expect(run_file["state"]).to eq("running")
    end

    it "fails a step past its timeout with on_timeout: fail, and a plain resume dispatches the next attempt" do
      begin_run(flow(step: "timeout: 1h\n    on_timeout: fail"))
      pane_shows("working")
      advance(3601)

      expect(only_row(sweep.call)).to include("outcome" => "timed_out", "cause" => "timed_out", "action" => "fail")
      expect(pressed.size).to eq(1)
      expect(events.reverse.find { |each| each["type"] == "step_failed" }).to include("step" => "build", "cause" => "timeout", "actor" => "sweep")
      expect(run_file["steps"]["build"]["attempts"].last).to include("outcome" => "failed", "code" => "step_timed_out")
      expect(run_file["state"]).to eq("waiting")

      kicks = panes.kicks.size
      resumed = engine.resume("wr_1", actor: "person")

      expect(resumed).to include("state" => "running", "current" => "build")
      expect(resumed["steps"]["build"]["attempts"].map { |each| each["n"] }).to eq([1, 2])
      expect(panes.kicks.size).to eq(kicks + 1)
    end

    it "decides an idle turn the person's stall says is over, and leaves it alone until the stall is reached" do
      stall = 2 * Workspace::WorkflowSweepRows::IDLE_GRACE
      begin_run(flow(top: "stall: #{stall}s"))
      advance(Workspace::WorkflowSweepRows::IDLE_GRACE)
      pane_shows("idle", idle_seconds: stall - 1)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "idle")

      pane_shows("idle", idle_seconds: stall)
      row = only_row(sweep.call)

      expect(row).to include("outcome" => "evaluated", "cause" => "idle_turn_over")
      expect(events.map { |each| each["type"] }).to include("step_recovered")
      expect(pressed).to be_empty
    end

    it "types an undelivered line again at each backoff until redeliver is spent, then records the exhaustion once" do
      backoff = Workspace::WorkflowTransitions::REDELIVER_BACKOFF
      code = Workspace::WorkflowTransitions::REDELIVER_CODES.first
      panes.kick_result = {ok: false, code: code, message: "the pane is busy"}
      begin_run(flow(top: "redeliver: 2"))
      expect(run_file["reason"]["details"]).to include("kind" => "dispatch", "error" => code)
      pane_shows("idle", idle_seconds: 600)

      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "backoff", "cause" => "undelivered")
      advance(backoff[0])
      kicks = panes.kicks.size
      expect(only_row(sweep.call)).to include("outcome" => "nothing", "reason" => "not_delivered", "action" => "redeliver")
      expect(panes.kicks.size).to eq(kicks + 1)
      advance(backoff[1] - 1)
      expect(only_row(sweep.call)).to include("reason" => "backoff")
      expect(panes.kicks.size).to eq(kicks + 1)
      advance(1)
      expect(only_row(sweep.call)).to include("reason" => "not_delivered")
      expect(panes.kicks.size).to eq(kicks + 2)
      kicks = panes.kicks.size

      advance(backoff[2])
      expect(only_row(sweep.call)).to include("outcome" => "recorded", "cause" => "redelivery_exhausted")
      expect(panes.kicks.size).to eq(kicks)
      expect(events.select { |each| each["type"] == "step_stalled" && each["cause"] == "undelivered" }).not_to be_empty
      expect(run_file["state"]).to eq("waiting")
    end
  end
end
