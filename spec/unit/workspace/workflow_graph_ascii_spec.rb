require "spec_helper"

RSpec.describe Workspace::WorkflowGraphAscii do
  {"rpiv" => "rpiv.txt", "rpiv-auto-approve-v2" => "rpiv-auto-approve-v2.txt"}.each do |id, file|
    it "keeps the #{id} diagram as in #{file}" do
      actual = described_class.render(WorkflowGraphGolden.model(id))
      expect(actual).to eq(WorkflowGraphGolden.pin(actual, file))
    end
  end

  it "marks the looped rpiv run as in rpiv-looped.txt" do
    actual = described_class.render(WorkflowGraphGolden.looped_model)
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv-looped.txt"))
  end

  describe "a hostile title" do
    let(:text) { described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::TRICKY).to_h) }

    it "prints no escape character or raw newline inside a box" do
      expect(text).not_to include("\e")
      expect(text).to include('Say "hi"\nthen <b>go</b>\e[31m')
      expect(text.lines).to all(satisfy { |line| line.chomp !~ /[\u0000-\u0008\u000b-\u001f]/ })
    end

    it "gives every loop edge its own lane and label" do
      expect(text).to include("fail: max 2", "reject (or --to an earlier step)", "review_rejected: max_rounds 3")
      expect(text.lines.count { |line| line.start_with?("+", "|") }).to be >= 3
    end
  end

  it "draws a straight line when nothing loops" do
    model = Workspace::WorkflowGraph.build({"steps" => [{"id" => "a"}, {"id" => "b"}]}).to_h
    expect(described_class.render(model)).to eq(<<~TXT)
      (Start)
        |
        v
      +---+
      | a |
      +---+
        |
        v
      +---+
      | b |
      +---+
        |
        v
      (End)
    TXT
  end

  it "draws a fan_out group as indented siblings between a fan-out line and a join line" do
    text = described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::GROUPED).to_h)
    expect(text).to include("(Fan out: Checks, side by side)", "(Join: Checks)  fail: max 2", "    | lint |", "    | test |")
    expect(text.index("| lint |")).to be < text.index("| test |")
    expect(text.lines.map(&:chomp).join("\n")).not_to match(/\| lint \|\n\s*\|\n\s*v\n\s*\+-+\+\n\s*\| test/)
  end

  it "keeps a gated sibling's gate box and its connector inside the group's indent" do
    definition = {"steps" => [step_for("a"), step_for("b", "gate" => "approve")], "groups" => {"g" => {"steps" => %w[a b]}}}
    text = described_class.render(Workspace::WorkflowGraph.build(definition).to_h)
    expect(text).to match(/\| b \|\n\|\s+\+-+\+\n\|\s{8}\|\n\|\s{8}v\n\|\s+\+=+\+\n\+--\s+\| b gate \|/)
    expect(text).to include("(Join: g)")
  end

  def step_for(id, extra = {})
    {"id" => id, "group" => "g"}.merge(extra)
  end

  {"rpiv-auto-approve" => "(Fan out:", "explore-parallel" => "(Fan out:", "rpiv" => "(Start)"}.each do |id, marker|
    it "draws #{id}" do
      text = described_class.render(WorkflowGraphGolden.model(id))
      expect(text).to include("(Start)", "(End)", marker)
      expect(text).to include("(Join:") unless id == "rpiv"
    end
  end
end
