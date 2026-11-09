require "spec_helper"
require "tmpdir"

# The desks and the typer read and type through a Pane, and must make the tmux calls they made
# when they held Tmux itself: a pane list only where they looked a pane up, none to read a screen.
RSpec.describe "tmux calls of the pane desks" do
  let(:empty_prompt) { "────────\n❯ \n" }
  let(:row) { {id: "%5", window: 0, index: 1, pid: 100} }
  let(:tmux) { RecordingFakeTmux.new(screens: [empty_prompt], details: [row], server_pid: "77") }
  let(:factory) { Workspace::PaneFactory.new(tmux: tmux, session_name: "api") }
  let(:monitor) do
    double("monitor").tap do |m|
      allow(m).to receive(:typing_facts) { {kind: "claude", state: "idle", open_tools: []} }
    end
  end

  describe Workspace::PromptTyper do
    subject(:typer) { described_class.new(panes: factory, session_monitor: monitor) }

    it "reads one styled screen to check a pane" do
      typer.check("%5")

      expect(tmux.calls).to eq([:capture_screen_styled])
    end

    it "reads, pastes, reads and presses Enter, with no pane list" do
      tmux.screens = [empty_prompt, "────────\n❯ hi\n────────\n"]
      tmux.styled_screens = tmux.screens.dup

      typer.type(session_name: "api", target: "0.1", pane_id: "%5", text: "hi")

      expect(tmux.calls).to eq([:capture_screen_styled, :deliver, :capture_screen_styled, :deliver])
    end

    it "makes no call at all for an id that is not a pane id" do
      typer.check("five")

      expect(tmux.calls).to eq([])
    end
  end

  describe Workspace::AgentStatusDesk do
    let(:dir) { Dir.mktmpdir }
    let(:hook_log) { Workspace::HookEventLog.new(dir: dir, workspace: "api", boot_id: "BOOT") }
    subject(:desk) do
      described_class.new(panes: factory, session_name: "api", workspace: "api", session_monitor: monitor,
        hook_event_log: hook_log, delivery_lock: Mutex.new)
    end

    after { FileUtils.remove_entry(dir) }

    it "lists the panes once to open a request, reads the screen to check, and again under the lock" do
      tmux.screens = [empty_prompt, empty_prompt, empty_prompt, "────────\n❯ x\n"]
      desk.request("pane_id" => "%5")

      expect(tmux.calls.first(3)).to eq([:pane_details, :capture_screen_styled, :pane_details])
      expect(tmux.calls.count(:pane_details)).to eq(2)
    end

    it "lists the panes once to refuse a pane the session does not have" do
      desk.request("pane_id" => "%9")

      expect(tmux.calls).to eq([:pane_details])
    end

    it "lists the panes once to post a reply" do
      desk.post("pane_id" => "%5", "summary" => "ok", "reply_to" => "sr-none")

      expect(tmux.calls).to eq([:pane_details])
    end
  end

  describe Workspace::PromptQueueDesk do
    let(:dir) { Dir.mktmpdir }
    let(:t0) { Time.utc(2026, 10, 19, 12, 0, 0) }
    let(:now) { [t0] }
    let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }
    let(:facts) do
      {kind: "claude", pane_pid: 100, agent_pid: 101, session_id: "s1", state: "done", fresh_since: t0 - 5, last_user_prompt_at: t0 - 60}
    end
    let(:monitor) do
      double("monitor").tap do |m|
        allow(m).to receive(:delivery_facts) { facts }
        allow(m).to receive(:fresh_since) { facts[:fresh_since] }
        allow(m).to receive(:typing_facts) { {kind: "claude", state: "idle", open_tools: []} }
        allow(m).to receive(:rescan_pane)
      end
    end
    let(:store) do
      ids = (1..5).map { |n| format("%016x", n) }
      Workspace::PromptQueueStore.new(path: File.join(dir, "prompt-queue.json"), clock: clock, id_generator: -> { ids.shift })
    end
    subject(:desk) do
      described_class.new(panes: factory, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
        delivery_lock: Mutex.new, clock: clock, sleeper: ->(seconds) { now[0] += seconds }, spawn: ->(&block) { block.call })
    end

    after { FileUtils.remove_entry(dir) }

    let(:pasted) { "────────\n❯ go\n────────\n" }

    it "types at once: a list and a server pid to accept, the same to prune and again to re-check, and quiet waits that only read" do
      tmux.styled_screens = [empty_prompt, pasted]
      desk.send_prompt("pane_id" => "%5", "text" => "go")

      expect(tmux.call_runs).to eq([
        :pane_details, :server_pid_for_pane,
        :pane_details, :server_pid_for_pane,
        :capture_screen, :pane_details, :server_pid_for_pane,
        :capture_screen_styled, :deliver, :capture_screen_styled, :deliver
      ])
    end

    it "refuses a pane the session does not have after one list" do
      desk.send_prompt("pane_id" => "%9", "text" => "go")

      expect(tmux.calls).to eq([:pane_details])
    end

    it "presses the keys and reads the screen with no list after the first" do
      tmux.styled_screens = [empty_prompt, empty_prompt, pasted]
      desk.interrupt_send("pane_id" => "%5", "text" => "go")

      expect(tmux.call_runs).to eq([
        :pane_details, :send_key, :capture_screen, :capture_screen_styled, :deliver, :capture_screen_styled, :deliver
      ])
    end
  end
  describe Workspace::HandoffWatcher do
    let(:t0) { Time.utc(2026, 10, 19, 12, 0, 0) }
    let(:now) { [t0] }
    let(:facts) do
      {kind: "claude", pane_pid: 100, agent_pid: 101, session_id: "s1", hooks: true, last_activity_at: t0 - 100,
       open_tools: 0, agents_running: 0}
    end
    let(:monitor) do
      double("monitor").tap do |m|
        allow(m).to receive(:followup_facts) { facts }
        allow(m).to receive(:typing_facts) { {kind: "claude", state: "idle", open_tools: []} }
      end
    end
    subject(:watcher) do
      described_class.new(panes: factory, session_name: "api", workspace: "api", session_monitor: monitor,
        typer: Workspace::PromptTyper.new(panes: factory, session_monitor: monitor), delivery_lock: Mutex.new,
        clock: -> { now.first })
    end

    it "makes no call to arm or to poll before a follow-up is due" do
      watcher.arm(pane_id: "%5", sent_at: t0, interval: 30, max: 3, text: "go", sent_text: "sent")
      watcher.poll

      expect(tmux.calls).to eq([])
    end

    it "lists the panes once for the follow-up, then reads and types with no list" do
      tmux.screens = [empty_prompt, "────────\n❯ go\n────────\n"]
      tmux.styled_screens = tmux.screens.dup
      watcher.arm(pane_id: "%5", sent_at: t0, interval: 30, max: 3, text: "go", sent_text: "sent")
      now[0] += 30
      watcher.poll

      expect(tmux.calls).to eq([:pane_details, :capture_screen_styled, :deliver, :capture_screen_styled, :deliver])
    end
  end

  describe Workspace::RestartRunner do
    it "reads the styled screen with no pane list" do
      wired = nil
      described_class.new(restart_factory: ->(**kw) { (wired = kw) && ScriptedCall.new { |**| {"ok" => true} } },
        registry: Workspace::RestartRegistry.new, panes: factory, session_name: "api", delivery_lock: Mutex.new,
        pipeline_ref: ->(_index) {}, monitor: nil, idle_prompt_check: Workspace::IdlePromptCheck.new,
        transcript_summary: Workspace::TranscriptSummary.new, pane_bindings: nil, error_output: StringIO.new)
        .run({"pane" => "0.1", "pane_id" => "%5"}, "go", false, 5, nil)
      wired[:screen_ready].call("%5")

      expect(tmux.calls).to eq([:capture_screen_styled])
    end
  end
  describe Workspace::AgentRestart do
    let(:now) { [0.0] }
    let(:wall) { [Time.utc(2026, 9, 27, 12, 0, 0)] }
    let(:context_reader) { instance_double(Workspace::ContextReader) }

    def restart(**options)
      described_class.new(panes: factory, context_reader: context_reader, session_name: "api", delivery_lock: Mutex.new,
        pipeline_ref: ->(_index) {}, clock: -> { now[0] }, wall_clock: -> { wall[0] },
        sleeper: ->(seconds) {
          now[0] += seconds
          wall[0] += seconds
        },
        quiet_timeout: 10, quiet_for: 1, poll_interval: 0.5, **options)
    end

    it "reads the plain screen with no pane list to find the pane gone" do
      tmux.screens = [nil]

      result = restart.call(pane_id: "%5", prompt: "go")

      expect(result).to include("error" => "pane_gone")
      expect(tmux.calls).to eq([:capture_screen])
    end

    it "waits on the screen, then lists the panes once for each of the clear and the prompt" do
      tmux.screens = ["❯ "]
      allow(context_reader).to receive(:read).and_return(
        {pct: 42, error: nil, updated_at: wall[0].utc.iso8601, session_id: "old"},
        {pct: nil, error: nil, updated_at: (wall[0] + 5).utc.iso8601, session_id: "new"}
      )
      result = restart(delivery_facts: ->(_id) { {hooks: true, last_user_prompt_at: wall[0] + 100} }).call(pane_id: "%5", prompt: "go", force: true)

      expect(result).to include("ok" => true)
      expect(tmux.call_runs).to eq([:capture_screen, :pane_details, :deliver, :pane_details, :deliver])
    end
  end

  describe Workspace::AgentRecoveryDesk do
    let(:dir) { Dir.mktmpdir }
    let(:t0) { Time.utc(2026, 10, 30, 12, 0, 0) }
    let(:sid) { "11111111-1111-4111-8111-111111111111" }
    let(:transcript_path) { File.join(dir, "session.jsonl") }
    let(:started) { "Mon Oct 26 10:00:00 2026" }
    let(:processes) do
      [10, 20].zip([[1, "-zsh"], [10, "claude --resume"]]).map do |pid, (ppid, args)|
        {pid: pid, ppid: ppid, lstart: started, command: args.split.first, args: args}
      end
    end
    let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new(processes)) }
    let(:store) { Workspace::AgentRecoveryStore.new(path: File.join(dir, "agent-recovery.json"), clock: -> { t0 }) }
    let(:ledger) { Workspace::SessionLedger.new(path: File.join(dir, "ledger.jsonl"), clock: -> { t0 }, logger: Workspace::Logger.new) }
    let(:report) { double("tmuxinator_report", show: {"windows" => [{"panes" => [{"kind" => "claude", "flags" => []}]}]}) }
    let(:desk_monitor) do
      double("monitor").tap do |m|
        allow(m).to receive(:typing_facts) { {kind: "claude", state: "idle", open_tools: []} }
        allow(m).to receive(:delivery_facts).and_return({})
        allow(m).to receive(:running_subagents).and_return(0)
      end
    end
    let(:desk) do
      described_class.new(panes: factory, workspace: "api", session_name: "api", session_monitor: desk_monitor, store: store,
        transcript: Workspace::TranscriptSummary.new, stopper: Workspace::AgentStopper.new(process_tree: process_tree, group_reader: ->(_pid) { [10, 10] }),
        detector: Workspace::AgentDetector.new, process_tree: process_tree, ledger: ledger,
        resume_command: Workspace::AgentResumeCommand.new(tmuxinator_report: report),
        prompt_typer: Workspace::PromptTyper.new(panes: factory, session_monitor: desk_monitor),
        readiness: double("readiness"), marker: Workspace::RecoveryStopMarker.new(state_dir: dir, clock: -> { t0 }),
        inbox: -> { Workspace::InboxStore.new(path: File.join(dir, "inbox.json"), clock: -> { t0 }) },
        delivery_lock: Mutex.new, clock: double("clock", now: t0 + 61), sleeper: ->(_seconds) {})
    end

    before do
      File.write(transcript_path, JSON.generate("type" => "assistant", "isApiErrorMessage" => true, "isSidechain" => false, "uuid" => "u-err") + "\n")
      ledger.record("event" => "session_start", "session_id" => sid, "pane_id" => "%5", "tmux_server" => "77", "cwd" => "/work")
      store.put("%5", {"session_id" => sid, "transcript_path" => transcript_path, "cwd" => "/work", "error" => "server_error",
                       "attempts" => 1, "phase" => "waiting", "stopped" => false, "failed_at" => Workspace::AgentRecoveryStore.stamp(t0),
                       "next_attempt_at" => Workspace::AgentRecoveryStore.stamp(t0 + 60), "agent_pid" => 20,
                       "agent_started" => started, "agent_flags" => [], "last_turn_uuid" => "u-err"})
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "claude"}]
      tmux.start_commands = [{window: 0, index: 1, id: "%5", start_command: nil}]
    end

    after { FileUtils.remove_entry(dir) }

    it "lists the panes once to check a pane, then reads the typed-in screen, the screen twice and the server pid" do
      verdict = desk.check("%5", store.get("%5"))

      expect(verdict).to have_attributes(answer: :go, mode: :restart)
      expect(tmux.call_runs).to eq([:pane_details, :capture_screen_styled, :capture_screen, :server_pid_for_pane])
    end

    it "lists the panes once, and reads nothing else, when tmux lists none" do
      tmux.details = []

      desk.check("%5", store.get("%5"))

      expect(tmux.calls).to eq([:pane_details])
    end
  end
end
