require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::LockReaper do
  let(:state_dir) { Dir.mktmpdir("ws-lock-reaper") }
  let(:app_cwd) { File.join(state_dir, "app").tap { |d| FileUtils.mkdir_p(d) } }
  let(:lib_cwd) { File.join(state_dir, "lib").tap { |d| FileUtils.mkdir_p(d) } }
  let(:app_dir) { File.join(state_dir, "locks", "app-ns") }
  let(:lib_dir) { File.join(state_dir, "locks", "lib-ns") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:liveness) { FakeLockLiveness.new }
  let(:now) { [100.0] }
  let(:error_output) { StringIO.new }

  after { FileUtils.remove_entry(state_dir) }

  before do
    allow(lock_namespace).to receive(:resolve).with(cwd: app_cwd).and_return(key: "app", display: "app", dir: app_dir)
    allow(lock_namespace).to receive(:resolve).with(cwd: lib_cwd).and_return(key: "lib", display: "lib", dir: lib_dir)
  end

  def reaper(terminator: nil, interval: 30)
    described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, terminator: terminator,
      interval: interval, clock: -> { now[0] }, error_output: error_output)
  end

  def store(dir = app_dir, terminator: nil)
    Workspace::LockStore.new(dir: dir, liveness: liveness, terminator: terminator)
  end

  def identity(pid, **extra)
    {kind: "agent", pid: pid, started: "start-#{pid}", pane: "%1", worktree: "app"}.merge(extra)
  end

  def hold(name, pid, dir = app_dir, **extra)
    store(dir).acquire(name, identity: identity(pid, **extra), waiter_pid: pid, waiter_started: "start-#{pid}")
  end

  def wait_for(name, pid, dir = app_dir)
    store(dir).acquire(name, identity: identity(pid), waiter_pid: pid, waiter_started: "start-#{pid}", wait: true)
  end

  def raw(dir = app_dir)
    JSON.parse(File.read(File.join(dir, "locks.json")))
  end

  def audit_events(dir = app_dir)
    File.readlines(File.join(dir, "locks.jsonl")).map { |l| JSON.parse(l) }
  end

  describe "#reap" do
    it "drops a dead holder, promotes the next live waiter, and audits the reap" do
      hold("edit", 100)
      wait_for("edit", 200)
      liveness.kill(100)

      expect(reaper.reap([app_cwd])).to eq(1)

      expect(raw["edit"]["holder"]).to include("pid" => 200, "unclaimed" => true)
      expect(audit_events.map { |e| e["event"] }).to include("reap")
      expect(audit_events.find { |e| e["event"] == "reap" }["holder"]).to include("pid" => 100)
    end

    it "drops dead waiters and leaves a live holder alone" do
      hold("edit", 100)
      wait_for("edit", 200)
      wait_for("edit", 300)
      liveness.kill(200)

      expect(reaper.reap([app_cwd])).to eq(1)

      expect(raw["edit"]["holder"]["pid"]).to eq(100)
      expect(raw["edit"]["queue"].map { |w| w["waiter_pid"] }).to eq([300])
    end

    describe "a devenv holder `lock clear` kept" do
      let(:terminator) { instance_double(Workspace::ProcessGroupTerminator) }

      before do
        hold("devenv", 100, kind: "process", pgid: 100, branch: "main")
        s = store
        s.keep_process_holder("devenv", s.clear("devenv", keep_process_holder: true)[:holder])
        liveness.kill(100)
      end

      it "stays while its process group runs" do
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(reaper(terminator: terminator).reap([app_cwd])).to eq(0)
        expect(raw["devenv"]["holder"]).to include("pid" => 100, "kept" => true)
      end

      it "stays when the group cannot be checked" do
        expect(reaper.reap([app_cwd])).to eq(0)
        expect(raw["devenv"]["holder"]["pid"]).to eq(100)
      end

      it "is reaped once its process group is gone" do
        allow(terminator).to receive(:orphan_running?).and_return(false)

        expect(reaper(terminator: terminator).reap([app_cwd])).to eq(1)
        expect(raw["devenv"]["holder"]).to be_nil
      end
    end

    it "reaps each namespace once, however many panes share it" do
      hold("edit", 100)
      liveness.kill(100)
      allow(Workspace::LockStore).to receive(:new).and_call_original

      expect(reaper.reap([app_cwd, app_cwd, nil])).to eq(1)
      expect(Workspace::LockStore).to have_received(:new).once
    end

    it "leaves a namespace with no locks.json untouched" do
      expect(reaper.reap([app_cwd])).to eq(0)
      expect(File.exist?(app_dir)).to be(false)
    end

    it "skips a pane directory that no longer exists" do
      expect(reaper.reap([File.join(state_dir, "gone")])).to eq(0)
    end

    it "skips a corrupt namespace and still reaps the others" do
      FileUtils.mkdir_p(app_dir)
      File.write(File.join(app_dir, "locks.json"), "{not json")
      hold("edit", 100, lib_dir)
      liveness.kill(100)

      expect(reaper.reap([app_cwd, lib_cwd])).to eq(1)
      expect(raw(lib_dir)["edit"]["holder"]).to be_nil
    end

    it "skips a directory whose namespace cannot be resolved" do
      allow(lock_namespace).to receive(:resolve).with(cwd: app_cwd).and_raise(Workspace::Error, "git failed")
      hold("edit", 100, lib_dir)
      liveness.kill(100)

      expect(reaper.reap([app_cwd, lib_cwd])).to eq(1)
    end

    it "tags its reaps as daemon reaps in the audit log" do
      hold("edit", 100)
      liveness.kill(100)

      reaper.reap([app_cwd])

      expect(audit_events.find { |e| e["event"] == "reap" }).to include("source" => "daemon")
    end

    it "warns once when a namespace fails to reap three times in a row, and again only after a success" do
      FileUtils.mkdir_p(app_dir)
      data_path = File.join(app_dir, "locks.json")
      File.write(data_path, "{not json")
      r = reaper

      2.times { r.reap([app_cwd]) }
      expect(error_output.string).to be_empty

      4.times { r.reap([app_cwd]) }
      expect(error_output.string.lines.size).to eq(1)
      expect(error_output.string).to include("Warning: lock reaper could not reap stale locks in #{app_dir} 3 times in a row")

      File.write(data_path, "{}")
      r.reap([app_cwd])
      File.write(data_path, "{not json")
      3.times { r.reap([app_cwd]) }
      expect(error_output.string.lines.size).to eq(2)
    end

    it "warns when a directory's namespace keeps failing to resolve" do
      allow(lock_namespace).to receive(:resolve).with(cwd: app_cwd).and_raise(Workspace::Error, "git failed")
      r = reaper

      3.times { r.reap([app_cwd]) }

      expect(error_output.string).to include("could not resolve the lock namespace for #{app_cwd}", "git failed")
    end
  end

  describe "#tick" do
    it "reaps on the first tick and then only once the interval has passed" do
      r = reaper(interval: 30)
      hold("edit", 100)
      liveness.kill(100)
      expect(r.tick([app_cwd])).to eq(1)

      hold("edit", 200)
      liveness.kill(200)
      now[0] += 29
      expect(r.tick([app_cwd])).to eq(0)
      expect(raw["edit"]["holder"]["pid"]).to eq(200)

      now[0] += 1
      expect(r.tick([app_cwd])).to eq(1)
      expect(raw["edit"]["holder"]).to be_nil
    end
  end
end
