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

  describe "closing a question from the screen" do
    let(:times) { [Time.utc(2026, 10, 31, 12, 0, 0)] }
    let(:clock) { Struct.new(:source) { def now = source[0] }.new(times) }
    let(:ask) { {"pane_id" => "%2", "session_id" => "s1"} }
    let(:err) { StringIO.new }

    subject(:monitor) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, error_output: err)
    end

    def fixture(name)
      File.read(File.expand_path("../fixtures/claude_screens/#{name}.txt", __dir__))
    end

    def show(name)
      allow(tmux).to receive(:capture_screen_styled).with("%2").and_return(fixture(name))
    end

    def open_question(tool = "AskUserQuestion", id = "t1")
      monitor.record(ask.merge("event" => "tool_start", "tool" => tool, "tool_use_id" => id))
    end

    def scans(count, seconds: 10)
      count.times do
        times[0] += seconds
        monitor.scan
      end
    end

    def open_tools = monitor.typing_facts("%2")[:open_tools]

    # What `WorkflowPanes#screen_refusal` builds in the `advance` process.
    def advance_facts
      row = pane("%2")
      {kind: row["kind"], state: row["activity_state"], open_tools: row["open_tools"]}
    end

    before do
      show("question_open_single")
      monitor.scan
      open_question
    end

    it "keeps the tool open for as long as a dialog shows, and types nothing into it" do
      scans(30)

      expect(open_tools).to eq(["AskUserQuestion"])
      expect(Workspace::TypingSafety.new.check(monitor.typing_facts("%2"), Workspace::StyledScreen.parse(fixture("question_open_single"))))
        .to include(reason: "question_open")
    end

    it "keeps the tool open through a slow PreToolUse hook, the box empty with a spinner over it" do
      show("question_about_to_draw")
      scans(30)

      expect(open_tools).to eq(["AskUserQuestion"])
    end

    it "closes the tool only after one reading held, for the daemon's facts and for the snapshot" do
      show("question_closed_single")
      scans(1)
      expect(open_tools).to eq(["AskUserQuestion"])

      scans(1)
      expect(open_tools).to eq([])
      expect(advance_facts[:open_tools]).to eq([])
      screen = Workspace::StyledScreen.parse(fixture("question_closed_single"))
      expect(Workspace::TypingSafety.new.check(monitor.typing_facts("%2"), screen)).to be_nil
      expect(Workspace::TypingSafety.new.check(advance_facts, screen)).to be_nil
    end

    it "keeps the question open when the capture raises or comes back empty" do
      allow(tmux).to receive(:capture_screen_styled).with("%2").and_raise(Workspace::Error, "no server")
      scans(3)
      expect(open_tools).to eq(["AskUserQuestion"])

      allow(tmux).to receive(:capture_screen_styled).with("%2").and_return(nil)
      scans(3)
      expect(open_tools).to eq(["AskUserQuestion"])
    end

    it "keeps the question open when the capture is not valid UTF-8" do
      allow(tmux).to receive(:capture_screen_styled).with("%2")
        .and_return((+"────\n❯ \n────\ncaf\xE9\n").force_encoding("UTF-8"))
      scans(3)
      expect(open_tools).to eq(["AskUserQuestion"])
    end

    it "reports the close on the daemon's error stream" do
      show("question_closed_single")
      scans(1)
      expect(err.string).to be_empty
      scans(1)
      expect(open_tools).to eq([])
      expect(err.string).to match(/question closed in %2/)
    end

    it "waits out the hold when scans come faster" do
      show("question_closed_single")
      scans(8, seconds: 1)
      expect(open_tools).to eq(["AskUserQuestion"])

      scans(1, seconds: 1)
      expect(open_tools).to eq([])
    end

    it "does not close on an empty box that a dialog then replaces" do
      show("question_closed_single")
      scans(1)
      show("question_open_single")
      scans(1)
      show("question_closed_single")
      scans(1)

      expect(open_tools).to eq(["AskUserQuestion"])
    end

    it "starts over when the rows above the box change" do
      show("question_closed_single")
      scans(1)
      show("question_closed_tabs")
      scans(1)

      expect(open_tools).to eq(["AskUserQuestion"])
      scans(1)
      expect(open_tools).to eq([])
    end

    it "starts over on a hook event" do
      show("question_closed_single")
      scans(1)
      times[0] += 1
      monitor.record(ask.merge("event" => "notification", "message" => "Claude needs your input"))
      scans(1)

      expect(open_tools).to eq(["AskUserQuestion"])
      scans(1)
      expect(open_tools).to eq([])
    end

    it "starts over for a question opened since" do
      show("question_closed_single")
      scans(1)
      times[0] += 1
      open_question("ExitPlanMode", "t2")
      scans(1)

      expect(open_tools).to eq(%w[AskUserQuestion ExitPlanMode])
      scans(1)
      expect(open_tools).to eq([])
    end

    it "leaves a draft alone: the tool stays open and the pane refused" do
      allow(tmux).to receive(:capture_screen_styled).with("%2").and_return("────────\n❯ half a thought\n────────\n")
      scans(5)

      expect(open_tools).to eq(["AskUserQuestion"])
      expect(Workspace::TypingSafety.new.check(monitor.typing_facts("%2"), "────────\n❯ half a thought\n────────\n"))
        .to include(reason: "question_open")
    end

    it "keeps other tools open, closes ExitPlanMode too" do
      monitor.record(ask.merge("event" => "tool_start", "tool" => "Bash", "tool_use_id" => "t2"))
      open_question("ExitPlanMode", "t3")
      show("question_closed_exit_plan")
      scans(2)

      expect(open_tools).to eq(["Bash"])
    end

    it "ends the wait the question's Notification opened, once the screen proves it" do
      monitor.record(ask.merge("event" => "notification", "message" => "Claude needs your input"))
      expect(monitor.restart_state("%2")).to eq("waiting")
      show("question_closed_single")
      scans(1)
      expect(monitor.restart_state("%2")).to eq("waiting")

      scans(1)
      expect(monitor.restart_state("%2")).to eq("idle")
      expect(pane("%2")["activity_state"]).not_to eq("waiting")
    end

    it "leaves a sub-agent's wait alone" do
      monitor.record(ask.merge("event" => "notification", "agent_id" => "sub1", "message" => "permission"))
      show("question_closed_single")
      scans(2)

      expect(open_tools).to eq([])
      expect(monitor.restart_state("%2")).to eq("waiting")
    end

    it "opens no wait for the idle notification that comes after" do
      show("question_closed_single")
      scans(2)
      monitor.record(ask.merge("event" => "notification", "notification_type" => "idle_prompt", "message" => "Claude is waiting for your input"))

      expect(monitor.restart_state("%2")).to eq("idle")
    end

    it "reads the styled screen only while a question tool is open" do
      show("question_closed_single")
      scans(2)
      expect(tmux).not_to receive(:capture_screen_styled)

      scans(3)
    end
  end

  describe "#main_turn_over_since" do
    let(:times) { [Time.utc(2026, 10, 31, 12, 0, 0)] }
    let(:clock) { Struct.new(:source) { def now = source[0] }.new(times) }

    before { monitor.scan }

    def hook(name, extra = {})
      times[0] += 1
      monitor.record({"event" => name, "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t.jsonl"}.merge(extra))
    end

    def missing = monitor.main_turn_evidence("%2")[:missing]

    it "is the time of the main Stop, with the transcript" do
      hook("stop")

      expect(monitor.main_turn_over_since("%2")).to eq(times[0])
      expect(monitor.main_turn_evidence("%2")).to eq(since: times[0], transcript_path: "/t.jsonl")
    end

    it "is nil for a pane not seen, a shell and a pane with no Stop heard" do
      expect(monitor.main_turn_over_since("%9")).to be_nil
      expect(monitor.main_turn_evidence("%9")[:missing]).to eq("pane_unknown")
      expect(monitor.main_turn_evidence("%1")[:missing]).to eq("not_claude")
      hook("user_prompt")
      expect(missing).to eq("no_stop_seen")
    end

    it "is nil with no hooks from the pane's agent" do
      expect(missing).to eq("no_hooks")
    end

    it "is nil for hooks from another agent" do
      hook("stop", "agent_kind" => "codex")
      expect(missing).to eq("no_hooks")
    end

    it "doesn't take a sub-agent's Stop for the main one" do
      hook("user_prompt")
      hook("stop", "agent_id" => "a1")
      expect(missing).to eq("no_stop_seen")
    end

    {
      "tool_start" => "main_tool_after_stop", "tool_use" => "main_tool_after_stop", "user_prompt" => "main_prompt_after_stop",
      "subagent_start" => "subagent_start_after_stop", "session_start" => "session_start_after_stop", "session_end" => "session_end_after_stop"
    }.each do |event, name|
      it "is nil after a main #{event}, until the next Stop" do
        hook("stop")
        hook(event, "tool" => "Bash")

        expect(monitor.main_turn_over_since("%2")).to be_nil
        expect(missing).to eq(name)

        hook("stop")
        expect(monitor.main_turn_over_since("%2")).to eq(times[0])
      end
    end

    it "keeps its time through a sub-agent's tool use and Stop" do
      hook("stop")
      stopped = times[0]
      hook("tool_start", "agent_id" => "a1", "tool" => "Bash")
      hook("tool_use", "agent_id" => "a1", "tool" => "Bash")
      hook("stop", "agent_id" => "a1")

      expect(monitor.main_turn_over_since("%2")).to eq(stopped)
    end

    it "counts a sub-agent start from a sub-agent, which takes the done mark too" do
      hook("stop")
      hook("subagent_start", "agent_id" => "a1")
      expect(missing).to eq("subagent_start_after_stop")
    end

    it "is nil on a wait, and on a failed turn" do
      hook("stop")
      hook("notification", "message" => "Allow Bash?", "notification_type" => "permission_prompt")
      expect(missing).to eq("waiting")

      hook("stop")
      monitor.mark_turn_failed("%2")
      expect(missing).to eq("turn_failed")
    end
  end

  describe "what a parked resume reads from the snapshot" do
    let(:times) { [Time.utc(2026, 10, 31, 12, 0, 0)] }
    let(:clock) { Struct.new(:source) { def now = source[0] }.new(times) }

    before { monitor.scan }

    def hook(name, extra = {})
      times[0] += 1
      monitor.record({"event" => name, "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t.jsonl"}.merge(extra))
    end

    it "lists the feature" do
      expect(monitor.snapshot["features"]).to eq(["parked_resume"])
    end

    it "gives a main Stop's time to the millisecond, with the transcript" do
      times[0] += 0.25
      hook("stop")

      expect(pane("%2")).to include("main_turn_over_since" => "2026-10-31T12:00:01.250Z", "transcript_path" => "/t.jsonl")
    end

    it "keeps the time through a sub-agent's tool use" do
      hook("stop")
      hook("tool_use", "agent_id" => "a1", "tool" => "Bash", "tool_use_id" => "t1")

      expect(pane("%2")["main_turn_over_since"]).to eq("2026-10-31T12:00:01.000Z")
    end

    it "drops the time on a wake-up's main tool_start, with the done mark still set" do
      hook("stop")
      hook("tool_start", "tool" => "Bash", "tool_use_id" => "t1")

      expect(pane("%2")).to include("state" => "done", "main_turn_over_since" => nil, "open_tools" => ["Bash"])
    end

    it "has no time for a pane with no Stop heard, a monitor that lost it, and a failed turn" do
      expect(pane("%2")["main_turn_over_since"]).to be_nil

      hook("stop")
      monitor.mark_turn_failed("%2")
      expect(pane("%2")).to include("main_turn_over_since" => nil, "turn_failed" => true)
    end

    it "gives the working state a done mark hides, and a waiting one" do
      hook("stop")
      expect(pane("%2")).to include("state" => "done", "activity_state" => "working")

      times[0] += 31
      expect(pane("%2")).to include("state" => "done", "activity_state" => "idle")

      hook("notification", "message" => "Allow Bash?", "notification_type" => "permission_prompt")
      expect(pane("%2")["activity_state"]).to eq("waiting")
    end

    it "closes a tool by id on a failed tool's event, which counts as main activity" do
      hook("stop")
      hook("tool_start", "tool" => "AskUserQuestion", "tool_use_id" => "t1")
      hook("tool_start", "tool" => "Bash", "tool_use_id" => "t2")
      hook("tool_use", "tool" => "AskUserQuestion", "tool_use_id" => "t1", "ok" => false)

      expect(pane("%2")["open_tools"]).to eq(["Bash"])
      expect(monitor.main_turn_evidence("%2")[:missing]).to eq("main_tool_after_stop")
    end

    it "gives a shell pane an empty tool list" do
      expect(pane("%1")).to include("open_tools" => [], "transcript_path" => nil, "main_turn_over_since" => nil)
    end
  end

  describe "the default poll interval" do
    it "matches the agentd.poll_interval default the config schema declares" do
      expect(monitor.instance_variable_get(:@poll_interval)).to eq(Workspace::SessionMonitor::DEFAULT_POLL_INTERVAL)
      expect(Workspace::SessionMonitor::DEFAULT_POLL_INTERVAL).to eq(Workspace::ConfigSchema.default("agentd.poll_interval"))
    end
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

  describe "scan slots" do
    let(:scan_slots) { instance_double(Workspace::ScanSlotLimiter) }

    subject(:slotted) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, scan_slots: scan_slots)
    end

    it "scans under a slot when one is available" do
      allow(scan_slots).to receive(:with_scan_slot).and_yield

      slotted.scan

      expect(slotted.snapshot["panes"].map { |p| p["pane_id"] }).to eq(["%1", "%2"])
    end

    it "rescans a pane even while the scan slot is busy" do
      allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
      allow(tmux).to receive(:pane_details).and_return([{id: "%2", index: 1, pid: 200, command: "zsh", cwd: "/project", title: "Claude"}])
      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], anything).and_return(nil)
      slotted.rescan_pane("%2")
      expect(slotted.pane_kind("%2")).to eq("shell")

      allow(snapshot).to receive(:find_descendant)
        .with(200, ["claude"], hash_including(include_root: true))
        .and_return({pid: 250, command: "claude", args: "claude"})
      slotted.rescan_pane("%2")

      expect(slotted.pane_kind("%2")).to eq("claude")
      expect(scan_slots).not_to have_received(:with_scan_slot)
    end

    it "skips the scan when no slot is available" do
      allow(scan_slots).to receive(:with_scan_slot).and_return(nil)

      slotted.scan

      expect(slotted.snapshot["panes"]).to eq([])
    end

    it "keeps the last scanned state when a tick is skipped" do
      allow(scan_slots).to receive(:with_scan_slot).and_yield
      slotted.scan
      allow(clock).to receive(:now).and_return(now + 31)
      allow(scan_slots).to receive(:with_scan_slot).and_return(nil)
      allow(tmux).to receive(:capture_pane).and_return("new output")

      slotted.scan

      # The pane's output changed, but no scan ran under a slot. If it had,
      # the changed output would reset last_activity_at and report working.
      pane = slotted.snapshot["panes"].find { |p| p["pane_id"] == "%1" }
      expect(pane["state"]).to eq("idle")
      expect(pane["idle_seconds"]).to eq(31)
    end

    it "bounds concurrent scans across monitors sharing one slot directory" do
      slot_dir = Dir.mktmpdir("ws-scan-slots")
      begin
        limit = 2
        active = 0
        peak = 0
        peak_lock = Mutex.new
        allow(process_tree).to receive(:snapshot) do
          peak_lock.synchronize do
            active += 1
            peak = [peak, active].max
          end
          sleep 0.05
          peak_lock.synchronize { active -= 1 }
          snapshot
        end

        monitors = Array.new(6) do
          described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
            idle_after: 30, clock: clock,
            scan_slots: Workspace::ScanSlotLimiter.new(dir: File.join(slot_dir, "scan-slots"), limit: limit))
        end

        Array.new(monitors.size) { |i| Thread.new { monitors[i].scan } }.each(&:join)

        expect(peak).to be <= limit
        expect(peak).to be > 1
      ensure
        FileUtils.remove_entry(slot_dir)
      end
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

  describe "done" do
    before { monitor.scan }

    def stop(extra = {})
      monitor.record({"event" => "stop", "pane_id" => "%2"}.merge(extra))
    end

    it "reports done with the default stop reason once the Stop hook fires" do
      allow(clock).to receive(:now).and_return(now + 5)
      stop

      expect(pane("%2")).to include("state" => "done", "stop_reason" => "end_turn", "state_since" => (now + 5).iso8601)
    end

    it "reports the stop reason the hook carries" do
      stop("stop_reason" => "max_tokens")

      expect(pane("%2")).to include("state" => "done", "stop_reason" => "max_tokens")
    end

    it "stays done however long the pane is quiet" do
      stop
      allow(clock).to receive(:now).and_return(now + 600)

      expect(pane("%2")).to include("state" => "done", "idle_seconds" => 600)
    end

    it "leaves stop_reason null while the pane is not done" do
      expect(pane("%2")).to include("state" => "working", "stop_reason" => nil)
    end

    it "leaves done on the next prompt" do
      stop
      monitor.record("event" => "user_prompt", "pane_id" => "%2", "prompt" => "next")

      expect(pane("%2")).to include("state" => "working", "stop_reason" => nil)
    end

    it "leaves done when a session starts or ends in the pane" do
      ["session_start", "session_end"].each do |name|
        stop
        monitor.record("event" => name, "pane_id" => "%2")

        expect(pane("%2")["state"]).not_to eq("done")
      end
    end

    it "leaves done when the agent works again without a prompt" do
      stop
      monitor.record("event" => "tool_use", "pane_id" => "%2")

      expect(pane("%2")["state"]).not_to eq("done")
    end

    it "keeps done when a sub-agent uses a tool after the Stop" do
      stop
      monitor.record("event" => "tool_use", "pane_id" => "%2", "agent_id" => "sub-1")

      expect(pane("%2")["state"]).to eq("done")
    end

    it "leaves done when the main agent uses a tool after the Stop" do
      stop
      monitor.record("event" => "tool_use", "pane_id" => "%2", "agent_id" => nil)

      expect(pane("%2")["state"]).not_to eq("done")
    end

    it "leaves done when a sub-agent starts" do
      stop
      monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "x"})

      expect(pane("%2")["state"]).not_to eq("done")
    end

    it "stays done, and opens no wait, when the agent's idle notification arrives after the turn ended" do
      stop
      monitor.record("event" => "notification", "pane_id" => "%2", "notification_type" => "idle_prompt",
        "message" => "Claude is waiting for your input")

      expect(pane("%2")).to include("state" => "done", "waiting_message" => nil)
      expect(monitor.restart_state("%2")).to eq("idle")
      expect(monitor.typing_facts("%2")).to include(state: "idle")
    end

    it "recognises the idle notification by its message when the hook sent no type" do
      stop
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "Claude is waiting for your input")

      expect(monitor.restart_state("%2")).to eq("idle")
    end

    it "still waits on a permission notification after a Stop" do
      stop
      monitor.record("event" => "notification", "pane_id" => "%2", "notification_type" => "permission_prompt",
        "message" => "Claude needs your permission to use Bash")

      expect(monitor.restart_state("%2")).to eq("waiting")
      expect(monitor.typing_facts("%2")).to include(state: "waiting")
    end

    it "keeps an idle-looking message as a wait while the turn is still going" do
      monitor.record("event" => "user_prompt", "pane_id" => "%2")
      monitor.record("event" => "notification", "pane_id" => "%2", "message" => "Claude is waiting for your input")

      expect(monitor.restart_state("%2")).to eq("waiting")
    end

    it "is not set by a sub-agent stopping, or by a Stop from a sub-agent" do
      monitor.record("event" => "subagent_stop", "pane_id" => "%2")
      expect(pane("%2")["state"]).to eq("working")

      stop("agent_id" => "sub-1")
      expect(pane("%2")["state"]).to eq("working")
    end

    it "is dropped when the agent leaves the pane" do
      stop
      allow(snapshot).to receive(:find_descendant).and_return(nil)
      monitor.scan

      expect(pane("%2")["state"]).not_to eq("done")
      expect(pane("%2")["stop_reason"]).to be_nil
    end

    it "does not change the restart busy check" do
      stop

      expect(monitor.pane_state("%2")).to eq("working")
      expect(monitor.restart_state("%2")).to eq("idle")
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

    %w[user_prompt tool_use stop session_start session_end].each do |event|
      it "clears waiting on a #{event} event" do
        notify

        monitor.record("event" => event, "pane_id" => "%2")

        expect(pane("%2")).to include("waiting_since" => nil, "waiting_message" => nil)
        expect(pane("%2")["state"]).not_to eq("waiting")
      end
    end

    it "keeps waiting when another tool starts, since tools run side by side" do
      notify

      monitor.record("event" => "tool_start", "pane_id" => "%2", "tool" => "Read")

      expect(pane("%2")).to include("state" => "waiting", "waiting_since" => now.iso8601)
    end

    it "keeps waiting when a sub-agent is started by the Agent tool" do
      notify

      monitor.record("event" => "subagent_start", "pane_id" => "%2", "tool" => "Agent", "tool_use_id" => "toolu_415751845")

      expect(pane("%2")).to include("state" => "waiting", "waiting_since" => now.iso8601)
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

  describe "permission requests" do
    let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

    subject(:monitor) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier)
    end

    before { monitor.scan }

    def at(seconds)
      allow(clock).to receive(:now).and_return(now + seconds)
    end

    def event(name, **fields)
      monitor.record({"event" => name, "pane_id" => "%2"}.merge(fields.transform_keys(&:to_s).compact))
    end

    def request(tool: "Bash", input: "rm -rf build", agent_id: nil)
      event("permission_request", tool: tool, input: input, agent_id: agent_id)
    end

    def prompt(type = "permission_prompt")
      event("notification", notification_type: type, message: "Claude needs your permission")
    end

    def tool_done(tool: "Bash", agent_id: nil)
      event("tool_use", tool: tool, agent_id: agent_id)
    end

    def waits
      monitor.instance_variable_get(:@panes)["%2"][:waits]
    end

    def requests
      monitor.instance_variable_get(:@panes)["%2"][:permission_requests]
    end

    def expect_null_fields
      expect(pane("%2")).to include("waiting_tool" => nil, "waiting_input" => nil)
    end

    describe "storing a request" do
      it "keeps the whole summary, past the length of a message" do
        input = "x" * 250
        request(input: input)
        prompt

        expect(pane("%2")).to include("waiting_tool" => "Bash", "waiting_input" => input)
      end

      it "caps the input and cleans the tool name" do
        request(tool: "Ba\nsh", input: "é" * 400)
        prompt

        expect(pane("%2")["waiting_tool"]).to eq("Ba sh")
        expect(pane("%2")["waiting_input"].bytesize).to be <= Workspace::ToolInputSummary::MAX_BYTES
        expect(pane("%2")["waiting_input"]).to be_valid_encoding
      end

      it "reports a null input with the tool set for a tool with no summary" do
        request(tool: "mcp__x__y", input: nil)
        prompt

        expect(pane("%2")).to include("waiting_tool" => "mcp__x__y", "waiting_input" => nil)
      end

      it "puts a replaced request last" do
        request(agent_id: "sub-1")
        request(agent_id: "sub-2")
        request(tool: "Read", agent_id: "sub-1")

        expect(requests.keys).to eq(["sub-2", "sub-1"])
        expect(requests["sub-1"][:tool]).to eq("Read")
      end
    end

    describe "keying" do
      it "keys the wait to a sub-agent's only request, which that sub-agent's PostToolUse ends and main's leaves" do
        request(agent_id: "sub-1")
        prompt

        expect(waits.keys).to eq(["sub-1"])
        expect(pane("%2")).to include("waiting_tool" => "Bash", "waiting_input" => "rm -rf build")

        tool_done(tool: "Read")
        expect(pane("%2")["state"]).to eq("waiting")

        tool_done(agent_id: "sub-1")
        expect(pane("%2")["state"]).not_to eq("waiting")
        expect_null_fields
      end
    end

    describe "a dead request" do
      [
        ["a sub-agent's then main's", ["sub-1", nil]],
        ["main's then a sub-agent's", [nil, "sub-1"]]
      ].each do |name, order|
        it "gives a nil-keyed wait with null fields, with #{name}" do
          order.each { |agent_id| request(agent_id: agent_id) }
          prompt

          expect(waits.keys).to eq([nil])
          expect_null_fields

          tool_done(agent_id: "sub-1")
          expect(pane("%2")["state"]).to eq("waiting")

          tool_done
          expect(pane("%2")["state"]).not_to eq("waiting")
        end
      end

      it "is gone after a main user_prompt, so that turn's main request binds alone" do
        request(agent_id: "sub-1")
        event("user_prompt")
        request(tool: "Write", input: "a.rb")
        prompt

        expect(waits.keys).to eq([nil])
        expect(pane("%2")).to include("waiting_tool" => "Write", "waiting_input" => "a.rb")
      end
    end

    describe "two live requests" do
      it "binds the one left once the first of two sub-agents is answered" do
        request(tool: "Bash", agent_id: "sub-1")
        request(tool: "Write", input: "a.rb", agent_id: "sub-2")
        prompt
        expect_null_fields

        tool_done(agent_id: "sub-1")
        prompt

        expect(pane("%2")).to include("waiting_tool" => "Write", "waiting_input" => "a.rb")
      end

      it "binds the sub-agent's once main is answered" do
        request(tool: "Bash")
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        prompt
        expect_null_fields

        tool_done
        prompt

        expect(pane("%2")).to include("waiting_tool" => "Write", "waiting_input" => "a.rb")
      end

      it "binds main's once the sub-agent is answered" do
        request(tool: "Bash")
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        prompt
        expect_null_fields

        tool_done(tool: "Write", agent_id: "sub-1")
        prompt

        expect(pane("%2")).to include("waiting_tool" => "Bash", "waiting_input" => "rm -rf build")
      end
    end

    describe "a moved wait" do
      it "moves the unbound wait to the bound agent with its since and alert state, leaving one wait" do
        prompt
        monitor.send_alerts
        at(10)
        request(agent_id: "sub-1")
        prompt

        expect(waits.keys).to eq(["sub-1"])
        expect(pane("%2")).to include("waiting_since" => now.iso8601, "waiting_tool" => "Bash")
        expect(monitor.send_alerts).to eq([])
        expect(notifier).to have_received(:notify).once
      end
    end

    describe "an allowed tool still running" do
      it "leaves main's bound wait with its since and null fields when a sub-agent's Notification comes" do
        request(tool: "Bash")
        prompt
        at(10)
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        at(20)
        prompt

        expect(pane("%2")).to include("waiting_since" => now.iso8601)
        expect_null_fields
      end

      it "does the same with the sub-agent as the allowed one" do
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        prompt
        at(10)
        request(tool: "Bash")
        at(20)
        prompt

        expect(pane("%2")).to include("waiting_since" => now.iso8601)
        expect_null_fields
      end

      it "does the same with the wait unbound" do
        request(tool: "Bash")
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        prompt
        at(20)
        prompt

        expect(waits.keys).to eq([nil])
        expect(pane("%2")).to include("waiting_since" => now.iso8601)
        expect_null_fields
      end
    end

    describe "repeats" do
      it "keeps one wait, on the same agent, with its original since" do
        request(agent_id: "sub-1")
        prompt
        at(30)
        prompt

        expect(waits.keys).to eq(["sub-1"])
        expect(pane("%2")).to include("waiting_since" => now.iso8601, "waiting_tool" => "Bash")
      end

      it "updates the wait from a replaced request on the next Notification" do
        request(agent_id: "sub-1")
        prompt
        request(tool: "Write", input: "a.rb", agent_id: "sub-1")
        expect(pane("%2")).to include("waiting_tool" => "Bash")

        prompt

        expect(pane("%2")).to include("waiting_tool" => "Write", "waiting_input" => "a.rb")
      end
    end

    describe "clearing" do
      it "keeps a sub-agent's request across a main Stop before its Notification" do
        request(agent_id: "sub-1")
        event("stop")
        prompt

        expect(waits.keys).to eq(["sub-1"])
        expect(pane("%2")).to include("waiting_tool" => "Bash")
      end

      it "wipes the wait and the request on a main Stop after the Notification" do
        request(agent_id: "sub-1")
        prompt

        event("stop")

        expect(waits).to be_empty
        expect(requests).to be_empty
      end

      it "leaves the request on a tool_use of another name and clears it on one of the same" do
        request
        tool_done(tool: "Read")
        expect(requests.keys).to eq([nil])

        tool_done
        expect(requests).to be_empty
      end

      it "leaves the request on a tool_start" do
        request
        event("tool_start", tool: "Bash")

        expect(requests.keys).to eq([nil])
      end

      it "clears that sub-agent's request on its subagent_stop and no other's" do
        request
        request(agent_id: "sub-1")
        request(agent_id: "sub-2")

        event("subagent_stop", agent_id: "sub-1")
        event("subagent_stop")

        expect(requests.keys).to eq([nil, "sub-2"])
      end

      it "clears main's request on a main stop or turn_failed and keeps a sub-agent's" do
        %w[stop turn_failed].each do |name|
          request
          request(agent_id: "sub-1")

          event(name)

          expect(requests.keys).to eq(["sub-1"])
        end
      end

      %w[user_prompt session_start session_end].each do |name|
        it "clears every request on #{name}" do
          request
          request(agent_id: "sub-1")

          event(name)

          expect(requests).to be_empty
        end
      end

      it "clears every request when the agent leaves the pane" do
        request
        request(agent_id: "sub-1")
        allow(snapshot).to receive(:find_descendant).and_return(nil)

        monitor.scan

        expect(requests).to be_empty
      end
    end

    describe "no effect" do
      it "opens no wait and changes no state for a request with no Notification" do
        before = pane("%2")
        request

        expect(waits).to be_empty
        expect(pane("%2")).to include(before.slice("state", "state_since", "waiting_since", "waiting_tool", "stop_reason"))
      end

      it "leaves a finished turn done" do
        event("stop")
        request(agent_id: "sub-1")

        expect(pane("%2")["state"]).to eq("done")
      end

      it "never ends an open wait" do
        prompt
        request
        request(agent_id: "sub-1")

        expect(waits.keys).to eq([nil])
        expect(pane("%2")["state"]).to eq("waiting")
      end

      it "takes no request for an idle or elicitation notification" do
        %w[idle_prompt elicitation_dialog].each do |type|
          request
          prompt(type)

          expect(pane("%2")["state"]).to eq("waiting")
          expect_null_fields
          event("user_prompt")
        end
      end

      it "leaves a bound wait's fields alone on any other notification type" do
        request
        prompt
        prompt("elicitation_dialog")

        expect(pane("%2")).to include("waiting_tool" => "Bash")
      end

      it "never moves an elicitation wait a permission Notification met while none could bind" do
        prompt("elicitation_dialog")
        request(agent_id: "sub-1")
        request(agent_id: "sub-2")
        prompt
        tool_done(agent_id: "sub-2")
        prompt
        tool_done(agent_id: "sub-1")

        expect(waits.keys).to eq([nil])
        expect(pane("%2")["state"]).to eq("waiting")
      end

      it "never moves a wait an elicitation took over" do
        request(agent_id: "sub-1")
        request(agent_id: "sub-2")
        prompt
        prompt("elicitation_dialog")
        tool_done(agent_id: "sub-2")
        prompt
        tool_done(agent_id: "sub-1")

        expect(waits.keys).to eq([nil])
      end

      it "leaves a main elicitation under the main agent when a sub-agent's dialog binds" do
        prompt("elicitation_dialog")
        since = waits[nil][:since]
        allow(clock).to receive(:now).and_return(now + 5)
        request(agent_id: "sub-1")
        prompt

        expect(waits.keys).to contain_exactly(nil, "sub-1")
        expect(waits[nil][:since]).to eq(since)
        expect_null_fields

        tool_done(agent_id: "sub-1")
        expect(waits.keys).to eq([nil])
        expect(pane("%2")["state"]).to eq("waiting")
      end
    end

    it "reports null for both fields on every pane with no wait, shell panes included" do
      expect(pane("%1")).to include("waiting_tool" => nil, "waiting_input" => nil)
      expect(pane("%2")).to include("waiting_tool" => nil, "waiting_input" => nil)
    end

    describe "reporting the fields of a wait" do
      before do
        request
        prompt
      end

      it "sets both during the wait" do
        expect(pane("%2")).to include("waiting_tool" => "Bash", "waiting_input" => "rm -rf build")
      end

      {
        "PostToolUse" => ["tool_use", {tool: "Bash"}],
        "Stop" => ["stop", {}],
        "a user prompt" => ["user_prompt", {}]
      }.each do |name, (type, fields)|
        it "nulls both after #{name}" do
          event(type, **fields)

          expect_null_fields
        end
      end

      it "doesn't report a stale request from an earlier call on a later wait" do
        tool_done
        prompt

        expect_null_fields
      end

      it "keeps the main wait's fields when a sub-agent's request arrives" do
        request(tool: "Write", input: "notes.txt", agent_id: "sub-1")

        expect(pane("%2")).to include("waiting_tool" => "Bash", "waiting_input" => "rm -rf build")
      end
    end

    describe "a ready prompt back on the screen" do
      let(:rule) { "─" * 40 }
      let(:footer) { "#{rule}\n❯ \n#{rule}\n  Opus test status line one\n  line two 50% left\n  ⏸ manual mode on\n" }
      let(:ready) { "⏺ Bash(touch a.txt)\n  ⎿  Interrupted · What should Claude do instead?\n\n#{footer}" }
      let(:dialog) do
        "⏺ Bash(touch a.txt)\n  ⎿  Waiting…\n\n#{rule}\n Bash command\n Create empty file a.txt\n" \
          "#{"╌" * 40}\n touch a.txt\n#{"╌" * 40}\n Do you want to proceed?\n ❯ 1. Yes\n" \
          "   2. Yes, and don’t ask again for: touch *\n   3. No\n\n Esc to cancel · Tab to amend\n"
      end

      def alerted_waits
        monitor.instance_variable_get(:@panes)["%2"][:alerted_waits]
      end

      def wait_on_bound_tool
        request
        prompt
        monitor.instance_variable_get(:@panes)["%2"][:alerted_waits] = {nil => now}
      end

      def scan_showing(screen)
        allow(tmux).to receive(:capture_pane).and_return(screen)
        monitor.scan
      end

      it "keeps a newer request from the same agent, whose dialog is yet to be drawn" do
        wait_on_bound_tool
        request(tool: "Write", input: "notes.txt")

        scan_showing(ready)

        expect(waits).to be_empty
        expect(requests[nil]).to eq(tool: "Write", input: "notes.txt")
      end

      it "reads a capture with invalid UTF-8 bytes" do
        wait_on_bound_tool

        scan_showing("\xFF\n#{ready}")

        expect(waits).to be_empty
      end

      it "ends a bound wait, its alert entry and its request" do
        wait_on_bound_tool

        scan_showing(ready)

        expect(waits).to be_empty
        expect(alerted_waits).to be_empty
        expect(requests).to be_empty
        expect(pane("%2")["state"]).not_to eq("waiting")
        expect_null_fields
      end

      it "ends the wait when blank rows sit below the footer" do
        wait_on_bound_tool

        scan_showing(ready + ("\n" * 30))

        expect(waits).to be_empty
      end

      it "keeps the wait while the dialog is shown" do
        wait_on_bound_tool

        scan_showing(dialog)

        expect(waits.keys).to eq([nil])
        expect(alerted_waits).to eq({nil => now})
        expect(requests.keys).to eq([nil])
      end

      it "keeps the wait while the cursor sits on an AskUserQuestion menu's last row" do
        wait_on_bound_tool

        scan_showing("  3. Blue\n     Blue\n  4. Type something.\n#{rule}\n❯ 5. Chat about this\n\nEnter to select · Esc to cancel\n")

        expect(waits.keys).to eq([nil])
        expect(requests.keys).to eq([nil])
      end

      it "keeps the wait for a dialog below an old ready prompt in scrollback" do
        wait_on_bound_tool

        scan_showing(ready + ("older output\n" * 3) + dialog + ("\n" * 20))

        expect(waits.keys).to eq([nil])
        expect(requests.keys).to eq([nil])
      end

      it "keeps the wait when the capture is empty or blank" do
        wait_on_bound_tool

        scan_showing("")
        scan_showing("\n\n  \n")

        expect(waits.keys).to eq([nil])
        expect(requests.keys).to eq([nil])
      end

      it "keeps a wait with no bound tool" do
        request(agent_id: "sub-1")
        request(tool: "Write", input: "a.rb", agent_id: "sub-2")
        prompt
        expect(waits.values.map { |wait| wait[:tool] }).to eq([nil])

        scan_showing(ready)

        expect(waits.size).to eq(1)
        expect(requests.keys).to eq(["sub-1", "sub-2"])
      end
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

  describe "#rescan_pane" do
    it "re-reads one pane so a stale shell reading becomes the agent that has started since" do
      stale = [{id: "%2", index: 1, pid: 200, command: "zsh", cwd: "/project", title: "Claude"}]
      allow(tmux).to receive(:pane_details).and_return(stale)
      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], anything).and_return(nil)
      monitor.scan
      expect(monitor.pane_kind("%2")).to eq("shell")

      allow(snapshot).to receive(:find_descendant)
        .with(200, ["claude"], hash_including(include_root: true))
        .and_return({pid: 250, command: "claude", args: "claude"})
      monitor.rescan_pane("%2")

      expect(monitor.pane_kind("%2")).to eq("claude")
      expect(monitor.agent_pid("%2")).to eq(250)
    end

    it "leaves the cache alone when the process table can't be read, and ignores a pane tmux doesn't list" do
      monitor.scan
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps failed")
      monitor.rescan_pane("%2")
      expect(monitor.pane_kind("%2")).to eq("claude")

      allow(process_tree).to receive(:snapshot).and_return(snapshot)
      expect { monitor.rescan_pane("%9") }.not_to raise_error
      expect(monitor.pane_kind("%9")).to be_nil
    end
  end

  describe "Codex screens that wait on a person" do
    let(:panes) { [{id: "%3", index: 0, pid: 300, command: "node", cwd: "/project", title: "Codex"}] }
    let(:fixtures) { File.expand_path("../fixtures/codex_screens", __dir__) }

    def screen(name) = File.read(File.join(fixtures, "#{name}.txt"))

    def codex_pane = monitor.snapshot["panes"].first

    before do
      allow(snapshot).to receive(:find_descendant)
        .with(300, ["codex"], hash_including(include_root: true))
        .and_return({pid: 350, command: "codex", args: "codex"})
    end

    %w[approval_command approval_patch trust_folder trust_restricted sign_in sign_in_browser sign_in_api_key].each do |name|
      it "reports #{name} as waiting, with a message, though no hook fired" do
        allow(tmux).to receive(:capture_pane).and_return(screen(name))

        monitor.scan

        expect(codex_pane).to include("kind" => "codex", "state" => "waiting", "waiting_since" => now.iso8601)
        expect(codex_pane["waiting_message"]).to start_with("Codex is asking you to")
      end
    end

    it "does not report ordinary output that quotes the screens' text" do
      allow(tmux).to receive(:capture_pane).and_return(screen("ordinary_output"))

      monitor.scan

      expect(codex_pane["state"]).not_to eq("waiting")
    end

    it "ignores a prompt that scrolled out of the last lines" do
      allow(tmux).to receive(:capture_pane).and_return(screen("approval_command") + ("output\n" * 60))

      monitor.scan

      expect(codex_pane["state"]).not_to eq("waiting")
    end

    it "stops waiting once the screen changes" do
      allow(tmux).to receive(:capture_pane).and_return(screen("trust_folder"))
      monitor.scan
      allow(tmux).to receive(:capture_pane).and_return("working on it\n")

      monitor.scan

      expect(codex_pane).to include("state" => "working", "waiting_since" => nil)
    end

    it "keeps the first start time while the same screen stays" do
      allow(tmux).to receive(:capture_pane).and_return(screen("sign_in"))
      monitor.scan
      allow(clock).to receive(:now).and_return(now + 60)
      monitor.scan

      expect(codex_pane).to include("state" => "waiting", "waiting_since" => now.iso8601)
    end

    it "keeps one wait, the hook's, when both the hook and the screen report the prompt" do
      allow(tmux).to receive(:capture_pane).and_return(screen("approval_command"))
      monitor.scan
      monitor.record("event" => "notification", "pane_id" => "%3", "message" => "Approval requested")
      allow(tmux).to receive(:capture_pane).and_return(screen("approval_command") + "\n")
      monitor.scan
      allow(tmux).to receive(:capture_pane).and_return("approved\n")
      monitor.scan

      expect(codex_pane).to include("state" => "waiting", "waiting_message" => "Approval requested")
    end

    it "does not match a quoted browser or API key heading alone" do
      allow(tmux).to receive(:capture_pane).and_return("  Finish signing in via your browser\n  Paste or type your API key\n")

      monitor.scan

      expect(codex_pane["state"]).not_to eq("waiting")
    end

    it "does not look for these screens in a Claude Code pane" do
      claude = {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
      allow(tmux).to receive(:pane_details).and_return([claude])
      allow(tmux).to receive(:capture_pane).and_return(screen("approval_command"))

      monitor.scan

      expect(monitor.snapshot["panes"].first["state"]).not_to eq("waiting")
    end
  end

  describe "#background_subagents" do
    def event(name, extra = {})
      monitor.record({"event" => name, "pane_id" => "%2", "session_id" => "s1"}.merge(extra))
    end

    before { monitor.scan }

    it "counts a sub-agent through the main agent\x27s Stop, until its own stop" do
      event("subagent_start", "subagent_id" => "a1", "agent" => {"name" => "x"})
      event("stop")

      expect(monitor.running_subagents("%2")).to eq(0)
      expect(monitor.background_subagents("%2")).to eq(1)

      event("subagent_stop", "agent_id" => "a1")

      expect(monitor.background_subagents("%2")).to eq(0)
    end

    it "closes only the sub-agent named by the stop" do
      event("subagent_start", "subagent_id" => "a1")
      event("subagent_start", "subagent_id" => "a2")
      event("subagent_stop", "agent_id" => "a2")

      expect(monitor.background_subagents("%2")).to eq(1)
      event("subagent_stop", "agent_id" => "a1")
      expect(monitor.background_subagents("%2")).to eq(0)
    end

    it "closes one when the stop names no sub-agent" do
      event("subagent_start")
      event("subagent_start")
      event("subagent_stop")

      expect(monitor.background_subagents("%2")).to eq(1)
    end

    it "counts a sub-agent started by the main agent's PreToolUse until its stop names it" do
      event("subagent_start")
      expect(monitor.background_subagents("%2")).to eq(1)

      event("stop")
      expect(monitor.background_subagents("%2")).to eq(1)

      event("subagent_stop", "agent_id" => "a1")
      expect(monitor.background_subagents("%2")).to eq(0)
    end

    it "is cleared by session_start and by session_end" do
      event("subagent_start")
      event("session_start", "source" => "clear")
      expect(monitor.background_subagents("%2")).to eq(0)

      event("subagent_start")
      event("session_end")
      expect(monitor.background_subagents("%2")).to eq(0)
    end

    it "answers nil for a pane not scanned" do
      expect(monitor.background_subagents("%9")).to be_nil
    end
  end

  describe "#agent_pid" do
    it "returns the pid of the coding agent in a pane, and nil for a shell or unscanned pane" do
      monitor.scan

      expect(monitor.agent_pid("%2")).to eq(250)
      expect(monitor.agent_pid("%1")).to be_nil
      expect(monitor.agent_pid("%9")).to be_nil
    end
  end

  describe "a failed turn (turn_failed)" do
    def event(name, extra = {})
      monitor.record({"event" => name, "pane_id" => "%2", "session_id" => "s1"}.merge(extra))
    end

    before { monitor.scan }

    it "ends the turn: a late idle notification opens no wait, and the pane reads idle past a minute" do
      event("user_prompt")
      event("turn_failed")
      event("notification", "notification_type" => "idle_prompt", "message" => "Claude is waiting for your input")
      allow(clock).to receive(:now).and_return(now + 90)

      expect(pane("%2")).to include("state" => "idle", "waiting_message" => nil, "turn_failed" => true)
      expect(monitor.restart_state("%2")).to eq("idle")
    end

    it "leaves :done unset and a running sub-agent running" do
      event("subagent_start", "agent" => {"name" => "x"})
      event("turn_failed")

      expect(monitor.running_subagents("%2")).to eq(1)
      expect(pane("%2")["state"]).not_to eq("done")
      expect(pane("%2")["stop_reason"]).to be_nil
    end

    it "counts running sub-agents, and answers nil for a pane not scanned" do
      expect(monitor.running_subagents("%2")).to eq(0)
      expect(monitor.running_subagents("%9")).to be_nil
    end

    it "is false until a turn fails" do
      event("user_prompt")

      expect(pane("%2")["turn_failed"]).to be false
    end

    it "survives session_end, a same-id session_start and a rescan with no agent" do
      event("turn_failed")
      event("session_end")
      event("session_start", "source" => "resume")
      expect(pane("%2")["turn_failed"]).to be true

      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], anything).and_return(nil)
      monitor.scan
      expect(pane("%2")["turn_failed"]).to be true
    end

    it "clears on user_prompt, stop and a session_start with another session id" do
      [["user_prompt", {}], ["stop", {}], ["session_start", {"session_id" => "s2"}]].each do |name, extra|
        event("turn_failed")
        expect(pane("%2")["turn_failed"]).to be true
        event(name, extra)
        expect(pane("%2")["turn_failed"]).to be(false), "#{name} should clear it"
      end
    end

    it "#mark_turn_failed sets it and ends the turn, and ignores an unknown pane" do
      event("user_prompt")
      monitor.mark_turn_failed("%2")
      monitor.mark_turn_failed("%9")

      expect(pane("%2")["turn_failed"]).to be true
      expect(monitor.restart_state("%2")).to eq("idle")
      expect(monitor.pane_state("%9")).to be_nil
    end
  end

  describe "#restart_state" do
    def event(name)
      monitor.record("pane_id" => "%2", "event" => name)
    end

    before { monitor.scan }

    it "returns nil for a pane it hasn't scanned" do
      expect(monitor.restart_state("%9")).to be_nil
    end

    it "follows pane_state when no turn event has been seen" do
      expect(monitor.restart_state("%2")).to eq("working")
    end

    it "follows pane_state while a turn is in progress" do
      event("stop")
      event("user_prompt")

      expect(monitor.restart_state("%2")).to eq("working")
    end

    it "is idle once the turn ended, while pane_state still says working" do
      event("user_prompt")
      event("stop")

      expect(monitor.pane_state("%2")).to eq("working")
      expect(monitor.restart_state("%2")).to eq("idle")
    end

    it "treats session_start and session_end as ending a turn" do
      event("user_prompt")
      event("session_end")
      expect(monitor.restart_state("%2")).to eq("idle")

      event("user_prompt")
      event("session_start")
      expect(monitor.restart_state("%2")).to eq("idle")
    end

    it "is waiting when the pane has a wait, even after a stop" do
      event("stop")
      monitor.record("pane_id" => "%2", "event" => "notification", "message" => "Allow?")

      expect(monitor.restart_state("%2")).to eq("waiting")
    end
  end

  describe "#typing_facts" do
    before { monitor.scan }

    it "returns nil for a pane it hasn't scanned" do
      expect(monitor.typing_facts("%9")).to be_nil
    end

    it "gives the pane's kind, its restart state and the main agent's running tools" do
      monitor.record("pane_id" => "%2", "event" => "user_prompt")
      monitor.record("pane_id" => "%2", "event" => "tool_start", "tool" => "AskUserQuestion", "tool_use_id" => "t1")
      monitor.record("pane_id" => "%2", "event" => "tool_start", "tool" => "Read", "tool_use_id" => "t2", "agent_id" => "sub-1")

      expect(monitor.typing_facts("%2")).to eq(kind: "claude", state: "working", open_tools: ["AskUserQuestion"])
    end

    it "says waiting while a notification is open" do
      monitor.record("pane_id" => "%2", "event" => "notification", "message" => "Allow?")

      expect(monitor.typing_facts("%2")).to include(state: "waiting")
    end
  end

  describe "#fresh_since and #delivery_facts" do
    before { monitor.scan }

    def at(seconds)
      allow(clock).to receive(:now).and_return(now + seconds)
    end

    it "is nil while the pane works, for a shell and for a pane it hasn't scanned" do
      expect(monitor.fresh_since("%2")).to be_nil
      expect(monitor.fresh_since("%1")).to be_nil
      expect(monitor.fresh_since("%9")).to be_nil
      expect(monitor.delivery_facts("%9")).to be_nil
    end

    it "is the time of the Stop for a done pane" do
      at(5)
      monitor.record("pane_id" => "%2", "event" => "stop")

      expect(monitor.fresh_since("%2")).to eq(now + 5)
    end

    it "stays the time of the Stop when a sub-agent uses a tool afterward" do
      at(5)
      monitor.record("pane_id" => "%2", "event" => "stop")
      at(9)
      monitor.record("pane_id" => "%2", "event" => "tool_use", "agent_id" => "sub-1")

      expect(monitor.fresh_since("%2")).to eq(now + 5)
    end

    it "is when the screen went quiet long enough for an idle pane" do
      at(31)
      monitor.scan

      expect(monitor.fresh_since("%2")).to eq(now + 30)
    end

    it "is nil while a wait is open, even after a Stop" do
      monitor.record("pane_id" => "%2", "event" => "stop")
      monitor.record("pane_id" => "%2", "event" => "notification", "message" => "Allow?")

      expect(monitor.fresh_since("%2")).to be_nil
    end

    it "gives what a delivery checks the pane against" do
      at(5)
      monitor.record("pane_id" => "%2", "event" => "user_prompt", "session_id" => "s1")
      at(9)
      monitor.record("pane_id" => "%2", "event" => "stop", "session_id" => "s1")

      expect(monitor.delivery_facts("%2")).to eq(kind: "claude", pane_pid: 200, agent_pid: 250, session_id: "s1",
        state: "done", fresh_since: now + 9, last_user_prompt_at: now + 5, hooks: true, last_session_start: nil)
    end

    it "says hooks: false for an agent pane no hook has reached" do
      expect(monitor.delivery_facts("%2")).to include(hooks: false, last_session_start: nil)
    end

    it "keeps the last SessionStart's time, source and session id" do
      at(3)
      monitor.record("pane_id" => "%2", "event" => "session_start", "session_id" => "s1", "source" => "startup")
      at(8)
      monitor.record("pane_id" => "%2", "event" => "session_start", "session_id" => "s2", "source" => "clear")
      monitor.record("pane_id" => "%2", "event" => "stop", "session_id" => "s2")

      expect(monitor.delivery_facts("%2")[:last_session_start]).to eq(at: now + 8, source: "clear", session_id: "s2")
    end
  end

  describe "#followup_facts" do
    before { monitor.scan }

    it "is nil for a pane that hasn't been scanned" do
      expect(monitor.followup_facts("%9")).to be_nil
    end

    it "gives identity, activity, open tool and running sub-agent counts" do
      monitor.record("pane_id" => "%2", "event" => "user_prompt", "session_id" => "s1")

      facts = monitor.followup_facts("%2")

      expect(facts).to include(kind: "claude", pane_pid: 200, agent_pid: 250, session_id: "s1", hooks: true,
        open_tools: 0, agents_running: 0)
      expect(facts).to have_key(:last_activity_at)
      expect(facts).not_to have_key(:last_user_prompt_at)
    end

    it "counts open tools" do
      monitor.record("pane_id" => "%2", "event" => "tool_start", "tool" => "Bash", "tool_use_id" => "t1")
      monitor.record("pane_id" => "%2", "event" => "tool_start", "tool" => "Read", "tool_use_id" => "t2")

      expect(monitor.followup_facts("%2")[:open_tools]).to eq(2)
    end

    it "counts running sub-agents, and not one a Stop closed" do
      monitor.record("pane_id" => "%2", "event" => "subagent_start", "agent" => {"name" => "a"})
      monitor.record("pane_id" => "%2", "event" => "subagent_start", "agent" => {"name" => "b"})
      expect(monitor.followup_facts("%2")[:agents_running]).to eq(2)

      monitor.record("pane_id" => "%2", "event" => "stop")

      expect(monitor.followup_facts("%2")[:agents_running]).to eq(0)
    end
  end

  describe "#alert_handoff_stalled" do
    let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

    subject(:monitor) do
      described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier)
    end

    before { monitor.scan }

    it "sends one alert with its own kind and text, and no event line" do
      expect(monitor.alert_handoff_stalled("%2", seconds: 600, followups: 3)).to be(true)

      expect(notifier).to have_received(:notify).once.with(include(
        "WORKSPACE_ALERT" => "handoff_stalled",
        "WORKSPACE_ALERT_PANE_ID" => "%2",
        "WORKSPACE_ALERT_SECONDS" => "600",
        "WORKSPACE_ALERT_TEXT" => "proj pane 0.1 (Claude Code) has not handed off after 3 follow-ups"
      ))
    end

    it "writes no agent_alert event and leaves the pane's alert state alone" do
      dir = Dir.mktmpdir
      log_config = Workspace::Config.new(workspace_dir: dir)
      allow(log_config).to receive(:event_log_file).and_return(File.join(dir, "events.jsonl"))
      event_log = Workspace::EventLog.new(config: log_config, error_output: StringIO.new, clock: clock)
      logging = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, clock: clock, notifier: notifier, event_log: event_log, project: "proj")
      logging.scan
      state = -> { logging.instance_variable_get(:@panes)["%2"].slice(:alerted_idle_since, :alerted_waits, :waits) }
      before_state = state.call

      logging.alert_handoff_stalled("%2", seconds: 600, followups: 3)

      expect(event_log.events.select { |e| e["type"] == "agent_alert" }).to be_empty
      expect(state.call).to eq(before_state)
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    it "returns false for a pane that hasn't been scanned" do
      expect(monitor.alert_handoff_stalled("%9", seconds: 1, followups: 1)).to be(false)
      expect(notifier).not_to have_received(:notify)
    end

    it "returns false with no notifier" do
      bare = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj", clock: clock)
      bare.scan

      expect(bare.alert_handoff_stalled("%2", seconds: 1, followups: 1)).to be(false)
    end

    it "returns false instead of raising when the notifier raises" do
      allow(notifier).to receive(:notify).and_raise(ThreadError, "no threads")

      expect(monitor.alert_handoff_stalled("%2", seconds: 1, followups: 1)).to be(false)
    end
  end

  describe "#on_scan" do
    it "is called after each scan, and what it raises doesn't end the scan thread" do
      calls = Queue.new
      quick = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj", poll_interval: 0.001, clock: clock)
      quick.on_scan = -> {
        calls << :scanned
        raise "boom"
      }

      thread = quick.start
      2.times { calls.pop }

      expect(thread).to be_alive
      quick.stop
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

    it "records done with its stop reason, and takes it up after a restart without logging it again" do
      first = logging_monitor
      first.scan
      allow(clock).to receive(:now).and_return(now + 5)
      first.record("event" => "stop", "pane_id" => "%2", "stop_reason" => "end_turn")
      first.scan

      expect(logged_states.map { |_, state, since| [state, since] }).to eq([
        ["working", "2026-09-26T12:00:00.000Z"], ["done", "2026-09-26T12:00:05.000Z"]
      ])
      expect(event_log.events.last["data"]).to include("stop_reason" => "end_turn")

      allow(clock).to receive(:now).and_return(now + 100)
      restarted = logging_monitor
      restarted.scan
      pane = restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }

      expect(pane).to include("state" => "done", "state_since" => "2026-09-26T12:00:05Z", "stop_reason" => "end_turn")
      expect(logged_states.size).to eq(2)
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

      it "does not alert again for a done pane's quiet stretch the last daemon alerted for" do
        at(95)
        done = alerting_monitor
        done.scan
        done.record("event" => "stop", "pane_id" => "%2")
        done.scan

        at(120)
        restarted = alerting_monitor
        restarted.scan
        at(300)
        restarted.scan

        expect(restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state"]).to eq("done")
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

      expect(context_reader).to have_received(:read).with(pane_id: "%2", agent_pid: 250, current_session_id: nil, kind: "claude")
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

    describe "fresh_since after a restart" do
      def restored_done
        first = logging_monitor
        first.scan
        first.record("pane_id" => "%2", "event" => "stop")
        first.scan
        allow(clock).to receive(:now).and_return(now + 100)
        logging_monitor.tap(&:scan)
      end

      it "opens no wait for an idle notification that reaches a restarted daemon for a pane read back as done" do
        restarted = restored_done
        restarted.record("event" => "notification", "pane_id" => "%2", "notification_type" => "idle_prompt",
          "message" => "Claude is waiting for your input")

        expect(restarted.restart_state("%2")).not_to eq("waiting")
      end

      it "doesn't trust a restored done until a Stop this daemon heard" do
        restarted = restored_done

        expect(restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state"]).to eq("done")
        expect(restarted.fresh_since("%2")).to be_nil

        allow(clock).to receive(:now).and_return(now + 105)
        restarted.record("pane_id" => "%2", "event" => "stop")
        expect(restarted.fresh_since("%2")).to eq(now + 105)
      end

      it "takes a restored done as fresh once two own scans idle_after apart saw the same screen" do
        restarted = restored_done
        allow(clock).to receive(:now).and_return(now + 120)
        restarted.scan
        expect(restarted.fresh_since("%2")).to be_nil

        allow(clock).to receive(:now).and_return(now + 130)
        restarted.scan
        expect(restarted.fresh_since("%2")).to eq(now + 130)
        allow(clock).to receive(:now).and_return(now + 140)
        restarted.scan
        expect(restarted.fresh_since("%2")).to eq(now + 130)
      end

      it "doesn't trust a restored idle until two own scans idle_after apart saw the same screen" do
        first = logging_monitor
        first.scan
        allow(clock).to receive(:now).and_return(now + 31)
        first.scan
        allow(clock).to receive(:now).and_return(now + 100)
        restarted = logging_monitor.tap(&:scan)

        expect(restarted.snapshot["panes"].find { |p| p["pane_id"] == "%2" }["state"]).to eq("idle")
        expect(restarted.fresh_since("%2")).to be_nil
        allow(clock).to receive(:now).and_return(now + 130)
        restarted.scan
        expect(restarted.fresh_since("%2")).to eq(now + 130)
      end

      it "starts counting again when the screen changes" do
        restarted = restored_done
        allow(clock).to receive(:now).and_return(now + 120)
        allow(tmux).to receive(:capture_pane).and_return("moved")
        restarted.scan
        allow(clock).to receive(:now).and_return(now + 140)
        restarted.scan

        expect(restarted.fresh_since("%2")).to be_nil
      end
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

    it "reads a Codex pane by its kind, so sessions reports its context_pct" do
      allow(snapshot).to receive(:find_descendant).with(200, ["codex"], hash_including(include_root: true))
        .and_return({pid: 260, command: "codex", args: "codex"})
      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], hash_including(include_root: true)).and_return(nil)
      allow(context_reader).to receive(:read).with(hash_including(pane_id: "%2", kind: "codex"))
        .and_return(pct: 28, error: nil, updated_at: "2026-09-27T00:00:00Z")

      monitor.scan

      expect(pane("%2")["kind"]).to eq("codex")
      expect(pane("%2")["context_pct"]).to eq(28)
    end

    it "stamps a coding-agent pane with context_pct/context_error/context_updated_at" do
      allow(context_reader).to receive(:read).with(pane_id: "%2", agent_pid: 250, current_session_id: nil, kind: "claude")
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

    describe "serving from the scan's cache" do
      before do
        allow(context_reader).to receive(:read).and_return(pct: 55, error: nil, updated_at: "2026-09-27T00:00:00Z")
      end

      it "reads once per scan however many snapshots ask, not once per request" do
        monitor.scan

        3.times { expect(pane("%2")["context_pct"]).to eq(55) }

        expect(context_reader).to have_received(:read).exactly(:once)
      end

      it "reads per request before the first scan has run" do
        monitor.record({"pane_id" => "%2", "event" => "user_prompt", "session_id" => "s-1"})

        2.times { pane("%2") }

        expect(context_reader).to have_received(:read).with(pane_id: "%2", agent_pid: nil, current_session_id: "s-1", kind: "unknown")
          .exactly(2).times
      end

      it "reads again once the scan is overdue past its freshness grace" do
        monitor.scan
        overdue = now + (Workspace::SessionMonitor::DEFAULT_POLL_INTERVAL * Workspace::SessionMonitor::CACHE_GRACE_INTERVALS) + 1
        allow(clock).to receive(:now).and_return(overdue)

        expect(pane("%2")["context_pct"]).to eq(55)

        expect(context_reader).to have_received(:read).exactly(2).times
      end

      it "reads again when the pane reports a different session, however fresh the cache" do
        monitor.scan
        monitor.record({"pane_id" => "%2", "event" => "session_start", "session_id" => "s-2"})

        expect(pane("%2")["context_pct"]).to eq(55)

        expect(context_reader).to have_received(:read).with(pane_id: "%2", agent_pid: 250, current_session_id: "s-2", kind: "claude")
      end
    end
  end

  describe "hook mode" do
    let(:all_events) { Workspace::AgentProvider::HOOK_EVENT_TYPES }

    def run_codex_in_pane
      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], hash_including(include_root: true)).and_return(nil)
      allow(snapshot).to receive(:find_descendant).with(200, ["codex"], hash_including(include_root: true))
        .and_return({pid: 260, command: "codex", args: "codex"})
    end

    it "is scrape for a recognized agent no hook event has reached, listing what its hooks can report" do
      monitor.scan

      expect(pane("%2")).to include("kind" => "claude", "hook_mode" => "scrape", "hook_events" => all_events)
    end

    it "is hooks once the pane's agent has sent an event; an event with no kind is Claude Code's" do
      monitor.scan
      monitor.record("event" => "session_start", "pane_id" => "%2")

      expect(pane("%2")["hook_mode"]).to eq("hooks")
    end

    it "is hooks for a Codex pane once a Codex event arrives, not on a Claude Code one" do
      run_codex_in_pane
      monitor.scan
      monitor.record("event" => "tool_start", "pane_id" => "%2", "agent_kind" => "claude")
      expect(pane("%2")).to include("kind" => "codex", "hook_mode" => "scrape")

      monitor.record("event" => "notification", "pane_id" => "%2", "agent_kind" => "codex", "message" => "Approval requested for Bash")

      expect(pane("%2")).to include("hook_mode" => "hooks", "hook_events" => all_events, "state" => "waiting",
        "waiting_message" => "Approval requested for Bash")
    end

    it "goes back to scrape when another kind of agent takes the pane over" do
      monitor.scan
      monitor.record("event" => "session_start", "pane_id" => "%2", "agent_kind" => "claude")
      run_codex_in_pane

      monitor.scan

      expect(pane("%2")).to include("kind" => "codex", "hook_mode" => "scrape")
    end

    it "lists no events for an agent with no hooks" do
      allow(snapshot).to receive(:find_descendant).with(200, ["claude"], hash_including(include_root: true)).and_return(nil)
      allow(snapshot).to receive(:find_descendant).with(200, ["opencode"], hash_including(include_root: true))
        .and_return({pid: 270, command: "opencode", args: "opencode"})
      monitor.scan

      expect(pane("%2")).to include("kind" => "opencode", "hook_mode" => "scrape", "hook_events" => [])
    end

    it "is none for a pane not identified yet, and absent on a shell pane" do
      monitor.record("event" => "stop", "pane_id" => "%9")

      expect(pane("%9")).to include("kind" => "unknown", "hook_mode" => "none", "hook_events" => [])
      monitor.scan
      expect(pane("%1")).not_to have_key("hook_mode")
      expect(pane("%1")).not_to have_key("hook_events")
    end
  end

  describe "per-pane tool status" do
    before { monitor.scan }

    def tool_start(id, tool = "Bash", extra = {})
      monitor.record({"event" => "tool_start", "pane_id" => "%2", "tool" => tool, "tool_use_id" => id}.merge(extra))
    end

    def tool_end(id, extra = {})
      monitor.record({"event" => "tool_use", "pane_id" => "%2", "tool" => "Bash", "tool_use_id" => id}.merge(extra))
    end

    it "reports nulls and no sub-agents for an agent pane no hook has reached" do
      expect(pane("%2")).to include("last_event_at" => nil, "current_tool" => nil,
        "current_tool_since" => nil, "subagents" => [])
    end

    it "leaves the fields off a shell pane" do
      expect(pane("%1").keys).not_to include("last_event_at", "current_tool", "current_tool_since", "subagents")
    end

    it "reports the running tool by name with when it started" do
      tool_start("t1")

      expect(pane("%2")).to include("current_tool" => "Bash", "current_tool_since" => now.iso8601,
        "last_event_at" => now.iso8601)
    end

    it "reports no tool between tools but keeps the heartbeat" do
      tool_start("t1")
      allow(clock).to receive(:now).and_return(now + 5)
      tool_end("t1")

      expect(pane("%2")).to include("current_tool" => nil, "current_tool_since" => nil,
        "last_event_at" => (now + 5).iso8601)
    end

    it "reports the latest of tools run side by side, then the earlier one once it ends" do
      tool_start("t1", "Read")
      allow(clock).to receive(:now).and_return(now + 2)
      tool_start("t2", "Grep")
      expect(pane("%2")["current_tool"]).to eq("Grep")

      tool_end("t2")
      expect(pane("%2")).to include("current_tool" => "Read", "current_tool_since" => now.iso8601)
    end

    it "ignores a sub-agent's tools" do
      tool_start("t1", "Bash", "agent_id" => "sub-1")

      expect(pane("%2")["current_tool"]).to be_nil
    end

    it "clears the tool when the turn ends or a prompt is submitted" do
      tool_start("t1")
      monitor.record("event" => "stop", "pane_id" => "%2")
      expect(pane("%2")["current_tool"]).to be_nil

      tool_start("t2")
      monitor.record("event" => "user_prompt", "pane_id" => "%2")
      expect(pane("%2")["current_tool"]).to be_nil
    end

    it "keeps no tool input: the name is all that is reported" do
      tool_start("t1", "Bash", "path" => "lib/a.rb", "command" => "rm -rf /")

      expect(pane("%2").to_s).not_to include("rm -rf")
    end

    describe "subagents" do
      def start_sub(id, description)
        monitor.record("event" => "subagent_start", "pane_id" => "%2", "tool" => "Task", "tool_use_id" => id,
          "description" => description, "agent" => {"name" => "general-purpose"})
      end

      it "lists running sub-agents with their description" do
        start_sub("task-1", "Review the diff")

        expect(pane("%2")["subagents"]).to eq([{"agent_id" => nil, "description" => "Review the diff", "since" => now.iso8601}])
        expect(pane("%2")["current_tool"]).to eq("Task")
      end

      it "takes a sub-agent the agent names itself (Codex) with its id and no tool to wait on, and closes that one on its stop" do
        monitor.record("event" => "subagent_start", "pane_id" => "%2", "subagent_id" => "sub-1", "agent" => {"name" => "explorer"})
        monitor.record("event" => "subagent_start", "pane_id" => "%2", "subagent_id" => "sub-2", "agent" => {"name" => "worker"})

        expect(pane("%2")["subagents"].map { |s| s["agent_id"] }).to eq(%w[sub-1 sub-2])
        expect(pane("%2")["current_tool"]).to be_nil

        monitor.record("event" => "subagent_stop", "pane_id" => "%2", "agent_id" => "sub-2")

        expect(pane("%2")["subagents"].map { |s| s["agent_id"] }).to eq(["sub-1"])
      end

      it "falls back to the sub-agent's name without a description" do
        monitor.record("event" => "subagent_start", "pane_id" => "%2", "agent" => {"name" => "x"})

        expect(pane("%2")["subagents"].first["description"]).to eq("x")
      end

      it "keeps a sub-agent running after its Task call returns, as a background Task does" do
        start_sub("task-1", "first")

        tool_end("task-1", "tool" => "Task")

        expect(pane("%2")["subagents"].map { |s| s["description"] }).to eq(["first"])
        expect(pane("%2")["current_tool"]).to be_nil
      end

      it "learns the agent id from its own tool when it is the only one unnamed" do
        start_sub("task-1", "first")
        tool_start("t9", "Read", "agent_id" => "sub-9")

        expect(pane("%2")["subagents"].first["agent_id"]).to eq("sub-9")
      end

      it "does not guess an agent id when two are unnamed" do
        start_sub("task-1", "first")
        start_sub("task-2", "second")
        tool_start("t9", "Read", "agent_id" => "sub-9")

        expect(pane("%2")["subagents"].map { |s| s["agent_id"] }).to eq([nil, nil])
      end

      it "closes the sub-agent a stop names" do
        start_sub("task-1", "first")
        tool_start("t9", "Read", "agent_id" => "sub-9")
        start_sub("task-2", "second")

        monitor.record("event" => "subagent_stop", "pane_id" => "%2", "agent_id" => "sub-9")

        expect(pane("%2")["subagents"].map { |s| s["description"] }).to eq(["second"])
      end

      it "reports none once the turn ends" do
        start_sub("task-1", "first")
        monitor.record("event" => "stop", "pane_id" => "%2")

        expect(pane("%2")["subagents"]).to eq([])
      end
    end
  end
