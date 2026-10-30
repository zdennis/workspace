require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowGuard do
  around do |example|
    Dir.mktmpdir("wf-guard") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "repo") }
  subject(:guard) { described_class.new }

  def git(*args, path: repo)
    out = IO.popen({"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"},
      ["git", "-C", path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args],
      err: File::NULL, &:read)
    raise "git #{args.join(" ")} failed" unless $?.success?
    out
  end

  def write(name, text = "x\n")
    path = File.join(repo, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  before do
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main")
    write("a.txt", "one\n")
    write("dir/b.txt", "two\n")
    git("add", "-A")
    git("commit", "-q", "-m", "start")
  end

  let!(:base) { guard.base(repo) }

  def check(scope = "unchanged")
    guard.check(repo, base, scope)
  end

  it "records HEAD and a snapshot, and passes a checkout nothing changed in" do
    expect(base["base_sha"]).to eq(git("rev-parse", "HEAD").strip)
    expect(base["base_guard"].keys).to eq(%w[config_sha256 hooks_sha256 hidden_sha256])
    expect(base["base_guard"].values).to all(match(/\A\h{64}\z/))
    expect(check).to be_nil
  end

  it "passes a new untracked file" do
    write("repro_spec.rb", "puts 1\n")

    expect(check).to be_nil
  end

  describe "no_commit" do
    it "is found when the run has no base commit" do
      expect(guard.check(repo, {"base_sha" => nil, "base_guard" => base["base_guard"]}, "unchanged")).to include("code" => "no_commit")
    end

    it "is found on an unborn branch, and in a directory that is no repository" do
      empty = File.join(@dir, "empty")
      FileUtils.mkdir_p(empty)
      git("init", "-q", "-b", "main", path: empty)

      expect(guard.base(empty)["base_sha"]).to be_nil
      expect(guard.check(empty, guard.base(empty), "unchanged")).to include("code" => "no_commit")
      expect(guard.check(@dir, guard.base(@dir), "config")).to include("code" => "no_commit")
    end
  end

  it "finds a commit as head_moved, naming both commits" do
    write("a.txt", "two\n")
    git("commit", "-q", "-am", "agent commit")

    expect(check).to include("code" => "head_moved", "base_sha" => base["base_sha"], "head" => git("rev-parse", "HEAD").strip)
    expect(check("config")).to be_nil
  end

  it "finds a checkout of another commit as head_moved" do
    git("checkout", "-q", "--detach", "HEAD")
    git("commit", "-q", "--allow-empty", "-m", "elsewhere")

    expect(check).to include("code" => "head_moved")
  end

  describe "operation_in_progress" do
    it "finds a bisect" do
      write("a.txt", "two\n")
      git("commit", "-q", "-am", "second")
      git("bisect", "start")
      git("bisect", "bad", "HEAD")
      git("bisect", "good", "HEAD~1")
      git("checkout", "-q", "main") if git("rev-parse", "HEAD").strip != git("rev-parse", "main").strip
      same_base = guard.base(repo)

      expect(guard.check(repo, same_base, "unchanged")).to include("code" => "operation_in_progress")
    end

    it "finds a bisect started and not yet given a bad commit" do
      git("bisect", "start")

      expect(check).to include("code" => "operation_in_progress")
    end

    it "finds a stopped rebase" do
      FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))

      expect(check).to include("code" => "operation_in_progress")
    end

    it "finds a merge in progress" do
      File.write(File.join(repo, ".git", "MERGE_HEAD"), "#{base["base_sha"]}\n")

      expect(check).to include("code" => "operation_in_progress")
    end

    it "is not looked for in the config scope" do
      git("bisect", "start")

      expect(check("config")).to be_nil
    end
  end

  describe "tracked_changed" do
    it "finds an unstaged change, naming the path" do
      write("a.txt", "changed\n")

      expect(check).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
    end

    it "finds a staged change" do
      write("dir/b.txt", "changed\n")
      git("add", "dir/b.txt")

      expect(check).to eq("code" => "tracked_changed", "paths" => ["dir/b.txt"])
    end

    it "finds a staged new file and a deleted file" do
      write("new.txt")
      git("add", "new.txt")
      File.delete(File.join(repo, "a.txt"))

      expect(check["paths"]).to contain_exactly("new.txt", "a.txt")
    end

    it "names a renamed file by its new path once" do
      git("mv", "a.txt", "renamed.txt")

      expect(check).to eq("code" => "tracked_changed", "paths" => ["renamed.txt"])
    end

    it "names at most 20 paths" do
      30.times { |n| write("many/f#{n}.txt") }
      git("add", "-A")
      git("commit", "-q", "-m", "many")
      fresh = guard.base(repo)
      30.times { |n| write("many/f#{n}.txt", "changed\n") }

      expect(guard.check(repo, fresh, "unchanged")["paths"].size).to eq(20)
    end

    it "is not looked for in the config scope" do
      write("a.txt", "changed\n")

      expect(check("config")).to be_nil
    end
  end

  describe "hidden_changed" do
    it "finds an edit hidden with assume-unchanged" do
      git("update-index", "--assume-unchanged", "a.txt")
      write("a.txt", "hidden edit\n")

      expect(check).to include("code" => "hidden_changed")
    end

    it "finds an edit hidden with skip-worktree" do
      git("update-index", "--skip-worktree", "a.txt")
      write("a.txt", "hidden edit\n")

      expect(check).to include("code" => "hidden_changed")
      expect(check("config")).to include("code" => "hidden_changed")
    end

    it "accepts flags that were already there when the run started, as in a sparse checkout" do
      git("update-index", "--skip-worktree", "dir/b.txt")
      sparse = guard.base(repo)

      expect(guard.check(repo, sparse, "unchanged")).to be_nil
    end

    it "finds a flag cleared after the run started" do
      git("update-index", "--skip-worktree", "dir/b.txt")
      sparse = guard.base(repo)
      git("update-index", "--no-skip-worktree", "dir/b.txt")

      expect(guard.check(repo, sparse, "unchanged")).to include("code" => "hidden_changed")
    end
  end

  describe "config_changed" do
    let(:marker) { File.join(@dir, "ran") }

    it "finds a core.fsmonitor set in the repository config, and never runs the command" do
      File.write(File.join(@dir, "fsmonitor.sh"), "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, File.join(@dir, "fsmonitor.sh"))
      git("config", "core.fsmonitor", File.join(@dir, "fsmonitor.sh"))

      expect(check).to include("code" => "config_changed")
      write("a.txt", "x\n")
      check
      expect(File.exist?(marker)).to be(false)
    end

    it "finds a core.hooksPath set in the repository config" do
      git("config", "core.hooksPath", File.join(@dir, "hooks"))

      expect(check).to include("code" => "config_changed")
    end

    it "finds a clean filter that lies about a tracked file, and never runs it" do
      File.write(File.join(@dir, "filter.sh"), "#!/bin/sh\ntouch #{marker}\ncat\n")
      File.chmod(0o755, File.join(@dir, "filter.sh"))
      write(".gitattributes", "a.txt filter=x\n")
      git("add", ".gitattributes")
      git("commit", "-q", "-m", "attributes")
      fresh = guard.base(repo)
      git("config", "filter.x.clean", File.join(@dir, "filter.sh"))
      write("a.txt", "edited\n")

      expect(guard.check(repo, fresh, "unchanged")).to include("code" => "config_changed")
      expect(File.exist?(marker)).to be(false)
    end

    it "finds a change to info/attributes" do
      FileUtils.mkdir_p(File.join(repo, ".git", "info"))
      File.write(File.join(repo, ".git", "info", "attributes"), "a.txt -diff\n")

      expect(check).to include("code" => "config_changed")
    end

    it "finds a change to config.worktree" do
      File.write(File.join(repo, ".git", "config.worktree"), "[core]\n\tfsmonitor = true\n")

      expect(check).to include("code" => "config_changed")
    end

    it "checks it in the config scope too" do
      git("config", "alias.x", "status")

      expect(check("config")).to include("code" => "config_changed")
    end
  end

  describe "hooks_changed" do
    it "finds a new hook in the repository's hooks directory" do
      File.write(File.join(repo, ".git", "hooks", "pre-commit"), "#!/bin/sh\nexit 0\n")

      expect(check).to include("code" => "hooks_changed")
    end

    it "finds an edited hook and a changed mode" do
      hook = File.join(repo, ".git", "hooks", "pre-commit")
      File.write(hook, "#!/bin/sh\nexit 0\n")
      with_hook = guard.base(repo)
      File.chmod(0o755, hook)

      expect(guard.check(repo, with_hook, "unchanged")).to include("code" => "hooks_changed")
      File.chmod(0o644, hook)
      File.write(hook, "#!/bin/sh\nexit 1\n")
      expect(guard.check(repo, with_hook, "unchanged")).to include("code" => "hooks_changed")
    end

    it "finds a hook that is a symlink pointing elsewhere" do
      hook = File.join(repo, ".git", "hooks", "pre-commit")
      File.symlink("/bin/true", hook)
      linked = guard.base(repo)
      File.delete(hook)
      File.symlink("/bin/false", hook)

      expect(guard.check(repo, linked, "unchanged")).to include("code" => "hooks_changed")
    end

    it "reads the directory a repository config's core.hooksPath names" do
      elsewhere = File.join(@dir, "my-hooks")
      FileUtils.mkdir_p(elsewhere)
      git("config", "core.hooksPath", elsewhere)
      configured = guard.base(repo)
      File.write(File.join(elsewhere, "pre-commit"), "#!/bin/sh\n")

      expect(guard.check(repo, configured, "unchanged")).to include("code" => "hooks_changed")
    end
  end

  it "ignores an inherited GIT_DIR, GIT_INDEX_FILE and GIT_CONFIG_COUNT" do
    other = File.join(@dir, "other")
    FileUtils.mkdir_p(other)
    git("init", "-q", "-b", "main", path: other)
    write("a.txt", "changed\n")

    saved = ENV.to_h.slice("GIT_DIR", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0")
    ENV["GIT_DIR"] = File.join(other, ".git")
    ENV["GIT_INDEX_FILE"] = File.join(other, ".git", "index")
    ENV["GIT_CONFIG_COUNT"] = "1"
    ENV["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
    ENV["GIT_CONFIG_VALUE_0"] = "true"
    begin
      expect(guard.check(repo, base, "unchanged")).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
    ensure
      %w[GIT_DIR GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0].each { |name| ENV.delete(name) }
      saved.each { |name, value| ENV[name] = value }
    end
  end

  it "works in a linked worktree, whose config and hooks live in the common dir" do
    linked = File.join(@dir, "linked")
    git("worktree", "add", "-q", "-b", "other", linked)
    start = guard.base(linked)

    expect(guard.check(linked, start, "unchanged")).to be_nil
    File.write(File.join(repo, ".git", "hooks", "pre-commit"), "#!/bin/sh\n")
    expect(guard.check(linked, start, "unchanged")).to include("code" => "hooks_changed")
  end

  it "answers no_commit instead of raising when git can't run" do
    broken = described_class.new(runner: ->(*, **) { raise Errno::ENOENT })

    expect(broken.check(repo, base, "unchanged")).to include("code" => "no_commit")
    expect(broken.snapshot(repo).values).to eq([nil, nil, nil])
  end

  describe "replace refs" do
    def replace_head_with_edited_tree
      write("a.txt", "edited under a replacement\n")
      git("add", "a.txt")
      tree = git("write-tree").strip
      commit = git("commit-tree", tree, "-p", "HEAD~0", "-m", "replacement").strip
      git("reset", "-q", "--hard", base["base_sha"])
      git("replace", base["base_sha"], commit)
      write("a.txt", "edited under a replacement\n")
    end

    it "finds a replace ref planted after the start, which would make status read a clean tree" do
      replace_head_with_edited_tree

      expect(check).to include("code" => "config_changed")
      expect(check("config")).to include("code" => "config_changed")
    end

    it "does not read through a replace ref that was there at the start" do
      replace_head_with_edited_tree
      with_replace = guard.base(repo)

      expect(with_replace["base_sha"]).to eq(base["base_sha"])
      expect(guard.check(repo, with_replace, "unchanged")).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
    end
  end

  describe "text that is not ASCII" do
    let(:repo) { File.join(@dir, "répo é") }

    it "starts and checks a checkout whose path is UTF-8, with a hook of bytes that are not text" do
      hooks = File.join(repo, ".git", "hooks")
      File.binwrite(File.join(hooks, "pre-commit"), "#!/bin/sh\n\xFF\xFE".b)
      File.binwrite(File.join(hooks, "é"), "\xFF".b)
      File.symlink("tárget", File.join(hooks, "ünk"))
      started = guard.base(repo)

      expect(started["base_guard"].values).to all(match(/\A\h{64}\z/))
      expect(guard.check(repo, started, "unchanged")).to be_nil
      File.binwrite(File.join(hooks, "é"), "\xFE".b)
      expect(guard.check(repo, started, "unchanged")).to include("code" => "hooks_changed")
    end

    it "reads a changed config in such a path" do
      git("config", "alias.st", "status é")

      expect(check).to include("code" => "config_changed")
    end
  end

  describe "a part git can't read" do
    let(:failing) do
      lambda do |argv, **options|
        next ["", "fatal: boom\n", false] if argv.include?("ls-files")
        Workspace::TimedProcess.run(argv, **options)
      end
    end

    it "fails with its code at check time even when it could not be read at the start" do
      broken = described_class.new(runner: failing)
      started = broken.base(repo)

      expect(started["base_guard"]["hidden_sha256"]).to be_nil
      expect(broken.check(repo, started, "unchanged")).to include("code" => "hidden_changed")
    end

    it "fails with hooks_changed when git can't read the hooksPath setting, rather than assuming it is unset" do
      broken = described_class.new(runner: lambda do |argv, **options|
        next ["", "fatal: bad config\n", false] if argv.include?("--get")
        Workspace::TimedProcess.run(argv, **options)
      end)

      expect(broken.snapshot(repo)["hooks_sha256"]).to be_nil
      expect(broken.check(repo, base, "config")).to include("code" => "hooks_changed")
    end
  end

  it "finds a change to the config.worktree of a linked worktree, from the main checkout" do
    linked = File.join(@dir, "linked")
    git("worktree", "add", "-q", "-b", "other", linked)
    start = guard.base(repo)
    File.write(File.join(repo, ".git", "worktrees", "linked", "config.worktree"), "[core]\n\tfsmonitor = true\n")

    expect(guard.check(repo, start, "unchanged")).to include("code" => "config_changed")
  end

  it "reads a core.hooksPath that comes from an included config file" do
    elsewhere = File.join(@dir, "included-hooks")
    FileUtils.mkdir_p(elsewhere)
    File.write(File.join(repo, ".git", "extra.cfg"), "[core]\n\thooksPath = #{elsewhere}\n")
    git("config", "include.path", "extra.cfg")
    started = guard.base(repo)
    File.write(File.join(elsewhere, "pre-commit"), "#!/bin/sh\n")

    expect(guard.check(repo, started, "unchanged")).to include("code" => "hooks_changed")
  end

  it "runs the git it was given, not whatever is first on PATH" do
    fake_bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(fake_bin)
    marker = File.join(@dir, "fake-git-ran")
    File.write(File.join(fake_bin, "git"), "#!/bin/sh\ntouch #{marker}\nexit 1\n")
    File.chmod(0o755, File.join(fake_bin, "git"))
    real = Workspace::Which.path("git")
    pinned = described_class.new(git_path: real)
    saved = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{saved}"
    begin
      expect(pinned.check(repo, base, "unchanged")).to be_nil
    ensure
      ENV["PATH"] = saved
    end
    expect(File.exist?(marker)).to be(false)
  end
end
