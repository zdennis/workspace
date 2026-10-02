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

  before do
    allow(Process).to receive(:spawn).and_return(999)
    allow(Process).to receive(:detach)
  end

  let(:iterm) { double("iterm") }
  let(:window_manager) { double("window_manager") }
  let(:tmux) { double("tmux") }
  let(:project_config) { double("project_config") }
  let(:window_layout) { double("window_layout") }
  let(:pipeline_config) { double("pipeline_config", stages_for: nil, literal_sentinel_warnings: []) }

  let(:agent_ensurer) do
    Class.new do
      attr_reader :calls
      attr_accessor :result

      def initialize
        @calls = []
        @result = Workspace::Commands::EnsureAgent::Result.new(:started)
      end

      def call(name:, wc_socket: nil)
        @calls << name
        @result
      end
    end.new
  end

  subject(:command) do
    described_class.new(
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      project_config: project_config,
      window_layout: window_layout,
      config: config,
      pipeline_config: pipeline_config,
      agent_ensurer: agent_ensurer,
      sleeper: ->(_seconds) {},
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

      it "drops a saved window id whose window can't be found, keeping the rest of the entry" do
        state["proj1"] = {"unique_id" => "uid-1", "iterm_window_id" => 7}
        state.save
        allow(window_manager).to receive(:iterm_windows).and_return({})

        command.call(["proj1"])

        expect(error_output.string).to include("Could not find windows for: proj1")
        state.load
        expect(state["proj1"]).to eq("unique_id" => "uid-1")
      end

      it "suppresses progress output when quiet: true" do
        command.call(["proj1"], quiet: true)

        expect(output.string).to eq("")
      end

      it "ensures a session monitor daemon for the project" do
        command.call(["proj1"])

        expect(agent_ensurer.calls).to eq(["proj1"])
      end

      it "warns and continues when the daemon can't be started" do
        agent_ensurer.result = Workspace::Commands::EnsureAgent::Result.new(:failed, "No such file or directory - workspace")

        command.call(["proj1"])

        expect(error_output.string).to include("Warning: Could not start session monitor for proj1: No such file or directory - workspace")
        expect(output.string).to include("Done!")
      end

      it "adds no warning of its own when the ensurer already reported an invalid pipeline config" do
        agent_ensurer.result = Workspace::Commands::EnsureAgent::Result.new(:invalid_config)

        command.call(["proj1"])

        expect(error_output.string).not_to include("Could not start session monitor")
      end
    end

    context "when no existing sessions are found" do
      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).with("proj1", reattach: false).and_return("tmuxinator start proj1 --attach")
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        # No session running yet when the pane is created; it appears once
        # tmuxinator starts it, which is what wait_for_tmux_sessions polls for.
        allow(tmux).to receive(:sessions).and_return([], ["proj1"])
        allow(tmux).to receive(:rename_window)
        allow(tmux).to receive(:reattach_or_start) { |session, start| "tmux -CC attach -t #{session} || tmux has-session -t #{session} 2>/dev/null || #{start}" }

        allow(iterm).to receive(:session_map).and_return({})
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(iterm).to receive(:find_launcher_window_id).and_return(nil)
        allow(iterm).to receive(:create_launcher_panes).and_return({"proj1" => "new-uid"})
        allow(window_manager).to receive(:iterm_windows).and_return({300 => "workspace-proj1"})
        allow(window_layout).to receive(:arrange)
      end

      it "creates new panes" do
        command.call(["proj1"])

        expect(iterm).to have_received(:create_launcher_panes).with(["proj1"], {"proj1" => "tmuxinator start proj1 --attach"}, launcher_wid: nil)
        expect(output.string).to include("Creating 1 new launcher pane(s)")
      end

      it "saves state with the new UID" do
        command.call(["proj1"])

        state.load
        expect(state["proj1"]["unique_id"]).to eq("new-uid")
      end

      it "attaches instead of restarting tmuxinator when the session is already running" do
        allow(tmux).to receive(:sessions).and_return(["proj1"])

        result = command.call(["proj1"])

        expect(iterm).to have_received(:create_launcher_panes).with(["proj1"], {"proj1" => "tmux -CC attach -t proj1 || tmux has-session -t proj1 2>/dev/null || tmuxinator start proj1 --attach"}, launcher_wid: nil)
        expect(output.string).to include("Session proj1 is already running for proj1; reusing it.")
        expect(result[:reused]).to eq(["proj1"])
      end

      it "reports no reused sessions when the pane is freshly started" do
        result = command.call(["proj1"])
        expect(result[:reused]).to eq([])
      end

      it "replaces headless state with iTerm state when the project switches modes" do
        state["proj1"] = {"headless" => true}
        state.save
        allow(tmux).to receive(:sessions).and_return(["proj1"])

        command.call(["proj1"])

        state.load
        expect(state["proj1"]).to eq("unique_id" => "new-uid", "iterm_window_id" => 300)
      end
    end

    context "when an existing session disappears during relaunch" do
      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).and_return("tmuxinator start proj1 --attach")
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return([], ["proj1"])
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
    context "with prompts" do
      let(:agent_readiness) { instance_double(Workspace::AgentReadiness, deadline_in: 60.0) }
      let(:ready) { Workspace::AgentReadiness::Result.new(ready: true, pane: "0.1", label: "Claude Code") }

      subject(:command) do
        described_class.new(
          state: state, iterm: iterm, window_manager: window_manager, tmux: tmux,
          project_config: project_config, window_layout: window_layout, config: config,
          pipeline_config: pipeline_config, agent_readiness: agent_readiness, prompt_timeout: 60,
          output: output, error_output: error_output
        )
      end

      def delivery(status)
        Workspace::Tmux::Delivery.new(status: status, message: "tmux says #{status}")
      end

      before do
        allow(project_config).to receive(:exists?).and_return(true)
        allow(tmux).to receive(:start_server)
        allow(tmux).to receive(:command_for).and_return("tmuxinator start --attach")
        allow(tmux).to receive(:session_name_for) { |name| "tmux-#{name}" }
        allow(tmux).to receive(:sessions).and_return(["tmux-proj1", "tmux-proj2"])
        allow(tmux).to receive(:rename_window)
        allow(iterm).to receive(:session_map).and_return({})
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid-1", "proj2" => "uid-2"})
        allow(iterm).to receive(:relaunch_in_session).and_return("ok")
        allow(window_manager).to receive(:iterm_windows).and_return({1 => "workspace-tmux-proj1", 2 => "workspace-tmux-proj2"})
        allow(window_layout).to receive(:arrange)
        allow(config).to receive(:agent_running?).and_return(true)
        allow(command).to receive(:sleep)
        allow(agent_readiness).to receive(:wait).and_return(ready)
        allow(tmux).to receive(:deliver).and_return(delivery(:submitted))
        allow(tmux).to receive(:shows_text?).and_return(false)
      end

      it "waits for each agent, sends its prompt to the agent's pane, and exits 0" do
        result = command.call(["proj1", "proj2"], prompts: {"proj1" => "fix it", "proj2" => "test it"})

        expect(agent_readiness).to have_received(:deadline_in).with(60).once
        expect(agent_readiness).to have_received(:wait).with("tmux-proj1", deadline: 60.0)
        expect(agent_readiness).to have_received(:wait).with("tmux-proj2", deadline: 60.0)
        expect(tmux).to have_received(:deliver).with("tmux-proj1", "0.1", "fix it")
        expect(tmux).to have_received(:deliver).with("tmux-proj2", "0.1", "test it")
        expect(result).to eq(exit_code: 0, prompt_failures: {}, reused: [])
        expect(output.string).to include("Sending prompt to proj1 (Claude Code, pane 0.1)")
        expect(error_output.string).to be_empty
      end

      it "sends nothing and exits 1 when the agent is never ready" do
        allow(agent_readiness).to receive(:wait).with("tmux-proj1", deadline: 60.0)
          .and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "no coding agent is running in tmux session 'tmux-proj1' yet"))

        result = command.call(["proj1", "proj2"], prompts: {"proj1" => "fix it", "proj2" => "test it"})

        expect(tmux).not_to have_received(:deliver).with("tmux-proj1", anything, anything)
        expect(tmux).to have_received(:deliver).with("tmux-proj2", "0.1", "test it")
        expect(result[:exit_code]).to eq(1)
        expect(result[:prompt_failures].keys).to eq(["proj1"])
        expect(error_output.string).to include("Error: prompt not sent to proj1: no coding agent is running in tmux session 'tmux-proj1' yet (waited up to 60s)")
        expect(error_output.string).to include("Error: the prompt was not sent to: proj1")
      end

      it "tries again when the prompt never shows up in the pane, up to three times" do
        allow(tmux).to receive(:deliver).and_return(delivery(:not_landed), delivery(:submitted))

        result = command.call(["proj1"], prompts: {"proj1" => "fix it"})

        expect(tmux).to have_received(:deliver).twice
        expect(agent_readiness).to have_received(:wait).twice
        expect(result[:exit_code]).to eq(0)
        expect(error_output.string).to include("did not arrive (tmux says not_landed); trying again")
      end

      it "presses Enter instead of pasting again when the first paste shows up late" do
        allow(tmux).to receive(:deliver).and_return(delivery(:not_landed), delivery(:submitted))
        allow(tmux).to receive(:shows_text?).with("tmux-proj1", "0.1", "fix it").and_return(true)

        result = command.call(["proj1"], prompts: {"proj1" => "fix it"})

        expect(tmux).to have_received(:deliver).with("tmux-proj1", "0.1", "fix it").once
        expect(tmux).to have_received(:deliver).with("tmux-proj1", "0.1", "")
        expect(result[:exit_code]).to eq(0)
        expect(output.string).to include("The prompt to proj1 arrived late; submitting it")
      end

      it "gives up after three attempts that never show up" do
        allow(tmux).to receive(:deliver).and_return(delivery(:failed))

        result = command.call(["proj1"], prompts: {"proj1" => "fix it"})

        expect(tmux).to have_received(:deliver).exactly(3).times
        expect(result[:prompt_failures]).to eq("proj1" => "tmux says failed")
      end

      it "does not send again, and exits 1, when the prompt landed but may not have been submitted" do
        allow(tmux).to receive(:deliver).and_return(delivery(:unsubmitted))

        result = command.call(["proj1"], prompts: {"proj1" => "fix it"})

        expect(tmux).to have_received(:deliver).once
        expect(result[:exit_code]).to eq(1)
        expect(error_output.string).to include("Error: prompt not sent to proj1: tmux says unsubmitted")
      end

      it "does not wait for agents when there are no prompts" do
        expect(command.call(["proj1"])).to eq(exit_code: 0, prompt_failures: {}, reused: [])
        expect(agent_readiness).not_to have_received(:wait)
      end
    end
  end
end
