require "spec_helper"

RSpec.describe Workspace::RecipeFile do
  def parse(text)
    described_class.parse(text, ref: "recipe/r")
  end

  def problems(text)
    parse(text)
    raise "expected an error"
  rescue Workspace::Error => e
    expect(e.code).to eq("invalid_recipe")
    expect(e.details).to include("ref" => "recipe/r")
    e.details["problems"]
  end

  it "reads every field from a plain YAML file" do
    fields = parse(<<~YAML)
      description: Review on Codex
      plays: [kickoff, play/review]
      packs: [review]
      agents: [reviewer]
      skills: [write-tests]
      agent_kind: codex
      prompt: Start at step 2.
    YAML

    expect(fields).to eq("description" => "Review on Codex", "plays" => %w[kickoff play/review], "packs" => ["review"],
      "agents" => ["reviewer"], "skills" => ["write-tests"], "agent_kind" => "codex", "prompt" => "Start at step 2.")
  end

  it "reads frontmatter and ignores the notes after it" do
    expect(parse("---\nplays: kickoff\n---\n\nwhy: this is a note\n")).to eq("plays" => ["kickoff"])
  end

  it "drops repeated list items" do
    expect(parse("packs: [review, review]")).to eq("packs" => ["review"])
  end

  it "lists every problem at once" do
    list = problems("plays: [Bad Name]\nagent_kind: gemini\nprompt: 3\nextra: 1\n")

    expect(list).to include(/unknown field 'extra'/, /plays must be names/, /agent_kind 'gemini' is not one of/, /prompt must be non-empty text/)
  end

  it "refuses a recipe that sets nothing" do
    expect(problems("description: only words")).to eq(["the recipe sets nothing: give plays, packs, agents, skills, agent_kind, prompt or workflow"])
  end

  it "refuses an empty file, a non-mapping and bad YAML" do
    expect(problems("")).to eq(["the recipe is empty"])
    expect(problems("- a\n- b\n")).to eq(["the recipe must be a mapping of field names to values"])
    expect(problems("plays: [unclosed")).to match([/not valid YAML/])
  end

  it "caps list length and prompt size" do
    expect(problems("plays: [#{(1..21).map { |i| "p#{i}" }.join(", ")}]")).to match([/at most 20/])
    expect(problems("prompt: #{"x" * 20_001}")).to match([/longer than 20000/])
  end

  it "refuses an empty list and a kind prefix that doesn't match the field" do
    expect(problems("plays: []")).to eq(["plays must not be empty"])
    expect(problems("agents: [play/x]")).to match([/agents must be names.*optionally agent\/name/])
    expect(parse("skills: [skill/x]")).to eq("skills" => ["skill/x"])
  end

  it "does not instantiate arbitrary YAML objects" do
    expect(problems("plays: !ruby/object:Object {}")).to match([/not valid YAML/])
  end

  describe "workflow recipes" do
    it "reads a workflow with inputs and claude as the agent kind" do
      expect(parse("workflow: rpiv\nworkflow_inputs: {task: Add a retry}\nagent_kind: claude\ndescription: d\n"))
        .to eq("workflow" => "rpiv", "workflow_inputs" => {"task" => "Add a retry"}, "agent_kind" => "claude", "description" => "d")
    end

    it "reads a bare workflow and accepts an id no catalog has" do
      expect(parse("workflow: no-such-flow_1")).to eq("workflow" => "no-such-flow_1")
    end

    it "turns numbers and booleans into strings" do
      fields = parse("workflow: w\nworkflow_inputs: {a: 3, c: true, d: false, e: text}\n")

      expect(fields["workflow_inputs"]).to eq("a" => "3", "c" => "true", "d" => "false", "e" => "text")
    end

    it "refuses floats, including .inf and .nan, and says to quote" do
      list = problems("workflow: w\nworkflow_inputs: {a: 1.50, b: .inf, c: .nan}")

      expect(list).to match([/a is a decimal number; quote it/, /b is a decimal/, /c is a decimal/])
      expect(parse("workflow: w\nworkflow_inputs: {a: \"1.50\"}")["workflow_inputs"]).to eq("a" => "1.50")
    end

    it "refuses control characters but not newline, return or tab, and never echoes the value" do
      list = problems("workflow: w\nworkflow_inputs: {a: \"x\\0y\", b: \"x\\ey\", c: \"x\\x7Fy\"}")

      expect(list).to eq(["workflow_inputs a holds a control character", "workflow_inputs b holds a control character", "workflow_inputs c holds a control character"])
      expect(parse("workflow: w\nworkflow_inputs: {a: \"l1\\nl2\\r\\tz\"}")["workflow_inputs"]).to eq("a" => "l1\nl2\r\tz")
    end

    it "gives a bad agent_kind beside workflow just its own problem" do
      ["~", "''", "Claude", "[x]"].each do |bad|
        expect(problems("workflow: w\nagent_kind: #{bad}").length).to eq(1)
        expect(problems("workflow: w\nagent_kind: #{bad}").first).not_to match(/only claude/)
      end
    end

    it "refuses a bad workflow id" do
      expect(problems("workflow: Bad Id")).to match([/workflow must be a workflow id \(lowercase letters, digits, '-' and '_'/])
      expect(problems("workflow: [a]")).to match([/workflow must be a workflow id/])
      expect(problems("workflow: #{"a" * 41}")).to match([/workflow must be a workflow id/])
    end

    it "refuses workflow_inputs that are not a non-empty mapping, or too many" do
      expect(problems("workflow: w\nworkflow_inputs: {}")).to eq(["workflow_inputs must be a non-empty mapping of input names to values"])
      expect(problems("workflow: w\nworkflow_inputs: [a]")).to match([/non-empty mapping/])
      many = (1..21).map { |i| "i#{i}: x" }.join(", ")
      expect(problems("workflow: w\nworkflow_inputs: {#{many}}")).to match([/at most 20 entries, not 21/])
    end

    it "refuses non-string keys and bad names without stringifying them" do
      expect(problems("workflow: w\nworkflow_inputs:\n  1: x\n")).to match([/input name 1 must be lowercase/])
      expect(problems("workflow: w\nworkflow_inputs:\n  true: x\n")).to match([/input name true must be lowercase/])
      expect(problems("workflow: w\nworkflow_inputs: {Bad-Name: x}")).to match([/input name "Bad-Name"/])
    end

    it "refuses null, list and map values and over-long values" do
      list = problems("workflow: w\nworkflow_inputs: {a: ~, b: [1], c: {d: 1}, e: #{"x" * 20_001}}")

      expect(list).to match([/a must be text, a whole number/, /b must be text/, /c must be text/, /e is longer than 20000/])
    end

    it "measures length after turning the value into a string" do
      expect(parse("workflow: w\nworkflow_inputs: {task: #{"x" * 20_000}}")["workflow_inputs"]["task"].length).to eq(20_000)
    end

    it "refuses workflow beside plays, packs, agents, skills or prompt in one problem" do
      expect(problems("workflow: w\nplays: [a]\npacks: [b]\nprompt: hi\nagents: [c]\nskills: [d]"))
        .to eq(["workflow can't be combined with plays, packs, agents, skills, prompt: a workflow run takes none of them"])
    end

    it "reports the combination even when a field's value is bad" do
      list = problems("workflow: w\nplays: 5")

      expect(list).to include(/plays must be names/, /workflow can't be combined with plays/)
    end

    it "refuses workflow_inputs without workflow, even with a bad value" do
      expect(problems("plays: [a]\nworkflow_inputs: {a: x}")).to eq(["workflow_inputs needs workflow"])
      expect(problems("plays: [a]\nworkflow_inputs: 5")).to include("workflow_inputs needs workflow")
    end

    it "refuses an agent kind other than claude beside workflow, and allows description" do
      expect(problems("workflow: w\nagent_kind: codex")).to match([/agent_kind 'codex' can't be combined with workflow: only claude/])
      expect(parse("workflow: w\ndescription: fine")).to eq("workflow" => "w", "description" => "fine")
    end

    it "collects several problems at once" do
      list = problems("workflow: Bad\nworkflow_inputs: {1: x}\nplays: [a]\nagent_kind: codex")

      expect(list).to match([/workflow must be/, /input name 1/, /can't be combined with plays/, /agent_kind 'codex'/])
    end
  end
end
