require "spec_helper"

RSpec.describe Workspace::TypingSafety do
  subject(:safety) { described_class.new }

  let(:prompt_screen) { "output\n────────────────────\n❯ \n────────────────────\n" }
  let(:dialog_screen) { "│ Do you want to make this edit?\n│ ❯ 1. Yes\n│   2. No\n" }

  def facts(kind: "claude", state: "idle", open_tools: [])
    {kind: kind, state: state, open_tools: open_tools}
  end

  it "lets an idle or working Claude pane with its input prompt on screen take text" do
    expect(safety.check(facts, prompt_screen)).to be_nil
    expect(safety.check(facts(state: "working", open_tools: ["Bash"]), prompt_screen)).to be_nil
  end

  it "refuses a pane the monitor hasn't seen, or whose agent it hasn't identified" do
    expect(safety.check(nil, prompt_screen)).to include(code: "pane_not_ready", reason: "unknown")
    expect(safety.check(facts(kind: "unknown"), prompt_screen)).to include(code: "pane_not_ready", reason: "unknown")
  end

  it "refuses a shell pane as not an agent" do
    expect(safety.check(facts(kind: "shell"), prompt_screen)).to include(code: "not_an_agent")
  end

  it "refuses a pane waiting on a permission prompt or a question" do
    expect(safety.check(facts(state: "waiting"), prompt_screen)).to include(code: "pane_not_ready", reason: "waiting")
  end

  it "refuses while AskUserQuestion or ExitPlanMode is running" do
    %w[AskUserQuestion ExitPlanMode].each do |tool|
      expect(safety.check(facts(state: "working", open_tools: ["Read", tool]), prompt_screen))
        .to include(code: "pane_not_ready", reason: "question_open")
    end
  end

  it "refuses when the input prompt isn't on screen: a dialog the monitor hasn't heard about yet" do
    expect(safety.check(facts(state: "working"), dialog_screen)).to include(code: "pane_not_ready", reason: "no_input_prompt")
    expect(safety.check(facts, nil)).to include(reason: "no_input_prompt")
  end

  it "refuses a provider with no input-prompt pattern, whose dialogs can't be seen" do
    plain = Workspace::AgentProvider.new(key: "plain", label: "Plain", executable: "plain")
    checker = described_class.new(providers: [plain])

    expect(checker.check(facts(kind: "plain"), prompt_screen)).to include(code: "pane_not_ready", reason: "unsupported_agent")
  end

  it "refuses a draft in the input line, and a menu row under a rule" do
    expect(safety.check(facts, "────────\n❯ half a thought\n")).to include(reason: "input_not_empty")
    expect(safety.check(facts, "────────\n❯ 1. Yes\n")).to include(reason: "input_not_empty")
  end

  it "goes by the last input prompt on screen" do
    expect(safety.check(facts, "────────\n❯ old text in scrollback\n#{prompt_screen}")).to be_nil
  end

  it "lets the placeholder through" do
    expect(safety.check(facts, "────────\n❯ Try \"write a test for scanner.rb\"\n────────\n")).to be_nil
  end

  it "wants the pasted text in the input line once it is pasted, not a menu row or another draft" do
    pasted = Workspace::AgentStatusDesk.prompt_for("sr-1")

    expect(safety.check(facts, "────────\n❯ #{pasted[0, 60]}\n#{pasted[60..]}\n", pasted: pasted)).to be_nil
    expect(safety.check(facts, dialog_screen, pasted: pasted)).to include(reason: "no_input_prompt")
    expect(safety.check(facts, "────────\n❯ 1. Yes\n", pasted: pasted)).to include(reason: "input_changed")
    expect(safety.check(facts, "────────\n❯ hello #{pasted}\n", pasted: pasted)).to include(reason: "input_changed")
  end

  it "takes Claude Code's paste placeholder as the pasted text, but not before a paste" do
    pasted = "line one\nline two\n" * 40

    expect(safety.check(facts, "────────\n❯ [Pasted text #1 +80 lines]\n", pasted: pasted)).to be_nil
    expect(safety.check(facts, "────────\n❯ [Pasted text #1 +80 lines]\n")).to include(reason: "input_not_empty")
    expect(safety.check(facts, "────────\n❯ my draft [Pasted text #1 +80 lines]\n", pasted: pasted)).to include(reason: "input_changed")
  end
end
