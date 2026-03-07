require "tmpdir"

RSpec.describe Workspace::Commands::Kill do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:state) do
    s = Workspace::State.new(config: config)
    allow(config).to receive(:state_file).and_return(state_file)
    s
  end
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:iterm) { double("iterm") }
  let(:window_manager) { double("window_manager") }
  let(:tmux) { double("tmux") }

  subject(:command) do
    described_class.new(
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      output: output,
      error_output: error_output
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "returns empty array when state is empty" do
      result = command.call
      expect(result).to eq([])
      expect(output.string).to include("No active workspace projects")
    end

    context "with active projects" do
      before do
        state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state["proj2"] = {"unique_id" => "uid2", "iterm_window_id" => 200}
        state.save
      end

      it "kills tmux sessions for specified projects" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        result = command.call(["proj1"])

        expect(tmux).to have_received(:kill_session).with("proj1")
        expect(result).to eq(["proj1"])
      end

      it "resolves tmux session name before killing" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("custom-session")
        allow(tmux).to receive(:sessions).and_return(["custom-session"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        expect(tmux).to have_received(:kill_session).with("custom-session")
      end

      it "returns killed project names" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        result = command.call(["proj1", "proj2"])
        expect(result).to contain_exactly("proj1", "proj2")
      end

      it "kills all projects when none specified" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        result = command.call
        expect(result).to contain_exactly("proj1", "proj2")
      end

      it "removes killed projects from state" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        state.load
        expect(state["proj1"]).to be_nil
        expect(state["proj2"]).not_to be_nil
      end

      it "warns about unknown projects" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:sessions).and_return([])

        command.call(["unknown-project"])

        expect(error_output.string).to include("Warning: 'unknown-project' is not an active workspace project")
      end
    end

    context "launcher window cleanup" do
      before do
        state["proj1"] = {"unique_id" => "uid1"}
        state["proj2"] = {"unique_id" => "uid2"}
        state.save
      end

      it "preserves launcher window when other projects still use it" do
        live_sessions = {"uid1" => "win-100", "uid2" => "win-100"}
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid1", "proj2" => "uid2"})
        allow(iterm).to receive(:session_map).and_return(live_sessions)
        allow(window_manager).to receive(:close_window)
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        # Should NOT close the window because proj2 is still in it
        expect(window_manager).not_to have_received(:close_window)
      end

      it "closes launcher window when all its projects are killed" do
        live_sessions = {"uid1" => "win-100", "uid2" => "win-100"}
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid1", "proj2" => "uid2"})
        allow(iterm).to receive(:session_map).and_return(live_sessions)
        allow(window_manager).to receive(:close_window)
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1", "proj2"])

        expect(window_manager).to have_received(:close_window).with("win-100")
      end
    end
  end
end
