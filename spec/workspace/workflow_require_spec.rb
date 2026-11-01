require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRequire do
  around do |example|
    Dir.mktmpdir("wf-require") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "repo") }
  let(:artifacts) { File.join(@dir, "artifacts") }
  let(:notes) { File.join(@dir, "notes") }
  let(:notes_dir) { notes }
  let(:guard) { Workspace::WorkflowGuard.new }
  subject(:requirer) { described_class.new(guard: guard, notes_dir_of: ->(_workspace) { notes_dir }) }

  def git(*args)
    system({"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"}, "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com",
      "-c", "commit.gpgsign=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args, out: File::NULL, exception: true)
  end

  before do
    FileUtils.mkdir_p([repo, artifacts, notes])
    File.write(File.join(repo, "a.txt"), "one\n")
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "start")
  end

  let!(:base) { guard.head(repo) }
  let(:run) { {"worktree" => repo, "artifacts_dir" => artifacts, "workspace" => "app"} }

  def check(*proofs, attempt: {"head" => {"before" => base}})
    requirer.check(run: run, step: {"require" => proofs}, attempt: attempt)
  end

  def commit
    git("commit", "-q", "--allow-empty", "-m", "more")
  end

  it "passes a step with no require" do
    expect(requirer.check(run: run, step: {}, attempt: {})).to be_nil
  end

  describe "commits" do
    it "passes with enough commits since the attempt began" do
      commit
      expect(check({"commits" => 1})).to be_nil
    end

    it "fails saying what was required and found" do
      expect(check({"commits" => 1})).to include("proof" => "commits", "code" => "require_commits", "required" => 1, "found" => 0, "base" => base,
        "detail" => "required 1 commit since #{base[0, 7]}, found 0")
      commit
      expect(check({"commits" => 2})).to include("detail" => "required 2 commits since #{base[0, 7]}, found 1")
    end

    it "fails as unproven with no recorded starting commit" do
      commit
      expect(check({"commits" => 1}, attempt: {})).to include("unproven" => true, "detail" => /no recorded starting commit/)
      expect(check({"commits" => 1}, attempt: {"head" => {"before" => nil}})).to include("unproven" => true)
    end

    it "does not count commits that arrive by merge" do
      git("checkout", "-q", "-b", "other")
      File.write(File.join(repo, "o.txt"), "o\n")
      git("add", "-A")
      git("commit", "-q", "-m", "other")
      git("checkout", "-q", "main")
      git("merge", "-q", "--no-ff", "-m", "merge", "other")
      expect(check({"commits" => 1})).to include("found" => 0, "detail" => /found 0/)
    end

    it "fails as unproven, with a reason, when the base is no longer an ancestor of HEAD" do
      commit
      git("reset", "-q", "--hard", "HEAD~1")
      git("commit", "-q", "--amend", "--allow-empty", "-m", "rewritten")
      expect(check({"commits" => 1})).to include("code" => "require_commits", "unproven" => true, "reason" => "history_rewritten",
        "detail" => /not an ancestor of HEAD/)
    end

    it "fails as unproven when git can't answer the ancestor check" do
      allow(guard).to receive(:commits_since).and_return(nil)
      expect(check({"commits" => 1})).to include("unproven" => true, "detail" => /could not count/)
    end

    it "fails as unproven when git does not know the base" do
      expect(check({"commits" => 1}, attempt: {"head" => {"before" => "a" * 40}})).to include("unproven" => true, "detail" => /could not count/)
    end
  end

  describe "nonempty" do
    it "passes a regular file with content" do
      File.write(File.join(artifacts, "implement.md"), "done\n")
      expect(check({"nonempty" => "implement.md"})).to be_nil
    end

    it "fails on a missing, an empty, a linked and a directory path" do
      expect(check({"nonempty" => "implement.md"})).to include("code" => "require_nonempty", "detail" => "required implement.md to be non-empty, found it missing")
      File.write(File.join(artifacts, "implement.md"), "")
      expect(check({"nonempty" => "implement.md"})).to include("detail" => /found it empty/)
      File.write(File.join(@dir, "real.md"), "x")
      File.symlink(File.join(@dir, "real.md"), File.join(artifacts, "link.md"))
      expect(check({"nonempty" => "link.md"})).to include("detail" => /a symbolic link/)
      FileUtils.mkdir_p(File.join(artifacts, "dir.md"))
      expect(check({"nonempty" => "dir.md"})).to include("detail" => /not a regular file/)
    end

    it "is unproven with no artifacts directory recorded, and never reads a path from the root" do
      run["artifacts_dir"] = nil
      expect(check({"nonempty" => "implement.md"})).to include("unproven" => true, "detail" => /no artifacts directory/)
      run["artifacts_dir"] = ""
      expect(check({"nonempty" => "implement.md"})).to include("unproven" => true)
    end

    it "fails a file reached through a linked parent directory, but passes a real subdirectory" do
      FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
      File.write(File.join(@dir, "elsewhere", "x.md"), "x")
      File.symlink(File.join(@dir, "elsewhere"), File.join(artifacts, "sub"))
      expect(check({"nonempty" => "sub/x.md"})).to include("detail" => /outside the artifacts directory/)
      FileUtils.mkdir_p(File.join(artifacts, "real"))
      File.write(File.join(artifacts, "real", "x.md"), "x")
      expect(check({"nonempty" => "real/x.md"})).to be_nil
    end

    it "passes when the artifacts directory is itself reached through a link" do
      File.symlink(artifacts, File.join(@dir, "alias"))
      File.write(File.join(artifacts, "x.md"), "x")
      run["artifacts_dir"] = File.join(@dir, "alias")
      expect(check({"nonempty" => "x.md"})).to be_nil
    end

    it "is unproven when the file can't be resolved" do
      File.write(File.join(artifacts, "x.md"), "x")
      allow(File).to receive(:realpath).and_raise(Errno::EACCES)
      expect(check({"nonempty" => "x.md"})).to include("unproven" => true, "detail" => /could not be read/)
    end
  end

  describe "plan_status" do
    def plan(status)
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "---\nplan: 1\nstatus: #{status}\n---\n\n## Tasks\n\n- [ ] T1 One\n")
    end

    it "passes when the plan's status is the one required" do
      plan("done")
      expect(check({"plan_status" => "done"})).to be_nil
    end

    it "fails naming the status found" do
      plan("active")
      expect(check({"plan_status" => "done"})).to include("code" => "require_plan_status", "detail" => "required plan status done, found active")
    end

    it "fails as unproven on a missing, unknown or malformed status, even for active" do
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "---\nplan: 1\n---\n\n## Tasks\n\n- [ ] T1 One\n")
      expect(check({"plan_status" => "active"})).to include("unproven" => true, "detail" => /status: is missing/)
      ["finished", "ACTIVE", "[active]"].each do |value|
        plan(value)
        expect(check({"plan_status" => "active"})).to include("unproven" => true, "detail" => /not one of active, paused, done/)
      end
      File.write(File.join(notes, "IMPLEMENTATION_PLAN.md"), "no frontmatter\n\n## Tasks\n\n- [ ] T1 One\n")
      expect(check({"plan_status" => "active"})).to include("unproven" => true)
    end

    it "fails when there is no plan" do
      expect(check({"plan_status" => "done"})).to include("detail" => /found no IMPLEMENTATION_PLAN.md/)
    end

    it "fails as unproven when the notes directory can't be found or the plan can't be read" do
      plan("done")
      File.chmod(0o000, File.join(notes, "IMPLEMENTATION_PLAN.md"))
      expect(check({"plan_status" => "done"})).to include("unproven" => true) unless Process.uid.zero?
      File.chmod(0o644, File.join(notes, "IMPLEMENTATION_PLAN.md"))
      requirer = described_class.new(guard: guard, notes_dir_of: ->(_workspace) {})
      expect(requirer.check(run: run, step: {"require" => [{"plan_status" => "done"}]}, attempt: {})).to include("unproven" => true)
    end
  end

  describe "tracked_clean" do
    it "passes a clean checkout, untracked files included" do
      File.write(File.join(repo, "new.txt"), "x")
      expect(check({"tracked_clean" => true})).to be_nil
    end

    it "fails naming the changed tracked paths" do
      File.write(File.join(repo, "a.txt"), "changed\n")
      expect(check({"tracked_clean" => true})).to include("code" => "require_tracked_clean", "paths" => ["a.txt"], "detail" => /found 1 \(a.txt\)/)
    end

    it "fails while a rebase, merge, cherry-pick, revert or bisect is in progress" do
      %w[MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG].each do |name|
        File.write(File.join(repo, ".git", name), "x\n")
        expect(check({"tracked_clean" => true})).to include("code" => "require_tracked_clean", "detail" => /in progress/)
        File.delete(File.join(repo, ".git", name))
      end
      FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))
      expect(check({"tracked_clean" => true})).to include("detail" => /in progress/)
    end

    it "does not see an assume-unchanged file" do
      git("update-index", "--assume-unchanged", "a.txt")
      File.write(File.join(repo, "a.txt"), "changed\n")
      expect(check({"tracked_clean" => true})).to be_nil
    end

    it "fails as unproven when git can't answer" do
      run["worktree"] = File.join(@dir, "gone")
      expect(check({"tracked_clean" => true})).to include("unproven" => true)
    end
  end

  it "puts the exception class and message in error when a proof raises" do
    allow(guard).to receive(:commits_since).and_raise("boom")
    expect(check({"commits" => 1})).to include("code" => "require_unknown", "unproven" => true, "error" => "RuntimeError: boom")
  end

  it "stops at the first proof that fails" do
    expect(check({"tracked_clean" => true}, {"commits" => 1}, {"nonempty" => "x.md"})).to include("proof" => "commits")
  end

  it "answers a failed proof, never an error, when a collaborator raises" do
    allow(guard).to receive(:commits_since).and_raise("boom")
    expect(check({"commits" => 1})).to include("code" => "require_unknown", "unproven" => true)
  end
end
