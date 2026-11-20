require "spec_helper"

RSpec.describe Workspace::WorkflowGraphDot do
  let(:tricky) { Workspace::WorkflowGraph.build(WorkflowGraphGolden::TRICKY).to_h }
  let(:text) { described_class.render(tricky) }
  let(:quoted) { /"(?:[^"\\]|\\.)*"/ }

  it "keeps the rpiv digraph as in rpiv.dot" do
    actual = described_class.render(WorkflowGraphGolden.model("rpiv"))
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv.dot"))
  end

  it "marks the looped rpiv run as in rpiv-looped.dot" do
    actual = described_class.render(WorkflowGraphGolden.looped_model)
    expect(actual).to eq(WorkflowGraphGolden.pin(actual, "rpiv-looped.dot"))
  end

  it "double-quotes every id in node and edge statements" do
    nodes = text.scan(/^  (#{quoted}) \[/).flatten
    edges = text.scan(/^  (#{quoted}) -> (#{quoted})/).flatten
    expect(nodes).to include('".start"', '"ci-run"', '"ci-run.gate"', '"end.review"', '"start"', '"end"')
    expect(edges.size).to eq(tricky["edges"].size * 2)
    expect(edges - nodes).to be_empty
  end

  it "shapes terminals, gates and reviews" do
    expect(text).to include('".start" [shape=point];', '".end" [shape=doublecircle, label=""];')
    expect(text).to match(/"ci-run\.gate" \[shape=diamond/)
    expect(text).to match(/"end\.review" \[shape=box, peripheries=2/)
  end

  it "dashes loop edges with their label and puts the legend in the graph label" do
    expect(text).to include('"ci-run" -> "start" [style=dashed, label="fail: max 2"];')
    expect(text).to include('label="max_attempts 4";')
  end

  it "escapes quotes, backslashes and newlines" do
    expect(text).to include('label="Say \\"hi\\"\\nthen <b>go</b>\\\\e[31m"')
    expect(text).not_to include("\e")
    escaped = described_class.render({"nodes" => [{"id" => "a\\b\"c", "kind" => "step", "title" => "t", "annotations" => {}}], "edges" => [], "legend" => {}})
    expect(escaped).to include('"a\\\\b\\"c" [shape=box, label="t"];')
  end

  it "draws a fan_out group as a dashed cluster between a fork and a join point" do
    text = described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::GROUPED).to_h)
    expect(text).to include('subgraph "cluster_checks" {', 'label="Fan out: Checks";', '"checks.join" -> "plan" [style=dashed, label="fail: max 2"]')
    expect(text).to match(/"cluster_checks" \{.*"lint".*"test".*\}\n  "checks.group" \[shape=point\]/m)
  end

  it "puts a gated sibling's gate in its group's cluster" do
    definition = {"steps" => [{"id" => "a", "group" => "g"}, {"id" => "b", "group" => "g", "gate" => "approve"}], "groups" => {"g" => {"steps" => %w[a b]}}}
    text = described_class.render(Workspace::WorkflowGraph.build(definition).to_h)
    expect(text).to match(/"cluster_g" \{.*"b\.gate" \[shape=diamond.*\n  \}\n/m)
  end

  it "draws a group's fork and join with no state and shows the loops on a marked run's join edge" do
    plain = described_class.render(Workspace::WorkflowGraph.build(WorkflowGraphGolden::GROUPED).to_h)
    expect(plain).to include('"checks.group" [shape=point];', '"checks.join" [shape=point];')
    marked = described_class.render(WorkflowGraphGolden.grouped_run_model)
    expect(marked).to include('"checks.group" [shape=point];', '"checks.join" -> "plan" [style=dashed, label="fail: max 2 (looped 2)"]')
  end

  %w[rpiv-auto-approve explore-parallel rpiv].each do |id|
    it "draws #{id}" do
      text = described_class.render(WorkflowGraphGolden.model(id))
      expect(text).to start_with("digraph workflow {\n")
      expect(text).to include("subgraph \"cluster_") unless id == "rpiv"
    end
  end
end
