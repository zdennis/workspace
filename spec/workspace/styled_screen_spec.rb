# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::StyledScreen do
  def fixture(name)
    File.read(File.join(__dir__, "..", "fixtures", "claude_screens", name))
  end

  def parse(raw)
    described_class.parse(raw)
  end

  def faint_columns(screen, line)
    (0...screen.text.lines[line].chomp.length).select { |column| screen.faint?(line, column) }
  end

  it "is nil for a nil capture" do
    expect(parse(nil)).to be_nil
  end

  describe "#text" do
    it "is the screen without escapes" do
      expect(parse("\e[39m❯ \e[2mhello\e[0m\n").text).to eq("❯ hello\n")
    end

    it "cuts trailing spaces from each line" do
      expect(parse("\e[2mfaint\e[0m   \nplain  \n").text).to eq("faint\nplain\n")
    end

    it "keeps a screen without a final newline as it is" do
      expect(parse("a\nb").text).to eq("a\nb")
    end

    it "drops links of both endings and shift characters" do
      raw = "x \e]8;id=1;https://e.test\e\\link\e]8;;\e\\ \e]8;;https://e.test\alink2\e]8;;\a \u000eqq\u000f\n"
      expect(parse(raw).text).to eq("x link link2 qq\n")
    end
  end

  describe "faint tracking" do
    it "sets faint with 2 and clears it with 0" do
      screen = parse("a\e[2mbc\e[0md\n")
      expect([0, 1, 2, 3].map { |c| screen.faint?(0, c) }).to eq([false, true, true, false])
    end

    it "clears faint with 22" do
      screen = parse("\e[2ma\e[22mb\n")
      expect([screen.faint?(0, 0), screen.faint?(0, 1)]).to eq([true, false])
    end

    it "clears faint with an empty parameter list or empty parameter" do
      expect(parse("\e[2ma\e[mb\n").faint?(0, 1)).to be(false)
      expect(parse("\e[2ma\e[;1mb\n").faint?(0, 1)).to be(false)
    end

    it "reads faint in a combined sequence" do
      screen = parse("\e[1;2ma\e[22;3mb\n")
      expect([screen.faint?(0, 0), screen.faint?(0, 1)]).to eq([true, false])
    end

    it "ignores an underline style written with a colon" do
      screen = parse("\e[4:2ma\n")
      expect([screen.faint?(0, 0), screen.proven?(0)]).to eq([false, true])
    end

    it "leaves a line unproven on any other colon group" do
      ["\e[2:1ma\n", "\e[2:ma\n", "\e[:2ma\n", "\e[1:2ma\n", "\e[2m\e[0:1ma\n", "\e[2m\e[0:0ma\n"].each do |raw|
        expect(parse(raw).proven?(0)).to be(false), raw.inspect
      end
    end

    it "compares parameters as numbers" do
      expect(parse("\e[2m\e[00mx\n").faint?(0, 0)).to be(false)
      expect(parse("\e[2m\e[000mx\n").faint?(0, 0)).to be(false)
      expect(parse("\e[02mx\n").faint?(0, 0)).to be(true)
      expect(parse("\e[2m\e[022mx\n").faint?(0, 0)).to be(false)
      expect(parse("\e[2m\e[2xmx\n").proven?(0)).to be(false)
    end

    it "treats a malformed colour as unproven and applies nothing after it" do
      ["\e[38;9;2m", "\e[38;5m", "\e[48;2;1;2m", "\e[58m"].each do |sgr|
        screen = parse("#{sgr}x\n")
        expect([screen.faint?(0, 0), screen.proven?(0)]).to eq([false, false]), sgr.inspect
      end
      expect(parse("\e[2;38;9mx\n").faint?(0, 0)).to be(true)
    end

    it "marks one word and not the next" do
      screen = parse("\e[2mdim\e[22m plain\n")
      expect(faint_columns(screen, 0)).to eq([0, 1, 2])
    end

    it "does not count a grey foreground or other colours" do
      ["\e[38;5;244m", "\e[38;5;2m", "\e[38;2;2;2;2m", "\e[38:5:2m", "\e[38:2::2:2:2m", "\e[48;5;2m", "\e[90m", "\e[2;0m"].each do |sgr|
        expect(parse("#{sgr}text\n").faint?(0, 0)).to be(false), sgr.inspect
      end
    end

    it "still reads faint after a colour in the same sequence" do
      expect(parse("\e[38;5;244;2mtext\n").faint?(0, 0)).to be(true)
    end

    it "carries the state to the next line" do
      screen = parse("\e[2ma\nb\n")
      expect(screen.faint?(1, 0)).to be(true)
    end

    it "is false off the screen" do
      screen = parse("\e[2ma\n")
      expect([screen.faint?(0, 5), screen.faint?(0, -1), screen.faint?(9, 0)]).to eq([false, false, false])
    end

    it "counts characters, not bytes, for line and column" do
      screen = parse("\e[38;5;244m───\n\e[39m❯ \e[2mgo\e[0m\n")
      expect(screen.faint?(1, 1)).to be(false)
      expect([screen.faint?(1, 2), screen.faint?(1, 3), screen.faint?(1, 4)]).to eq([true, true, false])
      expect(screen.faint?(0, 1)).to be(false)
    end
  end

  describe "#proven?" do
    it "is true for lines of understood styling" do
      screen = parse("\e[39m❯ \e[2mgo\e[0m\nplain\n")
      expect([screen.proven?(0), screen.proven?(1)]).to eq([true, true])
    end

    it "is false off the screen" do
      expect(parse("a\n").proven?(4)).to be(false)
    end

    it "ignores a link, on its own line or elsewhere" do
      raw = "see \e]8;;https://e.test\e\\here\e]8;;\e\\\n\e[39m❯ \e[2mgo\e[0m\n"
      screen = parse(raw)
      expect([screen.proven?(0), screen.proven?(1), screen.faint?(1, 2)]).to eq([true, true, true])
    end

    it "leaves a link inside a faint run faint" do
      screen = parse("\e[2ma\e]8;;u\e\\b\e]8;;\e\\c\e[0m\n")
      expect([0, 1, 2].map { |c| screen.faint?(0, c) }).to eq([true, true, true])
    end

    it "makes a line with a shift character unproven and no other" do
      screen = parse("a\u000eqq\u000fb\n\e[2mok\n")
      expect([screen.proven?(0), screen.proven?(1)]).to eq([false, true])
    end

    it "makes a line with an unknown escape unproven and no other" do
      ["\e[2K", "\e[?25h", "\e[3;4H", "\e(0", "\e]0;title\a", "\e=", "\e"].each do |esc|
        screen = parse("a#{esc}b\n\e[2mok\n")
        expect([screen.proven?(0), screen.proven?(1)]).to eq([false, true]), esc.inspect
      end
    end

    it "makes a line with a reverse cell that is not faint unproven" do
      screen = parse("\e[39m❯ \e[7m \e[0m\n\e[2;7mx\e[0m\n")
      expect([screen.proven?(0), screen.proven?(1)]).to eq([false, true])
    end

    it "lets reverse end with 27" do
      expect(parse("\e[7m\e[27m x\n").proven?(0)).to be(true)
    end
  end

  describe "live fixtures" do
    %w[suggestion_export.txt suggestion_send.txt suggestion_with_link.txt].each do |name|
      it "reads the suggestion in #{name} as faint after the prompt glyph" do
        screen = parse(fixture(name))
        line = screen.text.lines.index { |l| l.start_with?("❯ ") }
        text = screen.text.lines[line].chomp
        expect(screen.proven?(line)).to be(true)
        expect(screen.faint?(line, 0)).to be(false)
        expect((2...text.length).all? { |c| screen.faint?(line, c) }).to be(true)
      end
    end

    it "keeps the suggestion line proven with a link on another line" do
      screen = parse(fixture("suggestion_with_link.txt"))
      expect(screen.text.lines.first).to include("example docs")
      expect(screen.text).not_to include("\e")
      expect(screen.proven?(0)).to be(true)
    end

    it "reads an empty input line with no faint cell" do
      screen = parse(fixture("empty_input.txt"))
      line = screen.text.lines.index { |l| l.start_with?("❯") }
      expect(screen.text.lines[line]).to eq("❯\n")
      expect(screen.proven?(line)).to be(true)
      expect(faint_columns(screen, line)).to be_empty
    end

    it "gives the plain screen for every fixture, as capture-pane -p does" do
      Dir[File.join(__dir__, "..", "fixtures", "claude_screens", "*.txt")].each do |path|
        raw = File.read(path)
        plain = raw.gsub(/\e\]8;[^\a\e]*(?:\a|\e\\)/, "").gsub(/\e\[[0-9;:]*m/, "").lines.map(&:rstrip).join("\n") + "\n"
        expect(parse(raw).text).to eq(plain), path
      end
    end
  end
end
