require "spec_helper"

RSpec.describe Workspace::EventsConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  let(:error_output) { StringIO.new }
  subject(:config) do
    described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), error_output: error_output)
  end

  it "defaults to 5MB" do
    expect(config.rotate_size).to eq(5 * 1024 * 1024)
    expect(error_output.string).to be_empty
  end

  it "reads events.rotate_size as a size or a byte count" do
    global["events"] = {"rotate_size" => "1MB"}
    expect(config.rotate_size).to eq(1_048_576)

    global["events"] = {"rotate_size" => 200_000}
    expect(config.rotate_size).to eq(200_000)
  end

  it "warns and uses the default for a value `config set` would refuse" do
    global["events"] = {"rotate_size" => "10KB"}

    expect(config.rotate_size).to eq(5 * 1024 * 1024)
    expect(error_output.string).to match(/Warning: events.rotate_size: .*at least 64KB.*Using 5MB/)
  end

  it "warns and uses the default when the config file can't be parsed" do
    allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

    expect(config.rotate_size).to eq(5 * 1024 * 1024)
    expect(error_output.string).to include("Warning: events.rotate_size")
  end
end
