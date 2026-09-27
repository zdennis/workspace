require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require "json"
require "delegate"

module T4ConcurrencyFakes
  # Wraps a real Workspace::Git and runs a hook just before the worktree is
  # removed, standing in for an agent that is still running in the session.
  class GitWithWriteBeforeRemove < SimpleDelegator
    def initialize(git, &before_remove)
      super(git)
      @before_remove = before_remove
    end

    def remove_worktree(path, force: false)
      @before_remove.call
      __getobj__.remove_worktree(path, force: force)
    end
  end

  class RecordingStop
    attr_reader :calls

    def initialize(&on_call)
      @calls = []
      @on_call = on_call
    end

    def call(projects = [], quiet: false)
      @calls << projects
      @on_call&.call
      projects
    end
  end

  class RecordingSettings
    def remove(_name)
    end
  end
end

# Adversarial concurrency/liveness specs for T4 ("never lose work"):
# kill, prune and finish. Each example pins a defect found by review.
RSpec.describe "T4 finish/kill/prune adversarial concurrency" do
  def sh!(*cmd, chdir: nil)
    opts = chdir ? {chdir: chdir} : {}
    out, err, status = Open3.capture3(*cmd, **opts)
    raise "#{cmd.join(" ")} failed: #{err}" unless status.success?
    out
  end

  let(:root) { File.realpath(Dir.mktmpdir("t4-conc")) }
  let(:output) { StringIO.new }
  let(:project) { "proj.worktree-feat" }
  let(:bare) { File.join(root, "remote.git") }
  let(:main_repo) { File.join(root, "main") }
  let(:worktree) { File.join(root, "wt-feat") }
  let(:tracked_file) { File.join(worktree, "tracked.txt") }
  let(:config_dir) { File.join(root, "tmuxinator") }
  let(:config_path) { File.join(config_dir, "workspace.#{project}.yml") }
  let(:real_git) { Workspace::Git.new(output: output, input: StringIO.new) }

  let(:project_config) do
    cfg_path = config_path
    wt = worktree
    proj = project
    double("project_config").tap do |pc|
      allow(pc).to receive(:config_path_for).with(proj).and_return(cfg_path)
      allow(pc).to receive(:remove).with(proj) { FileUtils.rm_f(cfg_path) }
      allow(pc).to receive(:available_projects).and_return([proj])
      allow(pc).to receive(:project_root_for).with(proj).and_return(wt)
    end
  end
  let(:project_detector) do
    Workspace::ProjectDetector.new(state: CLITestHelpers::FakeState.new, project_config: project_config)
  end

  def build_repo(with_remote: true)
    env_git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.com"]
    if with_remote
      sh!("git", "init", "--bare", "-q", "-b", "main", bare)
      sh!("git", "clone", "-q", bare, main_repo)
    else
      sh!("git", "init", "-q", "-b", "main", main_repo)
    end
    File.write(File.join(main_repo, "tracked.txt"), "base\n")
    sh!("git", "add", "tracked.txt", chdir: main_repo)
    sh!(*env_git, "commit", "-q", "-m", "base", chdir: main_repo)
    sh!("git", "push", "-q", "origin", "main", chdir: main_repo) if with_remote
    sh!("git", "worktree", "add", "-q", "-b", "feat", worktree, chdir: main_repo)
    File.write(tracked_file, "feature\n")
    sh!(*env_git, "commit", "-q", "-am", "feature", chdir: worktree)
    sh!("git", "push", "-q", "-u", "origin", "feat", chdir: worktree) if with_remote
    FileUtils.mkdir_p(config_dir)
    File.write(config_path, YAML.dump("name" => project, "root" => worktree))
    File.write(File.join(worktree, ".workspace-project"), project)
  end

  def build_kill(git:, stop:, input: StringIO.new)
    Workspace::Commands::Kill.new(
      git: git, project_config: project_config, project_settings: T4ConcurrencyFakes::RecordingSettings.new,
      stop_command: stop, project_detector: project_detector, output: output, input: input
    )
  end

  after { FileUtils.rm_rf(root) }

  # Seed 1: kill/finish run from inside the tmux session they tear down.
  it "FC1: Kill records the project's removal from state before killing the session that runs it" do
    state = CLITestHelpers::FakeState.new
    state[project] = {"unique_id" => "uid-1", "iterm_window_id" => 1}
    tmux = double("tmux", sessions: ["ws-#{project}"])
    allow(tmux).to receive(:session_name_for).with(project).and_return("ws-#{project}")
    # tmux kill-session on our own session SIGHUPs this process: nothing after it runs.
    allow(tmux).to receive(:kill_session) { throw :caller_killed }
    iterm = double("iterm", find_existing_sessions: {})
    stop = Workspace::Commands::Stop.new(
      state: state, iterm: iterm, window_manager: double("wm"), tmux: tmux,
      output: output, error_output: StringIO.new
    )
    git = double("git", worktree_exists?: true, remove_worktree: nil)
    FileUtils.mkdir_p(config_dir)
    FileUtils.mkdir_p(worktree)
    File.write(config_path, YAML.dump("name" => project, "root" => worktree))

    catch(:caller_killed) { build_kill(git: git, stop: stop).call(project, force: true) }

    expect(state[project]).to be_nil,
      "the state entry (event log 'state_removed' + state file save) is written only after " \
      "tmux kill-session, so a finish/kill run from inside its own session leaves a stale entry"
  end

  # Seed 2: check-then-remove race in finish.
  it "FC2: finish does not destroy tracked-file edits made after its clean check (removal uses --force)" do
    build_repo
    git = T4ConcurrencyFakes::GitWithWriteBeforeRemove.new(real_git) { File.write(tracked_file, "agent edit after the check\n") }
    kill = build_kill(git: git, stop: T4ConcurrencyFakes::RecordingStop.new)
    finish = Workspace::Commands::Finish.new(
      git: git, project_config: project_config, kill_command: kill,
      project_detector: project_detector, output: output, error_output: StringIO.new
    )

    begin
      finish.call(project)
    rescue Workspace::Error
      # refusing is an acceptable outcome
    end

    expect(File.exist?(tracked_file) && File.read(tracked_file)).to eq("agent edit after the check\n"),
      "finish verified the worktree clean, then Kill ran `git worktree remove --force`, " \
      "silently deleting an uncommitted edit made in between"
  end

  def build_prune(git:, state:, stop:)
    prune = Workspace::Commands::Prune.new(
      state: state, project_config: project_config, project_settings: T4ConcurrencyFakes::RecordingSettings.new,
      git: git, stop_command: stop, output: output, input: StringIO.new("y\n")
    )
    ok = double("status", success?: true)
    allow(Open3).to receive(:capture3).and_call_original
    allow(Open3).to receive(:capture3).with("gh", "auth", "status").and_return(["", "", ok])
    allow(Open3).to receive(:capture3).with("git", "-C", worktree, "remote", "get-url", "origin")
      .and_return(["git@github.com:o/r.git\n", "", ok])
    allow(Open3).to receive(:capture3).with("gh", "pr", "view", "feat", "--repo", "o/r", "--json", "number,url,state")
      .and_return([JSON.generate("number" => 1, "url" => "u", "state" => "MERGED"), "", ok])
    prune
  end

  # Seed 2: prune without --force used to stop the session (whose agent may
  # write on SIGHUP) between its check and a `git worktree remove --force`.
  # Now the check sits inside the removal and the session is stopped last,
  # so an edit that lands after prune picked the candidate is refused.
  it "FC3: prune (no --force) refuses, rather than deletes, an edit made after it picked the candidate" do
    build_repo
    state = CLITestHelpers::FakeState.new
    state[project] = {"unique_id" => "uid-1"}
    stop = T4ConcurrencyFakes::RecordingStop.new
    git = T4ConcurrencyFakes::GitWithWriteBeforeRemove.new(real_git) { File.write(tracked_file, "agent's late edit\n") }

    expect { build_prune(git: git, state: state, stop: stop).call }.to raise_error(Workspace::Error, /#{Regexp.escape(project)}/)

    expect(File.read(tracked_file)).to eq("agent's late edit\n")
    expect(stop.calls).to be_empty
    expect(state[project]).not_to be_nil
    expect(File.exist?(config_path)).to be(true)
    expect(output.string).to include("Skipped #{project}")
  end

  it "FC3: prune stops the session only after the worktree is removed" do
    build_repo
    state = CLITestHelpers::FakeState.new
    state[project] = {"unique_id" => "uid-1"}
    wt = worktree
    worktree_present_at_stop = nil
    stop = T4ConcurrencyFakes::RecordingStop.new { worktree_present_at_stop = File.directory?(wt) }

    build_prune(git: real_git, state: state, stop: stop).call

    expect(stop.calls).to eq([[project]])
    expect(worktree_present_at_stop).to be(false)
  end

  # Seed 2: kill (no --force) deletes the marker before a removal that git can refuse.
  it "FC4: kill (no --force) leaves no half-removed state when git refuses the removal after the prompt" do
    build_repo
    marker = File.join(worktree, ".workspace-project")
    # The user sits at the [y/N] prompt while the agent keeps editing.
    prompt = Object.new
    tf = tracked_file
    prompt.define_singleton_method(:gets) do
      File.write(tf, "edit while the prompt waited\n")
      "y\n"
    end
    kill = build_kill(git: real_git, stop: T4ConcurrencyFakes::RecordingStop.new, input: prompt)

    begin
      kill.call(project)
    rescue Workspace::Error
      # git refused: fine, as long as nothing was half-removed
    end

    worktree_gone = !File.directory?(worktree)
    expect(worktree_gone || File.exist?(marker)).to be(true),
      "Kill deleted .workspace-project, then `git worktree remove` refused; the worktree and " \
      "config survive but cwd-based detection (`workspace kill`/`finish` with no argument) no longer works"
  end

  # User rule: untracked files never count as unsaved work.
  it "FC5: kill (no --force) removes a worktree whose only extra content is an untracked file" do
    build_repo
    File.write(File.join(worktree, "scratch.log"), "untracked\n")
    kill = build_kill(git: real_git, stop: T4ConcurrencyFakes::RecordingStop.new, input: StringIO.new("y\n"))

    expect { kill.call(project) }.not_to raise_error,
      "the unsaved-work check ignores untracked files, but the non-forced " \
      "`git worktree remove` then refuses because of them"
    expect(File.directory?(worktree)).to be(false)
  end

  # Seed 3: no-remote fallback builds `rev-list HEAD --not <every other branch>`.
  it "FC6: unsaved_work answers :unknown (not an exception) in a no-remote repo with many branches" do
    build_repo(with_remote: false)
    head = sh!("git", "rev-parse", "main", chdir: main_repo).strip
    packed = File.join(main_repo, ".git", "packed-refs")
    File.open(packed, "a") do |f|
      f.puts "# pack-refs with: peeled fully-peeled sorted " unless File.size?(packed)
      12_000.times { |i| f.puts "#{head} refs/heads/archive/#{"x" * 80}-#{i.to_s.rjust(6, "0")}" }
    end

    result = nil
    expect { result = real_git.unsaved_work(worktree) }.not_to raise_error,
      "every other branch is passed as an argv element to `git rev-list`, which overflows ARG_MAX (Errno::E2BIG)"
    expect(result).to eq(nil).or eq(:unknown).or be_a(Hash)
  end
end
