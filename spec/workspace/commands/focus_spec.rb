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
      ) { |error|
        expect(error.code).to eq("no_window")
        expect(error.details).to eq("workspace" => "myproject")
      }
    end

    it "raises Workspace::Error when window no longer exists" do
      state["myproject"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save

      allow(window_manager).to receive(:focus_by_id).with(42, highlight: nil).and_return(false)

      expect { command.call("myproject") }.to raise_error(
        Workspace::Error, /no longer exists/
      ) { |error|
        expect(error.code).to eq("window_gone")
        expect(error.details).to eq("workspace" => "myproject", "iterm_window_id" => 42)
      }
    end
  end

  describe "#call with a headless project" do
    it "explains there is no window and names the tmux session to attach to" do
      state["proj"] = {"headless" => true}
      state.save
      tmux = double("tmux", session_name_for: "proj-session")
      command = described_class.new(state: state, window_manager: window_manager, tmux: tmux, output: output)

      expect { command.call("proj") }.to raise_error(Workspace::Error,
        /'proj' runs headless, so it has no iTerm window.*tmux attach -t proj-session/m)
    end
  end

  describe "#call with a pane" do
    let(:tmux) do
      CLITestHelpers::FakeTmuxServer.new("proj" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 1, index: 2}], "other" => [{id: "%7", window: 0, index: 0}])
    end
    let(:command) do
      described_class.new(state: state, window_manager: window_manager, tmux: tmux,
        pane_locator: Workspace::PaneLocator.new(tmux: tmux), output: output)
    end

    before do
      state["proj"] = {"unique_id" => "uid1", "iterm_window_id" => 42}
      state.save
      allow(window_manager).to receive(:focus_by_id).and_return(true)
    end

    it "focuses the window, then selects the pane, and returns its id" do
      expect(command.call("proj", pane: "1.2")).to eq("%19")

      expect(window_manager).to have_received(:focus_by_id).with(42, highlight: nil)
      expect(tmux.selected).to eq([{session: "proj", id: "%19", window: 1}])
      expect(output.string).to eq("Focusing proj, pane %19...\n")
    end

    it "returns nil without a pane" do
      expect(command.call("proj")).to be_nil
      expect(tmux.selected).to be_empty
    end

    it "checks the pane before focusing the window" do
      expect { command.call("proj", pane: "%7") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("wrong_session") }

      expect(window_manager).not_to have_received(:focus_by_id)
      expect(tmux.selected).to be_empty
    end

    it "does not select the pane when the window is gone" do
      allow(window_manager).to receive(:focus_by_id).and_return(false)

      expect { command.call("proj", pane: "%3") }.to raise_error(Workspace::Error, /no longer exists/)

      expect(tmux.selected).to be_empty
    end

    it "raises focus_failed, naming the window as already focused, when tmux can't select the pane" do
      tmux.select_ok = false

      expect { command.call("proj", pane: "%3") }.to raise_error(Workspace::Error, /its window is in front/) { |e| expect(e.code).to eq("focus_failed") }
    end

    it "explains a build with no locator" do
      bare = described_class.new(state: state, window_manager: window_manager, output: output)

      expect { bare.call("proj", pane: "%3") }.to raise_error(Workspace::Error, /not available in this build/)
    end

    it "keeps the headless error ahead of the pane check" do
      state["proj"] = {"headless" => true}
      state.save

      expect { command.call("proj", pane: "%3") }.to raise_error(Workspace::Error, /runs headless/)
    end
  end

  describe "#cycle" do
    let(:liveness) { double("window_liveness") }
    let(:front) { [] }
    let(:cycler) do
      allow(window_manager).to receive(:focus_by_id).and_return(true)
      allow(window_manager).to receive(:window_ids_front_to_back) { front }
      described_class.new(state: state, window_manager: window_manager, window_liveness: liveness, output: output)
    end

    before do
      state["bravo"] = {"iterm_window_id" => 2}
      state["alpha"] = {"iterm_window_id" => 1}
      state["charlie"] = {"iterm_window_id" => 3}
      state["dead"] = {"iterm_window_id" => 9}
      state["quiet"] = {"headless" => true}
      state.save
      allow(liveness).to receive(:call).and_return(
        "alpha" => true, "bravo" => true, "charlie" => true, "dead" => false, "quiet" => nil
      )
    end

    it "focuses the next live project by name after the one in front" do
      front.replace([2, 1, 3])

      expect(cycler.cycle).to eq("charlie")
      expect(window_manager).to have_received(:focus_by_id).with(3, highlight: nil)
    end

    it "wraps around past the last" do
      front.replace([3, 1, 2])

      expect(cycler.cycle).to eq("alpha")
    end

    it "goes the other way with reverse" do
      front.replace([1, 2, 3])

      expect(cycler.cycle(reverse: true)).to eq("charlie")
    end

    it "steps back from the middle" do
      front.replace([2])

      expect(cycler.cycle(reverse: true)).to eq("alpha")
    end

    it "starts at the first when no tracked window is in front" do
      front.replace([77])

      expect(cycler.cycle).to eq("alpha")
      expect(cycler.cycle(reverse: true)).to eq("charlie")
    end

    it "skips closed and headless projects" do
      front.replace([3])

      expect(cycler.cycle).to eq("alpha")
    end

    it "passes shake and highlight on to the focus" do
      front.replace([1])
      allow(window_manager).to receive(:shake_by_id)

      cycler.cycle(shake: true, highlight: "blue")

      expect(window_manager).to have_received(:focus_by_id).with(2, highlight: "blue")
      expect(window_manager).to have_received(:shake_by_id).with(2)
    end

    it "still cycles when the window order cannot be read" do
      allow(window_manager).to receive(:window_ids_front_to_back).and_raise(Workspace::Error, "no window-tool")
      allow(window_manager).to receive(:focus_by_id).and_return(true)
      command = described_class.new(state: state, window_manager: window_manager, window_liveness: liveness, output: output)

      expect(command.cycle).to eq("alpha")
      expect(output.string).to include("Couldn't tell which window is in front")
    end

    it "refuses with no_windows_to_cycle when no window is live" do
      allow(liveness).to receive(:call).and_return("alpha" => false, "quiet" => nil)

      expect { cycler.cycle }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_windows_to_cycle") }
    end

    it "explains a build with no liveness" do
      bare = described_class.new(state: state, window_manager: window_manager, output: output)

      expect { bare.cycle }.to raise_error(Workspace::Error, /not available in this build/)
    end
  end
end
