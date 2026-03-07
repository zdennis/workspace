RSpec.describe Workspace::Commands::Layout do
  let(:output) { StringIO.new }
  let(:tmux) { double("tmux") }
  let(:state) { CLITestHelpers::FakeState.new }
  let(:layout_string) { "abc1,119x51,0,0[119x5,0,0,87,119x39,0,6,88,119x5,0,46,89]" }

  subject(:command) do
    described_class.new(state: state, tmux: tmux, output: output)
  end

  before do
    allow(tmux).to receive(:session_name_for).with("myproject").and_return("myproject")
    allow(tmux).to receive(:sessions).and_return(["myproject"])
  end

  describe "#save" do
    it "captures and stores the current layout" do
      allow(tmux).to receive(:capture_layout).with("myproject").and_return(layout_string)

      command.save("myproject", "coding")

      expect(state.dig("myproject", "layouts", "coding")).to eq(layout_string)
      expect(output.string).to include("Saved layout 'coding'")
    end

    it "saves with default name when none given" do
      allow(tmux).to receive(:capture_layout).with("myproject").and_return(layout_string)

      command.save("myproject")

      expect(state.dig("myproject", "layouts", "default")).to eq(layout_string)
    end

    it "preserves existing state data" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      allow(tmux).to receive(:capture_layout).with("myproject").and_return(layout_string)

      command.save("myproject", "coding")

      expect(state.dig("myproject", "unique_id")).to eq("uid1")
      expect(state.dig("myproject", "layouts", "coding")).to eq(layout_string)
    end

    it "raises error when no active session" do
      allow(tmux).to receive(:sessions).and_return([])

      expect { command.save("myproject") }.to raise_error(
        Workspace::Error, /No active tmux session/
      )
    end

    it "raises error when capture fails" do
      allow(tmux).to receive(:capture_layout).and_return(nil)

      expect { command.save("myproject") }.to raise_error(
        Workspace::Error, /Could not capture layout/
      )
    end
  end

  describe "#restore" do
    it "applies a saved layout" do
      state["myproject"] = {"layouts" => {"coding" => layout_string}}
      allow(tmux).to receive(:apply_layout).with("myproject", layout_string).and_return(true)

      command.restore("myproject", "coding")

      expect(tmux).to have_received(:apply_layout).with("myproject", layout_string)
      expect(output.string).to include("Restored layout 'coding'")
    end

    it "restores default layout when no name given" do
      state["myproject"] = {"layouts" => {"default" => layout_string}}
      allow(tmux).to receive(:apply_layout).and_return(true)

      command.restore("myproject")

      expect(tmux).to have_received(:apply_layout).with("myproject", layout_string)
    end

    it "raises error when layout not found" do
      state["myproject"] = {"layouts" => {}}

      expect { command.restore("myproject", "missing") }.to raise_error(
        Workspace::Error, /No saved layout 'missing'/
      )
    end

    it "raises error when no active session" do
      allow(tmux).to receive(:sessions).and_return([])

      expect { command.restore("myproject") }.to raise_error(
        Workspace::Error, /No active tmux session/
      )
    end

    it "raises error when apply fails" do
      state["myproject"] = {"layouts" => {"default" => layout_string}}
      allow(tmux).to receive(:apply_layout).and_return(false)

      expect { command.restore("myproject") }.to raise_error(
        Workspace::Error, /Failed to apply layout/
      )
    end
  end

  describe "#list" do
    it "lists saved layouts" do
      state["myproject"] = {"layouts" => {"default" => "...", "coding" => "...", "review" => "..."}}

      command.list("myproject")

      expect(output.string).to include("default")
      expect(output.string).to include("coding")
      expect(output.string).to include("review")
    end

    it "reports no layouts when none saved" do
      command.list("myproject")

      expect(output.string).to include("No saved layouts")
    end
  end

  describe "#auto_save" do
    it "silently saves the current layout" do
      allow(tmux).to receive(:capture_layout).with("myproject").and_return(layout_string)

      command.auto_save("myproject", "_before_resize")

      expect(state.dig("myproject", "layouts", "_before_resize")).to eq(layout_string)
      expect(output.string).to be_empty
    end

    it "does nothing when no active session" do
      allow(tmux).to receive(:sessions).and_return([])

      command.auto_save("myproject", "_before_resize")

      expect(state["myproject"]).to be_nil
    end

    it "does nothing when capture fails" do
      allow(tmux).to receive(:capture_layout).and_return(nil)

      command.auto_save("myproject", "_before_resize")

      expect(state.dig("myproject", "layouts")).to be_nil
    end
  end
end
