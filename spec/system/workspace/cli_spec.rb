require "stringio"
require "tmpdir"

RSpec.describe Workspace::CLI do
  include CLITestHelpers::EnvStub

  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    config = overrides[:config] || Workspace::Config.new
    logger = overrides[:logger] || Workspace::Logger.new(output: error_output)
    state = overrides[:state] || CLITestHelpers::FakeState.new
    window_manager = overrides[:window_manager] || CLITestHelpers::FakeWindowManager.new
    tmux = overrides[:tmux] || FakeTmux.new
    project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
    doctor = overrides[:doctor] || CLITestHelpers::FakeDoctor.new
    project_settings = overrides[:project_settings] || CLITestHelpers::FakeProjectSettings.new
    hook_runner = overrides[:hook_runner] || CLITestHelpers::FakeHookRunner.new
    working_dir = overrides[:working_dir] || Dir.tmpdir

    # Pre-build command objects (matching build_cli pattern)
    iterm = overrides[:iterm] || CLITestHelpers::FakeITerm.new
    window_layout = overrides[:window_layout] || CLITestHelpers::FakeWindowLayout.new
    git = overrides[:git] || Workspace::Git.new(output: output, input: input)

    project_detector = overrides[:project_detector] || Workspace::ProjectDetector.new(state: state, project_config: project_config)
    status_scope = overrides[:status_scope] || Workspace::StatusScope.new(project_detector: project_detector, catalog: overrides[:project_catalog] || CLITestHelpers::FakeStatusCatalog.new)

    stop_command = overrides[:stop_command] || Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = overrides[:launch_command] || Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, agent_ensurer: CLITestHelpers::FakeAgentEnsurer.new, output: output, error_output: error_output, sleeper: ->(_) {})
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(lineage: LineageSupport.lineage, git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
    kill_command = overrides[:kill_command] || Workspace::Commands::Kill.new(git: git, project_config: project_config, project_settings: project_settings, stop_command: stop_command, project_detector: project_detector, output: output, input: input)
    finish_command = overrides[:finish_command] || Workspace::Commands::Finish.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, error_output: error_output, input: input)
    focus_command = overrides[:focus_command] || Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = overrides[:tile_command] || Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = overrides[:layout_command] || Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = overrides[:resize_command] || Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    sessions_command = overrides[:sessions_command] || Workspace::Commands::Sessions.new(config: config, output: output, error_output: error_output)
    session_event_command = overrides[:session_event_command] || Workspace::Commands::SessionEvent.new(config: config, tmux: tmux, input: input, env: {})
    hook_installer = Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: output), output: output, input: input)
    init_command = overrides[:init_command] || Workspace::Commands::Init.new(config: config, hook_installer: hook_installer, which: ->(_exe) { false }, output: output, error_output: error_output, input: input)
    repair_command = overrides[:repair_command] || CLITestHelpers::FakeRepairCommand.new
    cleanup_command = overrides[:cleanup_command] || Workspace::Commands::Cleanup.new(state: state, window_liveness: Workspace::WindowLiveness.new(window_manager: window_manager), tmux: tmux, output: output, input: input)
    stop_command_for_prune = instance_double(Workspace::Commands::Stop)
    prune_command = overrides[:prune_command] || Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, stop_command: stop_command_for_prune, output: output, input: input)
    claude_command = overrides[:claude_command] || CLITestHelpers::FakeClaudeCommand.new
    lookup_command = overrides[:lookup_command] || Workspace::Commands::Lookup.new(project_config: project_config, output: output)
    update_pane_command = overrides[:update_pane_command] || CLITestHelpers::FakeUpdatePaneCommand.new
    run_command = overrides[:run_command] || CLITestHelpers::FakeRunCommand.new
    run_result_store = overrides[:run_result_store] || CLITestHelpers::FakeRunResultStore.new
    run_and_report_command = overrides[:run_and_report_command] || CLITestHelpers::FakeRunAndReportCommand.new
    capture_command = overrides[:capture_command] || CLITestHelpers::FakeCaptureCommand.new
    wait_until_content_command = overrides[:wait_until_content_command] || CLITestHelpers::FakeWaitUntilContentCommand.new
    lock_command = overrides[:lock_command] || CLITestHelpers::FakeLockCommand.new
    dev_command = overrides[:dev_command] || CLITestHelpers::FakeDevCommand.new
    parent_command = overrides[:parent_command] || CLITestHelpers::FakeParentCommand.new
    agent_command = overrides[:agent_command] || CLITestHelpers::FakeAgentCommand.new
    ask_command = overrides[:ask_command] || CLITestHelpers::FakeAskCommand.new

    cli = CLITestHelpers.build_cli(
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
      status_scope: status_scope,
      workspace_name: overrides[:workspace_name],
      lineage: overrides[:lineage] || CLITestHelpers::FakeLineage.new,
      launch_command: launch_command,
      kill_command: kill_command,
      finish_command: finish_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      repair_command: repair_command,
      cleanup_command: cleanup_command,
      prune_command: prune_command,
      claude_command: claude_command,
      lookup_command: lookup_command,
      update_pane_command: update_pane_command,
      run_command: run_command,
      run_result_store: run_result_store,
      run_and_report_command: run_and_report_command,
      capture_command: capture_command,
      wait_until_content_command: wait_until_content_command,
      lock_command: lock_command,
      dev_command: dev_command,
      parent_command: parent_command,
      agent_command: agent_command,
      sessions_command: sessions_command,
      session_event_command: session_event_command,
      config_command: overrides[:config_command] || CLITestHelpers::FakeConfigCommand.new,
      statusline_command: overrides[:statusline_command] || CLITestHelpers::FakeStatuslineCommand.new,
      ask_command: ask_command,
      restart_agent_command: overrides[:restart_agent_command],
      agent_status_command: overrides[:agent_status_command],
      agent_executables_command: overrides[:agent_executables_command],
      send_command: overrides[:send_command],
      prompt_queue_command: overrides[:prompt_queue_command],
      ensure_agent_command: overrides[:ensure_agent_command],
      name_migration: overrides[:name_migration],
      handoff_command: overrides[:handoff_command],
      notes_command: overrides[:notes_command],
      notes_setup: overrides[:notes_setup],
      plan_command: overrides[:plan_command],
      plan_dispatch_command: overrides[:plan_dispatch_command],
      plan_task_command: overrides[:plan_task_command],
      ticket_command: overrides[:ticket_command],
      skills_command: overrides[:skills_command],
      goal_command: overrides[:goal_command],
      spine_command: overrides[:spine_command],
      spine_init_command: overrides[:spine_init_command],
      spine_start_command: overrides[:spine_start_command],
      pull_request_command: overrides[:pull_request_command],
      rebase_command: overrides[:rebase_command],
      push_command: overrides[:push_command],
      pr_feedback_command: overrides[:pr_feedback_command],
      promote_command: overrides[:promote_command],
      rename_command: overrides[:rename_command],
      projects_command: overrides[:projects_command],
      groups_command: overrides[:groups_command],
      capabilities_command: overrides[:capabilities_command],
      hooks_command: overrides[:hooks_command],
      restore_command: overrides[:restore_command],
      daemon_command: overrides[:daemon_command],
      ui_command: overrides[:ui_command],
      binding_command: overrides[:binding_command],
      library_command: overrides[:library_command],
      instructions_command: overrides[:instructions_command],
      instruction_composer: overrides[:instruction_composer],
      workflow_command: overrides[:workflow_command],
      workflow_start_command: overrides[:workflow_start_command],
      go_command: overrides[:go_command],
      library: overrides[:library],
      review_command: overrides[:review_command],
      snapshot_command: overrides[:snapshot_command],
      events_command: overrides[:events_command],
      project_actions_command: overrides[:project_actions_command],
      remove_command: overrides[:remove_command],
      inbox_command: overrides[:inbox_command],
      config_report: overrides[:config_report],
      tmuxinator_report: overrides[:tmuxinator_report],
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: overrides[:exit_handler] || FakeExitHandler,
      input: input,
      working_dir: working_dir,
      clock: overrides[:clock] || -> { Time.now },
      sleeper: overrides[:sleeper] || ->(_) {},
      launch_mode: overrides[:launch_mode] || CLITestHelpers.launch_mode(headless: false),
      liveness: overrides[:liveness] || ->(names) { names.to_h { |name| [name, true] } },
      window_liveness: overrides[:window_liveness],
      env: overrides[:env] || {},
      editor_launcher: overrides[:editor_launcher] || ->(_argv) { true },
      interactive: overrides.fetch(:interactive, -> { true })
    )
    [cli, output, error_output, hook_runner]
  end

  describe "#run" do
    it "prints help for --help" do
      cli, output, _ = build_test_cli
      cli.run(["--help"])
      expect(output.string).to match(/Usage: workspace/)
    end

    it "prints help for nil subcommand" do
      cli, output, _ = build_test_cli
      cli.run([])
      expect(output.string).to match(/Usage: workspace/)
    end

    it "prints the version for the version subcommand" do
      cli, output, _ = build_test_cli
      cli.run(["version"])
      expect(output.string).to eq("workspace #{Workspace::VERSION}\n")
    end

    it "prints help for version --help" do
      cli, output, _ = build_test_cli
      cli.run(["version", "--help"])
      expect(output.string).to include("Usage: workspace version")
    end

    it "exits 1 and prints error for unknown subcommand" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown subcommand: bogus")
    end

    it "names a leading flag as an option and shows where it belongs, using the subcommand that follows it" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--headless", "launch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include(
        "Unknown option before the subcommand: --headless. Put options after the subcommand, e.g. \"workspace launch --headless\"."
      )
    end

    it "drops the example when a leading flag has nothing after it" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include(
        "Unknown option before the subcommand: --bogus. Put options after the subcommand."
      )
      expect(error_output.string).not_to include("<subcommand>")
    end

    it "scans past further leading options to find the real subcommand for the example" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--headless", "--bogus", "launch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include(
        "Unknown option before the subcommand: --headless. Put options after the subcommand, e.g. \"workspace launch --headless\"."
      )
    end

    it "skips a leading flag's value and uses the real subcommand for the example" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--project", "myproj", "launch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include(
        "Unknown option before the subcommand: --project. Put options after the subcommand, e.g. \"workspace launch --project\"."
      )
    end

    it "drops the example when no known subcommand appears after the leading flag" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--state-dir", "/foo", "bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include(
        "Unknown option before the subcommand: --state-dir. Put options after the subcommand."
      )
    end

    it "still enables --debug when it appears before the subcommand" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["--debug", "bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unknown subcommand: bogus")
    end

    it "exits 1 when a Workspace::Error is raised" do
      doctor = CLITestHelpers::FakeDoctor.new
      doctor.run_error = Workspace::Error.new("something broke")

      cli, _, error_output = build_test_cli(doctor: doctor)
      expect { cli.run(["doctor"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Error: something broke")
    end

    it "exits 1 when a Workspace::UsageError is raised" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["launch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace launch")
    end
  end

  describe "--debug flag" do
    it "enables debug logging and writes to stderr" do
      error_output = StringIO.new
      cli, _, _ = build_test_cli(error_output: error_output)
      cli.run(["--debug", "--help"])
      expect(error_output.string).to include("[DEBUG]")
    end

    it "strips --debug before dispatching subcommand" do
      cli, output, _ = build_test_cli
      cli.run(["--debug", "--help"])
      expect(output.string).to match(/Usage: workspace/)
    end

    it "includes --debug in help text" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("--debug")
      expect(output.string).to include("WORKSPACE_DEBUG")
    end
  end

  describe "#run with whereis" do
    it "outputs the workspace directory" do
      config = Workspace::Config.new(workspace_dir: "/test/workspace")
      cli, output, _ = build_test_cli(config: config)
      cli.run(["whereis"])
      expect(output.string.strip).to eq("/test/workspace")
    end
  end

  describe "#run with dir" do
    it "outputs project root directory" do
      pc = CLITestHelpers::FakeProjectConfig.new(
        "project-a" => "/path/to/project-a"
      )
      cli, output, _ = build_test_cli(project_config: pc)
      cli.run(["dir", "project-a"])
      expect(output.string.strip).to eq("/path/to/project-a")
    end

    it "expands tilde in project root" do
      pc = CLITestHelpers::FakeProjectConfig.new(
        "project-a" => "~/my-project"
      )
      cli, output, _ = build_test_cli(project_config: pc)
      cli.run(["dir", "project-a"])
      expanded = File.expand_path("~/my-project")
      expect(output.string.strip).to eq(expanded)
    end

    it "exits 1 when project has no root configured" do
      pc = CLITestHelpers::FakeProjectConfig.new
      cli, _, error_output = build_test_cli(project_config: pc)
      expect { cli.run(["dir", "project-a"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("not found or has no root")
    end

    it "exits 1 when project does not exist" do
      pc = CLITestHelpers::FakeProjectConfig.new
      cli, _, error_output = build_test_cli(project_config: pc)
      expect { cli.run(["dir", "unknown-project"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("not found or has no root")
    end

    it "prints the root of the workspace the working directory is in when no project is given" do
      Dir.mktmpdir do |root|
        state = CLITestHelpers::FakeState.new
        state["project-a"] = {}
        pc = CLITestHelpers::FakeProjectConfig.new("project-a" => root)
        cli, output, _ = build_test_cli(project_config: pc, state: state, working_dir: File.join(root, "sub").tap { |d| Dir.mkdir(d) })

        cli.run(["dir"])

        expect(output.string.strip).to eq(File.expand_path(root))
      end
    end

    it "prints the root of the workspace named by --name" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => "/path/to/project-a")
      cli, output, _ = build_test_cli(project_config: pc)
      cli.run(["dir", "--name", "project-a"])
      expect(output.string.strip).to eq("/path/to/project-a")
    end

    it "uses a stopped workspace the detector does not find when the directory's lineage names it" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => "/path/to/project-a")
      cli, output, _ = build_test_cli(project_config: pc, lineage: CLITestHelpers::FakeLineage.new("project-a"))
      cli.run(["dir"])
      expect(output.string.strip).to eq("/path/to/project-a")
    end

    it "does not use a linked worktree's lineage as a workspace" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => "/path/to/project-a")
      lineage = CLITestHelpers::FakeLineage.new("project-a", is_worktree: true)
      cli, _, error_output = build_test_cli(project_config: pc, lineage: lineage)
      expect { cli.run(["dir"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("No workspace found for")
    end

    it "does not use a lineage with no git common dir as a workspace" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => "/path/to/project-a")
      lineage = CLITestHelpers::FakeLineage.new("project-a", git_common_dir: nil)
      cli, _, error_output = build_test_cli(project_config: pc, lineage: lineage)
      expect { cli.run(["dir"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("No workspace found for")
    end

    it "refuses with not_in_workspace when no project is given outside any workspace" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["dir"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("No workspace found for", "pass --name")
    end

    it "refuses a positional and a --name that differ" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["dir", "project-a", "--name", "project-b"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Give the workspace once")
    end
  end

  describe "#run with current" do
    it "detects worktree project from marker file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "my-worktree-project")

        cli, output, _ = build_test_cli(working_dir: dir)
        cli.run(["current"])
        expect(output.string.strip).to eq("my-worktree-project")
      end
    end

    it "detects project from active project root" do
      Dir.mktmpdir do |dir|
        state = CLITestHelpers::FakeState.new
        state["my-project"] = {"unique_id" => "uid1", "iterm_window_id" => 100}

        project_config = CLITestHelpers::FakeProjectConfig.new(Hash.new(dir))

        cli, output, _ = build_test_cli(state: state, project_config: project_config, working_dir: dir)
        cli.run(["current"])
        expect(output.string.strip).to eq("my-project")
      end
    end

    it "detects project from subdirectory of project root" do
      Dir.mktmpdir do |dir|
        subdir = File.join(dir, "src")
        FileUtils.mkdir_p(subdir)

        state = CLITestHelpers::FakeState.new
        state["my-project"] = {"unique_id" => "uid1", "iterm_window_id" => 100}

        project_config = CLITestHelpers::FakeProjectConfig.new(Hash.new(dir))

        cli, output, _ = build_test_cli(state: state, project_config: project_config, working_dir: subdir)
        cli.run(["current"])
        expect(output.string.strip).to eq("my-project")
      end
    end

    it "picks the longest matching root when roots overlap" do
      Dir.mktmpdir do |dir|
        subdir = File.join(dir, "services", "auth")
        FileUtils.mkdir_p(subdir)

        state = CLITestHelpers::FakeState.new
        state["monorepo"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state["auth-service"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

        project_config = CLITestHelpers::FakeProjectConfig.new({"monorepo" => dir, "auth-service" => subdir})

        cli, output, _ = build_test_cli(state: state, project_config: project_config, working_dir: subdir)
        cli.run(["current"])
        expect(output.string.strip).to eq("auth-service")
      end
    end

    it "does not false-match projects with similar prefixes" do
      Dir.mktmpdir do |dir|
        app_dir = File.join(dir, "app")
        app_extra_dir = File.join(dir, "app-extra")
        FileUtils.mkdir_p(app_dir)
        FileUtils.mkdir_p(app_extra_dir)

        state = CLITestHelpers::FakeState.new
        state["app"] = {"unique_id" => "uid1", "iterm_window_id" => 100}

        project_config = CLITestHelpers::FakeProjectConfig.new(Hash.new(app_dir))

        cli, _, error_output = build_test_cli(state: state, project_config: project_config, working_dir: app_extra_dir)
        expect { cli.run(["current"]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
        expect(error_output.string).to include("Not inside a workspace project directory.")
      end
    end

    it "exits 1 when not inside a workspace project" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["current"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Not inside a workspace project directory.")
      expect(error_output.string).to include("workspace list --all")
    end
  end

  describe "#run with list --all" do
    it "lists all available projects" do
      cli, output, _ = build_test_cli
      cli.run(["list", "--all"])
      expect(output.string).to include("project-a")
      expect(output.string).to include("project-b")
    end

    it "does not load state or check windows" do
      wm = CLITestHelpers::FakeWindowManager.new

      cli, output, _ = build_test_cli(window_manager: wm)
      cli.run(["list", "--all"])
      expect(wm.live_window_ids_calls).to eq(0)
      expect(output.string).to include("project-a")
    end

    it "works via list-projects alias" do
      cli, output, _ = build_test_cli
      cli.run(["list-projects"])
      expect(output.string).to include("project-a")
      expect(output.string).to include("project-b")
    end

    it "wraps the names in the envelope under workspaces with --json-envelope" do
      state = CLITestHelpers::FakeState.new
      state["proj-b"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj-a"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      cli, output, _ = build_test_cli(state: state)
      cli.run(["list", "--json-envelope"])

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspaces" => %w[proj-a proj-b], "warnings" => [])
    end

    it "wraps an empty list with --json-envelope" do
      cli, output, _ = build_test_cli
      cli.run(["list", "--json-envelope"])
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "workspaces" => [], "warnings" => [])
    end

    it "wraps list --all rows with --json-envelope" do
      cli, output, _ = build_test_cli
      cli.run(["list", "--all", "--json-envelope"])
      expect(JSON.parse(output.string)).to include("ok" => true, "workspaces" => an_instance_of(Array), "warnings" => [])
    end

    it "outputs JSON array with --json" do
      cli, output, _ = build_test_cli
      cli.run(["list", "--all", "--json"])
      result = JSON.parse(output.string)
      # New format: array of objects with name and directory
      expect(result).to be_an(Array)
      expect(result.map { |p| p["name"] }).to include("project-a", "project-b")
    end

    it "includes directory in JSON objects" do
      pc = CLITestHelpers::FakeProjectConfig.new(
        "project-a" => "/path/a",
        "project-b" => "~/path/b"
      )
      cli, output, _ = build_test_cli(project_config: pc)
      cli.run(["list", "--all", "--json"])
      result = JSON.parse(output.string)

      proj_a = result.find { |p| p["name"] == "project-a" }
      expect(proj_a).to have_key("directory")
      expect(proj_a["directory"]).to eq("/path/a")

      proj_b = result.find { |p| p["name"] == "project-b" }
      expect(proj_b).to have_key("directory")
      expect(proj_b["directory"]).to eq(File.expand_path("~/path/b"))
    end

    it "sets directory to null when project has no root" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => nil)
      cli, output, _ = build_test_cli(project_config: pc)
      cli.run(["list", "--all", "--json"])
      result = JSON.parse(output.string)

      proj_a = result.find { |p| p["name"] == "project-a" }
      expect(proj_a["directory"]).to be_nil
    end
  end

  describe "auto-detection from working_dir" do
    it "focus auto-detects project from marker file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "my-project")

        state = CLITestHelpers::FakeState.new
        state["my-project"] = {"unique_id" => "uid1", "iterm_window_id" => 100}

        wm = CLITestHelpers::FakeWindowManager.new

        cli, output, _ = build_test_cli(state: state, window_manager: wm, working_dir: dir)
        cli.run(["focus"])
        expect(output.string).to include("Focusing my-project")
      end
    end

    it "layout save treats single arg as layout name when project detected" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "my-project")

        state = CLITestHelpers::FakeState.new
        state["my-project"] = {"unique_id" => "uid1"}

        tmux = FakeTmux.new
        allow(tmux).to receive(:sessions).and_return(["my-project"])

        cli, output, _ = build_test_cli(state: state, tmux: tmux, working_dir: dir)
        cli.run(["layout", "save", "coding"])
        expect(output.string).to include("my-project")
        expect(output.string).to include("coding")
      end
    end
  end

  describe "#run with status" do
    it "shows no tracked sessions when state is empty" do
      cli, output, _ = build_test_cli
      cli.run(["status"])
      expect(output.string).to include("No tracked sessions.")
    end

    it "shows all tracked sessions without pruning" do
      state = CLITestHelpers::FakeState.new
      state["proj-a"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj-b"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      cli, output, _ = build_test_cli(state: state)
      cli.run(["status"])

      expect(output.string).to include("proj-a")
      expect(output.string).to include("proj-b")
      expect(state.keys).to contain_exactly("proj-a", "proj-b")
    end

    it "outputs JSON with --json" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj2"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      wm = CLITestHelpers::FakeWindowManager.new(live_window_ids: Set.new([100, 200]))

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["status", "--json"])

      result = JSON.parse(output.string)
      expect(result).to include(
        "proj1" => a_hash_including("unique_id" => "uid1", "iterm_window_id" => 100),
        "proj2" => a_hash_including("unique_id" => "uid2", "iterm_window_id" => 200)
      )
    end

    it "wraps the state in the envelope under status with --json-envelope" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      wm = CLITestHelpers::FakeWindowManager.new(live_window_ids: Set.new([100]))

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["status", "--json-envelope"])

      result = JSON.parse(output.string)
      expect(result.keys).to eq(%w[schema_version ok status warnings])
      expect(result).to include("schema_version" => 1, "ok" => true, "warnings" => [])
      expect(result["status"]).to include("proj1" => a_hash_including("unique_id" => "uid1", "alive" => true))
    end

    it "wraps an empty state as an empty status with --json-envelope" do
      cli, output, _ = build_test_cli
      cli.run(["status", "--json-envelope"])
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "status" => {}, "warnings" => [])
    end

    it "outputs empty JSON object with --json when no sessions" do
      cli, output, _ = build_test_cli
      cli.run(["status", "--json"])
      expect(JSON.parse(output.string)).to eq({})
    end
  end

  describe "#run with status liveness" do
    let(:state) do
      CLITestHelpers::FakeState.new.tap do |s|
        s["up"] = {"unique_id" => "u1", "iterm_window_id" => 1}
        s["gone"] = {"unique_id" => "u2", "iterm_window_id" => 2}
        s["hl"] = {"headless" => true}
      end
    end
    let(:liveness) { ->(names) { {"up" => true, "gone" => false, "hl" => nil}.slice(*names) } }

    it "marks each session alive, dead, or unknown from tmux" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["status"])
      expect(output.string).to include("up  window_id=1  [alive]")
      expect(output.string).to include("gone  window_id=2  [dead]")
      expect(output.string).to include("hl  headless  [unknown]")
    end

    it "adds an alive key to each entry with --json and keeps the rest" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["status", "--json"])
      result = JSON.parse(output.string)
      expect(result["up"]).to eq("unique_id" => "u1", "iterm_window_id" => 1, "alive" => true, "window_alive" => nil)
      expect(result["gone"]["alive"]).to eq(false)
      expect(result["hl"]).to eq("headless" => true, "alive" => nil, "window_alive" => nil)
    end

    it "adds window_alive beside alive with --json" do
      window_liveness = ->(entries) { {"up" => true, "gone" => false, "hl" => nil}.slice(*entries.keys) }
      cli, output, _ = build_test_cli(state: state, liveness: liveness, window_liveness: window_liveness)
      cli.run(["status", "--json"])
      result = JSON.parse(output.string)
      expect(result.transform_values { |e| e.values_at("alive", "window_alive") }).to eq(
        "up" => [true, true], "gone" => [false, false], "hl" => [nil, nil]
      )
    end

    it "does not ask for windows without --json" do
      window_liveness = ->(_) { raise "should not be called" }
      cli, output, _ = build_test_cli(state: state, liveness: liveness, window_liveness: window_liveness)
      cli.run(["status"])
      expect(output.string).to include("up  window_id=1  [alive]")
    end

    it "does not write alive into the state file" do
      cli, _, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["status", "--json"])
      expect(state["up"]).to eq("unique_id" => "u1", "iterm_window_id" => 1)
    end
  end

  describe "#run with list --liveness" do
    let(:state) do
      CLITestHelpers::FakeState.new.tap do |s|
        s["up"] = {"unique_id" => "u1"}
        s["gone"] = {"unique_id" => "u2"}
      end
    end
    let(:liveness) { ->(names) { {"up" => true, "gone" => false}.slice(*names) } }

    it "leaves plain list output as bare names" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["list"])
      expect(output.string).to eq("gone\nup\n")
    end

    it "marks each project alive or dead" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["list", "--liveness"])
      expect(output.string).to eq("gone  [dead]\nup    [alive]\n")
    end

    it "wraps the name and alive objects with --json-envelope" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["list", "--liveness", "--json-envelope"])
      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => true, "warnings" => [],
        "workspaces" => [{"name" => "gone", "alive" => false, "window_alive" => nil}, {"name" => "up", "alive" => true, "window_alive" => nil}]
      )
    end

    it "prints name and alive objects with --json" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["list", "--liveness", "--json"])
      expect(JSON.parse(output.string)).to eq([{"name" => "gone", "alive" => false, "window_alive" => nil}, {"name" => "up", "alive" => true, "window_alive" => nil}])
    end

    it "adds window_alive beside alive with --json and not in the plain list" do
      window_liveness = ->(entries) { {"up" => true, "gone" => false}.slice(*entries.keys) }
      cli, output, _ = build_test_cli(state: state, liveness: liveness, window_liveness: window_liveness)
      cli.run(["list", "--liveness", "--json"])
      expect(JSON.parse(output.string)).to eq([{"name" => "gone", "alive" => false, "window_alive" => false}, {"name" => "up", "alive" => true, "window_alive" => true}])
      output.truncate(0)
      output.rewind
      output.rewind
      cli.run(["list", "--liveness"])
      expect(output.string).to eq("gone  [dead]\nup    [alive]\n")
    end

    it "keeps url and directory with --show-urls --json" do
      git = FakeGit.new(remote_url: "git@h:o/r.git")
      pc = CLITestHelpers::FakeProjectConfig.new({"up" => "/tmp/up"})
      cli, output, _ = build_test_cli(state: state, liveness: liveness, git: git, project_config: pc)
      cli.run(["list", "--liveness", "--show-urls", "--json"])
      up = JSON.parse(output.string).find { |e| e["name"] == "up" }
      expect(up).to eq("name" => "up", "directory" => "/tmp/up", "url" => "git@h:o/r.git", "alive" => true, "window_alive" => nil)
    end

    it "shows the alive marker after the url column" do
      git = FakeGit.new(remote_url: "u")
      pc = CLITestHelpers::FakeProjectConfig.new({"up" => "/tmp/up"})
      cli, output, _ = build_test_cli(state: state, liveness: liveness, git: git, project_config: pc)
      cli.run(["list", "--liveness", "--show-urls"])
      expect(output.string).to include("up    u  [alive]")
    end

    it "refuses --all, which lists configs rather than active projects" do
      cli, _, error_output = build_test_cli(state: state, liveness: liveness)
      expect { cli.run(["list", "--all", "--liveness"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("can't be combined with --all")
    end

    it "reports an empty list as before" do
      cli, output, _ = build_test_cli(liveness: liveness)
      cli.run(["list", "--liveness", "--json"])
      expect(output.string.strip).to eq("[]")
    end
  end

  describe "#run with list" do
    it "shows no active projects when state is empty" do
      cli, output, _ = build_test_cli
      cli.run(["list"])
      expect(output.string).to include("No active projects. Run 'workspace list --all' to see available projects.")
    end

    it "lists all tracked projects without pruning" do
      state = CLITestHelpers::FakeState.new
      state["proj-a"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj-b"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      cli, output, _ = build_test_cli(state: state)
      cli.run(["list"])

      expect(output.string).to include("proj-a")
      expect(output.string).to include("proj-b")
      expect(state.keys).to contain_exactly("proj-a", "proj-b")
    end

    it "outputs JSON array with --json" do
      state = CLITestHelpers::FakeState.new
      state["proj-b"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj-a"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      wm = CLITestHelpers::FakeWindowManager.new(live_window_ids: Set.new([100, 200]))

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["list", "--json"])

      expect(JSON.parse(output.string)).to eq(["proj-a", "proj-b"])
    end

    it "outputs empty JSON array with --json when no active projects" do
      cli, output, _ = build_test_cli
      cli.run(["list", "--json"])
      expect(JSON.parse(output.string)).to eq([])
    end

    it "outputs JSON objects with url when --json and --show-urls combined" do
      state = CLITestHelpers::FakeState.new
      state["proj-a"] = {"unique_id" => "uid1", "iterm_window_id" => 100}

      pc = CLITestHelpers::FakeProjectConfig.new("proj-a" => "/path/a")
      git = instance_double(Workspace::Git)
      allow(git).to receive(:remote_url).with("/path/a").and_return("https://github.com/org/proj-a")

      cli, output, _ = build_test_cli(state: state, project_config: pc, git: git)
      cli.run(["list", "--json", "--show-urls"])

      result = JSON.parse(output.string)
      expect(result).to be_an(Array)
      proj = result.find { |p| p["name"] == "proj-a" }
      expect(proj["url"]).to eq("https://github.com/org/proj-a")
      expect(proj["directory"]).to eq("/path/a")
    end

    context "with --show-urls" do
      it "prints name and URL columns for active projects" do
        state = CLITestHelpers::FakeState.new
        state["proj-a"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
        state["proj-b"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

        pc = CLITestHelpers::FakeProjectConfig.new(
          "proj-a" => "/path/a",
          "proj-b" => "/path/b"
        )

        git = instance_double(Workspace::Git)
        allow(git).to receive(:remote_url).with("/path/a").and_return("https://github.com/org/proj-a")
        allow(git).to receive(:remote_url).with("/path/b").and_return("https://github.com/org/proj-b")

        cli, output, _ = build_test_cli(state: state, project_config: pc, git: git)
        cli.run(["list", "--show-urls"])

        lines = output.string.lines.map(&:chomp)
        expect(lines).to include(match(/\Aproj-a\s+https:\/\/github\.com\/org\/proj-a\z/))
        expect(lines).to include(match(/\Aproj-b\s+https:\/\/github\.com\/org\/proj-b\z/))
      end

      it "omits URL column when project has no root" do
        state = CLITestHelpers::FakeState.new
        state["proj-a"] = {"unique_id" => "uid1"}

        pc = CLITestHelpers::FakeProjectConfig.new("proj-a" => nil)
        git = instance_double(Workspace::Git)
        allow(git).to receive(:remote_url).and_return(nil)

        cli, output, _ = build_test_cli(state: state, project_config: pc, git: git)
        cli.run(["list", "--show-urls"])

        expect(output.string).to include("proj-a")
        expect(git).not_to have_received(:remote_url)
      end

      it "shows empty URL when remote_url returns nil" do
        state = CLITestHelpers::FakeState.new
        state["proj-a"] = {"unique_id" => "uid1"}

        pc = CLITestHelpers::FakeProjectConfig.new("proj-a" => "/path/a")
        git = instance_double(Workspace::Git)
        allow(git).to receive(:remote_url).with("/path/a").and_return(nil)

        cli, output, _ = build_test_cli(state: state, project_config: pc, git: git)
        cli.run(["list", "--show-urls"])

        expect(output.string.chomp).to eq("proj-a")
      end
    end
  end

  describe "#run with list --all and --show-urls" do
    it "prints name and URL columns for all available projects" do
      pc = CLITestHelpers::FakeProjectConfig.new(
        "project-a" => "/path/a",
        "project-b" => "/path/b"
      )

      git = instance_double(Workspace::Git)
      allow(git).to receive(:remote_url).with("/path/a").and_return("https://github.com/org/project-a")
      allow(git).to receive(:remote_url).with("/path/b").and_return("https://github.com/org/project-b")

      cli, output, _ = build_test_cli(project_config: pc, git: git)
      cli.run(["list", "--all", "--show-urls"])

      lines = output.string.lines.map(&:chomp)
      expect(lines).to include(match(/\Aproject-a\s+https:\/\/github\.com\/org\/project-a\z/))
      expect(lines).to include(match(/\Aproject-b\s+https:\/\/github\.com\/org\/project-b\z/))
    end

    it "includes url key in JSON when --json and --show-urls combined" do
      pc = CLITestHelpers::FakeProjectConfig.new("project-a" => "/path/a")

      git = instance_double(Workspace::Git)
      allow(git).to receive(:remote_url).with("/path/a").and_return("https://github.com/org/project-a")

      cli, output, _ = build_test_cli(project_config: pc, git: git)
      cli.run(["list", "--all", "--json", "--show-urls"])

      result = JSON.parse(output.string)
      proj = result.find { |p| p["name"] == "project-a" }
      expect(proj["url"]).to eq("https://github.com/org/project-a")
    end
  end

  describe "#run with doctor" do
    it "delegates to the doctor collaborator" do
      doctor = CLITestHelpers::FakeDoctor.new

      cli, _, _ = build_test_cli(doctor: doctor)
      cli.run(["doctor"])
      expect(doctor.run_count).to eq(1)
    end
  end

  describe "#run with doctor --json" do
    let(:failing) do
      {mode: {"headless" => true, "reason" => "no display"}, issues: 1,
       rows: [{id: "tmux", status: "fail", message: "tmux (not found)", hints: [], fix: "brew install tmux", fix_command: "brew install tmux", project: nil},
         {id: "git", status: "ok", message: "git (2+)", hints: [], fix: nil, fix_command: nil, project: nil}]}
    end

    it "prints one document and exits 1 when a check failed" do
      doctor = CLITestHelpers::FakeDoctor.new
      doctor.result = failing
      cli, output, = build_test_cli(doctor: doctor)

      expect { cli.run(["doctor", "--json", "--headless"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      doc = JSON.parse(output.string)
      expect(doc).to include("schema_version" => 1, "ok" => true, "healthy" => false)
      expect(doc["checks"].map { |c| [c["id"], c["ok"]] }).to eq([["tmux", false], ["git", true]])
      expect(doc["checks"].first).to include("fix_command" => "brew install tmux")
      expect(doc["summary"]).to eq("ok" => 1, "warn" => 0, "fail" => 1, "skipped" => 0, "issues" => 1)
      expect(doctor.headless).to be true
    end

    it "exits 0 when nothing failed" do
      cli, output, = build_test_cli
      cli.run(["doctor", "--json"])
      expect(JSON.parse(output.string)).to include("healthy" => true, "checks" => [])
    end
  end

  describe "#run with stop" do
    it "stops every active project with --all" do
      cli, output, _ = build_test_cli
      cli.run(["stop", "--all"])
      expect(output.string).to include("No active workspace projects")
    end

    it "stops only the workspace the working directory is in when none is named" do
      Dir.mktmpdir do |root|
        state = CLITestHelpers::FakeState.new
        state["api"] = {}
        state["web"] = {}
        pc = CLITestHelpers::FakeProjectConfig.new("api" => root, "web" => "/elsewhere/web")
        cli, output, _ = build_test_cli(project_config: pc, state: state, working_dir: root)

        cli.run(["stop"])

        expect(output.string).to include("Stopped 1 project(s): api")
        expect(state.keys).to eq(["web"])
      end
    end

    it "stops the workspace named by --name" do
      state = CLITestHelpers::FakeState.new
      state["api"] = {}
      state["web"] = {}
      cli, output, _ = build_test_cli(state: state)

      cli.run(["stop", "--name", "web"])

      expect(output.string).to include("Stopped 1 project(s): web")
      expect(state.keys).to eq(["api"])
    end

    it "refuses with not_in_workspace outside any workspace with no name and no --all" do
      state = CLITestHelpers::FakeState.new
      state["api"] = {}
      cli, output, _ = build_test_cli(state: state)

      expect { cli.run(["stop", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
      expect(state.keys).to eq(["api"])
    end

    it "refuses --all beside a name" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["stop", "--all", "api"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--all stops every active workspace")
    end

    it "puts the stop command's warnings in the --json document and still exits 0" do
      message = "iTerm did not answer in 5s; the window for api was left open."
      stop_command = instance_double(Workspace::Commands::Stop, call: ["api"], warnings: [message])
      cli, output, _ = build_test_cli(stop_command: stop_command)

      cli.run(["stop", "--json", "api"])

      doc = JSON.parse(output.string)
      expect(doc["status"]).to eq("ok")
      expect(doc["warnings"]).to eq([message])
      expect(doc["results"].map { |r| [r["workspace"], r["outcome"]] }).to eq([["api", "stopped"]])
    end
  end

  describe "#run with add" do
    let(:root) { Dir.mktmpdir }
    let(:worktree_root) { File.join(root, ".worktrees", "x").tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:project_config) { instance_double(Workspace::ProjectConfig, existing_name: nil) }
    let(:notes_setup) { instance_double(Workspace::NotesSetup) }

    after { FileUtils.remove_entry(root) }

    before do
      allow(project_config).to receive(:resolve_project_arg) { |arg| [(arg == worktree_root) ? "repo-x" : "plain", File.expand_path(arg)] }
      allow(project_config).to receive(:create) { |name, _root| name }
      allow(project_config).to receive(:config_path_for) { |name| "/cfg/#{name}.yml" }
    end

    describe "--json" do
      it "reports created with the name, root and config path" do
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        cli.run(["add", "--json", root])

        doc = JSON.parse(output.string)
        expect(doc).to include("action" => "add", "status" => "ok")
        expect(doc["results"]).to eq([{"workspace" => "plain", "outcome" => "created", "reason" => nil, "message" => nil,
                                       "root" => root, "config_path" => "/cfg/plain.yml", "notes_dir" => nil}])
      end

      it "reports exists for a config already there, under the name create returns" do
        allow(project_config).to receive(:existing_name).and_return("Plain")
        allow(project_config).to receive(:create).and_return("Plain")
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        cli.run(["add", "--json", root])

        row = JSON.parse(output.string)["results"].first
        expect(row).to include("workspace" => "Plain", "outcome" => "exists", "config_path" => "/cfg/Plain.yml")
      end

      it "keeps stdout to one document" do
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        cli.run(["add", "--json", root])

        expect(output.string.lines.size).to eq(1)
      end

      it "gives a created worktree config its notes_dir and the setup warnings" do
        allow(notes_setup).to receive(:call).and_return("dir" => "/notes/x", "warnings" => ["Warning: slow"])
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        cli.run(["add", "--json", worktree_root])

        doc = JSON.parse(output.string)
        expect(doc["results"].first).to include("outcome" => "created", "notes_dir" => "/notes/x")
        expect(doc["warnings"]).to eq(["Warning: slow"])
      end

      it "gives a path that is not a directory a failed row and still adds the others (partial, exit 3)" do
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)
        missing = File.join(root, "nope")
        allow(project_config).to receive(:resolve_project_arg) { |arg| [(arg == missing) ? "nope" : "plain", File.expand_path(arg)] }

        expect { cli.run(["add", "--json", missing, root]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

        doc = JSON.parse(output.string)
        expect(doc["status"]).to eq("partial")
        expect(doc["results"].map { |r| [r["workspace"], r["outcome"], r["reason"]] }).to eq([["nope", "failed", "not_a_directory"], ["plain", "created", nil]])
        expect(doc["results"].first["details"]).to eq("path" => missing)
        expect(project_config).to have_received(:create).once
      end

      it "exits 1 when every path failed, still printing the document" do
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)
        missing = File.join(root, "nope")

        expect { cli.run(["add", "--json", missing]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("status" => "failed")
      end

      it "exits 0 when no row failed" do
        cli, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        expect { cli.run(["add", "--json", root]) }.not_to raise_error
      end

      it "accepts flags after the paths" do
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        cli.run(["add", root, "--json"])

        expect(JSON.parse(output.string)["results"].size).to eq(1)
      end

      it "turns a case conflict into a failed row and still adds the other paths" do
        other = Dir.mktmpdir
        allow(project_config).to receive(:resolve_project_arg) { |arg| [(arg == other) ? "other" : "plain", File.expand_path(arg)] }
        allow(project_config).to receive(:create) do |name, _root|
          raise Workspace::Error.new("clash", code: "workspace_name_case_conflict", details: {"name" => name}) if name == "plain"
          name
        end
        cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

        expect { cli.run(["add", "--json", root, other]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

        doc = JSON.parse(output.string)
        expect(doc["status"]).to eq("partial")
        expect(doc["results"].map { |r| [r["outcome"], r["reason"]] }).to eq([["failed", "workspace_name_case_conflict"], ["created", nil]])
      ensure
        FileUtils.remove_entry(other)
      end
    end

    it "turns a conflict found while resolving a path into a failed row" do
      other = Dir.mktmpdir
      allow(project_config).to receive(:resolve_project_arg) do |arg|
        raise Workspace::Error.new("clash", code: "workspace_name_case_conflict", details: {"name" => "plain"}) if arg == root
        ["other", File.expand_path(arg)]
      end
      cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      expect { cli.run(["add", "--json", root, other]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

      rows = JSON.parse(output.string)["results"]
      expect(rows.map { |r| [r["workspace"], r["outcome"], r["reason"]] }).to eq([["plain", "failed", "workspace_name_case_conflict"], ["other", "created", nil]])
    ensure
      FileUtils.remove_entry(other)
    end

    it "reports exists with no notes_dir for a worktree config already there" do
      allow(project_config).to receive(:existing_name).with("repo-x").and_return("repo-x")
      allow(notes_setup).to receive(:call)
      cli, output, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      cli.run(["add", "--json", worktree_root])

      expect(JSON.parse(output.string)["results"].first).to include("outcome" => "exists", "notes_dir" => nil)
      expect(notes_setup).not_to have_received(:call)
    end

    it "skips a path that is not a directory without --json and adds the rest" do
      cli, output, error_output = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      expect { cli.run(["add", File.join(root, "nope"), root]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

      expect(error_output.string).to include("Not a directory")
      expect(output.string).to include("Project name: plain")
    end

    it "exits 1 without --json when every path is skipped" do
      cli, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      expect { cli.run(["add", File.join(root, "nope")]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "skips a path whose name is refused with a message and adds the rest without --json" do
      other = Dir.mktmpdir
      allow(project_config).to receive(:resolve_project_arg) { |arg| [(arg == other) ? "other" : "plain", File.expand_path(arg)] }
      allow(project_config).to receive(:create) do |name, _root|
        raise Workspace::Error.new("clash", code: "workspace_name_case_conflict") if name == "plain"
        name
      end
      cli, output, error_output = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      expect { cli.run(["add", root, other]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }

      expect(error_output.string).to include("Error: clash")
      expect(output.string).to include("Project name: other")
    ensure
      FileUtils.remove_entry(other)
    end

    it "sets up the notes directory of a worktree config it creates" do
      allow(notes_setup).to receive(:call).with("repo-x").and_return("dir" => "/notes/x", "warnings" => ["Warning: could not finish"])
      cli, output, error_output = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      cli.run(["add", worktree_root])

      expect(output.string).to include("Project name: repo-x").and include("Notes directory: /notes/x")
      expect(error_output.string).to include("Warning: could not finish")
    end

    it "leaves a plain project's notes alone" do
      allow(notes_setup).to receive(:call)
      cli, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      cli.run(["add", root])

      expect(notes_setup).not_to have_received(:call)
    end

    it "leaves a worktree config that already exists as it is" do
      allow(project_config).to receive(:existing_name).with("repo-x").and_return("repo-x")
      allow(notes_setup).to receive(:call)
      cli, = build_test_cli(project_config: project_config, notes_setup: notes_setup)

      cli.run(["add", worktree_root])

      expect(notes_setup).not_to have_received(:call)
    end
  end

  describe "#run with kill" do
    it "refuses with not_in_workspace when no project is given outside any workspace" do
      cli, output, _ = build_test_cli
      expect { cli.run(["kill", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
    end

    it "kills the workspace the working directory is in when none is named" do
      Dir.mktmpdir do |root|
        state = CLITestHelpers::FakeState.new
        state["myproject.worktree-x"] = {}
        pc = CLITestHelpers::FakeProjectConfig.new("myproject.worktree-x" => root)
        kill_command = instance_double(Workspace::Commands::Kill)
        allow(kill_command).to receive(:call).and_return("myproject.worktree-x")
        cli, = build_test_cli(kill_command: kill_command, project_config: pc, state: state, working_dir: root)

        cli.run(["kill"])

        expect(kill_command).to have_received(:call).with("myproject.worktree-x", force: false, working_dir: root, delete_branch: true, delete_remote: false)
      end
    end

    it "kills the workspace named by --name, keeping the prompt (no --force)" do
      kill_command = instance_double(Workspace::Commands::Kill)
      allow(kill_command).to receive(:call).and_return(nil)
      raw = StringIO.new
      cli, = build_test_cli(kill_command: kill_command, output: Workspace::OutputGate.new(raw))

      cli.run(["kill", "--name", "myproject.worktree-x", "--json"])

      expect(kill_command).to have_received(:call).with("myproject.worktree-x", force: false, working_dir: anything, delete_branch: true, delete_remote: false)
      expect(JSON.parse(raw.string)["results"]).to eq([{"workspace" => "myproject.worktree-x", "outcome" => "cancelled", "reason" => "declined", "message" => "Not confirmed; nothing was removed."}])
    end

    it "puts the branch result in the JSON row, and the remote branch only with --delete-remote" do
      branch = {"name" => "x", "deleted" => true, "kept_reason" => nil}
      remote = {"name" => "x", "remote" => "origin", "deleted" => true, "kept_reason" => nil}
      kill_command = instance_double(Workspace::Commands::Kill, dev_stopped: false, notes_inside_worktree: nil, branch_result: branch)
      allow(kill_command).to receive(:call).and_return("myproject.worktree-x")
      allow(kill_command).to receive(:remote_branch_result).and_return(nil)
      raw = StringIO.new
      cli, = build_test_cli(kill_command: kill_command, output: Workspace::OutputGate.new(raw))

      cli.run(["kill", "--name", "myproject.worktree-x", "--json"])
      row = JSON.parse(raw.string)["results"].first
      expect(row).to include("branch" => branch)
      expect(row).not_to have_key("remote_branch")

      raw.truncate(0)
      raw.rewind
      allow(kill_command).to receive(:remote_branch_result).and_return(remote)
      cli.run(["kill", "--name", "myproject.worktree-x", "--delete-remote", "--json"])
      expect(kill_command).to have_received(:call).with("myproject.worktree-x", force: false, working_dir: anything, delete_branch: true, delete_remote: true)
      expect(JSON.parse(raw.string)["results"].first).to include("branch" => branch, "remote_branch" => remote)
    end

    it "reports an open pull request refusal as a JSON error with its code and retry" do
      kill_command = instance_double(Workspace::Commands::Kill)
      allow(kill_command).to receive(:call).and_raise(Workspace::Error.new("open", code: "open_pull_request",
        details: {"branch" => "x"}, retry_with: {"flags" => ["--force"], "destructive" => true}))
      raw = StringIO.new
      cli, = build_test_cli(kill_command: kill_command, output: Workspace::OutputGate.new(raw))

      expect { cli.run(["kill", "--name", "myproject.worktree-x", "--delete-remote", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "open_pull_request", "retry" => include("flags" => ["--force"]))
    end

    it "refuses a positional and a --name that differ" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["kill", "a", "--name", "b"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Give the workspace once")
    end

    it "runs the post_kill hook from inside Kill, before the session is stopped" do
      kill_command = instance_double(Workspace::Commands::Kill)
      allow(kill_command).to receive(:call).with("myproject", force: true, working_dir: anything, delete_branch: true, delete_remote: false)
        .and_yield("myproject").and_return("myproject")
      hook_runner = CLITestHelpers::FakeHookRunner.new

      cli, _, _ = build_test_cli(kill_command: kill_command, hook_runner: hook_runner)
      cli.run(["kill", "--force", "myproject"])

      expect(hook_runner.runs).to eq([{project: "myproject", event: "post_kill", env: {}}])
    end
  end

  describe "#run with finish" do
    it "refuses with not_in_workspace when no project is given outside any workspace" do
      cli, output, _ = build_test_cli
      expect { cli.run(["finish", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
    end

    it "finishes the workspace the working directory is in when none is named" do
      Dir.mktmpdir do |root|
        state = CLITestHelpers::FakeState.new
        state["myproject.worktree-x"] = {}
        pc = CLITestHelpers::FakeProjectConfig.new("myproject.worktree-x" => root)
        cli, _, error_output = build_test_cli(project_config: pc, state: state, working_dir: root)

        # The fake config has no file on disk, so finish stops at the config check, past detection.
        expect { cli.run(["finish"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("No config found for 'myproject.worktree-x'")
      end
    end

    it "finishes the workspace named by --name" do
      finish_command = instance_double(Workspace::Commands::Finish)
      allow(finish_command).to receive(:call).and_return("myproject.worktree-x")
      cli, = build_test_cli(finish_command: finish_command)

      cli.run(["finish", "--name", "myproject.worktree-x"])

      expect(finish_command).to have_received(:call).with("myproject.worktree-x", pr: false, json: false, working_dir: anything)
    end

    it "emits a JSON usage error and exits 1 for a bad flag with --json" do
      cli, output, _ = build_test_cli
      expect { cli.run(["finish", "--json", "--bogus-flag"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(1)
      expect(parsed).to have_key("error")
    end

    it "delegates to the finish collaborator and runs the post_kill hook" do
      finish_command = instance_double(Workspace::Commands::Finish)
      allow(finish_command).to receive(:call).with(nil, pr: false, json: false, working_dir: anything)
        .and_yield("myproject").and_return("myproject")
      hook_runner = CLITestHelpers::FakeHookRunner.new

      cli, _, _ = build_test_cli(finish_command: finish_command, hook_runner: hook_runner)
      cli.run(["finish"])

      expect(hook_runner.runs).to include(project: "myproject", event: "post_kill", env: {})
    end

    it "does not run the post_kill hook under --json, keeping stdout to the JSON line" do
      finish_command = instance_double(Workspace::Commands::Finish)
      block_given = nil
      allow(finish_command).to receive(:call).with(nil, pr: false, json: true, working_dir: anything) do |*_args, &block|
        block_given = !block.nil?
        {exit_code: 0}
      end
      hook_runner = CLITestHelpers::FakeHookRunner.new

      cli, _, _ = build_test_cli(finish_command: finish_command, hook_runner: hook_runner)
      cli.run(["finish", "--json"])

      expect(block_given).to be(false)
      expect(hook_runner.runs).to be_empty
    end
  end

  describe "#run with resize" do
    it "exits 1 when missing arguments" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["resize"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace resize")
    end

    it "exits 1 when missing pane spec and no project detected" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["resize", "myproject"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace resize")
    end
  end

  describe "#run with layout" do
    it "shows help when no subcommand given" do
      cli, output, _ = build_test_cli
      cli.run(["layout"])
      expect(output.string).to include("Usage: workspace layout")
      expect(output.string).to include("save")
      expect(output.string).to include("restore")
      expect(output.string).to include("list")
    end

    it "exits 1 for unknown layout subcommand" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["layout", "bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown layout subcommand: bogus")
    end

    it "exits 1 when save has no project" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["layout", "save"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace layout")
    end
  end

  describe "#run with --help on verbs that once ran or mangled it" do
    # OptionParser's own --help prints to $stdout and calls Kernel#exit, so both
    # streams are captured and a clean exit is let through.
    def run_help(cli, argv, output, error_output)
      real = [$stdout, $stderr]
      $stdout = output
      $stderr = error_output
      cli.run(argv)
    rescue SystemExit => e
      expect(e.status).to eq(0)
    ensure
      $stdout, $stderr = real
    end

    ["--help", "-h"].each do |flag|
      it "event-log compact #{flag} prints help and does not compact" do
        state = CLITestHelpers::FakeState.new
        expect(state.event_log).not_to receive(:compact)
        cli, output, error_output = build_test_cli(state: state)
        run_help(cli, ["event-log", "compact", flag], output, error_output)
        expect(output.string).to start_with("Usage: workspace event-log")
        expect(error_output.string).to be_empty
      end
    end

    it "event-log compact still compacts" do
      state = CLITestHelpers::FakeState.new
      expect(state.event_log).to receive(:compact).and_return({})
      cli, output, = build_test_cli(state: state)
      cli.run(["event-log", "compact"])
      expect(output.string).to include("Compacted event log")
    end

    %w[save restore list].each do |verb|
      it "layout #{verb} --help prints the layout help and touches nothing" do
        layout = instance_double(Workspace::Commands::Layout)
        cli, output, error_output = build_test_cli(layout_command: layout)
        run_help(cli, ["layout", verb, "--help"], output, error_output)
        expect(output.string).to start_with("Usage: workspace layout")
        expect(error_output.string).to be_empty
      end
    end

    it "agent-run --help prints the agent-run page" do
      cli, output, error_output = build_test_cli
      run_help(cli, ["agent-run", "--help"], output, error_output)
      expect(output.string).to start_with("Usage: workspace agent-run <subcommand>")
      expect(error_output.string).to be_empty
    end

    it "handoff --help prints the handoff page and exits 0" do
      cli, output, error_output = build_test_cli
      run_help(cli, ["handoff", "--help"], output, error_output)
      expect(output.string).to start_with("Usage: workspace handoff check [NAME]")
      expect(output.string).to include("workspace handoff new [NAME]")
      expect(error_output.string).to be_empty
    end

    ["check", "new"].each do |verb|
      ["--help", "-h"].each do |flag|
        it "handoff #{verb} #{flag} prints the page of that verb and exits 0" do
          handoff_command = double("handoff", check: {exit_code: 0}, new: {exit_code: 0})
          expect(handoff_command).not_to receive(:check)
          expect(handoff_command).not_to receive(:new)
          cli, output, error_output = build_test_cli(handoff_command: handoff_command)
          run_help(cli, ["handoff", verb, flag], output, error_output)
          expect(output.string).to start_with("Usage: workspace handoff #{verb} [NAME]")
          expect(output.string.scan("Usage: workspace handoff").size).to eq(1)
          expect(error_output.string).to be_empty
        end
      end

      it "handoff #{verb} treats --help after --handoff-prompt as the prompt" do
        handoff_command = double("handoff", check: {exit_code: 0}, new: {exit_code: 0})
        cli, output, = build_test_cli(handoff_command: handoff_command)
        cli.run(["handoff", verb, "myapp", "--handoff-prompt", "--help"])
        expect(output.string).to be_empty
        if verb == "check"
          expect(handoff_command).to have_received(:check).with(hash_including(name: "myapp", handoff_prompt: "--help"))
        else
          expect(handoff_command).to have_received(:new).with(hash_including(name: "myapp", handoff_prompt: "--help"))
        end
      end
    end

    it "layout --help save prints the layout help" do
      layout = instance_double(Workspace::Commands::Layout)
      cli, output, error_output = build_test_cli(layout_command: layout)
      run_help(cli, ["layout", "--help", "save"], output, error_output)
      expect(output.string).to start_with("Usage: workspace layout")
    end

    [%w[agent-run send], %w[agent-run queue list]].each do |argv|
      it "#{argv.join(" ")} --help prints help and sends nothing" do
        cli, output, error_output = build_test_cli
        run_help(cli, [*argv, "--help"], output, error_output)
        expect(output.string).to start_with("Usage: workspace agent-run")
        expect(error_output.string).to be_empty
      end
    end

    %w[start advance status reset].each do |verb|
      it "pipeline #{verb} --help keeps the deprecation warning off stdout" do
        cli, output, error_output = build_test_cli
        run_help(cli, ["pipeline", verb, "--help"], output, error_output)
        expect(output.string).to start_with("Usage: workspace pipeline #{verb}")
        expect(output.string).not_to include("deprecated")
        expect(error_output.string).to include("deprecated")
      end
    end

    [%w[alfred], %w[alfred install], %w[alfred uninstall], %w[alfred info], %w[statusline], %w[report-run-status]].each do |argv|
      it "#{argv.join(" ")} --help prints its page" do
        cli, output, error_output = build_test_cli
        run_help(cli, [*argv, "--help"], output, error_output)
        expect(output.string).to start_with("Usage: workspace #{argv.join(" ")}")
        expect(error_output.string).to be_empty
      end
    end
  end

  describe "#run with launch or start and a prompt" do
    let(:launch_result) { {exit_code: 1, prompt_failures: {"myproject" => "no coding agent"}} }

    it "runs post_launch hooks, then exits 1 when launch could not send the prompt" do
      launch_command = double("launch", call: launch_result)
      cli, _, _, hook_runner = build_test_cli(launch_command: launch_command)

      expect { cli.run(["launch", "--prompt", "go", "myproject"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {"myproject" => "go"}, report_panes: true)
      expect(hook_runner.runs).to include(project: "myproject", event: "post_launch", env: {})
    end

    it "launches a mixed-case workspace under the lowercase name its rename gives it" do
      launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
      migration = double("name_migration")
      allow(migration).to receive(:call_locked).with("MyProject")
        .and_return(Workspace::NameMigration::Result.new(name: "myproject", from: "MyProject", renamed: [], warnings: ["MyProject: state not renamed (taken)"]))
      cli, _, error_output = build_test_cli(launch_command: launch_command, name_migration: migration)

      cli.run(["launch", "--prompt", "go", "MyProject"])

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {"myproject" => "go"}, report_panes: true)
      expect(error_output.string).to include("Warning: MyProject: state not renamed (taken)")
    end

    it "launches under the name as given when nothing was renamed or its daemon runs" do
      launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
      migration = double("name_migration")
      allow(migration).to receive(:call_locked).with("Other").and_return(nil)
      allow(migration).to receive(:call_locked).with("Plain")
        .and_return(Workspace::NameMigration::Result.new(name: "plain", from: nil, renamed: [], warnings: []))
      cli, = build_test_cli(launch_command: launch_command, name_migration: migration)

      cli.run(["launch", "Other", "Plain"])

      expect(launch_command).to have_received(:call).with(%w[Other Plain], reattach: false, prompts: {})
    end

    it "exits 0 when launch sent every prompt" do
      launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(launch_command: launch_command)

      expect { cli.run(["launch", "--prompt", "go", "myproject"]) }.not_to raise_error
    end

    it "exits 1 when start could not send the prompt" do
      start_command = double("start", call: launch_result)
      cli, = build_test_cli(start_command: start_command)

      expect { cli.run(["start", "--prompt", "go", "PROJ-1"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end

    it "says how long it waits in the --prompt help" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["launch"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("ready (up to #{Workspace::AgentReadiness::DEFAULT_TIMEOUT}s); exits 1 if it can't be sent")
    end

    it "passes --prompt-timeout through to launch" do
      launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(launch_command: launch_command)

      cli.run(["launch", "--prompt", "go", "--prompt-timeout", "90s", "myproject"])

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {"myproject" => "go"}, prompt_timeout: 90.0, report_panes: true)
    end

    it "passes --prompt-timeout through to start" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--prompt", "go", "--prompt-timeout", "2m", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: "go", prompt_timeout: 120.0,
        base: nil, yes: false, json: false)
    end

    describe "start --recipe" do
      let(:entry) { {"ref" => "recipe/r", "scope" => "global", "path" => "/x", "fields" => {"plays" => ["a"]}} }

      it "reads the recipe once and passes that entry to call" do
        start_command = double("start", call: {exit_code: 0, prompt_failures: {}}, recipe_entry: entry)
        cli, = build_test_cli(start_command: start_command)

        cli.run(["start", "--recipe", "r", "PROJ-1"])

        expect(start_command).to have_received(:recipe_entry).with("r").once
        expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
          base: nil, yes: false, json: false, recipe: entry)
      end

      it "prints exactly one error document for an unknown recipe under --json" do
        start_command = double("start", call: nil)
        allow(start_command).to receive(:recipe_entry).and_raise(Workspace::Error.new("No recipe 'nope'.", code: "unknown_library_entry"))
        cli, output = build_test_cli(start_command: start_command)

        expect { cli.run(["start", "--recipe", "nope", "--json", "PROJ-1"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        lines = output.string.lines
        expect(lines.size).to eq(1)
        doc = JSON.parse(lines.first)
        expect(doc).to include("schema_version" => 1, "ok" => false, "code" => "unknown_library_entry")
        expect(start_command).not_to have_received(:call)
      end

      it "keeps an entry of another kind a usage error document under --json" do
        start_command = double("start", call: nil)
        allow(start_command).to receive(:recipe_entry).and_raise(Workspace::UsageError, "--recipe takes a recipe, and 'play/x' is a play.")
        cli, output = build_test_cli(start_command: start_command)

        expect { cli.run(["start", "--recipe", "play/x", "--json", "PROJ-1"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        lines = output.string.lines
        expect(lines.size).to eq(1)
        expect(JSON.parse(lines.first)).to include("ok" => false, "code" => "usage")
      end

      context "with a workflow" do
        let(:fields) { {"workflow" => "rpiv", "workflow_inputs" => {"task" => "do it"}, "agent_kind" => "claude"} }
        let(:entry) { {"ref" => "recipe/r", "scope" => "global", "path" => "/x", "fields" => fields} }
        let(:start_command) { double("start", call: {exit_code: 0}, recipe_entry: entry) }
        let(:workflow_start) { CLITestHelpers::FakeWorkflowStartCommand.new }
        let(:built) { build_test_cli(start_command: start_command, workflow_start_command: workflow_start, workflow_command: CLITestHelpers::FakeWorkflowCommand.new) }
        let(:cli) { built[0] }
        let(:output) { built[1] }

        def refused_flags
          expect { yield }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          doc = JSON.parse(output.string.lines.tap { |l| expect(l.size).to eq(1) }.first)
          expect(doc).to include("ok" => false, "code" => "recipe_workflow_conflict")
          expect(doc["details"]).to include("ref" => "recipe/r", "workflow" => "rpiv")
          doc["details"]["flags"]
        end

        it "makes the same call as workflow start and never calls Start" do
          cli.run(["start", "--recipe", "r", "PROJ-1", "--base", "main", "--slug", "--no-headless", "--prompt-timeout", "2m", "--yes", "--no-spine"])
          cli.run(["workflow", "start", "rpiv", "PROJ-1", "--base", "main", "--slug", "--no-headless", "--prompt-timeout", "2m", "--input", "task=do it", "--agent-kind", "claude"])

          from_start, from_workflow = workflow_start.calls
          expect(from_start).to eq(id: "rpiv", ref: "PROJ-1", slug: true, inputs: {"task" => "do it"}, base: "main", headless: false, agent_kind: "claude", prompt_timeout: 120)
          expect(from_start).to eq(from_workflow.slice(*from_start.keys))
          expect(from_workflow.except(*from_start.keys)).to eq(positional: nil, prompt: nil, branch: nil, note: nil, dry_run: false, force: false, route: false)
          expect(start_command).not_to have_received(:call)
        end

        it "lets an explicit --agent-kind win over the recipe's" do
          cli.run(["start", "--recipe", "r", "PROJ-1", "--agent-kind", "codex"])
          expect(workflow_start.calls.first).to include(agent_kind: "codex")
        end

        it "sends empty inputs when the recipe has none" do
          fields.delete("workflow_inputs")
          cli.run(["start", "--recipe", "r", "PROJ-1"])
          expect(workflow_start.calls.first).to include(inputs: {})
        end

        {
          "--prompt" => ["--prompt", "x"], "--play" => ["--play", "p"], "--pack" => ["--pack", "k"], "--no-packs" => ["--no-packs"],
          "--handoff" => ["--handoff"], "--no-handoff" => ["--no-handoff"], "--agent" => ["--agent", "a"], "--skill" => ["--skill", "s"],
          "--no-launch" => ["--no-launch"], "--spine" => ["--spine"], "--plan" => ["--plan"], "--title" => ["--title", "T"],
          "--title-from-ticket" => ["--title-from-ticket"]
        }.each do |flag, args|
          it "refuses #{flag} alone, creating nothing" do
            expect(refused_flags { cli.run(["start", "--recipe", "r", "PROJ-1", "--json", *args]) }).to eq([flag])
            expect(workflow_start.calls).to be_empty
            expect(start_command).not_to have_received(:call)
          end
        end

        it "lists every refused flag at once" do
          flags = refused_flags { cli.run(["start", "--recipe", "r", "PROJ-1", "--json", "--prompt", "x", "--no-launch", "--title", "T", "--no-handoff"]) }
          expect(flags).to eq(%w[--prompt --no-handoff --no-launch --title])
        end

        it "names a refusal in plain text too" do
          expect { cli.run(["start", "--recipe", "r", "PROJ-1", "--play", "p"]) }.to raise_error(FakeSystemExit)
          expect(built[2].string).to include("recipe/r runs workflow rpiv, which cannot take --play")
        end

        it "passes --headless through" do
          cli.run(["start", "--recipe", "r", "PROJ-1", "--headless"])
          expect(workflow_start.calls.first).to include(headless: true)
        end

        it "accepts --no-headless, --yes and --no-spine" do
          cli.run(["start", "--recipe", "r", "PROJ-1", "--no-headless", "--yes", "--no-spine"])
          expect(workflow_start.calls.size).to eq(1)
        end

        it "needs a REF before it dispatches" do
          expect { cli.run(["start", "--recipe", "r"]) }.to raise_error(FakeSystemExit)
          expect(workflow_start.calls).to be_empty
        end

        it "prints one action document with the recipe under --json" do
          cli.run(["start", "--recipe", "r", "PROJ-1", "--json"])

          doc = JSON.parse(output.string)
          expect(output.string.lines.size).to eq(1)
          expect(doc).to include("ok" => true, "action" => "start")
          expect(doc["results"].first).to include("outcome" => "started", "recipe" => {"ref" => "recipe/r", "scope" => "global"})
        end

        it "exits 1 for an outcome of failed" do
          workflow_start.row = {"workspace" => nil, "outcome" => "failed", "reason" => "x", "message" => "no"}
          expect { cli.run(["start", "--recipe", "r", "PROJ-1"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        end

        it "prints one error document for an unknown workflow" do
          workflow_start.error = Workspace::Error.new("No workflow rpiv.", code: "unknown_workflow")
          expect { cli.run(["start", "--recipe", "r", "PROJ-1", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          expect(output.string.lines.size).to eq(1)
          expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workflow", "error" => "No workflow rpiv.")
        end

        it "rewrites input_required to name workflow_inputs, keeping code and details" do
          details = {"workflow" => "rpiv", "inputs" => [{"name" => "task"}]}
          workflow_start.error = Workspace::Error.new("needs input task. Pass --input task=VALUE.", code: "input_required", details: details)
          expect { cli.run(["start", "--recipe", "r", "PROJ-1", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          expect(output.string.lines.size).to eq(1)
          doc = JSON.parse(output.string)
          expect(doc).to include("code" => "input_required", "details" => details)
          expect(doc["error"]).to include("workflow_inputs").and include("workspace workflow start rpiv PROJ-1 --input")
          expect(doc["error"]).not_to include("Pass --input")
        end

        it "says so when no workflow start command was wired" do
          cli, = build_test_cli(start_command: start_command)
          expect { cli.run(["start", "--recipe", "r", "PROJ-1"]) }.to raise_error(FakeSystemExit)
        end
      end

      it "sends a recipe without a workflow to Start" do
        start_command = double("start", call: {exit_code: 0}, recipe_entry: entry)
        workflow_start = CLITestHelpers::FakeWorkflowStartCommand.new
        cli, = build_test_cli(start_command: start_command, workflow_start_command: workflow_start)
        cli.run(["start", "--recipe", "r", "PROJ-1"])
        expect(start_command).to have_received(:call)
        expect(workflow_start.calls).to be_empty
      end
    end

    it "passes --play through to start" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--play", "kickoff", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, plays: ["kickoff"])
    end

    it "passes repeated and comma-separated --play values to start as one list, without repeats" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--play", "a, b", "--play", "c,,a", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, plays: %w[a b c])
    end

    it "refuses a --play value with no play name, on start and launch" do
      start_command = double("start", call: {exit_code: 0})
      launch_command = double("launch", call: {exit_code: 0})
      cli, = build_test_cli(start_command: start_command, launch_command: launch_command)

      [["start", "--play", "", "PROJ-1"], ["start", "--play", ",", "PROJ-1"], ["launch", "--play", "", "api"], ["launch", "--play", " , ", "api"]].each do |argv|
        expect { cli.run(argv) }.to raise_error(FakeSystemExit)
      end
      expect(start_command).not_to have_received(:call)
      expect(launch_command).not_to have_received(:call)
    end

    it "refuses more than 20 plays on launch before anything is launched" do
      launch_command = double("launch", call: {exit_code: 0})
      cli, _, error_output = build_test_cli(launch_command: launch_command)

      expect { cli.run(["launch", "--play", (1..21).map { |i| "p#{i}" }.join(","), "api"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("at most 20 plays")
      expect(launch_command).not_to have_received(:call)
    end

    it "sends no packs on relaunch or restore" do
      composer = instance_double(Workspace::InstructionComposer)
      allow(composer).to receive(:compose_start)
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      tmux = FakeTmux.new
      allow(tmux).to receive(:sessions).and_return(["proj1"])
      window_manager = CLITestHelpers::FakeWindowManager.new
      allow(window_manager).to receive(:iterm_windows).and_return({123 => "workspace-proj1"})
      cli, = build_test_cli(state: state, tmux: tmux, iterm: CLITestHelpers::FakeITerm.new, window_manager: window_manager, instruction_composer: composer)

      cli.run(["relaunch", "--all"])

      expect(composer).not_to have_received(:compose_start)
    end

    it "passes --pack and --no-packs through to start, and refuses both together" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, _, error_output = build_test_cli(start_command: start_command)

      cli.run(["start", "--pack", "review", "--pack", "commits", "PROJ-1"])
      cli.run(["start", "--no-packs", "PROJ-2"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, packs: %w[review commits])
      expect(start_command).to have_received(:call).with("PROJ-2", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, no_packs: true)
      expect { cli.run(["start", "--no-packs", "--pack", "review", "PROJ-3"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--no-packs cannot be combined with --pack")
      expect(start_command).not_to have_received(:call).with("PROJ-3", any_args)
    end

    it "passes --title-from-ticket and --slug (either spelling of a value flag) through to start" do
      start_command = double("start", call: {exit_code: 0})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--title-from-ticket", "--title=Mine", "PROJ-1"])
      cli.run(["start", "--slug", "PROJ-2"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, title: "Mine", title_from_ticket: true)
      expect(start_command).to have_received(:call).with("PROJ-2", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, slug: true)
    end

    it "passes --no-launch and --agent-kind (in either spelling) through to start" do
      start_command = double("start", call: {exit_code: 0})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--no-launch", "--agent-kind=codex", "PROJ-1"])
      cli.run(["start", "--agent-kind", "claude", "PROJ-2"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, no_launch: true, agent_kind: "codex")
      expect(start_command).to have_received(:call).with("PROJ-2", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, agent_kind: "claude")
    end

    it "passes --spine, --spine=NAME and --no-spine through to start, without eating the ref, and refuses both" do
      start_command = double("start", call: {exit_code: 0})
      cli, _, error_output = build_test_cli(start_command: start_command)

      cli.run(["start", "--spine", "PROJ-1"])
      cli.run(["start", "--spine=team", "PROJ-2"])
      cli.run(["start", "--no-spine", "PROJ-3"])

      expect(start_command).to have_received(:call).with("PROJ-1", hash_including(spine: true))
      expect(start_command).to have_received(:call).with("PROJ-2", hash_including(spine: "team"))
      expect(start_command).to have_received(:call).with("PROJ-3", hash_including(spine: false))
      expect { cli.run(["start", "--spine", "--no-spine", "PROJ-4"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--spine cannot be combined with --no-spine")
      expect(start_command).not_to have_received(:call).with("PROJ-4", anything)
    end

    it "passes --plan and --plan=TITLE through to start, without eating the ref" do
      start_command = double("start", call: {exit_code: 0})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--plan", "PROJ-1"])
      cli.run(["start", "--plan=Add SSO", "PROJ-2"])
      cli.run(["start", "PROJ-3"])

      expect(start_command).to have_received(:call).with("PROJ-1", hash_including(plan: true))
      expect(start_command).to have_received(:call).with("PROJ-2", hash_including(plan: "Add SSO"))
      expect(start_command).to have_received(:call).with("PROJ-3", hash_not_including(:plan))
    end

    it "passes --handoff and --no-handoff through to start, and refuses --handoff with --no-packs" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, _, error_output = build_test_cli(start_command: start_command)

      cli.run(["start", "--handoff", "PROJ-1"])
      cli.run(["start", "--no-handoff", "--no-packs", "PROJ-2"])
      cli.run(["start", "PROJ-4"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, handoff: true)
      expect(start_command).to have_received(:call).with("PROJ-2", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, no_packs: true, handoff: false)
      expect(start_command).to have_received(:call).with("PROJ-4", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false)
      expect { cli.run(["start", "--no-packs", "--handoff", "PROJ-3"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--no-packs cannot be combined with --handoff")
      expect(start_command).not_to have_received(:call).with("PROJ-3", any_args)
    end

    it "passes repeated --agent and --skill through to start" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, _, error_output = build_test_cli(start_command: start_command)

      cli.run(["start", "--agent", "reviewer", "--skill", "write-tests", "--agent", "agent/planner", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: false, agents: ["reviewer", "agent/planner"], skills: ["write-tests"])
      expect { cli.run(["start"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--agent NAME").and include("--skill NAME")
    end

    it "documents --play in launch and start help" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["launch"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["start"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string.scan("--play NAME").size).to eq(2)
      expect(error_output.string.scan("--no-packs").size).to eq(2)
    end

    it "passes --base and --yes through to start" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--base", "develop", "--yes", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: "develop", yes: true, json: false)
    end

    it "passes json: true to start with --json" do
      start_command = double("start", call: {exit_code: 0})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--json", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: true)
    end

    it "emits a JSON usage error instead of raising when --json start is missing an argument" do
      output = StringIO.new
      cli, = build_test_cli(output: output)

      expect { cli.run(["start", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      payload = JSON.parse(output.string)
      expect(payload["schema_version"]).to eq(1)
      expect(payload).to have_key("error")
    end

    it "rejects a non-positive --prompt-timeout" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["launch", "--prompt-timeout", "0", "myproject"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--prompt-timeout")
    end
  end

  describe "#run failure envelope" do
    def raising(error)
      Class.new {
        define_method(:call) { |*_args, **_opts| raise error }
      }.new
    end

    def run_failing(argv, error)
      cli, output, error_output = build_test_cli(parent_command: raising(error))
      status = nil
      begin
        cli.run(argv)
      rescue FakeSystemExit => e
        status = e.status
      end
      [status, output.string, error_output.string]
    end

    it "prints Error: on stderr without --json" do
      status, out, err = run_failing(["parent", "x"], Workspace::Error.new("boom", code: "unknown_workspace"))
      expect([status, out, err]).to eq([1, "", "Error: boom\n"])
    end

    it "prints one envelope on stdout and nothing on stderr with --json" do
      error = Workspace::Error.new("Unknown workspace 'x'", code: "unknown_workspace", details: {"name" => "x"})
      status, out, err = run_failing(["parent", "x", "--json"], error)
      expect(status).to eq(1)
      expect(err).to eq("")
      expect(JSON.parse(out)).to eq(
        "schema_version" => 1, "ok" => false, "error" => "Unknown workspace 'x'",
        "code" => "unknown_workspace", "details" => {"name" => "x"}
      )
    end

    it "includes retry when the error has one" do
      error = Workspace::UnsavedWorkError.new("unsaved", unsaved: {changed_files: 2, unpushed_commits: 0, branch: "b"})
      _, out, _ = run_failing(["parent", "--json"], error)
      expect(JSON.parse(out)).to include("code" => "unsaved_work", "retry" => {"flags" => ["--force"], "destructive" => true})
    end

    it "treats --json-envelope as a request for the failure envelope" do
      _, out, err = run_failing(["parent", "x", "--json-envelope"], Workspace::Error.new("boom", code: "unknown_workspace"))
      expect(err).to eq("")
      expect(JSON.parse(out)).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "finds --json in any position before --" do
      _, out, _ = run_failing(["parent", "--json", "x"], Workspace::Error.new("boom"))
      expect(JSON.parse(out)).to include("ok" => false, "code" => "error")
    end

    it "ignores --json after a bare --" do
      _, out, err = run_failing(["parent", "--", "--json"], Workspace::Error.new("boom"))
      expect([out, err]).to eq(["", "Error: boom\n"])
    end

    it "reports a usage error with the first line only and the usage code" do
      _, out, err = run_failing(["parent", "--json"], Workspace::UsageError.new("Usage: workspace parent\n\nmore help"))
      expect(err).to eq("")
      expect(JSON.parse(out)).to include("ok" => false, "error" => "Usage: workspace parent", "code" => "usage")
    end

    it "prints the full usage text on stderr without --json" do
      _, _, err = run_failing(["parent"], Workspace::UsageError.new("Usage: workspace parent\n\nmore help"))
      expect(err).to eq("Usage: workspace parent\n\nmore help\n")
    end

    it "keeps the exit code of a not-submitted error and gives it its code" do
      error = Workspace::Commands::Run::NotSubmittedError.new("typed but not sent")
      status, out, _ = run_failing(["parent", "--json"], error)
      expect(status).to eq(Workspace::Commands::Run::NotSubmittedError::EXIT_CODE)
      expect(JSON.parse(out)).to include("code" => "not_submitted", "error" => "typed but not sent")
    end

    it "reports an option parse error as a usage envelope" do
      cli, output, error_output = build_test_cli
      expect { cli.run(["parent", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to eq("")
      expect(JSON.parse(output.string)).to include("ok" => false, "error" => "invalid option: --bogus", "code" => "usage")
    end

    it "reports an unknown subcommand as a usage envelope with --json" do
      cli, output, error_output = build_test_cli
      expect { cli.run(["bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to eq("")
      expect(JSON.parse(output.string)).to include("ok" => false, "error" => "Unknown subcommand: bogus", "code" => "usage")
    end

    it "makes sessions --json outside a workspace an envelope instead of usage text" do
      cli, output, error_output = build_test_cli
      expect { cli.run(["sessions", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to eq("")
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "ok" => false, "code" => "usage")
    end

    it "reports a leading flag as a usage envelope with --json" do
      cli, output, error_output = build_test_cli
      expect { cli.run(["--headless", "launch", "--json"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to eq("")
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(JSON.parse(output.string)["error"]).to start_with("Unknown option before the subcommand: --headless")
    end
  end

  describe "#run with config" do
    it "exits 1 when no project specified and not --global" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace config")
    end

    it "shows project config with --name" do
      project_settings = CLITestHelpers::FakeProjectSettings.new(loader: ->(_name) { {"hooks" => {"post_launch" => "echo hi"}} })

      cli, output, _ = build_test_cli(project_settings: project_settings)
      cli.run(["config", "--name", "myproject"])

      expect(output.string).to include("post_launch")
      expect(output.string).to include("echo hi")
    end

    it "shows global config with --global" do
      project_settings = CLITestHelpers::FakeProjectSettings.new(global: {"layouts" => {"equal" => "even-vertical"}})

      cli, output, _ = build_test_cli(project_settings: project_settings)
      cli.run(["config", "--global"])

      expect(output.string).to include("equal")
      expect(output.string).to include("even-vertical")
    end

    it "reports when no project config found" do
      cli, output, _ = build_test_cli
      cli.run(["config", "--name", "nonexistent"])

      expect(output.string).to include("no config found for 'nonexistent'")
    end

    it "prints a key's effective value" do
      report = Class.new do
        attr_reader :shown

        def show(name, key: nil)
          @shown = [[name, key]]
          {"keys" => [{"key" => "dev.stop_timeout", "value" => "20", "effective" => "20"}]}
        end
      end.new
      detector = instance_double(Workspace::ProjectDetector, detect: "myproject")
      cli, output, _ = build_test_cli(config_report: report, project_detector: detector)

      cli.run(["config", "dev.stop_timeout"])

      expect(report.shown).to eq([["myproject", "dev.stop_timeout"]])
      expect(output.string).to include("20")
    end

    it "exits 1 with usage for an unknown key" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "bogus.key"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown config key 'bogus.key'")
    end

    it "reads a key with --global as --scope global" do
      shown = []
      report = ScriptedConfigReport.new { |name, **opts| shown << [name, opts] and {"keys" => [{"key" => "dev.up", "effective" => "x"}]} }
      cli, output, _ = build_test_cli(config_report: report)
      cli.run(["config", "dev.up", "--global", "--name", "api"])
      expect(shown).to eq([["api", {key: "dev.up", scope: "global"}]])
      expect(output.string).to include("x")
    end

    def key_cli_for(row)
      report = Class.new do
        attr_reader :shown

        def initialize(row)
          @row = row
        end

        def show(name, key: nil)
          @shown = [[name, key]]
          {"keys" => [@row]}
        end
      end.new(row)
      detector = instance_double(Workspace::ProjectDetector, detect: "myproject")
      build_test_cli(config_report: report, project_detector: detector)
    end

    it "prints false for a boolean key, not nothing" do
      cli, output, _ = key_cli_for({"key" => "handoff.auto", "effective" => false})

      cli.run(["config", "handoff.auto"])

      expect(output.string).to eq("false\n")
    end

    it "prints the effective path for a notes key" do
      cli, output, _ = key_cli_for({"key" => "notes.dir", "effective_path" => "/notes/api"})

      cli.run(["config", "notes.dir"])

      expect(output.string).to eq("/notes/api\n")
    end

    it "prints YAML for a mapping key" do
      cli, output, _ = key_cli_for({"key" => "hooks", "effective" => {"post_launch" => "echo hi"}})

      cli.run(["config", "hooks"])

      expect(output.string).to include("post_launch: echo hi")
    end

    it "exits 1 with a stderr note for an unset key" do
      cli, output, error_output = key_cli_for({"key" => "dev.ready", "effective" => nil})

      expect { cli.run(["config", "dev.ready"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(output.string).to be_empty
      expect(error_output.string).to include("dev.ready is not set")
    end

    it "exits 1 with a stderr note for a notes key with no path" do
      cli, output, error_output = key_cli_for({"key" => "notes.dir", "effective_path" => nil})

      expect { cli.run(["config", "notes.dir"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(output.string).to be_empty
      expect(error_output.string).to include("notes.dir is not set")
    end

    it "prints only set/unset status for a sensitive key, never the value" do
      cli, output, error_output = key_cli_for({"key" => "dev.up", "sensitive" => true, "source_file" => "/cfg/api.yml"})

      cli.run(["config", "dev.up"])

      expect(output.string).to be_empty
      expect(error_output.string).to include("dev.up is set in /cfg/api.yml")
    end

    it "exits 1 when a sensitive key is not set" do
      cli, output, error_output = key_cli_for({"key" => "dev.up", "sensitive" => true, "source_file" => nil})

      expect { cli.run(["config", "dev.up"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(output.string).to be_empty
      expect(error_output.string).to include("dev.up is not set")
    end
  end

  describe "#run with statusline" do
    it "dispatches to statusline_command" do
      statusline_command = CLITestHelpers::FakeStatuslineCommand.new
      cli, = build_test_cli(statusline_command: statusline_command)

      cli.run(["statusline"])

      expect(statusline_command.calls).to eq([{action: :call}])
    end

    it "exits with the command's exit code" do
      statusline_command = CLITestHelpers::FakeStatuslineCommand.new(result: {exit_code: 0})
      cli, = build_test_cli(statusline_command: statusline_command)

      expect { cli.run(["statusline"]) }.not_to raise_error
    end

    it "rejects extra arguments" do
      cli, = build_test_cli

      expect { cli.run(["statusline", "bogus"]) }.to raise_error(FakeSystemExit)
    end
  end

  describe "#run with ask" do
    it "treats a first word of list as the subcommand when --default is absent" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, _, _ = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "list", "--json"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :list, json: true))
    end

    it "records a question named after a subcommand when --default= is given inline" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, _, _ = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "resolve", "--default=x"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :call, question: "resolve", default: "x"))
    end

    it "passes --deliver to ask answer, with the id and answer after --" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "answer", "--deliver", "--json", "--", "q_7", "-y"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :answer, id: "q_7", answer: "-y", deliver: true, json: true))
    end

    it "passes --all to ask list" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "list", "--all"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :list, all: true))
    end

    it "dispatches ask withdraw with the id" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "withdraw", "q_7", "--json"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :withdraw, id: "q_7", json: true))
    end

    it "dispatches ask deliver with the id and --pane" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "deliver", "q_7", "--pane", "%19", "--json"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :deliver, id: "q_7", pane: "%19", json: true))
    end

    it "reports a missing id for ask deliver as JSON under --json" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      expect { cli.run(["ask", "deliver", "--json"]) }.to raise_error(FakeSystemExit)
      expect(ask_command.calls).to be_empty
    end

    it "requires an id for ask deliver" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      expect { cli.run(["ask", "deliver"]) }.to raise_error(FakeSystemExit)
    end

    it "treats withdraw as the question text when --default is given" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "withdraw", "--default", "x"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :call, question: "withdraw"))
    end

    it "gives the usage help, not unknown_workspace, for an unquoted question when no workspace has the first word's name" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      pc = CLITestHelpers::FakeProjectConfig.new
      allow(pc).to receive(:existing_name).and_return(nil)
      cli, _, error_output = build_test_cli(ask_command: ask_command, project_config: pc)

      expect { cli.run(["ask", "Use", "sqlite", "--default", "x"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Usage: workspace ask")
      expect(error_output.string).not_to include("unknown_workspace")
      expect(ask_command.calls).to be_empty
    end

    it "takes the first positional as the workspace when a workspace of that name exists" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      pc = CLITestHelpers::FakeProjectConfig.new("api" => "/api")
      allow(pc).to receive(:existing_name) { |name| (name == "api") ? "api" : nil }
      cli, = build_test_cli(ask_command: ask_command, project_config: pc)

      cli.run(["ask", "api", "Which db?", "--default", "x"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :call, question: "Which db?"))
    end

    it "does not deliver unless asked" do
      ask_command = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(ask_command: ask_command)

      cli.run(["ask", "answer", "q_7", "yes"])

      expect(ask_command.calls).to contain_exactly(a_hash_including(action: :answer, deliver: false))
    end
  end

  describe "#run with inbox" do
    let(:inbox_command) { instance_double(Workspace::Commands::Inbox) }
    let(:built) { build_test_cli(inbox_command: inbox_command, project_config: CLITestHelpers::FakeProjectConfig.new("ws" => "/ws")) }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "passes add its title, options and scope to the command" do
      expect(inbox_command).to receive(:add).with(
        title: "Check it", target: {global: true}, working_dir: anything, type: "alert", body: "b",
        source: {kind: "jira", url: "https://x.test/1"}, links: {pr: 7}, expires: "2h", as_user: true
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "add", "Check it", "--global", "--type=alert", "--body", "b", "--source-kind", "jira",
        "--source-url=https://x.test/1", "--link-pr", "7", "--expires", "2h", "--as-user"])
    end

    it "passes every add option to the command" do
      expect(inbox_command).to receive(:add).with(
        title: "T", target: {name: "ws"}, working_dir: "/ws", type: "todo", body_file: "-",
        source: {ref: "r"}, links: {pane: "%2", plan_task: "T1", run_id: "run1"}
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "add", "T", "--name", "ws", "--body-file", "-", "--source-ref", "r", "--link-pane", "%2",
        "--link-plan-task", "T1", "--link-run", "run1"])
    end

    it "passes --note to add" do
      expect(inbox_command).to receive(:add).with(
        title: "T", target: {}, working_dir: anything, type: "note", source: {}, links: {}, note: "findings.md"
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "add", "T", "--type", "note", "--note", "findings.md"])
    end

    it "passes --dedupe-key and --reopen to add" do
      expect(inbox_command).to receive(:add).with(
        title: "T", target: {global: true}, working_dir: anything, type: "todo", source: {}, links: {},
        dedupe_key: "ci:1", reopen: true
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "add", "T", "--global", "--dedupe-key", "ci:1", "--reopen"])
    end

    it "passes done and dismiss a --dedupe-key with no ids, and plain ids without one" do
      expect(inbox_command).to receive(:done).with([], target: {global: true}, working_dir: anything, dedupe_key: "ci:1")
        .and_return({exit_code: 0, results: []})
      expect(inbox_command).to receive(:dismiss).with(["abc"], target: {}, working_dir: anything)
        .and_return({exit_code: 0, results: []})

      cli.run(["inbox", "done", "--dedupe-key=ci:1", "--global"])
      cli.run(["inbox", "dismiss", "abc"])
    end

    it "passes edit its id, the changed fields, links and scope" do
      expect(inbox_command).to receive(:edit).with(
        "abc", target: {global: true}, working_dir: anything, title: "T", body: "", expires: "2h",
        links: {pr: 7, pane: "", run_id: "r1"}
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "edit", "abc", "--global", "--title", "T", "--body", "", "--expires", "2h",
        "--link-pr", "7", "--link-pane", "", "--link-run", "r1"])
    end

    it "passes edit --no-expires and --body-file, and refuses edit without an id" do
      expect(inbox_command).to receive(:edit).with(
        "abc", target: {}, working_dir: anything, links: {}, no_expires: true, body_file: "-"
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "edit", "abc", "--no-expires", "--body-file", "-"])
      expect { cli.run(["inbox", "edit", "--title", "T"]) }.to raise_error(FakeSystemExit)
    end

    it "passes snooze its ids, the wake option and scope" do
      expect(inbox_command).to receive(:snooze).with(
        ["abc", "def"], target: {global: true}, working_dir: anything, for_duration: "2h"
      ).and_return({exit_code: 0, results: []})
      expect(inbox_command).to receive(:snooze).with(
        ["abc"], target: {}, working_dir: anything, until_time: "2026-10-20T09:00:00Z"
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "snooze", "abc", "def", "--for", "2h", "--global"])
      cli.run(["inbox", "snooze", "abc", "--until=2026-10-20T09:00:00Z"])
    end

    it "passes ack its ids and scope, and refuses ack without an id" do
      expect(inbox_command).to receive(:ack).with(
        ["pane:waiting:api:%5", "plan:blocked:api"], target: {global: true}, working_dir: anything
      ).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "ack", "pane:waiting:api:%5", "plan:blocked:api", "--global"])
      expect { cli.run(["inbox", "ack"]) }.to raise_error(FakeSystemExit)
    end

    it "prints ack as an action document and exits 3 when some ids failed" do
      rows = [{"id" => "a:1", "outcome" => "acked"}, {"id" => "ask:x:1", "outcome" => "failed", "code" => "use_ask_answer"}]
      allow(inbox_command).to receive(:ack).and_return({exit_code: 3, results: rows})

      expect { cli.run(["inbox", "ack", "a:1", "ask:x:1", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
      doc = JSON.parse(output.string)
      expect(doc).to include("action" => "inbox ack", "status" => "partial")
    end

    it "refuses snooze without an id" do
      expect { cli.run(["inbox", "snooze", "--for", "2h"]) }.to raise_error(FakeSystemExit)
    end

    it "refuses reopen --dedupe-key and done with neither ids nor a key" do
      expect { cli.run(["inbox", "reopen", "--dedupe-key", "k"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["inbox", "done"]) }.to raise_error(FakeSystemExit)
    end

    it "passes --from-json to add_from_json" do
      expect(inbox_command).to receive(:add_from_json).with("-", working_dir: anything).and_return({exit_code: 0, results: []})

      cli.run(["inbox", "add", "--from-json", "-"])
    end

    it "accepts --from-json=PATH under --json" do
      row = {"id" => "a1b2c3d4e5", "outcome" => "created"}
      expect(inbox_command).to receive(:add_from_json).with("/p.json", working_dir: anything).and_return({exit_code: 0, results: [row]})

      cli.run(["inbox", "add", "--from-json=/p.json", "--json"])

      expect(JSON.parse(output.string)).to include("action" => "inbox add", "results" => [row])
    end

    it "refuses --from-json mixed with a title, a scope or an item flag" do
      [["T"], ["--global"], ["--type", "todo"], ["--type=alert"], ["--body", "b"], ["--as-user"], ["--expires", "2h"]].each do |extra|
        expect { cli.run(["inbox", "add", "--from-json", "-", *extra]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(built[2].string).to include("--from-json takes the whole item")
        built[2].truncate(0)
        built[2].rewind
      end
    end

    it "routes show with a scope flag under --json" do
      expect(inbox_command).to receive(:show).with("abc", target: {global: true}, working_dir: anything, json: true).and_return({exit_code: 0})

      cli.run(["inbox", "show", "abc", "--global", "--json"])
    end

    it "wraps add in an action document under --json" do
      row = {"id" => "a1b2c3d4e5", "outcome" => "created"}
      allow(inbox_command).to receive(:add).and_return({exit_code: 0, results: [row]})

      cli.run(["inbox", "add", "x", "--json"])

      expect(JSON.parse(output.string)).to include("action" => "inbox add", "status" => "ok", "results" => [row])
    end

    it "passes list filters through" do
      expect(inbox_command).to receive(:list).with(
        target: {project: "api"}, working_dir: anything, states: %w[open snoozed], type: "note", all: false, include_derived: false, json: true
      ).and_return({exit_code: 0})

      cli.run(["inbox", "list", "--project", "api", "--state", "open,snoozed", "--type", "note", "--json"])
    end

    it "passes --include-derived to list" do
      expect(inbox_command).to receive(:list).with(hash_including(all: true, include_derived: true)).and_return({exit_code: 0})

      cli.run(["inbox", "list", "--all", "--include-derived"])
    end

    it "routes show with the id" do
      expect(inbox_command).to receive(:show).with("a1b2c3d4e5", target: {}, working_dir: anything, json: false).and_return({exit_code: 0})

      cli.run(["inbox", "show", "a1b2c3d4e5"])
    end

    %w[done dismiss reopen].each do |verb|
      it "routes inbox #{verb} with every id and the scope" do
        expect(inbox_command).to receive(verb.to_sym).with(%w[a1 b2], target: {global: true}, working_dir: anything)
          .and_return({exit_code: 0, results: []})

        cli.run(["inbox", verb, "a1", "--global", "b2"])
      end
    end

    it "wraps done in an action document and exits 3 when partial" do
      rows = [{"id" => "a1", "outcome" => "resolved"}, {"id" => "b2", "outcome" => "failed", "code" => "unknown_inbox_item"}]
      allow(inbox_command).to receive(:done).and_return({exit_code: 3, results: rows})

      expect { cli.run(["inbox", "done", "a1", "b2", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
      expect(JSON.parse(output.string)).to include("action" => "inbox done", "status" => "partial", "results" => rows)
    end

    it "needs at least one id to resolve" do
      expect { cli.run(["inbox", "done", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "reports a missing title as a usage error in the JSON envelope" do
      expect { cli.run(["inbox", "add", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "reports an unknown subcommand as a usage error" do
      expect { cli.run(["inbox", "bogus", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "prints help for no subcommand" do
      cli.run(["inbox"])

      expect(output.string).to include("workspace inbox add TITLE")
    end
  end

  describe "#run with config show/validate --json" do
    let(:report) do
      Class.new do
        attr_reader :calls

        def initialize(valid: true)
          @calls = []
          @valid = valid
        end

        def show(name, key: nil)
          @calls << [:show, name]
          {"schema_version" => 1, "ok" => true, "workspace" => name, "keys" => [{"key" => key || "dev.up", "value" => "bin/dev"}]}
        end

        def validate(name)
          @calls << [:validate, name]
          problems = @valid ? [] : [{"severity" => "error", "code" => "yaml_syntax", "file" => "/c/p.yml", "line" => 3, "column" => 1, "message" => "bad"}]
          {"schema_version" => 1, "ok" => true, "valid" => @valid, "workspace" => name, "problems" => problems}
        end
      end
    end

    it "prints the show document for --name" do
      fake = report.new
      cli, output, _ = build_test_cli(config_report: fake)

      cli.run(["config", "show", "--name", "api", "--json"])

      expect(JSON.parse(output.string)).to include("ok" => true, "workspace" => "api")
      expect(fake.calls).to eq([[:show, "api"]])
    end

    it "accepts --json without the show word and a positional key" do
      fake = report.new
      detector = instance_double(Workspace::ProjectDetector, detect: "api")
      cli, output, _ = build_test_cli(config_report: fake, project_detector: detector)

      cli.run(["config", "--json", "dev.up"])

      doc = JSON.parse(output.string)
      expect(doc["workspace"]).to eq("api")
      expect(doc["keys"]).to eq([{"key" => "dev.up", "value" => "bin/dev"}])
    end

    it "uses the workspace detected from the working directory without --name" do
      fake = report.new
      detector = instance_double(Workspace::ProjectDetector, detect: "detected")
      cli, _, _ = build_test_cli(config_report: fake, project_detector: detector)

      cli.run(["config", "show", "--json"])

      expect(fake.calls).to eq([[:show, "detected"]])
    end

    it "treats --global --json as --scope global" do
      scoped = Class.new(report) do
        def show(name, key: nil, scope: nil)
          super(name, key: key).merge("scope" => scope)
        end
      end.new
      cli, output, _ = build_test_cli(config_report: scoped)

      cli.run(["config", "show", "--global", "--json", "--name", "api"])

      expect(JSON.parse(output.string)).to include("ok" => true, "scope" => "global")
    end

    it "shows a workspace literally named show through --name" do
      project_settings = CLITestHelpers::FakeProjectSettings.new(loader: ->(name) { {"dev" => {"up" => name}} })
      cli, output, _ = build_test_cli(project_settings: project_settings)

      cli.run(["config", "--name", "show"])

      expect(output.string).to include("up: show")
    end

    it "refuses a workspace name as a positional argument" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["config", "--", "show"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown config key 'show'")
    end

    it "validate prints the document and exits 0 when valid" do
      cli, output, _ = build_test_cli(config_report: report.new)

      cli.run(["config", "validate", "--name", "api", "--json"])

      expect(JSON.parse(output.string)).to include("valid" => true, "problems" => [])
    end

    it "validate exits 1 after printing the document when a problem is an error" do
      cli, output, _ = build_test_cli(config_report: report.new(valid: false))

      expect { cli.run(["config", "validate", "--name", "api", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => true, "valid" => false)
    end

    it "validate prints one line per problem without --json" do
      cli, output, _ = build_test_cli(config_report: report.new(valid: false))

      expect { cli.run(["config", "validate", "--name", "api"]) }.to raise_error(FakeSystemExit)

      expect(output.string).to eq("error: /c/p.yml:3:1: bad\n")
    end

    it "validate says so when there is nothing to report" do
      cli, output, _ = build_test_cli(config_report: report.new)

      cli.run(["config", "validate", "--name", "api"])

      expect(output.string).to eq("No problems found in the config for 'api'.\n")
    end

    it "validate with an extra argument exits 1 with its page" do
      cli, _, error_output = build_test_cli(config_report: report.new)

      expect { cli.run(["config", "validate", "extra"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("Usage: workspace config validate")
    end

    it "validate outside a workspace says so and shows its page" do
      cli, _, error_output = build_test_cli(config_report: report.new)

      expect { cli.run(["config", "validate"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("Not in a workspace. Pass --name <workspace>.", "Usage: workspace config validate")
    end

    it "show outside a workspace says so and shows its page" do
      cli, _, error_output = build_test_cli(config_report: report.new)

      expect { cli.run(["config", "show"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("Not in a workspace. Pass --name <workspace>.", "Usage: workspace config show")
    end
  end

  describe "#run with tmux show" do
    let(:reporter) do
      Class.new do
        def show(name)
          {"schema_version" => 1, "ok" => true, "workspace" => name, "file" => "/t/workspace.#{name}.yml", "parse_error" => nil,
           "session" => {"name" => name, "root" => "/src"}, "running" => false,
           "windows" => [{"index" => 0, "name" => "w", "layout" => "even-vertical",
                          "panes" => [{"index" => 0, "kind" => "claude", "command" => "claude --continue\nmore"}]}]}
        end
      end
    end

    it "prints the document with --json" do
      cli, output, _ = build_test_cli(tmuxinator_report: reporter.new)

      cli.run(["tmux", "show", "--name", "api", "--json"])

      expect(JSON.parse(output.string)).to include("ok" => true, "workspace" => "api")
    end

    it "prints a readable summary without --json" do
      cli, output, _ = build_test_cli(tmuxinator_report: reporter.new)

      cli.run(["tmux", "show", "--name", "api"])

      expect(output.string).to include("session api", "window 0 w (even-vertical)", "pane 0 [claude] claude --continue")
      expect(output.string).not_to include("more")
    end

    it "prints usage for a bare tmux and rejects an unknown action" do
      cli, output, _ = build_test_cli(tmuxinator_report: reporter.new)
      cli.run(["tmux"])
      expect(output.string).to include("Usage: workspace tmux show")

      expect { cli.run(["tmux", "bogus"]) }.to raise_error(FakeSystemExit)
    end
  end

  describe "#run with config set/get/unset" do
    it "dispatches set to config_command with key, value, and cwd" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, _, _ = build_test_cli(config_command: config_command, working_dir: "/tmp/some-project")

      cli.run(["config", "set", "dev.up", "./start-dev"])

      expect(config_command.calls).to eq([{action: :set, key: "dev.up", value: "./start-dev", project: nil, scope: nil, cwd: "/tmp/some-project"}])
    end

    it "passes --project through to config_command#set" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, _, _ = build_test_cli(config_command: config_command)

      cli.run(["config", "set", "--project", "otherapp", "dev.ready", "port:3000"])

      expect(config_command.calls.first[:project]).to eq("otherapp")
    end

    it "dispatches get to config_command with key and cwd" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, _, _ = build_test_cli(config_command: config_command, working_dir: "/tmp/some-project")

      cli.run(["config", "get", "dev.up"])

      expect(config_command.calls).to eq([{action: :get, key: "dev.up", project: nil, scope: nil, cwd: "/tmp/some-project"}])
    end

    it "exits 1 when config_command#get reports the key is unset" do
      config_command = CLITestHelpers::FakeConfigCommand.new(get_returns: false)
      cli, _, _ = build_test_cli(config_command: config_command)

      expect { cli.run(["config", "get", "dev.up"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end

    it "exits 0 when config_command#get reports the key is set" do
      config_command = CLITestHelpers::FakeConfigCommand.new(get_returns: true)
      cli, _, _ = build_test_cli(config_command: config_command)

      expect { cli.run(["config", "get", "dev.up"]) }.not_to raise_error
    end

    it "dispatches unset to config_command with key and cwd" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, _, _ = build_test_cli(config_command: config_command, working_dir: "/tmp/some-project")

      cli.run(["config", "unset", "dev.ready"])

      expect(config_command.calls).to eq([{action: :unset, key: "dev.ready", project: nil, scope: nil, cwd: "/tmp/some-project"}])
    end

    it "exits 1 with a clean usage error instead of a backtrace when the value looks like a flag" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "set", "locks.idle_grace", "-5m"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("durations must be positive")
    end

    it "exits 1 with usage when set is missing a key or value" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "set", "dev.up"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace config set")
    end

    it "exits 1 with usage when get is missing a key" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "get"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace config get")
    end

    it "exits 1 with usage when unset is missing a key" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "unset"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace config unset")
    end

    it "exits 1 with the edit page when edit is given extra arguments" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config", "edit", "one", "two"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace config edit")
    end

    it "prints the set page for config set --help, naming config keys --settable" do
      cli, output, _ = build_test_cli

      cli.run(["config", "set", "--help"])

      expect(output.string).to include("Usage: workspace config set", "workspace config keys --settable", "Examples:")
    end

    describe "--scope" do
      def json_cli(**overrides)
        raw = StringIO.new
        gate = Workspace::OutputGate.new(raw)
        cli, = build_test_cli(output: gate, error_output: StringIO.new, **overrides)
        [cli, raw]
      end

      it "passes the scope to set, get and unset, and maps worktree to workspace" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        cli, = build_test_cli(config_command: config_command)

        cli.run(["config", "set", "--scope", "project", "dev.up", "x"])
        cli.run(["config", "set", "--scope", "worktree", "dev.up", "x"])
        cli.run(["config", "get", "--scope", "global", "dev.up"])
        cli.run(["config", "unset", "--scope", "workspace", "dev.up"])

        expect(config_command.calls.map { |c| [c[:action], c[:scope]] }).to eq([[:set, "project"], [:set, "workspace"], [:get, "global"], [:unset, "workspace"]])
      end

      it "reads a value that starts with a dash after --" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        cli, = build_test_cli(config_command: config_command)

        cli.run(["config", "set", "--scope", "project", "--name", "api", "dev.up", "--", "-x --flag"])

        expect(config_command.calls.first).to include(key: "dev.up", value: "-x --flag", scope: "project", project: "api")
      end

      it "refuses a scope that is not global, project or workspace as a usage error" do
        cli, _, error_output = build_test_cli
        expect { cli.run(["config", "set", "--scope", "team", "dev.up", "x"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("Unknown scope 'team'. Use global, project or workspace.")
      end

      it "prints unknown_config_key as an envelope for set and unset under --json" do
        %w[set unset].each do |verb|
          command = Workspace::Commands::Config.new(project_settings: CLITestHelpers::FakeProjectSettings.new, lineage: LineageSupport.lineage,
            file_backup: Workspace::FileBackup.new(output: StringIO.new))
          cli, raw = json_cli(config_command: command)

          expect { cli.run(["config", verb, "no.such", "--json"] + ((verb == "set") ? ["x"] : [])) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

          expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "unknown_config_key", "details" => {"key" => "no.such"})
        end
      end

      it "takes a value that starts with a dash only after --" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        cli, _, error_output = build_test_cli(config_command: config_command)

        expect { cli.run(["config", "set", "dev.up", "-x"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("looks like a flag")
        expect(config_command.calls).to be_empty

        cli.run(["config", "set", "dev.up", "--", "-x"])
        expect(config_command.calls.first).to include(key: "dev.up", value: "-x")
      end

      it "prints a noop row when unset finds nothing to remove" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        config_command.handlers[:unset] = lambda do |key, **|
          Workspace::Commands::Config::Result.new(key: key, workspace: "api", layer: "project", scope: "project", path: "/cfg/api.yml", comments_preserved: true, backup: nil, affects: [], changed: false)
        end
        cli, raw = json_cli(config_command: config_command)

        cli.run(["config", "unset", "--name", "api", "dev.ready", "--json"])

        expect(JSON.parse(raw.string)["results"].first).to include("outcome" => "noop", "key" => "dev.ready")
      end

      it "prints the set row with scope, layer, file and the effective value after the write" do
        report = ScriptedConfigReport.new { |name, key: nil| {"keys" => [{"key" => key, "effective" => 90}]} }
        cli, raw = json_cli(config_command: CLITestHelpers::FakeConfigCommand.new, config_report: report)

        cli.run(["config", "set", "--scope", "project", "--name", "api", "dev.ready_timeout", "90s", "--json"])

        expect(JSON.parse(raw.string)["results"].first).to include("workspace" => "api", "outcome" => "set", "scope" => "project", "layer" => "project", "file" => "/cfg/api.yml", "effective" => 90)
      end

      it "gives a null effective when the report fails" do
        report = ScriptedConfigReport.new { |*, **| raise Workspace::Error.new("Unknown workspace 'api'", code: "unknown_workspace") }
        cli, raw = json_cli(config_command: CLITestHelpers::FakeConfigCommand.new, config_report: report)

        cli.run(["config", "set", "--name", "api", "dev.up", "x", "--json"])

        expect(JSON.parse(raw.string)["results"].first).to include("effective" => nil)
      end

      describe "config keys" do
        let(:config_command) { CLITestHelpers::FakeConfigCommand.new }

        it "passes the query and flags to the command" do
          cli, = build_test_cli(config_command: config_command)

          cli.run(["config", "keys", "timeout", "--settable", "--json"])
          cli.run(["config", "keys"])

          expect(config_command.calls).to eq([
            {action: :keys, query: "timeout", settable: true, json: true},
            {action: :keys, query: nil, settable: false, json: false}
          ])
        end

        it "prints the unknown_config_key error envelope on stdout and exits 1 under --json" do
          raw = StringIO.new
          command = Workspace::Commands::Config.new(project_settings: CLITestHelpers::FakeProjectSettings.new, lineage: LineageSupport.lineage,
            file_backup: Workspace::FileBackup.new(output: StringIO.new))
          cli, = build_test_cli(output: Workspace::OutputGate.new(raw), config_command: command)

          expect { cli.run(["config", "keys", "nosuch", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

          expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "unknown_config_key", "details" => {"key" => "nosuch"})
        end

        it "rejects a second query with usage" do
          cli, _, error_output = build_test_cli(config_command: config_command)

          expect { cli.run(["config", "keys", "a", "b"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          expect(error_output.string).to include("Usage: workspace config keys")
          expect(config_command.calls).to be_empty
        end
      end

      describe "config edit" do
        let(:config_command) { CLITestHelpers::FakeConfigCommand.new }

        it "passes the scope, name and cwd to the command" do
          cli, = build_test_cli(config_command: config_command, working_dir: "/tmp/p", env: {"EDITOR" => "vi"})

          cli.run(["config", "edit", "--scope", "worktree", "--name", "api.worktree-x"])

          expect(config_command.calls).to eq([{action: :edit, project: "api.worktree-x", scope: "workspace", cwd: "/tmp/p"}])
        end

        it "runs $VISUAL ahead of $EDITOR as an argv array, so no shell sees the path" do
          launched = []
          path = "/cfg/my project; rm -rf $HOME.yml"
          config_command.handlers[:edit] = ->(**) { Workspace::Commands::Config::EditResult.new(workspace: "api", layer: "project", scope: "project", path: path, created: false) }
          cli, = build_test_cli(config_command: config_command, env: {"VISUAL" => "code --wait", "EDITOR" => "vi"}, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit"])

          expect(launched).to eq([["code", "--wait", path]])
        end

        it "falls back to $EDITOR" do
          launched = []
          cli, = build_test_cli(config_command: config_command, env: {"VISUAL" => "", "EDITOR" => "nano"}, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit"])

          expect(launched).to eq([["nano", "/cfg/config.yml"]])
        end

        it "prints the path and opens nothing when no editor is set" do
          launched = []
          cli, output, = build_test_cli(config_command: config_command, env: {}, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit", "--scope", "global"])

          expect(launched).to be_empty
          expect(output.string).to eq("/cfg/config.yml\n")
        end

        it "treats blank or whitespace-only $VISUAL and $EDITOR as unset" do
          launched = []
          cli, output, = build_test_cli(config_command: config_command, env: {"VISUAL" => "  ", "EDITOR" => ""}, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit"])

          expect(launched).to be_empty
          expect(output.string).to eq("/cfg/config.yml\n")
        end

        it "prints the path and opens nothing under --no-input" do
          launched = []
          cli, output, = build_test_cli(config_command: config_command, env: {"EDITOR" => "vi"}, input: Workspace::PromptInput.new(StringIO.new), editor_launcher: ->(argv) { launched << argv })

          cli.run(["--no-input", "config", "edit"])

          expect(launched).to be_empty
          expect(output.string).to eq("/cfg/config.yml\n")
        end

        it "prints the path and opens nothing when stdin or stdout is not a terminal" do
          launched = []
          cli, output, = build_test_cli(config_command: config_command, env: {"EDITOR" => "vi"}, interactive: -> { false }, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit"])

          expect(launched).to be_empty
          expect(output.string).to eq("/cfg/config.yml\n")
        end

        it "fails with editor_failed on an unbalanced quote in $EDITOR" do
          launched = []
          cli, _, error_output = build_test_cli(config_command: config_command, env: {"EDITOR" => 'vim "x'}, editor_launcher: ->(argv) { launched << argv })

          expect { cli.run(["config", "edit"]) }.to raise_error(FakeSystemExit)
          expect(error_output.string).to include("$EDITOR is not a valid command").and include("Edit /cfg/config.yml directly.")
          expect(launched).to be_empty
        end

        it "fails when the editor can't be run" do
          cli, _, error_output = build_test_cli(config_command: config_command, env: {"EDITOR" => "nope"}, editor_launcher: ->(_argv) {})

          expect { cli.run(["config", "edit"]) }.to raise_error(FakeSystemExit)
          expect(error_output.string).to include("Could not run the editor 'nope'")
        end

        it "--json prints the path document and opens no editor" do
          launched = []
          cli, raw = json_cli(config_command: config_command, env: {"EDITOR" => "vi"}, editor_launcher: ->(argv) { launched << argv })

          cli.run(["config", "edit", "--scope", "global", "--json"])

          doc = JSON.parse(raw.string)
          expect(doc).to include("ok" => true, "action" => "config edit", "status" => "ok")
          expect(doc["results"].first).to include("outcome" => "ready", "workspace" => nil, "global" => true, "scope" => "global", "layer" => "global", "file" => "/cfg/config.yml", "created" => true)
          expect(launched).to be_empty
        end

        it "rejects an unknown scope" do
          cli, _, error_output = build_test_cli(config_command: config_command)

          expect { cli.run(["config", "edit", "--scope", "nope"]) }.to raise_error(FakeSystemExit)
          expect(error_output.string).to include("Unknown scope 'nope'")
        end
      end

      it "unset --json prints an action document without a value" do
        cli, raw = json_cli(config_command: CLITestHelpers::FakeConfigCommand.new)

        cli.run(["config", "unset", "--scope", "global", "launch.headless", "--json"])

        doc = JSON.parse(raw.string)
        expect(doc).to include("ok" => true, "action" => "config unset")
        expect(doc["results"].first).to include("outcome" => "unset", "key" => "launch.headless", "global" => true, "scope" => "global", "layer" => "global")
        expect(doc["results"].first).not_to have_key("value")
      end

      it "prints scope_not_allowed as an error envelope with its details" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        config_command.handlers[:set] = lambda do |*, **|
          raise Workspace::Error.new("dev.stop_timeout can't be set in the workspace scope.", code: "scope_not_allowed", details: {"key" => "dev.stop_timeout", "scope" => "workspace", "allowed" => ["project"]})
        end
        cli, raw = json_cli(config_command: config_command)

        expect { cli.run(["config", "set", "--scope", "workspace", "dev.stop_timeout", "5s", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "scope_not_allowed", "details" => {"key" => "dev.stop_timeout", "scope" => "workspace", "allowed" => ["project"]})
      end

      it "writes and reports through the real command and report, naming the file and the effective value" do
        dir = Dir.mktmpdir("ws-config-cli")
        settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir))
        project_config = instance_double(Workspace::ProjectConfig, available_projects: %w[api api.worktree-fix], project_root_for: nil)
        raw = StringIO.new
        gate = Workspace::OutputGate.new(raw)
        err = StringIO.new
        command = Workspace::Commands::Config.new(project_settings: settings, lineage: LineageSupport.lineage, file_backup: Workspace::FileBackup.new(output: err),
          project_config: project_config, output: gate, error_output: err)
        report = Workspace::ConfigReport.new(project_settings: settings, project_config: project_config, notes_dir: Workspace::NotesDir.new(git: Workspace::Git.new))
        cli, = build_test_cli(output: gate, error_output: err, config_command: command, config_report: report)

        cli.run(["config", "set", "--scope", "project", "--name", "api.worktree-fix", "dev.ready_timeout", "90s", "--json"])

        expect(JSON.parse(raw.string)["results"]).to eq([{"workspace" => "api", "outcome" => "set", "reason" => nil, "message" => nil, "key" => "dev.ready_timeout", "value" => "90s",
                                                          "global" => false, "scope" => "project", "layer" => "project", "file" => settings.project_config_path("api"),
                                                          "comments_preserved" => true, "effective" => 90}])
        expect(settings.load("api")).to eq({"dev" => {"ready_timeout" => "90s"}})
      ensure
        FileUtils.rm_rf(dir)
      end

      it "set --json gives an agent command row warnings only when there are some" do
        dir = Dir.mktmpdir("ws-config-cli")
        settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir))
        raw = StringIO.new
        gate = Workspace::OutputGate.new(raw)
        err = StringIO.new
        command = Workspace::Commands::Config.new(project_settings: settings, lineage: LineageSupport.lineage, file_backup: Workspace::FileBackup.new(output: err),
          agent_command_check: Workspace::AgentCommandCheck.new(which: ->(_) { false }), output: gate, error_output: err)
        cli, = build_test_cli(output: gate, error_output: err, config_command: command)

        cli.run(["config", "set", "--scope", "global", "agent.commands.claude", "claude-dev", "--json"])
        cli.run(["config", "set", "--scope", "global", "alerts.idle_after", "15m", "--json"])

        rows = raw.string.lines.map { |line| JSON.parse(line)["results"].first }
        expect(rows[0]["warnings"]).to eq(["claude-dev is not on PATH"])
        expect(rows[1]).not_to have_key("warnings")
      ensure
        FileUtils.rm_rf(dir)
      end

      it "show --scope forwards the scope to the report" do
        calls = []
        report = ScriptedConfigReport.new { |name, **opts| calls << [name, opts] and {"ok" => true, "keys" => []} }
        cli, _ = json_cli(config_report: report)

        cli.run(["config", "show", "--scope", "worktree", "--name", "api.worktree-fix", "--json"])

        expect(calls).to eq([["api.worktree-fix", {scope: "workspace"}]])
      end

      it "show --global and --scope global agree, and --global with another scope is refused" do
        calls = []
        report = ScriptedConfigReport.new { |name, **opts| calls << opts and {"ok" => true, "keys" => []} }
        cli, = json_cli(config_report: report)
        cli.run(["config", "show", "--global", "--name", "api", "--json"])
        cli.run(["config", "show", "--scope", "global", "--name", "api", "--json"])
        expect(calls).to eq([{scope: "global"}, {scope: "global"}])

        expect { cli.run(["config", "show", "--scope", "project", "--global", "--name", "api", "--json"]) }.to raise_error(FakeSystemExit)
      end

      it "show --scope project prints the project's file even from a worktree name (text mode)" do
        loaded = []
        settings = CLITestHelpers::FakeProjectSettings.new(loader: ->(name) { loaded << name and {"dev" => {"up" => "from-#{name}"}} })
        cli, output, = build_test_cli(project_settings: settings)

        cli.run(["config", "show", "--scope", "project", "--name", "api.worktree-fix"])

        expect(loaded).to eq(["api"])
        expect(output.string).to include("up: from-api")
        expect(output.string).to include("/tmp/workspace/projects/api.yml")
      end

      it "show --scope workspace prints the workspace's own file (text mode)" do
        settings = CLITestHelpers::FakeProjectSettings.new(loader: ->(name) { {"dev" => {"up" => "from-#{name}"}} })
        report = ScriptedConfigReport.new { |*, **| {"ok" => true, "keys" => []} }
        cli, output, = build_test_cli(project_settings: settings, config_report: report)

        cli.run(["config", "show", "--scope", "workspace", "--name", "api.worktree-fix"])

        expect(output.string).to include("up: from-api.worktree-fix")
      end

      it "show --scope workspace --name of an unknown workspace fails with unknown_workspace" do
        report = ScriptedConfigReport.new { |name, **| raise Workspace::Error.new("Unknown workspace '#{name}'", code: "unknown_workspace", details: {"name" => name}) }
        cli, = build_test_cli(config_report: report)

        expect { cli.run(["config", "show", "--scope", "workspace", "--name", "nosuch"]) }.to raise_error(FakeSystemExit)
      end
    end

    it "surfaces a Workspace::UsageError from config_command as exit 1" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      config_command.handlers[:set] = ->(*, **) { raise Workspace::UsageError, "Unknown config key 'dev.bogus'." }
      cli, _, error_output = build_test_cli(config_command: config_command)

      expect { cli.run(["config", "set", "dev.bogus", "x"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown config key 'dev.bogus'")
    end
  end

  describe "#run with alfred" do
    it "shows help when no subcommand given" do
      cli, output, _ = build_test_cli
      cli.run(["alfred"])
      expect(output.string).to include("Usage: workspace alfred")
      expect(output.string).to include("install")
      expect(output.string).to include("uninstall")
      expect(output.string).to include("info")
    end

    it "shows help for --help" do
      cli, output, _ = build_test_cli
      cli.run(["alfred", "--help"])
      expect(output.string).to include("Usage: workspace alfred")
    end

    it "exits 1 for unknown alfred subcommand" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["alfred", "bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown alfred subcommand: bogus")
    end

    describe "install" do
      it "raises error when Alfred is not installed" do
        config = Workspace::Config.new(workspace_dir: "/test/workspace")
        cli, _, _ = build_test_cli(config: config)
        expect { cli.run(["alfred", "install"]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end
    end

    # Runs the block with HOME set to a fresh directory, with or without an empty Alfred workflows directory in it.
    def with_empty_home(alfred_workflows: false)
      saved = ENV["HOME"]
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, "Library/Application Support/Alfred/Alfred.alfredpreferences/workflows")) if alfred_workflows
        ENV["HOME"] = home
        yield
      ensure
        ENV["HOME"] = saved
      end
    end

    describe "info" do
      it "reports Alfred not installed when workflows dir missing" do
        cli, output, _ = build_test_cli
        with_empty_home { cli.run(["alfred", "info"]) }
        expect(output.string).to include("Alfred is not installed")
      end
    end

    describe "uninstall" do
      it "reports not installed when workflow not found" do
        cli, output, _ = build_test_cli
        with_empty_home(alfred_workflows: true) { cli.run(["alfred", "uninstall"]) }
        expect(output.string).to include("not installed")
      end
    end
  end

  describe "#run with relaunch" do
    it "exits 1 when no active projects" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["relaunch", "--all"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("No active workspace projects to relaunch")
      expect(error_output.string).not_to include("Error:")
    end

    it "kills and relaunches active projects" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"unique_id" => "uid2"}

      tmux = FakeTmux.new
      allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])

      iterm = CLITestHelpers::FakeITerm.new

      window_manager = CLITestHelpers::FakeWindowManager.new
      allow(window_manager).to receive(:iterm_windows).and_return({123 => "workspace-proj1", 124 => "workspace-proj2"})

      slept = []
      cli, output, _ = build_test_cli(state: state, tmux: tmux, iterm: iterm, window_manager: window_manager, sleeper: ->(seconds) { slept << seconds })

      cli.run(["relaunch", "--all"])

      expect(slept).to eq([2])
      expect(output.string).to include("Will relaunch: proj1, proj2")
      expect(output.string).to include("Stopped 2 project(s): proj1, proj2")
    end

    def relaunch_pc(*names)
      CLITestHelpers::FakeProjectConfig.new(names.to_h { |n| [n, "/x/#{n}"] })
    end

    def relaunch_state(*names)
      CLITestHelpers::FakeState.new.tap { |st| names.each { |n| st[n] = {"unique_id" => "uid-#{n}"} } }
    end

    it "relaunches only the workspace the working directory is in when none is named" do
      Dir.mktmpdir do |root|
        state = relaunch_state("api", "web")
        pc = CLITestHelpers::FakeProjectConfig.new("api" => root, "web" => "/elsewhere/web")
        stop = instance_double(Workspace::Commands::Stop, call: ["api"], warnings: [])
        cli, output, _ = build_test_cli(project_config: pc, state: state, working_dir: root, stop_command: stop)

        cli.run(["relaunch"])

        expect(output.string).to include("Will relaunch: api\n")
        expect(stop).to have_received(:call).with(["api"])
      end
    end

    it "relaunches the workspace named by --name" do
      state = relaunch_state("api", "web")
      pc = relaunch_pc("api", "web")
      stop = instance_double(Workspace::Commands::Stop, call: ["web"], warnings: [])
      cli, output, _ = build_test_cli(project_config: pc, state: state, stop_command: stop)

      cli.run(["relaunch", "--name", "web"])

      expect(output.string).to include("Will relaunch: web\n")
      expect(stop).to have_received(:call).with(["web"])
    end

    it "relaunches the workspaces named positionally" do
      state = relaunch_state("api", "web", "docs")
      pc = relaunch_pc("api", "web", "docs")
      stop = instance_double(Workspace::Commands::Stop, call: ["api", "web"], warnings: [])
      cli, output, _ = build_test_cli(project_config: pc, state: state, stop_command: stop)

      cli.run(["relaunch", "api", "web"])

      expect(output.string).to include("Will relaunch: api, web\n")
      expect(stop).to have_received(:call).with(["api", "web"])
    end

    it "relaunches every active workspace with --all" do
      state = relaunch_state("api", "web")
      stop = instance_double(Workspace::Commands::Stop, call: ["api", "web"], warnings: [])
      cli, output, _ = build_test_cli(state: state, stop_command: stop)

      cli.run(["relaunch", "--all"])

      expect(output.string).to include("Will relaunch: api, web\n")
    end

    it "refuses --all beside a name or --name" do
      [["--all", "api"], ["--all", "--name", "api"]].each do |flags|
        cli, _, error_output = build_test_cli(state: relaunch_state("api"))
        expect { cli.run(["relaunch", *flags]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("--all relaunches every active workspace")
      end
    end

    it "refuses a workspace with no config as unknown_workspace before checking it is active" do
      stop = instance_double(Workspace::Commands::Stop, call: [], warnings: [])
      pc = CLITestHelpers::FakeProjectConfig.new("api" => "/x/api")
      cli, output, _ = build_test_cli(project_config: pc, state: relaunch_state("api"), stop_command: stop)

      expect { cli.run(["relaunch", "--json", "ghost"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("code" => "unknown_workspace")
      expect(stop).not_to have_received(:call)
    end

    it "refuses with not_in_workspace outside any workspace with no name and no --all" do
      stop = instance_double(Workspace::Commands::Stop, call: [], warnings: [])
      cli, output, _ = build_test_cli(state: relaunch_state("api"), stop_command: stop)

      expect { cli.run(["relaunch", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace")
      expect(stop).not_to have_received(:call)
    end

    it "refuses a workspace that is not active before anything stops" do
      stop = instance_double(Workspace::Commands::Stop, call: [], warnings: [])
      cli, output, _ = build_test_cli(project_config: relaunch_pc("api", "ghost"), state: relaunch_state("api"), stop_command: stop)

      expect { cli.run(["relaunch", "--json", "api", "ghost"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "workspace_not_active")
      expect(stop).not_to have_received(:call)
    end

    it "keeps a headless workspace headless when it is the one relaunched" do
      state = CLITestHelpers::FakeState.new
      state["api"] = {"unique_id" => "uid1"}
      state["bg"] = {"headless" => true}
      pc = relaunch_pc("api", "bg")
      launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
      stop = instance_double(Workspace::Commands::Stop, call: ["bg"], warnings: [])
      cli, = build_test_cli(project_config: pc, state: state, launch_command: launch_command, stop_command: stop)

      cli.run(["relaunch", "bg"])

      expect(launch_command).to have_received(:call).once
      expect(launch_command).to have_received(:call).with(["bg"], reattach: false, prompts: {}, headless: true)
    end
  end

  describe "#run with run" do
    it "exits 1 and shows usage when no arguments given" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace run")
    end

    it "dispatches to run_command with explicit project and command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi"])

      expect(run_command.calls.size).to eq(1)
      call = run_command.calls.first
      expect(call[:project]).to eq("myproject")
      expect(call[:command]).to eq("echo hi")
      expect(call[:pane]).to eq(:bottom)
      expect(call[:enter]).to eq(true)
    end

    it "auto-detects project from cwd when only command given" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "detected-project")

        run_command = CLITestHelpers::FakeRunCommand.new
        cli, _, _ = build_test_cli(run_command: run_command, working_dir: dir)
        cli.run(["run", "echo hello"])

        expect(run_command.calls.first[:project]).to eq("detected-project")
        expect(run_command.calls.first[:command]).to eq("echo hello")
      end
    end

    it "exits 1 when only command given and project cannot be detected" do
      cli, _, error_output = build_test_cli(working_dir: Dir.tmpdir)
      expect { cli.run(["run", "echo hello"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace run")
    end

    it "exits 2, not 1, when the text landed but wasn't confirmed submitted" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_command.raise_on_call(Workspace::Commands::Run::NotSubmittedError.new("pasted, but Enter didn't visibly take"))
      cli, _, error_output = build_test_cli(run_command: run_command)

      expect { cli.run(["run", "myproject", "echo hi"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(2)
      }
      expect(error_output.string).to include("Error: pasted, but Enter didn't visibly take")
    end

    it "passes --pane N as a string to run_command (TmuxPane resolves at runtime)" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "rake spec", "--pane", "2"])

      expect(run_command.calls.first[:pane]).to eq("2")
    end

    it "passes --pane bottom as a string to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "rake spec", "--pane", "bottom"])

      expect(run_command.calls.first[:pane]).to eq("bottom")
    end

    it "passes --pane with a title substring string to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--pane", "Claude Code"])

      expect(run_command.calls.first[:pane]).to eq("Claude Code")
    end

    it "passes --bottom as pane: :bottom" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--bottom"])

      expect(run_command.calls.first[:pane]).to eq(:bottom)
    end

    it "passes --split flag to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "tail -f log/dev.log", "--split"])

      expect(run_command.calls.first[:split]).to eq(true)
    end

    it "passes --split --vertical flags to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "rails console", "--split", "--vertical"])

      expect(run_command.calls.first[:split]).to eq(true)
      expect(run_command.calls.first[:vertical]).to eq(true)
    end

    it "exits 1 when --vertical is given without --split" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run", "myproject", "rails console", "--vertical"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--vertical requires --split")
    end

    it "joins multi-word trailing args into a single command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo", "hello", "world"])

      expect(run_command.calls.first[:project]).to eq("myproject")
      expect(run_command.calls.first[:command]).to eq("echo hello world")
    end

    it "passes --no-enter as enter: false" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--no-enter"])

      expect(run_command.calls.first[:enter]).to eq(false)
    end

    it "passes --focus flag to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--focus"])

      expect(run_command.calls.first[:focus]).to eq(true)
    end

    it "passes --dry-run flag to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--dry-run"])

      expect(run_command.calls.first[:dry_run]).to eq(true)
    end

    it "fires post_run hook after running" do
      run_command = CLITestHelpers::FakeRunCommand.new
      hook_runner = CLITestHelpers::FakeHookRunner.new
      cli, _, _ = build_test_cli(run_command: run_command, hook_runner: hook_runner)
      cli.run(["run", "myproject", "echo hi"])

      expect(hook_runner.runs).to include(hash_including(project: "myproject", event: "post_run"))
    end

    it "does not fire post_run hook for --dry-run" do
      run_command = CLITestHelpers::FakeRunCommand.new
      hook_runner = CLITestHelpers::FakeHookRunner.new
      cli, _, _ = build_test_cli(run_command: run_command, hook_runner: hook_runner)
      cli.run(["run", "myproject", "echo hi", "--dry-run"])

      expect(hook_runner.runs).not_to include(hash_including(event: "post_run"))
    end

    it "shows run in help output" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("run")
    end
  end

  describe "#run with run --pipe" do
    it "joins command and pipe stage with a shell pipe" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "cmd1", "--pipe", "cmd2"])

      expect(run_command.calls.first[:command]).to eq("cmd1 | cmd2")
    end

    it "joins multiple --pipe stages in order" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "cmd1", "--pipe", "cmd2", "--pipe", "cmd3"])

      expect(run_command.calls.first[:command]).to eq("cmd1 | cmd2 | cmd3")
    end

    it "sends the piped command with enter: true by default" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "echo hello", "--pipe", "grep hello"])

      expect(run_command.calls.first[:command]).to eq("echo hello | grep hello")
      expect(run_command.calls.first[:enter]).to eq(true)
    end

    it "exits 1 when --pipe is combined with --no-enter" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run", "myproject", "echo hi", "--pipe", "cat", "--no-enter"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("--pipe")
      expect(error_output.string).to include("--no-enter")
    end

    it "writes the piped command verbatim to the .cmd file when using --wait" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "cmd1 | cmd2",
          status: 0, stdout: "", stderr: "",
          started_at: nil, finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, _, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "cmd1", "--pipe", "cmd2", "--wait"])

      sent = run_command.calls.first[:command]
      expect(sent).to match(/\A\. '.*\.sh'\z/)
      cmd_path = sent.match(/\A\. '(.+\.sh)'\z/)[1].sub(/\.sh\z/, ".cmd")
      expect(File.read(cmd_path)).to eq("cmd1 | cmd2")
    end

    it "passes the joined command to run_command with dry_run: true" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "cmd1", "--pipe", "cmd2", "--dry-run"])

      expect(run_command.calls.first[:command]).to eq("cmd1 | cmd2")
      expect(run_command.calls.first[:dry_run]).to eq(true)
    end

    it "shows the joined command in --wait --dry-run output" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new
      cli, output, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "cmd1", "--pipe", "cmd2", "--wait", "--dry-run"])

      expect(output.string).to include("cmd1 | cmd2")
      expect(run_command.calls).to be_empty
    end

    it "exits 1 when --pipe is given an empty string" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run", "myproject", "echo hi", "--pipe", ""]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("--pipe")
    end

    it "raises UsageError when --pipe stage has unbalanced quotes" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run", "myproject", "echo hi", "--pipe", "grep 'bad", "--wait"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("invalid shell quoting")
    end

    it "does not mask unbalanced quotes across pipe stages" do
      cli, _, error_output = build_test_cli
      # "echo 'hello" and "world'" together would balance if validated as one joined string
      expect { cli.run(["run", "myproject", "echo 'hello", "--pipe", "world'", "--wait"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("invalid shell quoting")
    end
  end

  describe "#run with run --wait" do
    it "writes a script file and sends the source command to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "echo hi",
          status: 0, stdout: "hi\n", stderr: "",
          started_at: "2024-01-01T00:00:00Z", finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, _, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "echo hi", "--wait"])

      sent_command = run_command.calls.first[:command]
      # The pane receives `. '/path/uuid.sh'`, not the raw command inline
      expect(sent_command).to match(/\A\. '.*\.sh'\z/)

      script_path = sent_command.match(/\A\. '(.+\.sh)'\z/)[1]
      script = File.read(script_path)
      cmd_path = script_path.sub(/\.sh\z/, ".cmd")
      expect(File.read(cmd_path)).to eq("echo hi")
      expect(script).to include("workspace report-run-status")
      expect(script).to include(".stdout")
      expect(script).to include(".stderr")
    end

    it "prints exit status and stdout after the run completes" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "echo hi",
          status: 0, stdout: "hello world\n", stderr: "",
          started_at: "2024-01-01T00:00:00Z", finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, output, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "echo hi", "--wait"])

      expect(output.string).to include("Exit status: 0")
      expect(output.string).to include("hello world")
    end

    it "passes --timeout to the poll" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new
      received_timeout = nil

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, timeout:, **|
        received_timeout = timeout
        Workspace::RunResult.new(
          uuid: u, project: nil, command: nil,
          status: 0, stdout: "", stderr: "",
          started_at: nil, finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, _, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "echo hi", "--wait", "--timeout", "60"])

      expect(received_timeout).to eq(60)
    end

    it "fires post_run hook after --wait completes" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new
      hook_runner = CLITestHelpers::FakeHookRunner.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: nil, command: nil,
          status: 0, stdout: "", stderr: "",
          started_at: nil, finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, _, _ = build_test_cli(
        run_command: run_command,
        run_result_store: run_result_store,
        hook_runner: hook_runner
      )
      cli.run(["run", "myproject", "echo hi", "--wait"])

      expect(hook_runner.runs).to include(hash_including(project: "myproject", event: "post_run"))
    end

    it "exits 1 when store raises timeout error" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait).and_raise(
        Workspace::Error, "Timed out waiting for run x (300s)"
      )

      cli, _, error_output = build_test_cli(
        run_command: run_command,
        run_result_store: run_result_store
      )
      expect { cli.run(["run", "myproject", "echo hi", "--wait"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Timed out")
    end

    it "exits with the command's exit status when it is non-zero" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "false",
          status: 3, stdout: "", stderr: "",
          started_at: nil, finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, output, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      expect { cli.run(["run", "myproject", "false", "--wait"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(3)
      }
      expect(output.string).to include("Exit status: 3")
    end

    it "prints stderr when the run produced any" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "echo oops >&2",
          status: 0, stdout: "", stderr: "oops\n",
          started_at: nil, finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, output, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      cli.run(["run", "myproject", "echo oops >&2", "--wait"])

      expect(output.string).to include("--- stderr ---")
      expect(output.string).to include("oops")
    end

    it "exits 1 when --wait is combined with --no-enter" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, error_output = build_test_cli(run_command: run_command)

      expect { cli.run(["run", "myproject", "echo hi", "--wait", "--no-enter"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--wait requires the command to be sent with Enter")
      expect(run_command.calls).to be_empty
    end

    it "prints the wrapper form for --wait --dry-run without running anything" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new
      hook_runner = CLITestHelpers::FakeHookRunner.new

      cli, output, _ = build_test_cli(
        run_command: run_command,
        run_result_store: run_result_store,
        hook_runner: hook_runner
      )
      cli.run(["run", "myproject", "echo hi", "--wait", "--dry-run"])

      expect(output.string).to include("echo hi")
      expect(output.string).to include("workspace report-run-status")
      expect(output.string).to include(".stdout")
      expect(output.string).to include(".cmd")
      expect(output.string).to include(".sh")
      expect(run_command.calls).to be_empty
      expect(hook_runner.runs).not_to include(hash_including(event: "post_run"))
    end

    it "single-quotes the results directory so paths with spaces survive the shell" do
      config = Workspace::Config.new
      allow(config).to receive(:run_results_dir).and_return("/Users/a b/.workspace-runs")

      run_command = CLITestHelpers::FakeRunCommand.new
      cli, output, _ = build_test_cli(config: config, run_command: run_command)
      cli.run(["run", "myproject", "echo hi", "--wait", "--dry-run"])

      expect(output.string).to include("'/Users/a b/.workspace-runs/<uuid>.stdout'")
      expect(output.string).to include("2>'/Users/a b/.workspace-runs/<uuid>.stderr'")
      expect(output.string).to include("'/Users/a b/.workspace-runs/<uuid>.cmd'")
    end

    it "exits 1 with a quoting error when the command has an unbalanced single quote" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, error_output = build_test_cli(run_command: run_command)

      expect {
        cli.run(["run", "myproject", "echo what's up", "--wait"])
      }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("invalid shell quoting")
      expect(error_output.string).to include("double quotes")
      expect(run_command.calls).to be_empty
    end

    it "exits 1 with a quoting error when the command has an unbalanced double quote" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, error_output = build_test_cli(run_command: run_command)

      expect {
        cli.run(["run", "myproject", 'echo "hi', "--wait"])
      }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("invalid shell quoting")
      expect(run_command.calls).to be_empty
    end

    it "accepts a command with valid nested quotes" do
      run_command = CLITestHelpers::FakeRunCommand.new
      run_result_store = CLITestHelpers::FakeRunResultStore.new

      allow(run_result_store).to receive(:ensure_dir)
      allow(run_result_store).to receive(:wait) do |u, **|
        Workspace::RunResult.new(
          uuid: u, project: "myproject", command: "echo hi",
          status: 0, stdout: "", stderr: "",
          started_at: "2024-01-01T00:00:00Z", finished_at: "2024-01-01T00:00:01Z"
        )
      end

      cli, _, _ = build_test_cli(run_command: run_command, run_result_store: run_result_store)
      expect {
        cli.run(["run", "myproject", 'echo "hello world"', "--wait"])
      }.not_to raise_error

      expect(run_command.calls).not_to be_empty
    end
  end

  describe "#run with capture" do
    it "exits 1 and shows usage when no project given and cwd has no workspace project" do
      cli, _, error_output = build_test_cli(working_dir: Dir.tmpdir)
      expect { cli.run(["capture"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace capture")
    end

    it "auto-detects project from cwd when project arg is omitted" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "detected-project")

        capture_command = CLITestHelpers::FakeCaptureCommand.new
        cli, _, _ = build_test_cli(capture_command: capture_command, working_dir: dir)
        cli.run(["capture"])

        expect(capture_command.calls.first[:project]).to eq("detected-project")
      end
    end

    it "exits 1 when --lines is zero" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["capture", "myproject", "--lines", "0"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--lines must be a positive integer")
    end

    it "exits 1 when --lines is negative" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["capture", "myproject", "--lines", "-5"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--lines must be a positive integer")
    end

    it "exits 1 when --all and --lines are both specified" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["capture", "myproject", "--all", "--lines", "200"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("--all and --lines are mutually exclusive")
    end

    it "dispatches to lock_command#acquire with --task, --wait, --poll, and --max-wait" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "acquire", "edit", "--task", "PROJ-12", "--wait", "--poll", "1.5", "--max-wait", "9"])

      expect(lock_command.calls).to eq(
        [{action: :acquire, name: "edit", task: "PROJ-12", wait: true, poll: 1.5, max_wait: 9.0}]
      )
    end

    it "accepts durations like '9m' and '5s' for --max-wait and --poll" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "acquire", "edit", "--wait", "--poll", "5s", "--max-wait", "9m"])

      expect(lock_command.calls).to eq(
        [{action: :acquire, name: "edit", task: nil, wait: true, poll: 5.0, max_wait: 540.0}]
      )
    end

    it "passes --max-wait alone through as given, leaving the command to imply --wait" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "acquire", "edit", "--max-wait", "9"])

      expect(lock_command.calls).to eq(
        [{action: :acquire, name: "edit", task: nil, wait: false, poll: Workspace::Commands::Lock::DEFAULT_POLL_SECONDS, max_wait: 9.0}]
      )
    end

    it "raises a usage error instead of a backtrace for an unparsable --max-wait" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, error_output = build_test_cli(lock_command: lock_command)

      expect { cli.run(["lock", "acquire", "edit", "--wait", "--max-wait", "nonsense"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("--max-wait")
    end

    it "exits with the acquire result's exit_code" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      lock_command.result = {exit_code: 5}
      cli, _, _ = build_test_cli(lock_command: lock_command)

      expect { cli.run(["lock", "acquire", "edit"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(5)
      }
    end

    it "does not exit when acquire succeeds" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      expect { cli.run(["lock", "acquire", "edit"]) }.not_to raise_error
    end

    it "dispatches to lock_command#release" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "release", "edit"])

      expect(lock_command.calls).to eq([{action: :release, name: "edit", all: false}])
    end

    it "dispatches to lock_command#release with --all" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "release", "--all"])

      expect(lock_command.calls).to eq([{action: :release, name: nil, all: true}])
    end

    it "dispatches to lock_command#status" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "status", "edit"])

      expect(lock_command.calls).to eq([{action: :status, name: "edit", json: false}])
    end

    it "dispatches to lock_command#status with --json" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "status", "edit", "--json"])

      expect(lock_command.calls).to eq([{action: :status, name: "edit", json: true}])
    end

    it "emits the JSON error contract for `lock status` when --json appears after a bad flag" do
      cli, output, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "status", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(Workspace::Commands::Lock::JSON_SCHEMA_VERSION)
      expect(parsed["error"]).to be_a(String)
    end

    it "dispatches to lock_command#clear" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "clear", "edit"])

      expect(lock_command.calls).to eq([{action: :clear, name: "edit", all: false, json: false}])
    end

    it "dispatches to lock_command#clear with --json" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "clear", "edit", "--json"])

      expect(lock_command.calls).to eq([{action: :clear, name: "edit", all: false, json: true}])
    end

    it "emits the JSON error contract for `lock clear` when --json appears after a bad flag" do
      cli, output, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "clear", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(Workspace::Commands::Lock::JSON_SCHEMA_VERSION)
      expect(parsed["error"]).to be_a(String)
    end

    it "emits a short one-line JSON error for extra arguments to `lock clear`, not the full usage text" do
      cli, output, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "clear", "foo", "bar", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      parsed = JSON.parse(output.string)
      expect(parsed["error"]).to eq("workspace lock clear: too many arguments.")
      expect(parsed["error"]).not_to include("\n")
    end

    it "still prints full usage on stderr for extra arguments to `lock clear` in text mode" do
      cli, _, error_output = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "clear", "foo", "bar"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("workspace lock clear: too many arguments.")
      expect(error_output.string).to include("Usage: workspace lock clear")
    end

    it "dispatches to lock_command#instructions, defaulting to the edit lock" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      cli, _, _ = build_test_cli(lock_command: lock_command)

      cli.run(["lock", "instructions"])
      cli.run(["lock", "instructions", "test"])

      expect(lock_command.calls).to eq([{action: :instructions, name: "edit"}, {action: :instructions, name: "test"}])
    end

    it "rejects extra arguments to lock instructions" do
      cli, _, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "instructions", "a", "b"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits 3 when release reports an idle takeover" do
      lock_command = CLITestHelpers::FakeLockCommand.new
      lock_command.result = {exit_code: 3}
      cli, _, _ = build_test_cli(lock_command: lock_command)

      expect { cli.run(["lock", "release", "edit"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
    end

    it "points to the audit log in lock status help" do
      cli, _, error_output = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      expect { cli.run(["lock", "status", "extra", "args"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("locks.jsonl next to locks.json")
    end

    it "prints the verb's own Usage line for a stray argument to lock and dev verbs" do
      verbs = {
        %w[lock acquire] => %w[edit extra], %w[lock release] => %w[edit extra], %w[lock clear] => %w[edit extra],
        %w[lock status] => %w[a b], %w[lock instructions] => %w[a b], %w[dev up] => %w[a b], %w[dev down] => %w[a b], %w[dev wait] => %w[a b],
        %w[dev leave] => %w[a b], %w[dev status] => %w[a b], %w[dev __run] => %w[extra]
      }
      verbs.each do |(command, verb), stray|
        cli, _, error_output = build_test_cli(
          lock_command: CLITestHelpers::FakeLockCommand.new,
          dev_command: CLITestHelpers::FakeDevCommand.new
        )

        expect { cli.run([command, verb, *stray]) }.to raise_error(FakeSystemExit)

        usage = Workspace::HelpPages::COMMANDS.fetch(command).fetch(verb)[:usage].first
        expect(error_output.string).to include("Usage: workspace #{usage}")
      end
    end

    it "lists instructions and idle takeover in lock help" do
      cli, output, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      cli.run(["lock", "help"])

      expect(output.string).to include("Print the prompt block", "locks.idle_grace", "3   this agent's hold was taken over")
    end

    describe "dev" do
      let(:dev_command) { CLITestHelpers::FakeDevCommand.new }
      # The working directory is in a stopped workspace the detector does not find: its lineage names a configured one.
      let(:in_workspace) { {lineage: CLITestHelpers::FakeLineage.new("project-a")} }

      %w[up down status wait leave].each do |sub|
        it "refuses dev #{sub} with not_in_workspace outside any workspace, and calls nothing" do
          loose = Dir.mktmpdir("ws-dev-loose")
          cli, output, = build_test_cli(dev_command: dev_command, working_dir: loose)

          expect { cli.run(["dev", sub, "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "not_in_workspace", "details" => {"path" => loose})
          expect(dev_command.calls).to be_empty
        ensure
          FileUtils.rm_rf(loose)
        end
      end

      it "acts on the workspace the detector finds in the working directory" do
        detector = Struct.new(:found) { def detect(_dir) = found }.new("api")
        cli, = build_test_cli(dev_command: dev_command, project_detector: detector, working_dir: "/somewhere")

        cli.run(["dev", "status"])

        expect(dev_command.working_dirs).to eq(["/somewhere"])
      end

      it "acts from a directory whose lineage names a configured workspace, though it is not running" do
        sub = File.join(Dir.tmpdir, "ws-dev-sub-#{Process.pid}")
        FileUtils.mkdir_p(sub)
        cli, = build_test_cli(dev_command: dev_command, working_dir: sub, **in_workspace)

        cli.run(["dev", "leave"])

        expect(dev_command.working_dirs).to eq([sub])
      ensure
        FileUtils.rm_rf(sub)
      end

      it "dispatches up with --wait, --force, --no-ready and --max-wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--wait", "--force", "--no-ready", "--max-wait", "30"])

        expect(dev_command.calls).to eq([{action: :up, wait: true, takeover: true, ready: false, max_wait: 30.0}])
      end

      it "dispatches up with --takeover, the deprecated alias for --force" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--takeover"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: true, ready: true, max_wait: nil}])
      end

      it "defaults up to no wait, no takeover, and a ready check" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: nil}])
      end

      it "passes --max-wait alone through as given, leaving the command to imply --wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--max-wait", "5"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: 5.0}])
      end

      it "accepts durations like '9m' for up --max-wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--max-wait", "9m"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: 540.0}])
      end

      it "raises a usage error naming --max-wait for an unparsable up --max-wait" do
        cli, _, error_output = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "up", "--max-wait", "nonsense"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("--max-wait")
        expect(dev_command.calls).to be_empty
      end

      it "exits with up's exit code" do
        dev_command.result = {exit_code: 6}
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "up"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(6) }
      end

      it "passes queue: true to up only when --queue is given" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--queue"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: nil, queue: true}])
      end

      it "gives dev up --queue --json a row with status and position" do
        dev_command.result = {exit_code: 0, status: "queued", position: 2}
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--queue", "--json"])

        row = JSON.parse(output.string)["results"].first
        expect(row).to include("outcome" => "queued", "status" => "queued", "position" => 2)
      end

      it "gives dev up --queue --json a started row with a null position when it is running" do
        dev_command.result = {exit_code: 0, status: "running", position: nil}
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--queue", "--json"])

        expect(JSON.parse(output.string)["results"].first).to include("outcome" => "started", "status" => "running", "position" => nil)
      end

      it "leaves the plain dev up --json row without status or position" do
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "up", "--json"])

        expect(JSON.parse(output.string)["results"].first.keys).not_to include("status", "position")
      end

      it "dispatches wait with --no-ready and --max-wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "wait", "--no-ready", "--max-wait", "10m"])

        expect(dev_command.calls).to eq([{action: :wait, ready: false, max_wait: 600.0}])
      end

      it "defaults wait to a ready check and no limit" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "wait"])

        expect(dev_command.calls).to eq([{action: :wait, ready: true, max_wait: nil}])
      end

      it "exits with wait's exit code and puts status and position in its --json row" do
        dev_command.result = {exit_code: 75, status: "queued", position: 3}
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "wait", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(75) }

        row = JSON.parse(output.string)["results"].first
        expect(row).to include("outcome" => "failed", "exit_code" => 75, "status" => "queued", "position" => 3)
      end

      it "rejects --queue with --force through the usual usage error path" do
        dev_command.up_error = Workspace::UsageError.new("--queue returns at once")
        cli, _, error_output = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "up", "--queue", "--force"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("--queue")
      end

      it "gives a successful dev wait --json row with status running" do
        dev_command.result = {exit_code: 0, status: "running", position: nil}
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "wait", "--json"])

        expect(JSON.parse(output.string)["results"].first).to include("outcome" => "started", "status" => "running", "position" => nil)
      end

      it "dispatches leave and reports its outcome in --json" do
        dev_command.result = {exit_code: 0, outcome: "left"}
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "leave", "--json"])

        expect(dev_command.calls).to eq([{action: :leave}])
        document = JSON.parse(output.string)
        expect(document["status"]).to eq("ok")
        expect(document["results"].first["outcome"]).to eq("left")
      end

      it "names wait and leave and --queue in the dev help" do
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev"])

        expect(output.string).to include("Block until", "Take this worktree out", "--queue")
      end

      it "dispatches down with --force, status, and the hidden __run" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "down", "--force"])
        cli.run(["dev", "status"])
        cli.run(["dev", "__run", "--wait"])

        expect(dev_command.calls).to eq(
          [{action: :down, force: true}, {action: :status, json: false}, {action: :run, wait: true}]
        )
      end

      it "dispatches the hidden __release with the session id" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "__release", "sess-1"])

        expect(dev_command.calls).to eq([{action: :release, session_id: "sess-1"}])
      end

      it "exits with the release's own status when the environment could not be stopped" do
        dev_command.result = {exit_code: 1}
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "__release", "sess-1"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      end

      it "refuses __release without exactly one session id" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "__release"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect { cli.run(["dev", "__release", "a", "b"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      end

      it "dispatches status with --json" do
        cli, _, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev", "status", "--json"])

        expect(dev_command.calls).to eq([{action: :status, json: true}])
      end

      it "emits the JSON error contract for `dev status` when --json appears after a bad flag" do
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        expect { cli.run(["dev", "status", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(Workspace::Commands::Dev::JSON_SCHEMA_VERSION)
        expect(parsed["error"]).to be_a(String)
      end

      it "prints dev help without a subcommand and rejects unknown ones" do
        cli, output, _ = build_test_cli(dev_command: dev_command, **in_workspace)

        cli.run(["dev"])
        expect(output.string).to include("Usage: workspace dev <subcommand>")
        expect(output.string).not_to include("__run")
        expect { cli.run(["dev", "bogus"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      end

      it "lists dev in the main help" do
        cli, output, _ = build_test_cli

        cli.run(["help"])

        expect(output.string).to match(/^\s+dev\s+Start, stop, or inspect/)
      end
    end

    it "raises UsageError for an unknown lock subcommand" do
      cli, _, _ = build_test_cli

      expect { cli.run(["lock", "bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end

    it "requires a name for release without --all" do
      cli, _, _ = build_test_cli

      expect { cli.run(["lock", "release"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end

    it "dispatches to capture_command with explicit project and default options" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject"])

      expect(capture_command.calls.size).to eq(1)
      call = capture_command.calls.first
      expect(call[:project]).to eq("myproject")
      expect(call[:pane]).to eq(:bottom)
      expect(call[:lines]).to eq(100)
      expect(call[:all]).to eq(false)
    end

    it "passes --pane N as a string to capture_command (TmuxPane resolves at runtime)" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--pane", "1"])

      expect(capture_command.calls.first[:pane]).to eq("1")
    end

    it "passes --pane bottom as a string to capture_command" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--pane", "bottom"])

      expect(capture_command.calls.first[:pane]).to eq("bottom")
    end

    it "passes --pane with a title substring string to capture_command" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--pane", "Claude Code"])

      expect(capture_command.calls.first[:pane]).to eq("Claude Code")
    end

    it "passes --lines N to capture_command" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--lines", "200"])

      expect(capture_command.calls.first[:lines]).to eq(200)
    end

    it "passes --all flag to capture_command" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--all"])

      expect(capture_command.calls.first[:all]).to eq(true)
    end

    it "shows capture in help output" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("capture")
    end
  end

  describe "#run with hooks uninstall" do
    let(:hooks_command) do
      Class.new do
        attr_reader :calls

        def initialize(removed)
          @removed = removed
          @calls = []
        end

        def uninstall(agent:, dry_run: false)
          @calls << {agent: agent, dry_run: dry_run}
          raise Workspace::Error.new("nope", code: "unknown_agent_kind") if agent == "bogus"
          {"agent" => agent, "path" => "/h/hooks.json", "removed" => @removed, "backup" => (@removed.zero? ? nil : "/h/hooks.json.bak"), "dry_run" => dry_run}
        end
      end
    end

    it "removes the hooks and names the file and its backup" do
      command = hooks_command.new(3)
      cli, output, _ = build_test_cli(hooks_command: command)

      cli.run(["hooks", "uninstall", "--agent", "codex"])

      expect(command.calls).to eq([{agent: "codex", dry_run: false}])
      expect(output.string).to include("Removed 3 workspace hook(s) from /h/hooks.json (backup: /h/hooks.json.bak).")
    end

    it "says nothing was there" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(0))

      cli.run(["hooks", "uninstall", "--agent=codex"])

      expect(output.string).to include("No workspace hooks in /h/hooks.json; nothing to remove.")
    end

    it "reports a dry run as would_remove with --json" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(2))

      cli.run(["hooks", "uninstall", "--agent", "codex", "--dry-run", "--json"])

      doc = JSON.parse(output.string)
      expect(doc["status"]).to eq("dry_run")
      expect(doc["results"].first).to include("outcome" => "would_remove", "removed" => 2)
    end

    it "requires --agent" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(0))

      expect { cli.run(["hooks", "uninstall", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    describe "--name and --project" do
      let(:targeted) do
        Class.new do
          attr_reader :calls

          def initialize(rows)
            @rows = rows
            @calls = []
          end

          def uninstall_in(**args)
            @calls << args
            @rows
          end
        end
      end

      def row(workspace, outcome, **extra)
        {"workspace" => workspace, "checkout" => "/p/#{workspace}", "outcome" => outcome, "reason" => extra[:reason],
         "message" => extra[:message], "agent" => "claude", "path" => "/p/#{workspace}/.claude/settings.json",
         "removed" => (outcome == "removed") ? 2 : 0, "backup" => nil, "dry_run" => false}
      end

      it "passes --name and prints a line per checkout" do
        command = targeted.new([row("main", "removed")])
        cli, output, _ = build_test_cli(hooks_command: command)

        cli.run(["hooks", "uninstall", "--agent", "claude", "--name=main"])

        expect(command.calls).to eq([{agent: "claude", name: "main", project: nil, dry_run: false}])
        expect(output.string).to include("main: Removed 2 workspace hook(s) from /p/main/.claude/settings.json.")
      end

      it "takes --project with a value, or bare for the current directory's project" do
        command = targeted.new([row("main", "not_installed")])
        cli, output, _ = build_test_cli(hooks_command: command)

        cli.run(["hooks", "uninstall", "--agent", "claude", "--project", "app"])
        cli.run(["hooks", "uninstall", "--agent", "claude", "--project"])

        expect(command.calls.map { |c| c[:project] }).to eq(["app", true])
        expect(output.string).to include("main: no workspace hooks in")
      end

      it "reports one row per checkout and exits 3 when only some failed" do
        rows = [row("main", "removed"), row("wt", "failed", reason: "hook_settings_unreadable", message: "bad json")]
        cli, output, _ = build_test_cli(hooks_command: targeted.new(rows))

        expect { cli.run(["hooks", "uninstall", "--agent", "claude", "--project", "--json"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
        doc = JSON.parse(output.string)
        expect(doc).to include("status" => "partial")
        expect(doc["results"].map { |r| r.values_at("workspace", "outcome", "path") }).to eq(
          [["main", "removed", "/p/main/.claude/settings.json"], ["wt", "failed", "/p/wt/.claude/settings.json"]]
        )
        expect(doc["results"].last).to include("reason" => "hook_settings_unreadable", "checkout" => "/p/wt")
      end

      it "exits 3 without --json too, and exits 0 for a dry run" do
        rows = [row("main", "removed"), row("wt", "failed", reason: "x", message: "bad")]
        cli, output, _ = build_test_cli(hooks_command: targeted.new(rows))
        expect { cli.run(["hooks", "uninstall", "--agent", "claude", "--project"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
        expect(output.string).to include("wt: failed: bad")

        cli, output, _ = build_test_cli(hooks_command: targeted.new([row("main", "would_remove")]))
        cli.run(["hooks", "uninstall", "--agent", "claude", "--project", "--dry-run", "--json"])
        expect(JSON.parse(output.string)).to include("status" => "dry_run")
      end

      it "exits 1 when every checkout failed, and prints a skipped checkout by its path" do
        rows = [row("a", "failed", reason: "x", message: "bad"), row("b", "failed", reason: "x", message: "bad")]
        cli, _, _ = build_test_cli(hooks_command: targeted.new(rows))
        expect { cli.run(["hooks", "uninstall", "--agent", "claude", "--project", "--json"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        skipped = row(nil, "skipped", reason: "checkout_missing", message: "/p/x does not exist").merge("checkout" => "/p/x")
        cli, output, _ = build_test_cli(hooks_command: targeted.new([skipped]))
        cli.run(["hooks", "uninstall", "--agent", "claude", "--project"])
        expect(output.string).to include("/p/x: skipped: /p/x does not exist")
      end

      it "refuses --name with --project" do
        cli, output, _ = build_test_cli(hooks_command: targeted.new([]))

        expect { cli.run(["hooks", "uninstall", "--agent", "claude", "--name", "a", "--project", "b", "--json"]) }
          .to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("code" => "usage")
      end
    end

    it "rejects an extra argument" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(0))

      expect { cli.run(["hooks", "uninstall", "--agent", "codex", "extra", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "usage")
    end

    it "rejects an unknown subcommand" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(0))

      expect { cli.run(["hooks", "install", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false)
    end

    it "carries a command error through the JSON envelope" do
      cli, output, _ = build_test_cli(hooks_command: hooks_command.new(0))

      expect { cli.run(["hooks", "uninstall", "--agent", "bogus", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_agent_kind")
    end
  end

  describe "#run with capabilities" do
    it "dispatches to capabilities_command#call without --json" do
      capabilities_command = CLITestHelpers::FakeCapabilitiesCommand.new
      cli, _, _ = build_test_cli(capabilities_command: capabilities_command)

      cli.run(["capabilities"])

      expect(capabilities_command.calls).to eq([{json: false}])
    end

    it "dispatches with --json" do
      capabilities_command = CLITestHelpers::FakeCapabilitiesCommand.new
      cli, _, _ = build_test_cli(capabilities_command: capabilities_command)

      cli.run(["capabilities", "--json"])

      expect(capabilities_command.calls).to eq([{json: true}])
    end

    it "prints help for --help without calling the command" do
      capabilities_command = CLITestHelpers::FakeCapabilitiesCommand.new
      cli, output, _ = build_test_cli(capabilities_command: capabilities_command)

      cli.run(["capabilities", "--help"])

      expect(output.string).to include("Usage: workspace capabilities [--json]")
      expect(capabilities_command.calls).to eq([])
    end

    it "rejects an extra argument as a usage error" do
      capabilities_command = CLITestHelpers::FakeCapabilitiesCommand.new
      cli, output, _ = build_test_cli(capabilities_command: capabilities_command)

      expect { cli.run(["capabilities", "--json", "extra"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(capabilities_command.calls).to eq([])
    end

    it "is an error when no capabilities command was wired" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["capabilities"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("no capabilities command was wired")
    end

    it "is listed in the main help" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to match(/^  capabilities /)
    end
  end

  describe "#run with parent" do
    it "takes --name as another spelling of the NAME argument, and refuses two different names" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, error_output = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--name", "app.worktree-x", "--path"])
      cli.run(["parent", "app.worktree-x", "--name", "app.worktree-x"])
      expect { cli.run(["parent", "app.worktree-x", "--name", "other"]) }.to raise_error(FakeSystemExit)

      expect(parent_command.calls).to eq([{name: "app.worktree-x", path: true, json: false, envelope: false},
        {name: "app.worktree-x", path: false, json: false, envelope: false}])
      expect(error_output.string).to include("Give the workspace once")
    end

    it "dispatches to parent_command#call with no options" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent"])

      expect(parent_command.calls).to eq([{name: nil, path: false, json: false, envelope: false}])
    end

    it "dispatches with a given project name" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "app.worktree-login"])

      expect(parent_command.calls).to eq([{name: "app.worktree-login", path: false, json: false, envelope: false}])
    end

    it "dispatches with --path" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--path"])

      expect(parent_command.calls).to eq([{name: nil, path: true, json: false, envelope: false}])
    end

    it "dispatches --json-envelope as json with envelope" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--json-envelope"])

      expect(parent_command.calls).to eq([{name: nil, path: false, json: true, envelope: true}])
    end

    it "refuses --path with --json-envelope" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, output, _ = build_test_cli(parent_command: parent_command)

      expect { cli.run(["parent", "--path", "--json-envelope"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(parent_command.calls).to be_empty
    end

    it "dispatches with --json" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--json"])

      expect(parent_command.calls).to eq([{name: nil, path: false, json: true, envelope: false}])
    end

    it "shows parent in help output" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("parent")
    end

    it "raises a usage error when --path and --json are combined" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, output, error_output = build_test_cli(parent_command: parent_command)

      expect { cli.run(["parent", "--path", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage", "error" => "--path and --json cannot be used together.")
      expect(error_output.string).to eq("")
      expect(parent_command.calls).to be_empty
    end
  end

  describe "#run with events" do
    let(:events_command) { instance_double(Workspace::Commands::Events, call: nil) }
    let(:built) { build_test_cli(events_command: events_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "passes --follow, --json, every --types value and --since" do
      cli.run(["events", "--follow", "--json", "--types", "tool_started, tool_finished", "--types", "gap", "--since", "1.abc"])
      cli.run(["events"])

      expect(events_command).to have_received(:call).with(follow: true, json: true, types: %w[tool_started tool_finished gap], since: "1.abc", name: nil)
      expect(events_command).to have_received(:call).with(follow: false, json: false, types: [], since: nil, name: nil)
    end

    it "passes --name to the command for a known workspace" do
      project_config = instance_double(Workspace::ProjectConfig, existing_name: "proj")
      cli, = build_test_cli(events_command: events_command, project_config: project_config)

      cli.run(["events", "--name", "proj", "--json"])

      expect(events_command).to have_received(:call).with(follow: false, json: true, types: [], since: nil, name: "proj")
    end

    it "refuses an unknown --name as unknown_workspace" do
      project_config = instance_double(Workspace::ProjectConfig, existing_name: nil)
      cli, output = build_test_cli(events_command: events_command, project_config: project_config)

      expect { cli.run(["events", "--name", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
      expect(events_command).not_to have_received(:call)
    end

    it "emits the JSON usage envelope for an extra argument" do
      expect { cli.run(["events", "--json", "extra"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(events_command).not_to have_received(:call)
    end

    it "reports a cursor it can't read as invalid_cursor" do
      allow(events_command).to receive(:call).and_raise(Workspace::EventStream::InvalidCursor)

      expect { cli.run(["events", "--json", "--since", "x"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "invalid_cursor")
    end

    it "lists the hook event types and the stream lines in its help" do
      cli.run(["events", "--help"])

      expect(output.string).to include("Usage: workspace events", "tool_started, tool_finished", "follow_started", "gap")
      expect(events_command).not_to have_received(:call)
    end
  end

  describe "#run with snapshot" do
    let(:snapshot_command) { CLITestHelpers::FakeSnapshotCommand.new }
    let(:built) { build_test_cli(snapshot_command: snapshot_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "passes repeated --name values and --pr" do
      cli.run(["snapshot", "--json"])
      cli.run(["snapshot", "--json", "--name", "a", "--name", "b", "--pr"])

      expect(snapshot_command.calls).to eq([{names: [], pr: false}, {names: %w[a b], pr: true}])
    end

    it "refuses to run without --json, as a usage error" do
      expect { cli.run(["snapshot"]) }.to raise_error(FakeSystemExit)
      expect(built[2].string).to include("pass --json")
      expect(snapshot_command.calls).to be_empty
    end

    it "emits the JSON usage envelope for an extra argument" do
      expect { cli.run(["snapshot", "--json", "extra"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      expect(snapshot_command.calls).to be_empty
    end

    it "exits with the command's non-zero code" do
      snapshot_command.result = {exit_code: 1}

      expect { cli.run(["snapshot", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "prints help" do
      cli.run(["snapshot", "--help"])

      expect(output.string).to include("Usage: workspace snapshot --json").and include("daemons_unavailable")
    end
  end

  describe "#run with library" do
    let(:library_command) { CLITestHelpers::FakeLibraryCommand.new }
    let(:tty_input) { Class.new(StringIO) { def tty? = true }.new("") }
    let(:built) { build_test_cli(library_command: library_command, working_dir: "/some/dir", input: tty_input) }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:where) { {scope: nil, project: nil, cwd: "/some/dir"} }

    it "lists by default, through the lib alias, with a kind filter and a scope" do
      cli.run(["library"])
      cli.run(["lib", "list", "--kind", "play", "--global", "--json"])
      cli.run(["library", "list", "--project"])
      cli.run(["library", "list", "--project", "api"])

      expect(library_command.calls).to eq([
        [:list, where.merge(kind: nil, json: false)],
        [:list, where.merge(kind: "play", scope: "global", json: true)],
        [:list, where.merge(scope: "project", kind: nil, json: false)],
        [:list, where.merge(scope: "project", project: "api", kind: nil, json: false)]
      ])
    end

    it "narrows a read to the built-in entries with --builtin" do
      cli.run(["library", "list", "--builtin", "--json"])
      cli.run(["library", "show", "orchestrator", "--builtin"])

      expect(library_command.calls).to eq([
        [:list, where.merge(scope: "builtin", kind: nil, json: true)],
        [:show, where.merge(ref: "orchestrator", scope: "builtin", json: false)]
      ])
    end

    it "routes show and info with the ref" do
      cli.run(["library", "show", "play/kickoff"])
      cli.run(["library", "info", "kickoff", "--name", "api", "--json"])

      expect(library_command.calls).to eq([
        [:show, where.merge(ref: "play/kickoff", json: false)],
        [:info, where.merge(ref: "kickoff", scope: "project", project: "api", json: true)]
      ])
    end

    it "routes add with a path, a name, link, force, project and dry-run" do
      cli.run(["library", "add", "Play.md", "--kind", "play", "--as", "my-play", "--link", "--force", "--project", "--dry-run"])

      expect(library_command.calls).to eq([[:add, where.merge(scope: "project", kind: "play", path: "Play.md", body: nil, name: "my-play",
        link: true, force: true, dry_run: true)]])
      expect(output.string).to eq("")
    end

    it "reads the body from stdin for add - and update -" do
      input = Class.new(StringIO) { def tty? = true }.new("typed body\n")
      cli, output = build_test_cli(library_command: library_command, working_dir: "/some/dir", input: input)

      cli.run(["library", "add", "-", "--kind", "prompt", "--as", "typed"])
      input.rewind
      cli.run(["library", "update", "prompt/typed", "-"])

      expect(library_command.calls).to eq([
        [:add, where.merge(kind: "prompt", path: nil, body: "typed body\n", name: "typed", link: false, force: false, dry_run: false)],
        [:update, where.merge(ref: "prompt/typed", path: nil, body: "typed body\n", link: false, dry_run: false)]
      ])
      expect(output.string).to eq("")
    end

    it "prints an action document for add, with dry_run status under --dry-run" do
      cli.run(["library", "add", "x.md", "--kind", "play", "--json"])
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "action" => "library add", "status" => "ok", "summary" => {"added" => 1})
      expect(doc["results"].first).to include("workspace" => nil, "outcome" => "added", "message" => "Added play/kickoff in the global library.",
        "entry" => include("ref" => "play/kickoff"))

      output.truncate(0)
      output.rewind
      output.rewind
      cli.run(["library", "add", "x.md", "--kind", "play", "--json", "--dry-run"])
      expect(JSON.parse(output.string)).to include("status" => "dry_run")
    end

    it "routes remove with --yes and prints a removed row" do
      library_command.result = Workspace::Commands::Library::Result.new("removed", "api", {"ref" => "play/kickoff"}, "Removed play/kickoff from project api.")

      cli.run(["library", "remove", "play/kickoff", "--yes", "--project", "api", "--json"])

      expect(library_command.calls).to eq([[:remove, where.merge(ref: "play/kickoff", scope: "project", project: "api", yes: true, dry_run: false, force: false)]])
      expect(JSON.parse(output.string)).to include("action" => "library remove", "status" => "ok",
        "results" => [include("workspace" => "api", "outcome" => "removed")])
    end

    describe "install and uninstall" do
      let(:installed) { Workspace::Commands::Library::InstallResult.new("skill/x", "app", "installed", "/w/app/.claude/skills/x", false) }

      before { library_command.result = installed }

      it "passes the workspace, --force and --dry-run to install, and the working directory" do
        cli.run(["library", "install", "skill/x", "--name", "app", "--force", "--dry-run"])
        cli.run(["library", "install", "skill/x"])
        cli.run(["library", "install", "skill/x", "--user", "--force"])

        expect(library_command.calls).to eq([
          [:install, {ref: "skill/x", name: "app", force: true, dry_run: true, user: false, from: nil, cwd: "/some/dir"}],
          [:install, {ref: "skill/x", name: nil, force: false, dry_run: false, user: false, from: nil, cwd: "/some/dir"}],
          [:install, {ref: "skill/x", name: nil, force: true, dry_run: false, user: true, from: nil, cwd: "/some/dir"}]
        ])
      end

      it "refuses --user with --name, for install and uninstall" do
        expect { cli.run(["library", "install", "skill/x", "--user", "--name=app"]) }.to raise_error(FakeSystemExit)
        expect { cli.run(["library", "uninstall", "skill/x", "--user", "--name=app"]) }.to raise_error(FakeSystemExit)
        expect(library_command.calls).to be_empty
      end

      it "passes --user to uninstall, with no workspace" do
        cli.run(["library", "uninstall", "skill/x", "--user", "--force", "--dry-run"])

        expect(library_command.calls).to eq([[:uninstall, {ref: "skill/x", name: nil, force: true, dry_run: true, user: true, cwd: "/some/dir"}]])
      end

      it "passes --from to install, and refuses it for uninstall" do
        cli.run(["library", "install", "skill/x", "--from=global"])
        cli.run(["library", "install", "skill/x", "--user", "--from", "project"])
        expect { cli.run(["library", "uninstall", "skill/x", "--from=global"]) }.to raise_error(FakeSystemExit)

        expect(library_command.calls.map { |c| c.last.values_at(:from, :user) }).to eq([["global", false], ["project", true]])
      end

      it "passes the workspace, --force and --dry-run to uninstall" do
        cli.run(["library", "uninstall", "--name", "app", "agent/y", "--force", "--dry-run"])

        expect(library_command.calls).to eq([[:uninstall, {ref: "agent/y", name: "app", force: true, dry_run: true, user: false, cwd: "/some/dir"}]])
      end

      it "prints one document under --json and no extra text" do
        cli.run(["library", "install", "skill/x", "--name", "app", "--json"])

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "ref" => "skill/x", "workspace" => "app",
          "result" => "installed", "path" => "/w/app/.claude/skills/x", "dry_run" => false, "user" => false, "entry" => nil)
      end

      it "emits the error envelope for a refusal under --json" do
        library_command.error = Workspace::Error.new("differs", code: "library_install_exists", details: {"ref" => "skill/x"})

        expect { cli.run(["library", "install", "skill/x", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "library_install_exists")
      end
    end

    describe "installed" do
      it "passes the workspace, --user, --kind and --json" do
        cli.run(["library", "installed"])
        cli.run(["library", "installed", "--name=app", "--kind=skill", "--json"])
        cli.run(["library", "installed", "--user"])

        expect(library_command.calls).to eq([
          [:installed, {name: nil, user: false, kind: nil, json: false, cwd: "/some/dir"}],
          [:installed, {name: "app", user: false, kind: "skill", json: true, cwd: "/some/dir"}],
          [:installed, {name: nil, user: true, kind: nil, json: false, cwd: "/some/dir"}]
        ])
      end

      it "refuses --user with --name, --global and a stray argument" do
        expect { cli.run(["library", "installed", "--user", "--name=app"]) }.to raise_error(FakeSystemExit)
        expect { cli.run(["library", "installed", "--global"]) }.to raise_error(FakeSystemExit)
        expect { cli.run(["library", "installed", "skill/x"]) }.to raise_error(FakeSystemExit)
        expect(library_command.calls).to be_empty
      end

      it "emits a usage error document under --json" do
        expect { cli.run(["library", "installed", "--user", "--name=app", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      end

      it "emits the error envelope for a refusal under --json" do
        library_command.error = Workspace::Error.new("no", code: "unknown_workspace", details: {"name" => "ghost"})

        expect { cli.run(["library", "installed", "--name=ghost", "--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
      end
    end

    it "prompts for remove on a terminal and reports cancelled when declined" do
      library_command.result = nil

      cli.run(["library", "remove", "play/kickoff"])

      expect(library_command.calls).to eq([[:remove, where.merge(ref: "play/kickoff", yes: false, dry_run: false, force: false)]])
    end

    it "never prompts for remove under --json, --no-input or without a terminal" do
      expect { cli.run(["library", "remove", "play/kickoff", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string.lines.last)).to include("code" => "usage", "error" => a_string_matching(/--yes/))

      cli, _, error_output = build_test_cli(library_command: library_command, input: StringIO.new("y\n"))
      expect { cli.run(["library", "remove", "play/kickoff"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("without a terminal: pass --yes")

      cli, output = build_test_cli(library_command: library_command, input: Workspace::PromptInput.new(tty_input))
      expect { cli.run(["library", "remove", "play/kickoff", "--no-input", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "confirmation_required", "retry" => {"flags" => ["--yes"], "destructive" => true})
      expect(library_command.calls).to be_empty
    end

    it "emits the command's error envelope under --json" do
      library_command.error = Workspace::Error.new("No library entry 'x'.", code: "unknown_library_entry", details: {"ref" => "x", "scopes" => ["global"]})

      expect { cli.run(["library", "show", "x", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_library_entry", "details" => {"ref" => "x", "scopes" => ["global"]})
    end

    it "rejects bad usage, as an envelope under --json" do
      {
        ["library", "show"] => /needs a REF/,
        ["library", "add", "--kind", "play"] => /needs a PATH/,
        ["library", "add", "x.md"] => /needs --kind/,
        ["library", "update", "play/x"] => /needs a REF and a PATH/,
        ["library", "remove"] => /needs a REF/,
        ["library", "install"] => /library install needs a REF/,
        ["library", "uninstall"] => /library uninstall needs a REF/,
        ["library", "install", "--name", "skill/x"] => /--name took 'skill\/x' as the workspace name/,
        ["library", "install", "skill/x", "--global"] => /takes --name WS/,
        ["library", "uninstall", "skill/x", "--builtin"] => /takes --name WS/,
        ["library", "install", "skill/x", "extra"] => /Unexpected argument: extra/,
        ["library", "list", "--global", "--project", "api"] => /--global, --builtin and --project/,
        ["library", "list", "--global", "--builtin"] => /can.t be combined/,
        ["library", "add", "x.md", "--kind", "play", "--builtin"] => /can.t change the built-in entries/,
        ["library", "update", "play/x", "x.md", "--builtin"] => /library update can.t change the built-in entries/,
        ["library", "remove", "play/x", "--yes", "--builtin"] => /can.t change the built-in entries/,
        ["library", "show", "a", "b"] => /Unexpected argument: b/,
        ["library", "bogus"] => /Unknown library subcommand: bogus/,
        ["library", "list", "--nope"] => /invalid option/
      }.each do |argv, message|
        cli, _, error_output = build_test_cli(library_command: library_command, input: tty_input)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)

        cli, output = build_test_cli(library_command: library_command, input: tty_input)
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
      end
      expect(library_command.calls).to be_empty
    end

    it "prints help" do
      cli.run(["library", "--help"])

      expect(output.string).to include("Usage: workspace library list").and include("workspace library remove REF").and include("docs/README.library.md")
    end

    it "fails when no library command was wired" do
      cli, _, error_output = build_test_cli(library_command: nil)

      expect { cli.run(["library", "list"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no library command was wired")
    end
  end

  describe "#run with restore" do
    # Answers like Commands::Restore: asks its block to launch the workspaces
    # whose session is gone, then returns its rows.
    let(:restore_class) do
      Class.new do
        attr_reader :calls, :launch_failures

        def initialize(result: {exit_code: 0, results: [], warnings: [], extra: {"dry_run" => false, "unmatched" => []}}, missing: [])
          @result = result
          @missing = missing
          @calls = []
        end

        def call(names, dry_run: false)
          @calls << {names: names, dry_run: dry_run}
          @launch_failures = yield(@missing) unless @missing.empty?
          @result
        end
      end
    end
    let(:state) { CLITestHelpers::FakeState.new }
    let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/code/api", "web" => "/code/web") }

    def restore_cli(restore_command, **overrides)
      build_test_cli(restore_command: restore_command, state: state, project_config: project_config, **overrides)
    end

    it "restores the active set with --all" do
      state["api"] = {"iterm_window_id" => 1}
      state["web"] = {"headless" => true}
      restore = restore_class.new
      cli, = restore_cli(restore)

      cli.run(["restore", "--all"])
      cli.run(["restore", "--all", "--dry-run"])

      expect(restore.calls).to eq([{names: %w[api web], dry_run: false}, {names: %w[api web], dry_run: true}])
    end

    it "restores only the workspace the working directory is in by default" do
      state["api"] = {"iterm_window_id" => 1}
      state["web"] = {"headless" => true}
      restore = restore_class.new
      cli, = restore_cli(restore, working_dir: "/code/web/src")

      cli.run(["restore", "--dry-run"])

      expect(restore.calls).to eq([{names: %w[web], dry_run: true}])
    end

    it "restores the workspace named by --name" do
      restore = restore_class.new
      cli, = restore_cli(restore)

      cli.run(["restore", "--name", "api"])

      expect(restore.calls).to eq([{names: %w[api], dry_run: false}])
    end

    it "refuses with not_in_workspace outside any workspace, and --all beside a name" do
      state["api"] = {}
      restore = restore_class.new
      cli, _, error_output = restore_cli(restore)

      expect { cli.run(["restore"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("No workspace found for")
      expect { cli.run(["restore", "--all", "api"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--all restores every active workspace")
      expect(restore.calls).to eq([])
    end

    it "restores only the workspaces named, each once" do
      state["api"] = {"iterm_window_id" => 1}
      restore = restore_class.new
      cli, = restore_cli(restore)

      cli.run(["restore", "web", "web", "--dry-run"])

      expect(restore.calls).to eq([{names: %w[web], dry_run: true}])
    end

    it "refuses an unknown workspace before anything runs" do
      restore = restore_class.new
      cli, _, error_output = restore_cli(restore)

      expect { cli.run(["restore", "nope"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("Unknown workspace 'nope'")
      expect(restore.calls).to eq([])
    end

    it "fails when nothing is active and nothing is named" do
      restore = restore_class.new
      cli, _, error_output = restore_cli(restore)

      expect { cli.run(["restore", "--all"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("No active workspace projects to restore. Name one: workspace restore WORKSPACE (--all restores every active one)")
      expect(restore.calls).to eq([])
    end

    it "exits 1 when a row failed" do
      state["api"] = {}
      cli, = restore_cli(restore_class.new(result: {exit_code: 1, results: [], warnings: [], extra: {}}))

      expect { cli.run(["restore", "--all"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "fails when no restore command was wired" do
      cli, _, error_output = build_test_cli(restore_command: nil)

      expect { cli.run(["restore", "--all"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no restore command was wired")
    end

    it "is listed in the main help" do
      cli, output, = build_test_cli

      cli.run(["help"])

      expect(output.string).to match(/^\s+restore\s+Bring back agent panes after a reboot/)
    end

    it "explains itself with a usage error's help" do
      cli, _, error_output = restore_cli(restore_class.new)

      expect { cli.run(["restore", "--bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("invalid option: --bogus")
    end

    describe "launching the sessions that are gone" do
      let(:launch) do
        Class.new do
          attr_reader :calls

          def initialize(state, fail: [], raise_for: nil)
            @state = state
            @fail = fail
            @raise_for = raise_for
            @calls = []
          end

          def call(projects, **options)
            @calls << [projects, options[:headless] == true]
            raise Workspace::Error, "Missing config for #{projects.join(", ")}" if @raise_for == ((options[:headless] == true) ? :headless : :windowed)
            start_failures = projects.select { |p| @fail.include?(p) }.to_h { |p| [p, "tmuxinator exited 1"] }
            projects.each { |p| @state[p] = {"iterm_window_id" => 7, "headless" => options[:headless] == true} unless @fail.include?(p) }
            {exit_code: start_failures.empty? ? 0 : 1, prompt_failures: {}, reused: [], start_failures: start_failures}
          end
        end
      end

      before do
        state["api"] = {"iterm_window_id" => 1}
        state["web"] = {"headless" => true}
      end

      it "launches each the way it was last launched and reports no failures" do
        launcher = launch.new(state)
        restore = restore_class.new(missing: %w[api web])
        cli, = restore_cli(restore, launch_command: launcher, launch_mode: CLITestHelpers.launch_mode(headless: false))

        cli.run(["restore", "--all"])

        expect(launcher.calls).to eq([[%w[api], false], [%w[web], true]])
        expect(restore.launch_failures).to eq({})
      end

      it "sends no packs when it launches a missing workspace" do
        composer = instance_double(Workspace::InstructionComposer)
        allow(composer).to receive(:compose_start)
        restore = restore_class.new(missing: %w[api])
        cli, = restore_cli(restore, launch_command: launch.new(state), launch_mode: CLITestHelpers.launch_mode(headless: false), instruction_composer: composer)

        cli.run(["restore", "--all"])

        expect(composer).not_to have_received(:compose_start)
      end

      it "hands back why a workspace could not be launched" do
        launcher = launch.new(state, fail: %w[web])
        restore = restore_class.new(missing: %w[api web])
        cli, = restore_cli(restore, launch_command: launcher, launch_mode: CLITestHelpers.launch_mode(headless: false))

        cli.run(["restore", "--all"])

        expect(restore.launch_failures).to eq("web" => "tmuxinator exited 1")
      end

      it "fails a whole batch whose launch raised, and still launches the other" do
        launcher = launch.new(state, raise_for: :windowed)
        restore = restore_class.new(missing: %w[api web])
        cli, = restore_cli(restore, launch_command: launcher, launch_mode: CLITestHelpers.launch_mode(headless: false))

        cli.run(["restore", "--all"])

        expect(launcher.calls.size).to eq(2)
        expect(restore.launch_failures).to eq("api" => "Missing config for api")
      end
    end
  end

  describe "#run with binding" do
    let(:binding_command) { CLITestHelpers::FakeBindingCommand.new }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(binding_command: binding_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "routes set with the workspace positional, the pane and the subject" do
      cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", "--step", "implement", "--attempt", "2"])

      expect(binding_command.calls).to eq([[:set, {workspace: "app", pane: "%5", kind: "run", id: "wr_1", step: "implement", attempt: 2}]])
    end

    it "passes each --pack to set, and only when one is given" do
      cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "play", "--id", "play/notes", "--pack", "notes", "--pack", "handoff"])

      expect(binding_command.calls).to eq([[:set, {workspace: "app", pane: "%5", kind: "play", id: "play/notes", packs: %w[notes handoff]}]])
    end

    it "refuses a pack that is not in the library, before binding anything" do
      composer = instance_double(Workspace::InstructionComposer)
      allow(composer).to receive(:compose).with(packs: ["nope"], cwd: "/some/dir")
        .and_raise(Workspace::Error.new("No pack nope", code: "unknown_library_entry"))
      built_cli, _, err = build_test_cli(binding_command: binding_command, instruction_composer: composer, working_dir: "/some/dir")

      expect { built_cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "play", "--id", "play/nope", "--pack", "nope"]) }.to raise_error(FakeSystemExit)
      expect(binding_command.calls).to be_empty
      expect(err.string).to include("No pack nope")
    end

    it "binds a pane to a play through the real binding command and store" do
      Dir.mktmpdir do |dir|
        store = Workspace::PaneBindings.new(path: File.join(dir, "bindings.json"))
        locator = instance_double(Workspace::PaneLocator)
        allow(locator).to receive(:locate).with("app", "%5").and_return({id: "%5", window: 0, index: 1, session: "app"})
        tmux = instance_double(Workspace::Tmux, pane_slot: "app:0.1")
        out = StringIO.new
        real_cli, = build_test_cli(output: out, binding_command: Workspace::Commands::Binding.new(bindings: store, locator: locator, tmux: tmux, output: out))

        real_cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "play", "--id", "play/kickoff", "--instructions", "/lib/play/kickoff.md"])

        expect(store.binding_for("%5")).to include("kind" => "play", "id" => "play/kickoff", "instructions" => "/lib/play/kickoff.md")
        expect(out.string).to include("Bound pane %5 to play play/kickoff.")
      end
    end

    it "uses the detected workspace for set when none is named" do
      cli.run(["binding", "set", "--pane", "0.1", "--kind", "review", "--id", "acme/api#835", "--focus", "security"])

      expect(binding_command.calls).to eq([[:set, {workspace: "detected-ws", pane: "0.1", kind: "review", id: "acme/api#835", focus: "security"}]])
    end

    it "defaults show and clear to $TMUX_PANE and takes --pane" do
      stub_env("TMUX_PANE" => "%9")
      cli.run(["binding", "show"])
      cli.run(["binding", "clear", "--pane", "%5"])

      expect(binding_command.calls).to eq([[:show, {pane: "%9"}], [:clear, {pane: "%5"}]])
    end

    it "prints an action document under --json" do
      cli.run(["binding", "show", "--pane", "%5", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "action" => "binding show", "status" => "ok")
      expect(doc["results"].first).to include("workspace" => "app", "outcome" => "shown", "binding" => include("id" => "wr_1"))
    end

    it "prints a cleared action document for clear under --json" do
      cli.run(["binding", "clear", "--pane", "%5", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("action" => "binding clear", "status" => "ok")
      expect(doc["results"].first).to include("outcome" => "cleared", "binding" => include("id" => "wr_1"))
    end

    it "emits a JSON error envelope with the command's code" do
      binding_command.error = Workspace::Error.new("Pane %5 is not bound.", code: "not_bound")

      expect { cli.run(["binding", "show", "--pane", "%5", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_bound")
    end

    it "defaults set to $TMUX_PANE, the pane the command runs in" do
      stub_env("TMUX_PANE" => "%9")
      cli.run(["binding", "set", "app", "--kind", "run", "--id", "wr_1"])
      cli.run(["binding", "set", "app", "--pane", "0.1", "--kind", "run", "--id", "wr_1"])

      expect(binding_command.calls.map { |_, args| args[:pane] }).to eq(["%9", "0.1"])
    end

    it "stores --instructions and --artifacts as absolute paths, from the directory the command runs in" do
      cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", "--instructions", "runs/plan.md", "--artifacts", "../out"])
      cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", "--instructions", "/abs/plan.md", "--artifacts", "~/out"])

      expect(binding_command.calls.map { |_, args| args.values_at(:instructions, :artifacts) }).to eq([
        ["/some/dir/runs/plan.md", "/some/out"],
        ["/abs/plan.md", File.expand_path("~/out")]
      ])
    end

    it "leaves a blank --instructions or --artifacts blank, for the command to refuse" do
      cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", "--instructions", "", "--artifacts", "  "])

      expect(binding_command.calls.first.last.values_at(:instructions, :artifacts)).to eq(["", "  "])
    end

    it "refuses a blank --artifacts through the real command, storing nothing" do
      Dir.mktmpdir do |dir|
        store = Workspace::PaneBindings.new(path: File.join(dir, "bindings.json"))
        locator = instance_double(Workspace::PaneLocator, locate: {id: "%5", window: 0, index: 1, session: "app"})
        tmux = instance_double(Workspace::Tmux, pane_slot: "app:0.1")
        real_cli, _, err = build_test_cli(binding_command: Workspace::Commands::Binding.new(bindings: store, locator: locator, tmux: tmux, output: StringIO.new))

        expect { real_cli.run(["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", "--artifacts", ""]) }.to raise_error(FakeSystemExit)
        expect(err.string).to include("artifacts must be one line of text")
        expect(store.binding_for("%5")).to be_nil
      end
    end

    %w[--instructions --artifacts].each do |flag|
      it "refuses a #{flag} path under an unknown ~user as a usage error, binding nothing" do
        argv = ["binding", "set", "app", "--pane", "%5", "--kind", "run", "--id", "wr_1", flag, "~no-such-user-cli27/plan.md"]

        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(built[2].string).to include("#{flag}: can't make ~no-such-user-cli27/plan.md an absolute path")
        expect(built[2].string).not_to include("ArgumentError")

        json_cli, json_output = build_test_cli(binding_command: binding_command, project_detector: detector, working_dir: "/some/dir")
        expect { json_cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(JSON.parse(json_output.string)).to include("ok" => false, "code" => "usage",
          "error" => a_string_including("#{flag}: can't make ~no-such-user-cli27/plan.md an absolute path"))
        expect(binding_command.calls).to be_empty
      end
    end

    it "reports a stale binding in the show document" do
      Dir.mktmpdir do |dir|
        store = Workspace::PaneBindings.new(path: File.join(dir, "bindings.json"))
        store.bind("%5", "kind" => "run", "id" => "wr_1", "workspace" => "app", "session" => "app", "pane_slot" => "app:0.1")
        tmux = instance_double(Workspace::Tmux, session_name_for_pane: "app", pane_slot: "app:0.2")
        real_cli, out = build_test_cli(binding_command: Workspace::Commands::Binding.new(bindings: store,
          locator: instance_double(Workspace::PaneLocator), tmux: tmux, output: StringIO.new))

        real_cli.run(["binding", "show", "--pane", "%5", "--json"])

        expect(JSON.parse(out.string)["results"].first).to include("outcome" => "shown", "binding" => include("id" => "wr_1", "stale" => true))
      end
    end

    it "rejects a set without a pane, kind or id as a usage error" do
      stub_env("TMUX_PANE" => nil)
      {
        ["binding", "set", "app", "--kind", "run", "--id", "x"] => /--pane/,
        ["binding", "set", "app", "--pane", "%5"] => /--kind and --id/,
        ["binding"] => /Missing subcommand/
      }.each do |args, message|
        expect { cli.run(args) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(built[2].string).to match(message)
      end
      expect(binding_command.calls).to be_empty
    end

    it "prints help" do
      cli.run(["binding", "--help"])

      expect(output.string).to include("Usage: workspace binding set").and include("$TMUX_PANE")
    end
  end

  describe "#run with instructions" do
    let(:instructions_command) { CLITestHelpers::FakeInstructionsCommand.new }
    let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/work/api") }
    let(:built) { build_test_cli(instructions_command: instructions_command, project_config: project_config, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    before { stub_env("TMUX_PANE" => nil) }

    it "composes the default packs for the current directory, with no pane outside tmux" do
      cli.run(["instructions", "compose"])

      expect(instructions_command.calls).to eq([[:compose, {packs: [], cwd: "/some/dir", pane: nil, json: false}]])
    end

    it "takes --pack more than once, in order, with --json before or after the subcommand" do
      cli.run(["instructions", "compose", "--pack", "review", "--pack", "play/orchestrator", "--json"])
      cli.run(["instructions", "--json", "compose", "--pack", "commits"])

      expect(instructions_command.calls).to eq([
        [:compose, {packs: %w[review play/orchestrator], cwd: "/some/dir", pane: nil, json: true}],
        [:compose, {packs: %w[commits], cwd: "/some/dir", pane: nil, json: true}]
      ])
    end

    it "defaults the pane to $TMUX_PANE and takes --pane" do
      stub_env("TMUX_PANE" => "%9")
      cli.run(["instructions", "compose"])
      cli.run(["instructions", "compose", "--pane", "%5"])

      expect(instructions_command.calls.map { |_, args| args[:pane] }).to eq(["%9", "%5"])
    end

    it "composes for a named workspace from its root, without the caller's pane unless --pane names one" do
      stub_env("TMUX_PANE" => "%9")
      cli.run(["instructions", "compose", "--name", "api"])
      cli.run(["instructions", "compose", "--name", "api", "--pane", "%5"])

      expect(instructions_command.calls.map(&:last)).to eq([
        {packs: [], cwd: "/work/api", pane: nil, json: false},
        {packs: [], cwd: "/work/api", pane: "%5", json: false}
      ])
    end

    it "fails an unknown workspace with unknown_workspace, composing nothing" do
      expect { cli.run(["instructions", "compose", "--name", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_workspace")
      expect(instructions_command.calls).to be_empty
    end

    it "emits the command's error envelope under --json, and its message without" do
      instructions_command.error = Workspace::Error.new("No library entry 'play/nope' in builtin, global.", code: "unknown_library_entry",
        details: {"ref" => "play/nope", "scopes" => %w[builtin global]})

      expect { cli.run(["instructions", "compose", "--pack", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "unknown_library_entry",
        "details" => {"ref" => "play/nope", "scopes" => %w[builtin global]})

      expect { cli.run(["instructions", "compose", "--pack", "nope"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("No library entry 'play/nope'")
    end

    it "rejects bad usage, as an envelope under --json" do
      {
        ["instructions"] => /Missing subcommand: compose/,
        ["instructions", "list"] => /Unknown instructions subcommand: list/,
        ["instructions", "compose", "extra"] => /Unexpected argument: extra/,
        ["instructions", "compose", "--nope"] => /invalid option/
      }.each do |argv, message|
        cli, _, error_output = build_test_cli(instructions_command: instructions_command)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)

        cli, output = build_test_cli(instructions_command: instructions_command)
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit)
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage")
      end
      expect(instructions_command.calls).to be_empty
    end

    it "passes --start and --no-packs through, and refuses the bad combinations" do
      cli.run(["instructions", "compose", "--start", "--pack", "review", "--json"])
      cli.run(["instructions", "compose", "--start", "--no-packs", "--name", "api"])

      expect(instructions_command.calls.map(&:last)).to eq([
        {packs: %w[review], cwd: "/some/dir", pane: nil, json: true, start: true, no_packs: false},
        {packs: [], cwd: "/work/api", pane: nil, json: false, start: true, no_packs: true}
      ])
      {
        ["instructions", "compose", "--no-packs"] => /--no-packs only works with --start/,
        ["instructions", "compose", "--start", "--no-packs", "--pack", "review"] => /--no-packs cannot be combined with --pack/,
        ["instructions", "compose", "--start", "--pane", "%5"] => /--pane has no effect with --start/
      }.each do |argv, message|
        cli, _, error_output = build_test_cli(instructions_command: instructions_command)
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to match(message)
      end
      expect(instructions_command.calls.size).to eq(2)
    end

    it "prints help, also from the main help" do
      cli.run(["instructions", "--help"])
      expect(output.string).to include("Usage: workspace instructions compose").and include("--pack NAME").and include("commands.test")

      cli.run(["help"])
      expect(output.string).to match(/^\s+instructions\s+Print the instructions built from library packs/)
    end

    it "says so when no instructions command was wired" do
      cli, _, error_output = build_test_cli(instructions_command: nil)

      expect { cli.run(["instructions", "compose"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no instructions command was wired")
    end
  end

  describe "#run with notes" do
    let(:notes_command) { instance_double(Workspace::Commands::Notes, dir: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(notes_command: notes_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "answers for the workspace detected from the working directory" do
      cli.run(["notes", "dir"])

      expect(detector).to have_received(:detect).with("/some/dir")
      expect(notes_command).to have_received(:dir).with(name: "detected-ws", create: false, json: false)
    end

    it "passes --name, --create and --json in any order" do
      cli.run(["notes", "dir", "--json", "--create", "--name", "api.worktree-x"])

      expect(notes_command).to have_received(:dir).with(name: "api.worktree-x", create: true, json: true)
    end

    it "fails with not_in_workspace outside a workspace, as an envelope under --json" do
      allow(detector).to receive(:detect).and_return(nil)

      expect { cli.run(["notes", "dir", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "not_in_workspace", "details" => {"path" => "/some/dir"})
      expect(error_output.string).to eq("")
    end

    it "prints a command's failure as the envelope under --json and on stderr without it" do
      allow(notes_command).to receive(:dir).and_raise(Workspace::Error.new("Can't set up", code: "notes_dir_unwritable", details: {"path" => "/p"}))

      expect { cli.run(["notes", "dir", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "notes_dir_unwritable", "details" => {"path" => "/p"})

      expect { cli.run(["notes", "dir"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Error: Can't set up")
    end

    it "takes the subcommand after the options" do
      cli.run(["notes", "--json", "dir"])

      expect(notes_command).to have_received(:dir).with(name: "detected-ws", create: false, json: true)
    end

    it "shows help" do
      cli.run(["notes", "--help"])

      expect(output.string).to include("workspace notes dir").and include("--create")
      expect(notes_command).not_to have_received(:dir)
    end

    it "rejects a missing subcommand, an unknown one, and extra arguments as usage errors" do
      [["notes"], ["notes", "bogus"], ["notes", "dir", "extra"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
      expect(notes_command).not_to have_received(:dir)
    end
  end

  describe "#run with skills" do
    let(:skills_command) { instance_double(Workspace::Commands::Skills, install: true, uninstall: true) }
    let(:built) { build_test_cli(skills_command: skills_command) }
    let(:cli) { built[0] }

    it "passes install's flags through" do
      cli.run(["skills", "install", "--install-all", "--dry-run", "--json"])

      expect(skills_command).to have_received(:install).with(install_all: true, dry_run: true, json: true)
    end

    it "installs with no flags by default and accepts --no-input anywhere" do
      cli.run(["skills", "install", "--no-input"])

      expect(skills_command).to have_received(:install).with(install_all: false, dry_run: false, json: false)
    end

    it "passes uninstall's flags through" do
      cli.run(["skills", "uninstall", "--dry-run"])

      expect(skills_command).to have_received(:uninstall).with(dry_run: true, json: false)
    end

    it "exits 1 when the command says something was refused" do
      allow(skills_command).to receive(:install).and_return(false)

      expect { cli.run(["skills", "install"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "refuses --install-all on uninstall, a missing or unknown subcommand and extra arguments" do
      expect { cli.run(["skills", "uninstall", "--install-all"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["skills"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["skills", "nope"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["skills", "install", "extra"]) }.to raise_error(FakeSystemExit)
      expect(skills_command).not_to have_received(:install)
    end

    %w[install uninstall].each do |verb|
      it "prints the #{verb} page for skills #{verb} --help and calls nothing" do
        cli.run(["skills", verb, "--help"])

        other = (verb == "install") ? "uninstall" : "install"
        expect(built[1].string).to include("Usage: workspace skills #{verb}")
        expect(built[1].string).to include(Workspace::HelpPages::SKILLS.fetch(verb)[:summary])
        expect(built[1].string).not_to include("workspace skills #{other}")
        expect(skills_command).not_to have_received(:install)
        expect(skills_command).not_to have_received(:uninstall)
      end
    end

    it "lists skills in the main help" do
      built[1].truncate(0)
      cli.run(["help"])

      expect(built[1].string).to match(/^\s+skills\s+Link the workspace skills/)
    end
  end

  describe "#run with ticket" do
    let(:ticket_command) { instance_double(Workspace::Commands::Ticket, show: nil, list: nil) }
    let(:built) { build_test_cli(ticket_command: ticket_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "shows a ref" do
      cli.run(["ticket", "show", "PROJ-123"])

      expect(ticket_command).to have_received(:show).with("PROJ-123", name: nil, json: false)
    end

    it "passes --name and --json in any order" do
      cli.run(["ticket", "show", "--json", "PROJ-123", "--name", "api"])

      expect(ticket_command).to have_received(:show).with("PROJ-123", name: "api", json: true)
    end

    it "looks in the workspace detected from the working directory when no --name is given" do
      detector = Struct.new(:found) { def detect(_dir) = found }.new("api.worktree-x")
      cli, = build_test_cli(ticket_command: ticket_command, project_detector: detector,
        project_config: CLITestHelpers::FakeProjectConfig.new("api.worktree-x" => "/src/api-x"))

      cli.run(["ticket", "show", "PROJ-1"])
      cli.run(["ticket", "list"])
      cli.run(["ticket", "show", "PROJ-2", "--name", "other"])

      expect(ticket_command).to have_received(:show).with("PROJ-1", name: "api.worktree-x", json: false)
      expect(ticket_command).to have_received(:list).with(name: "api.worktree-x", filter: "assigned", limit: 20, sources: [], json: false)
      expect(ticket_command).to have_received(:show).with("PROJ-2", name: "other", json: false)
    end

    it "leaves ticket to the current directory's git repository outside any workspace, or for a detected one with no checkout" do
      detector = Struct.new(:found) { def detect(_dir) = found }.new(nil)
      cli, = build_test_cli(ticket_command: ticket_command, project_detector: detector, project_config: CLITestHelpers::FakeProjectConfig.new)

      cli.run(["ticket", "show", "PROJ-1"])
      detector.found = "marker-only"
      cli.run(["ticket", "list"])

      expect(ticket_command).to have_received(:show).with("PROJ-1", name: nil, json: false)
      expect(ticket_command).to have_received(:list).with(name: nil, filter: "assigned", limit: 20, sources: [], json: false)
    end

    it "prints a command's failure as the envelope under --json and on stderr without it" do
      allow(ticket_command).to receive(:show).and_raise(Workspace::Error.new("No such ticket", code: "ticket_not_found", details: {"source" => "gh"}))

      expect { cli.run(["ticket", "show", "#9", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "ticket_not_found", "details" => {"source" => "gh"})
      expect(error_output.string).to eq("")

      expect { cli.run(["ticket", "show", "#9"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Error: No such ticket")
    end

    it "shows help" do
      cli.run(["ticket", "--help"])

      expect(output.string).to include("workspace ticket show").and include("--name")
      expect(ticket_command).not_to have_received(:show)
    end

    it "runs ticket list with its defaults, and with each option in either spelling" do
      cli, = built

      cli.run(["ticket", "list"])
      cli.run(["ticket", "list", "--recent", "--limit=5", "--source=gh", "--source", "jira", "--name=api", "--json"])

      expect(ticket_command).to have_received(:list).with(name: nil, filter: "assigned", limit: 20, sources: [], json: false)
      expect(ticket_command).to have_received(:list).with(name: "api", filter: "recent", limit: 5, sources: %w[gh jira], json: true)
    end

    it "refuses list options on show, a ref or extra words on list, and a limit that is not a number" do
      [["ticket", "show", "A-1", "--recent"], ["ticket", "show", "A-1", "--limit", "3"], ["ticket", "list", "A-1"],
        ["ticket", "list", "--limit", "many"], ["ticket", "list", "--assigned", "--recent"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false), argv.inspect
      end
      expect(ticket_command).not_to have_received(:show)
      expect(ticket_command).not_to have_received(:list)
    end

    it "rejects a missing subcommand, an unknown one, a missing ref and extra arguments as usage errors" do
      [["ticket"], ["ticket", "bogus"], ["ticket", "show"], ["ticket", "show", "a", "b"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
      expect(ticket_command).not_to have_received(:show)
    end

    it "says so when no ticket command was wired" do
      cli, _, error_output, = build_test_cli

      expect { cli.run(["ticket", "show", "PROJ-1"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("ticket is not available")
    end
  end

  describe "#run with go" do
    let(:go_command) { CLITestHelpers::FakeGoCommand.new }
    let(:output) { StringIO.new }
    let(:built) { build_test_cli(output: output, go_command: go_command) }
    let(:cli) { built[0] }
    let(:error_output) { built[2] }

    it "passes the argument and every flag to go, with the pane from $TMUX_PANE" do
      stub_env("TMUX_PANE" => "%9")

      cli.run(["go", "try the thing", "--workflow", "investigate", "--input", "task=x", "--input", "spec=y", "--dry-run"])

      expect(go_command.calls).to eq([{argument: "try the thing", workflow: "investigate", inputs: {"task" => "x", "spec" => "y"}, headless: false, dry_run: true, caller_pane: "%9", here: false, base: nil, text: false}])
    end

    it "passes --here to go" do
      cli.run(["go", "try the thing", "--here"])

      expect(go_command.calls.last).to include(argument: "try the thing", here: true)
    end

    it "passes --text to go" do
      cli.run(["go", "fix PROJ-1", "--text"])

      expect(go_command.calls.last).to include(argument: "fix PROJ-1", text: true)
    end

    it "passes --base to go" do
      cli.run(["go", "try the thing", "--base", "origin/main"])

      expect(go_command.calls.last).to include(argument: "try the thing", base: "origin/main")
    end

    it "passes the launch mode's headless setting to go" do
      headless_cli, = build_test_cli(output: output, go_command: go_command, launch_mode: CLITestHelpers.launch_mode(headless: true))

      headless_cli.run(["go", "try the thing"])

      expect(go_command.calls.last).to include(headless: true)
    end

    it "passes no argument for bare go" do
      stub_env("TMUX_PANE" => nil)

      cli.run(["go"])

      expect(go_command.calls.first).to include(argument: nil, workflow: nil, inputs: {}, dry_run: false, caller_pane: nil)
    end

    it "prints one action document with --json" do
      cli.run(["go", "PROJ-1", "--json"])

      document = JSON.parse(output.string)
      expect(document).to include("action" => "go", "status" => "ok")
      expect(document["results"].first).to include("decision" => include("route" => "start"))
    end

    it "refuses more than one argument, naming the quoting" do
      expect { cli.run(["go", "try", "the", "thing"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("go takes one argument, got 3", "Quote free text")
      expect(go_command.calls).to be_empty
    end

    it "refuses a bad --input and bytes that are not UTF-8, as JSON errors under --json" do
      expect { cli.run(["go", "x", "--input", "nokey", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string.lines.last)).to include("code" => "usage")

      expect { cli.run(["go", "caf\xE9".b, "--json"]) }.to raise_error(FakeSystemExit)
      expect(go_command.calls).to be_empty
    end

    it "fails when go was not wired" do
      cli, _out, err = build_test_cli
      expect { cli.run(["go", "x"]) }.to raise_error(FakeSystemExit)
      expect(err.string).to include("go is not available")
    end

    it "prints its help page" do
      cli.run(["go", "--help"])

      expect(output.string).to start_with("Usage: workspace go")
      expect(go_command.calls).to be_empty
    end
  end

  describe "#run with rename" do
    let(:rename_command) { instance_double(Workspace::Commands::Rename) }
    let(:output) { StringIO.new }
    let(:gate) { Workspace::OutputGate.new(output) }
    let(:built) { build_test_cli(output: gate, rename_command: rename_command) }
    let(:cli) { built[0] }
    let(:error_output) { built[2] }
    let(:result) do
      {"project" => "api", "workspace" => {"from" => "api.worktree-old", "to" => "api.worktree-new"},
       "branch" => {"from" => "old", "to" => "new"}, "path" => {"from" => "/a/old", "to" => "/a/new"},
       "session" => {"from" => "api.worktree-old", "to" => "api.worktree-new"},
       "notes" => {"action" => "stays", "from" => nil, "to" => nil, "reason" => "same"},
       "warnings" => [{"code" => "x", "message" => "careful"}], "resume" => false, "dry_run" => false,
       "next" => "Run `workspace restore api.worktree-new`."}
    end

    before { allow(rename_command).to receive(:call).and_return(result) }

    it "takes NEW alone and renames the workspace of the working directory" do
      detector = instance_double(Workspace::ProjectDetector, detect: "api.worktree-old")
      cli, _, error_output = build_test_cli(output: gate, rename_command: rename_command, project_detector: detector, working_dir: "/a/old")
      cli.run(["rename", "new"])

      expect(rename_command).to have_received(:call).with(workspace: "api.worktree-old", new: "new", dry_run: false)
      expect(output.string).to include("api.worktree-old -> api.worktree-new").and include("Run `workspace restore")
      expect(error_output.string).to include("Warning: careful")
    end

    it "takes WORKSPACE NEW, passing a name that no config has any more on to the command" do
      cli.run(["rename", "api.worktree-old", "new", "--dry-run"])

      expect(rename_command).to have_received(:call).with(workspace: "api.worktree-old", new: "new", dry_run: true)
    end

    it "takes --name WS" do
      cli.run(["rename", "new", "--name", "api.worktree-old"])

      expect(rename_command).to have_received(:call).with(workspace: "api.worktree-old", new: "new", dry_run: false)
    end

    it "refuses a workspace both before NEW and with --name, and no NEW" do
      expect { cli.run(["rename", "a", "b", "--name", "c"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect { cli.run(["rename"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(rename_command).not_to have_received(:call)
    end

    it "prints one document with --json" do
      cli.run(["rename", "a", "new", "--json"])

      document = JSON.parse(output.string)
      expect(document).to include("ok" => true, "warnings" => [{"code" => "x", "message" => "careful"}])
      expect(document["results"].first).to include("workspace" => "api.worktree-new", "next" => result["next"])
    end

    it "shows help without renaming" do
      cli.run(["rename", "--help"])

      expect(output.string).to include("Usage: workspace rename [WORKSPACE] NEW")
      expect(rename_command).not_to have_received(:call)
    end
  end

  describe "#run with promote" do
    let(:promote_command) { instance_double(Workspace::Commands::Promote) }
    let(:output) { StringIO.new }
    let(:gate) { Workspace::OutputGate.new(output) }
    let(:built) { build_test_cli(output: gate, promote_command: promote_command) }
    let(:cli) { built[0] }
    let(:error_output) { built[2] }
    let(:document) { {"schema_version" => 1, "ok" => true, "dry_run" => false} }

    before do
      allow(promote_command).to receive(:call) do |json:, **|
        gate.puts "noise from a collaborator"
        {exit_code: 0, json: document}
      end
    end

    it "passes every flag, in --flag=value form too, and prints one JSON document on stdout" do
      cli.run(["promote", "fix-login", "--name=api", "--title=Fix it", "--spine=team", "--plan=Add SSO", "--carry-note=a.md",
        "--carry-note", "b.md", "--force", "--agent-kind=codex", "--json"])

      expect(promote_command).to have_received(:call).with(working_dir: an_instance_of(String), branch: "fix-login", name: "api", title: "Fix it",
        spine: "team", plan: "Add SSO", carry_notes: ["a.md", "b.md"], launch: nil, prompt: nil, headless: false, agent_kind: "codex",
        force: true, dry_run: false, json: true)
      expect(JSON.parse(output.string)).to eq(document)
      expect(error_output.string).to include("noise from a collaborator")
    end

    it "passes --no-spine as false, bare --spine and --plan as true, and --dry-run" do
      cli.run(["promote", "--no-spine", "--plan", "--dry-run"])
      cli.run(["promote", "--spine"])

      expect(promote_command).to have_received(:call).with(hash_including(branch: nil, spine: false, plan: true, dry_run: true, json: false))
      expect(promote_command).to have_received(:call).with(hash_including(spine: true, plan: nil))
    end

    it "gives --launch a launcher, and refuses --prompt or --prompt-timeout without it" do
      cli.run(["promote", "x", "--launch", "--prompt=Go", "--prompt-timeout=90s"])
      expect(promote_command).to have_received(:call).with(hash_including(launch: respond_to(:call), prompt: "Go"))

      expect { cli.run(["promote", "x", "--prompt", "Go", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string.lines.last)).to include("code" => "usage", "error" => "--prompt needs --launch.")
    end

    it "refuses --spine with --no-spine, and a second argument" do
      [["promote", "--spine", "--no-spine"], ["promote", "a", "b"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
    end

    it "exits 2 for branch_required, with the envelope" do
      allow(promote_command).to receive(:call).and_raise(Workspace::UsageError.new("name a branch", code: "branch_required", details: {"from_branch" => "main"}))

      expect { cli.run(["promote", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(2) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "branch_required", "details" => {"from_branch" => "main"})
    end

    it "exits 1 with the envelope for a refusal, and with the command's exit code otherwise" do
      allow(promote_command).to receive(:call).and_raise(Workspace::Error.new("busy", code: "agent_working", details: {"panes" => []}))
      expect { cli.run(["promote", "x", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("code" => "agent_working")

      allow(promote_command).to receive(:call).and_return(exit_code: 1, json: document)
      expect { cli.run(["promote", "x", "--launch"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "shows help naming the promote pack" do
      cli.run(["promote", "--help"])

      expect(output.string).to include("Usage: workspace promote [BRANCH]").and include("workspace instructions compose --pack promote")
      expect(promote_command).not_to have_received(:call)
    end

    it "lists promote in the main help" do
      cli.run(["help"])

      expect(output.string).to match(/^\s+promote\s+Move the work in a main checkout/)
    end
  end

  describe "#run with rebase and push" do
    let(:rebase_command) { instance_double(Workspace::Commands::Rebase, call: nil) }
    let(:push_command) { instance_double(Workspace::Commands::Push, call: nil) }
    let(:built) { build_test_cli(rebase_command: rebase_command, push_command: push_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "passes rebase's flags to the command" do
      cli.run(["rebase", "--onto", "update", "--name", "api", "--json"])

      expect(rebase_command).to have_received(:call).with(name: "api", onto: "update", json: true, working_dir: an_instance_of(String))
    end

    [%w[rebase --onto bogus --help], %w[rebase --name x --help], %w[push --help]].each do |argv|
      it "prints the page and runs nothing for 'workspace #{argv.join(" ")}'" do
        cli.run(argv)

        expect(output.string).to start_with("Usage: workspace #{argv.first}")
        expect(rebase_command).not_to have_received(:call)
        expect(push_command).not_to have_received(:call)
      end
    end

    %w[--json --help].permutation.each do |flags|
      it "prints the page as one document and runs nothing for 'workspace push #{flags.join(" ")}'" do
        cli.run(["push", *flags])

        expect(JSON.parse(output.string)["usage"].first).to start_with("workspace push")
        expect(rebase_command).not_to have_received(:call)
        expect(push_command).not_to have_received(:call)
      end
    end

    it "keeps the status of a failed help run under an injected exit handler and prints one error document" do
      expect { cli.run(%w[nosuch --help --json]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage", "error" => "Unknown subcommand: nosuch")
      expect(error_output.string).to eq("")
    end

    it "runs nothing and prints text for 'workspace rebase --name --help --json', where --help is the name" do
      expect { cli.run(%w[rebase --name --help --json]) }.to raise_error(FakeSystemExit)

      expect(output.string).not_to include('"examples"')
      expect(rebase_command).not_to have_received(:call)
    end

    it "requires --onto for rebase" do
      expect { cli.run(["rebase", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage")
      expect(rebase_command).not_to have_received(:call)
    end

    it "rejects extra arguments to rebase and push as usage errors" do
      [["rebase", "--onto", "local", "extra"], ["push", "extra"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
    end

    it "passes push's flags to the command" do
      cli.run(["push"])
      cli.run(["push", "--json", "--name", "api"])

      expect(push_command).to have_received(:call).with(name: nil, json: false, working_dir: an_instance_of(String))
      expect(push_command).to have_received(:call).with(name: "api", json: true, working_dir: an_instance_of(String))
    end

    it "prints a command's failure as the envelope under --json" do
      allow(rebase_command).to receive(:call).and_raise(Workspace::Error.new("dirty", code: "dirty_worktree", details: {"files" => ["a"]}))

      expect { cli.run(["rebase", "--onto", "local", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "dirty_worktree", "details" => {"files" => ["a"]})
    end

    it "shows help for each" do
      cli.run(["rebase", "--help"])
      cli.run(["push", "--help"])

      expect(output.string).to include("workspace rebase --onto local|update|remote|upstream").and include("workspace push [--name")
      expect(rebase_command).not_to have_received(:call)
      expect(push_command).not_to have_received(:call)
    end

    it "says so when no command was wired" do
      cli, _, error_output, = build_test_cli

      expect { cli.run(["rebase", "--onto", "local"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["push"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("rebase is not available").and include("push is not available")
    end

    it "lists both in the main help" do
      cli.run(["help"])

      expect(output.string).to match(/^\s+rebase\s+Rebase a workspace/)
      expect(output.string).to match(/^\s+push\s+Push a workspace/)
    end
  end

  describe "#run with pr" do
    let(:pull_request_command) { instance_double(Workspace::Commands::PullRequest, create: nil) }
    let(:built) { build_test_cli(pull_request_command: pull_request_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "creates with the defaults" do
      cli.run(["pr", "create"])

      expect(pull_request_command).to have_received(:create).with(name: nil, draft: false, json: false, working_dir: an_instance_of(String))
    end

    it "passes --name, --draft and --json in any order" do
      cli.run(["pr", "create", "--json", "--draft", "--name", "api"])

      expect(pull_request_command).to have_received(:create).with(name: "api", draft: true, json: true, working_dir: an_instance_of(String))
    end

    it "prints a command's failure as the envelope under --json and on stderr without it" do
      allow(pull_request_command).to receive(:create).and_raise(Workspace::Error.new("no commits", code: "nothing_to_push", details: {"branch" => "x"}))

      expect { cli.run(["pr", "create", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "nothing_to_push", "details" => {"branch" => "x"})
      expect(error_output.string).to eq("")

      expect { cli.run(["pr", "create"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Error: no commits")
    end

    it "shows help" do
      cli.run(["pr", "--help"])

      expect(output.string).to include("workspace pr create").and include("--draft")
      expect(pull_request_command).not_to have_received(:create)
    end

    ["--help", "-h"].each do |flag|
      it "prints the page of pr create for #{flag} and creates nothing" do
        cli.run(["pr", "create", flag])

        expect(output.string).to start_with("Usage: workspace pr create")
        expect(pull_request_command).not_to have_received(:create)
      end
    end

    it "rejects a missing subcommand, an unknown one and extra arguments as usage errors" do
      [["pr"], ["pr", "bogus"], ["pr", "create", "extra"]].each do |argv|
        expect { cli.run(argv + ["--json"]) }.to raise_error(FakeSystemExit), argv.inspect
        expect(JSON.parse(output.string.lines.last)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
      expect(pull_request_command).not_to have_received(:create)
    end

    it "reads feedback with the defaults" do
      feedback = instance_double(Workspace::Commands::PrFeedback, call: nil)
      cli, = build_test_cli(pr_feedback_command: feedback)

      cli.run(["pr", "feedback"])

      expect(feedback).to have_received(:call).with(name: nil, all: false, json: false, working_dir: an_instance_of(String))
    end

    it "passes --name, --all and --json to feedback" do
      feedback = instance_double(Workspace::Commands::PrFeedback, call: nil)
      cli, = build_test_cli(pr_feedback_command: feedback)

      cli.run(["pr", "feedback", "--json", "--all", "--name", "api"])

      expect(feedback).to have_received(:call).with(name: "api", all: true, json: true, working_dir: an_instance_of(String))
    end

    it "rejects extra arguments to feedback and says so when it was not wired" do
      feedback = instance_double(Workspace::Commands::PrFeedback, call: nil)
      cli, output, = build_test_cli(pr_feedback_command: feedback)

      expect { cli.run(["pr", "feedback", "extra", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string.lines.last)).to include("code" => "usage")
      expect(feedback).not_to have_received(:call)

      cli, _, error_output, = build_test_cli
      expect { cli.run(["pr", "feedback"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("pr feedback is not available")
    end

    [
      ["no_pull_request", {"branch" => "x"}, nil],
      ["pr_feedback_failed", {"reason" => "timeout", "detail" => "slow"}, {"flags" => [], "destructive" => false}],
      ["gh_unavailable", {"reason" => "missing"}, nil]
    ].each do |code, details, retry_with|
      it "prints #{code} from pr feedback as the one JSON envelope on stdout" do
        feedback = instance_double(Workspace::Commands::PrFeedback)
        allow(feedback).to receive(:call).and_raise(Workspace::Error.new("failed", code: code, details: details, retry_with: retry_with))
        cli, output, error_output, = build_test_cli(pr_feedback_command: feedback)

        expect { cli.run(["pr", "feedback", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        document = JSON.parse(output.string)
        expect(document).to include("ok" => false, "code" => code, "details" => details)
        expect(document["retry"]).to eq(retry_with) if retry_with
        expect(document).not_to have_key("retry") unless retry_with
        expect(error_output.string).to eq("")
      end
    end

    it "refuses --all on pr create" do
      expect { cli.run(["pr", "create", "--all", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string.lines.last)).to include("code" => "usage")
      expect(pull_request_command).not_to have_received(:create)
    end

    it "says so when no pr command was wired" do
      cli, _, error_output, = build_test_cli

      expect { cli.run(["pr", "create"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("pr is not available")
    end

    it "lists pr in the main help" do
      cli.run(["help"])

      expect(output.string).to match(/^\s+pr\s+Open a pull request/)
    end
  end

  describe "#run with ui" do
    let(:ui_command) { CLITestHelpers::FakeUiCommand.new }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) { build_test_cli(ui_command: ui_command, project_detector: detector, working_dir: "/some/dir") }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "routes open with the workspace positional or by --name" do
      cli.run(["ui", "open", "task", "app"])
      cli.run(["ui", "open", "review", "--name", "other", "--print"])
      cli.run(["ui", "open", "inbox"])

      expect(ui_command.calls).to eq([
        {view: "task", workspace: "app", print_only: false},
        {view: "review", workspace: "other", print_only: true},
        {view: "inbox", workspace: nil, print_only: false}
      ])
    end

    context "with no view" do
      let(:known) { instance_double(Workspace::ProjectConfig) }
      let(:built) { build_test_cli(ui_command: ui_command, project_detector: detector, working_dir: "/some/dir", project_config: known) }

      before do
        allow(known).to receive(:existing_name) { |word| %w[my-app task].find { |name| name.casecmp?(word) } }
      end

      it "asks for a workspace outside a project" do
        allow(detector).to receive(:detect).and_return(nil)

        expect { cli.run(["ui", "open"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("task needs a workspace")
        expect(ui_command.calls).to be_empty
      end

      it "opens the task view of the detected project" do
        cli.run(["ui", "open"])

        expect(ui_command.calls).to eq([{view: "task", workspace: "detected-ws", print_only: false}])
      end

      it "opens the task view of --name" do
        cli.run(["ui", "open", "--name", "other"])

        expect(ui_command.calls).to eq([{view: "task", workspace: "other", print_only: false}])
      end

      it "takes a known workspace word as the workspace, in its on-disk spelling" do
        cli.run(["ui", "open", "my-app"])
        cli.run(["ui", "open", "My-App", "--print"])

        expect(ui_command.calls).to eq([
          {view: "task", workspace: "my-app", print_only: false},
          {view: "task", workspace: "my-app", print_only: true}
        ])
      end

      it "keeps a workspace named like a view reachable as `ui open task task`" do
        cli.run(["ui", "open", "task", "task"])

        expect(ui_command.calls).to eq([{view: "task", workspace: "task", print_only: false}])
      end

      it "refuses an unknown word and opens nothing" do
        expect { cli.run(["ui", "open", "nosuchthing", "--print"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to include("Unknown view or workspace 'nosuchthing'").and include("task, review, notes")
        expect(output.string).to eq("")
        expect(ui_command.calls).to eq([])
      end

      it "refuses a non-view word given with --name, known or not, and opens nothing" do
        [["ui", "open", "my-app", "--name", "other"], ["ui", "open", "nosuchthing", "--name", "other"]].each do |argv|
          expect { cli.run(argv) }.to raise_error(FakeSystemExit), argv.inspect
          expect(error_output.string).to include("is not a view, and --name already names the workspace")
        end
        expect(ui_command.calls).to eq([])
      end

      it "answers --print --json on the bare form" do
        cli.run(["ui", "open", "--print", "--json"])

        expect(ui_command.calls).to eq([{view: "task", workspace: "detected-ws", print_only: true}])
        expect(JSON.parse(output.string)["results"].first).to include("workspace" => "detected-ws", "view" => "task")
      end

      it "answers an unknown word as the usage envelope under --json" do
        expect { cli.run(["ui", "open", "nosuchthing", "--json"]) }.to raise_error(FakeSystemExit)

        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
        expect(ui_command.calls).to eq([])
      end
    end

    describe "ui status" do
      it "prints three lines and calls no open" do
        cli.run(["ui", "status"])

        expect(output.string.lines.size).to eq(3)
        expect(ui_command.calls).to eq([{status: true}])
      end

      it "prints one read document with --json before or after the verb" do
        [["ui", "status", "--json"], ["ui", "--json", "status"]].each do |argv|
          output.truncate(0)
          output.rewind
          cli.run(argv)

          doc = JSON.parse(output.string)
          expect(doc).to include("schema_version" => 1, "ok" => true, "running" => false, "probe" => nil, "warnings" => [])
          expect(doc["links"]).to eq("revision" => nil, "reason" => "no_handler")
          expect(doc).not_to have_key("results")
        end
      end

      it "exits 0 when the probe had no answer" do
        ui_command.status_doc = {"running" => nil, "pids" => nil, "handler" => nil,
                                 "links" => {"revision" => nil, "reason" => "probe_failed"}, "probe" => "timed_out", "warnings" => []}

        expect { cli.run(["ui", "status", "--json"]) }.not_to raise_error
        expect(JSON.parse(output.string)).to include("ok" => true, "probe" => "timed_out", "running" => nil)
      end

      it "refuses a positional, --name, --path and --print as a usage error, in the envelope under --json" do
        [%w[extra], %w[--name x], %w[--path a.md], %w[--print]].each do |extra|
          output.truncate(0)
          output.rewind
          expect { cli.run(["ui", "status", "--json"] + extra) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
          expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
        end
        expect(ui_command.calls).to eq([])
      end

      it "names open and status when the subcommand is missing" do
        expect { cli.run(["ui"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("Missing subcommand: open or status.")
      end
    end

    it "routes notes with a workspace, --name, or the detected workspace" do
      cli.run(["ui", "open", "notes", "app", "--print"])
      cli.run(["ui", "open", "notes", "--name", "other"])
      cli.run(["ui", "open", "notes"])

      expect(ui_command.calls).to eq([
        {view: "notes", workspace: "app", print_only: true},
        {view: "notes", workspace: "other", print_only: false},
        {view: "notes", workspace: "detected-ws", print_only: false}
      ])
    end

    it "passes plan like notes and the pane of `pane WS PANE`" do
      cli.run(["ui", "open", "plan", "app", "--print"])
      cli.run(["ui", "open", "pane", "app", "%19"])
      cli.run(["ui", "open", "pane", "--name=other", "%2"])
      cli.run(["ui", "open", "pane", "%3"])

      expect(ui_command.calls).to eq([
        {view: "plan", workspace: "app", print_only: true},
        {view: "pane", workspace: "app", print_only: false, pane: "%19"},
        {view: "pane", workspace: "other", print_only: false, pane: "%2"},
        {view: "pane", workspace: "detected-ws", print_only: false, pane: "%3"}
      ])
    end

    it "reports the pane in the --json row" do
      cli.run(["ui", "open", "pane", "app", "%19", "--json"])

      expect(JSON.parse(output.string)["results"].first).to include("workspace" => "app", "pane" => "%19", "view" => "task")
    end

    it "keeps the pane key off rows of other views" do
      cli.run(["ui", "open", "plan", "app", "--json"])

      expect(JSON.parse(output.string)["results"].first).not_to have_key("pane")
    end

    it "takes a lone argument as the pane and the workspace from the directory" do
      cli.run(["ui", "open", "pane", "%7"])

      expect(ui_command.calls).to eq([{view: "pane", workspace: "detected-ws", print_only: false, pane: "%7"}])
    end

    it "rejects a pane after --name plus a positional workspace" do
      expect { cli.run(["ui", "open", "pane", "--name", "x", "a", "%1"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unexpected argument")
      expect(ui_command.calls).to eq([])
    end

    it "rejects extra arguments after a pane" do
      expect { cli.run(["ui", "open", "pane", "a", "%1", "%2"]) }.to raise_error(FakeSystemExit)
      expect(ui_command.calls).to eq([])
    end

    it "uses the detected workspace for task and review but not inbox" do
      cli.run(["ui", "open", "review"])
      cli.run(["ui", "open", "inbox"])

      expect(detector).to have_received(:detect).with("/some/dir").once
      expect(ui_command.calls.map { |c| c[:workspace] }).to eq(["detected-ws", nil])
    end

    it "passes --path to the notes view and adds it to the json row" do
      cli.run(["ui", "open", "notes", "app", "--path", "research/a.md", "--print", "--json"])

      expect(ui_command.calls).to eq([{view: "notes", workspace: "app", print_only: true, path: "research/a.md"}])
      expect(JSON.parse(output.string)["results"].first).to include("path" => "research/a.md")
    end

    it "reports invalid_note_path in the --json error envelope and exits 1" do
      ui_command.error = Workspace::Error.new("Invalid note path: x.", code: "invalid_note_path",
        details: {"workspace" => "app", "path" => "x.md", "reason" => "no such file in the notes directory"})

      expect { cli.run(["ui", "open", "notes", "app", "--path", "x.md", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => false, "code" => "invalid_note_path")
      expect(doc["details"]).to eq("workspace" => "app", "path" => "x.md", "reason" => "no such file in the notes directory")
    end

    it "lists --path in the ui help" do
      cli.run(["ui", "--help"])
      expect(output.string).to include("--path REL")
    end

    it "prints an action document under --json, text on stderr" do
      cli.run(["ui", "open", "task", "app", "--json"])

      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => true, "action" => "ui open", "status" => "ok")
      expect(doc["results"]).to eq([{"workspace" => "app", "outcome" => "opened", "reason" => nil, "message" => nil, "view" => "task", "url" => "workspace-ui://task/app"}])
    end

    it "exits 1 with open's message on stderr when the link can't be opened" do
      ui_command.result = Workspace::Commands::Ui::Result.new("failed", "task", "workspace-ui://task/app", "open_failed", "no handler")

      expect { cli.run(["ui", "open", "task", "app"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(error_output.string).to include("Error: no handler")
    end

    it "reports a failed open as a failed action document under --json" do
      ui_command.result = Workspace::Commands::Ui::Result.new("failed", "inbox", "workspace-ui://inbox", "open_failed", "no handler")

      expect { cli.run(["ui", "open", "inbox", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("status" => "failed")
    end

    it "shows help" do
      cli.run(["ui", "--help"])

      expect(output.string).to include("workspace ui open").and include("workspace-ui://")
    end

    it "rejects a missing subcommand, missing view and extra arguments as usage errors" do
      [["ui"], ["ui", "bogus"], ["ui", "open", "task", "a", "b"]].each do |argv|
        expect { cli.run(argv) }.to raise_error(FakeSystemExit), argv.inspect
      end
      expect(ui_command.calls).to eq([])
    end

    it "names an unknown subcommand, and says how to give the missing workspace" do
      expect { cli.run(["ui", "bogus", "task"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unknown ui subcommand: bogus")
      expect(error_output.string).not_to include("Missing subcommand")
      error_output.truncate(0)
      output.rewind
      expect { cli.run(["ui"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing subcommand: open")
      error_output.truncate(0)
      output.rewind
      allow(detector).to receive(:detect).and_return(nil)
      expect { cli.run(["ui", "open", "task"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("task needs a workspace: name one, pass --name")
      expect(ui_command.calls).to eq([])
    end

    it "suggests `ui open` when a view comes first" do
      expect { cli.run(["ui", "task", "foo"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Did you mean: workspace ui open task foo?")
    end

    it "answers CLI-raised usage errors as the usage envelope under --json" do
      [["ui", "bogus", "--json"], ["ui", "--json"]].each do |argv|
        output.truncate(0)
        output.rewind
        output.rewind
        expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }, argv.inspect
        expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage"), argv.inspect
      end
      allow(detector).to receive(:detect).and_return(nil)
      output.truncate(0)
      output.rewind
      output.rewind
      expect { cli.run(["ui", "open", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "usage", "error" => a_string_including("task needs a workspace"))
      output.truncate(0)
      output.rewind
      output.rewind
      expect { cli.run(["ui", "open", "task", "--json"]) }.to raise_error(FakeSystemExit)
      expect(JSON.parse(output.string)).to include("code" => "usage", "error" => a_string_including("pass --name"))
    end

    it "answers a view the command rejects with the usage error envelope under --json" do
      ui_command.error = Workspace::UsageError.new("Unknown view 'x': one of task, review, inbox.")

      expect { cli.run(["ui", "open", "x", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("ok" => false, "code" => "usage")
    end

    it "lists ui in the main help" do
      cli.run(["--help"])

      expect(output.string).to match(/^\s+ui\s+Open a workspace-ui:\/\/ link/)
    end
  end

  describe "#run with projects group" do
    let(:groups_command) { CLITestHelpers::FakeGroupsCommand.new }
    let(:built) { build_test_cli(groups_command: groups_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }

    it "creates a group from a name with spaces" do
      cli.run(["projects", "group", "create", "My Shop", "--json"])

      expect(groups_command.calls).to eq([{create: "My Shop", json: true}])
    end

    it "adds a path to a group" do
      cli.run(["projects", "group", "add", "billing", "/src/api"])

      expect(groups_command.calls).to eq([{add: "billing", path: "/src/api", json: false}])
    end

    it "lists groups" do
      cli.run(["projects", "--json", "group", "list"])

      expect(groups_command.calls).to eq([{list: true, json: true}])
    end

    it "shows a group with its options" do
      cli.run(["projects", "group", "show", "billing", "--json", "--no-agents", "--no-git", "--timeout", "2"])

      expect(groups_command.calls).to eq([{show: "billing", json: true, agents: false, git: false, timeout: 2.0}])
    end

    it "shows a group with the defaults" do
      cli.run(["projects", "group", "show", "billing"])

      expect(groups_command.calls).to eq([{show: "billing", json: false, agents: true, git: true, timeout: nil}])
    end

    it "refuses a bad --timeout for group show" do
      expect { cli.run(["projects", "group", "show", "billing", "--timeout", "0"]) }.to raise_error(FakeSystemExit)
      expect(groups_command.calls).to be_empty
    end

    it "prints help without running anything" do
      cli.run(["projects", "group", "--help"])

      expect(output.string).to include("workspace projects group create NAME")
      expect(groups_command.calls).to be_empty
    end

    [[%w[add billing], /needs GROUP PATH/], [%w[show], /needs GROUP/], [%w[list extra], /Unexpected argument: extra/], [%w[remove], /Unknown projects group subcommand/]].each do |args, message|
      it "refuses projects group #{args.join(" ")}" do
        expect { cli.run(["projects", "group", *args]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(built[2].string).to match(message)
      end
    end
  end

  describe "#run with projects" do
    let(:projects_command) { CLITestHelpers::FakeProjectsCommand.new }
    let(:built) { build_test_cli(projects_command: projects_command) }
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "runs list for a bare `projects`" do
      cli.run(["projects"])

      expect(projects_command.calls).to eq([{running_only: false, json: false, git: false}])
    end

    it "runs list for `projects list`" do
      cli.run(["projects", "list"])

      expect(projects_command.calls).to eq([{running_only: false, json: false, git: false}])
    end

    it "passes --running and --json, with flags before or after the subcommand" do
      cli.run(["projects", "--json", "list", "--running"])

      expect(projects_command.calls).to eq([{running_only: true, json: true, git: false}])
    end

    it "runs list for `projects --json` with no subcommand" do
      cli.run(["projects", "--json"])

      expect(projects_command.calls).to eq([{running_only: false, json: true, git: false}])
    end

    it "runs show with no name for `projects show`" do
      cli.run(["projects", "show"])

      expect(projects_command.calls).to eq([{show: nil, json: false, agents: true, git: true, timeout: nil}])
    end

    it "passes the name and --json to show, with flags before or after" do
      cli.run(["projects", "show", "app", "--json"])
      cli.run(["projects", "--json", "show", "~/src/app"])

      expect(projects_command.calls).to eq([{show: "app", json: true, agents: true, git: true, timeout: nil}, {show: "~/src/app", json: true, agents: true, git: true, timeout: nil}])
    end

    it "passes --no-agents and --timeout to show" do
      cli.run(["projects", "show", "app", "--no-agents"])
      cli.run(["projects", "show", "--timeout", "0.5"])

      expect(projects_command.calls).to eq([
        {show: "app", json: false, agents: false, git: true, timeout: nil},
        {show: nil, json: false, agents: true, git: true, timeout: 0.5}
      ])
    end

    it "rejects a --timeout that is not positive" do
      expect { cli.run(["projects", "show", "--timeout", "0"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--timeout must be a finite number greater than 0")
      expect(projects_command.calls).to be_empty
    end

    it "rejects a non-numeric --timeout" do
      expect { cli.run(["projects", "show", "--timeout", "soon"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("invalid argument")
    end

    it "rejects an infinite --timeout" do
      expect { cli.run(["projects", "show", "--timeout", "1e400"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--timeout must be a finite number greater than 0")
      expect(projects_command.calls).to be_empty
    end

    it "rejects a NaN --timeout" do
      expect { cli.run(["projects", "show", "--timeout", "NaN"]) }.to raise_error(FakeSystemExit)
      expect(projects_command.calls).to be_empty
    end

    it "reports a bad --timeout as a JSON error with --json" do
      expect { cli.run(["projects", "show", "--json", "--timeout", "0"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "--timeout must be a finite number greater than 0.")
    end

    it "lists --no-agents, --no-git and --timeout in show's help" do
      cli.run(["projects", "show", "--help"])

      expect(output.string).to include("--no-agents", "--no-git", "--timeout SECONDS")
    end

    it "passes --no-git to show" do
      cli.run(["projects", "show", "app", "--no-git"])

      expect(projects_command.calls).to eq([{show: "app", json: false, agents: true, git: false, timeout: nil}])
    end

    it "passes --git to list" do
      cli.run(["projects", "list", "--git"])
      cli.run(["projects", "--git", "--json"])

      expect(projects_command.calls).to eq([{running_only: false, json: false, git: true}, {running_only: false, json: true, git: true}])
    end

    it "rejects an unknown option to list as a usage error and lists nothing" do
      expect { cli.run(["projects", "list", "--bogus"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("--bogus")
      expect(projects_command.calls).to be_empty
    end

    it "documents --git and --no-git in the projects help" do
      cli.run(["projects", "--help"])
      cli.run(["projects", "list", "--help"])

      expect(output.string).to include("--git", "--no-git")
    end

    it "prints show's own help for `projects show --help`" do
      cli.run(["projects", "show", "--help"])

      expect(output.string).to include("Usage: workspace projects show [NAME|PATH] [--json]")
      expect(projects_command.calls).to be_empty
    end

    it "runs members with no name for `projects members`" do
      cli.run(["projects", "members"])

      expect(projects_command.calls).to eq([{members: nil, path: false, all: false, json: false, timeout: nil}])
    end

    it "passes the name, --path, --all and --json to members, with flags before or after" do
      cli.run(["projects", "members", "app", "--path", "--all"])
      cli.run(["projects", "--json", "members", "~/src/app", "--all"])

      expect(projects_command.calls).to eq([
        {members: "app", path: true, all: true, json: false, timeout: nil},
        {members: "~/src/app", path: false, all: true, json: true, timeout: nil}
      ])
    end

    it "passes --timeout through to members --all" do
      cli.run(["projects", "members", "app", "--all", "--timeout", "0.5"])

      expect(projects_command.calls).to eq([{members: "app", path: false, all: true, json: false, timeout: 0.5}])
    end

    it "rejects a non-positive members --timeout" do
      expect { cli.run(["projects", "members", "--all", "--timeout", "0"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("--timeout must be a finite number greater than 0.")
      expect(projects_command.calls).to be_empty
    end

    it "rejects --path with --json" do
      expect { cli.run(["projects", "members", "--path", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "--path and --json cannot be used together.")
      expect(projects_command.calls).to be_empty
    end

    it "rejects a second members argument with a usage error" do
      expect { cli.run(["projects", "members", "a", "b"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unexpected argument: b")
    end

    it "prints a JSON error for a bad members usage under --json, whatever the flag order" do
      expect { cli.run(["projects", "members", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /bogus/)
    end

    it "exits with members' exit code when it is non-zero" do
      projects_command.result = {exit_code: 1}

      expect { cli.run(["projects", "members", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "prints members' own help for `projects members --help`" do
      cli.run(["projects", "members", "--help"])

      expect(output.string).to include("Usage: workspace projects members [NAME|PATH] [--path] [--all] [--timeout SECONDS] [--json]", "--path", "--all", "not with --json")
      expect(projects_command.calls).to be_empty
    end

    it "mentions members in the projects help" do
      cli.run(["projects", "--help"])

      expect(output.string).to include("members [NAME|PATH]", "--path", "--all")
    end

    it "reports an error for `projects members` when no projects command was wired" do
      cli, _, error_output = build_test_cli(projects_command: nil)

      expect { cli.run(["projects", "members"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no projects command was wired")
    end

    describe "projects stop" do
      let(:actions_command) { CLITestHelpers::FakeProjectActionsCommand.new }
      let(:built) { build_test_cli(projects_command: projects_command, project_actions_command: actions_command) }

      it "runs stop with no name by default" do
        cli.run(["projects", "stop"])

        expect(actions_command.calls).to eq([{stop: nil, dry_run: false, json: false}])
        expect(projects_command.calls).to be_empty
      end

      it "passes the name, --dry-run and --json, with flags before or after" do
        cli.run(["projects", "stop", "app", "--dry-run"])
        cli.run(["projects", "--json", "stop", "~/src/app"])

        expect(actions_command.calls).to eq([
          {stop: "app", dry_run: true, json: false},
          {stop: "~/src/app", dry_run: false, json: true}
        ])
      end

      it "exits with the command's exit code when it is non-zero" do
        actions_command.result = {exit_code: 3}

        expect { cli.run(["projects", "stop"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(3) }
      end

      it "rejects a second argument with a usage error" do
        expect { cli.run(["projects", "stop", "a", "b"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("Unexpected argument: b")
        expect(actions_command.calls).to be_empty
      end

      it "prints a JSON usage error under --json, whatever the flag order" do
        expect { cli.run(["projects", "stop", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /bogus/)
      end

      it "prints stop's own help for `projects stop --help`" do
        cli.run(["projects", "stop", "--help"])

        expect(output.string).to include("Usage: workspace projects stop [NAME|PATH] [--dry-run] [--json]", "--dry-run", "Exit status")
        expect(actions_command.calls).to be_empty
      end

      it "lists stop under Actions in the projects help" do
        cli.run(["projects", "--help"])

        expect(output.string).to include("Actions:", "stop [NAME|PATH]", "--dry-run")
      end

      it "reports an error when no project actions command was wired" do
        cli, _, error_output = build_test_cli(project_actions_command: nil)

        expect { cli.run(["projects", "stop"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("no project actions command was wired")
      end
    end

    describe "projects kill" do
      let(:actions_command) { CLITestHelpers::FakeProjectActionsCommand.new }
      let(:tty_input) do
        Class.new(StringIO) { def tty? = true }.new("")
      end
      let(:built) { build_test_cli(projects_command: projects_command, project_actions_command: actions_command, input: tty_input) }

      def kill_call(name, **given)
        {kill: name, dry_run: false, yes: false, force: false, discard_unsaved: false, json: false, git_timeout: 5.0}.merge(given)
      end

      it "passes the name and every flag, with flags before or after" do
        cli.run(["projects", "kill", "app"])
        cli.run(["projects", "kill", "app", "--force", "--discard-unsaved", "--dry-run"])
        cli.run(["projects", "--json", "--yes", "kill", "~/src/app"])

        expect(actions_command.calls).to eq([
          kill_call("app"),
          kill_call("app", force: true, discard_unsaved: true, dry_run: true),
          kill_call("~/src/app", yes: true, json: true)
        ])
      end

      it "requires NAME" do
        expect { cli.run(["projects", "kill", "--yes"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to include("projects kill needs a project NAME or PATH")
        expect(actions_command.calls).to be_empty
      end

      it "prints the JSON error contract for a missing NAME under --json" do
        expect { cli.run(["projects", "kill", "--yes", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage",
          "error" => "projects kill needs a project NAME or PATH. Run 'workspace projects kill --help'.")
        expect(actions_command.calls).to be_empty
      end

      it "parses --timeout as a duration" do
        cli.run(["projects", "kill", "app", "--timeout", "30s"])
        cli.run(["projects", "kill", "app", "--timeout", "2"])

        expect(actions_command.calls.map { |c| c[:git_timeout] }).to eq([30.0, 2.0])
      end

      it "rejects a --timeout that isn't a positive duration" do
        expect { cli.run(["projects", "kill", "app", "--timeout", "0"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect { cli.run(["projects", "kill", "app", "--timeout", "soon", "--json"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("--timeout: must be greater than 0")
        expect(JSON.parse(output.string)["error"]).to start_with("--timeout: expected a duration")
        expect(actions_command.calls).to be_empty
      end

      it "documents --timeout in its help" do
        cli.run(["projects", "kill", "--help"])

        expect(output.string).to include("--timeout DURATION", "default 5s")
      end

      [%w[--help], %w[-h], %w[--yes --help], %w[app --yes -h]].each do |argv|
        it "prints its page and removes nothing for 'projects kill #{argv.join(" ")}'" do
          cli.run(["projects", "kill", *argv])

          expect(output.string).to start_with("Usage: workspace projects kill")
          expect(actions_command.calls).to be_empty
        end
      end

      it "rejects an unknown option as a usage error and removes nothing" do
        expect { cli.run(["projects", "kill", "app", "--bogus"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to include("--bogus")
        expect(actions_command.calls).to be_empty
      end

      it "rejects a second argument" do
        expect { cli.run(["projects", "kill", "a", "b"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("Unexpected argument: b")
      end

      it "makes --json without --yes a JSON usage error" do
        expect { cli.run(["projects", "kill", "app", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "projects kill --json never prompts: pass --yes to remove, or --dry-run to preview.")
        expect(actions_command.calls).to be_empty
      end

      it "allows --json with --dry-run and no --yes" do
        cli.run(["projects", "kill", "app", "--json", "--dry-run"])

        expect(actions_command.calls).to eq([kill_call("app", json: true, dry_run: true)])
      end

      context "when stdin is not a terminal" do
        let(:built) { build_test_cli(projects_command: projects_command, project_actions_command: actions_command) }

        it "is a usage error without --yes" do
          expect { cli.run(["projects", "kill", "app"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

          expect(error_output.string).to include("pass --yes")
          expect(actions_command.calls).to be_empty
        end

        it "prints the JSON error contract under --json" do
          expect { cli.run(["projects", "kill", "app", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

          expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage",
            "error" => "projects kill --json never prompts: pass --yes to remove, or --dry-run to preview.")
          expect(error_output.string).to be_empty
        end

        it "runs with --yes or --dry-run" do
          cli.run(["projects", "kill", "app", "--yes"])
          cli.run(["projects", "kill", "app", "--dry-run"])

          expect(actions_command.calls.size).to eq(2)
        end
      end

      it "exits with the command's exit code when it is non-zero" do
        actions_command.result = {exit_code: 1}

        expect { cli.run(["projects", "kill", "app"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      end

      it "prints kill's own help for `projects kill --help`" do
        cli.run(["projects", "kill", "--help"])

        expect(output.string).to include("Usage: workspace projects kill NAME|PATH [--dry-run] [--yes] [--force] [--discard-unsaved] [--timeout DURATION] [--json]",
          "--discard-unsaved", "workspace dev down", "Exit status")
        expect(actions_command.calls).to be_empty
      end

      # The real Kill, ProjectConfig and Stop write their own progress lines;
      # under --json none of them may reach stdout.
      context "with the real Kill, ProjectConfig and Stop" do
        include FakeCheckouts

        around do |example|
          Dir.mktmpdir do |dir|
            @root = File.realpath(dir)
            example.run
          end
        end

        let(:own_session) { nil }
        let(:out) { StringIO.new }
        let(:err) { StringIO.new }
        let(:main) { make_main_checkout(File.join(@root, "app")) }
        let(:checkouts) do
          {"app" => main,
           "app.worktree-login" => make_linked_worktree(main, File.join(main, ".worktrees", "login")),
           "app.worktree-wip" => make_linked_worktree(main, File.join(main, ".worktrees", "wip"))}
        end
        let(:config_dir) { FileUtils.mkdir_p(File.join(@root, "tmuxinator")).first }
        let(:tmuxinator) do
          dir = config_dir
          Class.new do
            define_method(:tmuxinator_dir) { dir }
            define_method(:config_path_for) { |name| File.join(dir, "workspace.#{name}.yml") }
            define_method(:render_state_dir) { File.join(dir, ".render") }
          end.new
        end
        let(:removed_worktrees) { [] }
        let(:fake_git) do
          removed = removed_worktrees
          Class.new do
            define_method(:worktree_exists?) { |path| File.directory?(path) }
            define_method(:unsaved_work) { |_path| nil }
            define_method(:worktree_branch) { |path| File.basename(path) }
            define_method(:remove_worktree) { |path, force: false| removed << path }
            define_method(:sanitize_for_filesystem) { |name| name }
          end.new
        end
        let(:live_sessions) { %w[app app-worktree-login app-worktree-wip] }
        let(:fake_tmux) do
          live = live_sessions
          own = own_session
          Class.new do
            define_method(:sessions) { |strict: false| live.dup }
            define_method(:session_name_for) { |workspace| workspace.tr(".", "-") }
            define_method(:session_name_for_pane) { |_pane| own }
            define_method(:kill_session) { |name, project: nil, socket: nil| live.delete(name) }
            define_method(:custom_socket_option) { |_workspace| nil }
          end.new
        end
        let(:fake_state) do
          CLITestHelpers::FakeState.new.tap { |s| s["app.worktree-wip"] = {"iterm_window_id" => 1} }
        end
        let(:lock_namespace) do
          dir = File.join(@root, "locks")
          Class.new { define_method(:resolve) { |cwd:| {dir: dir} } }.new
        end
        let(:built) do
          checkouts.each { |name, path| File.write(tmuxinator.config_path_for(name), "root: #{path}\n") }
          project_config = Workspace::ProjectConfig.new(config: tmuxinator, git: fake_git, output: out)
          stop = Workspace::Commands::Stop.new(state: fake_state, iterm: CLITestHelpers::FakeITerm.new,
            window_manager: CLITestHelpers::FakeWindowManager.new, tmux: fake_tmux, output: out, error_output: err)
          kill = Workspace::Commands::Kill.new(git: fake_git, project_config: project_config, project_settings: CLITestHelpers::FakeProjectSettings.new,
            stop_command: stop, project_detector: nil, output: out, input: StringIO.new)
          catalog = Workspace::ProjectCatalog.new(project_config: project_config, git: Workspace::Git.new(output: StringIO.new, input: StringIO.new))
          actions = Workspace::Commands::ProjectActions.new(catalog: catalog, stop_command: stop, kill_command: kill, state: fake_state,
            tmux: fake_tmux, git: fake_git, lock_namespace: lock_namespace, lock_holder: FakeLockLiveness.new,
            hook_runner: CLITestHelpers::FakeHookRunner.new, output: out, error_output: err, input: StringIO.new, own_pane: own_session && "%7")
          build_test_cli(output: out, error_output: err, project_actions_command: actions, projects_command: projects_command)
        end

        def expect_single_json_document
          expect(output.string.lines.size).to eq(1), "stdout was:\n#{output.string}"
          payload = JSON.parse(output.string)
          expect(payload["summary"]).to include("removed" => 2, "kept" => 1)
          expect(removed_worktrees.size).to eq(2)
          expect(Dir.glob(File.join(config_dir, "*.yml")).map { |f| File.basename(f) }).to eq(["workspace.app.yml"])
          payload
        end

        it "writes exactly one JSON document to stdout" do
          cli.run(["projects", "kill", "app", "--yes", "--json"])

          expect(expect_single_json_document["status"]).to eq("ok")
          expect(live_sessions).to eq(%w[app app-worktree-login])
        end

        it "doesn't warn about members that weren't active" do
          cli.run(["projects", "kill", "app", "--yes", "--json"])

          expect(error_output.string).not_to include("not an active workspace project")
        end

        context "when run from inside one of the worktrees" do
          let(:own_session) { "app-worktree-login" }

          it "still writes exactly one JSON document, with its own worktree removed last" do
            cli.run(["projects", "kill", "app", "--yes", "--json"])

            payload = expect_single_json_document
            expect(payload["results"].last).to include("workspace" => "app.worktree-login", "outcome" => "removed")
            expect(removed_worktrees.last).to eq(checkouts["app.worktree-login"])
          end
        end
      end

      it "lists kill under Actions in the projects help" do
        cli.run(["projects", "--help"])

        expect(output.string).to include("kill NAME|PATH", "--discard-unsaved", "--yes", "--force")
      end
    end

    it "mentions show in the projects help" do
      cli.run(["projects", "--help"])

      expect(output.string).to include("show [NAME|PATH]")
    end

    it "rejects a second show argument with a usage error" do
      expect { cli.run(["projects", "show", "a", "b"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unexpected argument: b")
    end

    it "prints a JSON error for a bad show usage under --json, whatever the flag order" do
      expect { cli.run(["projects", "show", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => /bogus/)
    end

    it "exits with show's exit code when it is non-zero" do
      projects_command.result = {exit_code: 1}

      expect { cli.run(["projects", "show", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "prints the definition of a project for `projects --help`, `-h` and `help`" do
      [["--help"], ["-h"], ["help"]].each do |args|
        cli.run(["projects"] + args)
      end

      expect(output.string.scan("A project is a repository's main checkout plus its linked git worktrees.").size).to eq(3)
      expect(output.string).to include("`list-projects` operate on single workspaces")
      expect(projects_command.calls).to be_empty
    end

    it "prints the page of `projects list` for `projects list --help`" do
      cli.run(["projects", "list", "--help"])

      expect(output.string).to include("Usage: workspace projects list [--running] [--git] [--json]", "--running")
      expect(output.string).not_to include("Subcommands:")
      expect(projects_command.calls).to be_empty
    end

    it "prints the projects help for `projects help`" do
      cli.run(["projects", "help"])

      expect(output.string).to include("Usage: workspace projects", "--no-git")
      expect(projects_command.calls).to be_empty
    end

    it "reports an error for `projects show` when no projects command was wired" do
      cli, _, error_output = build_test_cli(projects_command: nil)

      expect { cli.run(["projects", "show"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no projects command was wired")
    end

    it "reports an error for `projects list --git` when no projects command was wired" do
      cli, _, error_output = build_test_cli(projects_command: nil)

      expect { cli.run(["projects", "list", "--git"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no projects command was wired")
    end

    it "reports an error when no projects command was wired" do
      cli, _, error_output = build_test_cli(projects_command: nil)

      expect { cli.run(["projects"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("no projects command was wired")
    end

    it "exits with the command's exit code when it is non-zero" do
      projects_command.result = {exit_code: 1}

      expect { cli.run(["projects", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "lists projects in the main help" do
      cli.run(["help"])

      expect(output.string).to match(/^\s+projects\s+Group workspaces/)
    end

    it "does not touch list-projects" do
      state = CLITestHelpers::FakeState.new
      cli, output, = build_test_cli(state: state, projects_command: projects_command)

      cli.run(["list-projects", "--json"])

      expect(projects_command.calls).to be_empty
      expect(JSON.parse(output.string)).to be_an(Array)
    end

    context "usage errors" do
      it "rejects an unknown subcommand with a one-line pointer to help on stderr and exit 1" do
        expect { cli.run(["projects", "nope"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to eq("Unknown projects subcommand: nope. Run 'workspace projects --help'.\n")
      end

      it "rejects an unknown option with the parser message and exit 1" do
        expect { cli.run(["projects", "--bogus"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to include("invalid option: --bogus")
      end

      it "rejects extra arguments to list" do
        expect { cli.run(["projects", "list", "extra"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(error_output.string).to include("Unexpected argument: extra. Run 'workspace projects --help'.")
        expect(projects_command.calls).to be_empty
      end

      it "emits a single-line JSON error on stdout for an unknown subcommand when --json is given" do
        expect { cli.run(["projects", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "Unknown projects subcommand: nope. Run 'workspace projects --help'.")
        expect(error_output.string).to eq("")
      end

      it "emits the JSON error whatever the flag order, for an unknown option" do
        expect { cli.run(["projects", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => "invalid option: --bogus")
      end

      it "emits the JSON error for extra arguments" do
        expect { cli.run(["projects", "list", "extra", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        expect(JSON.parse(output.string)["error"]).to eq("Unexpected argument: extra. Run 'workspace projects --help'.")
      end
    end
  end

  describe "#run with wait-until-content" do
    it "exits 1 with a specific message when one positional is given but no project is detected from cwd" do
      cli, _, error_output = build_test_cli(working_dir: Dir.tmpdir)
      expect { cli.run(["wait-until-content", "myproject"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("no workspace project detected from the current directory")
      expect(error_output.string).to include("pass the project name explicitly")
      expect(error_output.string).to include("Usage: workspace wait-until-content")
    end

    it "exits 1 when no command is given (neither -- nor -e)" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["wait-until-content", "myproject", "READY"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("a command is required")
    end

    it "exits 1 when --lines is zero" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["wait-until-content", "myproject", "READY", "--lines", "0", "--", "irb"]) }
        .to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      expect(error_output.string).to include("--lines must be a positive integer")
    end

    it "exits 1 when --interval is zero" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["wait-until-content", "myproject", "READY", "--interval", "0", "--", "irb"]) }
        .to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      expect(error_output.string).to include("--interval must be a positive number")
    end

    it "exits 1 when --max-wait-time is negative" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["wait-until-content", "myproject", "READY", "--max-wait-time", "-1", "--", "irb"]) }
        .to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      expect(error_output.string).to include("--max-wait-time must be a positive number")
    end

    it "exits 1 when -e has invalid shell quoting" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["wait-until-content", "myproject", "READY", "-e", 'unbalanced "quote']) }
        .to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
      expect(error_output.string).to include("invalid shell quoting")
    end

    it "dispatches with project, content, and the command after -- as an argv array" do
      wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
      cli, _, _ = build_test_cli(wait_until_content_command: wait_command)
      cli.run(["wait-until-content", "myproject", "READY", "--", "irb", "--noreadline"])

      expect(wait_command.calls.size).to eq(1)
      call = wait_command.calls.first
      expect(call[:project]).to eq("myproject")
      expect(call[:content]).to eq("READY")
      expect(call[:exec_command]).to eq(["irb", "--noreadline"])
      expect(call[:pane]).to eq(:bottom)
      expect(call[:lines]).to eq(100)
      expect(call[:interval]).to eq(0.5)
      expect(call[:max_wait_time]).to be_nil
      expect(call[:since_start]).to eq(false)
    end

    it "dispatches with -e command as a shell string" do
      wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
      cli, _, _ = build_test_cli(wait_until_content_command: wait_command)
      cli.run(["wait-until-content", "myproject", "READY", "-e", "echo hi"])

      expect(wait_command.calls.first[:exec_command]).to eq("echo hi")
    end

    it "gives the command after -- precedence over -e" do
      wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
      cli, _, _ = build_test_cli(wait_until_content_command: wait_command)
      cli.run(["wait-until-content", "myproject", "READY", "-e", "echo hi", "--", "irb"])

      expect(wait_command.calls.first[:exec_command]).to eq(["irb"])
    end

    it "passes options through to the command" do
      wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
      cli, _, _ = build_test_cli(wait_until_content_command: wait_command)
      cli.run(["wait-until-content", "myproject", "READY", "--pane", "Claude Code",
        "--lines", "200", "--interval", "1.5", "--max-wait-time", "30",
        "--since-start", "--", "irb"])

      call = wait_command.calls.first
      expect(call[:pane]).to eq("Claude Code")
      expect(call[:lines]).to eq(200)
      expect(call[:interval]).to eq(1.5)
      expect(call[:max_wait_time]).to eq(30.0)
      expect(call[:since_start]).to eq(true)
    end

    it "auto-detects the project from cwd when only content is given" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".workspace-project"), "detected-project")

        wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
        cli, _, _ = build_test_cli(wait_until_content_command: wait_command, working_dir: dir)
        cli.run(["wait-until-content", "READY", "--", "irb"])

        call = wait_command.calls.first
        expect(call[:project]).to eq("detected-project")
        expect(call[:content]).to eq("READY")
      end
    end

    it "exits 1 when the command returns a failure status" do
      wait_command = CLITestHelpers::FakeWaitUntilContentCommand.new
      wait_command.next_status = 1
      cli, _, _ = build_test_cli(wait_until_content_command: wait_command)

      expect { cli.run(["wait-until-content", "myproject", "READY", "--", "irb"]) }
        .to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
    end

    it "shows wait-until-content in help output" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("wait-until-content")
    end
  end

  describe "#run with run-and-report" do
    it "exits 1 when no command given" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run-and-report"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace run-and-report")
    end

    it "delegates to run_and_report_command and prints JSON" do
      cmd = CLITestHelpers::FakeRunAndReportCommand.new
      cli, output, _ = build_test_cli(run_and_report_command: cmd)
      cli.run(["run-and-report", "echo hi"])

      expect(cmd.calls.size).to eq(1)
      expect(cmd.calls.first[:command]).to eq("echo hi")
      expect(output.string).to include('"uuid"')
      expect(output.string).to include('"status"')
    end

    it "exits with the command's exit code when non-zero" do
      cmd = CLITestHelpers::FakeRunAndReportCommand.new
      cmd.stub_result(Workspace::RunResult.new(
        uuid: "x", project: nil, command: "exit 2",
        status: 2, stdout: "", stderr: "oops\n",
        started_at: nil, finished_at: "2024-01-01T00:00:01Z"
      ))

      cli, _, _ = build_test_cli(run_and_report_command: cmd)
      expect { cli.run(["run-and-report", "exit 2"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(2)
      }
    end

    it "shows run-and-report in help output" do
      cli, output, _ = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("run-and-report")
    end
  end

  describe "#run with report-run-status" do
    let(:uuid) { "11111111-2222-3333-4444-555555555555" }

    it "writes the result JSON using the store" do
      store = CLITestHelpers::FakeRunResultStore.new
      cli, _, _ = build_test_cli(run_result_store: store)
      cli.run(["report-run-status", uuid, "0"])

      expect(store.written.size).to eq(1)
      expect(store.written.first.uuid).to eq(uuid)
      expect(store.written.first.status).to eq(0)
    end

    it "records a non-zero exit code correctly" do
      store = CLITestHelpers::FakeRunResultStore.new
      cli, _, _ = build_test_cli(run_result_store: store)
      cli.run(["report-run-status", uuid, "127"])

      expect(store.written.first.status).to eq(127)
    end

    it "exits 1 when too few arguments given" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["report-run-status", "only-uuid"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace report-run-status")
    end

    it "exits 1 with a usage error when the exit code is not an integer" do
      store = CLITestHelpers::FakeRunResultStore.new
      cli, _, error_output = build_test_cli(run_result_store: store)

      expect { cli.run(["report-run-status", uuid, "not-a-number"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("exit_code must be an integer")
      expect(store.written).to be_empty
    end

    it "exits 1 when the uuid is not a well-formed UUID" do
      store = CLITestHelpers::FakeRunResultStore.new
      cli, _, error_output = build_test_cli(run_result_store: store)

      expect { cli.run(["report-run-status", "../../etc/passwd", "0"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Invalid UUID format")
      expect(store.written).to be_empty
    end
  end

  describe "#run with event-log show" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:config) do
      Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
        allow(c).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
        allow(c).to receive(:state_file).and_return(File.join(tmpdir, "state.json"))
      end
    end
    let(:event_log) { Workspace::EventLog.new(config: config, error_output: StringIO.new) }
    let(:state) { Workspace::State.new(config: config, event_log: event_log) }

    after { FileUtils.remove_entry(tmpdir) }

    before do
      event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
      event_log.record(type: "dispatched", project: "proj1", data: {"work_item_ref" => "W-1", "summary" => "a\e[31mb"})
      event_log.record(type: "lock_wait_started", project: "proj2", data: {"lock" => "edit"})
    end

    it "prints one line per event, oldest first, with control characters blanked" do
      cli, output, _ = build_test_cli(state: state, config: config)
      cli.run(["event-log", "show"])

      lines = output.string.lines
      expect(lines.size).to eq(3)
      expect(lines[1]).to include("proj1  dispatched  work_item_ref=W-1  summary=a [31mb")
      expect(lines[1]).not_to include("\e")
    end

    it "filters by project, type and limit" do
      cli, output, _ = build_test_cli(state: state, config: config)
      cli.run(["event-log", "show", "--project", "proj1", "--type", "launched,dispatched", "--limit", "1"])

      expect(output.string.lines.size).to eq(1)
      expect(output.string).to include("dispatched")
    end

    it "emits only JSON on stdout with --json" do
      cli, output, _ = build_test_cli(state: state, config: config)
      cli.run(["event-log", "show", "--json", "--type", "lock_wait_started"])

      payload = JSON.parse(output.string)
      expect(payload["schema_version"]).to eq(1)
      expect(payload["events"].map { |e| e["type"] }).to eq(["lock_wait_started"])
    end

    it "warns on stderr about a --type no event has, listing the types the log has" do
      cli, output, error_output = build_test_cli(state: state, config: config)
      cli.run(["event-log", "show", "--json", "--type", "dispatched,lock_wiat_started"])

      expect(JSON.parse(output.string)["events"].map { |e| e["type"] }).to eq(["dispatched"])
      expect(error_output.string).to eq("Warning: no lock_wiat_started events in the event log " \
        "(types it has: dispatched, launched, lock_wait_started)\n")
    end

    it "does not warn when every --type has events" do
      cli, _, error_output = build_test_cli(state: state, config: config)
      cli.run(["event-log", "show", "--type", "launched"])

      expect(error_output.string).to be_empty
    end

    it "reports a bad option as JSON when --json is anywhere in the arguments" do
      cli, output, _ = build_test_cli(state: state, config: config)
      expect { cli.run(["event-log", "show", "--bogus", "--json"]) }.to raise_error(FakeSystemExit)

      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => a_string_including("--bogus"))
    end

    it "rejects a non-positive --limit" do
      cli, _, error_output = build_test_cli(state: state, config: config)
      expect { cli.run(["event-log", "show", "--limit", "0"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("--limit must be greater than 0")
    end
  end

  describe "headless launch" do
    let(:launch_command) { double("launch", call: {exit_code: 0, prompt_failures: {}}) }
    let(:start_command) { double("start", call: {exit_code: 0}) }

    it "passes headless: true to launch with --headless" do
      cli, = build_test_cli(launch_command: launch_command)

      cli.run(["launch", "--headless", "myproject"])

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {}, headless: true)
    end

    it "launches headless when the launch mode says so and no flag is given" do
      cli, = build_test_cli(launch_command: launch_command, launch_mode: CLITestHelpers.launch_mode(headless: true))

      cli.run(["launch", "myproject"])

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {}, headless: true)
    end

    it "lets --no-headless override the launch mode" do
      cli, = build_test_cli(launch_command: launch_command, launch_mode: CLITestHelpers.launch_mode(headless: true))

      cli.run(["launch", "myproject", "--no-headless"])

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {})
    end

    it "passes headless to start, with flags in any position" do
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--json", "PROJ-1", "--headless"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: nil, prompt_timeout: nil,
        base: nil, yes: false, json: true, headless: true)
    end

    it "emits the JSON usage error on stdout for a bad flag next to --headless" do
      output = StringIO.new
      cli, = build_test_cli(output: output, start_command: start_command)

      expect { cli.run(["start", "--headless", "--json", "--bogus", "PROJ-1"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(JSON.parse(output.string)).to include("schema_version" => 1, "error" => a_string_including("--bogus"))
    end

    it "passes --headless and --no-headless to doctor, and nil without a flag" do
      doctor = CLITestHelpers::FakeDoctor.new
      cli, = build_test_cli(doctor: doctor)

      cli.run(["doctor", "--headless"])
      expect(doctor.headless).to be true
      cli.run(["doctor", "--no-headless"])
      expect(doctor.headless).to be false
      cli.run(["doctor"])
      expect(doctor.headless).to be_nil
    end

    it "passes --fix to doctor, and false without the flag" do
      doctor = CLITestHelpers::FakeDoctor.new
      cli, = build_test_cli(doctor: doctor)

      cli.run(["doctor", "--fix"])
      expect(doctor.fix).to be true
      cli.run(["doctor"])
      expect(doctor.fix).to be false
    end

    it "relaunches headless projects headless and the rest in iTerm2" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"headless" => true}
      cli, = build_test_cli(state: state, launch_command: launch_command, stop_command: double("stop", call: [], warnings: []))

      cli.run(["relaunch", "--all"])

      expect(launch_command).to have_received(:call).with(["proj1"], reattach: false, prompts: {})
      expect(launch_command).to have_received(:call).with(["proj2"], reattach: false, prompts: {}, headless: true)
    end

    it "still relaunches headless projects when the windowed batch fails, and exits 1 overall" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"headless" => true}

      launch_command = ScriptedLaunchCommand.new do |_projects, **opts|
        opts[:headless] ? {exit_code: 0, prompt_failures: {}} : {exit_code: 1, prompt_failures: {"proj1" => "window never appeared"}}
      end

      cli, = build_test_cli(state: state, launch_command: launch_command, stop_command: double("stop", call: [], warnings: []))

      expect { cli.run(["relaunch", "--all"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }

      expect(launch_command.calls).to eq([
        [["proj1"], {reattach: false, prompts: {}}],
        [["proj2"], {reattach: false, prompts: {}, headless: true}]
      ])
    end

    it "labels headless projects in status" do
      state = CLITestHelpers::FakeState.new
      state["proj"] = {"headless" => true}
      cli, output, = build_test_cli(state: state)

      cli.run(["status"])

      expect(output.string).to include("proj  headless  [alive]")
    end
  end

  describe "#run with --no-input" do
    def guarded_input(**opts)
      Workspace::PromptInput.new(StringIO.new, **opts)
    end

    it "turns prompts off for the run and does not pass the flag to the subcommand" do
      input = guarded_input
      ask = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(input: input, ask_command: ask)

      cli.run(["ask", "list", "--no-input"])

      expect(input.no_input?).to be true
      expect(ask.calls).to contain_exactly(a_hash_including(action: :list))
    end

    it "accepts the flag ahead of the subcommand" do
      input = guarded_input
      cli, = build_test_cli(input: input)

      cli.run(["--no-input", "doctor"])
      expect(input.no_input?).to be true
    end

    it "leaves a --no-input after a bare -- alone" do
      input = guarded_input
      lock = CLITestHelpers::FakeLockCommand.new
      cli, = build_test_cli(input: input, lock_command: lock)

      cli.run(["lock", "status", "--", "--no-input"])

      expect(input.no_input?).to be false
      expect(lock.calls.first[:name]).to eq("--no-input")
    end

    it "reports a refused prompt as one envelope with the prompt and the answering flag" do
      cli, output, error_output = build_test_cli(input: guarded_input)

      expect { cli.run(["projects", "kill", "app", "--no-input", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      doc = JSON.parse(output.string)
      expect(doc).to include("schema_version" => 1, "ok" => false, "code" => "confirmation_required")
      expect(doc["details"]["prompt"]).to include("app")
      expect(doc["retry"]).to eq({"flags" => ["--yes"], "destructive" => true})
      expect(error_output.string).to eq("")
    end

    it "reports a refused prompt on stderr without --json" do
      cli, output, error_output = build_test_cli(input: guarded_input)

      expect { cli.run(["projects", "kill", "app", "--no-input"]) }.to raise_error(FakeSystemExit)
      expect(output.string).to eq("")
      expect(error_output.string).to include("Can't ask").and include("--no-input")
    end

    it "still lets --yes through" do
      actions = double("project_actions")
      allow(actions).to receive(:kill).and_return({exit_code: 0})
      cli, = build_test_cli(input: guarded_input, project_actions_command: actions)

      cli.run(["projects", "kill", "app", "--yes", "--no-input"])

      expect(actions).to have_received(:kill).with(a_hash_including(name: "app", yes: true))
    end
  end

  describe "#run with --name" do
    let(:roots) { {"api.worktree-x" => "/src/api-x"} }
    let(:project_config) { CLITestHelpers::FakeProjectConfig.new(roots) }

    it "points ask at the named workspace's root" do
      ask = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(project_config: project_config, ask_command: ask, working_dir: "/elsewhere")

      cli.run(["ask", "list", "--name", "api.worktree-x"])
      cli.run(["ask", "answer", "--name", "api.worktree-x", "a1", "ok"])
      cli.run(["ask", "--name", "api.worktree-x", "Q?", "--default", "d"])

      expect(ask.calls.map { |c| c[:working_dir] }).to all(eq("/src/api-x"))
      expect(ask.calls.map { |c| c[:action] }).to eq(%i[list answer call])
    end

    it "keeps cwd detection without --name" do
      ask = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(project_config: project_config, ask_command: ask, working_dir: "/elsewhere")

      cli.run(["ask", "list"])

      expect(ask.calls.first[:working_dir]).to eq("/elsewhere")
    end

    it "takes the workspace as a leading argument for every ask subcommand" do
      ask = CLITestHelpers::FakeAskCommand.new
      cli, = build_test_cli(project_config: project_config, ask_command: ask, working_dir: "/elsewhere")

      cli.run(["ask", "list", "api.worktree-x"])
      cli.run(["ask", "answer", "api.worktree-x", "a1", "ok"])
      cli.run(["ask", "resolve", "api.worktree-x", "a2", "--", "-y"])
      cli.run(["ask", "withdraw", "api.worktree-x", "a3"])
      cli.run(["ask", "api.worktree-x", "Q?", "--default", "d"])
      cli.run(["ask", "answer", "a4", "plain"])

      expect(ask.calls.map { |c| c[:working_dir] }).to eq(["/src/api-x"] * 5 + ["/elsewhere"])
      expect(ask.calls.map { |c| c[:id] || c[:question] }).to eq([nil, "a1", "a2", "a3", "Q?", "a4"])
      expect(ask.calls[2][:answer]).to eq("-y")
    end

    it "refuses an ask workspace argument no workspace has, and one given twice" do
      ask = CLITestHelpers::FakeAskCommand.new
      cli, _, error_output = build_test_cli(project_config: project_config, ask_command: ask, working_dir: "/elsewhere")

      expect { cli.run(["ask", "list", "ghost"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unknown workspace 'ghost'")
      expect { cli.run(["ask", "withdraw", "api.worktree-x", "a1", "--name", "api.worktree-x"]) }.to raise_error(FakeSystemExit)
      expect(ask.calls).to be_empty
    end

    it "takes the workspace as an argument for every dev subcommand, and keeps cwd without one" do
      dev = CLITestHelpers::FakeDevCommand.new
      configured = CLITestHelpers::FakeProjectConfig.new(roots)
      cli, = build_test_cli(project_config: configured, dev_command: dev, working_dir: "/elsewhere", lineage: CLITestHelpers::FakeLineage.new("project-a"))

      %w[up down status wait leave].each { |sub| cli.run(["dev", sub, "api.worktree-x"]) }
      cli.run(["dev", "up", "--wait", "api.worktree-x"])
      cli.run(["dev", "status"])

      expect(dev.working_dirs).to eq(["/src/api-x"] * 6 + ["/elsewhere"])
      expect(dev.calls.map { |c| c[:action] }).to eq(%i[up down status wait leave up status])
      expect(dev.calls[5]).to include(wait: true)
    end

    it "refuses a dev workspace argument no workspace has, and a second argument" do
      dev = CLITestHelpers::FakeDevCommand.new
      cli, _, error_output = build_test_cli(project_config: project_config, dev_command: dev, working_dir: "/elsewhere")

      expect { cli.run(["dev", "down", "ghost"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unknown workspace 'ghost'")
      expect { cli.run(["dev", "status", "api.worktree-x", "extra"]) }.to raise_error(FakeSystemExit)
      expect(dev.calls).to be_empty
    end

    it "takes the workspace as a leading argument for config get, set, unset and edit" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, = build_test_cli(project_config: project_config, config_command: config_command, working_dir: "/elsewhere", env: {})

      cli.run(["config", "get", "api.worktree-x", "dev.up"])
      cli.run(["config", "set", "api.worktree-x", "dev.up", "bin/dev"])
      cli.run(["config", "set", "api.worktree-x", "dev.up", "--", "-x"])
      cli.run(["config", "unset", "api.worktree-x", "dev.up"])
      cli.run(["config", "edit", "api.worktree-x"])
      cli.run(["config", "set", "dev.up", "bin/dev"])

      expect(config_command.calls.map { |c| c[:project] }).to eq(["api.worktree-x"] * 5 + [nil])
      expect(config_command.calls.map { |c| c[:key] }).to eq(["dev.up"] * 4 + [nil, "dev.up"])
      expect(config_command.calls[2][:value]).to eq("-x")
      expect(config_command.calls).to all(include(cwd: "/elsewhere"))
    end

    it "refuses a config workspace given both as an argument and with --name" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, = build_test_cli(project_config: project_config, config_command: config_command, working_dir: "/elsewhere", env: {})

      expect { cli.run(["config", "get", "api.worktree-x", "dev.up", "--name", "api.worktree-x"]) }.to raise_error(FakeSystemExit)
      expect { cli.run(["config", "edit", "api.worktree-x", "--name", "api.worktree-x"]) }.to raise_error(FakeSystemExit)
      expect(config_command.calls).to be_empty
    end

    it "fails config set and get with not_in_workspace outside any workspace, and still writes a global key" do
      config_dir = Dir.mktmpdir("ws-cli-config")
      loose = Dir.mktmpdir("ws-cli-loose")
      settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(config_dir))
      detector = Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config)
      raw = StringIO.new
      gate = Workspace::OutputGate.new(raw)
      command = Workspace::Commands::Config.new(project_settings: settings, lineage: LineageSupport.lineage, file_backup: Workspace::FileBackup.new(output: StringIO.new),
        project_config: project_config, project_detector: detector, output: gate, error_output: StringIO.new)
      cli, = build_test_cli(output: gate, project_config: project_config, project_detector: detector, config_command: command, working_dir: loose)

      expect { cli.run(["config", "set", "dev.up", "bin/dev", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(raw.string)).to include("ok" => false, "code" => "not_in_workspace", "details" => {"path" => loose})
      expect(Dir.glob(File.join(config_dir, "**", "*.yml"))).to be_empty

      raw.truncate(0)
      raw.rewind
      cli.run(["config", "set", "launch.headless", "true", "--json"])
      expect(JSON.parse(raw.string)).to include("ok" => true)
      expect(settings.load_global).to eq({"launch" => {"headless" => "true"}})
    ensure
      FileUtils.rm_rf([config_dir, loose].compact)
    end

    it "points every lock subcommand at the named workspace, apart from the lock name" do
      lock = CLITestHelpers::FakeLockCommand.new
      cli, = build_test_cli(project_config: project_config, lock_command: lock, working_dir: "/elsewhere")

      cli.run(["lock", "acquire", "edit", "--name", "api.worktree-x"])
      cli.run(["lock", "release", "edit", "--name", "api.worktree-x"])
      cli.run(["lock", "status", "edit", "--name", "api.worktree-x", "--json"])
      cli.run(["lock", "clear", "--all", "--name", "api.worktree-x"])

      expect(lock.working_dirs).to eq(["/src/api-x"] * 4)
      expect(lock.calls.map { |c| c[:name] }).to eq(["edit", "edit", "edit", nil])
    end

    it "points dev up, down and status at the named workspace" do
      dev = CLITestHelpers::FakeDevCommand.new
      cli, = build_test_cli(project_config: project_config, dev_command: dev, working_dir: "/elsewhere")

      cli.run(["dev", "up", "--name", "api.worktree-x"])
      cli.run(["dev", "down", "--name", "api.worktree-x"])
      cli.run(["dev", "status", "--name", "api.worktree-x", "--json"])

      expect(dev.working_dirs).to eq(["/src/api-x"] * 3)
    end

    it "fails with unknown_workspace for a name it doesn't know" do
      lock = CLITestHelpers::FakeLockCommand.new
      cli, output, = build_test_cli(project_config: project_config, lock_command: lock)

      expect { cli.run(["lock", "status", "--name", "nope", "--json"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      doc = JSON.parse(output.string)
      expect(doc).to include("ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"})
      expect(lock.calls).to be_empty
    end

    it "accepts --name as the same option as --project on config set, get and unset" do
      config = CLITestHelpers::FakeConfigCommand.new
      cli, = build_test_cli(config_command: config)

      cli.run(["config", "set", "--name", "api", "dev.up", "bin/dev"])
      cli.run(["config", "get", "--name", "api", "dev.up"])
      cli.run(["config", "unset", "--name", "api", "dev.up"])
      cli.run(["config", "set", "--project", "api", "dev.up", "bin/dev"])

      expect(config.calls.map { |c| c[:project] }).to eq(%w[api api api api])
    end
  end
  describe "action --json" do
    def action_cli(**overrides)
      raw = StringIO.new
      gate = Workspace::OutputGate.new(raw)
      error_output = StringIO.new
      overrides = overrides.merge(yield(gate)) if block_given?
      cli, = build_test_cli(output: gate, error_output: error_output, **overrides)
      [cli, raw, error_output]
    end

    # stdout must be exactly one JSON document.
    def parse_one(raw)
      expect(raw.string.lines.size).to eq(1), "stdout was: #{raw.string.inspect}"
      JSON.parse(raw.string)
    end

    def exit_status
      yield
      0
    rescue FakeSystemExit => e
      e.status
    end

    # The block action_cli yields the shared output gate to, so the fake launch prints through it.
    def launching(state, **options)
      ->(out) { {launch_command: launch_class.new(state: state, output: out, **options)} }
    end

    # A launch that behaves like Commands::Launch: prints progress, records state.
    let(:launch_class) do
      Class.new do
        attr_reader :calls

        def initialize(state:, output:, result: {}, fail: [])
          @state = state
          @output = output
          @result = result
          @fail = fail
          @calls = []
        end

        def call(projects, **options)
          @calls << [projects, options]
          @output.puts "Launching #{projects.join(", ")}..."
          projects.each do |p|
            next if @fail.include?(p)
            @state[p] = {"iterm_window_id" => 31337, "headless" => options[:headless] == true}
          end
          {exit_code: 0, prompt_failures: {}, reused: []}.merge(@result)
        end
      end
    end

    describe "plan start, pause and delete" do
      let(:plan_command) { instance_double(Workspace::Commands::Plan) }
      let(:plan_dispatch_command) { instance_double(Workspace::Commands::PlanDispatch) }
      let(:plan_task_command) { instance_double(Workspace::Commands::PlanTask) }
      let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
      let(:row) { {"outcome" => "paused", "reason" => nil, "message" => nil, "path" => "/n/IMPLEMENTATION_PLAN.md", "pane" => nil} }

      def plan_cli(**overrides, &block)
        action_cli(plan_command: plan_command, plan_dispatch_command: plan_dispatch_command, plan_task_command: plan_task_command, project_detector: detector, **overrides, &block)
      end

      describe "plan task" do
        let(:task_row) do
          row.merge("outcome" => "changed", "task" => "T3", "state" => "blocked", "previous_state" => "todo", "line" => 14, "phase" => "P",
            "revision" => "4e1f0c2a", "counts" => {"total" => 3}, "percent" => 33)
        end

        it "sends set-state's flags in --flag=value form and prints the result's task fields in the action document" do
          allow(plan_task_command).to receive(:set_state).and_return(task_row)
          cli, raw, = plan_cli

          cli.run(["plan", "task", "set-state", "--name=api", "--task=T3", "--state=blocked", "--reason=needs db", "--if-revision=9f8e7d6c", "--json"])

          expect(plan_task_command).to have_received(:set_state).with(name: "api", id: "T3", state: "blocked", reason: "needs db", if_revision: "9f8e7d6c")
          expect(parse_one(raw)).to include("action" => "plan task set-state", "status" => "ok",
            "results" => [a_hash_including("workspace" => "api", "outcome" => "changed", "task" => "T3", "state" => "blocked", "previous_state" => "todo",
              "revision" => "4e1f0c2a", "line" => 14, "counts" => {"total" => 3})])
        end

        it "sends set-title's flags and prints the title in the action document" do
          allow(plan_task_command).to receive(:set_title).and_return(task_row.merge("title" => "New"))
          cli, raw, = plan_cli

          cli.run(["plan", "task", "set-title", "--name=api", "--task=T3", "--title=New", "--if-revision=9f8e7d6c", "--json"])

          expect(plan_task_command).to have_received(:set_title).with(name: "api", id: "T3", title: "New", if_revision: "9f8e7d6c")
          expect(parse_one(raw)).to include("action" => "plan task set-title", "status" => "ok",
            "results" => [a_hash_including("task" => "T3", "title" => "New")])
        end

        it "sends add's flags, with state todo by default and the workspace of the directory" do
          allow(plan_task_command).to receive(:add).and_return(task_row.merge("outcome" => "added"))
          cli, = plan_cli

          cli.run(["plan", "task", "add", "--title", "Write docs", "--phase", "Docs"])
          cli.run(["plan", "task", "add", "--title=More", "--id=X1", "--state=skipped", "--reason=no", "--after=T1"])

          expect(plan_task_command).to have_received(:add).with(name: "detected-ws", title: "Write docs", id: nil, state: "todo", reason: nil, phase: "Docs", after: nil, if_revision: nil)
          expect(plan_task_command).to have_received(:add).with(name: "detected-ws", title: "More", id: "X1", state: "skipped", reason: "no", phase: nil, after: "T1", if_revision: nil)
        end

        it "sends move's place" do
          allow(plan_task_command).to receive(:move).and_return(task_row.merge("outcome" => "moved"))
          cli, = plan_cli

          cli.run(["plan", "task", "move", "--task=T3", "--before=T1"])
          cli.run(["plan", "task", "move", "--task", "T3", "--phase", "Docs"])

          expect(plan_task_command).to have_received(:move).with(name: "detected-ws", id: "T3", after: nil, before: "T1", phase: nil, if_revision: nil)
          expect(plan_task_command).to have_received(:move).with(name: "detected-ws", id: "T3", after: nil, before: nil, phase: "Docs", if_revision: nil)
        end

        it "prints a refusal as the json error envelope with its code and details" do
          allow(plan_task_command).to receive(:set_state).and_raise(Workspace::Error.new("changed", code: "stale_revision", details: {"revision" => "abc12345"}))
          cli, raw, = plan_cli

          expect(exit_status { cli.run(["plan", "task", "set-state", "--task=T3", "--state=done", "--json"]) }).to eq(1)

          expect(parse_one(raw)).to include("ok" => false, "code" => "stale_revision", "details" => a_hash_including("revision" => "abc12345"))
        end

        it "is a usage error without a verb, with an unknown verb or state, with a flag the verb does not take, or without what it needs" do
          cli, _, err = plan_cli
          [
            %w[plan task],
            %w[plan task nope],
            %w[plan task add],
            %w[plan task add --title=x --phase=P --after=T1],
            %w[plan task add --title=x --state=bogus],
            %w[plan task add --title=x --task=T1],
            %w[plan task set-state --task=T1],
            %w[plan task set-state --state=done],
            %w[plan task set-title --task=T1],
            %w[plan task set-title --title=x],
            %w[plan task set-title --task=T1 --title=x --state=done],
            %w[plan task move --task=T1],
            %w[plan task move --task=T1 --after=T2 --before=T3],
            %w[plan task move --task=T1 --after=T2 --state=done],
            %w[plan status --state=done]
          ].each do |argv|
            expect(exit_status { cli.run(argv) }).not_to eq(0), "expected #{argv.join(" ")} to be refused"
          end
          expect(err.string).to include("Missing task verb")
        end
      end

      it "prints pause as an action document with the row's path and pane" do
        allow(plan_command).to receive(:pause).with(name: "api", interrupt: false).and_return(row)
        cli, raw, = plan_cli

        cli.run(["plan", "pause", "--name", "api", "--json"])

        expect(parse_one(raw)).to include("action" => "plan pause", "status" => "ok",
          "results" => [{"workspace" => "api", "outcome" => "paused", "reason" => nil, "message" => nil, "path" => "/n/IMPLEMENTATION_PLAN.md", "pane" => nil}])
      end

      it "reports unchanged as ok, and pauses the workspace detected from the working directory" do
        allow(plan_command).to receive(:pause).and_return(row.merge("outcome" => "unchanged"))
        cli, raw, = plan_cli

        cli.run(["plan", "pause", "--json"])

        expect(plan_command).to have_received(:pause).with(name: "detected-ws", interrupt: false)
        expect(parse_one(raw)).to include("status" => "ok")
      end

      it "passes --yes to delete, and nothing without it" do
        allow(plan_command).to receive(:delete).and_return(row.merge("outcome" => "deleted", "message" => "Renamed to /n/x."))
        cli, raw, = plan_cli

        cli.run(["plan", "delete", "--name", "api", "--yes", "--json"])
        cli.run(["plan", "delete", "--name", "api"])

        expect(plan_command).to have_received(:delete).with(name: "api", yes: true)
        expect(plan_command).to have_received(:delete).with(name: "api", yes: false)
        expect(raw.string.lines.first).to include("\"action\":\"plan delete\"", "\"outcome\":\"deleted\"")
      end

      it "prints delete's refusal as an envelope with confirmation_required" do
        allow(plan_command).to receive(:delete).and_raise(Workspace::Error.new("needs --yes", code: "confirmation_required", details: {"name" => "api"}))
        cli, raw, = plan_cli

        expect(exit_status { cli.run(["plan", "delete", "--name", "api", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "confirmation_required")
      end

      it "prints start's refusals as envelopes" do
        allow(plan_dispatch_command).to receive(:start).and_raise(Workspace::Error.new("done", code: "plan_done", details: {"name" => "api"}))
        cli, raw, = plan_cli

        expect(exit_status { cli.run(["plan", "start", "--name", "api", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "plan_done")
      end

      it "prints a sent start as an action document with the pane" do
        allow(plan_dispatch_command).to receive(:start).and_return(row.merge("outcome" => "sent", "pane" => "%19"))
        cli, raw, = plan_cli

        cli.run(["plan", "start", "--name", "api", "--json"])

        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "sent", "reason" => nil, "message" => nil, "path" => "/n/IMPLEMENTATION_PLAN.md", "pane" => "%19"}])
      end

      it "exits 1 with a failed row when the launch could not send its prompt, and says why on stderr without --json" do
        allow(plan_dispatch_command).to receive(:start).and_return(row.merge("outcome" => "failed", "reason" => "prompt_not_sent", "message" => "agent never ready"))
        cli, raw, = plan_cli

        expect(exit_status { cli.run(["plan", "start", "--name", "api", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("status" => "failed")
        expect(parse_one(raw)["results"].first).to include("outcome" => "failed", "reason" => "prompt_not_sent")

        cli, raw, err = plan_cli
        expect(exit_status { cli.run(["plan", "start", "--name", "api"]) }).to eq(1)
        expect(err.string).to include("Error: could not start the plan for api: agent never ready")
        expect(raw.string).to eq("")
      end

      it "gives start a launcher that launches with the implementation-plan play and the continue line, and reports the bound pane" do
        launched = nil
        allow(plan_dispatch_command).to receive(:start) do |name:, launch:|
          launched = launch.call(name)
          row.merge("outcome" => "launched", "pane" => launched[:pane])
        end
        state = CLITestHelpers::FakeState.new
        project_config = CLITestHelpers::FakeProjectConfig.new("api" => "/work/api")
        library = Workspace::Library.new(
          config: instance_double(Workspace::Config, library_dir: Dir.mktmpdir, builtin_library_dir: File.join(PROJECT_ROOT, "lib", "library")),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api")), project_config: project_config
        )
        launch = nil
        cli, = plan_cli(state: state, project_config: project_config, library: library) do |out|
          launch = launch_class.new(state: state, output: out, result: {bound_panes: {"api" => "%5"}})
          {launch_command: launch}
        end

        cli.run(["plan", "start", "--name", "api"])

        play = File.join(PROJECT_ROOT, "lib", "library", "play", "implementation-plan.md")
        expect(launched).to eq(ok: true, reason: nil, message: nil, pane: "%5")
        expect(launch.calls.size).to eq(1)
        projects, options = launch.calls.first
        expect(projects).to eq(["api"])
        expect(options[:prompts]).to eq("api" => "Read \"#{play}\" and follow it.\n\nContinue the plan.")
        expect(options[:bindings]).to eq("api" => {"kind" => "play", "id" => "play/implementation-plan", "instructions" => play, "plays" => [{"id" => "play/implementation-plan", "instructions" => play}]})
      end

      it "gives the promote and spine launchers a single play name, or none, as a list of plays" do
        state = CLITestHelpers::FakeState.new
        project_config = CLITestHelpers::FakeProjectConfig.new("api" => "/work/api")
        library = Workspace::Library.new(
          config: instance_double(Workspace::Config, library_dir: Dir.mktmpdir, builtin_library_dir: File.join(PROJECT_ROOT, "lib", "library")),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api")), project_config: project_config
        )
        library.global_store.write("play", "kickoff", "# Kickoff\n")
        path = library.global_store.path_for("play", "kickoff")
        launch = nil
        promote = nil
        spine = nil
        promote_command = instance_double(Workspace::Commands::Promote)
        spine_start_command = instance_double(Workspace::Commands::SpineStart)
        allow(promote_command).to receive(:call) { |launch:, **|
          promote = launch
          {exit_code: 0}
        }
        allow(spine_start_command).to receive(:start) { |launch:, **|
          spine = launch
          {"ok" => true, "path" => "1-a"}
        }
        cli, = plan_cli(state: state, project_config: project_config, library: library, promote_command: promote_command, spine_start_command: spine_start_command) do |out|
          launch = launch_class.new(state: state, output: out)
          {launch_command: launch}
        end
        cli.run(["promote", "--launch"])
        cli.run(["spine", "start", "--name", "api", "1-a"])

        promote.call("api", prompt: "Go.", play: nil)
        promote.call("api", prompt: "Go.", play: "kickoff")
        spine.call("api", nil, "Brief.")
        spine.call("api", "kickoff", "Brief.")

        prompts = launch.calls.map { |_, options| options[:prompts]["api"] }
        expect(prompts.map { |text| text.include?("Read \"#{path}\"") }).to eq([false, true, false, true])
        expect(launch.calls.map { |_, options| options[:bindings]&.dig("api", "plays") })
          .to eq([nil, [{"id" => "play/kickoff", "instructions" => path}], nil, [{"id" => "play/kickoff", "instructions" => path}]])
      end

      it "gives start a launcher that reports a launch that never sent its prompt" do
        launched = nil
        allow(plan_dispatch_command).to receive(:start) do |name:, launch:|
          launched = launch.call(name)
          row
        end
        state = CLITestHelpers::FakeState.new
        project_config = CLITestHelpers::FakeProjectConfig.new("api" => "/work/api")
        library = Workspace::Library.new(
          config: instance_double(Workspace::Config, library_dir: Dir.mktmpdir, builtin_library_dir: File.join(PROJECT_ROOT, "lib", "library")),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api")), project_config: project_config
        )
        cli, = plan_cli(state: state, project_config: project_config, library: library, &launching(state, result: {exit_code: 1, prompt_failures: {"api" => "never ready"}}))

        cli.run(["plan", "start", "--name", "api"])

        expect(launched).to include(ok: false, reason: "prompt_not_sent", message: "never ready", pane: nil)
      end

      it "gives start the delivered pane when the play could not be bound to it" do
        launched = nil
        allow(plan_dispatch_command).to receive(:start) do |name:, launch:|
          launched = launch.call(name)
          row
        end
        state = CLITestHelpers::FakeState.new
        project_config = CLITestHelpers::FakeProjectConfig.new("api" => "/work/api")
        library = Workspace::Library.new(
          config: instance_double(Workspace::Config, library_dir: Dir.mktmpdir, builtin_library_dir: File.join(PROJECT_ROOT, "lib", "library")),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api")), project_config: project_config
        )
        cli, = plan_cli(state: state, project_config: project_config, library: library, &launching(state, result: {exit_code: 0, prompt_failures: {}, delivered_panes: {"api" => "%7"}}))

        cli.run(["plan", "start", "--name", "api"])

        expect(launched).to include(ok: true, pane: "%7")
      end

      it "sends --task, --pane and --spawn to start_task in the --flag=value form, and reports the task in the result" do
        allow(plan_dispatch_command).to receive(:start_task).and_return(row.merge("outcome" => "spawned", "pane" => "%23", "task" => "T5"))
        cli, raw, = plan_cli

        cli.run(["plan", "start", "--name=api", "--task=T5", "--spawn=codex", "--json"])
        cli.run(["plan", "start", "--name", "api", "--task", "T6", "--pane", "%4"])

        expect(plan_dispatch_command).to have_received(:start_task).with(name: "api", task_id: "T5", pane: nil, spawn: "codex", launch: kind_of(Proc))
        expect(plan_dispatch_command).to have_received(:start_task).with(name: "api", task_id: "T6", pane: "%4", spawn: nil, launch: kind_of(Proc))
        expect(parse_one(raw)).to include("action" => "plan start", "status" => "ok",
          "results" => [a_hash_including("workspace" => "api", "outcome" => "spawned", "pane" => "%23", "task" => "T5")])
      end

      it "gives start_task a launcher that sends the task's line instead of the continue line" do
        allow(plan_dispatch_command).to receive(:start_task) do |name:, task_id:, launch:, **|
          launch.call(name, Workspace::Commands::PlanDispatch.task_prompt(task_id))
          row.merge("outcome" => "launched", "task" => task_id)
        end
        state = CLITestHelpers::FakeState.new
        project_config = CLITestHelpers::FakeProjectConfig.new("api" => "/work/api")
        library = Workspace::Library.new(
          config: instance_double(Workspace::Config, library_dir: Dir.mktmpdir, builtin_library_dir: File.join(PROJECT_ROOT, "lib", "library")),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "api")), project_config: project_config
        )
        launch = nil
        cli, = plan_cli(state: state, project_config: project_config, library: library) do |out|
          launch = launch_class.new(state: state, output: out, result: {bound_panes: {"api" => "%5"}})
          {launch_command: launch}
        end

        cli.run(["plan", "start", "--name", "api", "--task", "T3"])

        prompt = launch.calls.first.last[:prompts]["api"]
        expect(prompt).to end_with("Work on plan task T3 only. Do not take other tasks; end your turn when it is done or blocked.")
      end

      it "refuses --pane with --spawn, either without --task, and an unknown --spawn kind" do
        cli, raw, = plan_cli

        [%w[start --task T1 --pane %1 --spawn claude], %w[start --pane %1], %w[start --spawn claude], %w[start --task T1 --spawn vim],
          %w[pause --task T1], %w[start --interrupt]].each do |argv|
          expect(exit_status { cli.run(["plan", *argv, "--json"]) }).to eq(1), argv.inspect
        end
        expect(raw.string.lines.map { |l| JSON.parse(l)["code"] }).to all(eq("usage"))
      end

      it "passes --interrupt to pause and puts the interrupts in the result and the warnings in the document" do
        interrupts = [{"pane" => "%19", "kind" => "claude", "outcome" => "sent", "message" => nil}]
        allow(plan_command).to receive(:pause).and_return(row.merge("interrupts" => interrupts, "warnings" => [{"code" => "no_daemon", "message" => "x"}]))
        cli, raw, = plan_cli

        cli.run(["plan", "pause", "--name", "api", "--interrupt", "--json"])

        expect(plan_command).to have_received(:pause).with(name: "api", interrupt: true)
        expect(parse_one(raw)).to include("status" => "ok", "warnings" => [{"code" => "no_daemon", "message" => "x"}],
          "results" => [a_hash_including("outcome" => "paused", "interrupts" => interrupts)])
      end

      it "rejects --yes on start and pause, and --all on delete" do
        cli, raw, = plan_cli

        [%w[start --yes], %w[pause --yes], %w[delete --all]].each do |argv|
          expect(exit_status { cli.run(["plan", *argv, "--json"]) }).to eq(1), argv.inspect
        end
        expect(raw.string.lines.map { |l| JSON.parse(l)["code"] }).to all(eq("usage"))
      end

      it "describes the new subcommands in plan --help" do
        cli, raw, = plan_cli

        cli.run(["plan", "--help"])

        expect(raw.string).to include("workspace plan start", "workspace plan pause", "workspace plan delete", "--yes")
      end
    end

    describe "stop" do
      it "prints one action document and sends the text to stderr" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {"iterm_window_id" => 1}
        hooks = CLITestHelpers::FakeHookRunner.new
        cli, raw, err = action_cli(state: state, hook_runner: hooks)

        cli.run(["stop", "api", "--json"])

        doc = parse_one(raw)
        expect(doc).to include("schema_version" => 1, "ok" => true, "action" => "stop", "status" => "ok", "summary" => {"stopped" => 1})
        expect(doc["results"]).to eq([{"workspace" => "api", "outcome" => "stopped", "reason" => nil, "message" => nil}])
        expect(err.string).to include("Stopped 1 project(s): api")
        expect(hooks.runs.map { |r| r[:event] }).to eq(["post_stop"])
      end

      it "reports a named project that is not active as not_running, without a stderr warning" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {}
        cli, raw, err = action_cli(state: state)

        cli.run(["stop", "api", "ghost", "--json"])

        doc = parse_one(raw)
        expect(doc["status"]).to eq("ok")
        expect(doc["results"].map { |r| [r["workspace"], r["outcome"]] }).to eq([%w[api stopped], %w[ghost not_running]])
        expect(err.string).not_to include("Warning")
      end

      it "prints nothing but text, and still warns, without --json" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {}
        cli, raw, err = action_cli(state: state)

        cli.run(["stop", "api", "ghost"])

        expect(raw.string).to include("Stopped 1 project(s): api")
        expect(raw.string).not_to include("{")
        expect(err.string).to include("'ghost' is not an active workspace project")
      end

      it "prints ok with no results when nothing is running" do
        cli, raw, = action_cli

        cli.run(["stop", "--all", "--json"])

        expect(parse_one(raw)).to include("ok" => true, "status" => "ok", "results" => [])
      end
    end

    describe "run" do
      it "names the new pane of a --split in one action document" do
        run_command = CLITestHelpers::FakeRunCommand.new
        run_command.returning("%23")
        cli, raw, = action_cli(run_command: run_command)

        status = exit_status { cli.run(["run", "api", "tail -f log", "--split", "--json"]) }

        expect(status).to eq(0)
        expect(parse_one(raw)).to include("action" => "run", "ok" => true, "status" => "ok")
        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "started", "reason" => nil, "message" => nil, "pane" => "%23"}])
      end

      it "gives a null pane when the command went to an existing pane" do
        cli, raw, = action_cli

        cli.run(["run", "api", "echo hi", "--json"])

        expect(parse_one(raw)["results"].first).to include("outcome" => "started", "pane" => nil)
      end

      it "runs the post_run hook once, inside the document" do
        hook_runner = CLITestHelpers::FakeHookRunner.new
        cli, raw, = action_cli(hook_runner: hook_runner)

        cli.run(["run", "api", "echo hi", "--json"])

        expect(hook_runner.runs.map { |r| r[:event] }).to eq(["post_run"])
        parse_one(raw)
      end

      it "prints the error envelope and exits 2 when the text landed but was not confirmed submitted" do
        run_command = CLITestHelpers::FakeRunCommand.new
        run_command.raise_on_call(Workspace::Commands::Run::NotSubmittedError.new("pasted, but Enter didn't visibly take"))
        cli, raw, = action_cli(run_command: run_command)

        status = exit_status { cli.run(["run", "api", "echo hi", "--json"]) }

        expect(status).to eq(2)
        expect(parse_one(raw)).to include("ok" => false, "code" => "not_submitted")
      end

      it "prints the error envelope and exits 1 when the command was not delivered" do
        run_command = CLITestHelpers::FakeRunCommand.new
        run_command.raise_on_call(Workspace::Error.new("No active tmux session for 'api'."))
        cli, raw, = action_cli(run_command: run_command)

        expect(exit_status { cli.run(["run", "api", "echo hi", "--split", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("ok" => false)
      end

      it "refuses --json with --wait or --dry-run as a usage error" do
        run_command = CLITestHelpers::FakeRunCommand.new
        cli, raw, = action_cli(run_command: run_command)

        expect(exit_status { cli.run(["run", "api", "echo hi", "--wait", "--json"]) }).to eq(1)
        expect(exit_status { cli.run(["run", "api", "echo hi", "--dry-run", "--json"]) }).to eq(1)
        expect(run_command.calls).to eq([])
        expect(raw.string.lines.size).to eq(2)
      end

      it "prints nothing extra without --json" do
        run_command = CLITestHelpers::FakeRunCommand.new
        run_command.returning("%23")
        cli, raw, = action_cli(run_command: run_command)

        cli.run(["run", "api", "tail -f log", "--split"])

        expect(raw.string).to eq("")
      end
    end

    describe "launch" do
      it "reports each project with its window id" do
        state = CLITestHelpers::FakeState.new
        cli, raw, err = action_cli(state: state, &launching(state))

        cli.run(["launch", "api", "web", "--json"])

        doc = parse_one(raw)
        expect(doc).to include("action" => "launch", "status" => "ok", "summary" => {"launched" => 2})
        expect(doc["results"].first).to include("workspace" => "api", "outcome" => "launched", "iterm_window_id" => 31337, "headless" => false)
        expect(doc["results"].map { |r| r.values_at("prompt_sent", "pane") }).to eq([[nil, nil], [nil, nil]])
        expect(err.string).to eq("Launching api, web...\n")
        expect(raw.string).not_to include("Launching")
      end

      it "reports each row's window position, passes --arrange on, and carries position warnings" do
        state = CLITestHelpers::FakeState.new
        launch = launch_class.new(state: state, output: StringIO.new,
          result: {positions: {"api" => "restored", "web" => "arranged"}, warnings: ["saved_window_offscreen: web: gone"]})
        cli, raw, = action_cli(state: state) { {launch_command: launch} }

        cli.run(["launch", "api", "web", "--arrange", "--json"])

        doc = parse_one(raw)
        expect(doc["results"].map { |r| r["position"] }).to eq(%w[restored arranged])
        expect(doc["warnings"]).to eq(["saved_window_offscreen: web: gone"])
        expect(launch.calls.first.last).to include(arrange: true)
      end

      it "is partial (exit 3) when a prompt could not be sent to one project" do
        state = CLITestHelpers::FakeState.new
        cli, raw, = action_cli(state: state, &launching(state, result: {exit_code: 1, prompt_failures: {"web" => "agent not ready"}}))

        status = exit_status { cli.run(["launch", "api", "web", "--prompt", "hi", "--json"]) }

        doc = parse_one(raw)
        expect(status).to eq(3)
        expect(doc["status"]).to eq("partial")
        expect(doc["results"].last).to include("workspace" => "web", "outcome" => "failed", "reason" => "prompt_not_sent", "message" => "agent not ready")
      end

      it "says per project whether the prompt was sent and to which pane" do
        state = CLITestHelpers::FakeState.new
        cli, raw, = action_cli(state: state, &launching(state, result: {exit_code: 1, prompt_failures: {"web" => "agent not ready"}, delivered_panes: {"api" => "%4"}}))

        exit_status { cli.run(["launch", "api", "web", "--prompt", "hi", "--json"]) }

        rows = parse_one(raw)["results"]
        expect(rows.map { |r| r.values_at("prompt_sent", "pane") }).to eq([[true, "%4"], [false, nil]])
      end

      it "asks Launch for the delivered panes whenever it sends a prompt" do
        state = CLITestHelpers::FakeState.new
        launch = nil
        cli, = action_cli(state: state) do |out|
          launch = launch_class.new(state: state, output: out)
          {launch_command: launch}
        end

        cli.run(["launch", "api", "--json"])
        cli.run(["launch", "api", "--prompt", "hi", "--json"])

        expect(launch.calls.map { |_, options| options[:report_panes] }).to eq([nil, true])
      end

      context "with --play" do
        around do |example|
          Dir.mktmpdir("play") do |dir|
            @play_dir = dir
            example.run
          end
        end

        let(:project_config) { CLITestHelpers::FakeProjectConfig.new("api" => "/work/api", "web" => "/work/web") }
        let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
        let(:library) do
          Workspace::Library.new(config: instance_double(Workspace::Config, library_dir: @play_dir, builtin_library_dir: File.join(@play_dir, "builtin")),
            lineage: lineage, project_config: project_config)
        end
        let(:api_path) { library.project_store("api").path_for("play", "kickoff") }
        let(:global_path) { library.global_store.path_for("play", "kickoff") }

        before do
          allow(lineage).to receive(:resolve) { |cwd:| Workspace::WorkspaceLineage::Lineage.new(name: File.basename(cwd)) }
          library.global_store.write("play", "kickoff", "# Global\n")
          library.project_store("api").write("play", "kickoff", "# Api\n")
        end

        it "resolves the play per project and reports it in each row" do
          state = CLITestHelpers::FakeState.new
          cli, raw, = action_cli(state: state, project_config: project_config, library: library,
            &launching(state, result: {exit_code: 1, prompt_failures: {"web" => "agent not ready"}, bound_panes: {"api" => "%5"}}))

          exit_status { cli.run(["launch", "api", "web", "--play", "kickoff", "--prompt", "Go.", "--json"]) }

          rows = parse_one(raw)["results"]
          expect(rows.first["play"]).to eq("ref" => "play/kickoff", "scope" => "project", "path" => api_path,
            "sha256" => Digest::SHA256.hexdigest("# Api\n"), "delivered" => true, "pane" => "%5")
          expect(rows.last["play"]).to include("scope" => "global", "path" => global_path, "delivered" => false, "pane" => nil)
        end

        it "reports the play as not delivered on a project that never launched or whose session did not start" do
          state = CLITestHelpers::FakeState.new
          cli, raw, = action_cli(state: state, project_config: project_config, library: library,
            &launching(state, fail: ["api", "web"], result: {exit_code: 1, prompt_failures: {}, start_failures: {"web" => "tmux refused"}}))

          exit_status { cli.run(["launch", "api", "web", "--play", "kickoff", "--json"]) }

          rows = parse_one(raw)["results"]
          expect(rows.map { |r| [r["reason"], r["play"]["delivered"]] }).to eq([["not_launched", false], ["session_not_started", false]])
        end

        it "sends each project a line pointing at its own play, then the prompt" do
          launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
          cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library)

          cli.run(["launch", "--play", "kickoff", "--prompt", "Go.", "api", "web"])

          expect(launch_command).to have_received(:call).with(["api", "web"], reattach: false, prompts: {
            "api" => "Read \"#{api_path}\" and follow it.\n\nGo.",
            "web" => "Read \"#{global_path}\" and follow it.\n\nGo."
          }, bindings: {
            "api" => {"kind" => "play", "id" => "play/kickoff", "instructions" => api_path, "plays" => [{"id" => "play/kickoff", "instructions" => api_path}]},
            "web" => {"kind" => "play", "id" => "play/kickoff", "instructions" => global_path, "plays" => [{"id" => "play/kickoff", "instructions" => global_path}]}
          }, report_panes: true)
        end

        context "with packs" do
          let(:project_settings) { instance_double(Workspace::ProjectSettings, load: {}, load_global: {}) }
          let(:composer) do
            Workspace::InstructionComposer.new(library: library, lineage: lineage, commands_config: Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
              pane_bindings: instance_double(Workspace::PaneBindings), notes_config: Workspace::NotesConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)))
          end
          let(:notes_text) { "## From pack notes (built-in)\n\nNotes go in the notes directory.\n" }

          before do
            library.builtin_store.write("play", "notes", "Notes go in the notes directory.\n")
            library.builtin_store.write("play", "review", "Review the diff.\n")
          end

          it "sends the notes pack to every project with no flags at all, ahead of the prompt" do
            launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
            cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

            cli.run(["launch", "--prompt", "Go.", "api", "web"])

            expect(launch_command).to have_received(:call).with(["api", "web"], reattach: false, report_panes: true,
              prompts: {"api" => "#{notes_text.strip}\n\nGo.", "web" => "#{notes_text.strip}\n\nGo."},
              bindings: %w[api web].to_h { |name| [name, {"kind" => "play", "id" => "play/notes", "packs" => ["notes"], "keep_existing" => true}] })
          end

          it "binds a project's pane to its play with the packs, and one with no play to the packs alone" do
            launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
            cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

            cli.run(["launch", "--play", "kickoff", "--pack", "review", "api"])

            expect(launch_command).to have_received(:call) do |_projects, **options|
              expect(options[:bindings]).to eq("api" => {"kind" => "play", "id" => "play/kickoff", "instructions" => api_path, "plays" => [{"id" => "play/kickoff", "instructions" => api_path}], "packs" => %w[notes review]})
            end
          end

          it "sends the play line, then the packs, then the prompt, and adds --pack after the automatic ones" do
            launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
            cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

            cli.run(["launch", "--play", "kickoff", "--pack", "review", "--prompt", "Go.", "api"])

            expect(launch_command).to have_received(:call) do |_projects, **options|
              expect(options[:prompts]).to eq("api" => "Read \"#{api_path}\" and follow it.\n\n#{notes_text}\n## From pack review (built-in)\n\nReview the diff.\n\nGo.")
            end
          end

          it "leaves out the automatic pack with --no-packs or notes.instructions false, sending no prompt at all" do
            launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
            cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)
            allow(project_settings).to receive(:load).with("web").and_return({"notes" => {"instructions" => "false"}})

            cli.run(["launch", "--no-packs", "api"])
            cli.run(["launch", "web"])

            expect(launch_command).to have_received(:call).with(["api"], reattach: false, prompts: {})
            expect(launch_command).to have_received(:call).with(["web"], reattach: false, prompts: {})
          end

          it "refuses --no-packs with --pack, and an unknown pack before anything is created" do
            launch_command = double("launch", call: {exit_code: 0})
            project_config.resolutions["/work/new"] = ["new", "/work/new"]
            cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

            expect(exit_status { cli.run(["launch", "api", "--no-packs", "--pack", "review", "--json"]) }).to eq(1)
            expect(parse_one(raw)).to include("ok" => false, "code" => "usage")

            cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)
            expect(exit_status { cli.run(["launch", "api", "/work/new", "--pack", "nope", "--json"]) }).to eq(1)
            expect(parse_one(raw)).to include("ok" => false, "code" => "unknown_library_entry")
            expect(project_config.created).to be_empty
            expect(launch_command).not_to have_received(:call)
          end

          it "marks a prompt of automatic packs alone as optional, and any explicit prompt, play or pack as required" do
            launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
            cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

            cli.run(["launch", "api"])
            cli.run(["launch", "--prompt", "Go.", "web"])
            cli.run(["launch", "--pack", "review", "api"])
            cli.run(["launch", "--play", "kickoff", "web"])

            expect(launch_command).to have_received(:call).with(["api"], hash_including(optional: {"api" => ["notes"]})).once
            expect(launch_command).to have_received(:call).with(["web"], hash_not_including(:optional)).twice
            expect(launch_command).to have_received(:call).with(["api"], hash_not_including(:optional)).once
          end

          it "exits 0 with delivered false, a null pane and a warning when the automatic pack was skipped" do
            state = CLITestHelpers::FakeState.new
            message = "the notes pack was not sent to api: no coding agent is running in tmux session 'api'"
            cli, raw, = action_cli(state: state, project_config: project_config, library: library, instruction_composer: composer,
              &launching(state, result: {exit_code: 0, prompt_failures: {}, delivered_panes: {}, skipped_prompts: {"api" => message}}))

            status = exit_status { cli.run(["launch", "api", "--json"]) }

            doc = parse_one(raw)
            expect(status).to eq(0)
            expect(doc["results"].first["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => false, "pane" => nil}])
            expect(doc["results"].first).to include("prompt_sent" => false, "pane" => nil)
            expect(doc["warnings"]).to eq([message])
          end

          it "reports each project's packs in its row, empty when none applied" do
            state = CLITestHelpers::FakeState.new
            allow(project_settings).to receive(:load).with("web").and_return({"notes" => {"instructions" => false}})
            cli, raw, = action_cli(state: state, project_config: project_config, library: library, instruction_composer: composer,
              &launching(state, result: {exit_code: 1, prompt_failures: {"api" => "agent not ready"}, delivered_panes: {}}))

            exit_status { cli.run(["launch", "api", "web", "--json"]) }

            rows = parse_one(raw)["results"]
            expect(rows.first["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => false, "pane" => nil}])
            expect(rows.last["packs"]).to eq([])
          end

          it "reports the pane a delivered pack went to" do
            state = CLITestHelpers::FakeState.new
            cli, raw, = action_cli(state: state, project_config: project_config, library: library, instruction_composer: composer,
              &launching(state, result: {exit_code: 0, prompt_failures: {}, delivered_panes: {"api" => "%4", "web" => "%6"}}))

            exit_status { cli.run(["launch", "api", "web", "--pack", "review", "--json"]) }

            rows = parse_one(raw)["results"]
            expect(rows.first["packs"]).to eq([{"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%4"},
              {"name" => "review", "source" => "flag", "delivered" => true, "pane" => "%4"}])
            expect(rows.map { |r| r.values_at("prompt_sent", "pane") }).to eq([[true, "%4"], [true, "%6"]])
          end

          context "with the handoff pack" do
            let(:handoff_auto) { {} }
            let(:handoff_config) { instance_double(Workspace::HandoffConfig) }
            let(:agent_kinds) { Hash.new("claude") }
            let(:main_agent) { instance_double(Workspace::MainAgent) }
            let(:composer) do
              Workspace::InstructionComposer.new(library: library, lineage: lineage, commands_config: Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
                pane_bindings: instance_double(Workspace::PaneBindings), notes_config: Workspace::NotesConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)),
                handoff_config: handoff_config, main_agent: main_agent)
            end

            before do
              library.builtin_store.write("play", "handoff", "Run the check.\n")
              allow(handoff_config).to receive(:auto?) { |name| handoff_auto.fetch(name, false) }
              allow(main_agent).to receive(:kind) { |name| agent_kinds[name] }
            end

            it "sends nothing extra with no flag and handoff.auto unset, so a plain launch is as before" do
              launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
              cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

              cli.run(["launch", "api"])

              expect(launch_command).to have_received(:call).with(["api"], hash_including(optional: {"api" => ["notes"]}))
            end

            it "sends the pack to every project with --handoff, as a required prompt" do
              launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
              cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

              cli.run(["launch", "--handoff", "api", "web"])

              expect(launch_command).to have_received(:call) do |_projects, **options|
                expect(options[:prompts].values).to all(include("## From pack handoff (built-in)"))
                expect(options[:bindings].values).to all(include("packs" => %w[notes handoff]))
                expect(options).not_to have_key(:optional)
              end
            end

            it "follows handoff.auto per project, and --no-handoff overrides it" do
              handoff_auto.merge!("api" => true, "web" => true)
              launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
              cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

              cli.run(["launch", "api"])
              cli.run(["launch", "--no-handoff", "web"])

              expect(launch_command).to have_received(:call).with(["api"], hash_including(optional: {"api" => %w[notes handoff]}))
              expect(launch_command).to have_received(:call).with(["web"], hash_including(optional: {"web" => %w[notes]}))
            end

            it "launches a project whose agent is not Claude Code without the pack, with a warning and a skipped row" do
              state = CLITestHelpers::FakeState.new
              handoff_auto["api"] = true
              agent_kinds["api"] = "opencode"
              cli, raw, err = action_cli(state: state, project_config: project_config, library: library, instruction_composer: composer,
                &launching(state, result: {exit_code: 0, prompt_failures: {}, delivered_panes: {"api" => "%4"}}))

              status = exit_status { cli.run(["launch", "api", "--json"]) }

              doc = parse_one(raw)
              expect(status).to eq(0)
              expect(doc["results"].first["packs"]).to eq([
                {"name" => "notes", "source" => "config", "delivered" => true, "pane" => "%4"},
                {"name" => "handoff", "source" => "config", "delivered" => false, "pane" => nil, "reason" => "handoff_unsupported_agent"}
              ])
              expect(doc["warnings"]).to eq(["the handoff pack was not sent to api: handoff.auto is on, but its main agent is opencode and the pack needs Claude Code or Codex"])
              expect(err.string).to include("Warning: the handoff pack was not sent to api")
            end

            it "refuses --handoff for a non-Claude project before anything launches or is created, with details.kind" do
              agent_kinds["web"] = "opencode"
              launch_command = double("launch", call: {exit_code: 0})
              cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

              expect(exit_status { cli.run(["launch", "api", "web", "--handoff", "--json"]) }).to eq(1)

              expect(parse_one(raw)).to include("ok" => false, "code" => "handoff_unsupported_agent", "details" => {"kind" => "opencode"})
              expect(launch_command).not_to have_received(:call)
            end

            it "refuses --no-packs with --handoff, and accepts it with --no-handoff" do
              launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
              cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)

              expect(exit_status { cli.run(["launch", "api", "--no-packs", "--handoff", "--json"]) }).to eq(1)
              expect(parse_one(raw)).to include("ok" => false, "code" => "usage")

              cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library, instruction_composer: composer)
              cli.run(["launch", "api", "--no-packs", "--no-handoff"])
              expect(launch_command).to have_received(:call).with(["api"], reattach: false, prompts: {})
            end

            it "lists --handoff in launch --help" do
              cli, _, error_output = build_test_cli
              expect { cli.run(["launch"]) }.to raise_error(FakeSystemExit)

              expect(error_output.string).to include("--[no-]handoff")
            end
          end
        end

        it "looks a directory argument's play up from that directory" do
          launch_command = double("launch", call: {exit_code: 0, prompt_failures: {}})
          project_config.resolutions["/work/new"] = ["new", "/work/new"]
          library.project_store("new").write("play", "kickoff", "# New\n")
          cli, = build_test_cli(launch_command: launch_command, project_config: project_config, library: library)

          cli.run(["launch", "--play", "kickoff", "/work/new"])

          expect(launch_command).to have_received(:call).with(["new"], reattach: false,
            prompts: {"new" => "Read \"#{library.project_store("new").path_for("play", "kickoff")}\" and follow it."},
            bindings: {"new" => {"kind" => "play", "id" => "play/kickoff", "instructions" => library.project_store("new").path_for("play", "kickoff"), "plays" => [{"id" => "play/kickoff", "instructions" => library.project_store("new").path_for("play", "kickoff")}]}},
            report_panes: true)
          expect(project_config.root_lookups).to be_empty
        end

        it "sends several plays as one line each and reports them in every row" do
          library.global_store.write("play", "review", "# Review\n")
          review_path = library.global_store.path_for("play", "review")
          state = CLITestHelpers::FakeState.new
          launch = launch_class.new(state: state, output: StringIO.new, result: {bound_panes: {"api" => "%5"}})
          cli, raw, = action_cli(state: state, project_config: project_config, library: library, launch_command: launch)

          exit_status { cli.run(["launch", "--play", "kickoff,review", "--play", "kickoff", "api", "--json"]) }

          expect(launch.calls.first.last).to include(prompts: {
            "api" => "Read \"#{api_path}\" and follow it.\nRead \"#{review_path}\" and follow it."
          }, bindings: {"api" => {"kind" => "play", "id" => "play/kickoff", "instructions" => api_path,
                                  "plays" => [{"id" => "play/kickoff", "instructions" => api_path}, {"id" => "play/review", "instructions" => review_path}]}})
          row = parse_one(raw)["results"].first
          expect(row["plays"].map { |p| p["ref"] }).to eq(%w[play/kickoff play/review])
          expect(row["play"]).to eq(row["plays"].first)
        end

        it "fails an unknown play among several with nothing launched or created" do
          launch_command = double("launch", call: {exit_code: 0})
          cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library)

          status = exit_status { cli.run(["launch", "api", "--play", "kickoff,nope", "--json"]) }

          expect(status).to eq(1)
          expect(parse_one(raw)).to include("ok" => false, "code" => "unknown_library_entry")
          expect(project_config.created).to be_empty
          expect(launch_command).not_to have_received(:call)
        end

        it "fails an unknown play with nothing launched or created" do
          launch_command = double("launch", call: {exit_code: 0})
          project_config.resolutions["/work/new"] = ["new", "/work/new"]
          cli, raw, = action_cli(launch_command: launch_command, project_config: project_config, library: library)

          status = exit_status { cli.run(["launch", "api", "/work/new", "--play", "nope", "--json"]) }

          expect(status).to eq(1)
          expect(parse_one(raw)).to include("ok" => false, "code" => "unknown_library_entry")
          expect(project_config.created).to be_empty
          expect(launch_command).not_to have_received(:call)
        end
      end

      it "fails (exit 1) when no project got a session" do
        state = CLITestHelpers::FakeState.new
        cli, raw, = action_cli(state: state, &launching(state, fail: ["api"], result: {exit_code: 1, start_failures: {"api" => "tmux refused"}}))

        status = exit_status { cli.run(["launch", "api", "--json"]) }

        expect(status).to eq(1)
        doc = parse_one(raw)
        expect(doc).to include("ok" => true, "status" => "failed")
        expect(doc["results"].first).to include("outcome" => "failed", "reason" => "session_not_started")
      end

      it "reports a headless project that was already running as reused" do
        state = CLITestHelpers::FakeState.new
        cli, raw, = action_cli(state: state, launch_mode: CLITestHelpers.launch_mode(headless: true), &launching(state, result: {reused: ["api"]}))

        cli.run(["launch", "api", "--json"])

        expect(parse_one(raw)["results"].first).to include("outcome" => "reused", "headless" => true)
      end

      it "keeps the exit code and text without --json" do
        state = CLITestHelpers::FakeState.new
        cli, raw, = action_cli(state: state, &launching(state, result: {exit_code: 1}))

        expect(exit_status { cli.run(["launch", "api"]) }).to eq(1)
        expect(raw.string).to eq("Launching api...\n")
      end

      it "answers a usage error with the error envelope" do
        cli, raw, err = action_cli

        expect(exit_status { cli.run(["launch", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "usage")
        expect(err.string).to eq("")
      end
    end

    describe "relaunch" do
      it "stops and relaunches every project, reporting relaunched" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {"iterm_window_id" => 1}
        cli, raw, err = action_cli(state: state, &launching(state))

        cli.run(["relaunch", "--all", "--json"])

        doc = parse_one(raw)
        expect(doc).to include("action" => "relaunch", "status" => "ok", "summary" => {"relaunched" => 1})
        expect(err.string).to include("Will relaunch: api")
      end

      it "answers with the error envelope when nothing is active" do
        cli, raw, err = action_cli

        expect(exit_status { cli.run(["relaunch", "--all", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "error" => "No active workspace projects to relaunch.")
        expect(err.string).to eq("")
      end
    end

    describe "restore" do
      let(:restore_class) do
        Class.new do
          def initialize(result) = @result = result

          def call(_names, dry_run: false) = @result
        end
      end
      let(:row) { {"workspace" => "api", "kind" => "pane", "outcome" => "restored", "reason" => nil, "slot" => "api:0.4"} }

      def restore_cli(result)
        state = CLITestHelpers::FakeState.new
        state["api"] = {"iterm_window_id" => 1}
        action_cli(state: state, restore_command: restore_class.new(result))
      end

      it "prints one action document with dry_run and unmatched beside the rows" do
        unmatched = [{"workspace" => "api", "slot" => "api:1.0", "reason" => "no_window"}]
        rows = [row.merge("outcome" => "would_restore"), row.merge("outcome" => "unmatched", "reason" => "no_window", "slot" => "api:1.0")]
        cli, raw, = restore_cli({exit_code: 0, results: rows, warnings: ["w"], status: "dry_run", extra: {"dry_run" => true, "unmatched" => unmatched}})

        expect(exit_status { cli.run(["restore", "--all", "--dry-run", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("schema_version" => 1, "ok" => true, "action" => "restore", "status" => "dry_run", "dry_run" => true,
          "unmatched" => unmatched, "results" => rows, "warnings" => ["w"], "summary" => {"would_restore" => 1, "unmatched" => 1})
      end

      it "is ok with exit 0 when panes were restored and some could not be matched" do
        rows = [row, row.merge("outcome" => "unmatched", "reason" => "pane_busy")]
        cli, raw, = restore_cli({exit_code: 0, results: rows, warnings: [], extra: {"dry_run" => false, "unmatched" => []}})

        expect(exit_status { cli.run(["restore", "--all", "--json"]) }).to eq(0)
        expect(parse_one(raw)).to include("status" => "ok", "dry_run" => false)
      end

      it "is partial with exit 3 when some rows failed, and failed with exit 1 when all did" do
        failed = row.merge("outcome" => "failed", "reason" => "split_failed")
        cli, raw, = restore_cli({exit_code: 1, results: [row, failed], warnings: [], extra: {}})
        expect(exit_status { cli.run(["restore", "--all", "--json"]) }).to eq(3)
        expect(parse_one(raw)).to include("status" => "partial")

        cli, raw, = restore_cli({exit_code: 1, results: [failed], warnings: [], extra: {}})
        expect(exit_status { cli.run(["restore", "--all", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("status" => "failed")
      end

      it "answers an unknown workspace and an empty active set with the error envelope" do
        cli, raw, = action_cli(restore_command: restore_class.new({}))
        expect(exit_status { cli.run(["restore", "nope", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"})

        cli, raw, err = action_cli(restore_command: restore_class.new({}))
        expect(exit_status { cli.run(["restore", "--all", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("ok" => false, "error" => "No active workspace projects to restore. Name one: workspace restore WORKSPACE (--all restores every active one)")
        expect(err.string).to eq("")
      end

      it "answers not_in_workspace with the error envelope outside any workspace and without --all" do
        cli, raw, = restore_cli({})
        expect(exit_status { cli.run(["restore", "--json"]) }).to eq(1)
        expect(parse_one(raw)).to include("ok" => false, "code" => "not_in_workspace")
      end
    end

    describe "kill" do
      it "reports killed" do
        kill = double("kill")
        allow(kill).to receive(:call).and_return("myproj.worktree-x")
        allow(kill).to receive(:notes_inside_worktree).and_return(nil)
        allow(kill).to receive(:branch_result).and_return({"name" => "x", "deleted" => true, "kept_reason" => nil})
        allow(kill).to receive(:remote_branch_result).and_return(nil)
        allow(kill).to receive(:dev_stopped).and_return(false)
        cli, raw, = action_cli(kill_command: kill)

        cli.run(["kill", "myproj.worktree-x", "--json"])

        expect(parse_one(raw)).to include("action" => "kill", "status" => "ok", "warnings" => [])
        expect(parse_one(raw)["results"].first).to include("workspace" => "myproj.worktree-x", "outcome" => "killed")
        expect(parse_one(raw)["results"].first).not_to have_key("notes_inside_worktree")
        expect(parse_one(raw)["results"].first).not_to have_key("dev_stopped")
      end

      it "reports dev_stopped: true on the row when the worktree's dev environment was stopped first" do
        kill = double("kill")
        allow(kill).to receive(:call).and_return("myproj.worktree-x")
        allow(kill).to receive(:notes_inside_worktree).and_return(nil)
        allow(kill).to receive(:branch_result).and_return({"name" => "x", "deleted" => true, "kept_reason" => nil})
        allow(kill).to receive(:remote_branch_result).and_return(nil)
        allow(kill).to receive(:dev_stopped).and_return(true)
        cli, raw, = action_cli(kill_command: kill)

        cli.run(["kill", "myproj.worktree-x", "--json"])

        expect(parse_one(raw)["results"].first).to include("workspace" => "myproj.worktree-x", "outcome" => "killed", "dev_stopped" => true)
      end

      it "reports notes that were inside the removed worktree on the row, and in warnings" do
        held = {"dir" => "/wt/tmp/workspace-notes", "files" => 3}
        kill = double("kill")
        allow(kill).to receive(:call).and_return("myproj.worktree-x")
        allow(kill).to receive(:notes_inside_worktree).and_return(held)
        allow(kill).to receive(:branch_result).and_return({"name" => "x", "deleted" => true, "kept_reason" => nil})
        allow(kill).to receive(:remote_branch_result).and_return(nil)
        allow(kill).to receive(:dev_stopped).and_return(false)
        cli, raw, = action_cli(kill_command: kill)

        expect(exit_status { cli.run(["kill", "myproj.worktree-x", "--json"]) }).to eq(0)

        expect(parse_one(raw)["results"].first).to include("outcome" => "killed", "notes_inside_worktree" => held)
        expect(parse_one(raw)["warnings"]).to eq([Workspace::Commands::Kill.notes_sentence(held)])
      end

      it "reports a declined confirmation as cancelled with exit 0" do
        kill = double("kill", call: nil)
        cli, raw, = action_cli(kill_command: kill)

        expect(exit_status { cli.run(["kill", "x", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("status" => "cancelled")
        expect(parse_one(raw)["results"].first).to include("outcome" => "cancelled", "reason" => "declined")
      end

      it "answers a refusal with the error envelope and a retry hint" do
        error = Workspace::UnsavedWorkError.new("has unsaved work", unsaved: {changed_files: 3, unpushed_commits: 0})
        kill = double("kill")
        allow(kill).to receive(:call).and_raise(error)
        cli, raw, err = action_cli(kill_command: kill)

        expect(exit_status { cli.run(["kill", "x", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "unsaved_work", "retry" => {"flags" => ["--force"], "destructive" => true})
        expect(err.string).to eq("")
      end
    end

    describe "focus" do
      it "reports focused with the window id" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {"iterm_window_id" => 77}
        hooks = CLITestHelpers::FakeHookRunner.new
        cli, raw, err = action_cli(state: state, hook_runner: hooks) do |out|
          {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: CLITestHelpers::FakeWindowManager.new, output: out)}
        end

        cli.run(["focus", "api", "--json"])

        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "focused", "reason" => nil, "message" => nil, "iterm_window_id" => 77}])
        expect(err.string).to include("Focusing api...")
        expect(hooks.runs.map { |r| r[:event] }).to eq(["post_focus"])
      end

      it "names focus.chain and how to get centering and a dim in its help" do
        cli, = action_cli
        help = a_string_including("focus.chain", "focus + center + dim --opacity 0.5 --duration 3", "a warning, not an error")

        expect { cli.run(["focus", "--help"]) }.to raise_error(SystemExit).and output(help).to_stdout
      end

      it "answers a missing window with the error envelope" do
        focus = Workspace::Commands::Focus.new(state: CLITestHelpers::FakeState.new, window_manager: CLITestHelpers::FakeWindowManager.new, output: StringIO.new)
        cli, raw, = action_cli(focus_command: focus)

        expect(exit_status { cli.run(["focus", "api", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "no_window", "details" => {"workspace" => "api"})
        expect(parse_one(raw)["error"]).to include("No iTerm window found for 'api'")
      end

      it "centers the window with --center" do
        state = CLITestHelpers::FakeState.new
        state["api"] = {"iterm_window_id" => 77}
        hooks = CLITestHelpers::FakeHookRunner.new
        windows = double("window_manager")
        allow(windows).to receive(:focus_by_id).and_return(true)
        allow(windows).to receive(:center_window).with(77).and_return([0, 0])
        cli, raw, err = action_cli(state: state, hook_runner: hooks) do |out|
          {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: windows, output: out)}
        end

        cli.run(["focus", "api", "--center", "--json"])

        expect(windows).to have_received(:center_window).with(77)
        expect(parse_one(raw)["results"].first).to include("workspace" => "api", "outcome" => "focused")
        expect(err.string).to include("Focusing api...")
      end

      describe "focus chain warnings" do
        let(:state) { CLITestHelpers::FakeState.new.tap { |s| s["api"] = {"iterm_window_id" => 77} } }
        let(:failure) { Workspace::WindowManager::StepFailure.new("dim", 2, "error: Unknown command 'dim'\n") }
        let(:windows) do
          double("window_manager", focus_by_id: true, run_focus_steps: failure, highlight_by_id: true).tap do |w|
            allow(w).to receive(:center_window).and_return(false)
          end
        end
        let(:config_reading) { Workspace::FocusConfig::Reading.new([["dim"]], "focus.chain is bad; using the default focus.chain.") }
        let(:hooks) { CLITestHelpers::FakeHookRunner.new }

        def chain_cli
          action_cli(state: state, hook_runner: hooks) do |out|
            focus_config = double("focus_config", read: config_reading)
            {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: windows, focus_config: focus_config, output: out, error_output: StringIO.new)}
          end
        end

        it "lists the warnings in the document, exits 0, runs post_focus, and keeps stdout to one document" do
          cli, raw, = chain_cli

          expect(exit_status { cli.run(["focus", "api", "--json"]) }).to eq(0)

          document = parse_one(raw)
          expect(document["status"]).to eq("ok")
          expect(document["warnings"]).to eq([
            "focus.chain is bad; using the default focus.chain.",
            "The window is in front, but this window-tool has no 'dim' command: error: Unknown command 'dim'. Update window-tool, or change focus.chain."
          ])
          expect(hooks.runs.map { |r| r[:event] }).to eq(["post_focus"])
        end

        it "lists the warnings for --cycle" do
          liveness = double("liveness", call: {"api" => true})
          allow(windows).to receive(:window_ids_front_to_back).and_return([])
          cli, raw, = action_cli(state: state, hook_runner: hooks) do |out|
            focus_config = double("focus_config", read: config_reading)
            {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: windows, window_liveness: liveness, focus_config: focus_config, output: out, error_output: StringIO.new)}
          end

          cli.run(["focus", "--cycle", "--json"])

          expect(parse_one(raw)["warnings"].size).to eq(2)
        end

        it "prints the warnings to stderr in text mode" do
          raw = StringIO.new
          err = StringIO.new
          focus_config = double("focus_config", read: config_reading)
          focus = Workspace::Commands::Focus.new(state: state, window_manager: windows, focus_config: focus_config, output: raw, error_output: err)
          cli, = build_test_cli(output: raw, error_output: err, state: state, focus_command: focus, hook_runner: hooks)

          expect(exit_status { cli.run(["focus", "api"]) }).to eq(0)

          expect(err.string).to include("Warning: focus.chain is bad").and include("Warning: The window is in front, but this window-tool has no 'dim' command")
          expect(raw.string).not_to include("Warning")
        end

        it "carries the warnings in the no_screen_geometry error document" do
          cli, raw, = chain_cli

          expect(exit_status { cli.run(["focus", "api", "--center", "--json"]) }).to eq(1)

          document = parse_one(raw)
          expect(document).to include("code" => "no_screen_geometry")
          expect(document["details"]["warnings"].size).to eq(2)
        end
      end

      describe "focus against a fake window-tool" do
        it "prints exactly one document under --json and warns on stderr" do
          Dir.mktmpdir("workspace-focus-e2e") do |dir|
            bin = File.join(dir, "bin")
            FileUtils.mkdir_p(bin)
            File.write(File.join(dir, "log"), "")
            tool = File.join(bin, "window-tool")
            File.write(tool, <<~SH)
              #!/bin/sh
              echo "$@" >> "#{dir}/log"
              if [ "$1" = "dim" ]; then echo "error: Unknown command 'dim'" >&2; exit 2; fi
              exit 0
            SH
            File.chmod(0o755, tool)
            File.write(File.join(dir, ".workspace-state.json"), JSON.generate("api" => {"unique_id" => "u", "iterm_window_id" => 77}))
            config_dir = File.join(dir, ".config", "workspace")
            FileUtils.mkdir_p(config_dir)
            File.write(File.join(config_dir, "config.yml"), "focus:\n  chain: \"focus + center + dim --opacity 0.5 --duration 3\"\n")
            saved = ENV.to_h
            raw = StringIO.new
            err = StringIO.new
            begin
              ENV.replace("HOME" => dir, "PATH" => "#{bin}:/usr/bin:/bin")
              cli = Workspace.build_cli(output: raw, error_output: err, input: StringIO.new, env: {})
              cli.run(["focus", "api", "--json"])
            ensure
              ENV.replace(saved)
            end

            document = parse_one(raw)
            expect(document["results"].first).to include("workspace" => "api", "outcome" => "focused")
            expect(document["warnings"].size).to eq(1)
            expect(document["warnings"].first).to include("this window-tool has no 'dim' command")
            expect(err.string).to include("Warning: The window is in front")
            expect(File.read(File.join(dir, "log")).lines.map { |l| l.split.first }).to eq(%w[focus center dim])
          end
        end
      end

      describe "--color" do
        let(:state) do
          CLITestHelpers::FakeState.new.tap { |s| s["api"] = {"iterm_window_id" => 77} }
        end
        let(:windows) do
          double("window_manager").tap do |w|
            allow(w).to receive(:focus_by_id).and_return(true)
            allow(w).to receive(:highlight_by_id).and_return(true)
            allow(w).to receive(:window_ids_front_to_back).and_return([77])
          end
        end

        def color_cli
          action_cli(state: state) do |out|
            {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: windows, output: out)}
          end
        end

        it "refuses an unknown color before focusing, with or without --highlight" do
          [["focus", "api", "--color", "pink"], ["focus", "api", "--highlight", "--color", "pink"]].each do |argv|
            cli, _, err = color_cli

            expect(exit_status { cli.run(argv) }).to eq(1)

            expect(err.string).to include("pink")
            expect(err.string).to include(Workspace::ConfigSchema::WINDOW_TOOL_COLORS.join(", "))
          end
          expect(windows).not_to have_received(:focus_by_id)
        end

        it "refuses an unknown color with --cycle before anything moves" do
          cli, _, err = color_cli

          expect(exit_status { cli.run(["focus", "--cycle", "--color", "pink"]) }).to eq(1)

          expect(err.string).to include("Unknown --color")
          expect(windows).not_to have_received(:focus_by_id)
        end

        it "accepts a color in any case, and random" do
          %w[BLUE random].each do |color|
            cli, = color_cli

            expect(exit_status { cli.run(["focus", "api", "--highlight", "--color", color]) }).to eq(0)
          end
          expect(windows).to have_received(:focus_by_id).twice
          expect(windows).to have_received(:highlight_by_id).with(77, "BLUE")
          expect(windows).to have_received(:highlight_by_id).with(77, "random")
        end

        it "answers an unknown color with the usage error document under --json" do
          cli, raw, = color_cli

          expect(exit_status { cli.run(["focus", "api", "--color", "pink", "--json"]) }).to eq(1)

          expect(parse_one(raw)).to include("ok" => false, "code" => "usage")
          expect(parse_one(raw)["error"]).to include("Unknown --color \"pink\"")
          expect(windows).not_to have_received(:focus_by_id)
        end
      end
    end

    describe "focus --cycle" do
      let(:state) do
        CLITestHelpers::FakeState.new.tap do |s|
          s["api"] = {"iterm_window_id" => 77}
          s["web"] = {"iterm_window_id" => 78}
        end
      end
      let(:windows) do
        Class.new(CLITestHelpers::FakeWindowManager) {
          def window_ids_front_to_back = [77, 78]
        }.new
      end
      let(:liveness) { ->(entries) { entries.to_h { |name, _| [name, true] } } }

      def cycle_cli(hooks: CLITestHelpers::FakeHookRunner.new, liveness: self.liveness)
        action_cli(state: state, hook_runner: hooks) do |out|
          {focus_command: Workspace::Commands::Focus.new(state: state, window_manager: windows, window_liveness: liveness, output: out)}
        end
      end

      it "reports the next workspace focused" do
        hooks = CLITestHelpers::FakeHookRunner.new
        cli, raw, = cycle_cli(hooks: hooks)

        cli.run(["focus", "--cycle", "--json"])

        expect(parse_one(raw)["results"]).to eq([{"workspace" => "web", "outcome" => "focused", "reason" => nil, "message" => nil, "iterm_window_id" => 78}])
        expect(hooks.runs.map { |r| r[:event] }).to eq(["post_focus"])
      end

      it "goes back with --reverse" do
        cli, raw, = cycle_cli

        cli.run(["focus", "--cycle", "--reverse", "--json"])

        expect(parse_one(raw)["results"].first["workspace"]).to eq("web")
      end

      it "answers no live window with no_windows_to_cycle" do
        none = ->(entries) { entries.to_h { |name, _| [name, false] } }
        cli, raw, = cycle_cli(liveness: none)

        expect(exit_status { cli.run(["focus", "--cycle", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "no_windows_to_cycle")
      end

      it "refuses a project, --pane, or --reverse alone" do
        {
          ["focus", "--cycle", "api"] => /takes no project/,
          ["focus", "--cycle", "--pane", "%3"] => /can't be combined with --pane/,
          ["focus", "--reverse", "api"] => /needs --cycle/
        }.each do |argv, message|
          cli, _, err = cycle_cli

          expect(exit_status { cli.run(argv) }).to eq(1)
          expect(err.string).to match(message)
        end
      end
    end

    describe "focus --pane" do
      let(:tmux) { CLITestHelpers::FakeTmuxServer.new("api" => [{id: "%3", window: 0, index: 0}, {id: "%19", window: 1, index: 2}], "web" => [{id: "%7", window: 0, index: 0}]) }
      let(:state) do
        CLITestHelpers::FakeState.new.tap { |st| st["api"] = {"iterm_window_id" => 77} }
      end

      def pane_cli(**overrides)
        action_cli(state: state, **overrides) do |out|
          focus = Workspace::Commands::Focus.new(state: state, window_manager: CLITestHelpers::FakeWindowManager.new, tmux: tmux,
            pane_locator: Workspace::PaneLocator.new(tmux: tmux), output: out)
          {focus_command: focus}
        end
      end

      it "selects the pane and reports it in the row" do
        cli, raw, = pane_cli

        cli.run(["focus", "api", "--pane", "%19", "--json"])

        expect(tmux.selected).to eq([{session: "api", id: "%19", window: 1}])
        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "focused", "reason" => nil, "message" => nil, "iterm_window_id" => 77, "pane" => "%19"}])
      end

      it "leaves the pane out of the row without --pane" do
        cli, raw, = pane_cli

        cli.run(["focus", "api", "--json"])

        expect(parse_one(raw)["results"].first).not_to have_key("pane")
        expect(tmux.selected).to be_empty
      end

      it "refuses a pane of another workspace before focusing anything" do
        cli, raw, = pane_cli

        expect(exit_status { cli.run(["focus", "api", "--pane", "%7", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "wrong_session")
        expect(tmux.selected).to be_empty
      end

      it "reports focus_failed when tmux can't select the pane" do
        tmux.select_ok = false
        cli, raw, = pane_cli

        expect(exit_status { cli.run(["focus", "api", "--pane", "%3", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "focus_failed")
      end
    end

    describe "repair" do
      it "reports each rebuilt window" do
        repair = double("repair", call: [{"workspace" => "api", "iterm_window_id" => 5, "unique_id" => "U1"}])
        cli, raw, = action_cli(repair_command: repair)

        cli.run(["repair", "--json"])

        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "repaired", "reason" => nil, "message" => nil, "iterm_window_id" => 5, "unique_id" => "U1"}])
      end

      it "reports the window id set by hand" do
        repair = double("repair", set_window_id: nil)
        cli, raw, = action_cli(repair_command: repair)

        cli.run(["repair", "api", "--window-id", "9", "--json"])

        expect(parse_one(raw)["results"].first).to include("workspace" => "api", "outcome" => "repaired", "iterm_window_id" => 9)
      end
    end

    describe "remove" do
      let(:removed_row) { {"workspace" => "app", "outcome" => "removed", "files" => ["/c.yml"], "backups" => ["/c.yml.b"], "state_entry" => true} }

      it "passes the options to the command" do
        remove = double("remove", call: removed_row)
        cli, = action_cli(remove_command: remove)

        cli.run(["remove", "app", "--yes", "--dry-run"])

        expect(remove).to have_received(:call).with("app", yes: true, dry_run: true)
      end

      it "prints one action document with the files and exits 0" do
        remove = double("remove", call: removed_row)
        cli, raw, = action_cli(remove_command: remove)

        expect(exit_status { cli.run(["remove", "app", "--yes", "--json"]) }).to eq(0)

        doc = parse_one(raw)
        expect(doc).to include("action" => "remove", "status" => "ok")
        expect(doc["results"].first).to include("workspace" => "app", "outcome" => "removed", "files" => ["/c.yml"], "state_entry" => true)
      end

      it "reports a dry run as status dry_run" do
        remove = double("remove", call: removed_row.merge("outcome" => "would_remove"))
        cli, raw, = action_cli(remove_command: remove)

        expect(exit_status { cli.run(["remove", "app", "--dry-run", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("status" => "dry_run")
      end

      it "reports a declined prompt as cancelled" do
        remove = double("remove", call: nil)
        cli, raw, = action_cli(remove_command: remove)

        expect(exit_status { cli.run(["remove", "app", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("status" => "cancelled")
      end

      it "takes at most one name" do
        cli, _, err = action_cli(remove_command: double("remove"))

        expect(exit_status { cli.run(["remove", "app", "web"]) }).to eq(1)
        expect(err.string).to include("takes at most one NAME")
      end

      it "removes the workspace the working directory is in when no name is given" do
        Dir.mktmpdir do |root|
          state = CLITestHelpers::FakeState.new
          state["app"] = {}
          remove = double("remove", call: removed_row)
          cli, = action_cli(remove_command: remove, state: state, project_config: CLITestHelpers::FakeProjectConfig.new("app" => root), working_dir: root)

          cli.run(["remove", "--yes"])

          expect(remove).to have_received(:call).with("app", yes: true, dry_run: false)
        end
      end

      it "removes the workspace named by --name" do
        remove = double("remove", call: removed_row)
        cli, = action_cli(remove_command: remove)

        cli.run(["remove", "--name", "app", "--dry-run"])

        expect(remove).to have_received(:call).with("app", yes: false, dry_run: true)
      end

      it "refuses with not_in_workspace outside any workspace when no name is given" do
        remove = double("remove")
        cli, raw, = action_cli(remove_command: remove)

        expect(exit_status { cli.run(["remove", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("ok" => false, "code" => "not_in_workspace")
      end
    end

    describe "prune" do
      def prune_row(name, outcome, error: nil)
        {"name" => name, "branch" => name, "reason" => "merged", "outcome" => outcome, "error" => error, "message" => nil, "pr_number" => 1, "pr_url" => "u"}
      end

      it "prints one action document and exits 0 when every selected row was removed" do
        prune = double("prune", call_structured: [prune_row("a", "removed"), prune_row("b", "not_selected")])
        cli, raw, = action_cli(prune_command: prune)

        expect(exit_status { cli.run(["prune", "--json", "--name=a"]) }).to eq(0)

        expect(prune).to have_received(:call_structured).with(dry_run: false, force: false, names: ["a"])
        doc = parse_one(raw)
        expect(doc).to include("action" => "prune", "status" => "ok", "summary" => {"removed" => 1, "not_selected" => 1})
        expect(doc["results"].first).to include("name" => "a", "branch" => "a", "reason" => "merged", "outcome" => "removed", "error" => nil)
      end

      it "exits 3 with status partial when some rows were skipped" do
        prune = double("prune", call_structured: [prune_row("a", "removed"), prune_row("b", "skipped_unsaved", error: "unsaved_work")])
        cli, raw, = action_cli(prune_command: prune)

        expect(exit_status { cli.run(["prune", "--json"]) }).to eq(3)

        expect(parse_one(raw)).to include("status" => "partial")
      end

      it "exits 1 with status failed when nothing selected was removed" do
        prune = double("prune", call_structured: [prune_row("a", "skipped_unsaved", error: "unsaved_work"), prune_row("b", "not_selected")])
        cli, raw, = action_cli(prune_command: prune)

        expect(exit_status { cli.run(["prune", "--json", "--name", "a"]) }).to eq(1)

        expect(parse_one(raw)).to include("status" => "failed")
      end

      it "with --dry-run reports status dry_run and exit 0, and passes --force through" do
        prune = double("prune", call_structured: [prune_row("a", "would_remove")])
        cli, raw, = action_cli(prune_command: prune)

        expect(exit_status { cli.run(["prune", "--dry-run", "--force", "--json"]) }).to eq(0)

        expect(prune).to have_received(:call_structured).with(dry_run: true, force: true, names: [])
        expect(parse_one(raw)).to include("status" => "dry_run", "summary" => {"would_remove" => 1})
      end

      it "does not call a dry run ok when a named workspace is no candidate" do
        prune = double("prune", call_structured: [prune_row("nope", "failed", error: "not_prunable")])
        cli, raw, = action_cli(prune_command: prune)

        expect(exit_status { cli.run(["prune", "--dry-run", "--json", "--name=nope"]) }).to eq(1)

        expect(parse_one(raw)).to include("status" => "failed")
      end

      it "passes --name to the text command without --json" do
        prune = double("prune", call: [])
        cli, = action_cli(prune_command: prune)

        cli.run(["prune", "--name=x"])

        expect(prune).to have_received(:call).with(dry_run: false, force: false, names: ["x"])
      end

      it "is ok with no rows when nothing is eligible" do
        cli, raw, = action_cli(prune_command: double("prune", call_structured: []))

        expect(exit_status { cli.run(["prune", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("status" => "ok", "results" => [])
      end
    end

    describe "cleanup" do
      let(:zombies) do
        [{project: "old-a", tmux_alive: false, window_alive: false}, {project: "old-b", tmux_alive: true, window_alive: nil}]
      end

      it "reports each zombie removed, with its tmux and window state" do
        cleanup = double("cleanup", call: zombies)
        cli, raw, = action_cli(cleanup_command: cleanup)

        cli.run(["cleanup", "--force", "--json"])

        expect(cleanup).to have_received(:call).with(force: true, dry_run: false, tmux_dead_only: false)
        doc = parse_one(raw)
        expect(doc).to include("action" => "cleanup", "status" => "ok", "summary" => {"cleaned" => 2})
        expect(doc["results"].first).to include("workspace" => "old-a", "outcome" => "cleaned", "reason" => nil, "message" => nil, "tmux_alive" => false, "window_alive" => false)
        expect(doc["results"].last).to include("tmux_alive" => true, "window_alive" => nil)
      end

      it "with --dry-run --json reports would_remove rows, status dry_run, exit 0" do
        cleanup = double("cleanup", call: zombies)
        cli, raw, = action_cli(cleanup_command: cleanup)

        expect(exit_status { cli.run(["cleanup", "--dry-run", "--json"]) }).to eq(0)

        expect(cleanup).to have_received(:call).with(force: false, dry_run: true, tmux_dead_only: false)
        doc = parse_one(raw)
        expect(doc).to include("action" => "cleanup", "status" => "dry_run", "summary" => {"would_remove" => 2})
        expect(doc["results"].first).to include("workspace" => "old-a", "outcome" => "would_remove", "tmux_alive" => false, "window_alive" => false)
      end

      it "passes --tmux-dead-only through" do
        cleanup = double("cleanup", call: [])
        cli, = action_cli(cleanup_command: cleanup)

        cli.run(["cleanup", "--tmux-dead-only", "--force", "--json"])

        expect(cleanup).to have_received(:call).with(force: true, dry_run: false, tmux_dead_only: true)
      end

      it "reports status dry_run with no rows when there is nothing to remove" do
        cleanup = double("cleanup", call: [])
        cli, raw, = action_cli(cleanup_command: cleanup)

        expect(exit_status { cli.run(["cleanup", "--dry-run", "--json"]) }).to eq(0)

        expect(parse_one(raw)).to include("status" => "dry_run", "results" => [])
      end

      it "names a headless row so null window_alive can be told from an unreadable list" do
        cleanup = double("cleanup", call: [{project: "hl", tmux_alive: false, window_alive: nil, headless: true}])
        cli, raw, = action_cli(cleanup_command: cleanup)

        cli.run(["cleanup", "--dry-run", "--json"])

        expect(parse_one(raw)["results"].first).to include("headless" => true, "window_alive" => nil)
      end
    end

    describe "deactivate and reactivate" do
      it "reports per-project outcomes, including a skipped project" do
        claude = double("claude", deactivate: {"api" => {"outcome" => "deactivated"}, "web" => {"outcome" => "skipped", "reason" => "no_session", "message" => "No active tmux session for web"}})
        cli, raw, = action_cli(claude_command: claude)

        cli.run(["deactivate", "--all", "--json"])

        doc = parse_one(raw)
        expect(doc).to include("action" => "deactivate", "status" => "ok", "summary" => {"deactivated" => 1, "skipped" => 1})
        expect(doc["results"].last).to include("workspace" => "web", "reason" => "no_session")
      end

      it "is failed when a reactivate delivery failed" do
        claude = double("claude", reactivate: {"api" => {"outcome" => "failed", "reason" => "not_delivered", "message" => "pane gone"}})
        cli, raw, = action_cli(claude_command: claude)

        expect(exit_status { cli.run(["reactivate", "api", "--json"]) }).to eq(1)

        expect(parse_one(raw)).to include("action" => "reactivate", "status" => "failed")
      end
    end

    describe "dev and lock" do
      it "reports dev up as started" do
        dev = double("dev", up: {exit_code: 0})
        cli, raw, = action_cli(dev_command: dev, project_config: CLITestHelpers::FakeProjectConfig.new("api" => Dir.tmpdir))

        cli.run(["dev", "up", "--name", "api", "--json"])

        expect(parse_one(raw)).to include("action" => "dev up", "status" => "ok")
        expect(parse_one(raw)["results"].first).to include("workspace" => "api", "outcome" => "started")
      end

      it "keeps the command's own exit code when dev up fails" do
        dev = double("dev", up: {exit_code: 75})
        cli, raw, = action_cli(dev_command: dev, project_config: CLITestHelpers::FakeProjectConfig.new("api" => Dir.tmpdir))

        expect(exit_status { cli.run(["dev", "up", "--name", "api", "--json"]) }).to eq(75)

        doc = parse_one(raw)
        expect(doc["status"]).to eq("failed")
        expect(doc["results"].first).to include("outcome" => "failed", "reason" => "exit_code", "exit_code" => 75)
      end

      it "reports dev down as stopped" do
        dev = double("dev", down: {exit_code: 0})
        cli, raw, = action_cli(dev_command: dev, project_config: CLITestHelpers::FakeProjectConfig.new("api" => Dir.tmpdir))

        cli.run(["dev", "down", "--name", "api", "--json"])

        expect(parse_one(raw)).to include("action" => "dev down", "status" => "ok")
      end

      it "reports lock release as released, naming the lock" do
        lock = double("lock", release: {exit_code: 0})
        cli, raw, = action_cli(lock_command: lock, project_config: CLITestHelpers::FakeProjectConfig.new("api" => Dir.tmpdir))

        cli.run(["lock", "release", "edit", "--name", "api", "--json"])

        expect(parse_one(raw)["results"].first).to include("workspace" => "api", "outcome" => "released", "lock" => "edit", "all" => false)
      end
    end

    describe "config set" do
      it "reports the project and key set" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        cli, raw, = action_cli(config_command: config_command)

        cli.run(["config", "set", "dev.up", "bin/dev", "--name", "api", "--json"])

        expect(parse_one(raw)["results"]).to eq([{"workspace" => "api", "outcome" => "set", "reason" => nil, "message" => nil, "key" => "dev.up", "value" => "bin/dev", "global" => false,
                                                  "scope" => "project", "layer" => "project", "file" => "/cfg/api.yml", "comments_preserved" => true, "effective" => nil}])
      end

      it "marks a global key" do
        config_command = CLITestHelpers::FakeConfigCommand.new
        cli, raw, = action_cli(config_command: config_command)

        cli.run(["config", "set", "launch.headless", "true", "--scope", "global", "--json"])

        expect(parse_one(raw)["results"].first).to include("workspace" => nil, "global" => true, "scope" => "global", "layer" => "global")
      end

      it "keeps stdout to one JSON document and puts the comment note on stderr" do
        dir = Dir.mktmpdir("ws-config-cli")
        settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir))
        path = settings.project_config_path("api")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "# keep me\ndev:\n  up: old\n")
        raw = StringIO.new
        gate = Workspace::OutputGate.new(raw)
        err = StringIO.new
        config_command = Workspace::Commands::Config.new(project_settings: settings, lineage: LineageSupport.lineage,
          file_backup: Workspace::FileBackup.new(output: err), output: gate, error_output: err)
        cli, = build_test_cli(output: gate, error_output: err, config_command: config_command)

        cli.run(["config", "set", "dev.up", "bin/dev", "--name", "api", "--json"])

        expect(parse_one(raw)["results"].first).to include("comments_preserved" => false)
        expect(err.string).to include("Note: comments in #{path} were not kept")
        expect(raw.string).not_to include("Note:")
      end
    end
  end

  describe "workspace given by --name or the working directory" do
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:lonely_detector) { instance_double(Workspace::ProjectDetector, detect: nil) }

    def expect_usage_error(cli, argv)
      expect { cli.run(argv) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    describe "capture" do
      let(:capture) { CLITestHelpers::FakeCaptureCommand.new }

      it "uses the detected workspace, --name, or the positional" do
        cli, = build_test_cli(capture_command: capture, project_detector: detector)
        cli.run(["capture"])
        cli.run(["capture", "--name", "other"])
        cli.run(["capture", "pos"])
        cli.run(["capture", "pos", "--name", "pos"])
        expect(capture.calls.map { |c| c[:project] }).to eq(%w[detected-ws other pos pos])
      end

      it "refuses a positional and a different --name" do
        cli, _, err = build_test_cli(capture_command: capture, project_detector: detector)
        expect_usage_error(cli, ["capture", "a", "--name", "b"])
        expect(err.string).to include("Give the workspace once")
        expect(capture.calls).to be_empty
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(capture_command: capture, project_detector: lonely_detector)
        expect_usage_error(cli, ["capture"])
        expect(err.string).to include("Usage: workspace capture")
      end
    end

    describe "focus" do
      let(:focus) { double("focus", call: nil, warnings: []) }

      it "uses the detected workspace, --name, or the positional" do
        cli, = build_test_cli(focus_command: focus, project_detector: detector)
        cli.run(["focus"])
        cli.run(["focus", "--name", "other"])
        cli.run(["focus", "pos", "--pane", "%1"])
        expect(focus).to have_received(:call).with("detected-ws", shake: false, highlight: nil, pane: nil, center: false)
        expect(focus).to have_received(:call).with("other", shake: false, highlight: nil, pane: nil, center: false)
        expect(focus).to have_received(:call).with("pos", shake: false, highlight: nil, pane: "%1", center: false)
      end

      it "refuses a differing --name and positional, and --cycle with --name" do
        cli, _, err = build_test_cli(focus_command: focus, project_detector: detector)
        expect_usage_error(cli, ["focus", "a", "--name", "b"])
        expect(err.string).to include("Give the workspace once")
        expect_usage_error(cli, ["focus", "--cycle", "--name", "b"])
        expect(focus).not_to have_received(:call)
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(focus_command: focus, project_detector: lonely_detector)
        expect_usage_error(cli, ["focus"])
        expect(err.string).to include("Usage: workspace focus")
      end
    end

    describe "handoff" do
      let(:handoff) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }

      it "check and new use the detected workspace, --name, or the positional" do
        cli, = build_test_cli(handoff_command: handoff, project_detector: detector)
        cli.run(["handoff", "check"])
        cli.run(["handoff", "check", "--name", "other"])
        cli.run(["handoff", "new", "--name", "other"])
        cli.run(["handoff", "new", "pos"])
        cli.run(["handoff", "new"])
        expect(handoff).to have_received(:check).with(hash_including(name: "detected-ws"))
        expect(handoff).to have_received(:check).with(hash_including(name: "other"))
        expect(handoff).to have_received(:new).with(hash_including(name: "other"))
        expect(handoff).to have_received(:new).with(hash_including(name: "pos"))
        expect(handoff).to have_received(:new).with(hash_including(name: "detected-ws"))
      end

      it "refuses a differing --name and positional" do
        cli, _, err = build_test_cli(handoff_command: handoff, project_detector: detector)
        expect_usage_error(cli, ["handoff", "check", "a", "--name", "b"])
        expect(err.string).to include("Give the workspace once")
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(handoff_command: handoff, project_detector: lonely_detector)
        expect_usage_error(cli, ["handoff", "check"])
        expect(err.string).to include("Missing workspace name")
        expect_usage_error(cli, ["handoff", "new"])
      end
    end

    describe "review show" do
      let(:review) { CLITestHelpers::FakeReviewCommand.new }

      it "uses the detected workspace, --name, or the positional" do
        cli, = build_test_cli(review_command: review, project_detector: detector)
        cli.run(["review", "show"])
        cli.run(["review", "show", "--name", "other"])
        cli.run(["review", "--name", "other"])
        cli.run(["review", "show", "pos"])
        expect(review.calls.map { |c| c[:show] }).to eq(%w[detected-ws other other pos])
      end

      it "refuses a differing --name and positional, and --name on list" do
        cli, _, err = build_test_cli(review_command: review, project_detector: detector)
        expect_usage_error(cli, ["review", "show", "a", "--name", "b"])
        expect(err.string).to include("Give the workspace once")
        expect_usage_error(cli, ["review", "list", "--name", "b"])
        expect(err.string).to include("workspace review list PROJECT")
        expect(review.calls).to be_empty
      end

      it "refuses --name on review list with a next step" do
        cli, _, err = build_test_cli(review_command: review, project_detector: detector)
        expect_usage_error(cli, ["review", "list", "--name", "b"])
        expect(err.string).to include("'review list' takes a PROJECT argument instead")
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(review_command: review, project_detector: lonely_detector)
        expect_usage_error(cli, ["review", "show"])
        expect(err.string).to include("Missing workspace name")
      end
    end

    describe "sessions" do
      let(:sessions) { double("sessions", call: {exit_code: 0}) }

      it "uses the detected workspace, --name, or the positional" do
        cli, = build_test_cli(sessions_command: sessions, project_detector: detector)
        cli.run(["sessions"])
        cli.run(["sessions", "--name", "other"])
        cli.run(["sessions", "pos"])
        expect(sessions).to have_received(:call).with(hash_including(name: "detected-ws"))
        expect(sessions).to have_received(:call).with(hash_including(name: "other"))
        expect(sessions).to have_received(:call).with(hash_including(name: "pos"))
      end

      it "refuses a differing --name and positional" do
        cli, _, err = build_test_cli(sessions_command: sessions, project_detector: detector)
        expect_usage_error(cli, ["sessions", "a", "--name", "b"])
        expect(err.string).to include("Give the workspace once")
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(sessions_command: sessions, project_detector: lonely_detector)
        expect_usage_error(cli, ["sessions"])
        expect(err.string).to include("Usage: workspace sessions")
      end
    end

    describe "wait-until-content" do
      let(:waiter) { CLITestHelpers::FakeWaitUntilContentCommand.new }

      it "uses the detected workspace, --name, or the positional" do
        cli, = build_test_cli(wait_until_content_command: waiter, project_detector: detector)
        cli.run(["wait-until-content", "READY", "--", "irb"])
        cli.run(["wait-until-content", "--name", "other", "READY", "--", "irb"])
        cli.run(["wait-until-content", "pos", "READY", "--", "irb"])
        cli.run(["wait-until-content", "--name", "pos", "pos", "READY", "--", "irb"])
        expect(waiter.calls.map { |c| [c[:project], c[:content]] }).to eq(
          [["detected-ws", "READY"], ["other", "READY"], ["pos", "READY"], ["pos", "READY"]]
        )
      end

      it "takes --name with the one-argument form and passes a command after -- through" do
        cli, = build_test_cli(wait_until_content_command: waiter, project_detector: detector)
        cli.run(["wait-until-content", "--name", "other", "READY", "--", "bin/console", "--flag", "x y"])
        cli.run(["wait-until-content", "READY", "--name=other2", "-e", "echo hi"])
        expect(waiter.calls.map { |c| [c[:project], c[:content]] }).to eq([["other", "READY"], ["other2", "READY"]])
        expect(waiter.calls.first[:exec_command]).to eq(["bin/console", "--flag", "x y"])
      end

      it "refuses a differing --name and positional" do
        cli, _, err = build_test_cli(wait_until_content_command: waiter, project_detector: detector)
        expect_usage_error(cli, ["wait-until-content", "a", "READY", "--name", "b", "--", "irb"])
        expect(err.string).to include("Give the workspace once")
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(wait_until_content_command: waiter, project_detector: lonely_detector)
        expect_usage_error(cli, ["wait-until-content", "READY", "--", "irb"])
        expect(err.string).to include("no workspace project detected")
      end
    end

    describe "layout" do
      let(:layout) { double("layout", save: nil, restore: nil, list: nil) }

      it "treats one argument as the layout name, for the detected workspace or --name" do
        cli, = build_test_cli(layout_command: layout, project_detector: detector)
        cli.run(["layout", "save", "coding"])
        cli.run(["layout", "restore", "--name", "other", "coding"])
        cli.run(["layout", "save", "--name=other"])
        cli.run(["layout", "restore"])
        expect(layout).to have_received(:save).with("detected-ws", "coding")
        expect(layout).to have_received(:restore).with("other", "coding")
        expect(layout).to have_received(:save).with("other", "default")
        expect(layout).to have_received(:restore).with("detected-ws", "default")
      end

      it "treats two arguments as PROJECT NAME, and list keeps its positional" do
        cli, = build_test_cli(layout_command: layout, project_detector: detector)
        cli.run(["layout", "save", "pos", "coding"])
        cli.run(["layout", "list", "pos"])
        cli.run(["layout", "list", "--name", "other"])
        cli.run(["layout", "list"])
        expect(layout).to have_received(:save).with("pos", "coding")
        expect(layout).to have_received(:list).with("pos")
        expect(layout).to have_received(:list).with("other")
        expect(layout).to have_received(:list).with("detected-ws")
      end

      it "refuses --name with two arguments or a differing list positional" do
        cli, = build_test_cli(layout_command: layout, project_detector: detector)
        expect_usage_error(cli, ["layout", "save", "--name", "x", "a", "b"])
        expect_usage_error(cli, ["layout", "list", "a", "--name", "b"])
        expect(layout).not_to have_received(:save)
      end

      it "fails outside any workspace, even with one argument" do
        cli, _, err = build_test_cli(layout_command: layout, project_detector: lonely_detector)
        expect_usage_error(cli, ["layout", "save", "coding"])
        expect(err.string).to include("No workspace detected from the current directory: pass --name WS, or give PROJECT NAME.")
        expect_usage_error(cli, ["layout", "restore", "coding"])
        expect(err.string).to include("No workspace detected")
        expect(layout).not_to have_received(:save)
        expect(layout).not_to have_received(:restore)
      end

      it "tells the person what to do when --name and PROJECT NAME are both given" do
        cli, _, err = build_test_cli(layout_command: layout, project_detector: detector)
        expect_usage_error(cli, ["layout", "save", "--name", "x", "a", "b"])
        expect(err.string).to include("either 'PROJECT NAME' or --name WS with just NAME")
      end

      it "points the undo hint at the --name form" do
        cli, output, = build_test_cli
        cli.run(["layout"])
        expect(output.string).to include("workspace layout restore --name <project> _before_resize")
      end
    end

    describe "set-command" do
      let(:pane_cmd) { double("update_pane", call: nil) }

      it "detects the workspace for one argument, and takes --name or the positional" do
        cli, = build_test_cli(update_pane_command: pane_cmd, project_detector: detector)
        cli.run(["set-command", "vim .", "--pane", "2"])
        cli.run(["set-command", "--name", "other", "vim .", "--pane", "2"])
        cli.run(["set-command", "pos", "vim .", "--pane", "2"])
        expect(pane_cmd).to have_received(:call).with(project: "detected-ws", command: "vim .", pane_index: 2)
        expect(pane_cmd).to have_received(:call).with(project: "other", command: "vim .", pane_index: 2)
        expect(pane_cmd).to have_received(:call).with(project: "pos", command: "vim .", pane_index: 2)
      end

      it "fails outside any workspace" do
        cli, _, err = build_test_cli(update_pane_command: pane_cmd, project_detector: lonely_detector)
        expect_usage_error(cli, ["set-command", "vim .", "--pane", "2"])
        expect(err.string).to include("No workspace found")
        expect(pane_cmd).not_to have_received(:call)
      end
    end
  end

  describe "short workspace names" do
    let(:configs) { ["a.worktree-fix-login", "b.worktree-other", "c.worktree-twin", "d.worktree-twin", "notes", "e.worktree-notes"] }
    let(:project_config) do
      instance_double(Workspace::ProjectConfig, available_projects: configs).tap do |pc|
        allow(pc).to receive(:existing_name) { |name| configs.find { |known| known.casecmp?(name.to_s) } }
        allow(pc).to receive(:project_root_for) { |name| configs.include?(name) ? "/roots/#{name}" : nil }
      end
    end
    let(:state) { CLITestHelpers::FakeState.new }
    let(:workspace_name) { Workspace::WorkspaceName.new(project_config: project_config, state: state) }
    let(:stop_command) { instance_double(Workspace::Commands::Stop, call: [], warnings: []) }
    let(:ask_command) { CLITestHelpers::FakeAskCommand.new }
    let(:config_command) { CLITestHelpers::FakeConfigCommand.new }
    let(:ui_command) { CLITestHelpers::FakeUiCommand.new }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:built) do
      build_test_cli(project_config: project_config, workspace_name: workspace_name, state: state, stop_command: stop_command,
        ask_command: ask_command, config_command: config_command, ui_command: ui_command, project_detector: detector)
    end
    let(:cli) { built[0] }
    let(:output) { built[1] }
    let(:error_output) { built[2] }

    it "settles --name SHORT and --name=SHORT to the full name, and says so" do
      cli.run(["stop", "--name", "fix-login"])
      cli.run(["stop", "--name=FIX-login"])

      expect(stop_command).to have_received(:call).with(["a.worktree-fix-login"]).twice
      expect(error_output.string).to eq("Workspace 'fix-login' is a.worktree-fix-login.\nWorkspace 'FIX-login' is a.worktree-fix-login.\n")
    end

    it "settles relaunch --name SHORT to the full name" do
      state["a.worktree-fix-login"] = {"unique_id" => "uid"}
      allow(stop_command).to receive(:call).and_raise(Workspace::Error, "stopped here")

      expect { cli.run(["relaunch", "--name", "fix-login"]) }.to raise_error(FakeSystemExit)

      expect(stop_command).to have_received(:call).with(["a.worktree-fix-login"])
    end

    it "prints no note for the full name" do
      cli.run(["stop", "--name", "a.worktree-fix-login"])

      expect(stop_command).to have_received(:call).with(["a.worktree-fix-login"])
      expect(error_output.string).to eq("")
    end

    it "settles a short positional, also beside the same workspace by full --name" do
      cli.run(["stop", "fix-login"])
      cli.run(["stop", "fix-login", "--name", "a.worktree-fix-login"])

      expect(stop_command).to have_received(:call).with(["a.worktree-fix-login"]).twice
    end

    it "takes a short workspace for ask list, config get and ui open" do
      cli.run(["ask", "list", "fix-login"])
      cli.run(["config", "get", "fix-login", "some.key"])
      cli.run(["ui", "open", "fix-login"])

      expect(ask_command.calls.first[:working_dir]).to eq("/roots/a.worktree-fix-login")
      expect(config_command.calls.first).to include(action: :get, project: "a.worktree-fix-login", key: "some.key")
      expect(ui_command.calls).to eq([{view: "task", workspace: "a.worktree-fix-login", print_only: false}])
    end

    it "says so on stderr for a short workspace at ask list, config get and ui open" do
      cli.run(["ask", "list", "fix-login"])
      cli.run(["config", "get", "fix-login", "some.key"])
      cli.run(["ui", "open", "fix-login"])

      expect(error_output.string.scan("Workspace 'fix-login' is a.worktree-fix-login.").size).to eq(3)
    end

    it "keeps `ui open notes` as the view when a workspace has the suffix notes" do
      cli.run(["ui", "open", "notes"])

      expect(ui_command.calls).to eq([{view: "notes", workspace: "detected-ws", print_only: false}])
    end

    it "leaves `ask list junk` and `ui open typo` to their own parsing" do
      expect { cli.run(["ask", "list", "junk"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Usage: workspace ask list")
      expect(ask_command.calls).to be_empty
      expect { cli.run(["ui", "open", "typo"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Unknown view or workspace 'typo'")
      expect(ui_command.calls).to be_empty
    end

    it "names the full workspace on stderr for stop SHORT and kill SHORT" do
      kill_command = instance_double(Workspace::Commands::Kill, call: "a.worktree-fix-login")
      cli, _, error_output = build_test_cli(project_config: project_config, workspace_name: workspace_name, state: state, stop_command: stop_command, kill_command: kill_command)

      cli.run(["stop", "fix-login"])
      cli.run(["kill", "fix-login"])

      expect(stop_command).to have_received(:call).with(["a.worktree-fix-login"])
      expect(kill_command).to have_received(:call).with("a.worktree-fix-login", anything)
      expect(error_output.string.scan("Workspace 'fix-login' is a.worktree-fix-login.").size).to eq(2)
    end

    it "keeps an active workspace with no config: stop foo gets foo, with no note" do
      configs << "b.worktree-foo"
      state["foo"] = {}

      cli.run(["stop", "foo"])

      expect(stop_command).to have_received(:call).with(["foo"])
      expect(error_output.string).to eq("")
    end

    it "answers an ambiguous --name with one error envelope on stdout under --json" do
      expect { cli.run(["stop", "--name", "twin", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      doc = JSON.parse(output.string)
      expect(doc["code"]).to eq("ambiguous_workspace")
      expect(doc["details"]).to include("name" => "twin", "matches" => ["c.worktree-twin", "d.worktree-twin"])
      expect(error_output.string).to eq("")
    end

    it "answers an ambiguous --name on stderr without --json" do
      expect { cli.run(["stop", "--name", "twin"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("'twin' matches more than one workspace")
      expect(output.string).to eq("")
    end

    it "prints help for an ambiguous --name, with --json too, and for events" do
      cli.run(["plan", "status", "--help", "--name", "twin"])
      expect(output.string).to include("workspace plan status")
      expect(error_output.string).to eq("")

      output.truncate(0)
      cli.run(["plan", "status", "--help", "--json", "--name", "twin"])
      expect(output.string).to include("workspace plan status")
      expect(error_output.string).to eq("")

      output.truncate(0)
      cli.run(["events", "--name", "twin", "--help"])
      expect(output.string).to include("Usage: workspace events")
      expect(error_output.string).to eq("")
    end

    it "prints help for an ambiguous --name given -h" do
      cli.run(["plan", "status", "-h", "--name", "twin"])

      expect(output.string).to include("workspace plan status")
      expect(error_output.string).to eq("")
    end

    it "does not read --help after a bare -- as asking for help" do
      expect { cli.run(["stop", "--name", "twin", "--", "--help"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("'twin' matches more than one workspace")
    end

    it "does not read --json after a bare -- as quieting the note" do
      cli.run(["stop", "--name", "fix-login", "--", "--json"])

      expect(error_output.string).to include("Workspace 'fix-login' is a.worktree-fix-login.")
    end

    it "writes no note under --json-envelope" do
      expect { cli.run(["stop", "--name", "fix-login", "--all", "--json-envelope"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).not_to include("Workspace 'fix-login' is")
    end

    it "writes no note under --json when the command then fails" do
      expect { cli.run(["stop", "--name", "fix-login", "--all", "--json"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to eq("")
    end

    it "leaves a name that matches nothing to the command's unknown_workspace" do
      expect { cli.run(["events", "--name", "nothing"]) }.to raise_error(FakeSystemExit)

      expect(error_output.string).to include("Unknown workspace 'nothing'")
    end
  end

  describe "short workspace names at raw positionals" do
    let(:configs) { ["a.worktree-fix-login", "c.worktree-twin", "d.worktree-twin"] }
    let(:project_config) do
      instance_double(Workspace::ProjectConfig, available_projects: configs).tap do |pc|
        allow(pc).to receive(:existing_name) { |name| configs.find { |known| known.casecmp?(name.to_s) } }
        allow(pc).to receive(:project_root_for) { |name| configs.include?(name) ? "/roots/#{name}" : nil }
      end
    end
    let(:state) { CLITestHelpers::FakeState.new }
    let(:workspace_name) { Workspace::WorkspaceName.new(project_config: project_config, state: state) }
    let(:run_command) { CLITestHelpers::FakeRunCommand.new }
    let(:resize_command) { double("resize", call: nil) }
    let(:repair_command) { double("repair", set_window_id: nil) }
    let(:detector) { instance_double(Workspace::ProjectDetector, detect: "detected-ws") }
    let(:tmpdir) { Dir.mktmpdir }
    let(:config) do
      dir = tmpdir
      Class.new(Workspace::Config) do
        define_method(:pipeline_state_path) { |name| File.join(dir, "#{name}-pipeline.json") }
      end.new
    end
    let(:built) do
      build_test_cli(project_config: project_config, workspace_name: workspace_name, state: state, run_command: run_command,
        resize_command: resize_command, repair_command: repair_command, project_detector: detector, config: config)
    end
    let(:cli) { built[0] }
    let(:output) { built[1] }

    after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

    it "run SHORT cmd reaches the command with the full name" do
      cli.run(["run", "fix-login", "echo hi"])

      expect(run_command.calls.first).to include(project: "a.worktree-fix-login", command: "echo hi")
    end

    it "resize SHORT spec reaches the command with the full name" do
      cli.run(["resize", "fix-login", "50%,50%"])

      expect(resize_command).to have_received(:call).with("a.worktree-fix-login", "50%,50%")
    end

    it "keeps a one-word run or resize as the command or spec, with the project detected" do
      cli.run(["run", "fix-login"])
      cli.run(["resize", "50%,50%"])

      expect(run_command.calls.first).to include(project: "detected-ws", command: "fix-login")
      expect(resize_command).to have_received(:call).with("detected-ws", "50%,50%")
    end

    it "raises ambiguous_workspace for run before anything is sent" do
      expect { cli.run(["run", "twin", "echo hi"]) }.to raise_error(FakeSystemExit)

      expect(built[2].string).to include("matches more than one workspace")
      expect(run_command.calls).to be_empty
    end

    it "repair SHORT --window-id gets the full name" do
      cli.run(["repair", "fix-login", "--window-id", "1"])

      expect(repair_command).to have_received(:set_window_id).with("a.worktree-fix-login", 1)
    end

    it "settles the workspace of every other pipeline verb" do
      [["reset", "twin"], ["advance", "twin", "--work-item", "T-1"]].each do |verb_args|
        built[2].truncate(0)
        expect { cli.run(["pipeline", *verb_args]) }.to raise_error(FakeSystemExit)
        expect(built[2].string).to include("'twin' matches more than one workspace")
      end
    end

    it "pipeline status SHORT reads the full name's state" do
      File.write(config.pipeline_state_path("a.worktree-fix-login"), "{}")

      cli.run(["pipeline", "status", "fix-login"])

      expect(output.string).to include("No pipeline work in flight for a.worktree-fix-login")
    end
  end

  describe "short workspace names given to launch" do
    let(:configs) { ["a.worktree-fix-login", "c.worktree-twin", "d.worktree-twin", "a.worktree-foo", "b.worktree-foo"] }
    let(:project_config) do
      instance_double(Workspace::ProjectConfig, available_projects: configs).tap do |pc|
        allow(pc).to receive(:existing_name) { |name| configs.find { |known| known.casecmp?(name.to_s) } }
        allow(pc).to receive(:project_root_for) { |name| configs.include?(name) ? "/roots/#{name}" : nil }
        allow(pc).to receive(:resolve_project_arg) do |arg|
          if arg.include?("/") || File.directory?(arg)
            [File.basename(arg), File.expand_path(arg)]
          else
            [arg, nil]
          end
        end
      end
    end
    let(:state) { CLITestHelpers::FakeState.new }
    let(:workspace_name) { Workspace::WorkspaceName.new(project_config: project_config, state: state) }
    let(:launch_command) { double("launch", call: {exit_code: 0, prompt_failures: {}}) }
    let(:stop_command) { instance_double(Workspace::Commands::Stop, call: [], warnings: []) }
    let(:built) do
      build_test_cli(project_config: project_config, workspace_name: workspace_name, state: state,
        launch_command: launch_command, stop_command: stop_command)
    end
    let(:cli) { built[0] }

    it "launches the full name for a short one" do
      cli.run(["launch", "fix-login"])

      expect(launch_command).to have_received(:call).with(["a.worktree-fix-login"], anything)
    end

    it "keeps a directory named like the suffix as a path" do
      allow(project_config).to receive(:create) { |name, _root| name }
      Dir.mktmpdir do |dir|
        path = File.join(dir, "fix-login")
        Dir.mkdir(path)
        cli.run(["launch", path])

        expect(project_config).to have_received(:create).with("fix-login", File.expand_path(path))
      end
      expect(launch_command).to have_received(:call).with(["fix-login"], anything)
    end

    it "raises on an ambiguous name in a list and launches nothing" do
      expect { cli.run(["launch", "fix-login", "twin"]) }.to raise_error(FakeSystemExit)

      expect(built[2].string).to include("matches more than one workspace")
      expect(launch_command).not_to have_received(:call)
    end

    it "relaunch passes a state key with no config through, raising nothing" do
      state["foo"] = {}
      state["a.worktree-foo"] = {}

      cli.run(["relaunch", "--all"])

      expect(launch_command).to have_received(:call).with(array_including("foo"), anything)
    end

    it "restore --all passes a state key with no config through to launch" do
      state["foo"] = {}
      restore = Class.new do
        def call(names, dry_run: false)
          yield names
          {exit_code: 0, results: [], warnings: [], extra: {}}
        end
      end.new
      cli, = build_test_cli(project_config: project_config, workspace_name: workspace_name, state: state,
        launch_command: launch_command, restore_command: restore)

      cli.run(["restore", "--all"])

      expect(launch_command).to have_received(:call).with(["foo"], anything)
    end
  end
end
