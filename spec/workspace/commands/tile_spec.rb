RSpec.describe Workspace::Commands::Tile do
  let(:output) { StringIO.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:window_manager) { CLITestHelpers::FakeWindowManager.new }
  let(:window_layout) { CLITestHelpers::FakeWindowLayout.new }

  subject(:command) do
    described_class.new(
      state: state,
      window_manager: window_manager,
      window_layout: window_layout,
      output: output
    )
  end

  describe "#call" do
    it "raises error when no matching windows found" do
      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /No active windows found/
      )
    end

    it "raises error when matching projects have no live windows" do
      state["myproject"] = {"iterm_window_id" => 100}
      # live_window_ids returns empty Set by default

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /No active windows found/
      )
    end

    it "tiles base project and worktree windows" do
      state["myproject"] = {"iterm_window_id" => 100}
      state["myproject.worktree-feat-1"] = {"iterm_window_id" => 200}
      state["myproject.worktree-feat-2"] = {"iterm_window_id" => 300}
      state["other-project"] = {"iterm_window_id" => 400}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 200, 300, 400]) }

      tiled_entries = nil
      wl = CLITestHelpers::FakeWindowLayout.new
      wl.define_singleton_method(:tile) { |entries| tiled_entries = entries }

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("myproject")

      expect(tiled_entries.size).to eq(3)
      expect(tiled_entries.map { |e| e[:project] }).to eq(
        ["myproject", "myproject.worktree-feat-1", "myproject.worktree-feat-2"]
      )
      expect(output.string).to include("Tiling 3 window(s)")
    end

    it "does not match projects that only share a prefix" do
      state["my"] = {"iterm_window_id" => 100}
      state["myproject"] = {"iterm_window_id" => 200}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 200]) }

      tiled_entries = nil
      wl = CLITestHelpers::FakeWindowLayout.new
      wl.define_singleton_method(:tile) { |entries| tiled_entries = entries }

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("my")

      expect(tiled_entries.size).to eq(1)
      expect(tiled_entries.first[:project]).to eq("my")
    end

    it "focuses all matched windows" do
      state["myproject"] = {"iterm_window_id" => 100}
      state["myproject.worktree-feat-1"] = {"iterm_window_id" => 200}

      focused_ids = []
      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 200]) }
      wm.define_singleton_method(:focus_by_id) { |wid|
        focused_ids << wid
        true
      }

      wl = CLITestHelpers::FakeWindowLayout.new
      wl.define_singleton_method(:tile) { |_| }

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("myproject")

      expect(focused_ids).to contain_exactly(100, 200)
    end
  end
end
