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

      released = s.release_all(identity(pid: 100))

      expect(released).to eq(["edit"])
      expect(s.status("edit")["edit"]["holder"]).to be_nil
    end

    it "dequeues the agent's wait even though it runs under a separate waiter pid" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 201, waiter_started: "start-201", wait: true)

      s.release_all(identity(pid: 200))

      expect(s.status("edit")["edit"]["queue"]).to be_empty
      expect(s.poll("edit", 201)).to eq(status: :cleared)
    end

    it "leaves a hold by a reused pid with a different start time" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(s.release_all(identity(pid: 100, started: "other-start"))).to eq([])
      expect(s.status("edit")["edit"]["holder"]["pid"]).to eq(100)
    end
  end

  describe "#reap" do
    it "reaps dead holders and waiters across every lock and returns how many" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
      s.acquire("test", identity: identity(pid: 300), waiter_pid: 300, waiter_started: "start-300")
      s.acquire("test", identity: identity(pid: 400), waiter_pid: 400, waiter_started: "start-400", wait: true)
      [100, 400].each { |pid| liveness.kill(pid) }

      expect(s.reap).to eq(2)

      expect(s.status["edit"]["holder"]).to include("pid" => 200, "unclaimed" => true)
      expect(s.status["test"]).to include("holder" => include("pid" => 300), "queue" => [])
      reaps = File.readlines(File.join(tmpdir, "locks.jsonl")).map { |l| JSON.parse(l) }.select { |e| e["event"] == "reap" }
      expect(reaps.map { |e| e["lock"] }).to eq(["edit", "test"])
    end

    it "returns zero when nothing is stale" do
      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(store.reap).to eq(0)
    end

    it "returns zero without waiting or reaping while another process holds the store flock" do
      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      liveness.kill(100)
      File.open(File.join(tmpdir, "locks.lock"), File::RDWR) do |contender|
        contender.flock(File::LOCK_EX)

        expect(store.reap).to eq(0)
      end

      expect(store.reap).to eq(1)
    end

    it "leaves locks.json untouched when nothing is reaped" do
      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      path = File.join(tmpdir, "locks.json")
      before = [File.read(path), File.stat(path).ino]

      store.reap

      expect([File.read(path), File.stat(path).ino]).to eq(before)
    end
  end

  describe "#current_holder" do
    it "reaps a dead holder and returns the promoted waiter" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 201, waiter_started: "start-201", wait: true)
      liveness.kill(100)

      expect(s.current_holder("edit")).to include("pid" => 200, "unclaimed" => true)
    end

    it "returns nil once a dead holder with no waiters is reaped" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      liveness.kill(100)

      expect(s.current_holder("edit")).to be_nil
      expect(JSON.parse(File.read(File.join(tmpdir, "locks.json")))["edit"]["holder"]).to be_nil
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

  describe "#acquire with priority" do
    it "queues ahead of earlier waiters so the next release promotes it" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      result = s.acquire("edit", identity: identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true, priority: true)
      expect(result).to include(status: :queued, position: 1, total: 3)
      s.release("edit", 100)

      expect(s.status("edit")["edit"]["holder"]["pid"]).to eq(300)
      expect(s.status("edit")["edit"]["queue"].map { |w| w["waiter_pid"] }).to eq([200])
    end

    it "moves an agent already queued to the head" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
      s.acquire("edit", identity: identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)

      result = s.acquire("edit", identity: identity(pid: 300), waiter_pid: 301, waiter_started: "start-301", wait: true, priority: true)

      expect(result).to include(status: :queued, position: 1)
      expect(s.status("edit")["edit"]["queue"].map { |w| w["waiter_pid"] }).to eq([301, 200])
    end
  end

  describe "#claim_or_dequeue" do
    it "claims a promotion that landed after the waiter's last poll" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)
      s.release("edit", 100)

      expect(s.claim_or_dequeue("edit", 2001)).to eq(status: :acquired)
      expect(s.status("edit")["edit"]["holder"]).not_to have_key("unclaimed")
    end

    it "leaves the queue when still waiting" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 2001, waiter_started: "start-2001", wait: true)

      expect(s.claim_or_dequeue("edit", 2001)).to eq(status: :dequeued)
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

    context "with keep_process_holder" do
      def process_identity(pid:)
        identity(pid: pid).merge(kind: "process", pgid: pid, branch: "main")
      end

      it "removes the queue but keeps a process holder until finish_clear" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.acquire("devenv", identity: process_identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

        removed = s.clear("devenv", keep_process_holder: true)

        expect(removed).to include(pending: true)
        expect(removed[:queue].size).to eq(1)
        expect(s.status("devenv")["devenv"]["holder"]["pid"]).to eq(100)
        expect(s.status("devenv")["devenv"]["queue"]).to be_empty
        expect(s.poll("devenv", 200)).to eq(status: :cleared)

        expect(s.finish_clear("devenv", removed[:holder], cleared_by: "pid 9")).to be_nil
        expect(s.status("devenv")).to be_empty
        events = File.readlines(File.join(tmpdir, "locks.jsonl")).map { |l| JSON.parse(l) }.last(2)
        expect(events[0]).to include("event" => "clear", "lock" => "devenv", "queue_size" => 1, "holder_kept" => true)
        expect(events[1]).to include("event" => "release", "lock" => "devenv", "cleared_by" => "pid 9")
      end

      it "keeps a queued takeover, which finish_clear then promotes" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.acquire("devenv", identity: process_identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true, priority: true)

        removed = s.clear("devenv", keep_process_holder: true)

        expect(removed[:queue].map { |w| w["waiter_pid"] }).to eq([200])
        expect(removed[:takeovers].map { |w| w["waiter_pid"] }).to eq([300])
        expect(s.status("devenv")["devenv"]["queue"].map { |w| w["waiter_pid"] }).to eq([300])
        expect(s.poll("devenv", 200)).to eq(status: :cleared)
        event = File.readlines(File.join(tmpdir, "locks.jsonl")).map { |l| JSON.parse(l) }.last
        expect(event).to include("event" => "clear", "queue_size" => 1, "takeovers_kept" => 1)

        expect(s.finish_clear("devenv", removed[:holder])).to be_nil
        expect(s.status("devenv")["devenv"]["holder"]).to include("pid" => 300)
      end

      it "marks a waiter that re-queues with priority as a takeover" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.acquire("devenv", identity: process_identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
        s.acquire("devenv", identity: process_identity(pid: 200), waiter_pid: 201, waiter_started: "start-201", wait: true, priority: true)

        expect(s.clear("devenv", keep_process_holder: true)[:takeovers].map { |w| w["waiter_pid"] }).to eq([201])
      end

      it "clears an agent holder in one step as usual" do
        s = store
        s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

        removed = s.clear("edit", keep_process_holder: true)

        expect(removed).not_to have_key(:pending)
        expect(s.status("edit")).to be_empty
      end

      it "leaves a newer holder alone when the stopped one already released" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        removed = s.clear("devenv", keep_process_holder: true)
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)
        s.release("devenv", 100)

        expect(s.finish_clear("devenv", removed[:holder])).to include("pid" => 300)
        expect(s.status("devenv")["devenv"]["holder"]["pid"]).to eq(300)
      end

      it "reports the lock as no longer named when the stopped holder released it and nobody took it" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        removed = s.clear("devenv", keep_process_holder: true)
        s.release("devenv", 100)

        expect(s.finish_clear("devenv", removed[:holder])).to be_nil
      end

      it "promotes a waiter that queued while the holder was being stopped" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        removed = s.clear("devenv", keep_process_holder: true)
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)

        expect(s.finish_clear("devenv", removed[:holder])).to be_nil
        expect(s.status("devenv")["devenv"]["holder"]["pid"]).to eq(300)
      end

      it "does not remove a holder that reused the pid with a different start time" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        removed = s.clear("devenv", keep_process_holder: true)

        expect(s.finish_clear("devenv", removed[:holder].merge("started" => "other"))).to include("pid" => 100)
        expect(s.status("devenv")["devenv"]["holder"]["pid"]).to eq(100)
      end
    end

    describe "#keep_process_holder" do
      def process_identity(pid:)
        identity(pid: pid).merge(kind: "process", pgid: pid, branch: "main")
      end

      def hold_and_clear(s)
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.clear("devenv", keep_process_holder: true)[:holder]
      end

      it "marks a holder the lock still names as kept" do
        s = store
        holder = hold_and_clear(s)

        expect(s.keep_process_holder("devenv", holder)).to be_nil
        expect(s.status("devenv")["devenv"]["holder"]).to include("pid" => 100, "kept" => true)
      end

      it "restores a holder that released meanwhile" do
        s = store
        holder = hold_and_clear(s)
        s.release("devenv", 100)

        expect(s.keep_process_holder("devenv", holder, cleared_by: "pid 9")).to be_nil
        expect(s.status("devenv")["devenv"]["holder"]).to include("pid" => 100, "kept" => true)
        audit = File.readlines(File.join(tmpdir, "locks.jsonl")).map { |l| JSON.parse(l) }.last
        expect(audit).to include("event" => "acquire", "cleared_by" => "pid 9")
      end

      it "takes back a promotion its waiter has not learned of, requeueing that waiter at the head" do
        s = store
        holder = hold_and_clear(s)
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)
        s.acquire("devenv", identity: process_identity(pid: 400), waiter_pid: 400, waiter_started: "start-400", wait: true)
        s.release("devenv", 100)

        expect(s.keep_process_holder("devenv", holder)).to be_nil
        entry = s.status("devenv")["devenv"]
        expect(entry["holder"]).to include("pid" => 100, "kept" => true)
        expect(entry["queue"].map { |w| w["agent_pid"] }).to eq([300, 400])
        expect(entry["queue"].first).to include("waiter_pid" => 300, "waiter_started" => "start-300", "kind" => "process", "pgid" => 300)
        expect(s.poll("devenv", 300)).to include(status: :queued, position: 1)
      end

      it "requeues a taken-back takeover still marked as one, so a later clear keeps it" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true, priority: true)
        removed = s.clear("devenv", keep_process_holder: true)
        s.release("devenv", 100)

        expect(s.keep_process_holder("devenv", removed[:holder])).to be_nil
        expect(s.status("devenv")["devenv"]["queue"].first).to include("waiter_pid" => 300, "takeover" => true)
        expect(s.clear("devenv", keep_process_holder: true)[:takeovers].map { |w| w["waiter_pid"] }).to eq([300])
      end

      it "drops the takeover mark once the promoted waiter claims the hold" do
        s = store
        s.acquire("devenv", identity: process_identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true, priority: true)
        s.release("devenv", 100)

        expect(s.poll("devenv", 300)).to include(status: :acquired)
        expect(s.status("devenv")["devenv"]["holder"]).not_to have_key("takeover")
      end

      it "leaves a hold its new holder already claimed, and returns it" do
        s = store
        holder = hold_and_clear(s)
        s.acquire("devenv", identity: process_identity(pid: 300), waiter_pid: 300, waiter_started: "start-300", wait: true)
        s.release("devenv", 100)
        s.poll("devenv", 300)

        expect(s.keep_process_holder("devenv", holder)).to include("pid" => 300)
        expect(s.status("devenv")["devenv"]["holder"]["pid"]).to eq(300)
      end
    end

    describe "reaping a kept holder" do
      let(:terminator) { instance_double(Workspace::ProcessGroupTerminator) }

      def kept_holder(s)
        s.acquire("devenv", identity: identity(pid: 100).merge(kind: "process", pgid: 100, branch: "main"),
          waiter_pid: 100, waiter_started: "start-100")
        s.keep_process_holder("devenv", s.clear("devenv", keep_process_holder: true)[:holder])
        s.acquire("devenv", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)
        liveness.kill(100)
      end

      def with_terminator
        described_class.new(dir: tmpdir, liveness: liveness, terminator: terminator)
      end

      it "keeps it past its wrapper while its process group runs, but marks it stale" do
        kept_holder(store)
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(with_terminator.poll("devenv", 200)[:status]).to eq(:queued)
        expect(with_terminator.status("devenv")["devenv"]["holder"]).to include("pid" => 100, "stale" => true)
      end

      it "counts a group it may not signal as running" do
        kept_holder(store)
        allow(terminator).to receive(:orphan_running?).and_raise(Workspace::Error, "not permitted")

        expect(with_terminator.poll("devenv", 200)[:status]).to eq(:queued)
      end

      it "counts the group as running when there is no terminator to check it" do
        kept_holder(store)

        expect(store.poll("devenv", 200)[:status]).to eq(:queued)
      end

      it "reaps it once its process group is gone" do
        kept_holder(store)
        allow(terminator).to receive(:orphan_running?).and_return(false)

        expect(with_terminator.poll("devenv", 200)[:status]).to eq(:acquired)
      end
    end
  end

  describe "persistence" do
    it "does not leave temp files behind" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(Dir.children(tmpdir)).to match_array(["locks.lock", "locks.json", "locks.jsonl"])
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

    it "wraps a filesystem failure in Workspace::Error naming the path and errno" do
      s = store
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES.new(tmpdir))

      expect { s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100") }
        .to raise_error(Workspace::Error, /#{Regexp.escape(tmpdir)}.*errno/)
    end

    it "chmods the lock dir to 0700 even when it already existed" do
      FileUtils.mkdir_p(tmpdir, mode: 0o755)

      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(File.stat(tmpdir).mode & 0o777).to eq(0o700)
    end
  end

  describe "malformed entries" do
    it "logs and drops a holder missing required fields" do
      logger = instance_double(Workspace::Logger, debug: nil)
      s = described_class.new(dir: tmpdir, liveness: liveness, logger: logger)
      FileUtils.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "locks.json"), JSON.generate("edit" => {"holder" => {"pid" => 100}, "queue" => []}))

      result = s.status("edit")

      expect(result["edit"]["holder"]).to be_nil
      expect(logger).to have_received(:debug)
    end

    it "logs and drops a queue entry missing required fields" do
      logger = instance_double(Workspace::Logger, debug: nil)
      s = described_class.new(dir: tmpdir, liveness: liveness, logger: logger)
      FileUtils.mkdir_p(tmpdir)
      File.write(File.join(tmpdir, "locks.json"), JSON.generate("edit" => {"holder" => nil, "queue" => [{"waiter_pid" => 1}]}))

      result = s.status("edit")

      expect(result["edit"]["queue"]).to eq([])
      expect(logger).to have_received(:debug)
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

  describe "audit log" do
    def audit_events
      path = File.join(tmpdir, "locks.jsonl")
      return [] unless File.exist?(path)
      File.readlines(path).map { |l| JSON.parse(l) }
    end

    it "records an acquire event when a free lock is taken" do
      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(audit_events.map { |e| e["event"] }).to eq(["acquire"])
    end

    it "records nothing when the locks.json write fails" do
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(/locks\.json\.\d+\.tmp\z/, anything).and_raise(Errno::ENOSPC)

      expect {
        store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      }.to raise_error(Workspace::Error)

      expect(audit_events).to eq([])
    end

    it "flushes audit events only after the rename that commits locks.json" do
      events_at_commit = nil
      rename = File.method(:rename)
      allow(File).to receive(:rename).and_call_original
      allow(File).to receive(:rename).with(/locks\.json\.\d+\.tmp\z/, anything) do |*args|
        events_at_commit = audit_events.map { |e| e["event"] }
        rename.call(*args)
      end

      store.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      expect(events_at_commit).to eq([])
      expect(audit_events.map { |e| e["event"] }).to eq(["acquire"])
    end

    it "drops events buffered before the block raises" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      liveness.kill(100)
      allow(s).to receive(:promote!).and_raise(Workspace::Error, "boom")

      expect { s.release("edit", 100) }.to raise_error(Workspace::Error, "boom")

      expect(audit_events.map { |e| e["event"] }).to eq(["acquire"])
    end

    it "records a release event, then an acquire event for the promoted waiter" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("edit", identity: identity(pid: 200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      s.release("edit", 100)

      expect(audit_events.map { |e| e["event"] }).to eq(["acquire", "release", "acquire"])
    end

    it "records a reap event for a dead holder" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      liveness.kill(100)

      s.release_all(identity(pid: 999)) # any mutating op reaps

      expect(audit_events.last["event"]).to eq("reap")
    end

    it "records a clear event" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")

      s.clear("edit", cleared_by: "pid 999")

      expect(audit_events.last).to include("event" => "clear", "cleared_by" => "pid 999")
    end

    it "does not touch the audit log for a read-only status call with no contention" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      before = audit_events.size

      s.status("edit")

      expect(audit_events.size).to eq(before)
    end

    it "appends a deny event to the audit log when a lock is denied" do
      s = store
      denier = identity(pid: 200, pane: "%2", worktree: "web")
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      holder_record = s.current_holder("edit")

      s.record_deny("edit", denier: denier, holder: holder_record)

      deny_events = audit_events.select { |e| e["event"] == "deny" }
      expect(deny_events.size).to eq(1)
      expect(deny_events[0]).to include(
        "event" => "deny",
        "lock" => "edit",
        "agent" => {"pid" => 200, "pane" => "%2", "worktree" => "web"},
        "holder" => {"pid" => 100, "pane" => "%1", "worktree" => "app", "task" => nil, "kind" => "agent"}
      )
    end

    it "does not mutate locks.json when recording a deny event" do
      s = store
      s.acquire("edit", identity: identity(pid: 100), waiter_pid: 100, waiter_started: "start-100")
      holder_record = s.current_holder("edit")

      locks_json_before = File.read(File.join(tmpdir, "locks.json"))

      s.record_deny("edit", denier: identity(pid: 200), holder: holder_record)

      locks_json_after = File.read(File.join(tmpdir, "locks.json"))
      expect(locks_json_after).to eq(locks_json_before)
    end
  end
end
