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

    it "chains highlight command when highlight color given" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(
        config.window_tool, "focus", "id=42",
        "+", "highlight", "id=42", "--color", "green"
      ).and_return(["", "", status])

      expect(manager.focus_by_id(42, highlight: "green")).to be true
    end

    it "chains highlight with custom color" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(
        config.window_tool, "focus", "id=42",
        "+", "highlight", "id=42", "--color", "red"
      ).and_return(["", "", status])

      expect(manager.focus_by_id(42, highlight: "red")).to be true
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
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return([json, "", status])

      expect(manager.live_window_ids).to eq(Set.new([100, 200]))
    end

    it "raises Workspace::Error when window-tool fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return(["", "", status])

      expect { manager.live_window_ids }.to raise_error(Workspace::Error, /window-tool list failed/)
    end
  end

  describe "#all_window_bounds" do
    it "returns bounds for requested window IDs in a single call" do
      json = '[{"window_id": 100, "x": 10, "y": 20, "width": 800, "height": 600}, {"window_id": 200, "x": 50, "y": 60, "width": 400, "height": 300}, {"window_id": 300, "x": 0, "y": 0, "width": 100, "height": 100}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return([json, "", status])

      result = manager.all_window_bounds([100, 200])

      expect(result[100]).to eq({x: 10, y: 20, width: 800, height: 600})
      expect(result[200]).to eq({x: 50, y: 60, width: 400, height: 300})
      expect(result.key?(300)).to be false
    end

    it "returns empty hash when window-tool fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return(["", "", status])

      expect(manager.all_window_bounds([100])).to eq({})
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
