require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockIdleTracker do
  let(:state_dir) { Dir.mktmpdir("ws-lock-idle-tracker") }
  let(:lock_dir) { File.join(state_dir, "locks") }
  let(:store_dir) { File.join(lock_dir, "app-ns") }
  let(:config) { instance_double(Workspace::Config, lock_dir: lock_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:agent) { FakeLockIdentity.new(pid: 100, pane: "%1") }
  let(:env) { {"TMUX_PANE" => "%1"} }
  let(:now) { [1_000_000] }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: store_dir)
  end

  def tracker(lock_holder: agent)
    described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder, env: env, clock: -> { now[0] })
  end

  def store
    Workspace::LockStore.new(dir: store_dir, liveness: agent, clock: -> { now[0] })
  end

  def hold(identity)
    id = identity.current
    store.acquire("edit", identity: id, waiter_pid: id[:pid], waiter_started: id[:started])
  end

  def idle_since
    store.status("edit")["edit"]["holder"]["idle_since"]
  end

  it "marks the agent's lock idle on Stop and active on UserPromptSubmit and PreToolUse" do
    hold(agent)

    expect(tracker.update("Stop")).to eq(["edit"])
    expect(idle_since).to eq(1_000_000)

    expect(tracker.update("UserPromptSubmit")).to eq(["edit"])
    expect(idle_since).to be_nil

    tracker.update("Stop")
    expect(tracker.update("PreToolUse")).to eq(["edit"])
    expect(idle_since).to be_nil
  end

  it "ignores other hook events" do
    hold(agent)

    expect(tracker.update("SubagentStop")).to eq([])
    expect(tracker.update(nil)).to eq([])
    expect(idle_since).to be_nil
  end

  it "never marks a lock held by another agent in another pane" do
    other = FakeLockIdentity.new(pid: 200, pane: "%2")
    hold(other)

    expect(tracker.update("Stop")).to eq([])
    expect(store.status("edit")["edit"]["holder"]["idle_since"]).to be_nil
  end

  it "never marks another agent's lock in the same pane" do
    other = FakeLockIdentity.new(pid: 200, pane: "%1")
    hold(other)

    expect(tracker.update("Stop")).to eq([])
    expect(store.status("edit")["edit"]["holder"]["idle_since"]).to be_nil
  end

  it "does nothing, without resolving the namespace, when no lock directory exists" do
    expect(lock_namespace).not_to receive(:resolve)

    expect(tracker.update("Stop")).to eq([])
  end

  it "does not identify the agent or create files when there is no locks.json" do
    FileUtils.mkdir_p(lock_dir)
    lock_holder = instance_double(Workspace::LockHolder)
    expect(lock_holder).not_to receive(:current)

    expect(tracker(lock_holder: lock_holder).update("Stop")).to eq([])
    expect(File.exist?(store_dir)).to be(false)
  end

  it "does not identify the agent when no holder's state would change" do
    hold(agent)
    lock_holder = instance_double(Workspace::LockHolder)
    expect(lock_holder).not_to receive(:current)

    expect(tracker(lock_holder: lock_holder).update("PreToolUse")).to eq([])
  end

  it "resolves the namespace from the payload's cwd when it exists" do
    hold(agent)
    expect(lock_namespace).to receive(:resolve).with(cwd: state_dir)

    tracker.update("Stop", cwd: state_dir)
  end

  it "falls back to the process cwd when the payload's cwd is missing" do
    FileUtils.mkdir_p(lock_dir)
    expect(lock_namespace).to receive(:resolve).with(cwd: Dir.pwd)

    tracker.update("Stop", cwd: File.join(state_dir, "gone"))
  end

  it "swallows errors so the hook never fails" do
    FileUtils.mkdir_p(lock_dir)
    allow(lock_namespace).to receive(:resolve).and_raise(Workspace::Error, "boom")

    expect(tracker.update("Stop")).to eq([])
  end

  it "swallows a failure to identify the agent" do
    hold(agent)
    lock_holder = instance_double(Workspace::LockHolder)
    allow(lock_holder).to receive(:current).and_raise(Workspace::Error, "ps failed")

    expect(tracker(lock_holder: lock_holder).update("Stop")).to eq([])
  end
end
