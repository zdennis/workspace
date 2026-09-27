require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "stringio"

module T5StartConcurrencyFakes
  class Launch
    attr_reader :calls

    def initialize(result = {exit_code: 0, prompt_failures: {}})
      @result = result
      @calls = []
    end

    def call(projects, **kwargs)
      @calls << [projects, kwargs]
      @result
    end
  end

  class ProjectConfig
    def create_worktree(project_name, worktree_name, _path, _branch, quiet: false)
      "#{project_name}.worktree-#{worktree_name}"
    end
  end

  class Config
    def initialize(dir)
      @dir = dir
    end

    def config_path_for(name) = File.join(@dir, "workspace.#{name}.yml")

    def worktree_template_path
      File.expand_path("../../lib/templates/workspace.project-worktree-template.yml", __dir__)
    end

    def window_tool = File.join(@dir, "window-tool")

    def agent_running?(_name) = true
  end

  class State < Hash
    def load = nil

    def save = nil
  end

  class ITerm
    def session_map = {}

    def find_existing_sessions(_state, live_sessions:) = {}

    def find_launcher_window_id(_state, live_sessions:) = nil

    def create_launcher_panes(projects, _commands, launcher_wid:)
      projects.to_h { |p| [p, "uid-#{p}"] }
    end
  end

  class Tmux
    def start_server = true

    def command_for(project, reattach:) = "tmuxinator start #{project}"

    def session_name_for(project) = "sess-#{project}"

    def sessions = ["sess-proj.worktree-x"]

    def rename_window(*) = true
  end

  class WindowManager
    def iterm_windows = {42 => "workspace-sess-proj.worktree-x"}

    def set_window_bounds(*) = true
  end

  class LaunchProjectConfig
    def exists?(_name) = true
  end
end

# Adversarial concurrency/process specs for `workspace start --json`
# (T5). Each example pins a defect: it fails until the defect is fixed.
RSpec.describe "T5 start adversarial concurrency" do
  let(:tmpdir) { Dir.mktmpdir("t5-start") }
  let(:output) { StringIO.new }

  after { FileUtils.remove_entry(tmpdir) }

  def sh!(*cmd, chdir:)
    _, err, status = Open3.capture3(*cmd, chdir: chdir)
    raise "#{cmd.join(" ")} failed: #{err}" unless status.success?
  end

  def make_repo
    repo = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(repo)
    sh!("git", "init", "-q", "-b", "main", chdir: repo)
    sh!("git", "-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init", chdir: repo)
    File.realpath(repo)
  end

  def git_double(root)
    git = instance_double(Workspace::Git)
    allow(git).to receive_messages(
      root: root,
      parse_start_input: {type: :branch, value: "x"},
      sanitize_for_filesystem: "x",
      worktree_exists?: false,
      branch_exists?: false,
      find_matching_branches: [],
      find_worktree_by_branch: nil
    )
    allow(git).to receive(:create_worktree) { |path, *| FileUtils.mkdir_p(path) }
    git
  end

  def start(git:, project_config: T5StartConcurrencyFakes::ProjectConfig.new, launch: T5StartConcurrencyFakes::Launch.new,
    hook_installer: nil, which: ->(_) { false })
    Workspace::Commands::Start.new(
      git: git, project_config: project_config, project_settings: CLITestHelpers::FakeProjectSettings.new,
      launch_command: launch, hook_installer: hook_installer, which: which,
      output: output, input: StringIO.new
    )
  end

  def stdout_lines = output.string.lines

  it "SC1: --json stdout holds only the JSON doc, but Git#create_worktree prints 'Running: git worktree add ...' to it" do
    repo = make_repo
    git = Workspace::Git.new(output: output, input: StringIO.new)
    result = Dir.chdir(repo) { start(git: git).call("x", base: "main", json: true) }

    expect(result[:exit_code]).to eq(0)
    expect(stdout_lines.grep(/Running:/)).to be_empty
    expect(stdout_lines.size).to eq(1)
  end

  it "SC2: --json stdout holds only the JSON doc, but ProjectConfig#create_worktree prints 'Created config: ...' to it" do
    root = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(root)
    config = T5StartConcurrencyFakes::Config.new(tmpdir)
    project_config = Workspace::ProjectConfig.new(config: config, git: Workspace::Git.new(output: output), output: output)

    result = start(git: git_double(root), project_config: project_config).call("x", base: "main", json: true)

    expect(result[:exit_code]).to eq(0)
    expect(stdout_lines.grep(/Created config/)).to be_empty
    expect(stdout_lines.size).to eq(1)
  end

  it "SC3: --json stdout holds only the JSON doc, but HookInstaller prints '  create  .../settings.json' to it" do
    root = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(root)
    installer = Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: output), output: output)

    result = start(git: git_double(root), hook_installer: installer, which: ->(exe) { exe == "claude" })
      .call("x", base: "main", json: true)

    expect(result[:exit_code]).to eq(0)
    expect(stdout_lines.grep(/settings\.json/)).to be_empty
    expect(stdout_lines.size).to eq(1)
  end

  it "SC4: Launch#call(quiet: true) still lets WindowLayout print '  Positioned ...' to the shared stdout" do
    config = T5StartConcurrencyFakes::Config.new(tmpdir)
    File.write(config.window_tool, "#!/bin/sh\necho '{\"x\":0,\"y\":0,\"width\":1000,\"height\":800}'\n")
    File.chmod(0o755, config.window_tool)
    window_manager = T5StartConcurrencyFakes::WindowManager.new
    launch = Workspace::Commands::Launch.new(
      state: T5StartConcurrencyFakes::State.new, iterm: T5StartConcurrencyFakes::ITerm.new,
      window_manager: window_manager, tmux: T5StartConcurrencyFakes::Tmux.new,
      project_config: T5StartConcurrencyFakes::LaunchProjectConfig.new,
      window_layout: Workspace::WindowLayout.new(window_manager: window_manager, config: config, output: output),
      config: config, pipeline_config: Object.new, agent_readiness: Object.new,
      sleeper: ->(_) {}, output: output, error_output: StringIO.new
    )

    result = launch.call(["proj.worktree-x"], quiet: true)

    expect(result[:exit_code]).to eq(0)
    expect(output.string).to eq("")
  end

  it "SC5: --json with an unsent --prompt exits 1 but prints the success doc with no 'error' (docs: exit 1 means an error doc)" do
    root = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(root)
    launch = T5StartConcurrencyFakes::Launch.new({exit_code: 1, prompt_failures: {"proj.worktree-x" => "agent never became ready"}})

    result = start(git: git_double(root), launch: launch).call("x", prompt: "hi", base: "main", json: true)

    expect(result[:exit_code]).to eq(1)
    doc = JSON.parse(stdout_lines.last)
    expect(doc).to include("error")
  end

  it "SC6: two starts racing to create .worktrees/ — the loser crashes with Errno::EEXIST (no JSON doc) instead of carrying on" do
    root = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(root)
    worktrees = File.join(root, ".worktrees")
    # The other `start` creates .worktrees/ between this run's check and its mkdir.
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(worktrees) do
      Dir.mkdir(worktrees) unless Dir.exist?(worktrees)
      false
    end

    result = nil
    expect { result = start(git: git_double(root)).call("x", base: "main", json: true) }.not_to raise_error
    expect(result).to eq({exit_code: 0})
    expect(JSON.parse(stdout_lines.last)).to include("created" => true)
  end
end
