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
    allow(tmux).to receive(:pane_details).and_return(panes)
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

    it "warns once when the process table can't be read five scans in a row, and again after a new streak" do
      err = StringIO.new
      warned = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, error_output: err)
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")

      4.times { warned.scan }
      expect(err.string).to eq("")
      6.times { warned.scan }
      expect(err.string.lines).to eq(["workspace agent: can't read the process table for proj " \
        "(5 scans in a row: ps timed out); idle alerts are paused until it can\n"])

      allow(process_tree).to receive(:snapshot).and_return(snapshot)
      warned.scan
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")
      4.times { warned.scan }
      expect(err.string.lines.size).to eq(1)
      warned.scan
      expect(err.string.lines.size).to eq(2)
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

    %w[user_prompt tool_use subagent_start stop session_start session_end].each do |event|
      it "clears waiting on a #{event} event" do
        notify

        monitor.record("event" => event, "pane_id" => "%2")

        expect(pane("%2")).to include("waiting_since" => nil, "waiting_message" => nil)
        expect(pane("%2")["state"]).not_to eq("waiting")
      end
    end

    it "keeps the main agent waiting when a sub-agent stops or uses a tool" do
      notify

      monitor.record("event" => "subagent_stop", "pane_id" => "%2")
      monitor.record("event" => "tool_use", "pane_id" => "%2", "agent_id" => "sub-1")

      expect(pane("%2")["state"]).to eq("waiting")
    end

    it "clears a sub-agent's wait on that sub-agent's next event, not the main agent's" do
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-1")

      monitor.record("event" => "tool_use", "pane_id" => "%2")
      expect(pane("%2")["state"]).to eq("waiting")

      monitor.record("event" => "tool_use", "pane_id" => "%2", "agent_id" => "sub-1")
      expect(pane("%2")["state"]).not_to eq("waiting")
    end

    it "keeps two sub-agents' waits apart, so one moving on leaves the other waiting" do
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-1", "message" => "first")
      allow(clock).to receive(:now).and_return(now + 30)
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-2", "message" => "second")

      monitor.record("event" => "tool_use", "pane_id" => "%2", "agent_id" => "sub-1")

      expect(pane("%2")).to include("state" => "waiting", "waiting_since" => (now + 30).iso8601,
        "waiting_message" => "second")
      monitor.record("event" => "subagent_stop", "pane_id" => "%2", "agent_id" => "sub-2")
      expect(pane("%2")["state"]).not_to eq("waiting")
    end

    it "reports the oldest wait when several agents in the pane are waiting" do
      notify("main")
      allow(clock).to receive(:now).and_return(now + 30)
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-1", "message" => "sub")

      expect(pane("%2")).to include("waiting_since" => now.iso8601, "waiting_message" => "main")
    end

    it "clears a sub-agent's wait when the turn ends" do
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-1")

      monitor.record("event" => "user_prompt", "pane_id" => "%2")

      expect(pane("%2")["state"]).not_to eq("waiting")
    end

    it "collapses control characters and whitespace in the message and caps its length" do
      notify("needs your\n\e[31mpermission\e[0m\a  now")
      expect(pane("%2")["waiting_message"]).to eq("needs your [31mpermission [0m now")

      notify("x" * 500)
      expect(pane("%2")["waiting_message"].length).to eq(described_class::MAX_MESSAGE_LENGTH)
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

  describe "#send_alerts" do
    let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

    subject(:monitor) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier, idle_alert_after: 600)
    end

    before { monitor.scan }

    def at(seconds)
      allow(clock).to receive(:now).and_return(now + seconds)
    end

    it "alerts once when an agent pane starts waiting, with the details in env vars" do
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "Claude needs your permission to use Bash")
      at(4)

      alerts = monitor.send_alerts
      monitor.send_alerts

      expect(alerts).to eq([{
        "WORKSPACE_ALERT" => "waiting",
        "WORKSPACE_ALERT_WORKSPACE" => "proj",
        "WORKSPACE_ALERT_PANE" => "0.1",
        "WORKSPACE_ALERT_PANE_ID" => "%2",
        "WORKSPACE_ALERT_KIND" => "claude",
        "WORKSPACE_ALERT_SECONDS" => "4",
        "WORKSPACE_ALERT_MESSAGE" => "Claude needs your permission to use Bash",
        "WORKSPACE_ALERT_TEXT" => "proj pane 0.1 (Claude Code) is waiting: Claude needs your permission to use Bash"
      }])
      expect(notifier).to have_received(:notify).once
    end

    it "alerts again for a new wait after the last one cleared" do
      monitor.record("event" => "notification", "pane_id" => "%2")
      monitor.send_alerts
      monitor.record("event" => "user_prompt", "pane_id" => "%2")
      at(10)
      monitor.record("event" => "notification", "pane_id" => "%2")

      monitor.send_alerts

      expect(notifier).to have_received(:notify).twice
    end

    it "alerts for a second agent's wait even while the pane is already waiting" do
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "main")
      monitor.send_alerts
      monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => "sub-1", "message" => "sub")

      expect(monitor.send_alerts.map { |a| a["WORKSPACE_ALERT_MESSAGE"] }).to eq(["sub"])
      expect(monitor.send_alerts).to eq([])
    end

    it "alerts once when an agent pane stays idle past the threshold, not on every scan" do
      at(599)
      monitor.scan
      expect(monitor.send_alerts).to eq([])

      at(600)
      monitor.scan
      alerts = monitor.send_alerts
      at(900)
      monitor.scan
      monitor.send_alerts

      expect(alerts.map { |a| [a["WORKSPACE_ALERT"], a["WORKSPACE_ALERT_PANE_ID"], a["WORKSPACE_ALERT_SECONDS"]] })
        .to eq([["idle", "%2", "600"]])
      expect(alerts.first["WORKSPACE_ALERT_TEXT"]).to eq("proj pane 0.1 (Claude Code) has been idle for 10m")
      expect(notifier).to have_received(:notify).once
    end

    it "alerts for idle again once the pane's output has changed and gone quiet again" do
      at(600)
      monitor.scan
      monitor.send_alerts
      allow(tmux).to receive(:capture_pane).and_return("new output")
      at(700)
      monitor.scan
      at(1300)
      monitor.scan

      monitor.send_alerts

      expect(notifier).to have_received(:notify).twice
    end

    it "does not alert for idle while the pane is waiting, which has its own alert" do
      monitor.record("event" => "notification", "pane_id" => "%2")
      monitor.send_alerts
      at(700)
      monitor.scan

      expect(monitor.send_alerts).to eq([])
    end

    it "never alerts for a shell pane" do
      at(700)
      monitor.scan
      monitor.record("event" => "notification", "pane_id" => "%1")

      expect(monitor.send_alerts.map { |a| a["WORKSPACE_ALERT_PANE_ID"] }).to eq(["%2"])
    end

    it "drops NUL bytes, which can't be passed in an environment variable" do
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "a\u0000b")

      expect(monitor.send_alerts.first["WORKSPACE_ALERT_MESSAGE"]).to eq("a b")
    end

    it "alerts only on waiting when no idle threshold is set" do
      quiet = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier)
      quiet.scan
      at(10_000)
      quiet.scan

      expect(quiet.send_alerts).to eq([])
    end

    it "sends nothing without a notifier" do
      plain = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj", clock: clock)
      plain.scan
      plain.record("event" => "notification", "pane_id" => "%2")

      expect(plain.send_alerts).to eq([])
    end

    it "returns an empty list instead of raising when the notifier raises, so the scan thread survives" do
      allow(notifier).to receive(:notify).and_raise(ThreadError, "can't create Thread")
      monitor.record("event" => "notification", "pane_id" => "%2")

      expect(monitor.send_alerts).to eq([])
    end

    it "retries an alert whose notify raised on the next call" do
      calls = 0
      allow(notifier).to receive(:notify) { ((calls += 1) == 1) ? raise(ThreadError, "can't create Thread") : :started }
      monitor.record("event" => "notification", "pane_id" => "%2")

      expect(monitor.send_alerts).to eq([])
      expect(monitor.send_alerts.map { |a| a["WORKSPACE_ALERT"] }).to eq(["waiting"])
      expect(monitor.send_alerts).to eq([])
    end

    it "retries an alert the notifier skipped for having too many runs going, once a run finishes" do
      agents = (2..6).map { |n| {id: "%#{n}", index: n, pid: n * 100, command: "claude", cwd: "/project", title: "Claude"} }
      allow(tmux).to receive(:pane_details).with("proj").and_return(agents)
      monitor.scan
      agents.each { |a| monitor.record("event" => "notification", "pane_id" => a[:id]) }
      free_slots = 4
      allow(notifier).to receive(:notify) do
        next nil if free_slots.zero?
        free_slots -= 1
        :started
      end

      first = monitor.send_alerts
      expect(monitor.send_alerts).to eq([])
      free_slots = 1
      later = monitor.send_alerts

      expect(first.size).to eq(4)
      sent = (first + later).map { |a| a["WORKSPACE_ALERT_PANE_ID"] }
      expect(sent).to match_array(agents.map { |a| a[:id] })
      expect(monitor.send_alerts).to eq([])
    end

    it "holds idle alerts while the process table can't be read, since output went uncaptured" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps timed out")
      at(700)
      monitor.scan

      expect(monitor.send_alerts).to eq([])
    end
  end

  describe "#stop" do
    it "stops the notifier, so no notify command outlives the monitor" do
      notifier = instance_double(Workspace::Notifier, stop: nil)
      monitor = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        clock: clock, notifier: notifier)

      monitor.stop

      expect(notifier).to have_received(:stop)
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

  describe "#pane_kind and #pane_state" do
    it "answers for one pane without building the whole snapshot" do
      monitor.scan
      monitor.record("pane_id" => "%2", "event" => "notification", "message" => "Allow?")

      expect(monitor.pane_kind("%1")).to eq("shell")
      expect(monitor.pane_kind("%2")).to eq("claude")
      expect(monitor.pane_state("%1")).to eq("working")
      expect(monitor.pane_state("%2")).to eq("waiting")
    end

    it "returns nil for a pane it hasn't scanned" do
      expect(monitor.pane_kind("%9")).to be_nil
      expect(monitor.pane_state("%9")).to be_nil
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

  describe "state history in the event log" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:log_config) do
      Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
        allow(c).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
      end
    end
    let(:log_errors) { StringIO.new }
    let(:event_log) { Workspace::EventLog.new(config: log_config, error_output: log_errors, clock: clock) }

    after { FileUtils.remove_entry(tmpdir) }

    def logging_monitor
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session",
        idle_after: 30, clock: clock, event_log: event_log, project: "proj")
    end

    def logged_states
      event_log.events.select { |e| e["type"] == "agent_state" }.map { |e| [e["data"]["pane_id"], e["data"]["state"], e["data"]["since"]] }
    end

    it "records each agent pane's state changes, and none for shell panes" do
      monitor = logging_monitor
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 31)
      monitor.scan
      monitor.scan

      expect(logged_states).to eq([
        ["%2", "working", "2026-09-26T12:00:00.000Z"],
        ["%2", "idle", "2026-09-26T12:00:30.000Z"]
      ])
      expect(event_log.events.map { |e| e["project"] }.uniq).to eq(["proj"])
      expect(event_log.events.last["data"]).to include("pane_pid" => 200, "index" => 1, "kind" => "claude")
    end

    it "records waiting from when the agent asked, and closed when the pane goes" do
      monitor = logging_monitor
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 5)
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "May I?")
      allow(clock).to receive(:now).and_return(now + 7)
      monitor.scan
      allow(tmux).to receive(:pane_details).with("proj-session").and_return([panes.first])
      monitor.scan

      expect(logged_states.map { |_, state, since| [state, since] }).to eq([
        ["working", "2026-09-26T12:00:00.000Z"],
        ["waiting", "2026-09-26T12:00:05.000Z"],
        ["closed", "2026-09-26T12:00:07.000Z"]
      ])
    end

    it "records exited when the agent leaves a pane that stays open" do
      monitor = logging_monitor
      monitor.scan
      allow(snapshot).to receive(:find_descendant).and_return(nil)
      monitor.scan

      expect(logged_states.map { |_, state, _| state }).to eq(["working", "exited"])
    end

    it "picks up an idle pane's state and start time after a restart, without logging it again" do
      first = logging_monitor
      first.scan
      allow(clock).to receive(:now).and_return(now + 31)
      first.scan

      allow(clock).to receive(:now).and_return(now + 100)
      restarted = logging_monitor
      restarted.scan
      pane = restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }

      expect(pane).to include("state" => "idle", "state_since" => "2026-09-26T12:00:30Z", "idle_seconds" => 100)
      expect(logged_states.size).to eq(2)
    end

    describe "idle alerts across a restart" do
      let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

      def alerting_monitor
        described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session",
          idle_after: 30, idle_alert_after: 60, clock: clock, notifier: notifier, event_log: event_log, project: "proj")
      end

      def at(seconds)
        allow(clock).to receive(:now).and_return(now + seconds)
      end

      def alert_events
        event_log.events.select { |e| e["type"] == "agent_alert" }.map { |e| e["data"] }
      end

      before do
        first = alerting_monitor
        first.scan
        at(90)
        first.scan
        first.send_alerts
      end

      it "logs each idle alert with the quiet stretch it was for" do
        expect(alert_events).to eq([
          {"pane_id" => "%2", "pane_pid" => 200, "kind" => "idle", "idle_since" => "2026-09-26T12:00:00.000Z"}
        ])
      end

      it "does not alert again for the same quiet stretch" do
        at(120)
        restarted = alerting_monitor
        restarted.scan

        expect(restarted.send_alerts).to be_empty
      end

      it "alerts for a quiet stretch that began after the last alert" do
        first = alerting_monitor
        first.scan
        at(100)
        allow(tmux).to receive(:capture_pane).and_return("new output")
        first.scan
        at(140)
        first.scan

        at(200)
        restarted = alerting_monitor
        restarted.scan

        expect(restarted.send_alerts.size).to eq(1)
      end
    end

    describe "waiting alerts across a restart" do
      let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

      def alerting_monitor
        described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session",
          idle_after: 30, clock: clock, notifier: notifier, event_log: event_log, project: "proj")
      end

      def at(seconds)
        allow(clock).to receive(:now).and_return(now + seconds)
      end

      def ask(monitor, agent_id = nil)
        monitor.record("event" => "notification", "pane_id" => "%2", "agent_id" => agent_id, "message" => "May I?")
      end

      def alert_events
        event_log.events.select { |e| e["type"] == "agent_alert" }.map { |e| e["data"] }
      end

      let!(:first) do
        alerting_monitor.tap do |monitor|
          monitor.scan
          at(5)
          ask(monitor)
          monitor.scan
          monitor.send_alerts
        end
      end

      it "logs each waiting alert with the agent and the wait it was for" do
        expect(alert_events).to eq([
          {"pane_id" => "%2", "pane_pid" => 200, "kind" => "waiting", "agent_id" => nil,
           "waiting_since" => "2026-09-26T12:00:05.000Z"}
        ])
      end

      it "does not alert again when the agent asks again during the same wait" do
        at(60)
        restarted = alerting_monitor
        restarted.scan
        ask(restarted)
        restarted.scan

        expect(restarted.send_alerts).to be_empty
        expect(restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" })
          .to include("state" => "waiting", "waiting_since" => "2026-09-26T12:00:05Z")
      end

      it "does not alert again when the agent asks before the first scan after the restart" do
        at(60)
        restarted = alerting_monitor
        ask(restarted)
        restarted.scan

        expect(restarted.send_alerts).to be_empty
      end

      it "alerts for a wait that begins after the agent moved on" do
        at(60)
        restarted = alerting_monitor
        restarted.scan
        restarted.record("event" => "post_tool_use", "pane_id" => "%2")
        ask(restarted)
        restarted.scan

        expect(restarted.send_alerts.size).to eq(1)
      end

      it "alerts for another agent's wait in the same pane" do
        at(60)
        restarted = alerting_monitor
        restarted.scan
        ask(restarted, "sub-1")
        restarted.scan

        expect(restarted.send_alerts.map { |env| env["WORKSPACE_ALERT"] }).to eq(["waiting"])
      end

      it "alerts for a new waiting stretch after the pane stopped waiting" do
        first.record("event" => "stop", "pane_id" => "%2")
        at(20)
        first.scan
        at(60)
        restarted = alerting_monitor
        restarted.scan
        ask(restarted)
        restarted.scan

        expect(restarted.send_alerts.size).to eq(1)
      end
    end

    it "passes a restored pane's agent pid to the context reader on the first scan" do
      logging_monitor.scan
      context_reader = instance_double(Workspace::ContextReader)
      allow(context_reader).to receive(:read).and_return(pct: 10, error: nil, updated_at: nil)

      allow(clock).to receive(:now).and_return(now + 10)
      restarted = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session",
        idle_after: 30, clock: clock, event_log: event_log, project: "proj", context_reader: context_reader)
      restarted.scan
      restarted.snapshot

      expect(context_reader).to have_received(:read).with(pane_id: "%2", agent_pid: 250, current_session_id: nil)
    end

    it "keeps a restored working pane's start time" do
      logging_monitor.scan

      allow(clock).to receive(:now).and_return(now + 10)
      restarted = logging_monitor
      restarted.scan

      expect(restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state_since"]).to eq("2026-09-26T12:00:00Z")
      expect(logged_states.size).to eq(1)
    end

    it "does not restore a pane id that now belongs to a different pane process" do
      logging_monitor.scan
      allow(tmux).to receive(:pane_details).with("proj-session").and_return([panes.last.merge(pid: 999)])
      allow(snapshot).to receive(:find_descendant).with(999, ["claude"], hash_including(include_root: true))
        .and_return({pid: 1000, command: "claude", args: "claude"})

      allow(clock).to receive(:now).and_return(now + 10)
      logging_monitor.scan

      expect(logged_states.last).to eq(["%2", "working", "2026-09-26T12:00:10.000Z"])
    end

    it "keeps scanning when the log can't be written, warning once" do
      allow(log_config).to receive(:event_log_file).and_return(File.join(tmpdir, "gone", "events.jsonl"))
      monitor = logging_monitor
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 31)
      monitor.scan

      expect(monitor.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state"]).to eq("idle")
      expect(log_errors.string.lines.size).to eq(1)
    end
  end

  describe "context fields" do
    let(:context_reader) { instance_double(Workspace::ContextReader) }

    subject(:monitor) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, context_reader: context_reader)
    end

    it "stamps a coding-agent pane with context_pct/context_error/context_updated_at" do
      allow(context_reader).to receive(:read).with(pane_id: "%2", agent_pid: 250, current_session_id: nil)
        .and_return(pct: 55, error: nil, updated_at: "2026-09-27T00:00:00Z")

      monitor.scan

      expect(pane("%2")["context_pct"]).to eq(55)
      expect(pane("%2")["context_error"]).to be_nil
      expect(pane("%2")["context_updated_at"]).to eq("2026-09-27T00:00:00Z")
    end

    it "never stamps context fields onto a shell pane" do
      allow(context_reader).to receive(:read).and_return(pct: 1, error: nil, updated_at: nil)
      monitor.scan

      expect(pane("%1")).not_to have_key("context_pct")
      expect(pane("%1")).not_to have_key("context_error")
    end

    it "reports the reason when context can't be determined" do
      allow(context_reader).to receive(:read).and_return(pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil)

      monitor.scan

      expect(pane("%2")["context_pct"]).to be_nil
      expect(pane("%2")["context_error"]).to eq(Workspace::ContextReasons::NO_READING)
    end

    it "omits context fields entirely when no context_reader is injected" do
      no_reader_monitor = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock)
      no_reader_monitor.scan

      pane = no_reader_monitor.snapshot["panes"].find { |p| p["pane_id"] == "%2" }
      expect(pane).not_to have_key("context_pct")
    end

    it "never lets a context_reader failure raise out of a scan" do
      allow(context_reader).to receive(:read).and_raise(StandardError, "boom")

      expect { monitor.scan }.not_to raise_error
      expect(pane("%2")["context_error"]).to eq(Workspace::ContextReasons::NO_READING)
    end
  end
end
