RSpec.describe Workspace::PaneScanner do
  let(:tmux) { instance_double(Workspace::Tmux) }
  let(:process_tree) { instance_double(Workspace::ProcessTree) }
  let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:times) { [now] }
  let(:clock) { Struct.new(:source) { def now = source[0] }.new(times) }
  let(:claude) { Workspace::AgentProvider.find("claude") }
  let(:codex) { Workspace::AgentProvider.find("codex") }
  let(:agents) { {200 => {provider: claude, pid: 250}} }
  let(:detector) { ->(command:, pid:, tree:, providers:) { agents[pid] } }
  let(:event_log) { nil }
  let(:err) { StringIO.new }
  let(:logger) { Workspace::Logger.new(output: StringIO.new) }
  let(:detail) { {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"} }
  let(:pane) { Workspace::PaneEvents.new_pane("%2") }

  subject(:scanner) do
    described_class.new(tmux: tmux, process_tree: process_tree, session_name: "proj", providers: Workspace::AgentProvider.all,
      detector: detector, question_check: Workspace::QuestionClosedCheck.new, idle_after: 30, clock: clock,
      logger: logger, error_output: err, event_log: event_log, project: "proj")
  end

  before { allow(tmux).to receive(:capture_pane).with("proj", 1).and_return("output") }

  def refresh(at = now) = scanner.refresh(pane, detail, snapshot, at)

  def fixture(name)
    File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "claude_screens", "#{name}.txt"))
  end

  describe "#pane_details and #process_snapshot" do
    it "lists the session's panes and snapshots the process table" do
      allow(tmux).to receive(:pane_details).with("proj").and_return([detail])
      allow(process_tree).to receive(:snapshot).and_return(snapshot)

      expect(scanner.pane_details).to eq([detail])
      expect(scanner.process_snapshot).to be(snapshot)
    end

    it "lets a process table that can't be read raise" do
      allow(process_tree).to receive(:snapshot).and_raise(Workspace::Error, "ps hung")

      expect { scanner.process_snapshot }.to raise_error(Workspace::Error, "ps hung")
    end
  end

  describe "#refresh" do
    it "copies the pane's tmux fields and the agent found in it" do
      refresh

      expect(pane).to include(index: 1, title: "Claude", cwd: "/project", pid: 200, kind: "claude",
        label: claude.label, agent_pid: 250, last_activity_at: now)
    end

    it "makes a pane with no agent a shell, with no waits, requests or done mark left" do
      agents.clear
      pane.merge!(waits: {nil => {since: now}}, permission_requests: {nil => {tool: "Bash"}}, done: {since: now})

      refresh

      expect(pane).to include(kind: "shell", label: "node", agent_pid: nil, waits: {}, permission_requests: {})
      expect(pane).not_to have_key(:done)
    end

    it "dates activity from the screen's last change" do
      refresh
      refresh(now + 40)
      expect(pane[:last_activity_at]).to eq(now)

      allow(tmux).to receive(:capture_pane).with("proj", 1).and_return("more output")
      refresh(now + 50)
      expect(pane[:last_activity_at]).to eq(now + 50)
    end

    it "opens a wait for an agent's waiting screen, dated by the clock" do
      agents[200] = {provider: codex, pid: 350}
      allow(tmux).to receive(:capture_pane).with("proj", 1).and_return("  1. Sign in with ChatGPT\n")
      times[0] = now + 2

      refresh

      expect(pane[:waits]["screen"]).to eq(since: now + 2, message: "Codex is asking you to sign in")
    end

    it "ends a bound permission wait once the ready prompt is back on the screen" do
      rule = "─" * 40
      allow(tmux).to receive(:capture_pane).with("proj", 1).and_return("#{rule}\n❯ \n#{rule}\n")
      pane[:waits][nil] = {since: now, tool: "Bash", input: "ls"}

      refresh

      expect(pane[:waits]).to be_empty
    end

    it "reads the styled screen only with a question tool open" do
      expect(tmux).not_to receive(:capture_screen_styled)

      refresh
    end

    it "closes a question whose dialog the screen proves gone, and says so on the error stream" do
      allow(tmux).to receive(:capture_screen_styled).with("%2").and_return(fixture("question_closed_single"))
      pane[:open_tools] = {"t1" => {tool: "AskUserQuestion", since: now}}

      refresh
      expect(err.string).to be_empty
      refresh(now + Workspace::QuestionClosedCheck::HOLD)

      expect(pane[:open_tools]).to be_empty
      expect(err.string).to eq("workspace agent: question closed in %2 of proj: its dialog is gone from the screen\n")
    end

    it "reads a styled capture that raises as no screen" do
      allow(tmux).to receive(:capture_screen_styled).with("%2").and_raise(Workspace::Error, "no server")
      pane[:open_tools] = {"t1" => {tool: "AskUserQuestion", since: now}}

      refresh
      refresh(now + 60)

      expect(pane[:open_tools].keys).to eq(["t1"])
    end
  end

  describe "history read back from the event log" do
    let(:event_log) { instance_double(Workspace::EventLog) }
    let(:logged) { {"pane_pid" => 200, "state" => "idle", "since" => (now - 100).utc.iso8601(3)} }

    before do
      allow(event_log).to receive(:latest_agent_alerts).with("proj").and_return({})
      allow(event_log).to receive(:latest_agent_states).with("proj").and_return({"%2" => logged})
    end

    it "takes up the pane's logged state on its first refresh, and reads the log once" do
      scanner.load_history
      refresh

      expect(pane).to include(logged_state: "idle", state_since: now - 100, restored_ready: true, last_activity_at: now - 130)
      expect(event_log).to have_received(:latest_agent_states).once
    end

    it "takes up no state logged for another pane process" do
      logged["pane_pid"] = 999

      refresh

      expect(pane).not_to have_key(:logged_state)
      expect(pane[:last_activity_at]).to eq(now)
    end

    it "reads a log that raises as no history" do
      allow(event_log).to receive(:latest_agent_states).and_raise(IOError, "gone")

      refresh

      expect(pane).not_to have_key(:logged_state)
    end
  end

  # Moved from session_monitor_spec: the screen rules the scan applies, read
  # through the monitor's own answers.
  describe "seen through SessionMonitor" do
    let(:clock) { class_double(Time, now: now) }

    let(:panes) do
      [
        {id: "%1", index: 0, pid: 100, command: "zsh", cwd: "/project", title: "shell"},
        {id: "%2", index: 1, pid: 200, command: "node", cwd: "/project", title: "Claude"}
      ]
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
        Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
          idle_after: 30, clock: clock, error_output: err)
      end

      def fixture(name)
        File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "claude_screens", "#{name}.txt"))
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

      it "drops the main agent's unanswered permission request, as a Stop does" do
        monitor.record(ask.merge("event" => "permission_request", "tool" => "Bash", "input" => {"command" => "ls"}))
        show("question_closed_single")
        scans(2)

        expect(open_tools).to eq([])
        monitor.record(ask.merge("event" => "notification", "message" => "Claude needs your permission"))
        expect(pane("%2")).to include("waiting_tool" => nil, "waiting_input" => nil)
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

    describe "permission requests" do
      let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }

      subject(:monitor) do
        Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
          idle_after: 30, clock: clock, notifier: notifier)
      end

      before { monitor.scan }

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
        pane("%2")["waits"].to_h { |wait| [wait["agent_id"], wait] }
      end

      def expect_null_fields
        expect(pane("%2")).to include("waiting_tool" => nil, "waiting_input" => nil)
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

        let(:tmpdir) { Dir.mktmpdir }
        let(:event_log) do
          log_config = Workspace::Config.new(workspace_dir: tmpdir)
          allow(log_config).to receive(:event_log_file).and_return(File.join(tmpdir, "events.jsonl"))
          Workspace::EventLog.new(config: log_config, error_output: StringIO.new, clock: clock)
        end

        after { FileUtils.remove_entry(tmpdir) }

        def daemon
          Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
            idle_after: 30, clock: clock, notifier: notifier, event_log: event_log, project: "proj")
        end

        # A daemon that alerted for the main agent's wait, then a new one that takes the wait up.
        subject(:monitor) do
          predecessor = daemon
          predecessor.scan
          predecessor.record("event" => "notification", "pane_id" => "%2", "message" => "Claude needs your permission")
          predecessor.scan
          predecessor.send_alerts
          daemon
        end

        def wait_on_bound_tool
          request
          prompt
        end

        def expect_request_kept(tool)
          prompt
          expect(pane("%2")["waiting_tool"]).to eq(tool)
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
          expect_request_kept("Write")
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
          expect(pane("%2")["state"]).not_to eq("waiting")
          expect_null_fields
          prompt
          expect_null_fields
          expect(monitor.send_alerts.size).to eq(1)
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
          expect(monitor.send_alerts).to be_empty
          expect_request_kept("Bash")
        end

        it "keeps the wait while the cursor sits on an AskUserQuestion menu's last row" do
          wait_on_bound_tool

          scan_showing("  3. Blue\n     Blue\n  4. Type something.\n#{rule}\n❯ 5. Chat about this\n\nEnter to select · Esc to cancel\n")

          expect(waits.keys).to eq([nil])
          expect_request_kept("Bash")
        end

        it "keeps the wait for a dialog below an old ready prompt in scrollback" do
          wait_on_bound_tool

          scan_showing(ready + ("older output\n" * 3) + dialog + ("\n" * 20))

          expect(waits.keys).to eq([nil])
          expect_request_kept("Bash")
        end

        it "keeps the wait when the capture is empty or blank" do
          wait_on_bound_tool

          scan_showing("")
          scan_showing("\n\n  \n")

          expect(waits.keys).to eq([nil])
          expect_request_kept("Bash")
        end

        it "keeps a wait with no bound tool" do
          request(agent_id: "sub-1")
          request(tool: "Write", input: "a.rb", agent_id: "sub-2")
          prompt
          expect(waits.values.map { |wait| wait["tool"] }).to eq([nil])

          scan_showing(ready)

          expect(waits.size).to eq(1)
          tool_done(agent_id: "sub-1")
          expect_request_kept("Write")
        end
      end
    end
  end
end
