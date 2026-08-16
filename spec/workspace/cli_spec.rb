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
    start_command = overrides[:start_command] || Workspace::Commands::Start.new(git: git, project_config: project_config, project_settings: project_settings, launch_command: launch_command, output: output, input: input)
    stop_command = overrides[:stop_command] || Workspace::Commands::Stop.new(git: git, project_config: project_config, project_settings: project_settings, kill_command: kill_command, project_detector: project_detector, output: output, input: input)
    focus_command = overrides[:focus_command] || Workspace::Commands::Focus.new(state: state, window_manager: window_manager, output: output)
    tile_command = overrides[:tile_command] || Workspace::Commands::Tile.new(state: state, window_manager: window_manager, window_layout: window_layout, output: output)
    layout_command = overrides[:layout_command] || Workspace::Commands::Layout.new(state: state, tmux: tmux, project_settings: project_settings, output: output)
    resize_command = overrides[:resize_command] || Workspace::Commands::Resize.new(tmux: tmux, layout_command: layout_command, output: output, error_output: error_output)
    init_command = overrides[:init_command] || Workspace::Commands::Init.new(config: config, output: output, error_output: error_output)
    repair_command = overrides[:repair_command] || CLITestHelpers::FakeRepairCommand.new
    cleanup_command = overrides[:cleanup_command] || Workspace::Commands::Cleanup.new(state: state, window_manager: window_manager, tmux: tmux, output: output, input: input)
    kill_command_for_prune = instance_double(Workspace::Commands::Kill)
    prune_command = overrides[:prune_command] || Workspace::Commands::Prune.new(state: state, project_config: project_config, project_settings: project_settings, git: git, kill_command: kill_command_for_prune, output: output, input: input)
    claude_command = overrides[:claude_command] || CLITestHelpers::FakeClaudeCommand.new
    lookup_command = overrides[:lookup_command] || Workspace::Commands::Lookup.new(project_config: project_config, output: output)
    update_pane_command = overrides[:update_pane_command] || CLITestHelpers::FakeUpdatePaneCommand.new
    run_command = overrides[:run_command] || CLITestHelpers::FakeRunCommand.new
    run_result_store = overrides[:run_result_store] || CLITestHelpers::FakeRunResultStore.new
    run_and_report_command = overrides[:run_and_report_command] || CLITestHelpers::FakeRunAndReportCommand.new
    capture_command = overrides[:capture_command] || CLITestHelpers::FakeCaptureCommand.new
    agent_command = overrides[:agent_command] || CLITestHelpers::FakeAgentCommand.new

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
      agent_command: agent_command,
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

    it "passes --pane N as integer to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "rake spec", "--pane", "2"])

      expect(run_command.calls.first[:pane]).to eq(2)
    end

    it "passes --pane bottom as :bottom to run_command" do
      run_command = CLITestHelpers::FakeRunCommand.new
      cli, _, _ = build_test_cli(run_command: run_command)
      cli.run(["run", "myproject", "rake spec", "--pane", "bottom"])

      expect(run_command.calls.first[:pane]).to eq(:bottom)
    end

    it "exits 1 for invalid --pane value" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["run", "myproject", "echo hi", "--pane", "invalid"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Invalid --pane value")
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

    it "dispatches to agent_command with --name and --wc-socket" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      cli, _, _ = build_test_cli(agent_command: agent_command)
      cli.run(["agent", "--name", "myapp", "--wc-socket", "/tmp/wc.sock"])

      expect(agent_command.calls).to eq([{name: "myapp", wc_socket: "/tmp/wc.sock"}])
    end

    it "exits 1 when the agent refuses to start" do
      agent_command = CLITestHelpers::FakeAgentCommand.new
      agent_command.result = false
      cli, _, _ = build_test_cli(agent_command: agent_command)

      expect { cli.run(["agent", "--name", "myapp"]) }.to raise_error(FakeSystemExit) { |e|
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

    it "passes --pane N as an integer" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--pane", "1"])

      expect(capture_command.calls.first[:pane]).to eq(1)
    end

    it "passes --pane bottom as :bottom" do
      capture_command = CLITestHelpers::FakeCaptureCommand.new
      cli, _, _ = build_test_cli(capture_command: capture_command)
      cli.run(["capture", "myproject", "--pane", "bottom"])

      expect(capture_command.calls.first[:pane]).to eq(:bottom)
    end

    it "exits 1 for an invalid --pane value" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["capture", "myproject", "--pane", "invalid"]) }.to raise_error(FakeSystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Invalid --pane value")
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

      it "treats an unreadable state file as empty rather than dying on it" do
        cli, output, error_output = build_test_cli(config: config)
        File.write(config.pipeline_state_path("myapp"), "{ truncated")

        cli.run(["pipeline", "status", "myapp"])

        expect(error_output.string).to include("Could not read myapp's pipeline state")
        expect(output.string).to include("No pipeline work in flight for myapp")
      end

      it "prints the entries as JSON for scripts" do
        cli, output, = build_test_cli(config: config)
        write_state("myapp",
          "WC-42" => {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
                      "pane_index" => 1, "phase" => "implementer"})

        cli.run(["pipeline", "status", "myapp", "--json"])

        expect(JSON.parse(output.string)).to eq([
          {"work_item_ref" => "WC-42", "dispatch_id" => "d-7a1",
           "pane_index" => 1, "phase" => "implementer"}
        ])
      end

      it "prints an empty JSON array when nothing is in flight" do
        cli, output, = build_test_cli(config: config)
        cli.run(["pipeline", "status", "myapp", "--json"])
        expect(JSON.parse(output.string)).to eq([])
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
        expect(error_output.string).to include("workspace agent --name myapp")
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
end
