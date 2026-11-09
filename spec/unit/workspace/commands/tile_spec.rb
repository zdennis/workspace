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

      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100, 200, 300, 400]))
      wl = RecordingWindowLayout.new

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("myproject")

      expect(wl.tiled_entries.size).to eq(3)
      expect(wl.tiled_entries.map { |e| e[:project] }).to eq(
        ["myproject", "myproject.worktree-feat-1", "myproject.worktree-feat-2"]
      )
      expect(output.string).to include("Tiling 3 window(s)")
    end

    it "does not match projects that only share a prefix" do
      state["my"] = {"iterm_window_id" => 100}
      state["myproject"] = {"iterm_window_id" => 200}

      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100, 200]))
      wl = RecordingWindowLayout.new

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("my")

      expect(wl.tiled_entries.size).to eq(1)
      expect(wl.tiled_entries.first[:project]).to eq("my")
    end

    it "focuses all matched windows" do
      state["myproject"] = {"iterm_window_id" => 100}
      state["myproject.worktree-feat-1"] = {"iterm_window_id" => 200}

      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100, 200]))
      wl = RecordingWindowLayout.new

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call("myproject")

      expect(wm.focused_ids).to contain_exactly(100, 200)
    end

    it "never runs the focus chain" do
      state["myproject"] = {"iterm_window_id" => 100}
      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100]), forbid_focus_steps: true)
      wl = RecordingWindowLayout.new

      expect { described_class.new(state: state, window_manager: wm, window_layout: wl, output: output).call("myproject") }.not_to raise_error
    end
  end

  describe "#call_all" do
    it "raises error when no active windows found" do
      expect { command.call_all }.to raise_error(
        Workspace::Error, /No active workspace windows found/
      )
    end

    it "tiles all active projects" do
      state["project-a"] = {"iterm_window_id" => 100}
      state["project-b"] = {"iterm_window_id" => 200}
      state["project-c"] = {"iterm_window_id" => 300}

      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100, 200, 300]))
      wl = RecordingWindowLayout.new

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call_all

      expect(wl.tiled_entries.size).to eq(3)
      expect(wl.tiled_entries.map { |e| e[:project] }).to eq(
        ["project-a", "project-b", "project-c"]
      )
      expect(output.string).to include("Tiling 3 window(s)")
    end

    it "only includes projects with live windows" do
      state["alive"] = {"iterm_window_id" => 100}
      state["dead"] = {"iterm_window_id" => 200}

      wm = ConfiguredWindowManager.new(live_window_ids: Set.new([100]))
      wl = RecordingWindowLayout.new

      cmd = described_class.new(
        state: state, window_manager: wm, window_layout: wl, output: output
      )
      cmd.call_all

      expect(wl.tiled_entries.size).to eq(1)
      expect(wl.tiled_entries.first[:project]).to eq("alive")
    end
  end

  describe "headless projects" do
    it "explains that a headless-only project has no windows, without asking window-tool" do
      state["proj"] = {"headless" => true}
      state["proj.worktree-a"] = {"headless" => true}
      expect(window_manager).not_to receive(:live_window_ids)

      expect { command.call("proj") }.to raise_error(Workspace::Error, /run headless \(no iTerm windows\)/)
    end

    it "tiles the windowed projects and leaves headless ones out" do
      state["proj"] = {"iterm_window_id" => 100}
      state["proj.worktree-a"] = {"headless" => true}
      allow(window_manager).to receive(:live_window_ids).and_return(Set[100])

      command.call("proj")

      expect(output.string).to include("Tiling 1 window(s) for proj")
    end

    it "notes headless workspaces when tiling everything finds no windows" do
      state["proj"] = {"headless" => true}
      expect(window_manager).not_to receive(:live_window_ids)

      expect { command.call_all }.to raise_error(Workspace::Error, /headless workspaces have no windows/)
    end
  end
end
