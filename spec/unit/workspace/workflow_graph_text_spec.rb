require "spec_helper"

RSpec.describe Workspace::WorkflowGraphText do
  describe ".node_title" do
    it "is the title alone for a node with no origin and no state" do
      expect(described_class.node_title({"title" => "Plan", "annotations" => {}})).to eq("Plan")
    end

    it "names the extends: parent a step came from" do
      expect(described_class.node_title({"title" => "Research", "annotations" => {"origin" => "rpiv"}})).to eq("Research (from rpiv)")
    end

    it "puts the origin before a run's state" do
      node = {"title" => "Implement", "annotations" => {"origin" => "rpiv"}, "state" => "passed", "passes" => 3, "attempts" => 3}
      expect(described_class.node_title(node)).to eq("Implement (from rpiv) [passed x3]")
    end
  end
end
