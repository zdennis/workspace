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
  subject(:dispatch) do
    described_class.new(snapshot_client: snapshot_client, sender: sender, binder: binder, library: library,
      runner: runner, readiness: readiness, main_agent: main_agent, tmux: tmux, prompt_timeout: 30)
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
      expect(runner).to have_received(:call).with("api", "claude", split: true)
      expect(readiness).to have_received(:wait).with("api", deadline: 9.0, only_pane: "%23")
    end
  end

  describe "#bind_play" do
    let(:play) { {"ref" => "play/research", "path" => "/lib/play/research.md"} }

    it "adds the packs to those of an existing play binding, with the focus" do
      allow(binder).to receive(:live).and_return("kind" => "play", "packs" => ["notes"])

      expect(dispatch.bind_play("api", "%2", play, focus: "spine stage verify", packs: ["spine"])).to be_nil
      fields = {"kind" => "play", "id" => "play/research", "instructions" => "/lib/play/research.md", "packs" => %w[notes spine], "focus" => "spine stage verify"}
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
end
