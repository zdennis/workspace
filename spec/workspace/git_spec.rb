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
      expect(result).to eq({type: :issue_url, value: "issue-42", repo: "owner/repo", number: "42"})
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

    it "records owner/repo#N in the branch config when the ref names a repository, and nothing without one" do
      install_fake_gh
      system("git", "init", "-q", repo_dir, exception: true)

      git.checkout_pr_worktree(worktree_path, number: "835", repo: "acme/api", branch: "pr-835", chdir: repo_dir, quiet: true)
      expect(git.branch_tracking(repo_dir, "pr-835")["pr"]).to eq("acme/api#835")

      git.checkout_pr_worktree(worktree_path, number: "836", repo: nil, branch: "pr-836", chdir: repo_dir, quiet: true)
      expect(git.branch_tracking(repo_dir, "pr-836")["pr"]).to be_nil
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

    describe "#drop_unresolved_upstream" do
      def config_get(key)
        stdout, _ = Open3.capture3("git", "-C", @repo_dir, "config", "--get", key)
        stdout.strip
      end

      def set_config(key, value)
        run!("git", "config", key, value, chdir: @repo_dir)
      end

      def expect_cleared
        %w[remote merge pushRemote].each { |key| expect(config_get("branch.fix-bug.#{key}")).to eq("") }
      end

      before do
        run!("git", "checkout", "-b", "fix-bug", chdir: @repo_dir)
      end

      it "keeps an upstream that resolves" do
        run!("git", "push", "-u", "origin", "fix-bug", chdir: @repo_dir)

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(false)
        expect(config_get("branch.fix-bug.merge")).to eq("refs/heads/fix-bug")
      end

      it "keeps a resolving upstream when HEAD is on another branch" do
        run!("git", "push", "-u", "origin", "fix-bug", chdir: @repo_dir)
        run!("git", "checkout", "--detach", chdir: @repo_dir)

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(false)
        expect(config_get("branch.fix-bug.merge")).to eq("refs/heads/fix-bug")
      end

      it "removes a URL remote upstream with a URL pushRemote" do
        set_config("branch.fix-bug.remote", "https://github.com/fork/repo.git")
        set_config("branch.fix-bug.merge", "refs/heads/fix-bug")
        set_config("branch.fix-bug.pushRemote", "https://github.com/fork/repo.git")

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(true)
        expect_cleared
      end

      it "removes an origin refs/pull/N/head upstream with an origin pushRemote" do
        set_config("branch.fix-bug.remote", "origin")
        set_config("branch.fix-bug.merge", "refs/pull/12/head")
        set_config("branch.fix-bug.pushRemote", "origin")

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(true)
        expect_cleared
      end

      it "does nothing when the branch has no upstream configured" do
        set_config("branch.fix-bug.pushRemote", "origin")

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(false)
        expect(config_get("branch.fix-bug.pushRemote")).to eq("origin")
      end

      it "removes an unresolved upstream that has no pushRemote" do
        set_config("branch.fix-bug.remote", "origin")
        set_config("branch.fix-bug.merge", "refs/pull/12/head")

        expect(git.drop_unresolved_upstream(@repo_dir, "fix-bug")).to be(true)
        expect_cleared
      end
    end

    describe "#branch_tracking and #remote_config_url" do
      it "reads a branch's remote and merge each on its own, nil when unset" do
        run!("git", "config", "branch.fix-bug.merge", "refs/pull/7/head", chdir: @repo_dir)

        expect(git.branch_tracking(@repo_dir, "fix-bug")).to eq("remote" => nil, "merge" => "refs/pull/7/head", "pr" => nil)
        expect(git.branch_tracking(@repo_dir, "none")).to eq("remote" => nil, "merge" => nil, "pr" => nil)
      end

      it "reads a remote's URL as configured, nil for a remote with none" do
        run!("git", "config", "remote.upstream.url", "git@github.com:o/r.git", chdir: @repo_dir)

        expect(git.remote_config_url(@repo_dir, "upstream")).to eq("git@github.com:o/r.git")
        expect(git.remote_config_url(@repo_dir, "gone")).to be_nil
      end
    end

    describe "#remote_effective_url" do
      it "applies url.<base>.insteadOf to the remote's URL" do
        run!("git", "config", "remote.origin.url", "gh:o/r", chdir: @repo_dir)
        run!("git", "config", "url.https://github.com/.insteadOf", "gh:", chdir: @repo_dir)

        expect(git.remote_effective_url(@repo_dir, "origin")).to eq("https://github.com/o/r")
      end

      it "returns the URL unchanged when no insteadOf rule applies" do
        run!("git", "config", "remote.origin.url", "git@github.com:o/r.git", chdir: @repo_dir)
        run!("git", "config", "url.https://example.com/.insteadOf", "zz:", chdir: @repo_dir)

        expect(git.remote_effective_url(@repo_dir, "origin")).to eq("git@github.com:o/r.git")
      end

      it "is nil for a remote with no URL" do
        expect(git.remote_effective_url(@repo_dir, "gone")).to be_nil
      end
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

      it "marks a new branch as created by workspace" do
        create("brand-new", base: "main")

        expect(git.workspace_created_branch?(@repo_dir, "brand-new")).to be(true)
      end

      it "does not mark an existing local branch" do
        run!("git", "branch", "local-only", chdir: @repo_dir)
        create("local-only")

        expect(git.workspace_created_branch?(@repo_dir, "local-only")).to be(false)
      end

      it "does not mark a branch made from origin" do
        create("feature/remote-only")

        expect(git.workspace_created_branch?(@repo_dir, "feature/remote-only")).to be(false)
      end

      it "still creates the worktree when the marker cannot be set" do
        failed = instance_double(Process::Status, success?: false)
        allow(git).to receive(:capture_git).and_call_original
        allow(git).to receive(:capture_git).with("-C", anything, "config", "branch.brand-new.workspace-created", "true").and_return(["", "boom", failed])

        path = create("brand-new", base: "main")

        expect(git.worktree_branch(path)).to eq("brand-new")
        expect(git.workspace_created_branch?(@repo_dir, "brand-new")).to be(false)
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

    describe "#remote_ref_exists?" do
      it "is true for a branch the remote has" do
        expect(git.remote_ref_exists?(@repo_dir, "origin", "refs/heads/main")).to be(true)
      end

      it "is false for a branch the remote does not have" do
        expect(git.remote_ref_exists?(@repo_dir, "origin", "refs/heads/gone")).to be(false)
      end

      it "is nil when the remote cannot be asked" do
        expect(git.remote_ref_exists?(@repo_dir, "nowhere", "refs/heads/main")).to be_nil
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

      describe "#branch_vs_base and #merged_into_base?" do
        before do
          run!("git", "checkout", "-b", "feature", chdir: @repo_dir)
          commit_file("a.txt", "one\n")
        end

        it "counts against origin/main when an origin exists" do
          expect(git.branch_vs_base(@repo_dir, "feature")).to eq("base" => "origin/main", "ahead" => 1, "merged" => false)
          expect(git.merged_into_base?(@repo_dir, "feature")).to be(false)
          expect(git.merged_into_base?(@repo_dir, "main")).to be(true)
        end

        it "is merged-false with no base when an origin exists but its default branch was never fetched" do
          run!("git", "update-ref", "-d", "refs/remotes/origin/main", chdir: @repo_dir)

          expect(git.branch_vs_base(@repo_dir, "feature")).to eq("base" => nil, "ahead" => nil, "merged" => false)
        end

        it "lets origin/HEAD win over origin/main" do
          run!("git", "branch", "trunk", "feature", chdir: @repo_dir)
          run!("git", "push", "origin", "trunk", chdir: @repo_dir)
          run!("git", "remote", "set-head", "origin", "trunk", chdir: @repo_dir)

          expect(git.branch_vs_base(@repo_dir, "feature")).to eq("base" => "origin/trunk", "ahead" => 0, "merged" => true)
        end

        it "falls back to origin/master" do
          run!("git", "update-ref", "refs/remotes/origin/master", "refs/remotes/origin/main", chdir: @repo_dir)
          run!("git", "update-ref", "-d", "refs/remotes/origin/main", chdir: @repo_dir)

          expect(git.branch_vs_base(@repo_dir, "feature")).to include("base" => "origin/master", "ahead" => 1)
        end

        it "uses the local master with no remote" do
          run!("git", "remote", "remove", "origin", chdir: @repo_dir)
          run!("git", "branch", "-m", "main", "master", chdir: @repo_dir)

          expect(git.branch_vs_base(@repo_dir, "feature")).to eq("base" => "master", "ahead" => 1, "merged" => false)
        end

        it "is nil with no remote and no default branch, and for a missing branch" do
          run!("git", "remote", "remove", "origin", chdir: @repo_dir)
          run!("git", "branch", "-m", "main", "trunk", chdir: @repo_dir)

          expect(git.branch_vs_base(@repo_dir, "feature")).to be_nil
          expect(git.branch_vs_base(@repo_dir, "nope")).to be_nil
          expect(git.merged_into_base?(@repo_dir, "nope")).to be_nil
        end

        it "is nil when rev-list fails" do
          allow(git).to receive(:capture_git).and_call_original
          allow(git).to receive(:capture_git).with("-C", @repo_dir, "rev-list", "--count", anything).and_return(["", "boom", instance_double(Process::Status, success?: false)])

          expect(git.branch_vs_base(@repo_dir, "feature")).to be_nil
        end
      end

      describe "#commits_unpushed" do
        it "is nil for a branch with no upstream" do
          run!("git", "checkout", "-b", "local-only", chdir: @repo_dir)

          expect(git.commits_unpushed(@repo_dir, "local-only")).to be_nil
        end

        it "is nil for a branch that does not exist" do
          expect(git.commits_unpushed(@repo_dir, "nope")).to be_nil
        end

        it "counts the named branch's commits its upstream lacks, whatever HEAD is" do
          run!("git", "commit", "--allow-empty", "-m", "ahead", chdir: @repo_dir)
          run!("git", "checkout", "-b", "other", chdir: @repo_dir)

          expect(git.commits_unpushed(@repo_dir, "main")).to eq(1)
          expect(git.commits_unpushed(@repo_dir, "other")).to be_nil
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

        it "returns the unified patch of the diffstat's range, binary files as git shows them" do
          patch = git.diff_patch(@repo_dir, "origin/main", max_bytes: 100_000)

          expect(patch).to include("truncated" => false, "bytes" => patch["text"].bytesize)
          expect(patch["text"]).to include("diff --git a/a.txt b/a.txt", "+two", "Binary files /dev/null and b/img.bin differ")
          expect(patch["text"]).not_to include("\e[")
        end

        it "cuts at a line end inside the cap and flags it" do
          full = git.diff_patch(@repo_dir, "origin/main", max_bytes: 100_000)
          cut = git.diff_patch(@repo_dir, "origin/main", max_bytes: 120)

          expect(cut).to include("truncated" => true, "bytes" => full["bytes"])
          expect(cut["text"]).to end_with("\n")
          expect(full["text"]).to start_with(cut["text"])
          expect(cut["text"].bytesize).to be <= 120
        end

        it "cuts on a character boundary when the cap holds no line end" do
          wide = described_class.new(runner: ->(*, **) { ["é" * 10, "", true] }).diff_patch(@repo_dir, "x", max_bytes: 5)

          expect(wide).to include("text" => "éé", "truncated" => true)
        end

        it "drops a 4-byte character cut at the cap and reports a patch that fits exactly as whole" do
          runner = ->(*, **) { ["😀😀", "", true] }
          cut = described_class.new(runner: runner).diff_patch(@repo_dir, "x", max_bytes: 7)
          exact = described_class.new(runner: runner).diff_patch(@repo_dir, "x", max_bytes: 8)

          expect(cut).to include("text" => "😀", "truncated" => true, "bytes" => 8)
          expect(exact).to include("text" => "😀😀", "truncated" => false)
        end

        it "scrubs invalid bytes and is nil for an unknown base or a git that fails or times out" do
          bad = described_class.new(runner: ->(*, **) { ["a\xFFb\n", "", true] }).diff_patch(@repo_dir, "x", max_bytes: 100)
          expect(bad["text"]).to eq("a�b\n")
          expect(git.diff_patch(@repo_dir, "origin/nope", max_bytes: 100)).to be_nil
          expect(described_class.new(runner: ->(*, **) { raise Timeout::Error }).diff_patch(@repo_dir, "x", max_bytes: 100)).to be_nil
        end

        it "keeps a file name with spaces intact" do
          commit_file("with space.txt", "x\n")

          expect(git.diff_stat(@repo_dir, "origin/main").map { |e| e["path"] }).to include("with space.txt")
        end
      end
    end
  end

  describe "#worktree_branches" do
    it "lists the branch of every worktree, the main one included, and none for a detached one" do
      Dir.mktmpdir("wt-branches") do |dir|
        repo = File.realpath(dir)
        run = ->(*args) { Open3.capture2e("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", *args) }
        run.call("init", "-q", "-b", "main")
        run.call("commit", "-q", "--allow-empty", "-m", "init")
        run.call("worktree", "add", "-q", "-b", "PROJ-1-x", File.join(repo, "a"))
        run.call("worktree", "add", "-q", "--detach", File.join(repo, "b"))

        expect(git.worktree_branches(repo: repo)).to contain_exactly("main", "PROJ-1-x")
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

  describe "#push_urls" do
    it "lists every push URL of origin" do
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "--quiet")
        system("git", "-C", dir, "remote", "add", "origin", "git@github.com:org/repo.git")
        system("git", "-C", dir, "config", "--add", "remote.origin.pushurl", "git@github.com:org/repo.git")
        system("git", "-C", dir, "config", "--add", "remote.origin.pushurl", "https://example.com/other/repo.git")

        expect(git.push_urls(dir)).to eq(["git@github.com:org/repo.git", "https://example.com/other/repo.git"])
      end
    end

    it "falls back to the fetch URL with no push URL set" do
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "--quiet")
        system("git", "-C", dir, "remote", "add", "origin", "git@github.com:org/repo.git")

        expect(git.push_urls(dir)).to eq(["git@github.com:org/repo.git"])
      end
    end

    it "returns nil with no origin remote" do
      Dir.mktmpdir do |dir|
        system("git", "-C", dir, "init", "--quiet")

        expect(git.push_urls(dir)).to be_nil
      end
    end
  end

  describe "#push" do
    def argv_for(*args, **opts)
      calls = []
      runner = ->(argv, chdir:, timeout:, env: {}) {
        calls << argv
        ["", "", true]
      }
      described_class.new(output: output, input: input, runner: runner).push("/w", *args, **opts)
      calls.first
    end

    it "pushes the branch to its own name, naming both refs in full" do
      expect(argv_for("feature/x")).to eq(%w[git push origin refs/heads/feature/x:refs/heads/feature/x])
    end

    it "pushes to another branch on origin with a full refspec" do
      expect(argv_for("pr-12", dest: "fix/thing")).to eq(%w[git push origin refs/heads/pr-12:refs/heads/fix/thing])
    end

    it "never lets a branch named +x become a forced refspec" do
      expect(argv_for("+x", set_upstream: true)).to eq(%w[git push -u origin refs/heads/+x:refs/heads/+x])
    end

    it "names the destination ref and the commit in the lease" do
      sha = "a" * 40

      expect(argv_for("pr-12", dest: "fix/thing", lease: sha)).to eq(["git", "push", "--force-with-lease=refs/heads/fix/thing:#{sha}", "origin", "refs/heads/pr-12:refs/heads/fix/thing"])
      expect(argv_for("feature/x", lease: sha)).to eq(["git", "push", "--force-with-lease=refs/heads/feature/x:#{sha}", "origin", "refs/heads/feature/x:refs/heads/feature/x"])
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

