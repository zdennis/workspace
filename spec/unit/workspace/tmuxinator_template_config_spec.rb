require "spec_helper"

RSpec.describe Workspace::TmuxinatorTemplateConfig do
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  def files(global: {}, project: {}, worktree: {})
    allow(project_settings).to receive(:load_global).and_return(global)
    allow(project_settings).to receive(:load).with("app").and_return(project)
    allow(project_settings).to receive(:load).with("app.worktree-x").and_return(worktree)
  end

  def tm(**keys)
    {"tmuxinator" => keys.transform_keys(&:to_s)}
  end

  it "is default, from the default, when no layer sets it" do
    files
    expect(config.name(:project, workspace: "app")).to eq("name" => "default", "source" => "default")
    expect(config.name(:worktree, workspace: "app.worktree-x")).to eq("name" => "default", "source" => "default")
  end

  it "names the nearest layer that sets template: worktree, then project, then global" do
    files(global: tm(template: "g"), project: tm(template: "p"), worktree: tm(template: "w"))
    expect(config.name(:project, workspace: "app.worktree-x")).to eq("name" => "w", "source" => "worktree")
    files(global: tm(template: "g"), project: tm(template: "p"))
    expect(config.name(:project, workspace: "app")).to eq("name" => "p", "source" => "project")
    files(global: tm(template: "g"))
    expect(config.name(:project, workspace: "app")).to eq("name" => "g", "source" => "global")
  end

  it "reads the global file alone for a nil workspace" do
    allow(project_settings).to receive(:load_global).and_return(tm(template: "g"))
    expect(config.name(:project, workspace: nil)).to eq("name" => "g", "source" => "global")
  end

  it "lets worktree_template win for the worktree kind only, else follows template" do
    files(project: tm(template: "p", worktree_template: "wt"))
    expect(config.name(:worktree, workspace: "app")).to eq("name" => "wt", "source" => "project")
    expect(config.name(:project, workspace: "app")).to eq("name" => "p", "source" => "project")
    files(project: tm(template: "p"))
    expect(config.name(:worktree, workspace: "app")).to eq("name" => "p", "source" => "project")
  end

  it "lets a worktree layer's worktree_template win over the project layer's template" do
    files(project: tm(template: "p"), worktree: tm(worktree_template: "w"))
    expect(config.name(:worktree, workspace: "app.worktree-x")).to eq("name" => "w", "source" => "worktree")
    expect(config.name(:project, workspace: "app.worktree-x")).to eq("name" => "p", "source" => "project")
  end

  it "treats a stored value that is not a valid name as unset, falling to the next key or the default" do
    files(project: tm(template: "p", worktree_template: "Bad Name"))
    expect(config.name(:worktree, workspace: "app")).to eq("name" => "p", "source" => "project")
    files(project: tm(template: "Bad Name"))
    expect(config.name(:project, workspace: "app")).to eq("name" => "default", "source" => "default")
  end

  it "ignores a blank or non-string value" do
    [" ", 5, true].each do |value|
      files(project: tm(template: value))
      expect(config.name(:worktree, workspace: "app")).to eq("name" => "default", "source" => "default")
    end
  end
end
