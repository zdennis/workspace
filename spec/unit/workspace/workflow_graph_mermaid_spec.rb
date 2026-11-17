require "spec_helper"

RSpec.describe Workspace::WorkflowGraphMermaid do
  let(:tricky) { Workspace::WorkflowGraph.build(WorkflowGraphGolden::TRICKY).to_h }

  it "keeps the rpiv diagram as in rpiv.mmd" do
    actual = described_class.render(WorkflowGraphGolden.model("rpiv"))
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv.mmd"))
  end

  describe "ids" do
    let(:text) { described_class.render(tricky) }
    let(:declared) { text.scan(/^    state ".*" as (\S+)$/).flatten }
    let(:endpoints) { text.scan(/^    (\S+) --> (\S+?)(?: :.*)?$/).flatten }

    it "writes only generated ids or [*]" do
      expect(declared).to all(match(/\A[A-Za-z_][A-Za-z0-9_]*\z/))
      expect(declared.size).to eq(tricky["nodes"].size - 2)
    end

    it "ends every edge at a declared state or [*]" do
      expect(endpoints).not_to be_empty
      expect(endpoints - declared - ["[*]"]).to be_empty
    end

    it "draws the terminals as [*]" do
      expect(text).to include("[*] --> n0")
      expect(text).to match(/^    n4 --> \[\*\]$/)
    end
  end

  describe "quoting" do
    let(:text) { described_class.render(tricky) }

    it "turns a quote into #quot; and leaves no bare quote inside a label" do
      expect(text).to include("Say #quot;hi#quot;")
      expect(text.scan(/^    state (".*") as \S+$/).flatten).to all(match(/\A"[^"]*"\z/))
    end

    it "keeps a newline, angle brackets and an escape out of a label" do
      line = text.lines.find { |l| l.include?("Say") }
      expect(line).to include('Say #quot;hi#quot; then bgo/b\e[31m')
      expect(text.scan(/"[^"]*"|: .*/).join).not_to match(/[<>]/)
      expect(text).not_to include("\e")
    end

    it "turns a semicolon into #59; so it cannot end a statement" do
      semi = {"nodes" => [{"id" => "a", "kind" => "step", "title" => "one; two", "annotations" => {}}], "edges" => [], "legend" => {}}
      expect(described_class.render(semi)).to include('state "one#59; two" as n0')
    end

    it "attaches the legend note to a state" do
      expect(text).to include("    note right of n0\n        max_attempts 4\n    end note\n")
    end
  end
end
