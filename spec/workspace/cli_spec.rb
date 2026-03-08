require "stringio"

module CLITestHelpers
  class FakeState
    def initialize
      @data = {}
    end

    def load
      self
    end

    def save
    end

    def [](key)
      @data[key]
    end

    def []=(key, value)
      @data[key] = value
    end

    def delete(key)
      @data.delete(key)
    end

    def keys
      @data.keys
    end

    def empty?
      @data.empty?
    end

    def each(&block)
      @data.each(&block)
    end

    def dig(*keys)
      @data.dig(*keys)
    end

    def to_h
      @data.dup
    end
  end

  class FakeITerm
    def session_map = {}
    def find_existing_sessions(_state, **_opts) = {}
    def find_launcher_window_id(_state, **_opts) = nil
    def create_launcher_panes(_projects, _commands, **_opts) = {}
    def relaunch_in_session(_uid, _cmd) = "ok"
  end

  class FakeWindowManager
    def window_exists?(_wid) = false
    def find_window_by_title(_title) = nil
    def find_window_for_project(_project) = nil
    def focus_by_id(_wid) = true
    def shake_by_id(_wid) = true
    def live_window_ids = Set.new
    def set_window_bounds(_wid, _x, _y, _w, _h) = nil
    def all_window_bounds(_wids) = {}
    def close_window(_wid) = nil
    def window_titles = []
  end

  class FakeTmux
    def sessions = []
    def start_server = nil
    def kill_session(_name) = nil
    def rename_window(_session, _index, _name) = nil
    def resize_pane(_session, _pane, _size) = true
    def capture_layout(_session, **_opts) = "layout-string"
    def apply_layout(_session, _layout, **_opts) = true

    def command_for(_project, **_opts)
      "tmuxinator start test --attach"
    end

    def session_name_for(config)
      config
    end
  end

  class FakeProjectConfig
    def resolve_project_arg(arg)
      [arg, nil]
    end

    def create(name, _root)
      name
    end

    def create_worktree(_pn, _wn, _wp, _bn)
      "test-config"
    end

    def config_path_for(name)
      "~/.config/tmuxinator/workspace.#{name}.yml"
    end

    def exists?(_name)
      true
    end

    def available_projects
      ["project-a", "project-b"]
    end

    def project_root_for(_name)
      nil
    end
  end

  class FakeWindowLayout
    def arrange(_ids) = nil
    def tile(_ids) = nil
    def calculate_positions(**_opts) = []
  end

  class FakeDoctor
    def run
    end
  end

  class FakeProjectSettings
    def load(_project_name) = {}
    def save(_project_name, _data) = nil
    def load_global = {}
    def ensure_exists(_project_name) = nil
    def hook_for(_project_name, _event) = nil
    def layouts_for(_project_name) = {}
    def project_config_path(name) = "/tmp/workspace/projects/#{name}.yml"
    def global_config_path = "/tmp/workspace/config.yml"
  end

  class FakeHookRunner
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(project, event, env: {}, chdir: nil)
      @runs << {project: project, event: event, env: env, chdir: chdir}
      true
    end
  end
end

RSpec.describe Workspace::CLI do
  def build_test_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, **overrides)
    config = overrides[:config] || Workspace::Config.new
    state = overrides[:state] || CLITestHelpers::FakeState.new
    iterm = overrides[:iterm] || CLITestHelpers::FakeITerm.new
    window_manager = overrides[:window_manager] || CLITestHelpers::FakeWindowManager.new
    tmux = overrides[:tmux] || CLITestHelpers::FakeTmux.new
    git = overrides[:git] || Workspace::Git.new(output: output, input: input)
    project_config = overrides[:project_config] || CLITestHelpers::FakeProjectConfig.new
    window_layout = overrides[:window_layout] || CLITestHelpers::FakeWindowLayout.new
    doctor = overrides[:doctor] || CLITestHelpers::FakeDoctor.new
    project_settings = overrides[:project_settings] || CLITestHelpers::FakeProjectSettings.new
    hook_runner = overrides[:hook_runner] || CLITestHelpers::FakeHookRunner.new

    cli = Workspace::CLI.new(
      config: config,
      state: state,
      iterm: iterm,
      window_manager: window_manager,
      tmux: tmux,
      git: git,
      project_config: project_config,
      window_layout: window_layout,
      doctor: doctor,
      project_settings: project_settings,
      hook_runner: hook_runner,
      output: output,
      error_output: error_output,
      input: input
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
      expect { cli.run(["bogus"]) }.to raise_error(SystemExit) { |e|
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
      expect { cli.run(["doctor"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Error: something broke")
    end

    it "exits 1 when a Workspace::UsageError is raised" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["launch"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace launch")
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

  describe "#run with list-projects" do
    it "lists available projects" do
      cli, output, _ = build_test_cli
      cli.run(["list-projects"])
      expect(output.string).to include("project-a")
      expect(output.string).to include("project-b")
    end
  end

  describe "#run with status" do
    it "shows no tracked sessions when state is empty" do
      cli, output, _ = build_test_cli
      cli.run(["status"])
      expect(output.string).to include("No tracked sessions.")
    end
  end

  describe "#run with list" do
    it "shows no active projects when state is empty" do
      cli, output, _ = build_test_cli
      cli.run(["list"])
      expect(output.string).to include("No active projects.")
    end

    it "lists projects whose window IDs are live" do
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
    it "exits 1 when no project specified and no marker file found" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["stop"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("No project specified")
    end
  end

  describe "#run with resize" do
    it "exits 1 when missing arguments" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["resize"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace resize")
    end

    it "exits 1 when missing pane spec" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["resize", "myproject"]) }.to raise_error(SystemExit) { |e|
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
      expect { cli.run(["layout", "bogus"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown layout subcommand: bogus")
    end

    it "exits 1 when save has no project" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["layout", "save"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Usage: workspace layout")
    end
  end

  describe "#run with config" do
    it "exits 1 when no project specified and not --global" do
      cli, _, error_output = build_test_cli
      expect { cli.run(["config"]) }.to raise_error(SystemExit) { |e|
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
      expect { cli.run(["alfred", "bogus"]) }.to raise_error(SystemExit) { |e|
        expect(e.status).to eq(1)
      }
      expect(error_output.string).to include("Unknown alfred subcommand: bogus")
    end

    describe "install" do
      it "raises error when Alfred is not installed" do
        config = Workspace::Config.new(workspace_dir: "/test/workspace")
        cli, _, _ = build_test_cli(config: config)
        expect { cli.run(["alfred", "install"]) }.to raise_error(SystemExit) { |e|
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
      expect { cli.run(["relaunch"]) }.to raise_error(SystemExit) { |e|
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
      allow(iterm).to receive(:find_window_by_title).and_return("123")

      cli, output, _ = build_test_cli(state: state, tmux: tmux, iterm: iterm)
      allow(cli).to receive(:sleep)

      cli.run(["relaunch"])

      expect(output.string).to include("Will relaunch: proj1, proj2")
    end
  end
end