end

RSpec.describe Workspace::SessionMonitor, "display_label" do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:clock) { class_double(Time, now: Time.utc(2026, 9, 26, 12, 0, 0)) }
  let(:label_reader) { instance_double(Workspace::TranscriptLabel) }
  let(:panes) do
    [
      {id: "%1", index: 0, pid: 100, command: "zsh", cwd: "/project", title: "shell"},
      {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
    ]
  end

  subject(:monitor) do
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
      idle_after: 30, clock: clock, label_reader: label_reader)
  end

  before do
    allow(tmux).to receive(:pane_details).and_return(panes)
    allow(process_tree).to receive(:snapshot).and_return(snapshot)
    allow(snapshot).to receive(:find_descendant).and_return(nil)
    allow(snapshot).to receive(:find_descendant)
      .with(200, ["claude"], hash_including(include_root: true))
      .and_return({pid: 250, command: "claude", args: "claude"})
    allow(tmux).to receive(:capture_pane).and_return("output")
    allow(label_reader).to receive(:read).and_return(title: nil, last_prompt: nil)
    monitor.scan
  end

  def pane(id) = monitor.snapshot["panes"].find { |p| p["pane_id"] == id }

  it "is null before the pane has reported anything, and the existing label is unchanged" do
    expect(pane("%2")["display_label"]).to be_nil
    expect(pane("%2")["label"]).to eq("Claude Code")
  end

  it "prefers the transcript's ai-title" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: "Fix the build", last_prompt: "hello")
    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1",
      "transcript_path" => "/t/a.jsonl", "prompt" => "typed")

    expect(pane("%2")["display_label"]).to eq("Fix the build")
  end

  it "falls back to the last prompt seen in memory, cleaned and cut to 80 characters" do
    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1",
      "prompt" => "line one\nline two " + "x" * 200)

    expect(pane("%2")["display_label"]).to eq(("line one line two " + "x" * 200)[0, 80])
  end

  it "falls back to the transcript's last-prompt when no prompt was seen" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: nil, last_prompt: "from file")
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl")

    expect(pane("%2")["display_label"]).to eq("from file")
  end

  it "forgets the old session's path and prompt when the session id changes" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: "Old", last_prompt: nil)
    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1",
      "transcript_path" => "/t/a.jsonl", "prompt" => "old prompt")
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s2")

    expect(pane("%2")["display_label"]).to be_nil
  end

  it "keeps the label source when a later event carries no session id" do
    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1", "prompt" => "keep me")
    monitor.record("event" => "notification", "pane_id" => "%2", "message" => "hello")

    expect(pane("%2")["display_label"]).to eq("keep me")
  end

  it "reads the transcript once per scan however many snapshots ask, not once per request" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: "Fix the build", last_prompt: nil)
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl")
    monitor.scan

    3.times { expect(pane("%2")["display_label"]).to eq("Fix the build") }

    expect(label_reader).to have_received(:read).with("/t/a.jsonl").exactly(:once)
  end

  it "reads the transcript again when the pane reports a new prompt, however fresh the cache" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: "Fix the build", last_prompt: nil)
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl")
    monitor.scan
    expect(pane("%2")["display_label"]).to eq("Fix the build")

    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1",
      "transcript_path" => "/t/a.jsonl", "prompt" => "typed")

    expect(pane("%2")["display_label"]).to eq("Fix the build")
    expect(label_reader).to have_received(:read).with("/t/a.jsonl").twice
  end

  it "reads the transcript again once the scan is overdue past its freshness grace" do
    allow(label_reader).to receive(:read).with("/t/a.jsonl").and_return(title: "Fix the build", last_prompt: nil)
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl")
    monitor.scan

    allow(clock).to receive(:now).and_return(Time.utc(2026, 9, 26, 12, 0, 31))
    expect(pane("%2")["display_label"]).to eq("Fix the build")
    allow(clock).to receive(:now).and_return(Time.utc(2026, 9, 26, 12, 1, 1))
    expect(pane("%2")["display_label"]).to eq("Fix the build")

    expect(label_reader).to have_received(:read).with("/t/a.jsonl").twice
  end

  it "never lets a label_reader failure raise out of a scan" do
    monitor.record("event" => "session_start", "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl")
    monitor.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1", "prompt" => "keep me")
    allow(label_reader).to receive(:read).and_raise(StandardError, "boom")

    expect { monitor.scan }.not_to raise_error
    expect(pane("%2")["display_label"]).to eq("keep me")
  end

  it "is null on a shell pane" do
    monitor.record("event" => "user_prompt", "pane_id" => "%1", "session_id" => "s1", "prompt" => "hi")

    expect(pane("%1")["display_label"]).to be_nil
  end

  it "never writes the prompt to the event log" do
    log = instance_double(Workspace::EventLog)
    written = []
    allow(log).to receive(:record) { |**args| written << args }
    allow(log).to receive_messages(latest_agent_alerts: {}, latest_agent_states: {})
    logged = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
      idle_after: 30, clock: clock, event_log: log, project: "proj", label_reader: label_reader)
    logged.scan
    logged.record("event" => "user_prompt", "pane_id" => "%2", "session_id" => "s1", "prompt" => "secret text")
    logged.scan

    expect(written).not_to be_empty
    expect(written.to_s).not_to include("secret text")
  end
