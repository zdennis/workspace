RSpec.describe Workspace::Commands::Resize do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { double("tmux") }

  subject(:command) do
    described_class.new(tmux: tmux, output: output, error_output: error_output)
  end

  before do
    allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
    allow(tmux).to receive(:sessions).and_return(["myproject"])
    allow(tmux).to receive(:resize_pane).and_return(true)
  end

  describe "#call" do
    it "raises error when no active tmux session" do
      allow(tmux).to receive(:sessions).and_return([])

      expect { command.call("myproject", "33%,33%,33%") }.to raise_error(
        Workspace::Error, /No active tmux session.*workspace launch/m
      )
    end

    it "resizes panes with percentage spec" do
      command.call("myproject", "15%,,35%")

      expect(tmux).to have_received(:resize_pane).with("myproject", "0.0", "15%")
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.2", "35%")
      expect(tmux).not_to have_received(:resize_pane).with("myproject", "0.1", anything)
    end

    it "resizes panes with row counts" do
      command.call("myproject", "10h,80%,20%")

      expect(tmux).to have_received(:resize_pane).with("myproject", "0.0", "10")
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.1", "80%")
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.2", "20%")
    end

    it "treats bare numbers as row counts" do
      command.call("myproject", "10,,")

      expect(tmux).to have_received(:resize_pane).with("myproject", "0.0", "10")
    end

    it "resizes equal thirds" do
      command.call("myproject", "33%,33%,33%")

      expect(tmux).to have_received(:resize_pane).with("myproject", "0.0", "33%")
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.1", "33%")
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.2", "33%")
    end

    it "skips empty entries" do
      command.call("myproject", ",,50%")

      expect(tmux).to have_received(:resize_pane).once
      expect(tmux).to have_received(:resize_pane).with("myproject", "0.2", "50%")
    end

    it "raises error for invalid size" do
      expect { command.call("myproject", "abc,,") }.to raise_error(
        Workspace::Error, /Invalid pane size/
      )
    end

    it "raises error for empty spec" do
      expect { command.call("myproject", ",,") }.to raise_error(
        Workspace::Error, /No pane sizes specified/
      )
    end

    it "outputs resize info per pane" do
      command.call("myproject", "15%,,35%")

      expect(output.string).to include("Pane 0 → 15%")
      expect(output.string).to include("Pane 2 → 35%")
    end

    it "warns on resize failure" do
      allow(tmux).to receive(:resize_pane).and_return(false)

      command.call("myproject", "50%,50%")

      expect(error_output.string).to include("Warning: Failed to resize pane 0")
      expect(error_output.string).to include("Warning: Failed to resize pane 1")
      expect(output.string).not_to include("Pane 0")
    end

    it "auto-saves layout before resizing when layout_command provided" do
      layout_command = double("layout_command")
      expect(layout_command).to receive(:auto_save).with("myproject", "_before_resize")

      cmd = described_class.new(
        tmux: tmux,
        layout_command: layout_command,
        output: output,
        error_output: error_output
      )
      cmd.call("myproject", "50%,50%")
    end

    it "resolves tmux session name from config" do
      allow(tmux).to receive(:session_name_for).with("myproject").and_return("my-tmux-session")
      allow(tmux).to receive(:sessions).and_return(["my-tmux-session"])

      command.call("myproject", "50%,50%")

      expect(tmux).to have_received(:resize_pane).with("my-tmux-session", "0.0", "50%")
      expect(tmux).to have_received(:resize_pane).with("my-tmux-session", "0.1", "50%")
    end
  end
end
