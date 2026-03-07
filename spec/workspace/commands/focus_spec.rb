require "tmpdir"

RSpec.describe Workspace::Commands::Focus do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:output) { StringIO.new }
  let(:window_manager) { double("window_manager") }

  subject(:command) do
    described_class.new(state: Workspace::State.new(config: config), window_manager: window_manager, output: output)
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "focuses window by title pattern" do
      allow(window_manager).to receive(:focus_by_title).with("workspace-myproject").and_return(true)

      command.call("myproject")

      expect(window_manager).to have_received(:focus_by_title).with("workspace-myproject")
      expect(output.string).to include("Focusing myproject")
    end

    it "shakes window when shake: true" do
      allow(window_manager).to receive(:focus_by_title).with("workspace-myproject").and_return(true)
      allow(window_manager).to receive(:shake_by_title).with("workspace-myproject").and_return(true)

      command.call("myproject", shake: true)

      expect(window_manager).to have_received(:focus_by_title).with("workspace-myproject")
      expect(window_manager).to have_received(:shake_by_title).with("workspace-myproject")
    end

    it "does not shake when shake: false" do
      allow(window_manager).to receive(:focus_by_title).with("workspace-myproject").and_return(true)
      allow(window_manager).to receive(:shake_by_title)

      command.call("myproject")

      expect(window_manager).not_to have_received(:shake_by_title)
    end

    it "raises Workspace::Error when no window is found" do
      allow(window_manager).to receive(:focus_by_title).with("workspace-myproject").and_return(false)

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /No iTerm window found for 'myproject'/
      )
    end
  end
end
