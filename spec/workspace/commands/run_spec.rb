RSpec.describe Workspace::Commands::Run do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { double("tmux") }
  let(:state) { double("state") }
  let(:window_manager) { double("window_manager") }

  subject(:command) do
    described_class.new(
      tmux: tmux,
      state: state,
      window_manager: window_manager,
      output: output,
      error_output: error_output
    )
  end

  before do
    allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
    allow(tmux).to receive(:sessions).and_return(["myproject"])
    allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
    allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))
  end

  describe "#call" do
    context "when no active tmux session" do
      it "raises Workspace::Error" do
        allow(tmux).to receive(:sessions).and_return([])

        expect { command.call("myproject", "echo hi") }.to raise_error(
          Workspace::Error, /No active tmux session.*workspace launch/m
        )
      end
    end

    context "default behavior (bottommost pane)" do
      it "sends command to the last pane" do
        command.call("myproject", "echo hi")

        expect(tmux).to have_received(:deliver).with("myproject", "0.2", "echo hi", enter: true)
      end

      it "resolves tmux session name from config" do
        allow(tmux).to receive(:session_name_for).with("myproject").and_return("my-tmux-session")
        allow(tmux).to receive(:sessions).and_return(["my-tmux-session"])
        allow(tmux).to receive(:panes).with("my-tmux-session", window: "0").and_return([0, 1])

        command.call("myproject", "echo hi")

        expect(tmux).to have_received(:deliver).with("my-tmux-session", "0.1", "echo hi", enter: true)
      end
    end

    context "with pane: :bottom (explicit)" do
      it "sends command to the last pane" do
        command.call("myproject", "echo hi", pane: :bottom)

        expect(tmux).to have_received(:deliver).with("myproject", "0.2", "echo hi", enter: true)
      end
    end

    context "with pane: 0" do
      it "sends command to pane 0 rather than falling through to the last pane" do
        command.call("myproject", "echo hi", pane: 0)

        expect(tmux).to have_received(:deliver).with("myproject", "0.0", "echo hi", enter: true)
      end
    end

    context "when the window has no panes" do
      it "raises Workspace::Error in the normal path" do
        allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([])

        expect { command.call("myproject", "echo hi") }.to raise_error(
          Workspace::Error, /No panes found for session 'myproject'/
        )
      end

      it "raises Workspace::Error in the split path without attempting a split" do
        allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([])
        allow(tmux).to receive(:split_pane)

        expect { command.call("myproject", "echo hi", split: true) }.to raise_error(
          Workspace::Error, /No panes found for session 'myproject'/
        )
        expect(tmux).not_to have_received(:split_pane)
      end
    end

    context "with pane: N (explicit index)" do
      it "sends command to the specified pane" do
        command.call("myproject", "rake spec", pane: 1)

        expect(tmux).to have_received(:deliver).with("myproject", "0.1", "rake spec", enter: true)
      end

      it "raises Workspace::Error when pane index is out of range" do
        expect { command.call("myproject", "echo hi", pane: 99) }.to raise_error(
          Workspace::Error, /Pane 99 does not exist/
        )
      end
    end

    context "with enter: false" do
      it "sends text without pressing Enter" do
        command.call("myproject", "rails console", enter: false)

        expect(tmux).to have_received(:deliver).with("myproject", "0.2", "rails console", enter: false)
      end
    end

    context "with split: true" do
      before do
        allow(tmux).to receive(:split_pane).and_return({index: 3, id: "%23"})
      end

      it "splits the last pane and sends command to the pane index tmux reported" do
        command.call("myproject", "tail -f log/dev.log", split: true)

        expect(tmux).to have_received(:split_pane).with("myproject", pane: 2, vertical: false, cwd: nil)
        expect(tmux).to have_received(:deliver).with("myproject", "0.3", "tail -f log/dev.log", enter: true)
      end

      it "starts the new pane in cwd" do
        command.call("myproject", "claude", split: true, cwd: "/w/api")

        expect(tmux).to have_received(:split_pane).with("myproject", pane: 2, vertical: false, cwd: "/w/api")
      end

      it "returns the id of the new pane" do
        expect(command.call("myproject", "tail -f log/dev.log", split: true)).to eq("%23")
      end

      it "returns nil for a split that tmux gave no id for" do
        allow(tmux).to receive(:split_pane).and_return({index: 3, id: nil})

        expect(command.call("myproject", "tail -f log/dev.log", split: true)).to be_nil
      end

      it "returns nil when it did not split" do
        expect(command.call("myproject", "echo hi")).to be_nil
      end

      it "returns nil for a dry run" do
        expect(command.call("myproject", "echo hi", split: true, dry_run: true)).to be_nil
      end

      it "uses the reported index even when it is not the highest pane index" do
        allow(tmux).to receive(:split_pane).and_return({index: 1, id: "%9"})

        command.call("myproject", "tail -f log/dev.log", split: true)

        expect(tmux).to have_received(:deliver).with("myproject", "0.1", "tail -f log/dev.log", enter: true)
      end

      it "sends text without Enter when enter: false" do
        command.call("myproject", "rails console", split: true, enter: false)

        expect(tmux).to have_received(:deliver).with("myproject", "0.3", "rails console", enter: false)
      end

      it "raises Workspace::Error when split fails" do
        allow(tmux).to receive(:split_pane).and_return(nil)

        expect { command.call("myproject", "tail -f log/dev.log", split: true) }.to raise_error(
          Workspace::Error, /Failed to split window/
        )
      end

      it "raises Workspace::Error when the command never reaches the new pane" do
        allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :not_landed, message: "nothing changed"))

        expect { command.call("myproject", "tail -f log/dev.log", split: true) }.to raise_error(
          Workspace::Error, /Failed to send command to new split pane/
        )
      end
    end

    context "with split: true, vertical: true" do
      before do
        allow(tmux).to receive(:split_pane).and_return({index: 3, id: "%23"})
      end

      it "splits side-by-side (vertical: true)" do
        command.call("myproject", "rails console", split: true, vertical: true)

        expect(tmux).to have_received(:split_pane).with("myproject", pane: 2, vertical: true, cwd: nil)
      end
    end

    context "with focus: true" do
      it "focuses the iTerm window after sending" do
        allow(state).to receive(:load)
        allow(state).to receive(:dig).with("myproject", "iterm_window_id").and_return(42)
        allow(window_manager).to receive(:focus_by_id).and_return(true)

        command.call("myproject", "echo hi", focus: true)

        expect(window_manager).to have_received(:focus_by_id).with(42, highlight: nil)
      end

      it "skips focus when the stored window ID is 0" do
        allow(state).to receive(:load)
        allow(state).to receive(:dig).with("myproject", "iterm_window_id").and_return(0)
        allow(window_manager).to receive(:focus_by_id)

        command.call("myproject", "echo hi", focus: true)

        expect(window_manager).not_to have_received(:focus_by_id)
      end

      it "skips focus when no window ID in state" do
        allow(state).to receive(:load)
        allow(state).to receive(:dig).with("myproject", "iterm_window_id").and_return(nil)
        allow(window_manager).to receive(:focus_by_id)

        command.call("myproject", "echo hi", focus: true)

        expect(window_manager).not_to have_received(:focus_by_id)
      end
    end

    context "with dry_run: true" do
      it "prints the load-buffer/paste-buffer sequence without executing" do
        command.call("myproject", "echo hi", dry_run: true)

        expect(output.string).to include("tmux load-buffer")
        expect(output.string).to include("tmux paste-buffer")
        expect(output.string).to include("myproject")
        expect(tmux).not_to have_received(:deliver)
      end

      it "prints Enter line when enter: true" do
        command.call("myproject", "echo hi", dry_run: true)

        expect(output.string).to include("Enter")
      end

      it "omits Enter line when enter: false" do
        command.call("myproject", "echo hi", dry_run: true, enter: false)

        expect(output.string).not_to include("Enter")
      end

      it "prints split commands without executing when split: true" do
        allow(tmux).to receive(:panes).and_return([0, 1, 2])
        allow(tmux).to receive(:split_pane)

        command.call("myproject", "tail -f log", split: true, dry_run: true)

        expect(output.string).to include("split-window")
        expect(tmux).not_to have_received(:split_pane)
        expect(tmux).not_to have_received(:deliver)
      end
    end

    context "when the command never reaches the pane" do
      it "raises Workspace::Error" do
        allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :not_landed, message: "nothing changed"))

        expect { command.call("myproject", "echo hi") }.to raise_error(
          Workspace::Error, /Failed to send command to pane 0.2 of .myproject.: nothing changed/
        )
      end

      it "hints that it is safe to run again, since the text never landed" do
        allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :not_landed, message: "nothing changed"))

        expect { command.call("myproject", "echo hi") }.to raise_error(Workspace::Error) do |error|
          expect(error.message.downcase).not_to include("do not run it again")
          expect(error.message).to include("safe to run it again")
        end
      end
    end

    context "when delivery is unverified (may or may not have landed)" do
      it "raises a NotSubmittedError with a hint to check before resending" do
        allow(tmux).to receive(:deliver).and_return(
          Workspace::Tmux::Delivery.new(status: :unverified, message: "pasted, but the pane could not be read back; it may not have arrived")
        )

        expect { command.call("myproject", "echo hi") }.to raise_error(Workspace::Commands::Run::NotSubmittedError) do |error|
          expect(error.message.downcase).to include("do not run it again")
        end
      end
    end

    context "when delivery is unsubmitted (landed but Enter never took)" do
      it "raises a NotSubmittedError, distinct from a plain not-landed failure" do
        allow(tmux).to receive(:deliver).and_return(
          Workspace::Tmux::Delivery.new(status: :unsubmitted, message: "may not have been submitted")
        )

        expect { command.call("myproject", "echo hi") }.to raise_error(Workspace::Commands::Run::NotSubmittedError) do |error|
          expect(error.message.downcase).to include("press enter there instead")
        end
      end
    end
  end

  describe "a claude-dev pane found by agent label" do
    let(:output) { StringIO.new }
    let(:tmux) { double("tmux") }
    let(:claude_dev) { Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}) }
    let(:label_details) do
      [{id: "%10", window: 0, index: 0, pid: 100, command: "zsh", title: "a"},
        {id: "%11", window: 0, index: 1, pid: 200, command: "claude-dev", title: "b"},
        {id: "%12", window: 0, index: 2, pid: 300, command: "zsh", title: "c"}]
    end
    let(:labels) { Workspace::AgentLabels.new(process_tree: instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([]))) }
    let(:configured) do
      settings = instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {})
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings))
    end

    before do
      allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
      allow(tmux).to receive(:sessions).and_return(["myproject"])
      allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
      allow(tmux).to receive(:find_pane_by_title).and_return(nil)
      allow(tmux).to receive(:pane_details).with("myproject", window: "0").and_return(label_details)
      allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :submitted, message: "ok"))
    end

    def build(agent_commands)
      described_class.new(tmux: tmux, state: double("state"), window_manager: double("wm"), agent_labels: labels,
        agent_commands: agent_commands, output: output, error_output: StringIO.new)
    end

    it "is sent to through the configured detector" do
      build(configured).call("myproject", "echo hi", pane: "Claude Code")

      expect(tmux).to have_received(:deliver).with("myproject", "0.1", "echo hi", enter: true)
    end

    it "is not found without the configuration" do
      expect { build(nil).call("myproject", "echo hi", pane: "Claude Code") }.to raise_error(Workspace::Error, /No pane matching/)
    end
  end
end
