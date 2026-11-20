require "spec_helper"

RSpec.describe Workspace::WorkflowSimScript do
  let(:definition) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "demo", source: "file", path: nil).to_h
      schema_version: 1
      id: demo
      title: Demo
      inputs:
        task: {required: true}
      reviewers:
        skeptic: {prompt: Find what is wrong.}
        builder: {prompt: Check it can be built.}
      steps:
        build:
          prompt: build
          produces: [build.md, notes.md]
          require:
            - commits: 1
        test:
          prompt: test
          produces: [test.md]
          status: {run: "true"}
          gate: approve
        design:
          prompt: design
          produces: [design.md]
          review:
            from: [skeptic, builder]
    YAML
  end

  def parse(text)
    described_class.parse(text, definition: definition, source: "s.yml")
  end

  def problems(text)
    parse(text)
    raise "no error"
  rescue Workspace::Error => e
    expect(e.code).to eq("invalid_script")
    e.details["problems"]
  end

  it "reads inputs and the attempts of a step, and answers an empty map past the list" do
    script = parse("inputs: {task: x}\nsteps:\n  test:\n    - {check: fail, tokens: 5}\n    -\n")

    expect(script.inputs).to eq("task" => "x")
    expect(script.attempt("test", 1)).to eq("check" => "fail", "tokens" => 5)
    expect(script.attempt("test", 2)).to eq({})
    expect(script.attempt("test", 3)).to eq({})
    expect(script.attempt("build", 1)).to eq({})
  end

  it "accepts every key with a valid value" do
    expect {
      parse(<<~YAML)
        steps:
          build:
            - {writes: [build.md], report: fail, summary: s, code: oops, require: {commits: fail}}
          test:
            - {check: timeout, log: l, gate: reject, note: n, tokens: 0}
      YAML
    }.not_to raise_error
  end

  it "lists every problem, naming the step and attempt" do
    list = problems(<<~YAML)
      wat: 1
      inputs: {nope: x, task: [1]}
      steps:
        ghost: []
        build:
          - {writes: [other.md], report: maybe, code: Bad, require: {tests: pass, commits: later}, check: pass, gate: approve, note: n, tokens: -1, extra: 1}
          - nope
        test:
          - {check: sometimes, summary: 3}
    YAML

    expect(list).to include(
      a_string_matching(/unknown key "wat"/),
      a_string_matching(/inputs\.nope: the workflow has no such input/),
      a_string_matching(/inputs\.task must be a string or an integer/),
      a_string_matching(/steps\.ghost: .*steps: build, test/),
      a_string_matching(/steps\.build attempt 1: writes "other.md"/),
      a_string_matching(/attempt 1: report must be one of pass, fail/),
      a_string_matching(/attempt 1: code must be lowercase/),
      a_string_matching(/attempt 1: require "tests": the step has no such proof/),
      a_string_matching(/attempt 1: require commits must be one of pass, fail/),
      a_string_matching(/attempt 1: check is set, and the step has no status: check/),
      a_string_matching(/attempt 1: gate is set, and the step has no gate:/),
      a_string_matching(/attempt 1: note is for a gate/),
      a_string_matching(/attempt 1: tokens must be a whole number/),
      a_string_matching(/attempt 1: unknown key "extra"/),
      a_string_matching(/steps\.build attempt 2 must be a mapping/),
      a_string_matching(/steps\.test attempt 1: check must be one of pass, fail, timeout, error/),
      a_string_matching(/steps\.test attempt 1: summary must be a string/)
    )
  end

  it "refuses text that is not YAML, not a mapping, too long, not UTF-8 or aliased" do
    expect(problems("a: [")).to match([a_string_matching(/not valid YAML/)])
    expect(problems("- 1\n")).to match([a_string_matching(/must be a YAML mapping/)])
    expect(problems("")).to match([a_string_matching(/must be a YAML mapping/)])
    expect(problems("steps: {}\n" + "#" * described_class::MAX_BYTES)).to match([a_string_matching(/limit is/)])
    expect(problems("steps: {}\n\xFF".b.force_encoding(Encoding::UTF_8))).to match([a_string_matching(/not UTF-8/)])
    expect(problems("a: &x 1\nsteps: *x\n")).to match([a_string_matching(/not valid YAML/)])
    expect(problems("steps: [1]\n")).to include(a_string_matching(/steps must be a mapping/))
    expect(problems("steps:\n  build: 1\n")).to include(a_string_matching(/steps\.build must be a list/))
    expect(problems("inputs: 1\n")).to include(a_string_matching(/inputs must be a mapping/))
  end

  it "caps the attempts of a step and the problems listed" do
    expect(problems("steps:\n  build: [#{(["{}"] * 101).join(",")}]\n")).to eq(["steps.build has 101 attempts; the limit is 100"])

    many = (1..60).map { |index| "k#{index}: 1" }.join("\n")
    begin
      parse(many)
    rescue Workspace::Error => e
      expect(e.details).to include("count" => 60)
      expect(e.details["problems"].size).to eq(50)
    end
  end

  it "accepts every allowed value of the choice keys and the edges of the limits" do
    %w[pass fail].each { |value| expect { parse("steps:\n  build: [{report: #{value}}]\n") }.not_to raise_error }
    %w[pass fail timeout error].each { |value| expect { parse("steps:\n  test: [{check: #{value}}]\n") }.not_to raise_error }
    %w[approve reject].each { |value| expect { parse("steps:\n  test: [{gate: #{value}}]\n") }.not_to raise_error }
    %w[pass fail].each { |value| expect { parse("steps:\n  build: [{require: {commits: #{value}}}]\n") }.not_to raise_error }
    expect { parse("steps:\n  build: [{summary: '#{"x" * 4000}', tokens: #{described_class::MAX_TOKENS}}]\n") }.not_to raise_error
    expect(parse("inputs: {task: 5}\n").inputs).to eq("task" => "5")
  end

  it "refuses one past the edges, a negative count, a bad report and writes that are not names" do
    expect(problems("steps:\n  build: [{summary: '#{"x" * 4001}'}]\n")).to match([a_string_matching(/summary must be a string of at most 4000/)])
    expect(problems("steps:\n  build: [{tokens: #{described_class::MAX_TOKENS + 1}}]\n")).to match([a_string_matching(/tokens must be/)])
    expect(problems("steps:\n  build: [{tokens: -1}]\n")).to match([a_string_matching(/tokens must be/)])
    expect(problems("steps:\n  build: [{report: maybe}]\n")).to match([a_string_matching(/report must be one of pass, fail/)])
    expect(problems("steps:\n  build: [{writes: [1]}]\n")).to match([a_string_matching(/writes must be a list of file names/)])
    expect(problems("steps:\n  build: [{writes: build.md}]\n")).to match([a_string_matching(/writes must be a list/)])
  end

  it "refuses report: x" do
    expect(problems("steps:\n  build: [{report: x}]\n")).to match([a_string_matching(/report must be one of pass, fail/)])
  end

  it "does not check the attempts past the limit" do
    entries = (["{}"] * 100 + ["{wat: 1}"]).join(",")

    expect(problems("steps:\n  build: [#{entries}]\n")).to eq(["steps.build has 101 attempts; the limit is 100"])
  end

  it "refuses a code the engine sets itself, by the rule step done uses" do
    expect(problems("steps:\n  build: [{report: fail, code: check_failed}]\n")).to match([a_string_matching(/code check_failed is a word the engine sets itself/)])
  end

  it "says '1 problem' for one and escapes control characters in the message" do
    expect { parse("wat: 1\n") }.to raise_error(Workspace::Error, /has 1 problem:/)
    expect { parse("steps:\n  \"a\\e[31m\": []\n") }.to raise_error(Workspace::Error) { |e|
      expect(e.message).not_to include("\e")
      expect(e.message).to include("\\e[31m")
      expect(e.details["problems"].first).to include("\e")
    }
  end
  describe "reviews" do
    it "reads a verdict per reviewer of the step and revision_changes" do
      script = parse("steps:\n  design:\n    - {reviews: {skeptic: approve, builder: reject}, revision_changes: true}\n")

      expect(script.attempt("design", 1)).to include("reviews" => {"skeptic" => "approve", "builder" => "reject"}, "revision_changes" => true)
    end

    it "refuses a reviewer the step does not name" do
      expect(problems("steps:\n  design: [{reviews: {nobody: approve}}]\n")).to match([a_string_matching(/reviews "nobody": the step has no such reviewer \(reviewers: skeptic, builder\)/)])
    end

    it "refuses a verdict that is not approve or reject" do
      expect(problems("steps:\n  design: [{reviews: {skeptic: maybe}}]\n")).to match([a_string_matching(/reviews "skeptic" must be one of approve, reject, not "maybe"/)])
    end

    it "refuses reviews that are not a mapping" do
      expect(problems("steps:\n  design: [{reviews: [skeptic]}]\n")).to match([a_string_matching(/reviews must be a mapping of the step's reviewers to approve or reject/)])
    end

    it "refuses reviews and revision_changes on a step without review:" do
      expect(problems("steps:\n  build: [{reviews: {skeptic: approve}, revision_changes: true}]\n")).to match([
        a_string_matching(/reviews is set, and the step has no review:/), a_string_matching(/revision_changes is set, and the step has no review:/)
      ])
    end

    it "refuses a revision_changes that is not a boolean" do
      expect(problems("steps:\n  design: [{revision_changes: yes please}]\n")).to match([a_string_matching(/revision_changes must be true or false/)])
    end

    it "reads pause as true or a reason, and unpause beside it" do
      script = parse("steps:\n  design:\n    - {pause: true}\n    - {pause: \"hold on\", unpause: true}\n")

      expect(script.attempt("design", 1)).to eq("pause" => true)
      expect(script.attempt("design", 2)).to eq("pause" => "hold on", "unpause" => true)
    end

    it "refuses a pause that is neither true nor a reason, and an unpause that is not true or has no pause" do
      expect(problems("steps:\n  design: [{pause: false}, {pause: \"\"}, {pause: true, unpause: no}, {unpause: true}]\n")).to match([
        a_string_matching(/attempt 1: pause must be true or a non-empty reason/), a_string_matching(/attempt 2: pause must be true or a non-empty reason/),
        a_string_matching(/attempt 3: unpause must be true/), a_string_matching(/attempt 4: unpause is set, and the attempt does not pause/)
      ])
    end

    it "reads reruns, one verdict map per rerun of the round's missing reviewers, and unchanged" do
      script = parse("steps:\n  design:\n    - {reviews: {skeptic: approve}, reruns: [{builder: approve}, {}], unchanged: false}\n")

      expect(script.attempt("design", 1)).to include("reruns" => [{"builder" => "approve"}, {}], "unchanged" => false)
    end

    it "refuses reruns that are not a list of verdict maps, an unknown reviewer in one, and an unchanged that is not a boolean" do
      expect(problems("steps:\n  design: [{reruns: {builder: approve}}]\n")).to match([a_string_matching(/reruns must be a list, one mapping of reviewers/)])
      expect(problems("steps:\n  design: [{reruns: [{nobody: approve}]}]\n")).to match([a_string_matching(/reruns\[0\] "nobody": the step has no such reviewer/)])
      expect(problems("steps:\n  design: [{unchanged: maybe}]\n")).to match([a_string_matching(/unchanged must be true or false/)])
      expect(problems("steps:\n  build: [{reruns: [], unchanged: true}]\n")).to match([
        a_string_matching(/reruns is set, and the step has no review:/), a_string_matching(/unchanged is set, and the step has no review:/)
      ])
    end
  end

  describe "require exec" do
    let(:exec_definition) do
      {"id" => "d", "inputs" => {}, "steps" => [{"id" => "t", "require" => [{"exec" => ["a"]}, {"exec" => ["b"]}]}]}
    end

    def exec_problems(value)
      described_class.parse("steps:\n  t: [{require: {exec: #{value}}}]\n", definition: exec_definition, source: "s.yml")
      raise "no error"
    rescue Workspace::Error => e
      e.details["problems"]
    end

    it "refuses an answer that is not pass or fail" do
      expect(exec_problems("[pass, bogus]")).to match([a_string_matching(/require exec must list only pass, fail/)])
    end

    it "refuses a list whose length differs from the exec count" do
      expect(exec_problems("[pass]")).to match([a_string_matching(/require exec lists 1 answer, but the step has 2 exec entries \(one pass or fail per exec entry\)/)])
    end

    it "refuses an exec list on a step with no exec entries" do
      expect(problems("steps:\n  build: [{require: {exec: [pass]}}]\n")).to include(a_string_matching(/require exec lists 1 answer, but the step has 0 exec entries/))
    end

    it "gives a list under a non-exec proof the existing message" do
      expect(problems("steps:\n  build: [{require: {commits: [pass]}}]\n")).to match([a_string_matching(/require commits must be one of pass, fail/)])
    end
  end

  describe "a fan_out group's siblings" do
    let(:definition) do
      Workspace::WorkflowDefinition.parse(<<~YAML, id: "grouped", source: "file", path: nil).to_h
        schema_version: 1
        id: grouped
        title: Grouped
        steps:
          plan:
            prompt: plan
            produces: [plan.md]
          checks:
            checkout: shared
            fan_out:
              lint: {prompt: lint, produces: [lint.md]}
              test: {prompt: test, produces: [test.md], gate: approve}
              docs: {prompt: docs, produces: [docs.md]}
          more:
            checkout: shared
            fan_out:
              audit: {prompt: audit, produces: [audit.md]}
              bench: {prompt: bench, produces: [bench.md]}
      YAML
    end

    it "reads a sibling's attempts named under its group, in the group's order" do
      script = parse("steps:\n  checks:\n    lint: [{report: fail}, {}]\n    docs: [{tokens: 3}]\n")

      expect(script.attempt("lint", 1)).to eq("report" => "fail")
      expect(script.attempt("lint", 2)).to eq({})
      expect(script.attempt("docs", 1)).to eq("tokens" => 3)
      expect(script.attempt("test", 1)).to eq({})
    end

    it "reads a sibling named at the top level under its own id, as any step" do
      expect(parse("steps:\n  test: [{gate: reject}]\n").attempt("test", 1)).to eq("gate" => "reject")
    end

    it "checks a sibling's attempts against the sibling's own step, naming the group in the place" do
      expect(problems("steps:\n  checks:\n    lint: [{gate: approve}]\n")).to eq(["steps.checks.lint attempt 1: gate is set, and the step has no gate:"])
    end

    it "refuses a sibling the group does not have, and one of another group" do
      expect(problems("steps:\n  checks:\n    nope: []\n    audit: []\n")).to eq([
        "steps.checks.nope: the fan_out group has no such sibling (siblings: lint, test, docs)",
        "steps.checks.audit: audit is a sibling of the fan_out group more, not of checks (siblings: lint, test, docs)"
      ])
    end

    it "refuses siblings listed out of the group's order" do
      expect(problems("steps:\n  checks:\n    docs: []\n    lint: []\n")).to eq(["steps.checks: siblings must be listed in the group's order (lint, test, docs), not docs, lint"])
    end

    it "refuses a sibling given both under its group and under its own id, either way round" do
      expect(problems("steps:\n  checks:\n    lint: []\n  lint: []\n")).to eq(["steps.lint: the attempts are given twice, here and under steps.checks"])
      expect(problems("steps:\n  lint: []\n  checks:\n    lint: []\n")).to eq(["steps.checks.lint: the attempts are given twice, here and under steps.lint"])
    end

    it "refuses a pause on a sibling, nested or named by its own id" do
      expect(problems("steps:\n  checks:\n    lint: [{pause: true, unpause: true}]\n")).to eq(["steps.checks.lint attempt 1: pause and unpause can't be set on a fan_out sibling"])
      expect(problems("steps:\n  docs: [{pause: true}]\n")).to eq(["steps.docs attempt 1: pause can't be set on a fan_out sibling"])
    end

    it "refuses a group given a list instead of a mapping of its siblings" do
      expect(problems("steps:\n  checks: [{}]\n")).to eq(["steps.checks is a fan_out group: give a mapping of its siblings (lint, test, docs) to lists of attempts"])
    end

    it "names the groups when a step is unknown" do
      expect(problems("steps:\n  ghost: []\n")).to eq(["steps.ghost: the workflow has no such step (steps: plan, lint, test, docs, audit, bench; fan_out groups: checks, more)"])
    end
  end
end
