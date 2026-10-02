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

    context "with a PR ref" do
      let(:pr_worktree_path) { File.join(tmpdir, ".worktrees", "pr-123") }

      def stub_pr(parsed)
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).and_return(parsed)
        allow(git).to receive(:sanitize_for_filesystem).with("pr-123").and_return("pr-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:local_branch_exists?).with("pr-123").and_return(false)
        allow(git).to receive(:checkout_pr_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-pr-123")
        allow(launch_command).to receive(:call)
      end

      it "checks the PR out into a worktree with gh and launches it" do
        stub_pr({type: :pr_url, value: "https://github.com/org/repo/pull/123", repo: "org/repo", number: "123"})

        command.call("https://github.com/org/repo/pull/123")

        expect(git).to have_received(:checkout_pr_worktree)
          .with(pr_worktree_path, number: "123", repo: "org/repo", branch: "pr-123", chdir: tmpdir, quiet: false)
        expect(project_config).to have_received(:create_worktree)
          .with(File.basename(tmpdir), "pr-123", pr_worktree_path, "pr-123", quiet: false)
        expect(launch_command).to have_received(:call).with(["myproject.worktree-pr-123"], prompts: {})
      end

      it "never resolves the head branch name or creates the worktree itself, which is wrong for forks" do
        stub_pr({type: :pr_url, value: "https://github.com/org/repo/pull/123", repo: "org/repo", number: "123"})
        allow(git).to receive(:branch_exists?)
        allow(git).to receive(:create_worktree)

        command.call("https://github.com/org/repo/pull/123")

        expect(git).not_to have_received(:create_worktree)
        expect(git).not_to have_received(:branch_exists?)
      end

      it "accepts a bare #n ref, leaving the repo to gh" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})

        command.call("#123")

        expect(git).to have_received(:checkout_pr_worktree)
          .with(pr_worktree_path, number: "123", repo: nil, branch: "pr-123", chdir: tmpdir, quiet: false)
      end

      it "accepts an owner/repo#n ref" do
        stub_pr({type: :pr_url, value: "org/repo#123", repo: "org/repo", number: "123"})

        command.call("org/repo#123")

        expect(git).to have_received(:checkout_pr_worktree)
          .with(pr_worktree_path, number: "123", repo: "org/repo", branch: "pr-123", chdir: tmpdir, quiet: false)
      end

      it "reuses an existing worktree for the PR without calling gh" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:worktree_exists?).with(pr_worktree_path).and_return(true)

        command.call("#123")

        expect(git).not_to have_received(:checkout_pr_worktree)
        expect(output.string).to include("Worktree already exists at: #{pr_worktree_path}")
        expect(launch_command).to have_received(:call)
      end

      it "adopts a worktree that already has the PR branch checked out elsewhere" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        elsewhere = File.join(tmpdir, "elsewhere")
        allow(git).to receive(:find_worktree_by_branch).with("pr-123", repo: tmpdir).and_return(elsewhere)

        command.call("#123")

        expect(git).not_to have_received(:checkout_pr_worktree)
        expect(output.string).to include("Adopting existing worktree at: #{elsewhere}")
      end

      it "stops with a clear error when a stale pr-<n> branch has no worktree, instead of letting gh reset it" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:local_branch_exists?).with("pr-123").and_return(true)

        expect { command.call("#123") }.to raise_error(Workspace::Error, /Branch 'pr-123' already exists but has no worktree.*git branch -D pr-123/m)

        expect(git).not_to have_received(:checkout_pr_worktree)
        expect(launch_command).not_to have_received(:call)
      end

      it "notes that --base is ignored when reusing an existing PR worktree" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:worktree_exists?).with(pr_worktree_path).and_return(true)

        command.call("#123", base: "main")

        expect(error_output.string).to include("--base ignored")
      end

      it "notes that --base is ignored for a PR" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})

        command.call("#123", base: "main")

        expect(error_output.string).to include("--base ignored")
        expect(git).to have_received(:checkout_pr_worktree)
      end

      it "reports the PR branch, a nil base and the created worktree in --json" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})

        result = command.call("#123", json: true)

        expect(result[:exit_code]).to eq(0)
        payload = JSON.parse(output.string)
        expect(payload).to include("branch" => "pr-123", "base" => nil, "created" => true, "path" => pr_worktree_path)
        expect(git).to have_received(:checkout_pr_worktree).with(anything, hash_including(quiet: true))
      end

      it "emits the JSON error payload and launches nothing when gh fails" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:checkout_pr_worktree).and_raise(Workspace::Error, "Could not check out PR #123")

        result = command.call("#123", json: true)

        expect(result[:exit_code]).to eq(1)
        expect(JSON.parse(output.string)).to include("error" => "Could not check out PR #123")
        expect(project_config).not_to have_received(:create_worktree)
        expect(launch_command).not_to have_received(:call)
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

        it "routes its status line through workspace statusline" do
          command.call("PROJ-123")

          status_line = JSON.parse(File.read(settings_path))["statusLine"]
          expect(status_line).to eq("type" => "command", "command" => "workspace statusline")
        end

        context "in quiet mode, when the worktree already routes statusLine elsewhere" do
          before do
            FileUtils.mkdir_p(File.dirname(settings_path))
            File.write(settings_path, JSON.pretty_generate(
              "statusLine" => {"type" => "command", "command" => "my-statusline.sh"}
            ) + "\n")
          end

          it "surfaces the displaced statusLine notice in the JSON warnings" do
            command.call("PROJ-123", json: true)

            payload = JSON.parse(output.string)
            expect(payload["warnings"]).to include(
              "Note: save previous statusLine command -> statusline.command (my-statusline.sh)."
            )
            expect(JSON.parse(File.read(settings_path))["statusLine"]["command"]).to eq("workspace statusline")
          end
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

    context "when run from inside a linked worktree" do
      let(:worktree_root) { File.join(tmpdir, ".worktrees", "existing") }
      let(:lineage) { instance_double(Workspace::WorkspaceLineage) }

      subject(:command) do
        described_class.new(
          git: git,
          project_config: project_config,
          project_settings: project_settings,
          launch_command: launch_command,
          lineage: lineage,
          output: output,
          error_output: error_output,
          input: input
        )
      end

      before do
        allow(git).to receive(:root).and_return(worktree_root)
        allow(git).to receive(:parse_start_input).with("feature-x").and_return({type: :branch, value: "feature-x"})
        allow(git).to receive(:sanitize_for_filesystem).with("feature-x").and_return("feature-x")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("feature-x").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature-x")
        allow(launch_command).to receive(:call)
        allow(lineage).to receive(:write_marker)
      end

      def lineage_info(**overrides)
        defaults = {name: "myproject", path: tmpdir, git_common_dir: File.join(tmpdir, ".git"),
                    is_worktree: true, worktree: "myproject.worktree-existing"}
        Workspace::WorkspaceLineage::Lineage.new(**defaults.merge(overrides))
      end

      it "targets the parent repo for the worktree, config name, and session" do
        allow(lineage).to receive(:resolve).with(cwd: worktree_root).and_return(lineage_info)

        command.call("feature-x")

        expect(git).to have_received(:create_worktree).with(
          File.join(tmpdir, ".worktrees", "feature-x"), "feature-x", base: nil, quiet: false
        )
        expect(git).to have_received(:find_worktree_by_branch).with("feature-x", repo: tmpdir)
        expect(project_config).to have_received(:create_worktree).with(
          "myproject", "feature-x", File.join(tmpdir, ".worktrees", "feature-x"), "feature-x", quiet: false
        )
        expect(launch_command).to have_received(:call).with(["myproject.worktree-feature-x"], prompts: {})
        expect(error_output.string).to include("Note: run from inside a linked worktree; using parent repo #{tmpdir}.")
      end

      it "surfaces the parent repo note in the JSON warnings in quiet mode" do
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})
        allow(lineage).to receive(:resolve).with(cwd: worktree_root).and_return(lineage_info)

        command.call("feature-x", json: true)

        payload = JSON.parse(output.string)
        expect(payload["warnings"]).to include("Note: run from inside a linked worktree; using parent repo #{tmpdir}.")
      end

      it "uses the repo root and name as-is when not inside a worktree" do
        allow(lineage).to receive(:resolve).with(cwd: worktree_root).and_return(lineage_info(is_worktree: false, worktree: nil))

        command.call("feature-x")

        expect(git).to have_received(:create_worktree).with(
          File.join(worktree_root, ".worktrees", "feature-x"), "feature-x", base: nil, quiet: false
        )
        expect(project_config).to have_received(:create_worktree).with(
          Workspace::WorkspaceLineage.name_from_path(worktree_root), "feature-x",
          File.join(worktree_root, ".worktrees", "feature-x"), "feature-x", quiet: false
        )
        expect(error_output.string).not_to include("using parent repo")
      end

      context "falls back when the lineage result is not self-consistent" do
        it "uses the cwd repo's own root when the resolved path is the cwd root itself" do
          git_root = File.join(tmpdir, ".worktrees", "existing", "myrepo")
          allow(git).to receive(:root).and_return(git_root)
          allow(lineage).to receive(:resolve).with(cwd: git_root).and_return(
            lineage_info(name: "myproject", path: git_root, git_common_dir: File.join(git_root, ".git"))
          )

          command.call("feature-x")

          expect(error_output.string).not_to include("using parent repo")
          expect(git).to have_received(:create_worktree).with(
            File.join(git_root, ".worktrees", "feature-x"), "feature-x", base: nil, quiet: false
          )
          expect(project_config).to have_received(:create_worktree).with(
            Workspace::WorkspaceLineage.name_from_path(git_root), "feature-x",
            File.join(git_root, ".worktrees", "feature-x"), "feature-x", quiet: false
          )
        end

        it "uses the cwd repo's own root when the common dir is a bare repo" do
          allow(lineage).to receive(:resolve).with(cwd: worktree_root).and_return(
            lineage_info(path: tmpdir, git_common_dir: File.join(tmpdir, "myproject.git"), worktree: nil)
          )

          command.call("feature-x")

          expect(error_output.string).not_to include("using parent repo")
          expect(git).to have_received(:create_worktree).with(
            File.join(worktree_root, ".worktrees", "feature-x"), "feature-x", base: nil, quiet: false
          )
          expect(project_config).to have_received(:create_worktree).with(
            Workspace::WorkspaceLineage.name_from_path(worktree_root), "feature-x",
            File.join(worktree_root, ".worktrees", "feature-x"), "feature-x", quiet: false
          )
        end
      end
    end

    context "with real git, run from inside a linked worktree" do
      let(:real_git) { Workspace::Git.new(output: output, input: input) }
      let(:lineage) { Workspace::WorkspaceLineage.new }
      let(:worktree_path) { File.join(tmpdir, ".worktrees", "existing") }

      subject(:command) do
        described_class.new(
          git: real_git,
          project_config: project_config,
          project_settings: project_settings,
          launch_command: launch_command,
          lineage: lineage,
          output: output,
          error_output: error_output,
          input: input
        )
      end

      def git(*args, chdir:)
        system("git", *args, chdir: chdir, out: File::NULL, err: File::NULL)
      end

      def init_repo(dir)
        FileUtils.mkdir_p(dir)
        git("init", "-q", chdir: dir)
        git("config", "user.email", "test@example.com", chdir: dir)
        git("config", "user.name", "Test", chdir: dir)
        File.write(File.join(dir, "README"), "x")
        git("add", "README", chdir: dir)
        git("commit", "-q", "-m", "init", chdir: dir)
      end

      before do
        init_repo(tmpdir)
        FileUtils.mkdir_p(File.join(tmpdir, ".worktrees"))
        git("worktree", "add", "-b", "existing", worktree_path, chdir: tmpdir)
        allow(real_git).to receive(:find_matching_branches).and_return([])
        allow(project_config).to receive(:create_worktree) { |project_name, dir_name, *_args, **_kwargs| "#{project_name}.worktree-#{dir_name}" }
        allow(launch_command).to receive(:call)
      end

      after do
        %w[existing feature-x].each do |name|
          path = File.join(tmpdir, ".worktrees", name)
          git("worktree", "remove", "--force", path, chdir: tmpdir) if File.directory?(path)
        end
      end

      it "creates the worktree under the parent repo, not nested inside the cwd worktree" do
        Dir.chdir(worktree_path) do
          command.call("feature-x", yes: true)
        end

        expect(File.directory?(File.join(tmpdir, ".worktrees", "feature-x"))).to be true
        expect(File).not_to exist(File.join(worktree_path, ".worktrees"))
      end

      it "reuses the parent repo's existing worktree and config name" do
        git("worktree", "add", "-b", "feature-x", File.join(tmpdir, ".worktrees", "feature-x"), chdir: tmpdir)

        Dir.chdir(worktree_path) do
          command.call("feature-x", yes: true)
        end

        parent_name = Workspace::WorkspaceLineage.name_from_path(tmpdir)
        expect(launch_command).to have_received(:call).with(["#{parent_name}.worktree-feature-x"], prompts: {})
        expect(File).not_to exist(File.join(worktree_path, ".worktrees"))
      end

      it "uses a standalone repo nested inside the worktree as its own project" do
        lineage.write_marker(worktree_path, "#{Workspace::WorkspaceLineage.name_from_path(tmpdir)}.worktree-existing")
        nested_repo = File.join(worktree_path, "nested-repo")
        init_repo(nested_repo)

        Dir.chdir(nested_repo) do
          command.call("feature-x", yes: true)
        end

        expect(error_output.string).not_to include("using parent repo")
        # git reports the symlink-resolved toplevel (/private/var on macOS)
        nested_worktree = File.realpath(File.join(nested_repo, ".worktrees", "feature-x"))
        expect(project_config).to have_received(:create_worktree).with(
          "nested-repo", "feature-x", nested_worktree, "feature-x", quiet: false
        )
        expect(File).not_to exist(File.join(tmpdir, ".worktrees", "feature-x"))
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
