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
    def focus_and_shake(_wid) = "ok"
    def set_window_bounds(_wid, _x, _y, _w, _h) = nil
    def close_window(_wid) = nil
    def window_titles = []
  end

  class FakeTmux
    def sessions = []
    def start_server = nil
    def kill_session(_name) = nil
    def rename_window(_session, _index, _name) = nil

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
  end

  class FakeWindowLayout
    def arrange(_ids) = nil
    def calculate_positions(**_opts) = []
  end

  class FakeDoctor
    def run
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
      output: output,
      error_output: error_output,
      input: input
    )
    [cli, output, error_output]
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
