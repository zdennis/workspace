require "spec_helper"
require "tmpdir"
require "json"

# Adversarial concurrency specs for `lock clear` on a `kind: "process"`
# holder (commit 7e201d4). Every signal goes through the terminator's kill:
# seam and every pid through FakeLockIdentity, so nothing real is signalled.
RSpec.describe "lock clear on a process holder, under concurrency" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-clear-cc") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: tmpdir}) }
  # The clearer's identity, and the liveness oracle for every recorded pid.
  let(:identity) { FakeLockIdentity.new(pid: 999) }
  let(:now) { [0.0] }
  let(:advance) { ->(seconds) { now[0] += seconds } }
  let(:mono_clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
  let(:signals) { [] }
  let(:member_states) { ["S"] }
  let(:terminator) do
    Workspace::ProcessGroupTerminator.new(clock: -> { now[0] }, sleeper: advance, own_pgid: 77,
      kill: ->(signal, target) {
        signals << [signal, target]
        @on_kill&.call(signal, target)
      },
      member_states: ->(_pgid) { member_states }, member_owners: ->(_pgid) { ["root"] })
  end
  let(:command) do
    Workspace::Commands::Lock.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, terminator: terminator, clock: mono_clock, sleeper: advance,
      pid_provider: -> { 999 }, trap: ->(*) {})
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store
    Workspace::LockStore.new(dir: tmpdir, liveness: identity)
  end

  def process_identity(pid, branch)
    {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, worktree: "/w/#{branch}", branch: branch}
  end

  def hold_devenv
    store.acquire("devenv", identity: process_identity(4242, "login"), waiter_pid: 4242, waiter_started: "start-4242")
  end

  # A second worktree's `dev __run --wait` wrapper queueing for devenv.
  def queue_second_env
    store.acquire("devenv", identity: process_identity(5000, "signup"), waiter_pid: 5000,
      waiter_started: "start-5000", wait: true)
  end

  def devenv_holder_pid
    store.status("devenv").dig("devenv", "holder", "pid")
  end

  def audit_events
    path = File.join(tmpdir, "locks.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  it "CC1: a lock clear reports as kept is freed by the wrapper's own release when an other-user member outlives it" do
    hold_devenv
    # The wrapper forwards SIGTERM; its shell child exits, so it releases
    # devenv in its ensure and exits, while a root-owned server in its group
    # keeps running. A second env queued during the stop is promoted by that release.
    @on_kill = ->(signal, target) {
      if [signal, target] == ["TERM", 4242]
        queue_second_env
        store.release("devenv", 4242)
        identity.kill(4242)
      elsif target == -4242
        raise Errno::EPERM
      end
    }

    result = command.clear("devenv")

    expect(result).to eq(exit_code: 1)
    expect(error_output.string).to include("Kept devenv lock: it still names pid 4242")
    expect(devenv_holder_pid).to eq(4242)
  end

  it "CC2: a kept lock whose wrapper died to SIGKILL is reaped and granted to a waiter while the group still runs" do
    hold_devenv
    @on_kill = ->(signal, target) {
      case [signal, target]
      when ["TERM", 4242]
        queue_second_env
      when ["KILL", -4242]
        identity.kill(4242)
      when [0, -4242]
        raise Errno::EPERM unless identity.alive?(pid: 4242, started: "start-4242")
      end
    }

    result = command.clear("devenv")
    expect(result).to eq(exit_code: 1)
    expect(error_output.string).to include("Kept devenv lock")

    expect(store.poll("devenv", 5000)[:status]).not_to eq(:acquired)
  end

  it "CC3: a clear whose wrapper releases on SIGTERM leaves no clear event in the audit log" do
    hold_devenv
    queue_second_env
    @on_kill = ->(signal, target) {
      if [signal, target] == ["TERM", 4242]
        store.release("devenv", 4242)
        identity.kill(4242)
      elsif target == -4242
        raise Errno::ESRCH
      end
    }

    result = command.clear("devenv")

    expect(result).to eq(exit_code: 0)
    clear_events = audit_events.select { |e| e["event"] == "clear" && e["lock"] == "devenv" }
    expect(clear_events.size).to eq(1)
    expect(clear_events.first).to include("queue_size" => 1, "cleared_by" => "pid 999")
  end

  it "CC4: a wrapper that vanishes between the liveness check and SIGTERM is reported stopped while its group runs" do
    hold_devenv
    @on_kill = ->(signal, target) {
      if [signal, target] == ["TERM", 4242]
        identity.kill(4242)
        raise Errno::ESRCH
      end
      raise Errno::ESRCH if target == 4242 && !identity.alive?(pid: 4242, started: "start-4242")
    }

    result = command.clear("devenv")

    expect(result).to eq(exit_code: 1)
    expect(output.string).not_to include("Stopped process group 4242")
    expect(error_output.string).to include("its wrapper pid 4242 is gone, but the group is still running", "Kept devenv lock")
    expect(devenv_holder_pid).to eq(4242)
  end
end

# Adversarial concurrency specs for the `clearing` marker (commit a3d00ff).
# Signals go through the terminator's kill: seam and liveness through
# FakeLockIdentity; nothing real is signalled.
RSpec.describe "lock clear's clearing marker, under concurrency" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-clear-marker-cc") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: tmpdir}) }
  let(:identity) { FakeLockIdentity.new(pid: 999) }
  let(:now) { [0.0] }
  let(:advance) { ->(seconds) { now[0] += seconds } }
  let(:mono_clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
  let(:signals) { [] }
  let(:group_running) { [true] }
  let(:terminator) do
    Workspace::ProcessGroupTerminator.new(clock: -> { now[0] }, sleeper: advance, own_pgid: 77,
      kill: ->(signal, target) {
        signals << [signal, target]
        @on_kill&.call(signal, target)
        case [signal, target]
        when [0, -4242] then raise Errno::ESRCH unless group_running[0]
        when ["KILL", -4242]
          group_running[0] = false
          identity.kill(4242)
        end
      },
      member_states: ->(_pgid) { group_running[0] ? ["S"] : [] }, member_owners: ->(_pgid) { [] })
  end
  let(:lock_command) do
    Workspace::Commands::Lock.new(config: Workspace::Config.new, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, terminator: terminator, clock: mono_clock, sleeper: advance,
      pid_provider: -> { 999 }, trap: ->(*) {})
  end
  let(:dev_command) do
    lineage = Object.new
    lineage.define_singleton_method(:resolve) { |cwd:| Struct.new(:name, :worktree).new("app", nil) }
    settings = Struct.new(:data) { def load(_name) = data }.new({"dev" => {"up" => "true", "stop_timeout" => 2}})
    Workspace::Commands::Dev.new(lock_namespace: lock_namespace, lock_holder: identity, lineage: lineage,
      dev_config: Workspace::DevConfig.new(project_settings: settings), dev_runner: nil, terminator: terminator,
      tmux: nil, executable: "unused", output: output, error_output: error_output, env: {}, sleeper: advance,
      clock: mono_clock, poll: 0.1)
  end

  around do |example|
    old = ENV.values_at("XDG_STATE_HOME", "XDG_CONFIG_HOME")
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    ENV["XDG_CONFIG_HOME"] = File.join(tmpdir, "config")
    example.run
  ensure
    ENV["XDG_STATE_HOME"], ENV["XDG_CONFIG_HOME"] = old
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store
    Workspace::LockStore.new(dir: tmpdir, liveness: identity)
  end

  def hold_devenv
    wrapper = {kind: "process", pid: 4242, started: "start-4242", pgid: 4242, worktree: "/w/login", branch: "login"}
    store.acquire("devenv", identity: wrapper, waiter_pid: 4242, waiter_started: "start-4242")
  end

  def wrapper_terms
    signals.count { |s| s == ["TERM", 4242] }
  end

  it "BC1: dev down run while a lock clear is stopping the devenv group signals that group a second time" do
    hold_devenv
    @on_kill = ->(signal, target) {
      next unless [signal, target] == ["TERM", 4242] && !@nested
      @nested = true
      dev_command.down(working_dir: tmpdir)
    }

    lock_command.clear("devenv")

    expect(wrapper_terms).to eq(1)
  end

  it "BC2: a keep_process_holder by someone other than the marked clearer drops that live clear's marker" do
    hold_devenv
    store.clear("devenv", keep_process_holder: true, clearer: {"pid" => 999, "started" => "start-999"})
    holder = store.status("devenv").dig("devenv", "holder")
    # `dev down` (which read the holder before the clear marked it) could not
    # stop the group and re-asserts the lock, while clear 999 is still stopping it.
    store.keep_process_holder("devenv", holder)

    second = store.clear("devenv", keep_process_holder: true, clearer: {"pid" => 1001, "started" => "start-1001"})

    expect(second).to include(in_progress: true)
  end

  it "BC3: a lock clear run while dev down is stopping the devenv group signals that group a second time" do
    hold_devenv
    @on_kill = ->(signal, target) {
      next unless [signal, target] == ["TERM", 4242] && !@nested
      @nested = true
      lock_command.clear("devenv")
    }

    dev_command.down(working_dir: tmpdir)

    expect(wrapper_terms).to eq(1)
  end
end
