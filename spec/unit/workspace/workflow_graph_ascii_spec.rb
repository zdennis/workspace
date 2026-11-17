require "spec_helper"

RSpec.describe Workspace::WorkflowGraphAscii do
  {"rpiv" => "rpiv.txt", "rpiv-auto-approve-v2" => "rpiv-auto-approve-v2.txt"}.each do |id, file|
    it "keeps the #{id} diagram as in #{file}" do
      actual = described_class.render(WorkflowGraphGolden.model(id))
      expect(actual).to eq(WorkflowGraphGolden.pin(actual, file))
    end
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
end
