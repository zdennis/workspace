require "open3"

RSpec.describe Workspace::WindowManager do
  let(:config) { Workspace::Config.new }
  subject(:manager) { described_class.new(config: config) }

  describe "#focus_by_id" do
    it "returns true on success" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "focus", "id=42").and_return(["", "", status])

      expect(manager.focus_by_id(42)).to be true
    end

    it "returns false on failure" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "focus", "id=99").and_return(["", "", status])

      expect(manager.focus_by_id(99)).to be false
    end
  end

  describe "#shake_by_id" do
    it "returns true on success" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "shake", "id=42").and_return(["", "", status])

      expect(manager.shake_by_id(42)).to be true
    end

    it "returns false on failure" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "shake", "id=99").and_return(["", "", status])

      expect(manager.shake_by_id(99)).to be false
    end
  end

  describe "#live_window_ids" do
    it "returns a set of integer window IDs" do
      json = '[{"window_id": 100, "title": "foo"}, {"window_id": 200, "title": "bar"}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--json").and_return([json, "", status])

      expect(manager.live_window_ids).to eq(Set.new([100, 200]))
    end

    it "raises Workspace::Error when window-tool fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--json").and_return(["", "", status])

      expect { manager.live_window_ids }.to raise_error(Workspace::Error, /window-tool list failed/)
    end
  end

  describe "#set_window_bounds" do
    it "calls window-tool move with id= and coordinates" do
      allow(manager).to receive(:system).and_return(true)

      manager.set_window_bounds(42, 100, 50, 800, 600)

      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "100", "50", "800", "600")
    end
  end
end
