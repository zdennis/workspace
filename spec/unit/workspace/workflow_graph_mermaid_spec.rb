require "spec_helper"

RSpec.describe Workspace::WorkflowGraphMermaid do
  let(:tricky) { Workspace::WorkflowGraph.build(WorkflowGraphGolden::TRICKY).to_h }

  it "keeps the rpiv diagram as in rpiv.mmd" do
    actual = described_class.render(WorkflowGraphGolden.model("rpiv"))
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv.mmd"))
  end

  it "marks the looped rpiv run as in rpiv-looped.mmd" do
    actual = described_class.render(WorkflowGraphGolden.looped_model)
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv-looped.mmd"))
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

  it "draws a fan_out group as a fork and a join with its goto as a loop edge" do
    text = described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::GROUPED).to_h)
    expect(text).to include("state n1 <<fork>>", "state n4 <<join>>", "n1 --> n2", "n1 --> n3", "n2 --> n4", "n3 --> n4", "n4 --> n0 : fail: max 2", "n2 --> n3 : fail: max 1")
  end

  it "runs a gated sibling through its gate to the join and keeps its reject loop inside the group" do
    definition = {"steps" => [{"id" => "a", "group" => "g"}, {"id" => "b", "group" => "g", "gate" => "approve"}], "groups" => {"g" => {"steps" => %w[a b]}}}
    text = described_class.render(Workspace::WorkflowGraph.build(definition).to_h)
    expect(text).to include("state n0 <<fork>>", "state \"b gate\" as n3", "state n4 <<join>>", "n0 --> n2", "n2 --> n3", "n3 --> n4", "n3 --> n2 : reject")
    expect(text).not_to include("n2 --> n4")
  end

  it "draws a group's fork and join with no state and shows the loops on a marked run's join edge" do
    plain = described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::GROUPED).to_h)
    expect(plain).to include("<<fork>>", "<<join>>")
    marked = described_class.render(WorkflowGraphGolden.grouped_run_model)
    expect(marked).to include("<<fork>>", "<<join>>", "n4 --> n0 : fail: max 2 (looped 2)")
  end

  %w[rpiv-auto-approve explore-parallel rpiv].each do |id|
    it "draws #{id}" do
      text = described_class.render(WorkflowGraphGolden.model(id))
      expect(text).to start_with("stateDiagram-v2\n")
      expect(text).to include("<<fork>>", "<<join>>") unless id == "rpiv"
    end
  end
end
