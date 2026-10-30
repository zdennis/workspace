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
      "max_attempts" => 6,
      "steps" => [{"id" => "build", "title" => "build", "prompt" => "Build it.", "include" => [], "produces" => [], "status" => nil,
                   "gate" => nil, "guard" => nil, "uses" => [], "on_fail" => nil, "context" => "fresh", "timeout" => nil}]
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
      "the workflow has unknown key colour (known: schema_version, id, title, description, inputs, include, instructions, max_attempts, steps)",
      "schema_version must be 1, got 2",
      "id must be \"demo\", the name of its file, got \"other\"",
      "max_attempts must be a whole number of 1 or more, got 0",
      "input name \"Task\" must be lowercase letters, digits and '_', starting with a letter",
      "input Task has unknown key extra (known: description, required, pattern)",
      "input Task: required must be true or false",
      "step id \"Build\" must be lowercase letters, digits, '-' and '_'",
      "step Build needs exactly one of prompt and prompt_file",
      "step test has unknown key retries (known: title, prompt, prompt_file, include, produces, status, gate, guard, uses, on_fail, context, timeout)",
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
end
