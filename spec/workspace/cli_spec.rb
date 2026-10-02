require "stringio"
require "tmpdir"

RSpec.describe Workspace::CLI do
  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    config = overrides[:config] || Workspace::Config.new
    logger = overrides[:logger] || Workspace::Logger.new(output: error_output)
    state = overrides[:state] || CLITestHelpers::FakeState.new
    window_manager = overrides[:window_manager] || CLITestHelpers::FakeWindowManager.new
    tmux = overrides[:tmux] || CLITestHelpers::FakeTmux.new
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

    stop_command = overrides[:stop_command] || Workspace::Commands::Stop.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = overrides[:launch_command] || Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, config: config, output: output, error_output: error_output)
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
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
    cleanup_command = overrides[:cleanup_command] || Workspace::Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
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

    cli = Workspace::CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      git: git,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
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
      ensure_agent_command: overrides[:ensure_agent_command],
      handoff_command: overrides[:handoff_command],
      projects_command: overrides[:projects_command],
      project_actions_command: overrides[:project_actions_command],
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: overrides[:exit_handler] || FakeExitHandler,
      input: input,
      working_dir: working_dir,
      clock: overrides[:clock] || -> { Time.now },
      launch_mode: overrides[:launch_mode] || CLITestHelpers.launch_mode(headless: false),
      liveness: overrides[:liveness] || ->(names) { names.to_h { |name| [name, true] } }
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
      doctor.define_singleton_method(:run) do |headless: nil, fix: false|
        raise Workspace::Error, "something broke"
      end

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
      pc.define_singleton_method(:project_root_for) { |name| nil }
      cli, _, error_output = build_test_cli(project_config: pc)
      expect { cli.run(["dir", "unknown-project"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("not found or has no root")
    end

    it "exits 1 when no project argument given" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["dir"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage:")
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

        project_config = CLITestHelpers::FakeProjectConfig.new
        project_config.define_singleton_method(:project_root_for) { |_name| dir }

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

        project_config = CLITestHelpers::FakeProjectConfig.new
        project_config.define_singleton_method(:project_root_for) { |_name| dir }

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

        project_config = CLITestHelpers::FakeProjectConfig.new
        roots = {"monorepo" => dir, "auth-service" => subdir}
        project_config.define_singleton_method(:project_root_for) { |name| roots[name] }

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

        project_config = CLITestHelpers::FakeProjectConfig.new
        project_config.define_singleton_method(:project_root_for) { |_name| app_dir }

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
      called = false
      wm.define_singleton_method(:live_window_ids) do
        called = true
        Set.new
      end

      cli, output, _ = build_test_cli(window_manager: wm)
      cli.run(["list", "--all"])
      expect(called).to be false
      expect(output.string).to include("project-a")
    end

    it "works via list-projects alias" do
      cli, output, _ = build_test_cli
      cli.run(["list-projects"])
      expect(output.string).to include("project-a")
      expect(output.string).to include("project-b")
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

        tmux = CLITestHelpers::FakeTmux.new
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

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 200]) }

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["status", "--json"])

      result = JSON.parse(output.string)
      expect(result).to include(
        "proj1" => a_hash_including("unique_id" => "uid1", "iterm_window_id" => 100),
        "proj2" => a_hash_including("unique_id" => "uid2", "iterm_window_id" => 200)
      )
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
      expect(result["up"]).to eq("unique_id" => "u1", "iterm_window_id" => 1, "alive" => true)
      expect(result["gone"]["alive"]).to eq(false)
      expect(result["hl"]).to eq("headless" => true, "alive" => nil)
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

    it "prints name and alive objects with --json" do
      cli, output, _ = build_test_cli(state: state, liveness: liveness)
      cli.run(["list", "--liveness", "--json"])
      expect(JSON.parse(output.string)).to eq([{"name" => "gone", "alive" => false}, {"name" => "up", "alive" => true}])
    end

    it "keeps url and directory with --show-urls --json" do
      git = Object.new.tap { |g| g.define_singleton_method(:remote_url) { |_| "git@h:o/r.git" } }
      pc = CLITestHelpers::FakeProjectConfig.new({"up" => "/tmp/up"})
      cli, output, _ = build_test_cli(state: state, liveness: liveness, git: git, project_config: pc)
      cli.run(["list", "--liveness", "--show-urls", "--json"])
      up = JSON.parse(output.string).find { |e| e["name"] == "up" }
      expect(up).to eq("name" => "up", "directory" => "/tmp/up", "url" => "git@h:o/r.git", "alive" => true)
    end

    it "shows the alive marker after the url column" do
      git = Object.new.tap { |g| g.define_singleton_method(:remote_url) { |_| "u" } }
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

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 200]) }

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
      called = false
      doctor.define_singleton_method(:run) { |headless: nil, fix: false| called = true }

      cli, _, _ = build_test_cli(doctor: doctor)
      cli.run(["doctor"])
      expect(called).to be true
    end
  end

  describe "#run with stop" do
    it "stops all active projects when none specified" do
      cli, output, _ = build_test_cli
      cli.run(["stop"])
      expect(output.string).to include("No active workspace projects")
    end
  end

  describe "#run with kill" do
    it "exits 1 when no project specified and no marker file found" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["kill"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("No project specified")
    end

    it "runs the post_kill hook from inside Kill, before the session is stopped" do
      kill_command = instance_double(Workspace::Commands::Kill)
      allow(kill_command).to receive(:call).with("myproject", force: true, working_dir: anything)
        .and_yield("myproject").and_return("myproject")
      hook_runner = CLITestHelpers::FakeHookRunner.new

      cli, _, _ = build_test_cli(kill_command: kill_command, hook_runner: hook_runner)
      cli.run(["kill", "--force", "myproject"])

      expect(hook_runner.runs).to eq([{project: "myproject", event: "post_kill", env: {}}])
    end
  end

  describe "#run with finish" do
    it "exits 1 when no project specified and no marker file found" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["finish"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("No project specified")
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

  describe "#run agent-run command" do
    it "defaults --work-item to a random UUID, shown in the printed message" do
      cli, output = build_test_cli

      cli.run(["agent-run", "command", "--name", "myapp", "--body", "Add OAuth support", "--dry-run"])

      expect(output.string).to match(/"work_item_ref": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"/)
    end

    it "uses an explicit --work-item instead of generating one" do
      cli, output = build_test_cli

      cli.run(["agent-run", "command", "--name", "myapp", "--work-item", "WC-42", "--body", "Add OAuth support", "--dry-run"])

      expect(output.string).to include('"work_item_ref": "WC-42"')
    end
  end

  describe "#run agent-run inject" do
    it "still requires --work-item" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["agent-run", "inject", "--name", "myapp", "--body", "Use Postgres"]) }
        .to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing --work-item")
    end
  end

  describe "#run agent-run restart" do
    let(:restart_command) { double("restart", call: {exit_code: 0}) }

    it "passes the explicit pane, prompt and flags to the restart command" do
      cli, = build_test_cli(restart_agent_command: restart_command)

      cli.run(["agent-run", "restart", "--name", "myapp", "--pane", "%18", "--prompt", "Read HANDOFF.md",
        "--force", "--wait", "--timeout", "45s", "--json"])

      expect(restart_command).to have_received(:call).with(name: "myapp", pane: "%18", prompt: "Read HANDOFF.md",
        force: true, wait: true, timeout: 45, json: true)
    end

    it "exits with the command's exit code" do
      allow(restart_command).to receive(:call).and_return({exit_code: 1})
      cli, = build_test_cli(restart_agent_command: restart_command)

      expect { cli.run(["agent-run", "restart", "--name", "myapp", "--pane", "0.1", "--prompt", "go"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
    end

    [
      [["--name", "myapp", "--prompt", "go"], "Missing --pane."],
      [["--name", "myapp", "--pane", "0.1"], "Missing --prompt."],
      [["--name", "myapp", "--pane", "0.1", "--prompt", "go", "--timeout", "11m"], "--timeout: at most 600s"],
      [["--name", "myapp", "--pane", "0.1", "--prompt", "go", "extra"], "Unexpected argument: extra"]
    ].each do |args, message|
      it "rejects #{args.last(2).join(" ")} with a usage error" do
        cli, _, error_output = build_test_cli(restart_agent_command: restart_command)

        expect { cli.run(["agent-run", "restart", *args]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include(message)
        expect(restart_command).not_to have_received(:call)
      end

      it "reports #{args.last(2).join(" ")} as a JSON error with --json" do
        cli, output = build_test_cli(restart_agent_command: restart_command)

        expect { cli.run(["agent-run", "restart", "--json", *args]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "usage", "error" => message)
      end
    end

    it "lists restart in the agent-run help" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["agent-run"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("restart    Clear the coding agent in one pane")
    end
  end

  describe "#run handoff" do
    let(:handoff_command) { double("handoff", check: {exit_code: 0}, new: {exit_code: 0}) }

    it "passes name, pane, threshold, and doc/prompt flags to handoff check" do
      cli, = build_test_cli(handoff_command: handoff_command)

      cli.run(["handoff", "check", "myapp", "--pane", "2", "--threshold", "20", "--handoff-doc", "HANDOFF.md", "--json"])

      expect(handoff_command).to have_received(:check).with(name: "myapp", pane: "2", threshold: 20,
        context_pct: nil, handoff_doc: "HANDOFF.md", handoff_prompt: nil, json: true)
    end

    it "passes --context-pct through, skipping detection" do
      cli, = build_test_cli(handoff_command: handoff_command)

      cli.run(["handoff", "check", "myapp", "--context-pct", "42", "--handoff-prompt", "Wrap up"])

      expect(handoff_command).to have_received(:check).with(name: "myapp", pane: nil, threshold: nil,
        context_pct: 42, handoff_doc: nil, handoff_prompt: "Wrap up", json: false)
    end

    it "exits with handoff check's exit code, including 2 for undetermined usage" do
      allow(handoff_command).to receive(:check).and_return({exit_code: 2})
      cli, = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(2) }
    end

    it "rejects a non-numeric --threshold with the custom range message" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--threshold", "bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--threshold must be an integer between 1 and 100")
      expect(handoff_command).not_to have_received(:check)
    end

    it "rejects an out-of-range --threshold with the custom range message" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--threshold", "150"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("--threshold must be an integer between 1 and 100")
      expect(handoff_command).not_to have_received(:check)
    end

    it "reports a Workspace::Error from handoff check as a JSON error with --json" do
      allow(handoff_command).to receive(:check).and_raise(Workspace::Error, "no agent daemon for 'myapp'")
      cli, output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--json"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "no agent daemon for 'myapp'")
    end

    it "rejects both --handoff-doc and --handoff-prompt together" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check", "myapp", "--handoff-doc", "a", "--handoff-prompt", "b"]) }
        .to raise_error(FakeSystemExit)
      expect(error_output.string).to include("mutually exclusive")
      expect(handoff_command).not_to have_received(:check)
    end

    it "requires a workspace name when none is given and cwd detection fails" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "check"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing workspace name")
      expect(handoff_command).not_to have_received(:check)
    end

    it "passes name, pane, and doc/prompt flags to handoff new" do
      cli, = build_test_cli(handoff_command: handoff_command)

      cli.run(["handoff", "new", "myapp", "--pane", "2", "--handoff-doc", "HANDOFF.md", "--json"])

      expect(handoff_command).to have_received(:new).with(name: "myapp", pane: "2", handoff_doc: "HANDOFF.md",
        handoff_prompt: nil, wait: false, json: true)
    end

    it "passes --wait to handoff new" do
      cli, = build_test_cli(handoff_command: handoff_command)

      cli.run(["handoff", "new", "myapp", "--pane", "2", "--handoff-prompt", "Go", "--wait"])

      expect(handoff_command).to have_received(:new).with(name: "myapp", pane: "2", handoff_doc: nil,
        handoff_prompt: "Go", wait: true, json: false)
    end

    it "reports a Workspace::Error from handoff new as a JSON error with --json" do
      allow(handoff_command).to receive(:new).and_raise(Workspace::Error, "no agent daemon for 'myapp'")
      cli, output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "new", "myapp", "--handoff-doc", "a", "--json"]) }
        .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "error", "error" => "no agent daemon for 'myapp'")
    end

    it "requires --handoff-doc or --handoff-prompt for handoff new" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "new", "myapp"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Missing --handoff-doc or --handoff-prompt")
      expect(handoff_command).not_to have_received(:new)
    end

    it "raises a usage error for an unknown handoff subcommand" do
      cli, _, error_output = build_test_cli(handoff_command: handoff_command)

      expect { cli.run(["handoff", "bogus"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("Usage: workspace handoff")
    end

    it "lists handoff in the main help" do
      cli, output = build_test_cli
      cli.run(["help"])
      expect(output.string).to include("handoff         Check context usage and hand off to a fresh conversation")
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
      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {"myproject" => "go"})
      expect(hook_runner.runs).to include(project: "myproject", event: "post_launch", env: {})
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

      expect(launch_command).to have_received(:call).with(["myproject"], reattach: false, prompts: {"myproject" => "go"}, prompt_timeout: 90.0)
    end

    it "passes --prompt-timeout through to start" do
      start_command = double("start", call: {exit_code: 0, prompt_failures: {}})
      cli, = build_test_cli(start_command: start_command)

      cli.run(["start", "--prompt", "go", "--prompt-timeout", "2m", "PROJ-1"])

      expect(start_command).to have_received(:call).with("PROJ-1", prompt: "go", prompt_timeout: 120.0,
        base: nil, yes: false, json: false)
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
      error = Workspace::Error.new("Unknown project 'x'", code: "unknown_workspace", details: {"name" => "x"})
      status, out, err = run_failing(["parent", "x", "--json"], error)
      expect(status).to eq(1)
      expect(err).to eq("")
      expect(JSON.parse(out)).to eq(
        "schema_version" => 1, "ok" => false, "error" => "Unknown project 'x'",
        "code" => "unknown_workspace", "details" => {"name" => "x"}
      )
    end

    it "includes retry when the error has one" do
      error = Workspace::UnsavedWorkError.new("unsaved", unsaved: {changed_files: 2, unpushed_commits: 0, branch: "b"})
      _, out, _ = run_failing(["parent", "--json"], error)
      expect(JSON.parse(out)).to include("code" => "unsaved_work", "retry" => {"flags" => ["--force"], "destructive" => true})
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

    it "shows project config" do
      project_settings = CLITestHelpers::FakeProjectSettings.new
      project_settings.define_singleton_method(:load) { |_name| {"hooks" => {"post_launch" => "echo hi"}} }
      project_settings.define_singleton_method(:project_config_path) { |name| "/tmp/workspace/projects/#{name}.yml" }

      cli, output, _ = build_test_cli(project_settings: project_settings)
      cli.run(["config", "myproject"])

      expect(output.string).to include("post_launch")
      expect(output.string).to include("echo hi")
    end

    it "shows global config with --global" do
      project_settings = CLITestHelpers::FakeProjectSettings.new
      project_settings.define_singleton_method(:load_global) { {"layouts" => {"equal" => "even-vertical"}} }
      project_settings.define_singleton_method(:global_config_path) { "/tmp/workspace/config.yml" }

      cli, output, _ = build_test_cli(project_settings: project_settings)
      cli.run(["config", "--global"])

      expect(output.string).to include("equal")
      expect(output.string).to include("even-vertical")
    end

    it "reports when no project config found" do
      cli, output, _ = build_test_cli
      cli.run(["config", "nonexistent"])

      expect(output.string).to include("no config found for 'nonexistent'")
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
  end

  describe "#run with config set/get/unset" do
    it "dispatches set to config_command with key, value, and cwd" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      cli, _, _ = build_test_cli(config_command: config_command, working_dir: "/tmp/some-project")

      cli.run(["config", "set", "dev.up", "./start-dev"])

      expect(config_command.calls).to eq([{action: :set, key: "dev.up", value: "./start-dev", project: nil, cwd: "/tmp/some-project"}])
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

      expect(config_command.calls).to eq([{action: :get, key: "dev.up", project: nil, cwd: "/tmp/some-project"}])
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

      expect(config_command.calls).to eq([{action: :unset, key: "dev.ready", project: nil, cwd: "/tmp/some-project"}])
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

    it "surfaces a Workspace::UsageError from config_command as exit 1" do
      config_command = CLITestHelpers::FakeConfigCommand.new
      config_command.define_singleton_method(:set) { |*| raise Workspace::UsageError, "Unknown config key 'dev.bogus'." }
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

    describe "info" do
      it "reports Alfred not installed when workflows dir missing" do
        cli, output, _ = build_test_cli
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with(include("Alfred.alfredpreferences/workflows")).and_return(false)
        cli.run(["alfred", "info"])
        expect(output.string).to include("Alfred is not installed")
      end
    end

    describe "uninstall" do
      it "reports not installed when workflow not found" do
        cli, output, _ = build_test_cli
        allow(Dir).to receive(:glob).and_call_original
        allow(Dir).to receive(:glob).with(include("Alfred.alfredpreferences/workflows")).and_return([])
        cli.run(["alfred", "uninstall"])
        expect(output.string).to include("not installed")
      end
    end
  end

  describe "#run with relaunch" do
    it "exits 1 when no active projects" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["relaunch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("No active workspace projects to relaunch")
      expect(error_output.string).not_to include("Error:")
    end

    it "kills and relaunches active projects" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"unique_id" => "uid2"}

      tmux = CLITestHelpers::FakeTmux.new
      allow(tmux).to receive(:sessions).and_return(["proj1", "proj2"])

      iterm = CLITestHelpers::FakeITerm.new

      window_manager = CLITestHelpers::FakeWindowManager.new
      allow(window_manager).to receive(:iterm_windows).and_return({123 => "workspace-proj1", 124 => "workspace-proj2"})

      cli, output, _ = build_test_cli(state: state, tmux: tmux, iterm: iterm, window_manager: window_manager)
      allow(cli).to receive(:sleep)

      cli.run(["relaunch"])

      expect(output.string).to include("Will relaunch: proj1, proj2")
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

      expect(error_output.string).to include("Audit trail: locks.jsonl next to locks.json")
    end

    it "lists instructions and idle takeover in lock help" do
      cli, output, _ = build_test_cli(lock_command: CLITestHelpers::FakeLockCommand.new)

      cli.run(["lock", "help"])

      expect(output.string).to include("instructions [<name>]", "locks.idle_grace", "3   this agent's hold was taken over")
    end

    describe "dev" do
      let(:dev_command) { CLITestHelpers::FakeDevCommand.new }

      it "dispatches up with --wait, --force, --no-ready and --max-wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "up", "--wait", "--force", "--no-ready", "--max-wait", "30"])

        expect(dev_command.calls).to eq([{action: :up, wait: true, takeover: true, ready: false, max_wait: 30.0}])
      end

      it "dispatches up with --takeover, the deprecated alias for --force" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "up", "--takeover"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: true, ready: true, max_wait: nil}])
      end

      it "defaults up to no wait, no takeover, and a ready check" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "up"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: nil}])
      end

      it "passes --max-wait alone through as given, leaving the command to imply --wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "up", "--max-wait", "5"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: 5.0}])
      end

      it "accepts durations like '9m' for up --max-wait" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "up", "--max-wait", "9m"])

        expect(dev_command.calls).to eq([{action: :up, wait: false, takeover: false, ready: true, max_wait: 540.0}])
      end

      it "raises a usage error naming --max-wait for an unparsable up --max-wait" do
        cli, _, error_output = build_test_cli(dev_command: dev_command)

        expect { cli.run(["dev", "up", "--max-wait", "nonsense"]) }
          .to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("--max-wait")
        expect(dev_command.calls).to be_empty
      end

      it "exits with up's exit code" do
        dev_command.result = {exit_code: 6}
        cli, _, _ = build_test_cli(dev_command: dev_command)

        expect { cli.run(["dev", "up"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(6) }
      end

      it "dispatches down with --force, status, and the hidden __run" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "down", "--force"])
        cli.run(["dev", "status"])
        cli.run(["dev", "__run", "--wait"])

        expect(dev_command.calls).to eq(
          [{action: :down, force: true}, {action: :status, json: false}, {action: :run, wait: true}]
        )
      end

      it "dispatches status with --json" do
        cli, _, _ = build_test_cli(dev_command: dev_command)

        cli.run(["dev", "status", "--json"])

        expect(dev_command.calls).to eq([{action: :status, json: true}])
      end

      it "emits the JSON error contract for `dev status` when --json appears after a bad flag" do
        cli, output, _ = build_test_cli(dev_command: dev_command)

        expect { cli.run(["dev", "status", "--bogus", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(Workspace::Commands::Dev::JSON_SCHEMA_VERSION)
        expect(parsed["error"]).to be_a(String)
      end

      it "prints dev help without a subcommand and rejects unknown ones" do
        cli, output, _ = build_test_cli(dev_command: dev_command)

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

    it "dispatches to agent_command with --name and --wc-socket" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      cli, _, _ = build_test_cli(agent_command: agent_command)
      cli.run(["agentd", "--name", "myapp", "--wc-socket", "/tmp/wc.sock"])

      expect(agent_command.calls).to eq([{name: "myapp", wc_socket: "/tmp/wc.sock"}])
    end

    it "accepts a positional project name for agentd" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      cli, _, _ = build_test_cli(agent_command: agent_command)
      cli.run(["agentd", "myapp", "--force"])

      expect(agent_command.calls).to eq([{name: "myapp", wc_socket: nil}])
    end

    it "exits 1 when the agent refuses to start" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      agent_command.result = false
      cli, _, _ = build_test_cli(agent_command: agent_command)

      expect { cli.run(["agentd", "--name", "myapp"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
    end

    it "starts the daemon for legacy agent --name, with a deprecation warning" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      cli, _, error_output = build_test_cli(agent_command: agent_command)

      cli.run(["agent", "--name", "myapp"])

      expect(agent_command.calls).to eq([{name: "myapp", wc_socket: nil}])
      expect(error_output.string).to include("deprecated; use `workspace agentd`")
    end

    it "starts the daemon for bare agent with empty args (installed templates)" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      project_detector = instance_double(Workspace::ProjectDetector, detect: "proj")
      cli, _, error_output = build_test_cli(agent_command: agent_command, project_detector: project_detector)

      cli.run(["agent"])

      expect(agent_command.calls).to eq([{name: "proj", wc_socket: nil}])
      expect(error_output.string).to include("deprecated; use `workspace agentd`")
    end

    it "shows the umbrella help for agent help" do
      cli, output, _ = build_test_cli

      cli.run(["agent", "help"])

      expect(output.string).to include("Usage: workspace agent <subcommand>")
      expect(output.string).to include("workspace agentd")
    end

    describe "#run agent run" do
      it "sends the joined positional args as the prompt" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--work-item", "WC-42", "Add", "OAuth", "support", "--dry-run"])

        expect(output.string).to include('"work_item_ref": "WC-42"')
        expect(output.string).to include("Add OAuth support")
        expect(output.string).to include('"type": "command"')
      end

      it "defaults --work-item to a random UUID" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "Do the thing", "--dry-run"])

        expect(output.string).to match(/"work_item_ref": "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"/)
      end

      it "supports -- for a prompt starting with a dash" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--dry-run", "--", "--verbose prompt"])

        expect(output.string).to include("--verbose prompt")
      end

      it "errors when the prompt is missing" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agent", "run", "--name", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Missing prompt")
      end

      it "sends a prompt containing the word help" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "--dry-run", "help", "me", "refactor", "login"])

        expect(output.string).to include("help me refactor login")
      end

      it "dispatches to run when a value-taking flag leads" do
        cli, output = build_test_cli

        cli.run(["agent", "--name", "myapp", "run", "Add OAuth support", "--dry-run"])

        expect(output.string).to include("Add OAuth support")
      end

      it "dry-runs when a -- terminator leads the subcommand" do
        cli, output = build_test_cli

        cli.run(["agent", "--", "run", "--name", "myapp", "x", "--dry-run"])

        expect(output.string).to include('"type": "command"')
        expect(output.string).to include('"body"')
        expect(output.string).to include("(dry-run: not sent)")
        expect(output.string).not_to include("--dry-run")
      end

      it "uses an agent-run dispatch_id prefix" do
        cli, output = build_test_cli

        cli.run(["agent", "run", "--name", "myapp", "Do the thing", "--dry-run"])

        expect(output.string).to match(/"dispatch_id": "agent-run-[0-9a-f]{8}"/)
      end

      it "errors with a hint when a flag-looking word is parsed as an option" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agent", "run", "--name", "myapp", "fix", "the", "--force", "flag", "handling"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("pass it after --")
      end
    end

    describe "#run agent unknown word" do
      it "errors instead of starting a daemon named after the word" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, _, error_output = build_test_cli(agent_command: agent_command)

        expect { cli.run(["agent", "status"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unknown agent subcommand: status")
        expect(error_output.string).to include("workspace agentd")
        expect(agent_command.calls).to be_empty
      end
    end

    describe "#run agentd --ensure" do
      let(:ensure_command) do
        Class.new do
          attr_reader :calls
          attr_accessor :result

          def initialize
            @calls = []
            @result = Workspace::Commands::EnsureAgent::Result.new(:started)
          end

          def call(name:, wc_socket: nil)
            @calls << {name: name, wc_socket: wc_socket}
            @result
          end
        end.new
      end

      it "ensures instead of running the daemon, passing --wc-socket through" do
        agent_command = CLITestHelpers::FakeAgentCommand.new
        cli, output, _ = build_test_cli(agent_command: agent_command, ensure_agent_command: ensure_command)

        cli.run(["agentd", "--ensure", "myapp", "--wc-socket", "/tmp/wc.sock"])

        expect(ensure_command.calls).to eq([{name: "myapp", wc_socket: "/tmp/wc.sock"}])
        expect(agent_command.calls).to be_empty
        expect(output.string).to eq("Started agentd for myapp\n")
      end

      it "says so and exits 0 when one is already running" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:running)
        cli, output, _ = build_test_cli(ensure_agent_command: ensure_command)

        cli.run(["agentd", "--ensure", "--name", "myapp"])

        expect(output.string).to eq("agentd for myapp is already running\n")
      end

      it "exits 1 with the reason when the daemon can't be started" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:failed, "it did not answer within 5s")
        cli, _, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(error_output.string).to include("Could not start the agent daemon for myapp: it did not answer within 5s")
      end

      it "exits 1 quietly when the pipeline config was invalid (the warning is already printed)" do
        ensure_command.result = Workspace::Commands::EnsureAgent::Result.new(:invalid_config)
        cli, output, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "myapp"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }
        expect(output.string).to eq("")
        expect(error_output.string).to eq("")
      end

      it "refuses to combine --ensure with --force" do
        cli, _, error_output = build_test_cli(ensure_agent_command: ensure_command)

        expect { cli.run(["agentd", "--ensure", "--force", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("--ensure and --force can't be combined")
        expect(ensure_command.calls).to be_empty
      end
    end

    describe "#run agentd" do
      it "errors on an unexpected argument" do
        cli, _, error_output = build_test_cli

        expect { cli.run(["agentd", "myapp", "extra"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unexpected argument: extra")
      end
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

  describe "#run with parent" do
    it "dispatches to parent_command#call with no options" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent"])

      expect(parent_command.calls).to eq([{name: nil, path: false, json: false}])
    end

    it "dispatches with a given project name" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "app.worktree-login"])

      expect(parent_command.calls).to eq([{name: "app.worktree-login", path: false, json: false}])
    end

    it "dispatches with --path" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--path"])

      expect(parent_command.calls).to eq([{name: nil, path: true, json: false}])
    end

    it "dispatches with --json" do
      parent_command = CLITestHelpers::FakeParentCommand.new
      cli, _, _ = build_test_cli(parent_command: parent_command)

      cli.run(["parent", "--json"])

      expect(parent_command.calls).to eq([{name: nil, path: false, json: true}])
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
            define_method(:kill_session) { |name| live.delete(name) }
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

    it "prints the same help for `projects list --help`" do
      cli.run(["projects", "list", "--help"])

      expect(output.string).to include("A project is a repository's main checkout plus its linked git worktrees.")
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

  describe "pipeline" do
    # Routes the pipeline paths into a tmpdir so specs never touch the real ones.
    let(:tmpdir) { Dir.mktmpdir("ws-pipeline", "/tmp") }
    let(:config) do
      dir = tmpdir
      Class.new(Workspace::Config) do
        define_method(:pipeline_state_path) { |name| File.join(dir, "#{name}-pipeline.json") }
        define_method(:agent_socket_path) { |name| File.join(dir, "#{name}.sock") }
      end.new
    end

    after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

    def write_state(project, entries)
      File.write(config.pipeline_state_path(project), JSON.generate(entries))
    end

    # Answers one connection the way a live agent would, and records what it got.
    def with_fake_agent(project, reply)
      server = UNIXServer.new(config.agent_socket_path(project))
      received = []
      accepter = Thread.new do
        client = server.accept
        received << JSON.parse(client.gets)
        client.puts(reply.to_json)
        client.close
      rescue IOError, Errno::EBADF
        nil
      end
      yield received
      accepter.join(2)
      received
    ensure
      server.close
      accepter&.kill
    end

    describe "status" do
      it "says so when the project has no state file at all" do
        cli, output, = build_test_cli(config: config)
        cli.run(["pipeline", "status", "myapp"])
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "says so when the project has a state file with nothing in it" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp", {})
        cli.run(["pipeline", "status", "myapp"])
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "lists each in-flight work item with its pane and phase" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer"},
          "WC-43" => {"work_item_ref" => "WC-43", "pane_index" => 0, "phase" => "researcher"})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("WORK ITEM  PANE  STAGE")
        expect(output.string).to include("WC-42  pane 1  implementer")
        expect(output.string).to include("WC-43  pane 0  researcher")
      end

      it "exits 1 without a project" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "status"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Usage: workspace pipeline status")
      end

      it "shows a stage's deadline in local time plus how long remains" do
        now = Time.utc(2026, 9, 27, 12, 0, 0)
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config, clock: -> { now })
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("(in 12m)")
        expect(output.string).to include(deadline.localtime.strftime("%H:%M"))
      end

      it "shows an overdue stage's deadline as overdue" do
        now = Time.utc(2026, 9, 27, 12, 15, 0)
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config, clock: -> { now })
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("(overdue 3m)")
      end

      it "shows '-' when the stage has no deadline" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer"})

        cli.run(["pipeline", "status", "myapp"])

        expect(output.string).to include("WC-42  pane 1  implementer  -")
      end

      it "leaves --json's deadline_at as raw ISO 8601 UTC" do
        deadline = Time.utc(2026, 9, 27, 12, 12, 0)
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1, "phase" => "implementer",
                      "deadline_at" => deadline.iso8601(3)})

        cli.run(["pipeline", "status", "myapp", "--json"])

        expect(JSON.parse(output.string)["entries"].first["deadline_at"]).to eq(deadline.iso8601(3))
      end

      it "treats an unreadable state file as empty rather than dying on it" do
        cli, output, error_output = build_test_cli(config: config)
        File.write(config.pipeline_state_path("myapp"), "{ truncated")

        cli.run(["pipeline", "status", "myapp"])

        expect(error_output.string).to include("Could not read myapp's pipeline state")
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "prints the entries as a JSON envelope for scripts" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
                      "pane_index" => 1, "phase" => "implementer"})

        cli.run(["pipeline", "status", "myapp", "--json"])

        expect(JSON.parse(output.string)).to eq({
          "schema_version" => 1, "ok" => true,
          "entries" => [
            {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
             "pane_index" => 1, "phase" => "implementer"}
          ]
        })
      end

      it "prints an empty entries array when nothing is in flight" do
        cli, output, = build_test_cli(config: config)
        cli.run(["pipeline", "status", "myapp", "--json"])
        expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => true, "entries" => []})
      end

      it "emits a JSON usage error when --json is passed without a project" do
        cli, output, = build_test_cli(config: config)
        expect { cli.run(["pipeline", "status", "--json"]) }.to raise_error(FakeSystemExit) { |e|
          expect(e.status).to eq(1)
        }
        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(1)
        expect(parsed["error"]).to be_a(String)
      end
    end

    describe "start" do
      it "hands the work item to the running agent" do
        cli, output, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true}) do
          cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first).to include(
          "type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42"
        )
        expect(received.first["dispatch_id"]).to start_with("manual-")
        expect(output.string).to include("Sent WC-42 into myapp's pipeline")
      end

      it "exits 1 when no agent is listening" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("No agent is running for myapp")
        expect(error_output.string).to include("workspace agentd --name myapp")
      end

      it "exits 1 when the work item is missing" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp"]) }.to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Missing project or --work-item")
      end

      it "exits 1 when the agent refuses the work item" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "wrong_workspace"}) do
          expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("refused the work item: wrong_workspace")
      end

      it "exits 1 on a stray extra argument rather than silently ignoring it" do
        cli, _, error_output = build_test_cli(config: config)
        expect { cli.run(["pipeline", "start", "myapp", "extra", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        expect(error_output.string).to include("Unexpected arguments: extra")
      end

      it "exits 1 when the agent hangs up without replying" do
        cli, _, error_output = build_test_cli(config: config)
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new { server.accept.close }

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        accepter.join(2)

        expect(error_output.string).to include("closed the connection without replying")
        server.close
      end

      it "exits 1 with the same message when the write races the daemon's close (EPIPE after connect)" do
        cli, _, error_output = build_test_cli(config: config)
        socket = instance_double(UNIXSocket, close: nil)
        allow(socket).to receive(:puts).and_raise(Errno::EPIPE)
        allow(UNIXSocket).to receive(:open).and_return(socket)

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)

        expect(error_output.string).to include("closed the connection without replying")
        expect(error_output.string).not_to include("No agent is running")
      end

      it "exits 1 when the agent's reply is not readable" do
        cli, _, error_output = build_test_cli(config: config)
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new do
          client = server.accept
          client.gets
          client.puts("garbage")
          client.close
        end

        expect { cli.run(["pipeline", "start", "myapp", "--work-item", "WC-42"]) }
          .to raise_error(FakeSystemExit)
        accepter.join(2)

        expect(error_output.string).to include("Unreadable reply from the agent for myapp")
        server.close
      end
    end

    describe "advance" do
      it "asks the agent to interrupt the stage with the completion sentinel" do
        cli, output, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first).to include(
          "type" => "inject", "work_item_ref" => "WC-42", "interrupt" => true
        )
        expect(received.first["body"]).to include(Workspace::SentinelPoller::SENTINEL)
        expect(output.string).to include("Nudged myapp/WC-42 to advance")
      end

      it "carries the running stage's token so the agent's watch accepts it" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "sentinel_token" => "a1b2c3d4"})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(Shellwords.split(received.first["body"])).to eq(["echo", "WORKSPACE_DONE:a1b2c3d4 manual advance"])
      end

      it "sends a tokenless sentinel for a stage recorded before stages had tokens" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "pane_index" => 1})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(Shellwords.split(received.first["body"])).to eq(["echo", "WORKSPACE_DONE: manual advance"])
      end

      it "escapes the body so it cannot break out of the echo it is typed into" do
        cli, _, = build_test_cli(config: config)

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42",
            "--body", "it's done'; rm -rf /tmp/nope; echo '"])
        end

        # One shell word: the quotes and semicolons reach the pane as text.
        expect(Shellwords.split(received.first["body"])).to eq([
          "echo", "#{Workspace::SentinelPoller::SENTINEL} it's done'; rm -rf /tmp/nope; echo '"
        ])
      end

      it "exits 1 when the agent refuses" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "no_active_pipeline"}) do
          expect { cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("no_active_pipeline")
      end

      it "sends the running stage's token as expected_token" do
        cli, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42", "sentinel_token" => "a1b2c3d4"})

        received = with_fake_agent("myapp", {"ok" => true, "queued_for_pane" => 1}) do
          cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"])
        end

        expect(received.first["expected_token"]).to eq("a1b2c3d4")
      end

      it "exits 1 with a clear message when the stage moved on before the advance landed" do
        cli, _, error_output = build_test_cli(config: config)

        with_fake_agent("myapp", {"ok" => false, "error" => "stale_token"}) do
          expect { cli.run(["pipeline", "advance", "myapp", "--work-item", "WC-42"]) }
            .to raise_error(FakeSystemExit)
        end

        expect(error_output.string).to include("The stage moved on before the advance landed; run 'workspace pipeline advance' again")
      end
    end

    describe "reset" do
      it "clears the state file when no agent is running" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42"})

        cli.run(["pipeline", "reset", "myapp"])

        expect(File.exist?(config.pipeline_state_path("myapp"))).to be false
        expect(output.string).to include("Cleared pipeline state for myapp")
      end

      it "refuses while the agent is still running so the two cannot disagree" do
        cli, _, error_output = build_test_cli(config: config)
        write_state("myapp", "WC-42" => {"work_item_ref" => "WC-42"})
        server = UNIXServer.new(config.agent_socket_path("myapp"))
        accepter = Thread.new do
          loop { server.accept.close }
        rescue IOError, Errno::EBADF
          nil
        end

        expect { cli.run(["pipeline", "reset", "myapp"]) }.to raise_error(FakeSystemExit)

        expect(error_output.string).to include("before resetting its pipeline state")
        expect(File.exist?(config.pipeline_state_path("myapp"))).to be true
        server.close
        accepter.kill
      end
    end

    it "prints help for an unknown subcommand" do
      cli, _, error_output = build_test_cli(config: config)
      expect { cli.run(["pipeline", "nonsense"]) }.to raise_error(FakeSystemExit)
      expect(error_output.string).to include("workspace pipeline <subcommand>")
    end

    it "prints help with no subcommand" do
      cli, output, = build_test_cli(config: config)
      cli.run(["pipeline"])
      expect(output.string).to include("workspace pipeline <subcommand>")
    end
  end

  describe "sessions" do
    it "explains the LOCK column legend in its help" do
      cli, _, error_output = build_test_cli

      expect { cli.run(["sessions"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(error_output.string).to include("every lock", "locks array")
    end

    it "exits 1 without raising when --json and no agent daemon is listening" do
      config = instance_double(Workspace::Config, agent_socket_path: "/nonexistent/socket")
      cli, output, = build_test_cli(config: config, project_detector: instance_double(Workspace::ProjectDetector, detect: "proj"))

      expect { cli.run(["sessions", "--json"]) }.to raise_error(FakeSystemExit) { |e| expect(e.status).to eq(1) }

      expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "no_daemon", "error" => "No agent daemon for 'proj'.\nStart one with:  workspace agentd proj")
    end

    it "forwards --worktrees to the sessions command" do
      sessions_command = instance_double(Workspace::Commands::Sessions)
      cli, = build_test_cli(sessions_command: sessions_command, project_detector: instance_double(Workspace::ProjectDetector, detect: "proj"))

      expect(sessions_command).to receive(:call)
        .with(name: "proj", json: false, watch: false, interval: 2, worktrees: true)
        .and_return({exit_code: 0})

      cli.run(["sessions", "--worktrees"])
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
      cli, = build_test_cli(state: state, launch_command: launch_command, stop_command: double("stop", call: []))
      allow(cli).to receive(:sleep)

      cli.run(["relaunch"])

      expect(launch_command).to have_received(:call).with(["proj1"], reattach: false, prompts: {})
      expect(launch_command).to have_received(:call).with(["proj2"], reattach: false, prompts: {}, headless: true)
    end

    it "still relaunches headless projects when the windowed batch fails, and exits 1 overall" do
      state = CLITestHelpers::FakeState.new
      state["proj1"] = {"unique_id" => "uid1"}
      state["proj2"] = {"headless" => true}

      calls = []
      launch_command = Object.new
      launch_command.define_singleton_method(:call) do |projects, **opts|
        calls << [projects, opts]
        opts[:headless] ? {exit_code: 0, prompt_failures: {}} : {exit_code: 1, prompt_failures: {"proj1" => "window never appeared"}}
      end

      cli, = build_test_cli(state: state, launch_command: launch_command, stop_command: double("stop", call: []))
      allow(cli).to receive(:sleep)

      expect { cli.run(["relaunch"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }

      expect(calls).to eq([
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
end
