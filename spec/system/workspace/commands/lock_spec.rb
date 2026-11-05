require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::Commands::Lock do
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmpdir) { Dir.mktmpdir("ws-lock-command") }
  let(:config) { Workspace::Config.new }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:sleeper) { instance_double("sleeper", call: nil) }
  let(:clock) { class_double(Time, now: base_time) }
  let(:base_time) { Time.utc(2026, 9, 26, 12, 0, 0) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: tmpdir)
  end

  # Each simulated agent needs its own "waiter" pid distinct from this test
  # process's real Process.pid — otherwise two commands built in the same
  # RSpec process would look like the same OS process to the lock store.
  def enqueue_waiter(name:, identity:, task:)
    store = Workspace::LockStore.new(dir: tmpdir, liveness: identity)
    id = identity.current
    store.acquire(name, identity: id, waiter_pid: id[:pid], waiter_started: id[:started], task: task, wait: true)
  end

  def command_for(identity)
    described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: identity,
      output: output, error_output: error_output, sleeper: sleeper, clock: clock,
      pid_provider: -> { identity.current[:pid] },
      # Real Signal.trap is process-wide state; a no-op here keeps tests from
      # leaking signal handlers into whichever example runs next. SIGINT/TERM
      # dequeuing itself is covered directly by LockStore's #dequeue spec.
      trap: ->(signal, handler) {})
  end

  describe "#acquire" do
    it "acquires a free lock and prints the acquired message" do
      result = command_for(FakeLockIdentity.new(pid: 100)).acquire("edit", task: "PROJ-1")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to eq("Acquired edit lock. Release with: workspace lock release edit\n")
    end

    it "is idempotent for the same agent (re-entrant)" do
      identity = FakeLockIdentity.new(pid: 100)
      command_for(identity).acquire("edit")

      result = command_for(identity).acquire("edit")

      expect(result).to eq(exit_code: 0)
    end

    it "refuses with exit 1 when held by another agent and --wait is not given" do
      command_for(FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app.worktree-a")).acquire("edit", task: "task-a")

      result = command_for(FakeLockIdentity.new(pid: 200)).acquire("edit")

      expect(result).to eq(exit_code: 1)
      expect(error_output.string).to include("held by %1 \"task-a\" in app.worktree-a")
    end

    it "exits 5 when this agent already holds a different lock (deadlock rule)" do
      identity = FakeLockIdentity.new(pid: 100)
      command_for(identity).acquire("edit")

      result = command_for(identity).acquire("test")

      expect(result).to eq(exit_code: 5)
      expect(error_output.string).to include("already holding or waiting for 'edit'")
    end

    it "prints the two-line --wait contract and acquires once the holder releases" do
      holder_identity = FakeLockIdentity.new(pid: 100)
      command_for(holder_identity).acquire("edit", task: "the-task")

      waiter_identity = FakeLockIdentity.new(pid: 200)
      waiter_command = command_for(waiter_identity)

      call_count = 0
      allow(sleeper).to receive(:call) do
        call_count += 1
        # Release the lock after the first poll so the loop exits promptly.
        command_for(holder_identity).release("edit") if call_count == 1
      end

      result = waiter_command.acquire("edit", wait: true, poll: 0.01)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include(
        "Trying to obtain workspace edit lock (position 1 of 2, held by %1 \"the-task\" in app)...\n"
      )
      expect(output.string.lines.last).to eq("Acquired edit lock. Release with: workspace lock release edit\n")
    end

    it "exits 4 when the lock is cleared while this agent is waiting" do
      holder_identity = FakeLockIdentity.new(pid: 100)
      command_for(holder_identity).acquire("edit")

      waiter_identity = FakeLockIdentity.new(pid: 200)
      waiter_command = command_for(waiter_identity)

      allow(sleeper).to receive(:call) do
        command_for(holder_identity).clear("edit")
      end

      result = waiter_command.acquire("edit", wait: true, poll: 0.01)

      expect(result).to eq(exit_code: 4)
      expect(error_output.string).to include("cleared while waiting")
    end

    it "exits 75 once --max-wait elapses while still queued" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit")

      waiter_identity = FakeLockIdentity.new(pid: 200)
      times = [base_time, base_time, base_time + 10]
      allow(clock).to receive(:now) { times.shift || base_time + 10 }

      result = command_for(waiter_identity).acquire("edit", wait: true, poll: 0.01, max_wait: 5)

      expect(result).to eq(exit_code: 75)
      expect(error_output.string).to include("Still queued")
    end

    it "queues instead of refusing when given max_wait with wait: false" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit")

      waiter_identity = FakeLockIdentity.new(pid: 200)
      times = [base_time, base_time, base_time + 10]
      allow(clock).to receive(:now) { times.shift || base_time + 10 }

      result = command_for(waiter_identity).acquire("edit", wait: false, poll: 0.01, max_wait: 5)

      expect(result).to eq(exit_code: 75)
      expect(error_output.string).to include("Still queued")
    end

    it "returns the interrupted exit code through the normal {exit_code:} contract, never calling Kernel.exit" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit")

      waiter_identity = FakeLockIdentity.new(pid: 200)
      command = described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: waiter_identity,
        output: output, error_output: error_output, sleeper: sleeper, clock: clock,
        pid_provider: -> { waiter_identity.current[:pid] },
        trap: ->(signal, handler) {
          handler.call if signal == "INT" && handler.respond_to?(:call)
        })

      expect(Kernel).not_to receive(:exit)

      result = command.acquire("edit", wait: true, poll: 0.01)

      expect(result).to eq(exit_code: 130)
    end
  end

  describe "#release" do
    it "releases a held lock" do
      identity = FakeLockIdentity.new(pid: 100)
      command_for(identity).acquire("edit")

      result = command_for(identity).release("edit")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Released edit lock.")
    end

    it "says so when this agent does not hold the lock" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit")

      command_for(FakeLockIdentity.new(pid: 200)).release("edit")

      expect(output.string).to include("edit lock is not held by this agent.")
    end

    it "releases every lock this agent holds with --all" do
      identity = FakeLockIdentity.new(pid: 100)
      command_for(identity).acquire("edit")

      result = command_for(identity).release(nil, all: true)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Released edit lock.")
    end
  end

  describe "a lock held by a workflow run" do
    let(:store) { Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new) }
    let(:run) { {run_id: "wr_1", step: "verify", workflow: "rpiv", workspace: "app.worktree-a", worktree: "/src/app-a", pane: "%4"} }
    let(:agent) { FakeLockIdentity.new(pid: 100, pane: "%4", worktree: "/src/app-a") }

    before { store.acquire_run(%w[test-db], run: run) }

    def bound_command(run_id)
      described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: agent, output: output, error_output: error_output,
        sleeper: sleeper, clock: clock, pid_provider: -> { 100 }, trap: ->(*) {},
        bound_run: instance_double(Workspace::BoundRun, run_id: run_id))
    end

    it "tells the run's own agent the lock is already held for it, instead of queueing behind its run" do
      result = bound_command("wr_1").acquire("test-db", wait: true, task: "run the suite")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to eq("test-db lock is already held for this pane by run wr_1; there is nothing to acquire or release.\n")
      expect(store.status("test-db")["test-db"]).to include("holder" => include("run_id" => "wr_1"), "queue" => [])
    end

    it "refuses an agent in a pane bound to another run, or to none, naming the run" do
      [bound_command("wr_2"), bound_command(nil), command_for(agent)].each do |command|
        expect(command.acquire("test-db")).to eq(exit_code: 1)
      end

      expect(error_output.string.lines.uniq).to eq(["test-db lock is held by run wr_1 (step verify) in /src/app-a.\n"])
    end

    it "still acquires a lock the pane's run does not hold" do
      expect(bound_command("wr_1").acquire("edit")).to eq(exit_code: 0)
      expect(output.string).to include("Acquired edit lock.")
    end

    it "does not count a run that has ended as holding it for the pane" do
      agent.end_run("wr_1")

      expect(bound_command("wr_1").acquire("test-db")).to eq(exit_code: 0)
      expect(output.string).to include("Acquired test-db lock.")
    end

    it "is not released by an agent's release" do
      command_for(agent).release("test-db")

      expect(output.string).to eq("test-db lock is not held by this agent.\n")
      expect(store.status("test-db").dig("test-db", "holder", "run_id")).to eq("wr_1")
    end

    it "shows the run, its step, its delegate and a queued run in status" do
      store.acquire_run(%w[devenv], run: run)
      store.delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 700, started: "start-700", pgid: 700})
      store.acquire_run(%w[devenv], run: run.merge(run_id: "wr_2", step: "implement", worktree: "/src/app-b"))

      command_for(agent).status("devenv")

      expect(output.string.lines.map(&:chomp)).to match([
        a_string_matching(%r{\Adevenv: held by run wr_1 \(step verify\) in /src/app-a \(since \d{4}-[^)]+\) DELEGATE pid 700\z}),
        "  1. run wr_2 (step implement) in /src/app-b"
      ])
    end

    it "tags a delegate whose wrapper is gone as STALE" do
      store.acquire_run(%w[devenv test-db], run: run)
      store.delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 700, started: "start-700", pgid: 700})
      agent.kill(700)

      command_for(agent).status("devenv")

      expect(output.string).to match(/\Adevenv: held by run wr_1 \(step verify\) in \/src\/app-a \(since [^)]+\) DELEGATE pid 700 STALE\n\z/)
    end

    it "stops a run's dev environment on clear, like any devenv holder, and the lock is freed" do
      terminator = instance_double(Workspace::ProcessGroupTerminator, stop_holder: :terminated, running?: false, orphan_running?: false)
      store.acquire_run(%w[devenv test-db], run: run)
      store.delegate("devenv", run_id: "wr_1", identity: {kind: "process", pid: 700, started: "start-700", pgid: 700, worktree: "/src/app-a"})
      clearer = FakeLockIdentity.new(pid: 999)
      command = described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: clearer, output: output,
        error_output: error_output, sleeper: sleeper, clock: Workspace::Commands::Lock::MonotonicClock, pid_provider: -> { 999 },
        trap: ->(*) {}, terminator: terminator)

      expect(command.clear("devenv")).to eq(exit_code: 0)

      expect(terminator).to have_received(:stop_holder).with(hash_including("kind" => "process", "pid" => 700), liveness: clearer, stop_timeout: anything)
      expect(output.string).to include("Stopped process group 700 (pid 700).", "Cleared devenv: was held by ? in /src/app-a")
      expect(store.status("devenv")).to eq({})
      expect(store.status("test-db").dig("test-db", "holder", "run_id")).to eq("wr_1")
    end

    it "names the run, with no blank pid, when a run takes the lock while a clear stops its holder" do
      terminator = instance_double(Workspace::ProcessGroupTerminator, running?: false, orphan_running?: false)
      store.acquire("devenv", identity: {kind: "process", pid: 700, started: "start-700", pgid: 700, worktree: "/w"}, waiter_pid: 700, waiter_started: "start-700")
      allow(terminator).to receive(:stop_holder) do
        store.release("devenv", 700)
        store.acquire_run(%w[devenv], run: run.merge(run_id: "wr_3"))
        :terminated
      end
      clearer = FakeLockIdentity.new(pid: 999)
      command = described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: clearer, output: output,
        error_output: error_output, sleeper: sleeper, clock: Workspace::Commands::Lock::MonotonicClock, pid_provider: -> { 999 },
        trap: ->(*) {}, terminator: terminator)

      expect(command.clear("devenv")).to eq(exit_code: 1)

      expect(error_output.string).to include("devenv lock is now held by run wr_3 (step verify) in /src/app-a, so it was not cleared.")
    end

    it "carries the run's fields in status --json" do
      command_for(agent).status("test-db", json: true)

      holder = JSON.parse(output.string).dig("locks", "test-db", "holder")
      expect(holder).to include("kind" => "run", "run_id" => "wr_1", "step" => "verify", "workflow" => "rpiv",
        "workspace" => "app.worktree-a", "worktree" => "/src/app-a", "pane" => "%4", "stale" => false)
      expect(holder).not_to include("pid")
    end

    it "is cleared like any other holder, and the result names the run" do
      command_for(FakeLockIdentity.new(pid: 999)).clear("test-db")
      store.acquire_run(%w[test-db], run: run)
      output.truncate(0)
      output.rewind
      command_for(FakeLockIdentity.new(pid: 999)).clear("test-db", json: true)

      expect(JSON.parse(output.string)).to include("result" => "cleared",
        "holder" => include("kind" => "run", "run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-a"))
      expect(store.status("test-db")).to eq({})
    end

    it "says in text which run a cleared lock was held by" do
      command_for(FakeLockIdentity.new(pid: 999)).clear("test-db")

      expect(output.string).to eq("Cleared test-db: was held by run wr_1 (step verify) in /src/app-a, 0 waiter(s) removed.\n")
    end
  end

  describe "#status" do
    it "reports a free lock" do
      command_for(FakeLockIdentity.new(pid: 100)).status("edit")

      expect(output.string).to eq("edit lock is free.\n")
    end

    it "reports a held lock and its queue" do
      holder = FakeLockIdentity.new(pid: 100)
      command_for(holder).acquire("edit", task: "the-task")
      # Enqueue directly against the store: going through Commands::Lock#acquire
      # with wait: true would block this test until the lock frees up.
      enqueue_waiter(name: "edit", identity: FakeLockIdentity.new(pid: 200), task: "queued-task")

      command_for(holder).status

      expect(output.string).to include("edit: held by %1 \"the-task\" in app (pid 100")
      expect(output.string).to include("1. %1 \"queued-task\" in app (pid 200)")
    end

    it "tags a holder with a live clearing marker as CLEARING" do
      liveness = Workspace::LockHolder.new
      own_start = liveness.start_time(Process.pid)
      store = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new)
      store.acquire("devenv", identity: {kind: "process", pid: 4242, started: "start-4242", pgid: 4242, worktree: "/w/login"},
        waiter_pid: 4242, waiter_started: "start-4242")
      store.clear("devenv", cleared_by: "pid 999", keep_process_holder: true, clearer: {"pid" => Process.pid, "started" => own_start})

      command = described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: liveness,
        output: output, error_output: error_output, trap: ->(*) {})
      command.status("devenv")

      expect(output.string).to include("CLEARING by pid #{Process.pid}")
    end

    describe "--json" do
      it "emits an empty locks object for an empty store" do
        command_for(FakeLockIdentity.new(pid: 100)).status(json: true)

        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => true, "locks" => {})
      end

      it "emits the holder and queue for a held lock" do
        holder = FakeLockIdentity.new(pid: 100)
        command_for(holder).acquire("edit", task: "the-task")
        enqueue_waiter(name: "edit", identity: FakeLockIdentity.new(pid: 200), task: "queued-task")

        output.truncate(0)
        output.rewind
        command_for(holder).status("edit", json: true)

        payload = JSON.parse(output.string)
        expect(payload["schema_version"]).to eq(1)
        expect(payload["locks"]["edit"]["holder"]).to include("pid" => 100, "task" => "the-task", "stale" => false)
        expect(payload["locks"]["edit"]["queue"].first).to include("agent_pid" => 200, "task" => "queued-task")
      end

      it "emits a JSON error object on stdout, exit 1, for a corrupt locks.json" do
        FileUtils.mkdir_p(tmpdir)
        File.write(File.join(tmpdir, "locks.json"), "{not json")

        result = command_for(FakeLockIdentity.new(pid: 100)).status(json: true)

        expect(result).to eq(exit_code: 1)
        payload = JSON.parse(output.string)
        expect(payload["schema_version"]).to eq(1)
        expect(payload["error"]).to include("corrupt")
        expect(error_output.string).to eq("")
      end
    end
  end

  describe "#clear" do
    it "removes a lock's holder and queue" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit", task: "the-task")

      result = command_for(FakeLockIdentity.new(pid: 999)).clear("edit")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Cleared edit: was held by")
      expect(command_for(FakeLockIdentity.new(pid: 999)).status("edit").tap { |_| }).to eq(exit_code: 0)
    end

    describe "--json" do
      it "emits a cleared result for a held lock" do
        command_for(FakeLockIdentity.new(pid: 100)).acquire("edit", task: "the-task")
        output.truncate(0)
        output.rewind

        result = command_for(FakeLockIdentity.new(pid: 999)).clear("edit", json: true)

        expect(result).to eq(exit_code: 0)
        parsed = JSON.parse(output.string)
        expect(parsed).to include("schema_version" => Workspace::Commands::Lock::JSON_SCHEMA_VERSION, "name" => "edit", "result" => "cleared")
        expect(parsed["holder"]["pid"]).to eq(100)
        expect(error_output.string).to eq("")
      end

      it "emits a not_held result for a name with no entry" do
        result = command_for(FakeLockIdentity.new(pid: 999)).clear("edit", json: true)

        expect(result).to eq(exit_code: 0)
        parsed = JSON.parse(output.string)
        expect(parsed).to eq("schema_version" => Workspace::Commands::Lock::JSON_SCHEMA_VERSION, "ok" => true, "name" => "edit", "result" => "not_held")
      end

      it "emits a results array for --all" do
        command_for(FakeLockIdentity.new(pid: 100)).acquire("edit", task: "the-task")
        output.truncate(0)
        output.rewind

        result = command_for(FakeLockIdentity.new(pid: 999)).clear(nil, all: true, json: true)

        expect(result).to eq(exit_code: 0)
        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(Workspace::Commands::Lock::JSON_SCHEMA_VERSION)
        expect(parsed["results"]).to contain_exactly(include("name" => "edit", "result" => "cleared"))
      end

      it "emits the JSON error contract for a usage error" do
        result = command_for(FakeLockIdentity.new(pid: 999)).clear("bad name!", json: true)

        expect(result).to eq(exit_code: 1)
        parsed = JSON.parse(output.string)
        expect(parsed["schema_version"]).to eq(Workspace::Commands::Lock::JSON_SCHEMA_VERSION)
        expect(parsed["error"]).to be_a(String)
      end
    end

    it "yields the holder record for a kind-specific hook" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("devenv")

      yielded = nil
      command_for(FakeLockIdentity.new(pid: 999)).clear("devenv") { |holder| yielded = holder }

      expect(yielded["pid"]).to eq(100)
    end

    context "with a kind: process holder (the dev wrapper)" do
      let(:liveness) { Workspace::LockHolder.new }
      let(:terminator) { Workspace::ProcessGroupTerminator.new(poll_interval: 0.05) }
      let(:dev_config) { instance_double(Workspace::DevConfig, for_project: {stop_timeout: 2}) }
      let(:group) { Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, in: File::NULL).tap { |pid| Process.detach(pid) } }

      after do
        Process.kill("KILL", -group)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def hold_devenv(started)
        store = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new)
        store.acquire("devenv", identity: {kind: "process", pid: group, started: started, pgid: group, worktree: "/w/login", branch: "login"},
          waiter_pid: group, waiter_started: started)
      end

      def clear_command
        described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: liveness, output: output,
          error_output: error_output, terminator: terminator, dev_config: dev_config, trap: ->(*) {})
      end

      it "stops the recorded process group once the holder's pid and start time are confirmed" do
        sleep 0.1 until liveness.start_time(group)
        hold_devenv(liveness.start_time(group))

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(output.string).to include("Cleared devenv", "Stopped process group #{group} (pid #{group}).")
        expect(terminator.running?(group)).to be(false)
        expect(dev_config).to have_received(:for_project).with("app")
      end

      it "never signals the group when the recorded start time no longer matches" do
        sleep 0.1 until liveness.start_time(group)
        hold_devenv("Thu Jan  1 00:00:00 1970")

        clear_command.clear("devenv")

        expect(terminator.running?(group)).to be(true)
        expect(error_output.string).to include("Process group #{group} was not signalled: its holder pid #{group} is gone, " \
          "and the id now belongs to an unrelated process.")
        expect(error_output.string).not_to include("kill -TERM")
      end
    end

    context "when the process holder's group cannot be stopped" do
      let(:terminator) { instance_double(Workspace::ProcessGroupTerminator) }
      let(:mono) { [0] }
      let(:mono_clock) { double("clock").tap { |c| allow(c).to receive(:now) { mono[0] } } }
      let(:not_permitted) do
        Workspace::Error.new("process group 4242 has running processes this user is not permitted to signal (owned by alice: ...)")
      end

      def hold_devenv
        store = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new)
        store.acquire("devenv", identity: {kind: "process", pid: 4242, started: "start-4242", pgid: 4242, worktree: "/w/login", branch: "login"},
          waiter_pid: 4242, waiter_started: "start-4242")
      end

      def clear_command(dev_config: nil, pid: 999, output: self.output, error_output: self.error_output, event_log: nil)
        described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: FakeLockIdentity.new(pid: pid), output: output,
          error_output: error_output, terminator: terminator, clock: mono_clock, trap: ->(*) {}, pid_provider: -> { pid },
          sleeper: ->(seconds) { mono[0] += seconds }, dev_config: dev_config, event_log: event_log)
      end

      def devenv_holder_pid
        Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new).status("devenv").dig("devenv", "holder", "pid")
      end

      it "keeps the lock and exits 1 when the group belongs to another user, leaving its waiters queued" do
        hold_devenv
        enqueue_waiter(name: "devenv", identity: FakeLockIdentity.new(pid: 300), task: "next")
        allow(terminator).to receive(:stop_holder).and_raise(not_permitted)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 1)
        expect(devenv_holder_pid).to eq(4242)
        queue = Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new).status("devenv")["devenv"]["queue"]
        expect(queue.map { |w| w["agent_pid"] }).to eq([300])
        expect(queue.first).not_to have_key("clearing")
        expect(error_output.string).to include("Could not stop process group 4242 (pid 4242): process group 4242",
          "owned by alice", "Kept devenv lock", "kill -TERM -4242", "workspace lock clear devenv")
        expect(output.string).not_to include("Cleared devenv")
      end

      it "records no lock_cleared for a lock it kept because the group could not be stopped" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_raise(not_permitted)
        event_log = CLITestHelpers::FakeEventLog.new

        expect(clear_command(event_log: event_log).clear("devenv")).to eq(exit_code: 1)

        expect(event_log.events).to be_empty
      end

      it "keeps the lock when the group is still running after SIGKILL" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_return(:killed)
        allow(terminator).to receive(:running?).with(4242).and_return(true)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 1)
        expect(devenv_holder_pid).to eq(4242)
        expect(error_output.string).to include("still running #{described_class::KILL_GRACE_SECONDS}s after SIGKILL", "Kept devenv lock")
      end

      it "waits the project's dev.kill_grace after SIGKILL before keeping the lock" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_return(:killed)
        allow(terminator).to receive(:running?).with(4242).and_return(true)
        dev_config = instance_double(Workspace::DevConfig, for_project: {stop_timeout: 2, kill_grace: 0.5})

        result = clear_command(dev_config: dev_config).clear("devenv")

        expect(result).to eq(exit_code: 1)
        expect(mono[0]).to be >= 0.5
        expect(mono[0]).to be < described_class::KILL_GRACE_SECONDS
        expect(error_output.string).to include("still running 0.5s after SIGKILL", "Kept devenv lock")
      end

      it "clears the lock once a SIGKILLed group disappears within the grace period" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_return(:killed)
        allow(terminator).to receive(:running?).with(4242).and_return(true, false)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(devenv_holder_pid).to be_nil
        expect(output.string).to include("Killed process group 4242", "Cleared devenv")
      end

      it "keeps the lock when the holder is already gone but its group has members it may not signal" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_return(:gone)
        allow(terminator).to receive(:orphan_running?).and_raise(not_permitted)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 1)
        expect(devenv_holder_pid).to eq(4242)
        expect(error_output.string).to include("Could not stop process group 4242 (pid 4242): its wrapper pid 4242 is gone",
          "Kept devenv lock")
        expect(output.string).not_to include("Cleared devenv")
      end

      it "clears the lock when the holder is already gone and its group id was reused" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_return(:gone)
        allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: true)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(devenv_holder_pid).to be_nil
        expect(error_output.string).to include("Process group 4242 was not signalled: its holder pid 4242 is gone, and the id now belongs to an unrelated process.")
        expect(error_output.string).not_to include("kill -TERM")
      end

      it "on a later clear, keeps a lock whose wrapper is gone while its group still runs" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_raise(not_permitted)
        clear_command.clear("devenv")
        allow(terminator).to receive(:stop_holder).and_return(:gone)
        allow(terminator).to receive(:orphan_running?).and_return(true)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 1)
        expect(devenv_holder_pid).to eq(4242)
        expect(error_output.string).to include("its wrapper pid 4242 is gone, but the group is still running")
      end

      it "on a later clear, clears the lock once its group has stopped" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_raise(not_permitted)
        clear_command.clear("devenv")
        allow(terminator).to receive(:stop_holder).and_return(:gone)
        allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(devenv_holder_pid).to be_nil
        expect(output.string).to include("Cleared devenv")
      end

      it "hands the lock to a queued dev up --takeover and says so, while still removing other waiters" do
        hold_devenv
        enqueue_waiter(name: "devenv", identity: FakeLockIdentity.new(pid: 300), task: "next")
        Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new).acquire("devenv",
          identity: {kind: "process", pid: 555, started: "start-555", pgid: 555, pane: "%5", worktree: "/w/signup", branch: "signup"},
          waiter_pid: 555, waiter_started: "start-555", wait: true, priority: true)
        allow(terminator).to receive(:stop_holder).and_return(:gone)
        allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(devenv_holder_pid).to eq(555)
        expect(output.string).to include("Cleared devenv: was held by ? in /w/login, 1 waiter(s) removed; " \
          "kept the queued takeover by %5 in /w/signup, which takes the lock next.")
      end

      it "stops the group once when a second clear runs while the first is still stopping it" do
        hold_devenv
        second_err = StringIO.new
        second_result = nil
        stops = 0
        allow(terminator).to receive(:stop_holder) do
          stops += 1
          second_result ||= clear_command(pid: 998, output: StringIO.new, error_output: second_err).clear("devenv")
          :terminated
        end

        result = clear_command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(stops).to eq(1)
        expect(second_result).to eq(exit_code: 1)
        expect(second_err.string).to include("devenv lock is already being cleared by pid 999", "process group 4242",
          "workspace lock status devenv")
        expect(devenv_holder_pid).to be_nil
        events = File.readlines(File.join(tmpdir, "locks.jsonl")).map { |l| JSON.parse(l)["event"] }
        expect(events.count("clear")).to eq(1)
        expect(events.count("release")).to eq(1)
      end

      it "reports the in-progress outcome as JSON when a second clear runs while the first is still stopping it" do
        hold_devenv
        second_out = StringIO.new
        second_result = nil
        allow(terminator).to receive(:stop_holder) do
          second_result ||= clear_command(pid: 998, output: second_out, error_output: StringIO.new).clear("devenv", json: true)
          :terminated
        end

        clear_command.clear("devenv")

        expect(second_result).to eq(exit_code: 1)
        parsed = JSON.parse(second_out.string)
        expect(parsed).to include("schema_version" => Workspace::Commands::Lock::JSON_SCHEMA_VERSION, "name" => "devenv",
          "result" => "in_progress", "clearer_pid" => 999)
        expect(parsed["holder"]["pid"]).to eq(4242)
      end

      it "takes over a clear whose clearer died mid-stop" do
        hold_devenv
        allow(terminator).to receive(:stop_holder).and_raise(Interrupt)
        expect { clear_command(pid: 998).clear("devenv") }.to raise_error(Interrupt)
        allow(terminator).to receive(:stop_holder).and_return(:terminated)

        identity = FakeLockIdentity.new(pid: 999).tap { |i| i.kill(998) }
        command = described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: identity, output: output,
          error_output: error_output, terminator: terminator, clock: mono_clock, trap: ->(*) {}, pid_provider: -> { 999 })
        result = command.clear("devenv")

        expect(result).to eq(exit_code: 0)
        expect(devenv_holder_pid).to be_nil
        expect(output.string).to include("Stopped process group 4242", "Cleared devenv")
      end

      it "with --all, clears every other lock and keeps only the one it could not stop" do
        hold_devenv
        command_for(FakeLockIdentity.new(pid: 100)).acquire("edit")
        allow(terminator).to receive(:stop_holder).and_raise(not_permitted)

        result = clear_command.clear(nil, all: true)

        expect(result).to eq(exit_code: 1)
        expect(output.string).to include("Cleared edit")
        expect(devenv_holder_pid).to eq(4242)
        expect(Workspace::LockStore.new(dir: tmpdir, liveness: FakeLockLiveness.new).status("edit")).to be_empty
      end
    end
  end

  describe "lock name validation" do
    let(:command) { command_for(FakeLockIdentity.new(pid: 100)) }

    it "accepts plain names" do
      %w[edit devenv test a.b_c-1 9x].each do |name|
        expect { command.status(name) }.not_to raise_error
      end
    end

    it "rejects shell metacharacters in every subcommand before touching the store" do
      name = 'edit"; touch /tmp/pwned; echo "'

      expect { command.acquire(name) }.to raise_error(Workspace::UsageError, /invalid lock name/)
      expect { command.release(name) }.to raise_error(Workspace::UsageError, /invalid lock name/)
      expect { command.status(name) }.to raise_error(Workspace::UsageError, /invalid lock name/)
      expect { command.clear(name) }.to raise_error(Workspace::UsageError, /invalid lock name/)
      expect { command.instructions(name) }.to raise_error(Workspace::UsageError, /invalid lock name/)
      expect(lock_namespace).not_to have_received(:resolve)
      expect(output.string).to be_empty
    end

    it "rejects names that start with punctuation or contain slashes or spaces" do
      ["-edit", ".edit", "a/b", "a b", "édit"].each do |name|
        expect { command.acquire(name) }.to raise_error(Workspace::UsageError), name
      end
    end
  end
end
