require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe "Lock observability (adversarial concurrency)" do
  let(:store_dir) { Dir.mktmpdir("ws-lock-observe-adv") }
  let(:audit_path) { File.join(store_dir, "locks.jsonl") }
  let(:liveness) { FakeLockLiveness.new }

  after { FileUtils.remove_entry(store_dir) if File.directory?(store_dir) }

  def identity(pid, pane)
    {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
  end

  def store
    Workspace::LockStore.new(dir: store_dir, liveness: liveness)
  end

  def acquire(pid, pane, wait: false)
    store.acquire("edit", identity: identity(pid, pane), waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
  end

  def events(path = audit_path)
    return [] unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l) }
  end

  it "OC1: an acquire whose locks.json commit fails leaves no acquire event in locks.jsonl" do
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(/locks\.json\.\d+\.tmp\z/, anything).and_raise(Errno::ENOSPC)

    expect { acquire(100, "%1") }.to raise_error(Workspace::Error)

    expect(File.exist?(File.join(store_dir, "locks.json"))).to be false
    expect(events.map { |e| e["event"] }).not_to include("acquire")
  end

  it "OC2: two concurrent appenders crossing the rotation threshold do not clobber locks.jsonl.1" do
    rotate_bytes = 2_000
    Workspace::LockAuditLog.new(dir: store_dir, rotate_bytes: 10**9).then do |seed|
      seed.append(event: "old", name: "edit", data: {"n" => 0}) while !File.exist?(audit_path) || File.size(audit_path) < rotate_bytes - 50
    end
    old_count = events.size
    first = Workspace::LockAuditLog.new(dir: store_dir, rotate_bytes: rotate_bytes)
    second = Workspace::LockAuditLog.new(dir: store_dir, rotate_bytes: rotate_bytes)

    # Two `record_deny` calls hold only a shared flock, so both can check the
    # size before either rotates: interleave `first`'s whole append between
    # `second`'s size check and its rename.
    interleaved = false
    allow(File).to receive(:size).and_wrap_original do |original, *args|
      size = original.call(*args)
      unless interleaved
        interleaved = true
        first.append(event: "deny", name: "edit", data: {"from" => "first"})
      end
      size
    end
    second.append(event: "deny", name: "edit", data: {"from" => "second"})

    all = events("#{audit_path}.1") + events
    expect(all.count { |e| e["event"] == "old" }).to eq(old_count)
    expect(all.map { |e| e["from"] }.compact).to contain_exactly("first", "second")
  end

  it "OC3: sessions does not mark a dead holder's pane as holding the edit lock" do
    acquire(100, "%1")
    acquire(200, "%2", wait: true)
    liveness.kill(100)
    namespace = instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: store_dir})
    sessions = Workspace::Commands::Sessions.new(config: instance_double(Workspace::Config),
      lock_namespace: namespace, lock_holder: liveness, output: StringIO.new, error_output: StringIO.new)
    panes = [{"pane_id" => "%1"}, {"pane_id" => "%2"}]

    sessions.send(:apply_lock_column, panes)

    expect(panes[0]["lock"]).not_to eq("edit ✓")
  end
end
