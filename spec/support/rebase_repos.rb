require "open3"
require "tmpdir"
require "fileutils"

# Throwaway repositories for the rebase and push specs: a bare origin, a main
# checkout (`repo`, on `main`) and a linked worktree (`wt`) on `feature/x`
# that branched from main's first commit. Nothing outside the temp directory
# is touched and nothing reaches the network.
module RebaseRepos
  def self.included(base)
    base.around do |example|
      Dir.mktmpdir("rebase-spec") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end
    base.let(:remote) { File.join(@dir, "remote.git") }
    base.let(:repo) { File.join(@dir, "api") }
    base.let(:wt) { File.join(@dir, "api.worktree-x") }
    base.let(:other) { File.join(@dir, "other") }
    base.before { build_repos }
  end

  def sh(*args, dir: repo)
    out, st = Open3.capture2e("git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{out}" unless st.success?
    out
  end

  def sh_status(*args, dir: repo)
    out, st = Open3.capture2e("git", "-C", dir, *args)
    [out, st.success?]
  end

  def commit_file(file, content, message, dir: repo)
    File.write(File.join(dir, file), content)
    sh("add", file, dir: dir)
    sh("commit", "-q", "-m", message, dir: dir)
  end

  def rev(ref, dir: repo) = sh("rev-parse", ref, dir: dir).strip

  def build_repos
    sh("init", "-q", "--bare", "-b", "main", remote, dir: @dir)
    FileUtils.mkdir_p(repo)
    sh("init", "-q", "-b", "main")
    sh("config", "user.name", "t")
    sh("config", "user.email", "t@example.com")
    commit_file("base.txt", "base\n", "init")
    sh("remote", "add", "origin", remote)
    sh("push", "-q", "-u", "origin", "main")
    sh("worktree", "add", "-q", "-b", "feature/x", wt)
    commit_file("feature.txt", "feature\n", "feature work", dir: wt)
  end

  # A second clone, to push commits the first one does not have.
  def clone_other
    sh("clone", "-q", remote, other, dir: @dir)
    sh("config", "user.name", "o", dir: other)
    sh("config", "user.email", "o@example.com", dir: other)
  end
end
