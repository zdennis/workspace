require "spec_helper"
require "tmpdir"
require "json"

# Adversarial concurrency specs for `lock clear devenv` racing `dev up
# --takeover`. Each interleaving is driven from inside the stubbed
# stop_holder seams, so nothing is signalled and no step depends on timing.
RSpec.describe "lock clear devenv racing dev up --takeover" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-lock-clear-takeover")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:clear_output) { StringIO.new }
  let(:clear_error_output) { StringIO.new }
  # The clearer's identity, and the liveness oracle for every recorded pid.
  let(:liveness) { FakeLockIdentity.new(pid: 999) }
  let(:now) { [0.0] }
  let(:clock) { Struct.new(:now_ref) { def now = now_ref[0] }.new(now) }
  let(:sleeper) { ->(seconds) { now[0] += seconds } }
  let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
  let(:settings) { {"up" => "run-dev", "stop_timeout" => 2, "startup_timeout" => 5} }
  let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => settings})) }
  let(:lineage) { double("lineage", resolve: double(name: "app", worktree: nil)) }
  let(:tmux) { double("tmux", session_name_for_pane: "app", sessions: ["app"], session_name_for: "app", close_dead_pane: nil) }

  # Terminators whose every real signal raises; stop_holder is stubbed per example.
  def fake_terminator
    Workspace::ProcessGroupTerminator.new(own_pgid: 1, kill: ->(signal, _target) {
      raise Errno::ESRCH if signal == 0
      raise "unexpected signal #{signal}"
    }).tap { |t| allow(t).to receive(:running?).and_return(false) }
  end

  let(:dev_terminator) { fake_terminator }
  let(:clear_terminator) { fake_terminator }

  let(:dev) do
    Workspace::Commands::Dev.new(lock_namespace: lock_namespace, lock_holder: liveness, lineage: lineage, dev_config: dev_config,
      dev_runner: nil, terminator: dev_terminator, tmux: tmux, executable: "/ws/bin/workspace", output: output,
      error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 1, clock: clock, sleeper: sleeper,
      kill: ->(signal, pid) {
        raise Errno::ESRCH unless liveness.alive?(pid: pid, started: "start-#{pid}")
        1
      })
  end

  let(:lock_command) do
    Workspace::Commands::Lock.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: liveness,
      output: clear_output, error_output: clear_error_output, terminator: clear_terminator, clock: clock, sleeper: sleeper,
      pid_provider: -> { 999 }, trap: ->(*) {})
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
  end

  def process_identity(pid, worktree)
    {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, pane: "%#{pid}", worktree: worktree, branch: "b-#{pid}"}
  end

  def hold(pid)
    store.acquire("devenv", identity: process_identity(pid, "/w/old"), waiter_pid: pid, waiter_started: "start-#{pid}")
  end

  def enqueue(pid, priority: false)
    store.acquire("devenv", identity: process_identity(pid, tmpdir), waiter_pid: pid, waiter_started: "start-#{pid}",
      wait: true, priority: priority)
  end

  # The takeover's `dev __run` wrapper: joins the queue as DevRunner would,
  # at its head when the window was opened for a takeover.
  def wrapper_joins(pid)
    allow(tmux).to receive(:new_window) do |_session, env:, **|
      enqueue(pid, priority: env["WORKSPACE_DEV_TAKEOVER"] == "1")
      pid
    end
  end

  # The holder's wrapper forwarding SIGTERM: its command exits, it releases
  # devenv (promoting the queue head), and exits.
  def holder_stops_on_term(pid)
    store.release("devenv", pid)
    liveness.kill(pid)
    :terminated
  end

  def devenv
    store.status("devenv")["devenv"] || {}
  end

  it "keeps a queued takeover when lock clear runs before the takeover stops the holder" do
    hold(700)
    wrapper_joins(555)
    allow(clear_terminator).to receive(:stop_holder) { holder_stops_on_term(700) }
    # The clear lands between the takeover queueing and its own stop.
    allow(dev_terminator).to receive(:stop_holder) do
      expect(lock_command.clear("devenv")).to eq(exit_code: 0)
      :gone
    end

    expect(dev.up(takeover: true, working_dir: tmpdir)).to eq(exit_code: 0)
    expect(devenv["holder"]).to include("pid" => 555)
    expect(clear_output.string).to include("kept the queued takeover")
  end

  it "promotes a takeover that queues after lock clear emptied the queue" do
    hold(700)
    allow(clear_terminator).to receive(:stop_holder) do
      # The takeover's wrapper queues mid-clear; the holder then dies
      # without releasing, so the clear's own finish promotes the takeover.
      enqueue(555, priority: true)
      liveness.kill(700)
      :terminated
    end

    expect(lock_command.clear("devenv")).to eq(exit_code: 0)
    expect(devenv["holder"]).to include("pid" => 555)
  end

  it "hands the lock to a takeover that queues mid-clear when the holder releases on its own" do
    hold(700)
    allow(clear_terminator).to receive(:stop_holder) do
      enqueue(555, priority: true)
      holder_stops_on_term(700)
    end

    lock_command.clear("devenv")

    expect(devenv["holder"]).to include("pid" => 555)
  end

  it "still removes an ordinary waiter while keeping the takeover" do
    hold(700)
    enqueue(800)
    enqueue(555, priority: true)
    allow(clear_terminator).to receive(:stop_holder) { holder_stops_on_term(700) }

    expect(lock_command.clear("devenv")).to eq(exit_code: 0)

    expect(devenv["holder"]).to include("pid" => 555)
    expect(devenv["queue"]).to be_empty
    expect(store.poll("devenv", 800)).to eq(status: :cleared)
    expect(clear_output.string).to include("1 waiter(s) removed")
  end

  it "leaves the takeover queued first when the holder's group can't be stopped" do
    hold(700)
    enqueue(555, priority: true)
    allow(clear_terminator).to receive(:stop_holder).and_raise(Workspace::Error, "not permitted")

    expect(lock_command.clear("devenv")).to eq(exit_code: 1)

    expect(devenv["holder"]).to include("pid" => 700, "kept" => true)
    expect(devenv["queue"].map { |w| w["waiter_pid"] }).to eq([555])
  end
end
