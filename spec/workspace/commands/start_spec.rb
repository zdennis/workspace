require "tmpdir"

RSpec.describe Workspace::Commands::Start do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:git) { double("git") }
  let(:project_config) do
    double("project_config", existing_name: nil).tap { |pc| allow(pc).to receive(:settle_worktree_name) { |project, dir, _path| "#{project}.worktree-#{dir}" } }
  end
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
        allow(git).to receive(:drop_unresolved_upstream).and_return(false)
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

      it "gives the worktree the parent project's name in lowercase, or the spelling its config already has" do
        stub_pr({type: :pr_url, value: "https://github.com/org/repo/pull/123", repo: "org/repo", number: "123"})
        parent = File.basename(tmpdir)
        allow(project_config).to receive(:existing_name).with(parent).and_return(nil)

        command.call("https://github.com/org/repo/pull/123")
        expect(project_config).to have_received(:create_worktree).with(parent.downcase, anything, anything, anything, anything)

        allow(project_config).to receive(:existing_name).with(parent).and_return("Existing-Spelling")
        command.call("https://github.com/org/repo/pull/123")
        expect(project_config).to have_received(:create_worktree).with("Existing-Spelling", anything, anything, anything, anything)
      end

      it "refuses a case-only name clash before it checks anything out" do
        stub_pr({type: :pr_url, value: "https://github.com/org/repo/pull/123", repo: "org/repo", number: "123"})
        allow(project_config).to receive(:settle_worktree_name)
          .and_raise(Workspace::Error.new("clash", code: "workspace_name_case_conflict"))

        expect { command.call("https://github.com/org/repo/pull/123") }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("workspace_name_case_conflict") }
        expect(git).not_to have_received(:checkout_pr_worktree)
        expect(launch_command).not_to have_received(:call)
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

      it "drops an upstream git cannot resolve after the checkout and says how to set one" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:drop_unresolved_upstream).and_return(true)

        command.call("#123")

        expect(git).to have_received(:drop_unresolved_upstream).with(pr_worktree_path, "pr-123")
        expect(output.string).to include("No upstream set for pr-123; the first `workspace push` or `workspace pr create` sets one.")
      end

      it "stays silent when there was no unresolved upstream to drop" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})

        command.call("#123")

        expect(git).to have_received(:drop_unresolved_upstream).with(pr_worktree_path, "pr-123")
        expect(output.string).not_to include("No upstream set")
      end

      it "does not print the upstream note when quiet" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:drop_unresolved_upstream).and_return(true)

        command.call("#123", json: true)

        expect(output.string).not_to include("No upstream set")
      end

      it "does not touch the upstream of a reused, adopted or failed PR checkout" do
        stub_pr({type: :pr_url, value: "#123", repo: nil, number: "123"})
        allow(git).to receive(:worktree_exists?).with(pr_worktree_path).and_return(true)
        command.call("#123")

        allow(git).to receive(:worktree_exists?).with(pr_worktree_path).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).with("pr-123", repo: tmpdir).and_return(File.join(tmpdir, "elsewhere"))
        command.call("#123")

        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:checkout_pr_worktree).and_raise(Workspace::Error, "boom")
        command.call("#123", json: true)

        expect(git).not_to have_received(:drop_unresolved_upstream)
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
      let(:settings_path) { File.join(worktree_path, ".claude", "settings.local.json") }
      let(:tracked_settings_path) { File.join(worktree_path, ".claude", "settings.json") }

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

        it "never writes the tracked settings.json" do
          command.call("PROJ-123")

          expect(File).not_to exist(tracked_settings_path)
        end

        it "lists the .workspace-project marker through the excluder" do
          excluder = instance_double(Workspace::BookkeepingExclude, created: true)
          described_class.new(
            git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, hook_installer: hook_installer, which: which,
            excluder: excluder, output: output, input: input
          ).call("PROJ-123")

          expect(excluder).to have_received(:created).with(File.join(worktree_path, ".workspace-project"))
        end

        it "warns instead of failing when settings.local.json is malformed" do
          FileUtils.mkdir_p(File.dirname(settings_path))
          File.write(settings_path, "{nope")

          expect { command.call("PROJ-123", json: true) }.not_to raise_error
          warnings = JSON.parse(output.string)["warnings"]
          expect(warnings).to include(a_string_matching(/\ANote: Claude Code hooks not installed: .*not valid JSON/))
          expect(warnings).to include(a_string_matching(/\ANote: Claude Code statusLine not routed: .*not valid JSON/))
          expect(File.read(settings_path)).to eq("{nope")
        end

        it "prints Note lines instead of raising for a malformed settings.local.json outside --json" do
          FileUtils.mkdir_p(File.dirname(settings_path))
          File.write(settings_path, "{nope")

          expect { command.call("PROJ-123") }.not_to raise_error
          expect(output.string).to match(/^Note: Claude Code hooks not installed: /)
          expect(output.string).to match(/^Note: Claude Code statusLine not routed: /)
        end

        it "neither reads nor warns about a malformed settings.local.json when the tracked file already holds the entries" do
          claude = Workspace::AgentProvider.find("claude")
          hook_installer.install(claude, worktree_path, Workspace::Commands::Init::HOOK_COMMAND, quiet: true)
          hook_installer.install_statusline(claude, worktree_path,
            command: Workspace::Commands::Init::STATUSLINE_COMMAND, project_settings: project_settings, quiet: true)
          FileUtils.mkdir_p(File.dirname(settings_path))
          File.write(settings_path, "{nope")

          command.call("PROJ-123", json: true)

          expect(Array(JSON.parse(output.string)["warnings"]).grep(/not installed|not routed/)).to be_empty
          expect(File.read(settings_path)).to eq("{nope")
        end

        context "in quiet mode, when the worktree already routes statusLine elsewhere" do
          before do
            FileUtils.mkdir_p(File.dirname(tracked_settings_path))
            File.write(tracked_settings_path, JSON.pretty_generate(
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

      context "when the agent runs a configured command" do
        let(:agent_commands) { instance_double(Workspace::AgentCommands, kind: "claude") }
        let(:seen) { [] }
        let(:which) { ->(exe) { seen << exe && exe == "claude-dev" } }

        subject(:command) do
          described_class.new(
            git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, hook_installer: hook_installer, which: which, agent_commands: agent_commands,
            output: output, input: input
          )
        end

        before do
          allow(project_config).to receive(:check_agent_kind!)
          allow(agent_commands).to receive(:executable_for) { |_name, kind| (kind == "claude") ? "claude-dev" : kind }
          allow(agent_commands).to receive(:command_for) { |_name, kind| (kind == "claude") ? "claude-dev" : kind }
        end

        it "installs hooks and the status line when that program is on PATH" do
          command.call("PROJ-123")

          expect(agent_commands).to have_received(:executable_for).with("myproject.worktree-PROJ-123", "claude").at_least(:once)
          expect(JSON.parse(File.read(settings_path))["hooks"]).to have_key("PreToolUse")
          expect(JSON.parse(File.read(settings_path))["statusLine"]).to include("command" => "workspace statusline")
        end

        it "installs nothing when only the bare agent would be on PATH" do
          allow(agent_commands).to receive(:executable_for) { |_name, kind| "#{kind}-missing" }

          command.call("PROJ-123")

          expect(File).not_to exist(settings_path)
        end
      end

      context "when Codex is detected" do
        let(:which) { ->(exe) { exe == "codex" } }
        let(:codex_home) { File.join(tmpdir, "codex-home") }
        let(:codex_path) { File.join(codex_home, "hooks.json") }
        let(:hook_installer) { Workspace::HookInstaller.new(backup: backup, output: output, input: input, env: {"CODEX_HOME" => codex_home}, home: tmpdir) }

        it "installs its user-level hooks, not into the worktree, and notes once in the JSON warnings how to trust them" do
          command.call("PROJ-123", json: true)

          expect(JSON.parse(File.read(codex_path))["hooks"]).to have_key("PermissionRequest")
          expect(File).not_to exist(File.join(worktree_path, ".codex"))
          expect(JSON.parse(output.string)["warnings"]).to include(a_string_including("run /hooks in Codex"))
        end

        context "when codex.hooks.install is false" do
          let(:hooks_config) { instance_double(Workspace::HooksConfig, install_user_hooks?: false) }

          subject(:command) do
            described_class.new(
              git: git, project_config: project_config, project_settings: project_settings,
              launch_command: launch_command, hook_installer: hook_installer, hooks_config: hooks_config,
              which: which, output: output, input: input
            )
          end

          it "leaves the user-level file alone and says so once in the JSON warnings" do
            command.call("PROJ-123", json: true)

            expect(File).not_to exist(codex_path)
            warnings = JSON.parse(output.string)["warnings"]
            expect(warnings.grep(/codex\.hooks\.install is false/).size).to eq(1)
          end

          it "prints the note once in plain mode" do
            command.call("PROJ-123")

            expect(File).not_to exist(codex_path)
            expect(output.string.scan("codex.hooks.install is false").size).to eq(1)
          end
        end

        it "warns rather than fails when Codex's hook file can't be read" do
          FileUtils.mkdir_p(codex_home)
          File.write(codex_path, "{ nope")

          command.call("PROJ-123", json: true)

          payload = JSON.parse(output.string)
          expect(payload["ok"]).to be true
          expect(payload["warnings"]).to include(a_string_including("Codex hooks not installed"))
          expect(File.read(codex_path)).to eq("{ nope")
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

    context "with a play" do
      let(:library_dir) { File.join(tmpdir, "library") }
      let(:library) do
        Workspace::Library.new(config: instance_double(Workspace::Config, library_dir: library_dir, builtin_library_dir: File.join(library_dir, "builtin")),
          lineage: Workspace::WorkspaceLineage.new, project_config: project_config)
      end
      let(:project_name) { Workspace::WorkspaceLineage.name_from_path(tmpdir) }
      let(:global_path) { library.global_store.path_for("play", "kickoff") }
      let(:play_command) do
        described_class.new(git: git, project_config: project_config, project_settings: project_settings,
          launch_command: launch_command, library: library, output: output, error_output: error_output, input: input)
      end

      before do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:exists?).and_return(false)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})
        library.global_store.write("play", "kickoff", "# Kickoff\n")
      end

      it "sends a line pointing at the play, then the --prompt text" do
        play_command.call("PROJ-123", plays: ["kickoff"], prompt: "Start at CLI27.")

        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"],
          prompts: {"myproject.worktree-PROJ-123" => "Read \"#{global_path}\" and follow it.\n\nStart at CLI27."},
          bindings: {"myproject.worktree-PROJ-123" => {"kind" => "play", "id" => "play/kickoff", "instructions" => global_path, "plays" => [{"id" => "play/kickoff", "instructions" => global_path}]}})
      end

      it "sends one line per play in order, binds the first as id and lists all, and reports each in --json" do
        review_path = library.global_store.path_for("play", "review")
        library.global_store.write("play", "review", "# Review\n")
        allow(launch_command).to receive(:call)
          .and_return({exit_code: 0, prompt_failures: {}, bound_panes: {"myproject.worktree-PROJ-123" => "%5"}})

        play_command.call("PROJ-123", plays: %w[kickoff play/review kickoff], prompt: "Go.", json: true)

        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"],
          quiet: true,
          prompts: {"myproject.worktree-PROJ-123" => "Read \"#{global_path}\" and follow it.\nRead \"#{review_path}\" and follow it.\n\nGo."},
          bindings: {"myproject.worktree-PROJ-123" => {"kind" => "play", "id" => "play/kickoff", "instructions" => global_path,
                                                       "plays" => [{"id" => "play/kickoff", "instructions" => global_path}, {"id" => "play/review", "instructions" => review_path}]}})
        payload = JSON.parse(output.string)
        expect(payload["plays"].map { |p| p["ref"] }).to eq(%w[play/kickoff play/review])
        expect(payload["plays"]).to all(include("delivered" => true, "pane" => "%5"))
        expect(payload["play"]).to eq(payload["plays"].first)
      end

      it "refuses more than 20 plays with nothing created" do
        names = (1..21).map { |i| "p#{i}" }

        expect { play_command.call("PROJ-123", plays: names) }.to raise_error(Workspace::UsageError, /at most 20 plays/)
        expect(project_config).not_to have_received(:create_worktree)
        expect(launch_command).not_to have_received(:call)
      end

      it "leaves play and plays out of --json without --play" do
        play_command.call("PROJ-123", json: true)

        expect(JSON.parse(output.string)).not_to include("play", "plays")
      end

      describe "with a recipe" do
        let(:name) { "myproject.worktree-PROJ-123" }

        def recipe(body, name: "review-pass")
          library.global_store.write("recipe", name, body)
        end

        it "sends the recipe's play and prompt and reports the recipe in --json" do
          recipe("plays: [kickoff]\nprompt: Start at step 2.\n")

          play_command.call("PROJ-123", recipe: "review-pass", json: true)

          expect(launch_command).to have_received(:call).with([name], quiet: true,
            prompts: {name => "Read \"#{global_path}\" and follow it.\n\nStart at step 2."}, bindings: anything)
          doc = JSON.parse(output.string)
          expect(doc["recipe"]).to eq("ref" => "recipe/review-pass", "scope" => "global")
          expect(doc["plays"].map { |p| p["ref"] }).to eq(["play/kickoff"])
        end

        it "lets explicit --prompt and --play replace the recipe's values" do
          library.global_store.write("play", "other", "# Other\n")
          other_path = library.global_store.path_for("play", "other")
          recipe("plays: [kickoff]\nprompt: From the recipe.\n")

          play_command.call("PROJ-123", recipe: "review-pass", plays: ["other"], prompt: "Mine.")

          expect(launch_command).to have_received(:call).with([name],
            prompts: {name => "Read \"#{other_path}\" and follow it.\n\nMine."}, bindings: anything)
        end

        it "passes the recipe's agent kind unless --agent-kind is given" do
          recipe("agent_kind: codex\n")
          allow(project_config).to receive(:check_agent_kind!)

          play_command.call("PROJ-123", recipe: "review-pass")
          expect(project_config).to have_received(:create_worktree).with(anything, anything, anything, anything, quiet: false, agent_kind: "codex")

          play_command.call("PROJ-123", recipe: "review-pass", agent_kind: "claude")
          expect(project_config).to have_received(:create_worktree).with(anything, anything, anything, anything, quiet: false, agent_kind: "claude")
        end

        it "copies the recipe's agents and skills" do
          copier = double("copier")
          allow(copier).to receive(:relative_path).and_return("x")
          recipe("agents: [reviewer]\n")
          library.global_store.write("agent", "reviewer", "# Reviewer\n")
          installing = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, library: library, library_installer: copier, output: output, error_output: error_output, input: input)
          allow(copier).to receive(:copy).and_return({"ref" => "agent/reviewer", "outcome" => "copied"})

          installing.call("PROJ-123", recipe: "review-pass", json: true)

          expect(copier).to have_received(:copy).with(hash_including("ref" => "agent/reviewer"), worktree: anything, project: anything)
        end

        it "drops the recipe's play and prompt with a warning under --no-launch" do
          recipe("plays: [kickoff]\nprompt: Hi\nagent_kind: codex\n")
          allow(project_config).to receive(:check_agent_kind!)

          play_command.call("PROJ-123", recipe: "review-pass", no_launch: true, json: true)

          doc = JSON.parse(output.string)
          expect(doc).to include("ok" => true, "launched" => false)
          expect(doc["warnings"]).to include(/left out plays, prompt \(--no-launch sends nothing\)/)
          expect(launch_command).not_to have_received(:call)
        end

        it "leaves the recipe's packs out under --no-packs and its plays out under --plan, with a warning" do
          recipe("plays: [kickoff]\npacks: [review]\n")

          play_command.call("PROJ-123", recipe: "review-pass", no_packs: true, json: true)

          expect(JSON.parse(output.string)["warnings"]).to include(/left out packs \(--no-packs was given\)/)
        end

        it "does not turn the recipe's plays into a --plan conflict" do
          recipe("plays: [kickoff]\n")
          plan_command = double("plan_command")
          allow(plan_command).to receive(:init).and_return({"path" => "/p/IMPLEMENTATION_PLAN.md"})
          planning = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, library: library, plan_command: plan_command, output: output, error_output: error_output, input: input)

          expect { planning.call("PROJ-123", recipe: "review-pass", plan: true, no_launch: true, json: true) }.not_to raise_error
          expect(JSON.parse(output.string)["warnings"].join).to include("--plan sends its own play")
        end

        it "fails an unknown recipe with nothing created" do
          expect { play_command.call("PROJ-123", recipe: "nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }
          expect(project_config).not_to have_received(:create_worktree)
        end

        it "fails an invalid recipe with nothing created" do
          recipe("plays: 3\nbogus: 1\n")

          expect { play_command.call("PROJ-123", recipe: "review-pass") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_recipe") }
          expect(project_config).not_to have_received(:create_worktree)
        end

        it "refuses a recipe when no library was wired" do
          expect { command.call("PROJ-123", recipe: "x") }.to raise_error(Workspace::Error, /no library was wired/)
        end
      end

      it "fails an unknown play among several with nothing created" do
        expect { play_command.call("PROJ-123", plays: %w[kickoff nope]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_library_entry") }

        expect(git).not_to have_received(:create_worktree)
        expect(project_config).not_to have_received(:create_worktree)
        expect(launch_command).not_to have_received(:call)
      end

      it "sends only the line pointing at the play without --prompt" do
        play_command.call("PROJ-123", plays: ["kickoff"])

        expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"],
          prompts: {"myproject.worktree-PROJ-123" => "Read \"#{global_path}\" and follow it."},
          bindings: {"myproject.worktree-PROJ-123" => {"kind" => "play", "id" => "play/kickoff", "instructions" => global_path, "plays" => [{"id" => "play/kickoff", "instructions" => global_path}]}})
      end

      it "uses the parent project's play over the global one" do
        allow(project_config).to receive(:exists?).with(project_name).and_return(true)
        library.project_store(project_name).write("play", "kickoff", "# Project kickoff\n")

        play_command.call("PROJ-123", plays: ["kickoff"], json: true)

        expect(JSON.parse(output.string)["play"]).to include("scope" => "project",
          "path" => library.project_store(project_name).path_for("play", "kickoff"))
      end

      it "reports the play it sent in --json" do
        play_command.call("PROJ-123", plays: ["play/kickoff"], json: true)

        expect(JSON.parse(output.string)["play"]).to eq("ref" => "play/kickoff", "scope" => "global", "path" => global_path,
          "sha256" => Digest::SHA256.hexdigest("# Kickoff\n"), "delivered" => true, "pane" => nil)
      end

      it "reports the pane the play was bound to in --json" do
        allow(launch_command).to receive(:call)
          .and_return({exit_code: 0, prompt_failures: {}, bound_panes: {"myproject.worktree-PROJ-123" => "%5"}})

        play_command.call("PROJ-123", plays: ["kickoff"], json: true)

        expect(JSON.parse(output.string)["play"]).to include("delivered" => true, "pane" => "%5")
      end

      it "reports the play as not delivered, with exit 1, when the prompt was not sent" do
        allow(launch_command).to receive(:call)
          .and_return({exit_code: 1, prompt_failures: {"myproject.worktree-PROJ-123" => "no coding agent"}})

        result = play_command.call("PROJ-123", plays: ["kickoff"], json: true)

        payload = JSON.parse(output.string)
        expect(result).to eq({exit_code: 1})
        expect(payload["play"]).to include("delivered" => false)
        expect(payload["prompt_failures"]).to eq("myproject.worktree-PROJ-123" => "no coding agent")
      end

      it "reports the play as not delivered when the session did not start" do
        allow(launch_command).to receive(:call)
          .and_return({exit_code: 1, prompt_failures: {}, start_failures: {"myproject.worktree-PROJ-123" => "tmux refused"}})

        play_command.call("PROJ-123", plays: ["kickoff"], json: true)

        expect(JSON.parse(output.string)["play"]).to include("delivered" => false)
      end

      context "with packs" do
        let(:composer) do
          Workspace::InstructionComposer.new(library: library, lineage: Workspace::WorkspaceLineage.new, commands_config: Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
            pane_bindings: instance_double(Workspace::PaneBindings), notes_config: Workspace::NotesConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)))
        end
        let(:packs_command) do
          described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, library: library, instruction_composer: composer, output: output, error_output: error_output, input: input)
        end
        let(:notes_text) { "## From pack notes (built-in)\n\nNotes go in the notes directory.\n" }

        before do
          library.builtin_store.write("play", "notes", "Notes go in the notes directory.\n")
          library.builtin_store.write("play", "review", "Review the diff.\n")
        end

        it "sends the notes pack before the prompt with no flags" do
          packs_command.call("PROJ-123", prompt: "Go.")

          expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {"myproject.worktree-PROJ-123" => "#{notes_text.strip}\n\nGo."}, report_panes: true,
            bindings: {"myproject.worktree-PROJ-123" => {"kind" => "play", "id" => "play/notes", "packs" => ["notes"], "keep_existing" => true}})
        end

        it "binds the pane to the packs it was sent when there is no play, and leaves a live binding alone" do
          packs_command.call("PROJ-123", packs: %w[review])

          expect(launch_command).to have_received(:call).with(anything, hash_including(
            bindings: {"myproject.worktree-PROJ-123" => {"kind" => "play", "id" => "play/notes", "packs" => %w[notes review], "keep_existing" => true}}
          ))
        end

        it "adds the packs to the play's binding" do
          packs_command.call("PROJ-123", plays: ["kickoff"], packs: %w[review])

          expect(launch_command).to have_received(:call).with(anything, hash_including(
            bindings: {"myproject.worktree-PROJ-123" => hash_including("id" => "play/kickoff", "instructions" => global_path, "packs" => %w[notes review])}
          ))
        end

        it "binds nothing when no pack applies" do
          packs_command.call("PROJ-123", prompt: "Go.", no_packs: true)

          expect(launch_command).to have_received(:call).with(anything, hash_excluding(:bindings))
        end

        it "sends the play line, then the packs, then the prompt, with --pack after the automatic pack" do
          packs_command.call("PROJ-123", plays: ["kickoff"], packs: %w[review], prompt: "Go.")

          expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], hash_including(
            prompts: {"myproject.worktree-PROJ-123" => "Read \"#{global_path}\" and follow it.\n\n#{notes_text}\n## From pack review (built-in)\n\nReview the diff.\n\nGo."}
          ))
        end

        it "sends only the packs when there is no prompt" do
          packs_command.call("PROJ-123")

          expect(launch_command).to have_received(:call).with(anything, hash_including(prompts: {"myproject.worktree-PROJ-123" => notes_text.strip}))
        end

        it "sends no automatic pack with no_packs, or when notes.instructions is false" do
          packs_command.call("PROJ-123", no_packs: true)
          expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {})

          project_settings.data[project_name] = {"notes" => {"instructions" => "false"}} if project_settings.respond_to?(:data)
          allow(project_settings).to receive(:load).with(project_name).and_return({"notes" => {"instructions" => "false"}})
          allow(project_settings).to receive(:load).with(/-PROJ-123\z/).and_return({"notes" => {"instructions" => "false"}})
          packs_command.call("PROJ-123")
          expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {}).twice
        end

        it "reports the packs, where each went, in --json" do
          allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}, delivered_panes: {"myproject.worktree-PROJ-123" => "%4"}})

          packs_command.call("PROJ-123", packs: %w[review], json: true)

          expect(JSON.parse(output.string)["packs"]).to eq([
            {"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%4"},
            {"name" => "review", "source" => "flag", "delivered" => true, "pane" => "%4"}
          ])
        end

        it "reports the packs as not delivered when the prompt was not sent" do
          allow(launch_command).to receive(:call).and_return({exit_code: 1, prompt_failures: {"myproject.worktree-PROJ-123" => "agent not ready"}, delivered_panes: {}})

          packs_command.call("PROJ-123", json: true)

          expect(JSON.parse(output.string)["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => false, "pane" => nil}])
        end

        it "asks launch to treat a prompt of automatic packs alone as optional, and any explicit one as required" do
          packs_command.call("PROJ-123")
          packs_command.call("PROJ-123", prompt: "Go.")
          packs_command.call("PROJ-123", packs: %w[review])
          packs_command.call("PROJ-123", plays: ["kickoff"])

          expect(launch_command).to have_received(:call).with(anything, hash_including(optional: {"myproject.worktree-PROJ-123" => ["notes"]})).once
          expect(launch_command).to have_received(:call).with(anything, hash_not_including(:optional)).exactly(3).times
        end

        it "exits 0 with delivered false, a null pane and a warning when the automatic pack was skipped" do
          message = "the notes pack was not sent to myproject.worktree-PROJ-123: no coding agent is running"
          allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}, delivered_panes: {}, skipped_prompts: {"myproject.worktree-PROJ-123" => message}})

          result = packs_command.call("PROJ-123", json: true)

          doc = JSON.parse(output.string)
          expect(result[:exit_code]).to eq(0)
          expect(doc["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => false, "pane" => nil}])
          expect(doc["warnings"]).to include(message)
          expect(doc).not_to have_key("error")
        end

        it "reports an empty packs list when none applied" do
          packs_command.call("PROJ-123", no_packs: true, json: true)

          expect(JSON.parse(output.string)["packs"]).to eq([])
        end

        it "fails an unknown pack before creating anything, as a --json error" do
          result = packs_command.call("PROJ-123", packs: %w[nope], json: true)

          expect(result).to eq({exit_code: 1})
          expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_library_entry")
          expect(git).not_to have_received(:create_worktree)
          expect(project_config).not_to have_received(:create_worktree)
          expect(launch_command).not_to have_received(:call)
        end

        it "refuses --pack when no composer is wired" do
          expect { play_command.call("PROJ-123", packs: %w[review]) }.to raise_error(Workspace::Error, /--pack is not available/)
          expect(project_config).not_to have_received(:create_worktree)
        end

        context "with the handoff pack" do
          let(:handoff_auto) { false }
          let(:agent_kind) { "claude" }
          let(:handoff_config) { instance_double(Workspace::HandoffConfig, auto?: handoff_auto) }
          let(:main_agent) { instance_double(Workspace::MainAgent, kind: agent_kind) }
          let(:composer) do
            Workspace::InstructionComposer.new(library: library, lineage: Workspace::WorkspaceLineage.new, commands_config: Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
              pane_bindings: instance_double(Workspace::PaneBindings), notes_config: Workspace::NotesConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
              handoff_config: handoff_config, main_agent: main_agent)
          end
          let(:name) { "myproject.worktree-PROJ-123" }

          before { library.builtin_store.write("play", "handoff", "Run the check.\n") }

          it "sends nothing extra with no flag while handoff.auto is off" do
            packs_command.call("PROJ-123", json: true)

            expect(JSON.parse(output.string)["packs"].map { |row| row["name"] }).to eq(%w[notes])
          end

          context "when --handoff is given" do
            it "sends the pack as a required flag pack, bound with the others" do
              packs_command.call("PROJ-123", handoff: true)

              expect(launch_command).to have_received(:call).with(anything, hash_including(
                prompts: {name => a_string_including("## From pack handoff (built-in)")},
                bindings: {name => hash_including("packs" => %w[notes handoff])}
              ))
              expect(launch_command).to have_received(:call).with(anything, hash_not_including(:optional))
            end

            it "reports a flag row in --json" do
              allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}, delivered_panes: {name => "%4"}})

              packs_command.call("PROJ-123", handoff: true, json: true)

              expect(JSON.parse(output.string)["packs"]).to include({"name" => "handoff", "source" => "flag", "delivered" => true, "pane" => "%4"})
            end

            context "and the main agent is not Claude Code" do
              let(:agent_kind) { "opencode" }

              it "fails before anything is created, with handoff_unsupported_agent and details.kind" do
                result = packs_command.call("PROJ-123", handoff: true, json: true)

                expect(result).to eq({exit_code: 1})
                expect(JSON.parse(output.string)).to include("ok" => false, "code" => "handoff_unsupported_agent", "details" => {"kind" => "opencode"})
                expect(git).not_to have_received(:create_worktree)
                expect(project_config).not_to have_received(:create_worktree)
                expect(launch_command).not_to have_received(:call)
              end
            end
          end

          context "when handoff.auto is on" do
            let(:handoff_auto) { true }

            it "sends the pack from config, as an optional prompt with the notes pack" do
              packs_command.call("PROJ-123")

              expect(launch_command).to have_received(:call).with(anything, hash_including(optional: {name => %w[notes handoff]}))
            end

            it "leaves it out with --no-handoff" do
              packs_command.call("PROJ-123", handoff: false, json: true)

              expect(JSON.parse(output.string)["packs"].map { |row| row["name"] }).to eq(%w[notes])
            end

            context "and the main agent is not Claude Code" do
              let(:agent_kind) { "opencode" }

              it "still starts, skips the pack, reports why, and warns" do
                result = packs_command.call("PROJ-123", json: true)

                doc = JSON.parse(output.string)
                expect(result[:exit_code]).to eq(0)
                expect(doc["packs"]).to include({"name" => "handoff", "source" => "config", "delivered" => false, "pane" => nil, "reason" => "handoff_unsupported_agent"})
                expect(doc["warnings"]).to include(a_string_including("the handoff pack was not sent to #{project_name}", "opencode"))
                expect(launch_command).to have_received(:call).with(anything, hash_including(prompts: {name => notes_text.strip}))
              end

              it "prints the warning to stderr without --json" do
                packs_command.call("PROJ-123")

                expect(error_output.string).to include("Warning: the handoff pack was not sent to #{project_name}")
              end

              it "sends no prompt at all when the skipped pack was the only one" do
                allow(project_settings).to receive(:load).with(project_name).and_return({"notes" => {"instructions" => "false"}})
                allow(project_settings).to receive(:load).with(/-PROJ-123\z/).and_return({"notes" => {"instructions" => "false"}})
                packs_command.call("PROJ-123", json: true)

                expect(JSON.parse(output.string)["packs"]).to eq([{"name" => "handoff", "source" => "config", "delivered" => false, "pane" => nil, "reason" => "handoff_unsupported_agent"}])
                expect(launch_command).to have_received(:call).with(["myproject.worktree-PROJ-123"], prompts: {}, quiet: true)
              end
            end
          end
        end
      end

      it "fails an unknown play before creating anything" do
        expect { play_command.call("PROJ-123", plays: ["nope"]) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("unknown_library_entry")
        }
        expect(git).not_to have_received(:parse_start_input)
        expect(git).not_to have_received(:create_worktree)
        expect(project_config).not_to have_received(:create_worktree)
        expect(launch_command).not_to have_received(:call)
      end

      it "fails an unreadable play before creating anything, as a --json error" do
        library.global_store.link("play", "gone", File.join(tmpdir, "evicted.md"))

        result = play_command.call("PROJ-123", plays: ["gone"], json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "library_source_missing")
        expect(git).not_to have_received(:create_worktree)
        expect(launch_command).not_to have_received(:call)
      end
    end

    context "with agents and skills" do
      let(:library_dir) { File.join(tmpdir, "library") }
      let(:library) do
        Workspace::Library.new(config: instance_double(Workspace::Config, library_dir: library_dir, builtin_library_dir: File.join(library_dir, "builtin")),
          lineage: Workspace::WorkspaceLineage.new, project_config: project_config)
      end
      let(:installer) { instance_double(Workspace::LibraryInstaller) }
      let(:worktree_path) { File.join(tmpdir, ".worktrees", "PROJ-123") }
      let(:kit_command) do
        described_class.new(git: git, project_config: project_config, project_settings: project_settings,
          launch_command: launch_command, library: library, library_installer: installer,
          output: output, error_output: error_output, input: input)
      end

      def copied(ref, outcome = "copied")
        kind, name = ref.split("/")
        rel = (kind == "agent") ? ".claude/agents/#{name}.md" : ".claude/skills/#{name}"
        {"ref" => ref, "scope" => "global", "source" => library.global_store.path_for(kind, name),
         "path" => File.join(worktree_path, rel), "outcome" => outcome}
      end

      before do
        allow(git).to receive(:root).and_return(tmpdir)
        allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
        allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
        allow(git).to receive(:worktree_exists?).and_return(false)
        allow(git).to receive(:find_worktree_by_branch).and_return(nil)
        allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
        allow(git).to receive(:create_worktree)
        allow(project_config).to receive(:exists?).and_return(false)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-PROJ-123")
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})
        allow(installer).to receive(:relative_path).and_return(".claude/x")
        allow(installer).to receive(:copy) { |entry, worktree:, project:| copied(entry["ref"]) }
        library.global_store.write("agent", "reviewer", "You review.\n")
        library.global_store.write("agent", "planner", "You plan.\n")
        library.global_store.write("skill", "write-tests", "# Tests\n")
        library.global_store.write("play", "kickoff", "# Kickoff\n")
      end

      it "copies each entry into the worktree after its config is written and before launch" do
        expect(project_config).to receive(:create_worktree).ordered.and_return("myproject.worktree-PROJ-123")
        expect(installer).to receive(:copy).with(hash_including("ref" => "agent/reviewer"), worktree: worktree_path, project: kind_of(String)).ordered
          .and_return(copied("agent/reviewer"))
        expect(installer).to receive(:copy).with(hash_including("ref" => "agent/planner"), worktree: worktree_path, project: kind_of(String)).ordered
          .and_return(copied("agent/planner"))
        expect(installer).to receive(:copy).with(hash_including("ref" => "skill/write-tests"), worktree: worktree_path, project: kind_of(String)).ordered
          .and_return(copied("skill/write-tests"))
        expect(launch_command).to receive(:call).ordered.and_return({exit_code: 0, prompt_failures: {}})

        kit_command.call("PROJ-123", agents: ["reviewer", "agent/planner"], skills: ["write-tests"])

        expect(output.string).to include("Copied agent/reviewer to #{File.join(worktree_path, ".claude/agents/reviewer.md")}")
          .and include("Copied skill/write-tests to #{File.join(worktree_path, ".claude/skills/write-tests")}")
      end

      it "fails on a bad install directory before the worktree is created" do
        allow(installer).to receive(:relative_path).and_raise(Workspace::Error.new("bad", code: "invalid_library_install_dir"))

        expect { kit_command.call("PROJ-123", skills: ["write-tests"]) }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("invalid_library_install_dir") }
        expect(git).not_to have_received(:create_worktree)
      end

      it "copies a name given twice once" do
        kit_command.call("PROJ-123", agents: ["reviewer", "agent/reviewer"])

        expect(installer).to have_received(:copy).once
      end

      it "reports agents and skills in --json alongside the play, not inside it" do
        kit_command.call("PROJ-123", agents: ["reviewer"], skills: ["write-tests"], plays: ["kickoff"], json: true)

        payload = JSON.parse(output.string)
        expect(payload["agents"]).to eq([copied("agent/reviewer")])
        expect(payload["skills"]).to eq([copied("skill/write-tests")])
        expect(payload["play"].keys).not_to include("agents", "skills")
      end

      it "leaves agents and skills out of --json, and copies nothing, when none are asked for" do
        kit_command.call("PROJ-123", json: true)

        expect(JSON.parse(output.string).keys).not_to include("agents", "skills")
        expect(installer).not_to have_received(:copy)
      end

      it "warns, without failing, when the repo tracks the file" do
        allow(installer).to receive(:copy).and_return(copied("agent/reviewer", "skipped_tracked"))

        result = kit_command.call("PROJ-123", agents: ["reviewer"], json: true)

        payload = JSON.parse(output.string)
        expect(result).to eq({exit_code: 0})
        expect(payload["agents"].first["outcome"]).to eq("skipped_tracked")
        expect(payload["warnings"]).to include(a_string_matching(/kept the repo's tracked .*reviewer\.md; agent\/reviewer was not copied/))
      end

      it "notes a tracked file on stderr without --json" do
        allow(installer).to receive(:copy).and_return(copied("agent/reviewer", "skipped_tracked"))

        kit_command.call("PROJ-123", agents: ["reviewer"])

        expect(error_output.string).to match(/kept the repo's tracked .*reviewer\.md; agent\/reviewer was not copied/)
      end

      it "notes an entry it did not copy because the destination is under a symlinked directory" do
        allow(installer).to receive(:copy).and_return(copied("skill/write-tests", "skipped_linked"))

        kit_command.call("PROJ-123", skills: ["write-tests"], json: true)

        expect(JSON.parse(output.string)["warnings"])
          .to include(a_string_matching(/write-tests is under a symlinked directory.*skill\/write-tests was not copied/))
      end

      it "fails as a --json error, without launching, when git can't tell what is tracked" do
        allow(installer).to receive(:copy).and_raise(Workspace::Error, "Can't tell whether git tracks .claude/agents/reviewer.md")

        result = kit_command.call("PROJ-123", agents: ["reviewer"], json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("ok" => false, "error" => a_string_matching(/Can't tell whether git tracks/))
        expect(launch_command).not_to have_received(:call)
      end

      it "copies into an existing worktree too" do
        allow(git).to receive(:worktree_exists?).and_return(true)

        kit_command.call("PROJ-123", skills: ["write-tests"])

        expect(installer).to have_received(:copy).with(hash_including("ref" => "skill/write-tests"), worktree: worktree_path, project: kind_of(String))
        expect(git).not_to have_received(:create_worktree)
      end

      it "copies into an adopted worktree at its own path" do
        elsewhere = File.join(tmpdir, "elsewhere")
        allow(git).to receive(:find_worktree_by_branch).and_return(elsewhere)
        allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-elsewhere")

        kit_command.call("PROJ-123", agents: ["reviewer"])

        expect(installer).to have_received(:copy).with(hash_including("ref" => "agent/reviewer"), worktree: elsewhere, project: kind_of(String))
      end

      it "fails an unknown agent or skill before creating anything" do
        [{agents: ["nope"]}, {skills: ["nope"]}].each do |options|
          expect { kit_command.call("PROJ-123", **options) }.to raise_error(Workspace::Error) { |e|
            expect(e.code).to eq("unknown_library_entry")
          }
        end
        expect(git).not_to have_received(:parse_start_input)
        expect(project_config).not_to have_received(:create_worktree)
        expect(installer).not_to have_received(:copy)
        expect(launch_command).not_to have_received(:call)
      end

      it "fails an entry of the wrong kind as usage, and an unreadable skill as a --json error, before creating anything" do
        expect { kit_command.call("PROJ-123", skills: ["agent/reviewer"]) }
          .to raise_error(Workspace::UsageError, /--skill takes a skill/)
        library.global_store.link("skill", "gone", File.join(tmpdir, "evicted"))

        result = kit_command.call("PROJ-123", skills: ["gone"], json: true)

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "library_source_missing")
        expect(git).not_to have_received(:parse_start_input)
        expect(installer).not_to have_received(:copy)
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

      it "warns and still starts when the parent project config can't be parsed" do
        parent_name = Workspace::WorkspaceLineage.name_from_path(tmpdir)
        File.write(project_settings.project_config_path(parent_name), "a: [\n")

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

        expect(launch_command).to have_received(:call)
        expect(error_output.string).to include("Worktree hooks were not seeded")
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

      context "with a task store" do
        let(:task_store) { Workspace::TaskStore.new(dir: File.join(tmpdir, "tasks")) }
        let(:task_command) do
          described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, task_store: task_store, output: output, error_output: error_output, input: input)
        end

        before do
          allow(project_config).to receive(:settle_worktree_name).and_return("myproject.worktree-PROJ-123")
          allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})
        end

        it "records the task before the config is written, and passes its id and title through" do
          task_command.call("PROJ-123", json: true, title: "Fix login")

          task = task_store.active_for("myproject.worktree-PROJ-123")
          expect(task).to include("title" => "Fix login", "ref" => "PROJ-123", "branch" => "PROJ-123",
            "path" => File.join(tmpdir, ".worktrees", "PROJ-123"))
          expect(project_config).to have_received(:create_worktree)
            .with(Workspace::WorkspaceLineage.name_from_path(tmpdir), "PROJ-123", anything, "PROJ-123", quiet: true, task_id: task["id"])
          expect(JSON.parse(output.string)["task"]).to eq("id" => task["id"], "title" => "Fix login")
        end

        it "keeps the task of a workspace that is started again and updates its title" do
          first = task_command.call("PROJ-123", json: true, title: "A")
          output.truncate(0)
          task_command.call("PROJ-123", json: true, title: "B")

          expect(first).to eq(exit_code: 0)
          expect(Dir.glob(File.join(tmpdir, "tasks", "*.json")).size).to eq(1)
          expect(task_store.active_for("myproject.worktree-PROJ-123")["title"]).to eq("B")
        end

        it "treats a blank title as no title" do
          task_command.call("PROJ-123", json: true, title: "  ")

          expect(task_store.active_for("myproject.worktree-PROJ-123")["title"]).to be_nil
        end

        it "starts with no title when none is given" do
          task_command.call("PROJ-123", json: true)

          expect(task_store.active_for("myproject.worktree-PROJ-123")["title"]).to be_nil
          expect(JSON.parse(output.string)["task"]["title"]).to be_nil
        end
      end

      context "with --title-from-ticket and --slug" do
        let(:task_store) { Workspace::TaskStore.new(dir: File.join(tmpdir, "tasks")) }
        let(:fetched) { {"title" => "Fix the Login: redirect (v2)!", "body" => nil, "url" => nil} }
        let(:ticket_source) { instance_double(Workspace::TicketSource, fetch: fetched) }
        let(:ticket_command) do
          described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, task_store: task_store, ticket_source: ticket_source,
            output: output, error_output: error_output, input: input)
        end
        let(:payload) { JSON.parse(output.string) }

        before do
          allow(git).to receive(:sanitize_for_filesystem) { |name| name }
          allow(git).to receive(:branch_exists?).and_return(true)
          allow(git).to receive(:worktree_branches).and_return([])
          allow(project_config).to receive(:settle_worktree_name).and_return("myproject.worktree-PROJ-123")
          allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})
        end

        it "fills the task title from the ticket" do
          ticket_command.call("PROJ-123", json: true, title_from_ticket: true)

          expect(payload["task"]["title"]).to eq("Fix the Login: redirect (v2)!")
          expect(payload["branch"]).to eq("PROJ-123")
          expect(ticket_source).to have_received(:fetch).with(an_object_having_attributes(kind: "jira"), chdir: tmpdir)
        end

        it "keeps an explicit --title and reads no ticket for it" do
          ticket_command.call("PROJ-123", json: true, title_from_ticket: true, title: "Mine")

          expect(payload["task"]["title"]).to eq("Mine")
          expect(ticket_source).not_to have_received(:fetch)
        end

        it "puts the title's words in the branch of a JIRA ref with --slug, and fills the title" do
          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123-fix-the-login-redirect-v2")
          expect(payload["task"]["title"]).to eq("Fix the Login: redirect (v2)!")
          expect(git).to have_received(:create_worktree).with(File.join(tmpdir, ".worktrees", "PROJ-123-fix-the-login-redirect-v2"), "PROJ-123-fix-the-login-redirect-v2", base: nil, quiet: true)
        end

        it "slugs the --title it was given" do
          ticket_command.call("PROJ-123", json: true, slug: true, title: "Other words")

          expect(payload["branch"]).to eq("PROJ-123-other-words")
          expect(ticket_source).not_to have_received(:fetch)
        end

        it "slugs an issue ref's issue-<n> branch" do
          allow(git).to receive(:parse_start_input).with("https://github.com/o/r/issues/7")
            .and_return({type: :issue_url, value: "issue-7", repo: "o/r", number: "7"})

          ticket_command.call("https://github.com/o/r/issues/7", json: true, slug: true)

          expect(payload["branch"]).to eq("issue-7-fix-the-login-redirect-v2")
        end

        it "warns and keeps the plain branch and no title when the ticket cannot be read" do
          allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("`jira` is not installed.", code: "ticket_source_unavailable"))

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123")
          expect(payload["task"]["title"]).to be_nil
          expect(payload["warnings"]).to include(/Could not read the ticket's title \(ticket_source_unavailable\).*not installed/, /--slug left the branch as 'PROJ-123'/)
        end

        def reuse_worktree(*branches, path_of:)
          allow(git).to receive(:worktree_branches).and_return(branches)
          allow(git).to receive(:worktree_exists?).with(File.join(tmpdir, ".worktrees", path_of)).and_return(true)
        end

        it "reuses the worktree already made for the plain branch" do
          reuse_worktree("PROJ-123", path_of: "PROJ-123")

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123")
          expect(payload["created"]).to be(false)
        end

        it "reuses the worktree an earlier --slug run made, even when the ticket was retitled or cannot be read" do
          reuse_worktree("PROJ-123-old-title", "PROJ-1234-other", path_of: "PROJ-123-old-title")
          allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("`jira` did not answer in time.", code: "ticket_source_unavailable"))

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123-old-title")
          expect(payload["created"]).to be(false)
        end

        it "prefers the worktree of the slugged branch over the plain one" do
          reuse_worktree("PROJ-123", "PROJ-123-fix-the-login-redirect-v2", path_of: "PROJ-123-fix-the-login-redirect-v2")

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123-fix-the-login-redirect-v2")
        end

        it "does not mistake another ticket whose key starts the same for this one" do
          allow(git).to receive(:worktree_branches).and_return(["PROJ-1234-other"])

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123-fix-the-login-redirect-v2")
          expect(payload["created"]).to be(true)
        end

        it "strips control characters from a ticket title" do
          allow(ticket_source).to receive(:fetch).and_return({"title" => "Fix\u0000 it\e[31m now\n", "body" => nil, "url" => nil})

          ticket_command.call("PROJ-123", json: true, slug: true)

          expect(payload["task"]["title"]).to eq("Fix it [31m now")
          expect(payload["branch"]).to eq("PROJ-123-fix-it-31m-now")
        end

        it "warns when --slug is given and no ticket source is wired" do
          bare = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
            launch_command: launch_command, task_store: task_store, output: output, error_output: error_output, input: input)

          bare.call("PROJ-123", json: true, slug: true)

          expect(payload["branch"]).to eq("PROJ-123")
          expect(payload["warnings"]).to include(/--slug left the branch as 'PROJ-123'/)
        end

        it "fills the title of a pull request from gh without changing its branch" do
          allow(git).to receive(:parse_start_input).with("#9").and_return({type: :pr_url, value: "#9", repo: nil, number: "9"})
          allow(git).to receive(:local_branch_exists?).and_return(false)
          allow(git).to receive(:checkout_pr_worktree)
          allow(git).to receive(:drop_unresolved_upstream).and_return(false)

          ticket_command.call("#9", json: true, title_from_ticket: true)

          expect(payload["branch"]).to eq("pr-9")
          expect(payload["task"]["title"]).to eq("Fix the Login: redirect (v2)!")
          expect(payload["warnings"]).to be_nil
        end

        it "leaves a pull request's pr-<n> branch alone" do
          allow(git).to receive(:parse_start_input).with("#9").and_return({type: :pr_url, value: "#9", repo: nil, number: "9"})
          allow(git).to receive(:local_branch_exists?).and_return(false)
          allow(git).to receive(:checkout_pr_worktree)
          allow(git).to receive(:drop_unresolved_upstream).and_return(false)

          ticket_command.call("#9", json: true, slug: true)

          expect(payload["branch"]).to eq("pr-9")
          expect(payload["warnings"]).to include(/--slug left the branch as 'pr-9'/)
        end

        it "prints the warning on stderr outside --json" do
          allow(ticket_source).to receive(:fetch).and_raise(Workspace::Error.new("`jira` did not answer in time.", code: "ticket_source_unavailable"))

          ticket_command.call("PROJ-123", yes: true, title_from_ticket: true)

          expect(error_output.string).to include("Warning: Could not read the ticket's title")
        end
      end

      it "reports no task and passes no task id without a task store" do
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})

        command.call("PROJ-123", json: true)

        expect(JSON.parse(output.string)).not_to have_key("task")
        expect(project_config).to have_received(:create_worktree).with(Workspace::WorkspaceLineage.name_from_path(tmpdir), "PROJ-123", anything, "PROJ-123", quiet: true)
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
        expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => false, "code" => "error", "error" => "Not inside a git repository."})
      end

      it "never prompts, even when stdin is a TTY" do
        allow(input).to receive(:tty?).and_return(true)
        allow(launch_command).to receive(:call).and_return({exit_code: 0, prompt_failures: {}})

        command.call("PROJ-123", json: true)

        expect(output.string.lines.size).to eq(1)
      end
    end
  end

  describe "recording worktree_started" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }
    let(:task_store) { Workspace::TaskStore.new(dir: File.join(tmpdir, "tasks")) }
    let(:worktree_path) { File.join(tmpdir, ".worktrees", "feature") }

    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, task_store: task_store, event_log: event_log,
        output: output, error_output: error_output, input: input)
    end

    before do
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).and_return({type: :branch, value: "feature"})
      allow(git).to receive(:sanitize_for_filesystem).with("feature").and_return("feature")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("feature").and_return(true)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:settle_worktree_name).and_return("app.worktree-feature")
      allow(project_config).to receive(:create_worktree).and_return("app.worktree-feature")
      allow(launch_command).to receive(:call)
    end

    it "records the branch, parent project, created and task id, and no path or title" do
      command.call("feature", title: "Secret title", yes: true)

      event = event_log.events.fetch(0)
      expect(event).to include("type" => "worktree_started", "project" => "app.worktree-feature")
      expect(event["data"]).to eq("workspace" => "app.worktree-feature", "parent" => File.basename(tmpdir), "branch" => "feature", "created" => true,
        "task" => task_store.active_for("app.worktree-feature")["id"])
      expect(event.to_s).not_to include("Secret title")
      expect(event.to_s).not_to include(tmpdir + "/.worktrees")
    end

    it "records created false for a worktree that already exists" do
      allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)

      command.call("feature", yes: true)

      expect(event_log.events.map { |e| e["data"]["created"] }).to eq([false])
    end

    it "records created true and promoted true for a promoted worktree, and does not say it already exists" do
      allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)

      command.call("feature", yes: true, promoted: true)

      expect(event_log.events.map { |e| e["data"] }).to match([include("created" => true, "promoted" => true)])
      expect(output.string).not_to include("already exists")
      expect(git).not_to have_received(:create_worktree)
    end

    it "leaves promoted out of the event for an ordinary start" do
      command.call("feature", yes: true)

      expect(event_log.events.fetch(0)["data"]).not_to have_key("promoted")
    end

    it "starts in the given root instead of the working directory's repository" do
      other = File.join(tmpdir, "elsewhere")
      FileUtils.mkdir_p(other)
      allow(git).to receive(:root).and_return(nil)
      allow(git).to receive(:worktree_exists?).with(File.join(other, ".worktrees", "feature")).and_return(true)

      command.call("feature", yes: true, promoted: true, root: other)

      expect(event_log.events.fetch(0)["data"]).to include("parent" => "elsewhere", "branch" => "feature")
    end

    it "returns the JSON payload from #payload without printing it, and raises a failure" do
      allow(git).to receive(:worktree_exists?).with(worktree_path).and_return(true)

      result = command.payload("feature", no_launch: true, promoted: true, spine: false, root: tmpdir)

      expect(result[:exit_code]).to eq(0)
      expect(result[:json]).to include("ok" => true, "workspace" => "app.worktree-feature", "created" => true, "launched" => false)
      expect(output.string).to eq("")
      allow(git).to receive(:root).and_return(nil)
      expect { command.payload("feature") }.to raise_error(Workspace::Error, /Not inside a git repository/)
    end

    it "records the event before launching, so a launch failure still shows the worktree" do
      allow(launch_command).to receive(:call).and_raise(Workspace::Error, "no tmux")

      expect { command.call("feature", yes: true) }.to raise_error(Workspace::Error, "no tmux")

      expect(event_log.events.map { |e| e["type"] }).to eq(["worktree_started"])
    end

    it "records nothing when start stops before the worktree is configured" do
      allow(git).to receive(:root).and_return(nil)

      expect { command.call("feature", yes: true) }.to raise_error(Workspace::Error)

      expect(event_log.events).to be_empty
    end

    it "starts and launches when the log can't be written" do
      broken = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, event_log: CLITestHelpers.unwritable_event_log(tmpdir),
        output: output, error_output: error_output, input: input)

      broken.call("feature", yes: true)

      expect(launch_command).to have_received(:call)
    end
  end
  describe "notes directory" do
    let(:notes_setup) { double("notes_setup") }
    let(:setup_result) { {"dir" => "/notes/myproject.worktree-feature", "warnings" => []} }
    let(:calls) { [] }

    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, notes_setup: notes_setup, output: output, error_output: error_output, input: input)
    end

    before do
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).and_return({type: :branch, value: "feature"})
      allow(git).to receive(:sanitize_for_filesystem) { |name| name }
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).and_return(true)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:create_worktree).and_return("myproject.worktree-feature")
      allow(notes_setup).to receive(:call) { |name|
        calls << [:notes, name]
        setup_result
      }
      allow(launch_command).to receive(:call) {
        calls << :launch
        nil
      }
    end

    it "sets up the notes directory of the new workspace before launching it" do
      command.call("feature", yes: true)

      expect(notes_setup).to have_received(:call).with("myproject.worktree-feature")
      expect(calls).to eq([[:notes, "myproject.worktree-feature"], :launch])
    end

    it "sets it up for a worktree that already exists too" do
      allow(git).to receive(:worktree_exists?).and_return(true)

      command.call("feature", yes: true)

      expect(notes_setup).to have_received(:call).with("myproject.worktree-feature")
    end

    it "reports the directory as notes_dir under --json" do
      command.call("feature", yes: true, json: true)

      expect(JSON.parse(output.string)).to include("notes_dir" => "/notes/myproject.worktree-feature")
    end

    it "prints a setup warning on stderr, and starts anyway" do
      setup_result["warnings"] << "Warning: could not finish setting up the notes directory for x"

      command.call("feature", yes: true)

      expect(error_output.string).to include("Warning: could not finish setting up the notes directory for x")
      expect(launch_command).to have_received(:call)
    end

    it "puts a setup warning in warnings under --json and keeps the exit code 0" do
      setup_result["warnings"] << "Warning: could not finish setting up the notes directory for x"

      command.call("feature", yes: true, json: true)

      document = JSON.parse(output.string)
      expect(document["ok"]).to be true
      expect(document["warnings"]).to include("Warning: could not finish setting up the notes directory for x")
    end

    it "leaves notes_dir out when the directory could not be worked out" do
      setup_result.replace("dir" => nil, "warnings" => ["Warning: could not set up the notes directory for x: boom"])

      command.call("feature", yes: true, json: true)

      expect(JSON.parse(output.string)).not_to have_key("notes_dir")
    end

    it "sets nothing up and reports no notes_dir when no setup is wired" do
      bare = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, output: output, error_output: error_output, input: input)

      bare.call("feature", yes: true, json: true)

      expect(JSON.parse(output.string)).not_to have_key("notes_dir")
    end
  end
  describe "#call with --no-launch and --agent-kind" do
    let(:main_agent) { double("main_agent", kind: "claude") }
    let(:which) { ->(_exe) { true } }
    let(:name) { "myproject.worktree-PROJ-123" }
    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, main_agent: main_agent, which: which, output: output, error_output: error_output, input: input)
    end

    before do
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
      allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:create_worktree).and_return(name)
      allow(project_config).to receive(:check_agent_kind!)
      allow(launch_command).to receive(:call)
    end

    it "creates the worktree and config and launches nothing" do
      result = command.call("PROJ-123", no_launch: true)

      expect(git).to have_received(:create_worktree)
      expect(project_config).to have_received(:create_worktree)
      expect(launch_command).not_to have_received(:call)
      expect(result).to be_nil
      expect(output.string).to include("Not launching #{name}")
    end

    it "reports launched false, no packs and the agent kind in --json" do
      allow(main_agent).to receive(:kind).with(name).and_return("codex")

      result = command.call("PROJ-123", no_launch: true, json: true)

      expect(result).to eq({exit_code: 0})
      expect(JSON.parse(output.string)).to include("ok" => true, "launched" => false, "agent_kind" => "codex", "packs" => [], "workspace" => name)
    end

    it "reports launched true after a launch" do
      allow(launch_command).to receive(:call).and_return({exit_code: 0})

      command.call("PROJ-123", json: true)

      expect(JSON.parse(output.string)).to include("launched" => true, "agent_kind" => "claude")
    end

    it "reports launched false when the session did not start" do
      allow(launch_command).to receive(:call).and_return({exit_code: 1, start_failures: {name => "tmux died"}})

      command.call("PROJ-123", json: true)

      expect(JSON.parse(output.string)).to include("launched" => false)
    end

    {prompt: "hi", prompt_timeout: 5, plays: ["kickoff"], packs: %w[review], handoff: true}.each do |option, value|
      it "refuses --no-launch with #{option}, before anything is created" do
        result = command.call("PROJ-123", **{:no_launch => true, :json => true, option => value})

        expect(result).to eq({exit_code: 1})
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
        expect(git).not_to have_received(:create_worktree)
      end
    end

    it "accepts --no-launch with --no-packs and --no-handoff" do
      result = command.call("PROJ-123", no_launch: true, no_packs: true, handoff: false, json: true)

      expect(result).to eq({exit_code: 0})
    end

    it "passes the agent kind to the config" do
      command.call("PROJ-123", agent_kind: "Codex")

      expect(project_config).to have_received(:create_worktree).with(anything, anything, anything, anything, quiet: false, agent_kind: "codex")
    end

    it "fails an unknown kind before creating anything" do
      result = command.call("PROJ-123", agent_kind: "gemini", json: true)

      expect(result).to eq({exit_code: 1})
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => false, "code" => "unknown_agent_kind")
      expect(doc["details"]).to include("kind" => "gemini", "known" => include("claude", "codex"))
      expect(git).not_to have_received(:create_worktree)
    end

    it "fails before creating anything when the template cannot take the kind" do
      allow(project_config).to receive(:check_agent_kind!).and_raise(Workspace::Error.new("old", code: "template_outdated"))

      result = command.call("PROJ-123", agent_kind: "codex", json: true)

      expect(result).to eq({exit_code: 1})
      expect(JSON.parse(output.string)).to include("code" => "template_outdated")
      expect(git).not_to have_received(:create_worktree)
    end

    it "warns when an existing config kept a different kind" do
      command.call("PROJ-123", agent_kind: "codex", no_launch: true, json: true)

      expect(JSON.parse(output.string)["warnings"].join).to match(/--agent-kind codex was not applied.*runs claude/)
    end

    it "warns when the agent is not on PATH" do
      allow(main_agent).to receive(:kind).and_return("codex")
      missing = described_class.new(git: git, project_config: project_config, project_settings: project_settings,
        launch_command: launch_command, main_agent: main_agent, which: ->(_) { false }, output: output, error_output: error_output, input: input)

      missing.call("PROJ-123", agent_kind: "codex", no_launch: true, json: true)

      expect(JSON.parse(output.string)["warnings"].join).to include("codex is not on your PATH")
    end

    context "with agent.kind and agent.commands" do
      let(:agent_commands) { instance_double(Workspace::AgentCommands, kind: "codex") }
      let(:which_seen) { [] }
      subject(:command) do
        described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command,
          main_agent: main_agent, agent_commands: agent_commands, which: ->(program) { which_seen << program && false }, output: output, error_output: error_output, input: input)
      end

      before do
        allow(agent_commands).to receive(:command_for) { |_workspace, kind| kind }
        allow(main_agent).to receive(:kind).and_return("codex")
      end

      it "uses agent.kind, resolved for the parent project, when no flag is given" do
        command.call("PROJ-123", no_launch: true, json: true)

        expect(agent_commands).to have_received(:kind).with(File.basename(tmpdir).downcase)
        expect(project_config).to have_received(:check_agent_kind!).with("codex")
        expect(project_config).to have_received(:create_worktree).with(anything, anything, anything, anything, quiet: true)
        expect(JSON.parse(output.string)).to include("agent_kind" => "codex")
      end

      it "lets the flag win over agent.kind" do
        allow(main_agent).to receive(:kind).and_return("claude")

        command.call("PROJ-123", agent_kind: "claude", no_launch: true, json: true)

        expect(project_config).to have_received(:create_worktree).with(anything, anything, anything, anything, quiet: true, agent_kind: "claude")
        expect(JSON.parse(output.string)).to include("agent_kind" => "claude")
      end

      it "checks the configured command's program on PATH" do
        allow(agent_commands).to receive(:command_for).with(name, "codex").and_return("FOO=1 /opt/bin/codex-dev --yolo")

        command.call("PROJ-123", no_launch: true, json: true)

        expect(which_seen).to eq(["codex-dev"])
        expect(JSON.parse(output.string)["warnings"].join).to include("codex-dev is not on your PATH")
      end

      it "does not check PATH when the existing config runs a different kind" do
        allow(main_agent).to receive(:kind).and_return("claude")

        command.call("PROJ-123", no_launch: true, json: true)

        expect(which_seen).to be_empty
        expect(JSON.parse(output.string)["warnings"].to_a.join).not_to include("PATH")
      end

      it "checks a configured claude command on PATH" do
        allow(agent_commands).to receive(:kind).and_return("claude")
        allow(main_agent).to receive(:kind).and_return("claude")
        allow(agent_commands).to receive(:command_for).with(name, "claude").and_return("claude-dev --x")

        command.call("PROJ-123", no_launch: true, json: true)

        expect(which_seen).to eq(["claude-dev"])
      end
    end
  end

  describe "#call with --spine, --no-spine and spine.auto" do
    let(:name) { "myproject.worktree-PROJ-123" }
    let(:library) { double("library") }
    let(:spine_exists) { [false] }
    let(:composer) { double("composer") }
    let(:spine_init) { double("spine_init") }
    let(:auto) { false }
    let(:spine_config) { double("spine_config", auto?: auto, template: {"name" => "default", "source" => "default"}) }
    let(:init_answer) { {"outcome" => "created", "dir" => "/n/spine", "files" => ["a.md"], "template" => {"name" => "default", "scope" => "builtin", "source" => "default"}} }
    let(:events) { [] }
    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command,
        library: library, instruction_composer: composer, spine_init: spine_init, spine_config: spine_config,
        output: output, error_output: error_output, input: input)
    end

    before do
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
      allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:create_worktree).and_return(name)
      allow(launch_command).to receive(:call)
      allow(library).to receive(:play_prompt) { |_play, prompt, packs:| [packs, prompt].compact.join("\n\n") }
      allow(library).to receive(:packs_binding) { |names| {"kind" => "play", "id" => "play/#{names.first}", "packs" => names} }
      allow(composer).to receive(:compose_start) do |cwd:, **|
        events << [:compose, cwd]
        if spine_exists.first
          {"packs" => [{"ref" => "play/spine", "source" => "config"}], "text" => "SPINE PACK", "skipped" => []}
        else
          {"packs" => [], "text" => nil, "skipped" => []}
        end
      end
      allow(spine_init).to receive(:call) do |**args|
        events << [:init, args]
        spine_exists[0] = true
        init_answer
      end
    end

    it "runs init after the worktree exists and before the first prompt is composed, so the spine pack is sent" do
      command.call("PROJ-123", spine: true, json: true)

      expect(events.map(&:first)).to eq(%i[compose init compose])
      expect(events.last.last).to eq(File.join(tmpdir, ".worktrees", "PROJ-123"))
      expect(spine_init).to have_received(:call).with(name: name, template: nil, print: false)
      expect(launch_command).to have_received(:call).with([name], hash_including(prompts: {name => "SPINE PACK"}))
      payload = JSON.parse(output.string)
      expect(payload["spine"]).to eq("outcome" => "created", "template" => init_answer["template"])
      expect(payload["packs"].map { |p| p["name"] }).to eq(["spine"])
    end

    it "passes --spine=NAME as the template" do
      command.call("PROJ-123", spine: "team", json: true)

      expect(spine_init).to have_received(:call).with(name: name, template: "team", print: false)
    end

    it "runs on spine.auto, and --no-spine skips it even then" do
      auto_command = described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command,
        library: library, instruction_composer: composer, spine_init: spine_init, spine_config: double("c", auto?: true), output: output, error_output: error_output, input: input)

      auto_command.call("PROJ-123", json: true)
      expect(spine_init).to have_received(:call).once
      expect(JSON.parse(output.string)).to include("spine")

      output.truncate(0)
      output.rewind
      auto_command.call("PROJ-123", spine: false, json: true)
      expect(spine_init).to have_received(:call).once
      expect(JSON.parse(output.string)).not_to include("spine")
    end

    it "does nothing and reports no spine key without a flag or spine.auto" do
      command.call("PROJ-123", json: true)

      expect(spine_init).not_to have_received(:call)
      expect(JSON.parse(output.string)).not_to include("spine")
    end

    it "makes a failed init a warning: start goes on, the prompt is still sent and --json says failed" do
      allow(spine_init).to receive(:call).and_raise(Workspace::Error.new("No spine template 'gone'.", code: "unknown_template"))

      result = command.call("PROJ-123", spine: "gone", json: true)

      expect(result).to eq({exit_code: 0})
      payload = JSON.parse(output.string)
      expect(payload["spine"]).to eq("outcome" => "failed", "template" => {"name" => "gone", "source" => "flag"}, "error" => "unknown_template")
      expect(payload["warnings"].join).to include("Could not set up the spine: No spine template 'gone'")
      expect(launch_command).to have_received(:call)
    end

    it "warns on stderr and prints one line on stdout in plain mode" do
      command.call("PROJ-123", spine: true)
      expect(output.string).to include("Spine created: /n/spine (template default)")

      allow(spine_init).to receive(:call).and_raise(Workspace::Error.new("boom"))
      command.call("PROJ-123", spine: true)
      expect(error_output.string).to include("Warning: Could not set up the spine: boom")
    end

    it "still runs init with --no-launch, sends no prompt and reports it in --json" do
      result = command.call("PROJ-123", spine: true, no_launch: true, json: true)

      expect(result).to eq({exit_code: 0})
      expect(spine_init).to have_received(:call)
      expect(launch_command).not_to have_received(:call)
      expect(JSON.parse(output.string)).to include("spine" => hash_including("outcome" => "created"), "packs" => [])
    end

    it "keeps the first packs and warns when composing them again fails" do
      calls = 0
      allow(composer).to receive(:compose_start) do |**|
        calls += 1
        raise Workspace::Error, "unreadable" if calls > 1
        {"packs" => [], "text" => nil, "skipped" => []}
      end

      result = command.call("PROJ-123", spine: true, json: true)

      expect(result).to eq({exit_code: 0})
      expect(JSON.parse(output.string)["warnings"].join).to include("Could not compose the packs again", "unreadable")
    end

    it "refuses --spine when no spine init command was wired" do
      bare = described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, error_output: error_output, input: input)

      expect { bare.call("PROJ-123", spine: true) }.to raise_error(Workspace::Error, /--spine is not available/)
    end
  end

  describe "#call with --plan" do
    let(:name) { "myproject.worktree-PROJ-123" }
    let(:plan_play) { {"ref" => "play/implementation-plan", "path" => "/lib/play/implementation-plan.md"} }
    let(:library) { double("library", pack: [plan_play, "body"]) }
    let(:plan_command) { double("plan_command") }
    let(:plan_file) { File.join(tmpdir, "IMPLEMENTATION_PLAN.md") }
    let(:plan_text) { "---\nplan: 1\ntitle: \"Add SSO\"\nstatus: active\n---\n\n## Tasks\n" }
    subject(:command) do
      described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command,
        library: library, plan_command: plan_command, output: output, error_output: error_output, input: input)
    end

    before do
      allow(git).to receive(:root).and_return(tmpdir)
      allow(git).to receive(:parse_start_input).with("PROJ-123").and_return({type: :jira_key, value: "PROJ-123"})
      allow(git).to receive(:sanitize_for_filesystem).with("PROJ-123").and_return("PROJ-123")
      allow(git).to receive(:worktree_exists?).and_return(false)
      allow(git).to receive(:find_worktree_by_branch).and_return(nil)
      allow(git).to receive(:branch_exists?).with("PROJ-123").and_return(true)
      allow(git).to receive(:create_worktree)
      allow(project_config).to receive(:create_worktree).and_return(name)
      allow(launch_command).to receive(:call)
      allow(library).to receive(:play_prompt) { |plays, prompt, packs: nil| ["Read \"#{plays.first["path"]}\"", packs, prompt].compact.join("\n\n") }
      allow(library).to receive(:play_binding) { |plays, packs: []| {"kind" => "play", "id" => plays.first["ref"]} }
      allow(plan_command).to receive(:init) do |**|
        File.write(plan_file, plan_text)
        {"path" => plan_file, "message" => nil}
      end
    end

    let(:draft) { Workspace::Commands::PlanDispatch::DRAFT_PROMPT }

    it "runs plan init quietly, sends the play with the draft line, binds the pane to the play and reports plan beside play" do
      command.call("PROJ-123", plan: true, json: true)

      expect(plan_command).to have_received(:init).with(name: name, title: nil, print: false)
      expect(launch_command).to have_received(:call).with([name],
        hash_including(prompts: {name => "Read \"/lib/play/implementation-plan.md\"\n\n#{draft}"}, bindings: {name => {"kind" => "play", "id" => "play/implementation-plan"}}))
      payload = JSON.parse(output.string)
      expect(payload["plan"]).to eq("path" => plan_file, "outcome" => "created", "title" => "Add SSO", "drafting" => true)
      expect(payload["play"]).to include("ref" => "play/implementation-plan", "delivered" => false)
    end

    it "passes --plan=TITLE to plan init" do
      command.call("PROJ-123", plan: "Add SSO", json: true)

      expect(plan_command).to have_received(:init).with(name: name, title: "Add SSO", print: false)
    end

    it "sends --prompt after the draft line as the goal" do
      command.call("PROJ-123", plan: true, prompt: "Add SSO login", json: true)

      expect(launch_command).to have_received(:call).with([name],
        hash_including(prompts: {name => "Read \"/lib/play/implementation-plan.md\"\n\n#{draft}\n\nThe goal: Add SSO login"}))
    end

    it "keeps a plan that is already there and sends the play with the prompt alone when it has tasks" do
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("There is already a plan.", code: "plan_exists", details: {"path" => plan_file}))
      File.write(plan_file, plan_text + "- [ ] T1 First\n")

      command.call("PROJ-123", plan: true, prompt: "Go", json: true)

      expect(JSON.parse(output.string)["plan"]).to include("outcome" => "exists", "drafting" => false)
      expect(launch_command).to have_received(:call).with([name], hash_including(prompts: {name => "Read \"/lib/play/implementation-plan.md\"\n\nGo"}))
    end

    it "asks for a draft when the plan that is already there has no tasks" do
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("There is already a plan.", code: "plan_exists", details: {"path" => plan_file}))
      File.write(plan_file, plan_text)

      command.call("PROJ-123", plan: true, json: true)

      expect(JSON.parse(output.string)["plan"]).to include("outcome" => "exists", "drafting" => true)
    end

    it "makes the plan and sends nothing with --no-launch" do
      result = command.call("PROJ-123", plan: true, no_launch: true, json: true)

      expect(result).to eq({exit_code: 0})
      expect(launch_command).not_to have_received(:call)
      expect(JSON.parse(output.string)["plan"]).to eq("path" => plan_file, "outcome" => "created", "title" => "Add SSO", "drafting" => false)
    end

    it "makes a failed init a warning, with no play sent and plan reported as failed" do
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("Can't write.", code: "notes_dir_unwritable"))

      result = command.call("PROJ-123", plan: true, prompt: "Go", json: true)

      expect(result).to eq({exit_code: 0})
      payload = JSON.parse(output.string)
      expect(payload["plan"]).to eq("path" => nil, "outcome" => "failed", "error" => "notes_dir_unwritable", "drafting" => false)
      expect(payload["warnings"].join).to include("Could not make the plan: Can't write.", "workspace plan init")
      expect(payload).not_to include("play")
      expect(launch_command).to have_received(:call).with([name], hash_including(prompts: {name => "Go"}))
    end

    it "refuses a ref with a space: --plan took the title as the ref" do
      expect { command.call("Add SSO", plan: true) }.to raise_error(Workspace::UsageError, /--plan=/)
      expect(git).not_to have_received(:create_worktree)
    end

    it "says nothing was sent with --no-launch, and that a plan with tasks is not redrafted" do
      command.call("PROJ-123", plan: true, no_launch: true)
      expect(output.string).to include("nothing sent: run `workspace plan start`")

      output.truncate(0)
      File.write(plan_file, plan_text + "- [ ] T1 First\n")
      allow(plan_command).to receive(:init).and_raise(Workspace::Error.new("exists", code: "plan_exists", details: {"path" => plan_file}))
      command.call("PROJ-123", plan: true)
      expect(output.string).to include("not asked to redraft")
    end

    it "leaves title out of the plan object when the plan has none" do
      File.write(plan_file, "---\nplan: 1\nstatus: active\n---\n\n## Tasks\n")
      allow(plan_command).to receive(:init).and_return({"path" => plan_file})
      command.call("PROJ-123", plan: true, json: true)
      expect(JSON.parse(output.string)["plan"]).not_to include("title")
    end

    it "refuses --play with --plan before anything is created" do
      expect { command.call("PROJ-123", plan: true, plays: ["kickoff"]) }.to raise_error(Workspace::UsageError, /--plan sends the implementation-plan play/)
      expect(git).not_to have_received(:create_worktree)
    end

    it "refuses --plan when no plan command was wired" do
      bare = described_class.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command,
        library: library, output: output, error_output: error_output, input: input)

      expect { bare.call("PROJ-123", plan: true) }.to raise_error(Workspace::Error, /--plan is not available/)
    end

    it "prints one plain line and leaves plan out of --json when not asked" do
      command.call("PROJ-123", plan: true)
      expect(output.string).to include("Plan created: #{plan_file}")

      output.truncate(0)
      output.rewind
      command.call("PROJ-123", json: true)
      expect(JSON.parse(output.string)).not_to include("plan")
    end
  end
end
