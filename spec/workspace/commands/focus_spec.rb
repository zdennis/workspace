require "tmpdir"

RSpec.describe Workspace::Commands::Focus do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:event_log_file) { File.join(tmpdir, "events.jsonl") }
  let(:state) do
    allow(config).to receive(:state_file).and_return(state_file)
    allow(config).to receive(:event_log_file).and_return(event_log_file)
    event_log = Workspace::EventLog.new(config: config)
    Workspace::State.new(config: config, event_log: event_log)
  end
  let(:output) { StringIO.new }
  let(:window_manager) { double("window_manager") }

  subject(:command) do
    described_class.new(state: state, window_manager: window_manager, output: output)
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "focuses window by stored window ID" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: nil).and_return(true)

      command.call("myproject")

      expect(window_manager).to have_received(:focus_by_id).with(42, highlight: nil)
      expect(output.string).to include("Focusing myproject")
    end

    it "shakes window when shake: true" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: nil).and_return(true)
      allow(window_manager).to receive(:shake_by_id).with(42).and_return(true)

      command.call("myproject", shake: true)

      expect(window_manager).to have_received(:focus_by_id).with(42, highlight: nil)
      expect(window_manager).to have_received(:shake_by_id).with(42)
    end

    it "does not shake when shake: false" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: nil).and_return(true)
      allow(window_manager).to receive(:shake_by_id)

      command.call("myproject")

      expect(window_manager).not_to have_received(:shake_by_id)
    end

    it "passes highlight color to focus_by_id" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: "green").and_return(true)

      command.call("myproject", highlight: "green")

      expect(window_manager).to have_received(:focus_by_id).with(42, highlight: "green")
    end

    it "raises Workspace::Error when no window ID in state" do
      state.save

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /No iTerm window found for 'myproject'/
      )
    end

    it "raises Workspace::Error when window no longer exists" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: nil).and_return(false)

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /no longer exists/
      )
    end
  end
end
