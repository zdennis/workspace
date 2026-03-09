RSpec.describe Workspace::Commands::Repair do
  let(:output) { StringIO.new }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:window_manager) { CLITestHelpers::FakeWindowManager.new }
  let(:iterm) { CLITestHelpers::FakeITerm.new }

  subject(:command) do
    described_class.new(
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      output: output
    )
  end

  describe "#call" do
    it "reports no windows found when none match" do
      command.call
      expect(output.string).to include("No workspace windows found.")
    end

    it "rebuilds state from live workspace windows" do
      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:iterm_windows) do
        {100 => "workspace-proj1 [tmux]", 200 => "workspace-proj2 [tmux]", 300 => "Scooter"}
      end

      fake_iterm = CLITestHelpers::FakeITerm.new
      fake_iterm.define_singleton_method(:session_map) do
        {"uid-a" => "100", "uid-b" => "200"}
      end

      cmd = described_class.new(state: state, iterm: fake_iterm, window_manager: wm, output: output)
      cmd.call

      expect(state["proj1"]).to include("iterm_window_id" => 100, "unique_id" => "uid-a")
      expect(state["proj2"]).to include("iterm_window_id" => 200, "unique_id" => "uid-b")
      expect(state["Scooter"]).to be_nil
      expect(output.string).to include("Repaired 2 project(s).")
    end

    it "preserves existing state entries for non-workspace windows" do
      state["other-proj"] = {"unique_id" => "uid-x", "iterm_window_id" => 999}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:iterm_windows) { {100 => "workspace-proj1"} }

      fake_iterm = CLITestHelpers::FakeITerm.new
      fake_iterm.define_singleton_method(:session_map) { {} }

      cmd = described_class.new(state: state, iterm: fake_iterm, window_manager: wm, output: output)
      cmd.call

      expect(state["other-proj"]).to eq({"unique_id" => "uid-x", "iterm_window_id" => 999})
      expect(state["proj1"]).to include("iterm_window_id" => 100)
    end
  end

  describe "#set_window_id" do
    it "sets the window ID for a project" do
      command.set_window_id("myproject", 12345)
      expect(state["myproject"]["iterm_window_id"]).to eq(12345)
      expect(output.string).to include("Set window_id=12345 for myproject")
    end

    it "preserves existing entry fields" do
      state["myproject"] = {"unique_id" => "uid-1", "iterm_window_id" => 100}
      command.set_window_id("myproject", 200)
      expect(state["myproject"]).to eq({"unique_id" => "uid-1", "iterm_window_id" => 200})
    end
  end
end
