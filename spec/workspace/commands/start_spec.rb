require "tmpdir"

RSpec.describe Workspace::Commands::Start do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
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
      error_output: error_output,
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

    context "agent hook installation" do
      let(:backup) { Workspace::FileBackup.new(output: output) }
      let(:hook_installer) { Workspace::HookInstaller.new(backup: backup, output: output, input: input) }
      let(:worktree_path) { File.join(tmpdir, ".worktrees", "PROJ-123") }
      let(:settings_path) { File.join(worktree_path, ".claude", "settings.json") }

      subject(:command) do
        described_class.new(
          git: git, project_config: project_config, project_settings: project_settings,
          launch_command: launch_command, hook_installer: hook_installer, which: which,
          output: output, input: input
        )
      end

      before do
        FileUtils.mkdir_p(worktree_path)
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)
      end

      context "when a hook-capable agent is detected" do
        let(:which) { ->(exe) { exe == "claude" } }

        it "installs its hooks into the new worktree" do
          command.call("PROJ-123")

          expect(File).to exist(settings_path)
          expect(JSON.parse(File.read(settings_path))["hooks"]).to have_key("PreToolUse")
        end
      end

      context "when no hook-capable agent is detected" do
        let(:which) { ->(_exe) { false } }

        it "installs nothing" do
          command.call("PROJ-123")

          expect(File).not_to exist(settings_path)
        end
      end

      context "with no hook installer" do
        subject(:command) do
          described_class.new(
            git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, output: output, input: input
          )
        end
        let(:which) { ->(exe) { exe == "claude" } }

        it "skips hook installation without raising" do
          expect { command.call("PROJ-123") }.not_to raise_error
          expect(File).not_to exist(settings_path)
        end
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
      it "passes prompt through to launch command and returns its result" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        launch_result = {exit_code: 1, prompt_failures: {"myproject.worktree-PROJ-123" => "no coding agent"}}
        allow(launch_command).to receive(:call).and_return(launch_result)

        result = command.call("PROJ-123", prompt: "Fix the bug")

        expect(launch_command).to have_received(:call).with(
          ["myproject.worktree-PROJ-123"],
          prompts: {"myproject.worktree-PROJ-123" => "Fix the bug"}
        )
        expect(result).to eq(launch_result)
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

      it "warns on stderr when --base is given but ignored" do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(true)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call)

        command.call("PROJ-123", base: "develop")

        expect(error_output.string).to include("Note: --base ignored; branch 'PROJ-123' already exists.")
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
          anything, "feature-branch", external_path, "feature-branch", quiet: false
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
        parent_name = Workspace::WorkspaceLineage.name_from_path(tmpdir)
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
        parent_name = Workspace::WorkspaceLineage.name_from_path(tmpdir)
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
        parent_name = Workspace::WorkspaceLineage.name_from_path(tmpdir)
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

    context "non-interactive base branch resolution" do
      before do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("feature-x").and_return({type: :branch, value: "feature-x"})
        allow(git).to receive(:sanitize_for_filesystem).with("feature-x").and_return("feature-x")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("feature-x").and_return(false)
        allow(git).to receive(:find_matching_branches).with("feature-x").and_return([])
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature-x")
        allow(launch_command).to receive(:call)
      end

      it "uses --base without prompting, even when stdin is a TTY" do
        allow(input).to receive(:tty?).and_return(true)

        command.call("feature-x", base: "develop")

        expect(git).to have_received(:create_worktree).with(anything, "feature-x", base: "develop", quiet: false)
      end

      it "uses the default branch with --yes and no --base" do
        allow(git).to receive(:default_branch).and_return("main")

        command.call("feature-x", yes: true)

        expect(git).to have_received(:create_worktree).with(anything, "feature-x", base: "main", quiet: false)
      end

      it "raises a usage error instead of blocking on a non-TTY stdin with no --base/--yes" do
        expect { command.call("feature-x") }.to raise_error(Workspace::UsageError, /--base.*--yes/m)
      end

      it "still prompts interactively when stdin is a TTY and neither flag is given" do
        allow(input).to receive(:tty?).and_return(true)
        allow(git).to receive(:default_branch).and_return("main")
        allow(git).to receive(:current_branch).and_return("main")
        allow(git).to receive(:prompt_base_branch).and_return("main")

        command.call("feature-x")

        expect(git).to have_received(:prompt_base_branch)
        expect(git).to have_received(:create_worktree).with(anything, "feature-x", base: "main", quiet: false)
      end
    end

    context "non-interactive branch selection" do
      before do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("feature-x").and_return({type: :branch, value: "feature-x"})
        allow(git).to receive(:sanitize_for_filesystem).with("feature-x").and_return("feature-x")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("feature-x").and_return(false)
        allow(git).to receive(:find_matching_branches).with("feature-x").and_return(["feature-x-a", "feature-x-b"])
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature-x")
        allow(launch_command).to receive(:call)
      end

      it "raises a usage error on ambiguous matches with no --base/--yes on a non-TTY stdin" do
        expect { command.call("feature-x") }.to raise_error(Workspace::UsageError, /Multiple remote branches match/)
        expect(git).not_to have_received(:create_worktree)
      end

      it "falls through to creating a new branch with --yes" do
        allow(git).to receive(:default_branch).and_return("main")

        command.call("feature-x", yes: true)

        expect(git).to have_received(:create_worktree).with(anything, "feature-x", base: "main", quiet: false)
      end

      it "falls through to creating a new branch with --base" do
        command.call("feature-x", base: "develop")

        expect(git).to have_received(:create_worktree).with(anything, "feature-x", base: "develop", quiet: false)
      end
    end

    context "with json: true" do
      before do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
      end

      it "emits the documented schema and nothing else on stdout" do
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})

        result = command.call("PROJ-123", json: true)

        expect(result).to eq({exit_code: 0})
        payload = JSON.parse(output.string)
        expect(payload).to include(
          "schema_version" => 1,
          "project" => Workspace::WorkspaceLineage.name_from_path(tmpdir),
          "workspace" => "myproject.worktree-PROJ-123",
          "path" => File.join(tmpdir, ".worktrees", "PROJ-123"),
          "branch" => "PROJ-123",
          "created" => true
        )
        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {}, quiet: true)
      end

      it "reports headless: false in the JSON by default" do
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})

        command.call("PROJ-123", json: true)

        payload = JSON.parse(output.string)
        expect(payload["headless"]).to be false
        expect(payload).not_to have_key("session_reused")
      end

      it "launches headless and reports whether the session was already running" do
        allow(launch_command).to receive(:call)
          .and_return({exit_code: 0, prompt_failures: {}, headless: true, reused: ["myproject.worktree-PROJ-123"], start_failures: {}})

        command.call("PROJ-123", json: true, headless: true)

        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {}, headless: true, quiet: true)
        payload = JSON.parse(output.string)
        expect(payload).to include("headless" => true, "session_reused" => true)
      end

      it "reports a session that could not be started as the JSON error" do
        allow(launch_command).to receive(:call).and_return({exit_code: 1, prompt_failures: {}, headless: true,
          reused: [], start_failures: {"myproject.worktree-PROJ-123" => "tmuxinator exited 1"}})

        result = command.call("PROJ-123", json: true, headless: true)

        expect(result).to eq({exit_code: 1})
        payload = JSON.parse(output.string)
        expect(payload["error"]).to eq("Could not start the workspace session: tmuxinator exited 1")
        expect(payload).not_to have_key("prompt_failures")
      end

      it "emits a JSON error and exit_code 1 on failure, instead of raising" do
        allow(git).to receive(:root).and_return(nil)

        result = command.call("PROJ-123", json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "error" => "Not inside a git repository."})
      end

      it "never prompts, even when stdin is a TTY" do
        allow(input).to receive(:tty?).and_return(true)
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})

        command.call("PROJ-123", json: true)

        expect(output.string.lines.size).to eq(1)
      end
    end
  end
end
