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
    expect(problems("description: only words")).to eq(["the recipe sets nothing: give plays, packs, agents, skills, agent_kind or prompt"])
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
end
