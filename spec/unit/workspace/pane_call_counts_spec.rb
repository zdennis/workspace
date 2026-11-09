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
end
