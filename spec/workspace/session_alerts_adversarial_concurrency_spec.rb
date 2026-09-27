require "spec_helper"
require "tmpdir"

# Adversarial specs for the session alerts (T2): each example pins a
# concurrency, liveness, or signal-handling defect and fails until it is fixed.
RSpec.describe "session alerts: concurrency and signals (adversarial)" do
  let(:dir) { Dir.mktmpdir("ws-alerts-adv") }
  let(:error_output) { StringIO.new }
  let(:env) { {"WORKSPACE_ALERT" => "waiting", "WORKSPACE_ALERT_TEXT" => "app pane 0.1 is waiting"} }
  let(:cleanup_pids) { [] }

  after do
    # Every child these specs start leads, or belongs to, its own process
    # group (pgroup: true), never RSpec's, so signalling it is safe.
    cleanup_pids.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    FileUtils.remove_entry(dir)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def read_pid(path, limit: 5)
    deadline = monotonic + limit
    until File.size?(path)
      raise "no pid written to #{path}" if monotonic > deadline
      sleep 0.01
    end
    File.read(path).to_i.tap { |pid| cleanup_pids << pid }
  end

  def gone_within?(pid, seconds)
    deadline = monotonic + seconds
    sleep 0.05 while alive?(pid) && monotonic < deadline
    !alive?(pid)
  end

  describe Workspace::Notifier do
    it "SC1: kills a group member that ignores SIGTERM even when the leader exits during the grace period" do
      survivor = File.join(dir, "survivor")
      command = %((trap '' TERM; exec sh -c 'echo $$ > "#{survivor}"; exec sleep 30') & ) +
        %(while [ ! -s "#{survivor}" ]; do sleep 0.01; done; wait)
      notifier = described_class.new(command: command, timeout: 0.5, kill_grace: 0.5, error_output: error_output)

      thread = notifier.notify(env)
      pid = read_pid(survivor)
      thread.join(5)

      expect(error_output.string).to include("still running after 0.5s")
      expect(gone_within?(pid, 2)).to be(true), "notify command's child #{pid} outlived SIGTERM and was never sent SIGKILL"
    end
  end

  describe Workspace::SessionMonitor do
    let(:tmux) { instance_double(Workspace::Tmux) }
    let(:process_tree) { instance_double(Workspace::ProcessTree) }
    let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
    let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
    let(:clock) { class_double(Time, now: now) }
    let(:panes) do
      [
        {id: "%2", index: 1, pid: 200, command: "claude", cwd: "/project", title: "Claude"},
        {id: "%3", index: 2, pid: 300, command: "claude", cwd: "/project", title: "Claude"}
      ]
    end
    let(:notifier) { instance_double(Workspace::Notifier, notify: nil) }

    def build_monitor(notifier)
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier, idle_alert_after: 600, error_output: error_output)
    end

    def at(seconds)
      allow(clock).to receive(:now).and_return(now + seconds)
    end

    before do
      allow(tmux).to receive(:pane_details).with("proj").and_return(panes)
      allow(process_tree).to receive(:snapshot).and_return(snapshot)
      allow(snapshot).to receive(:find_descendant).and_return(nil)
      allow(tmux).to receive(:capture_pane).and_return("output")
    end

    it "SC2: stopping the monitor stops a notify command that is still running" do
      leader = File.join(dir, "leader")
      real = Workspace::Notifier.new(command: %(echo $$ > "#{leader}"; exec sleep 30),
        timeout: 30, kill_grace: 1, error_output: error_output)
      monitor = build_monitor(real)
      monitor.scan
      monitor.record("event" => "notification", "pane_id" => "%2")

      monitor.send_alerts
      pid = read_pid(leader)
      monitor.stop

      expect(gone_within?(pid, 3)).to be(true), "notify command #{pid} kept running after the monitor stopped"
    end

    it "SC3: one notify that raises (e.g. ThreadError) does not lose the other panes' alerts for good" do
      calls = []
      raised = false
      flaky = Object.new
      flaky.define_singleton_method(:notify) do |alert|
        unless raised
          raised = true
          raise ThreadError, "can't create Thread: Resource temporarily unavailable"
        end
        calls << alert["WORKSPACE_ALERT_PANE_ID"]
        nil
      end
      monitor = build_monitor(flaky)
      monitor.scan
      monitor.record("event" => "notification", "pane_id" => "%2")
      monitor.record("event" => "notification", "pane_id" => "%3")

      monitor.send_alerts
      at(2)
      monitor.send_alerts

      expect(calls.sort).to eq(["%2", "%3"])
    end

    it "SC4: does not raise an idle alert from stale activity when the process table can't be read" do
      monitor = build_monitor(notifier)
      monitor.scan
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")
      output = 0
      allow(tmux).to receive(:capture_pane) { "output #{output += 1}" }

      (60..720).step(60) do |t|
        at(t)
        monitor.scan
        monitor.send_alerts
      end

      expect(notifier).not_to have_received(:notify)
    end

    it "SC5: a parallel sub-agent's event does not end the main agent's wait (and so no idle alert follows)" do
      monitor = build_monitor(notifier)
      monitor.scan
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "Claude needs your permission to use Bash")
      monitor.send_alerts

      at(700)
      monitor.record("event" => "subagent_stop", "pane_id" => "%2")
      monitor.scan
      monitor.send_alerts

      state = monitor.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state"]
      expect(state).to eq("waiting")
      # Pane %3 legitimately goes idle past 600s here; only %2 must alert once.
      expect(notifier).to have_received(:notify).with(hash_including("WORKSPACE_ALERT_PANE_ID" => "%2")).once
    end
  end
end
