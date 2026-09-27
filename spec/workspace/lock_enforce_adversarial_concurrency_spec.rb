require "spec_helper"
require "tmpdir"

RSpec.describe "Edit lock enforcement (adversarial concurrency)" do
  let(:state_dir) { Dir.mktmpdir("ws-lock-enforce-adv") }
  let(:lock_dir) { File.join(state_dir, "locks") }
  let(:store_dir) { File.join(lock_dir, "app-ns") }
  let(:config) { instance_double(Workspace::Config, lock_dir: lock_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:holder_agent) { FakeLockIdentity.new(pid: 100, pane: "%1", worktree: "app") }
  let(:other_agent) { FakeLockIdentity.new(pid: 200, pane: "%2", worktree: "app.worktree-b") }
  let(:waiting_agent) { FakeLockIdentity.new(pid: 300, pane: "%3", worktree: "app.worktree-c") }
  let(:namespace) { {key: "ns", display: "app", dir: store_dir} }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(namespace)
  end

  def enforcer(lock_holder)
    Workspace::LockEnforcer.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder)
  end

  def store(liveness: holder_agent)
    Workspace::LockStore.new(dir: store_dir, liveness: liveness)
  end

  def hold(identity)
    id = identity.current
    store.acquire("edit", identity: id, waiter_pid: id[:pid], waiter_started: id[:started])
  end

  # The background `lock acquire --wait` process has its own pid, distinct
  # from the agent's.
  def enqueue(identity, waiter_pid:)
    store.acquire("edit", identity: identity.current, waiter_pid: waiter_pid,
      waiter_started: "start-#{waiter_pid}", wait: true)
  end

  it "EC1: release_all on /clear or SessionEnd removes the agent's own queue entry" do
    hold(holder_agent)
    enqueue(waiting_agent, waiter_pid: 301)

    enforcer(waiting_agent).release_all

    store.release("edit", 100)
    expect(store.poll("edit", 301)).to include(status: :cleared)
  end

  it "EC2: a corrupt locks.json in an unrelated namespace does not disable enforcement" do
    hold(holder_agent)
    other_ns = File.join(lock_dir, "other-ns")
    FileUtils.mkdir_p(other_ns)
    File.write(File.join(other_ns, "locks.json"), "{")
    allow(Dir).to receive(:children).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).sort_by { |name| (name == "other-ns") ? 0 : 1 }
    end

    expect(enforcer(other_agent).check(tool_name: "Edit")).to include("Workspace edit lock held by %1")
  end

  it "EC3: a dead holder with a live queued waiter still denies a non-queued agent's edit" do
    hold(holder_agent)
    enqueue(waiting_agent, waiter_pid: 301)
    other_agent.kill(100)

    expect(enforcer(other_agent).check(tool_name: "Edit")).to include("Workspace edit lock held by %3")
  end

  it "EC4: a dead holder's record is reaped by the check, so later edits take the fast path" do
    hold(holder_agent)
    other_agent.kill(100)
    expect(lock_namespace).to receive(:resolve).at_most(:once).and_return(namespace)

    2.times { enforcer(other_agent).check(tool_name: "Edit") }
  end
end
