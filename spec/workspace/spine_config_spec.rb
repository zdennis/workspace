require "spec_helper"

RSpec.describe Workspace::SpineConfig do
  let(:project_settings) { instance_double(Workspace::ProjectSettings) }
  subject(:config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }

  def files(global: {}, project: {}, worktree: {})
    allow(project_settings).to receive(:load_global).and_return(global)
    allow(project_settings).to receive(:load).with("app").and_return(project)
    allow(project_settings).to receive(:load).with("app.worktree-x").and_return(worktree)
  end

  describe "#template" do
    it "is default, from the default, when no layer sets it" do
      files
      expect(config.template("app.worktree-x")).to eq("name" => "default", "source" => "default")
    end

    it "names the nearest layer that sets it: worktree, then project, then global" do
      files(global: {"spine" => {"template" => "g"}}, project: {"spine" => {"template" => "p"}}, worktree: {"spine" => {"template" => "w"}})
      expect(config.template("app.worktree-x")).to eq("name" => "w", "source" => "worktree")

      files(global: {"spine" => {"template" => "g"}}, project: {"spine" => {"template" => "p"}})
      expect(config.template("app.worktree-x")).to eq("name" => "p", "source" => "project")
      expect(config.template("app")).to eq("name" => "p", "source" => "project")

      files(global: {"spine" => {"template" => "g"}})
      expect(config.template("app.worktree-x")).to eq("name" => "g", "source" => "global")
    end

    it "ignores a blank or non-string value" do
      [" ", 5, true].each do |value|
        files(project: {"spine" => {"template" => value}})
        expect(config.template("app")).to eq("name" => "default", "source" => "default")
      end
    end
  end

  describe "#auto?" do
    it "is false unless the nearest layer says true, as a boolean or the string config set stores" do
      files
      expect(config.auto?("app")).to be(false)
      [true, "true"].each do |value|
        files(project: {"spine" => {"auto" => value}})
        expect(config.auto?("app")).to be(true)
      end
      files(project: {"spine" => {"auto" => "true"}}, worktree: {"spine" => {"auto" => "false"}})
      expect(config.auto?("app.worktree-x")).to be(false)
      files(global: {"spine" => {"auto" => "true"}})
      expect(config.auto?("app.worktree-x")).to be(true)
    end
  end
end
