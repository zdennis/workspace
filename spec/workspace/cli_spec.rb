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

    kill_command = overrides[:kill_command] || Workspace::Commands::Kill.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, output: output, error_output: error_output)
    launch_command = overrides[:launch_command] || Workspace::Commands::Launch.new(state: state, iterm: iterm, window_manager: window_manager, tmux: tmux, project_config: project_config, window_layout: window_layout, output: output, error_output: error_output)
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(git: git, project_config: project_config, launch_command: launch_command, output: output, input: input)
    stop_command = overrides[:stop_command] || Workspace::Commands::Stop.new(git: git, project_config: project_config, kill_command: kill_command, project_detector: project_detector, output: output, input: input)
    focus_command = overrides[:focus_command] || Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = overrides[:tile_command] || Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = overrides[:layout_command] || Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = overrides[:resize_command] || Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    init_command = overrides[:init_command] || Workspace::Commands::Init.new(config: config, output: output, error_output: error_output)

    cli = Workspace::CLI.new(
      config: config,
      state: state,
      project_config: project_config,
      window_manager: window_manager,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      project_detector: project_detector,
      launch_command: launch_command,
      kill_command: kill_command,
      start_command: start_command,
      stop_command: stop_command,
      focus_command: focus_command,
      tile_command: tile_command,
      layout_command: layout_command,
      resize_command: resize_command,
      init_command: init_command,
      logger: logger,
      output: output,
      error_output: error_output,
      exit_handler: overrides[:exit_handler] || FakeExitHandler,
      input: input,
      working_dir: working_dir
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

    it "exits 1 and prints error for unknown subcommand" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["bogus"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown subcommand: bogus")
    end

    it "exits 1 when a Workspace::Error is raised" do
      doctor = CLITestHelpers::FakeDoctor.new
      doctor.define_singleton_method(:run) do
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
      expect(result).to include("project-a", "project-b")
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

    it "prunes gone sessions and shows only alive ones" do
      state = CLITestHelpers::FakeState.new
      state["alive-proj"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["dead-proj"] = {"unique_id" => "uid2", "iterm_window_id" => 200}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100]) }

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["status"])

      expect(output.string).to include("alive-proj")
      expect(output.string).to include("window_id=100")
      expect(output.string).to include("[alive]")
      expect(output.string).not_to include("dead-proj")
      expect(state.keys).to eq(["alive-proj"])
    end

    it "shows no tracked sessions after all are pruned" do
      state = CLITestHelpers::FakeState.new
      state["dead-proj"] = {"unique_id" => "uid1", "iterm_window_id" => 200}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new }

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["status"])

      expect(output.string).to include("No tracked sessions.")
      expect(state).to be_empty
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

  describe "#run with list" do
    it "shows no active projects when state is empty" do
      cli, output, _ = build_test_cli
      cli.run(["list"])
      expect(output.string).to include("No active projects. Run 'workspace list --all' to see available projects.")
    end

    it "lists projects whose window IDs are live and prunes dead ones" do
      state = CLITestHelpers::FakeState.new
      state["proj-a"] = {"unique_id" => "uid1", "iterm_window_id" => 100}
      state["proj-b"] = {"unique_id" => "uid2", "iterm_window_id" => 200}
      state["proj-c"] = {"unique_id" => "uid3", "iterm_window_id" => 300}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new([100, 300]) }

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["list"])

      expect(output.string).to include("proj-a")
      expect(output.string).not_to include("proj-b")
      expect(output.string).to include("proj-c")
      expect(state.keys).to contain_exactly("proj-a", "proj-c")
    end

    it "shows no active projects after all are pruned" do
      state = CLITestHelpers::FakeState.new
      state["dead-proj"] = {"unique_id" => "uid1", "iterm_window_id" => 999}

      wm = CLITestHelpers::FakeWindowManager.new
      wm.define_singleton_method(:live_window_ids) { Set.new }

      cli, output, _ = build_test_cli(state: state, window_manager: wm)
      cli.run(["list"])

      expect(output.string).to include("No active projects. Run 'workspace list --all' to see available projects.")
      expect(state).to be_empty
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
  end

  describe "#run with doctor" do
    it "delegates to the doctor collaborator" do
      doctor = CLITestHelpers::FakeDoctor.new
      called = false
      doctor.define_singleton_method(:run) { called = true }

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
end
