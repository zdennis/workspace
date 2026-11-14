require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowDefinition do
  def parse(yaml, id: "demo", path: "/defs/demo.yml")
    described_class.parse(yaml, id: id, source: "global", path: path)
  end

  def problems(yaml, **rest)
    parse(yaml, **rest)
    []
  rescue Workspace::Error => e
    expect(e.code).to eq("invalid_workflow")
    e.details.fetch("problems")
  end

  let(:minimal) { "steps:\n  build:\n    prompt: Build it.\n" }

  describe "redeliver" do
    it "defaults to 3 in a new definition, reads a number from 0 to 10, and reads 0 from a definition without the key" do
      expect(parse(minimal).to_h["redeliver"]).to eq(3)
      expect(parse("redeliver: 0\n#{minimal}").to_h["redeliver"]).to eq(0)
      expect(described_class.redeliver({"steps" => []})).to eq(0)
      expect(described_class.redeliver({"redeliver" => 99})).to eq(0)
      expect(described_class.redeliver(nil)).to eq(0)
    end

    it "refuses anything else" do
      expect(problems("redeliver: 11\n#{minimal}")).to include(a_string_matching(/redeliver must be a whole number from 0 to 10/))
      expect(problems("redeliver: soon\n#{minimal}")).to include(a_string_matching(/redeliver/))
    end
  end

  describe "budget" do
    it "is absent unless declared, and read as nil from a definition without it" do
      expect(parse(minimal).to_h).not_to have_key("budget")
      expect(described_class.budget(parse(minimal).to_h)).to be_nil
      expect(described_class.budget(nil)).to be_nil
      expect(described_class.budget({"budget" => "lots"})).to be_nil
      expect(described_class.budget({"budget" => {"tokens" => -3}})).to be_nil
    end

    it "keeps tokens, with the stop action by default" do
      expect(parse("budget: {tokens: 4000000, action: stop}\n#{minimal}").to_h["budget"]).to eq("tokens" => 4_000_000, "action" => "stop")
      expect(parse("budget: {tokens: 5}\n#{minimal}").to_h["budget"]).to eq("tokens" => 5, "action" => "stop")
      expect(described_class.budget({"budget" => {"tokens" => 7, "action" => "other"}})).to eq("tokens" => 7, "action" => "stop")
    end

    it "refuses a non-mapping, a missing or bad tokens, an unknown key and another action" do
      expect(problems("budget: 5\n#{minimal}")).to include(a_string_matching(/budget must be a mapping/))
      expect(problems("budget: {action: stop}\n#{minimal}")).to include(a_string_matching(/budget tokens must be a whole number from 1/))
      expect(problems("budget: {tokens: 0}\n#{minimal}")).to include(a_string_matching(/budget tokens must be a whole number from 1/))
      expect(problems("budget: {tokens: 1.5}\n#{minimal}")).to include(a_string_matching(/budget tokens/))
      expect(problems("budget: {tokens: 5, dollars: 2}\n#{minimal}")).to include(a_string_matching(/budget has unknown key dollars \(known: tokens, action\)/))
      expect(problems("budget: {tokens: 5, action: pause}\n#{minimal}")).to include(a_string_matching(/budget action must be stop, got "pause"/))
    end
  end

  describe "deny" do
    it "is an empty list by default and keeps a list of patterns" do
      expect(parse(minimal).to_h["deny"]).to eq([])
      expect(parse("deny:\n  - 'git push*'\n  - 'gh pr comment*'\n#{minimal}").to_h["deny"]).to eq(["git push*", "gh pr comment*"])
    end

    it "reads nothing from a missing or bad stored value" do
      expect(described_class.deny(nil)).to eq([])
      expect(described_class.deny({"steps" => []})).to eq([])
      expect(described_class.deny({"deny" => "git push"})).to eq([])
      expect(described_class.deny({"deny" => ["git push*", 3]})).to eq([])
      expect(described_class.deny({"deny" => ["git push*"]})).to eq(["git push*"])
    end

    it "collects every problem" do
      expect(problems("deny: git push\n#{minimal}")).to include(a_string_matching(/deny must be a list/))
      expect(problems("deny: ['', 5]\n#{minimal}")).to include(a_string_matching(/deny entry 1 must be a non-empty/), a_string_matching(/deny entry 2/))
      expect(problems("deny: ['#{"a" * 201}']\n#{minimal}")).to include(a_string_matching(/longer than 200/))
      expect(problems("deny: ['#{"*" * 9}']\n#{minimal}")).to include(a_string_matching(/more than 8 wildcards/))
      many = (1..51).map { |n| "'c#{n}'" }.join(", ")
      expect(problems("deny: [#{many}]\n#{minimal}")).to include(a_string_matching(/at most 50/))
    end
  end

  describe "stall and on_timeout" do
    it "reads stall as seconds and on_timeout as a word, with warn and unset as defaults" do
      definition = parse("stall: 20m\nsteps:\n  a:\n    prompt: P\n    timeout: 2h\n    on_timeout: interrupt\n  b:\n    prompt: P\n")
      expect(definition.to_h["stall"]).to eq(1200.0)
      expect(definition.steps.map { |step| described_class.on_timeout(step) }).to eq(%w[interrupt warn])
      expect(described_class.stall(parse(minimal).to_h)).to be_nil
    end

    it "reads an old stored definition without the keys as warn and unset" do
      expect(described_class.on_timeout({"id" => "a"})).to eq("warn")
      expect(described_class.stall({"steps" => []})).to be_nil
    end

    it "reads nil, an old hash or an invalid stored value as the default" do
      expect(described_class.on_timeout(nil)).to eq("warn")
      expect(described_class.on_timeout({"on_timeout" => "stop"})).to eq("warn")
      expect(described_class.on_timeout({"on_timeout" => 5})).to eq("warn")
      expect(described_class.stall(nil)).to be_nil
      expect(described_class.stall({"stall" => 0})).to be_nil
      expect(described_class.stall({"stall" => -3})).to be_nil
      expect(described_class.stall({"stall" => "20m"})).to be_nil
      expect(described_class.stall({"stall" => 30.0})).to eq(30.0)
    end

    {"stall: 0" => /\Astall: /, "stall: -1" => /\Astall: /, "stall: 20" => nil, "stall: ~" => nil}.each do |line, bad|
      it "treats #{line} as #{bad ? "a problem" : "valid"}" do
        found = problems("#{line}\nsteps:\n  a:\n    prompt: P\n")
        if bad
          expect(found.grep(bad).size).to eq(1)
        else
          expect(found).to eq([])
        end
      end
    end

    {"on_timeout: ~" => "nil", "on_timeout: 5" => "5"}.each do |line, shown|
      it "refuses #{line}" do
        expect(problems("steps:\n  a:\n    prompt: P\n    timeout: 1h\n    #{line}\n"))
          .to eq(["step a: on_timeout must be warn, interrupt, fail, got #{shown}"])
      end
    end

    it "warns for interrupt with no timeout and not for fail with one" do
      expect(parse("steps:\n  a:\n    prompt: P\n    gate: approve\n    on_timeout: interrupt\n").warnings.map { |w| w["code"] }).to eq(["on_timeout_without_timeout"])
      expect(parse("steps:\n  a:\n    prompt: P\n    gate: approve\n    timeout: 1h\n    on_timeout: fail\n").warnings).to eq([])
    end

    it "lists bad values as problems" do
      found = problems("stall: soon\nsteps:\n  a:\n    prompt: P\n    timeout: 1h\n    on_timeout: stop\n")
      expect(found).to include("step a: on_timeout must be warn, interrupt, fail, got \"stop\"")
      expect(found.grep(/\Astall: expected a duration/).size).to eq(1)
    end

    it "warns when on_timeout is interrupt or fail and the step has no timeout" do
      yaml = "steps:\n  a:\n    prompt: P\n    produces: [a.md]\n    on_timeout: fail\n  b:\n    prompt: P\n    produces: [b.md]\n    on_timeout: warn\n"
      expect(parse(yaml).warnings).to match([include("code" => "on_timeout_without_timeout", "step" => "a")])
    end
  end

  describe "the run timeout" do
    it "reads timeout and timeout_action, and stores them only when written" do
      data = parse("timeout: 8h\ntimeout_action: interrupt\n#{minimal}").to_h
      expect(data).to include("timeout" => 28_800.0, "timeout_action" => "interrupt")
      expect(parse("timeout: 90m\n#{minimal}").to_h).to include("timeout" => 5400.0, "timeout_action" => "hold")
      expect(parse(minimal).to_h.keys).not_to include("timeout", "timeout_action")
    end

    it "reads an absent or bad stored timeout as none" do
      expect(described_class.run_timeout({"timeout" => 60.0, "timeout_action" => "interrupt"})).to eq("seconds" => 60.0, "action" => "interrupt")
      expect(described_class.run_timeout({"timeout" => 60.0})).to eq("seconds" => 60.0, "action" => "hold")
      expect(described_class.run_timeout({"steps" => []})).to be_nil
      expect(described_class.run_timeout({"timeout" => "soon"})).to be_nil
      expect(described_class.run_timeout(nil)).to be_nil
    end

    it "refuses a bad duration or action" do
      expect(problems("timeout: soon\n#{minimal}")).to include(a_string_matching(/timeout: expected a duration/))
      expect(problems("timeout: 0\n#{minimal}")).to include(a_string_matching(/timeout: must be greater than 0/))
      expect(problems("timeout: 1#{"0" * 400}\n#{minimal}")).to include(a_string_matching(/timeout: must be greater than 0 and at most 31536000s/))
      expect(problems("timeout: 8761h\n#{minimal}")).to include(a_string_matching(/at most 31536000s/))
      expect(parse("timeout: 8760h\n#{minimal}").to_h["timeout"]).to eq(31_536_000.0)
      expect(described_class.run_timeout({"timeout" => Float::INFINITY})).to be_nil
      expect(problems("timeout: 1h\ntimeout_action: stop\n#{minimal}")).to include(a_string_matching(/timeout_action must be hold or interrupt/))
    end

    it "warns on timeout_action without a timeout, and not otherwise" do
      expect(parse("timeout_action: interrupt\n#{minimal}").warnings).to include(a_hash_including("code" => "timeout_action_without_timeout"))
      expect(parse("timeout: 1h\ntimeout_action: interrupt\n#{minimal}").warnings.map { |w| w["code"] }).not_to include("timeout_action_without_timeout")
    end
  end

  describe "a step's max_attempts" do
    def step_problems(value)
      problems("steps:\n  a:\n    prompt: P\n    produces: [a.md]\n    max_attempts: #{value}\n")
    end

    it "reads a whole number of 1 or more and defaults to none" do
      definition = parse("steps:\n  a:\n    prompt: P\n    produces: [a.md]\n    max_attempts: 3\n  b:\n    prompt: P\n    produces: [b.md]\n")
      expect(definition.steps.map { |step| step["max_attempts"] }).to eq([3, nil])
      expect(described_class.step_max_attempts(definition.steps[0])).to eq(3)
      expect(described_class.step_max_attempts(definition.steps[1])).to be_nil
      expect(described_class.step_max_attempts({"id" => "x"})).to be_nil
    end

    it "accepts an explicit nil as none" do
      expect(step_problems("~")).to eq([])
    end

    it "refuses 0, a string and a fraction" do
      ["0", "\"3\"", "1.5", "-1"].each do |value|
        expect(step_problems(value)).to include(a_string_matching(/step a: max_attempts must be a whole number of 1 or more, got/))
      end
    end
  end

  describe "step attempt warnings" do
    def found(yaml, code)
      parse(yaml).warnings.select { |w| w["code"] == code }
    end

    let(:looping) { "max_attempts: 10\nsteps:\n  a:\n    prompt: P\n    produces: [a.md]\n    max_attempts: 2\n  b:\n    prompt: P\n    produces: [b.md]\n    on_fail: {goto: a, max: 2}\n" }

    it "warns when on_fail.max + 1 is above the target's cap" do
      expect(found(looping, "on_fail_exceeds_step_attempts")).to match([include("step" => "b", "message" => /up to 3 times.*max_attempts: 2/)])
    end

    it "is quiet when the cap holds every run of the target or the target has none" do
      expect(found(looping.sub("max_attempts: 2", "max_attempts: 3"), "on_fail_exceeds_step_attempts")).to eq([])
      expect(found(looping.sub("    max_attempts: 2\n", ""), "on_fail_exceeds_step_attempts")).to eq([])
    end

    it "warns when a step's cap is above the run's" do
      yaml = looping.sub("max_attempts: 10", "max_attempts: 2").sub("max_attempts: 2\n  b", "max_attempts: 5\n  b")
      expect(found(yaml, "step_attempts_exceed_run")).to match([include("step" => "a", "message" => /max_attempts: 5.*max_attempts: 2/)])
      expect(found(looping, "step_attempts_exceed_run")).to eq([])
    end
  end

  describe "on_fail_exceeds_max_attempts" do
    def retry_warnings(attempts, *steps)
      body = steps.map { |id, extra| "  #{id}:\n    prompt: P\n    produces: [#{id}.md]\n#{extra}" }.join
      parse("max_attempts: #{attempts}\nsteps:\n#{body}").warnings.select { |w| w["code"] == "on_fail_exceeds_max_attempts" }
    end

    let(:loop_back) { "    on_fail: {goto: a, max: 3}\n" }

    it "counts the attempts a retry runs again, as the engine does" do
      # a=1, b=2 fails first on attempt 2; each retry reruns a and b (2 attempts): retry 3 needs 2 + 2 * 2 = 6 made
      expect(retry_warnings(6, ["a"], ["b", loop_back]).first["message"]).to match(/lets only 2 of those retries start.*attempt 2.*2 steps.*Raise max_attempts to 7/)
      expect(retry_warnings(7, ["a"], ["b", loop_back])).to eq([])
    end

    it "is quiet when every retry fits and the default max is 1" do
      expect(retry_warnings(6, ["a"], ["b", "    on_fail: {goto: a}\n"])).to eq([])
    end

    it "reports no retry at all when the step itself is past the limit" do
      found = retry_warnings(2, ["a"], ["b", "    on_fail: {goto: a, max: 1}\n"])
      expect(found.first["message"]).to match(/lets only 0 of those retries start/)
    end

    it "warns for a step that loops to an earlier step only" do
      found = retry_warnings(4, ["a"], ["b"], ["c", "    on_fail: {goto: b, max: 2}\n"])
      expect(found).to match([include("step" => "c", "message" => /2 steps/)])
    end

    it "is never an error, so the definition still parses" do
      expect { retry_warnings(1, ["a"], ["b", loop_back]) }.not_to raise_error
    end
  end

  describe "#warnings" do
    def warnings(yaml) = parse(yaml).warnings

    it "names a step with no produces, status, require or gate" do
      expect(warnings(minimal)).to match([include("code" => "step_without_proof", "step" => "build", "message" => /step build has no produces, status, require or gate.*Add produces/)])
    end

    it "is quiet for a step with produces, a status command or a gate" do
      yaml = "steps:\n  a:\n    prompt: A.\n    produces: [a.md]\n  b:\n    prompt: B.\n    status: {run: \"true\"}\n  c:\n    prompt: C.\n    gate: approve\n"
      expect(warnings(yaml)).to eq([])
    end

    it "names only the steps without proof, in order" do
      yaml = "steps:\n  a:\n    prompt: A.\n  b:\n    prompt: B.\n    produces: [b.md]\n  c:\n    prompt: C.\n"
      expect(warnings(yaml).map { |w| w["step"] }).to eq(%w[a c])
    end

    it "warns for no shipped preset" do
      presets = File.join(PROJECT_ROOT, "lib", "workflows")
      lookup = ->(id, below: nil) { {"text" => File.read(File.join(presets, "#{id}.yml")), "path" => File.join(presets, "#{id}.yml"), "source" => "builtin"} }
      Dir[File.join(presets, "*.yml")].each do |file|
        expect(described_class.parse(File.read(file), id: File.basename(file, ".yml"), source: "builtin", path: file, parent_lookup: lookup).warnings).to eq([])
      end
    end
  end

  describe "input pattern" do
    def with_pattern(pattern)
      "inputs:\n  pr: {pattern: #{pattern}}\nsteps:\n  build:\n    prompt: Build it.\n"
    end

    it "keeps a good pattern on the input" do
      expect(parse(with_pattern("'[0-9]+'")).to_h["inputs"]["pr"]).to include("pattern" => "[0-9]+")
    end

    it "leaves the key out when there is none" do
      expect(parse(minimal.sub("steps:", "inputs:\n  pr:\nsteps:")).to_h["inputs"]["pr"]).not_to have_key("pattern")
    end

    it "lists a pattern that does not compile" do
      expect(problems(with_pattern("'(['"))).to contain_exactly(/input pr: pattern does not compile/)
    end

    it "lists a pattern over 300 characters" do
      expect(problems(with_pattern("'#{"a" * 301}'"))).to eq(["input pr: pattern is longer than 300 characters"])
    end

    it "lists a pattern that is not a string" do
      expect(problems(with_pattern("12"))).to eq(["input pr: pattern must be a non-empty regexp string"])
    end
  end

  describe "text with no file" do
    it "loads a relative prompt_file from base_dir when path is nil" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "p.md"), "From file.")
        yaml = "steps:\n  a:\n    prompt_file: p.md\n"

        definition = described_class.parse(yaml, id: "demo", source: "global", path: nil, base_dir: dir)

        expect(definition.steps.first["prompt"]).to eq("From file.")
      end
    end

    it "reports a relative prompt_file as one problem, not an exception, with neither path nor base_dir" do
      expect(problems("steps:\n  a:\n    prompt_file: p.md\n", path: nil)).to match([/prompt_file p\.md is relative/])
    end

    it "says the text came from stdin, not an empty path, when it has no path" do
      expect { described_class.parse("bogus: 1\n", id: "demo", source: "stdin", path: nil) }
        .to raise_error(Workspace::Error) { |e| expect(e.message).to start_with("Workflow 'demo' (from stdin) is not valid:") }
    end

    it "keeps the text it was given and the digest of it" do
      definition = parse(minimal)

      expect(definition.text).to eq(minimal)
      expect(definition.sha256).to eq(Digest::SHA256.hexdigest(minimal))
    end
  end

  it "fills in the defaults of a step that names only a prompt" do
    definition = parse(minimal)

    expect(definition.id).to eq("demo")
    expect(definition.source).to eq("global")
    expect(definition.sha256).to eq(Digest::SHA256.hexdigest(minimal))
    expect(definition.to_h).to eq(
      "id" => "demo", "title" => "demo", "description" => nil, "use_when" => nil, "applies_to" => [], "inputs" => {}, "include" => [], "instructions" => nil,
      "max_attempts" => 6, "stall" => nil, "redeliver" => 3, "deny" => [],
      "steps" => [{"id" => "build", "title" => "build", "prompt" => "Build it.", "include" => [], "produces" => [], "status" => nil,
                   "gate" => nil, "guard" => nil, "require" => [], "uses" => [], "on_fail" => nil, "context" => "fresh", "timeout" => nil, "on_timeout" => "warn", "max_attempts" => nil}]
    )
  end

  it "keeps the steps in file order and reads every step key" do
    definition = parse(<<~YAML)
      schema_version: 1
      id: demo
      title: Demo
      description: Two steps.
      inputs:
        task: {description: What to build, required: true}
        spec:
      include: [review]
      instructions: Work on {{inputs.task}} in {{workspace}} ({{branch}}); files go in {{artifacts}} for {{run}}. {{ inputs.spec }}
      max_attempts: 4
      steps:
        plan:
          title: Plan
          prompt: Plan {{inputs.task}}.
          produces: [plan.md, notes/risks.md]
          gate: approve
          timeout: 45m
        verify:
          prompt: Verify.
          include: [commits]
          uses: [test-db, dev-env]
          status: {command: test, timeout: 10m}
          context: continue
          on_fail: {goto: plan, max: 3, context: continue}
    YAML

    data = definition.to_h
    expect(data["inputs"]).to eq("task" => {"description" => "What to build", "required" => true},
      "spec" => {"description" => nil, "required" => false})
    expect(data.values_at("title", "description", "include", "max_attempts")).to eq(["Demo", "Two steps.", ["review"], 4])
    expect(definition.steps.map { |step| step["id"] }).to eq(%w[plan verify])
    expect(definition.steps.first).to include("title" => "Plan", "produces" => ["plan.md", "notes/risks.md"], "gate" => "approve", "timeout" => 2700.0)
    expect(definition.steps.last).to include("include" => ["commits"], "uses" => %w[devenv test-db], "context" => "continue",
      "status" => {"command" => "test", "timeout" => 600.0}, "on_fail" => {"goto" => "plan", "max" => 3, "context" => "continue"})
  end

  describe "guard" do
    %w[unchanged config].each do |value|
      it "reads guard: #{value}" do
        step = parse("steps:\n  build:\n    prompt: Build it.\n    guard: #{value}\n").steps.first

        expect(step["guard"]).to eq(value)
      end
    end

    it "refuses any other value, naming the step" do
      ["strict", "true", "[unchanged]", "''"].each do |value|
        expect(problems("steps:\n  build:\n    prompt: Build it.\n    guard: #{value}\n"))
          .to include(a_string_starting_with("step build: guard must be unchanged or config, got "))
      end
    end
  end

  it "takes a status given as a command line, or as run:, with the default time limit" do
    one = parse("steps:\n  a:\n    prompt: P\n    status: bin/check\n").steps.first["status"]
    two = parse("steps:\n  a:\n    prompt: P\n    status: {run: bin/check}\n").steps.first["status"]

    expect(one).to eq("run" => "bin/check", "timeout" => 1200)
    expect(two).to eq(one)
  end

  it "reads status report_code as opt-in, and leaves it out when unset or false" do
    set = parse("steps:\n  a:\n    prompt: P\n    status:\n      report_code: true\n      run: bin/check\n").steps.first["status"]
    unset = parse("steps:\n  a:\n    prompt: P\n    status: bin/check\n").steps.first["status"]
    false_ = parse("steps:\n  a:\n    prompt: P\n    status:\n      report_code: false\n      run: bin/check\n").steps.first

    expect(set).to eq("run" => "bin/check", "timeout" => 1200, "report_code" => true)
    expect(unset).not_to have_key("report_code")
    expect(false_["status"]).not_to have_key("report_code")
    expect(problems("steps:\n  a:\n    prompt: P\n    status:\n      report_code: sure\n      run: bin/check\n"))
      .to eq(["step a: status report_code must be true or false, got \"sure\""])
  end

  it "defaults on_fail to one loop and the step's own context" do
    step = parse("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a}\n").steps.last

    expect(step["on_fail"]).to eq("goto" => "a", "max" => 1, "context" => nil)
  end

  describe "on_fail log_tail and backoff" do
    def on_fail(text) = parse("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: #{text}\n").steps.last["on_fail"]

    it "stores a line count and a backoff in seconds, and leaves both out when unset" do
      expect(on_fail("{goto: a, log_tail: 40, backoff: 2m}")).to eq("goto" => "a", "max" => 1, "context" => nil, "log_tail" => 40, "backoff" => 120.0)
      expect(on_fail("{goto: a, backoff: 90}")).to include("backoff" => 90.0)
      expect(on_fail("{goto: a}")).not_to include("log_tail", "backoff")
    end

    it "collects a problem for each bad value" do
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, log_tail: 0, backoff: soon}\n")).to eq([
        "step b: on_fail log_tail must be a whole number from 1 to 200, got 0",
        "step b: on_fail backoff: expected a duration like \"20\", \"20s\", \"5m\" or \"1h\", got \"soon\""
      ])
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, log_tail: 201, backoff: 2d}\n").size).to eq(2)
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, log_tail: 2.5, backoff: 0}\n").size).to eq(2)
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, backoff: 25h}\n").first).to include("at most 86400")
    end

    it "reads both through class readers that take nil, a missing key and a bad stored value" do
      expect(described_class.backoff(nil)).to be_nil
      expect(described_class.backoff("goto" => "a")).to be_nil
      expect(described_class.backoff("backoff" => "2m")).to be_nil
      expect(described_class.backoff("backoff" => -1)).to be_nil
      expect(described_class.backoff("backoff" => 10**9)).to be_nil
      expect(described_class.backoff("backoff" => 120.0)).to eq(120.0)
      expect(described_class.log_tail(nil)).to be_nil
      expect(described_class.log_tail("log_tail" => "40")).to be_nil
      expect(described_class.log_tail("log_tail" => 0)).to be_nil
      expect(described_class.log_tail("log_tail" => 9999)).to be_nil
      expect(described_class.log_tail("log_tail" => 40)).to eq(40)
    end
  end

  describe "on_fail except" do
    def on_fail(text) = parse("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: #{text}\n").steps.last["on_fail"]

    it "stores a list of codes or causes, and leaves it out when unset" do
      expect(on_fail("{goto: a, except: [stale_plan_revision, guard]}")).to eq("goto" => "a", "max" => 1, "context" => nil, "except" => %w[stale_plan_revision guard])
      expect(on_fail("{goto: a}")).not_to have_key("except")
    end

    it "collects a problem for a name over its cap, too many entries, or a non-list" do
      long = "x" * 61
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, except: [#{long}]}\n").first)
        .to include("on_fail except \"#{long}\" is longer than 60 characters")
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, except: [#{Array.new(9, "c").join(", ")}]}\n").first)
        .to include("on_fail except takes at most 8 codes or causes, got 9")
      expect(problems("steps:\n  a:\n    prompt: P\n  b:\n    prompt: P\n    on_fail: {goto: a, except: guard}\n").first)
        .to include("on_fail except must be a list of names, got \"guard\"")
    end
  end

  it "reads a prompt from prompt_file, beside the definition" do
    Dir.mktmpdir("wf-def") do |dir|
      File.write(File.join(dir, "build.md"), "Build from a file.\n")
      definition = parse("steps:\n  build:\n    prompt_file: build.md\n", path: File.join(dir, "demo.yml"))

      expect(definition.steps.first["prompt"]).to eq("Build from a file.\n")
    end
  end

  describe "use_when and applies_to" do
    it "reads both" do
      data = parse("use_when: Review feedback to act on.\napplies_to: [github_pr, branch, github_pr]\n#{minimal}").to_h

      expect(data).to include("use_when" => "Review feedback to act on.", "applies_to" => %w[github_pr branch])
    end

    it "collects every problem under one error" do
      found = problems("use_when: \"two\\nlines\"\napplies_to: [jira, ticket, pr]\n#{minimal}")

      expect(found).to include("use_when must be one line of at most 200 characters",
        a_string_starting_with('applies_to has unknown kinds "ticket", "pr"'))
    end

    it "refuses an applies_to that is not a non-empty list, and a use_when over the limit" do
      expect(problems("applies_to: jira\n#{minimal}")).to include(a_string_starting_with("applies_to must be a list of ref kinds"))
      expect(problems("applies_to: []\n#{minimal}")).to include(a_string_starting_with("applies_to must be a list of ref kinds"))
      expect(problems("use_when: #{"x" * 201}\n#{minimal}")).to include("use_when must be one line of at most 200 characters")
    end

    it "reads a stored definition that has none, or a bad value, as unset" do
      expect(described_class.use_when({})).to be_nil
      expect(described_class.use_when(nil)).to be_nil
      expect(described_class.use_when("use_when" => 5)).to be_nil
      expect(described_class.use_when("use_when" => "two\nlines")).to be_nil
      expect(described_class.use_when("use_when" => "x" * 300)).to be_nil
      expect(described_class.use_when("use_when" => "x" * 200)).to eq("x" * 200)
      expect(described_class.applies_to({})).to eq([])
      expect(described_class.applies_to(nil)).to eq([])
      expect(described_class.applies_to("applies_to" => %w[jira bogus])).to eq([])
      expect(described_class.applies_to("applies_to" => %w[jira])).to eq(%w[jira])
    end
  end

  describe "schema_version" do
    def versioned(line)
      <<~YAML
        #{line}
        title: Demo
        inputs:
          task: {description: What to build, required: true}
        steps:
          plan:
            prompt: Plan {{inputs.task}}.
            produces: [plan.md]
            gate: approve
          build:
            prompt: Build it.
      YAML
    end

    it "reads 0.1 as the same definition as no key and as the legacy 1" do
      current = parse(versioned("schema_version: 0.1"))

      expect(current.to_h).to eq(parse(versioned("")).to_h)
      expect(current.to_h).to eq(parse(versioned("schema_version: 1")).to_h)
      expect(current.to_h).not_to have_key("schema_version")
    end

    it "reads a quoted \"0.1\"" do
      expect(parse(versioned('schema_version: "0.1"')).to_h).to eq(parse(versioned("")).to_h)
    end

    it "takes the last of duplicate keys, as written" do
      expect(problems(versioned("schema_version: 0.1\nschema_version: 0.10"))).to eq(["schema_version must be one of 0.1, got 0.10"])
      expect(problems(versioned("schema_version: 0.10\nschema_version: 0.1"))).to eq([])
    end

    it "refuses a version it can't read as written, such as one from a merge key" do
      expect(problems(versioned("<<: {schema_version: 0.10}"))).to eq(["schema_version must be one of 0.1, got 0.1"])
    end

    {"2" => "2", "0.2" => "0.2", '"1.0"' => '"1.0"', "1.0" => "1.0", '"1"' => '"1"', "true" => "true", "" => "nil",
     "0.10" => "0.10", '"0.10"' => '"0.10"', ".1" => ".1", "01" => "01", "0x1" => "0x1"}.each do |written, shown|
      it "refuses schema_version #{written}" do
        expect(problems(versioned("schema_version: #{written}"))).to eq(["schema_version must be one of 0.1, got #{shown}"])
      end
    end
  end

  it "reports every problem in a file at once" do
    found = problems(<<~YAML)
      schema_version: 2
      id: other
      colour: red
      max_attempts: 0
      inputs:
        Task: {required: maybe, extra: 1}
      steps:
        Build:
          prompt: P
          prompt_file: p.md
        test:
          prompt: Uses {{inputs.nope}} and {{secret}}.
          produces: [../escape.md, /abs.md]
          status: {command: deploy}
          gate: human
          uses: [edit]
          on_fail: {goto: later, max: 0}
          context: new
          timeout: soon
          retries: 2
        later:
          prompt: ""
    YAML

    expect(found).to include(
      "the workflow has unknown key colour (known: schema_version, id, title, description, use_when, applies_to, extends, replace, inputs, include, instructions, max_attempts, stall, redeliver, budget, timeout, timeout_action, deny, reviewers, steps)",
      "schema_version must be one of 0.1, got 2",
      "id must be \"demo\", the name of its file, got \"other\"",
      "max_attempts must be a whole number of 1 or more, got 0",
      "input name \"Task\" must be lowercase letters, digits and '_', starting with a letter",
      "input Task has unknown key extra (known: description, required, pattern)",
      "input Task: required must be true or false",
      "step id \"Build\" must be lowercase letters, digits, '-' and '_'",
      "step Build needs exactly one of prompt and prompt_file",
      "step test has unknown key retries (known: title, prompt, prompt_file, include, produces, status, gate, guard, require, uses, on_fail, context, timeout, on_timeout, max_attempts, review, after)",
      "step test: prompt uses {{inputs.nope}}, which nothing supplies (known: {{workspace}}, {{branch}}, {{artifacts}}, {{run}}, {{inputs.Task}})",
      "step test: prompt uses {{secret}}, which nothing supplies (known: {{workspace}}, {{branch}}, {{artifacts}}, {{run}}, {{inputs.Task}})",
      "step test: produces \"../escape.md\" must be a path under the run's artifacts directory",
      "step test: produces \"/abs.md\" must be a path under the run's artifacts directory",
      "step test: status command must be one of test, lint, got \"deploy\"",
      "step test: gate must be approve, got \"human\"",
      "step test: on_fail goto must name an earlier step (Build), got \"later\"",
      "step test: on_fail max must be a whole number of 1 or more, got 0",
      "step test: context must be one of fresh, continue, got \"new\"",
      "step later: prompt must be text, got \"\""
    )
    expect(found.grep(/uses: edit is not a resource a run can hold/).size).to eq(1)
    expect(found.grep(/step test: timeout: expected a duration/).size).to eq(1)
  end

  it "names the file and the problems in the error's message" do
    expect { parse("steps: []\n") }.to raise_error(Workspace::Error,
      "Workflow 'demo' (/defs/demo.yml) is not valid:\n  - steps must be a mapping of step id to step, with at least one step")
  end

  it "refuses a file that is not a YAML mapping, or not YAML" do
    expect(problems("- a\n- b\n")).to include("the file must be a YAML mapping")
    expect(problems("steps: [unclosed\n").first).to start_with("the file is not valid YAML")
  end

  it "refuses a status with both run and command, or neither" do
    expect(problems("steps:\n  a:\n    prompt: P\n    status: {run: x, command: test}\n")).to eq(["step a: status needs exactly one of run and command"])
    expect(problems("steps:\n  a:\n    prompt: P\n    status: {timeout: 5m}\n")).to eq(["step a: status needs exactly one of run and command"])
  end

  it "refuses a status timeout with no value, which would leave the check with no time limit" do
    expect(problems("steps:\n  a:\n    prompt: P\n    status: {run: x, timeout: }\n"))
      .to eq(["step a: status timeout must be a duration such as 90 or 20m, got nothing"])
  end

  it "refuses a prompt_file that is missing or empty" do
    Dir.mktmpdir("wf-def") do |dir|
      File.write(File.join(dir, "empty.md"), "  \n")
      path = File.join(dir, "demo.yml")

      expect(problems("steps:\n  a:\n    prompt_file: gone.md\n", path: path)).to eq(["step a: prompt_file #{File.join(dir, "gone.md")} can't be read (Errno::ENOENT)"])
      expect(problems("steps:\n  a:\n    prompt_file: empty.md\n", path: path)).to eq(["step a: prompt_file #{File.join(dir, "empty.md")} is empty"])
    end
  end

  describe "read by a process with no UTF-8 locale" do
    it "takes a definition and its prompt_file as UTF-8, however the text was tagged" do
      Dir.mktmpdir("wf-def") do |dir|
        File.write(File.join(dir, "plan.md"), "Écris le plan.\n", encoding: "UTF-8")
        yaml = "title: Café\ninstructions: Travaille sur {{inputs.task}}.\ninputs:\n  task: {}\nsteps:\n  a:\n    prompt_file: plan.md\n"

        definition = without_utf8_locale { parse(yaml.b, path: File.join(dir, "demo.yml")) }

        expect(definition.to_h).to include("title" => "Café", "instructions" => "Travaille sur {{inputs.task}}.")
        expect(definition.steps.first["prompt"]).to eq("Écris le plan.\n")
        expect(definition.steps.first["prompt"].encoding).to eq(Encoding::UTF_8)
        expect(definition.sha256).to eq(Digest::SHA256.hexdigest(yaml))
      end
    end

    it "reports a definition or a prompt_file whose bytes are not UTF-8 as a problem, in any locale" do
      Dir.mktmpdir("wf-def") do |dir|
        File.binwrite(File.join(dir, "cut.md"), "caf\xC3".b)
        path = File.join(dir, "demo.yml")

        [->(&block) { without_utf8_locale(&block) }, ->(&block) { block.call }].each do |locale|
          locale.call do
            expect(problems("title: caf\xC3\nsteps:\n  a:\n    prompt: P\n".b)).to include("the file is not valid UTF-8 text")
            expect(problems("steps:\n  a:\n    prompt_file: cut.md\n", path: path))
              .to eq(["step a: prompt_file #{File.join(dir, "cut.md")} is not valid UTF-8 text"])
          end
        end
      end
    end
  end

  it "refuses an on_fail in the first step, which has nowhere to go back to" do
    expect(problems("steps:\n  a:\n    prompt: P\n    on_fail: {goto: a}\n"))
      .to eq(["step a: on_fail goto must name an earlier step (there is none), got \"a\""])
  end

  describe ".render" do
    it "reads a value tagged with another encoding as UTF-8, so it joins the text, and replaces bytes that are not" do
      values = {"branch" => "fonctionnalité".b, "inputs.task" => (+"caf\xC3").force_encoding("US-ASCII")}

      text = described_class.render("Café: {{branch}} / {{inputs.task}}", values)

      expect(text).to eq("Café: fonctionnalité / caf\uFFFD")
      expect(values["branch"].encoding).to eq(Encoding::BINARY)
    end

    it "fills the placeholders it has a value for and leaves the rest as written" do
      text = described_class.render("Do {{inputs.task}} in {{ workspace }}; {{unknown}} stays.", "inputs.task" => "X-1", "workspace" => "app")

      expect(text).to eq("Do X-1 in app; {{unknown}} stays.")
    end
  end
  describe ".reads_plan?" do
    let(:catalog) do
      Workspace::WorkflowCatalog.new(config: Workspace::Config.new)
    end

    def preset(id)
      catalog.find(id).to_h
    end

    %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
      it "is true for #{id} at research, plan and implement, and false at verify" do
        definition = preset(id)

        %w[research plan implement].each do |step|
          expect(described_class.reads_plan?(definition, from: step)).to be(true), "#{id} at #{step}"
        end
        expect(described_class.reads_plan?(definition, from: "verify")).to be(false)
      end
    end

    %w[investigate explore pr-feedback].each do |id|
      it "is false for #{id}" do
        definition = preset(id)

        definition["steps"].each do |step|
          expect(described_class.reads_plan?(definition, from: step["id"])).to be(false)
        end
        expect(described_class.reads_plan?(definition, from: nil)).to be(false)
      end
    end

    it "counts every step for an unknown or nil from" do
      definition = preset("rpiv")

      expect(described_class.reads_plan?(definition, from: nil)).to be(true)
      expect(described_class.reads_plan?(definition, from: "nope")).to be(true)
    end

    it "is true at every step when the top-level include lists implementation-plan" do
      definition = parse("include: [implementation-plan]\nsteps:\n  a:\n    prompt: A.\n  b:\n    prompt: B.\n").to_h

      expect(described_class.reads_plan?(definition, from: "b")).to be(true)
    end

    it "is true for a plan_status require, and false for a definition that names neither" do
      with_proof = parse("steps:\n  a:\n    prompt: A.\n    require:\n      - plan_status: done\n").to_h
      neither = parse(minimal).to_h

      expect(described_class.reads_plan?(with_proof, from: "a")).to be(true)
      expect(described_class.reads_plan?(neither, from: "build")).to be(false)
    end
  end

  describe "require" do
    def step_require(text)
      parse("steps:\n  build:\n    prompt: Build it.\n    require:\n#{text.lines.map { |l| "      #{l}" }.join}").steps.first["require"]
    end

    it "reads the four proofs as one-key entries, kept in order" do
      list = step_require("- commits: 1\n- nonempty: implement.md\n- plan_status: done\n- tracked_clean: true\n")
      expect(list).to eq([{"commits" => 1}, {"nonempty" => "implement.md"}, {"plan_status" => "done"}, {"tracked_clean" => true}])
    end

    it "reads command, inbox_item and remote_unchanged" do
      list = step_require("- command: lint\n- inbox_item: \"verify:{{run}}\"\n- remote_unchanged: true\n")
      expect(list).to eq([{"command" => "lint"}, {"inbox_item" => "verify:{{run}}"}, {"remote_unchanged" => true}])
    end

    it "reads optional: beside command, in either order, storing command first" do
      expect(step_require("- command: lint\n  optional: true\n")).to eq([{"command" => "lint", "optional" => true}])
      reversed = step_require("- optional: true\n  command: lint\n")
      expect(reversed).to eq([{"command" => "lint", "optional" => true}])
      expect(reversed.first.keys).to eq(%w[command optional])
    end

    it "refuses optional: on its own, beside another proof, or with a value that is not true or false" do
      yaml = ->(entry) { "steps:\n  build:\n    prompt: B.\n    require:\n#{entry}" }
      expect(problems(yaml.call("      - optional: true\n"))).to include(a_string_matching(/optional/))
      expect(problems(yaml.call("      - commits: 1\n        optional: true\n"))).to include(a_string_matching(/may take optional: true beside it/))
      expect(problems(yaml.call("      - command: lint\n        optional: yes please\n"))).to include(a_string_matching(/optional must be true or false/))
      expect(problems(yaml.call("      - command: lint\n        optional: true\n        extra: 1\n"))).to include(a_string_matching(/each require entry/))
    end

    it "lists every bad value of the new proofs" do
      yaml = "inputs:\n  task: {}\nsteps:\n  build:\n    prompt: B.\n    require:\n      - command: deploy\n      - inbox_item: \"a b\"\n      - remote_unchanged: false\n"
      expect(problems(yaml)).to include(
        "step build: require command must be test or lint, got \"deploy\"",
        /step build: require inbox_item must be a dedupe key of 1 to 200 letters.*got "a b"/,
        "step build: require remote_unchanged must be true, got false"
      )
      yaml = "steps:\n  build:\n    prompt: B.\n    require:\n      - inbox_item: \"x:{{branch}}:{{inputs.nope}}\"\n"
      expect(problems(yaml)).to include(/require inbox_item uses \{\{branch\}\}, which it can't fill in/, /require inbox_item uses \{\{inputs.nope\}\}/)
    end

    it "accepts inputs in an inbox_item key" do
      yaml = "inputs:\n  task: {}\nsteps:\n  build:\n    prompt: B.\n    require:\n      - inbox_item: \"k:{{inputs.task}}\"\n"
      expect(parse(yaml).steps.first["require"]).to eq([{"inbox_item" => "k:{{inputs.task}}"}])
    end

    describe "exec" do
      def exec_yaml(*entries)
        "inputs:\n  task: {}\nsteps:\n  build:\n    prompt: B.\n    require:\n#{entries.map { |e| "      - #{e}\n" }.join}"
      end

      it "stores the argv and the timeout in seconds" do
        list = parse(exec_yaml("exec: \"script/check --task '{{inputs.task}}' -- {{changed.files}}\"\n        timeout: 10m")).steps.first["require"]
        expect(list).to eq([{"exec" => ["script/check", "--task", "{{inputs.task}}", "--", "{{changed.files}}"], "timeout" => 600}])
        expect(list.first.keys.first).to eq("exec")
      end

      it "defaults the timeout to 5 minutes" do
        expect(parse(exec_yaml("exec: script/check")).steps.first["require"]).to eq([{"exec" => ["script/check"], "timeout" => 300}])
      end

      it "accepts two exec entries" do
        list = parse(exec_yaml("exec: a one", "exec: b two")).steps.first["require"]
        expect(list.map { |e| e["exec"] }).to eq([%w[a one], %w[b two]])
      end

      it "refuses what the argv check refuses, each as a problem" do
        expect(problems(exec_yaml("exec: \"check 'oops\""))).to include(/step build: require exec has an unbalanced quote/)
        expect(problems(exec_yaml("exec: \"check {{nope}}\""))).to include(/require exec uses \{\{nope\}\}/)
        expect(problems(exec_yaml("exec: \"check x{{changed.files}}\""))).to include(/require exec uses \{\{changed.files\}\} inside the word/)
        expect(problems(exec_yaml("exec: \"{{checkout}}/check\""))).to include(/require exec has \{\{checkout\}\} in the program/)
        expect(problems(exec_yaml("exec: 5"))).to include(/require exec must be a program and its arguments as one string/)
      end

      it "refuses optional: beside exec" do
        expect(problems(exec_yaml("exec: check\n        optional: true"))).to include(/require exec does not take optional:/)
      end

      it "refuses a bad timeout and one over 2 hours, and takes 2h" do
        expect(problems(exec_yaml("exec: check\n        timeout: soon"))).to include(/require exec timeout/)
        expect(problems(exec_yaml("exec: check\n        timeout: 3h"))).to include(/require exec timeout must be at most 2h/)
        expect(parse(exec_yaml("exec: check\n        timeout: 2h")).steps.first["require"]).to eq([{"exec" => ["check"], "timeout" => 7200}])
      end

      it "refuses a timeout with nothing after it" do
        expect(problems(exec_yaml("exec: check\n        timeout:"))).to include(/require exec timeout must be a duration such as 10m/)
        expect(problems(exec_yaml("exec: check\n        timeout: ~"))).to include(/require exec timeout must be a duration such as 10m/)
      end

      it "refuses a timeout of 0 or below" do
        expect(problems(exec_yaml("exec: check\n        timeout: 0"))).to include(/require exec timeout: must be greater than 0/)
        expect(problems(exec_yaml("exec: check\n        timeout: -5"))).to include(/require exec timeout/)
      end

      it "rounds a fractional timeout up to whole seconds" do
        expect(parse(exec_yaml("exec: check\n        timeout: 1.5")).steps.first["require"]).to eq([{"exec" => ["check"], "timeout" => 2}])
      end

      it "reports a bad exec and a bad timeout in one entry" do
        found = problems(exec_yaml("exec: \"check 'oops\"\n        timeout: soon"))
        expect(found).to include(/require exec has an unbalanced quote/, /require exec timeout/)
      end

      it "parses beside another proof and keeps the order" do
        list = parse(exec_yaml("commits: 1", "exec: check\n        timeout: 1m", "nonempty: x")).steps.first["require"]
        expect(list.map { |e| e.keys.first }).to eq(%w[commits exec nonempty])
        expect(list[1]).to eq({"exec" => ["check"], "timeout" => 60})
      end

      it "refuses a key beside exec other than timeout" do
        expect(problems(exec_yaml("exec: check\n        extra: 1"))).to include(/require exec takes only timeout:/)
      end

      it "counts as proof, so the step is not warned about" do
        expect(parse(exec_yaml("exec: check")).warnings).to eq([])
      end
    end

    it "defaults to an empty list" do
      expect(parse(minimal).steps.first["require"]).to eq([])
    end

    it "counts as proof, so the step is not warned about" do
      expect(parse("steps:\n  build:\n    prompt: B.\n    require: [{tracked_clean: true}]\n").warnings).to eq([])
      expect(parse("steps:\n  build:\n    prompt: B.\n    require: []\n").warnings.size).to eq(1)
    end

    it "lists every bad entry at once" do
      yaml = "steps:\n  build:\n    prompt: B.\n    require:\n      - commits: 0\n      - commits: 2\n      - nonempty: ../x\n      - nonempty: /abs\n" \
             "      - plan_status: finished\n      - tracked_clean: false\n      - bogus: 1\n      - {commits: 1, nonempty: a}\n      - just\n"
      expect(problems(yaml)).to include(
        "step build: require commits must be a whole number from 1 to 1000, got 0",
        "step build: require commits is listed twice",
        "step build: require nonempty must be a path under the run's artifacts directory, got \"../x\"",
        "step build: require nonempty must be a path under the run's artifacts directory, got \"/abs\"",
        "step build: require plan_status must be active, paused, done, got \"finished\"",
        "step build: require tracked_clean must be true, got false",
        "step build: require \"bogus\" is not a proof (known: commits, nonempty, plan_status, tracked_clean, command, inbox_item, remote_unchanged, exec)",
        /each require entry must be one proof/
      )
    end

    it "refuses a nonempty path with a control character or a non-normal form" do
      ["a//b", "./x", "a/./x", "x/", " x", "x ", "a/ b", "a\u0000b", "a\nb", "~x", "a/..", " "].each do |path|
        yaml = "steps:\n  build:\n    prompt: B.\n    require:\n      - nonempty: #{path.to_json}\n"
        expect(problems(yaml)).to include(/require nonempty must be a path under the run's artifacts directory/), "expected #{path.inspect} refused"
      end
      ["x.md", "sub/x.md", "a b/c.md"].each do |path|
        expect(problems("steps:\n  build:\n    prompt: B.\n    require:\n      - nonempty: #{path.to_json}\n")).to eq([])
      end
    end

    it "refuses a require that is not a list" do
      expect(problems("steps:\n  build:\n    prompt: B.\n    require: {commits: 1}\n")).to eq(["step build: require must be a list of proofs such as - commits: 1, got {\"commits\" => 1}"])
    end
  end

  describe "reviewers and a step's review" do
    let(:reviewers) { "reviewers:\n  skeptic:\n    prompt: Doubt {{review.subject}} at {{review.revision}}.\n  fan:\n    title: Fan\n    prompt: Like it.\n    include: [plan-review]\n    parallel: false\n" }

    def with_review(review, extra = "")
      "#{reviewers}#{extra}steps:\n  plan:\n    prompt: P\n#{review}"
    end

    it "parses reviewers with their defaults and a bare list as from" do
      definition = parse(with_review("    review: [skeptic, fan]\n"))
      expect(definition.to_h["reviewers"]).to eq(
        "skeptic" => {"title" => "skeptic", "prompt" => "Doubt {{review.subject}} at {{review.revision}}.", "include" => [], "parallel" => true},
        "fan" => {"title" => "Fan", "prompt" => "Like it.", "include" => ["plan-review"], "parallel" => false}
      )
      expect(definition.steps[0]["review"]).to eq(
        "from" => %w[skeptic fan], "need" => 2, "must" => [], "subject" => nil, "revision" => nil, "max_rounds" => 6,
        "timeout" => 1800, "uses" => [], "context" => "fresh", "notify" => true
      )
      expect(described_class.reviewers(definition.to_h).keys).to eq(%w[skeptic fan])
      expect(described_class.review(definition.steps[0])).to eq(definition.steps[0]["review"])
    end

    it "parses a full mapping" do
      review = "    review:\n      from: [skeptic, fan]\n      need: 1\n      must: [skeptic]\n      subject: the plan, see {{artifacts}}/research.md and round {{review.round}}\n      revision: echo hi\n      max_rounds: 3\n      timeout: 10m\n      uses: [test-db]\n      context: continue\n      notify: false\n"
      expect(parse(with_review(review)).steps[0]["review"]).to include(
        "need" => 1, "must" => ["skeptic"], "revision" => "echo hi", "max_rounds" => 3, "timeout" => 600, "uses" => ["test-db"], "context" => "continue", "notify" => false
      )
    end

    it "reads absence as none, so a definition stored before the keys loads" do
      definition = parse(minimal)
      expect(definition.to_h).not_to have_key("reviewers")
      expect(definition.steps[0]).not_to have_key("review")
      expect(described_class.reviewers({"steps" => []})).to eq({})
      expect(described_class.reviewers(nil)).to eq({})
      expect(described_class.review({"id" => "x"})).to be_nil
      expect(described_class.review({"review" => {"from" => []}})).to be_nil
      stored = JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/workflow_runs/legacy_minimal.json")))
      expect(described_class.reviewers(stored["definition"])).to eq({})
    end

    it "counts review as a proof" do
      expect(parse(with_review("    review: [skeptic]\n")).warnings.map { |w| w["code"] }).not_to include("step_without_proof")
      expect(parse(with_review("    review: {from: [skeptic]}\n")).warnings.map { |w| w["code"] }).not_to include("step_without_proof")
    end

    it "refuses an unknown reviewer, a repeat, and need or must that don't fit" do
      expect(problems(with_review("    review: [skeptic, ghost]\n"))).to include(a_string_matching(/step plan: review names unknown reviewer ghost \(known: skeptic, fan\)/))
      expect(problems("steps:\n  plan:\n    prompt: P\n    review: [a]\n")).to include(a_string_matching(/unknown reviewer a \(known: none/))
      expect(problems(with_review("    review: [skeptic, skeptic]\n"))).to include(a_string_matching(/lists skeptic more than once/))
      expect(problems(with_review("    review: {from: [skeptic], need: 2}\n"))).to include(a_string_matching(/need is 2, more than the 1 reviewer in from/))
      expect(problems(with_review("    review: {from: [skeptic, fan], need: 0}\n"))).to include(a_string_matching(/need must be a whole number of 1 or more/))
      expect(problems(with_review("    review: {from: [skeptic], must: [fan]}\n"))).to include(a_string_matching(/must lists fan, which is not in from/))
      expect(problems(with_review("    review: {from: [skeptic, fan], need: 1, must: [skeptic, fan]}\n"))).to include(a_string_matching(/need is 1, fewer than the 2 reviewers in must/))
    end

    it "refuses a bad shape, key, value or an empty review" do
      expect(problems(with_review("    review: {}\n"))).to include(a_string_matching(/review must be a list of reviewer names or a mapping with from/))
      expect(problems(with_review("    review: []\n"))).to include(a_string_matching(/review must be a list/))
      expect(problems(with_review("    review: skeptic\n"))).to include(a_string_matching(/review must be a list/))
      expect(problems(with_review("    review: {from: [skeptic], bogus: 1}\n"))).to include(a_string_matching(/unknown key bogus/))
      expect(problems(with_review("    review: {need: 1}\n"))).to include(a_string_matching(/review from must be a list/))
      expect(problems(with_review("    review: {from: [skeptic], max_rounds: 0}\n"))).to include(a_string_matching(/max_rounds must be a whole number from 1 to 50/))
      expect(problems(with_review("    review: {from: [skeptic], timeout: soon}\n"))).to include(a_string_matching(/review timeout/))
      expect(problems(with_review("    review: {from: [skeptic], context: never}\n"))).to include(a_string_matching(/review context must be one of/))
      expect(problems(with_review("    review: {from: [skeptic], notify: maybe}\n"))).to include(a_string_matching(/notify must be true or false/))
      expect(problems(with_review("    review: {from: [skeptic], uses: [edit]}\n"))).to include(a_string_matching(/step plan: review: uses: edit is not a resource a run can hold; it is taken by the agent that edits/))
    end

    it "reports an invalid from once, without a bogus need problem" do
      ["foo", "[]", "[Bad]"].each do |from|
        found = problems(with_review("    review: {from: #{from}}\n"))
        expect(found).to eq(["step plan: review from must be a list of reviewer names, got #{YAML.safe_load(from).inspect}"])
      end
      expect(problems(with_review("    review: {from: foo, need: 2}\n")).grep(/need/)).to eq([])
    end

    it "reports a repeat in must as a repeat" do
      found = problems(with_review("    review: {from: [skeptic, fan], need: 2, must: [skeptic, skeptic]}\n"))
      expect(found).to eq(["step plan: review must lists skeptic more than once"])
    end

    it "refuses a null on every key that has a default, and reads a null subject or revision as none" do
      %w[need must max_rounds timeout notify context uses].each do |key|
        found = problems(with_review("    review: {from: [skeptic], #{key}: ~}\n"))
        expect(found).to include(a_string_matching(/review #{key} .*got nothing/)), "#{key}: #{found.inspect}"
      end
      review = parse(with_review("    review: {from: [skeptic], subject: ~, revision: ~}\n")).steps[0]["review"]
      expect(review).to include("subject" => nil, "revision" => nil)
      expect(problems("reviewers:\n  a: {prompt: x, parallel: ~}\n#{minimal}")).to include(a_string_matching(/parallel must be true or false, got nothing/))
    end

    it "refuses the reviewer name summary, which would be the engine's summary.md" do
      expect(problems("reviewers:\n  summary: {prompt: x}\n#{minimal}")).to include("reviewer name summary is reserved: its verdict file would be the engine's summary.md")
      expect { parse("reviewers:\n  summary: {prompt: x}\n#{minimal}") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_workflow") }
    end

    it "refuses a reviewer whose prompt is null" do
      expect(problems("reviewers:\n  a: {prompt: ~}\n#{minimal}")).to include("reviewer a: prompt must be text, got nothing")
      expect(problems("reviewers:\n  a: {prompt: ~, prompt_file: ~}\n#{minimal}")).not_to be_empty
    end

    it "refuses a bad reviewers mapping" do
      expect(problems("reviewers: [a]\n#{minimal}")).to include(a_string_matching(/reviewers must be a mapping/))
      expect(problems("reviewers:\n  Bad-Name:\n    prompt: x\n#{minimal}")).to include(a_string_matching(/reviewer name "Bad-Name" must be lowercase/))
      expect(problems("reviewers:\n  a: nope\n#{minimal}")).to include(a_string_matching(/reviewer a must be a mapping/))
      expect(problems("reviewers:\n  a: {title: T}\n#{minimal}")).to include(a_string_matching(/reviewer a needs exactly one of prompt and prompt_file/))
      expect(problems("reviewers:\n  a: {prompt: x, prompt_file: y}\n#{minimal}")).to include(a_string_matching(/exactly one of prompt and prompt_file/))
      expect(problems("reviewers:\n  a: {prompt: x, agent: claude}\n#{minimal}")).to include(a_string_matching(/reviewer a has unknown key agent/))
      expect(problems("reviewers:\n  a: {prompt: x, parallel: 1}\n#{minimal}")).to include(a_string_matching(/parallel must be true or false/))
    end

    it "reads a reviewer's prompt_file beside the definition" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "skeptic.md"), "Doubt {{review.previous}}.\n")
        definition = described_class.parse("reviewers:\n  s: {prompt_file: skeptic.md}\n#{minimal}", id: "demo", source: "global", path: File.join(dir, "demo.yml"))
        expect(definition.to_h["reviewers"]["s"]["prompt"]).to eq("Doubt {{review.previous}}.\n")
      end
    end

    it "allows the review placeholders only in a reviewer's prompt and a review subject" do
      expect(problems("reviewers:\n  a: {prompt: 'x {{review.nope}}'}\n#{minimal}")).to include(a_string_matching(/reviewer a: prompt uses \{\{review.nope\}\}.*review.verdict_path/))
      expect(problems("steps:\n  build:\n    prompt: 'see {{review.round}}'\n")).to include(a_string_matching(/step build: prompt uses \{\{review.round\}\}/))
      expect(problems("instructions: '{{review.subject}}'\n#{minimal}")).to include(a_string_matching(/instructions uses \{\{review.subject\}\}/))
      expect(problems(with_review("    review: {from: [skeptic], subject: 'x {{review.subject}}'}\n"))).to include(a_string_matching(/review subject uses \{\{review.subject\}\}/))
      expect(problems(with_review("    review: {from: [skeptic], subject: 'x {{inputs.nope}}'}\n"))).to include(a_string_matching(/review subject uses \{\{inputs.nope\}\}/))
    end

    it "keeps reviewers in the stored copy" do
      stored = JSON.parse(JSON.generate(parse(with_review("    review: [skeptic]\n")).to_h))
      expect(stored["reviewers"].keys).to eq(%w[skeptic fan])
      expect(stored["steps"][0]["review"]["from"]).to eq(["skeptic"])
    end
  end
  describe "review round warnings" do
    def warned(yaml, code)
      parse(yaml).warnings.select { |w| w["code"] == code }
    end

    def reviewed(run_cap: 10, cap: nil, rounds: 3, extra: "")
      "max_attempts: #{run_cap}\nreviewers:\n  skeptic:\n    prompt: Doubt\nsteps:\n  a:\n    prompt: P\n    produces: [a.md]\n#{"    max_attempts: #{cap}\n" if cap}    review: {from: [skeptic], max_rounds: #{rounds}}\n  b:\n    prompt: Q\n    produces: [b.md]\n#{extra}"
    end

    it "warns when max_rounds reaches the step's own cap" do
      expect(warned(reviewed(cap: 3), "review_rounds_reach_step_attempts")).to match([include("step" => "a", "message" => /max_rounds: 3.*max_attempts: 3.*Set the step.s max_attempts: 4 or review.max_rounds: 2/)])
      expect(warned(reviewed(cap: 4), "review_rounds_reach_step_attempts")).to eq([])
      expect(warned(reviewed, "review_rounds_reach_step_attempts")).to eq([])
    end

    it "warns when the run's cap leaves fewer attempts than max_rounds" do
      expect(warned(reviewed(run_cap: 3), "review_rounds_exceed_run_attempts")).to match([include("step" => "a", "message" => /max_rounds: 3.*max_attempts: 3 leaves 2 attempts.*max_attempts: 4 or review.max_rounds: 2/)])
      expect(warned(reviewed(run_cap: 4), "review_rounds_exceed_run_attempts")).to eq([])
    end

    it "counts the review rounds of a step inside an on_fail loop" do
      loop_text = reviewed(run_cap: 7, extra: "    on_fail: {goto: a, max: 2}\n")
      expect(warned(loop_text, "on_fail_exceeds_max_attempts")).to match([include("step" => "b", "message" => /if every review round is used.*each retry runs 4 attempts again.*Raise max_attempts to 9/)])
      expect(warned(loop_text.sub("max_rounds: 3", "max_rounds: 1"), "on_fail_exceeds_max_attempts")).to eq([])
    end
    it "words an on_fail count with a reviewed step as the worst case, and counts research, a reviewed plan and implement by hand" do
      yaml = "max_attempts: 8\nreviewers:\n  skeptic:\n    prompt: D\nsteps:\n  research:\n    prompt: R\n    produces: [r.md]\n  plan:\n    prompt: P\n    produces: [p.md]\n    review: {from: [skeptic], max_rounds: 3}\n  implement:\n    prompt: I\n    produces: [i.md]\n    on_fail: {goto: plan, max: 2}\n"
      found = parse(yaml).warnings.select { |w| w["code"] == "on_fail_exceeds_max_attempts" }
      expect(found).to match([include("message" => /lets only 1 of those retries start if every review round is used \(the step then fails first on attempt 5, and each retry runs 4 attempts again\).*Raise max_attempts to 10/)])
    end

    it "names the values to set for the default max_rounds and max_attempts" do
      yaml = "reviewers:\n  skeptic:\n    prompt: D\nsteps:\n  a:\n    prompt: P\n    produces: [a.md]\n    review: [skeptic]\n  b:\n    prompt: Q\n    produces: [b.md]\n"
      expect(parse(yaml).warnings.select { |w| w["code"] == "review_rounds_exceed_run_attempts" }).to match([include("message" => /set max_attempts: 7 or review.max_rounds: 5/i)])
    end

    it "has no extends notes, and no warning from them, for a definition that extends nothing" do
      expect(parse("steps:\n  a:\n    prompt: P\n    produces: [a.md]\n").warnings).to eq([])
    end
  end
end
