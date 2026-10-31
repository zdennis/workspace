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

      def capture_screen_styled(pane_id) = capture_screen(pane_id)

      def log = (@log ||= [])

      def key_ok = @key_ok != false

      attr_writer :key_ok

      def send_key(_session, _pane, key)
        log << [:key, key]
        key_ok
      end

      def deliver(session, target, text, enter: true)
        log << [:deliver, text, enter]
        @delivered << [session, target, text, enter]
        @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n────────\n")
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
      allow(m).to receive(:rescan_pane)
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
  let(:recovering) { [] }
  let(:refuse_claim) { [false] }
  let(:on_sleep) { [] }

  subject(:desk) do
    described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
      delivery_lock: Mutex.new, restarting: ->(id) { restarting.include?(id) }, recovering: ->(id) { recovering.include?(id) },
      claim_restart: ->(id) { (restarting.include?(id) || refuse_claim[0]) ? nil : (restarting << id) && :claim },
      release_restart: ->(id, token) { restarting.delete(id) if token == :claim },
      event_log: event_log, clock: clock,
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

    it "types into a pane that shows only Claude Code's suggestion" do
      suggestion = "────────\n\e[39m❯ \e[2msend %45 the reply when it's done\e[0m\n────────\n"
      tmux.scripted = -> { typed.empty? ? suggestion : "────────\n❯ run the specs\n────────\n" }

      reply = send_prompt

      expect(reply).to include("ok" => true)
      expect(typed).to eq(["run the specs"])
    end

    it "queues instead of typing over a draft in the input line" do
      tmux.screen = "────────\n❯ half a thought\n"

      reply = send_prompt

      expect(reply).to include("ok" => true, "queued" => true, "position" => 1)
      expect(typed).to eq([])
      expect(store.entries.first).to include("state" => "queued")
    end
  end

  describe "a refusal at delivery time" do
    before { working! }

    def refused_events = events.select { |type, _, _| type == "prompt_refused" }.map(&:last)

    def draft_screen! = (tmux.screen = "────────\n❯ half a thought\n")

    it "stores why the entry waits and writes one prompt_refused for ten refusals" do
      send_prompt
      draft_screen!
      turn_ends!(t0 + 30)
      stop_hook

      expect(store.entries.first).to include("refused_reason" => "input_not_empty", "refusals" => 1)
      expect(store.entries.first["refused_message"]).to be_a(String)

      9.times do |n|
        turn_ends!(t0 + 60 + (n * 10))
        desk.deliver_next("%5")
      end

      expect(store.entries.first["refusals"]).to eq(10)
      expect(refused_events).to eq([{"id" => "0000000000000001", "pane_id" => "%5", "reason" => "input_not_empty",
                                     "message" => store.entries.first["refused_message"]}])
    end

    it "writes a second event when the reason changes" do
      send_prompt
      draft_screen!
      turn_ends!(t0 + 30)
      stop_hook
      tmux.screen = "────────\n❯ \n"
      typing_refusal = Workspace::PromptTyper::Result.new(outcome: :refused, code: "not_ready", reason: "dialog_open", message: "a dialog is open")
      allow_any_instance_of(Workspace::PromptTyper).to receive(:type).and_return(typing_refusal)
      turn_ends!(t0 + 60)
      desk.deliver_next("%5")
      turn_ends!(t0 + 90)
      desk.deliver_next("%5")

      expect(refused_events.map { |e| e["reason"] }).to eq(%w[input_not_empty dialog_open])
      expect(store.entries.first).to include("refused_reason" => "dialog_open", "refusals" => 2)
    end

    it "clears the stored refusal once the entry is typed" do
      send_prompt
      draft_screen!
      turn_ends!(t0 + 30)
      stop_hook
      tmux.screen = empty_prompt
      turn_ends!(t0 + 60)
      desk.deliver_next("%5")

      expect(store.entries).to eq([])
      expect(typed).to eq(["run the specs"])
    end

    it "tells the sender of a first-try refusal why, and records the event after the entry is announced" do
      working_off = facts.merge!(state: "done", fresh_since: t0 - 5)
      draft_screen!

      reply = send_prompt

      expect(working_off).to be_a(Hash)
      expect(reply).to include("queued" => true, "waiting_reason" => "input_not_empty")
      expect(refused_events.map { |e| e["reason"] }).to eq(["input_not_empty"])
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
      tmux.screen = "────────\n❯ [Pasted text #1 +40 lines]\n────────\n" unless enter
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

  describe "a stale shell reading" do
    it "rescans a pane read as a shell once, and queues when an agent is there now" do
      facts[:kind] = "shell"
      allow(monitor).to receive(:rescan_pane).with("%5") { facts[:kind] = "claude" }

      expect(send_prompt).not_to include("error" => "not_an_agent")
      expect(monitor).to have_received(:rescan_pane).with("%5").once
    end
  end

  describe "refusals, which queue nothing" do
    it "refuses a shell" do
      facts[:kind] = "shell"
      expect(send_prompt).to include("ok" => false, "error" => "not_an_agent", "pane_id" => "%5")
    end

    it "still refuses a shell after the rescan" do
      facts[:kind] = "shell"

      expect(send_prompt).to include("error" => "not_an_agent")
      expect(monitor).to have_received(:rescan_pane).with("%5").once
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

  describe "while an API-error recovery holds the pane" do
    before do
      working!
      send_prompt
      turn_ends!(t0 + 30)
      recovering << "%5"
    end

    it "keeps the entry through the agent's own session_end" do
      desk.session_event("pane_id" => "%5", "event" => "session_end", "reason" => "other")

      expect(store.entries.size).to eq(1)
    end

    it "keeps the entry and types nothing when a scan finds a shell" do
      facts.merge!(kind: "shell", agent_pid: nil)
      desk.scan

      expect(store.entries.size).to eq(1)
      expect(typed).to eq([])
    end

    it "keeps the entry and types nothing when a scan finds a changed agent pid" do
      facts[:agent_pid] = 202
      desk.scan
      stop_hook

      expect(store.entries.size).to eq(1)
      expect(typed).to eq([])
    end

    it "queues a send without delivering it" do
      reply = send_prompt("second")

      expect(reply).to include("queued" => true)
      expect(store.entries.size).to eq(2)
      expect(typed).to eq([])
    end

    it "queues nothing and refuses a send that may not wait" do
      reply = desk.send_prompt("pane_id" => "%5", "text" => "now", "when_idle" => false)

      expect(reply).to include("ok" => false, "error" => "pane_busy")
      expect(store.entries.size).to eq(1)
      expect(typed).to eq([])
    end

    it "delivers the entry once the recovery is over and the resumed agent's turn ends" do
      facts[:agent_pid] = 202
      store.rebind_agent("%5", agent_pid: 202)
      recovering.clear
      stop_hook

      expect(typed).to eq(["run the specs"])
    end

    it "does not make the recovering call on the hook's thread" do
      blocks = []
      calls = []
      deferred = described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
        delivery_lock: Mutex.new, recovering: ->(id) { calls << id && false }, event_log: event_log, clock: clock,
        spawn: ->(&block) { blocks << block })

      deferred.session_event("pane_id" => "%5", "event" => "session_end", "reason" => "other")
      expect(calls).to eq([])
      blocks.each(&:call)
      expect(calls).to eq(["%5"])
      expect(store.entries).to eq([])
    end
  end

  describe "--clear-first" do
    # What the pane's hooks answer the first clear with, once its Enter was
    # pressed; [nil] sends no SessionStart.
    let(:answer) { [{source: "clear", session_id: "s2"}] }
    # Run on each look at the pane after the clear, until it is answered.
    let(:after_clear) { [] }
    let(:held_during_wait) { [] }

    before do
      facts.merge!(hooks: true, last_session_start: nil)
      answered = false
      allow(monitor).to receive(:delivery_facts) do |id|
        next nil unless id == "%5"
        if clear_entered? && !answered
          held_during_wait << restarting.include?("%5")
          after_clear.each(&:call)
          if answer[0]
            answered = true
            facts.merge!(session_id: answer[0][:session_id], last_session_start: answer[0].merge(at: now[0]))
          end
        end
        facts
      end
    end

    def clear_entered?
      index = tmux.delivered.index { |_, _, text, enter| text == "/clear" && !enter }
      index && tmux.delivered[index + 1]&.last == true
    end

    def send_clear_first(text = "run the specs", when_idle: true)
      desk.send_prompt("pane_id" => "%5", "text" => text, "clear_first" => true, "when_idle" => when_idle)
    end

    def dequeued = events.select { |type, _, _| type == "prompt_dequeued" }.map(&:last)

    context "on a pane whose turn has ended" do
      it "types the clear, waits for its SessionStart, then types the text" do
        reply = send_clear_first

        expect(reply).to eq("ok" => true, "delivered" => true, "submitted" => true, "cleared" => true,
          "id" => "0000000000000001", "pane" => "0.1", "pane_id" => "%5")
        expect(typed).to eq(["/clear", "run the specs"])
        expect(store.entries).to eq([])
        expect(events).to eq([])
      end

      it "holds the pane as a restart from the clear until the text is typed, then lets go" do
        send_clear_first

        expect(held_during_wait).to all(be(true))
        expect(held_during_wait).not_to be_empty
        expect(restarting).to eq([])
      end

      it "types nothing more when no SessionStart comes within the wait, answering clear_unconfirmed" do
        answer[0] = nil

        reply = send_clear_first

        expect(reply).to include("ok" => false, "error" => "clear_unconfirmed", "clear_typed" => true, "id" => "0000000000000001")
        expect(reply["message"]).to include("no SessionStart")
        expect(typed).to eq(["/clear"])
        expect(now[0] - t0).to be >= described_class::CLEAR_TIMEOUT
        expect(store.entries).to eq([])
        expect(restarting).to eq([])
      end

      it "doesn't take a SessionStart from another source, even with a new session id" do
        answer[0] = {source: "resume", session_id: "s2"}

        expect(send_clear_first).to include("error" => "clear_unconfirmed")
        expect(typed).to eq(["/clear"])
      end

      it "doesn't take a clear's SessionStart recorded before this clear was typed" do
        answer[0] = nil
        facts[:last_session_start] = {at: t0 - 1, source: "clear", session_id: "s1"}

        expect(send_clear_first).to include("error" => "clear_unconfirmed")
      end

      it "takes a prompt submitted after the clear as voiding it" do
        answer[0] = nil
        after_clear << -> { facts[:last_user_prompt_at] = now[0] }

        reply = send_clear_first

        expect(reply).to include("error" => "clear_unconfirmed")
        expect(reply["message"]).to include("prompt was submitted")
        expect(typed).to eq(["/clear"])
      end

      it "lets a prompt submitted after the SessionStart through the wait, and the re-check then types nothing" do
        after_clear << -> { facts[:last_user_prompt_at] = now[0] }

        reply = send_clear_first

        expect(reply).to include("error" => "not_delivered", "reason" => "not_delivered", "clear_typed" => true)
        expect(reply["message"]).to include("pane changed after the clear")
        expect(typed).to eq(["/clear"])
      end

      it "drops the entry with the identity reason when the pane is replaced during the wait" do
        after_clear << -> { tmux.details = [{id: "%5", window: 0, index: 1, pid: 999}] }

        reply = send_clear_first

        expect(reply).to include("error" => "not_delivered", "reason" => "pane_gone", "clear_typed" => true)
        expect(typed).to eq(["/clear"])
        expect(restarting).to eq([])
      end

      it "drops the entry when the screen doesn't settle after the clear" do
        frames = (1..1000).map { |n| "frame #{n}\n#{empty_prompt}" }
        after_clear << -> { tmux.scripted = -> { frames.shift } }

        reply = send_clear_first

        expect(reply).to include("error" => "not_delivered", "clear_typed" => true)
        expect(reply["message"]).to include("didn't settle")
        expect(typed).to eq(["/clear"])
      end

      it "types nothing and keeps the entry queued when a restart claims the pane before the clear" do
        refuse_claim[0] = true

        expect(send_clear_first).to include("queued" => true)
        expect(typed).to eq([])
        expect(store.entries.first).to include("state" => "queued")
      end

      it "answers clear_unconfirmed when the clear's Enter isn't confirmed" do
        tmux.statuses = [:pasted, :unsubmitted]

        expect(send_clear_first).to include("error" => "clear_unconfirmed", "clear_typed" => true)
        expect(typed).to eq(["/clear"])
      end

      it "drops the entry, never clearing twice, when the text doesn't reach the pane after the clear" do
        tmux.statuses = [:pasted, :submitted, :not_landed]

        reply = send_clear_first

        expect(reply).to include("ok" => false, "error" => "not_delivered", "reason" => "not_delivered", "clear_typed" => true)
        expect(store.entries).to eq([])
        expect(typed).to eq(["/clear", "run the specs"])
      end

      it "types nothing and keeps the entry queued when the clear isn't pasted" do
        tmux.screen = "────────\n❯ half a thought\n"

        expect(send_clear_first).to include("queued" => true)
        expect(typed).to eq([])
        expect(restarting).to eq([])
      end
    end

    context "queued for a working pane" do
      before { working! }

      it "is announced as clear_first and cleared at the end of the turn" do
        expect(send_clear_first).to include("queued" => true, "position" => 1)
        expect(events.first.last).to include("clear_first" => true)
        turn_ends!(t0 + 30)

        stop_hook

        expect(typed).to eq(["/clear", "run the specs"])
        expect(dequeued).to eq([{"id" => "0000000000000001", "pane_id" => "%5", "outcome" => "delivered", "submitted" => true}])
      end

      it "is dropped clear_unconfirmed, with nothing more typed, when the clear isn't confirmed" do
        answer[0] = nil
        send_clear_first
        turn_ends!(t0 + 30)

        stop_hook

        expect(typed).to eq(["/clear"])
        expect(dequeued).to eq([{"id" => "0000000000000001", "pane_id" => "%5", "outcome" => "dropped", "reason" => "clear_unconfirmed"}])
      end

      it "survives a change of conversation before its turn comes" do
        send_clear_first
        facts[:session_id] = "s9"
        turn_ends!(t0 + 30)

        stop_hook

        expect(typed).to eq(["/clear", "run the specs"])
      end

      it "moves the entries queued behind it to the conversation its clear started" do
        send_clear_first("one")
        send_prompt("two")
        turn_ends!(t0 + 30)
        stop_hook
        expect(store.entries.first).to include("text" => "two", "session_id" => "s2")

        turn_ends!(t0 + 90)
        desk.scan

        expect(typed).to eq(["/clear", "one", "two"])
      end

      it "types nothing after the clear when the entry is cancelled during the wait" do
        send_clear_first
        turn_ends!(t0 + 30)
        after_clear << -> { store.cancel("0000000000000001") }

        stop_hook

        expect(typed).to eq(["/clear"])
        expect(store.entries).to eq([])
        expect(dequeued).to eq([])
        expect(restarting).to eq([])
      end

      it "drops the entry interrupted, and lets go of the pane, when the delivery raises after the clear" do
        send_clear_first
        turn_ends!(t0 + 30)
        after_clear << -> { raise IOError, "monitor gone" }

        stop_hook

        expect(typed).to eq(["/clear"])
        expect(dequeued).to eq([{"id" => "0000000000000001", "pane_id" => "%5", "outcome" => "dropped", "reason" => "interrupted"}])
        expect(restarting).to eq([])
      end

      it "doesn't clear when the entry was cancelled before the clear" do
        send_clear_first
        turn_ends!(t0 + 30)
        on_sleep << -> { store.cancel("0000000000000001") }

        stop_hook

        expect(typed).to eq([])
        expect(store.entries).to eq([])
      end

      it "leaves the entry queued while a restart holds the pane" do
        send_clear_first
        turn_ends!(t0 + 30)
        restarting << "%5"

        stop_hook

        expect(typed).to eq([])
        expect(store.entries.first).to include("state" => "queued")
      end
    end

    context "without --when-idle" do
      it "clears and types now when the pane's turn has ended" do
        expect(send_clear_first(when_idle: false)).to include("delivered" => true, "cleared" => true)
      end

      it "refuses pane_busy, keeping nothing, while the agent works" do
        working!

        reply = send_clear_first(when_idle: false)

        expect(reply).to include("ok" => false, "error" => "pane_busy", "reason" => "not_ready")
        expect(store.entries).to eq([])
        expect(events).to eq([])
        expect(typed).to eq([])
      end

      it "refuses pane_busy when prompts are queued ahead" do
        working!
        send_prompt("first")

        reply = send_clear_first(when_idle: false)

        expect(reply).to include("error" => "pane_busy", "reason" => "queued_ahead")
        expect(store.entries.map { |e| e["text"] }).to eq(["first"])
      end
    end

    describe "refusals" do
      it "refuses clear_unsupported for an agent other than Claude Code" do
        facts[:kind] = "codex"
        typing[:kind] = "codex"

        reply = send_clear_first

        expect(reply).to include("ok" => false, "error" => "clear_unsupported", "kind" => "codex", "reason" => "agent")
        expect(store.entries).to eq([])
      end

      it "refuses clear_unsupported for a Claude Code pane no hook has reached" do
        facts[:hooks] = false

        expect(send_clear_first).to include("error" => "clear_unsupported", "kind" => "claude", "reason" => "no_hooks")
        expect(store.entries).to eq([])
        expect(typed).to eq([])
      end
    end
  end

  describe "#interrupt_send" do
    def interrupt_send(text = "do this instead", pane_id: "%5") = desk.interrupt_send("pane_id" => pane_id, "text" => text)

    it "presses the interrupt keys, waits for the prompt to settle, then types the text and Enter, in that order" do
      captures = 0
      busy = "✻ Working… (esc to interrupt)\n❯ \n"
      tmux.scripted = lambda do
        captures += 1
        tmux.log << [:capture]
        (captures <= 2) ? busy + "x" * captures : tmux.screen
      end

      reply = interrupt_send

      expect(reply).to include("ok" => true, "interrupted" => true, "keys" => ["Escape"], "delivered" => true,
        "submitted" => true, "pane" => "0.1", "pane_id" => "%5")
      expect(tmux.log.first).to eq([:key, "Escape"])
      captures_before_paste = tmux.log.take_while { |entry| entry[0] != :deliver }.count { |entry| entry[0] == :capture }
      expect(captures_before_paste).to be > 3
      expect(tmux.log.select { |entry| entry[0] == :deliver }).to eq([[:deliver, "do this instead", false], [:deliver, "", true]])
    end

    it "holds the delivery lock from the keys to Enter" do
      lock = Mutex.new
      held = []
      locked_desk = described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
        delivery_lock: lock, clock: clock, sleeper: ->(seconds) { now[0] += seconds }, spawn: ->(&block) { block.call })
      allow(tmux).to receive(:send_key).and_wrap_original { |m, *a| held << lock.owned? && m.call(*a) }
      allow(tmux).to receive(:deliver).and_wrap_original { |m, *a, **kw| held << lock.owned? && m.call(*a, **kw) }

      locked_desk.interrupt_send("pane_id" => "%5", "text" => "go")

      expect(held).to eq([true, true, true])
    end

    it "does not type, and says not_ready, when the prompt never comes back" do
      tick = 0
      tmux.scripted = -> { "✻ Working… #{tick += 1}\n❯ \n" }

      reply = interrupt_send

      expect(reply).to include("ok" => false, "error" => "not_ready", "interrupted" => true, "keys" => ["Escape"], "reason" => "busy")
      expect(tmux.delivered).to eq([])
      expect(now[0] - t0).to be >= described_class::INTERRUPT_TIMEOUT
    end

    it "does not type, and says not_ready, when the input line holds a draft" do
      tmux.screen = "────────\n❯ half a thought\n"

      reply = interrupt_send

      expect(reply).to include("error" => "not_ready", "reason" => "input_not_empty")
      expect(tmux.delivered).to eq([])
    end

    it "refuses a pane whose agent has no interrupt keys before pressing anything" do
      provider = Workspace::AgentProvider.find("claude")
      bare = instance_double(Workspace::AgentProvider, key: "claude", label: "Claude Code", interrupt_keys: [], ready_pattern: provider.ready_pattern)
      bare_desk = described_class.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: store,
        delivery_lock: Mutex.new, providers: [bare], clock: clock, sleeper: ->(s) { now[0] += s })

      reply = bare_desk.interrupt_send("pane_id" => "%5", "text" => "go")

      expect(reply).to include("error" => "no_interrupt_key", "kind" => "claude")
      expect(tmux.log).to eq([])
    end

    it "refuses a shell, an agent with no checkable screen, a waiting pane and a held pane without pressing anything" do
      facts[:kind] = "shell"
      expect(interrupt_send).to include("error" => "not_an_agent")
      facts[:kind] = "codex"
      expect(interrupt_send).to include("error" => "unsupported_agent", "kind" => "codex")
      facts[:kind] = "claude"
      typing[:state] = "waiting"
      expect(interrupt_send).to include("error" => "pane_waiting", "reason" => "waiting")
      typing[:state] = "idle"
      restarting << "%5"
      expect(interrupt_send).to include("error" => "pane_busy", "reason" => "restarting")
      expect(tmux.log).to eq([])
    end

    it "rescans a pane read as a shell once before refusing it" do
      facts[:kind] = "shell"
      allow(monitor).to receive(:rescan_pane).with("%5") { facts[:kind] = "codex" }
      expect(interrupt_send).to include("error" => "unsupported_agent", "kind" => "codex")

      facts[:kind] = "shell"
      allow(monitor).to receive(:rescan_pane).with("%5")
      expect(interrupt_send).to include("error" => "not_an_agent")
    end

    it "stops, typing nothing, when a key press fails" do
      tmux.key_ok = false

      expect(interrupt_send).to include("error" => "not_delivered", "keys_sent" => 0, "interrupted" => false)
      expect(tmux.delivered).to eq([])
    end

    it "answers not_submitted when the paste landed but Enter did not take" do
      tmux.statuses.push(:pasted, :unsubmitted)

      expect(interrupt_send).to include("error" => "not_submitted", "interrupted" => true, "delivered" => true, "submitted" => false)
    end

    it "answers pane_not_ready when the pane is not scanned yet, and when the question tool is open" do
      allow(monitor).to receive(:delivery_facts).and_return(nil)
      expect(interrupt_send).to include("error" => "pane_not_ready", "reason" => "unknown")
      allow(monitor).to receive(:delivery_facts).and_return(facts)
      typing[:open_tools] = ["AskUserQuestion"]
      expect(interrupt_send).to include("error" => "pane_waiting", "reason" => "question_open")
      expect(tmux.log).to eq([])
    end

    it "answers not_delivered when the paste never lands" do
      tmux.statuses.push(:not_landed)

      expect(interrupt_send).to include("error" => "not_delivered", "interrupted" => true)
    end

    it "refuses an empty text and an unknown pane" do
      expect(interrupt_send("")).to include("error" => "usage")
      expect(interrupt_send("go", pane_id: "%99")).to include("error" => "no_such_pane")
    end
  end
end
