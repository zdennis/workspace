require "spec_helper"

RSpec.describe Workspace::AgentDetector do
  let(:tree) { Workspace::ProcessTree::Snapshot.new([]) }

  it "detects like AgentProvider.detect with no aliases" do
    expect(described_class.new.call(command: "claude", pid: 1, tree: tree)).to eq(provider: Workspace::AgentProvider.find("claude"), pid: 1)
    expect(described_class.new.call(command: "claude-dev", pid: 1, tree: tree)).to be_nil
    expect(described_class.new).not_to be_aliases
  end

  it "knows the aliases it was made with" do
    detector = described_class.new(aliases: {"claude" => ["claude-dev"]})

    expect(detector.call(command: "claude-dev", pid: 1, tree: tree)).to eq(provider: Workspace::AgentProvider.find("claude"), pid: 1)
    expect(detector).to be_aliases
  end
end
