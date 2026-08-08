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
    allow(tmux).to receive(:send_keys).and_return(true)
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

        expect(tmux).to have_received(:send_keys).with("myproject", "0.2", "echo hi", enter: true)
      end

      it "resolves tmux session name from config" do
        allow(tmux).to receive(:session_name_for).with("myproject").and_return("my-tmux-session")
        allow(tmux).to receive(:sessions).and_return(["my-tmux-session"])
        allow(tmux).to receive(:panes).with("my-tmux-session", window: "0").and_return([0, 1])

        command.call("myproject", "echo hi")

        expect(tmux).to have_received(:send_keys).with("my-tmux-session", "0.1", "echo hi", enter: true)
      end
    end

    context "with pane: :bottom (explicit)" do
      it "sends command to the last pane" do
        command.call("myproject", "echo hi", pane: :bottom)

        expect(tmux).to have_received(:send_keys).with("myproject", "0.2", "echo hi", enter: true)
      end
    end

    context "with pane: 0" do
      it "sends command to pane 0 rather than falling through to the last pane" do
        command.call("myproject", "echo hi", pane: 0)

        expect(tmux).to have_received(:send_keys).with("myproject", "0.0", "echo hi", enter: true)
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
        allow(tmux).to receive(:split_window)

        expect { command.call("myproject", "echo hi", split: true) }.to raise_error(
          Workspace::Error, /No panes found for session 'myproject'/
        )
        expect(tmux).not_to have_received(:split_window)
      end
    end

    context "with pane: N (explicit index)" do
      it "sends command to the specified pane" do
        command.call("myproject", "rake spec", pane: 1)

        expect(tmux).to have_received(:send_keys).with("myproject", "0.1", "rake spec", enter: true)
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

        expect(tmux).to have_received(:send_keys).with("myproject", "0.2", "rails console", enter: false)
      end
    end

    context "with split: true" do
      before do
        allow(tmux).to receive(:split_window).and_return(3)
      end

      it "splits the last pane and sends command to the pane index tmux reported" do
        command.call("myproject", "tail -f log/dev.log", split: true)

        expect(tmux).to have_received(:split_window).with("myproject", pane: 2, vertical: false)
        expect(tmux).to have_received(:send_keys).with("myproject", "0.3", "tail -f log/dev.log", enter: true)
      end

      it "uses the reported index even when it is not the highest pane index" do
        allow(tmux).to receive(:split_window).and_return(1)

        command.call("myproject", "tail -f log/dev.log", split: true)

        expect(tmux).to have_received(:send_keys).with("myproject", "0.1", "tail -f log/dev.log", enter: true)
      end

      it "sends text without Enter when enter: false" do
        command.call("myproject", "rails console", split: true, enter: false)

        expect(tmux).to have_received(:send_keys).with("myproject", "0.3", "rails console", enter: false)
      end

      it "raises Workspace::Error when split fails" do
        allow(tmux).to receive(:split_window).and_return(nil)

        expect { command.call("myproject", "tail -f log/dev.log", split: true) }.to raise_error(
          Workspace::Error, /Failed to split window/
        )
      end

      it "raises Workspace::Error when send_keys to the new pane fails" do
        allow(tmux).to receive(:send_keys).and_return(false)

        expect { command.call("myproject", "tail -f log/dev.log", split: true) }.to raise_error(
          Workspace::Error, /Failed to send command to new split pane/
        )
      end
    end

    context "with split: true, vertical: true" do
      before do
        allow(tmux).to receive(:split_window).and_return(3)
      end

      it "splits side-by-side (vertical: true)" do
        command.call("myproject", "rails console", split: true, vertical: true)

        expect(tmux).to have_received(:split_window).with("myproject", pane: 2, vertical: true)
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
      it "prints the tmux send-keys command without executing" do
        command.call("myproject", "echo hi", dry_run: true)

        expect(output.string).to include("tmux send-keys")
        expect(output.string).to include("myproject")
        expect(output.string).to include("echo hi")
        expect(tmux).not_to have_received(:send_keys)
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
        allow(tmux).to receive(:split_window)

        command.call("myproject", "tail -f log", split: true, dry_run: true)

        expect(output.string).to include("split-window")
        expect(tmux).not_to have_received(:split_window)
        expect(tmux).not_to have_received(:send_keys)
      end
    end

    context "when send_keys fails" do
      it "raises Workspace::Error" do
        allow(tmux).to receive(:send_keys).and_return(false)

        expect { command.call("myproject", "echo hi") }.to raise_error(
          Workspace::Error, /Failed to send command/
        )
      end
    end
  end
end
