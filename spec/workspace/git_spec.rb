require "stringio"
require "timeout"

RSpec.describe Workspace::Git do
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  subject(:git) { described_class.new(output: output, input: input) }

  describe "#parse_start_input" do
    it "parses a JIRA URL" do
      result = git.parse_start_input("https://mycompany.atlassian.net/browse/PROJ-123")
      expect(result).to eq({type: :jira_key, value: "PROJ-123"})
    end

    it "parses a GitHub PR URL" do
      result = git.parse_start_input("https://github.com/owner/repo/pull/471")
      expect(result).to eq({type: :pr_url, value: "https://github.com/owner/repo/pull/471", repo: "owner/repo", number: "471"})
    end

    it "parses a GitHub PR URL with a trailing path" do
      result = git.parse_start_input("https://github.com/owner/repo/pull/471/files")
      expect(result).to include(type: :pr_url, repo: "owner/repo", number: "471")
    end

    it "parses a bare #n PR ref with no repo" do
      result = git.parse_start_input("#835")
      expect(result).to eq({type: :pr_url, value: "#835", repo: nil, number: "835"})
    end

    it "parses an owner/repo#n PR ref" do
      result = git.parse_start_input("acme/api#835")
      expect(result).to eq({type: :pr_url, value: "acme/api#835", repo: "acme/api", number: "835"})
    end

    it "allows dots, dashes and underscores in an owner/repo#n ref" do
      result = git.parse_start_input("my-org/my_repo.js#7")
      expect(result).to include(type: :pr_url, repo: "my-org/my_repo.js", number: "7")
    end

    it "treats a branch containing # but not shaped like a PR ref as a branch" do
      expect(git.parse_start_input("fix#12-thing")).to eq({type: :branch, value: "fix#12-thing"})
      expect(git.parse_start_input("a/b/c#12")).to eq({type: :branch, value: "a/b/c#12"})
      expect(git.parse_start_input("#12abc")).to eq({type: :branch, value: "#12abc"})
    end

    it "parses a GitHub issue URL" do
      result = git.parse_start_input("https://github.com/owner/repo/issues/42")
      expect(result).to eq({type: :issue_url, value: "issue-42"})
    end

    it "treats singular /issue/ path as a branch (GitHub only uses /issues/)" do
      result = git.parse_start_input("https://github.com/owner/repo/issue/42")
      expect(result).to eq({type: :branch, value: "https://github.com/owner/repo/issue/42"})
    end

    it "parses a JIRA key" do
      result = git.parse_start_input("PROJ-123")
      expect(result).to eq({type: :jira_key, value: "PROJ-123"})
    end

    it "parses a branch name" do
      result = git.parse_start_input("user/PROJ-123")
      expect(result).to eq({type: :branch, value: "user/PROJ-123"})
    end

    it "treats lowercase jira-like input as a branch" do
      result = git.parse_start_input("proj-123")
      expect(result).to eq({type: :branch, value: "proj-123"})
    end
  end

  describe "#sanitize_for_filesystem" do
    it "replaces special characters with dashes" do
      expect(git.sanitize_for_filesystem('a/b\\c:d*e?"f<g>h|i')).to eq("a-b-c-d-e-f-g-h-i")
    end

    it "collapses consecutive dashes" do
      expect(git.sanitize_for_filesystem("a//b")).to eq("a-b")
    end

    it "strips leading and trailing dashes" do
      expect(git.sanitize_for_filesystem("/hello/")).to eq("hello")
    end

    it "handles already-clean names" do
      expect(git.sanitize_for_filesystem("feature-branch")).to eq("feature-branch")
    end
  end

  describe "#find_matching_branches" do
    let(:branches) do
      ["main", "feature/PROJ-123", "feature/PROJ-124", "bugfix/proj-123-hotfix"]
    end

    it "returns exact matches first" do
      result = git.find_matching_branches("main", branches: branches)
      expect(result).to eq(["main"])
    end

    it "returns contains matches when no exact match" do
      result = git.find_matching_branches("PROJ-123", branches: branches)
      expect(result).to eq(["feature/PROJ-123"])
    end

    it "returns case-insensitive matches as last resort" do
      result = git.find_matching_branches("proj-124", branches: branches)
      expect(result).to eq(["feature/PROJ-124"])
    end

    it "returns empty when nothing matches" do
      result = git.find_matching_branches("nonexistent", branches: branches)
      expect(result).to eq([])
    end
  end

  describe "#prompt_branch_selection" do
    it "returns the selected branch for a valid choice" do
      input = StringIO.new("2\n")
      git = described_class.new(output: output, input: input)
      result = git.prompt_branch_selection(["branch-a", "branch-b", "branch-c"], "pattern")
      expect(result).to eq("branch-b")
    end

    it "returns nil when user chooses 0" do
      input = StringIO.new("0\n")
      git = described_class.new(output: output, input: input)
      result = git.prompt_branch_selection(["branch-a"], "pattern")
      expect(result).to be_nil
    end

    it "displays the branches and prompt" do
      input = StringIO.new("1\n")
      git = described_class.new(output: output, input: input)
      git.prompt_branch_selection(["branch-a", "branch-b"], "test")
      expect(output.string).to include("Multiple remote branches match 'test':")
      expect(output.string).to include("1) branch-a")
      expect(output.string).to include("2) branch-b")
      expect(output.string).to include("0) None")
    end
  end

  describe "#worktree_exists?" do
    let(:worktree_path) { "/Users/me/project/.worktrees/feature-x" }

    it "returns true when the path appears in the worktree list" do
      porcelain = <<~OUTPUT
        worktree /Users/me/project
        HEAD abc123
        branch refs/heads/main

        worktree #{worktree_path}
        HEAD def456
        branch refs/heads/feature-x

      OUTPUT
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "list", "--porcelain")
        .and_return([porcelain, "", double(success?: true)])

      expect(git.worktree_exists?(worktree_path)).to be true
    end

    it "returns false when the path does not appear in the worktree list" do
      porcelain = <<~OUTPUT
        worktree /Users/me/project
        HEAD abc123
        branch refs/heads/main

      OUTPUT
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "list", "--porcelain")
        .and_return([porcelain, "", double(success?: true)])

      expect(git.worktree_exists?(worktree_path)).to be false
    end

    it "does not match a worktree whose path merely starts with the given path" do
      porcelain = "worktree #{worktree_path}-bar\nHEAD def456\nbranch refs/heads/feature-x-bar\n\n"
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "list", "--porcelain")
        .and_return([porcelain, "", double(success?: true)])

      expect(git.worktree_exists?(worktree_path)).to be false
    end

    it "returns false when git errors (e.g. path does not exist)" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "list", "--porcelain")
        .and_return(["", "fatal: not a git repository", double(success?: false)])

      expect(git.worktree_exists?(worktree_path)).to be false
    end
  end

  describe "#remove_worktree" do
    let(:worktree_path) { "/Users/me/project/.worktrees/feature-x" }

    it "re-checks for unsaved work, then removes with --force so untracked files don't block it" do
      allow(git).to receive(:unsaved_work).with(worktree_path).and_return(nil)
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", "--force", worktree_path)
        .and_return(["", "", double(success?: true)])

      expect { git.remove_worktree(worktree_path) }.not_to raise_error
    end

    it "refuses with UnsavedWorkError, without running git worktree remove, when there is unsaved work" do
      unsaved = {changed_files: 1, unpushed_commits: 0, branch: "feature-x"}
      allow(git).to receive(:unsaved_work).with(worktree_path).and_return(unsaved)
      expect(Open3).not_to receive(:capture3).with("git", "-C", worktree_path, "worktree", "remove", any_args)

      expect { git.remove_worktree(worktree_path) }.to raise_error(Workspace::UnsavedWorkError) { |e|
        expect(e.unsaved).to eq(unsaved)
        expect(e.message).to include("1 changed file(s) and 0 unpushed commit(s) on feature-x")
      }
    end

    it "refuses when git can't tell whether there is unsaved work" do
      allow(git).to receive(:unsaved_work).with(worktree_path).and_return(:unknown)

      expect { git.remove_worktree(worktree_path) }.to raise_error(Workspace::UnsavedWorkError, /couldn't check/)
    end

    it "skips the check when force: true" do
      expect(git).not_to receive(:unsaved_work)
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", "--force", worktree_path)
        .and_return(["", "", double(success?: true)])

      expect { git.remove_worktree(worktree_path, force: true) }.not_to raise_error
    end

    it "raises Workspace::Error when git fails" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", "--force", worktree_path)
        .and_return(["", "fatal: not a worktree", double(success?: false)])

      expect { git.remove_worktree(worktree_path, force: true) }
        .to raise_error(Workspace::Error, /fatal: not a worktree/)
    end
  end

  describe "#checkout_pr_worktree" do
    # A stand-in `gh` on PATH that behaves like `gh pr checkout`: progress on
    # stderr, the worktree directory created on success, GraphQL errors on
    # stderr with exit 1, and cobra's "unknown flag" for a gh without --worktree.
    let(:bin_dir) { Dir.mktmpdir }
    let(:argv_log) { File.join(bin_dir, "argv.log") }
    let(:cwd_log) { File.join(bin_dir, "cwd.log") }
    let(:repo_dir) { Dir.mktmpdir }
    let(:worktree_path) { File.join(repo_dir, ".worktrees", "pr-835") }

    def install_fake_gh(mode: "ok")
      path = File.join(bin_dir, "gh")
      File.write(path, <<~SH)
        #!/bin/sh
        echo "$@" >> "#{argv_log}"
        echo "prompt_disabled=$GH_PROMPT_DISABLED" >> "#{argv_log}"
        pwd >> "#{cwd_log}"
        case "#{mode}" in
          ok)
            while [ $# -gt 0 ]; do
              if [ "$1" = "--worktree" ]; then mkdir -p "$2"; fi
              shift
            done
            echo "Switched to a new branch 'pr-835'" >&2
            exit 0 ;;
          missing_pr)
            echo "GraphQL: Could not resolve to a PullRequest with the number of 835. (repository.pullRequest)" >&2
            exit 1 ;;
          old_gh)
            echo "unknown flag: --worktree" >&2
            echo "Usage:  gh pr checkout [<number> | <url> | <branch>] [flags]" >&2
            exit 1 ;;
        esac
      SH
      File.chmod(0o755, path)
    end

    around do |example|
      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin_dir}:#{original_path}"
      example.run
    ensure
      ENV["PATH"] = original_path
      FileUtils.remove_entry(bin_dir)
      FileUtils.remove_entry(repo_dir)
    end

    it "runs gh pr checkout with --worktree and --branch from the repo root and creates the worktree" do
      install_fake_gh

      git.checkout_pr_worktree(worktree_path, number: "835", repo: nil, branch: "pr-835", chdir: repo_dir, quiet: true)

      expect(File.read(argv_log).lines.first.strip).to eq("pr checkout 835 --worktree #{worktree_path} --branch pr-835")
      expect(File.read(argv_log)).to include("prompt_disabled=1")
      expect(File.realpath(File.read(cwd_log).strip)).to eq(File.realpath(repo_dir))
      expect(File.directory?(worktree_path)).to be(true)
    end

    it "passes --repo when the ref names a repository" do
      install_fake_gh

      git.checkout_pr_worktree(worktree_path, number: "835", repo: "acme/api", branch: "pr-835", chdir: repo_dir, quiet: true)

      expect(File.read(argv_log).lines.first.strip).to eq("pr checkout 835 --repo acme/api --worktree #{worktree_path} --branch pr-835")
    end

    it "echoes the command it runs unless quiet" do
      install_fake_gh

      git.checkout_pr_worktree(worktree_path, number: "835", repo: nil, branch: "pr-835", chdir: repo_dir)

      expect(output.string).to include("Running: gh pr checkout 835 --worktree #{worktree_path} --branch pr-835")
    end

    it "raises with gh's message when the PR can't be found" do
      install_fake_gh(mode: "missing_pr")

      expect {
        git.checkout_pr_worktree(worktree_path, number: "835", repo: nil, branch: "pr-835", chdir: repo_dir, quiet: true)
      }.to raise_error(Workspace::Error, /Could not check out PR #835.*Could not resolve to a PullRequest/m)
    end

    it "says to upgrade gh when it doesn't know --worktree" do
      install_fake_gh(mode: "old_gh")

      expect {
        git.checkout_pr_worktree(worktree_path, number: "835", repo: nil, branch: "pr-835", chdir: repo_dir, quiet: true)
      }.to raise_error(Workspace::Error, /too old.*--worktree/m)
    end

    it "raises an install hint when gh is not on PATH" do
      ENV["PATH"] = repo_dir

      expect {
        git.checkout_pr_worktree(worktree_path, number: "835", repo: nil, branch: "pr-835", chdir: repo_dir, quiet: true)
      }.to raise_error(Workspace::Error, /`gh` is not installed/)
    end
  end

  describe "unsaved work detection" do
    def run!(*cmd, chdir:)
      _, stderr, status = Open3.capture3(*cmd, chdir: chdir)
      raise "#{cmd.join(" ")} failed: #{stderr}" unless status.success?
    end

    def make_repo_with_remote
      remote_dir = Dir.mktmpdir
      run!("git", "init", "--bare", "-b", "main", chdir: remote_dir)

      repo_dir = Dir.mktmpdir
      run!("git", "clone", remote_dir, repo_dir, chdir: Dir.pwd)
      run!("git", "config", "user.email", "test@example.com", chdir: repo_dir)
      run!("git", "config", "user.name", "Test", chdir: repo_dir)
      File.write(File.join(repo_dir, "README.md"), "hi\n")
      run!("git", "add", "README.md", chdir: repo_dir)
      run!("git", "commit", "-m", "initial", chdir: repo_dir)
      run!("git", "push", "-u", "origin", "main", chdir: repo_dir)
      [remote_dir, repo_dir]
    end

    around do |example|
      @remote_dir, @repo_dir = make_repo_with_remote
      example.run
    ensure
      FileUtils.remove_entry(@remote_dir) if @remote_dir && File.exist?(@remote_dir)
      FileUtils.remove_entry(@repo_dir) if @repo_dir && File.exist?(@repo_dir)
    end

    describe "#create_worktree" do
      def upstream_of(path)
        stdout, _ = Open3.capture3("git", "-C", path, "rev-parse", "--abbrev-ref", "@{upstream}")
        stdout.strip
      end

      def create(branch, **options)
        path = File.join(@repo_dir, ".worktrees", branch.tr("/", "-"))
        Dir.chdir(@repo_dir) { git.create_worktree(path, branch, quiet: true, **options) }
        path
      end

      before do
        run!("git", "push", "origin", "main:feature/remote-only", chdir: @repo_dir)
      end

      it "sets a branch that exists only on origin to track origin" do
        path = create("feature/remote-only")

        expect(git.worktree_branch(path)).to eq("feature/remote-only")
        expect(upstream_of(path)).to eq("origin/feature/remote-only")
      end

      it "tracks origin even when branch.autoSetupMerge is off" do
        run!("git", "config", "branch.autoSetupMerge", "false", chdir: @repo_dir)

        expect(upstream_of(create("feature/remote-only"))).to eq("origin/feature/remote-only")
      end

      it "tracks origin when another remote has a branch of the same name" do
        run!("git", "remote", "add", "fork", @remote_dir, chdir: @repo_dir)
        run!("git", "fetch", "fork", chdir: @repo_dir)

        expect(upstream_of(create("feature/remote-only"))).to eq("origin/feature/remote-only")
      end

      it "checks out an existing local branch as it is" do
        run!("git", "branch", "local-only", chdir: @repo_dir)

        path = create("local-only")

        expect(git.worktree_branch(path)).to eq("local-only")
        expect(upstream_of(path)).to eq("")
      end

      it "leaves a local branch alone when origin has one of the same name" do
        run!("git", "branch", "--no-track", "feature/remote-only", "main", chdir: @repo_dir)

        path = create("feature/remote-only")

        expect(git.worktree_branch(path)).to eq("feature/remote-only")
        expect(upstream_of(path)).to eq("")
      end

      it "creates a new branch from the base" do
        path = create("brand-new", base: "main")

        expect(git.worktree_branch(path)).to eq("brand-new")
        expect(upstream_of(path)).to eq("")
      end
    end

    describe "#changed_files_count" do
      it "returns 0 for a clean repo" do
        expect(git.changed_files_count(@repo_dir)).to eq(0)
      end

      it "counts modified tracked files, ignoring untracked ones" do
        File.write(File.join(@repo_dir, "untracked.txt"), "x")
        File.write(File.join(@repo_dir, "README.md"), "changed\n")

        expect(git.changed_files_count(@repo_dir)).to eq(1)
      end

      it "counts staged and unstaged changes to tracked files" do
        File.write(File.join(@repo_dir, "README.md"), "staged\n")
        run!("git", "add", "README.md", chdir: @repo_dir)
        File.write(File.join(@repo_dir, "README.md"), "staged then unstaged\n")

        expect(git.changed_files_count(@repo_dir)).to eq(1)
      end

      it "returns nil when git cannot answer" do
        expect(git.changed_files_count(File.join(@repo_dir, "does-not-exist"))).to be_nil
      end
    end

    describe "#unpushed_commit_count" do
      it "returns 0 when HEAD matches its remote" do
        expect(git.unpushed_commit_count(@repo_dir)).to eq(0)
      end

      it "counts commits not reachable from any remote-tracking ref" do
        run!("git", "commit", "--allow-empty", "-m", "unpushed 1", chdir: @repo_dir)
        run!("git", "commit", "--allow-empty", "-m", "unpushed 2", chdir: @repo_dir)

        expect(git.unpushed_commit_count(@repo_dir)).to eq(2)
      end

      it "falls back to other local branches when the repo has no remotes" do
        run!("git", "remote", "remove", "origin", chdir: @repo_dir)
        run!("git", "branch", "other", chdir: @repo_dir)
        run!("git", "commit", "--allow-empty", "-m", "on main only", chdir: @repo_dir)

        expect(git.unpushed_commit_count(@repo_dir)).to eq(1)
      end

      it "compares a detached HEAD with every local branch when the repo has no remotes" do
        run!("git", "remote", "remove", "origin", chdir: @repo_dir)
        run!("git", "commit", "--allow-empty", "-m", "on main", chdir: @repo_dir)
        run!("git", "checkout", "-q", "--detach", chdir: @repo_dir)
        run!("git", "commit", "--allow-empty", "-m", "detached only", chdir: @repo_dir)

        expect(git.unpushed_commit_count(@repo_dir)).to eq(1)
      end

      it "returns nil when git can't be started" do
        allow(git).to receive(:capture_git).and_call_original
        allow(git).to receive(:capture_git).with("-C", @repo_dir, "rev-list", any_args).and_raise(Errno::E2BIG)

        expect(git.unpushed_commit_count(@repo_dir)).to be_nil
      end
    end

    describe "#unsaved_work" do
      it "returns nil for a clean, fully-pushed repo" do
        expect(git.unsaved_work(@repo_dir)).to be_nil
      end

      it "returns a hash describing dirty tracked files and unpushed commits" do
        File.write(File.join(@repo_dir, "README.md"), "changed\n")
        run!("git", "commit", "--allow-empty", "-m", "unpushed", chdir: @repo_dir)

        result = git.unsaved_work(@repo_dir)
        expect(result).to eq(changed_files: 1, unpushed_commits: 1, branch: "main")
      end

      it "ignores untracked files entirely" do
        File.write(File.join(@repo_dir, "untracked.txt"), "x")

        expect(git.unsaved_work(@repo_dir)).to be_nil
      end

      it "returns nil when the worktree directory no longer exists" do
        expect(git.unsaved_work(File.join(@repo_dir, "does-not-exist"))).to be_nil
      end

      it "returns :unknown when git cannot answer for an existing directory" do
        allow(git).to receive(:capture_git).and_call_original
        allow(git).to receive(:capture_git).with("-C", @repo_dir, "status", any_args).and_return(["", "", instance_double(Process::Status, success?: false)])

        expect(git.unsaved_work(@repo_dir)).to eq(:unknown)
      end
    end

    describe "#upstream_branch" do
      it "returns the upstream ref when one is set" do
        expect(git.upstream_branch(@repo_dir)).to eq("origin/main")
      end

      it "returns nil when there is no upstream" do
        run!("git", "checkout", "-b", "no-upstream", chdir: @repo_dir)
        expect(git.upstream_branch(@repo_dir)).to be_nil
      end
    end

    describe "#commits_ahead_of_upstream" do
      it "returns 0 when HEAD matches its upstream" do
        expect(git.commits_ahead_of_upstream(@repo_dir)).to eq(0)
      end

      it "counts commits ahead of the upstream" do
        run!("git", "commit", "--allow-empty", "-m", "ahead", chdir: @repo_dir)
        expect(git.commits_ahead_of_upstream(@repo_dir)).to eq(1)
      end

      it "returns nil when there is no upstream" do
        run!("git", "checkout", "-b", "no-upstream", chdir: @repo_dir)
        expect(git.commits_ahead_of_upstream(@repo_dir)).to be_nil
      end
    end

    describe "review reads" do
      def commit_file(name, content)
        File.write(File.join(@repo_dir, name), content)
        run!("git", "add", name, chdir: @repo_dir)
        run!("git", "commit", "-m", "add #{name}", chdir: @repo_dir)
      end

      describe "#base_ref" do
        it "falls back to origin/main when origin/HEAD is not set" do
          expect(git.base_ref(@repo_dir)).to eq("origin/main")
        end

        it "prefers the remote default branch named by origin/HEAD" do
          run!("git", "branch", "trunk", chdir: @repo_dir)
          run!("git", "push", "origin", "trunk", chdir: @repo_dir)
          run!("git", "remote", "set-head", "origin", "trunk", chdir: @repo_dir)

          expect(git.base_ref(@repo_dir)).to eq("origin/trunk")
        end

        it "ignores an origin/HEAD that points at a missing branch" do
          run!("git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone", chdir: @repo_dir)

          expect(git.base_ref(@repo_dir)).to eq("origin/main")
        end

        it "is nil in a directory that is not a repository" do
          Dir.mktmpdir { |dir| expect(git.base_ref(dir)).to be_nil }
        end
      end

      describe "#commits_ahead_of, #commits_since and #diff_stat" do
        before do
          run!("git", "checkout", "-b", "feature", chdir: @repo_dir)
          commit_file("a.txt", "one\ntwo\n")
          commit_file("b.txt", "x\n")
          File.binwrite(File.join(@repo_dir, "img.bin"), "\x00\x01\x02")
          run!("git", "add", "img.bin", chdir: @repo_dir)
          run!("git", "commit", "-m", "add img.bin", chdir: @repo_dir)
        end

        it "counts the commits the base lacks" do
          expect(git.commits_ahead_of(@repo_dir, "origin/main")).to eq(3)
        end

        it "is nil for a base git can't resolve" do
          expect(git.commits_ahead_of(@repo_dir, "origin/nope")).to be_nil
          expect(git.diff_stat(@repo_dir, "origin/nope")).to be_nil
          expect(git.commits_since(@repo_dir, "origin/nope", limit: 5)).to be_nil
        end

        it "lists subjects newest first, up to the limit" do
          commits = git.commits_since(@repo_dir, "origin/main", limit: 2)

          expect(commits.map { |c| c["subject"] }).to eq(["add img.bin", "add b.txt"])
          expect(commits.first["sha"]).to match(/\A\h+\z/)
        end

        it "reports added and removed lines per file, nil counts for a binary file" do
          stat = git.diff_stat(@repo_dir, "origin/main")

          expect(stat).to contain_exactly(
            {"path" => "a.txt", "added" => 2, "removed" => 0},
            {"path" => "b.txt", "added" => 1, "removed" => 0},
            {"path" => "img.bin", "added" => nil, "removed" => nil}
          )
        end

        it "diffs from the merge base, so work that landed on the base since is not counted" do
          run!("git", "checkout", "main", chdir: @repo_dir)
          commit_file("landed.txt", "later\n")
          run!("git", "push", "origin", "main", chdir: @repo_dir)
          run!("git", "checkout", "feature", chdir: @repo_dir)

          expect(git.diff_stat(@repo_dir, "origin/main").map { |e| e["path"] }).not_to include("landed.txt")
        end

        it "scrubs bytes that aren't valid UTF-8 so the result can be encoded as JSON" do
          File.write(File.join(@repo_dir, "c.txt"), "x\n")
          run!("git", "add", "c.txt", chdir: @repo_dir)
          File.binwrite(File.join(@repo_dir, ".msg"), "bad \xFF subject\n")
          run!("git", "commit", "-F", ".msg", chdir: @repo_dir)

          expect { JSON.generate(git.commits_since(@repo_dir, "origin/main", limit: 1)) }.not_to raise_error
        end

        it "keeps a file name with spaces intact" do
          commit_file("with space.txt", "x\n")

          expect(git.diff_stat(@repo_dir, "origin/main").map { |e| e["path"] }).to include("with space.txt")
        end
      end
    end
  end

  describe "#find_worktree_by_branch" do
    it "returns the worktree path when a worktree exists for the branch" do
      porcelain = <<~OUTPUT
        worktree /Users/me/project
        HEAD abc123
        branch refs/heads/main

        worktree /Users/me/elsewhere/feature-x
        HEAD def456
        branch refs/heads/feature-x

      OUTPUT
      allow(Open3).to receive(:capture3).with("git", "-C", Dir.pwd, "worktree", "list", "--porcelain").and_return([porcelain, "", double(success?: true)])

      expect(git.find_worktree_by_branch("feature-x")).to eq("/Users/me/elsewhere/feature-x")
    end

    it "returns nil when no worktree exists for the branch" do
      porcelain = <<~OUTPUT
        worktree /Users/me/project
        HEAD abc123
        branch refs/heads/main

      OUTPUT
      allow(Open3).to receive(:capture3).with("git", "-C", Dir.pwd, "worktree", "list", "--porcelain").and_return([porcelain, "", double(success?: true)])

      expect(git.find_worktree_by_branch("feature-x")).to be_nil
    end

    it "uses the provided repo: path for -C" do
      porcelain = <<~OUTPUT
        worktree /Users/me/project
        HEAD abc123
        branch refs/heads/main

      OUTPUT
      allow(Open3).to receive(:capture3).with("git", "-C", "/Users/me/project", "worktree", "list", "--porcelain").and_return([porcelain, "", double(success?: true)])

      expect(git.find_worktree_by_branch("feature-x", repo: "/Users/me/project")).to be_nil
    end
  end

  describe "#prompt_base_branch" do
    it "returns default branch when current equals default" do
      git = described_class.new(output: output, input: input)
      allow(git).to receive(:default_branch).and_return("main")
      allow(git).to receive(:current_branch).and_return("main")
      expect(git.prompt_base_branch).to eq("main")
    end

    it "returns default branch when user chooses 1" do
      input = StringIO.new("1\n")
      git = described_class.new(output: output, input: input)
      allow(git).to receive(:default_branch).and_return("main")
      allow(git).to receive(:current_branch).and_return("feature-x")
      expect(git.prompt_base_branch).to eq("main")
    end

    it "returns current branch when user chooses 2" do
      input = StringIO.new("2\n")
      git = described_class.new(output: output, input: input)
      allow(git).to receive(:default_branch).and_return("main")
      allow(git).to receive(:current_branch).and_return("feature-x")
      expect(git.prompt_base_branch).to eq("feature-x")
    end

    it "returns nil when user chooses 3 (cancel)" do
      input = StringIO.new("3\n")
      git = described_class.new(output: output, input: input)
      allow(git).to receive(:default_branch).and_return("main")
      allow(git).to receive(:current_branch).and_return("feature-x")
      expect(git.prompt_base_branch).to be_nil
    end
  end

  describe "#remote_url" do
    it "returns the origin remote URL for a git repository" do
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "--quiet")
        system("git", "-C", dir, "remote", "add", "origin", "git@github.com:org/repo.git")
        expect(git.remote_url(dir)).to eq("git@github.com:org/repo.git")
      end
    end

    it "returns nil for a directory with no origin remote" do
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "--quiet")
        expect(git.remote_url(dir)).to be_nil
      end
    end

    it "returns nil for a non-git directory" do
      Dir.mktmpdir do |dir|
        expect(git.remote_url(dir)).to be_nil
      end
    end
  end
