require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::LockNamespace do
  let(:state_home) { Dir.mktmpdir("ws-lock-namespace-state") }
  let(:config) { Workspace::Config.new }

  before { allow(ENV).to receive(:fetch).and_call_original }
  before { allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", anything).and_return(state_home) }

  after { FileUtils.remove_entry(state_home) if File.directory?(state_home) }

  subject(:namespace) { described_class.new(config: config) }

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

  describe "git repos" do
    it "shares one namespace across two worktrees of the same repo" do
      root = Dir.mktmpdir("ws-lock-repo")
      init_repo(root)
      worktree_path = File.join(root, ".worktrees", "wt1")
      FileUtils.mkdir_p(File.dirname(worktree_path))
      git("worktree", "add", "-b", "wt1-branch", worktree_path, chdir: root)

      root_ns = namespace.resolve(cwd: root)
      worktree_ns = namespace.resolve(cwd: worktree_path)

      expect(worktree_ns[:key]).to eq(root_ns[:key])
      expect(worktree_ns[:dir]).to eq(root_ns[:dir])
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "resolves same-named repos at different paths to different namespaces" do
      repo_a = Dir.mktmpdir("ws-lock-repo-a")
      repo_b = Dir.mktmpdir("ws-lock-repo-b")
      begin
        FileUtils.mv(repo_a, File.join(File.dirname(repo_a), "app"))
        repo_a = File.join(File.dirname(repo_a), "app")
        FileUtils.mv(repo_b, File.join(File.dirname(repo_b), "app-2"))
        repo_b = File.join(File.dirname(repo_b), "app-2")
        init_repo(repo_a)
        init_repo(repo_b)

        expect(namespace.resolve(cwd: repo_a)[:key]).not_to eq(namespace.resolve(cwd: repo_b)[:key])
      ensure
        FileUtils.remove_entry(repo_a) if File.directory?(repo_a)
        FileUtils.remove_entry(repo_b) if File.directory?(repo_b)
      end
    end

    it "derives the display name from the .workspace-project marker, split on .worktree-" do
      root = Dir.mktmpdir("ws-lock-repo-marker")
      init_repo(root)
      worktree_path = File.join(root, ".worktrees", "wt1")
      FileUtils.mkdir_p(worktree_path)
      File.write(File.join(worktree_path, ".workspace-project"), "myapp.worktree-wt1")

      expect(namespace.resolve(cwd: worktree_path)[:display]).to eq("myapp")
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end
  end

  describe "non-git projects" do
    it "keys the namespace on the project name" do
      dir = Dir.mktmpdir("ws-lock-plainproject")

      result = namespace.resolve(cwd: dir)

      expect(result[:key]).to eq(Workspace::ProjectConfig.name_from_path(dir))
      expect(result[:display]).to eq(Workspace::ProjectConfig.name_from_path(dir))
    ensure
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end
  end

  it "suffixes the store directory with a 12-hex-char sha1" do
    dir = Dir.mktmpdir("ws-lock-plainproject-sha1")

    result = namespace.resolve(cwd: dir)

    expect(File.basename(result[:dir])).to match(/-[0-9a-f]{12}\z/)
  ensure
    FileUtils.remove_entry(dir) if File.directory?(dir)
  end

  it "puts the store directory under the configured lock_dir" do
    dir = Dir.mktmpdir("ws-lock-plainproject-2")

    result = namespace.resolve(cwd: dir)

    expect(result[:dir]).to start_with(config.lock_dir)
  ensure
    FileUtils.remove_entry(dir) if File.directory?(dir)
  end
end
