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

  it "does not inherit the parent's version, and keeps the child's own" do
    write(builtin_dir, "base", "version: 3\n#{parent_yaml}")
    write(global_dir, "plain", "extends: base\n")
    write(global_dir, "own", "extends: base\nversion: 9\n")

    expect(catalog.find("plain").to_h).not_to have_key("version")
    expect(catalog.find("own").to_h["version"]).to eq(9)
  end

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

  it "keeps the stored argv of an exec proof in a replaced step" do
    write(global_dir, "kid", "extends: base\nreplace:\n  one:\n    prompt: Uno\n    produces: [uno.md]\n    require:\n      - exec: \"script/check -- {{changed.files}}\"\n        timeout: 90s\n")

    one = catalog.find("kid").steps.find { |s| s["id"] == "one" }

    expect(one["require"]).to eq([{"exec" => ["script/check", "--", "{{changed.files}}"], "timeout" => 90}])
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

  describe "permissions" do
    it "joins the parent's rules and the child's, so a child only adds" do
      write(global_dir, "base", "permissions:\n  - {tool: Bash, pattern: 'git push*', action: deny}\nsteps:\n  one: {prompt: P, produces: [o.md]}\n")
      write(global_dir, "kid", "extends: base\npermissions:\n  - {tool: Write, action: ask}\n")

      expect(catalog.find("kid").to_h["permissions"]).to eq([
        {"tool" => "Bash", "pattern" => "git push*", "action" => "deny"},
        {"tool" => "Write", "action" => "ask"}
      ])
    end

    it "keeps the parent's rules when the child sets none" do
      write(global_dir, "base", "permissions:\n  - {tool: Bash, action: deny}\nsteps:\n  one: {prompt: P, produces: [o.md]}\n")
      write(global_dir, "kid", "extends: base\n")

      expect(catalog.find("kid").to_h["permissions"]).to eq([{"tool" => "Bash", "action" => "deny"}])
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

  describe "the rpiv-auto-approve-v2 preset" do
    let(:presets) { File.join(PROJECT_ROOT, "lib", "workflows") }
    let(:real) { Workspace::WorkflowCatalog.new(config: instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: presets)) }
    let(:v2) { real.find("rpiv-auto-approve-v2") }
    let(:rpiv) { real.find("rpiv") }

    it "is rpiv with its plan step replaced by a reviewed one, and no steps added" do
      steps = v2.to_h["steps"].to_h { |step| [step["id"], step] }
      base = rpiv.to_h["steps"].to_h { |step| [step["id"], step] }

      expect(v2.to_h["steps"].map { |s| s["id"] }).to eq(%w[research plan implement verify])
      %w[research implement verify].each { |id| expect(steps[id]).to eq(base[id]) }
      expect(steps["plan"]["gate"]).to be_nil
      expect(base["plan"]["gate"]).to eq("approve")
      expect(steps["plan"]["max_attempts"]).to eq(8)
      expect(steps["plan"]["review"]).to include("from" => %w[supportive skeptical implementer], "need" => 2, "must" => ["skeptical"], "max_rounds" => 6, "timeout" => 1800.0, "context" => "fresh")
      expect(steps["plan"]["prompt"]).not_to include("plan-approval.md")
    end

    it "carries its own caps, budget and reviewers over rpiv's inputs" do
      data = v2.to_h

      expect(data).to include("max_attempts" => 21, "timeout" => 28_800.0, "timeout_action" => "hold", "budget" => {"action" => "stop", "tokens" => 40_000_000})
      expect(data["inputs"]).to eq(rpiv.to_h["inputs"])
      expect(data["reviewers"].keys).to eq(%w[supportive skeptical implementer])
      expect(v2.warnings).to eq([])
    end

    # v2's shape before its plan was guard: config: a child that replaces the parent's plan with an unchanged one, which
    # the parent's committing implement loops back into, is warned of on the resolved steps.
    it "warns of a replaced step that a parent step's failure loops back into after a commit" do
      write(builtin_dir, "looping", "title: Looping\nsteps:\n  plan:\n    prompt: Plan\n    produces: [plan.md]\n    guard: config\n" \
        "  implement:\n    prompt: Build\n    require:\n      - commits: 1\n")
      write(global_dir, "child", "extends: looping\nreplace:\n  plan:\n    prompt: Plan again\n    produces: [plan.md]\n    guard: unchanged\n")

      expect(catalog.find("looping").warnings).to eq([])
      expect(catalog.find("child").warnings.map { |w| [w["code"], w["step"]] }).to eq([["guard_unchanged_loop_back", "plan"]])
    end

    it "resolves its sha over rpiv's text, and leaves the old preset's pin alone" do
      expect(v2.parents.map { |p| p["id"] }).to eq(["rpiv"])
      expect(v2.resolved_sha256).not_to eq(v2.sha256)
      expect(real.find("rpiv-auto-approve").parents).to eq([])
    end
  end

  describe "reviewers" do
    let(:reviewed_parent) {
      <<~YAML
        reviewers:
          skeptic:
            prompt: Doubt it
          fan:
            prompt_file: fan.txt
        steps:
          one:
            prompt: First
            produces: [one.md]
            review: [skeptic]
          two:
            prompt: Second
            produces: [two.md]
      YAML
    }

    before do
      write(builtin_dir, "reviewed", reviewed_parent)
      File.write(File.join(builtin_dir, "fan.txt"), "Like it, from the parent's directory")
    end

    it "lets a child step name a parent's reviewer" do
      write(global_dir, "child", "extends: reviewed\nreplace:\n  two:\n    prompt: Second\n    produces: [two.md]\n    review: [fan]\n")

      definition = catalog.find("child")

      expect(definition.steps.last["review"]["from"]).to eq(["fan"])
      expect(definition.warnings.map { |w| w["code"] }).not_to include("review_dropped")
    end

    it "refuses a child step that names a reviewer neither file has" do
      write(global_dir, "child", "extends: reviewed\nreplace:\n  two:\n    prompt: Second\n    produces: [two.md]\n    review: [nobody]\n")

      expect(problems_of("child")).to include(a_string_matching(/step two: review names unknown reviewer nobody \(known: skeptic, fan\)/))
    end

    it "merges reviewers by name, the child's entry replacing the parent's whole" do
      write(global_dir, "child", "extends: reviewed\nreviewers:\n  skeptic:\n    prompt: Doubt harder\n  extra:\n    prompt: More\n")

      reviewers = catalog.find("child").to_h["reviewers"]

      expect(reviewers.keys).to eq(%w[skeptic fan extra])
      expect(reviewers["skeptic"]["prompt"]).to eq("Doubt harder")
    end

    it "reads a parent's reviewer prompt_file beside the parent" do
      write(global_dir, "child", "extends: reviewed\ntitle: C\nreviewers:\n  other:\n    prompt: Hi\n")

      expect(catalog.find("child").to_h["reviewers"]["fan"]["prompt"]).to eq("Like it, from the parent's directory")
    end

    it "warns review_dropped once when a replacing step leaves out the parent step's review" do
      write(global_dir, "child", "extends: reviewed\nreplace:\n  one:\n    prompt: First again\n    produces: [one.md]\n  two:\n    prompt: Second\n    produces: [two.md]\n")

      dropped = catalog.find("child").warnings.select { |w| w["code"] == "review_dropped" }

      expect(dropped).to match([include("step" => "one", "message" => /replace step one.*reviewed.*Repeat review:/)])
    end

    it "is quiet when the replacing step repeats review:" do
      write(global_dir, "child", "extends: reviewed\nreplace:\n  one:\n    prompt: First again\n    produces: [one.md]\n    review: [skeptic]\n")

      expect(catalog.find("child").warnings.map { |w| w["code"] }).not_to include("review_dropped")
    end

    it "anchors a reviewer prompt_file beside the file that wrote it, through three levels" do
      FileUtils.mkdir_p(File.join(builtin_dir, "deep"))
      write(File.join(builtin_dir, "deep"), "grand", "reviewers:\n  fan:\n    prompt_file: fan.txt\nsteps:\n  one:\n    prompt: P\n    produces: [o.md]\n")
      File.write(File.join(builtin_dir, "deep", "fan.txt"), "from deep")
      write(global_dir, "mid", "extends: grand\ntitle: Mid\n")
      write(global_dir, "top", "extends: mid\ntitle: Top\n")
      config_with_deep = instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: File.join(builtin_dir, "deep"), workspace_projects_dir: File.join(global_dir, "..", "no-projects"))

      top = Workspace::WorkflowCatalog.new(config: config_with_deep).find("top")

      expect(top.to_h["reviewers"]["fan"]["prompt"]).to eq("from deep")
    end

    it "lets a child override a parent's reviewer with its own prompt_file, read beside the child" do
      FileUtils.mkdir_p(global_dir)
      File.write(File.join(global_dir, "mine.txt"), "child's own")
      write(global_dir, "child", "extends: reviewed\nreviewers:\n  fan:\n    prompt_file: mine.txt\n")

      expect(catalog.find("child").to_h["reviewers"]["fan"]["prompt"]).to eq("child's own")
    end
  end

  describe "origins" do
    it "is empty for a definition that extends nothing" do
      expect(catalog.find("base").origins).to eq({})
    end

    it "names the parent for inherited steps and own for added or replaced ones" do
      write(global_dir, "child", "extends: base\nreplace:\n  two:\n    prompt: New two\n    produces: [two.md]\nsteps:\n  four:\n    after: three\n    prompt: Fourth\n    produces: [four.md]\n")

      definition = catalog.find("child")

      expect(definition.origins).to eq("one" => "base", "two" => "own", "three" => "base", "four" => "own")
      expect(definition.to_h["steps"].map { |step| step["id"] }).to eq(%w[one two three four])
    end

    it "gives a step a parent inherited itself the parent's own origin, down a chain" do
      write(global_dir, "mid", "extends: base\nsteps:\n  mid-step:\n    after: one\n    prompt: Mid\n    produces: [m.md]\n")
      write(global_dir, "top", "extends: mid\nreplace:\n  three:\n    prompt: Top three\n    produces: [three.md]\nsteps:\n  top-step:\n    prompt: Top\n    produces: [t.md]\n")

      expect(catalog.find("top").origins).to eq("one" => "base", "mid-step" => "mid", "two" => "base", "three" => "own", "top-step" => "own")
    end

    it "tags only inherited steps in the drawn graph" do
      write(global_dir, "child", "extends: base\nsteps:\n  four:\n    prompt: Fourth\n    produces: [four.md]\n")
      definition = catalog.find("child")
      model = Workspace::WorkflowGraph.build(definition.to_h, origins: definition.origins).to_h
      titles = model["nodes"].select { |node| node["kind"] == "step" }.to_h { |node| [node["id"], Workspace::WorkflowGraphText.node_title(node)] }

      expect(titles["one"]).to end_with("(from base)")
      expect(titles["four"]).not_to include("from")
    end
  end

  describe "fan_out groups" do
    let(:group) { "    fan_out:\n      lint:\n        prompt: L\n        produces: [lint.md]\n" }

    it "refuses extending a parent that has a group, naming the parent and the group" do
      write(builtin_dir, "grouped", "steps:\n  one:\n    prompt: P\n    produces: [one.md]\n  checks:\n#{group}")
      write(global_dir, "child", "extends: grouped\n")

      expect(catalog.find("grouped").to_h["groups"].keys).to eq(["checks"])
      expect(problems_of("child")).to eq(["extends grouped: workflow grouped has the fan_out group checks, and a workflow with a fan_out group can't be extended yet"])
    end

    it "refuses a child that declares a group while it extends a parent without one, added or as a replacement" do
      write(global_dir, "added", "extends: base\nsteps:\n  checks:\n#{group}")
      write(global_dir, "swapped", "extends: base\nreplace:\n  two:\n#{group}")

      expect(problems_of("added")).to eq(["step checks is a fan_out group, which workflow added can't declare while it has extends: yet"])
      expect(problems_of("swapped")).to eq(["step two is a fan_out group, which workflow swapped can't declare while it has extends: yet"])
    end
  end
end
