require "spec_helper"
require "tmpdir"
require "json"
require "digest"

RSpec.describe Workspace::WorkflowDefinition do
  around do |example|
    Dir.mktmpdir("wf-def-imports") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:host_dir) { File.join(@dir, "global") }
  let(:host_path) { File.join(host_dir, "host.yml") }
  let(:verify_library) do
    <<~YAML
      schema_version: 0.1
      description: Expects an earlier step named implement.
      steps:
        verify:
          title: Verify
          include: [review]
          prompt: Run the tests for {{inputs.task}}.
          produces: [verify.md]
          uses: [test-db, devenv]
          on_fail: {goto: implement, max: 3, context: continue}
        other:
          prompt: Something else.
    YAML
  end
  let(:found) { {} }
  let(:lookup) do
    ->(name, layer:) {
      found.fetch(name) do
        {"path" => nil, "layer" => nil, "shadows" => [],
         "searched" => [{"layer" => "global", "path" => File.join(host_dir, "steps", "#{name}.yml")}, {"layer" => "builtin", "path" => "/builtin/steps/#{name}.yml"}]}
      end
    }
  end

  def write(relative, text)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def library(name = "verify", text = verify_library)
    path = write("global/steps/#{name}.yml", text)
    found[name] = {"path" => path, "layer" => "global", "searched" => [], "shadows" => []}
    path
  end

  def parse(yaml, import_lookup: lookup, **rest)
    described_class.parse(yaml, id: "host", source: "global", path: host_path, import_lookup: import_lookup, **rest)
  end

  def problems(yaml, **rest)
    parse(yaml, **rest)
    []
  rescue Workspace::Error => e
    expect(e.code).to eq("invalid_workflow")
    e.details.fetch("problems")
  end

  def host(steps)
    <<~YAML
      inputs:
        task: {description: The task}
      steps:
        implement:
          prompt: Implement it.
          produces: [code.md]
      #{steps.gsub(/^/, "  ")}
    YAML
  end

  def step(definition, id)
    definition.steps.find { |each| each["id"] == id }
  end

  describe "R1: an import with no other keys" do
    it "gives the library step under the host's step id, as if the host wrote it" do
      library
      imported = parse(host("check:\n  import: verify\n"))
      by_hand = parse(host(<<~YAML), import_lookup: nil)
        check:
          title: Verify
          include: [review]
          prompt: Run the tests for {{inputs.task}}.
          produces: [verify.md]
          uses: [test-db, devenv]
          on_fail: {goto: implement, max: 3, context: continue}
      YAML

      expect(step(imported, "check")).to eq(step(by_hand, "check"))
      expect(imported.to_h).to eq(by_hand.to_h)
    end

    it "lists the import, and folds its digest into resolved_sha256 but not sha256" do
      path = library
      definition = parse(host("check:\n  import: verify\n"))

      expect(definition.imports).to contain_exactly(include("step" => "check", "import" => "verify", "layer" => "global", "path" => path, "overrides" => []))
      expect(definition.sha256).to eq(Digest::SHA256.hexdigest(host("check:\n  import: verify\n")))
      expect(definition.resolved_sha256).not_to eq(definition.sha256)
      expect(definition.resolved_sha256).to eq(Digest::SHA256.hexdigest([definition.sha256, definition.imports.first["sha256"]].join("\n")))
    end

    it "gives a new resolved_sha256 when the library step changes, and the same one when another step of the file does" do
      library
      before = parse(host("check:\n  import: verify\n")).resolved_sha256
      library("verify", verify_library.sub("Something else.", "Something new."))
      expect(parse(host("check:\n  import: verify\n")).resolved_sha256).to eq(before)
      library("verify", verify_library.sub("produces: [verify.md]", "produces: [checked.md]"))
      expect(parse(host("check:\n  import: verify\n")).resolved_sha256).not_to eq(before)
    end
  end

  describe "R2: one library step imported twice" do
    it "gives two independent steps, and an override on one leaves the other alone" do
      library
      definition = parse(host("first:\n  import: verify\nsecond:\n  import: verify\n  title: Second check\n"))

      expect(step(definition, "first")["title"]).to eq("Verify")
      expect(step(definition, "second")["title"]).to eq("Second check")
      expect(step(definition, "first").except("id", "title")).to eq(step(definition, "second").except("id", "title"))
      expect(definition.imports.map { |entry| entry["step"] }).to eq(%w[first second])
    end
  end

  describe "R7: overrides" do
    before { library }

    it "replaces a list whole, and KEY: null removes the key" do
      definition = parse(host("check:\n  import: verify\n  uses: [devenv]\n  on_fail: null\n"))

      expect(step(definition, "check")["uses"]).to eq(["devenv"])
      expect(step(definition, "check")["on_fail"]).to be_nil
    end

    it "takes the host's prompt_file over the library's prompt" do
      write("global/check.md", "Check from a file.\n")
      definition = parse(host("check:\n  import: verify\n  prompt_file: check.md\n"))

      expect(step(definition, "check")["prompt"]).to eq("Check from a file.\n")
      expect(definition.imports.first["removes"]).to eq(["prompt"])
    end

    it "takes the host's prompt over a library prompt_file, read against the library's directory" do
      write("global/steps/verify.md", "Verify from the library.\n")
      library("verify", verify_library.sub("prompt: Run the tests for {{inputs.task}}.", "prompt_file: verify.md"))

      expect(step(parse(host("check:\n  import: verify\n")), "check")["prompt"]).to eq("Verify from the library.\n")
      definition = parse(host("check:\n  import: verify\n  prompt: Inline.\n"))
      expect(step(definition, "check")["prompt"]).to eq("Inline.")
      expect(definition.imports.first["removes"]).to eq(["prompt_file"])
    end

    it "rejects a null that leaves no prompt with the existing message and the provenance suffix" do
      path = File.join(host_dir, "steps", "verify.yml")

      expect(problems(host("check:\n  import: verify\n  prompt: null\n"))).to eq(
        ["step check needs exactly one of prompt and prompt_file (step imported from verify, #{path}; the host sets prompt)"]
      )
    end
  end

  describe "R10: an imported step is checked as a hand-written host step" do
    let(:strict_library) do
      <<~YAML
        steps:
          verify:
            prompt: Check {{inputs.ticket}}.
            produces: [verify.md]
            on_fail: {goto: build, max: 2}
            review: [security]
      YAML
    end

    it "rejects an input the host lacks, a goto naming no host step and a review naming no host reviewer" do
      library("verify", strict_library)
      reported = problems(host("check:\n  import: verify\n"))

      expect(reported).to include(a_string_matching(/\Astep check: prompt uses \{\{inputs\.ticket\}\}/))
      expect(reported).to include(a_string_matching(/\Astep check: on_fail goto/))
      expect(reported).to include(a_string_matching(/\Astep check: review names unknown reviewer security/))
      expect(reported.size).to eq(3)
    end

    it "accepts the same import with corrective overrides" do
      library("verify", strict_library)
      definition = parse(host("check:\n  import: verify\n  prompt: Check {{inputs.task}}.\n  on_fail: {goto: implement, max: 2}\n  review: null\n"))

      expect(step(definition, "check")["on_fail"]).to include("goto" => "implement")
      expect(step(definition, "check")).not_to have_key("review")
    end
  end

  describe "R11: the provenance suffix" do
    it "ends every problem of an imported step with the library and the keys the host set, and no other step's" do
      path = library
      reported = problems(<<~YAML)
        steps:
          build:
            prompt: Build {{inputs.nope}}.
          check:
            import: verify
            uses: [devenv]
            context: null
      YAML

      suffix = "(step imported from verify, #{path}; the host sets uses, context)"
      expect(reported).to include("step build: prompt uses {{inputs.nope}}, which nothing supplies (known: {{workspace}}, {{branch}}, {{artifacts}}, {{run}})")
      check = reported.select { |each| each.start_with?("step check") }
      expect(check).not_to be_empty
      expect(check).to all(end_with(suffix))
    end

    it "names only the library when the host set no keys" do
      path = library
      reported = problems("steps:\n  check:\n    import: verify\n")

      expect(reported).not_to be_empty
      expect(reported).to all(end_with("(step imported from verify, #{path})"))
    end
  end

  describe "R12: resolution errors" do
    it "reports every bad import in one error, naming the step, reference and path, with no post-merge problem" do
      library
      bad = write("global/steps/bad.yml", "steps: [1]\n")
      found["bad"] = {"path" => bad, "layer" => "global", "searched" => [], "shadows" => []}
      reported = problems(<<~YAML)
        steps:
          a:
            import: 42
          b:
            import: missing
          c:
            import: nofile.yml#verify
          d:
            import: verify.yml#nosuch
          e:
            import: bad
          f:
            prompt: Uses {{inputs.nope}}.
      YAML

      expect(reported).to include(a_string_starting_with("step a: import must be a step name"))
      expect(reported).to include("step b: import missing: no layer has steps/missing.yml (searched: global #{File.join(host_dir, "steps", "missing.yml")}, builtin /builtin/steps/missing.yml)")
      expect(reported).to include("step c: import nofile.yml#verify: no file #{File.join(host_dir, "nofile.yml")}")
      expect(reported).to include(a_string_starting_with("step d: import verify.yml#nosuch: no file"))
      expect(reported).to include(a_string_starting_with("step e: import bad (#{bad}):"))
      expect(reported.grep(/inputs\.nope/)).to be_empty
    end

    it "reports a missing step of an existing file with the steps it holds" do
      write("global/lib.yml", verify_library)

      expect(problems("steps:\n  d:\n    import: lib.yml#nosuch\n")).to eq(
        ["step d: import lib.yml#nosuch (#{File.join(host_dir, "lib.yml")}): the file has no step nosuch (its steps: verify, other)"]
      )
    end
  end

  describe "R13: imports where none can go" do
    it "refuses a library step holding import, after or fan_out" do
      library("verify", "steps:\n  verify:\n    import: other\n    after: x\n    fan_out: {}\n    prompt: P\n")

      reported = problems("steps:\n  check:\n    import: verify\n")
      expect(reported).to include(a_string_matching(/step check: import verify .*: step verify: a library step can't import/))
      expect(reported).to include(a_string_matching(/step verify: a library step can't take after:/))
      expect(reported).to include(a_string_matching(/step verify: a library step can't be a fan_out group/))
    end

    it "refuses a top-level import, pointing to extends:" do
      library

      expect(problems("import: verify\n#{minimal_steps}")).to eq(
        ["import: works on a step, not on a whole workflow; to build on another workflow, use extends: ID"]
      )
    end

    it "refuses an import on a fan_out group, pointing to extends:, and on a group's sibling" do
      library
      reported = problems(<<~YAML)
        steps:
          group:
            import: verify
            fan_out:
              one:
                import: verify
                prompt: One.
                produces: [one.md]
              two:
                prompt: Two.
                produces: [two.md]
      YAML

      expect(reported).to include("step group is a fan_out group, which can't import: (an import is one step); to build on another workflow's steps, use extends: ID")
      expect(reported).to include("step one (in fan_out group group): a fan_out sibling can't import: a step yet; write the step in the group")
      expect(reported.grep(/unknown key/)).to be_empty
    end
  end

  describe "R21: no catalog" do
    it "leaves a bare-name import not checked, without failing, and still resolves a file reference" do
      write("global/lib.yml", verify_library)
      definition = parse(host("check:\n  import: verify\nlocal:\n  import: lib.yml#verify\n"), import_lookup: nil)

      expect(definition.warnings).to include(include("code" => "import_not_checked", "step" => "check"))
      expect(definition.warnings.select { |each| each["step"] == "check" }.map { |each| each["code"] }).to eq(["import_not_checked"])
      expect(step(definition, "local")["title"]).to eq("Verify")
      expect(definition.imports.map { |entry| entry["step"] }).to eq(["local"])
    end

    it "still reports another step's problem, with no suffix" do
      expect(problems("steps:\n  check:\n    import: verify\n  build:\n    prompt: Build {{inputs.nope}}.\n", import_lookup: nil)).to eq(
        ["step build: prompt uses {{inputs.nope}}, which nothing supplies (known: {{workspace}}, {{branch}}, {{artifacts}}, {{run}})"]
      )
    end
  end

  describe "import under extends: replace:" do
    it "swaps the parent's step for the library step" do
      path = library
      parent = "inputs:\n  task: {description: The task}\nsteps:\n  implement:\n    prompt: P\n    produces: [p.md]\n  check:\n    prompt: Old check.\n    produces: [c.md]\n"
      parent_lookup = ->(id, below: nil) { {"text" => parent, "path" => File.join(host_dir, "base.yml"), "source" => "global"} if id == "base" }
      definition = parse("extends: base\nreplace:\n  check:\n    import: verify\n", parent_lookup: parent_lookup)

      expect(step(definition, "check")["title"]).to eq("Verify")
      expect(definition.origins["check"]).to eq("own")
      expect(definition.imports).to contain_exactly(include("step" => "check", "path" => path))
    end
  end

  describe "notes" do
    it "keeps import notes next to the extends notes" do
      library
      parent = "steps:\n  implement:\n    prompt: P\n    produces: [p.md]\n    review: [sec]\nreviewers:\n  sec: {prompt: Review.}\n"
      parent_lookup = ->(id, below: nil) { {"text" => parent, "path" => File.join(host_dir, "base.yml"), "source" => "global"} if id == "base" }
      definition = parse(<<~YAML, parent_lookup: parent_lookup)
        extends: base
        inputs:
          task: {description: The task}
        replace:
          implement:
            prompt: P2
            produces: [p.md]
        steps:
          check:
            import: verify
            uses: null
      YAML

      expect(definition.warnings.map { |each| each["code"] }).to include("review_dropped", "import_dropped")
    end
  end

  describe "R24: a definition with no import" do
    it "reads the same with an import lookup as without one" do
      plain_presets = Dir[File.join(PresetSimulation::WORKFLOWS, "*.yml")].reject do |path|
        definition = PresetSimulation.definition(File.basename(path, ".yml"))
        definition.imports.any? || definition.parents.any? { |parent| parent["import_sha256s"].any? }
      end
      expect(plain_presets.map { |path| File.basename(path, ".yml") }).to include("bugfix", "investigate")

      plain_presets.each do |path|
        id = File.basename(path, ".yml")
        plain = PresetSimulation.definition(id)
        parent_lookup = ->(parent, below: nil) {
          file = File.join(PresetSimulation::WORKFLOWS, "#{parent}.yml")
          {"text" => File.read(file), "path" => file, "source" => "builtin"} if File.file?(file) && below.nil?
        }
        looked = described_class.parse(File.read(path), id: id, source: "builtin", path: path, parent_lookup: parent_lookup, import_lookup: lookup)

        expect([looked.sha256, looked.resolved_sha256, looked.to_h, looked.warnings, looked.imports]).to eq([plain.sha256, plain.resolved_sha256, plain.to_h, plain.warnings, []]), id
      end
    end
  end

  def minimal_steps
    "steps:\n  build:\n    prompt: Build it.\n    produces: [b.md]\n"
  end
end
