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

    let(:kills) { [] }

    # The group is this rspec process's own pid, so its real members are
    # never looked up: each example says who else is in it.
    def runner(**opts)
      described_class.new(liveness: liveness, output: output, env: {"TMUX_PANE" => "%7"}, trap: trap,
        pgrp: -> { Process.pid }, kill: ->(signal, target) { kills << [signal, target] }, sleeper: ->(_) {},
        group_members: ->(_pgid) { [Process.pid] }, **opts)
    end

    def run_with(store: fake_store, **opts)
      seams = %i[spawner kill pgrp sleeper group_members]
      runner(**opts.slice(*seams)).call(store: store, **opts.except(*seams))
    end

    it "records a process-kind holder with its pgid, branch, pane and worktree" do
      seen = nil
      spawner = lambda do |command, chdir|
        seen = devenv_holder
        Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end

      run_with(spawner: spawner, command: "true", worktree: worktree, branch: "login")

      expect(seen).to include("kind" => "process", "pid" => Process.pid, "started" => "start-#{Process.pid}",
        "pgid" => Process.pid, "pane" => "%7", "worktree" => worktree, "branch" => "login")
    end

    it "runs through the shell in the worktree root and releases the lock on normal exit" do
      code = run_with(command: "pwd -P > out.txt; exit 3", worktree: worktree)

      expect(code).to eq(3)
      expect(File.read(File.join(worktree, "out.txt")).strip).to eq(File.realpath(worktree))
      expect(devenv_holder).to be_nil
    end

    it "prints one header line and one exit-status line" do
      run_with(command: "exit 0", worktree: worktree)

      expect(output.string.lines).to eq([
        "[workspace] devenv lock held for #{worktree}; running: exit 0\n",
        "[workspace] exit 0 exited with status 0; devenv lock released\n"
      ])
    end

    it "releases the lock when the child crashes" do
      code = run_with(command: "kill -USR1 $$", worktree: worktree)

      expect(code).to eq(128 + Signal.list["USR1"])
      expect(output.string).to include("exited on SIGUSR1")
      expect(devenv_holder).to be_nil
    end

    it "holds the lock until the rest of its process group has exited" do
      members = [[Process.pid, 4321], [Process.pid, 4321], [Process.pid]].each
      held = []
      code = run_with(command: "exit 0", worktree: worktree, group_members: ->(_pgid) { members.next },
        sleeper: ->(_) { held << devenv_holder&.dig("pid") })

      expect(code).to eq(0)
      expect(held).to eq([Process.pid, Process.pid])
      expect(output.string.scan("waiting for").size).to eq(1)
      expect(output.string).to include("Command exited; waiting for 1 process(es) left in process group #{Process.pid} " \
        "to exit before releasing the devenv lock.")
      expect(devenv_holder).to be_nil
    end

    it "counts a process table it cannot read as its group still running" do
      members = [-> { raise Workspace::Error, "ps failed" }, -> { [Process.pid] }].each
      held = []
      run_with(command: "exit 0", worktree: worktree, group_members: ->(_pgid) { members.next.call },
        sleeper: ->(_) { held << devenv_holder&.dig("pid") })

      expect(held).to eq([Process.pid])
      expect(devenv_holder).to be_nil
    end

    it "releases the lock when the command cannot be started" do
      expect { run_with(command: "true", worktree: File.join(tmpdir, "missing")) }
        .to raise_error(Workspace::Error, /cannot run true/)
      expect(devenv_holder).to be_nil
    end

    it "installs INT, TERM and HUP handlers only while running, then restores them" do
      during = nil
      spawner = lambda do |command, chdir|
        during = traps.dup
        Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end

      run_with(spawner: spawner, command: "true", worktree: worktree)

      expect(during.keys).to contain_exactly("INT", "TERM", "HUP")
      expect(during.values).to all(be_a(Proc))
      expect(traps.values).to all(eq("DEFAULT"))
    end

    it "forwards a TERM that arrives before the child is spawned to its own process group, ignoring its own copy" do
      child = nil
      spawner = lambda do |command, chdir|
        traps["TERM"].call
        child = Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end
      kill = lambda do |signal, target|
        kills << [signal, target, traps[signal]]
        Process.kill(signal, child)
      end

      code = run_with(spawner: spawner, kill: kill, command: "exec sleep 5", worktree: worktree)

      expect(code).to eq(128 + Signal.list["TERM"])
      expect(kills).to eq([["TERM", -Process.pid, "IGNORE"]])
      expect(traps["TERM"]).to eq("DEFAULT")
      expect(devenv_holder).to be_nil
    end

    it "forwards each signal to the group only once" do
      child = nil
      handler = nil
      spawner = lambda do |command, chdir|
        handler = traps["TERM"]
        handler.call
        child = Process.spawn("/bin/sh", "-c", command, chdir: chdir)
      end
      kill = lambda do |signal, target|
        kills << [signal, target]
        handler.call
        Process.kill(signal, child)
      end

      run_with(spawner: spawner, kill: kill, command: "exec sleep 5", worktree: worktree)

      expect(kills).to eq([["TERM", -Process.pid]])
    end

    it "refuses to run unless it leads its own process group" do
      spawner = ->(*) { raise "should not spawn" }

      expect { run_with(pgrp: -> { Process.pid + 1 }, spawner: spawner, command: "true", worktree: worktree) }
        .to raise_error(Workspace::Error, /must lead its own process group/)
      expect(devenv_holder).to be_nil
    end

    describe "with wait: true" do
      let(:other) { {kind: "process", pid: 4242, started: "s", pgid: 4242, pane: "%3", worktree: "/w/other", branch: "main"} }

      def hold_as_other(store)
        store.acquire("devenv", identity: other, waiter_pid: 4242, waiter_started: "s")
      end

      it "queues behind the holder, then runs once promoted with its process fields intact" do
        store = fake_store
        hold_as_other(store)
        seen = nil
        sleeper = ->(_) { store.release("devenv", 4242) }
        spawner = lambda do |command, chdir|
          seen = devenv_holder(store)
          Process.spawn("/bin/sh", "-c", command, chdir: chdir)
        end

        code = run_with(store: store, sleeper: sleeper, spawner: spawner, command: "true", worktree: worktree, branch: "login", wait: true)

        expect(code).to eq(0)
        expect(seen).to include("kind" => "process", "pid" => Process.pid, "pgid" => Process.pid, "branch" => "login", "worktree" => worktree)
        expect(output.string).to start_with("[workspace] Trying to obtain workspace devenv lock...\n")
        expect(devenv_holder(store)).to be_nil
      end

      it "with priority: true, queues ahead of an earlier waiter so the holder's release promotes it" do
        store = fake_store
        hold_as_other(store)
        store.acquire("devenv", identity: other.merge(pid: 5151, pgid: 5151), waiter_pid: 5151, waiter_started: "s", wait: true)
        queue = nil
        sleeper = lambda do |_|
          queue ||= store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }
          store.release("devenv", 4242)
        end

        code = run_with(store: store, sleeper: sleeper, spawner: ->(command, chdir) { Process.spawn("/bin/sh", "-c", command, chdir: chdir) },
          command: "true", worktree: worktree, wait: true, priority: true)

        expect(code).to eq(0)
        expect(queue).to eq([Process.pid, 5151])
        expect(devenv_holder(store)).to include("pid" => 5151)
      end

      it "returns 4 without running when the lock is cleared while queued" do
        store = fake_store
        hold_as_other(store)
        sleeper = ->(_) { store.clear("devenv") }

        code = run_with(store: store, sleeper: sleeper, spawner: ->(*) { raise "should not spawn" },
          command: "true", worktree: worktree, wait: true)

        expect(code).to eq(4)
        expect(output.string).to include("devenv lock was cleared while waiting")
      end

      it "leaves the queue when interrupted while waiting" do
        store = fake_store
        hold_as_other(store)
        sleeper = ->(_) { traps["TERM"].call }

        code = run_with(store: store, sleeper: sleeper, spawner: ->(*) { raise "should not spawn" },
          command: "true", worktree: worktree, wait: true)

        expect(code).to eq(128 + Signal.list["TERM"])
        expect(store.status("devenv").dig("devenv", "queue")).to be_empty
        expect(traps.values).to all(eq("DEFAULT"))
      end
    end

    it "fails cleanly without spawning when another holder has the lock" do
      store = fake_store
      store.acquire("devenv", identity: {kind: "process", pid: 4242, started: "s", pgid: 4242, pane: "%3", worktree: "/w/other", branch: "main"},
        waiter_pid: 4242, waiter_started: "s")
      spawner = ->(*) { raise "should not spawn" }

      expect { run_with(store: store, spawner: spawner, command: "true", worktree: worktree) }
        .to raise_error(Workspace::Error, "devenv lock is held by pid 4242 (pane %3, worktree /w/other, branch main)")
      expect(devenv_holder(store)["pid"]).to eq(4242)
      expect(output.string).to be_empty
    end

    it "raises when its own start time cannot be read" do
      allow(liveness).to receive(:start_time).and_return(nil)

      expect { run_with(command: "true", worktree: worktree) }.to raise_error(Workspace::Error, /start time/)
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
        runner = Workspace::DevRunner.new(liveness: liveness, env: {"TMUX_PANE" => "%9"}, poll: 0.1)
        begin
          exit runner.call(store: store, command: command, worktree: worktree, branch: "login", wait: ENV["DEV_WAIT"] == "1")
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

    it "reaches the whole group with exactly one SIGTERM when only the wrapper is signalled" do
      script = 'n = 0; trap("TERM") { n += 1 }; File.write("child.pid", $$.to_s); sleep 0.05 until n > 0; sleep 0.5; File.write("terms.txt", n.to_s)'
      pid = spawn_wrapper(%(sleep 30 & echo $! > grandchild.pid; #{RbConfig.ruby} -e '#{script}'))
      wait_for_child_marker("child.pid")
      grandchild = wait_for_child_marker("grandchild.pid")

      Process.kill("TERM", pid)
      exit_status(pid)

      expect(wait_until { File.read(File.join(worktree, "terms.txt")) if File.exist?(File.join(worktree, "terms.txt")) }).to eq("1")
      expect { Process.kill(0, grandchild) }.to raise_error(Errno::ESRCH)
      expect(devenv_holder(real_store)).to be_nil
    end

    it "keeps the lock until a process the command left in its group exits" do
      pid = spawn_wrapper("sleep 1 & echo $! > bg.pid; exit 0")
      background = wait_for_child_marker("bg.pid")
      wait_until { File.read(File.join(tmpdir, "wrapper.log")).include?("Command exited; waiting for 1 process(es)") }

      expect(devenv_holder(real_store)).to include("pid" => pid)
      expect(exit_status(pid).exitstatus).to eq(0)
      expect { Process.kill(0, background) }.to raise_error(Errno::ESRCH)
      expect(devenv_holder(real_store)).to be_nil
    end

    it "queues behind a live holder with wait and runs once it releases" do
      holder = real_store.acquire("devenv", identity: {kind: "agent", pid: Process.pid, started: Workspace::LockHolder.new.start_time},
        waiter_pid: Process.pid, waiter_started: "x")
      expect(holder).to eq(status: :acquired)
      log = File.join(tmpdir, "wrapper.log")
      pid = Process.spawn({"SKIP_SIMPLECOV" => "1", "DEV_WAIT" => "1"}, *wrapper_argv("echo $$ > child.pid; exec sleep 30"),
        pgroup: true, in: File::NULL, out: log, err: log)
      spawned << [pid, pid]
      wait_until { File.read(log).include?("Trying to obtain workspace devenv lock") }
      expect(File.exist?(File.join(worktree, "child.pid"))).to be(false)

      real_store.release("devenv", Process.pid)
      wait_for_child_marker("child.pid")

      expect(devenv_holder(real_store)).to include("pid" => pid, "kind" => "process", "pgid" => pid, "branch" => "login")
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

  it "sends SIGTERM to the leader alone when given one, and SIGKILL to the group after stop_timeout" do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "child-term")
      child = %(trap("TERM") { File.write(#{marker.inspect}, "x") }; sleep 30)
      reader, writer = IO.pipe
      pid = Process.spawn(RbConfig.ruby, "-e",
        %(Process.spawn(RbConfig.ruby, "-e", #{child.inspect}); trap("TERM") { exit }; puts "ready"; $stdout.flush; sleep 30),
        pgroup: true, in: File::NULL, out: writer)
      writer.close
      spawned << pid
      Process.detach(pid)
      reader.gets
      sleep 0.2

      result = described_class.new(poll_interval: 0.05).terminate(pid, stop_timeout: 0.5, leader: pid)

      expect(result).to eq(:killed)
      expect(File.exist?(marker)).to be(false)
    ensure
      reader&.close
    end
  end

  it "lists a group's live members, without the `ps` it runs" do
    pgid = spawn_group("sleep 30")

    expect(described_class.new.live_member_pids(pgid)).to eq([pgid])
    expect(described_class.new.live_member_pids(Process.getpgrp)).not_to be_empty
  end

  describe "#orphan_running?" do
    let(:holder) { {"pid" => 4242, "started" => "s", "pgid" => 4242} }

    it "is true while a dead wrapper's group still has members" do
      terminator = described_class.new(kill: ->(_sig, target) { raise Errno::ESRCH if target == 4242 }, own_pgid: 1)

      expect(terminator.orphan_running?(holder)).to be(true)
    end

    it "is false once another process has taken the wrapper's pid, without probing the group" do
      sent = []
      terminator = described_class.new(kill: ->(sig, target) { sent << [sig, target] }, own_pgid: 1)

      expect(terminator.orphan_running?(holder)).to be(false)
      expect(sent).to eq([[0, 4242]])
    end
  end

  describe "#stop_holder" do
    it "signals nothing when the holder's pid and start time no longer match" do
      pgid = spawn_group("sleep 30")
      liveness = FakeLockLiveness.new(dead: [pgid])

      result = described_class.new.stop_holder({"pid" => pgid, "started" => "s", "pgid" => pgid}, liveness: liveness, stop_timeout: 1)

      expect(result).to eq(:gone)
      expect(described_class.new.running?(pgid)).to be(true)
    end

    it "stops a live holder's group through its wrapper pid" do
      pgid = spawn_group("sleep 30")

      result = described_class.new.stop_holder({"pid" => pgid, "started" => "s", "pgid" => pgid}, liveness: FakeLockLiveness.new, stop_timeout: 5)

      expect(result).to eq(:terminated)
    end
  end

  describe "with a guard" do
    def recording_kill(sent)
      ->(signal, target) { sent << [signal, target] }
    end

    it "sends nothing when the guard fails before the SIGTERM" do
      sent = []
      terminator = described_class.new(kill: recording_kill(sent), own_pgid: 1)

      expect(terminator.terminate(4242, stop_timeout: 1, guard: -> { false })).to eq(:not_running)
      expect(sent).to be_empty
    end

    it "withholds the SIGKILL when the guard fails after the SIGTERM" do
      sent = []
      checks = [true, false].each
      clock = [0, 10].each
      terminator = described_class.new(kill: recording_kill(sent), own_pgid: 1, clock: -> { clock.next }, sleeper: ->(_s) {})

      expect(terminator.terminate(4242, stop_timeout: 1, guard: -> { checks.next })).to eq(:terminated)
      expect(sent).to eq([["TERM", -4242], [0, -4242]])
    end
  end

  describe "when the kernel answers EPERM" do
    def eperm_kill(allowed: [])
      sent = []
      kill = lambda do |signal, target|
        sent << [signal, target]
        raise Errno::EPERM unless allowed.include?(target)
        1
      end
      [kill, sent]
    end

    it "treats a group of only zombies as not running" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["Z", "Z+"] }, own_pgid: 1)

      expect(terminator.running?(4242)).to be(false)
      expect(terminator.terminate(4242, stop_timeout: 0)).to eq(:not_running)
    end

    it "treats a group with no members left as not running" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { [] }, own_pgid: 1)

      expect(terminator.running?(4242)).to be(false)
    end

    it "raises instead of reporting success for a live group it may not signal" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["Z", "Ss"] }, own_pgid: 1)

      expect { terminator.running?(4242) }.to raise_error(Workspace::Error, /process group 4242 has running processes this user is not permitted to signal/)
      expect { terminator.terminate(4242, stop_timeout: 0) }.to raise_error(Workspace::Error, /not permitted/)
    end

    it "names the users owning the group's live processes in the error" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["S"] }, member_owners: ->(_pgid) { ["alice", "root"] },
        own_pgid: 1)

      expect { terminator.running?(4242) }.to raise_error(Workspace::Error, /not permitted to signal \(owned by alice, root: /)
    end

    it "still raises the not-permitted error when the owners cannot be looked up" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["S"] },
        member_owners: ->(_pgid) { raise Workspace::Error, "ps failed" }, own_pgid: 1)

      expect { terminator.running?(4242) }.to raise_error(Workspace::Error, /not permitted to signal \(another user's/)
    end

    it "raises from stop_holder rather than returning a stop that never happened" do
      kill, _sent = eperm_kill
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["S"] }, own_pgid: 1)

      expect {
        terminator.stop_holder({"pid" => 4242, "started" => "s", "pgid" => 4242}, liveness: FakeLockLiveness.new, stop_timeout: 0)
      }.to raise_error(Workspace::Error, /not permitted/)
    end

    it "signals the whole group when its leader is a zombie that cannot take the SIGTERM" do
      kill, sent = eperm_kill(allowed: [-4242])
      clock = [0, 0, 10, 10].each
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["Z", "S"] }, own_pgid: 1,
        clock: -> { clock.next }, sleeper: ->(_s) {})

      expect(terminator.terminate(4242, stop_timeout: 1, leader: 4242)).to eq(:killed)
      expect(sent).to eq([["TERM", 4242], ["TERM", -4242], [0, -4242], [0, -4242], ["KILL", -4242]])
    end

    it "raises when SIGKILL is refused for a group that is still live" do
      kill = lambda do |signal, _target|
        raise Errno::EPERM if signal == "KILL"
        1
      end
      clock = [0, 10].each
      terminator = described_class.new(kill: kill, member_states: ->(_pgid) { ["R"] }, own_pgid: 1,
        clock: -> { clock.next }, sleeper: ->(_s) {})

      expect { terminator.terminate(4242, stop_timeout: 1) }.to raise_error(Workspace::Error, /not permitted/)
    end
  end

  it "refuses to signal its own process group or pgid <= 1" do
    expect { described_class.new.terminate(Process.getpgrp, stop_timeout: 1) }.to raise_error(Workspace::Error)
    expect { described_class.new.terminate(1, stop_timeout: 1) }.to raise_error(Workspace::Error)
  end
end
