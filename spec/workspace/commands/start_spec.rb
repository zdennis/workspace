require "tmpdir"

RSpec.describe Workspace::Commands::Start do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) { double("project_config") }
  let(:project_settings) { CLITestHelpers::FakeProjectSettings.new }
  let(:launch_command) { double("launch_command") }

  subject(:command) do
    described_class.new(
      git: git,
      project_config: project_config,
      project_settings: project_settings,
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
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
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
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
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
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
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
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
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

      it "writes .workspace-project marker in existing worktree" do
        worktree_path = File.join(tmpdir, ".worktrees", "PROJ-123")
        FileUtils.mkdir_p(worktree_path)

        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(true)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)

        command.call("PROJ-123")

        marker = File.join(worktree_path, ".workspace-project")
        expect(File.exist?(marker)).to be true
        expect(File.read(marker)).to eq("myproject.worktree-PROJ-123")
      end
    end

    context "with a worktree at a non-standard location" do
      it "adopts the existing worktree and launches" do
        external_path = File.join(tmpdir, "elsewhere", "feature-branch")
        FileUtils.mkdir_p(external_path)

        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("feature-branch").and_return({type: :branch, value: "feature-branch"})
        allow(git).to receive(:sanitize_for_filesystem).with("feature-branch").and_return("feature-branch")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:branch_exists?).with("feature-branch").and_return(true)
        allow(git).to receive(:find_worktree_by_branch).with("feature-branch", repo: tmpdir).and_return(external_path)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature-branch")
        allow(launch_command).to receive(:call)

        command.call("feature-branch")

        expect(git).not_to have_received(:create_worktree) if git.respond_to?(:create_worktree)
        expect(output.string).to include("Adopting existing worktree at: #{external_path}")
        expect(project_config).to have_received(:create_worktree).with(
          anything, "feature-branch", external_path, "feature-branch"
        )
        expect(launch_command).to have_received(:call).with(["myproject.worktree-feature-branch"], prompts: {})

        marker = File.join(external_path, ".workspace-project")
        expect(File.exist?(marker)).to be true
        expect(File.read(marker)).to eq("myproject.worktree-feature-branch")
      end
    end

    context "with a new worktree" do
      it "writes .workspace-project marker after creation" do
        worktree_path = File.join(tmpdir, ".worktrees", "PROJ-456")

        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-456").and_return({type: :jira_key, value: "PROJ-456"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-456").and_return("PROJ-456")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-456").and_return(true)
        allow(git).to receive(:create_worktree) { FileUtils.mkdir_p(worktree_path) }
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-456")
        allow(launch_command).to receive(:call)

        command.call("PROJ-456")

        marker = File.join(worktree_path, ".workspace-project")
        expect(File.exist?(marker)).to be true
        expect(File.read(marker)).to eq("myproject.worktree-PROJ-456")
      end
    end

    context "worktree hooks" do
      let(:settings_dir) { File.join(tmpdir, "config") }
      let(:config) { Workspace::Config.new(workspace_dir: tmpdir) }
      let(:project_settings) do
        ps = Workspace::ProjectSettings.new(config: config)
        allow(config).to receive(:workspace_config_dir).and_return(settings_dir)
        ps
      end

      before do
        FileUtils.mkdir_p(File.join(settings_dir, "projects"))
      end

      it "seeds worktree hooks from parent project's worktree_hooks" do
        parent_name = Workspace::ProjectConfig.name_from_path(tmpdir)
        project_settings.save(parent_name, {
          "hooks" => {"post_launch" => "echo parent"},
          "worktree_hooks" => {"post_launch" => "echo worktree launched", "post_focus" => "echo focused"}
        })

        worktree_config = "#{parent_name}.worktree-PROJ-789"
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-789").and_return({type: :jira_key, value: "PROJ-789"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-789").and_return("PROJ-789")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-789").and_return(true)
        allow(git).to receive(:create_worktree) { FileUtils.mkdir_p(File.join(tmpdir, ".worktrees", "PROJ-789")) }
        allow(project_config).to receive(:create_worktree).and_return(worktree_config)
        allow(launch_command).to receive(:call)

        command.call("PROJ-789")

        worktree_data = project_settings.load(worktree_config)
        expect(worktree_data["hooks"]).to eq({
          "post_launch" => "echo worktree launched",
          "post_focus" => "echo focused"
        })
      end

      it "does not overwrite existing worktree hooks" do
        parent_name = Workspace::ProjectConfig.name_from_path(tmpdir)
        worktree_config = "#{parent_name}.worktree-PROJ-789"
        project_settings.save(parent_name, {
          "worktree_hooks" => {"post_launch" => "echo from parent"}
        })
        project_settings.save(worktree_config, {
          "hooks" => {"post_launch" => "echo custom"}
        })

        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-789").and_return({type: :jira_key, value: "PROJ-789"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-789").and_return("PROJ-789")
        allow(git).to receive(:worktree_exists?).and_return(true)
        allow(project_config).to receive(:create_worktree).and_return(worktree_config)
        allow(launch_command).to receive(:call)

        command.call("PROJ-789")

        worktree_data = project_settings.load(worktree_config)
        expect(worktree_data["hooks"]["post_launch"]).to eq("echo custom")
      end

      it "does nothing when parent has no worktree_hooks" do
        parent_name = Workspace::ProjectConfig.name_from_path(tmpdir)
        worktree_config = "#{parent_name}.worktree-PROJ-789"
        project_settings.save(parent_name, {"hooks" => {"post_launch" => "echo parent"}})

        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-789").and_return({type: :jira_key, value: "PROJ-789"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-789").and_return("PROJ-789")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-789").and_return(true)
        allow(git).to receive(:create_worktree) { FileUtils.mkdir_p(File.join(tmpdir, ".worktrees", "PROJ-789")) }
        allow(project_config).to receive(:create_worktree).and_return(worktree_config)
        allow(launch_command).to receive(:call)

        command.call("PROJ-789")

        worktree_data = project_settings.load(worktree_config)
        expect(worktree_data).to eq({"hooks" => {}, "layouts" => {}})
      end
    end
  end
end
