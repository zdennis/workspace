require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkspaceLineage do
  subject(:lineage) { described_class.new }

  def git(*args, chdir:)
    system("git", *args, chdir: chdir, out: File::NULL, err: File::NULL)
  end

  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    git("init", "-q", chdir: dir)
    git("config", "user.email", "test@example.com", chdir: dir)
    git("config", "user.name", "Test", chdir: dir)
    File.write(File.join(dir, "README"), "x")
    git("add", "README", chdir: dir)
    git("commit", "-q", "-m", "init", chdir: dir)
  end

  describe ".split_worktree_name" do
    it "splits a worktree config name on the separator" do
      expect(described_class.split_worktree_name("app.worktree-login")).to eq(["app", "login"])
    end

    it "returns nil for a non-worktree config name" do
      expect(described_class.split_worktree_name("app")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.split_worktree_name(nil)).to be_nil
    end
  end

  describe "#resolve" do
    it "resolves a non-worktree git repo to itself" do
      root = Dir.mktmpdir("ws-lineage-repo")
      init_repo(root)

      info = lineage.resolve(cwd: root)

      expect(info.name).to eq(Workspace::WorkspaceLineage.name_from_path(root))
      expect(File.realpath(info.path)).to eq(File.realpath(root))
      expect(info.is_worktree).to be false
      expect(info.worktree).to be_nil
      expect(info.git_common_dir).not_to be_nil
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "resolves a linked worktree via git-common-dir when there is no marker" do
      root = Dir.mktmpdir("ws-lineage-repo2")
      init_repo(root)
      worktree_path = File.join(root, ".worktrees", "wt1")
      FileUtils.mkdir_p(File.dirname(worktree_path))
      git("worktree", "add", "-b", "wt1-branch", worktree_path, chdir: root)

      info = lineage.resolve(cwd: worktree_path)

      expect(info.is_worktree).to be true
      expect(info.name).to eq(Workspace::WorkspaceLineage.name_from_path(root))
      expect(File.realpath(info.path)).to eq(File.realpath(root))
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "prefers the .workspace-project marker, split on .worktree-, over git" do
      root = Dir.mktmpdir("ws-lineage-repo3")
      init_repo(root)
      worktree_path = File.join(root, ".worktrees", "wt1")
      FileUtils.mkdir_p(File.dirname(worktree_path))
      git("worktree", "add", "-b", "wt1-branch", worktree_path, chdir: root)
      File.write(File.join(worktree_path, ".workspace-project"), "myapp.worktree-wt1")

      info = lineage.resolve(cwd: worktree_path)

      expect(info.name).to eq("myapp")
      expect(info.worktree).to eq("myapp.worktree-wt1")
      expect(info.is_worktree).to be true
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "walks up parent directories to find the marker" do
      root = Dir.mktmpdir("ws-lineage-repo4")
      init_repo(root)
      worktree_path = File.join(root, ".worktrees", "wt1")
      nested = File.join(worktree_path, "src", "lib")
      FileUtils.mkdir_p(nested)
      File.write(File.join(worktree_path, ".workspace-project"), "myapp.worktree-wt1")

      info = lineage.resolve(cwd: nested)

      expect(info.name).to eq("myapp")
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "falls back to the path-derived name for non-git directories" do
      dir = Dir.mktmpdir("ws-lineage-plain")

      info = lineage.resolve(cwd: dir)

      expect(info.name).to eq(Workspace::WorkspaceLineage.name_from_path(dir))
      expect(info.git_common_dir).to be_nil
      expect(info.is_worktree).to be false
    ensure
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end

    it "does not raise when git is missing" do
      dir = Dir.mktmpdir("ws-lineage-nogit")
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      info = lineage.resolve(cwd: dir)

      expect(info.name).to eq(Workspace::WorkspaceLineage.name_from_path(dir))
    ensure
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end
  end

  describe "#write_marker" do
    it "writes a marker readable back by #resolve" do
      dir = Dir.mktmpdir("ws-lineage-write")

      lineage.write_marker(dir, "app.worktree-feature")

      expect(File.read(File.join(dir, ".workspace-project")).strip).to eq("app.worktree-feature")
      expect(lineage.resolve(cwd: dir).worktree).to eq("app.worktree-feature")
    ensure
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end

    it "does nothing when the directory doesn't exist" do
      expect { lineage.write_marker("/nonexistent/path", "app.worktree-x") }.not_to raise_error
    end
  end
end
