require "spec_helper"
require "stringio"

RSpec.describe Workspace::PlanConfig do
  let(:error_output) { StringIO.new }
  let(:settings) { instance_double(Workspace::ProjectSettings) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings), error_output: error_output) }

  it "gives 300 seconds when the key is unset" do
    allow(settings).to receive(:load).with("api").and_return({})

    expect(config.stall_seconds_for("api")).to eq(300)
  end

  it "treats an empty key as unset: the default and no warning" do
    allow(settings).to receive(:load).with("api").and_return("plan" => {"stall_seconds" => nil})

    expect(config.stall_seconds_for("api")).to eq(300)
    expect(error_output.string).to eq("")
  end

  it "reads a duration the project set" do
    allow(settings).to receive(:load).with("api").and_return("plan" => {"stall_seconds" => "10m"})

    expect(config.stall_seconds_for("api")).to eq(600)
  end

  it "reads a worktree's value from its parent project" do
    allow(settings).to receive(:load).with("api").and_return("plan" => {"stall_seconds" => 90})

    expect(config.stall_seconds_for("api.worktree-x")).to eq(90)
  end

  it "falls back to the default with a warning for a value config set would refuse" do
    allow(settings).to receive(:load).with("api").and_return("plan" => {"stall_seconds" => "soon"})

    expect(config.stall_seconds_for("api")).to eq(300)
    expect(error_output.string).to include("invalid plan.stall_seconds for 'api'")
  end

  it "falls back to the default with a warning when the config file can't be parsed" do
    allow(settings).to receive(:load).and_raise(Workspace::ConfigParseError.new("/c/api.yml", "not valid YAML"))

    expect(config.stall_seconds_for("api")).to eq(300)
    expect(error_output.string).to include("Using 300s for plan.stall_seconds")
  end

  it "gives the default for a plan block without the key" do
    allow(settings).to receive(:load).and_return("plan" => {})

    expect(config.stall_seconds_for("api")).to eq(300)
  end

  it "reads a plan block that is not a mapping as unset" do
    allow(settings).to receive(:load).and_return("plan" => "oops")

    expect(config.stall_seconds_for("api")).to eq(300)
  end

  it "ignores a worktree's own value" do
    allow(settings).to receive(:load).with("api").and_return("plan" => {"stall_seconds" => "10m"})
    allow(settings).to receive(:load).with("api.worktree-x").and_return("plan" => {"stall_seconds" => "1m"})

    expect(config.stall_seconds_for("api.worktree-x")).to eq(600)
  end
end
