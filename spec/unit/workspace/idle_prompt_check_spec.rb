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

  it "refuses a draft that starts on the second row of the box" do
    expect(check.refusal(facts, screen(input: "\n  please keep this draft"))[:reason]).to eq("input_not_empty")
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

  describe "rows above the last finished-turn line" do
    it "does not read a real idle pane whose reply quotes `esc to interrupt` as busy" do
      captured = File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "claude_screens", "quoted_busy_words_after_done.txt"))

      expect(check.refusal(facts, captured)).to be_nil
    end

    it "does not read the turn's own rows as busy" do
      above = ["⏺ Done. It no longer prints esc to interrupt or ends a line in an ellipsis…", "",
        "✻ Cogitated for 1m 19s · done 1:23 PM", ""]

      expect(check.refusal(facts, screen(*above))).to be_nil
    end

    it "reads a new turn's spinner below the line as busy" do
      above = ["✻ Brewed for 6s · done 1:28 PM", "", "❯ next prompt", "", "✽ Incubating… (8s · ↓ 381 tokens)", ""]

      expect(check.refusal(facts, screen(*above))).to include(reason: "turn_started")
    end

    it "does not take an indented, quoted done-line for the end of a turn" do
      above = ["  press esc to interrupt", "  ✻ Brewed for 25s · done", ""]

      expect(check.refusal(facts, screen(*above))).to include(reason: "turn_started")
    end

    it "takes a done-line with background shells left for the end of a turn" do
      above = ["  Retrying in 3s is quoted here", "✻ Churned for 1m 8s · done 12:53 PM · 1 shell still running", ""]

      expect(check.refusal(facts, screen(*above))).to be_nil
    end
  end

  # Captured from Claude Code with identifying text replaced. A live spinner
  # row has no `esc to interrupt` (`✽ Incubating… (8s · ↓ 381 tokens)`), so its
  # ellipsis is what marks it; a finished-turn line has the same glyph-and-verb
  # shape without one.
  describe "finished-turn lines and live spinners as Claude Code draws them" do
    def fixture(name)
      File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "claude_screens", name))
    end

    it "reads a finished turn with its clock time as idle" do
      expect(check.refusal(facts, fixture("done_line_idle.txt"))).to be_nil
    end

    it "reads a finished turn with a shell still running as idle" do
      expect(check.refusal(facts, fixture("done_line_shell_running.txt"))).to be_nil
    end

    it "reads a live spinner as a turn started" do
      expect(check.refusal(facts, fixture("live_spinner.txt"))).to include(reason: "turn_started")
    end

    it "reads a done-line with no clock time as idle" do
      expect(check.refusal(facts, screen("✻ Brewed for 25s · done", ""))).to be_nil
    end

    it "still reads a spinner with a timer as busy" do
      expect(check.refusal(facts, screen("✢ Brewing… (3s)", ""))).to include(reason: "turn_started")
    end

    it "reads `esc to interrupt` below a done-line as busy" do
      above = ["✻ Brewed for 25s · done", "  esc to interrupt", ""]

      expect(check.refusal(facts, screen(*above))).to include(reason: "turn_started")
    end
  end

  it "goes by the last input box on screen" do
    text = screen("✽ Frosting… (2s)", "") + Array.new(30) { "line" }.join("\n") + "\n" + screen

    expect(check.refusal(facts, text)).to be_nil
  end

  describe "with scrollback rows" do
    let(:capture) { Struct.new(:raw, :history_rows) }

    it "passes a short pane whose opening rule is in history and whose box is empty" do
      raw = [*Array.new(5) { "old" }, rule, "❯ ", rule, *Array.new(6) { "" }, ""].join("\n")

      expect(check.refusal(facts, capture.new(raw, 1))).to be_nil
    end

    it "refuses a prompt that is only in history" do
      raw = [rule, "❯ ", rule, "history", "more", "text"].join("\n")

      expect(check.refusal(facts, capture.new(raw, 4))).to include(reason: "no_input_prompt")
    end

    it "reads a spinner row in history above the box as busy" do
      raw = ["✻ Razzle-dazzling… (12s)", rule, "❯ ", rule, "  [Model] example status", ""].join("\n")

      expect(check.refusal(facts, capture.new(raw, 1))).to include(reason: "turn_started")
    end
  end
end
