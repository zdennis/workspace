require "spec_helper"

# The Git methods CheckoutMove uses, against real temp repositories.
RSpec.describe Workspace::Git do
  include MoveRepos

  let(:runner) { Workspace::TimedProcess.method(:run) }
  subject(:git) { described_class.new(output: StringIO.new, input: StringIO.new, runner: runner) }

  describe "#status_entries" do
    it "sorts each change into its kind" do
      write("app.rb", "staged\n")
      sh("add", "app.rb")
      write("app.rb", "staged and changed\n")
      write("run.sh", "unstaged\n")
      FileUtils.mkdir_p(File.join(repo, "bin"))
      sh("mv", "logo.bin", "bin/logo.bin")
      write("dir/deep/new.txt", "n\n")
      write("ita.rb", "i\n")
      sh("add", "-N", "ita.rb")
      write("debug.log", "ignored\n")
      write("nested/x", "x\n")
      sh("init", "-q", dir: File.join(repo, "nested"))

      expect(git.status_entries(repo)).to eq(staged: ["app.rb", "bin/logo.bin"], unstaged: ["app.rb", "run.sh"],
        untracked: ["dir/deep/new.txt", "nested/"], unmerged: [], intent_to_add: ["ita.rb"], submodule: [], deleted: ["logo.bin"])
    end

    it "lists a tracked file deleted in the index or the working tree as deleted" do
      sh("rm", "-q", "--cached", "app.rb")
      File.delete(File.join(repo, "run.sh"))

      expect(git.status_entries(repo)).to include(deleted: ["app.rb", "run.sh"], untracked: ["app.rb"])
    end
  end

  describe "#hidden_files" do
    it "lists assume-unchanged files and skip-worktree files that are on disk" do
      sh("update-index", "--assume-unchanged", "app.rb")
      sh("update-index", "--skip-worktree", "run.sh")
      sh("update-index", "--skip-worktree", "logo.bin")
      File.delete(File.join(repo, "logo.bin"))

      expect(git.hidden_files(repo)).to eq(["app.rb", "run.sh"])
    end

    it "lists unmerged paths" do
      sh("switch", "-q", "-c", "side")
      commit_file("run.sh", "side\n", "side")
      sh("switch", "-q", "main")
      commit_file("run.sh", "main\n", "main")
      sh_status("merge", "-q", "side")

      expect(git.status_entries(repo)[:unmerged]).to eq(["run.sh"])
    end

    it "is nil outside a repository" do
      expect(git.status_entries(@dir)).to be_nil
    end
  end

  describe "#operation_in_progress" do
    it "names each stopped operation, and nil when none is" do
      expect(git.operation_in_progress(repo)).to be_nil
      {"MERGE_HEAD" => "merge", "CHERRY_PICK_HEAD" => "cherry_pick", "REVERT_HEAD" => "revert", "BISECT_LOG" => "bisect"}.each do |file, name|
        path = File.join(repo, ".git", file)
        File.write(path, "x\n")
        expect(git.operation_in_progress(repo)).to eq(name)
        File.delete(path)
      end
    end
  end

  describe "#snapshot_trees and #tree_diff" do
    it "records the index apart from the working tree and changes neither" do
      write("app.rb", "staged\n")
      sh("add", "app.rb")
      write("app.rb", "unstaged\n")
      write("new.txt", "n\n")
      index_before = sh("ls-files", "-s")

      trees = git.snapshot_trees(repo)

      expect(trees[:index]).to eq(sh("write-tree").strip)
      expect(trees[:worktree]).not_to eq(trees[:index])
      expect(sh("ls-files", "-s")).to eq(index_before)
      expect(sh("status", "--porcelain")).to eq("MM app.rb\n?? new.txt\n")
      expect(git.tree_diff(repo, trees[:index], trees[:worktree])).to eq([%w[M app.rb], %w[A new.txt]])
    end

    it "leaves out the skipped directories" do
      write("nested/x", "x\n")
      sh("init", "-q", dir: File.join(repo, "nested"))

      expect(git.snapshot_trees(repo)).to be_nil
      expect(git.snapshot_trees(repo, skip: ["nested/"])).to eq(index: sh("write-tree").strip, worktree: sh("write-tree").strip)
    end
  end

  describe "#stash_push with include_untracked" do
    it "finds the entry by its tag, below an entry pushed after it" do
      write("app.rb", "mine\n")
      stash, ok, = git.stash_push(repo, "workspace promote: x abc", include_untracked: true)
      write("run.sh", "theirs\n")
      sh("stash", "push", "-q", "-m", "theirs")

      expect(ok).to be(true)
      expect(stash.sha).to eq(rev("stash@{1}"))
    end

    it "finds no entry when git had nothing to save, though it exits 0" do
      expect(git.stash_push(repo, "workspace promote: x abc", include_untracked: true).first(2)).to eq([nil, true])
    end

    it "still looks for the tag when git runs out of time" do
      timing_out = lambda do |argv, chdir:, timeout:|
        Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout).tap { raise Timeout::Error if argv.include?("push") }
      end
      write("app.rb", "mine\n")

      stash, ok, stderr = described_class.new(runner: timing_out).stash_push(repo, "workspace promote: x abc", include_untracked: true)

      expect([stash.sha, ok]).to eq([rev("stash@{0}"), false])
      expect(stderr).to include("did not finish")
    end
  end

  describe "#stash_drop" do
    it "drops only its own entry" do
      write("app.rb", "theirs\n")
      sh("stash", "push", "-q", "-m", "theirs")
      write("app.rb", "mine\n")
      sh("stash", "push", "-q", "-m", "mine")
      theirs = rev("stash@{1}")

      expect(git.stash_drop(repo, Workspace::Git::Stash.new(rev("stash@{0}"), "mine"))).to be(true)
      expect(stash_shas).to eq([theirs])
    end

    context "when another entry is pushed between the check and the drop" do
      let(:runner) do
        pushed = false
        lambda do |argv, chdir:, timeout:|
          if argv.include?("drop") && !pushed
            pushed = true
            write("run.sh", "theirs\n")
            sh("stash", "push", "-q", "-m", "theirs")
          end
          Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout)
        end
      end

      it "stores the other entry back and drops its own" do
        write("app.rb", "mine\n")
        sh("stash", "push", "-q", "-m", "mine")
        mine = rev("stash@{0}")

        expect(git.stash_drop(repo, Workspace::Git::Stash.new(mine, "mine"))).to be(true)
        expect(stash_shas.size).to eq(1)
        expect(sh("stash", "list", "--format=%gs").strip).to eq("On main: theirs")
        expect(sh("stash", "show", "--name-only", "stash@{0}").strip).to eq("run.sh")
      end
    end

    it "is true when the entry is not on the list" do
      expect(git.stash_drop(repo, Workspace::Git::Stash.new(rev("HEAD"), "mine"))).to be(true)
    end
  end

  describe "#pin_ref and #delete_ref" do
    it "pins only a new ref and deletes only while it names the commit" do
      head = rev("HEAD")

      expect(git.pin_ref(repo, "refs/workspace/promote/a", head)).to be(true)
      expect(git.pin_ref(repo, "refs/workspace/promote/a", head)).to be(false)
      expect(git.delete_ref(repo, "refs/workspace/promote/a", "1" * 40)).to be(false)
      expect(git.delete_ref(repo, "refs/workspace/promote/a", head)).to be(true)
      expect(promote_refs).to eq([])
    end
  end

  describe "#stash_apply with index" do
    it "applies a stash commit that is off the list, the index kept apart" do
      write("app.rb", "staged\n")
      sh("add", "app.rb")
      write("new.txt", "n\n")
      stash, = git.stash_push(repo, "t1", include_untracked: true)
      sh("stash", "drop", "-q")

      expect(git.stash_apply(repo, stash.sha, index: true).first).to be(true)
      expect(sh("status", "--porcelain")).to eq("M  app.rb\n?? new.txt\n")
    end
  end

  describe "#switch" do
    it "refuses to replace an ignored file the other branch tracks" do
      sh("switch", "-q", "-c", "side")
      write("keep.log", "tracked\n")
      sh("add", "-f", "keep.log")
      sh("commit", "-q", "-m", "track a log")
      sh("switch", "-q", "main")
      write("keep.log", "mine\n")

      ok, = git.switch(repo, "side")

      expect(ok).to be(false)
      expect(File.read(File.join(repo, "keep.log"))).to eq("mine\n")
      expect(git.worktree_branch(repo)).to eq("main")
    end
  end

  describe "#create_worktree_at" do
    it "makes a new branch at a start point, or checks out an existing one" do
      head = rev("HEAD")
      sh("branch", "existing")
      new_wt = File.join(@dir, "new")
      old_wt = File.join(@dir, "old")

      expect(git.create_worktree_at(repo, new_wt, "fresh", start_point: head).first).to be(true)
      expect(git.create_worktree_at(repo, old_wt, "existing").first).to be(true)
      expect([git.worktree_branch(new_wt), git.worktree_branch(old_wt)]).to eq(%w[fresh existing])
    end
  end

  describe "#valid_branch_name?" do
    it "accepts what git accepts as a branch name" do
      expect(git.valid_branch_name?(repo, "feature/login")).to be(true)
      expect(%w[bad..name -x a~b].push("").map { |name| git.valid_branch_name?(repo, name) }).to all(be(false))
    end
  end

  describe "#rev_parse" do
    it "names a commit, or nil" do
      expect(git.rev_parse(repo, "HEAD")).to match(/\A\h{40}\z/)
      expect(git.rev_parse(repo, "refs/heads/none")).to be_nil
    end
  end
end
