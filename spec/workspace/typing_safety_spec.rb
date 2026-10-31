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

    expect(safety.check(facts, "────────\n❯ #{pasted[0, 60]}\n#{pasted[60..]}\n────────\n", pasted: pasted)).to be_nil
    expect(safety.check(facts, dialog_screen, pasted: pasted)).to include(reason: "no_input_prompt")
    expect(safety.check(facts, "────────\n❯ 1. Yes\n────────\n", pasted: pasted)).to include(reason: "input_changed")
    expect(safety.check(facts, "────────\n❯ hello #{pasted}\n────────\n", pasted: pasted)).to include(reason: "input_changed")
  end

  describe "a paste checked against the whole input box" do
    def box(width, *rows)
      rule = "─" * width
      ([rule, "❯ #{rows.first}"] + rows.drop(1) + [rule]).join("\n") + "\n"
    end

    it "passes a word-wrapped paste at 14 columns" do
      pasted = "run the specs for the module now"
      expect(safety.check(facts, box(14, "run the", "specs for", "the module", "now"), pasted: pasted)).to be_nil
    end

    it "passes a long word split across rows at 14 columns" do
      pasted = "deployment-pipeline-config-review-now"
      expect(safety.check(facts, box(14, "deployment", "-pipeline-", "config-rev", "iew-now"), pasted: pasted)).to be_nil
    end

    it "refuses a draft ahead of the paste at 20 columns" do
      pasted = "run the specs for the module now"
      screen = box(20, "run the specs", "against prodrun", "the specs for", "the module now")
      expect(safety.check(facts, screen, pasted: pasted)).to include(reason: "input_changed")
    end

    it "refuses a draft ahead of the paste at 14 columns" do
      pasted = "deployment-pipeline-config-review-now"
      screen = box(14, "deployment", "deployment", "-pipeline-", "config-rev", "iew-now")
      expect(safety.check(facts, screen, pasted: pasted)).to include(reason: "input_changed")
    end

    it "refuses when the paste is missing" do
      expect(safety.check(facts, box(14, "run the specs"), pasted: "run the specs for the module now")).to include(reason: "input_changed")
    end

    it "does not pass a blank paste against an empty box" do
      expect(safety.check(facts, box(40, ""), pasted: " ")).to include(reason: "input_changed")
    end

    it "passes a lone paste placeholder" do
      expect(safety.check(facts, box(40, "[Pasted text #1 +1 line]"), pasted: "line one\nline two")).to be_nil
    end

    it "passes a short paste and refuses a different draft" do
      expect(safety.check(facts, box(40, "run it"), pasted: "run it")).to be_nil
      expect(safety.check(facts, box(40, "walk it"), pasted: "run it")).to include(reason: "input_changed")
    end

    it "passes on a wide pane, one row" do
      expect(safety.check(facts, box(80, "run the specs for the module now"), pasted: "run the specs for the module now")).to be_nil
    end

    it "passes a multi-line paste" do
      expect(safety.check(facts, box(40, "line one", "line two"), pasted: "line one\nline two")).to be_nil
    end

    it "refuses a draft that begins with the same words as the paste" do
      expect(safety.check(facts, box(80, "continue but skip the db testscontinue"), pasted: "continue")).to include(reason: "input_changed")
      expect(safety.check(facts, box(80, "yes please do it"), pasted: "yes")).to include(reason: "input_changed")
      expect(safety.check(facts, box(80, "run the specs please"), pasted: "run the specs")).to include(reason: "input_changed")
    end

    it "refuses an identical draft with the text doubled" do
      expect(safety.check(facts, box(80, "run the specsrun the specs"), pasted: "run the specs")).to include(reason: "input_changed")
    end

    it "passes a long paste at 20 and 80 columns" do
      pasted = "run the specs for the module now and report"
      expect(safety.check(facts, box(20, "run the specs for", "the module now and", "report"), pasted: pasted)).to be_nil
      expect(safety.check(facts, box(80, pasted), pasted: pasted)).to be_nil
    end

    it "refuses when the closing rule isn't on screen" do
      expect(safety.check(facts, "────\n❯ run it\n", pasted: "run it")).to include(reason: "input_changed")
    end
  end

  it "takes Claude Code's paste placeholder as the pasted text, but not before a paste" do
    pasted = "line one\nline two\n" * 40

    expect(safety.check(facts, "────────\n❯ [Pasted text #1 +80 lines]\n────────\n", pasted: pasted)).to be_nil
    expect(safety.check(facts, "────────\n❯ [Pasted text #1]\n────────\n", pasted: pasted)).to be_nil
    expect(safety.check(facts, "────────\n❯ [Pasted text #3 +39 lines] [Pasted text #4 +2 lines]\n────────\n", pasted: pasted)).to include(reason: "input_changed")
    expect(safety.check(facts, "────────\n❯ [Pasted text #1 +80 lines] and more\n────────\n", pasted: pasted)).to include(reason: "input_changed")
    expect(safety.check(facts, "────────\n❯ [Pasted text #1 +80 lines]\n")).to include(reason: "input_not_empty")
    expect(safety.check(facts, "────────\n❯ my draft [Pasted text #1 +80 lines]\n", pasted: pasted)).to include(reason: "input_changed")
  end

  describe "with a styled screen" do
    let(:rule) { "\e[38;5;244m────────\e[39m\n" }
    let(:status) { "  \e[36m[Model]\e[39m status\n" }

    def fixture(name)
      Workspace::StyledScreen.parse(File.read(File.expand_path("../fixtures/claude_screens/#{name}.txt", __dir__)))
    end

    def styled(input, tail: rule)
      Workspace::StyledScreen.parse("#{rule}#{input}\n#{tail}#{status}")
    end

    it "reads both live suggestions as empty" do
      expect(safety.check(facts, fixture("suggestion_export"))).to be_nil
      expect(safety.check(facts, fixture("suggestion_send"))).to be_nil
      expect(safety.check(facts, fixture("empty_input"))).to be_nil
    end

    it "reads a suggestion with a link elsewhere on screen as empty" do
      expect(safety.check(facts, fixture("suggestion_with_link"))).to be_nil
    end

    it "refuses a plain draft, typed text with a dim tail, and a partly dim line" do
      expect(safety.check(facts, styled("\e[39m❯ half a thought"))).to include(reason: "input_not_empty")
      expect(safety.check(facts, styled("\e[39m❯ typed\e[2m dim tail\e[0m"))).to include(reason: "input_not_empty")
      expect(safety.check(facts, styled("\e[39m❯ \e[2mdim\e[0m more"))).to include(reason: "input_not_empty")
    end

    it "refuses a grey foreground, which is not faint" do
      expect(safety.check(facts, styled("\e[39m❯ \e[38;5;244mgrey text\e[0m"))).to include(reason: "input_not_empty")
    end

    it "refuses a dialog row" do
      expect(safety.check(facts, styled("\e[39m❯ 1. Yes"))).to include(reason: "input_not_empty")
    end

    it "still passes the placeholder" do
      expect(safety.check(facts, styled("\e[39m❯ Try \"write a test\""))).to be_nil
    end

    it "reads a wrapped suggestion as empty only when every line is faint" do
      faint = "\e[39m❯ \e[2mfirst half of a long suggestion\n  second half\e[0m"
      expect(safety.check(facts, styled(faint))).to be_nil
      undimmed = "\e[39m❯ \e[2mfirst half of a long suggestion\e[0m\n  second half"
      expect(safety.check(facts, styled(undimmed))).to include(reason: "input_not_empty")
    end

    it "refuses a plain screen and an unprovable line, as today" do
      expect(safety.check(facts, "────────\n❯ send %45 the reply\n")).to include(reason: "input_not_empty")
      expect(safety.check(facts, styled("\e[39m❯ \e[2msend\e[?25l the reply\e[0m"))).to include(reason: "input_not_empty")
      expect(safety.check(facts, styled("\e[39m❯ \e[7m\e[2msend\e[0m\e[7m the reply\e[0m"))).to include(reason: "input_not_empty")
    end

    it "refuses an unknown escape on a continuation line" do
      input = "\e[39m❯ \e[2mfirst half\e[0m\n  \e[2m\e[?25lsecond\e[0m"
      expect(safety.check(facts, styled(input))).to include(reason: "input_not_empty")
    end

    it "keeps pasted: and exact: on the plain text, so dim text in the box refuses" do
      suggestion = styled("\e[39m❯ \e[2msend %45 the reply\e[0m")
      expect(safety.check(facts, suggestion, pasted: "run the specs")).to include(reason: "input_changed")
      expect(safety.check(facts, suggestion, exact: "run the specs")).to include(reason: "input_changed")
      pasted = "run the specs"
      typed = styled("\e[39m❯ #{pasted}\e[2m and more\e[0m")
      expect(safety.check(facts, typed, pasted: pasted)).to include(reason: "input_changed")
      expect(safety.check(facts, typed, exact: pasted)).to include(reason: "input_changed")
    end
  end

  describe "with exact:" do
    let(:text) { "An API error stopped your last turn. Continue where you left off." }

    it "passes only on the whole text, however it wraps" do
      expect(safety.check(facts, "────────\n❯ #{text}\n────────\n  status\n", exact: text)).to be_nil
      wrapped = "────────\n❯ An API error stopped your last turn.\n  Continue where you left off.\n────────\n"
      expect(safety.check(facts, wrapped, exact: text)).to be_nil
    end

    it "refuses a longer draft, a shorter one, more lines, and a paste placeholder" do
      ["#{text} and more", text[0, 30], "#{text}\n  a second line", "[Pasted text #1 +80 lines]"].each do |input|
        expect(safety.check(facts, "────────\n❯ #{input}\n────────\n", exact: text)).to include(reason: "input_changed")
      end
    end

    it "reads past a person's line that holds box-drawing characters" do
      screen = "────────\n❯ #{text}\n  a ───── line of mine\n────────\n"
      expect(safety.check(facts, screen, exact: text)).to include(reason: "input_changed")
    end

    it "still refuses a waiting pane" do
      expect(safety.check(facts(state: "waiting"), "────────\n❯ #{text}\n", exact: text)).to include(reason: "waiting")
    end
  end
end
