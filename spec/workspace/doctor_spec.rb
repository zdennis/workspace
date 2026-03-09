require "stringio"

RSpec.describe Workspace::Doctor do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }
  let(:state) { CLITestHelpers::FakeState.new }

  it "runs without crashing and produces output" do
    doctor = described_class.new(config: config, state: state, output: output)
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing in test environment
    end
    expect(output.string).to include("workspace doctor")
    expect(output.string.length).to be > 0
  end

  it "checks for required commands and templates" do
    doctor = described_class.new(config: config, state: state, output: output)
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing
    end
    expect(output.string).to include("ruby")
    expect(output.string).to include("tmux")
    expect(output.string).to include("git")
  end

  describe "duplicate window ID detection" do
    it "reports no issues when window IDs are unique" do
      state["proj-a"] = {"iterm_window_id" => 100}
      state["proj-b"] = {"iterm_window_id" => 200}

      doctor = described_class.new(config: config, state: state, output: output)
      begin
        doctor.run
      rescue Workspace::Error
        # May fail on missing dependencies
      end
      expect(output.string).to include("no duplicate window IDs")
    end

    it "detects duplicate window IDs" do
      state["growth-engine"] = {"iterm_window_id" => 318}
      state["growth-engine-migrations"] = {"iterm_window_id" => 318}

      doctor = described_class.new(config: config, state: state, output: output)
      begin
        doctor.run
      rescue Workspace::Error
        # Expected
      end
      expect(output.string).to include("duplicate window IDs detected")
      expect(output.string).to include("window 318 claimed by: growth-engine, growth-engine-migrations")
    end
  end
end
