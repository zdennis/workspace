require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockStore, "run holders" do
  let(:tmpdir) { Dir.mktmpdir("ws-lock-store-run") }
  let(:liveness) { FakeLockLiveness.new }
  let(:now) { [1_000] }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def store(idle_grace: 300)
    described_class.new(dir: tmpdir, liveness: liveness, clock: -> { now.first }, idle_grace: idle_grace)
  end

  def run(id = "wr_1", step: "verify", **rest)
    {run_id: id, step: step, workflow: "rpiv", workspace: "app.worktree-a", worktree: "/src/app-a", pane: "%4"}.merge(rest)
  end

  def agent(pid, pane: "%1")
    {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
  end

  def process(pid)
    {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, pane: "%9", worktree: "/src/app-a", branch: "feat/a"}
  end

  def hold(name, pid, wait: false)
    store.acquire(name, identity: agent(pid), waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
  end

  def holder(name)
    store.status(name).dig(name, "holder")
  end

  def queue(name)
    store.status(name).dig(name, "queue")
  end

  def audit_events
    path = File.join(tmpdir, "locks.jsonl")
    File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
  end

  describe "#acquire_run" do
    it "takes every free lock and records the run, not a pid, as the holder" do
      result = store.acquire_run(%w[test-db devenv], run: run)

      expect(result).to include(status: :acquired, held: %w[devenv test-db], acquired: %w[devenv test-db], released: [], took_over: {}, waiting: nil)
      expect(holder("test-db")).to include("kind" => "run", "run_id" => "wr_1", "step" => "verify", "workflow" => "rpiv",
        "workspace" => "app.worktree-a", "worktree" => "/src/app-a", "pane" => "%4", "stale" => false)
      expect(holder("test-db")).not_to include("pid", "started", "waiter_pid")
      expect(holder("test-db")["acquired_at"]).to match(/\A\d{4}-\d\d-\d\dT/)
    end

    it "lets one run hold several locks at once, which an agent may not" do
      store.acquire_run(%w[a b c], run: run)

      expect(%w[a b c].map { |name| holder(name)["run_id"] }).to eq(%w[wr_1 wr_1 wr_1])
    end

    it "is re-entrant, and records the step the run is on now" do
      store.acquire_run(%w[test-db], run: run(step: "implement"))

      result = store.acquire_run(%w[test-db], run: run(step: "verify"))

      expect(result).to include(status: :acquired, held: %w[test-db], acquired: [])
      expect(holder("test-db")["step"]).to eq("verify")
    end

    it "acquires in sorted name order and stops at the first busy lock, holding only the names before it" do
      hold("m", 100)

      result = store.acquire_run(%w[z m a], run: run)

      expect(result).to include(status: :waiting, held: %w[a], acquired: %w[a])
      expect(result[:waiting]).to include(name: "m", position: 1, total: 2, queued: true)
      expect(result[:waiting][:holder]).to include("pid" => 100)
      expect(store.status("z")).to eq({})
      expect(queue("m").first).to include("kind" => "run", "run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-a")
      expect(queue("m").first).not_to include("waiter_pid", "agent_pid")
    end

    it "keeps its place in the queue across calls instead of queueing twice" do
      hold("m", 100)
      store.acquire_run(%w[m], run: run)
      store.acquire_run(%w[m], run: run("wr_2"))

      result = store.acquire_run(%w[m], run: run)

      expect(result[:waiting]).to include(name: "m", position: 1, total: 3, queued: false)
      expect(queue("m").map { |w| w["run_id"] }).to eq(%w[wr_1 wr_2])
    end

    it "queues FIFO with agents and processes" do
      hold("devenv", 100)
      store.acquire("devenv", identity: process(200), waiter_pid: 200, waiter_started: "start-200", wait: true)

      result = store.acquire_run(%w[devenv], run: run)

      expect(result[:waiting]).to include(position: 2, total: 3)
    end

    it "is promoted when the holder releases, and holds the lock on its next call" do
      hold("m", 100)
      store.acquire_run(%w[a m z], run: run)

      store.release("m", 100)

      expect(holder("m")).to include("kind" => "run", "run_id" => "wr_1", "unclaimed" => true)
      result = store.acquire_run(%w[a m z], run: run)
      expect(result).to include(status: :acquired, held: %w[a m z], acquired: %w[m z])
      expect(holder("m")).not_to include("unclaimed")
    end

    it "queues behind a waiter that a clear in progress is holding back" do
      s = store
      s.acquire("devenv", identity: process(100), waiter_pid: 100, waiter_started: "start-100")
      s.acquire("devenv", identity: process(200), waiter_pid: 200, waiter_started: "start-200", wait: true)
      s.clear("devenv", keep_process_holder: true, clearer: {"pid" => 900, "started" => "start-900"})
      s.release("devenv", 100)

      result = s.acquire_run(%w[devenv], run: run)

      expect(result[:waiting]).to include(name: "devenv", position: 2, holder: nil)
    end

    it "releases what the run held for an earlier step and this step does not use" do
      store.acquire_run(%w[devenv test-db], run: run(step: "implement"))

      result = store.acquire_run(%w[devenv], run: run(step: "verify"))

      expect(result).to include(status: :acquired, held: %w[devenv], released: %w[test-db])
      expect(holder("test-db")).to be_nil
    end

    it "leaves the queue of a lock this step does not use" do
      hold("lint", 100)
      store.acquire_run(%w[lint], run: run(step: "implement"))

      store.acquire_run(%w[devenv], run: run(step: "verify"))

      expect(queue("lint")).to eq([])
    end

    it "gives up a lock it holds that sorts after the one it has to wait for, so it never holds out of order" do
      store.acquire_run(%w[z], run: run(step: "implement"))
      hold("a", 100)

      result = store.acquire_run(%w[a z], run: run(step: "verify"))

      expect(result).to include(status: :waiting, held: [], released: %w[z])
      expect(holder("z")).to be_nil
    end

    it "cannot deadlock two runs that want the same locks" do
      store.acquire_run(%w[a b], run: run("wr_1"))

      second = store.acquire_run(%w[b a], run: run("wr_2"))

      expect(second).to include(status: :waiting, held: [])
      expect(second[:waiting]).to include(name: "a")
      expect(second[:waiting][:holder]).to include("run_id" => "wr_1", "step" => "verify", "workspace" => "app.worktree-a")
      expect(queue("b")).to eq([])
    end

    it "takes over from an agent idle past the grace period when it heads the queue" do
      s = store(idle_grace: 60)
      hold("test-db", 100)
      s.mark_idle(agent(100), idle: true)
      s.acquire_run(%w[test-db], run: run)
      now[0] += 61

      result = s.acquire_run(%w[test-db], run: run)

      expect(result).to include(status: :acquired, acquired: %w[test-db])
      expect(result[:took_over]).to include("test-db" => include("pid" => 100))
      expect(audit_events.last).to include("event" => "takeover", "from" => include("pid" => 100), "to" => include("run_id" => "wr_1"))
      displaced = s.pop_displaced(agent(100))
      expect(displaced.first).to include("name" => "test-db", "by" => include("run_id" => "wr_1", "worktree" => "/src/app-a"))
    end

    it "does not take over while another waiter is ahead of it" do
      s = store(idle_grace: 60)
      hold("test-db", 100)
      s.mark_idle(agent(100), idle: true)
      hold("test-db", 200, wait: true)
      s.acquire_run(%w[test-db], run: run)
      now[0] += 61

      expect(s.acquire_run(%w[test-db], run: run)).to include(status: :waiting)
    end

    it "updates a waiting run's step while it keeps its place" do
      hold("m", 100)
      store.acquire_run(%w[m], run: run(step: "implement"))

      store.acquire_run(%w[m], run: run(step: "verify"))

      expect(queue("m").map { |w| [w["run_id"], w["step"]] }).to eq([%w[wr_1 verify]])
    end

    it "takes nothing for a run that is not alive, since the next op would reap it" do
      liveness.end_run("wr_1")

      result = store.acquire_run(%w[test-db], run: run)

      expect(result).to eq(status: :not_alive, held: [], acquired: [], released: [], handed_over: [], took_over: {}, waiting: nil)
      expect(store.status).to eq({})
    end

    it "writes acquire and release audit events that name the run" do
      store.acquire_run(%w[test-db], run: run)
      store.release_run("wr_1")

      expect(audit_events.map { |e| [e["event"], e["lock"], e.dig("holder", "run_id"), e.dig("holder", "kind")] })
        .to eq([["acquire", "test-db", "wr_1", "run"], ["release", "test-db", "wr_1", "run"]])
    end
  end

  describe "a run holder" do
    before { store.acquire_run(%w[devenv test-db], run: run) }

    it "is never marked idle or taken over, however long it holds" do
      s = store(idle_grace: 1)
      hold("test-db", 200, wait: true)
      now[0] += 10_000

      expect(s.idle_change_possible?(pane: "%4", idle: true)).to be(false)
      expect(s.poll("test-db", 200)).to include(status: :queued)
      expect(holder("test-db")).to include("run_id" => "wr_1", "idle_since" => nil)
    end

    it "is not released by an agent's release, even with no pid" do
      expect(store.release("test-db", nil)).to be(false)
      expect(store.release("test-db", 100)).to be(false)
      expect(holder("test-db")["run_id"]).to eq("wr_1")
    end

    it "does not count against an agent's one-lock rule" do
      expect(hold("edit", 100)).to eq(status: :acquired)
    end

    it "is refused to an agent like any other holder" do
      expect(hold("test-db", 100)).to include(status: :held, holder: include("run_id" => "wr_1"))
    end

    it "is reaped once its run has ended, and the next waiter is promoted" do
      hold("test-db", 200, wait: true)
      liveness.end_run("wr_1")

      expect(holder("test-db")).to include("stale" => true)
      expect(store.reap).to eq(2)
      expect(holder("test-db")).to include("pid" => 200, "unclaimed" => true)
      expect(holder("devenv")).to be_nil
      expect(audit_events.select { |e| e["event"] == "reap" }.map { |e| e.dig("holder", "run_id") }).to eq(%w[wr_1 wr_1])
    end

    it "counts as alive when its run's state can't be read" do
      allow(liveness).to receive(:run_alive?).and_raise(Workspace::Error, "unreadable run file")

      expect(store.reap).to eq(0)
      expect(holder("test-db")).to include("run_id" => "wr_1", "stale" => false)
    end

    it "counts as alive with a liveness checker that knows nothing about runs" do
      plain = Class.new {
        def alive?(pid:, started:) = true
      }.new
      s = described_class.new(dir: tmpdir, liveness: plain)

      expect(s.reap).to eq(0)
      expect(s.status("test-db").dig("test-db", "holder")).to include("run_id" => "wr_1", "stale" => false)
    end

    it "survives a read and rewrite of locks.json" do
      hold("edit", 100)

      expect(holder("test-db")).to include("kind" => "run", "run_id" => "wr_1")
    end

    it "is not matched by a waiter with no pid" do
      hold("lint", 100)
      store.acquire_run(%w[lint], run: run("wr_2"))

      expect(store.dequeue("test-db", nil)).to eq(:absent)
      expect(store.poll("lint", nil)).to eq(status: :cleared)
      expect(store.claim_or_dequeue("lint", nil)).to eq(status: :dequeued)
      expect(holder("test-db")).to include("run_id" => "wr_1")
      expect(queue("lint").map { |w| w["run_id"] }).to eq(%w[wr_2])
    end

    it "loses a delegate record that is not a process record, and keeps the lock" do
      path = File.join(tmpdir, "locks.json")
      data = JSON.parse(File.read(path))
      data["devenv"]["holder"]["delegate"] = {"pid" => 5}
      data["test-db"]["holder"]["delegate"] = "nope"
      File.write(path, JSON.generate(data))

      expect(holder("devenv")).to include("run_id" => "wr_1")
      expect(holder("devenv")).not_to include("delegate")
      expect(holder("test-db")).not_to include("delegate")
    end

    it "is dropped as malformed without a run id" do
      path = File.join(tmpdir, "locks.json")
      data = JSON.parse(File.read(path))
      data["test-db"]["holder"].delete("run_id")
      data["devenv"]["queue"] << {"kind" => "run", "step" => "x"}
      File.write(path, JSON.generate(data))

      expect(holder("test-db")).to be_nil
      expect(queue("devenv")).to eq([])
    end
  end

  describe "a run waiter" do
    before do
      hold("test-db", 100)
      store.acquire_run(%w[test-db], run: run)
    end

    it "is reaped once its run has ended" do
      liveness.end_run("wr_1")

      expect(queue("test-db").first).to include("stale" => true)
      expect(store.reap).to eq(1)
      expect(queue("test-db")).to eq([])
    end

    it "is skipped at promotion once its run has ended" do
      hold("test-db", 200, wait: true)
      liveness.end_run("wr_1")

      store.release("test-db", 100)

      expect(holder("test-db")).to include("pid" => 200)
    end

    it "goes back to the head of the queue when a kept process holder is restored over its promotion" do
      s = store
      kept = process(300)
      s.acquire("devenv", identity: kept, waiter_pid: 300, waiter_started: "start-300")
      record = s.status("devenv").dig("devenv", "holder")
      s.acquire_run(%w[devenv], run: run("wr_2"))
      s.release("devenv", 300)
      expect(holder("devenv")).to include("run_id" => "wr_2", "unclaimed" => true)

      expect(s.keep_process_holder("devenv", record)).to be_nil

      expect(holder("devenv")).to include("pid" => 300, "kept" => true)
      expect(queue("devenv").first).to include("kind" => "run", "run_id" => "wr_2", "step" => "verify")
      expect(s.acquire_run(%w[devenv], run: run("wr_2"))[:waiting]).to include(position: 1, queued: false)
    end
  end

  describe "#release_run" do
    it "releases every lock the run holds, leaves its queues, and promotes the next waiter" do
      store.acquire_run(%w[a b], run: run)
      hold("c", 100)
      store.acquire_run(%w[a b c], run: run)
      hold("a", 200, wait: true)

      expect(store.release_run("wr_1")).to eq(%w[a b])

      expect(holder("a")).to include("pid" => 200)
      expect(holder("b")).to be_nil
      expect(queue("c")).to eq([])
    end

    it "releases only the named locks" do
      store.acquire_run(%w[a b], run: run)

      expect(store.release_run("wr_1", %w[b])).to eq(%w[b])
      expect(holder("a")).to include("run_id" => "wr_1")
    end

    it "leaves another run's locks alone" do
      store.acquire_run(%w[a], run: run("wr_1"))
      store.acquire_run(%w[b], run: run("wr_2"))

      expect(store.release_run("wr_2")).to eq(%w[b])
      expect(holder("a")).to include("run_id" => "wr_1")
    end

    it "is a no-op for a run that holds nothing" do
      expect(store.release_run("wr_9")).to eq([])
    end
  end

  describe "#release_all" do
    it "leaves a run's locks and queue entries when an agent's session ends, even in the run's own pane" do
      s = store
      hold("test-db", 300)
      s.acquire_run(%w[devenv test-db], run: run(pane: "%1"))
      hold("edit", 100)

      expect(s.release_all(agent(100, pane: "%1"))).to eq(%w[edit])

      expect(holder("devenv")).to include("run_id" => "wr_1")
      expect(queue("test-db").map { |w| w["run_id"] }).to eq(%w[wr_1])
      expect(holder("edit")).to be_nil
    end

    it "leaves a run's locks and queue entries for an identity with no pid" do
      store.acquire_run(%w[test-db], run: run)
      store.acquire_run(%w[test-db], run: run("wr_2"))

      expect(store.release_all({kind: "agent", pid: nil, started: nil, pane: "%4"})).to eq([])
      expect(holder("test-db")).to include("run_id" => "wr_1")
      expect(queue("test-db").map { |w| w["run_id"] }).to eq(%w[wr_2])
    end

    it "releases every lock an agent holds in one call" do
      path = File.join(tmpdir, "locks.json")
      hold("edit", 100)
      data = JSON.parse(File.read(path))
      data["test-db"] = {"holder" => data["edit"]["holder"].dup, "queue" => []}
      File.write(path, JSON.generate(data))

      expect(store.release_all(agent(100))).to eq(%w[edit test-db])
      expect([holder("edit"), holder("test-db")]).to eq([nil, nil])
    end
  end

  describe "delegates" do
    before { store.acquire_run(%w[devenv], run: run) }

    it "records a process on the run's hold instead of queueing it" do
      result = store.delegate("devenv", run_id: "wr_1", identity: process(500))

      expect(result).to eq(status: :delegated)
      expect(holder("devenv")).to include("kind" => "run", "run_id" => "wr_1")
      expect(holder("devenv")["delegate"]).to include("kind" => "process", "pid" => 500, "started" => "start-500", "pgid" => 500,
        "pane" => "%9", "worktree" => "/src/app-a", "branch" => "feat/a", "stale" => false)
      expect(holder("devenv")["delegate"]["since"]).to match(/\A\d{4}-/)
      expect(queue("devenv")).to eq([])
    end

    it "is idempotent for the same process" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      expect(store.delegate("devenv", run_id: "wr_1", identity: process(500))).to eq(status: :delegated)
    end

    it "refuses a second delegate while the first is alive" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      result = store.delegate("devenv", run_id: "wr_1", identity: process(600))

      expect(result).to include(status: :busy, delegate: include("pid" => 500))
    end

    it "refuses a process whose run does not hold the lock" do
      expect(store.delegate("devenv", run_id: "wr_2", identity: process(500))).to include(status: :not_holder, holder: include("run_id" => "wr_1"))
      expect(store.delegate("test-db", run_id: "wr_1", identity: process(500))).to eq(status: :not_holder, holder: nil)
    end

    it "drops the delegate when its process ends, and the run keeps the lock" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      expect(store.end_delegate("devenv", 500)).to eq(:ended)

      expect(holder("devenv")).to include("run_id" => "wr_1")
      expect(holder("devenv")).not_to include("delegate")
      expect(store.end_delegate("devenv", 500)).to eq(:absent)
    end

    it "reaps a delegate whose process died, and shows it stale until then" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      liveness.kill(500)

      expect(holder("devenv")["delegate"]).to include("stale" => true)
      store.reap
      expect(holder("devenv")).to include("run_id" => "wr_1")
      expect(holder("devenv")).not_to include("delegate")
    end

    it "keeps the delegate across the run's next step" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      store.acquire_run(%w[devenv], run: run(step: "review"))

      expect(holder("devenv")).to include("step" => "review", "delegate" => include("pid" => 500))
    end

    it "hands the lock to a live delegate when the run releases it, so the lock still names the running process" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.acquire("devenv", identity: process(700), waiter_pid: 700, waiter_started: "start-700", wait: true)

      expect(store.release_run("wr_1")).to eq(%w[devenv])

      expect(holder("devenv")).to include("kind" => "process", "pid" => 500, "started" => "start-500", "pgid" => 500,
        "worktree" => "/src/app-a", "branch" => "feat/a", "pane" => "%9")
      expect(holder("devenv")).not_to include("run_id", "delegate", "unclaimed")
      expect(queue("devenv").map { |w| w["waiter_pid"] }).to eq([700])
      expect(store.end_delegate("devenv", 500)).to eq(:released)
      expect(holder("devenv")).to include("pid" => 700)
    end

    it "records the hand-over in the audit log, with the run it came from" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      store.release_run("wr_1")

      expect(audit_events.last).to include("event" => "acquire", "holder" => include("pid" => 500, "kind" => "process"),
        "handed_over_from" => include("run_id" => "wr_1", "kind" => "run"))
      expect(audit_events.last).not_to include("cleared_by")
    end

    it "gives the lock back to the run that handed it over, with the process as its delegate again" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.acquire("devenv", identity: process(700), waiter_pid: 700, waiter_started: "start-700", wait: true)
      store.release_run("wr_1")
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500, "from_run" => "wr_1")

      result = store.acquire_run(%w[devenv], run: run(step: "review"))

      expect(result).to include(status: :acquired, acquired: %w[devenv], waiting: nil)
      expect(holder("devenv")).to include("kind" => "run", "run_id" => "wr_1", "step" => "review")
      expect(holder("devenv")).not_to include("pid", "from_run")
      expect(holder("devenv")["delegate"]).to include("kind" => "process", "pid" => 500, "started" => "start-500", "pgid" => 500,
        "worktree" => "/src/app-a", "branch" => "feat/a", "pane" => "%9", "stale" => false)
      expect(queue("devenv").map { |w| w["waiter_pid"] }).to eq([700])
      expect(audit_events.last).to include("event" => "readopt", "holder" => include("run_id" => "wr_1"), "delegate" => include("pid" => 500))
    end

    it "gets devenv back after waiting for an earlier lock made it give devenv up" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      hold("db", 100)

      waiting = store.acquire_run(%w[db devenv], run: run(step: "verify"))
      expect(waiting).to include(status: :waiting, held: [], released: %w[devenv], handed_over: %w[devenv])
      store.release("db", 100)
      result = store.acquire_run(%w[db devenv], run: run(step: "verify"))

      expect(result).to include(status: :acquired, held: %w[db devenv], acquired: %w[db devenv])
      expect(holder("devenv")).to include("run_id" => "wr_1", "delegate" => include("pid" => 500))
    end

    it "leaves its place in the queue when it gets the lock back" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.release_run("wr_1")
      path = File.join(tmpdir, "locks.json")
      data = JSON.parse(File.read(path))
      data["devenv"]["queue"] << {"kind" => "run", "run_id" => "wr_1", "step" => "old", "enqueued_at" => "2026-10-04T00:00:00Z"}
      File.write(path, JSON.generate(data))

      expect(store.acquire_run(%w[devenv], run: run)).to include(status: :acquired)
      expect(queue("devenv")).to eq([])
    end

    it "does not give the lock back to another run" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.release_run("wr_1")

      result = store.acquire_run(%w[devenv], run: run("wr_2"))

      expect(result[:waiting]).to include(name: "devenv", position: 1, holder: include("pid" => 500))
    end

    it "queues behind its former delegate once that holder is kept, since its wrapper may be gone" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.release_run("wr_1")
      store.keep_process_holder("devenv", holder("devenv"))

      result = store.acquire_run(%w[devenv], run: run)

      expect(result[:waiting]).to include(name: "devenv", position: 1)
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500, "kept" => true)
    end

    it "queues behind its former delegate while a clear is stopping it" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.release_run("wr_1")
      store.mark_clearing("devenv", holder("devenv"), {"pid" => 900, "started" => "start-900"})

      expect(store.acquire_run(%w[devenv], run: run)).to include(status: :waiting)
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "queues behind its former delegate when a `dev up --force` waiter is first in line to replace it" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.release_run("wr_1")
      store.acquire("devenv", identity: process(700), waiter_pid: 700, waiter_started: "start-700", wait: true, priority: true)

      result = store.acquire_run(%w[devenv], run: run)

      expect(result[:waiting]).to include(name: "devenv", position: 2)
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "does not get the lock back from a delegate it was cleared off" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.clear("devenv", cleared_by: "pid 900", keep_process_holder: true, clearer: {"pid" => 900, "started" => "start-900"})
      expect(holder("devenv")).to include("pid" => 500)
      expect(holder("devenv")).not_to include("from_run")
      expect(audit_events.find { |e| e["handed_over_from"] }).to include("cleared_by" => "pid 900")
      liveness.kill(900)

      expect(store.acquire_run(%w[devenv], run: run)).to include(status: :waiting)
      expect(holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "blocks a second run behind the first run's dev environment when the first gives devenv up to wait: the one case two runs can still block each other" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      store.acquire_run(%w[db], run: run("wr_2"))
      store.acquire_run(%w[db devenv], run: run("wr_2"))

      first = store.acquire_run(%w[db devenv], run: run("wr_1"))
      second = store.acquire_run(%w[db devenv], run: run("wr_2"))

      expect(first).to include(status: :waiting, released: %w[devenv], handed_over: %w[devenv])
      expect(first[:waiting]).to include(name: "db", holder: include("run_id" => "wr_2"))
      expect(second).to include(status: :waiting, held: %w[db])
      expect(second[:waiting]).to include(name: "devenv", holder: include("kind" => "process", "pid" => 500, "from_run" => "wr_1"))

      liveness.kill(500)
      expect(store.acquire_run(%w[db devenv], run: run("wr_2"))).to include(status: :acquired, held: %w[db devenv])
    end

    describe "one whose process group could not be stopped" do
      let(:terminator) { instance_double(Workspace::ProcessGroupTerminator, orphan_running?: true) }

      def kept_store
        described_class.new(dir: tmpdir, liveness: liveness, terminator: terminator)
      end

      before do
        store.delegate("devenv", run_id: "wr_1", identity: process(500))
        expect(store.keep_delegate("devenv", 500)).to be(true)
        liveness.kill(500)
      end

      it "stays on the run's hold after its wrapper is gone, while its group runs, and refuses a second delegate" do
        expect(kept_store.reap).to eq(0)

        expect(holder("devenv")["delegate"]).to include("pid" => 500, "kept" => true, "stale" => true)
        expect(kept_store.delegate("devenv", run_id: "wr_1", identity: process(600))).to include(status: :busy, delegate: include("pid" => 500))
      end

      it "is dropped once its group is gone" do
        allow(terminator).to receive(:orphan_running?).and_return(false)

        kept_store.reap

        expect(holder("devenv")).to include("run_id" => "wr_1")
        expect(holder("devenv")).not_to include("delegate")
      end

      it "takes the lock as a kept holder when the run gives it up, and the run then waits behind it" do
        expect(kept_store.release_run("wr_1")).to eq(%w[devenv])

        expect(holder("devenv")).to include("kind" => "process", "pid" => 500, "kept" => true)
        expect(kept_store.reap).to eq(0)
        expect(kept_store.acquire_run(%w[devenv], run: run)).to include(status: :waiting)
      end

      it "marks nothing for a pid that is not the delegate's" do
        expect(store.keep_delegate("devenv", 999)).to be(false)
        expect(store.keep_delegate("devenv", nil)).to be(false)
        expect(store.keep_delegate("nope", 500)).to be(false)
      end
    end

    it "hands the lock to a live delegate when the run has ended" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      liveness.end_run("wr_1")

      store.reap

      expect(holder("devenv")).to include("kind" => "process", "pid" => 500)
    end

    it "frees the lock when the run has ended and its delegate is dead too" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))
      liveness.end_run("wr_1")
      liveness.kill(500)

      store.reap

      expect(holder("devenv")).to be_nil
    end

    it "hands the lock to a live delegate before a clear that keeps process holders, so the clear can stop it" do
      store.delegate("devenv", run_id: "wr_1", identity: process(500))

      removed = store.clear("devenv", keep_process_holder: true, clearer: {"pid" => 900, "started" => "start-900"})

      expect(removed).to include(pending: true, holder: include("kind" => "process", "pid" => 500))
      expect(holder("devenv")).to include("pid" => 500, "clearing" => {"pid" => 900, "started" => "start-900"})
    end

    it "clears a run holder with no delegate outright" do
      removed = store.clear("devenv", keep_process_holder: true)

      expect(removed[:holder]).to include("run_id" => "wr_1")
      expect(store.status("devenv")).to eq({})
    end
  end
end
