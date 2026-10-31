require "spec_helper"

RSpec.describe Workspace::IdlePromptCheck do
  subject(:check) { described_class.new }

  let(:facts) { {kind: "claude", state: "idle", open_tools: []} }
  let(:rule) { "─" * 40 }

  def screen(*above, input: "", below: ["  [Model] example status"])
    [*above, rule, "❯ #{input}", rule, *below, ""].join("\n")
  end

  it "passes an empty box with nothing running" do
    expect(check.refusal(facts, screen("✻ Churned for 22s · done 9:59 AM", ""))).to be_nil
  end

  it "passes a suggestion" do
    expect(check.refusal(facts, screen(input: "\e[2msend the reply\e[0m"))).to be_nil
  end

  it "refuses a nil capture" do
    expect(check.refusal(facts, nil)).to include(reason: "no_input_prompt")
  end

  it "refuses a pane the monitor has not seen" do
    expect(check.refusal(nil, screen)).to include(reason: "unknown")
  end

  it "keeps TypingSafety's reason for a draft and answers only reason and message" do
    refused = check.refusal(facts, screen(input: "half a thought"))

    expect(refused.keys).to contain_exactly(:reason, :message)
    expect(refused[:reason]).to eq("input_not_empty")
  end

  it "keeps TypingSafety's reason for a dialog" do
    expect(check.refusal(facts, "Do you want to proceed?\n❯ 1. Yes\n")[:reason]).to eq("no_input_prompt")
  end

  [
    "✻ Razzle-dazzling… (12s)",
    "✢ Beboppin'… (3s)",
    "✽ Frosting… (1m 18s · ↓ 1.4k tokens)",
    "  ⎿  Running… (54s · timeout 5m)",
    "✶ Thinking…",
    "  ☐ Write tests…",
    "  ctrl+c, esc to interrupt",
    "  Retrying in 12 seconds"
  ].each do |row|
    it "reads #{row.inspect} as busy" do
      expect(check.refusal(facts, screen(row, ""))).to include(reason: "turn_started")
    end
  end

  [
    "  ◯ Explore  Searching bar tests for questio… 3m 5s",
    "✻ Waiting for 1 background agent to finish",
    "· 1 shell still running",
    "  ⎿  Tip: press ctrl+o to expand the output and look…",
    "✻ Crunched for 14s · done 11:05 AM · 1 shell still running",
    "     … +6 lines (ctrl+o to expand)"
  ].each do |row|
    it "does not read #{row.inspect} as busy" do
      expect(check.refusal(facts, screen(row, ""))).to be_nil
    end
  end

  it "reads a sub-agent row below the box as not busy" do
    row = "  ◯ general-purpose  Editing attention CLAUDE.md wai… 4m 41s · ↓ 99.3k tokens"

    expect(check.refusal(facts, screen(below: [row]))).to be_nil
  end

  it "reads a custom status line cut short with an ellipsis as not busy" do
    expect(check.refusal(facts, screen(below: ["  📁 proj | 🌿 long-branch…"]))).to be_nil
  end

  it "reads `Retrying in` below the box as busy" do
    expect(check.refusal(facts, screen(below: ["  Retrying in 12 seconds"]))).to include(reason: "turn_started")
  end

  it "reads `esc to interrupt` below the box as busy" do
    expect(check.refusal(facts, screen(below: ["  esc to interrupt"]))).to include(reason: "turn_started")
  end

  it "reads a spinner row above a long task list as busy" do
    tasks = Array.new(10) { |n| "  ⎿  ☐ task #{n}" }

    expect(check.refusal(facts, screen("✽ Frosting… (2s)", *tasks, "  ⎿  Tip: try something", ""))).to include(reason: "turn_started")
  end

  it "does not read that wording far above the box as busy" do
    quoted = ["✽ Frosting… (2s)", "press esc to interrupt", "Retrying in 3s"]
    filler = Array.new(described_class::ROWS_ABOVE) { |n| "line #{n}" }

    expect(check.refusal(facts, screen(*quoted, *filler))).to be_nil
  end

  it "goes by the last input box on screen" do
    text = screen("✽ Frosting… (2s)", "") + Array.new(30) { "line" }.join("\n") + "\n" + screen

    expect(check.refusal(facts, text)).to be_nil
  end
end
