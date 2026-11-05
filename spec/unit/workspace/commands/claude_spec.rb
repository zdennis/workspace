RSpec.describe Workspace::Commands::Claude do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { CLITestHelpers::FakeTmux.new }

  subject(:command) do
    described_class.new(
      state: CLITestHelpers::FakeState.new,
      tmux: tmux,
      output: output,
      error_output: error_output
    )
  end

  describe "#deactivate" do
    it "sends Ctrl-C to the Claude pane multiple times" do
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      allow(tmux).to receive(:send_key).and_return(true)
      allow(command).to receive(:sleep)

      command.deactivate(["myproject"])

      expect(tmux).to have_received(:send_key)
        .with("myproject", "0.1", "C-c")
        .exactly(3).times
      expect(output.string).to include("Deactivating Claude in myproject")
      expect(output.string).to include("Done.")
    end

    it "warns and skips when session is not active" do
      allow(tmux).to receive(:sessions).and_return([])

      command.deactivate(["missing-project"])

      expect(error_output.string).to include("No active tmux session for missing-project")
      expect(output.string).to include("Done.")
    end

    it "returns each project's outcome, skipped ones included" do
      allow(tmux).to receive(:sessions).and_return(["proj1"])
      allow(tmux).to receive(:send_key).and_return(true)
      allow(command).to receive(:sleep)

      expect(command.deactivate(%w[proj1 gone])).to eq(
        "proj1" => {"outcome" => "deactivated"},
        "gone" => {"outcome" => "skipped", "reason" => "no_session", "message" => "No active tmux session for gone"}
      )
    end

    it "deactivates multiple projects" do
      allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
      allow(tmux).to receive(:send_key).and_return(true)
      allow(command).to receive(:sleep)

      command.deactivate(["proj1", "proj2"])

      expect(tmux).to have_received(:send_key).exactly(6).times
      expect(output.string).to include("Deactivating Claude in proj1")
      expect(output.string).to include("Deactivating Claude in proj2")
    end
  end

  describe "#reactivate" do
    it "sends the reactivate command to the Claude pane" do
      allow(tmux).to receive(:sessions).and_return(["myproject"])

      command.reactivate(["myproject"])

      expect(tmux.sent_keys).to eq([{session: "myproject", pane: "0.1", text: "claude --continue || claude", enter: true}])
      expect(output.string).to include("Reactivating Claude in myproject")
      expect(output.string).to include("Done.")
      expect(error_output.string).to be_empty
    end

    it "warns when the command doesn't reach the pane" do
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      tmux.delivery_status = :not_landed

      command.reactivate(["myproject"])

      expect(error_output.string).to include("Warning: myproject: fake not_landed")
    end

    it "warns and skips when session is not active" do
      allow(tmux).to receive(:sessions).and_return([])

      command.reactivate(["missing-project"])

      expect(error_output.string).to include("No active tmux session for missing-project")
    end

    it "returns reactivated, or failed with the delivery message" do
      allow(tmux).to receive(:sessions).and_return(["proj1"])

      expect(command.reactivate(["proj1"])).to eq("proj1" => {"outcome" => "reactivated"})

      tmux.delivery_status = :not_landed
      expect(command.reactivate(["proj1"])).to eq("proj1" => {"outcome" => "failed", "reason" => "not_delivered", "message" => "fake not_landed"})
    end

    it "returns skipped for a project with no session" do
      allow(tmux).to receive(:sessions).and_return([])

      expect(command.reactivate(["gone"])["gone"]).to include("outcome" => "skipped", "reason" => "no_session")
    end

    it "reactivates multiple projects" do
      allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])

      command.reactivate(["proj1", "proj2"])

      expect(tmux.sent_keys.size).to eq(2)
      expect(output.string).to include("Reactivating Claude in proj1")
      expect(output.string).to include("Reactivating Claude in proj2")
    end
  end

  describe "#reactivate with a configured command" do
    let(:agent_commands) do
      ps = instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {})
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: ps))
    end

    subject(:command) do
      described_class.new(state: CLITestHelpers::FakeState.new, tmux: tmux, agent_commands: agent_commands, output: output, error_output: error_output)
    end

    it "types the configured command in both halves" do
      allow(tmux).to receive(:sessions).and_return(["myproject"])

      command.reactivate(["myproject"])

      expect(tmux.sent_keys).to eq([{session: "myproject", pane: "0.1", text: "claude-dev --continue || claude-dev", enter: true}])
    end

    it "types the default command when nothing is configured" do
      ps = instance_double(Workspace::ProjectSettings, load_global: {}, load: {})
      plain = described_class.new(state: CLITestHelpers::FakeState.new, tmux: tmux, output: output, error_output: error_output,
        agent_commands: Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: ps)))
      allow(tmux).to receive(:sessions).and_return(["myproject"])

      plain.reactivate(["myproject"])

      expect(tmux.sent_keys.first[:text]).to eq("claude --continue || claude")
    end
  end

  describe "the Claude pane of a project with a configured command" do
    let(:settings) { instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "/opt/bin/claude-dev --model x"}}}, load: {}) }
    let(:agent_commands) { Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings)) }
    let(:real_tmux) { instance_double(Workspace::Tmux) }
    let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([])) }
    let(:labels) { Workspace::AgentLabels.new(process_tree: process_tree) }

    def build(agent_commands)
      described_class.new(state: CLITestHelpers::FakeState.new, tmux: real_tmux, agent_labels: labels, agent_commands: agent_commands,
        output: output, error_output: error_output)
    end

    before do
      allow(real_tmux).to receive(:sessions).and_return(["proj"])
      allow(real_tmux).to receive(:session_name_for) { |name| name }
      allow(real_tmux).to receive(:panes).and_return([0, 1])
      allow(real_tmux).to receive(:find_pane_by_title).and_return(nil)
      allow(real_tmux).to receive(:pane_details).and_return([{id: "%1", window: 0, index: 0, pid: 10, command: "zsh", title: "t"},
        {id: "%2", window: 0, index: 1, pid: 20, command: "claude-dev", title: "t"}])
      allow(real_tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))
    end

    it "finds a pane running the configured command by its label, and types the configured command with its path and flags" do
      build(agent_commands).reactivate(["proj"])

      expect(real_tmux).to have_received(:deliver)
        .with("proj", "0.1", "/opt/bin/claude-dev --model x --continue || /opt/bin/claude-dev --model x")
    end

    it "does not find that pane by its label without the configuration" do
      build(nil).reactivate(["proj"])

      expect(real_tmux).to have_received(:deliver).with("proj", "0.1", "claude --continue || claude")
    end

    it "types exactly REACTIVATE_COMMAND when AgentCommands is wired and nothing is configured" do
      plain = instance_double(Workspace::ProjectSettings, load_global: {}, load: {})
      build(Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: plain))).reactivate(["proj"])

      expect(real_tmux).to have_received(:deliver).with("proj", anything, described_class::REACTIVATE_COMMAND)
    end
  end
end
