require "tmpdir"

RSpec.describe Workspace::Commands::Focus do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
  let(:state_file) { File.join(tmpdir, "state.json") }
  let(:state) do
    s = Workspace::State.new(config: config)
    allow(config).to receive(:state_file).and_return(state_file)
    s
  end
  let(:output) { StringIO.new }
  let(:iterm) { double("iterm") }

  subject(:command) do
    described_class.new(state: state, iterm: iterm, output: output)
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "focuses window using saved window ID" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(iterm).to receive(:focus_and_shake).with(42).and_return("ok")

      command.call("myproject")

      expect(iterm).to have_received(:focus_and_shake).with(42)
      expect(output.string).to include("Focusing myproject")
    end

    it "searches live when no saved ID, then saves the found ID" do
      state["myproject"] = {"unique_id" => "uid1"}
      state.save

      allow(iterm).to receive(:find_window_for_project).with("myproject").and_return("99")
      allow(iterm).to receive(:focus_and_shake).with(99).and_return("ok")

      command.call("myproject")

      state.load
      expect(state.dig("myproject", "iterm_window_id")).to eq(99)
      expect(iterm).to have_received(:focus_and_shake).with(99)
    end

    it "raises Workspace::Error when no window is found anywhere" do
      state.save

      allow(iterm).to receive(:find_window_for_project).with("myproject").and_return(nil)

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /No iTerm window found for 'myproject'/
      )
    end

    it "raises Workspace::Error when saved window has disappeared" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(iterm).to receive(:focus_and_shake).with(42).and_return("not_found")

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /no longer exists/
      )
    end
  end
end
