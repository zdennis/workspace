require "tmpdir"

RSpec.describe Workspace::Commands::Stop do
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
  let(:error_output) { StringIO.new }
  let(:iterm) { double("iterm", last_call_timed_out?: false, applescript_timeout: 5) }
  let(:window_manager) { double("window_manager") }
  let(:tmux) { double("tmux", custom_socket_option: nil) }

  subject(:command) do
    described_class.new(
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      output: output,
      error_output: error_output
    )
  end

  let(:positions_dir) { File.join(tmpdir, "positions") }
  let(:window_positions) { Workspace::WindowPositions.new(dir: positions_dir) }

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "returns empty array when state is empty" do
      result = command.call
      expect(result).to eq([])
      expect(output.string).to include("No active workspace projects")
    end

    context "with active projects" do
      before do
        state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state["proj2"] = {"unique_id" => "uid2", "iterm_window_id" => 200}
        state.save
      end

      it "saves the state entry's removal before killing the session (the caller may be inside it)" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        on_disk_at_kill = :not_killed
        allow(tmux).to receive(:kill_session).with("proj1", project: "proj1") do
          reloaded = Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
          reloaded.load
          on_disk_at_kill = reloaded["proj1"]
        end

        command.call(["proj1"])

        expect(on_disk_at_kill).to be_nil
        expect(output.string.index("Stopped 1 project(s)")).to be < output.string.index("Killing tmux session")
      end

      it "prints nothing with quiet: true" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"], quiet: true)

        expect(output.string).to eq("")
      end

      it "kills tmux sessions for specified projects" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        result = command.call(["proj1"])

        expect(tmux).to have_received(:kill_session).with("proj1", project: "proj1")
        expect(result).to eq(["proj1"])
      end

      it "resolves tmux session name before killing" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("custom-session")
        allow(tmux).to receive(:sessions).and_return(["custom-session"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        expect(tmux).to have_received(:kill_session).with("custom-session", project: "proj1")
      end

      it "returns killed project names" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        result = command.call(["proj1", "proj2"])
        expect(result).to contain_exactly("proj1", "proj2")
      end

      it "kills all projects when none specified" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        result = command.call
        expect(result).to contain_exactly("proj1", "proj2")
      end

      it "removes killed projects from state" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        state.load
        expect(state["proj1"]).to be_nil
        expect(state["proj2"]).not_to be_nil
      end

      it "warns about unknown projects" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:sessions).and_return([])

        command.call(["unknown-project"])

        expect(error_output.string).to include("Warning: 'unknown-project' is not an active workspace project")
      end

      it "doesn't warn about unknown projects with warn_inactive: false" do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:sessions).and_return([])

        command.call(["unknown-project"], warn_inactive: false)

        expect(error_output.string).to be_empty
      end
    end

    context "when iTerm2 does not answer" do
      before do
        state["api"] = {"unique_id" => "uid1"}
        state["notes"] = {"headless" => true}
        state.save
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(iterm).to receive(:last_call_timed_out?).and_return(true)
        allow(tmux).to receive(:session_name_for) { |p| p }
        allow(tmux).to receive(:sessions).and_return(%w[api notes])
        allow(tmux).to receive(:kill_session)
      end

      it "still removes and saves the entries, kills the sessions and leaves the window open" do
        allow(window_manager).to receive(:close_window)

        result = command.call(%w[api notes])

        reloaded = Workspace::State.new(config: config, event_log: Workspace::EventLog.new(config: config))
        reloaded.load
        expect(result).to eq(%w[api notes])
        expect(reloaded.keys).to eq([])
        expect(tmux).to have_received(:kill_session).twice
        expect(window_manager).not_to have_received(:close_window)
      end

      it "warns once per project that has a window, in #warnings and on the error stream" do
        command.call(%w[api notes])

        message = "iTerm did not answer in 5s; the window for api was left open."
        expect(command.warnings).to eq([message])
        expect(error_output.string).to include("Warning: #{message}")
      end

      it "clears the warnings on the next call" do
        command.call(%w[api])
        allow(iterm).to receive(:last_call_timed_out?).and_return(false)
        state["api"] = {"unique_id" => "uid1"}

        command.call(%w[api])

        expect(command.warnings).to eq([])
      end
    end

    context "with a project on a custom tmux socket" do
      it "kills its session on that socket though the default socket does not list it" do
        state["proj1"] = {"unique_id" => "uid1"}
        state.save
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return([])
        allow(tmux).to receive(:custom_socket_option).with("proj1").and_return("-L")
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        expect(tmux).to have_received(:kill_session).with("proj1", project: "proj1")
      end
    end

    context "when iTerm2 answers but cannot close the window" do
      it "warns that the window was left open" do
        state["proj1"] = {"unique_id" => "uid1"}
        state.save
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid1"})
        allow(iterm).to receive(:session_map).and_return({"uid1" => "win-100"})
        allow(window_manager).to receive(:close_window).and_return(false)
        allow(tmux).to receive(:session_name_for).and_return("proj1")
        allow(tmux).to receive(:sessions).and_return([])

        command.call(["proj1"])

        expect(command.warnings).to eq(["iTerm did not close launcher window win-100; it was left open."])
      end
    end

    context "launcher window cleanup" do
      before do
        state["proj1"] = {"unique_id" => "uid1"}
        state["proj2"] = {"unique_id" => "uid2"}
        state.save
      end

      it "preserves launcher window when other projects still use it" do
        live_sessions = {"uid1" => "win-100", "uid2" => "win-100"}
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid1", "proj2" => "uid2"})
        allow(iterm).to receive(:session_map).and_return(live_sessions)
        allow(window_manager).to receive(:close_window)
        allow(tmux).to receive(:session_name_for).with("proj1").and_return("proj1")
        allow(tmux).to receive(:sessions).and_return(["proj1"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1"])

        # Should NOT close the window because proj2 is still in it
        expect(window_manager).not_to have_received(:close_window)
      end

      it "closes launcher window when all its projects are killed" do
        live_sessions = {"uid1" => "win-100", "uid2" => "win-100"}
        allow(iterm).to receive(:find_existing_sessions).and_return({"proj1" => "uid1", "proj2" => "uid2"})
        allow(iterm).to receive(:session_map).and_return(live_sessions)
        allow(window_manager).to receive(:close_window)
        allow(tmux).to receive(:session_name_for).and_return("proj1", "proj2")
        allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])
        allow(tmux).to receive(:kill_session)

        command.call(["proj1", "proj2"])

        expect(window_manager).to have_received(:close_window).with("win-100")
      end
    end
  end

  describe "#call with headless projects" do
    it "kills the tmux session without asking iTerm2 about windows" do
      state["proj"] = {"headless" => true}
      state.save
      allow(tmux).to receive(:sessions).and_return(["proj"])
      allow(tmux).to receive(:session_name_for).with("proj").and_return("proj")
      allow(tmux).to receive(:kill_session)

      expect(command.call(["proj"])).to eq(["proj"])

      expect(tmux).to have_received(:kill_session).with("proj", project: "proj")
      state.load
      expect(state["proj"]).to be_nil
    end
    describe "saving window positions" do
      subject(:command) do
        described_class.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux,
          window_positions: window_positions, output: output, error_output: error_output)
      end

      let(:bounds) { {x: 10, y: 20, width: 800, height: 600} }
      let(:screen) { {x: 0, y: 0, width: 1728, height: 1117} }

      before do
        allow(iterm).to receive(:find_existing_sessions).and_return({})
        allow(tmux).to receive(:sessions).and_return([])
        allow(tmux).to receive(:session_name_for) { |p| p }
        allow(window_manager).to receive(:screens).and_return([screen])
      end

      it "saves the window's bounds and screen before the state entry goes" do
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        saved_with_entry = nil
        allow(window_manager).to receive(:all_window_bounds).with([100]) do
          saved_with_entry = state["proj"]
          {100 => bounds}
        end

        command.call(["proj"])

        expect(saved_with_entry).not_to be_nil
        expect(window_positions.read("proj")).to include(bounds: bounds, screen: screen)
        expect(state["proj"]).to be_nil
      end

      it "reads every target window in one call" do
        state["a"] = {"unique_id" => "u1", "iterm_window_id" => 100}
        state["b"] = {"unique_id" => "u2", "iterm_window_id" => 200}
        state.save
        allow(window_manager).to receive(:all_window_bounds).with([100, 200]).and_return({100 => bounds, 200 => bounds.merge(x: 5)})

        command.call

        expect(window_manager).to have_received(:all_window_bounds).once
        expect(window_positions.read("b")[:bounds][:x]).to eq(5)
      end

      it "records a nil screen when the window is on no listed screen" do
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        allow(window_manager).to receive(:all_window_bounds).and_return({100 => bounds.merge(x: 5000)})

        command.call(["proj"])

        expect(window_positions.read("proj")[:screen]).to be_nil
      end

      it "finds a window on a second screen left of the first" do
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        left = {x: -1920, y: 0, width: 1920, height: 1080}
        allow(window_manager).to receive(:screens).and_return([screen, left])
        allow(window_manager).to receive(:all_window_bounds).and_return({100 => bounds.merge(x: -1500)})

        command.call(["proj"])

        expect(window_positions.read("proj")[:screen]).to eq(left)
      end

      it "still stops when the window read or the write fails" do
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        allow(window_manager).to receive(:all_window_bounds).and_raise(JSON::ParserError, "bad")

        expect(command.call(["proj"])).to eq(["proj"])

        state.load
        expect(state["proj"]).to be_nil
        expect(error_output.string).to eq("")
      end

      it "skips headless entries without reading any window" do
        state["proj"] = {"headless" => true}
        state.save
        allow(window_manager).to receive(:all_window_bounds)

        command.call(["proj"])

        expect(window_manager).not_to have_received(:all_window_bounds)
        expect(window_positions.read("proj")).to be_nil
      end

      it "saves nothing for a window that is already gone and keeps the old file" do
        window_positions.write("proj", bounds, screen)
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        allow(window_manager).to receive(:all_window_bounds).and_return({})

        command.call(["proj"])

        expect(window_positions.read("proj")[:bounds]).to eq(bounds)
        expect(error_output.string).to eq("")
      end

      it "does not save when asked not to" do
        state["proj"] = {"unique_id" => "u", "iterm_window_id" => 100}
        state.save
        allow(window_manager).to receive(:all_window_bounds)

        command.call(["proj"], save_position: false)

        expect(window_manager).not_to have_received(:all_window_bounds)
      end
    end
  end
end
