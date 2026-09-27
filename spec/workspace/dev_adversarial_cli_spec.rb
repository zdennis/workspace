require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"

# Adversarial coverage for PR2 (dev environment lock, `workspace parent`,
# `workspace config set|get|unset`). Each `it` pins one confirmed defect.
# These specs are expected to FAIL until the defect is fixed.
RSpec.describe "PR2 adversarial findings" do
  around do |example|
    Dir.mktmpdir("ws-adversarial-state") do |state_dir|
      Dir.mktmpdir("ws-adversarial-config") do |config_dir|
        old_state, old_config = ENV["XDG_STATE_HOME"], ENV["XDG_CONFIG_HOME"]
        ENV["XDG_STATE_HOME"] = state_dir
        ENV["XDG_CONFIG_HOME"] = config_dir
        example.run
        ENV["XDG_STATE_HOME"] = old_state
        ENV["XDG_CONFIG_HOME"] = old_config
      end
    end
  end

  def git_repo(dir)
    Dir.chdir(dir) do
      system("git", "init", "-q", chdir: dir, out: File::NULL, err: File::NULL)
      system("git", "-c", "user.email=a@a", "-c", "user.name=a", "commit", "-q", "--allow-empty", "-m", "init",
        chdir: dir, out: File::NULL, err: File::NULL)
    end
  end

  # --- D-U1: submodule misnamed as its .git/modules directory -------------
  describe "WorkspaceLineage on a git submodule (D-U1)" do
    it "does not derive the project name from the .git/modules directory" do
      Dir.mktmpdir("ws-submodule") do |root|
        outer = File.join(root, "outer")
        sub = File.join(root, "sub")
        FileUtils.mkdir_p(outer)
        FileUtils.mkdir_p(sub)
        git_repo(outer)
        git_repo(sub)

        system("git", "-c", "protocol.file.allow=always", "-C", outer, "submodule", "add", "-q",
          "../sub", "subdir", out: File::NULL, err: File::NULL)

        info = Workspace::WorkspaceLineage.new.resolve(cwd: File.join(outer, "subdir"))

        # D-U1: name comes out as "modules" (the basename of .git/modules),
        # not "subdir" (the submodule's own directory) or "outer" (the
        # superproject). This silently misdirects `dev`, `config set`, and
        # `parent` for any repo using submodules.
        expect(info.name).to eq("subdir"),
          "expected the submodule's own directory name, got #{info.name.inspect} " \
          "(lib/workspace/workspace_lineage.rb derives the name from File.dirname(git_common_dir), " \
          "which for a submodule is `<repo>/.git/modules`, not the submodule's worktree)"
      end
    end
  end

  # --- D-U2: stale .workspace-project marker overrides git ground truth ---
  describe "WorkspaceLineage with a stale .workspace-project marker (D-U2)" do
    it "does not report is_worktree when git itself says this is not a worktree" do
      Dir.mktmpdir("ws-stale-marker") do |root|
        repo = File.join(root, "plain-repo")
        FileUtils.mkdir_p(repo)
        git_repo(repo)
        # Simulate a marker left over from a copy/rename/promote of what used
        # to be a worktree — git-common-dir now equals git-dir here, so this
        # is, by git's own account, a normal standalone checkout.
        File.write(File.join(repo, ".workspace-project"), "someparent.worktree-orphan")

        info = Workspace::WorkspaceLineage.new.resolve(cwd: repo)

        # D-U2: the marker is trusted unconditionally, even though
        # `worktree?` (comparing --git-dir with --git-common-dir) says this
        # is not a worktree. Every consumer (dev, config set, parent,
        # LockNamespace) is misdirected to a parent project ("someparent")
        # that may not even exist.
        expect(info.is_worktree).to eq(false),
          "expected is_worktree to follow git's own --git-dir/--git-common-dir comparison, " \
          "but the stale .workspace-project marker overrides it unconditionally " \
          "(lib/workspace/workspace_lineage.rb#resolve)"
      end
    end
  end

  # --- D-U3: dev.up = "" bypasses the "no dev command configured" guard ---
  describe "Commands::Dev#run with dev.up set to an empty string (D-U3)" do
    it "raises the no-dev-command error instead of running an empty command" do
      Dir.mktmpdir("ws-empty-devup") do |worktree|
        git_repo(worktree)
        Dir.mktmpdir("ws-empty-devup-locks") do |lock_dir|
          store = Struct.new(:data) { def load(_name) = data }.new({"dev" => {"up" => ""}})
          dev_config = Workspace::DevConfig.new(project_settings: store)
          lock_namespace = Struct.new(:dir) { def resolve(cwd:) = {dir: dir} }.new(lock_dir)
          liveness = Workspace::LockHolder.new
          runner_calls = []
          fake_runner = Object.new
          fake_runner.define_singleton_method(:call) { |**kw|
            runner_calls << kw
            0
          }

          dev = Workspace::Commands::Dev.new(
            lock_namespace: lock_namespace, lock_holder: liveness, lineage: Workspace::WorkspaceLineage.new,
            dev_config: dev_config, dev_runner: fake_runner, terminator: nil, tmux: nil, executable: "unused"
          )

          # D-U3: `ctx[:settings][:up]` is the empty string, which is
          # truthy in Ruby, so `raise ... unless ctx[:settings][:up]`
          # (lib/workspace/commands/dev.rb) never fires. The dev runner is
          # invoked with an empty command instead of surfacing
          # Commands::Dev::NO_COMMAND.
          expect { dev.run(working_dir: worktree) }.to raise_error(Workspace::Error, /No dev command configured/)
          expect(runner_calls).to be_empty
        end
      end
    end
  end

  # --- D-U4: `config set/get/unset` silently swallow trailing arguments ---
  describe "CLI `workspace config set|get|unset` with trailing extra arguments (D-U4)" do
    def build_cli(project_settings:, output:, error_output:, working_dir:)
      lineage = Workspace::WorkspaceLineage.new
      file_backup = Workspace::FileBackup.new(output: output)
      config_command = Workspace::Commands::Config.new(
        project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output
      )
      exit_handler = FakeExitHandler
      placeholder = Object.new

      Workspace::CLI.new(
        config: placeholder, state: placeholder, project_config: placeholder, git: placeholder,
        window_manager: placeholder, doctor: placeholder, project_settings: project_settings,
        hook_runner: placeholder, project_detector: placeholder, launch_command: placeholder,
        kill_command: placeholder, finish_command: placeholder, start_command: placeholder, stop_command: placeholder,
        focus_command: placeholder, tile_command: placeholder, layout_command: placeholder,
        resize_command: placeholder, init_command: placeholder, repair_command: placeholder,
        cleanup_command: placeholder, prune_command: placeholder, claude_command: placeholder,
        lookup_command: placeholder, update_pane_command: placeholder, run_command: placeholder,
        run_result_store: placeholder, run_and_report_command: placeholder, capture_command: placeholder,
        lock_command: placeholder, dev_command: placeholder, parent_command: placeholder,
        agent_command: placeholder, sessions_command: placeholder, session_event_command: placeholder,
        config_command: config_command, statusline_command: CLITestHelpers::FakeStatuslineCommand.new,
        ask_command: CLITestHelpers::FakeAskCommand.new,
        exit_handler: exit_handler, output: output, error_output: error_output,
        working_dir: working_dir
      )
    end

    it "rejects trailing args on `config set` instead of silently ignoring them" do
      Dir.mktmpdir("ws-config-cli-set") do |config_root|
        Dir.mktmpdir("ws-config-cli-project") do |project_dir|
          fake_path_config = Struct.new(:workspace_config_dir).new(config_root)
          project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
          output = StringIO.new
          error_output = StringIO.new
          cli = build_cli(project_settings: project_settings, output: output,
            error_output: error_output, working_dir: project_dir)

          # `dev up`/`down`/`status` all raise UsageError on leftover argv
          # (`raise UsageError, parser.help if args.any?`); config set/get/
          # unset never make that check, so a stray extra word after the
          # value is silently dropped instead of failing loudly.
          expect { cli.run(["config", "set", "dev.up", "./start-dev", "extra-arg"]) }
            .to raise_error(FakeSystemExit)
          expect(error_output.string).not_to be_empty
        end
      end
    end

    it "rejects trailing args on `config get` instead of silently ignoring them" do
      Dir.mktmpdir("ws-config-cli-get") do |config_root|
        Dir.mktmpdir("ws-config-cli-project") do |project_dir|
          fake_path_config = Struct.new(:workspace_config_dir).new(config_root)
          project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
          project_settings.save(File.basename(project_dir), {"dev" => {"up" => "bin/dev"}})
          output = StringIO.new
          error_output = StringIO.new
          cli = build_cli(project_settings: project_settings, output: output,
            error_output: error_output, working_dir: project_dir)

          expect { cli.run(["config", "get", "dev.up", "extra-arg"]) }
            .to raise_error(FakeSystemExit)
          expect(error_output.string).not_to be_empty
        end
      end
    end
  end
end
