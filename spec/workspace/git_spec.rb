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

    it "returns false when git errors (e.g. path does not exist)" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "list", "--porcelain")
        .and_return(["", "fatal: not a git repository", double(success?: false)])

      expect(git.worktree_exists?(worktree_path)).to be false
    end
  end

  describe "#remove_worktree" do
    let(:worktree_path) { "/Users/me/project/.worktrees/feature-x" }

    it "runs git worktree remove with -C set to the worktree path" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", worktree_path)
        .and_return(["", "", double(success?: true)])

      expect { git.remove_worktree(worktree_path) }.not_to raise_error
    end

    it "passes --force when force: true" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", "--force", worktree_path)
        .and_return(["", "", double(success?: true)])

      expect { git.remove_worktree(worktree_path, force: true) }.not_to raise_error
    end

    it "raises Workspace::Error when git fails" do
      allow(Open3).to receive(:capture3)
        .with("git", "-C", worktree_path, "worktree", "remove", worktree_path)
        .and_return(["", "fatal: not a worktree", double(success?: false)])

      expect { git.remove_worktree(worktree_path) }
        .to raise_error(Workspace::Error, /fatal: not a worktree/)
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
end
