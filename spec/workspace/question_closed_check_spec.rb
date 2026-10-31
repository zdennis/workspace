require "spec_helper"

RSpec.describe Workspace::QuestionClosedCheck do
  subject(:check) { described_class.new }

  let(:box) { "────────\n❯ \n────────\n" }

  # The text at the bottom of a pane as tall as a real one.
  def tall(text, rows: 40)
    "\n" * [rows - text.count("\n"), 0].max + text
  end

  def fixture(name)
    File.read(File.expand_path("../fixtures/claude_screens/#{name}.txt", __dir__))
  end

  # Captured from Claude Code 2.1.316; see the class comment.
  Dir[File.expand_path("../fixtures/claude_screens/question_open_*.txt", __dir__)].sort.each do |path|
    name = File.basename(path, ".txt")

    it "reads nothing from the open dialog #{name}" do
      expect(check.reading("claude", File.read(path))).to be_nil
    end
  end

  # An empty box left higher up must not stand in for the dialog below it.
  Dir[File.expand_path("../fixtures/claude_screens/question_open_*.txt", __dir__)].sort.each do |path|
    name = File.basename(path, ".txt")

    it "reads nothing from #{name} with a stale empty box above it" do
      expect(check.reading("claude", "#{box}#{File.read(path)}")).to be_nil
    end
  end

  it "reads nothing from a capture that is not valid UTF-8" do
    bad = "#{box}caf\xE9\n".force_encoding("UTF-8")

    expect(bad.valid_encoding?).to be(false)
    expect(check.reading("claude", bad)).to be_nil
  end

  it "reads nothing with a selector or numbered row under the box, however it is indented" do
    expect(check.reading("claude", "#{box} ❯ 1. Yes\n")).to be_nil
    expect(check.reading("claude", "#{box}❯ 1. Submit\n")).to be_nil
    expect(check.reading("claude", "#{box}  2. Cancel\n")).to be_nil
  end

  it "has the captured forms of an open dialog to read" do
    expect(Dir[File.expand_path("../fixtures/claude_screens/question_open_*.txt", __dir__)].size).to be >= 16
  end

  it "reads nothing while PreToolUse hooks run before the dialog draws: the box is empty, the spinner is up" do
    expect(fixture("question_about_to_draw")).to include("running PreToolUse hooks")
    expect(check.reading("claude", fixture("question_about_to_draw"))).to be_nil
  end

  %w[question_closed_single question_closed_tabs question_closed_exit_plan question_closed_default_tui].each do |name|
    it "reads the screen left by Esc: #{name}" do
      expect(check.reading("claude", fixture(name))).to be_a(String)
    end
  end

  it "reads nothing from a draft, and nothing with no capture" do
    expect(check.reading("claude", "────────\n❯ half a thought\n────────\n")).to be_nil
    expect(check.reading("claude", nil)).to be_nil
  end

  it "wants the closing rule on the row under the prompt" do
    expect(check.reading("claude", "────────\n❯ \n\n────────\n")).to be_nil
    expect(check.reading("claude", "────────\n❯ \n")).to be_nil
  end

  it "reads nothing with a dialog's hint under the box, and doesn't mind one quoted above it" do
    expect(check.reading("claude", "#{box}Enter to select · Esc to cancel\n")).to be_nil
    expect(check.reading("claude", tall("Esc to cancel\n#{box}"))).to be_a(String)
  end

  it "reads nothing from an agent it can't read a box for" do
    expect(check.reading("codex", box)).to be_nil
    expect(check.reading("shell", box)).to be_nil
  end

  it "reads the same with a status line that moves, and differently when the rows above the box move" do
    first = check.reading("claude", tall("done\n#{box}  12s\n"))

    expect(first).to be_a(String)
    expect(check.reading("claude", tall("done\n#{box}  13s\n"))).to eq(first)
    expect(check.reading("claude", tall("other\n#{box}  12s\n"))).not_to eq(first)
  end

  describe "a short pane" do
    it "reads nothing when the spinner could have scrolled off" do
      rows = fixture("question_about_to_draw").lines
      spinner = rows.index { |row| row.include?("running PreToolUse hooks") }
      tasks = (1..6).map { |n| "  ◻ task #{n}\n" }
      short = rows.dup.insert(spinner + 1, *tasks).last(12).join

      expect(short).not_to include("running PreToolUse hooks")
      expect(short.lines.size).to be < described_class::MIN_ROWS
      expect(check.reading("claude", short)).to be_nil
    end

    it "still reads a tall pane with the box near the top" do
      expect(fixture("question_closed_single").lines.size).to be >= described_class::MIN_ROWS
      expect(check.reading("claude", fixture("question_closed_single"))).to be_a(String)
    end
  end

  describe "rows under the box" do
    it "reads nothing from a selector or option row behind a non-breaking space" do
      expect(check.reading("claude", tall("#{box} ❯ 1. Yes\n"))).to be_nil
      expect(check.reading("claude", tall("#{box}  2. No\n"))).to be_nil
    end

    it "reads nothing from a numbered option with nothing after the dot" do
      expect(check.reading("claude", tall("#{box}  1.\n"))).to be_nil
    end

    ["1.2 GB free", "2.1.316 update available", "1 shell still running"].each do |row|
      it "still reads a screen with #{row.inspect} under the box" do
        expect(check.reading("claude", tall("#{box}  #{row}\n"))).to be_a(String)
      end
    end
  end
end
