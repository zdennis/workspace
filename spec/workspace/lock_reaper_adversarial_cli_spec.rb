require "spec_helper"
require "tmpdir"
require "stringio"

# Adversarial CLI/observability coverage for the daemon-driven LockReaper
# (commit 0ad3074). Each `it` documents one confirmed defect; see the
# skeptic report for severity and prescribed fixes. IDs: RU1, RU2.
RSpec.describe Workspace::LockReaper do
  let(:state_dir) { Dir.mktmpdir("ws-lock-reaper-adversarial") }
  let(:app_cwd) { File.join(state_dir, "app").tap { |d| FileUtils.mkdir_p(d) } }
  let(:app_dir) { File.join(state_dir, "locks", "app-ns") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:liveness) { FakeLockLiveness.new }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).with(cwd: app_cwd).and_return(key: "app", display: "app", dir: app_dir)
  end

  def reaper(logger: Workspace::Logger.new, error_output: StringIO.new)
    described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, logger: logger, error_output: error_output)
  end

  def store(dir = app_dir)
    Workspace::LockStore.new(dir: dir, liveness: liveness)
  end

  def identity(pid, **extra)
    {kind: "agent", pid: pid, started: "start-#{pid}", pane: "%1", worktree: "app"}.merge(extra)
  end

  def hold(name, pid, dir = app_dir)
    store(dir).acquire(name, identity: identity(pid), waiter_pid: pid, waiter_started: "start-#{pid}")
  end

  def audit_events(dir = app_dir)
    File.readlines(File.join(dir, "locks.jsonl")).map { |l| JSON.parse(l) }
  end

  # RU1: a reap the daemon runs on its own (no lock op in progress) writes
  # the exact same "reap" audit line as one an `acquire`/`release`/`status`
  # call triggers as its opening pass. Nothing in locks.jsonl lets an operator
  # tell "the daemon dropped this holder while it was crashed" apart from
  # "an unrelated `lock status` happened to reap it" -- see
  # lib/workspace/lock_reaper.rb:1 (no source/origin passed through to
  # LockStore#reap) and lib/workspace/lock_store.rb:191 (#reap calls reap!
  # with no distinguishing data).
  it "RU1: tags a daemon-triggered reap in the audit log so it's distinguishable from an op-time reap" do
    hold("edit", 100)
    liveness.kill(100)

    expect(reaper.reap([app_cwd])).to eq(1)

    reap_event = audit_events.find { |e| e["event"] == "reap" }
    expect(reap_event).to include("source" => "daemon")
  end

  # RU2: LockReaper#reap_dir rescues every error and only ever logs at
  # `debug`, which is a silent no-op unless `--debug` was passed (see
  # lib/workspace/logger.rb:29 -- disabled Logger#debug does nothing at
  # all). The daemon runs without `--debug` in normal operation, and
  # LockReaper takes no error_output/notifier of its own
  # (lib/workspace/lock_reaper.rb ctor), so a namespace that fails on every
  # tick (e.g. a permissions problem on locks.json) never surfaces to
  # anyone, ever -- not on the first failure, not after 100.
  it "RU2: surfaces a namespace that persistently fails to reap, even when debug logging is off" do
    hold("edit", 100)
    File.chmod(0o000, File.join(app_dir, "locks.json"))

    out = StringIO.new
    r = reaper(logger: Workspace::Logger.new(output: StringIO.new, enabled: false), error_output: out)

    5.times { r.reap([app_cwd]) }

    expect(out.string).not_to be_empty
  ensure
    File.chmod(0o600, File.join(app_dir, "locks.json")) if File.exist?(File.join(app_dir, "locks.json"))
  end
end
