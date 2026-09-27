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
  end

  describe "#clear" do
    it "removes a lock's holder and queue" do
      command_for(FakeLockIdentity.new(pid: 100)).acquire("edit", task: "the-task")

      result = command_for(FakeLockIdentity.new(pid: 999)).clear("edit")

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Cleared edit: was held by")
      expect(command_for(FakeLockIdentity.new(pid: 999)).status("edit").tap { |_| }).to eq(exit_code: 0)
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
        expect(error_output.string).to include("Process group #{group} is still running, but its holder pid #{group} is gone",
          "kill -TERM -#{group}")
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
