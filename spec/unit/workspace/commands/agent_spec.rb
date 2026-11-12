require "spec_helper"
require "tmpdir"

# The daemon's router reached through #handle, with no socket and no process: each message goes to the parts
# Workspace.build_agentd_parts builds over FakeTmux and a stubbed coordinator client.
RSpec.describe Workspace::Commands::Agent do
  include_context "an agent daemon over a fake coordinator"

  describe "#handle, before the daemon has started" do
    let(:coordinator_client) { instance_double(Workspace::WorkCoordinatorClient, report_status: {"ok" => true}) }
    let(:served) do
      build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),
        config: config, tmux: tmux, work_coordinator_client: coordinator_client,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state, current_name: "myapp",
        token_generator: token_generator, clock: -> { now }, retry_backoff: 0,
        output: output, error_output: error_output)
    end
    let(:reply) { StringIO.new }

    def replied = JSON.parse(reply.string.lines.last)

    it "delivers a command message to the Claude pane and answers on the client" do
      served.handle({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-1",
                     "dispatch_id" => "d-1", "body" => "do it"}, reply)

      expect(replied).to include("ok" => true)
      expect(tmux.sent_keys.map { |k| [k[:session], k[:pane]] }).to eq([["myapp", "0.1"]])
      expect(tmux.sent_keys.first[:text]).to include("do it")
    end

    describe "reply bytes" do
      def bytes_for(message) = StringIO.new.tap { |io| served.handle(message, io) }.string

      it "writes each reply with its keys in the order the clients have always read" do
        expect(bytes_for({"type" => "nonsense", "workspace" => "myapp"})).to eq(%({"ok":false,"error":"unknown_type"}\n))
        expect(bytes_for({"type" => "command", "workspace" => "other"})).to eq(%({"ok":false,"error":"wrong_workspace"}\n))
        expect(bytes_for({"type" => "version", "workspace" => "myapp"})).to eq(%({"ok":true,"version":"#{Workspace::VERSION}"}\n))
        expect(bytes_for({"type" => "session_event", "workspace" => "myapp", "event" => "stop"})).to eq(%({"ok":true}\n))
        expect(bytes_for({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18"}))
          .to eq(%({"ok":false,"error":"missing_prompt","message":"restart_agent needs a non-empty \\"prompt\\""}\n))
        expect(bytes_for({"type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-9", "body" => "x"}))
          .to eq(%({"ok":false,"error":"no_active_pipeline"}\n))
      end
    end

    it "drops a message addressed to another workspace" do
      served.handle({"type" => "command", "workspace" => "other", "work_item_ref" => "WC-1", "body" => "do it"}, reply)

      expect(replied).to eq("ok" => false, "error" => "wrong_workspace")
      expect(tmux.sent_keys).to be_empty
    end

    it "refuses a restart_agent message with no prompt on the same path" do
      served.handle({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18"}, reply)

      expect(replied).to include("ok" => false, "error" => "missing_prompt")
    end
  end

  describe "the Claude pane lookup with configured names" do
    let(:claude_dev) { Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}) }
    let(:label_details) do
      [{id: "%10", window: 0, index: 0, pid: 100, command: "zsh", title: "a"},
        {id: "%11", window: 0, index: 1, pid: 200, command: "claude-dev", title: "b"},
        {id: "%12", window: 0, index: 2, pid: 300, command: "zsh", title: "c"}]
    end
    let(:labels) { Workspace::AgentLabels.new(process_tree: instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([]))) }
    let(:settings) { instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {}) }
    let(:configured) do
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings))
    end

    def build_agent(agent_commands)
      build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),
        config: config, tmux: tmux, work_coordinator_client: client, pipeline_config: pipeline_config,
        pipeline_state: pipeline_state, agent_labels: labels, agent_commands: agent_commands, current_name: "myapp",
        output: output, error_output: error_output)
    end

    # The pane a command message is typed into.
    def pane_for_command(served)
      served.handle({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-1", "body" => "go"}, StringIO.new)
      tmux.sent_keys.last[:pane]
    end

    before do
      allow(tmux).to receive(:panes).with("myapp", window: "0").and_return([0, 1, 2])
      allow(tmux).to receive(:find_pane_by_title).and_return(nil)
      allow(tmux).to receive(:pane_details).with("myapp", window: "0").and_return(label_details.rotate(1).each_with_index.map { |d, i| d.merge(index: i) })
    end

    it "asks AgentCommands for the detector of the current workspace and finds the claude-dev pane" do
      expect(pane_for_command(build_agent(configured))).to eq("0.0")
      expect(settings).to have_received(:load).with("myapp").at_least(:once)
    end

    it "falls back to pane 1 without AgentCommands" do
      expect(pane_for_command(build_agent(nil))).to eq("0.1")
    end
  end
end
