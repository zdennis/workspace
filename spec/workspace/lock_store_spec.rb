require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockStore do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-store") }
  let(:liveness) { FakeLockLiveness.new }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store(liveness: self.liveness)
    described_class.new(dir: tmpdir, liveness: liveness)
  end

  def identity(pid:, started: "start-#{pid}", pane: "%1", worktree: "app")
    {kind: "agent", pid: pid, started: started, pane: pane, worktree: worktree}
  end

  describe "#acquire" do
    it "acquires a free lock" do
      result = store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(result).to eq(status: :acquired)
    end

    it "is re-entrant for the same agent pid and start time" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      result = s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(result).to eq(status: :already_held)
    end

    it "refuses a different agent without --wait" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      result = s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200")

      expect(result[:status]).to eq(:held)
      expect(result[:holder]["pid"]).to eq(100)
    end

    it "enqueues FIFO with --wait" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      first_waiter = s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
      second_waiter = s.acquire("edit", identity: identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)

      expect(first_waiter).to include(status: :queued, position: 1, total: 2)
      expect(second_waiter).to include(status: :queued, position: 2, total: 3)
    end

    it "refuses to hold or wait for a second lock at the same time (deadlock rule)" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      result = s.acquire("test", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(result).to eq(status: :deadlock, other: "edit")
    end

    it "refuses to queue for a second lock while already queued for another" do
      s = store
      s.acquire("edit", identity: identity(pid: 1), waiter_pid: 1, waiter_started: "start-1")
      s.acquire("edit", identity: identity(pid: 2), waiter_pid: 2, waiter_started: "start-2", wait: true)

      result = s.acquire("test", identity: identity(pid: 2), waiter_pid: 2, waiter_started: "start-2")

      expect(result).to eq(status: :deadlock, other: "edit")
    end
  end

  describe "#poll" do
    it "reports :acquired once the head waiter is promoted" do
      s = store(liveness: FakeLockLiveness.new(dead: [100]))
      # Seed a holder that will be reaped as dead, then a live waiter behind it.
      raw_store = described_class.new(dir: tmpdir, liveness: FakeLockLiveness.new)
      raw_store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 55, waiter_started: "start-55", wait: true)

      expect(s.poll("edit", 55)).to eq(status: :acquired)
    end

    it "reports :cleared when the lock was cleared out from under a waiter" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      s.clear("edit")

      expect(s.poll("edit", 200)).to eq(status: :cleared)
    end

    it "reports :queued with an updated position while still waiting" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      expect(s.poll("edit", 200)).to include(status: :queued, position: 1)
    end
  end

  describe "reaping" do
    it "drops a dead holder and promotes the next live waiter" do
      dead = FakeLockLiveness.new
      s = store(liveness: dead)
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      dead.kill(100)

      result = s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200")
      expect(result).to eq(status: :already_held)
    end

    it "drops a dead waiter from the queue" do
      liveness = FakeLockLiveness.new
      s = store(liveness: liveness)
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
      s.acquire("edit", identity: identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)

      liveness.kill(200)

      expect(s.poll("edit", 300)).to include(status: :queued, position: 1)
    end

    it "treats a reused pid with a different start time as a dead holder" do
      # A real liveness check ties "alive" to the recorded start time, so a
      # pid that is running again under a new process is correctly seen as a
      # different, still-absent holder.
      started_times = {100 => "original-start"}
      liveness = Class.new do
        define_method(:alive?) { |pid:, started:| started_times[pid] == started }
      end.new
      s = store(liveness: liveness)
      s.acquire("edit", identity: identity(pid: 100, started: "original-start"), waiter_pid: 100, waiter_started: "original-start")

      started_times[100] = "reused-start"
      result = s.acquire("edit", identity: identity(pid: 100, started: "reused-start"), waiter_pid: 100, waiter_started: "reused-start")

      expect(result).to eq(status: :acquired)
    end

    it "keeps a holder whose liveness is unknown" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      unknown = Class.new { def alive?(pid:, started:) = raise(Workspace::Error, "ps failed") }.new

      result = store(liveness: unknown).acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200")

      expect(result).to include(status: :held)
    end

    it "shares one liveness snapshot across a single operation" do
      liveness = FakeLockLiveness.new
      scopes = 0
      liveness.define_singleton_method(:within_snapshot) do |&block|
        scopes += 1
        block.call
      end
      s = store(liveness: liveness)
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      scopes = 0
      s.status

      expect(scopes).to eq(1)
    end
  end

  describe "#release" do
    it "releases only the caller's own hold" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(s.release("edit", 999)).to be false
      expect(s.release("edit", 100)).to be true
      expect(s.status("edit")["edit"]["holder"]).to be_nil
    end

    it "is idempotent" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.release("edit", 100)

      expect(s.release("edit", 100)).to be false
    end

    it "promotes the next waiter on release" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      s.release("edit", 100)

      expect(s.poll("edit", 200)).to eq(status: :acquired)
    end
  end

  describe "#release_all" do
    it "releases every lock the pid holds and dequeues it elsewhere" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      released = s.release_all(100)

      expect(released).to eq(["edit"])
      expect(s.status("edit")["edit"]["holder"]).to be_nil
    end
  end

  describe "#dequeue" do
    it "removes one waiter, e.g. on SIGINT" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      s.dequeue("edit", 200)

      expect(s.status("edit")["edit"]["queue"]).to be_empty
    end

    it "releases the lock when the waiter was already promoted, handing it to the next waiter" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.acquire("edit", identity: identity(pid: 300), waiter_pid: 3001, waiter_started: "start-3001", wait: true)
      s.release("edit", 100)

      expect(s.dequeue("edit", 2001)).to eq(:released)
      expect(s.status("edit")["edit"]["holder"]["pid"]).to eq(300)
    end
  end

  describe "#claim_or_dequeue" do
    it "claims a promotion that landed after the waiter's last poll" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.release("edit", 100)

      expect(s.claim_or_dequeue("edit", 2001)).to eq(:acquired)
      expect(s.status("edit")["edit"]["holder"]).not_to have_key("unclaimed")
    end

    it "leaves the queue when still waiting" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)

      expect(s.claim_or_dequeue("edit", 2001)).to eq(:dequeued)
      expect(s.status("edit")["edit"]["queue"]).to be_empty
    end
  end

  describe "unclaimed promotions" do
    it "reports a promotion whose waiter died before polling as stale, even though the agent is alive" do
      liveness = FakeLockLiveness.new
      s = store(liveness: liveness)
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.release("edit", 100)

      liveness.kill(2001)

      # status is read-only and no longer reaps; it flags the dead promotion
      # as stale instead of silently dropping it (a subsequent mutating op,
      # e.g. acquire/release/poll, still reaps it for real).
      expect(s.status("edit")["edit"]["holder"]["stale"]).to be true
    end

    it "keeps a claimed promotion after its waiter exits" do
      liveness = FakeLockLiveness.new
      s = store(liveness: liveness)
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.release("edit", 100)
      s.poll("edit", 2001)

      liveness.kill(2001)

      expect(s.status("edit")["edit"]["holder"]["pid"]).to eq(200)
    end
  end

  describe "#clear" do
    it "removes the holder and queue with no liveness check" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      removed = s.clear("edit")

      expect(removed[:holder]["pid"]).to eq(100)
      expect(removed[:queue].size).to eq(1)
      expect(s.status("edit")).to be_empty
    end

    it "yields the holder so a caller can run a kind-specific side effect" do
      s = store
      s.acquire("devenv", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      yielded = nil
      s.clear("devenv") { |holder| yielded = holder }

      expect(yielded["pid"]).to eq(100)
    end

    it "returns nil for a name with no entry" do
      expect(store.clear("nothing")).to be_nil
    end
  end

  describe "persistence" do
    it "does not leave temp files behind" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(Dir.children(tmpdir)).to match_array(["locks.lock", "locks.json"])
    end

    it "raises pointing at `workspace lock clear` when the data file is corrupt" do
      FileUtils.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "locks.json"), "{not json")

      expect { store.status }.to raise_error(Workspace::Error, /workspace lock clear/)
    end

    it "still lets clear reset a corrupt data file" do
      FileUtils.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "locks.json"), "{not json")

      expect { store.clear("edit") }.not_to raise_error
    end
  end

  describe "namespacing" do
    it "keeps two worktree cwds sharing one namespace serialized through the same store" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      other_view = described_class.new(dir: tmpdir, liveness: liveness)
      result = other_view.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200")

      expect(result[:status]).to eq(:held)
    end
  end

  describe "concurrency" do
    it "serializes concurrent mutations from real OS processes via flock" do
      # A real child process, not an in-process fake, is the only way to prove
      # flock actually serializes independent read-modify-write cycles rather
      # than relying on Ruby-level thread scheduling.
      worker_script = File.join(tmpdir, "worker.rb")
      File.write(worker_script, <<~RUBY)
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).inspect})
        require "workspace"

        i = ARGV[0].to_i
        liveness = Class.new { def alive?(pid:, started:) = true }.new
        store = Workspace::LockStore.new(dir: #{tmpdir.inspect}, liveness: liveness)
        store.acquire("edit",
          identity: {kind: "agent", pid: 1000 + i, started: "start-\#{1000 + i}", pane: "%1", worktree: "app"},
          waiter_pid: 1000 + i, waiter_started: "start-\#{1000 + i}", wait: true)
      RUBY

      workers = 8
      pids = Array.new(workers) { |i| Process.spawn(RbConfig.ruby, worker_script, i.to_s) }
      pids.each { |pid| Process.wait(pid) }

      final = store.status("edit")["edit"]
      total_tracked = (final["holder"] ? 1 : 0) + final["queue"].size

      expect(total_tracked).to eq(workers)
      # Exactly one holder: flock serialized every worker's read-modify-write,
      # so no two acquires raced into the same "lock is free" branch.
      expect(final["holder"]).not_to be_nil
    end
  end
end
