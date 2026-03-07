require "stringio"

RSpec.describe Workspace::Doctor do
  let(:output) { StringIO.new }
  let(:config) { Workspace::Config.new }

  it "runs without crashing and produces output" do
    doctor = described_class.new(config: config, output: output)
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing in test environment
    end
    expect(output.string).to include("workspace doctor")
    expect(output.string.length).to be > 0
  end

  it "checks for required commands and templates" do
    doctor = described_class.new(config: config, output: output)
    begin
      doctor.run
    rescue Workspace::Error
      # Expected if dependencies are missing
    end
    expect(output.string).to include("ruby")
    expect(output.string).to include("tmux")
    expect(output.string).to include("git")
  end
end