end

RSpec.describe Workspace::Git, "checkout layout" do
  include FakeCheckouts

  subject(:git) { described_class.new(output: StringIO.new, input: StringIO.new) }

  around do |example|
    Dir.mktmpdir { |dir| (@root = File.realpath(dir)) && example.run }
  end

  describe "#list_worktrees" do
    def sh(*cmd, chdir: @root)
      system(*cmd, chdir: chdir, out: File::NULL, err: File::NULL) || raise("#{cmd.join(" ")} failed")
    end

    it "leaves out a bare repository's own entry, keeping its linked worktrees" do
      source = File.join(@root, "source")
      FileUtils.mkdir_p(source)
      sh("git", "init", "-q", "-b", "main", chdir: source)
      sh("git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init", chdir: source)
      bare = File.join(@root, "bare.git")
      sh("git", "clone", "-q", "--bare", source, bare)

      expect(git.list_worktrees(repo: bare)).to eq([])

      sh("git", "worktree", "add", "-q", "-b", "feature", File.join(@root, "feature"), chdir: bare)

      expect(git.list_worktrees(repo: bare).map { |path| File.realpath(path) }).to eq([File.realpath(File.join(@root, "feature"))])
    end
  end

  describe "stopping a timed-out read" do
    it "terminates the git process when the thread waiting on it is killed" do
      bin = File.join(@root, "bin")
      FileUtils.mkdir_p(bin)
      pid_file = File.join(@root, "git.pid")
      File.write(File.join(bin, "git"), "#!/bin/sh\necho $$ > '#{pid_file}'\nexec sleep 30\n")
      File.chmod(0o755, File.join(bin, "git"))
      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{original_path}"
      begin
        thread = Thread.new { git.upstream_branch(@root) }
        Timeout.timeout(5) { sleep 0.02 until File.exist?(pid_file) && !File.read(pid_file).strip.empty? }
        pid = File.read(pid_file).to_i

        thread.kill
        thread.join

        expect { Timeout.timeout(5) { sleep 0.02 while process_alive?(pid) } }.not_to raise_error
      ensure
        ENV["PATH"] = original_path
        Process.kill("KILL", pid) if pid && process_alive?(pid)
      end
    end

    it "kills a git process that ignores SIGTERM" do
      bin = File.join(@root, "bin")
      FileUtils.mkdir_p(bin)
      pid_file = File.join(@root, "git.pid")
      File.write(File.join(bin, "git"), "#!/bin/sh\ntrap '' TERM\necho $$ > '#{pid_file}'\nwhile true; do sleep 1; done\n")
      File.chmod(0o755, File.join(bin, "git"))
      original_path = ENV["PATH"]
      ENV["PATH"] = "#{bin}:#{original_path}"
      begin
        thread = Thread.new { git.upstream_branch(@root) }
        Timeout.timeout(5) { sleep 0.02 until File.exist?(pid_file) && !File.read(pid_file).strip.empty? }
        sleep 0.2
        pid = File.read(pid_file).to_i

        thread.kill
        thread.join

        expect { Timeout.timeout(3) { sleep 0.02 while process_alive?(pid) } }.not_to raise_error
      ensure
        ENV["PATH"] = original_path
        Process.kill("KILL", pid) if pid && process_alive?(pid)
      end
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end

  describe "#checkout_layout" do
    it "treats a directory .git as a main checkout" do
      main = make_main_checkout(File.join(@root, "app"))

      expect(git.checkout_layout(main)).to eq(toplevel: main, common_dir: File.join(main, ".git"), linked: false)
    end

    it "walks up from a subdirectory to the checkout root" do
      main = make_main_checkout(File.join(@root, "app"))
      FileUtils.mkdir_p(File.join(main, "lib", "deep"))

      expect(git.checkout_layout(File.join(main, "lib", "deep"))).to include(toplevel: main)
    end

    it "resolves a linked worktree to the main checkout's .git via commondir" do
      main = make_main_checkout(File.join(@root, "app"))
      worktree = make_linked_worktree(main, File.join(@root, "elsewhere", "login"))

      expect(git.checkout_layout(worktree)).to eq(toplevel: worktree, common_dir: File.join(main, ".git"), linked: true)
    end

    it "resolves a relative gitdir against the .git file's directory" do
      main = make_main_checkout(File.join(@root, "app"))
      worktree = make_linked_worktree(main, File.join(main, ".worktrees", "login"), "login")
      File.write(File.join(worktree, ".git"), "gitdir: ../../.git/worktrees/login\n")

      expect(git.common_dir_from_files(worktree)).to eq(File.join(main, ".git"))
    end

    it "uses the gitdir itself as the common dir when there is no commondir (submodule)" do
      main = make_main_checkout(File.join(@root, "app"))
      sub = make_submodule(main, File.join(main, "vendor", "lib"), "lib")

      expect(git.checkout_layout(sub)).to eq(toplevel: sub, common_dir: File.join(main, ".git", "modules", "lib"), linked: false)
    end

    it "reports a worktree whose main repository is gone as a broken checkout" do
      stale = File.join(@root, "stale")
      FileUtils.mkdir_p(stale)
      File.write(File.join(stale, ".git"), "gitdir: #{File.join(@root, "deleted", ".git", "worktrees", "stale")}\n")

      expect(git.checkout_layout(stale)).to eq(toplevel: stale, common_dir: nil, linked: true, broken: true)
      expect(git.common_dir_from_files(stale)).to be_nil
    end

    it "returns nil outside any git checkout" do
      plain = File.join(@root, "notes")
      FileUtils.mkdir_p(plain)

      expect(git.checkout_layout(plain)).to be_nil
    end

    it "falls back to git when the .git file can't be parsed, and returns nil if git can't either" do
      broken = File.join(@root, "broken")
      FileUtils.mkdir_p(broken)
      File.write(File.join(broken, ".git"), "not a gitdir line\n")

      expect(git.checkout_layout(broken)).to be_nil
    end

    it "gives nil for a garbage .git file inside a real repository, without walking up to the repository" do
      repo = File.join(@root, "real")
      FileUtils.mkdir_p(File.join(repo, "sub"))
      system("git", "-C", repo, "init", "--quiet", "-b", "main")
      File.write(File.join(repo, "sub", ".git"), "garbage\n")

      expect(git.checkout_layout(File.join(repo, "sub"))).to be_nil
      expect(git.checkout_layout(repo)).to include(toplevel: repo)
    end

    it "uses git rev-parse's answer for a .git file with no gitdir line" do
      odd = File.join(@root, "odd")
      FileUtils.mkdir_p(odd)
      File.write(File.join(odd, ".git"), "garbage\n")
      common = File.join(@root, "real", ".git")
      FileUtils.mkdir_p(common)
      ok = instance_double(Process::Status, success?: true)
      allow(git).to receive(:capture_git).with("-C", odd, "rev-parse", "--show-toplevel", "--git-common-dir", "--absolute-git-dir")
        .and_return(["#{odd}\n#{common}\n#{common}\n", "", ok])

      expect(git.checkout_layout(odd)).to eq(toplevel: odd, common_dir: common, linked: false)
    end

    it "agrees with git itself on a real linked worktree" do
      main = File.join(@root, "real")
      FileUtils.mkdir_p(main)
      system("git", "-C", main, "init", "--quiet", "-b", "main")
      system("git", "-C", main, "-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init", "--quiet")
      worktree = File.join(@root, "real-wt")
      system("git", "-C", main, "worktree", "add", "--quiet", "-b", "wt", worktree)

      expected = File.realpath(File.join(main, ".git"))
      expect(File.realpath(git.common_dir_from_files(worktree))).to eq(expected)
      expect(git.checkout_layout(worktree)[:linked]).to be(true)
      expect(git.checkout_layout(main)[:linked]).to be(false)
    end
  end

  describe "#common_dir_from_files" do
    it "returns just the shared git directory" do
      main = make_main_checkout(File.join(@root, "app"))

      expect(git.common_dir_from_files(main)).to eq(File.join(main, ".git"))
    end

    it "returns nil for a non-git directory" do
      expect(git.common_dir_from_files(@root)).to be_nil
    end
  end

  describe "#tracked?" do
    it "is true for a tracked file, or a directory holding one, and false otherwise" do
      main = File.join(@root, "real")
      FileUtils.mkdir_p(File.join(main, "dir"))
      File.write(File.join(main, "dir", "a.md"), "x")
      File.write(File.join(main, "loose.md"), "x")
      system("git", "-C", main, "init", "--quiet")
      system("git", "-C", main, "add", "dir/a.md")

      expect(git.tracked?(main, "dir/a.md")).to be true
      expect(git.tracked?(main, "dir")).to be true
      expect(git.tracked?(main, "loose.md")).to be false
      expect(git.tracked?(main, "missing")).to be false
    end

    it "ignores case, as a case-insensitive volume does" do
      main = File.join(@root, "real")
      FileUtils.mkdir_p(File.join(main, "Agents"))
      File.write(File.join(main, "Agents", "Reviewer.md"), "x")
      system("git", "-C", main, "init", "--quiet")
      system("git", "-C", main, "add", "Agents/Reviewer.md")

      expect(git.tracked?(main, "agents/reviewer.md")).to be true
      expect(git.tracked?(main, "agents")).to be true
    end

    it "still reads the pathspec as one when GIT_LITERAL_PATHSPECS is set in the environment" do
      main = File.join(@root, "real")
      FileUtils.mkdir_p(File.join(main, "Agents"))
      File.write(File.join(main, "Agents", "Reviewer.md"), "x")
      File.write(File.join(main, "loose.md"), "x")
      system("git", "-C", main, "init", "--quiet")
      system("git", "-C", main, "add", "Agents/Reviewer.md")
      old = ENV["GIT_LITERAL_PATHSPECS"]
      ENV["GIT_LITERAL_PATHSPECS"] = "1"

      expect(git.tracked?(main, "Agents/Reviewer.md")).to be true
      expect(git.tracked?(main, "agents/reviewer.md")).to be true
      expect(git.tracked?(main, "loose.md")).to be false
    ensure
      ENV["GIT_LITERAL_PATHSPECS"] = old
    end

    it "raises when git can't answer, so nothing is overwritten on a guess" do
      expect { git.tracked?(@root, "a.md") }.to raise_error(Workspace::Error, /Can't tell whether git tracks a.md/)
    end
  end
end
