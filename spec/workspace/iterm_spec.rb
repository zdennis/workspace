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
end
