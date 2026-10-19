require "spec_helper"

RSpec.describe Workspace::HooksConfig do
  let(:global) { {} }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  let(:error_output) { StringIO.new }
  subject(:config) do
    described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), error_output: error_output)
  end

  it "installs Codex's hooks by default" do
    expect(config.codex_install?).to be true
    expect(error_output.string).to be_empty
  end

  it "reads codex.hooks.install false" do
    global["codex"] = {"hooks" => {"install" => "false"}}
    expect(config.codex_install?).to be false
  end

  it "reads a YAML boolean" do
    global["codex"] = {"hooks" => {"install" => false}}
    expect(config.codex_install?).to be false
  end

  it "warns and installs for a value `config set` would refuse" do
    global["codex"] = {"hooks" => {"install" => "maybe"}}

    expect(config.codex_install?).to be true
    expect(error_output.string).to include("Warning: codex.hooks.install:")
  end

  it "only turns off Codex, never Claude Code" do
    global["codex"] = {"hooks" => {"install" => "false"}}

    expect(config.install_user_hooks?(Workspace::AgentProvider.find("codex"))).to be false
    expect(config.install_user_hooks?(Workspace::AgentProvider.find("claude"))).to be true
  end
end
