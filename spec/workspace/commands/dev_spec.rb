require "spec_helper"
require "tmpdir"
require "timeout"
require "rbconfig"
require "socket"
require "json"

RSpec.describe Workspace::Commands::Dev do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-dev-command")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:main) { File.join(tmpdir, "app") }
  let(:login) { File.join(tmpdir, "app-login") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:spawned) { [] }
  let(:dev_settings) { {"up" => "exec sleep 30", "stop_timeout" => 2} }
  let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
  let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => dev_settings})) }
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
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

  def spawn_wrapper(cwd, wait, env = {})
    log = File.join(tmpdir, "wrapper-#{spawned.size}.log")
    pid = Process.spawn({"SKIP_SIMPLECOV" => "1", **env}, RbConfig.ruby, "-e", wrapper_script, lock_dir,
      JSON.generate("dev" => dev_settings), wait ? "1" : "0", chdir: cwd, pgroup: true, in: File::NULL, out: log, err: log)
    Process.detach(pid)
    spawned << pid
    pid
  end

  def git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(" ")} failed"
  end

  def dev(**opts)
    described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
      lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: nil,
      terminator: Workspace::ProcessGroupTerminator.new(poll_interval: 0.05), tmux: tmux, executable: "/ws/bin/workspace",
      output: output, error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 0.05, startup_timeout: 10, **opts)
  end

  def holder
    Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new).status("devenv").dig("devenv", "holder")
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    result
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  around do |example|
    Timeout.timeout(40) { example.run }
  end

  before do
    git("init", "-q", "-b", "main", main)
    git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
    git("-C", main, "worktree", "add", "-q", "-b", "feat/login", login)
  end

  after do
    spawned.each do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  describe "#up" do
    it "opens a devenv window running the hidden wrapper and waits for it to hold the lock" do
      result = dev.up(working_dir: login)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Dev environment running for app-login (feat/login) in app:devenv.")
      expect(tmux.windows).to eq([{session: "app", name: "devenv", cwd: login, command: [RbConfig.ruby, "/ws/bin/workspace", "dev", "__run"]}])
      expect(holder).to include("kind" => "process", "pid" => spawned.last, "pgid" => spawned.last, "worktree" => login, "branch" => "feat/login")
    end

    it "is idempotent when this worktree already holds the lock" do
      dev.up(working_dir: login)

      result = dev.up(working_dir: login)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Dev environment is already running for app-login (feat/login).")
      expect(tmux.windows.size).to eq(1)
    end

    it "refuses with the holder's worktree and branch when another worktree holds it" do
      dev.up(working_dir: login)

      result = dev.up(working_dir: main)

      expect(result).to eq(exit_code: 1)
      expect(error_output.string).to include("Dev environment is running for app-login (feat/login). Use --wait to queue or --takeover to switch.")
      expect(tmux.windows.size).to eq(1)
    end

    it "takes over: stops the other worktree's env before starting its own" do
      dev.up(working_dir: login)
      first = spawned.last

      result = dev.up(takeover: true, working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Taking over: stopping dev environment for app-login (feat/login)...")
      expect(alive?(first)).to be(false)
      expect(holder).to include("pid" => spawned.last, "worktree" => main, "branch" => "main")
    end

    it "queues with --wait and starts once the holder stops" do
      dev.up(working_dir: login)
      stopper = Thread.new do
        wait_until { output.string.include?("Trying to obtain workspace devenv lock") }
        dev(output: StringIO.new).down(working_dir: login)
      end

      result = dev.up(wait: true, working_dir: main)
      stopper.join

      expect(result).to eq(exit_code: 0)
      expect(tmux.windows.last[:command]).to end_with("__run", "--wait")
      expect(holder).to include("pid" => spawned.last, "worktree" => main)
    end

    it "exits 75 and withdraws the queued wrapper when --max-wait passes" do
      dev.up(working_dir: login)

      result = dev.up(wait: true, max_wait: 0.5, working_dir: main)

      expect(result).to eq(exit_code: 75)
      wait_until { !alive?(spawned.last) }
      expect(Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new).status("devenv").dig("devenv", "queue")).to be_empty
    end

    context "with a ready check" do
      it "waits until the ready port accepts connections" do
        port = free_port
        dev_settings.merge!("up" => %(exec #{RbConfig.ruby} -rsocket -e 'sleep 0.3; s = TCPServer.new("127.0.0.1", #{port}); loop { s.accept.close }'),
          "ready" => "port:#{port}")

        result = dev.up(working_dir: login)

        expect(result).to eq(exit_code: 0)
        expect { TCPSocket.new("127.0.0.1", port).close }.not_to raise_error
      end

      it "exits 6, stops the env, and releases the lock when the check times out" do
        dev_settings["ready"] = "port:#{free_port}"

        result = dev(ready_timeout: 0.5).up(working_dir: login)

        expect(result).to eq(exit_code: 6)
        expect(error_output.string).to include("did not pass within")
        expect(alive?(spawned.last)).to be(false)
        expect(holder).to be_nil
      end

      it "skips the check with ready: false" do
        dev_settings["ready"] = "false"

        expect(dev.up(ready: false, working_dir: login)).to eq(exit_code: 0)
      end

      it "treats a non-port check as a shell command run in the worktree" do
        dev_settings["ready"] = "test -f ready.txt"
        File.write(File.join(login, "ready.txt"), "")

        expect(dev.up(working_dir: login)).to eq(exit_code: 0)
      end
    end

    it "raises with setup instructions when no dev command is configured" do
      dev_settings.delete("up")

      expect { dev.up(working_dir: login) }.to raise_error(Workspace::Error, 'No dev command configured. Set one with: workspace config set dev.up "<command>"')
    end
  end

  describe "#down" do
    it "stops the env from any worktree of the repo and frees the lock" do
      dev.up(working_dir: login)
      wrapper = spawned.last

      result = dev.down(working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Stopped dev environment for app-login (feat/login).")
      expect(alive?(wrapper)).to be(false)
      expect(holder).to be_nil
    end

    it "reports nothing to stop" do
      expect(dev.down(working_dir: main)).to eq(exit_code: 0)
      expect(output.string).to eq("No dev environment is running.\n")
    end

    it "reports a SIGKILLed wrapper's orphaned group, and kills it with force" do
      dev.up(working_dir: login)
      wrapper = spawned.last
      Process.kill("KILL", wrapper)
      wait_until { !alive?(wrapper) }
      expect(Workspace::ProcessGroupTerminator.new.running?(wrapper)).to be(true)

      expect(dev.down(working_dir: main)).to eq(exit_code: 1)
      expect(error_output.string).to include("process group #{wrapper} is still running", "workspace dev down --force")

      expect(dev.down(force: true, working_dir: main)).to eq(exit_code: 0)
      expect(output.string).to include("Killed orphaned dev process group #{wrapper}")
      expect(Workspace::ProcessGroupTerminator.new.running?(wrapper)).to be(false)
      expect(holder).to be_nil
    end
  end

  describe "#status" do
    it "shows the holder, branch, pid, pane, uptime and readiness" do
      dev_settings["ready"] = "true"
      dev.up(working_dir: login)
      output.truncate(0)
      output.rewind

      dev.status(working_dir: main)

      expect(output.string).to include("Dev environment: running for app-login (feat/login)")
      expect(output.string).to match(/pid #{spawned.last}, pgid #{spawned.last}, pane %9, up \d+s/)
      expect(output.string).to include("ready: yes (true)")
    end

    it "reports no environment" do
      dev.status(working_dir: main)

      expect(output.string).to eq("No dev environment is running.\n")
    end
  end

  describe "#run" do
    it "runs the configured command for this worktree through the dev runner" do
      runner = double("dev_runner")
      allow(runner).to receive(:call).and_return(3)

      result = described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
        lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: runner,
        terminator: nil, tmux: nil, executable: "unused", env: {}).run(wait: true, working_dir: login)

      expect(result).to eq(exit_code: 3)
      expect(runner).to have_received(:call).with(store: an_instance_of(Workspace::LockStore), command: "exec sleep 30",
        worktree: login, branch: "feat/login", wait: true, priority: false)
    end

    it "queues ahead of everyone when its window was opened by a takeover" do
      runner = double("dev_runner")
      allow(runner).to receive(:call).and_return(0)

      described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
        lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: runner, terminator: nil, tmux: nil,
        executable: "unused", env: {"WORKSPACE_DEV_TAKEOVER" => "1"}).run(wait: true, working_dir: login)

      expect(runner).to have_received(:call).with(hash_including(wait: true, priority: true))
    end
  end
end

RSpec.describe Workspace::Commands::Dev, "with fake processes and clock" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-dev-unit")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:worktree) { tmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:settings) { {"up" => "run-dev", "stop_timeout" => 2} }
  let(:liveness) { FakeLockLiveness.new }
  let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
  let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => settings})) }
  let(:lineage) { double("lineage", resolve: double(name: "app", worktree: nil)) }
  let(:terminator) { double("terminator", running?: false) }
  let(:tmux) { double("tmux", session_name_for_pane: "app", sessions: ["app"], session_name_for: "app") }
  let(:dead_pids) { [] }
  let(:signals) { [] }
  let(:now) { [0.0] }
  let(:on_sleep) { [] }

  def dev(**opts)
    described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, lineage: lineage, dev_config: dev_config,
      dev_runner: nil, terminator: terminator, tmux: tmux, executable: "/ws/bin/workspace", output: output,
      error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 1, startup_timeout: 5, ready_timeout: 5,
      clock: Struct.new(:now_ref) { def now = now_ref[0] }.new(now),
      sleeper: ->(seconds) {
        now[0] += seconds
        on_sleep.shift&.call
      },
      kill: ->(signal, pid) {
        signals << [signal, pid] unless signal == 0
        raise Errno::ESRCH if dead_pids.include?(pid)
        1
      }, **opts)
  end

  def store
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
  end

  def process_identity(pid, worktree: "/w/other", branch: "feat/other")
    {kind: "process", pid: pid, started: "s-#{pid}", pgid: pid, pane: "%7", worktree: worktree, branch: branch}
  end

  def hold(pid, **opts)
    store.acquire("devenv", identity: process_identity(pid, **opts), waiter_pid: pid, waiter_started: "s-#{pid}")
  end

  def enqueue(pid, **opts)
    store.acquire("devenv", identity: process_identity(pid, **opts), waiter_pid: pid, waiter_started: "s-#{pid}", wait: true)
  end

  def holder
    store.status("devenv").dig("devenv", "holder")
  end

  def orphan(pid)
    hold(pid)
    liveness.kill(pid)
    dead_pids << pid
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  # Stands in for the `dev __run` wrapper tmux would start: it takes or
  # queues for the lock the way DevRunner does, with the window env given.
  def wrapper_joins(pid, wait: true)
    allow(tmux).to receive(:new_window) do |_session, env:, **|
      store.acquire("devenv", identity: process_identity(pid, worktree: worktree, branch: nil), waiter_pid: pid,
        waiter_started: "s-#{pid}", wait: wait, priority: env["WORKSPACE_DEV_TAKEOVER"] == "1")
      pid
    end
  end

  describe "#up --takeover" do
    it "queues the new wrapper ahead of an earlier waiter so the stopped holder's lock passes to it" do
      hold(700)
      enqueue(800)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:new_window).with("app", hash_including(env: {"WORKSPACE_DEV_TAKEOVER" => "1"}))
      expect(holder).to include("pid" => 555)
      expect(store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }).to eq([800])
    end
  end

  describe "a process group this user may not signal" do
    let(:foreign) { Workspace::Error.new("process group 700 has running processes this user is not permitted to signal") }

    it "`status` reports it instead of failing" do
      orphan(700)
      allow(terminator).to receive(:running?).and_raise(foreign)

      expect(dev.status(working_dir: worktree)).to eq(exit_code: 0)
      expect(output.string).to include("wrapper pid 700 is gone; process group 700 has running processes this user is not permitted to signal")
    end

    it "`down --force` raises and keeps the stale lock" do
      orphan(700)
      allow(terminator).to receive(:running?).and_raise(foreign)

      expect { dev.down(force: true, working_dir: worktree) }.to raise_error(Workspace::Error, /not permitted/)
      expect(File.read(File.join(lock_dir, "locks.json"))).to include('"pid": 700')
    end

    it "`down` of a live holder raises and keeps its lock" do
      hold(700)
      allow(terminator).to receive(:stop_holder).and_raise(foreign)

      expect { dev.down(working_dir: worktree) }.to raise_error(Workspace::Error, /not permitted/)
      expect(holder).to include("pid" => 700)
    end
  end
end
