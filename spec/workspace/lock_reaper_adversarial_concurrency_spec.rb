require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::LockReaper do
  let(:state_dir) { Dir.mktmpdir("ws-lock-reaper-conc") }
  let(:app_cwd) { File.join(state_dir, "app").tap { |d| FileUtils.mkdir_p(d) } }
  let(:app_dir) { File.join(state_dir, "locks", "app-ns") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:liveness) { FakeLockLiveness.new }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).with(cwd: app_cwd).and_return(key: "app", display: "app", dir: app_dir)
  end

  def reaper
    described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, clock: -> { 100.0 })
  end

  def hold(name, pid)
    Workspace::LockStore.new(dir: app_dir, liveness: liveness).acquire(name,
      identity: {kind: "agent", pid: pid, started: "start-#{pid}", pane: "%1", worktree: "app"},
      waiter_pid: pid, waiter_started: "start-#{pid}")
  end

  def data_path
    File.join(app_dir, "locks.json")
  end

  it "RC1: returns promptly when another process holds the store flock, instead of stalling the monitor's scan thread" do
    hold("edit", 100)
    contender = File.open(File.join(app_dir, "locks.lock"), File::RDWR)
    contender.flock(File::LOCK_EX)
    ticking = Thread.new { reaper.tick([app_cwd]) }

    finished = ticking.join(2)

    expect(finished).not_to be_nil, "tick was still blocked in flock after 2s; the scan thread stops refreshing panes for as long as the store is held"
  ensure
    contender&.close
    ticking&.join
  end

  it "RC2: leaves locks.json untouched when there is nothing to reap, so a long-lived daemon on older code never rewrites fields newer code added" do
    hold("edit", 100)
    data = JSON.parse(File.read(data_path))
    data["edit"]["added_by_newer_version"] = [{"pid" => 300}]
    File.write(data_path, JSON.pretty_generate(data))
    before = File.read(data_path)
    inode = File.stat(data_path).ino

    expect(reaper.tick([app_cwd])).to eq(0)

    expect(File.read(data_path)).to eq(before)
    expect(File.stat(data_path).ino).to eq(inode)
  end
end
