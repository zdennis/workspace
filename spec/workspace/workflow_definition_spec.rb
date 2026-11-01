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
      Dir[File.expand_path("../../lib/workflows/*.yml", __dir__)].each do |file|
        expect(described_class.parse(File.read(file), id: File.basename(file, ".yml"), source: "builtin", path: file).warnings).to eq([])
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
      "id" => "demo", "title" => "demo", "description" => nil, "inputs" => {}, "include" => [], "instructions" => nil,
      "max_attempts" => 6, "stall" => nil, "redeliver" => 3,
      "steps" => [{"id" => "build", "title" => "build", "prompt" => "Build it.", "include" => [], "produces" => [], "status" => nil,
                   "gate" => nil, "guard" => nil, "require" => [], "uses" => [], "on_fail" => nil, "context" => "fresh", "timeout" => nil, "on_timeout" => "warn"}]
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

  it "reads a prompt from prompt_file, beside the definition" do
    Dir.mktmpdir("wf-def") do |dir|
      File.write(File.join(dir, "build.md"), "Build from a file.\n")
      definition = parse("steps:\n  build:\n    prompt_file: build.md\n", path: File.join(dir, "demo.yml"))

      expect(definition.steps.first["prompt"]).to eq("Build from a file.\n")
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
      "the workflow has unknown key colour (known: schema_version, id, title, description, inputs, include, instructions, max_attempts, stall, redeliver, steps)",
      "schema_version must be 1, got 2",
      "id must be \"demo\", the name of its file, got \"other\"",
      "max_attempts must be a whole number of 1 or more, got 0",
      "input name \"Task\" must be lowercase letters, digits and '_', starting with a letter",
      "input Task has unknown key extra (known: description, required, pattern)",
      "input Task: required must be true or false",
      "step id \"Build\" must be lowercase letters, digits, '-' and '_'",
      "step Build needs exactly one of prompt and prompt_file",
      "step test has unknown key retries (known: title, prompt, prompt_file, include, produces, status, gate, guard, require, uses, on_fail, context, timeout, on_timeout)",
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
        "step build: require \"bogus\" is not a proof (known: commits, nonempty, plan_status, tracked_clean, command, inbox_item, remote_unchanged)",
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
end
