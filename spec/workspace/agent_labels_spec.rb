require "spec_helper"

RSpec.describe Workspace::AgentLabels do
  let(:snapshot) { double("snapshot", find_descendant: nil) }
  let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: snapshot) }

  it "labels panes by index for the agents the providers recognize" do
    details = [
      {index: 0, pid: 1, command: "zsh"},
      {index: 1, pid: 2, command: "codex"}
    ]
    expect(described_class.new(process_tree: process_tree).by_index(details)).to eq(1 => "Codex")
  end

  it "reads no process table for no panes" do
    expect(process_tree).not_to receive(:snapshot)
    expect(described_class.new(process_tree: process_tree).by_index([])).to eq({})
  end

  it "returns no labels when the process table cannot be read" do
    allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")
    expect(described_class.new(process_tree: process_tree).by_index([{index: 0, pid: 1, command: "codex"}])).to eq({})
  end
end
