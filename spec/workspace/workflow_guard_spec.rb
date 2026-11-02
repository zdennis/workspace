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
    expect(base["base_guard"].keys).to eq(%w[config_sha256 hooks_sha256 hidden_sha256 config_format filter_sha256])
    expect(base["base_guard"].except("config_format").values).to all(match(/\A\h{64}\z/))
    expect(base["base_guard"]["config_format"]).to eq(2)
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

  describe "#head" do
    it "answers the full commit id, and nil when git can't answer" do
      expect(guard.head(repo)).to eq(git("rev-parse", "HEAD").strip)
      expect(guard.head(File.join(@dir, "nowhere"))).to be_nil
    end

    it "waits at most 5 seconds for git, and reads a timeout as nil" do
      limits = []
      slow = described_class.new(runner: lambda do |_argv, **options|
        limits << options[:timeout]
        raise Timeout::Error
      end)

      expect(slow.head(repo)).to be_nil
      expect(limits).to eq([5])
    end

    it "leaves the other git calls at 30 seconds" do
      limits = []
      watching = described_class.new(runner: lambda do |argv, **options|
        limits << options[:timeout]
        Workspace::TimedProcess.run(argv, **options)
      end)
      watching.base(repo)

      expect(limits.uniq.sort).to eq([5, 30])
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

  describe "#config_change" do
    let(:marker) { File.join(@dir, "ran") }
    let(:hooks) { File.join(@dir, "hooks") }

    def change(seen: nil, on: repo, from: base)
      guard.config_change(on, from, seen: seen)
    end

    def config_file
      File.join(repo, ".git", "config")
    end

    it "is nil, and check passes, with nothing changed" do
      expect(change).to be_nil
    end

    it "ignores layout and comments, which git's reading drops" do
      File.write(config_file, "# a comment\n#{File.read(config_file)}\n")

      expect(change).to be_nil
    end

    it "ignores `workspace-created` added for another branch" do
      git("config", "branch.other.workspace-created", "true")

      expect(change).to be_nil
      expect(check).to be_nil
    end

    it "ignores another branch's remote, and a branch name with dots and slashes" do
      git("config", "branch.feature/a.b.remote", "origin")
      git("config", "branch.feature/a.b.merge", "refs/heads/x")

      expect(change).to be_nil
    end

    it "warns of the checkout's own branch's remote, and the step passes" do
      git("config", "branch.main.remote", "elsewhere")

      expect(change).to include("code" => "config_changed", "old_format" => false)
      expect(check).to be_nil
      expect(check("config")).to be_nil
    end

    it "keeps two-part keys of the [branch] section, which are settings and not a branch's" do
      git("config", "branch.autoSetupRebase", "always")

      expect(change).to include("code" => "config_changed")
    end

    it "ignores every branch's section on a detached HEAD" do
      git("checkout", "-q", "--detach")
      detached = guard.base(repo)
      git("config", "branch.main.remote", "elsewhere")

      expect(guard.config_change(repo, detached)).to be_nil
    end

    it "warns of a core.fsmonitor, the step passes, and the command never runs" do
      File.write(File.join(@dir, "fsmonitor.sh"), "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, File.join(@dir, "fsmonitor.sh"))
      git("config", "core.fsmonitor", File.join(@dir, "fsmonitor.sh"))

      expect(change).to include("code" => "config_changed")
      expect(check).to be_nil
      write("a.txt", "x\n")
      check
      expect(File.exist?(marker)).to be(false)
    end

    it "warns of a change to info/attributes" do
      FileUtils.mkdir_p(File.join(repo, ".git", "info"))
      File.write(File.join(repo, ".git", "info", "attributes"), "a.txt -diff\n")

      expect(change).to include("code" => "config_changed")
    end

    it "warns of a change to the checkout's own config.worktree" do
      File.write(File.join(repo, ".git", "config.worktree"), "[core]\n\tfsmonitor = true\n")

      expect(change).to include("code" => "config_changed")
    end

    it "warns of the own config.worktree of a linked worktree" do
      linked = File.join(@dir, "linked")
      git("worktree", "add", "-q", "-b", "other", linked)
      start = guard.base(linked)
      File.write(File.join(repo, ".git", "worktrees", "linked", "config.worktree"), "[core]\n\tfsmonitor = true\n")

      expect(change(on: linked, from: start)).to include("code" => "config_changed")
    end

    it "ignores another linked worktree's config.worktree" do
      linked = File.join(@dir, "linked")
      git("worktree", "add", "-q", "-b", "other", linked)
      start = guard.base(repo)
      File.write(File.join(repo, ".git", "worktrees", "linked", "config.worktree"), "[core]\n\tfsmonitor = true\n")

      expect(change(from: start)).to be_nil
    end

    it "warns of a new include, and of a change inside an included file" do
      extra = File.join(repo, ".git", "extra.cfg")
      File.write(extra, "[alias]\n\tx = status\n")
      git("config", "include.path", "extra.cfg")
      expect(change).to include("code" => "config_changed")

      included = guard.base(repo)
      expect(guard.config_change(repo, included)).to be_nil
      File.write(extra, "[alias]\n\tx = log\n")
      expect(guard.config_change(repo, included)).to include("code" => "config_changed")
    end

    it "still fails hooks_changed for a core.hooksPath, the warning apart" do
      git("config", "core.hooksPath", hooks)

      expect(change).to include("code" => "config_changed")
      expect(check).to include("code" => "hooks_changed")
      expect(check("config")).to include("code" => "hooks_changed")
    end

    it "lets neither a config change hide a hook nor a hidden flag" do
      git("config", "alias.x", "status")
      File.write(File.join(repo, ".git", "hooks", "pre-commit"), "#!/bin/sh\n")
      expect(check).to include("code" => "hooks_changed")
      File.delete(File.join(repo, ".git", "hooks", "pre-commit"))
      git("update-index", "--assume-unchanged", "a.txt")
      expect(check).to include("code" => "hidden_changed")
    end

    it "answers with a reading, and nil when asked again with that reading" do
      git("config", "alias.x", "status")
      first = change

      expect(first["reading"]).to match(/\A\h{64}\z/)
      expect(change(seen: first["reading"])).to be_nil
      git("config", "alias.y", "log")
      expect(change(seen: first["reading"])).to include("code" => "config_changed", "old_format" => false)
    end

    it "says nothing, and drops `seen`, when the config comes back to the base's reading" do
      git("config", "alias.x", "status")
      first = change
      git("config", "--unset", "alias.x")

      expect(change(seen: first["reading"])).to eq("code" => nil, "reading" => base["base_guard"]["config_sha256"])
      expect(change).to be_nil
    end

    it "says nothing when a config unreadable a moment ago recovers to the base's reading" do
      expect(change(seen: "unreadable")).to eq("code" => nil, "reading" => base["base_guard"]["config_sha256"])
    end

    it "warns when a config unreadable a moment ago recovers to something else" do
      git("config", "alias.x", "status")

      expect(change(seen: "unreadable")).to include("code" => "config_changed", "old_format" => false)
    end

    it "warns once, marked old_format, for a base whose digest was made the old way" do
      old = {"base_sha" => base["base_sha"], "base_guard" => base["base_guard"].except("config_format").merge("config_sha256" => "0" * 64)}

      found = guard.config_change(repo, old)
      expect(found).to include("code" => "config_changed", "old_format" => true)
      expect(guard.config_change(repo, old, seen: found["reading"])).to be_nil
      expect(guard.check(repo, old, "unchanged")).to be_nil
    end

    it "reads an unreadable config as nil, which warns and then stays quiet" do
      broken = described_class.new(runner: lambda do |argv, **options|
        next ["", "fatal: bad config\n", false] if argv.include?("--list")
        Workspace::TimedProcess.run(argv, **options)
      end)

      expect(broken.snapshot(repo)["config_sha256"]).to be_nil
      expect(broken.config_change(repo, base)).to include("reading" => "unreadable")
      expect(broken.config_change(repo, base, seen: "unreadable")).to be_nil
    end
  end

  describe "a filter set after the start" do
    let(:marker) { File.join(@dir, "ran") }

    before do
      File.write(File.join(@dir, "filter.sh"), "#!/bin/sh\ntouch #{marker}\ncat a.txt.orig 2>/dev/null\n")
      File.chmod(0o755, File.join(@dir, "filter.sh"))
      write(".gitattributes", "a.txt filter=x\n")
      git("add", ".gitattributes")
      git("commit", "-q", "-m", "attributes")
    end

    let(:fresh) { guard.base(repo) }

    it "finds the edit it would hide, and never runs it" do
      fresh
      git("config", "filter.x.clean", File.join(@dir, "filter.sh"))
      git("config", "filter.x.required", "true")
      write("a.txt", "edited\n")

      expect(guard.check(repo, fresh, "unchanged")).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
      expect(guard.dirty_paths(repo, base: fresh)).to eq(["a.txt"])
      expect(File.exist?(marker)).to be(false)
    end

    it "leaves a filter alone while the config is the base's" do
      git("config", "filter.x.clean", "cat")
      started = guard.base(repo)
      write("a.txt", "edited\n")

      expect(guard.dirty_paths(repo, base: started)).to eq(["a.txt"])
    end

    it "answers nil for a planted filter whose name git -c can't carry, and never runs it" do
      fresh
      git("config", "filter.a=b.clean", File.join(@dir, "filter.sh"))
      write(".gitattributes", "a.txt filter=a=b\n")

      expect(guard.dirty_paths(repo, base: fresh)).to be_nil
      expect(guard.check(repo, fresh, "unchanged")).to eq("code" => "tracked_changed", "paths" => [])
      expect(File.exist?(marker)).to be(false)
    end

    it "leaves alone a filter with such a name that was there at the start" do
      git("config", "filter.a=b.clean", "cat")
      started = guard.base(repo)

      expect(guard.dirty_paths(repo, base: started)).to eq([])
    end
  end

  describe "a project's own filter, on a file whose stat data is stale" do
    let(:marker) { File.join(@dir, "ran") }

    before do
      git("config", "filter.up.clean", "tr a-z A-Z")
      write(".gitattributes", "a.txt filter=up\n")
      git("add", ".gitattributes")
      git("add", "--renormalize", ".")
      git("commit", "-q", "-m", "filter")
    end

    let!(:started) { guard.base(repo) }

    def touch_tracked
      stamp = Time.now - 300
      File.utime(stamp, stamp, File.join(repo, "a.txt"))
    end

    it "stays clean with nothing changed" do
      touch_tracked

      expect(guard.check(repo, started, "unchanged")).to be_nil
    end

    it "stays clean for a run with no recorded filter digest, whose config digest never matches" do
      old = {"base_sha" => started["base_sha"],
             "base_guard" => started["base_guard"].except("config_format", "filter_sha256").merge("config_sha256" => "0" * 64)}
      touch_tracked

      expect(guard.config_change(repo, old)).to include("old_format" => true)
      expect(guard.check(repo, old, "unchanged")).to be_nil
    end

    it "stays clean through a harmless change to the own branch's section" do
      git("config", "branch.main.remote", "origin")
      touch_tracked

      expect(guard.config_change(repo, started)).to include("code" => "config_changed")
      expect(guard.check(repo, started, "unchanged")).to be_nil
    end

    it "turns the filters off once a filter entry changes, and never runs the new one" do
      File.write(File.join(@dir, "planted.sh"), "#!/bin/sh\ntouch #{marker}\ncat\n")
      File.chmod(0o755, File.join(@dir, "planted.sh"))
      git("config", "filter.up.clean", File.join(@dir, "planted.sh"))
      touch_tracked

      expect(guard.check(repo, started, "unchanged")).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
      expect(File.exist?(marker)).to be(false)
    end

    it "leaves the filters on when the entries can't be read, rather than failing the step" do
      reader = described_class.new(runner: lambda do |argv, **options|
        next ["", "fatal: boom\n", false] if argv.include?("--get-regexp")
        Workspace::TimedProcess.run(argv, **options)
      end)
      touch_tracked

      expect(reader.dirty_paths(repo, base: started)).to eq([])
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

    it "warns of a replace ref planted after the start, and still reads the real tree" do
      replace_head_with_edited_tree

      expect(guard.config_change(repo, base)).to include("code" => "config_changed")
      expect(check).to eq("code" => "tracked_changed", "paths" => ["a.txt"])
      expect(check("config")).to be_nil
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

      expect(started["base_guard"].except("config_format").values).to all(match(/\A\h{64}\z/))
      expect(guard.check(repo, started, "unchanged")).to be_nil
      File.binwrite(File.join(hooks, "é"), "\xFE".b)
      expect(guard.check(repo, started, "unchanged")).to include("code" => "hooks_changed")
    end

    it "reads a changed config in such a path" do
      git("config", "alias.st", "status é")

      expect(guard.config_change(repo, base)).to include("code" => "config_changed")
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

  describe "#remote_head" do
    let(:remote) { File.join(@dir, "remote.git") }

    before do
      git("init", "-q", "--bare", "-b", "main", remote, path: @dir)
      git("remote", "add", "origin", remote)
      git("push", "-q", "origin", "main")
    end

    it "reads the current branch's sha on the remote it tracks, else origin" do
      sha = git("rev-parse", "HEAD").strip
      expect(guard.remote_head(repo)).to eq("remote" => "origin", "ref" => "refs/heads/main", "sha" => sha)
      git("remote", "rename", "origin", "up")
      git("config", "branch.main.remote", "up")
      expect(guard.remote_head(repo)).to include("remote" => "up", "sha" => sha)
    end

    it "reads a nil sha for a branch the remote lacks" do
      git("checkout", "-q", "-b", "topic")
      expect(guard.remote_head(repo)).to eq("remote" => "origin", "ref" => "refs/heads/topic", "sha" => nil)
    end

    it "reads the ref the branch tracks, not its local name" do
      sha = git("rev-parse", "HEAD").strip
      git("checkout", "-q", "-b", "pr-12")
      git("config", "branch.pr-12.remote", "origin")
      git("config", "branch.pr-12.merge", "refs/heads/main")
      expect(guard.remote_head(repo)).to eq("remote" => "origin", "ref" => "refs/heads/main", "sha" => sha)
    end

    it "says why it has no reading: unreachable, an option-like remote name, a detached HEAD" do
      git("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))
      expect(guard.remote_head(repo)).to eq("unread" => "unreachable")
      git("config", "branch.main.remote", "--upload-pack=x")
      expect(guard.remote_head(repo)).to eq("unread" => "bad_remote")
      git("checkout", "-q", "--detach")
      expect(guard.remote_head(repo)).to eq("unread" => "detached_head")
    end

    it "does not look at origin for a branch whose upstream is local" do
      git("config", "branch.main.remote", ".")
      expect(guard.remote_head(repo)).to eq("unread" => "local_upstream")
    end

    it "says no_remote, not unreachable, when there is no such remote" do
      git("remote", "remove", "origin")
      expect(guard.remote_head(repo)).to eq("unread" => "no_remote")
      git("config", "branch.main.remote", "gone")
      expect(guard.remote_head(repo)).to eq("unread" => "no_remote")
    end

    describe "the remote a push would go to" do
      let(:fork_remote) { File.join(@dir, "fork.git") }
      let!(:sha) { git("rev-parse", "HEAD").strip }

      before do
        git("init", "-q", "--bare", "-b", "main", fork_remote, path: @dir)
        git("remote", "add", "fork", fork_remote)
        git("push", "-q", "fork", "main:refs/heads/topic", "main:refs/heads/head-x")
        git("checkout", "-q", "-b", "topic")
        git("config", "branch.topic.remote", "origin")
        git("config", "branch.topic.merge", "refs/heads/main")
      end

      it "prefers branch.<b>.pushRemote, on the branch's own name" do
        git("config", "remote.pushDefault", "origin")
        git("config", "branch.topic.pushRemote", "fork")
        expect(guard.remote_head(repo)).to eq("remote" => "fork", "ref" => "refs/heads/topic", "sha" => sha)
      end

      it "takes remote.pushDefault over the tracked remote" do
        git("config", "remote.pushDefault", "fork")
        expect(guard.remote_head(repo)).to include("remote" => "fork", "ref" => "refs/heads/topic")
      end

      it "keeps the merge ref when the push remote is the tracked one" do
        git("config", "branch.topic.pushRemote", "origin")
        expect(guard.remote_head(repo)).to include("remote" => "origin", "ref" => "refs/heads/main")
      end

      it "keeps a pr-N branch's refs/heads/ merge ref on another push remote, but not a pull ref" do
        git("checkout", "-q", "-b", "pr-7")
        git("config", "branch.pr-7.remote", "origin")
        git("config", "branch.pr-7.merge", "refs/heads/head-x")
        git("config", "branch.pr-7.pushRemote", "fork")
        expect(guard.remote_head(repo)).to include("remote" => "fork", "ref" => "refs/heads/head-x", "sha" => sha)
        git("config", "branch.pr-7.merge", "refs/pull/7/head")
        expect(guard.remote_head(repo)).to include("remote" => "fork", "ref" => "refs/heads/pr-7", "sha" => nil)
      end

      it "reads a real push remote for a branch whose upstream is local" do
        git("config", "branch.topic.remote", ".")
        git("config", "branch.topic.pushRemote", "fork")
        expect(guard.remote_head(repo)).to include("remote" => "fork")
      end
    end

    it "runs hardened, with no prompt and a time limit" do
      calls = []
      runner = ->(command, **options) do
        calls << [command, options]
        ["main\n", "", true]
      end
      described_class.new(runner: runner, git_path: "/usr/bin/git").remote_head(repo)
      command, options = calls.find { |(cmd, _)| cmd.include?("ls-remote") }
      expect(command.first).to eq("/usr/bin/git")
      expect(command).to include("ls-remote", "core.hooksPath=/dev/null")
      expect(options[:timeout]).to eq(described_class::REMOTE_TIMEOUT)
      expect(options[:env]).to include("GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_ALLOW_PROTOCOL" => "https:ssh:git:file")
    end
  end

  describe "#commits_since" do
    it "counts the commits made after the base" do
      expect(guard.commits_since(repo, base["base_sha"])).to eq(0)
      write("c.txt")
      git("add", "-A")
      git("commit", "-q", "-m", "one")
      git("commit", "-q", "--allow-empty", "-m", "two")
      expect(guard.commits_since(repo, base["base_sha"])).to eq(2)
    end

    it "counts a merge's arrivals as nothing and its own commits as they are" do
      git("checkout", "-q", "-b", "other")
      write("o.txt")
      git("add", "-A")
      git("commit", "-q", "-m", "other")
      git("checkout", "-q", "main")
      git("merge", "-q", "--no-ff", "-m", "merge", "other")
      expect(guard.commits_since(repo, base["base_sha"])).to eq(0)
      git("commit", "-q", "--allow-empty", "-m", "own")
      expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
    end

    describe "with an upstream" do
      let(:remote) { File.join(@dir, "remote.git") }
      let(:other) { File.join(@dir, "other") }

      def add_remote(name = "origin")
        git("init", "-q", "--bare", "-b", "main", remote, path: @dir) unless File.exist?(remote)
        git("remote", "add", name, remote)
        git("push", "-q", name, "main")
      end

      def advance_remote_main
        git("clone", "-q", remote, other, path: @dir) unless File.exist?(other)
        git("commit", "-q", "--allow-empty", "-m", "arrived", path: other)
        git("push", "-q", "origin", "main", path: other)
      end

      def count_from(sha)
        guard.commits_since(repo, sha)
      end

      it "does not count a fast-forward onto origin/main for a branch tracking it" do
        add_remote
        git("checkout", "-q", "-b", "feat", "--track", "origin/main")
        before = guard.head(repo)
        advance_remote_main
        git("fetch", "-q", "origin")
        git("merge", "-q", "--ff-only", "origin/main")
        expect(guard.head(repo)).not_to eq(before)
        expect(count_from(before)).to eq(0)
      end

      it "does not count a fast-forward onto a local branch the branch tracks" do
        git("checkout", "-q", "-b", "feat", "--track", "main")
        before = guard.head(repo)
        git("checkout", "-q", "main")
        git("commit", "-q", "--allow-empty", "-m", "arrived")
        git("checkout", "-q", "feat")
        git("merge", "-q", "--ff-only", "main")
        expect(count_from(before)).to eq(0)
      end

      it "counts an own unpushed commit of a branch tracking origin/main" do
        add_remote
        git("checkout", "-q", "-b", "feat", "--track", "origin/main")
        before = guard.head(repo)
        git("commit", "-q", "--allow-empty", "-m", "own")
        expect(count_from(before)).to eq(1)
      end

      it "counts an own commit pushed to the branch's own upstream" do
        add_remote
        git("checkout", "-q", "-b", "feat")
        before = guard.head(repo)
        git("push", "-q", "-u", "origin", "feat")
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("push", "-q")
        expect(count_from(before)).to eq(1)
      end

      it "counts an own commit pushed to an upstream with another name (pr-12 tracking origin/other)" do
        add_remote
        git("checkout", "-q", "-b", "pr-12")
        before = guard.head(repo)
        git("push", "-q", "origin", "pr-12:other")
        git("branch", "-q", "--set-upstream-to=origin/other")
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("push", "-q", "origin", "pr-12:other")
        expect(count_from(before)).to eq(1)
      end

      it "counts an own commit main pushed to origin/main" do
        add_remote
        git("branch", "-q", "--set-upstream-to=origin/main", "main")
        before = guard.head(repo)
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("push", "-q")
        expect(count_from(before)).to eq(1)
      end

      it "reads the default branch from the remote's HEAD (up/HEAD is trunk)" do
        git("init", "-q", "--bare", "-b", "trunk", remote, path: @dir)
        git("remote", "add", "up", remote)
        git("push", "-q", "up", "main:trunk")
        git("remote", "set-head", "up", "trunk")
        git("checkout", "-q", "-b", "feat", "--track", "up/trunk")
        before = guard.head(repo)
        git("clone", "-q", remote, other, path: @dir)
        git("commit", "-q", "--allow-empty", "-m", "arrived", path: other)
        git("push", "-q", "origin", "HEAD:trunk", path: other)
        git("fetch", "-q", "up")
        git("merge", "-q", "--ff-only", "up/trunk")
        expect(guard.head(repo)).not_to eq(before)
        expect(count_from(before)).to eq(0)
      end

      it "guesses main as the default branch when the remote has no HEAD set" do
        add_remote
        git("remote", "set-head", "origin", "-d")
        expect { git("symbolic-ref", "-q", "refs/remotes/origin/HEAD") }.to raise_error(/failed/)
        git("checkout", "-q", "-b", "feat", "--track", "origin/main")
        before = guard.head(repo)
        advance_remote_main
        git("fetch", "-q", "origin")
        git("merge", "-q", "--ff-only", "origin/main")
        expect(count_from(before)).to eq(0)
      end
    end

    it "is :history_rewritten when the base is not an ancestor of HEAD (amend, reset, rebase)" do
      git("commit", "-q", "--allow-empty", "-m", "own")
      git("reset", "-q", "--hard", "HEAD~1")
      git("commit", "-q", "--amend", "--allow-empty", "-m", "start again")
      expect(guard.commits_since(repo, base["base_sha"])).to eq(:history_rewritten)
    end

    it "is :history_rewritten after a rebase onto commits that arrived" do
      git("checkout", "-q", "-b", "work")
      git("commit", "-q", "--allow-empty", "-m", "own")
      git("checkout", "-q", "main")
      write("m.txt")
      git("add", "-A")
      git("commit", "-q", "-m", "arrived")
      git("checkout", "-q", "work")
      before = guard.head(repo)
      git("rebase", "-q", "main")
      expect(guard.head(repo)).not_to eq(before)
      expect(guard.commits_since(repo, before)).to eq(:history_rewritten)
    end

    context "with commits that arrive from another branch" do
      def main_two_ahead
        git("checkout", "-q", "-b", "feat")
        git("checkout", "-q", "main")
        2.times { |i| git("commit", "-q", "--allow-empty", "-m", "main #{i}") }
        git("checkout", "-q", "feat")
      end

      it "counts nothing for a --ff-only merge of main" do
        main_two_ahead
        git("merge", "-q", "--ff-only", "main")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(0)
      end

      it "counts nothing for a rebase onto main with no own commit" do
        main_two_ahead
        git("rebase", "-q", "main")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(0)
      end

      it "counts the own commit after a rebase onto main" do
        main_two_ahead
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("rebase", "-q", "main")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end

      it "counts an own commit and a merge of main as one" do
        main_two_ahead
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("merge", "-q", "--no-ff", "-m", "merge", "main")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end

      it "counts an own commit pushed to the branch's upstream" do
        git("init", "-q", "--bare", File.join(@dir, "origin.git"))
        git("remote", "add", "origin", File.join(@dir, "origin.git"))
        git("checkout", "-q", "-b", "feat")
        git("push", "-q", "-u", "origin", "feat")
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("push", "-q", "origin", "feat")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end

      it "counts commits pulled from the branch's own upstream" do
        git("init", "-q", "--bare", File.join(@dir, "origin.git"))
        git("remote", "add", "origin", File.join(@dir, "origin.git"))
        git("checkout", "-q", "-b", "feat")
        git("push", "-q", "-u", "origin", "feat")
        git("commit", "-q", "--allow-empty", "-m", "elsewhere")
        git("push", "-q", "origin", "feat")
        git("reset", "-q", "--hard", base["base_sha"])
        git("pull", "-q", "--ff-only")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end

      it "does not count a commit that is also on a sibling branch" do
        git("checkout", "-q", "-b", "feat")
        git("commit", "-q", "--allow-empty", "-m", "own")
        git("branch", "sibling")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(0)
      end

      it "counts a commit on a detached HEAD" do
        git("checkout", "-q", "--detach")
        git("commit", "-q", "--allow-empty", "-m", "own")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end

      it "works on a branch with no upstream" do
        git("checkout", "-q", "-b", "feat")
        git("commit", "-q", "--allow-empty", "-m", "own")
        expect(guard.commits_since(repo, base["base_sha"])).to eq(1)
      end
    end

    it "is nil, not a pass or a rewrite, when git fails on the ancestor check" do
      failing = ->(command, **_opts) { command.include?("merge-base") ? ["", "fatal: boom", false] : ["1\n", "", true] }
      expect(described_class.new(runner: failing).commits_since(repo, base["base_sha"])).to be_nil
      timing_out = ->(command, **_opts) { command.include?("merge-base") ? raise(Timeout::Error) : ["1\n", "", true] }
      expect(described_class.new(runner: timing_out).commits_since(repo, base["base_sha"])).to be_nil
    end

    it "is nil for no base, a base git does not know, or a value that is not a full commit id" do
      expect(guard.commits_since(repo, nil)).to be_nil
      expect(guard.commits_since(repo, "f" * 40)).to be_nil
      expect(guard.commits_since(repo, "--all")).to be_nil
      expect(guard.commits_since(repo, "HEAD")).to be_nil
    end

    it "is nil for a path that is not a checkout" do
      expect(guard.commits_since(File.join(@dir, "gone"), base["base_sha"])).to be_nil
    end
  end

  describe "#operation_in_progress?" do
    it "is false in a quiet checkout and true for a rebase, merge, cherry-pick, revert or bisect" do
      expect(guard.operation_in_progress?(repo)).to be(false)
      %w[rebase-merge rebase-apply].each do |dir|
        FileUtils.mkdir_p(File.join(repo, ".git", dir))
        expect(guard.operation_in_progress?(repo)).to be(true)
        FileUtils.rmdir(File.join(repo, ".git", dir))
      end
      %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG].each do |name|
        File.write(File.join(repo, ".git", name), "x\n")
        expect(guard.operation_in_progress?(repo)).to be(true)
        File.delete(File.join(repo, ".git", name))
      end
    end
  end

  describe "#dirty_paths" do
    it "lists changed tracked files and ignores untracked ones" do
      expect(guard.dirty_paths(repo)).to eq([])
      write("a.txt", "changed\n")
      write("new.txt")
      expect(guard.dirty_paths(repo)).to eq(["a.txt"])
    end

    it "is nil when git can't answer" do
      expect(guard.dirty_paths(File.join(@dir, "gone"))).to be_nil
    end
  end
end