end

RSpec.describe Workspace::SessionMonitor, "task" do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:clock) { class_double(Time, now: Time.utc(2026, 9, 26, 12, 0, 0)) }
  let(:label_reader) { instance_double(Workspace::TranscriptLabel) }
  let(:task) { {"id" => "ab12cd34", "workspace" => "proj", "title" => "Fix login", "ref" => "PROJ-1", "branch" => "PROJ-1"} }
  let(:task_reader) { ->(_workspace) { task } }
  let(:panes) do
    [
      {id: "%1", index: 0, pid: 100, command: "zsh", cwd: "/project", title: "shell"},
      {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
    ]
  end

  subject(:monitor) do
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session", project: "proj",
      idle_after: 30, clock: clock, label_reader: label_reader, task_reader: task_reader)
  end

  before do
    allow(tmux).to receive(:pane_details).and_return(panes)
    allow(process_tree).to receive(:snapshot).and_return(snapshot)
    allow(snapshot).to receive(:find_descendant).and_return(nil)
    allow(snapshot).to receive(:find_descendant)
      .with(200, ["claude"], hash_including(include_root: true))
      .and_return({pid: 250, command: "claude", args: "claude"})
    allow(tmux).to receive(:capture_pane).and_return("output")
    allow(label_reader).to receive(:read).and_return(title: "Transcript title", last_prompt: nil)
    monitor.scan
  end

  def pane(id) = monitor.snapshot["panes"].find { |p| p["pane_id"] == id }

  def record(event, **fields) = monitor.record({"event" => event, "pane_id" => "%2", "session_id" => "s1", "transcript_path" => "/t/a.jsonl"}.merge(fields.transform_keys(&:to_s)))

  it "reports the task and puts its title first in display_label, ahead of the transcript title" do
    record("user_prompt", prompt: "typed")

    expect(pane("%2")["display_label"]).to eq("Fix login")
    expect(monitor.snapshot["task"]).to include("id" => "ab12cd34", "title" => "Fix login", "ref" => "PROJ-1", "branch" => "PROJ-1")
  end

  it "leaves a shell pane's display_label null" do
    expect(pane("%1")["display_label"]).to be_nil
  end

  it "reads the task by the project name" do
    asked = []
    reader = ->(workspace) { asked << workspace and nil }
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj-session", project: "proj",
      clock: clock, task_reader: reader).snapshot

    expect(asked).to eq(["proj"])
  end

  context "when the task has no title" do
    let(:task) { {"id" => "ab12cd34", "workspace" => "proj", "title" => nil} }

    it "falls back to the transcript title" do
      record("user_prompt", prompt: "typed")

      expect(pane("%2")["display_label"]).to eq("Transcript title")
      expect(monitor.snapshot["task"]).to include("id" => "ab12cd34", "title" => nil)
    end
  end

  context "without a task" do
    let(:task) { nil }

    it "reports task null and keeps the transcript title" do
      record("user_prompt", prompt: "typed")

      expect(monitor.snapshot["task"]).to be_nil
      expect(pane("%2")["display_label"]).to eq("Transcript title")
    end
  end

  context "when the task reader raises" do
    let(:task_reader) { ->(_workspace) { raise Errno::EACCES, "tasks" } }

    it "reads as no task instead of failing the snapshot" do
      expect(monitor.snapshot["task"]).to be_nil
    end
  end

  describe "derived status" do
    def status = monitor.snapshot["task"]["status"]

    it "is idle when no agent has reported and the pane is quiet" do
      allow(clock).to receive(:now).and_return(Time.utc(2026, 9, 26, 12, 5, 0))
      monitor.scan

      expect(status).to eq("idle")
    end

    it "is working while an agent works" do
      record("user_prompt", prompt: "go")

      expect(status).to eq("working")
    end

    it "is done once the Stop hook fires" do
      record("stop")

      expect(status).to eq("done")
    end

    it "is blocked while an agent waits for permission" do
      record("user_prompt", prompt: "go")
      record("notification", message: "needs permission")

      expect(status).to eq("blocked")
    end
  end

  describe "with a detector that knows claude-dev" do
    let(:detector) { Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}) }
    let(:panes) { [{id: "%3", index: 0, pid: 300, command: "claude-dev", cwd: "/project", title: "x"}] }

    it "reports a pane running claude-dev as claude, and as a shell without it" do
      with = described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj", idle_after: 30, clock: clock, detector: detector)
      with.scan
      expect(with.snapshot["panes"].first).to include("kind" => "claude", "label" => "Claude Code")

      monitor.scan
      expect(pane("%3")).to include("kind" => "shell")
    end
  end
end
