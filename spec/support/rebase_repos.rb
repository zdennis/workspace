require "open3"
require "tmpdir"
require "fileutils"

# Throwaway repositories for the rebase and push specs: a bare origin, a main
# checkout (`repo`, on `main`) and a linked worktree (`wt`) on `feature/x`
# that branched from main's first commit. Nothing outside the temp directory
# is touched and nothing reaches the network.
module RebaseRepos
  # Git starts detached background maintenance after fetch, rebase, commit and
  # push; it writes `objects/maintenance.lock` while mktmpdir deletes the tree.
  # Env config reaches the specs own git calls and the ones the code under test makes.
  NO_MAINTENANCE = {
    "GIT_CONFIG_COUNT" => "3",
    "GIT_CONFIG_KEY_0" => "gc.auto", "GIT_CONFIG_VALUE_0" => "0",
    "GIT_CONFIG_KEY_1" => "maintenance.auto", "GIT_CONFIG_VALUE_1" => "false",
    "GIT_CONFIG_KEY_2" => "gc.autoDetach", "GIT_CONFIG_VALUE_2" => "false"
  }.freeze

  def self.included(base)
    base.around do |example|
      saved = NO_MAINTENANCE.keys.to_h { |k| [k, ENV[k]] }
      NO_MAINTENANCE.each { |k, v| ENV[k] = v }
      begin
        Dir.mktmpdir("rebase-spec") do |dir|
          @dir = File.realpath(dir)
          example.run
        end
      ensure
        saved.each { |k, v| ENV[k] = v }
      end
    end
    base.let(:remote) { File.join(@dir, "remote.git") }
    base.let(:repo) { File.join(@dir, "api") }
    base.let(:wt) { File.join(@dir, "api.worktree-x") }
    base.let(:other) { File.join(@dir, "other") }
    base.before { copy_repos }
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

  def build_repos(root)
    origin = File.join(root, "remote.git")
    main = File.join(root, "api")
    linked = File.join(root, "api.worktree-x")
    sh("init", "-q", "--bare", "-b", "main", origin, dir: root)
    FileUtils.mkdir_p(main)
    sh("init", "-q", "-b", "main", dir: main)
    sh("config", "user.name", "t", dir: main)
    sh("config", "user.email", "t@example.com", dir: main)
    commit_file("base.txt", "base\n", "init", dir: main)
    sh("remote", "add", "origin", origin, dir: main)
    sh("push", "-q", "-u", "origin", "main", dir: main)
    sh("worktree", "add", "-q", "-b", "feature/x", linked, dir: main)
    commit_file("feature.txt", "feature\n", "feature work", dir: linked)
  end

  # The repositories built once (in `build_repos`) and copied into this example.
  def copy_repos
    RepoTemplate.copy(:rebase, to: @dir) { |root| build_repos(root) }
  end

  # A second clone, to push commits the first one does not have.
  def clone_other
    sh("clone", "-q", remote, other, dir: @dir)
    sh("config", "user.name", "o", dir: other)
    sh("config", "user.email", "o@example.com", dir: other)
  end
end
