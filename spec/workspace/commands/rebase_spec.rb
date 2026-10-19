require "spec_helper"
require "json"

RSpec.describe Workspace::Commands::Rebase do
  include RebaseRepos

  let(:output) { StringIO.new }
  let(:runner) { Workspace::TimedProcess.method(:run) }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: runner) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "api.worktree-x") }
  let(:checkout) { Workspace::WorkspaceCheckout.new(git: git, project_config: project_config, project_detector: project_detector) }
  subject(:command) { described_class.new(git: git, checkout: checkout, output: output) }

  before { allow(project_config).to receive(:project_root_for).with("api.worktree-x").and_return(wt) }

  def document = JSON.parse(output.string)

  def run_json(onto)
    command.call(onto: onto, json: true, working_dir: wt)
    document
  end

  # A runner that fails the git calls whose first words match, and runs the rest.
  def failing(*words)
    lambda do |argv, chdir:, timeout:|
      return ["", "forced failure\n", false] if words.all? { |w| argv.include?(w) }
      Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout)
    end
  end

  def advance_main(message = "main moves", file: "main.txt")
    commit_file(file, "#{message}\n", message)
  end

  describe "--onto local" do
    it "rebases onto the local default branch without fetching" do
      advance_main
      sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

      expect(run_json("local")).to include("ok" => true, "workspace" => "api.worktree-x", "branch" => "feature/x", "onto" => "local",
        "outcome" => "rebased", "reason" => nil, "aborted" => nil, "conflicted" => [], "detail" => nil, "schema_version" => 1)
      expect(sh("merge-base", "--is-ancestor", "main", "feature/x", dir: wt)).to eq("")
      expect(File).to exist(File.join(wt, "main.txt"))
    end

    it "reports up_to_date and changes nothing when the branch already has the default branch" do
      before_head = rev("HEAD", dir: wt)

      expect(run_json("local")).to include("outcome" => "up_to_date")
      expect(rev("HEAD", dir: wt)).to eq(before_head)
    end

    it "prints one sentence without --json" do
      advance_main
      command.call(onto: "local", working_dir: wt)

      expect(output.string).to eq("Rebased feature/x onto local.\n")
    end

    it "prints the up-to-date sentence" do
      command.call(onto: "local", working_dir: wt)

      expect(output.string).to eq("feature/x is already up to date with local.\n")
    end

    it "aborts its own conflicted rebase and lists the files" do
      commit_file("clash.txt", "main\n", "main clash")
      commit_file("clash.txt", "feature\n", "feature clash", dir: wt)
      before_head = rev("HEAD", dir: wt)

      result = run_json("local")

      expect(result).to include("outcome" => "conflict", "reason" => "conflict", "aborted" => true, "conflicted" => ["clash.txt"])
      expect(result["detail"]).to be_a(String)
      expect(git.rebase_in_progress?(wt)).to be(false)
      expect(rev("HEAD", dir: wt)).to eq(before_head)
      expect(sh("status", "--porcelain", dir: wt)).to eq("")
    end

    it "prints the conflicted files without --json" do
      commit_file("clash.txt", "main\n", "main clash")
      commit_file("clash.txt", "feature\n", "feature clash", dir: wt)

      command.call(onto: "local", working_dir: wt)

      expect(output.string).to eq("Rebase of feature/x stopped on a conflict and was aborted.\n  clash.txt\n")
    end

    it "says aborted is false when git rebase --abort fails" do
      commit_file("clash.txt", "main\n", "main clash")
      commit_file("clash.txt", "feature\n", "feature clash", dir: wt)
      allow(git).to receive(:rebase_abort).and_return(false)

      result = run_json("local")

      expect(result).to include("outcome" => "conflict", "aborted" => false)
      expect(result["detail"]).to include("--abort failed")
    end

    context "when git runs past its time limit during the rebase" do
      let(:timing_out) do
        lambda do |argv, chdir:, timeout:|
          Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout)
          raise Timeout::Error if argv.include?("rebase") && !argv.include?("--abort")
          ["", "", true]
        end
      end
      let(:slow_git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: timing_out) }
      let(:cmd) { described_class.new(git: slow_git, checkout: checkout, output: output) }

      before do
        commit_file("clash.txt", "main\n", "main clash")
        commit_file("clash.txt", "feature\n", "feature clash", dir: wt)
      end

      it "aborts the stopped rebase and says so, with details.aborted true" do
        before_head = rev("HEAD", dir: wt)

        expect { cmd.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("error")
          expect(e.details).to eq("aborted" => true)
          expect(e.message).to include("did not finish within").and include("rebase was aborted").and include("'feature/x' is unchanged")
        }
        expect(git.rebase_in_progress?(wt)).to be(false)
        expect(rev("HEAD", dir: wt)).to eq(before_head)
      end

      it "raises rebase_in_progress with details.aborted false when the abort fails" do
        allow(slow_git).to receive(:rebase_abort).and_return(false)

        expect { cmd.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("rebase_in_progress")
          expect(e.details).to eq("path" => wt, "aborted" => false)
          expect(e.message).to include("still in the middle of a rebase").and include("git rebase --abort")
        }
        expect(git.rebase_in_progress?(wt)).to be(true)
      end

      it "re-raises the plain timeout error when no rebase was left in progress" do
        never_started = ->(argv, chdir:, timeout:) { argv.include?("rebase") ? raise(Timeout::Error) : Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout) }
        idle_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: never_started)
        idle_cmd = described_class.new(git: idle_git, checkout: checkout, output: output)

        expect { idle_cmd.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("error")
          expect(e.details).not_to include("aborted")
          expect(e.message).to eq("git rebase did not finish within #{Workspace::Git::REBASE_TIMEOUT} seconds.")
        }
      end
    end

    it "raises a plain error for a rebase that fails without stopping" do
      advance_main
      failing_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: failing("rebase"))
      cmd = described_class.new(git: failing_git, checkout: checkout, output: output)

      expect { cmd.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error, /git rebase onto main failed: forced failure/)
    end
  end

  describe "refusals" do
    it "refuses a bad or missing --onto as a usage error" do
      [nil, "sideways"].each do |onto|
        expect { command.call(onto: onto, working_dir: wt) }.to raise_error(Workspace::UsageError, /--onto must be one of local, update, remote/)
      end
    end

    it "refuses changes to tracked files and names them" do
      File.write(File.join(wt, "feature.txt"), "edited\n")
      File.write(File.join(wt, "staged.txt"), "x\n")
      sh("add", "staged.txt", dir: wt)

      expect { command.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("dirty_worktree")
        expect(e.details["files"]).to contain_exactly("feature.txt", "staged.txt")
        expect(e.details["path"]).to eq(wt)
      }
      expect(File.read(File.join(wt, "feature.txt"))).to eq("edited\n")
      expect(sh("stash", "list", dir: wt)).to eq("")
    end

    it "does not count untracked files as dirty" do
      advance_main
      File.write(File.join(wt, "scratch.txt"), "x\n")

      expect(run_json("local")).to include("outcome" => "rebased")
    end

    it "refuses a workspace whose git state cannot be read" do
      allow(git).to receive(:dirty_tracked_files).and_return(nil)

      expect { command.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error, /could not read the state/)
    end

    it "refuses a rebase that is already stopped" do
      commit_file("clash.txt", "main\n", "main clash")
      commit_file("clash.txt", "feature\n", "feature clash", dir: wt)
      _, ok = sh_status("rebase", "main", dir: wt)
      expect(ok).to be(false)

      expect { command.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("rebase_in_progress")
        expect(e.details).to eq("path" => wt)
      }
      expect(git.rebase_in_progress?(wt)).to be(true)
    end

    it "refuses a detached HEAD" do
      sh("checkout", "-q", "--detach", dir: wt)

      expect { command.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error, /detached HEAD/)
    end

    it "refuses the default branch itself" do
      allow(project_config).to receive(:project_root_for).with("api.worktree-x").and_return(repo)

      expect { command.call(onto: "local", working_dir: repo) }.to raise_error(Workspace::Error, /is the default branch/)
    end

    it "raises when the repository has no main or master" do
      sh("branch", "-m", "main", "trunk")
      sh("update-ref", "-d", "refs/remotes/origin/main")

      expect { command.call(onto: "local", working_dir: wt) }.to raise_error(Workspace::Error, /No default branch/)
    end

    it "raises when the target ref does not exist" do
      empty_remote = File.join(@dir, "empty.git")
      sh("init", "-q", "--bare", "-b", "main", empty_remote, dir: @dir)
      sh("remote", "set-url", "origin", empty_remote)
      sh("update-ref", "-d", "refs/remotes/origin/main")

      expect { command.call(onto: "remote", working_dir: wt) }.to raise_error(Workspace::Error, /'origin\/main' does not exist/)
    end
  end

  describe "--onto upstream" do
    def push_feature
      sh("push", "-q", "-u", "origin", "feature/x", dir: wt)
    end

    def teammate_pushes_to(branch, file)
      clone_other
      sh("checkout", "-q", branch, dir: other)
      commit_file(file, "x\n", "teammate #{file}", dir: other)
      sh("push", "-q", "origin", branch, dir: other)
    end

    it "rebases a feature branch onto its own upstream" do
      push_feature
      teammate_pushes_to("feature/x", "mate.txt")
      expect(File).not_to exist(File.join(wt, "mate.txt"))

      expect(run_json("upstream")).to include("ok" => true, "onto" => "upstream", "branch" => "feature/x", "outcome" => "rebased")
      expect(File).to exist(File.join(wt, "mate.txt"))
    end

    it "reports up_to_date when the branch already has its upstream" do
      push_feature
      before_head = rev("HEAD", dir: wt)

      expect(run_json("upstream")).to include("outcome" => "up_to_date")
      expect(rev("HEAD", dir: wt)).to eq(before_head)
    end

    it "rebases the default branch onto origin's, which the other targets refuse" do
      teammate_pushes_to("main", "up.txt")
      allow(project_config).to receive(:project_root_for).with("api.worktree-x").and_return(repo)

      command.call(onto: "upstream", json: true, working_dir: repo)

      expect(document).to include("branch" => "main", "outcome" => "rebased")
      expect(File).to exist(File.join(repo, "up.txt"))
      expect { command.call(onto: "remote", working_dir: repo) }.to raise_error(Workspace::Error, /is the default branch/)
    end

    it "prints one sentence without --json" do
      push_feature
      command.call(onto: "upstream", working_dir: wt)

      expect(output.string).to eq("feature/x is already up to date with upstream.\n")
    end

    it "raises no_upstream for a branch that was never pushed" do
      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("no_upstream")
        expect(e.details).to eq("branch" => "feature/x")
      }
    end

    it "raises upstream_gone when the branch was deleted on the remote" do
      push_feature
      clone_other
      sh("push", "-q", "origin", "--delete", "feature/x", dir: other)
      before_head = rev("HEAD", dir: wt)

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("upstream_gone")
        expect(e.details).to eq("branch" => "feature/x", "upstream" => "origin/feature/x")
      }
      expect(rev("HEAD", dir: wt)).to eq(before_head)
    end

    it "raises upstream_gone whatever language git's fetch error is in" do
      push_feature
      clone_other
      sh("push", "-q", "origin", "--delete", "feature/x", dir: other)
      allow(git).to receive(:fetch).and_return([false, "fatal: référence distante introuvable feature/x\n"])

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("upstream_gone")
      }
    end

    it "raises upstream_gone when the remote-tracking branch was already pruned" do
      push_feature
      sh("update-ref", "-d", "refs/remotes/origin/feature/x")
      sh("push", "-q", "origin", "--delete", "feature/x", dir: wt)

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("upstream_gone")
      }
    end

    it "rebases onto a local branch upstream without fetching, and raises upstream_gone when it is deleted" do
      advance_main
      sh("branch", "--set-upstream-to=main", dir: wt)
      sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

      expect(run_json("upstream")).to include("outcome" => "rebased")

      sh("branch", "-q", "--unset-upstream", dir: wt)
      sh("branch", "-q", "tmp-up", dir: wt)
      sh("branch", "--set-upstream-to=tmp-up", dir: wt)
      sh("branch", "-q", "-D", "tmp-up")
      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("upstream_gone") }
    end

    it "raises fetch_failed when the remote cannot be reached" do
      push_feature
      sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("fetch_failed")
        expect(e.details).to include("remote" => "origin")
      }
    end

    it "aborts its own conflicted rebase" do
      push_feature
      teammate_pushes_to("feature/x", "feature.txt")
      commit_file("feature.txt", "mine\n", "my edit", dir: wt)
      before_head = rev("HEAD", dir: wt)

      result = run_json("upstream")

      expect(result).to include("outcome" => "conflict", "aborted" => true, "conflicted" => ["feature.txt"])
      expect(git.rebase_in_progress?(wt)).to be(false)
      expect(rev("HEAD", dir: wt)).to eq(before_head)
    end

    it "refuses dirty tracked files without stashing them" do
      push_feature
      File.write(File.join(wt, "feature.txt"), "edited\n")

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("dirty_worktree") }
      expect(sh("stash", "list", dir: wt)).to eq("")
    end

    it "refuses a rebase that is already stopped" do
      push_feature
      allow(git).to receive(:rebase_in_progress?).and_return(true)

      expect { command.call(onto: "upstream", working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("rebase_in_progress") }
    end
  end

  describe "--onto remote" do
    it "fetches and rebases onto origin's default branch, leaving the local one alone" do
      clone_other
      commit_file("up.txt", "up\n", "upstream work", dir: other)
      sh("push", "-q", "origin", "main", dir: other)
      local_main = rev("main")

      expect(run_json("remote")).to include("onto" => "remote", "outcome" => "rebased")
      expect(File).to exist(File.join(wt, "up.txt"))
      expect(rev("main")).to eq(local_main)
    end

    it "raises fetch_failed when origin cannot be reached" do
      sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))

      expect { command.call(onto: "remote", working_dir: wt) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("fetch_failed")
        expect(e.details).to include("remote" => "origin")
        expect(e.details["detail"]).to be_a(String)
      }
    end
  end

  describe "--onto update" do
    before do
      clone_other
      commit_file("up.txt", "up\n", "upstream work", dir: other)
      sh("push", "-q", "origin", "main", dir: other)
    end

    it "moves a clean checked-out default branch to origin's, then rebases onto it" do
      expect(run_json("update")).to include("onto" => "update", "outcome" => "rebased")

      expect(rev("main")).to eq(rev("origin/main", dir: other))
      expect(File).to exist(File.join(repo, "up.txt"))
      expect(File).to exist(File.join(wt, "up.txt"))
    end

    it "stashes and restores changes in the default checkout" do
      File.write(File.join(repo, "base.txt"), "dirty\n")

      expect(run_json("update")).to include("outcome" => "rebased")

      expect(rev("main")).to eq(rev("origin/main", dir: other))
      expect(File.read(File.join(repo, "base.txt"))).to eq("dirty\n")
      expect(sh("stash", "list")).to eq("")
    end

    it "leaves another session's stash entry alone" do
      File.write(File.join(repo, "base.txt"), "other session\n")
      sh("stash", "push", "-m", "someone else")
      File.write(File.join(repo, "base.txt"), "dirty\n")

      expect(run_json("update")).to include("outcome" => "rebased")

      expect(File.read(File.join(repo, "base.txt"))).to eq("dirty\n")
      expect(sh("stash", "list")).to match(/\Astash@\{0\}: On main: someone else\n\z/)
    end

    it "reports stash_pop when the stashed changes do not apply back, keeping the stash" do
      sh("fetch", "-q", "origin")
      commit_file("shared.txt", "one\n", "add shared", dir: other)
      sh("push", "-q", "origin", "main", dir: other)
      sh("pull", "-q", "--ff-only")
      commit_file("shared.txt", "two\n", "edit shared", dir: other)
      sh("push", "-q", "origin", "main", dir: other)
      File.write(File.join(repo, "shared.txt"), "mine\n")

      result = run_json("update")

      expect(result).to include("outcome" => "default_not_updated", "reason" => "stash_pop")
      expect(result["detail"]).to include("kept in the stash")
      expect(sh("stash", "list")).to include("workspace-rebase-")
      expect(result["detail"]).to match(/kept in the stash as \h{40}/)
    end

    it "reports diverged when local and origin each have commits the other lacks" do
      commit_file("local.txt", "local\n", "local only")
      feature_head = rev("HEAD", dir: wt)

      result = run_json("update")

      expect(result).to include("outcome" => "default_not_updated", "reason" => "diverged")
      expect(result["detail"]).to include("each have commits")
      expect(rev("HEAD", dir: wt)).to eq(feature_head)
    end

    it "moves a default branch that is checked out nowhere" do
      sh("switch", "-q", "-c", "elsewhere")

      expect(run_json("update")).to include("outcome" => "rebased")
      expect(rev("main")).to eq(rev("origin/main", dir: other))
    end

    it "rebases onto a local default branch that is ahead of origin's without moving it" do
      sh("fetch", "-q", "origin")
      sh("pull", "-q", "--ff-only")
      commit_file("ahead.txt", "ahead\n", "local ahead")
      ahead = rev("main")

      expect(run_json("update")).to include("outcome" => "rebased")
      expect(rev("main")).to eq(ahead)
    end

    it "rebases onto the local branch when origin has no default branch" do
      sh("update-ref", "-d", "refs/remotes/origin/main")
      empty_remote = File.join(@dir, "empty.git")
      sh("init", "-q", "--bare", "-b", "main", empty_remote, dir: @dir)
      sh("remote", "set-url", "origin", empty_remote)

      expect(run_json("update")).to include("outcome" => "up_to_date")
    end

    it "raises fetch_failed before touching anything when origin cannot be reached" do
      sh("remote", "set-url", "origin", File.join(@dir, "nowhere.git"))
      main_before = rev("main")

      expect { command.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("fetch_failed") }
      expect(rev("main")).to eq(main_before)
    end

    it "raises when origin has a default branch but there is no local one" do
      sh("switch", "-q", "-c", "elsewhere")
      sh("branch", "-q", "-D", "main")

      expect { command.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error, /No local branch 'main' to update/)
    end

    it "raises when the unchecked-out default branch cannot be moved" do
      sh("switch", "-q", "-c", "elsewhere")
      failing_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: failing("update-ref"))
      cmd = described_class.new(git: failing_git, checkout: checkout, output: output)

      expect { cmd.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error, /Could not move 'main' to origin\/main/)
    end

    it "raises when the changes in the default checkout cannot be stashed" do
      File.write(File.join(repo, "base.txt"), "dirty\n")
      failing_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: failing("stash"))
      cmd = described_class.new(git: failing_git, checkout: checkout, output: output)

      expect { cmd.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error, /Could not stash the changes/)
      expect(File.read(File.join(repo, "base.txt"))).to eq("dirty\n")
    end

    it "says git saved nothing when the stash push succeeds without an entry" do
      File.write(File.join(repo, "base.txt"), "dirty\n")
      saving_nothing = lambda do |argv, chdir:, timeout:|
        next ["", "", true] if argv.include?("stash") && argv.include?("push")
        Workspace::TimedProcess.run(argv, chdir: chdir, timeout: timeout)
      end
      quiet_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: saving_nothing)
      cmd = described_class.new(git: quiet_git, checkout: checkout, output: output)

      expect { cmd.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error, /Could not stash the changes in .+: git saved nothing\z/)
    end

    it "reports diverged when the checked-out default branch cannot be fast-forwarded" do
      failing_git = Workspace::Git.new(output: StringIO.new, input: StringIO.new, runner: failing("merge"))
      cmd = described_class.new(git: failing_git, checkout: checkout, output: output)
      cmd.call(onto: "update", json: true, working_dir: wt)

      expect(document).to include("outcome" => "default_not_updated", "reason" => "diverged")
      expect(document["detail"]).to include("could not be fast-forwarded")
    end

    it "raises when the default checkout's state cannot be read" do
      allow(git).to receive(:dirty_tracked_files).and_call_original
      allow(git).to receive(:dirty_tracked_files).with(repo).and_return(nil)

      expect { command.call(onto: "update", working_dir: wt) }.to raise_error(Workspace::Error, /could not read the state of #{Regexp.escape(repo)}/)
    end

    it "prints the reason without --json" do
      commit_file("local.txt", "local\n", "local only")

      command.call(onto: "update", working_dir: wt)

      expect(output.string).to start_with("Default branch not updated (diverged):")
    end
  end
end
