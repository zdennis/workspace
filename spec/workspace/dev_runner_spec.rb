require "spec_helper"
require "tmpdir"
require "timeout"
require "rbconfig"
require "pty"
require "workspace/dev_runner"
require "workspace/process_group_terminator"

RSpec.describe Workspace::DevRunner do
  let(:tmpdir) { Dir.mktmpdir("ws-dev-runner") }
  let(:lock_dir) { File.join(tmpdir, "state", "workspace", "locks", "ns") }
  let(:worktree) { File.join(tmpdir, "app.worktree-login").tap { |d| FileUtils.mkdir_p(d) } }
  let(:output) { StringIO.new }
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }
  let(:spawned) { [] }

  around do |example|
    Timeout.timeout(20) { example.run }
  end

  after do
    spawned.each do |pid, pgid|
      begin
        Process.kill("KILL", -pgid) if pgid
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      begin
        Process.kill("KILL", pid) if pid
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid) if pid
      rescue Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    result
  end

  def fake_store(liveness = FakeLockLiveness.new)
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
  end

  def real_store
    Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new)
  end

  def devenv_holder(store = fake_store)
    store.status("devenv").dig("devenv", "holder")
  end

  describe "in process (trap seam, no real signal handlers)" do
    let(:traps) { {} }
    let(:trap) { ->(signal, handler) { traps.fetch(signal, "DEFAULT").tap { traps[signal] = handler } } }
    let(:liveness) { FakeLockIdentity.new(pid: Process.pid) }

    def runner(store: fake_store, **opts)
      described_class.new(store: store, liveness: liveness, output: output, env: {"TMUX_PANE" => "%7"}, trap: trap, **opts)
    end

    it "records a process-kind holder with its pgid, branch, pane and worktree" do
      seen = nil
      spawner = lambda do |command, chdir|
        seen = devenv_holder
        Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end

      runner(spawner: spawner).call(command: "true", worktree: worktree, branch: "login")

      expect(seen).to include("kind" => "process", "pid" => Process.pid, "started" => "start-#{Process.pid}",
        "pgid" => Process.getpgrp, "pane" => "%7", "worktree" => worktree, "branch" => "login")
    end

    it "runs through the shell in the worktree root and releases the lock on normal exit" do
      code = runner.call(command: "pwd -P > out.txt; exit 3", worktree: worktree)

      expect(code).to eq(3)
      expect(File.read(File.join(worktree, "out.txt")).strip).to eq(File.realpath(worktree))
      expect(devenv_holder).to be_nil
    end

    it "prints one header line and one exit-status line" do
      runner.call(command: "exit 0", worktree: worktree)

      expect(output.string.lines).to eq([
        "[workspace] devenv lock held for #{worktree}; running: exit 0\n",
        "[workspace] exit 0 exited with status 0; devenv lock released\n"
      ])
    end

    it "releases the lock when the child crashes" do
      code = runner.call(command: "kill -USR1 $$", worktree: worktree)

      expect(code).to eq(128 + Signal.list["USR1"])
      expect(output.string).to include("exited on SIGUSR1")
      expect(devenv_holder).to be_nil
    end

    it "releases the lock when the command cannot be started" do
      expect { runner.call(command: "true", worktree: File.join(tmpdir, "missing")) }
        .to raise_error(Workspace::Error, /cannot run true/)
      expect(devenv_holder).to be_nil
    end

    it "installs INT, TERM and HUP handlers only while running, then restores them" do
      during = nil
      spawner = lambda do |command, chdir|
        during = traps.dup
        Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end

      runner(spawner: spawner).call(command: "true", worktree: worktree)

      expect(during.keys).to contain_exactly("INT", "TERM", "HUP")
      expect(during.values).to all(be_a(Proc))
      expect(traps.values).to all(eq("DEFAULT"))
    end

    it "forwards a TERM that arrives before the child is spawned" do
      spawner = lambda do |command, chdir|
        traps["TERM"].call
        Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end

      code = runner(spawner: spawner).call(command: "exec sleep 5", worktree: worktree)

      expect(code).to eq(128 + Signal.list["TERM"])
      expect(devenv_holder).to be_nil
    end

    it "fails cleanly without spawning when another holder has the lock" do
      store = fake_store
      store.acquire("devenv", identity: {kind: "process", pid: 4242, started: "s", pgid: 4242, pane: "%3", worktree: "/w/other", branch: "main"},
        waiter_pid: 4242, waiter_started: "s")
      spawner = ->(*) { raise "should not spawn" }

      expect { runner(store: store, spawner: spawner).call(command: "true", worktree: worktree) }
        .to raise_error(Workspace::Error, "devenv lock is held by pid 4242 (pane %3, worktree /w/other, branch main)")
      expect(devenv_holder(store)["pid"]).to eq(4242)
      expect(output.string).to be_empty
    end

    it "raises when its own start time cannot be read" do
      allow(liveness).to receive(:start_time).and_return(nil)

      expect { runner.call(command: "true", worktree: worktree) }.to raise_error(Workspace::Error, /start time/)
    end
  end

  describe "as a spawned wrapper process (real signals)" do
    let(:wrapper_script) do
      <<~RUBY
        $LOAD_PATH.unshift #{lib_dir.inspect}
        require "workspace"
        require "workspace/dev_runner"
        dir, command, worktree = ARGV
        liveness = Workspace::LockHolder.new
        store = Workspace::LockStore.new(dir: dir, liveness: liveness)
        runner = Workspace::DevRunner.new(store: store, liveness: liveness, env: {"TMUX_PANE" => "%9"})
        begin
          exit runner.call(command: command, worktree: worktree, branch: "login")
        rescue Workspace::Error => e
          warn e.message
          exit 1
        end
      RUBY
    end

    def wrapper_argv(command)
      [RbConfig.ruby, "-e", wrapper_script, lock_dir, command, worktree]
    end

    def spawn_wrapper(command)
      log = File.join(tmpdir, "wrapper.log")
      pid = Process.spawn({"SKIP_SIMPLECOV" => "1"}, *wrapper_argv(command), pgroup: true, in: File::NULL, out: log, err: log)
      spawned << [pid, pid]
      pid
    end

    def wait_for_child_marker(name)
      path = File.join(worktree, name)
      wait_until { File.exist?(path) && File.read(path).strip.then { |s| s.empty? ? nil : s.to_i } }
    end

    def exit_status(pid)
      _, status = Process.wait2(pid)
      spawned.map! { |p, g| (p == pid) ? [nil, g] : [p, g] }
      status
    end

    it "forwards SIGTERM to the child and releases the lock" do
      pid = spawn_wrapper("echo $$ > child.pid; exec sleep 30")
      child = wait_for_child_marker("child.pid")
      expect(devenv_holder(real_store)).to include("pid" => pid, "pgid" => pid, "kind" => "process")

      Process.kill("TERM", pid)
      status = exit_status(pid)

      expect(status.exitstatus).to eq(128 + Signal.list["TERM"])
      expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
      expect(devenv_holder(real_store)).to be_nil
    end

    it "leaves a SIGKILLed wrapper's lock to dead-pid reaping" do
      pid = spawn_wrapper("echo $$ > child.pid; exec sleep 30")
      wait_for_child_marker("child.pid")

      Process.kill("KILL", pid)
      exit_status(pid)

      expect(File.read(File.join(lock_dir, "locks.json"))).to include("\"pid\": #{pid}")
      result = real_store.acquire("devenv", identity: {kind: "agent", pid: Process.pid, started: Workspace::LockHolder.new.start_time},
        waiter_pid: Process.pid, waiter_started: "x")
      expect(result).to eq(status: :acquired)
    end

    describe "under a PTY" do
      def pty_run(command)
        reader, writer, pid = PTY.spawn({"SKIP_SIMPLECOV" => "1"}, *wrapper_argv(command))
        spawned << [pid, pid]
        buffer = +""
        yield reader, writer, pid, buffer
      ensure
        writer&.close
        reader&.close
      end

      def drain(reader, buffer)
        return unless reader.wait_readable(0.05)
        buffer << reader.read_nonblock(4096)
      rescue IO::WaitReadable, EOFError, Errno::EIO
        nil
      end

      # macOS blocks a process exiting on a tty until its output is drained,
      # so keep reading the pty while waiting for the wrapper.
      def pty_exit_status(reader, buffer, pid)
        status = wait_until do
          drain(reader, buffer)
          Process.wait2(pid, Process::WNOHANG)&.last
        end
        spawned.map! { |p, g| (p == pid) ? [nil, g] : [p, g] }
        status
      end

      def read_until(reader, buffer, pattern)
        wait_until do
          drain(reader, buffer)
          buffer.match?(pattern)
        end
      end

      it "gives the child the TTY and delivers its output unbuffered" do
        pty_run(%(#{RbConfig.ruby} -e 'puts "tty=\#{$stdout.tty?} \#{$stdin.tty?}"; $stdout.flush; sleep 30')) do |reader, _writer, pid, buffer|
          read_until(reader, buffer, /tty=true true/)
          expect(buffer).to include("[workspace] devenv lock held for #{worktree}")
          Process.kill("TERM", pid)
        end
      end

      it "stops the child on Ctrl-C and releases the lock" do
        pty_run(%(#{RbConfig.ruby} -e 'puts "re" + "ady"; $stdout.flush; sleep 30')) do |reader, writer, pid, buffer|
          read_until(reader, buffer, /^ready/)
          expect(devenv_holder(real_store)).to include("pid" => pid)

          writer.write("\x03")
          read_until(reader, buffer, /devenv lock released/)
          status = pty_exit_status(reader, buffer, pid)

          expect(status.exitstatus).to eq(128 + Signal.list["INT"])
          expect(buffer).to include("exited on SIGINT")
          expect(devenv_holder(real_store)).to be_nil
        end
      end

      it "lets a child read stdin without being stopped by SIGTTIN" do
        pty_run(%(#{RbConfig.ruby} -e 'print "na" + "me? "; $stdout.flush; puts "got \#{$stdin.gets.strip}"')) do |reader, writer, pid, buffer|
          read_until(reader, buffer, /name\? /)
          writer.write("zach\n")
          read_until(reader, buffer, /got zach/)

          expect(pty_exit_status(reader, buffer, pid).exitstatus).to eq(0)
        end
      end
    end
  end
end

RSpec.describe Workspace::ProcessGroupTerminator do
  let(:spawned) { [] }

  around do |example|
    Timeout.timeout(20) { example.run }
  end

  after do
    spawned.each do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  def spawn_group(script)
    pid = Process.spawn(RbConfig.ruby, "-e", script, pgroup: true, in: File::NULL)
    spawned << pid
    Process.detach(pid)
    pid
  end

  it "sends SIGTERM and reports :terminated once the group exits" do
    pgid = spawn_group("sleep 30")

    expect(described_class.new.terminate(pgid, stop_timeout: 5)).to eq(:terminated)
    expect(described_class.new.running?(pgid)).to be(false)
  end

  it "sends SIGKILL after stop_timeout when the group ignores SIGTERM" do
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", 'trap("TERM") {}; $stdout.puts "ready"; $stdout.flush; sleep 30', pgroup: true, in: File::NULL, out: writer)
    writer.close
    spawned << pid
    Process.detach(pid)
    reader.gets

    expect(described_class.new(poll_interval: 0.05).terminate(pid, stop_timeout: 0.3)).to eq(:killed)
    sleep 0.2
    expect(described_class.new.running?(pid)).to be(false)
  ensure
    reader&.close
  end

  it "reports :not_running for a group that no longer exists" do
    pgid = spawn_group("exit")
    sleep 0.3

    expect(described_class.new.terminate(pgid, stop_timeout: 1)).to eq(:not_running)
  end

  it "refuses to signal its own process group or pgid <= 1" do
    expect { described_class.new.terminate(Process.getpgrp, stop_timeout: 1) }.to raise_error(Workspace::Error)
    expect { described_class.new.terminate(1, stop_timeout: 1) }.to raise_error(Workspace::Error)
  end
end
