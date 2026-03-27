require "tmpdir"

RSpec.describe Workspace::Commands::Launch do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:event_log_file) { File.join(tmpdir, "events.jsonl") }
  let(:state) do
    allow(config).to receive(:state_file).and_return(state_file)
    allow(config).to receive(:event_log_file).and_return(event_log_file)
    event_log = Workspace::EventLog.new(config: config)
    Workspace::State.new(config: config, event_log: event_log)
  end
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  let(:iterm) { double("iterm") }
  let(:window_manager) { double("window_manager") }
  let(:tmux) { double("tmux") }
  let(:project_config) { double("project_config") }
  let(:window_layout) { double("window_layout") }

  subject(:command) do
    described_class.new(
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      project_config: project_config,
      window_layout: window_layout,
      output: output,
      error_output: error_output
    )
  end

  describe "#call" do
    it "raises Workspace::Error when a config is missing" do
      allow(project_config).to receive(:exists?).with("missing-project").and_return(false)
      allow(project_config).to receive(:config_path_for).with("missing-project").and_return("/path/to/missing-project.yml")

      expect { command.call(["missing-project"]) }.to raise_error(
        Workspace::Error, /No tmuxinator config found for.*expected.*missing-project\.yml/m
      )
    end

    context "when existing sessions are found" do
      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).with("proj1", reattach: false).and_return("tmuxinator start proj1 --attach")
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:rename_window)

        # State has existing session
        state["proj1"] = {"unique_id" => "uid-1"}
        state.save

        allow(iterm).to receive(:session_map).and_return({"uid-1" => "100"})
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid-1"})
        allow(iterm).to receive(:relaunch_in_session).with("uid-1", "tmuxinator start proj1 --attach").and_return("ok")
        allow(iterm).to receive(:find_launcher_window_id).and_return(nil)
        allow(window_manager).to receive(:iterm_windows).and_return({200 => "workspace-proj1"})
        allow(window_layout).to receive(:arrange)
      end

      it "reuses existing panes instead of creating new ones" do
        command.call(["proj1"])

        expect(iterm).to have_received(:relaunch_in_session).with("uid-1", "tmuxinator start proj1 --attach")
        expect(output.string).to include("Reusing existing pane for proj1")
        expect(output.string).not_to include("Creating")
      end
    end

    context "when no existing sessions are found" do
      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).with("proj1", reattach: false).and_return("tmuxinator start proj1 --attach")
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:rename_window)

        allow(iterm).to receive(:session_map).and_return({})
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(iterm).to receive(:find_launcher_window_id).and_return(nil)
        allow(iterm).to receive(:create_launcher_panes).and_return({"proj1" => "new-uid"})
        allow(window_manager).to receive(:iterm_windows).and_return({300 => "workspace-proj1"})
        allow(window_layout).to receive(:arrange)
      end

      it "creates new panes" do
        command.call(["proj1"])

        expect(iterm).to have_received(:create_launcher_panes)
        expect(output.string).to include("Creating 1 new launcher pane(s)")
      end

      it "saves state with the new UID" do
        command.call(["proj1"])

        state.load
        expect(state["proj1"]["unique_id"]).to eq("new-uid")
      end
    end

    context "when an existing session disappears during relaunch" do
      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).and_return("tmuxinator start proj1 --attach")
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:rename_window)

        state["proj1"] = {"unique_id" => "old-uid"}
        state.save

        allow(iterm).to receive(:session_map).and_return({"old-uid" => "100"})
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "old-uid"})
        allow(iterm).to receive(:relaunch_in_session).and_return("not_found")
        allow(iterm).to receive(:find_launcher_window_id).and_return(nil)
        allow(iterm).to receive(:create_launcher_panes).and_return({"proj1" => "new-uid"})
        allow(window_manager).to receive(:iterm_windows).and_return({400 => "workspace-proj1"})
        allow(window_layout).to receive(:arrange)
      end

      it "falls through to creating a new pane" do
        command.call(["proj1"])

        expect(iterm).to have_received(:create_launcher_panes)
        expect(error_output.string).to include("disappeared")
      end
    end
  end
end
