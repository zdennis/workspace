require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockStore, "idle takeover" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-idle") }
  let(:liveness) { FakeLockLiveness.new }
  let(:now) { [1_000_000] }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store(idle_grace: 300)
    described_class.new(dir: tmpdir, liveness: liveness, clock: -> { now[0] }, idle_grace: idle_grace)
  end

  def identity(pid:, pane: "%#{pid}", kind: "agent")
    {kind: kind, pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
  end

  def hold(pid, **opts)
    store.acquire("edit", identity: identity(pid: pid, **opts), waiter_pid: pid, waiter_started: "start-#{pid}", task: "task-#{pid}")
  end

  def wait_for(pid, name: "edit")
    store.acquire(name, identity: identity(pid: pid), waiter_pid: pid + 1, waiter_started: "start-#{pid + 1}", task: "task-#{pid}", wait: true)
  end

  def holder
    store.status("edit")["edit"]["holder"]
  end

  describe "#mark_idle" do
    it "sets idle_since on the agent's own hold" do
      hold(100)

      expect(store.mark_idle(identity(pid: 100), idle: true)).to eq(["edit"])
      expect(holder["idle_since"]).to eq(1_000_000)
    end

    it "keeps the original idle_since when marked idle again" do
      hold(100)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 50

      expect(store.mark_idle(identity(pid: 100), idle: true)).to eq([])
      expect(holder["idle_since"]).to eq(1_000_000)
    end

    it "clears idle_since when the agent becomes active" do
      hold(100)
      store.mark_idle(identity(pid: 100), idle: true)

      expect(store.mark_idle(identity(pid: 100), idle: false)).to eq(["edit"])
      expect(holder["idle_since"]).to be_nil
    end

    it "never marks another agent's hold, even with the same pid and a different start time" do
      hold(100)

      expect(store.mark_idle(identity(pid: 200), idle: true)).to eq([])
      expect(store.mark_idle({kind: "agent", pid: 100, started: "reused", pane: "%100"}, idle: true)).to eq([])
      expect(holder["idle_since"]).to be_nil
    end

    it "never marks a process holder" do
      hold(100, kind: "process")

      expect(store.mark_idle(identity(pid: 100, kind: "process"), idle: true)).to eq([])
      expect(holder["idle_since"]).to be_nil
    end
  end

  describe "#idle_change_possible?" do
    it "is false with no locks.json" do
      expect(store.idle_change_possible?(pane: "%1", idle: true)).to be(false)
    end

    it "is false on a corrupt locks.json rather than raising" do
      File.write(File.join(tmpdir, "locks.json"), "{nope")

      expect(store.idle_change_possible?(pane: "%1", idle: true)).to be(false)
    end

    it "only considers holders in the given pane whose state would change" do
      hold(100)

      expect(store.idle_change_possible?(pane: "%100", idle: true)).to be(true)
      expect(store.idle_change_possible?(pane: "%100", idle: false)).to be(false)
      expect(store.idle_change_possible?(pane: "%999", idle: true)).to be(false)
      expect(store.idle_change_possible?(pane: nil, idle: true)).to be(true)
    end

    it "ignores process holders" do
      hold(100, kind: "process")

      expect(store.idle_change_possible?(pane: nil, idle: true)).to be(false)
    end
  end

  describe "#poll takeover" do
    it "lets the head waiter take a lock idle for at least the grace period" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 300

      result = store.poll("edit", 201)

      expect(result[:status]).to eq(:acquired)
      expect(result[:took_over]).to include("pid" => 100, "idle_since" => 1_000_000)
      expect(holder).to include("pid" => 200, "idle_since" => nil)
      expect(holder).not_to have_key("unclaimed")
    end

    it "does not take over before the grace period elapses" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 299

      expect(store.poll("edit", 201)[:status]).to eq(:queued)
      expect(holder["pid"]).to eq(100)
    end

    it "honours a custom idle_grace" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 10

      expect(store(idle_grace: 10).poll("edit", 201)[:status]).to eq(:acquired)
    end

    it "does not take over a holder that resumed" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 600
      store.mark_idle(identity(pid: 100), idle: false)

      expect(store.poll("edit", 201)[:status]).to eq(:queued)
      expect(holder["pid"]).to eq(100)
    end

    it "lets only the head waiter take over" do
      hold(100)
      wait_for(200)
      wait_for(300)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 600

      expect(store.poll("edit", 301)).to include(status: :queued, position: 2)
      expect(holder["pid"]).to eq(100)
      expect(store.poll("edit", 201)[:status]).to eq(:acquired)
    end

    it "never takes over a process holder, even one carrying idle_since" do
      hold(100, kind: "process")
      wait_for(200)
      data = JSON.parse(File.read(File.join(tmpdir, "locks.json")))
      data["edit"]["holder"]["idle_since"] = 1
      File.write(File.join(tmpdir, "locks.json"), JSON.generate(data))
      now[0] += 10_000

      expect(store.poll("edit", 201)[:status]).to eq(:queued)
      expect(holder["pid"]).to eq(100)
    end

    it "does not take over a holder that re-ran acquire" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 600

      expect(hold(100)).to eq(status: :already_held)
      expect(holder["idle_since"]).to be_nil
      expect(store.poll("edit", 201)[:status]).to eq(:queued)
    end

    it "treats a non-numeric idle_since as active, so the next mark_idle records a real one" do
      hold(100)
      wait_for(200)
      write_holder_field("idle_since", "999999")

      expect(holder["idle_since"]).to be_nil
      expect(store.mark_idle(identity(pid: 100), idle: true)).to eq(["edit"])
      now[0] += 300
      expect(store.poll("edit", 201)[:status]).to eq(:acquired)
    end

    it "restarts the grace period from now when idle_since is in the future" do
      hold(100)
      wait_for(200)
      write_holder_field("idle_since", now[0] + 86_400)

      expect(store.poll("edit", 201)[:status]).to eq(:queued)
      expect(holder["idle_since"]).to eq(1_000_000)
      now[0] += 300
      expect(store.poll("edit", 201)[:status]).to eq(:acquired)
    end

    it "clamps a future idle_since when the agent is marked idle again" do
      hold(100)
      write_holder_field("idle_since", now[0] + 86_400)

      store.mark_idle(identity(pid: 100), idle: true)

      expect(holder["idle_since"]).to eq(1_000_000)
    end

    def write_holder_field(key, value)
      path = File.join(tmpdir, "locks.json")
      data = JSON.parse(File.read(path))
      data["edit"]["holder"][key] = value
      File.write(path, JSON.generate(data))
    end
  end

  describe "#claim_or_dequeue takeover" do
    it "takes over an idle holder at the deadline instead of leaving the queue" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 300

      result = store.claim_or_dequeue("edit", 201)

      expect(result).to include(status: :acquired, took_over: include("pid" => 100))
      expect(holder["pid"]).to eq(200)
    end

    it "leaves the queue when the holder's grace has not elapsed" do
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 299

      expect(store.claim_or_dequeue("edit", 201)).to eq(status: :dequeued)
      expect(holder["pid"]).to eq(100)
      expect(store.status("edit")["edit"]["queue"]).to be_empty
    end
  end

  describe "#pop_displaced" do
    def take_over_from_100
      hold(100)
      wait_for(200)
      store.mark_idle(identity(pid: 100), idle: true)
      now[0] += 300
      store.poll("edit", 201)
    end

    it "returns the displacement once, naming the new holder" do
      take_over_from_100

      records = store.pop_displaced(identity(pid: 100), name: "edit")

      expect(records.size).to eq(1)
      expect(records.first).to include("name" => "edit", "idle_since" => 1_000_000, "at" => 1_000_300,
        "by" => {"pane" => "%200", "task" => "task-200", "worktree" => "app"})
      expect(store.pop_displaced(identity(pid: 100), name: "edit")).to eq([])
    end

    it "does not return another agent's displacement" do
      take_over_from_100

      expect(store.pop_displaced(identity(pid: 200))).to eq([])
      expect(store.pop_displaced(identity(pid: 100), name: "other")).to eq([])
      expect(store.pop_displaced(identity(pid: 100)).size).to eq(1)
    end

    it "drops the record once the displaced agent is dead" do
      take_over_from_100
      liveness.kill(100)
      store.status # read-only, no reap
      store.release("edit", 999) # any mutating op reaps

      expect(JSON.parse(File.read(File.join(tmpdir, "locks.json")))["edit"]).not_to have_key("displaced")
    end

    it "returns nothing and creates no files when the store does not exist" do
      FileUtils.remove_entry(tmpdir)

      expect(store.pop_displaced(identity(pid: 100))).to eq([])
      expect(File.exist?(tmpdir)).to be(false)
    end
  end
end
