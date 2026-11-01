require "spec_helper"
require "tmpdir"

RSpec.describe "workflow extends" do
  around do |example|
    Dir.mktmpdir("wf-extends") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:global_dir) { File.join(@dir, "global") }
  let(:builtin_dir) { File.join(@dir, "builtin") }
  let(:config) { instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir, workspace_projects_dir: File.join(global_dir, "..", "no-projects")) }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }

  let(:parent_yaml) {
    <<~YAML
      title: Parent
      inputs:
        task:
          required: true
      max_attempts: 4
      steps:
        one:
          prompt: First {{inputs.task}}
          produces: [one.md]
        two:
          prompt: Second
          produces: [two.md]
          gate: approve
        three:
          prompt: Third
          produces: [three.md]
          on_fail:
            goto: one
            max: 2
    YAML
  }

  def write(dir, id, yaml)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), yaml)
  end

  def problems_of(id)
    catalog.find(id)
    nil
  rescue Workspace::Error => e
    expect(e.code).to eq("invalid_workflow")
    e.details["problems"]
  end

  before { write(builtin_dir, "base", parent_yaml) }

  it "lays the child over the parent: its keys replace, its inputs add, replace swaps a step in place, steps adds after a step" do
    write(global_dir, "child", <<~YAML)
      extends: base
      title: Child
      inputs:
        extra: {description: more}
      replace:
        two:
          prompt: Second, again
          produces: [two.md]
      steps:
        mid:
          after: one
          prompt: Middle
          produces: [mid.md]
        last:
          prompt: Last
          produces: [last.md]
    YAML

    data = catalog.find("child").to_h

    expect(data["id"]).to eq("child")
    expect(data["title"]).to eq("Child")
    expect(data["max_attempts"]).to eq(4)
    expect(data["inputs"].keys).to eq(%w[task extra])
    expect(data["steps"].map { |s| s["id"] }).to eq(%w[one mid two three last])
    expect(data["steps"].find { |s| s["id"] == "two" }).to include("prompt" => "Second, again", "gate" => nil)
    expect(data["steps"].find { |s| s["id"] == "three" }["on_fail"]).to include("goto" => "one")
  end

  it "keeps a replaced step where it was, ahead of the steps after it" do
    write(global_dir, "kid", "extends: base\nreplace:\n  one: {prompt: Uno, produces: [uno.md]}\n  two: {prompt: Dos, produces: [dos.md]}\n")

    steps = catalog.find("kid").steps

    expect(steps.map { |s| [s["id"], s["prompt"]] }).to eq([["one", "Uno"], ["two", "Dos"], ["three", "Third"]])
  end

  it "keeps a replaced middle step in the middle, with the steps before and after it untouched" do
    write(global_dir, "kid", "extends: base\nreplace:\n  two: {prompt: Dos, produces: [dos.md]}\n")

    steps = catalog.find("kid").steps

    expect(steps.map { |s| [s["id"], s["prompt"]] }).to eq([["one", "First {{inputs.task}}"], ["two", "Dos"], ["three", "Third"]])
  end

  it "replaces step b of a, b, c in place" do
    write(global_dir, "abc", "steps:\n  a: {prompt: A, produces: [a.md]}\n  b: {prompt: B, produces: [b.md]}\n  c: {prompt: C, produces: [c.md]}\n")
    write(global_dir, "kid", "extends: abc\nreplace:\n  b: {prompt: B2, produces: [b2.md]}\n")

    steps = catalog.find("kid").steps

    expect(steps.map { |step| step["id"] }).to eq(%w[a b c])
    expect(steps.map { |step| step["prompt"] }).to eq(%w[A B2 C])
  end

  it "keeps the parent's inputs when the child's inputs: is empty, and has none when neither has any" do
    write(global_dir, "kid", "extends: base\ninputs:\n")
    write(global_dir, "bare", "steps:\n  s: {prompt: P, produces: [p.md]}\n")
    write(global_dir, "bare_kid", "extends: bare\ninputs:\n")

    expect(catalog.find("kid").to_h["inputs"].keys).to eq(%w[task])
    expect(catalog.find("bare_kid").to_h["inputs"]).to eq({})
  end

  it "keeps several steps added after the same step in the order written" do
    write(global_dir, "child", <<~YAML)
      extends: base
      steps:
        a: {after: one, prompt: A, produces: [a.md]}
        b: {after: one, prompt: B, produces: [b.md]}
    YAML

    expect(catalog.find("child").to_h["steps"].map { |s| s["id"] }).to eq(%w[one a b two three])
  end

  it "follows a chain of parents and reports them nearest first" do
    write(global_dir, "mid", "extends: base\ntitle: Mid\n")
    write(global_dir, "top", "extends: mid\nreplace:\n  one: {prompt: Uno, produces: [uno.md]}\n")

    definition = catalog.find("top")

    expect(definition.parents.map { |p| p["id"] }).to eq(%w[mid base])
    expect(definition.to_h).to include("title" => "Mid")
    expect(definition.steps.first["prompt"]).to eq("Uno")
  end

  it "reads a parent's prompt_file beside the parent" do
    write(builtin_dir, "filed", "steps:\n  one:\n    prompt_file: one.txt\n    produces: [o.md]\n")
    File.write(File.join(builtin_dir, "one.txt"), "From the parent's directory")
    write(global_dir, "child", "extends: filed\ntitle: C\n")

    expect(catalog.find("child").steps.first["prompt"]).to eq("From the parent's directory")
  end

  describe "refusals under invalid_workflow, all listed" do
    it "a missing parent" do
      write(global_dir, "child", "extends: nothing\n")

      expect(problems_of("child")).to include(a_string_matching(/extends nothing: no workflow has that id/))
    end

    it "a cycle" do
      write(global_dir, "a", "extends: b\n")
      write(global_dir, "b", "extends: a\n")

      expect(problems_of("a")).to contain_exactly(a_string_matching(/\Aextends b \(.*b\.yml\): extends makes a cycle: a -> b -> a\z/))
    end

    it "a workflow that extends its own id" do
      write(global_dir, "loop", "extends: loop\n")

      expect(problems_of("loop")).to eq(["extends loop: no other workflow has that id, so there is nothing for it to extend"])
    end

    it "a chain longer than the limit" do
      write(global_dir, "c0", parent_yaml)
      (1..6).each { |n| write(global_dir, "c#{n}", "extends: c#{n - 1}\n") }

      expect(catalog.find("c4").parents.size).to eq(4)
      expect(problems_of("c5").join).to match(/more than 4 workflows up/)
    end

    it "a replace naming an unknown step, and an added step that already exists, together" do
      write(global_dir, "child", <<~YAML)
        extends: base
        replace:
          nope: {prompt: X, produces: [x.md]}
        steps:
          one: {prompt: again, produces: [o.md]}
          late: {after: ghost, prompt: L, produces: [l.md]}
      YAML

      expect(problems_of("child")).to include(
        a_string_matching(/replace names step "nope", which base \(#{Regexp.escape(File.join(builtin_dir, "base.yml"))}\) doesn't have \(its steps: one, two, three\)/),
        a_string_matching(/step one is already a step of base \(.*base\.yml\): put it under replace:/),
        a_string_matching(/step late: after names step "ghost"/)
      )
    end

    it "replace or after without extends, and a bad extends value" do
      write(global_dir, "r", "replace: {a: {prompt: x}}\nsteps:\n  s: {prompt: p, produces: [p.md], after: q}\n")
      write(global_dir, "e", "extends: 7\n")

      expect(problems_of("r")).to include("replace only means something with extends:", a_string_matching(/after: only places a step added/))
      expect(problems_of("e")).to include(a_string_matching(/extends must be the id of a workflow/))
      write(global_dir, "s", "extends: \"Not An Id\"\n")
      expect(problems_of("s")).to match([a_string_matching(/\Aextends must be the id of a workflow .*, got "Not An Id"\z/)])
    end

    it "a replacement with after:, and a replaced step that is itself wrong" do
      write(global_dir, "child", "extends: base\nreplace:\n  two: {after: one, prompt: X, produces: [x.md]}\n  three: {prompt: Y, on_fail: {goto: later}}\n")

      expect(problems_of("child")).to include(a_string_matching(/replace step two: after: is for added steps/), a_string_matching(/step three: on_fail goto/))
    end
  end

  it "has no lookup to resolve a parent when none is given" do
    expect { Workspace::WorkflowDefinition.parse("extends: base\n", id: "x", source: "file", path: nil) }
      .to raise_error(Workspace::Error) { |e| expect(e.details["problems"].first).to match(/can't be checked here/) }
  end

  describe "a parent that is itself wrong" do
    it "is reported under the parent's id and path, alone, with no follow-on lines about the child" do
      write(global_dir, "bad", "colour: red\nsteps:\n  one: {prompt: P, produces: [o.md]}\n")
      write(global_dir, "kid", "extends: bad\nsteps:\n  x: {after: one, prompt: X, produces: [x.md]}\nreplace:\n  ghost: {prompt: G}\n")

      expect(problems_of("kid")).to eq(["extends bad (#{File.join(global_dir, "bad.yml")}): the workflow has unknown key colour (known: #{Workspace::WorkflowDefinition::TOP_KEYS.join(", ")})"])
    end

    it "carries the extends prefix for a parent that is not YAML" do
      write(global_dir, "bad", "steps: [unclosed\n")
      write(global_dir, "kid", "extends: bad\n")

      expect(problems_of("kid").first).to start_with("extends bad (#{File.join(global_dir, "bad.yml")}): the file is not valid YAML")
    end

    it "names the user's shadowing file, not the preset, when that file is broken" do
      write(global_dir, "base", "colour: red\n")
      write(global_dir, "kid", "extends: base\n")

      expect(problems_of("kid").first).to start_with("extends base (#{File.join(global_dir, "base.yml")}):")
    end
  end

  describe "a file that extends the preset it shadows" do
    it "reads the preset, not itself, and a real cycle is still refused" do
      write(global_dir, "base", "extends: base\ntitle: Mine\n")

      definition = catalog.find("base")

      expect(definition.to_h["title"]).to eq("Mine")
      expect(definition.steps.map { |s| s["id"] }).to eq(%w[one two three])
      expect(definition.parents).to contain_exactly(include("id" => "base", "source" => "builtin"))
    end

    it "lists, for a child of a shadowed preset, the user's file as its parent" do
      write(global_dir, "base", "title: Shadow\nsteps:\n  only: {prompt: P, produces: [p.md]}\n")
      write(global_dir, "kid", "extends: base\n")

      parent = catalog.find("kid").parents.first

      expect(parent).to include("source" => "global", "path" => File.join(global_dir, "base.yml"))
      expect(catalog.find("kid").steps.map { |s| s["id"] }).to eq(%w[only])
    end
  end

  describe "a child's own mistakes beside a good parent" do
    it "reports bad inputs as a definition without extends would" do
      write(global_dir, "kid", "extends: base\ninputs: [nope]\n")

      expect(problems_of("kid")).to include("inputs must be a mapping of input name to its description")
    end
  end

  describe "the catalog lookup" do
    it "can skip the sources up to the asker's own, so a shadow extends what it shadows" do
      write(global_dir, "base", "title: Mine\n")

      expect(catalog.parent("base")).to include("source" => "global")
      expect(catalog.parent("base", below: "global")).to include("source" => "builtin")
      expect(catalog.parent("base", below: "file")).to include("source" => "builtin")
      expect(catalog.parent("base", below: "builtin")).to be_nil
    end

    it "names the definitions that extend an id, through others too, broken ones included, and never the id itself" do
      write(global_dir, "kid", "extends: base\n")
      write(global_dir, "grandkid", "extends: kid\n")
      write(global_dir, "broken_kid", "extends: base\ncolour: red\n")
      write(global_dir, "other", "title: no\nsteps: {}\n")
      write(global_dir, "selfie", "extends: selfie\n")
      write(global_dir, "unparseable", "extends: base\nsteps: [\n")
      write(global_dir, "a_list", "- extends: base\n")
      write(global_dir, "not_text", "extends: base\n\xFF\xFE: [\n".b)
      FileUtils.mkdir_p(File.join(global_dir, "adir.yml"))
      write(global_dir, "unreadable", "extends: base\n")
      File.chmod(0o000, File.join(global_dir, "unreadable.yml"))

      expect(catalog.extended_by("base")).to eq(%w[broken_kid grandkid kid])
      expect(catalog.extended_by("kid")).to eq(%w[grandkid])
      expect(catalog.extended_by("selfie")).to eq([])
    ensure
      File.chmod(0o644, File.join(global_dir, "unreadable.yml")) if File.exist?(File.join(global_dir, "unreadable.yml"))
    end

    it "ignores an extends: that is not a string, and ends on a cycle that does not include the id" do
      write(global_dir, "listy", "extends: [base]\n")
      write(global_dir, "numbery", "extends: 7\n")
      write(global_dir, "ring_a", "extends: ring_b\n")
      write(global_dir, "ring_b", "extends: ring_a\n")

      expect(catalog.extended_by("base")).to eq([])
      expect(catalog.extended_by("ring_a")).to eq(%w[ring_b])
    end

    it "does not look a parent up by an id that climbs out of the directory" do
      File.write(File.join(@dir, "outside.yml"), parent_yaml)

      expect(catalog.parent("../outside")).to be_nil
      expect(catalog.parent("../builtin/base")).to be_nil
      expect(catalog.parent("a/b")).to be_nil
    end

    it "answers a parent's text, path and source, and nil for no file" do
      expect(catalog.parent("base")).to include("source" => "builtin", "path" => File.join(builtin_dir, "base.yml"), "text" => parent_yaml)
      expect(catalog.parent("nothing")).to be_nil
      expect(catalog.parent("../etc")).to be_nil
    end
  end

  describe "the digest" do
    it "changes when only the child's own text changes" do
      write(global_dir, "kid", "extends: base\ntitle: One\n")
      one = catalog.find("kid")
      write(global_dir, "kid", "extends: base\ntitle: Two\n")
      two = catalog.find("kid")

      expect(two.resolved_sha256).not_to eq(one.resolved_sha256)
    end

    it "is the file's own when nothing is extended" do
      definition = catalog.find("base")

      expect(definition.resolved_sha256).to eq(definition.sha256)
    end

    it "covers each parent's text, so a parent edit changes the child's digest but not its own" do
      write(global_dir, "child", "extends: base\ntitle: Kid\n")
      before = catalog.find("child")
      write(builtin_dir, "base", parent_yaml.sub("Parent", "Parent edited"))
      after = catalog.find("child")

      expect(after.sha256).to eq(before.sha256)
      expect(after.resolved_sha256).not_to eq(before.resolved_sha256)
    end
  end

  it "stores the resolved definition in a run: a later parent edit leaves a stored run's copy alone" do
    write(global_dir, "child", "extends: base\n")
    stored = Marshal.load(Marshal.dump(catalog.find("child").to_h))
    write(builtin_dir, "base", parent_yaml.sub("Second", "Changed"))

    expect(stored["steps"][1]["prompt"]).to eq("Second")
    expect(catalog.find("child").to_h["steps"][1]["prompt"]).to eq("Changed")
  end

  describe "the rpiv-auto-approve preset" do
    it "resolves to exactly what the full file did before it extended rpiv" do
      presets = File.expand_path("../../lib/workflows", __dir__)
      real = Workspace::WorkflowCatalog.new(config: instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: presets))
      before_text = File.read(File.expand_path("../fixtures/workflows/rpiv-auto-approve.before-extends.yml", __dir__))

      expected = Workspace::WorkflowDefinition.parse(before_text, id: "rpiv-auto-approve", source: "builtin", path: nil).to_h
      actual = real.find("rpiv-auto-approve").to_h

      expect(actual).to eq(expected)
      expect(actual["steps"].map { |s| s["id"] }).to eq(%w[research plan plan_review implement verify])
    end
  end
end
