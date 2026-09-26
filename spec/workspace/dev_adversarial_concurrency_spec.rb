require "spec_helper"
require "tmpdir"
require "timeout"
require "rbconfig"
require "json"

# Adversarial concurrency/liveness/signal specs for PR2 (devenv lock). Each
# example pins one confirmed defect and is expected to FAIL until it is fixed.
RSpec.describe "devenv lock: adversarial concurrency" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-dev-adv")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:spawned) { [] }

  around do |example|
    old_state = ENV["XDG_STATE_HOME"]
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    Timeout.timeout(40) { example.run }
  ensure
    ENV["XDG_STATE_HOME"] = old_state
  end

  after do
    spawned.each do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  def spawn_group(*cmd)
    pid = Process.spawn(*cmd, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
    spawned << pid
    pid
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    result
  end

  def adv_liveness
    Object.new.tap do |o|
      o.define_singleton_method(:start_time) { |_pid = nil| "Sat Jan  1 00:00:00 2000" }
      o.define_singleton_method(:alive?) { |pid:, started:| true }
    end
  end

  def adv_trap
    handlers = {}
    Object.new.tap do |o|
      o.define_singleton_method(:handlers) { handlers }
      o.define_singleton_method(:call) do |signal, handler|
        previous = handlers.fetch(signal, "DEFAULT")
        handlers[signal] = handler
        previous
      end
    end
  end

  describe Workspace::DevRunner do
    let(:output) { StringIO.new }
    let(:trap) { adv_trap }
    let(:kills) { [] }
    let(:spawner_calls) { [] }

    def runner(spawner:)
      Workspace::DevRunner.new(liveness: adv_liveness, output: output, env: {}, trap: trap,
        spawner: spawner, kill: ->(sig, target) { kills << [sig, target] }, pgrp: -> { Process.pid },
        sleeper: ->(_) {}, poll: 0)
    end

    it "D-C1: a SIGTERM that lands while the queued poll promotes the wrapper is dropped, so the dev command runs anyway" do
      store = Object.new
      calls = []
      handlers = trap.handlers
      store.define_singleton_method(:acquire) { |*, **| {status: :queued} }
      store.define_singleton_method(:poll) do |*|
        handlers["TERM"].call # `dev up --max-wait` give_up / `dev down` arrives mid-poll
        {status: :acquired}
      end
      store.define_singleton_method(:dequeue) { |name, pid| calls << [:dequeue, name, pid] && :released }
      store.define_singleton_method(:release) { |name, pid| calls << [:release, name, pid] && true }
      spawner = ->(command, _dir) {
        spawner_calls << command
        spawn_group("/bin/sh", "-c", "exit 0")
      }

      code = runner(spawner: spawner).call(store: store, command: "./start-dev", worktree: tmpdir, wait: true)

      expect(spawner_calls).to be_empty
      expect(code).to eq(128 + Signal.list["TERM"])
    end

    it "D-C2: a child that exits normally with status 130 is reported as killed by SIGINT" do
      store = Object.new
      store.define_singleton_method(:acquire) { |*, **| {status: :acquired} }
      store.define_singleton_method(:release) { |*| true }
      spawner = ->(_command, _dir) { spawn_group("/bin/sh", "-c", "exit 130") }

      code = runner(spawner: spawner).call(store: store, command: "exit-130", worktree: tmpdir)

      expect(code).to eq(130)
      expect(output.string).not_to include("SIGINT")
      expect(output.string).to include("exited with status 130")
    end
  end

  describe Workspace::ProcessGroupTerminator do
    it "D-C3: terminating a group whose only member is an unreaped zombie raises instead of returning :not_running" do
      pid = spawn_group("/bin/sh", "-c", "exit 0")
      wait_until do
        Process.kill(0, -pid)
        false
      rescue Errno::EPERM
        true
      end
      terminator = described_class.new(poll_interval: 0.01)

      begin
        expect(terminator.running?(pid)).to be(false)
        expect { expect(terminator.terminate(pid, stop_timeout: 0)).to eq(:not_running) }.not_to raise_error
      ensure
        Process.wait(pid)
      end
    end
  end

  describe Workspace::Commands::Dev do
    let(:main) { File.join(tmpdir, "app") }
    let(:login) { File.join(tmpdir, "app-login") }
    let(:output) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:dev_settings) { {"up" => "exec sleep 30", "stop_timeout" => 2} }
    let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
    let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => dev_settings})) }
    let(:lib_dir) { File.expand_path("../../lib", __dir__) }
    let(:tmux) { FakeDevWindowTmux.new(method(:spawn_wrapper)) }

    let(:wrapper_script) do
      <<~RUBY
        $LOAD_PATH.unshift #{lib_dir.inspect}
        require "workspace"
        lock_dir, settings, wait = ARGV
        ns = Struct.new(:dir) { def resolve(cwd:) = {dir: dir} }.new(lock_dir)
        store = Struct.new(:data) { def load(_name) = data }.new(JSON.parse(settings))
        liveness = Workspace::LockHolder.new
        dev = Workspace::Commands::Dev.new(lock_namespace: ns, lock_holder: liveness, lineage: Workspace::WorkspaceLineage.new,
          dev_config: Workspace::DevConfig.new(project_settings: store),
          dev_runner: Workspace::DevRunner.new(liveness: liveness, env: {"TMUX_PANE" => "%9"}, poll: 0.05),
          terminator: Workspace::ProcessGroupTerminator.new, tmux: nil, executable: "unused")
        begin
          exit dev.run(wait: wait == "1", working_dir: Dir.pwd)[:exit_code]
        rescue Workspace::Error => e
          warn e.message
          exit 1
        end
      RUBY
    end

    def spawn_wrapper(cwd, wait)
      log = File.join(tmpdir, "wrapper-#{spawned.size}.log")
      pid = Process.spawn({"SKIP_SIMPLECOV" => "1"}, RbConfig.ruby, "-e", wrapper_script, lock_dir,
        JSON.generate("dev" => dev_settings), wait ? "1" : "0", chdir: cwd, pgroup: true, in: File::NULL, out: log, err: log)
      Process.detach(pid)
      spawned << pid
      pid
    end

    def git(*args)
      system("git", *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(" ")} failed"
    end

    def dev
      described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
        lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: nil,
        terminator: Workspace::ProcessGroupTerminator.new(poll_interval: 0.05), tmux: tmux, executable: "/ws/bin/workspace",
        output: output, error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 0.05, startup_timeout: 10)
    end

    def real_store
      Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new)
    end

    before do
      git("init", "-q", "-b", "main", main)
      git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
      git("-C", main, "worktree", "add", "-q", "-b", "feat/login", login)
    end

    it "D-C4: `dev down --force` signals a recorded pgid that was reused by an unrelated live process group" do
      victim = spawn_group("sleep", "30")
      reaper = Process.detach(victim)
      # The wrapper's pid (== its pgid) has been reused: the pid is running,
      # but with a different start time, so the holder reads as stale.
      Workspace::LockStore.new(dir: lock_dir, liveness: adv_liveness).acquire("devenv",
        identity: {kind: "process", pid: victim, started: "Sat Jan  1 00:00:00 2000", pgid: victim, worktree: login, branch: "feat/login"},
        waiter_pid: victim, waiter_started: "Sat Jan  1 00:00:00 2000")
      expect(real_store.status("devenv").dig("devenv", "holder", "stale")).to be(true)

      dev.down(force: true, working_dir: main)

      expect(reaper.join(0.5)).to be_nil, "an unrelated process group that reused the dead wrapper's pgid was killed"
    end

    it "D-C5: `dev up --takeover` fails when a waiter is queued: the stopped holder's release promotes the waiter, not the taker" do
      expect(dev.up(working_dir: login)).to eq(exit_code: 0)
      waiter = spawn_group("sleep", "30")
      Process.detach(waiter)
      started = Workspace::LockHolder.new.start_time(waiter)
      queued = real_store.acquire("devenv",
        identity: {kind: "process", pid: waiter, started: started, pgid: waiter, worktree: "/elsewhere", branch: "feat/other"},
        waiter_pid: waiter, waiter_started: started, wait: true)
      expect(queued[:status]).to eq(:queued)

      result = dev.up(takeover: true, working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(real_store.status("devenv").dig("devenv", "holder")).to include("worktree" => main)
    end
  end
end
