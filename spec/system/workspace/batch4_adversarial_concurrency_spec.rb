require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe "Deferred batch 4 adversarial concurrency" do
  describe Workspace::LockStore do
    let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-batch4-conc")) }
    let(:liveness) do
      Class.new do
        def alive?(pid:, started:) = true
      end.new
    end
    let(:store) { described_class.new(dir: tmpdir, liveness: liveness) }

    after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

    def process_identity(pid)
      {kind: "process", pid: pid, started: "start-#{pid}", pgid: pid, pane: "%#{pid}", worktree: "/wt/#{pid}", branch: "b-#{pid}"}
    end

    it "BC1: a promoted takeover restored to the queue head by keep_process_holder keeps its takeover mark, so a later clear keeps it" do
      store.acquire("devenv", identity: process_identity(10), waiter_pid: 10, waiter_started: "start-10")
      store.acquire("devenv", identity: process_identity(20), waiter_pid: 20, waiter_started: "start-20", wait: true, priority: true)

      removed = store.clear("devenv", cleared_by: "clearer", keep_process_holder: true)
      expect(removed[:takeovers].map { |w| w["waiter_pid"] }).to eq([20])

      # The group survives SIGKILL, but its wrapper exits and releases,
      # promoting the takeover before the stopper re-asserts the holder.
      store.release("devenv", 10)
      expect(store.keep_process_holder("devenv", removed[:holder], cleared_by: "clearer")).to be_nil

      head = store.status("devenv")["devenv"]["queue"].first
      expect(head["waiter_pid"]).to eq(20)
      expect(head["takeover"]).to be(true)

      second = store.clear("devenv", cleared_by: "clearer", keep_process_holder: true)
      expect(second[:takeovers].map { |w| w["waiter_pid"] }).to eq([20])
    end
  end

  describe Workspace::ProcessTree do
    it "BC2: a snapshot aborted by Thread#kill (SessionMonitor#stop mid-scan) does not dump reader-thread IOError backtraces" do
      tree = described_class.new(timeout: 10, command: ["sleep", "2"])
      captured = StringIO.new
      original = $stderr
      $stderr = captured
      begin
        scan = Thread.new { tree.snapshot }
        sleep 0.3
        scan.kill
        scan.join
        sleep 0.3
      ensure
        $stderr = original
      end
      expect(captured.string).not_to include("stream closed in another thread")
    end
  end
end
