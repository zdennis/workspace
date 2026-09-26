require "spec_helper"
require "tmpdir"
require "rbconfig"

RSpec.describe "Lock adversarial concurrency" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-adv") }
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def identity(pid:, started: "start-#{pid}")
    {kind: "agent", pid: pid, started: started, pane: "%1", worktree: "app"}
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def lock_command(lock_holder:, clock: Time, sleeper: ->(_) {}, trap: ->(_s, _h) { "DEFAULT" }, pid_provider: -> { 2001 })
    namespace = double("LockNamespace", resolve: {key: "k", display: "app", dir: tmpdir})
    Workspace::Commands::Lock.new(config: double("Config"), lock_namespace: namespace, lock_holder: lock_holder,
      output: StringIO.new, error_output: StringIO.new, sleeper: sleeper, clock: clock,
      pid_provider: pid_provider, trap: trap)
  end

  def fake_store
    Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockIdentity.new(pid: 0))
  end

  describe "liveness (real ProcessTree)" do
    let(:holder_check) { Workspace::LockHolder.new(process_tree: Workspace::ProcessTree.new) }
    let(:my_started) { holder_check.start_time(Process.pid) }

    it "C1: a transient `ps` failure must not reap a live holder (double grant)" do
      store = Workspace::LockStore.new(dir: tmpdir, liveness: holder_check)
      store.acquire("edit", identity: identity(pid: Process.pid, started: my_started),
        waiter_pid: Process.pid, waiter_started: my_started)

      failed = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_call_original
      allow(Open3).to receive(:capture3).with("ps", any_args).and_return(["", "ps: fork failed", failed])
      allow(Open3).to receive(:capture3).with(kind_of(Hash), "ps", any_args).and_return(["", "ps: fork failed", failed])

      result = store.acquire("edit", identity: identity(pid: 999_999), waiter_pid: 999_999, waiter_started: "x")

      expect(result[:status]).not_to eq(:acquired)
    end

    it "C2: a holder recorded under one TZ must stay alive when checked from a process with another TZ" do
      started = with_env("TZ" => "UTC") { holder_check.start_time(Process.pid) }

      alive = with_env("TZ" => "Asia/Tokyo") { holder_check.alive?(pid: Process.pid, started: started) }

      expect(alive).to be(true)
    end

    it "C3: a holder recorded under one locale must stay alive when checked from a process with another locale" do
      started = with_env("LC_ALL" => "C") { holder_check.start_time(Process.pid) }

      alive = with_env("LC_ALL" => "fr_FR.UTF-8") { holder_check.alive?(pid: Process.pid, started: started) }

      expect(alive).to be(true)
    end

    it "C4: ps parsing must extract only the start time under a locale whose lstart is not five tokens" do
      entry = with_env("LC_ALL" => "ja_JP.UTF-8") { Workspace::ProcessTree.new.snapshot.find(Process.pid) }

      expect(entry).not_to be_nil
      expect(entry[:lstart]).to match(/\d{2}:\d{2}:\d{2}\s+\d{4}\z/)
    end

    it "C5: one reap takes at most one process-table snapshot (not one `ps` per holder/waiter under the flock)" do
      real = Workspace::ProcessTree.new
      calls = 0
      counting = Object.new
      counting.define_singleton_method(:snapshot) do
        calls += 1
        real.snapshot
      end
      liveness = Workspace::LockHolder.new(process_tree: counting)
      store = Workspace::LockStore.new(dir: tmpdir, liveness: liveness)
      store.acquire("edit", identity: identity(pid: Process.pid, started: my_started),
        waiter_pid: Process.pid, waiter_started: my_started)
      5.times do |i|
        store.acquire("edit", identity: identity(pid: 50_000 + i), waiter_pid: Process.pid,
          waiter_started: my_started, wait: true)
      end

      calls = 0
      store.status

      expect(calls).to be <= 1
    end
  end

  describe "signals and wait-loop races" do
    it "C6: SIGINT arriving while the poll loop holds the flock must not self-deadlock" do
      script = File.join(tmpdir, "waiter.rb")
      File.write(script, <<~RUBY)
        $LOAD_PATH.unshift(#{lib_dir.inspect})
        require "workspace"
        require "stringio"
        dir = #{File.join(tmpdir, "store").inspect}
        seed = Class.new { def alive?(pid:, started:) = true }.new
        Workspace::LockStore.new(dir: dir, liveness: seed).acquire("edit",
          identity: {kind: "agent", pid: 100, started: "s", pane: "%1", worktree: "a"},
          waiter_pid: 100, waiter_started: "s")

        # Slow liveness stands in for `ps` running inside the flock.
        holder = Class.new do
          def current = {kind: "agent", pid: 200, started: "s", pane: "%2", worktree: "b"}
          def start_time(_ = nil) = "s"
          def alive?(pid:, started:)
            sleep 0.3
            true
          end
        end.new
        ns = Struct.new(:dir) { def resolve(cwd:) = {key: "k", display: "a", dir: dir} }.new(dir)
        lock = Workspace::Commands::Lock.new(config: nil, lock_namespace: ns, lock_holder: holder,
          output: StringIO.new, error_output: StringIO.new, sleeper: ->(_) { sleep 0.01 })
        $stdout.puts "READY"
        $stdout.flush
        lock.acquire("edit", wait: true, poll: 0.01)
      RUBY

      reader, writer = IO.pipe
      pid = Process.spawn(RbConfig.ruby, script, out: writer)
      writer.close
      reader.gets
      sleep 1.0
      Process.kill("INT", pid)

      status = nil
      deadline = Time.now + 6
      while Time.now < deadline
        _, status = Process.wait2(pid, Process::WNOHANG)
        break if status
        sleep 0.1
      end
      unless status
        Process.kill("KILL", pid)
        Process.wait(pid)
      end

      expect(status).not_to be_nil, "waiter hung after SIGINT (trap handler blocked on its own flock)"
      expect(status.exitstatus).to eq(130)
    end

    it "C7: --max-wait timing out must not leave the agent holding a lock it was promoted to after its last poll" do
      fake_store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      t0 = Time.now
      calls = 0
      store_dir = tmpdir
      clock = Object.new
      clock.define_singleton_method(:now) do
        calls += 1
        if calls >= 2
          Workspace::LockStore.new(dir: store_dir, liveness: FakeLockIdentity.new(pid: 0)).release("edit", 100)
          t0 + 1000
        else
          t0
        end
      end
      lock = lock_command(lock_holder: FakeLockIdentity.new(pid: 200), clock: clock)

      result = lock.acquire("edit", wait: true, max_wait: 10, working_dir: tmpdir)

      holder = fake_store.status("edit")["edit"]["holder"]
      expect(holder&.dig("pid")).to eq(200)
      expect(result[:exit_code]).to eq(0), "agent 200 holds the lock but was not told it acquired it"
    end

    it "C8: SIGINT after promotion (before the waiter polls) must not leave the agent holding the lock" do
      fake_store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      handlers = {}
      store_dir = tmpdir
      sleeper = lambda do |_|
        Workspace::LockStore.new(dir: store_dir, liveness: FakeLockIdentity.new(pid: 0)).release("edit", 100)
        handlers["INT"].call
      end
      trap = ->(sig, handler) {
        handlers[sig] = handler
        "DEFAULT"
      }
      lock = lock_command(lock_holder: FakeLockIdentity.new(pid: 200), sleeper: sleeper, trap: trap)

      expect { lock.acquire("edit", wait: true, working_dir: tmpdir) }.to raise_error(SystemExit)

      holder = fake_store.status("edit")["edit"]["holder"]
      expect(holder&.dig("pid")).not_to eq(200), "interrupted waiter left its agent holding the lock"
    end

    it "C9: a waiter whose own start time could not be read must not be reaped as 'cleared' (exit 4)" do
      fake_store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      holder = FakeLockIdentity.new(pid: 200)
      holder.define_singleton_method(:start_time) { |_pid = nil| nil }
      store_dir = tmpdir
      sleeper = ->(_) { Workspace::LockStore.new(dir: store_dir, liveness: FakeLockIdentity.new(pid: 0)).release("edit", 100) }
      lock = lock_command(lock_holder: holder, sleeper: sleeper)

      result = begin
        lock.acquire("edit", wait: true, working_dir: tmpdir)
      rescue Workspace::Error => e
        {exit_code: :refused, error: e}
      end

      expect(result[:exit_code]).not_to eq(4)
    end
  end

  describe "corrupt state" do
    it "C10: a truncated locks.json must not fail open and grant a lock that was held" do
      FileUtils.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "locks.json"), '{"edit": {"holder": {"pid": 100, "started": "start-100"')

      result = begin
        fake_store.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200")
      rescue Workspace::Error => e
        {status: :refused, error: e}
      end

      expect(result[:status]).not_to eq(:acquired)
    end

    it "C11: a structurally invalid entry must not wedge the store so that even `clear` crashes" do
      File.write(File.join(tmpdir, "locks.json"), '{"edit": null}')

      expect { fake_store.clear("edit") }.not_to raise_error
    end
  end

  describe "queue integrity" do
    it "C12: the same agent calling acquire --wait twice must not be queued behind itself" do
      s = fake_store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2002, waiter_started: "start-2002", wait: true)

      s.release("edit", 100)
      s.release("edit", 200)

      holder = s.status("edit")["edit"]["holder"]
      expect(holder&.dig("pid")).not_to eq(200), "agent 200 released but was immediately re-granted from its own duplicate queue entry"
    end
  end
end
