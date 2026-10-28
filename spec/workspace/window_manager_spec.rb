require "open3"

RSpec.describe Workspace::WindowManager do
  let(:config) { Workspace::Config.new }
  subject(:manager) { described_class.new(config: config) }

  describe "#close_window" do
    it "runs the close script through the bounded runner" do
      runner = double("osascript")
      allow(runner).to receive(:call).and_return(Workspace::OsascriptRunner::Result.new("", true, false))

      expect(described_class.new(config: config, osascript: runner).close_window(42)).to be true
      expect(runner).to have_received(:call).with(/close \(window id 42\)/)
    end

    it "returns false when iTerm2 does not answer in time" do
      runner = double("osascript", call: Workspace::OsascriptRunner::Result.new("", false, true))

      expect(described_class.new(config: config, osascript: runner).close_window(42)).to be false
    end
  end

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

  describe "#window_ids_front_to_back" do
    it "keeps window-tool's order" do
      json = '[{"window_id": 200}, {"window_id": 100}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return([json, "", status])

      expect(manager.window_ids_front_to_back).to eq([200, 100])
    end

    it "raises Workspace::Error when window-tool fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return(["", "", status])

      expect { manager.window_ids_front_to_back }.to raise_error(Workspace::Error, /window-tool list failed/)
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

  describe "#screens" do
    it "returns each screen's full frame and its visible area" do
      json = '[{"frame_x": 0, "frame_y": 0, "frame_width": 1728, "frame_height": 1117, "visible_x": 0, "visible_y": 25, "visible_width": 1728, "visible_height": 1057}, {"frame_x": -1920, "frame_y": 0, "frame_width": 1920, "frame_height": 1080, "visible_x": -1920, "visible_y": 25, "visible_width": 1920, "visible_height": 1020}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return([json, "", status])

      expect(manager.screens).to eq([
        {x: 0, y: 0, width: 1728, height: 1117, visible_x: 0, visible_y: 25, visible_width: 1728, visible_height: 1057},
        {x: -1920, y: 0, width: 1920, height: 1080, visible_x: -1920, visible_y: 25, visible_width: 1920, visible_height: 1020}
      ])
    end

    it "falls back to the full frame for the visible area when the screen reports none" do
      json = '[{"frame_x": 0, "frame_y": 0, "frame_width": 1728, "frame_height": 1117, "visible_width": 1728}, {"frame_x": -1920, "frame_y": 0, "frame_width": 1920, "frame_height": 1080}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return([json, "", status])

      expect(manager.screens).to eq([
        {x: 0, y: 0, width: 1728, height: 1117, visible_x: 0, visible_y: 0, visible_width: 1728, visible_height: 1117},
        {x: -1920, y: 0, width: 1920, height: 1080, visible_x: -1920, visible_y: 0, visible_width: 1920, visible_height: 1080}
      ])
    end

    it "returns an empty list when window-tool fails" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return(["", "", status])

      expect(manager.screens).to eq([])
    end

    it "returns an empty list for JSON that is not a list of screens" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return(["{}", "", status])

      expect(manager.screens).to eq([])
    end

    it "returns an empty list for output it cannot read" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return(["nope", "", status])

      expect(manager.screens).to eq([])
    end
  end

  describe "#set_window_bounds" do
    it "calls window-tool move with id= and coordinates" do
      allow(manager).to receive(:system).and_return(true)

      manager.set_window_bounds(42, 100, 50, 800, 600)

      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "100", "50", "800", "600")
    end
  end

  describe "#center_window" do
    def stub_bounds_and_screens(list_json, screens_json)
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return([list_json, "", status])
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return([screens_json, "", status])
      allow(manager).to receive(:system).and_return(true)
    end

    it "moves the window to the middle of its screen's visible area, keeping its size" do
      stub_bounds_and_screens(
        '[{"window_id": 42, "x": 110, "y": 60, "width": 800, "height": 600}]',
        '[{"frame_x": 0, "frame_y": 0, "frame_width": 1920, "frame_height": 1080, "visible_x": 0, "visible_y": 25, "visible_width": 1920, "visible_height": 1055}]'
      )

      expect(manager.center_window(42)).to eq([560, 252])
      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "560", "252", "800", "600")
    end

    it "returns false when the window is gone" do
      stub_bounds_and_screens("[]", '[{"frame_x": 0, "frame_y": 0, "frame_width": 1920, "frame_height": 1080}]')

      expect(manager.center_window(42)).to be false
      expect(manager).not_to have_received(:system)
    end

    it "returns false when there are no screens" do
      stub_bounds_and_screens(
        '[{"window_id": 42, "x": 0, "y": 0, "width": 800, "height": 600}]',
        "[]"
      )

      expect(manager.center_window(42)).to be false
      expect(manager).not_to have_received(:system)
    end

    it "returns false when the screens cannot be read" do
      status = instance_double(Process::Status, success?: false)
      list_status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with(config.window_tool, "list", "--app", "iTerm2", "--json").and_return(['[{"window_id": 42, "x": 0, "y": 0, "width": 800, "height": 600}]', "", list_status])
      allow(Open3).to receive(:capture3).with(config.window_tool, "screens", "--json").and_return(["", "", status])
      allow(manager).to receive(:system).and_return(true)

      expect(manager.center_window(42)).to be false
      expect(manager).not_to have_received(:system)
    end

    it "returns false when the move fails" do
      stub_bounds_and_screens(
        '[{"window_id": 42, "x": 110, "y": 60, "width": 800, "height": 600}]',
        '[{"frame_x": 0, "frame_y": 0, "frame_width": 1920, "frame_height": 1080, "visible_x": 0, "visible_y": 25, "visible_width": 1920, "visible_height": 1055}]'
      )
      allow(manager).to receive(:system).and_return(false)

      expect(manager.center_window(42)).to be false
      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "560", "252", "800", "600")
    end

    it "picks the screen holding the window's center over the one it shares more area with" do
      stub_bounds_and_screens(
        '[{"window_id": 42, "x": -500, "y": 100, "width": 2600, "height": 800}]',
        '[{"frame_x": 0, "frame_y": 0, "frame_width": 1000, "frame_height": 1000}, {"frame_x": 1000, "frame_y": 0, "frame_width": 1000, "frame_height": 1000}]'
      )

      # The window's center (800) is on the first screen, though more of it lies on the second.
      expect(manager.center_window(42)).to eq([-800, 100])
      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "-800", "100", "2600", "800")
    end

    it "picks the screen with the largest overlap when no screen holds the window's center" do
      stub_bounds_and_screens(
        '[{"window_id": 42, "x": 950, "y": 300, "width": 300, "height": 400}]',
        '[{"frame_x": 0, "frame_y": 0, "frame_width": 1000, "frame_height": 1000}, {"frame_x": 1100, "frame_y": 0, "frame_width": 1000, "frame_height": 1000}]'
      )

      # The window's center (1100) sits between the screens; it shares more of the second.
      expect(manager.center_window(42)).to eq([1450, 300])
      expect(manager).to have_received(:system).with(config.window_tool, "move", "id=42", "1450", "300", "300", "400")
    end
  end

  describe ".center_position" do
    it "centers on the visible area" do
      position = described_class.center_position(
        bounds: {x: 110, y: 60, width: 800, height: 600},
        screen: {x: 0, y: 0, width: 1920, height: 1080, visible_x: 0, visible_y: 25, visible_width: 1920, visible_height: 1055}
      )

      expect(position).to eq([560, 252])
    end

    it "falls back to the full frame without visible values" do
      position = described_class.center_position(
        bounds: {x: 0, y: 0, width: 800, height: 600},
        screen: {x: 100, y: 50, width: 1920, height: 1080}
      )

      expect(position).to eq([660, 290])
    end
  end

  describe "without window-tool" do
    before { allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "window-tool") }

    it "reports no windows and a failed focus instead of raising" do
      expect(manager.iterm_windows).to eq({})
      expect(manager.focus_by_id(1)).to be false
    end

    it "raises a workspace error from live_window_ids" do
      expect { manager.live_window_ids }.to raise_error(Workspace::Error, /window-tool list failed/)
    end
  end

  describe "#find_window_by_title" do
    before do
      json = '[{"window_id": 1, "title": "workspace-Notes [claude]"}, {"window_id": 2, "title": "workspace-notesy"}]'
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return([json, "", status])
    end

    it "matches a window title ignoring case" do
      expect(manager.find_window_by_title("workspace-notes")).to eq("1")
    end

    it "still wants the whole name" do
      expect(manager.find_window_by_title("workspace-note")).to be_nil
    end
  end
end
