RSpec.describe Workspace::SessionMonitor do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:clock) { class_double(Time, now: now) }

  let(:panes) do
    [
      {id: "%1", index: 0, pid: 100, command: "zsh", cwd: "/project", title: "shell"},
      {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
    ]
  end

  subject(:monitor) do
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
      idle_after: 30, clock: clock)
  end

  before do
    allow(tmux).to receive(:pane_details).with("proj").and_return(panes)
    allow(process_tree).to receive(:snapshot).and_return(snapshot)
    allow(snapshot).to receive(:find_descendant).and_return(nil)
    allow(snapshot).to receive(:find_descendant)
      .with(200, ["claude"], hash_including(include_root: true))
      .and_return({pid: 250, command: "claude", args: "claude"})
    allow(tmux).to receive(:capture_pane).and_return("output")
  end

  def pane(id)
    monitor.snapshot["panes"].find { |p| p["pane_id"] == id }
  end

  describe "#scan" do
    it "labels a pane running an agent by its provider" do
      monitor.scan

      expect(pane("%2")["kind"]).to eq("claude")
      expect(pane("%2")["label"]).to eq("Claude Code")
    end

    it "labels a pane with no agent as a shell" do
      monitor.scan

      expect(pane("%1")["kind"]).to eq("shell")
      expect(pane("%1")["label"]).to eq("zsh")
    end

    it "keeps the last known state when the process table cannot be read" do
      monitor.scan
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")

      monitor.scan

      expect(pane("%2")["kind"]).to eq("claude")
    end

    it "skips the tick instead of stalling when ps hangs" do
      monitor.scan
      hung_tree = Workspace::ProcessTree.new(timeout: 0.1, command: ["/bin/sleep", "30"])
      allow(process_tree).to receive(:snapshot) { hung_tree.snapshot }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      monitor.scan

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(pane("%2")["kind"]).to eq("claude")
    end

    it "drops panes that have closed, along with their history" do
      monitor.scan
      allow(tmux).to receive(:pane_details).with("proj").and_return([panes.first])

      monitor.scan

      expect(pane("%2")).to be_nil
    end

    it "follows a pane across a reindex, because entries are keyed on pane id" do
      monitor.scan
      monitor.record("event" => "subagent_start", "pane_id" => "%2",
        "agent" => {"name" => "reviewer"})
      # A pane was closed ahead of %2, so tmux now reports it at index 0.
      allow(tmux).to receive(:pane_details).with("proj")
        .and_return([panes.last.merge(index: 0)])

      monitor.scan

      expect(pane("%2")["index"]).to eq(0)
      expect(pane("%2")["agents"].map { |a| a["name"] }).to eq(["reviewer"])
    end
  end

  describe "activity" do
    it "reports a pane as working while its output changes" do
      monitor.scan

      expect(pane("%1")["state"]).to eq("working")
    end

    it "reports a pane as idle once its output has been unchanged past the threshold" do
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 31)

      monitor.scan

      expect(pane("%1")["state"]).to eq("idle")
      expect(pane("%1")["idle_seconds"]).to eq(31)
    end

    it "returns to working as soon as output changes again" do
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 31)
      monitor.scan
      allow(tmux).to receive(:capture_pane).and_return("new output")

      monitor.scan

      expect(pane("%1")["state"]).to eq("working")
      expect(pane("%1")["idle_seconds"]).to eq(0)
    end
  end

  describe "#record" do
    before { monitor.scan }

    it "adds a running sub-agent on start" do
      monitor.record("event" => "subagent_start", "pane_id" => "%2",
        "session_id" => "sess-1", "agent" => {"name" => "eval-baseline"})

      expect(pane("%2")["agents"]).to eq([{
        "name" => "eval-baseline", "state" => "running",
        "started_at" => now.iso8601, "ended_at" => nil
      }])
      expect(pane("%2")["session_id"]).to eq("sess-1")
    end

    it "closes the oldest running sub-agent on stop" do
      monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "first"})
      monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "second"})

      monitor.record("event" => "subagent_stop", "pane_id" => "%2")

      expect(pane("%2")["agents"].map { |a| [a["name"], a["state"]] })
        .to eq([["first", "done"], ["second", "running"]])
    end

    it "closes every running sub-agent when the session stops" do
      monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "first"})
      monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "second"})

      monitor.record("event" => "stop", "pane_id" => "%2")

      expect(pane("%2")["agents"].map { |a| a["state"] }).to eq(["done", "done"])
    end

    it "names an unlabelled sub-agent rather than dropping it" do
      monitor.record("event" => "subagent_start", "pane_id" => "%2")

      expect(pane("%2")["agents"].first["name"]).to eq("agent")
    end

    it "ignores an event with no pane id" do
      expect { monitor.record("event" => "subagent_start") }.not_to raise_error
      expect(pane("%2")["agents"]).to be_empty
    end

    it "accepts an event for a pane it has not scanned yet" do
      monitor.record("event" => "subagent_start", "pane_id" => "%9", "agent" => {"name" => "early"})

      expect(pane("%9")["agents"].first["name"]).to eq("early")
    end
  end

  describe "waiting" do
    before { monitor.scan }

    def notify(message = "Claude needs your permission to use Bash")
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => message)
    end

    it "reports a pane as waiting after a notification, with the agent's message" do
      notify
      allow(clock).to receive(:now).and_return(now + 5)

      expect(pane("%2")).to include("state" => "waiting", "waiting_since" => now.iso8601,
        "waiting_seconds" => 5, "waiting_message" => "Claude needs your permission to use Bash")
    end

    it "reports waiting even while the pane's output keeps changing" do
      notify
      allow(tmux).to receive(:capture_pane).and_return("spinner frame")

      monitor.scan

      expect(pane("%2")["state"]).to eq("waiting")
    end

    it "keeps the first start time when a notification repeats during one wait" do
      notify
      allow(clock).to receive(:now).and_return(now + 60)
      notify("Claude is waiting for your input")

      expect(pane("%2")).to include("waiting_since" => now.iso8601,
        "waiting_message" => "Claude is waiting for your input")
    end

    %w[user_prompt tool_use subagent_start subagent_stop stop session_start session_end].each do |event|
      it "clears waiting on a #{event} event" do
        notify

        monitor.record("event" => event, "pane_id" => "%2")

        expect(pane("%2")).to include("waiting_since" => nil, "waiting_message" => nil)
        expect(pane("%2")["state"]).not_to eq("waiting")
      end
    end

    it "clears waiting once the pane no longer runs an agent" do
      notify
      allow(snapshot).to receive(:find_descendant).and_return(nil)

      monitor.scan

      expect(pane("%2")["state"]).to eq("working")
    end

    it "leaves the waiting fields nil for a pane that never waited" do
      expect(pane("%1")).to include("waiting_since" => nil, "waiting_seconds" => nil, "waiting_message" => nil)
    end
  end

  describe "#reap_locks" do
    let(:lock_reaper) { instance_double(Workspace::LockReaper) }

    it "ticks the reaper with the working directory of every pane it has seen" do
      reaping = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, lock_reaper: lock_reaper)
      allow(lock_reaper).to receive(:tick).and_return(2)
      reaping.scan

      expect(reaping.reap_locks).to eq(2)
      expect(lock_reaper).to have_received(:tick).with(["/project", "/project"])
    end

    it "returns zero instead of raising when the reaper raises, so the scan thread keeps running" do
      reaping = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, lock_reaper: lock_reaper)
      allow(lock_reaper).to receive(:tick).and_raise(IOError, "closed stream")
      reaping.scan

      expect(reaping.reap_locks).to eq(0)
    end

    it "logs a reaper failure at debug" do
      out = StringIO.new
      reaping = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, lock_reaper: lock_reaper, logger: Workspace::Logger.new(output: out, enabled: true))
      allow(lock_reaper).to receive(:tick).and_raise(IOError, "closed stream")

      reaping.reap_locks

      expect(out.string).to include("lock reap failed (IOError: closed stream)")
    end

    it "still returns zero when logging the reaper's failure raises too" do
      logger = instance_double(Workspace::Logger)
      allow(logger).to receive(:debug).and_raise(IOError, "log closed")
      reaping = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, lock_reaper: lock_reaper, logger: logger)
      allow(lock_reaper).to receive(:tick).and_raise(IOError, "closed stream")

      expect(reaping.reap_locks).to eq(0)
    end

    it "does nothing without a reaper" do
      monitor.scan

      expect(monitor.reap_locks).to eq(0)
    end
  end

  describe "#snapshot" do
    it "orders panes by index" do
      monitor.scan

      expect(monitor.snapshot["panes"].map { |p| p["index"] }).to eq([0, 1])
    end

    it "names the workspace and when it was taken" do
      expect(monitor.snapshot).to include("workspace" => "proj", "updated_at" => now.iso8601)
    end
  end
end
