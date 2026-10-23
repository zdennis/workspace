require "spec_helper"

RSpec.describe Workspace::PaneDispatch do
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:sender) { instance_double(Workspace::Commands::Send) }
  let(:binder) { instance_double(Workspace::Commands::Binding, live: nil, bind: {}) }
  let(:library) { Workspace::Library.allocate }
  let(:runner) { instance_double(Workspace::Commands::Run, call: "%23") }
  let(:main_agent) { instance_double(Workspace::MainAgent, spawn_command: "claude") }
  let(:ready) { Workspace::AgentReadiness::Result.new(ready: true, pane: "0.2", pane_id: "%23", label: "Claude Code") }
  let(:readiness) { instance_double(Workspace::AgentReadiness, deadline_in: 9.0, wait: ready) }
  let(:tmux) { instance_double(Workspace::Tmux, session_name_for: "api") }
  let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: "/w/api") }
  subject(:dispatch) do
    described_class.new(snapshot_client: snapshot_client, sender: sender, binder: binder, library: library,
      runner: runner, readiness: readiness, main_agent: main_agent, tmux: tmux, project_config: project_config, prompt_timeout: 30)
  end

  describe "#session_live?" do
    before { allow(tmux).to receive(:custom_socket_option).and_return(nil) }

    it "says whether the workspace's session runs, and nil when tmux can't tell" do
      allow(tmux).to receive(:sessions).with(strict: true).and_return(["api"])
      expect(dispatch.session_live?("api")).to be(true)
      allow(tmux).to receive(:sessions).with(strict: true).and_return([])
      expect(dispatch.session_live?("api")).to be(false)
      allow(tmux).to receive(:sessions).and_raise(Workspace::Error, "no tmux")
      expect(dispatch.session_live?("api")).to be_nil
      allow(tmux).to receive(:custom_socket_option).and_return("-L x")
      expect(dispatch.session_live?("api")).to be_nil
    end
  end

  describe "#panes" do
    it "turns a daemon that does not answer into no_daemon" do
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("no daemon", reason: :no_daemon))

      expect { dispatch.panes("api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_daemon") }
    end
  end

  describe "#main_pane" do
    let(:panes) { [{"pane_id" => "%1", "kind" => "shell"}, {"pane_id" => "%2", "kind" => "claude"}, {"pane_id" => "%3", "kind" => "codex"}] }

    it "picks the preferred agent pane, else the first one" do
      expect(dispatch.main_pane("api", panes, preferred: "%3", what: "x")["pane_id"]).to eq("%3")
      expect(dispatch.main_pane("api", panes, preferred: "%1", what: "x")["pane_id"]).to eq("%2")
    end

    it "names what had nowhere to go when no pane runs an agent" do
      expect { dispatch.main_pane("api", [panes.first], preferred: nil, what: "the stage") }
        .to raise_error(Workspace::Error, /nowhere to send the stage/) { |e| expect(e.code).to eq("no_agent_pane") }
    end
  end

  describe "#refuse_busy" do
    it "refuses a waiting or working pane with its state, naming the noun" do
      expect { dispatch.refuse_busy("api", {"pane_id" => "%2", "state" => "waiting"}, "stage") }
        .to raise_error(Workspace::Error, /start the stage again/) { |e| expect(e.details["state"]).to eq("waiting") }
      expect { dispatch.refuse_busy("api", {"pane_id" => "%2", "state" => "working"}, "stage") }
        .to raise_error(Workspace::Error, /Send the stage to another pane/) { |e| expect(e.code).to eq("pane_busy") }
      expect { dispatch.refuse_busy("api", {"pane_id" => "%2", "state" => "idle"}, "stage") }.not_to raise_error
    end
  end

  describe "#spawn" do
    it "splits a pane with the agent's command and waits for that pane only" do
      spawned = dispatch.spawn("api", "claude")

      expect(spawned).to have_attributes(pane: "%23", label: "Claude Code")
      expect(spawned).to be_ready
      expect(runner).to have_received(:call).with("api", "claude", split: true, cwd: "/w/api")
      expect(readiness).to have_received(:wait).with("api", deadline: 9.0, only_pane: "%23")
    end
  end

  describe "#spawn that fails" do
    before { allow(tmux).to receive_messages(close_pane: true, custom_socket_option: nil, capture_screen: "") }

    it "closes the new pane when the agent is not ready" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout"))

      spawned = dispatch.spawn("api", "claude")

      expect(spawned).not_to be_ready
      expect(spawned.closed).to be(true)
      expect(tmux).to have_received(:close_pane).with("%23")
    end

    it "keeps a Codex pane open at a sign-in screen and says so" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "still starting up", label: "Codex"))
      allow(tmux).to receive(:capture_screen).with("%23").and_return("Welcome to Codex\n\n> 1. Sign in with ChatGPT\n  2. Provide your own API key\n")

      spawned = dispatch.spawn("api", "codex")

      expect(spawned).to have_attributes(closed: false, waiting: "sign_in")
      expect(tmux).not_to have_received(:close_pane)
      expect(dispatch.not_ready_details(spawned)).to eq("pane_id" => "%23", "pane_closed" => false, "waiting" => "sign_in")
      expect(dispatch.not_ready_message(spawned, "task")).to match(/left open: finish the sign-in screen in it, then start the task again/)
    end

    it "keeps a Codex pane open at a folder-trust screen" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "x"))
      allow(tmux).to receive(:capture_screen).with("%23").and_return("Trust this folder?\n\n> 1. Trust and continue\n  2. Quit\n")

      expect(dispatch.spawn("api", "codex")).to have_attributes(closed: false, waiting: "trust")
    end

    it "still closes a pane whose screen is unrecognised" do
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "x"))
      allow(tmux).to receive(:capture_screen).with("%23").and_return("starting...\n")

      spawned = dispatch.spawn("api", "codex")

      expect(spawned).to have_attributes(closed: true, waiting: nil)
      expect(dispatch.not_ready_details(spawned)).to eq("pane_id" => "%23", "pane_closed" => true)
      expect(dispatch.not_ready_message(spawned, "task")).to end_with("and the pane was closed.")
    end

    it "leaves the pane when the workspace uses a custom tmux socket" do
      allow(tmux).to receive(:custom_socket_option).with("api").and_return("-L x")
      allow(readiness).to receive(:wait).and_return(Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout"))

      expect(dispatch.spawn("api", "claude").closed).to be(false)
      expect(tmux).not_to have_received(:close_pane)
    end

    it "keeps a ready pane" do
      expect(dispatch.spawn("api", "claude").closed).to be(false)
      expect(tmux).not_to have_received(:close_pane)
    end

    it "closes the pane and names it in details when the wait raises" do
      allow(readiness).to receive(:wait).and_raise(Workspace::Error.new("tmux gone", code: "tmux_error"))

      expect { dispatch.spawn("api", "claude") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("tmux_error")
        expect(e.details).to include("pane_id" => "%23", "pane_closed" => true)
      }
    end
  end

  describe "#spawn without a known root" do
    it "splits with no cwd" do
      allow(project_config).to receive(:project_root_for).and_return(nil)

      dispatch.spawn("api", "claude")

      expect(runner).to have_received(:call).with("api", "claude", split: true, cwd: nil)
    end
  end

  describe "#bind_play" do
    let(:play) { {"ref" => "play/research", "path" => "/lib/play/research.md"} }

    it "adds the packs to those of an existing play binding, with the focus" do
      allow(binder).to receive(:live).and_return("kind" => "play", "packs" => ["notes"])

      expect(dispatch.bind_play("api", "%2", play, focus: "spine stage verify", packs: ["spine"])).to be_nil
      fields = {"kind" => "play", "id" => "play/research", "instructions" => "/lib/play/research.md", "plays" => [{"id" => "play/research", "instructions" => "/lib/play/research.md"}], "packs" => %w[notes spine], "focus" => "spine stage verify"}
      expect(binder).to have_received(:bind).with(workspace: "api", pane: "%2", **fields)
    end

    it "binds the first pack as the play when there is no play" do
      dispatch.bind_play("api", "%2", nil, packs: ["spine"])

      fields = {"kind" => "play", "id" => "play/spine", "packs" => ["spine"]}
      expect(binder).to have_received(:bind).with(workspace: "api", pane: "%2", **fields)
    end

    it "leaves a run binding alone" do
      allow(binder).to receive(:live).and_return("kind" => "run")

      dispatch.bind_play("api", "%2", play)
      expect(binder).not_to have_received(:bind)
    end

    it "returns a note when the binding cannot be written" do
      allow(binder).to receive(:bind).and_raise(Errno::EACCES)

      expect(dispatch.bind_play("api", "%2", play)).to start_with("Sent, but could not bind pane %2")
    end
  end

  describe "#spawn with configured agent names" do
    let(:settings) { instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {}) }
    let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings)) }

    def build(agent_commands)
      described_class.new(snapshot_client: snapshot_client, sender: sender, binder: binder, library: library, runner: runner, readiness: readiness,
        main_agent: main_agent, tmux: tmux, project_config: project_config, prompt_timeout: 30, agent_commands: agent_commands)
    end

    it "waits with a detector that knows the workspace's names" do
      build(agent_commands).spawn("api", "claude")

      expect(readiness).to have_received(:wait)
        .with("api", deadline: 9.0, only_pane: "%23", detector: Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}))
    end

    it "waits as before when nothing is configured or no AgentCommands is wired" do
      plain = instance_double(Workspace::ProjectSettings, load_global: {}, load: {})
      build(Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: plain))).spawn("api", "claude")
      build(nil).spawn("api", "claude")

      expect(readiness).to have_received(:wait).with("api", deadline: 9.0, only_pane: "%23").twice
    end
  end
end
