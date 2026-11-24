require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped step library" do
  steps_dir = File.join(PROJECT_ROOT, "lib", "workflows", "steps")
  names = Dir[File.join(steps_dir, "*.yml")].map { |path| File.basename(path, ".yml") }.sort

  # The delivery chain, in order. A step that joins the library adds one name here.
  chain = %w[goals design tests_first implement verify acceptance_check docs_update code_review open_pr]

  def parse(yaml)
    Dir.mktmpdir("step-library") do |dir|
      path = File.join(dir, "host.yml")
      File.write(path, yaml)
      Workspace::WorkflowDefinition.parse(yaml, id: "host", source: "builtin", path: path,
        import_lookup: PresetSimulation.import_lookup, confine_dir: File.realpath(PresetSimulation::WORKFLOWS))
    end
  end

  def host_for(names)
    # tests_first has no on_fail of its own, so its default loop would go back to design, a guarded step; a host sets one.
    steps = names.map { |name| "  #{name}:\n    import: #{name}\n#{"    on_fail: stop\n" if name == "tests_first"}" }.join
    "max_attempts: 12\ninputs:\n  task: {description: The task}\nsteps:\n#{steps}"
  end

  it "ships the steps the chain lists" do
    expect(names).to include(*chain)
  end

  # `workflow validate`'s lint (packs, command roles, the main agent) reads the person's setup, so it is not run here.
  names.each do |name|
    describe name do
      let(:text) { File.read(File.join(steps_dir, "#{name}.yml")) }

      it "parses as the only imported step, beside an implement stub, with no problem and no warning" do
        stub = (name == "implement") ? "stub" : "implement"
        definition = parse("max_attempts: 12\ninputs:\n  task: {description: The task}\nsteps:\n  #{stub}:\n    prompt: Implement it.\n    produces: [#{stub}.md]\n  #{name}:\n    import: #{name}\n")
        expect(definition.steps.map { |step| step["id"] }).to include(name)
        expect(definition.warnings).to eq([])
      rescue Workspace::Error => e
        raise "#{name}: #{e.details.fetch("problems", [e.message]).join("; ")}"
      end

      it "describes what it reads, writes and needs" do
        description = YAML.safe_load(text).fetch("description")
        expect(description).to match(/reads/i)
        expect(description).to match(/writes/i)
        expect(description).to match(/needs/i)
      end

      it "names no project tool, language or file" do
        expect(text).not_to match(/\.claude\/skills|rspec|\bruby\b|\bbundle\b|\bnpm\b|pytest/i)
        expect(text).not_to match(/(?-i:CHANGELOG)|changelog\.\w+/i)
      end

      it "uses prompt, never prompt_file" do
        expect(text).not_to match(/prompt_file/)
        expect(YAML.safe_load(text).fetch("steps").values).to all(include("prompt"))
      end

      it "reaches check-ids only through workspace step check-ids" do
        expect(text.scan("check-ids").size).to eq(text.scan("workspace step check-ids").size)
      end
    end
  end

  it "chains #{chain.join(", ")} with no warning" do
    definition = parse(host_for(chain))
    expect(definition.steps.map { |step| step["id"] }).to eq(chain)
    expect(definition.warnings).to eq([])
  end

  it "warns of a guard looping back when tests_first has no on_fail of its own" do
    definition = parse(host_for(chain).sub("    on_fail: stop\n", ""))
    expect(definition.warnings.map { |each| each["code"] }).to include("guard_unchanged_loop_back")
  end

  describe "code_review's reviewers" do
    let(:imported) { parse("max_attempts: 12\ninputs:\n  task: {description: The task}\nsteps:\n  implement:\n    prompt: Implement it.\n    produces: [implement.md]\n  code_review:\n    import: code_review\n") }

    it "brings correctness, tests and maintainability to a host with no reviewers" do
      expect(imported.warnings).to eq([])
      expect(imported.to_h["reviewers"].keys).to match_array(%w[correctness tests maintainability])
      review = imported.steps.find { |step| step["id"] == "code_review" }["review"]
      expect(review).to include("from" => %w[correctness tests maintainability], "need" => 2, "must" => %w[correctness], "max_rounds" => 3)
      expect(review["revision"]).to eq("git rev-parse HEAD 'HEAD^{tree}'")
    end

    it "keeps a host reviewer of the same name instead" do
      host = "max_attempts: 12\ninputs:\n  task: {description: The task}\nreviewers:\n  correctness:\n    prompt: The host's own correctness prompt.\nsteps:\n  implement:\n    prompt: Implement it.\n    produces: [implement.md]\n  code_review:\n    import: code_review\n"
      definition = parse(host)
      expect(definition.to_h["reviewers"]["correctness"]["prompt"]).to include("The host's own correctness prompt.")
      expect(definition.to_h["reviewers"].keys).to match_array(%w[correctness tests maintainability])
      library = YAML.safe_load_file(File.join(steps_dir, "code_review.yml"))["reviewers"]
      expect(definition.to_h["reviewers"]["maintainability"]["prompt"]).to eq(library["maintainability"]["prompt"])
      expect(definition.to_h["reviewers"]["tests"]["prompt"]).to eq(library["tests"]["prompt"])
      expect(definition.steps.find { |step| step["id"] == "code_review" }["review"]["from"]).to eq(%w[correctness tests maintainability])
    end
  end

  describe "goals' acceptance check" do
    let(:command) { YAML.safe_load_file(File.join(steps_dir, "goals.yml")).dig("steps", "goals", "status", "run") }
    let(:pattern) { Regexp.new(command[/--each-line-matches '([^']+)'/, 1]) }

    let(:ac_line) { Regexp.new(command[/\Agrep -Eq '([^']+)'/, 1]) }

    it "runs workspace step check-ids on acceptance.md, after a check that an AC line exists" do
      expect(command).to start_with("grep -Eq ")
      expect(command).to include("&& workspace step check-ids --prefix AC --defined acceptance.md --covered acceptance.md")
    end

    it "requires at least one AC line" do
      prose = ["Some prose about the goal.", "", "R1 Given x When y Then z — test"]
      expect(prose.grep(ac_line)).to eq([])
      expect("AC1 Given x When y Then z — test").to match(ac_line)
    end

    it "accepts lines that end with a verify method" do
      ["AC1 Given a user When they log in Then they see a name — test",
        "AC-2 Given x When y Then z — manual",
        "AC3 Given x When y Then z - metric.",
        "AC4 Given x When y Then z — test."].each { |line| expect(line).to match(pattern) }
    end

    it "rejects a line with no verify method" do
      ["AC1 Given a user When they log in Then they see a name",
        "AC2 Given x When y Then z — test later",
        "AC1 Given a When b Then the latest",
        "AC1: Given x — test",
        "AC1 Given x — Test",
        "R1 Given x When y Then z — test"].each { |line| expect(line).not_to match(pattern) }
    end
  end

  describe "acceptance_check's report check" do
    let(:command) { YAML.safe_load_file(File.join(steps_dir, "acceptance_check.yml")).dig("steps", "acceptance_check", "status", "run") }
    let(:pattern) { Regexp.new(command[/--each-line-matches '([^']+)'/, 1]) }

    it "runs workspace step check-ids over acceptance.md and acceptance-report.md" do
      expect(command).to start_with("workspace step check-ids --prefix AC --defined acceptance.md --covered acceptance-report.md")
    end

    it "requires a clean tracked tree" do
      step = YAML.safe_load_file(File.join(steps_dir, "acceptance_check.yml")).dig("steps", "acceptance_check")
      expect(step["require"]).to eq([{"tracked_clean" => true}])
    end

    it "loops back to implement twice, continuing the conversation" do
      step = YAML.safe_load_file(File.join(steps_dir, "acceptance_check.yml")).dig("steps", "acceptance_check")
      expect(step["on_fail"]).to eq({"goto" => "implement", "max" => 2, "context" => "continue"})
    end

    it "accepts a PASS with evidence and a MANUAL with text" do
      ["AC1 PASS spec/foo_spec.rb shows the name", "AC-2 MANUAL check the page in a browser", "AC1 PASS x "].each { |line| expect(line).to match(pattern) }
    end

    it "rejects a bare PASS, a FAIL and the colon form" do
      ["AC1 PASS", "AC1 PASS ", "AC1 FAIL broken", "AC1: PASS x", "AC1 MANUAL", "AC1 PASSED x", "AC1 PASS  x", "AC1 pass x", "AC1 MANUAL  x"].each { |line| expect(line).not_to match(pattern) }
    end
  end

  describe "tests_first's coverage check" do
    let(:command) { YAML.safe_load_file(File.join(steps_dir, "tests_first.yml")).dig("steps", "tests_first", "status", "run") }
    let(:pattern) { Regexp.new(command[/--each-line-matches '([^']+)'/, 1]) }

    it "runs workspace step check-ids over acceptance.md and tests-first.md" do
      expect(command).to start_with("workspace step check-ids --prefix AC --defined acceptance.md --covered tests-first.md")
    end

    it "accepts a test line and a not-test line" do
      ["AC1 spec/foo_spec.rb shows the name", "AC-2 not-test"].each { |line| expect(line).to match(pattern) }
    end

    it "rejects a line with nothing after the number, or the colon form" do
      ["AC1 ", "AC1", "AC1: spec/foo_spec.rb shows the name", "R1 spec/foo_spec.rb x"].each { |line| expect(line).not_to match(pattern) }
    end
  end
end
