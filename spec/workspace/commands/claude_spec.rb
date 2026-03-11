RSpec.describe Workspace::Commands::Claude do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { CLITestHelpers::FakeTmux.new }

  let(:project_settings) { CLITestHelpers::FakeProjectSettings.new }

  subject(:command) do
    described_class.new(
      state: CLITestHelpers::FakeState.new,
      tmux: tmux,
      project_settings: project_settings,
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
      allow(tmux).to receive(:send_keys).and_return(true)

      command.reactivate(["myproject"])

      expect(tmux).to have_received(:send_keys)
        .with("myproject", "0.1", "claude --continue || claude")
      expect(output.string).to include("Reactivating Claude in myproject")
      expect(output.string).to include("Done.")
    end

    it "warns and skips when session is not active" do
      allow(tmux).to receive(:sessions).and_return([])

      command.reactivate(["missing-project"])

      expect(error_output.string).to include("No active tmux session for missing-project")
    end

    it "reactivates multiple projects" do
      allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
      allow(tmux).to receive(:send_keys).and_return(true)

      command.reactivate(["proj1", "proj2"])

      expect(tmux).to have_received(:send_keys).twice
      expect(output.string).to include("Reactivating Claude in proj1")
      expect(output.string).to include("Reactivating Claude in proj2")
    end
  end
end