RSpec.describe Workspace::Git, "write operations on a checkout" do
  include RebaseRepos

  let(:git) { described_class.new(output: StringIO.new, input: StringIO.new) }

  it "names the default branch from origin/HEAD, else from main or master" do
    expect(git.default_branch_name(repo)).to eq("main")

    sh("remote", "set-head", "origin", "main")
    expect(git.default_branch_name(repo)).to eq("main")

    sh("update-ref", "-d", "refs/remotes/origin/HEAD")
    sh("branch", "-m", "main", "master")
    sh("update-ref", "-d", "refs/remotes/origin/main")
    expect(git.default_branch_name(repo)).to eq("master")
  end

  it "reports commits only upstream has and commits only HEAD has" do
    expect(git.behind_ahead(wt, "main")).to eq([0, 1])
    expect(git.behind_ahead(wt, "no-such-ref")).to be_nil
  end

  it "lists only changes to tracked files as dirty" do
    File.write(File.join(repo, "untracked.txt"), "x\n")
    expect(git.dirty_tracked_files(repo)).to eq([])

    File.write(File.join(repo, "base.txt"), "changed\n")
    expect(git.dirty_tracked_files(repo)).to eq(["base.txt"])
    expect(git.dirty_tracked_files(File.join(@dir, "missing"))).to be_nil

    sh("checkout", "-q", "--", "base.txt")
    sh("mv", "base.txt", "moved.txt")
    expect(git.dirty_tracked_files(repo)).to contain_exactly("base.txt", "moved.txt")
  end

  it "judges replaced upstream commits false for a branch with no reflog, and lists no conflicts in a clean checkout" do
    expect(git.upstream_commits_replaced?(repo, "no-such-branch", "origin/main")).to be(false)
    expect(git.conflicted_files(repo)).to eq([])
  end

  it "turns a missing git and a timeout into errors for each timed call" do
    missing = described_class.new(runner: ->(argv, chdir:, timeout:, env: {}) { raise Errno::ENOENT })
    slow = described_class.new(runner: ->(argv, chdir:, timeout:, env: {}) { raise Timeout::Error })

    expect { missing.fetch(repo) }.to raise_error(Workspace::Error, "git is not installed.")
    expect { slow.fetch(repo) }.to raise_error(Workspace::Error, "git fetch did not finish within #{described_class::FETCH_TIMEOUT} seconds.")
    expect { slow.rebase(repo, "main") }.to raise_error(Workspace::Error, /git rebase did not finish within/)
    expect { slow.push(repo, "main") }.to raise_error(Workspace::Error, /git push of .main. did not finish within #{described_class::PUSH_TIMEOUT} seconds/o) { |e| expect(e.code).to eq("push_timeout") }
  end

  describe "branch deletion and the created marker" do
    def with_runner(result = ["", "", true], &block)
      calls = []
      runner = block || ->(argv, chdir:, timeout:, env: {}) { calls << [argv, chdir, timeout, env] && result }
      [described_class.new(runner: runner), calls]
    end

    it "reads the marker as true only when the value is true" do
      yes, calls = with_runner(["true\n", "", true])
      no, = with_runner(["false\n", "", true])
      unset, = with_runner(["", "", false])

      expect(yes.workspace_created_branch?(repo, "feature/x")).to be(true)
      expect(calls.first[0]).to eq(%w[git config --get branch.feature/x.workspace-created])
      expect(no.workspace_created_branch?(repo, "feature/x")).to be(false)
      expect(unset.workspace_created_branch?(repo, "feature/x")).to be(false)
    end

    it "deletes a branch with -d, or -D when forced" do
      safe, safe_calls = with_runner
      forced, forced_calls = with_runner(["", "not fully merged", false])

      expect(safe.delete_branch(repo, "x", force: false)).to eq([true, ""])
      expect(safe_calls.first[0]).to eq(%w[git branch -d x])
      expect(forced.delete_branch(repo, "x", force: true)).to eq([false, "not fully merged"])
      expect(forced_calls.first[0]).to eq(%w[git branch -D x])
    end

    it "runs the delete in English so its refusal can be recognised" do
      git, calls = with_runner
      git.delete_branch(repo, "x")

      expect(calls.first[3]).to eq(described_class::ENGLISH)
    end

    it "deletes a remote branch" do
      git, calls = with_runner
      expect(git.delete_remote_branch(repo, "origin", "x")).to eq([:deleted, ""])
      expect(calls).to eq([[%w[git push origin --delete x], repo, described_class::PUSH_TIMEOUT, described_class::ENGLISH]])
    end

    it "tells a missing remote branch from other failures" do
      gone, = with_runner(["", "error: unable to delete 'x': remote ref does not exist\n", false])
      broken, = with_runner(["", "fatal: Authentication failed\n", false])

      expect(gone.delete_remote_branch(repo, "origin", "x")).to eq([:not_found, "error: unable to delete 'x': remote ref does not exist\n"])
      expect(broken.delete_remote_branch(repo, "origin", "x")).to eq([:error, "fatal: Authentication failed\n"])
    end

    it "reports a remote delete that runs too long, and raises when git is missing" do
      slow, = with_runner { |*, **| raise Timeout::Error }
      missing, = with_runner { |*, **| raise Errno::ENOENT }

      status, message = slow.delete_remote_branch(repo, "origin", "x")
      expect(status).to eq(:timeout)
      expect(message).to match(/did not finish within #{described_class::PUSH_TIMEOUT} seconds/o)
      expect { missing.delete_remote_branch(repo, "origin", "x") }.to raise_error(Workspace::Error, "git is not installed.")
    end
  end

  it "runs git through the injected runner with the checkout as its directory" do
    calls = []
    git = described_class.new(runner: ->(argv, chdir:, timeout:, env: {}) { calls << [argv, chdir, timeout] && ["", "", true] })

    expect(git.push(wt, "feature/x", set_upstream: true, lease: "b" * 40)).to eq([true, ""])
    expect(calls).to eq([[["git", "push", "-u", "--force-with-lease=refs/heads/feature/x:#{"b" * 40}", "origin", "refs/heads/feature/x:refs/heads/feature/x"], wt, described_class::PUSH_TIMEOUT]])
  end
end

RSpec.describe Workspace::Git, "stash by tag" do
  subject(:git) { described_class.new(output: StringIO.new, input: StringIO.new) }

  around do |example|
    Dir.mktmpdir { |dir| (@repo = File.realpath(dir)) && example.run }
  end

  def sh(*args)
    out = IO.popen(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", @repo, *args], err: [:child, :out], &:read)
    raise "git #{args.join(" ")} failed: #{out}" unless $?.success?
    out
  end

  before do
    sh("init", "-q", "-b", "main")
    File.write(File.join(@repo, "a.txt"), "base\n")
    sh("add", ".")
    sh("commit", "-q", "-m", "init")
  end

  def dirty!(content = "mine\n")
    File.write(File.join(@repo, "a.txt"), content)
  end

  it "pushes under the tag and returns the entry's sha and tag" do
    dirty!
    stash, ok, = git.stash_push(@repo, "workspace-rebase-abc workspace rebase: main")

    expect(ok).to be(true)
    expect(stash.tag).to eq("workspace-rebase-abc workspace rebase: main")
    expect(sh("stash", "list", "--format=%H %gs").lines.map(&:strip)).to eq(["#{stash.sha} On main: workspace-rebase-abc workspace rebase: main"])
    expect(File.read(File.join(@repo, "a.txt"))).to eq("base\n")
  end

  it "returns no entry and leaves the stack alone when there is nothing to stash" do
    expect(git.stash_push(@repo, "x").first(2)).to eq([nil, true])
    expect(sh("stash", "list")).to eq("")
  end

  it "applies by sha even when another entry was pushed on top, then drops only its own entry" do
    dirty!
    stash, = git.stash_push(@repo, "x")
    File.write(File.join(@repo, "a.txt"), "other session\n")
    sh("stash", "push", "-m", "someone else")

    expect(git.stash_apply(@repo, stash.sha)).to eq([true, ""])
    expect(File.read(File.join(@repo, "a.txt"))).to eq("mine\n")
    expect(git.stash_drop(@repo, stash)).to be(true)

    expect(sh("stash", "list")).to match(/\Astash@\{0\}: On main: someone else\n\z/)
  end

  it "drops nothing else when its entry is no longer in the stack" do
    dirty!
    stash, = git.stash_push(@repo, "x")
    sh("stash", "drop", "--quiet")
    File.write(File.join(@repo, "a.txt"), "other\n")
    sh("stash", "push", "-m", "someone else")

    expect(git.stash_drop(@repo, stash)).to be(true)
    expect(sh("stash", "list")).to match(/\Astash@\{0\}: On main: someone else\n\z/)
  end

  it "leaves an entry with the same tag but another commit alone" do
    dirty!
    stash, = git.stash_push(@repo, "x")
    sh("stash", "drop", "--quiet")
    dirty!("another session\n")
    sh("stash", "push", "-m", "x")

    expect(git.stash_drop(@repo, stash)).to be(true)
    expect(sh("stash", "list").lines.size).to eq(1)
  end

  it "reports a conflicting apply with git's message and keeps the entry" do
    dirty!
    stash, = git.stash_push(@repo, "x")
    File.write(File.join(@repo, "a.txt"), "changed meanwhile\n")

    applied, stderr = git.stash_apply(@repo, stash.sha)

    expect(applied).to be(false)
    expect(stderr).not_to be_empty
    expect(sh("stash", "list", "--format=%H")).to include(stash.sha)
  end
end

RSpec.describe Workspace::Git, "deleting a branch start made" do
  subject(:git) { described_class.new(output: StringIO.new, input: StringIO.new) }

  around do |example|
    Dir.mktmpdir { |dir| (@repo = File.realpath(dir)) && example.run }
  end

  def sh(*args)
    out = IO.popen(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-C", @repo, *args], err: [:child, :out], &:read)
    raise "git #{args.join(" ")} failed: #{out}" unless $?.success?
    out
  end

  before do
    sh("init", "-q", "-b", "main")
    File.write(File.join(@repo, "a.txt"), "base\n")
    sh("add", ".")
    sh("commit", "-q", "-m", "init")
    sh("switch", "-q", "-c", "PROJ-123")
    sh("config", "branch.PROJ-123.workspace-created", "true")
    File.write(File.join(@repo, "b.txt"), "work\n")
    sh("add", ".")
    sh("commit", "-q", "-m", "work")
    sh("switch", "-q", "main")
    sh("merge", "-q", "--no-ff", "-m", "merge", "PROJ-123")
  end

  it "deletes a merged branch with -d from the git directory, as kill does, and its marker goes with it" do
    expect(git.workspace_created_branch?(@repo, "PROJ-123")).to be(true)

    expect(git.delete_branch(File.join(@repo, ".git"), "PROJ-123")).to eq([true, ""])

    expect(sh("branch", "--list", "PROJ-123")).to eq("")
    expect(git.workspace_created_branch?(@repo, "PROJ-123")).to be(false)
    expect(IO.popen(["git", "-C", @repo, "config", "--get-regexp", "^branch\\.PROJ-123\\."], err: File::NULL, &:read)).to eq("")
  end
end
