require "tmpdir"

RSpec.describe Workspace::Commands::Cleanup do
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
  let(:input) { StringIO.new }
  let(:window_manager) { double("window_manager") }
  let(:tmux) { double("tmux") }

  subject(:command) do
    described_class.new(
      state: state,
      window_manager: window_manager,
      tmux: tmux,
      output: output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    context "when state is empty" do
      it "returns empty array and prints clean message" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No tracked sessions. State is clean.")
      end
    end

    context "when state has no zombies" do
      before do
        state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state.save

        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(window_manager).to receive(:live_window_ids).and_return(Set.new([100]))
      end

      it "returns empty array and prints clean message" do
        result = command.call
        expect(result).to eq([])
        expect(output.string).to include("No zombie sessions detected. State is clean.")
      end
    end

    context "when state has zombie sessions" do
      before do
        state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state["proj2"] = {"unique_id" => "uid2", "iterm_window_id" => 200}
        state["proj3"] = {"unique_id" => "uid3", "iterm_window_id" => 300}
        state.save

        # proj1: both tmux and window dead (zombie)
        # proj2: tmux alive, window dead (zombie)
        # proj3: both alive (not a zombie)
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:session_name_for).with("proj2").and_return("proj2")
        allow(tmux).to receive(:session_name_for).with("proj3").and_return("proj3")
        allow(tmux).to receive(:sessions).and_return(["proj2", "proj3"])
        allow(window_manager).to receive(:live_window_ids).and_return(Set.new([300]))
      end

      context "without force flag" do
        it "lists zombies and prompts for confirmation" do
          input.string = "n\n"
          input.rewind

          result = command.call

          output_text = output.string
          expect(output_text).to include("Found 2 zombie session(s)")
          expect(output_text).to include("proj1")
          expect(output_text).to include("proj2")
          expect(output_text).not_to include("proj3")
          expect(output_text).to include("Remove these 2 zombie session(s) from state?")
          expect(output_text).to include("Cancelled")
          expect(result).to eq([])
        end

        it "removes zombies when user confirms with 'y'" do
          input.string = "y\n"
          input.rewind

          result = command.call

          expect(result).to contain_exactly("proj1", "proj2")
          expect(output.string).to include("Cleaned up 2 zombie session(s)")

          state.load
          expect(state["proj1"]).to be_nil
          expect(state["proj2"]).to be_nil
          expect(state["proj3"]).not_to be_nil
        end

        it "removes zombies when user confirms with 'yes'" do
          input.string = "yes\n"
          input.rewind

          result = command.call

          expect(result).to contain_exactly("proj1", "proj2")
          expect(output.string).to include("Cleaned up 2 zombie session(s)")
        end

        it "cancels when user enters anything else" do
          input.string = "maybe\n"
          input.rewind

          result = command.call

          expect(result).to eq([])
          expect(output.string).to include("Cancelled")

          state.load
          expect(state["proj1"]).not_to be_nil
          expect(state["proj2"]).not_to be_nil
        end
      end

      context "with force flag" do
        it "removes zombies without confirmation" do
          result = command.call(force: true)

          expect(result).to contain_exactly("proj1", "proj2")
          expect(output.string).to include("Cleaned up 2 zombie session(s)")
          expect(output.string).not_to include("Remove these")

          state.load
          expect(state["proj1"]).to be_nil
          expect(state["proj2"]).to be_nil
          expect(state["proj3"]).not_to be_nil
        end
      end

      it "shows correct zombie status for dead tmux and dead window" do
        input.string = "n\n"
        input.rewind

        command.call

        output_text = output.string
        expect(output_text).to match(/proj1.*tmux session: DEAD.*iTerm window: DEAD/m)
      end

      it "shows correct zombie status for alive tmux and dead window" do
        input.string = "n\n"
        input.rewind

        command.call

        output_text = output.string
        expect(output_text).to match(/proj2.*tmux session: alive.*iTerm window: DEAD/m)
      end
    end

    context "when window_id is nil in state" do
      before do
        state["proj1"] = {"unique_id" => "uid1"}
        state.save

        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return([])
        allow(window_manager).to receive(:live_window_ids).and_return(Set.new([]))
      end

      it "treats nil window_id as dead" do
        input.string = "n\n"
        input.rewind

        command.call

        output_text = output.string
        expect(output_text).to include("proj1")
        expect(output_text).to include("tmux session: DEAD")
        expect(output_text).to include("iTerm window: DEAD")
      end
    end
  end
end
