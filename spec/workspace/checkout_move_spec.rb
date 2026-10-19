require "spec_helper"

RSpec.describe Workspace::CheckoutMove do
  include MoveRepos

  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  subject(:move) { mover(git) }

  def mover(git, **options)
    described_class.new(git: git, git_exclude: Workspace::GitExclude.new(git: git), **options)
  end

  # A real Git whose named methods go through +overrides+, each `(original, *args, **kw)`.
  def git_with(**overrides)
    Workspace::Git.new(output: StringIO.new, input: StringIO.new).tap do |double|
      overrides.each do |name, fn|
        original = double.method(name)
        double.define_singleton_method(name) { |*args, **kw| fn.call(original, *args, **kw) }
      end
    end
  end

  def worktree(branch = "fix-login") = File.join(repo, ".worktrees", branch)

  def error_from
    yield
    raise "expected an error"
  rescue Workspace::Error => e
    e
  end

  def dirty_default
    write("app.rb", "one\nTWO\nthree\n")
    sh("add", "app.rb")
    write("run.sh", "echo changed\n")
    write("spec/login_spec.rb", "it\n")
    write("debug.log", "ignored\n")
  end

  def exclude_file = File.join(repo, ".git", "info", "exclude")

  describe "#call" do
    it "moves staged, unstaged and untracked changes from the default branch to a new branch at HEAD" do
      dirty_default
      before = work(repo)
      head = rev("HEAD")

      result = move.call(repo, "fix-login")

      expect(work(worktree)).to eq(before)
      expect(sh("rev-parse", "--abbrev-ref", "HEAD", dir: worktree).strip).to eq("fix-login")
      expect(rev("HEAD", dir: worktree)).to eq(head)
      expect(work(repo)).to eq(staged: "", unstaged: "", untracked: {}, status: "")
      expect(File.read(File.join(repo, "debug.log"))).to eq("ignored\n")
      expect(File).not_to exist(File.join(worktree, "debug.log"))
      expect(stash_shas).to eq([])
      expect(promote_refs).to eq([])
      expect(File.read(exclude_file)).to include("/.worktrees/\n")
      expect(result).to include("branch_required" => false, "path" => worktree, "warnings" => [])
      expect(result["moved"]).to include(
        "from_branch" => "main", "branch" => "fix-login", "branch_created" => true, "base_commit" => head, "commits_ahead" => 0,
        "staged" => ["app.rb"], "staged_count" => 1, "unstaged" => ["run.sh"], "unstaged_count" => 1,
        "untracked" => ["spec/login_spec.rb"], "untracked_count" => 1, "left_behind" => [],
        "main" => {"path" => repo, "branch" => "main", "clean" => true}
      )
      expect(result["moved"]["snapshot"]).to include("ref" => start_with("refs/workspace/promote/"), "id" => match(/\A\h{40}\z/), "kept" => false)
    end

    it "moves a feature branch with commits ahead and every kind of change, and switches main to the default" do
      sh("switch", "-q", "-c", "feature-x")
      commit_file("feature.rb", "f\n", "feature work")
      dirty_default
      before = work(repo)
      head = rev("HEAD")

      result = move.call(repo, nil)

      expect(work(worktree("feature-x"))).to eq(before)
      expect(rev("HEAD", dir: worktree("feature-x"))).to eq(head)
      expect(sh("symbolic-ref", "HEAD").strip).to eq("refs/heads/main")
      expect(rev("main")).not_to eq(head)
      expect(work(repo)[:status]).to eq("")
      expect(result["moved"]).to include("from_branch" => "feature-x", "branch" => "feature-x", "branch_created" => false,
        "commits_ahead" => 1, "main" => {"path" => repo, "branch" => "main", "clean" => true})
    end

    it "moves a feature branch's work to a new name and leaves the feature branch where it was" do
      sh("switch", "-q", "-c", "feature-x")
      commit_file("feature.rb", "f\n", "feature work")
      write("feature.rb", "g\n")
      head = rev("HEAD")

      result = move.call(repo, "other-name")

      expect(rev("feature-x")).to eq(head)
      expect(rev("HEAD", dir: worktree("other-name"))).to eq(head)
      expect(File.read(File.join(worktree("other-name"), "feature.rb"))).to eq("g\n")
      expect(sh("symbolic-ref", "HEAD").strip).to eq("refs/heads/main")
      expect(result["moved"]).to include("branch" => "other-name", "branch_created" => true, "commits_ahead" => 1)
    end

    it "carries a file staged and changed again, a staged rename, a binary and a mode change exactly" do
      write("app.rb", "one\nSTAGED\nthree\n")
      sh("add", "app.rb")
      write("app.rb", "one\nSTAGED\nthree\nand unstaged\n")
      FileUtils.mkdir_p(File.join(repo, "bin"))
      sh("mv", "run.sh", "bin/run.sh")
      write("logo.bin", "\x00\xFF\xFEnew bytes\x00".b)
      write("new.bin", "\x00\x01\x02".b)
      File.chmod(0o755, File.join(repo, "bin/run.sh"))
      before = work(repo)

      result = move.call(repo, "fix-login")

      expect(work(worktree)).to eq(before)
      expect(File.stat(File.join(worktree, "bin/run.sh")).mode & 0o111).not_to eq(0)
      expect(File.binread(File.join(worktree, "logo.bin"))).to eq("\x00\xFF\xFEnew bytes\x00".b)
      expect(result["moved"]).to include("staged" => ["app.rb", "bin/run.sh"], "unstaged" => ["app.rb", "bin/run.sh", "logo.bin"],
        "untracked" => ["new.bin"])
    end

    it "moves only the commits when a feature branch has no uncommitted changes" do
      sh("switch", "-q", "-c", "feature-x")
      commit_file("feature.rb", "f\n", "feature work")

      result = move.call(repo, nil)

      expect(result["moved"]["snapshot"]).to be_nil
      expect(File.read(File.join(worktree("feature-x"), "feature.rb"))).to eq("f\n")
      expect(sh("symbolic-ref", "HEAD").strip).to eq("refs/heads/main")
    end

    it "uses an existing branch whose tip is HEAD" do
      sh("branch", "fix-login")
      write("app.rb", "changed\n")

      result = move.call(repo, "fix-login")

      expect(result["moved"]).to include("branch_created" => false)
      expect(File.read(File.join(worktree, "app.rb"))).to eq("changed\n")
    end

    it "leaves the notes directory and an untracked nested repository in the main checkout" do
      write("tmp/workspace-notes/research.md", "notes\n")
      write("nested/inner.txt", "inner\n")
      sh("init", "-q", dir: File.join(repo, "nested"))
      committed = File.join(repo, "vendor/committed")
      write("c.txt", "c\n", dir: committed)
      sh("init", "-q", dir: committed)
      sh("add", "c.txt", dir: committed)
      sh("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c", dir: committed)
      write("app.rb", "changed\n")

      result = move.call(repo, "fix-login", notes_dir: File.join(repo, "tmp/workspace-notes"))

      expect(File.read(File.join(repo, "tmp/workspace-notes/research.md"))).to eq("notes\n")
      expect(File.read(File.join(repo, "nested/inner.txt"))).to eq("inner\n")
      expect(%w[nested vendor].map { |d| File.exist?(File.join(worktree, d)) }).to eq([false, false])
      expect(File.read(exclude_file)).to include("/tmp/workspace-notes/\n")
      expect(result["moved"]).to include("untracked" => [], "left_behind" => ["nested/", "vendor/committed/"])
      expect(result["warnings"]).to contain_exactly(include("code" => "left_behind", "paths" => ["nested/", "vendor/committed/"]))
      expect(result["moved"]["main"]).to include("clean" => true)
    end

    it "warns that the default branch is ahead of origin and leaves it there" do
      commit_file("local.rb", "l\n", "local commit")
      write("app.rb", "changed\n")
      head = rev("HEAD")

      result = move.call(repo, "fix-login")

      expect(rev("main")).to eq(head)
      expect(result["warnings"]).to contain_exactly(include("code" => "default_ahead", "branch" => "main", "upstream" => "origin/main",
        "count" => 1, "command" => "git -C #{repo} reset --keep origin/main"))
    end

    it "caps each list at 200 paths and keeps the full count" do
      201.times { |i| write(format("many/f%03d.txt", i), "x") }

      result = move.call(repo, "fix-login")

      expect(result["moved"]["untracked"].size).to eq(200)
      expect(result["moved"]["untracked_count"]).to eq(201)
    end

    it "never touches a stash entry another session pushes while the move runs" do
      other = File.join(@dir, "other")
      sh("worktree", "add", "-q", "-b", "other", other)
      write("theirs-before.txt", "before\n", dir: other)
      sh("stash", "push", "-q", "-u", "-m", "theirs before", dir: other)
      pushed = git_with(stash_push: lambda do |original, *args, **kw|
        original.call(*args, **kw).tap do
          write("theirs-during.txt", "during\n", dir: other)
          sh("stash", "push", "-q", "-u", "-m", "theirs during", dir: other)
        end
      end)
      theirs_before = stash_shas
      write("app.rb", "changed\n")

      mover(pushed).call(repo, "fix-login")

      expect(stash_shas.size).to eq(2)
      expect(stash_shas.last).to eq(theirs_before.first)
      expect(sh("stash", "list", "--format=%gs").lines.map(&:strip)).to eq(["On other: theirs during", "On other: theirs before"])
      expect(File.read(File.join(worktree, "app.rb"))).to eq("changed\n")
    end

    context "with a post-checkout hook" do
      it "warns when the hook fails and judges the steps by their state" do
        sh("switch", "-q", "-c", "feature-x")
        install_hook("post-checkout", "exit 7")
        write("app.rb", "changed\n")

        result = move.call(repo, nil)

        expect(result["warnings"].map { |w| [w["code"], w["step"]] }).to eq([%w[hook_failed switch], %w[hook_failed worktree_add]])
        expect(File.read(File.join(worktree("feature-x"), "app.rb"))).to eq("changed\n")
      end

      it "reports a file the hook writes in the new worktree as an extra, not a failure" do
        install_hook("post-checkout", 'case "$PWD" in */.worktrees/*) echo hook > hook-made.txt;; esac')
        write("app.rb", "changed\n")

        result = move.call(repo, "fix-login")

        expect(result["warnings"]).to contain_exactly(include("code" => "extra_untracked", "paths" => ["hook-made.txt"]))
      end

      it "rolls back when the hook changes a tracked file in the new worktree" do
        install_hook("post-checkout", 'case "$PWD" in */.worktrees/*) echo hook >> logo.bin;; esac')
        dirty_default
        before = fingerprint

        error = error_from { move.call(repo, "fix-login") }

        expect(error.code).to eq("move_failed")
        expect(error.details).to include("step" => "verify", "rolled_back" => true, "snapshot" => include("kept" => false))
        expect(fingerprint).to eq(before)
        expect(File).not_to exist(worktree)
      end
    end

    context "when a step fails" do
      it "rolls back an apply failure and leaves the main checkout byte-identical" do
        failing = git_with(stash_apply: ->(original, path, sha, **kw) { path.include?("/.worktrees/") ? [false, "forced"] : original.call(path, sha, **kw) })
        dirty_default
        write("tmp/workspace-notes/n.md", "n\n")
        before = fingerprint

        error = error_from { mover(failing).call(repo, "fix-login") }

        expect(error.code).to eq("move_failed")
        expect(error.message).to include("Nothing moved")
        expect(error.details).to include("step" => "apply", "rolled_back" => true,
          "snapshot" => include("ref" => start_with("refs/workspace/promote/"), "kept" => false))
        expect(fingerprint).to eq(before)
        expect(File).not_to exist(worktree)
        expect(sh("branch", "--list", "fix-login")).to eq("")
        expect(promote_refs).to eq([])
      end

      it "switches main back to the branch it was on" do
        failing = git_with(create_worktree_at: ->(*) { [false, "forced"] })
        sh("switch", "-q", "-c", "feature-x")
        dirty_default
        before = fingerprint

        error = error_from { mover(failing).call(repo, nil) }

        expect(error.details).to include("step" => "worktree_add", "rolled_back" => true)
        expect(fingerprint).to eq(before)
      end

      it "rolls back a commits-only move, with no snapshot" do
        failing = git_with(create_worktree_at: ->(*) { [false, "forced"] })
        sh("switch", "-q", "-c", "feature-x")
        commit_file("feature.rb", "f\n", "feature work")
        before = fingerprint

        error = error_from { mover(failing).call(repo, nil) }

        expect(error.details).to eq("step" => "worktree_add", "rolled_back" => true, "snapshot" => nil)
        expect(fingerprint).to eq(before)
      end

      it "rolls back a step that raised after changing the checkouts" do
        raising = git_with(create_worktree_at: lambda do |original, *args, **kw|
          original.call(*args, **kw)
          raise Workspace::Error, "git worktree did not finish within 600 seconds."
        end)
        sh("switch", "-q", "-c", "feature-x")
        dirty_default
        before = fingerprint

        error = error_from { mover(raising).call(repo, nil) }

        expect(error.details).to include("step" => "worktree_add", "rolled_back" => true)
        expect(error.message).to include("did not finish")
        expect(fingerprint).to eq(before)
        expect(sh("worktree", "list", "--porcelain")).not_to include(".worktrees")
      end

      it "rolls back rather than overwrite an ignored file the default branch tracks" do
        write("keep.log", "tracked on main\n")
        sh("add", "-f", "keep.log")
        sh("commit", "-q", "-m", "track a log")
        sh("switch", "-q", "-c", "feature-x")
        sh("rm", "-q", "--cached", "keep.log")
        sh("commit", "-q", "-m", "untrack it")
        write("keep.log", "mine, ignored\n")
        write("app.rb", "changed\n")
        before = fingerprint

        error = error_from { move.call(repo, nil) }

        expect(error.details).to include("step" => "switch", "rolled_back" => true)
        expect(fingerprint).to eq(before)
      end

      it "rolls back when the main checkout is not clean after the stash" do
        writer = git_with(stash_push: ->(original, *args, **kw) { original.call(*args, **kw).tap { write("late.txt", "late\n") } })
        write("app.rb", "changed\n")

        error = error_from { mover(writer).call(repo, "fix-login") }

        expect(error.details).to include("step" => "stash", "rolled_back" => true)
        expect(File.read(File.join(repo, "app.rb"))).to eq("changed\n")
        expect(promote_refs).to eq([])
      end

      it "is move_incomplete and keeps the ref when the rollback's apply fails too" do
        failing = git_with(stash_apply: ->(*, **) { [false, "forced"] })
        dirty_default
        before = fingerprint

        error = error_from { mover(failing).call(repo, "fix-login") }

        expect(error.code).to eq("move_incomplete")
        expect(error.details).to include("step" => "rollback_apply", "steps_done" => %w[stash worktree_add worktree_remove branch_delete],
          "main_branch" => "main", "worktree" => nil)
        sha = error.details["snapshot"]["id"]
        ref = error.details["snapshot"]["ref"]
        expect(error.details["snapshot"]).to include("kept" => true)
        expect(error.message).to include(ref)
        expect(promote_refs).to eq(["#{ref} #{sha}"])
        expect(error.details["recover"]).to eq(["git -C #{repo} stash apply --index #{sha}", "git -C #{repo} update-ref -d #{ref} #{sha}"])

        error.details["recover"].each { |command| expect(system(command, out: File::NULL, err: File::NULL)).to be(true) }
        expect(fingerprint).to eq(before)
      end

      it "keeps the ref and names no delete when the main checkout does not match after applying back" do
        failing = git_with(
          stash_apply: ->(original, path, sha, **kw) { path.include?("/.worktrees/") ? [false, "forced"] : original.call(path, sha, **kw) },
          tree_diff: ->(original, dir, from, to) { (dir == repo) ? [%w[M app.rb]] : original.call(dir, from, to) }
        )
        write("app.rb", "changed\n")

        error = error_from { mover(failing).call(repo, "fix-login") }

        sha = error.details["snapshot"]["id"]
        expect(error.details).to include("step" => "rollback_verify", "snapshot" => include("kept" => true))
        expect(error.details["recover"]).to eq(["git -C #{repo} stash show --include-untracked --stat #{sha}"])
        expect(promote_refs.size).to eq(1)
      end

      it "lists the commands to undo each step left when undoing stops early" do
        failing = git_with(stash_apply: ->(*, **) { [false, "forced"] }, remove_worktree: ->(*) { raise Workspace::Error, "locked" })
        sh("switch", "-q", "-c", "feature-x")
        write("app.rb", "changed\n")
        before = fingerprint

        error = error_from { mover(failing).call(repo, nil) }

        expect(error.code).to eq("move_incomplete")
        expect(error.details).to include("step" => "worktree_remove", "worktree" => worktree("feature-x"), "main_branch" => "main")
        expect(error.details["recover"]).to all(start_with("git -C "))
        expect(error.details["recover"].first(2)).to eq(["git -C #{repo} worktree remove --force #{worktree("feature-x")}", "git -C #{repo} switch feature-x"])

        error.details["recover"].each { |command| expect(system(command, out: File::NULL, err: File::NULL)).to be(true) }
        expect(fingerprint).to eq(before)
      end

      it "is move_incomplete with no re-apply when the stash push fails after storing the entry" do
        half = git_with(stash_push: ->(original, *args, **kw) { original.call(*args, **kw).then { |stash, _, _| [stash, false, "cannot remove spec/"] } })
        dirty_default
        before = fingerprint

        error = error_from { mover(half).call(repo, "fix-login") }

        expect(error.code).to eq("move_incomplete")
        expect(error.details).to include("step" => "stash", "steps_done" => ["stash"], "worktree" => nil)
        expect(stash_shas).to eq([])
        expect(promote_refs.size).to eq(1)
        error.details["recover"].each { |command| expect(system(command, out: File::NULL, err: File::NULL)).to be(true) }
        expect(fingerprint).to eq(before)
      end

      it "is stash_failed, with nothing changed, when no entry has the tag" do
        none = git_with(stash_push: ->(*, **) { [nil, false, "fatal: index.lock exists"] })
        dirty_default
        before = fingerprint

        error = error_from { mover(none).call(repo, "fix-login") }

        expect(error.code).to eq("stash_failed")
        expect(error.details).to eq("path" => repo)
        expect(error.message).to include("index.lock exists")
        expect(fingerprint).to eq(before)
      end
    end
  end

  describe "#plan" do
    it "changes nothing, not even info/exclude" do
      dirty_default
      before = fingerprint
      exclude = File.exist?(exclude_file) && File.read(exclude_file)

      result = move.plan(repo, "fix-login")

      expect(fingerprint).to eq(before)
      expect(File.exist?(exclude_file) && File.read(exclude_file)).to eq(exclude)
      expect(File).not_to exist(File.join(repo, ".worktrees"))
      expect(result).to include("branch_required" => false, "path" => worktree)
      expect(result["moved"]).to include("snapshot" => nil, "staged" => ["app.rb"], "unstaged" => ["run.sh"], "untracked" => ["spec/login_spec.rb"],
        "main" => {"path" => repo, "branch" => "main", "clean" => true})
    end

    it "names the branch main would end on" do
      sh("switch", "-q", "-c", "feature-x")
      write("app.rb", "changed\n")

      expect(move.plan(repo, nil)["moved"]["main"]).to include("branch" => "main")
    end

    it "answers with the lists and branch_required on the default branch with no branch" do
      dirty_default

      result = move.plan(repo, nil)

      expect(result).to include("branch_required" => true, "path" => nil)
      expect(result["moved"]).to include("branch" => nil, "branch_created" => nil, "staged" => ["app.rb"])
    end

    it "skips the branch checks without a branch" do
      write("app.rb", "changed\n")
      FileUtils.mkdir_p(worktree("main"))

      expect(move.plan(repo, nil)).to include("branch_required" => true)
    end

    it "leaves out the notes directory and .worktrees/" do
      write("tmp/workspace-notes/n.md", "n\n")
      write(".worktrees/stray.txt", "s\n")
      write("app.rb", "changed\n")

      expect(move.plan(repo, "x", notes_dir: File.join(repo, "tmp/workspace-notes"))["moved"]["untracked"]).to eq([])
    end
  end

  describe "refusals" do
    def refusal(branch = "fix-login", path: repo)
      [error_from { move.plan(path, branch) }, error_from { move.call(path, branch) }].tap do |plan_error, call_error|
        expect([call_error.code, call_error.details]).to eq([plan_error.code, plan_error.details])
      end.first
    end

    before { write("app.rb", "changed\n") }

    it "is branch_required, a usage error, for a real run on the default branch with no branch" do
      error = error_from { move.call(repo, nil) }

      expect(error).to be_a(Workspace::UsageError)
      expect([error.code, error.details]).to eq(["branch_required", {"from_branch" => "main"}])
      expect(work(repo)[:unstaged]).not_to eq("")
    end

    it "is not_main_checkout from a subdirectory" do
      FileUtils.mkdir_p(File.join(repo, "lib"))
      error = refusal(path: File.join(repo, "lib"))
      expect([error.code, error.details]).to eq(["not_main_checkout", {"path" => File.join(repo, "lib")}])
    end

    it "is not_main_checkout in a linked worktree" do
      linked = File.join(@dir, "linked")
      sh("worktree", "add", "-q", "-b", "linked", linked)
      expect(refusal(path: linked).code).to eq("not_main_checkout")
    end

    it "is detached_head" do
      sh("switch", "-q", "--detach")
      expect([refusal.code, refusal.details]).to eq(["detached_head", {"path" => repo}])
    end

    it "is rebase_in_progress" do
      FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))
      expect(refusal.code).to eq("rebase_in_progress")
    end

    it "is git_operation_in_progress for a stopped merge" do
      File.write(File.join(repo, ".git", "MERGE_HEAD"), "#{rev("HEAD")}\n")
      expect([refusal.code, refusal.details]).to eq(["git_operation_in_progress", {"path" => repo, "operation" => "merge"}])
    end

    it "is unmerged_files" do
      sh("switch", "-q", "-c", "side")
      commit_file("run.sh", "side\n", "side")
      sh("switch", "-q", "main")
      sh("checkout", "--", "app.rb")
      commit_file("run.sh", "main\n", "main")
      sh_status("merge", "-q", "side")
      File.delete(File.join(repo, ".git", "MERGE_HEAD"))
      expect([refusal.code, refusal.details]).to eq(["unmerged_files", {"paths" => ["run.sh"], "count" => 1}])
    end

    it "is intent_to_add" do
      write("later.rb", "l\n")
      sh("add", "-N", "later.rb")
      expect([refusal.code, refusal.details]).to eq(["intent_to_add", {"paths" => ["later.rb"], "count" => 1}])
    end

    it "is submodule_changes" do
      lib = File.join(@dir, "lib")
      sh("init", "-q", "-b", "main", lib, dir: @dir)
      commit_file("l.txt", "l\n", "l", dir: lib)
      sh("submodule", "add", "-q", lib, "vendor/lib")
      sh("commit", "-q", "-m", "submodule", "--", ".gitmodules", "vendor/lib")
      write("vendor/lib/l.txt", "changed\n")
      expect([refusal.code, refusal.details]).to eq(["submodule_changes", {"paths" => ["vendor/lib"]}])
    end

    it "is hidden_files for an edited assume-unchanged file, which the stash would overwrite" do
      sh("update-index", "--assume-unchanged", "run.sh")
      write("run.sh", "hidden edit\n")
      before = fingerprint

      expect([refusal.code, refusal.details]).to eq(["hidden_files", {"paths" => ["run.sh"], "count" => 1}])
      expect(fingerprint).to eq(before)
      expect(File.read(File.join(repo, "run.sh"))).to eq("hidden edit\n")
    end

    it "is hidden_files for a skip-worktree file on disk" do
      sh("update-index", "--skip-worktree", "run.sh")
      expect(refusal.code).to eq("hidden_files")
    end

    it "is path_conflicts for a file untracked with git rm --cached" do
      sh("rm", "-q", "--cached", "run.sh")
      expect([refusal.code, refusal.details]).to eq(["path_conflicts", {"paths" => ["run.sh"], "count" => 1}])
    end

    it "is path_conflicts for a tracked file replaced by a directory, and the other way round" do
      File.delete(File.join(repo, "run.sh"))
      write("run.sh/inner", "i\n")
      expect(refusal.details).to eq("paths" => ["run.sh/inner"], "count" => 1)

      FileUtils.rm_rf(File.join(repo, "run.sh"))
      sh("checkout", "--", "run.sh")
      commit_file("lib/a.rb", "a\n", "lib")
      FileUtils.rm_rf(File.join(repo, "lib"))
      write("lib", "now a file\n")
      expect([refusal.code, refusal.details]).to eq(["path_conflicts", {"paths" => ["lib"], "count" => 1}])
    end

    it "is no_default_branch" do
      sh("branch", "-m", "main", "trunk")
      expect([refusal.code, refusal.details]).to eq(["no_default_branch", {"path" => repo}])
    end

    it "is branch_checked_out when the default branch is checked out in another worktree" do
      sh("switch", "-q", "-c", "feature-x")
      elsewhere = File.join(@dir, "main-elsewhere")
      sh("worktree", "add", "-q", elsewhere, "main")
      error = refusal(nil)
      expect([error.code, error.details]).to eq(["branch_checked_out", {"branch" => "main", "path" => elsewhere, "workspace" => nil}])
    end

    it "is branch_checked_out, naming the workspace, when the branch is checked out in a worktree" do
      elsewhere = File.join(@dir, "fix")
      sh("worktree", "add", "-q", elsewhere, "-b", "fix-login")
      move = mover(git, workspace_name: ->(path) { "api.worktree-fix" if path == elsewhere })
      error = error_from { move.call(repo, "fix-login") }
      expect([error.code, error.details]).to eq(["branch_checked_out", {"branch" => "fix-login", "path" => elsewhere, "workspace" => "api.worktree-fix"}])
    end

    it "is branch_exists for a branch at another commit" do
      sh("branch", "fix-login", "HEAD")
      commit_file("more.rb", "m\n", "more")
      write("app.rb", "changed\n")
      error = refusal
      expect([error.code, error.details]).to eq(["branch_exists", {"branch" => "fix-login", "commit" => rev("HEAD~1")}])
    end

    it "is worktree_exists" do
      FileUtils.mkdir_p(worktree)
      expect([refusal.code, refusal.details]).to eq(["worktree_exists", {"path" => worktree}])
    end

    it "is nothing_to_move, naming workspace start" do
      sh("checkout", "--", "app.rb")
      error = refusal
      expect([error.code, error.details]).to eq(["nothing_to_move", {"branch" => "fix-login"}])
      expect(error.message).to include("workspace start fix-login")
    end

    it "is a usage error to name the default branch or a name git refuses" do
      expect(refusal("main")).to be_a(Workspace::UsageError)
      expect(refusal("bad..name")).to be_a(Workspace::UsageError)
      expect(refusal("-x").code).to eq("usage")
    end

    it "writes nothing before refusing" do
      FileUtils.mkdir_p(worktree)
      before = fingerprint
      error_from { move.call(repo, "fix-login") }
      expect(fingerprint).to eq(before)
      expect(File.exist?(exclude_file) && File.read(exclude_file)).not_to include("/.worktrees/")
    end
  end
end
