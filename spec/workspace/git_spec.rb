require "stringio"

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
      expect(result).to eq({type: :pr_url, value: "https://github.com/owner/repo/pull/471"})
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
        allow(Open3).to receive(:capture3).and_call_original
        allow(Open3).to receive(:capture3).with("git", "-C", @repo_dir, "rev-list", any_args).and_raise(Errno::E2BIG)

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
        allow(Open3).to receive(:capture3).and_call_original
        allow(Open3).to receive(:capture3).with("git", "-C", @repo_dir, "status", any_args).and_return(["", "", instance_double(Process::Status, success?: false)])

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

    it "returns nil for a worktree whose main repository is gone" do
      stale = File.join(@root, "stale")
      FileUtils.mkdir_p(stale)
      File.write(File.join(stale, ".git"), "gitdir: #{File.join(@root, "deleted", ".git", "worktrees", "stale")}\n")

      expect(git.checkout_layout(stale)).to be_nil
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
end
