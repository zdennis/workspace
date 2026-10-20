require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PromptQueueDesk do
  let(:empty_prompt) { "────────\n❯ \n" }

  # One tmux for the desk and the typer: a paste shows in the input line and
  # Enter empties it again, unless screens are scripted.
  let(:tmux) do
    Class.new do
      attr_accessor :details, :server_pid, :screen, :scripted, :statuses
      attr_reader :delivered

      def initialize(screen)
        @details = [{id: "%5", window: 0, index: 1, pid: 100}]
        @server_pid = "77"
        @screen = screen
        @empty = screen
        @delivered = []
        @statuses = []
      end

      def pane_details(_session, window: "0")
        raise ArgumentError, "expected every window" unless window.nil?
        @details
      end

      def server_pid_for_pane(_pane_id) = @server_pid

      def capture_screen(_pane_id) = @scripted ? @scripted.call : @screen

      def deliver(session, target, text, enter: true)
        @delivered << [session, target, text, enter]
        @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n")
        status = @statuses.shift || (enter ? :submitted : :pasted)
        Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
      end
    end.new(empty_prompt)
  end

  let(:t0) { Time.utc(2026, 10, 19, 12, 0, 0) }
  let(:now) { [t0] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }

  let(:facts) do
    {kind: "claude", pane_pid: 100, agent_pid: 101, session_id: "s1", state: "done",
     fresh_since: t0 - 5, last_user_prompt_at: t0 - 60}
  end
  let(:typing) { {kind: "claude", state: "idle", open_tools: []} }
  let(:monitor) do
    double("monitor").tap do |m|
      allow(m).to receive(:delivery_facts) { |id| (id == "%5") ? facts : nil }
      allow(m).to receive(:fresh_since) { facts[:fresh_since] }
      allow(m).to receive(:typing_facts) { typing }
    end
  end

  let(:dir) { Dir.mktmpdir }
  let(:ids) { (1..20).map { |n| format("%016x", n) } }
  let(:store) do
    Workspace::PromptQueueStore.new(path: File.join(dir, "prompt-queue.json"), clock: clock, id_generator: -> { ids.shift })
  end
  let(:events) { [] }
  let(:event_log) do
    double("event_log").tap do |log|
      allow(log).to receive(:record) { |type:, project:, data:| events << [type, project, data] }
    end
  end
  let(:restarting) { [] }
  let(:on_sleep) { [] }

  subject(:desk) do
    described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
      delivery_lock: Mutex.new, restarting: ->(id) { restarting.include?(id) }, event_log: event_log, clock: clock,
      sleeper: ->(seconds) {
        on_sleep.shift&.call
        now[0] += seconds
      },
      spawn: ->(&block) { block.call }, daemon_pid: Process.pid)
  end

  after { FileUtils.remove_entry(dir) }

  def send_prompt(text = "run the specs", pane_id: "%5") = desk.send_prompt("pane_id" => pane_id, "text" => text)

  def stop_hook = desk.session_event("pane_id" => "%5", "event" => "stop", "session_id" => "s1")

  def typed = tmux.delivered.select { |_, _, text, enter| !enter }.map { |_, _, text, _| text }

  def last_delivered = JSON.parse(File.read(File.join(dir, "prompt-queue.json")))["panes"].dig("%5", "last_delivered_at")

  def working!
    facts.merge!(state: "working", fresh_since: nil)
  end

  def turn_ends!(at)
    now[0] = at
    facts.merge!(state: "done", fresh_since: at)
  end

  describe "#send_prompt to a pane whose turn has ended" do
    it "types the text during the call and records no event" do
      reply = send_prompt

      expect(reply).to eq("ok" => true, "delivered" => true, "submitted" => true, "id" => "0000000000000001",
        "pane" => "0.1", "pane_id" => "%5")
      expect(tmux.delivered).to eq([["api", "0.1", "run the specs", false], ["api", "0.1", "", true]])
      expect(store.entries).to eq([])
      expect(last_delivered).not_to be_nil
      expect(events).to eq([])
    end

    it "waits for the screen to stay unchanged before typing" do
      screens = ["a", "b", "b", "b", "b", "b", "b", "b", "b", "b", "b"].map { |s| "#{s}\n#{empty_prompt}" }
      tmux.scripted = -> { (screens.size > 1) ? screens.shift : tmux.screen }

      send_prompt

      expect(now[0] - t0).to be >= described_class::QUIET_FOR
      expect(typed).to eq(["run the specs"])
    end

    it "says not_submitted, and never types it again, when the pasted text isn't confirmed" do
      tmux.statuses = [:pasted, :unsubmitted]

      reply = send_prompt

      expect(reply).to include("ok" => false, "error" => "not_submitted", "delivered" => true, "submitted" => false)
      expect(store.entries).to eq([])
      expect(events).to eq([])
    end

    it "queues instead of typing over a draft in the input line" do
      tmux.screen = "────────\n❯ half a thought\n"

      reply = send_prompt

      expect(reply).to include("ok" => true, "queued" => true, "position" => 1)
      expect(typed).to eq([])
      expect(store.entries.first).to include("state" => "queued")
    end
  end

  describe "#send_prompt to a working pane" do
    before { working! }

    it "queues the text, answers its id and position, and records prompt_queued" do
      reply = send_prompt

      expect(reply).to eq("ok" => true, "queued" => true, "id" => "0000000000000001", "position" => 1,
        "pane" => "0.1", "pane_id" => "%5")
      expect(events).to eq([["prompt_queued", "api",
        {"id" => "0000000000000001", "pane_id" => "%5", "position" => 1, "clear_first" => false}]])
      expect(store.entries.first).to include("server_pid" => "77", "pane_pid" => 100, "agent_pid" => 101, "session_id" => "s1")
      expect(typed).to eq([])
    end

    it "types it when the turn ends, recording prompt_dequeued" do
      send_prompt
      turn_ends!(t0 + 30)

      stop_hook

      expect(typed).to eq(["run the specs"])
      expect(events.last).to eq(["prompt_dequeued", "api",
        {"id" => "0000000000000001", "pane_id" => "%5", "outcome" => "delivered", "submitted" => true}])
    end

    it "types queued prompts in order, one per turn end" do
      send_prompt("one")
      expect(send_prompt("two")).to include("position" => 2)
      turn_ends!(t0 + 30)

      stop_hook
      stop_hook
      expect(typed).to eq(["one"])

      turn_ends!(t0 + 90)
      desk.scan
      expect(typed).to eq(["one", "two"])
    end

    it "keeps an entry while the pane waits on a person, and types it once it is done again" do
      send_prompt
      facts.merge!(state: "waiting", fresh_since: nil)
      desk.scan
      expect(typed).to eq([])

      turn_ends!(t0 + 30)
      desk.scan
      expect(typed).to eq(["run the specs"])
    end

    it "doesn't type when a prompt was submitted after the turn ended" do
      send_prompt
      turn_ends!(t0 + 30)
      on_sleep << -> { facts[:last_user_prompt_at] = t0 + 31 }

      stop_hook

      expect(typed).to eq([])
      expect(store.entries.first).to include("state" => "queued")
      expect(last_delivered).to be_nil
    end

    it "doesn't type when the turn ended again during the quiet wait" do
      send_prompt
      turn_ends!(t0 + 30)
      on_sleep << -> { facts[:fresh_since] = t0 + 31 }

      stop_hook

      expect(typed).to eq([])
      expect(store.entries.first).to include("state" => "queued")
    end

    it "leaves a pane a restart holds alone" do
      send_prompt
      turn_ends!(t0 + 30)
      restarting << "%5"

      stop_hook

      expect(typed).to eq([])
    end

    it "types nothing for an entry cancelled while it was claimed" do
      send_prompt
      turn_ends!(t0 + 30)
      on_sleep << -> { store.cancel("0000000000000001") }

      stop_hook

      expect(typed).to eq([])
      expect(store.entries).to eq([])
      expect(events.map(&:first)).to eq(["prompt_queued"])
    end

    it "puts an entry back when the paste never reached the pane" do
      send_prompt
      turn_ends!(t0 + 30)
      tmux.statuses = [:not_landed]

      stop_hook

      expect(store.entries.first).to include("state" => "queued")
      expect(store.entries.first.keys).not_to include("paste_started_at")
      expect(last_delivered).to be_nil
    end

    it "drops an entry interrupted after its paste started, and puts back one interrupted before" do
      send_prompt("one")
      turn_ends!(t0 + 30)
      allow(tmux).to receive(:deliver).and_raise(IOError, "tmux died")

      stop_hook

      expect(events.last).to eq(["prompt_dequeued", "api",
        {"id" => "0000000000000001", "pane_id" => "%5", "outcome" => "dropped", "reason" => "interrupted"}])

      working!
      send_prompt("two")
      turn_ends!(t0 + 90)
      on_sleep << -> { raise IOError, "capture failed" }
      stop_hook
      expect(store.entries.first).to include("text" => "two", "state" => "queued")
    end

    it "is started by the scan for every pane with entries" do
      send_prompt
      turn_ends!(t0 + 30)

      desk.scan

      expect(typed).to eq(["run the specs"])
    end
  end

  describe "drop rules" do
    before do
      working!
      send_prompt
      turn_ends!(t0 + 30)
    end

    def dropped_reason = events.last.last.values_at("outcome", "reason")

    it "drops an entry whose pane was replaced" do
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 999}]
      desk.scan
      expect(dropped_reason).to eq(["dropped", "pane_gone"])
    end

    it "drops an entry whose pane is gone" do
      tmux.details = [{id: "%6", window: 0, index: 2, pid: 200}]
      desk.scan
      expect(dropped_reason).to eq(["dropped", "pane_gone"])
    end

    it "drops nothing, and types nothing, when tmux lists no pane at all (it failed)" do
      tmux.details = []
      desk.scan
      expect(store.entries.size).to eq(1)
      expect(typed).to eq([])
    end

    it "drops nothing while the agent pid isn't known" do
      facts[:agent_pid] = nil
      desk.scan
      expect(typed).to eq(["run the specs"])
    end

    it "drops an entry whose agent exited" do
      facts.merge!(kind: "shell", agent_pid: nil)
      desk.scan
      expect(dropped_reason).to eq(["dropped", "session_ended"])
    end

    it "drops an entry when tmux restarted" do
      tmux.server_pid = "78"
      desk.scan
      expect(dropped_reason).to eq(["dropped", "pane_gone"])
    end

    it "drops an entry whose agent was restarted" do
      facts[:agent_pid] = 202
      desk.scan
      expect(dropped_reason).to eq(["dropped", "session_ended"])
    end

    it "drops an entry when the conversation changed" do
      facts[:session_id] = "s2"
      desk.scan
      expect(dropped_reason).to eq(["dropped", "conversation_changed"])
      expect(typed).to eq([])
    end

    it "drops an entry when its session ended, but not on a clear" do
      desk.session_event("pane_id" => "%5", "event" => "session_end", "reason" => "clear")
      expect(store.entries.size).to eq(1)

      desk.session_event("pane_id" => "%5", "event" => "session_end", "reason" => "logout")
      expect(dropped_reason).to eq(["dropped", "session_ended"])
    end

    it "drops an entry whose identity changed between the claim and the paste" do
      on_sleep << -> { facts[:session_id] = "s2" }

      stop_hook

      expect(dropped_reason).to eq(["dropped", "conversation_changed"])
      expect(typed).to eq([])
    end
  end

  it "binds a pane's first session id to entries queued without one, on its session_start or the next delivery" do
    working!
    facts[:session_id] = nil
    send_prompt
    send_prompt

    desk.session_event("pane_id" => "%5", "event" => "user_prompt", "session_id" => "s7")
    expect(store.entries.first["session_id"]).to be_nil
    desk.session_event("pane_id" => "%5", "event" => "session_start", "session_id" => "s7")
    expect(store.entries.first["session_id"]).to eq("s7")
  end

  it "binds the monitor's session id before a delivery, so the entry goes to that conversation" do
    working!
    facts[:session_id] = nil
    send_prompt
    turn_ends!(t0 + 30)
    facts[:session_id] = "s7"

    stop_hook

    expect(typed).to eq(["run the specs"])
  end

  it "ignores a sub-agent's Stop" do
    working!
    send_prompt
    turn_ends!(t0 + 30)

    desk.session_event("pane_id" => "%5", "event" => "stop", "agent_id" => "sub-1")

    expect(typed).to eq([])
  end

  describe "#scan" do
    before do
      working!
      send_prompt
    end

    it "costs no tmux call for a pane still at work" do
      expect(tmux).not_to receive(:pane_details)
      desk.scan
    end

    it "skips a pane whose delivery is still running" do
      turn_ends!(t0 + 30)
      lock = desk.send(:pane_lock, "%5")
      lock.lock
      desk.scan
      lock.unlock

      expect(typed).to eq([])
    end
  end

  it "leaves an entry queued when the screen never stays unchanged" do
    working!
    send_prompt
    turn_ends!(t0 + 30)
    n = 0
    tmux.scripted = -> { "#{n += 1}\n#{empty_prompt}" }

    stop_hook

    expect(typed).to eq([])
    expect(store.entries.first).to include("state" => "queued")
  end

  it "types a long prompt Claude Code shows as a paste placeholder" do
    working!
    text = "step\n" * 40
    send_prompt(text)
    turn_ends!(t0 + 30)
    allow(tmux).to receive(:deliver).and_wrap_original do |original, session, target, body, enter: true|
      result = original.call(session, target, body, enter: enter)
      tmux.screen = "────────\n❯ [Pasted text #1 +40 lines]\n" unless enter
      result
    end

    stop_hook

    expect(events.last.last).to include("outcome" => "delivered", "submitted" => true)
  end

  it "reports an abandoned delivery the store reaped as interrupted" do
    working!
    send_prompt
    turn_ends!(t0 + 30)
    claimed, = store.claim("%5", daemon_pid: 999_999_999) { t0 + 30 }
    store.start_paste(claimed)
    now[0] += Workspace::PromptQueueStore::STALE_CLAIM + 1

    desk.scan

    expect(events.last.last).to include("outcome" => "dropped", "reason" => "interrupted")
  end

  describe "a send whose own delivery doesn't go through" do
    it "answers not_delivered with the reason when the pane changed during the quiet wait" do
      on_sleep << -> { facts[:session_id] = "s2" }

      expect(send_prompt).to include("ok" => false, "error" => "not_delivered", "reason" => "conversation_changed")
      expect(events).to eq([])
    end

    it "answers not_delivered when the prompt was cancelled before the paste" do
      on_sleep << -> { store.cancel("0000000000000001") }

      expect(send_prompt).to include("ok" => false, "error" => "not_delivered", "reason" => "cancelled")
    end
  end

  describe "refusals, which queue nothing" do
    it "refuses a shell" do
      facts[:kind] = "shell"
      expect(send_prompt).to include("ok" => false, "error" => "not_an_agent", "pane_id" => "%5")
    end

    it "refuses an agent whose screen can't be checked" do
      facts[:kind] = "codex"
      expect(send_prompt).to include("error" => "unsupported_agent", "kind" => "codex")
    end

    it "refuses a pane waiting on a person" do
      typing[:state] = "waiting"
      expect(send_prompt).to include("error" => "pane_waiting", "reason" => "waiting")
    end

    it "refuses a pane showing a question tool" do
      typing[:open_tools] = ["AskUserQuestion"]
      expect(send_prompt).to include("error" => "pane_waiting", "reason" => "question_open")
    end

    it "refuses a pane the monitor hasn't scanned, and one tmux doesn't have" do
      tmux.details << {id: "%6", window: 0, index: 2, pid: 200}
      expect(send_prompt(pane_id: "%6")).to include("error" => "pane_not_ready", "reason" => "unknown")
      expect(send_prompt(pane_id: "%9")).to include("error" => "no_such_pane")
    end

    it "refuses while tmux can't list the panes, or the tmux server or agent pid can't be read" do
      tmux.details = []
      expect(send_prompt).to include("error" => "pane_not_ready", "reason" => "unknown")

      tmux.details = [{id: "%5", window: 0, index: 1, pid: 100}]
      tmux.server_pid = nil
      expect(send_prompt).to include("error" => "pane_not_ready", "reason" => "unknown")

      tmux.server_pid = "77"
      facts[:agent_pid] = nil
      expect(send_prompt).to include("error" => "pane_not_ready", "reason" => "unknown")
    end

    it "refuses empty or oversized text" do
      expect(send_prompt("")).to include("error" => "usage")
      expect(send_prompt("x" * (Workspace::PromptQueueStore::MAX_BYTES + 1))).to include("error" => "usage")
    end

    after do
      expect(typed).to eq([])
      expect(store.entries).to eq([])
    end
  end

  it "refuses a ninth prompt for one pane, saying the bound" do
    working!
    8.times { send_prompt }

    expect(send_prompt).to include("error" => "queue_full", "limit" => 8)
    expect(store.entries.size).to eq(8)
  end

  describe "with the real session monitor after a daemon restart" do
    let(:log_dir) { Dir.mktmpdir }
    let(:log_config) do
      Workspace::Config.new(workspace_dir: log_dir).tap do |c|
        allow(c).to receive(:event_log_file).and_return(File.join(log_dir, "events.jsonl"))
      end
    end
    let(:real_log) { Workspace::EventLog.new(config: log_config, error_output: StringIO.new, clock: clock) }
    let(:process_tree) { double("process_tree") }
    let(:tree) { double("snapshot") }
    let(:monitor) do
      Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "api", idle_after: 30,
        clock: clock, event_log: real_log, project: "api")
    end

    before do
      allow(tmux).to receive(:pane_details).and_return([{id: "%5", window: 0, index: 1, pid: 100, command: "node", cwd: "/p", title: "c"}])
      allow(tmux).to receive(:capture_pane) { tmux.screen }
      allow(process_tree).to receive(:snapshot).and_return(tree)
      allow(tree).to receive(:find_descendant).and_return({pid: 101, command: "claude", args: "claude"})
    end

    after { FileUtils.remove_entry(log_dir) }

    it "doesn't deliver on a restored done until a Stop or two matching scans idle_after apart" do
      first = Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "api", idle_after: 30,
        clock: clock, event_log: real_log, project: "api")
      first.scan
      first.record("pane_id" => "%5", "event" => "stop")
      first.scan
      now[0] = t0 + 100
      monitor.scan
      monitor.on_scan = -> { desk.scan }
      expect(send_prompt).to include("queued" => true)

      monitor.scan
      desk.scan
      expect(typed).to eq([])

      now[0] = t0 + 131
      monitor.scan
      desk.scan
      expect(typed).to eq(["run the specs"])
    end

    it "delivers to a restored done pane once this daemon hears its Stop" do
      first = Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "api", idle_after: 30,
        clock: clock, event_log: real_log, project: "api")
      first.scan
      first.record("pane_id" => "%5", "event" => "stop")
      first.scan
      now[0] = t0 + 100
      monitor.scan
      expect(send_prompt).to include("queued" => true)

      now[0] = t0 + 105
      monitor.record("pane_id" => "%5", "event" => "stop")
      stop_hook

      expect(typed).to eq(["run the specs"])
    end
  end
end
