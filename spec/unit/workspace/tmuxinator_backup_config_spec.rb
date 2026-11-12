require "spec_helper"

RSpec.describe Workspace::TmuxinatorBackupConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  let(:error_output) { StringIO.new }
  subject(:config) do
    described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), error_output: error_output)
  end

  it "keeps 20 batches with no age limit by default" do
    expect([config.keep, config.max_age]).to eq([20, nil])
    expect(error_output.string).to be_empty
  end

  it "reads tmuxinator.backups.keep and max_age, the age in seconds" do
    global["tmuxinator"] = {"backups" => {"keep" => 5, "max_age" => "48h"}}

    expect([config.keep, config.max_age]).to eq([5, 48 * 3600])
  end

  it "warns and uses the default for a value `config set` would refuse" do
    global["tmuxinator"] = {"backups" => {"keep" => 0, "max_age" => "soon"}}

    expect([config.keep, config.max_age]).to eq([20, nil])
    expect(error_output.string).to include("Warning: tmuxinator.backups.keep:", "Using 20.", "Warning: tmuxinator.backups.max_age:", "Using no limit.")
  end

  it "warns and uses the default when the config file can't be parsed" do
    allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

    expect(config.keep).to eq(20)
    expect(error_output.string).to include("Warning: tmuxinator.backups.keep")
  end
end
