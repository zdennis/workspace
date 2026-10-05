require "spec_helper"

RSpec.describe Workspace::WorkflowConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  subject(:config) { described_class.new(project_settings: project_settings) }

  it "defaults to binding, orchestrator and commits" do
    expect(config.default_packs).to eq(%w[binding orchestrator commits])
  end

  it "reads workflows.defaults.include as `config set` writes it, or as a list written by hand" do
    global["workflows"] = {"defaults" => {"include" => "binding, commits"}}
    expect(config.default_packs).to eq(%w[binding commits])

    global["workflows"] = {"defaults" => {"include" => %w[binding review]}}
    expect(config.default_packs).to eq(%w[binding review])
  end

  it "uses the default for a value `config set` would refuse" do
    ["", "Not A Pack!", [], [1], {"a" => 1}].each do |bad|
      global["workflows"] = {"defaults" => {"include" => bad}}
      expect(config.default_packs).to eq(%w[binding orchestrator commits])
    end
  end

  it "lets a config file that can't be parsed raise" do
    allow(project_settings).to receive(:load_global).and_raise(Workspace::ConfigParseError.new("/c/config.yml", "bad"))

    expect { config.default_packs }.to raise_error(Workspace::ConfigParseError)
  end
end
