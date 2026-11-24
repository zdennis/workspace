require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped step library" do
  steps_dir = File.join(PROJECT_ROOT, "lib", "workflows", "steps")
  names = Dir[File.join(steps_dir, "*.yml")].map { |path| File.basename(path, ".yml") }.sort

  # The delivery chain, in order. A step that joins the library adds one name here.
  chain = %w[goals design implement verify]

  def parse(yaml)
    Dir.mktmpdir("step-library") do |dir|
      path = File.join(dir, "host.yml")
      File.write(path, yaml)
      Workspace::WorkflowDefinition.parse(yaml, id: "host", source: "builtin", path: path,
        import_lookup: PresetSimulation.import_lookup, confine_dir: File.realpath(PresetSimulation::WORKFLOWS))
    end
  end

  def host_for(names)
    # implement has no on_fail of its own, so its default loop would go back to a guarded step; a host sets one.
    steps = names.map { |name| "  #{name}:\n    import: #{name}\n#{"    on_fail: stop\n" if name == "implement"}" }.join
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
        expect(text).not_to match(/\.claude\/skills|CHANGELOG|rspec|\bruby\b|\bbundle\b|\bnpm\b|pytest/i)
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

  it "chains #{chain.join(", ")} with no guard after a commit" do
    definition = parse(host_for(chain))
    expect(definition.steps.map { |step| step["id"] }).to eq(chain)
    guard_codes = definition.warnings.map { |each| each["code"] }.grep(/\Aguard_unchanged/)
    expect(guard_codes).to eq([])
  end

  it "warns of a guard looping back when implement has no on_fail of its own" do
    definition = parse(host_for(chain).sub("    on_fail: stop\n", ""))
    expect(definition.warnings.map { |each| each["code"] }).to include("guard_unchanged_loop_back")
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
end
