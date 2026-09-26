require "spec_helper"
require "stringio"

RSpec.describe Workspace::Commands::Parent do
  let(:output) { StringIO.new }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  subject(:command) { described_class.new(lineage: lineage, project_config: project_config, output: output) }

  def info(**overrides)
    defaults = {name: "app", path: "/Users/z/src/app", git_common_dir: "/Users/z/src/app/.git", is_worktree: true, worktree: "app.worktree-login"}
    Workspace::WorkspaceLineage::Lineage.new(**defaults.merge(overrides))
  end

  describe "#call" do
    it "prints the name by default, resolving from cwd" do
      allow(lineage).to receive(:resolve).with(cwd: Dir.pwd).and_return(info)

      command.call

      expect(output.string).to eq("app\n")
    end

    it "prints its own name for a non-worktree workspace" do
      allow(lineage).to receive(:resolve).with(cwd: Dir.pwd).and_return(info(is_worktree: false, worktree: nil))

      command.call

      expect(output.string).to eq("app\n")
    end

    it "prints the path with --path" do
      allow(lineage).to receive(:resolve).with(cwd: Dir.pwd).and_return(info)

      command.call(nil, path: true)

      expect(output.string).to eq("/Users/z/src/app\n")
    end

    it "prints JSON with --json" do
      allow(lineage).to receive(:resolve).with(cwd: Dir.pwd).and_return(info)

      command.call(nil, json: true)

      parsed = JSON.parse(output.string)
      expect(parsed).to eq(
        "name" => "app",
        "path" => "/Users/z/src/app",
        "git_common_dir" => "/Users/z/src/app/.git",
        "is_worktree" => true,
        "worktree" => "app.worktree-login"
      )
    end

    it "resolves a given project name via project_config's root" do
      allow(project_config).to receive(:project_root_for).with("app.worktree-login").and_return("/Users/z/src/app/.worktrees/login")
      allow(lineage).to receive(:resolve).with(cwd: "/Users/z/src/app/.worktrees/login").and_return(info)

      command.call("app.worktree-login")

      expect(output.string).to eq("app\n")
    end

    it "raises when the given project name is unknown" do
      allow(project_config).to receive(:project_root_for).with("nope").and_return(nil)

      expect { command.call("nope") }.to raise_error(Workspace::Error, /Unknown project 'nope'/)
    end

    it "raises when nothing resolves" do
      allow(lineage).to receive(:resolve).with(cwd: Dir.pwd).and_return(info(name: nil))

      expect { command.call }.to raise_error(Workspace::Error, /Could not resolve/)
    end
  end
end
