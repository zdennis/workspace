require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowSimulator do
  let(:base) { Dir.mktmpdir("wf-sim") }
  let(:made) { [] }
  let(:tmpdir) do
    lambda do |prefix, &block|
      dir = Dir.mktmpdir(prefix, base)
      made << dir
      block.call(dir)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace::WorkflowEngine.new(**parts) }, tmpdir: tmpdir) }

  after { FileUtils.rm_rf(base) }

  def definition(extra: "", test_extra: "")
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "demo", source: "file", path: nil)
      schema_version: 1
      id: demo
      title: Demo
      max_attempts: 20
      #{extra}
      steps:
        build:
          prompt: build it
          produces: [build.md]
        test:
          prompt: test it
          produces: [test.md]
          status: {run: "true"}
          on_fail: {goto: build, max: 3#{test_extra}}
    YAML
  end

  def play(text, **options)
    data = options.delete(:definition) || definition
    script = Workspace::WorkflowSimScript.parse(text, definition: data.to_h, source: "s.yml")
    simulator.call(definition: data, script: script, **options)
  end

  def types(result)
    result["transitions"].map { |each| each["type"] }
  end

  it "completes a workflow whose script says nothing, with a plain agent" do
    result = play("steps: {}\n")

    expect(result).to include("outcome" => "completed", "capped" => false, "stopped" => nil)
    expect(result["steps"].map { |step| step["attempts"].map { |each| each["outcome"] } }).to eq([%w[passed], %w[passed]])
    expect(types(result)).to start_with("run_started", "step_dispatching", "step_dispatched", "simulated_agent", "step_passed")
    expect(types(result).last).to eq("run_completed")
  end

  it "loops a failed check back along on_fail until it passes, then stops at a person when the loops run out" do
    passes = play("steps:\n  test:\n    - {check: fail}\n    - {check: fail}\n    - {}\n")
    expect(passes["outcome"]).to eq("completed")
    expect(passes["run"]["loops"]).to eq("test->build" => 2)

    stops = play("steps:\n  test: [{check: fail}, {check: fail}, {check: fail}, {check: fail}]\n")
    expect(stops).to include("outcome" => "stopped", "stopped" => {"step" => "test", "attempt" => 4, "reason" => "failed_check"})
  end

  it "fails a step the agent reports as failed, with the agent's code" do
    result = play("steps:\n  build:\n    - {report: fail, summary: stuck, code: no_luck}\n", definition: definition)
    failed = result["transitions"].find { |each| each["type"] == "step_failed" }

    expect(failed).to include("step" => "build", "cause" => "reported")
    expect(result["steps"].first["attempts"].first).to include("outcome" => "failed", "code" => "no_luck")
  end

  it "stops at a turn that ended without its files" do
    result = play("steps:\n  build:\n    - {writes: []}\n")

    expect(result).to include("outcome" => "stopped")
    expect(result["stopped"]).to include("step" => "build", "reason" => "turn_ended_incomplete")
  end

  it "waits out an on_fail backoff by moving the simulated time, the same way every time" do
    data = definition(test_extra: ", backoff: 2m")
    text = "steps:\n  test:\n    - {check: fail}\n"
    first = play(text, definition: data)
    second = play(text, definition: data)

    wait = first["transitions"].find { |each| each["type"] == "simulated_wait" }
    expect(wait["at"]).to eq(122)
    expect(types(first)).to include("step_retry_started")
    expect(first["transitions"]).to eq(second["transitions"])
  end

  it "holds the run before an attempt that would go past the token budget" do
    data = definition(extra: "budget: {tokens: 50000}")
    result = play("steps:\n  build: [{tokens: 30000}, {tokens: 30000}]\n  test: [{check: fail}]\n", definition: data)

    expect(result["outcome"]).to eq("stopped")
    expect(result["stopped"]["reason"]).to eq("budget_spent")
    expect(result["budget"]).to include("used" => 60000, "allowance" => 50000, "spent" => true)
    expect(types(result)).to include("budget_spent")
  end

  it "ends at the action cap and says so" do
    stub_const("Workspace::WorkflowSimulator::MAX_ACTIONS", 1)
    result = play("steps: {}\n")

    expect(result).to include("outcome" => "capped", "capped" => true, "max_actions" => 1, "actions" => 1)
  end

  it "records an engine refusal as the end of the simulation" do
    data = Workspace::WorkflowDefinition.parse(<<~YAML, id: "gated", source: "file", path: nil)
      schema_version: 1
      id: gated
      title: Gated
      max_attempts: 1
      steps:
        draft:
          prompt: draft
          produces: [draft.md]
          gate: approve
    YAML
    result = play("steps:\n  draft: [{gate: reject}]\n", definition: data)

    expect(result["outcome"]).to eq("stopped")
    expect(result["transitions"].last).to include("type" => "simulated_refused", "code" => "attempts_spent")
  end

  it "takes input values from the script and from the call, the call winning" do
    data = Workspace::WorkflowDefinition.parse(<<~YAML, id: "asks", source: "file", path: nil)
      schema_version: 1
      id: asks
      title: Asks
      inputs:
        task: {required: true}
      steps:
        only:
          prompt: do {{inputs.task}}
          produces: [out.md]
    YAML
    expect(play("inputs: {task: from script}\n", definition: data)["outcome"]).to eq("completed")
    expect { play("steps: {}\n", definition: data) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("input_required") }
    expect(play("inputs: {task: a}\n", definition: data, inputs: {"task" => "b"})["outcome"]).to eq("completed")
  end

  it "keeps everything in one temporary directory that is gone afterwards, and touches no real state" do
    home = Dir.mktmpdir("wf-sim-home")
    saved = ENV.to_h
    ENV["HOME"] = home
    before = Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort
    play("steps:\n  test: [{check: fail}, {}]\n")

    expect(Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort).to eq(before)
    expect(made.size).to eq(1)
    expect(File.exist?(made.first)).to be false
    expect(Dir.children(base)).to eq([])
  ensure
    ENV.replace(saved)
    FileUtils.rm_rf(home)
  end

  it "removes the temporary directory when the engine refuses the start" do
    expect { play("steps: {}\n", inputs: {"nope" => "x"}) }.to raise_error(Workspace::UsageError)
    expect(Dir.children(base)).to eq([])
  end
end

RSpec.describe Workspace::WorkflowSimulator, "against the engine's own rules" do
  let(:simulator) { described_class.new(engine_factory: ->(**parts) { Workspace::WorkflowEngine.new(**parts) }) }

  def definition(text)
    Workspace::WorkflowDefinition.parse(text, id: "demo", source: "file", path: nil)
  end

  def play(data, script_text, **options)
    script = Workspace::WorkflowSimScript.parse(script_text, definition: data.to_h, source: "s.yml")
    simulator.call(definition: data, script: script, **options)
  end

  let(:loop_definition) do
    definition(<<~YAML)
      schema_version: 1
      id: demo
      title: Demo
      max_attempts: 20
      inputs:
        task: {}
      steps:
        build:
          prompt: build
          produces: [build.md]
        test:
          prompt: test
          produces: [test.md]
          status: {run: "true"}
          require:
            - commits: 1
            - nonempty: test.md
          on_fail: {goto: build, max: 3}
    YAML
  end

  it "does not count a file an earlier attempt left as written again" do
    result = play(loop_definition, "steps:\n  test: [{check: fail}]\n  build: [{}, {writes: []}]\n")

    expect(result["outcome"]).to eq("stopped")
    expect(result["stopped"]).to include("step" => "build", "attempt" => 2, "reason" => "turn_ended_incomplete")
  end

  it "answers the engine's check outcomes: timeout, error and a failing proof" do
    timeout = play(loop_definition, "steps:\n  test: [{check: timeout}]\n")
    expect(timeout["steps"].last["attempts"].first).to include("code" => "check_timed_out")
    error = play(loop_definition, "steps:\n  test: [{check: error}]\n")
    expect(error["steps"].last["attempts"].first).to include("code" => "check_error")
    proof = play(loop_definition, "steps:\n  test: [{require: {nonempty: fail}}]\n")
    expect(proof["steps"].last["attempts"].first).to include("code" => "require_nonempty")
    both = play(loop_definition, "steps:\n  test: [{require: {commits: pass, nonempty: pass}}]\n")
    expect(both["outcome"]).to eq("completed")
  end

  it "uses a reject's note and reports the inputs the run used, the call's winning" do
    gated = definition("schema_version: 1\nid: demo\ntitle: D\nmax_attempts: 5\ninputs:\n  task: {}\nsteps:\n  one:\n    prompt: p\n    produces: [a.md]\n    gate: approve\n")
    result = play(gated, "inputs: {task: from script}\nsteps:\n  one: [{gate: reject, note: too big}]\n", inputs: {"task" => "from call"})

    expect(result["transitions"].find { |each| each["type"] == "gate_rejected" }).to include("note" => "too big")
    expect(result["inputs"]).to eq("task" => "from call")
    expect(play(gated, "inputs: {task: from script}\n")["inputs"]).to eq("task" => "from script")
  end

  it "does not count the attempt in progress against the budget when it is cut off" do
    stub_const("Workspace::WorkflowSimulator::MAX_ACTIONS", 0)
    data = definition("schema_version: 1\nid: demo\ntitle: D\nbudget: {tokens: 10}\nsteps:\n  one:\n    prompt: p\n    produces: [a.md]\n")
    result = play(data, "steps: {}\n")

    expect(result["outcome"]).to eq("capped")
    expect(result["budget"]).to include("counted" => 0, "uncounted" => 0)
  end

  it "answers one error, not a backtrace, for files that can't both exist" do
    data = definition("schema_version: 1\nid: demo\ntitle: D\nsteps:\n  one:\n    prompt: p\n    produces: [x, x/y]\n")

    expect { play(data, "steps: {}\n") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("invalid_workflow")
      expect(e.details).to include("workflow" => "demo")
    }
  end

  describe "the fake agent's moves" do
    let(:run) { {"state" => "waiting", "current" => "a", "steps" => {"a" => {"state" => "running"}}, "reason" => nil} }

    def move(changes)
      simulator.send(:next_move, run.merge(changes))
    end

    it "takes a turn only for a running step with no reason and no park" do
      expect(move({})).to eq(:turn)
      expect(move("reason" => {"code" => "x"})).to be_nil
      expect(move("parked" => {"id" => "p"})).to be_nil
    end

    it "waits out a backoff unless it is blocked" do
      expect(move("backoff" => {"to" => "a", "until" => "x"})).to eq(:backoff)
      blocked = {"state" => "waiting", "reason" => {"code" => "pane_gone"}, "steps" => {"a" => {"state" => "failed"}}}
      expect(move(blocked.merge("backoff" => {"to" => "a", "blocked" => "pane_gone"}))).to be_nil
    end

    it "writes only inside the artifacts directory" do
      Dir.mktmpdir do |dir|
        inner = File.join(dir, "art")
        FileUtils.mkdir_p(inner)
        clock = Workspace::WorkflowSimulator::SimClock.new
        simulator.send(:write, {"artifacts_dir" => inner}, "../escape.md", clock)
        simulator.send(:write, {"artifacts_dir" => inner}, "ok.md", clock)

        expect(File.exist?(File.join(dir, "escape.md"))).to be false
        expect(File.mtime(File.join(inner, "ok.md"))).to eq(clock.call)
      end
    end
  end

  it "stubs the repository the engine reads" do
    expect(described_class::SimGit.new.worktree_branch("anywhere")).to eq("simulation")
    expect(described_class::SimGuard.new.head("anywhere")).to be_nil
  end

  describe Workspace::WorkflowSimulator::SimRequire do
    let(:script) { Workspace::WorkflowSimScript.parse("steps:\n  t: [{require: {commits: fail, nonempty: fail}}]\n", definition: {"id" => "d", "inputs" => {}, "steps" => [{"id" => "t", "require" => [{"commits" => 1}, {"nonempty" => "f"}]}]}, source: "s") }
    let(:step) { {"id" => "t", "require" => [{"commits" => 1}, {"nonempty" => "f"}]} }

    it "answers the first failing proof from the entry it is asked to start at, as proven" do
      first = described_class.new(script).check(step: step, attempt: {"n" => 1})
      later = described_class.new(script).check(step: step, attempt: {"n" => 1}, from: 1)

      expect(first).to include("proof" => "commits", "code" => "require_commits", "unproven" => false)
      expect(later).to include("proof" => "nonempty")
      expect(described_class.new(script).check(step: step, attempt: {"n" => 1}, from: 2)).to be_nil
    end

    describe "exec entries" do
      let(:execs) { [{"commits" => 1}, {"exec" => ["a"], "timeout" => 300}, {"exec" => ["b"], "timeout" => 300}] }
      let(:step) { {"id" => "t", "require" => execs} }

      def script_for(require_text)
        Workspace::WorkflowSimScript.parse("steps:\n  t: [{require: #{require_text}}]\n", definition: {"id" => "d", "inputs" => {}, "steps" => [step]}, source: "s")
      end

      def ask(script, from: 0)
        described_class.new(script).check(step: step, attempt: {"n" => 1}, from: from)
      end

      it "gives the i-th exec entry the i-th answer, so the second can fail while the first passes" do
        script = script_for("{exec: [pass, fail]}")
        expect(ask(script)).to include("proof" => "exec", "code" => "require_exec", "index" => 2, "detail" => "the script says exec entry 2 of 2 fails")
        expect(ask(script, from: 2)).to include("proof" => "exec")
        expect(ask(script, from: 3)).to be_nil
      end

      it "passes when the failing answer belongs to an entry before where it starts" do
        expect(ask(script_for("{exec: [fail, pass]}"), from: 2)).to be_nil
      end

      it "applies a bare value to every exec entry" do
        script = script_for("{exec: fail}")
        expect(ask(script, from: 2)).to include("proof" => "exec")
      end

      it "refuses a list whose length differs from the step's exec count" do
        expect { script_for("{exec: [pass]}") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("invalid_script")
          expect(e.details["problems"].join).to match(/exec lists 1 answer, but the step has 2 exec entries/)
        }
      end
    end
  end
end
