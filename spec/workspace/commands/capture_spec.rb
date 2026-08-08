RSpec.describe Workspace::Commands::Capture do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { double("tmux") }

  subject(:command) do
    described_class.new(tmux: tmux, output: output, error_output: error_output)
  end

  before do
    allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
    allow(tmux).to receive(:sessions).and_return(["myproject"])
    allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([0, 1, 2])
    allow(tmux).to receive(:capture_pane).and_return("some output\n")
  end

  describe "#call" do
    context "when no active tmux session exists" do
      it "raises Workspace::Error with a launch hint" do
        allow(tmux).to receive(:sessions).and_return([])

        expect { command.call("myproject") }.to raise_error(
          Workspace::Error, /No active tmux session.*workspace launch/m
        )
      end
    end

    context "with default options (bottommost pane, 100 lines)" do
      it "captures the last pane index" do
        command.call("myproject")
        expect(tmux).to have_received(:capture_pane).with("myproject", 2, lines: 100, all: false)
      end

      it "prints the captured output to @output" do
        command.call("myproject")
        expect(output.string).to eq("some output\n")
      end

      it "resolves the session name from the config" do
        allow(tmux).to receive(:session_name_for).with("myproject").and_return("my-tmux-session")
        allow(tmux).to receive(:sessions).and_return(["my-tmux-session"])
        allow(tmux).to receive(:panes).with("my-tmux-session", window: "0").and_return([0, 1])
        allow(tmux).to receive(:capture_pane).with("my-tmux-session", 1, lines: 100, all: false).and_return("text\n")

        command.call("myproject")

        expect(output.string).to eq("text\n")
      end
    end

    context "with pane: :bottom (explicit symbol)" do
      it "targets the last pane" do
        command.call("myproject", pane: :bottom)
        expect(tmux).to have_received(:capture_pane).with("myproject", 2, lines: 100, all: false)
      end
    end

    context "with pane: \"bottom\" (string)" do
      it "targets the last pane" do
        command.call("myproject", pane: "bottom")
        expect(tmux).to have_received(:capture_pane).with("myproject", 2, lines: 100, all: false)
      end
    end

    context "with pane: 0" do
      it "targets pane 0" do
        command.call("myproject", pane: 0)
        expect(tmux).to have_received(:capture_pane).with("myproject", 0, lines: 100, all: false)
      end
    end

    context "with pane: 1" do
      it "targets pane 1" do
        command.call("myproject", pane: 1)
        expect(tmux).to have_received(:capture_pane).with("myproject", 1, lines: 100, all: false)
      end
    end

    context "when pane index is out of range" do
      it "raises Workspace::Error" do
        expect { command.call("myproject", pane: 99) }.to raise_error(
          Workspace::Error, /Pane 99 does not exist/
        )
      end
    end

    context "when the window has no panes" do
      it "raises Workspace::Error" do
        allow(tmux).to receive(:panes).with("myproject", window: "0").and_return([])

        expect { command.call("myproject") }.to raise_error(
          Workspace::Error, /No panes found for session 'myproject'/
        )
      end
    end

    context "with lines: 200" do
      it "passes lines: 200 to capture_pane" do
        command.call("myproject", lines: 200)
        expect(tmux).to have_received(:capture_pane).with("myproject", 2, lines: 200, all: false)
      end
    end

    context "with all: true" do
      it "passes all: true to capture_pane" do
        command.call("myproject", all: true)
        expect(tmux).to have_received(:capture_pane).with("myproject", 2, lines: 100, all: true)
      end
    end

    context "when capture_pane returns nil (tmux failure)" do
      it "raises Workspace::Error" do
        allow(tmux).to receive(:capture_pane).and_return(nil)

        expect { command.call("myproject") }.to raise_error(
          Workspace::Error, /Failed to capture pane/
        )
      end
    end

    context "when capture_pane returns empty string (valid empty buffer)" do
      it "prints nothing and does not raise" do
        allow(tmux).to receive(:capture_pane).and_return("")

        expect { command.call("myproject") }.not_to raise_error
        expect(output.string).to eq("")
      end
    end
  end
end
