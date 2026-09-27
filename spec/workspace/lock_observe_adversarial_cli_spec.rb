require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

# Adversarial CLI/UX coverage for PR5 (lock observability: audit log,
# `--json` on `lock status`/`dev status`, and the `sessions` LOCK column).
# Each example is tagged with a finding id (OU1, OU2, ...).
RSpec.describe "workspace lock observability adversarial findings" do
  describe "--json contract at the CLI dispatch layer (OU1)" do
    # Minimal-but-real CLI: every collaborator besides lock_command is a
    # CLITestHelpers fake/double (as in cli_spec.rb's build_test_cli), but
    # lock_command is the real Workspace::Commands::Lock so validate_name!
    # and OptionParser actually run.
    def build_lock_cli(output:, error_output:, tmpdir:)
      config = Workspace::Config.new
      state = CLITestHelpers::FakeState.new
      window_manager = CLITestHelpers::FakeWindowManager.new
      tmux = CLITestHelpers::FakeTmux.new
      project_config = CLITestHelpers::FakeProjectConfig.new
      doctor = CLITestHelpers::FakeDoctor.new
      project_settings = CLITestHelpers::FakeProjectSettings.new
      hook_runner = CLITestHelpers::FakeHookRunner.new
      iterm = CLITestHelpers::FakeITerm.new
      window_layout = CLITestHelpers::FakeWindowLayout.new
      git = Workspace::Git.new(output: output, input: StringIO.new)
      project_detector = Workspace::ProjectDetector.new(state: state, project_config: project_config)

      stop_command = Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
      launch_command = Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
      start_command = Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: StringIO.new)
      kill_command = Workspace::Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: StringIO.new)
      focus_command = Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
      tile_command = Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
      layout_command = Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
      resize_command = Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
      sessions_command = Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output)
      session_event_command = Workspace::Commands::SessionEvent.new(config: config, tmux: tmux, input: StringIO.new, env: {})
      hook_installer = Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: output), output: output, input: StringIO.new)
      init_command = Workspace::Commands::Init.new(config: config, hook_installer: hook_installer, which: ->(_exe) { false }, output: output, error_output: error_output, input: StringIO.new)
      cleanup_command = Workspace::Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: StringIO.new)
      prune_command = Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: instance_double(Workspace::Commands::Stop), output: output, input: StringIO.new)
      lookup_command = Workspace::Commands::Lookup.new(project_config: project_config, output: output)

      lock_namespace = instance_double(Workspace::LockNamespace,
        resolve: {key: "ns", display: "app", dir: tmpdir})
      lock_command = Workspace::Commands::Lock.new(
        config: config,
        lock_namespace: lock_namespace,
        lock_holder: FakeLockIdentity.new(pid: 100),
        output: output,
        error_output: error_output
      )

      Workspace::CLI.new(
        config: config, state: state, project_config: project_config, git: git,
        window_manager: window_manager, doctor: doctor, project_settings: project_settings,
        hook_runner: hook_runner, project_detector: project_detector,
        launch_command: launch_command, kill_command: kill_command, start_command: start_command,
        stop_command: stop_command, focus_command: focus_command, tile_command: tile_command,
        layout_command: layout_command, resize_command: resize_command, init_command: init_command,
        repair_command: CLITestHelpers::FakeRepairCommand.new, cleanup_command: cleanup_command,
        prune_command: prune_command, claude_command: CLITestHelpers::FakeClaudeCommand.new,
        lookup_command: lookup_command, update_pane_command: CLITestHelpers::FakeUpdatePaneCommand.new,
        run_command: CLITestHelpers::FakeRunCommand.new, run_result_store: CLITestHelpers::FakeRunResultStore.new,
        run_and_report_command: CLITestHelpers::FakeRunAndReportCommand.new,
        capture_command: CLITestHelpers::FakeCaptureCommand.new,
        lock_command: lock_command, dev_command: CLITestHelpers::FakeDevCommand.new,
        parent_command: CLITestHelpers::FakeParentCommand.new, agent_command: CLITestHelpers::FakeAgentCommand.new,
        sessions_command: sessions_command, session_event_command: session_event_command,
        config_command: CLITestHelpers::FakeConfigCommand.new,
        logger: Workspace::Logger.new(output: error_output), output: output, error_output: error_output,
        exit_handler: FakeExitHandler, input: StringIO.new, working_dir: Dir.tmpdir
      )
    end

    it "OU1: `lock status --json` with an invalid lock name prints a plain-text UsageError instead of the documented JSON error object" do
      tmpdir = Dir.mktmpdir("ws-lock-observe")
      output = StringIO.new
      error_output = StringIO.new
      cli = build_lock_cli(output: output, error_output: error_output, tmpdir: tmpdir)

      expect { cli.run(["lock", "status", "bad name!", "--json"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      # The documented --json contract (docs/README.lock.md, Lock#status_json)
      # promises stdout always carries a {"schema_version":...} JSON object,
      # even on error. Name validation happens before the json: true branch
      # is reached, so it instead raises Workspace::UsageError, which
      # CLI#run's top-level rescue prints as plain text to stderr and never
      # touches stdout at all -- violating the contract this asserts.
      parsed = JSON.parse(output.string)
      expect(parsed).to include("schema_version" => 1, "error" => a_string_matching(/invalid lock name/))
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir)
    end

    it "OU1b: `lock status --json --bogus-flag` should exit cleanly (like every other bad-usage path), not crash with an uncaught OptionParser::InvalidOption" do
      tmpdir = Dir.mktmpdir("ws-lock-observe")
      output = StringIO.new
      error_output = StringIO.new
      cli = build_lock_cli(output: output, error_output: error_output, tmpdir: tmpdir)

      # CLI#run's top-level rescue only catches OptionParser::InvalidArgument
      # and OptionParser::MissingArgument (lib/workspace/cli.rb:190), not the
      # OptionParser::InvalidOption an unrecognized flag like --bogus-flag
      # raises. Every other malformed invocation in this codebase (bad
      # argument, missing argument, unknown subcommand) exits cleanly via
      # @exit_handler with a message on stderr; an unknown flag instead
      # propagates out of CLI#run as a raw, uncaught Ruby exception -- a
      # crash with a backtrace on the user's terminal, --json or not.
      expect { cli.run(["lock", "status", "--json", "--bogus-flag"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir && File.directory?(tmpdir)
    end
  end

  describe "sessions LOCK column namespace resolution (OU2)" do
    it "OU2: resolves the lock namespace from the command process's Dir.pwd, not the named workspace, so the LOCK column can show another project's lock state" do
      state_home = Dir.mktmpdir("ws-sessions-xdg-state")
      allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", anything).and_return(state_home)

      lock_namespace = Workspace::LockNamespace.new(config: Workspace::Config.new)
      lock_holder = FakeLockIdentity.new(pid: 100)

      other_project_dir = Dir.mktmpdir("ws-sessions-other-project")
      cwd_project_dir = Dir.mktmpdir("ws-sessions-cwd-project")

      # Hold the "edit" lock in the *cwd* project's namespace, not in the
      # project actually named on the command line.
      begin
        Dir.chdir(cwd_project_dir) do
          namespace = lock_namespace.resolve(cwd: cwd_project_dir)
          store = Workspace::LockStore.new(dir: namespace[:dir], liveness: lock_holder)
          identity = lock_holder.current
          store.acquire("edit", identity: identity, waiter_pid: identity[:pid],
            waiter_started: identity[:started], task: "unrelated work", wait: false)

          sessions = Workspace::Commands::Sessions.new(
            config: Workspace::Config.new,
            lock_namespace: lock_namespace,
            lock_holder: lock_holder,
            output: StringIO.new,
            error_output: StringIO.new
          )

          # Simulate `workspace sessions other-project` invoked from inside
          # cwd_project_dir: the daemon reports a pane for the *other*
          # project, keyed by a pane id that happens to collide with the
          # holder's pane in the unrelated cwd project's lock store.
          snapshot = {
            "workspace" => "other-project",
            "panes" => [{"pane_id" => identity[:pane], "index" => 0, "kind" => "agent"}]
          }

          sessions.send(:apply_lock_column, snapshot["panes"])

          # Desired behavior: a pane belonging to "other-project" must never
          # be stamped with a lock held in some unrelated project's store.
          # Real defect: apply_lock_column calls @lock_namespace.resolve(cwd:
          # Dir.pwd) with no reference to the "other-project" workspace being
          # rendered, so it picks up cwd_project_dir's lock store instead and
          # wrongly stamps the other project's pane as holding a lock it
          # never acquired.
          expect(snapshot["panes"].first["lock"]).not_to eq("edit ✓")
        end
      ensure
        FileUtils.remove_entry(other_project_dir) if File.directory?(other_project_dir)
        FileUtils.remove_entry(cwd_project_dir) if File.directory?(cwd_project_dir)
        FileUtils.remove_entry(state_home) if File.directory?(state_home)
      end
    end
  end
end
