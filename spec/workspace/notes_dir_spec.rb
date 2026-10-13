require "spec_helper"

RSpec.describe Workspace::NotesDir do
  let(:git) { Workspace::Git.new }
  let(:branch) { "feature/login" }
  subject(:notes_dir) { described_class.new(git: git, home: "/home/me") }

  before { allow(git).to receive(:worktree_branch).with("/src/api/.worktrees/x").and_return(branch) }

  describe "#default_path" do
    def path(template, root: "/src/api/.worktrees/x", workspace: "api.worktree-x")
      notes_dir.default_path(template, root: root, workspace: workspace)
    end

    it "is tmp/workspace-notes inside the checkout when no template is set" do
      expect(path(nil)).to eq("/src/api/.worktrees/x/tmp/workspace-notes")
    end

    it "is nil without a checkout root to put a relative path in" do
      expect(path(nil, root: nil)).to be_nil
      expect(path("notes", root: nil)).to be_nil
    end

    it "puts a relative template under the checkout root" do
      expect(path("tmp/n")).to eq("/src/api/.worktrees/x/tmp/n")
    end

    it "keeps an absolute template and expands ~/ against the home directory" do
      expect(path("/notes/api")).to eq("/notes/api")
      expect(path("~/notes/api")).to eq("/home/me/notes/api")
    end

    it "fills {workspace} and {branch} with filesystem-safe text" do
      expect(path("/notes/{workspace}/{branch}")).to eq("/notes/api.worktree-x/feature-login")
    end

    it "is nil when the template needs a branch and the checkout has none" do
      allow(git).to receive(:worktree_branch).with("/src/api/.worktrees/x").and_return(nil)
      expect(path("/notes/{branch}")).to be_nil
      expect(path("/notes/{workspace}")).to eq("/notes/api.worktree-x")
    end

    it "is nil for {branch} when the checkout root is unknown" do
      expect(path("/notes/{branch}", root: nil)).to be_nil
      expect(path("/notes/{workspace}", root: nil)).to eq("/notes/api.worktree-x")
    end

    it "does not ask git for a branch when the template has no {branch}" do
      expect(git).not_to receive(:worktree_branch)
      path("/notes/{workspace}")
    end
  end

  describe "#resolve" do
    def resolve(stored: nil, template: nil, worktree: true)
      notes_dir.resolve(stored: stored, template: template, worktree: worktree, root: "/src/api/.worktrees/x", workspace: "api.worktree-x")
    end

    it "uses a worktree's own value" do
      expect(resolve(stored: "/mine")).to have_attributes(path: "/mine", source: "worktree")
    end

    it "cleans .. segments and a trailing slash from the stored value" do
      expect(resolve(stored: "/a/b/../c/").path).to eq("/a/c")
    end

    it "uses the project's value for a main checkout" do
      expect(resolve(stored: "/shared", worktree: false)).to have_attributes(path: "/shared", source: "project")
    end

    it "falls back to the project default, then to tmp/workspace-notes" do
      expect(resolve(template: "~/n/{workspace}")).to have_attributes(path: "/home/me/n/api.worktree-x", source: "default")
      expect(resolve).to have_attributes(path: "/src/api/.worktrees/x/tmp/workspace-notes", source: "default")
    end

    it "gives a nil path with source default when nothing can be computed" do
      result = notes_dir.resolve(stored: nil, template: nil, worktree: true, root: nil, workspace: "api.worktree-x")
      expect(result).to have_attributes(path: nil, source: "default")
    end
  end
end
