require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowImports do
  around do |example|
    Dir.mktmpdir("wf-imports") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:host_dir) { File.join(@dir, "global") }
  let(:verify_library) do
    <<~YAML
      schema_version: 0.1
      description: Expects an earlier step named implement.
      steps:
        verify:
          title: Verify
          include: [review]
          prompt: Run the tests.
          produces: [verify.md]
          uses: [test-db, devenv]
          on_fail: {goto: implement, max: 3, context: continue}
        other:
          prompt: Something else.
    YAML
  end
  let(:lookups) { [] }
  let(:found) { {} }
  let(:lookup) do
    ->(name, layer:) {
      lookups << [name, layer]
      found.fetch(name) { {"path" => nil, "layer" => nil, "searched" => [{"layer" => "global", "path" => File.join(host_dir, "steps", "#{name}.yml")}, {"layer" => "builtin", "path" => "/builtin/steps/#{name}.yml"}], "shadows" => []} }
    }
  end

  def write(relative, text)
    path = File.join(@dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def library_at(relative, text = verify_library, layer: "global", shadows: [])
    path = write(relative, text)
    found[File.basename(relative, ".yml")] = {"path" => path, "layer" => layer, "searched" => [], "shadows" => shadows}
    path
  end

  def imports(lookup: self.lookup, layer: "global", base_dir: host_dir, confine_dir: nil)
    described_class.new(lookup: lookup, layer: layer, base_dir: base_dir, confine_dir: confine_dir)
  end

  describe "R1: an import with no other keys" do
    it "gives the library step under the host's step id, with import dropped" do
      library_at("global/steps/verify.yml")
      importer = imports
      raw = importer.expand({"steps" => {"check" => {"import" => "verify"}}})

      expect(importer.failure).to eq([])
      expect(raw["steps"]["check"]).to eq(YAML.safe_load(verify_library)["steps"]["verify"])
      expect(lookups).to eq([["verify", "global"]])
    end

    it "leaves steps without import, and the rest of the mapping, as written" do
      raw = {"title" => "T", "steps" => {"one" => {"prompt" => "p"}}}
      expect(imports.expand(raw)).to eq(raw)
    end
  end

  describe "R2: one library step imported twice" do
    it "gives two independent steps" do
      library_at("global/steps/verify.yml")
      raw = imports.expand({"steps" => {"a" => {"import" => "verify"}, "b" => {"import" => "verify", "title" => "B"}}})

      expect(raw["steps"]["a"]["title"]).to eq("Verify")
      expect(raw["steps"]["b"]["title"]).to eq("B")
      raw["steps"]["a"]["produces"] << "extra.md"
      expect(raw["steps"]["b"]["produces"]).to eq(["verify.md"])
    end
  end

  describe "R3: bare names go to the lookup from the host's layer" do
    it "asks the lookup with the host's layer and reports the layer and the shadowed files" do
      lower = File.join(@dir, "builtin", "steps", "verify.yml")
      library_at("project/steps/verify.yml", layer: "project", shadows: [lower])
      importer = imports(layer: "project")
      importer.expand({"steps" => {"verify" => {"import" => "verify"}}})

      expect(lookups).to eq([["verify", "project"]])
      expect(importer.imports.first).to include("layer" => "project", "shadows" => [lower])
    end
  end

  describe "R4: a library without the named step" do
    it "is a failure listing the steps the file holds" do
      path = library_at("global/steps/review.yml", verify_library)
      importer = imports
      importer.expand({"steps" => {"check" => {"import" => "review"}}})

      expect(importer.failure).to eq(["step check: import review (#{path}): the file has no step review (its steps: verify, other)"])
    end
  end

  describe "R5: PATH#NAME references" do
    it "resolves PATH against the base directory and supplies several steps from one file" do
      write("shared/rpiv-steps.yml", verify_library)
      importer = imports
      raw = importer.expand({"steps" => {"v" => {"import" => "../shared/rpiv-steps.yml#verify"}, "o" => {"import" => "../shared/rpiv-steps.yml#other"}}})

      expect(importer.failure).to eq([])
      expect(raw["steps"]["v"]["title"]).to eq("Verify")
      expect(raw["steps"]["o"]).to eq({"prompt" => "Something else."})
      expect(importer.imports.map { |each| [each["path"], each["layer"]] }).to eq([[File.join(@dir, "shared/rpiv-steps.yml"), nil]] * 2)
      expect(lookups).to eq([])
    end

    it "accepts an absolute path and a ~ path when not confined" do
      path = write("shared/lib.yml", verify_library)
      importer = imports
      home = ENV["HOME"]
      ENV["HOME"] = @dir
      raw = begin
        importer.expand({"steps" => {"a" => {"import" => "#{path}#verify"}, "b" => {"import" => "~/shared/lib.yml#other"}}})
      ensure
        ENV["HOME"] = home
      end

      expect(importer.failure).to eq([])
      expect(raw["steps"].keys).to eq(%w[a b])
    end

    it "refuses a null or empty reference" do
      importer = imports
      importer.expand({"steps" => {"a" => {"import" => nil}, "b" => {"import" => ""}}})
      expect(importer.failure).to eq([
        "step a: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got nil",
        "step b: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got \"\""
      ])
      expect(lookups).to eq([])
    end

    it "refuses a PATH that doesn't end in .yml or holds a NUL byte, and a NAME off the id pattern" do
      importer = imports
      importer.expand({"steps" => {"a" => {"import" => "lib.yaml#verify"}, "b" => {"import" => "lib.yml#Bad Name"}, "c" => {"import" => 3}, "d" => {"import" => "li\0b.yml#verify"}}})

      expect(importer.failure).to eq([
        "step a: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got \"lib.yaml#verify\"",
        "step b: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got \"lib.yml#Bad Name\"",
        "step c: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got 3",
        "step d: import must be a step name (#{Workspace::IdPatterns::WORKFLOW_ID_RULE}) or PATH.yml#NAME, got \"li\\u0000b.yml#verify\""
      ])
    end
  end

  describe "R7: overrides" do
    before { library_at("global/steps/verify.yml") }

    it "replaces a list or a map whole and removes a key set to null" do
      importer = imports
      raw = importer.expand({"steps" => {"verify" => {"import" => "verify", "uses" => nil, "on_fail" => {"goto" => "fix", "max" => 3}, "include" => ["commits"]}}})

      step = raw["steps"]["verify"]
      expect(step).not_to have_key("uses")
      expect(step["on_fail"]).to eq({"goto" => "fix", "max" => 3})
      expect(step["include"]).to eq(["commits"])
      expect(importer.imports.first).to include("overrides" => %w[on_fail include], "removes" => %w[uses])
    end

    it "drops the library prompt_file when the host sets prompt, and the reverse" do
      library_at("global/steps/filed.yml", "steps:\n  filed:\n    prompt_file: filed.md\n")
      importer = imports
      raw = importer.expand({"steps" => {
        "verify" => {"import" => "verify", "prompt_file" => "mine.md"},
        "filed" => {"import" => "filed", "prompt" => "Inline."}
      }})

      expect(raw["steps"]["verify"]).not_to have_key("prompt")
      expect(raw["steps"]["verify"]["prompt_file"]).to eq("mine.md")
      expect(raw["steps"]["filed"]).to eq({"prompt" => "Inline."})
      expect(importer.imports.map { |each| each["removes"] }).to eq([%w[prompt], %w[prompt_file]])
    end

    it "deletes the key on prompt: null, never writing nil, so the definition can say a prompt is missing" do
      raw = imports.expand({"steps" => {"verify" => {"import" => "verify", "prompt" => nil}}})
      expect(raw["steps"]["verify"]).not_to have_key("prompt")
      expect(raw["steps"]["verify"]).not_to have_key("prompt_file")
    end

    it "keeps after: for the extends merge and does not count it as an override" do
      importer = imports
      raw = importer.expand({"replace" => {"verify" => {"import" => "verify"}}, "steps" => {"extra" => {"import" => "verify", "after" => "plan"}}})

      expect(raw["replace"]["verify"]["title"]).to eq("Verify")
      expect(raw["steps"]["extra"]["after"]).to eq("plan")
      expect(importer.imports.last["overrides"]).to eq([])
    end
  end

  describe "R8: dropped-value notes" do
    before { library_at("global/steps/verify.yml") }

    it "notes a null on a key the library set, and a list or map override that loses entries" do
      importer = imports
      importer.expand({"steps" => {"verify" => {"import" => "verify", "uses" => nil, "include" => ["commits"], "on_fail" => {"goto" => "fix"}}}})

      expect(importer.notes).to eq([
        {"code" => "import_dropped", "step" => "verify", "message" => "step verify: uses: null removes the uses of imported step verify ([\"test-db\",\"devenv\"])"},
        {"code" => "import_dropped", "step" => "verify", "message" => "step verify: include replaces the include of imported step verify whole and drops review"},
        {"code" => "import_dropped", "step" => "verify", "message" => "step verify: on_fail replaces the on_fail of imported step verify whole and drops max, context"}
      ])
    end

    it "is silent for a scalar override, a list keeping every entry, and a null on a key the library lacked" do
      importer = imports
      importer.expand({"steps" => {"verify" => {"import" => "verify", "title" => "Mine", "uses" => %w[devenv test-db extra], "gate" => nil}}})
      expect(importer.notes).to eq([])
    end
  end

  describe "R9: prompt_file anchoring" do
    it "anchors a library's relative prompt_file to the library's directory and leaves the host's own as written" do
      library_at("global/steps/filed.yml", "steps:\n  filed:\n    prompt_file: prompts/filed.md\n")
      raw = imports.expand({"steps" => {"a" => {"import" => "filed"}, "b" => {"import" => "filed", "prompt_file" => "mine.md"}}})

      expect(raw["steps"]["a"]["prompt_file"]).to eq(File.join(@dir, "global/steps/prompts/filed.md"))
      expect(raw["steps"]["b"]["prompt_file"]).to eq("mine.md")
    end
  end

  describe "R11: provenance" do
    it "names the reference, the file and the keys the host set, nulls included" do
      path = library_at("global/steps/verify.yml")
      importer = imports
      importer.expand({"steps" => {"a" => {"import" => "verify"}, "b" => {"import" => "verify", "timeout" => "15m", "uses" => nil}, "c" => {"prompt" => "p"}}})

      expect(importer.provenance("a")).to eq("(step imported from verify, #{path})")
      expect(importer.provenance("b")).to eq("(step imported from verify, #{path}; the host sets timeout, uses)")
      expect(importer.provenance("c")).to be_nil
    end
  end

  describe "R12: resolution failures" do
    it "lists every layer searched for a bare-name miss" do
      importer = imports
      importer.expand({"steps" => {"check" => {"import" => "nothing"}}})
      expect(importer.failure).to eq(["step check: import nothing: no layer has steps/nothing.yml (searched: global #{host_dir}/steps/nothing.yml, builtin /builtin/steps/nothing.yml)"])
    end

    it "names the absolute path of a missing file" do
      importer = imports
      importer.expand({"steps" => {"check" => {"import" => "gone.yml#verify"}}})
      expect(importer.failure).to eq(["step check: import gone.yml#verify: no file #{File.join(host_dir, "gone.yml")}"])
    end

    it "reports a bad library file through the importing step" do
      path = library_at("global/steps/broken.yml", "steps: [1, 2]\n")
      importer = imports
      importer.expand({"steps" => {"check" => {"import" => "broken"}}})
      expect(importer.failure).to eq(["step check: import broken (#{path}): a step library needs steps: a mapping of step id to step"])
    end

    it "collects every bad import at once and leaves those steps as written" do
      library_at("global/steps/verify.yml")
      importer = imports
      raw = importer.expand({"steps" => {"a" => {"import" => "nothing"}, "b" => {"import" => "gone.yml#x"}, "c" => {"import" => "verify"}}})

      expect(importer.failure.size).to eq(2)
      expect(raw["steps"]["a"]).to eq({"import" => "nothing"})
      expect(importer.imports.map { |each| each["step"] }).to eq(%w[c])
    end
  end

  describe "R13: refused shapes" do
    it "refuses a library step holding import, after or fan_out" do
      path = library_at("global/steps/bad.yml", "steps:\n  bad:\n    import: verify\n    after: one\n  group:\n    fan_out: {}\n")
      importer = imports
      importer.expand({"steps" => {"check" => {"import" => "bad"}}})

      expect(importer.failure).to eq([
        "step check: import bad (#{path}): step bad: a library step can't import another step (imports don't chain)",
        "step check: import bad (#{path}): step bad: a library step can't take after: (the host places the step)",
        "step check: import bad (#{path}): step group: a library step can't be a fan_out group"
      ])
    end

    it "leaves an import on a fan_out group, and inside its siblings, for the definition to refuse" do
      raw = {"steps" => {"g" => {"import" => "verify", "fan_out" => {"s" => {"import" => "verify"}}}}}
      importer = imports
      expect(importer.expand(raw)).to eq(raw)
      expect(lookups).to eq([])
    end
  end

  describe "R15: the import digest" do
    it "changes with the imported step and not with another step or the description" do
      path = library_at("global/steps/verify.yml")
      digest = -> {
        importer = imports
        importer.expand({"steps" => {"verify" => {"import" => "verify"}}})
        importer.imports.first["sha256"]
      }
      before = digest.call

      File.write(path, verify_library.sub("Expects an earlier step", "Needs a step").sub("Something else.", "Changed."))
      expect(digest.call).to eq(before)

      File.write(path, verify_library.sub("Run the tests.", "Run every test."))
      expect(digest.call).not_to eq(before)
    end

    it "does not change with the order the library's keys are written in" do
      path = library_at("global/steps/verify.yml", "steps:\n  verify:\n    prompt: P\n    produces: [a.md]\n")
      importer = imports
      importer.expand({"steps" => {"verify" => {"import" => "verify"}}})
      before = importer.imports.first["sha256"]

      File.write(path, "steps:\n  verify:\n    produces: [a.md]\n    prompt: P\n")
      again = imports
      again.expand({"steps" => {"verify" => {"import" => "verify"}}})
      expect(again.imports.first["sha256"]).to eq(before)
    end
  end

  describe "R17: the import report" do
    it "has one entry per imported step with the fields show and validate print" do
      path = library_at("global/steps/verify.yml")
      importer = imports
      importer.expand({"steps" => {"verify" => {"import" => "verify", "prompt_file" => "mine.md", "uses" => nil}}})

      expect(importer.imports).to eq([{"step" => "verify", "import" => "verify", "layer" => "global", "path" => path,
                                       "overrides" => %w[prompt_file], "removes" => %w[uses prompt], "shadows" => [],
                                       "reviewers" => [], "reviewer_overrides" => [],
                                       "sha256" => importer.imports.first["sha256"]}])
      expect(importer.imports.first["sha256"]).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "R19: confinement for source and builtin hosts" do
    let(:layer_dir) { File.join(@dir, "builtin") }

    it "accepts a relative reference inside the layer directory" do
      write("builtin/shared/lib.yml", verify_library)
      importer = imports(base_dir: layer_dir, confine_dir: layer_dir)
      importer.expand({"steps" => {"verify" => {"import" => "shared/lib.yml#verify"}}})
      expect(importer.failure).to eq([])
    end

    it "refuses absolute and ~ references" do
      path = write("builtin/lib.yml", verify_library)
      importer = imports(base_dir: layer_dir, confine_dir: layer_dir)
      importer.expand({"steps" => {"a" => {"import" => "#{path}#verify"}, "b" => {"import" => "~/lib.yml#verify"}}})

      expect(importer.failure.size).to eq(2)
      expect(importer.failure).to all(include("this workflow's imports must be paths inside its own directory #{layer_dir}, not absolute or ~ paths"))
    end

    it "refuses a relative reference that leaves the layer directory, through .. or a link" do
      write("outside/lib.yml", verify_library)
      FileUtils.mkdir_p(layer_dir)
      File.symlink(File.join(@dir, "outside/lib.yml"), File.join(layer_dir, "linked.yml"))
      importer = imports(base_dir: layer_dir, confine_dir: layer_dir)
      importer.expand({"steps" => {"a" => {"import" => "../outside/lib.yml#verify"}, "b" => {"import" => "linked.yml#verify"}}})

      expect(importer.failure).to eq([
        "step a: import ../outside/lib.yml#verify (#{File.join(@dir, "outside/lib.yml")}): the file is outside this workflow's directory #{layer_dir} once links are followed",
        "step b: import linked.yml#verify (#{File.join(layer_dir, "linked.yml")}): the file is outside this workflow's directory #{layer_dir} once links are followed"
      ])
    end

    it "is a failure, not an error, when the layer directory is missing" do
      missing = File.join(@dir, "gone")
      write("lib.yml", verify_library)
      importer = imports(base_dir: @dir, confine_dir: missing)
      importer.expand({"steps" => {"verify" => {"import" => "lib.yml#verify"}}})
      expect(importer.failure).to eq(["step verify: import lib.yml#verify (#{File.join(@dir, "lib.yml")}): this workflow's directory #{missing} is missing, so the import can't be checked"])
    end

    it "reads the library from the path it checked, links followed" do
      write("builtin/real/lib.yml", verify_library)
      File.symlink(File.join(layer_dir, "real/lib.yml"), File.join(layer_dir, "link.yml"))
      importer = imports(base_dir: layer_dir, confine_dir: layer_dir)
      importer.expand({"steps" => {"verify" => {"import" => "link.yml#verify"}}})
      expect(importer.failure).to eq([])
      expect(importer.imports.first["path"]).to eq(File.join(layer_dir, "real/lib.yml"))
    end

    it "follows links on the layer directory too" do
      write("real/lib.yml", verify_library)
      File.symlink(File.join(@dir, "real"), File.join(@dir, "keg"))
      keg = File.join(@dir, "keg")
      importer = imports(base_dir: keg, confine_dir: keg)
      importer.expand({"steps" => {"verify" => {"import" => "lib.yml#verify"}}})
      expect(importer.failure).to eq([])
    end
  end

  describe "R21: no lookup" do
    it "notes each bare name as not checked, leaves it as written, and still resolves file references" do
      write("global/lib.yml", verify_library)
      importer = imports(lookup: nil)
      raw = importer.expand({"steps" => {"a" => {"import" => "verify"}, "b" => {"import" => "lib.yml#other"}}})

      expect(importer.failure).to eq([])
      expect(importer.unchecked).to eq(%w[a])
      expect(raw["steps"]["a"]).to eq({"import" => "verify"})
      expect(raw["steps"]["b"]).to eq({"prompt" => "Something else."})
      expect(importer.notes).to eq([{"code" => "import_not_checked", "step" => "a",
                                     "message" => "step a: import verify names a step library that can't be found here, where no workflows are known, so the step is not checked"}])
    end
  end

  describe "R22: the library file's shape" do
    it "accepts schema_version 0.1, legacy 1, and no key" do
      ["schema_version: 0.1\n", "schema_version: \"0.1\"\n", "schema_version: 1\n", ""].each do |head|
        expect(described_class.library_problems("#{head}steps:\n  a:\n    prompt: p\n")).to eq([]), head
      end
    end

    it "refuses another schema_version and an unknown top-level key" do
      expect(described_class.library_problems("schema_version: 2\nid: x\nsteps:\n  a:\n    prompt: p\n")).to eq([
        "a step library has unknown key(s) id (known: schema_version, description, reviewers, steps)",
        "schema_version must be one of 0.1, got 2"
      ])
      expect(described_class.library_problems("schema_version: 0.10\nsteps:\n  a:\n    prompt: p\n")).to eq(["schema_version must be one of 0.1, got 0.10"])
    end

    it "refuses text that is not a YAML mapping of steps" do
      expect(described_class.library_problems("- a\n")).to eq(["the file must be a YAML mapping"])
      expect(described_class.library_problems("steps: [\n")).to match([a_string_starting_with("the file is not valid YAML")])
      expect(described_class.library_problems("steps:\n  Bad: {}\n  b: text\n")).to eq([
        "step \"Bad\": a step id must be #{Workspace::IdPatterns::WORKFLOW_ID_RULE}",
        "step b: must be a mapping of step keys"
      ])
    end

    describe "reviewers:" do
      def reviewed(reviewers, dir: nil)
        described_class.library_problems("reviewers:\n#{reviewers.gsub(/^/, "  ")}steps:\n  a:\n    prompt: p\n", dir: dir)
      end

      it "accepts good reviewers, with placeholders left to the host" do
        write("global/steps/rev.md", "Check {{inputs.anything}}.")
        text = "security:\n  prompt: Look at {{inputs.missing}}\n  scope: \"{{inputs.nope}} only\"\n  include: [x]\nstyle:\n  prompt_file: rev.md\n"
        expect(reviewed(text, dir: File.join(@dir, "global/steps"))).to eq([])
        expect(reviewed(text)).to eq([])
      end

      it "returns the reviewers as written" do
        _steps, reviewers, problems = described_class.read_library("reviewers:\n  sec:\n    prompt: p\nsteps:\n  a:\n    prompt: p\n")
        expect(problems).to eq([])
        expect(reviewers).to eq("sec" => {"prompt" => "p"})
      end

      it "reports each of these as one problem" do
        {
          "sec:\n  prompt: p\n  nope: 1\n" => "reviewer sec has unknown key nope",
          "summary:\n  prompt: p\n" => "reviewer name summary is reserved",
          "Bad-Name:\n  prompt: p\n" => "reviewer name \"Bad-Name\" must be lowercase",
          "sec:\n  prompt: p\n  prompt_file: f.md\n" => "reviewer sec needs exactly one of prompt and prompt_file",
          "sec:\n  title: T\n" => "reviewer sec needs exactly one of prompt and prompt_file",
          "sec:\n  prompt_file: gone.md\n" => "reviewer sec: prompt_file #{File.join(@dir, "global/steps/gone.md")} can't be read"
        }.each do |text, message|
          expect(reviewed(text, dir: File.join(@dir, "global/steps"))).to match([a_string_starting_with(message)]), text
        end
      end

      it "reports a reviewers: that is not a mapping" do
        expect(described_class.library_problems("reviewers: [a]\nsteps:\n  a:\n    prompt: p\n")).to eq(["reviewers must be a mapping of reviewer name to its prompt"])
      end

      it "fails an import through a library with a bad reviewer, naming the library path" do
        path = library_at("global/steps/verify.yml", "reviewers:\n  sec:\n    prompt: p\n    nope: 1\n" + verify_library)
        importer = imports
        importer.expand({"steps" => {"verify" => {"import" => "verify"}}})
        expect(importer.failure).to match([a_string_starting_with("step verify: import verify (#{path}): reviewer sec has unknown key nope")])
      end
    end

    it "refuses an empty steps mapping" do
      expect(described_class.library_problems("steps: {}\n")).to eq(["a step library needs steps: a mapping of step id to step"])
    end

    it "fails an import through a library whose step id is not a workflow id" do
      path = library_at("global/steps/verify.yml", verify_library + "  Not_An-Id!: {prompt: p}\n")
      importer = imports
      importer.expand({"steps" => {"verify" => {"import" => "verify"}}})
      expect(importer.failure).to eq(["step verify: import verify (#{path}): step \"Not_An-Id!\": a step id must be #{Workspace::IdPatterns::WORKFLOW_ID_RULE}"])
    end
  end

  describe "library reviewers an imported step names" do
    let(:reviewed_library) do
      <<~YAML
        reviewers:
          skeptic:
            prompt: Doubt it.
          fan:
            prompt_file: prompts/fan.md
          unused:
            prompt: Never used.
        steps:
          verify:
            prompt: Run the tests.
            review: [skeptic]
          mapped:
            prompt: Mapped.
            review: {from: [skeptic, fan, missing], must: [fan]}
          plain:
            prompt: Plain.
      YAML
    end

    before { write("global/prompts/fan.md", "Like it.") }

    def expand(steps, host_reviewers: nil, library: reviewed_library, file: "lib.yml")
      write("global/#{file}", library)
      importer = imports
      raw = {"steps" => steps}
      raw["reviewers"] = host_reviewers unless host_reviewers.nil?
      [importer, importer.expand(raw)]
    end

    it "adds the reviewers a list review: names and not the unused ones" do
      importer, raw = expand({"v" => {"import" => "lib.yml#verify"}})
      expect(importer.failure).to eq([])
      expect(raw["reviewers"]).to eq("skeptic" => {"prompt" => "Doubt it."})
      expect(importer.imports[0]).to include("reviewers" => ["skeptic"], "reviewer_overrides" => [])
    end

    it "reads a mapping's from, ignores must, and leaves an unknown name for later checks" do
      importer, raw = expand({"m" => {"import" => "lib.yml#mapped"}})
      expect(importer.failure).to eq([])
      expect(raw["reviewers"].keys).to eq(%w[skeptic fan])
      expect(importer.imports[0]["reviewers"]).to eq(%w[skeptic fan])
    end

    it "anchors a relative prompt_file against the library's directory" do
      _importer, raw = expand({"m" => {"import" => "lib.yml#mapped"}})
      expect(raw["reviewers"]["fan"]).to eq("prompt_file" => File.join(host_dir, "prompts/fan.md"))
    end

    it "gives an import with no review: empty lists and adds no reviewers key" do
      importer, raw = expand({"p" => {"import" => "lib.yml#plain"}})
      expect(raw).not_to have_key("reviewers")
      expect(importer.imports[0]).to include("reviewers" => [], "reviewer_overrides" => [])
    end

    it "keeps the host's own reviewer, records the override and adds the rest" do
      importer, raw = expand({"m" => {"import" => "lib.yml#mapped"}}, host_reviewers: {"skeptic" => {"prompt" => "Mine."}})
      expect(raw["reviewers"]["skeptic"]).to eq("prompt" => "Mine.")
      expect(raw["reviewers"].keys).to eq(%w[skeptic fan])
      expect(importer.imports[0]).to include("reviewers" => ["fan"], "reviewer_overrides" => ["skeptic"])
    end

    it "takes the names from the host's review: override" do
      importer, raw = expand({"m" => {"import" => "lib.yml#mapped", "review" => ["fan"]}})
      expect(raw["reviewers"].keys).to eq(%w[fan])
      expect(importer.imports[0]["reviewers"]).to eq(["fan"])
    end

    it "brings reviewers for a replace: step too" do
      write("global/lib.yml", reviewed_library)
      importer = imports
      raw = importer.expand({"replace" => {"v" => {"import" => "lib.yml#verify"}}})
      expect(raw["reviewers"].keys).to eq(%w[skeptic])
      expect(importer.imports[0]["reviewers"]).to eq(["skeptic"])
    end

    it "leaves a host reviewers: that is not a mapping alone" do
      importer, raw = expand({"v" => {"import" => "lib.yml#verify"}}, host_reviewers: ["skeptic"])
      expect(raw["reviewers"]).to eq(["skeptic"])
      expect(importer.imports[0]["reviewers"]).to eq([])
    end

    it "refuses the same name from two files with different content, naming both paths" do
      first = write("global/one.yml", reviewed_library)
      second = write("global/two.yml", reviewed_library.sub("Doubt it.", "Doubt it harder."))
      importer = imports
      importer.expand({"steps" => {"a" => {"import" => "one.yml#verify"}, "b" => {"import" => "two.yml#verify"}}})
      expect(importer.failure).to eq(["step b: import two.yml#verify (#{second}): reviewer skeptic is also brought in by #{first} with different content"])
    end

    it "accepts the same name with equal content from two files" do
      write("global/one.yml", reviewed_library)
      write("global/two.yml", reviewed_library)
      importer = imports
      raw = importer.expand({"steps" => {"a" => {"import" => "one.yml#verify"}, "b" => {"import" => "two.yml#verify"}}})
      expect(importer.failure).to eq([])
      expect(raw["reviewers"].keys).to eq(%w[skeptic])
    end

    describe "prompt_file in a confined host" do
      let(:layer_dir) { File.join(@dir, "builtin") }

      def confined(prompt_file)
        write("builtin/lib.yml", "reviewers:\n  fan:\n    prompt_file: #{prompt_file}\nsteps:\n  verify:\n    prompt: P\n    review: [fan]\n")
        importer = imports(base_dir: layer_dir, confine_dir: layer_dir)
        raw = importer.expand({"steps" => {"v" => {"import" => "lib.yml#verify"}}})
        [importer, raw]
      end

      it "accepts a file inside the directory, anchored by its real path" do
        write("builtin/prompts/fan.md", "Like it.")
        importer, raw = confined("prompts/fan.md")
        expect(importer.failure).to eq([])
        expect(raw["reviewers"]["fan"]).to eq("prompt_file" => File.realpath(File.join(layer_dir, "prompts/fan.md")))
      end

      it "refuses an absolute path" do
        path = write("builtin/prompts/fan.md", "Like it.")
        importer, = confined(path)
        expect(importer.failure).to eq(["step v: import lib.yml#verify (#{File.join(layer_dir, "lib.yml")}): reviewer fan prompt_file #{path}: this workflow's imports must stay inside its own directory #{layer_dir}, not absolute or ~ paths"])
      end

      it "refuses a ~ path" do
        write("home/fan.md", "Like it.")
        old_home = ENV["HOME"]
        ENV["HOME"] = File.join(@dir, "home")
        importer, = begin
          confined("~/fan.md")
        ensure
          ENV["HOME"] = old_home
        end
        expect(importer.failure).to match([a_string_including("reviewer fan prompt_file ~/fan.md: this workflow's imports must stay inside")])
      end

      it "refuses a link that leads out of the directory" do
        write("outside/fan.md", "Like it.")
        FileUtils.mkdir_p(File.join(layer_dir, "prompts"))
        File.symlink(File.join(@dir, "outside/fan.md"), File.join(layer_dir, "prompts/fan.md"))
        importer, = confined("prompts/fan.md")
        expect(importer.failure).to match([a_string_including("reviewer fan prompt_file prompts/fan.md: the file is outside this workflow's directory #{layer_dir} once links are followed")])
      end

      it "leaves an unconfined host as before" do
        path = write("outside/fan.md", "Like it.")
        write("global/lib.yml", "reviewers:\n  fan:\n    prompt_file: #{path}\nsteps:\n  verify:\n    prompt: P\n    review: [fan]\n")
        importer = imports
        raw = importer.expand({"steps" => {"v" => {"import" => "lib.yml#verify"}}})
        expect(importer.failure).to eq([])
        expect(raw["reviewers"]["fan"]).to eq("prompt_file" => path)
      end
    end
  end
end
