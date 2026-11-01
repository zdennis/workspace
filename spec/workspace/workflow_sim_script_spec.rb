require "spec_helper"

RSpec.describe Workspace::WorkflowSimScript do
  let(:definition) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "demo", source: "file", path: nil).to_h
      schema_version: 1
      id: demo
      title: Demo
      inputs:
        task: {required: true}
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
end
