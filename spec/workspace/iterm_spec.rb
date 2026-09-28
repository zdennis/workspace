RSpec.describe Workspace::ITerm do
  let(:config) { Workspace::Config.new }
  let(:output) { StringIO.new }

  describe "#find_existing_sessions" do
    it "returns empty hash when state is empty" do
      iterm = described_class.new(config: config, output: output)
      result = iterm.find_existing_sessions({}, live_sessions: {"uid1" => "100"})
      expect(result).to eq({})
    end

    it "returns matching projects whose UIDs exist in live sessions" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {"unique_id" => "uid1"},
        "projectB" => {"unique_id" => "uid2"},
        "projectC" => {"unique_id" => "uid3"}
      }
      live = {"uid1" => "100", "uid3" => "200"}

      result = iterm.find_existing_sessions(state, live_sessions: live)
      expect(result).to eq({"projectA" => "uid1", "projectC" => "uid3"})
    end

    it "skips projects with no unique_id" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {"unique_id" => "uid1"},
        "projectB" => {}
      }
      live = {"uid1" => "100"}

      result = iterm.find_existing_sessions(state, live_sessions: live)
      expect(result).to eq({"projectA" => "uid1"})
    end

    it "returns empty hash when no UIDs match live sessions" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {"unique_id" => "uid1"}
      }
      live = {"uid999" => "100"}

      result = iterm.find_existing_sessions(state, live_sessions: live)
      expect(result).to eq({})
    end
  end

  describe "#find_launcher_window_id" do
    it "returns window ID for the first matching UID" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {"unique_id" => "uid1"},
        "projectB" => {"unique_id" => "uid2"}
      }
      live = {"uid1" => "100", "uid2" => "200"}

      result = iterm.find_launcher_window_id(state, live_sessions: live)
      expect(result).to eq("100")
    end

    it "returns nil when no UIDs match live sessions" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {"unique_id" => "uid1"}
      }
      live = {"uid999" => "100"}

      result = iterm.find_launcher_window_id(state, live_sessions: live)
      expect(result).to be_nil
    end

    it "skips entries without unique_id" do
      iterm = described_class.new(config: config, output: output)
      state = {
        "projectA" => {},
        "projectB" => {"unique_id" => "uid2"}
      }
      live = {"uid2" => "200"}

      result = iterm.find_launcher_window_id(state, live_sessions: live)
      expect(result).to eq("200")
    end

    it "returns nil for empty state" do
      iterm = described_class.new(config: config, output: output)
      result = iterm.find_launcher_window_id({}, live_sessions: {"uid1" => "100"})
      expect(result).to be_nil
    end
  end

  describe "without osascript" do
    it "answers as if iTerm2 had no sessions instead of raising" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "osascript")
      iterm = described_class.new(config: config, output: output)

      expect(iterm.session_map).to eq({})
    end
  end

  describe "AppleScript injection safety" do
    let(:iterm) { described_class.new(config: config, output: output) }

    def captured_script
      script = nil
      allow(Open3).to receive(:capture3) do |*args|
        script = args.last
        ["", "", instance_double(Process::Status, success?: true)]
      end
      yield
      script
    end

    # A command containing a double quote, a backslash, a `$(...)`
    # substitution, a backtick and a space, all of which would otherwise
    # break out of the AppleScript string literal or execute in the shell.
    let(:dangerous_command) { %(echo "hi" && $(rm -rf /) `x` a\\b) }

    it "escapes a dangerous command sent to a new launcher window" do
      script = captured_script { iterm.create_launcher_panes(["proj"], {"proj" => dangerous_command}) }

      expect(script).to include(%(write text "echo \\"hi\\" && $(rm -rf /) `x` a\\\\b"))
    end

    it "escapes a dangerous command sent to an existing launcher window" do
      script = captured_script do
        iterm.create_launcher_panes(["proj"], {"proj" => dangerous_command}, launcher_wid: "99")
      end

      expect(script).to include(%(write text "echo \\"hi\\" && $(rm -rf /) `x` a\\\\b"))
    end

    it "escapes a dangerous command sent via relaunch_in_session" do
      script = captured_script { iterm.relaunch_in_session("uid-1", dangerous_command) }

      expect(script).to include(%(write text "echo \\"hi\\" && $(rm -rf /) `x` a\\\\b"))
    end

    it "escapes a dangerous project name used in the launcher output line" do
      script = captured_script { iterm.create_launcher_panes(["pro\"ject"], {"pro\"ject" => "cmd"}) }

      expect(script).to include(%("pro\\"ject"))
    end
  end
end
