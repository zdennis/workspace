require "tmpdir"

RSpec.describe Workspace::Commands::Start do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:launch_command) { double("launch_command") }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      launch_command: launch_command,
      output: output,
      input: input
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe "#call" do
    it "raises Workspace::Error when not in a git repo" do
      allow(git).to receive(:root).and_return(nil)

      expect { command.call("PROJ-123") }.to raise_error(
        Workspace::Error, /Not inside a git repository/
      )
    end

    context "with a PR URL" do
      it "resolves branch via git and launches" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("https://github.com/org/repo/pull/123").and_return({type: :pr_url, value: "https://github.com/org/repo/pull/123"})
        allow(git).to receive(:resolve_branch_from_pr).and_return("feature/PROJ-123")
        allow(git).to receive(:sanitize_for_filesystem).with("feature/PROJ-123").and_return("feature-PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:branch_exists?).with("feature/PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature-PROJ-123")
        allow(launch_command).to receive(:call)

        # Create .worktrees parent
        command.call("https://github.com/org/repo/pull/123")

        expect(git).to have_received(:resolve_branch_from_pr)
        expect(launch_command).to have_received(:call).with(["myproject.worktree-feature-PROJ-123"], prompts: {})
        expect(output.string).to include("Fetching PR details")
        expect(output.string).to include("PR branch: feature/PROJ-123")
      end
    end

    context "with a JIRA key" do
      it "uses it as branch name" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)

        command.call("PROJ-123")

        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {})
      end
    end

    context "with a GitHub issue URL" do
      it "uses issue number as branch name" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("https://github.com/org/repo/issues/42").and_return({type: :issue_url, value: "issue-42"})
        allow(git).to receive(:sanitize_for_filesystem).with("issue-42").and_return("issue-42")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:branch_exists?).with("issue-42").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-issue-42")
        allow(launch_command).to receive(:call)

        command.call("https://github.com/org/repo/issues/42")

        expect(launch_command).to have_received(:call).with(["myproject.worktree-issue-42"], prompts: {})
      end
    end

    context "with a prompt" do
      it "passes prompt through to launch command" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)

        command.call("PROJ-123", prompt: "Fix the bug")

        expect(launch_command).to have_received(:call).with(
          ["myproject.worktree-PROJ-123"],
          prompts: {"myproject.worktree-PROJ-123" => "Fix the bug"}
        )
      end
    end

    context "with an existing worktree" do
      it "skips creation and launches directly" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)

        command.call("PROJ-123")

        expect(git).not_to have_received(:create_worktree)
        expect(output.string).to include("Worktree already exists")
        expect(launch_command).to have_received(:call)
      end
    end
  end
end
