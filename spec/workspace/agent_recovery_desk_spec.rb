require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentRecoveryDesk do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:started) { "Mon Oct 26 10:00:00 2026" }
  let(:empty_prompt) { "────────\n❯ \n" }

  let(:tmux) do
    Class.new(CLITestHelpers::FakeTmux) do
      attr_accessor :details, :screen, :scripted, :start_commands, :on_deliver, :gone

      def initialize(screen)
        super()
        @screen = screen
        @empty = screen
        @details = [{id: "%5", window: 0, index: 1, pid: 10, command: "claude"}]
        @start_commands = [{window: 0, index: 1, id: "%5", start_command: nil}]
      end

      def pane_details(_session, window: "0")
        raise ArgumentError, "expected every window" unless window.nil?
        @details
      end

      def session_gone?(_session) = @gone == true

      def pane_start_commands(_session) = @start_commands

      def server_pid_for_pane(pane_id) = (@details.any? { |detail| detail[:id] == pane_id }) ? "77" : nil

      def capture_screen(_pane_id) = @scripted ? @scripted.call : @screen

      def deliver(session, pane, text, enter: true)
        @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n")
        sent_keys << {session: session, pane: pane, text: text, enter: enter}
        on_deliver&.call(text)
        Workspace::Tmux::Delivery.new(status: enter ? :submitted : :pasted, message: "fake")
      end
    end.new(empty_prompt)
  end

  let(:t0) { Time.utc(2026, 10, 30, 12, 0, 0) }
  let(:now) { [t0] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }

  let(:facts) do
    {kind: "claude", pane_pid: 10, agent_pid: 10, session_id: sid, state: "idle", fresh_since: t0 - 5,
     last_user_prompt_at: t0 - 60}
  end
  let(:typing) { {kind: "claude", state: "idle", open_tools: []} }
  let(:subagents) { [0] }
  let(:marked) { [] }
  let(:unknown_panes) { [] }
  let(:monitor) do
    double("monitor").tap do |m|
      allow(m).to receive(:delivery_facts) { facts }
      allow(m).to receive(:fresh_since) { facts[:fresh_since] }
      allow(m).to receive(:typing_facts) { typing }
      allow(m).to receive(:running_subagents) { subagents[0] }
      allow(m).to receive(:mark_turn_failed) { |id| marked << id }
      allow(m).to receive(:rescan_pane)
      allow(m).to receive(:pane_kind) { |id| unknown_panes.include?(id) ? nil : "claude" }
      allow(m).to receive(:agent_pid) { facts[:agent_pid] }
    end
  end

  def proc_entry(pid, ppid, args, lstart: started)
    {pid: pid, ppid: ppid, lstart: lstart, command: args.split.first, args: args}
  end

  let(:processes) { [proc_entry(10, 1, "-zsh"), proc_entry(20, 10, "claude --resume")] }
  let(:tree_broken) { [false] }
  let(:process_tree) do
    double("process_tree").tap do |tree|
      allow(tree).to receive(:snapshot) do
        raise Workspace::Error, "could not read the process table" if tree_broken[0]
        hooks[:snapshot]&.call
        Workspace::ProcessTree::Snapshot.new(processes)
      end
    end
  end
  let(:signals) { [] }
  let(:group_ids) { [10, 10] }
  let(:stopper) do
    Workspace::AgentStopper.new(process_tree: process_tree,
      signaller: ->(signal, pid) {
        signals << [signal, pid]
        hooks[:signal]&.call
      },
      group_reader: ->(pid) { group_read.call(pid) })
  end
  let(:group_read) { ->(_pid) { group_ids } }
  # What a fake agent does when the attempt reaches it: :signal, :deliver (the
  # resume command), :enter (a typed message's Enter), :wait (the readiness wait), :sleep, :rebind.
  let(:hooks) { {} }
  let(:sleeps) { [] }
  let(:refuse_claim) { [false] }
  let(:delivery_lock) { Mutex.new }
  let(:readiness) do
    double("readiness").tap do |ready|
      allow(ready).to receive(:deadline_in) { |seconds| seconds }
      allow(ready).to receive(:wait) { hooks[:wait]&.call }
    end
  end

  let(:dir) { Dir.mktmpdir }
  let(:store) { Workspace::AgentRecoveryStore.new(path: File.join(dir, "agent-recovery.json"), clock: clock) }
  let(:ledger) { Workspace::SessionLedger.new(path: File.join(dir, "ledger.jsonl"), clock: -> { now[0] }, logger: Workspace::Logger.new) }
  let(:inbox) { Workspace::InboxStore.new(path: File.join(dir, "inbox.json"), clock: -> { now[0] }) }
  let(:marker) { Workspace::RecoveryStopMarker.new(state_dir: dir, clock: clock) }
  let(:transcript_path) { File.join(dir, "session.jsonl") }
  let(:report) do
    double("tmuxinator_report", show: {"windows" => [{"panes" => [{"kind" => "claude", "flags" => []}]}]})
  end
  let(:resume_command) { Workspace::AgentResumeCommand.new(tmuxinator_report: report) }
  let(:typer) { Workspace::PromptTyper.new(tmux: tmux, session_monitor: monitor) }
  let(:events) { [] }
  let(:event_log) do
    double("event_log").tap do |log|
      allow(log).to receive(:record) do |type:, project:, data:|
        events << [type, project, data]
        hooks[:record]&.call
      end
    end
  end
  let(:restarting) { [] }
  let(:rebound) { [] }
  let(:spawn) { ->(&block) { block.call } }

  def build_desk(store: self.store, stub_attempts: true, spawn: self.spawn)
    tmux.on_deliver = lambda { |text|
      hooks[:deliver]&.call if text.include?("--resume")
      hooks[:enter]&.call if text.empty?
    }
    described_class.new(tmux: tmux, workspace: "api", session_name: "api", session_monitor: monitor, store: store,
      transcript: Workspace::TranscriptSummary.new, stopper: stopper, detector: Workspace::AgentDetector.new,
      process_tree: process_tree, ledger: ledger, resume_command: resume_command, prompt_typer: typer,
      readiness: readiness, marker: marker, inbox: -> { inbox }, event_log: event_log, delivery_lock: delivery_lock,
      restarting: ->(id) { restarting.include?(id) },
      claim_restart: ->(id) {
        next nil if refuse_claim[0]
        restarting << id
        Object.new
      },
      release_restart: ->(id, _token) { restarting.delete(id) },
      rebind_queue: ->(id, pid) {
        rebound << [id, pid]
        hooks[:rebind]&.call
      },
      clock: clock,
      sleeper: ->(seconds) {
        now[0] += seconds
        sleeps << seconds
        hooks[:sleep]&.call
      },
      spawn: spawn).tap do |built|
      if stub_attempts
        allow(built).to receive(:typed_attempt) { |id, answer| attempts << [:typed, id, answer] }
        allow(built).to receive(:restart_attempt) { |id, answer| attempts << [:restart, id, answer] }
      end
    end
  end

  let(:attempts) { [] }
  subject(:desk) { build_desk }

  before do
    write_transcript
    start_session(sid)
  end

  after { FileUtils.remove_entry(dir) }

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  def error_line(uuid = "u-err")
    JSON.generate("type" => "assistant", "isApiErrorMessage" => true, "isSidechain" => false, "uuid" => uuid)
  end

  def good_line(uuid = "u-good")
    JSON.generate("type" => "assistant", "isSidechain" => false, "uuid" => uuid)
  end

  def write_transcript(*lines)
    lines = [error_line] if lines.empty?
    File.write(transcript_path, lines.join("\n") + "\n")
  end

  def start_session(id, pane: "%5", cwd: "/work")
    ledger.record("event" => "session_start", "session_id" => id, "pane_id" => pane, "tmux_server" => "77", "cwd" => cwd)
  end

  def event(name, session: sid, pane: "%5", **fields)
    desk.session_event({"event" => name, "pane_id" => pane, "session_id" => session}.merge(fields.transform_keys(&:to_s)))
  end

  def failed(error = "server_error", session: sid, path: transcript_path)
    event("turn_failed", session: session, error: error, transcript_path: path)
  end

  # An entry due now, confirmed by the scan, with the agent still in the pane.
  def due_entry(**fields)
    store.put("%5", {"session_id" => sid, "transcript_path" => transcript_path, "cwd" => "/work", "error" => "server_error",
                     "attempts" => 1, "phase" => "waiting", "stopped" => false, "failed_at" => stamp(t0),
                     "next_attempt_at" => stamp(t0 + 60), "agent_pid" => 20, "agent_started" => started,
                     "last_turn_uuid" => "u-err"}.merge(fields.transform_keys(&:to_s)))
    now[0] = t0 + 61
  end

  def entry = store.get("%5")

  def gone!
    processes.reject! { |p| p[:pid] == 20 }
    tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "zsh"}]
  end

  def answer = desk.check("%5", entry).answer

  def expect_gave_up(reason, items: 1)
    expect(entry).to include("phase" => "gave_up", "give_up_reason" => reason)
    expect(inbox.list.size).to eq(items)
    expect(events.reverse.find { |type, _, _| type == "agent_recovery_gave_up" }[2]).to include("reason" => reason)
  end

  def expect_no_attempt
    expect(attempts).to eq([])
    expect(signals).to eq([])
  end

  describe "the typed messages" do
    [described_class::TYPED_MESSAGE, described_class::RESUMED_MESSAGE].each do |template|
      it "hold nothing a shell expands or runs: #{template[0, 30]}" do
        expect(format(template, error: "server_error")).not_to match(/[`$;&|<>\\'"\n]/)
      end
    end
  end

  describe "the worker" do
    it "does no store or process call on the caller's thread, and works the queue in order" do
      blocks = []
      worker_desk = described_class.new(tmux: tmux, workspace: "api", session_name: "api", session_monitor: monitor, store: spy("store"),
        transcript: nil, stopper: spy("stopper"), detector: nil, process_tree: spy("tree"), ledger: nil, resume_command: nil,
        prompt_typer: nil, readiness: nil, marker: nil, inbox: nil, delivery_lock: Mutex.new, clock: clock,
        spawn: ->(&block) { blocks << block })

      worker_desk.session_event("event" => "stop", "pane_id" => "%5", "session_id" => sid)
      worker_desk.session_event("event" => "user_prompt", "pane_id" => "%5", "session_id" => sid)

      expect(blocks.size).to eq(1)
      expect(worker_desk.instance_variable_get(:@store)).not_to have_received(:update)
      expect(process_tree).not_to have_received(:snapshot)
    end

    it "starts a new worker for an event that arrives after the queue ran dry" do
      failed
      event("stop")

      expect(entry).to be_nil
    end

    it "goes on working through a logger that raises" do
      logger = double("logger")
      allow(logger).to receive(:debug).and_raise(RuntimeError, "log closed")
      worker_desk = described_class.new(tmux: tmux, workspace: "api", session_name: "api", session_monitor: monitor, store: store,
        transcript: Workspace::TranscriptSummary.new, stopper: stopper, detector: Workspace::AgentDetector.new, process_tree: process_tree,
        ledger: ledger, resume_command: resume_command, prompt_typer: typer, readiness: nil, marker: marker, inbox: -> { inbox },
        delivery_lock: Mutex.new, clock: clock, logger: logger,
        spawn: ->(&block) {
          # A raise ends a real thread there; it doesn't reach the caller.
          begin
            block.call
          rescue
            nil
          end
        })
      allow(store).to receive(:update).and_wrap_original do
        allow(store).to receive(:update).and_call_original
        raise "disk gone"
      end

      expect { worker_desk.session_event("event" => "stop", "pane_id" => "%5", "session_id" => sid) }.not_to raise_error
      worker_desk.session_event("event" => "turn_failed", "pane_id" => "%5", "session_id" => sid, "error" => "server_error",
        "transcript_path" => transcript_path)

      expect(entry["phase"]).to eq("waiting")
    end

    it "ignores events it has no rule for, and a message with no pane" do
      expect(spawn).not_to receive(:call)

      desk.session_event("event" => "notification", "pane_id" => "%5")
      desk.session_event("event" => "stop")
    end
  end

  describe "a sub-agent's event" do
    it "only stamps last_subagent_at on an existing entry" do
      due_entry(phase: "watching")
      event("stop", agent_id: "a1")

      expect(entry).to include("phase" => "watching", "last_subagent_at" => stamp(now[0]))
    end

    it "creates no entry" do
      event("tool_use", agent_id: "a1")

      expect(entry).to be_nil
    end
  end

  describe "turn_failed with a retryable error" do
    it "writes a waiting entry with the real pid, a minute out, no cwd from the payload" do
      event("turn_failed", error: "server_error", transcript_path: transcript_path, cwd: "/moved")

      expect(entry).to include("phase" => "waiting", "session_id" => sid, "attempts" => 0, "stopped" => false, "agent_pid" => 20,
        "agent_started" => started, "failed_at" => stamp(t0), "next_attempt_at" => stamp(t0 + 60), "error" => "server_error",
        "last_turn_uuid" => nil, "defer_since" => nil)
      expect(entry["cwd"]).to be_nil
    end

    it "schedules every retryable kind" do
      %w[server_error overloaded rate_limit unknown].each do |kind|
        store.delete("%5")
        failed(kind)
        expect(entry["phase"]).to eq("waiting")
      end
    end

    it "stores a nil pid when the tree can't be read" do
      tree_broken[0] = true
      failed

      expect(entry).to include("phase" => "waiting", "agent_pid" => nil)
    end

    it "uses the wait for the next attempt, and keeps the count through watching" do
      due_entry(attempts: 3, phase: "watching", last_turn_uuid: "old")
      now[0] = t0 + 500
      failed

      expect(entry).to include("phase" => "waiting", "attempts" => 3, "last_turn_uuid" => nil,
        "next_attempt_at" => stamp(now[0] + 480))
    end

    it "clears stopped on a same-session failure from a replaced agent, moving the queue first" do
      due_entry(stopped: true, phase: "watching", agent_pid: 19)
      held = nil
      allow(monitor).to receive(:agent_pid) {
        held = desk.holding?("%5")
        10
      }
      failed

      expect(entry).to include("phase" => "waiting", "stopped" => false, "agent_pid" => 20)
      expect(rebound).to eq([["%5", 10]])
      expect(held).to be(true)
    end

    it "keeps stopped on a failure from the process it stopped" do
      due_entry(stopped: true, phase: "watching")
      failed

      expect(entry).to include("phase" => "waiting", "stopped" => true)
      expect(rebound).to eq([])
    end

    it "clears stopped on the same pid with another start time" do
      due_entry(stopped: true, phase: "watching", agent_started: "another start")
      failed

      expect(entry["stopped"]).to be(false)
    end

    it "keeps stopped and the stored pid when no agent can be read" do
      due_entry(stopped: true, phase: "watching")
      tree_broken[0] = true
      failed

      expect(entry).to include("phase" => "waiting", "stopped" => true, "agent_pid" => 20, "agent_started" => started)
    end

    it "clears draft_text when a new failure reschedules" do
      due_entry(phase: "watching", draft_text: "ours")
      failed

      expect(entry["draft_text"]).to be_nil
    end

    it "ignores a session id that isn't one, and a missing transcript path" do
      failed(session: "not-a-session")
      failed(path: nil)

      expect(entry).to be_nil
    end

    it "only flags a same-id failure during an attempt" do
      due_entry(phase: "attempting")
      failed("overloaded")

      expect(entry).to include("phase" => "attempting", "failed_during_attempt" => true, "error" => "overloaded",
        "next_attempt_at" => stamp(t0 + 60))
    end

    it "ignores another id during an attempt" do
      due_entry(phase: "attempting")
      before = entry
      failed(session: other_sid)

      expect(entry).to eq(before)
    end

    it "gives up at the twelfth attempt" do
      due_entry(attempts: 12, phase: "watching")
      failed

      expect_gave_up("attempts_exhausted")
      expect(inbox.list.first["body"]).to include("12 recovery attempts")
    end

    it "gives up at the twelfth attempt from waiting too" do
      due_entry(attempts: 12)
      failed

      expect_gave_up("attempts_exhausted")
    end

    it "starts the count at 0 with no entry, so 12 can't be reached without one" do
      failed

      expect(entry).to include("phase" => "waiting", "attempts" => 0)
      expect(inbox.list).to eq([])
    end

    it "starts a new episode for another id, attempts 0" do
      due_entry(attempts: 4, cwd: "/old")
      failed(session: other_sid)

      expect(entry).to include("session_id" => other_sid, "attempts" => 0, "phase" => "waiting")
      expect(entry["cwd"]).to be_nil
    end

    it "starts a new episode for another id after any give-up" do
      due_entry(phase: "gave_up", give_up_reason: "fresh_conversation", attempts: 5)
      failed(session: other_sid)

      expect(entry).to include("session_id" => other_sid, "attempts" => 0, "phase" => "waiting")
      expect(entry).not_to include("give_up_reason")
    end

    describe "on an unconfirmed give-up" do
      def given_up(**fields)
        due_entry(phase: "watching", attempts: 3, last_signal_at: stamp(t0), **fields)
        event("session_end", reason: "prompt_input_exit")
        expect_gave_up("unconfirmed")
      end

      it "reopens with a live agent, keeping the count and the item until a Stop" do
        given_up
        failed
        expect(entry).to include("phase" => "waiting", "attempts" => 3, "give_up_reason" => nil, "stopped" => false,
          "last_signal_at" => nil, "item_open" => true, "agent_pid" => 20, "failed_at" => stamp(now[0]))
        expect(inbox.list.first["state"]).to eq("open")

        event("stop")
        expect(entry).to be_nil
        expect(inbox.list.first["state"]).to eq("done")
      end

      it "stays given up with no live agent" do
        given_up
        gone!
        failed

        expect_gave_up("unconfirmed")
      end

      it "gives up attempts_exhausted at 12, with the one item, and stays there" do
        given_up(attempts: 12)
        failed
        expect_gave_up("attempts_exhausted")

        failed
        expect_gave_up("attempts_exhausted")
      end

      it "holds off on a prompt since the new failure, and types no first message again" do
        given_up
        failed
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }

        facts[:last_user_prompt_at] = now[0] + 1
        expect(answer).to eq(:defer)

        facts[:last_user_prompt_at] = now[0] - 1
        expect(desk.check("%5", entry)).to have_attributes(answer: :go, mode: :restart)
      end

      it "leaves another give-up alone" do
        due_entry(phase: "gave_up", give_up_reason: "attempts_exhausted")
        failed

        expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted")
      end
    end

    {0 => "before any attempt", 3 => "after restarts"}.each do |attempts, name|
      it "words a not_retryable item truly #{name}" do
        due_entry(attempts: attempts)
        failed("billing_error")

        expect(inbox.list.first["body"]).to include("won't try again")
        expect(inbox.list.first["body"]).not_to include("Nothing was stopped")
      end
    end

    it "returns a not_retryable record to waiting with its count, and a Stop resolves the one item" do
      failed("authentication_failed")
      store.update("%5") { |e| e.merge!("attempts" => 2, "stopped" => true) }
      failed

      expect(entry).to include("phase" => "waiting", "attempts" => 2, "stopped" => false, "give_up_reason" => nil)
      expect(desk.holding?("%5")).to be(false)
      expect(inbox.list.map { |item| item["state"] }).to eq(["open"])

      event("stop")
      expect(inbox.list.map { |item| item["state"] }).to eq(["done"])
    end

    it "changes nothing after any other give-up" do
      %w[attempts_exhausted cannot_restart fresh_conversation deferred].each do |reason|
        due_entry(phase: "gave_up", give_up_reason: reason)
        before = entry
        failed
        expect(entry).to eq(before)
      end
      expect(inbox.list).to eq([])
    end
  end

  describe "turn_failed with another error" do
    it "gives up at once with no entry, and restarts nothing" do
      failed("authentication_failed")

      expect_gave_up("not_retryable")
      item = inbox.list.first
      expect(item).to include("type" => "alert", "state" => "open", "dedupe_key" => "agent-recovery:#{sid}")
      expect(item["source"]).to include("kind" => "session")
      expect(item["scope"]).to include("kind" => "workspace", "key" => "api")
      expect(item["body"]).to include("authentication_failed")
      expect(events.last[2]).to include("attempts" => 0, "error" => "authentication_failed", "pane_id" => "%5")

      now[0] = t0 + 3600
      desk.scan
      expect_no_attempt
    end

    it "cancels a scheduled attempt, keeping the count" do
      due_entry(attempts: 3)
      failed("billing_error")
      desk.scan

      expect_gave_up("not_retryable")
      expect(entry["attempts"]).to eq(3)
      expect_no_attempt
    end

    it "is recorded and acted on later during an attempt" do
      due_entry(phase: "attempting")
      failed("billing_error")

      expect(entry).to include("phase" => "attempting", "failed_during_attempt" => true, "error" => "billing_error")
      expect(inbox.list).to eq([])
    end

    it "keeps the original reason on a gave_up record of any other reason" do
      %w[attempts_exhausted cannot_restart fresh_conversation deferred unconfirmed].each do |reason|
        due_entry(phase: "gave_up", give_up_reason: reason)
        before = entry
        failed("billing_error")
        expect(entry).to eq(before)
      end
      expect(inbox.list).to eq([])
    end

    it "replaces another session's entry" do
      due_entry(attempts: 3)
      failed("billing_error", session: other_sid)

      expect(entry).to include("session_id" => other_sid, "attempts" => 0, "phase" => "gave_up")
    end

    it "treats a failure with no kind the same" do
      event("turn_failed", transcript_path: transcript_path)

      expect_gave_up("not_retryable")
      expect(inbox.list.first["body"]).to include("an unnamed error")
    end
  end

  describe "stop" do
    it "only sets turn_completed during an attempt" do
      due_entry(phase: "attempting")
      event("stop")

      expect(entry).to include("phase" => "attempting", "turn_completed" => true)
    end

    it "resets the count" do
      due_entry(attempts: 4, phase: "watching")
      event("stop")

      expect(entry).to be_nil
    end

    it "resolves the item after a give-up" do
      failed("authentication_failed")
      event("stop")

      expect(entry).to be_nil
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "from another session leaves a fresh_conversation item open" do
      due_entry(attempts: 2)
      event("session_start", session: other_sid, source: "startup")
      event("stop", session: other_sid)

      expect_gave_up("fresh_conversation")
      expect(inbox.list.first["state"]).to eq("open")
    end

    it "is no work without a record" do
      expect { event("stop") }.not_to(change { inbox.list })
    end
  end

  describe "user_prompt, tool_start and tool_use" do
    %w[user_prompt tool_start tool_use subagent_start].each do |name|
      it "moves #{name} in waiting to watching, keeping the count, so no attempt is due" do
        due_entry(attempts: 3, defer_since: stamp(t0))
        event(name)
        desk.scan

        expect(entry).to include("phase" => "watching", "attempts" => 3, "defer_since" => nil)
        expect_no_attempt
      end

      it "leaves a stopped entry in waiting on #{name} when no agent is read" do
        due_entry(stopped: true)
        gone!
        event(name)

        expect(entry).to include("phase" => "waiting", "stopped" => true)
      end

      it "clears stopped on #{name} from a replaced agent, moving the queue first" do
        due_entry(stopped: true, agent_pid: 1)
        held = nil
        allow(monitor).to receive(:agent_pid) {
          held = desk.holding?("%5")
          10
        }
        event(name)

        expect(entry).to include("phase" => "watching", "stopped" => false, "agent_pid" => 20)
        expect(rebound).to eq([["%5", 10]])
        expect(held).to be(true)
      end

      it "keeps stopped on a late #{name} from the process it stopped, so the attempts go on" do
        due_entry(stopped: true)
        event(name)

        expect(entry).to include("phase" => "waiting", "stopped" => true)
        expect(rebound).to eq([])
      end
    end

    it "keeps stopped when no pid was ever stored" do
      due_entry(stopped: true, agent_pid: nil, agent_started: nil)
      event("tool_use")

      expect(entry).to include("phase" => "waiting", "stopped" => true)
    end

    it "clears stopped in watching too, and reads the agent outside the update" do
      due_entry(stopped: true, phase: "watching", agent_pid: 19)
      inside = [false]
      in_update = []
      allow(store).to receive(:update).and_wrap_original do |update, *args, &block|
        inside[0] = true
        update.call(*args, &block).tap { inside[0] = false }
      end
      allow(process_tree).to receive(:snapshot) do
        in_update << inside[0]
        Workspace::ProcessTree::Snapshot.new(processes)
      end
      event("tool_use")

      expect(entry).to include("phase" => "watching", "stopped" => false)
      expect(in_update).to eq([false])
    end

    it "sets prompt_seen on a same-id user_prompt during an attempt, and nothing else" do
      due_entry(phase: "attempting")
      event("user_prompt")

      expect(entry).to include("phase" => "attempting", "prompt_seen" => true)
    end

    it "ignores tools during an attempt, and another id's prompt" do
      due_entry(phase: "attempting")
      before = entry
      event("tool_use")
      event("user_prompt", session: other_sid)

      expect(entry).to eq(before)
    end

    it "ignores another id in waiting" do
      due_entry
      event("user_prompt", session: other_sid)

      expect(entry["phase"]).to eq("waiting")
    end
  end

  describe "session_start" do
    it "in attempting, same id: the new agent is known, so stopped and the signal go, and the hold stays" do
      due_entry(phase: "attempting", stopped: true, last_signal_at: stamp(t0))
      before = entry
      event("session_start", source: "resume")

      expect(entry).to eq(before.merge("attempt_session_id" => sid, "stopped" => false, "last_signal_at" => nil))
      expect(desk.holding?("%5")).to be(true)
    end

    it "in attempting, another id, writes attempt_session_id and nothing else" do
      due_entry(phase: "attempting", stopped: true)
      before = entry
      event("session_start", session: other_sid, source: "resume")

      expect(entry).to eq(before.merge("attempt_session_id" => other_sid))
      expect(desk.holding?("%5")).to be(true)
    end

    it "in waiting or watching, same id, stopped: a person resumed it" do
      %w[waiting watching].each do |phase|
        rebound.clear
        due_entry(phase: phase, stopped: true, agent_pid: 20)
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(30, 10, "claude --resume", lstart: "Tue")])
        facts[:agent_pid] = 10
        event("session_start", source: "resume")

        expect(entry).to include("phase" => "watching", "stopped" => false, "agent_pid" => 30, "agent_started" => "Tue")
        expect(rebound).to eq([["%5", 10]])
      end
    end

    it "moves the queue before the hold can end" do
      due_entry(stopped: true)
      held = nil
      allow(monitor).to receive(:agent_pid) {
        held = desk.holding?("%5")
        10
      }
      event("session_start", source: "resume")

      expect(held).to be(true)
    end

    it "in waiting or watching, same id, not stopped, same agent: stays as it was" do
      %w[waiting watching].each do |phase|
        due_entry(phase: phase)
        event("session_start", source: "compact")

        expect(entry).to include("phase" => phase, "agent_pid" => 20)
        expect(rebound).to eq([])
      end
    end

    it "in waiting or watching, same id, no pid stored, no attempts: stores the agent and proves nothing" do
      %w[waiting watching].each do |phase|
        due_entry(phase: phase, attempts: 0, agent_pid: nil, agent_started: nil)
        event("session_start", source: "resume")

        expect(entry).to include("phase" => phase, "agent_pid" => 20)
        expect(rebound).to eq([])
      end
    end

    it "in waiting or watching, same id, pid blanked after attempts: watched, stored and rebound" do
      %w[waiting watching].each do |phase|
        rebound.clear
        due_entry(phase: phase, attempts: 2, agent_pid: nil, agent_started: nil, defer_since: stamp(t0))
        event("session_start", source: "resume")

        expect(entry).to include("phase" => "watching", "agent_pid" => 20, "defer_since" => nil)
        expect(rebound).to eq([["%5", 10]])
        desk.scan
        expect_no_attempt
      end
    end

    it "in waiting, same id, pid blanked and no agent read: stays as it was" do
      due_entry(attempts: 2, agent_pid: nil, agent_started: nil)
      gone!
      event("session_start", source: "resume")

      expect(entry).to include("phase" => "waiting", "agent_pid" => nil)
      expect(rebound).to eq([])
    end

    it "in waiting or watching, same id, another agent: someone else resumed it, so it is watched and never signalled" do
      [["waiting", {pid: 31, lstart: "Wed"}], ["watching", {pid: 20, lstart: "Wed"}]].each do |phase, agent|
        rebound.clear
        due_entry(phase: phase, defer_since: stamp(t0))
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(agent[:pid], 10, "claude", lstart: agent[:lstart])])
        event("session_start", source: "resume")

        expect(entry).to include("phase" => "watching", "stopped" => false, "agent_pid" => agent[:pid],
          "agent_started" => "Wed", "defer_since" => nil)
        expect(rebound).to eq([["%5", 10]])
        desk.scan
        expect_no_attempt
      end
    end

    it "deletes on another id with source clear, whatever the count" do
      due_entry(attempts: 4)
      event("session_start", session: other_sid, source: "clear")

      expect(entry).to be_nil
    end

    %w[waiting watching].each do |phase|
      it "deletes in #{phase} on another id with attempts 0" do
        due_entry(attempts: 0, phase: phase)
        event("session_start", session: other_sid, source: "startup")

        expect(entry).to be_nil
        expect(inbox.list).to eq([])
      end

      it "gives up in #{phase} on another id with attempts above 0" do
        due_entry(attempts: 2, stopped: true, phase: phase)
        event("session_start", session: other_sid, source: "startup")

        expect_gave_up("fresh_conversation")
        expect(desk.holding?("%5")).to be(false)
      end
    end

    it "gives up, not deletes, on another id with an item open" do
      failed("authentication_failed")
      failed
      event("session_start", session: other_sid, source: "startup")

      expect_gave_up("fresh_conversation")
    end

    it "resolves the open item on a clear" do
      failed("authentication_failed")
      failed
      event("session_start", session: other_sid, source: "clear")

      expect(entry).to be_nil
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "changes nothing in gave_up" do
      due_entry(phase: "gave_up", give_up_reason: "deferred")
      before = entry
      event("session_start", session: other_sid, source: "startup")
      event("session_start", source: "resume")

      expect(entry).to eq(before)
    end

    it "from another pane removes a stopped entry of that session" do
      due_entry(stopped: true)
      event("session_start", pane: "%9", source: "resume")

      expect(entry).to be_nil
    end

    it "from another pane resolves the item of a deleted item_open entry" do
      failed("authentication_failed")
      failed
      store.update("%5") { |e| e.merge!("stopped" => true) }
      event("session_start", pane: "%9", source: "resume")

      expect(entry).to be_nil
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "from another pane only flags an entry in attempting" do
      due_entry(phase: "attempting", stopped: true)
      event("session_start", pane: "%9", source: "resume")

      expect(entry).to include("phase" => "attempting", "resumed_elsewhere" => true)
    end

    it "from another pane leaves one that isn't stopped, or is gave_up" do
      due_entry
      event("session_start", pane: "%9", source: "resume")
      expect(entry).not_to be_nil

      due_entry(phase: "gave_up", give_up_reason: "deferred", stopped: true)
      event("session_start", pane: "%9", source: "resume")
      expect(entry).not_to be_nil
    end
  end

  describe "session_end" do
    it "changes nothing in attempting, while stopped, or in gave_up" do
      [{phase: "attempting", stopped: true}, {phase: "waiting", stopped: true}, {phase: "watching", stopped: true},
        {phase: "gave_up", give_up_reason: "deferred"}].each do |fields|
        due_entry(**fields)
        before = entry
        event("session_end", reason: "other")
        expect(entry).to eq(before)
      end
    end

    it "sets stopped after a not_stopped attempt whose signal took effect late" do
      due_entry(last_signal_at: stamp(now[0] - 100))
      event("session_end", reason: "other")

      expect(entry).to include("stopped" => true, "phase" => "waiting")
    end

    it "deletes with no attempts, in waiting with an old signal or none, and in watching" do
      [{last_signal_at: stamp(t0 - 400)}, {}, {phase: "watching", last_signal_at: stamp(t0)}].each do |fields|
        due_entry(attempts: 0, **fields)
        event("session_end", reason: "prompt_input_exit")
        expect(entry).to be_nil
      end
    end

    %w[waiting watching].each do |phase|
      it "gives up unconfirmed after attempts in #{phase}, with one item" do
        due_entry(phase: phase, attempts: 2, stopped: false)
        event("session_end", reason: "prompt_input_exit")

        expect_gave_up("unconfirmed")
        expect(inbox.list.first["state"]).to eq("open")
      end
    end

    it "leaves an open item open after attempts, as the give-up's item" do
      failed("authentication_failed")
      failed
      store.update("%5") { |e| e["attempts"] = 2 }
      event("session_end", reason: "prompt_input_exit")

      expect_gave_up("unconfirmed")
      expect(inbox.list.first["state"]).to eq("open")
    end

    it "deletes on a /clear after attempts: the person moved on" do
      due_entry(attempts: 2)
      event("session_end", reason: "clear")

      expect(entry).to be_nil
      expect(inbox.list).to eq([])
    end

    it "has nothing to give up after a real resumed whose turn completed" do
      due_entry(phase: "watching", attempts: 3)
      event("stop")
      event("session_end", reason: "prompt_input_exit")

      expect(entry).to be_nil
      expect(inbox.list).to eq([])
    end

    it "resolves the open item when a person ended the session" do
      failed("authentication_failed")
      failed
      event("session_end", reason: "prompt_input_exit")

      expect(entry).to be_nil
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "ignores another id" do
      due_entry
      event("session_end", session: other_sid)

      expect(entry).not_to be_nil
    end
  end

  describe "a SessionEnd with no attempts and stopped false" do
    %w[waiting watching].each do |phase|
      it "in #{phase} deletes the entry and resolves its item" do
        failed("authentication_failed")
        failed
        store.update("%5") { |current| current.merge!("phase" => phase, "stopped" => false, "attempts" => 0) }
        event("session_end")

        expect(entry).to be_nil
        expect(inbox.list.first["state"]).to eq("done")
      end
    end
  end

  describe "#scan: after a restart" do
    it "marks the failed panes once, and skips a fresh_conversation record" do
      {"%1" => {"phase" => "waiting"}, "%2" => {"phase" => "attempting"}, "%3" => {"phase" => "watching"},
       "%4" => {"phase" => "gave_up", "give_up_reason" => "deferred"},
       "%6" => {"phase" => "gave_up", "give_up_reason" => "fresh_conversation"}}.each { |id, fields| store.put(id, fields) }
      restarting.push("%2")

      2.times { desk.scan }

      expect(marked).to eq(%w[%1 %2 %4])
    end

    it "retries a pane the monitor doesn't know yet, until it is marked" do
      due_entry(next_attempt_at: stamp(t0 + 9999))
      unknown_panes << "%5"
      desk.scan
      expect(marked).to eq([])

      unknown_panes.clear
      2.times { desk.scan }
      expect(marked).to eq(["%5"])
    end

    it "doesn't mark a pane that failed after the desk started" do
      desk.scan
      due_entry(next_attempt_at: stamp(t0 + 9999))
      desk.scan

      expect(marked).to eq([])
    end

    it "drops a listed pane whose failure ended before the monitor knew it" do
      due_entry(next_attempt_at: stamp(t0 + 9999))
      unknown_panes << "%5"
      desk.scan
      store.delete("%5")
      unknown_panes.clear
      desk.scan

      expect(marked).to eq([])
    end

    it "fires from a store read back by a new desk" do
      due_entry
      desk2 = build_desk(store: Workspace::AgentRecoveryStore.new(path: File.join(dir, "agent-recovery.json"), clock: clock))
      desk2.scan

      expect(attempts.map(&:first)).to eq([:restart])
    end
  end

  describe "#scan: the settle read" do
    before do
      failed
      store.update("%5") { |e| e["next_attempt_at"] = stamp(t0 + 3600) }
    end

    it "reads nothing before 30 seconds" do
      write_transcript(good_line)
      now[0] = t0 + 29
      desk.scan

      expect(entry["last_turn_uuid"]).to be_nil
    end

    it "stores the error's uuid and the ledger's cwd, never the payload's" do
      now[0] = t0 + 30
      desk.scan

      expect(entry).to include("last_turn_uuid" => "u-err", "cwd" => "/work")
    end

    it "sees an error line written after the hook" do
      File.write(transcript_path, "")
      now[0] = t0 + 30
      desk.scan
      expect(entry["last_turn_uuid"]).to be_nil

      write_transcript
      desk.scan
      expect(entry["last_turn_uuid"]).to eq("u-err")
    end

    it "deletes when Claude Code recovered by itself" do
      write_transcript(error_line, good_line)
      now[0] = t0 + 30
      desk.scan

      expect(entry).to be_nil
      expect(inbox.list).to eq([])
    end

    it "gives up unconfirmed when attempts were made" do
      store.update("%5") { |e| e["attempts"] = 2 }
      write_transcript(error_line, good_line)
      now[0] = t0 + 30
      desk.scan

      expect_gave_up("unconfirmed")
      event("stop")
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "gives up unconfirmed when an item is open, with attempts 0" do
      store.update("%5") { |e| e["item_open"] = true }
      write_transcript(error_line, good_line)
      now[0] = t0 + 30
      desk.scan

      expect_gave_up("unconfirmed")
    end

    it "names both failures, and no attempt count, when it gives up with attempts 0" do
      store.delete("%5")
      failed("authentication_failed")
      failed
      write_transcript(error_line, good_line)
      now[0] += 30
      desk.scan

      expect_gave_up("unconfirmed")
      body = inbox.list.first["body"]
      expect(body).to include("authentication_failed", "server_error", "No recovery attempt was made")
      expect(body).not_to include("0 recovery attempts")
    end

    it "doesn't clear on an isMeta record after the error" do
      write_transcript(error_line, JSON.generate("type" => "user", "isMeta" => true, "uuid" => "m"))
      now[0] = t0 + 30
      desk.scan

      expect(entry["last_turn_uuid"]).to eq("u-err")
    end

    it "fills in a nil pid from the intake, which isn't a mismatch" do
      store.update("%5") { |e| e.merge!("agent_pid" => nil, "agent_started" => nil) }
      now[0] = t0 + 30
      desk.scan

      expect(entry).to include("agent_pid" => 20, "agent_started" => started)
    end

    it "clears when the ledger names another session" do
      start_session(other_sid)
      now[0] = t0 + 30
      desk.scan

      expect(entry).to be_nil
    end

    it "gives up unconfirmed on that with attempts made" do
      store.update("%5") { |e| e["attempts"] = 1 }
      start_session(other_sid)
      now[0] = t0 + 30
      desk.scan

      expect_gave_up("unconfirmed")
    end

    it "leaves cwd for later when the ledger has no answer" do
      ledger.record("event" => "session_end", "session_id" => sid)
      now[0] = t0 + 30
      desk.scan

      expect(entry["phase"]).to eq("waiting")
      expect(entry["cwd"]).to be_nil
    end

    it "doesn't write a stale read over a newer failure" do
      now[0] = t0 + 30
      seen = entry
      failed
      desk.send(:settle, "%5", seen)

      expect(entry["last_turn_uuid"]).to be_nil
    end
  end

  describe "#scan: which entries are checked" do
    it "skips an entry not due" do
      due_entry
      now[0] = t0 + 59
      desk.scan
      expect_no_attempt
    end

    it "skips a pane a restart holds" do
      due_entry
      restarting << "%5"
      desk.scan
      expect_no_attempt
    end

    it "skips watching, and leaves a healthy idle agent alone" do
      due_entry(phase: "watching", next_attempt_at: stamp(t0))
      now[0] = t0 + 86_400
      desk.scan
      expect_no_attempt
    end

    it "starts no attempt when a hook changed the entry during the screen wait" do
      due_entry
      allow(desk).to receive(:check).and_wrap_original do |check, *args|
        result = check.call(*args)
        event("user_prompt")
        result
      end
      desk.scan

      expect_no_attempt
      expect(entry["phase"]).to eq("watching")
    end

    it "defers when the check raises, so the limit ends it" do
      due_entry
      allow(desk).to receive(:check).and_raise(RuntimeError, "boom")
      desk.scan
      expect(entry["defer_since"]).not_to be_nil

      now[0] += 1800
      desk.scan
      expect_gave_up("deferred")
    end

    it "keeps going past a pane that raises" do
      due_entry
      store.put("%1", {"phase" => "waiting", "stopped" => false, "failed_at" => "bad"})
      allow(store).to receive(:get).and_call_original
      allow(store).to receive(:get).with("%1").and_raise(RuntimeError, "boom")
      desk.scan

      expect(attempts.size).to eq(1)
    end
  end

  describe "#scan: an attempt with no live claim" do
    it "goes back to waiting with its next wait, the pid stored, and an interrupted line" do
      due_entry(phase: "attempting", attempts: 2, stopped: true, agent_pid: 1, attempt_session_id: sid, prompt_seen: true)
      marker.mark(sid)
      desk.scan

      expect(entry).to include("phase" => "waiting", "stopped" => false, "agent_pid" => 20, "attempts" => 2,
        "next_attempt_at" => stamp(now[0] + 240), "last_turn_uuid" => nil)
      expect(entry).not_to include("prompt_seen", "attempt_session_id")
      expect(marker.marked?(sid)).to be(true)
      expect(events.map(&:first)).to eq(["agent_recovery_attempt"])
      expect(events[0][2]).to eq("attempt" => 2, "session_id" => sid, "pane_id" => "%5", "error" => "server_error",
        "mode" => "restart", "outcome" => "interrupted")
    end

    it "names a first attempt typed" do
      due_entry(phase: "attempting", attempts: 1)
      desk.scan

      expect(events[0][2]).to include("mode" => "typed")
    end

    it "keeps stopped with no agent left and no new agent reported, so the next attempt is resume_only" do
      due_entry(phase: "attempting", attempts: 2, stopped: true, last_signal_at: stamp(t0 + 60))
      marker.mark(sid)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(marker.marked?(sid)).to be(false)
      expect(entry).to include("phase" => "waiting", "stopped" => true)
      now[0] += 300
      desk.scan
      expect(attempts.first[2]).to have_attributes(answer: :go, mode: :resume_only)
    end

    it "gives up with nothing typed when the ledger shows a new agent came and went while the daemon was down" do
      due_entry(phase: "attempting", attempts: 2, stopped: true, last_signal_at: stamp(t0 + 60))
      now[0] += 5
      start_session(sid)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan
      expect(entry).to include("phase" => "waiting", "stopped" => true)

      now[0] += 300
      desk.scan

      expect_gave_up("unconfirmed")
      expect_no_attempt
      expect(tmux.sent_keys).to eq([])
    end

    it "defers a resume on a ledger that can't be read" do
      due_entry(stopped: true, last_signal_at: stamp(t0 + 60))
      gone!
      FileUtils.rm_f(File.join(dir, "ledger.jsonl"))
      FileUtils.mkdir_p(File.join(dir, "ledger.jsonl"))
      desk.scan

      expect_no_attempt
      expect(entry["phase"]).to eq("waiting")
      expect(entry["defer_since"]).not_to be_nil
    end

    describe "a closed pane" do
      def closed! = tmux.details = [{id: "%9", window: 0, index: 2, pid: 99, command: "zsh"}]

      def ride_out_the_defer_limit
        now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
        desk.scan
        expect(entry).to include("phase" => "waiting")
        now[0] += described_class::DEFER_LIMIT
        desk.scan
      end

      it "finishes a restart, then ends in one give-up with nothing sent" do
        due_entry(phase: "attempting", attempts: 3, stopped: true)
        marker.mark(sid)
        closed!
        desk.scan

        expect(entry).to include("phase" => "waiting", "stopped" => true, "attempts" => 3)
        expect(marker.marked?(sid)).to be(true)
        expect(events.map { |_, _, data| data["outcome"] }).to eq(["interrupted"])

        ride_out_the_defer_limit
        expect_gave_up("deferred")
        desk.scan
        expect(events.size).to eq(2)
        expect_no_attempt
        expect(tmux.sent_keys).to eq([])
      end

      it "gives up a typed attempt at once" do
        due_entry(phase: "attempting", attempts: 1)
        closed!
        desk.scan

        expect_gave_up("unconfirmed")
        expect(entry["stopped"]).to be(false)
        expect_no_attempt
      end

      it "says nothing was done in the 30 minutes, which holds after an attempt that stopped the agent" do
        due_entry(attempts: 3, stopped: true)
        closed!
        desk.scan
        now[0] += described_class::DEFER_LIMIT
        desk.scan

        expect(inbox.list.first["body"]).to include("Nothing was stopped or typed in those 30 minutes")
      end

      it "leaves stopped false and the marker alone: the read may be wrong" do
        due_entry(phase: "attempting", attempts: 3, stopped: false)
        marker.mark(sid)
        tmux.details = []
        tmux.gone = true
        desk.scan

        expect(entry).to include("stopped" => false)
        expect(marker.marked?(sid)).to be(true)
        expect_gave_up("unconfirmed")
        expect_no_attempt
        expect(tmux.sent_keys).to eq([])
      end

      it "finishes when the session went with its last pane" do
        due_entry(phase: "attempting", attempts: 3, stopped: true)
        tmux.details = []
        tmux.gone = true
        desk.scan

        expect(entry).to include("phase" => "waiting", "stopped" => true)
        ride_out_the_defer_limit
        expect_gave_up("deferred")
        expect_no_attempt
      end

      it "reads a turn stop recorded before the pane closed" do
        due_entry(phase: "attempting", attempts: 3, turn_completed: true)
        closed!
        desk.scan

        expect(entry).to be_nil
      end
    end

    it "keeps stopped false after a typed attempt whose agent left, so nothing is typed into the shell" do
      due_entry(phase: "attempting", attempts: 1, stopped: false)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(entry).to include("stopped" => false, "attempts" => 1)
      expect_gave_up("unconfirmed")
      expect_no_attempt
      expect(tmux.sent_keys).to eq([])
    end

    it "gives up on a retryable failure recorded before the agent left" do
      due_entry(phase: "attempting", attempts: 3, stopped: false, failed_during_attempt: true)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(entry).to include("stopped" => false)
      expect_gave_up("unconfirmed")
    end

    it "still reschedules a failure recorded before a restart whose signal has no agent back yet" do
      due_entry(phase: "attempting", attempts: 3, stopped: true, failed_during_attempt: true)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(entry).to include("phase" => "waiting", "stopped" => true)
    end

    it "doesn't resume an interrupted attempt whose new agent reported and left" do
      due_entry(phase: "attempting", attempts: 3, stopped: false, agent_pid: 21, last_signal_at: nil)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(entry).to include("stopped" => false)
      expect_gave_up("unconfirmed")
      expect_no_attempt
      expect(tmux.sent_keys).to eq([])
    end

    it "gives up with fresh_conversation when the ledger names another session" do
      due_entry(phase: "attempting", attempts: 2)
      start_session(other_sid)
      desk.scan

      expect_gave_up("fresh_conversation")
    end

    it "gives up at 12" do
      due_entry(phase: "attempting", attempts: 12)
      desk.scan

      expect_gave_up("attempts_exhausted")
    end

    it "deletes an entry resumed in another pane, and resolves its item" do
      failed("authentication_failed")
      failed
      store.update("%5") { |e| e.merge!("phase" => "attempting", "attempts" => 2, "resumed_elsewhere" => true) }
      desk.scan

      expect(entry).to be_nil
      expect(events.last[2]).to include("outcome" => "interrupted")
      expect(inbox.list.first["state"]).to eq("done")
    end

    it "decides nothing on a ledger that can't be read" do
      due_entry(phase: "attempting")
      FileUtils.rm_f(File.join(dir, "ledger.jsonl"))
      FileUtils.mkdir_p(File.join(dir, "ledger.jsonl"))
      desk.scan

      expect(entry["phase"]).to eq("attempting")
      expect(events).to eq([])
    end

    it "honours a stop and a failure recorded before the restart" do
      due_entry(phase: "attempting", attempts: 3, turn_completed: true)
      desk.scan
      expect(entry).to be_nil

      due_entry(phase: "attempting", attempts: 3, failed_during_attempt: true, error: "billing_error")
      desk.scan
      expect_gave_up("not_retryable")
    end

    it "leaves a claimed attempt alone" do
      due_entry(phase: "attempting")
      restarting << "%5"
      desk.scan

      expect(entry["phase"]).to eq("attempting")
      expect(events).to eq([])
    end

    it "decides nothing on a tree or a tmux that can't be read" do
      due_entry(phase: "attempting")
      tree_broken[0] = true
      desk.scan
      expect(entry["phase"]).to eq("attempting")
      expect(events).to eq([])

      tree_broken[0] = false
      tmux.details = []
      desk.scan
      expect(entry["phase"]).to eq("attempting")
    end
  end

  describe "#check with an agent" do
    it "answers a restart :go with the command when everything holds" do
      due_entry

      result = desk.check("%5", entry)
      expect(result).to have_attributes(answer: :go, mode: :restart, command: "cd -- /work && claude --resume #{sid}")
      expect(signals).to eq([])
    end

    {
      "a wait" => -> { typing[:state] = "waiting" },
      "a question tool" => -> { typing[:open_tools] = ["AskUserQuestion"] },
      "a draft in the input line" => -> { tmux.screen = "────────\n❯ half a thought\n" },
      "a dialog in place of the prompt" => -> { tmux.screen = "Allow this tool?\n" },
      "Retrying in on screen" => -> { tmux.screen = "Retrying in 5s · attempt 2\n❯ \n" },
      "esc to interrupt on screen" => -> { tmux.screen = "esc to interrupt\n❯ \n" },
      "a prompt newer than the failure" => -> { facts[:last_user_prompt_at] = t0 + 10 },
      "a pane not scanned yet" => -> { allow(monitor).to receive(:delivery_facts).and_return(nil) },
      "sub-agents that can't be read" => -> { subagents[0] = nil },
      "a sub-agent recently heard" => -> {
        subagents[0] = 1
        store.update("%5") { |e| e["last_subagent_at"] = stamp(now[0] - 300) }
      },
      "stopped true" => -> { store.update("%5") { |e| e["stopped"] = true } },
      "no cwd yet" => -> {
        store.update("%5") { |e| e["cwd"] = nil }
        start_session(sid, cwd: nil)
      },
      "a config that can't be read" => -> { allow(report).to receive(:show).and_raise(Workspace::Error, "no config") },
      "the ledger with no open session" => -> { ledger.record("event" => "session_end", "session_id" => sid) },
      "a transcript that can't be read" => -> { File.delete(transcript_path) },
      "pane start commands that can't be read" => -> { tmux.start_commands = [] },
      "a process table that can't be read" => -> { tree_broken[0] = true },
      "a tmux that lists nothing" => -> { tmux.details = [] },
      "a pane tmux no longer has" => -> { tmux.details = [{id: "%9", window: 0, index: 2, pid: 99, command: "zsh"}] }
    }.each do |name, breaks|
      it "defers, and starts no attempt, on #{name}" do
        due_entry
        instance_exec(&breaks)

        expect(answer).to eq(:defer)
        desk.scan
        expect_no_attempt
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
        expect(entry["defer_since"]).not_to be_nil
      end
    end

    it "defers on a ledger that raises, which isn't the same as no session open" do
      due_entry
      FileUtils.rm_f(File.join(dir, "ledger.jsonl"))
      FileUtils.mkdir_p(File.join(dir, "ledger.jsonl"))

      expect(answer).to eq(:defer)
      expect { ledger.read_open_record(pane_id: "%5", tmux_server: "77") }.to raise_error(SystemCallError)
    end

    it "defers on a screen that keeps changing" do
      due_entry
      frames = (1..4).map { |n| "frame #{n}\n❯ \n" }
      tmux.scripted = -> { frames.shift || "last\n❯ \n" }

      expect(answer).to eq(:defer)
    end

    it "stores the live pid when none is stored, and defers" do
      due_entry(agent_pid: nil, agent_started: nil)

      expect(answer).to eq(:defer)
      expect(entry).to include("agent_pid" => 20, "agent_started" => started)
      expect(answer).to eq(:go)
    end

    it "doesn't defer on a prompt from before the failure" do
      due_entry
      facts[:last_user_prompt_at] = t0 - 1

      expect(answer).to eq(:go)
    end

    it "takes no prompt time, as after a restart, for no prompt" do
      due_entry
      facts[:last_user_prompt_at] = nil

      expect(answer).to eq(:go)
    end

    it "defers on a prompt the monitor holds and the worker hasn't reached, even with the transcript moved on" do
      due_entry
      facts[:last_user_prompt_at] = t0 + 30
      write_transcript(error_line, good_line)
      desk.scan

      expect_no_attempt
      expect(entry["phase"]).to eq("waiting")
      expect(inbox.list).to eq([])
    end

    it "doesn't defer on an open ask" do
      due_entry
      File.write(File.join(dir, "asks.json"), JSON.generate([{"id" => "a1", "state" => "open"}]))

      expect(answer).to eq(:go)
    end

    it "stops counting a silent sub-agent after 10 minutes, from the last event" do
      due_entry(last_subagent_at: stamp(t0 + 100))
      subagents[0] = 2

      now[0] = t0 + 699
      expect(answer).to eq(:defer)
      now[0] = t0 + 701
      expect(answer).to eq(:go)
    end

    it "counts those 10 minutes from the failure with no event" do
      due_entry
      subagents[0] = 1

      now[0] = t0 + 590
      expect(answer).to eq(:defer)
      now[0] = t0 + 601
      expect(answer).to eq(:go)
    end

    it "keeps deferring for a sub-agent that goes on sending events" do
      due_entry
      subagents[0] = 1
      now[0] = t0 + 700
      event("tool_use", agent_id: "a1")

      expect(answer).to eq(:defer)
    end

    it "accepts our own text left in the input line" do
      due_entry(draft_text: "An API error stopped your last turn")
      tmux.screen = "────────\n❯ An API error stopped your last turn\n"

      expect(answer).to eq(:go)
    end

    it "defers on a person's draft that only starts with our text" do
      due_entry(draft_text: "An API error stopped your last turn")
      tmux.screen = "────────\n❯ An API error stopped your last turn and I want more\n"

      expect(answer).to eq(:defer)
    end

    it "defers on a paste placeholder, which can't be told from a person's paste" do
      due_entry(draft_text: "An API error stopped your last turn")
      tmux.screen = "────────\n❯ [Pasted text #1 +40 lines]\n"

      expect(answer).to eq(:defer)
    end

    it "accepts our own text wrapped over two lines" do
      due_entry(draft_text: "An API error stopped your last turn")
      tmux.screen = "────────\n❯ An API error stopped\n  your last turn\n────────\n  status\n"

      expect(answer).to eq(:go)
    end

    it "defers on a draft that isn't our text" do
      due_entry(draft_text: "An API error stopped your last turn")
      tmux.screen = "────────\n❯ something a person wrote\n"

      expect(answer).to eq(:defer)
    end

    describe "a typed :go, with attempts 0" do
      before { due_entry(attempts: 0) }

      it "answers :go in a pane that can't be restarted" do
        tmux.start_commands = [{window: 0, index: 1, id: "%5", start_command: "claude"}]

        expect(desk.check("%5", entry)).to have_attributes(answer: :go, mode: :typed, command: nil)
      end

      it "answers :go under a non-shell parent" do
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "node runner"), proc_entry(20, 15, "claude")])

        expect(answer).to eq(:go)
      end

      it "answers :go with no cwd and with a nil resume command" do
        store.update("%5") { |e| e["cwd"] = nil }
        allow(report).to receive(:show).and_raise(Workspace::Error, "no config")

        expect(answer).to eq(:go)
      end

      it "starts the typed attempt from the scan" do
        desk.scan

        expect(attempts.map(&:first)).to eq([:typed])
      end
    end

    describe "an agent whose group doesn't hold the terminal" do
      {"a shell that took it back" => ->(pid) { (pid == 20) ? [20, 10] : [10, 10] },
       "an agent's group that can't be read" => ->(pid) { (pid == 20) ? nil : [10, 10] },
       "a terminal that can't be read" => ->(pid) { (pid == 20) ? [20, 20] : nil },
       "a read that raises" => ->(_pid) { raise Errno::EAGAIN }}.each do |name, read|
        context "with #{name}" do
          let(:group_read) { read }

          [0, 1].each do |count|
            it "defers with attempts at #{count}, with a prompt on the screen" do
              due_entry(attempts: count)

              expect(answer).to eq(:defer)
              desk.scan
              expect_no_attempt
              expect(entry["defer_since"]).not_to be_nil
            end
          end
        end
      end

      it "answers :go again once the agent's group has the terminal back" do
        due_entry(attempts: 0)
        foreground = [false]
        allow(stopper).to receive(:foreground?).with(pid: 20, pane_pid: 10) { foreground[0] }

        expect(answer).to eq(:defer)
        foreground[0] = true
        expect(answer).to eq(:go)
      end

      it "answers :go for a wrapper's agent in the group that holds the terminal" do
        due_entry(attempts: 0)
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "/bin/sh /Users/z/bin/claude-dev"),
          proc_entry(20, 15, "claude")])
        allow(stopper).to receive(:foreground?).and_call_original
        group_ids.replace([15, 15])

        expect(answer).to eq(:go)
        expect(stopper).to have_received(:foreground?).with(pid: 20, pane_pid: 10)
      end
    end

    it "gives up cannot_restart once attempts are above 0, for a start command" do
      due_entry
      tmux.start_commands = [{window: 0, index: 1, id: "%5", start_command: "claude"}]
      desk.scan

      expect_gave_up("cannot_restart")
      expect_no_attempt
    end

    it "gives up cannot_restart under a non-shell parent" do
      due_entry
      processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "node runner"), proc_entry(20, 15, "claude")])
      desk.scan

      expect_gave_up("cannot_restart")
    end

    describe ":clear" do
      {
        "a last record that isn't the stored error" => -> { write_transcript(error_line, good_line) },
        "another error record" => -> { write_transcript(error_line("u-later")) },
        "a changed pid" => -> { processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(21, 10, "claude")]) },
        "a changed start time" => -> { processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(20, 10, "claude", lstart: "Thu")]) },
        "the ledger naming another session" => -> { start_session(other_sid) }
      }.each do |name, breaks|
        it "deletes on #{name} with attempts 0" do
          due_entry(attempts: 0)
          instance_exec(&breaks)
          desk.scan

          expect(entry).to be_nil
          expect(inbox.list).to eq([])
          expect_no_attempt
        end

        it "gives up unconfirmed on #{name} with attempts above 0, and a later stop resolves it" do
          due_entry(attempts: 2)
          instance_exec(&breaks)
          desk.scan

          expect_gave_up("unconfirmed")
          expect_no_attempt
          event("stop")
          expect(entry).to be_nil
          expect(inbox.list.first["state"]).to eq("done")
        end
      end
    end
  end

  describe "#check with no agent" do
    before do
      due_entry(stopped: true)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
    end

    it "answers resume_only with the ledger at nil and a last record that isn't the error" do
      write_transcript(error_line, JSON.generate("type" => "user", "uuid" => "ours"))

      expect(desk.check("%5", entry)).to have_attributes(answer: :go, mode: :resume_only, command: "cd -- /work && claude --resume #{sid}")
    end

    it "answers resume_only over a ledger whose start is older than the signal, which is every real resume" do
      store.update("%5") { |e| e["last_signal_at"] = stamp(t0 + 30) }
      expect(ledger.last_start_at(sid)).not_to be_nil

      expect(desk.check("%5", entry)).to have_attributes(answer: :go, mode: :resume_only)
    end

    it "answers :clear over a ledger whose start is later than the signal" do
      store.update("%5") { |e| e["last_signal_at"] = stamp(t0 - 30) }

      expect(answer).to eq(:clear)
    end

    it "defers on a stored session id that isn't one" do
      store.update("%5") { |e| e["session_id"] = "not-a-session" }
      allow(resume_command).to receive(:call).and_return("cd -- /work && claude --resume x")

      expect(answer).to eq(:defer)
    end

    it "defers while the shell doesn't hold the terminal" do
      group_ids.replace([10, 15])

      expect(answer).to eq(:defer)
    end

    it "defers on a screen that isn't quiet" do
      frames = ["a\n", "b\n"]
      tmux.scripted = -> { frames.shift || "c\n" }

      expect(answer).to eq(:defer)
    end

    it "defers with no cwd, or no resume command" do
      store.update("%5") { |e| e["cwd"] = nil }
      expect(answer).to eq(:defer)

      store.update("%5") { |e| e["cwd"] = "/work" }
      allow(report).to receive(:show).and_raise(Workspace::Error, "no config")
      expect(answer).to eq(:defer)
    end

    it "gives up cannot_restart when the transcript is gone" do
      File.delete(transcript_path)
      desk.scan

      expect_gave_up("cannot_restart")
    end

    it "with stopped false defers on a recent signal, a late SessionEnd may be coming" do
      due_entry(stopped: false, last_signal_at: stamp(t0 - 100), cwd: "/work")

      expect(answer).to eq(:defer)
    end

    it "with stopped false clears: the agent ended and we didn't stop it" do
      due_entry(stopped: false, attempts: 0)
      desk.scan

      expect(entry).to be_nil
    end

    it "with stopped false gives up unconfirmed after attempts" do
      due_entry(stopped: false, attempts: 3, last_signal_at: stamp(t0 - 400))
      desk.scan

      expect_gave_up("unconfirmed")
    end
  end

  describe "deferring" do
    before do
      due_entry
      typing[:state] = "waiting"
    end

    it "costs no attempt and gives up after 30 minutes of it, with nothing stopped" do
      desk.scan
      expect(entry["defer_since"]).not_to be_nil
      first = entry["defer_since"]

      now[0] += 1799
      desk.scan
      expect(entry).to include("phase" => "waiting", "attempts" => 1, "defer_since" => first)

      now[0] += 1
      desk.scan
      expect_gave_up("deferred")
      expect(entry["attempts"]).to eq(1)
      expect_no_attempt
    end

    it "keeps counting through a :go, so a scan's :go and an attempt's :defer can't loop for good" do
      desk.scan
      first = entry["defer_since"]
      typing[:state] = "idle"
      desk.scan

      expect(attempts.size).to eq(1)
      expect(entry["defer_since"]).to eq(first)
    end
  end

  describe "giving up" do
    it "leaves one inbox item however often it happens" do
      2.times do
        failed("authentication_failed")
      end
      failed("billing_error")

      expect(inbox.list.size).to eq(1)
    end

    it "reopens an item a person closed" do
      failed("authentication_failed")
      inbox.transition_by_key("agent-recovery:#{sid}", to: "done")
      failed("billing_error")

      expect(inbox.list.map { |item| item["state"] }).to eq(["open"])
    end

    it "resolves the item when a Stop came between the record and the item" do
      allow(inbox).to receive(:upsert).and_wrap_original do |upsert, *args, **opts|
        store.delete("%5")
        upsert.call(*args, **opts)
      end
      failed("authentication_failed")

      expect(inbox.list.first["state"]).to eq("done")
    end

    it "resolves the item when another session took the entry meanwhile" do
      allow(inbox).to receive(:upsert).and_wrap_original do |upsert, *args, **opts|
        store.update("%5") { |e| e["session_id"] = other_sid }
        upsert.call(*args, **opts)
      end
      failed("authentication_failed")

      expect(inbox.list.first["state"]).to eq("done")
    end

    it "keeps the record when the inbox can't be written" do
      allow(inbox).to receive(:upsert).and_raise(Workspace::Error, "full")
      failed("authentication_failed")

      expect(entry["phase"]).to eq("gave_up")
    end

    it "writes ids and kinds to the event log, never free text" do
      failed("authentication_failed")

      expect(events.last[2].keys).to contain_exactly("pane_id", "session_id", "attempts", "error", "reason")
    end

    %w[attempts_exhausted not_retryable cannot_restart fresh_conversation deferred unconfirmed].each do |reason|
      it "stops holding the queue for #{reason}" do
        due_entry(phase: "attempting", stopped: true, last_signal_at: stamp(now[0]))
        expect(desk.holding?("%5")).to be(true)
        store.update("%5") { |e| e["phase"] = "waiting" }
        desk.send(:give_up, "%5", entry, reason)

        expect(desk.holding?("%5")).to be(false)
        expect(inbox.list.first["body"]).not_to be_empty
      end
    end
  end

  describe "through the prompt queue" do
    let(:queue_store) { Workspace::PromptQueueStore.new(path: File.join(dir, "prompt-queue.json"), clock: clock) }
    let(:queue) do
      Workspace::PromptQueueDesk.new(tmux: tmux, session_name: "api", workspace: "api", session_monitor: monitor, store: queue_store,
        delivery_lock: Mutex.new, recovering: ->(id) { desk.holding?(id) }, event_log: event_log, typer: typer, clock: clock,
        sleeper: ->(seconds) { now[0] += seconds }, spawn: ->(&block) { block.call })
    end

    before do
      facts.merge!(session_id: other_sid, state: "done", agent_pid: 20)
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "zsh"}]
    end

    def expect_queue_free
      expect(desk.holding?("%5")).to be(false)
      facts[:fresh_since] = now[0]
      typing[:state] = "idle"
      expect(queue.deliver_next("%5")).to include(outcome: :delivered)
      expect(tmux.sent_keys.map { |k| k[:text] }).to include("held prompt")

      facts.merge!(state: "working", fresh_since: nil)
      expect(queue.send_prompt("pane_id" => "%5", "text" => "next prompt")).to include("queued" => true)
      queue.session_event("pane_id" => "%5", "event" => "session_end", "session_id" => other_sid)
      expect(queue_store.entries).to eq([])
    end

    it "frees the queue after an attempt that found a fresh agent" do
      due_entry(phase: "attempting", attempts: 2, stopped: true, last_signal_at: stamp(now[0]))
      expect(queue.send_prompt("pane_id" => "%5", "text" => "held prompt")).to include("queued" => true)
      start_session(other_sid)
      desk.scan

      expect_gave_up("fresh_conversation")
      expect_queue_free
    end

    it "frees the queue after 12 attempts ending at a shell" do
      due_entry(phase: "attempting", attempts: 12, stopped: true, last_signal_at: stamp(now[0]))
      expect(queue.send_prompt("pane_id" => "%5", "text" => "held prompt")).to include("queued" => true)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect_gave_up("attempts_exhausted")
      expect(entry["stopped"]).to be(true)
      processes.push(proc_entry(20, 10, "claude"))
      expect_queue_free
    end

    it "frees the queue when a fresh agent arrives in waiting with stopped true" do
      due_entry(attempts: 2, stopped: true, last_signal_at: stamp(now[0]))
      expect(queue.send_prompt("pane_id" => "%5", "text" => "held prompt")).to include("queued" => true)
      event("session_start", session: other_sid, source: "startup")

      expect_gave_up("fresh_conversation")
      expect_queue_free
    end
  end

  shared_context "a real attempt" do
    subject(:desk) { build_desk(stub_attempts: false) }

    let(:later) { "Mon Oct 26 11:00:00 2026" }

    def agent_exits
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      event("session_end")
    end

    def agent_appears(pid: 21)
      processes.push(proc_entry(pid, 10, "claude --resume", lstart: later))
      tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "claude"}]
    end

    def agent_resumes(session: sid, pid: 21, answers: true)
      agent_appears(pid: pid)
      start_session(session)
      event("session_start", session: session, source: "resume")
      hooks[:enter] ||= -> { event("user_prompt", session: session) } if answers
    end

    def healthy_run
      hooks[:signal] = -> { agent_exits }
      hooks[:deliver] = -> { agent_resumes }
    end

    def texts = tmux.sent_keys.map { |key| key[:text] }

    def resumes = texts.grep(/--resume/)

    def messages = texts.grep(message)

    def lines = events.select { |type, _, _| type == "agent_recovery_attempt" }.map(&:last)

    def outcomes = lines.map { |line| line["outcome"] }

    def expect_rescheduled(attempts)
      expect(entry).to include("phase" => "waiting", "attempts" => attempts, "last_turn_uuid" => nil, "defer_since" => nil,
        "next_attempt_at" => stamp(now[0] + Workspace::AgentRecoveryStore.wait_before(attempts + 1)))
      expect(entry).not_to include("attempt_session_id", "prompt_seen")
    end

    def clear_twice_then(&block)
      reads = 0
      allow(stopper).to receive(:pane_clear?).and_wrap_original do |original, **args|
        reads += 1
        block.call if reads == 2
        original.call(**args)
      end
    end
  end

  describe "a restart attempt" do
    include_context "a real attempt"

    let(:message) { /\AAn API error stopped your last turn \(server_error\), so workspace restarted Claude Code/ }

    describe "the steps in order" do
      it "writes the marker and stopped before the signal, and clears the marker after" do
        due_entry(defer_since: stamp(t0))
        seen = {}
        hooks[:signal] = lambda {
          seen[:marked] = marker.marked?(sid)
          seen[:entry] = entry
          seen[:typed_before_signal] = texts.dup
          agent_exits
        }
        hooks[:deliver] = lambda {
          seen[:signals_before_resume] = signals.size
          seen[:typed_before_resume] = texts.size
          agent_resumes
        }
        desk.scan

        expect(seen[:typed_before_signal]).to eq([])
        expect(seen[:signals_before_resume]).to eq(1)
        expect(seen[:typed_before_resume]).to eq(1)
        expect(texts.index { |text| text.include?("--resume") }).to be < texts.index { |text| text.match?(message) }

        expect(seen[:marked]).to be(true)
        expect(seen[:entry]).to include("phase" => "attempting", "attempts" => 2, "stopped" => true,
          "attempt_session_id" => nil, "last_signal_at" => stamp(t0 + 65), "defer_since" => nil)
        expect(marker.marked?(sid)).to be(false)
        expect(texts.first).to eq("cd -- /work && claude --resume #{sid}")
        expect(messages.size).to eq(1)
        expect(entry).to include("phase" => "watching", "stopped" => false, "last_signal_at" => nil, "agent_pid" => 21,
          "agent_started" => later, "attempts" => 2)
        expect(lines).to eq([{"attempt" => 2, "session_id" => sid, "pane_id" => "%5", "error" => "server_error",
                              "mode" => "restart", "outcome" => "resumed"}])
      end

      it "keeps user text out of the event lines" do
        due_entry
        healthy_run
        desk.scan

        expect(events.to_s).not_to include("Continue where")
      end

      it "signals the real agent in an unwrapped pane, never the pane's pid" do
        due_entry
        healthy_run
        desk.scan

        expect(signals).to eq([["INT", 20]])
      end

      it "signals the real agent in a wrapper pane" do
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(15, 10, "/bin/sh /Users/z/bin/claude-dev"),
          proc_entry(20, 15, "claude --resume")])
        due_entry
        hooks[:signal] = lambda {
          processes.reject! { |process| process[:pid] == 15 }
          agent_exits
        }
        hooks[:deliver] = -> { agent_resumes }
        desk.scan

        expect(signals).to eq([["INT", 20]])
        expect(outcomes).to eq(["resumed"])
      end

      it "goes from a failure through attempts to a stop, entry gone, lines in order" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        desk.scan
        expect(outcomes).to eq(["not_ready"])
        expect(entry["stopped"]).to be(true)

        hooks[:deliver] = -> { agent_resumes }
        now[0] += 240
        desk.scan
        expect(outcomes).to eq(%w[not_ready resumed])

        event("stop")
        expect(entry).to be_nil
        expect(signals.size).to eq(1)
        base = {"session_id" => sid, "pane_id" => "%5", "error" => "server_error", "mode" => "restart"}
        expect(events).to eq([
          ["agent_recovery_attempt", "api", base.merge("attempt" => 2, "outcome" => "not_ready")],
          ["agent_recovery_attempt", "api", base.merge("attempt" => 3, "outcome" => "resumed")]
        ])
      end

      it "registers no binding" do
        expect(Workspace::PaneBindings).not_to receive(:new)
        due_entry
        healthy_run
        desk.scan
      end
    end

    describe "the prompt wait after the second message" do
      let(:rule_prompt) { "────────\n❯ " }

      def resume_swallows_enter
        hooks[:signal] = -> { agent_exits }
        hooks[:deliver] = -> { agent_resumes(answers: false) }
      end

      def agent_leaves(pid)
        processes.reject! { |process| process[:pid] == pid }
        ledger.record("event" => "session_end", "session_id" => sid)
        gone!
      end

      def next_attempt
        now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
        desk.scan
      end

      it "is no_response with the screen changing and no hook, never watching" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = -> { tmux.screen = "#{empty_prompt}status line redrawn\n" }
        desk.scan

        expect(outcomes).to eq(["no_response"])
        expect(sleeps.count(described_class::POLL_INTERVAL)).to be >= described_class::PROMPT_WAIT
        expect(entry).to include("stopped" => false, "agent_pid" => 21, "last_signal_at" => nil,
          "draft_text" => a_string_matching(message))
        expect_rescheduled(2)
      end

      it "gives up on a person's SessionEnd after no_response, with one item and nothing typed into the shell" do
        due_entry
        resume_swallows_enter
        desk.scan
        expect(outcomes).to eq(["no_response"])
        hooks[:deliver] = nil

        now[0] += 60
        expect(desk.holding?("%5")).to be(false)
        agent_leaves(21)
        event("session_end")
        desk.scan

        expect_gave_up("unconfirmed")
        expect(entry["stopped"]).to be(false)
        expect(resumes.size).to eq(1)
        expect(signals).to eq([["INT", 20]])
      end

      it "opens with prompt_seen false, a restart and a resume_only alike" do
        due_entry(prompt_seen: true)
        seen = {}
        hooks[:signal] = lambda {
          seen[:restart] = entry["prompt_seen"]
          agent_exits
        }
        hooks[:deliver] = -> { agent_resumes(answers: false) }
        desk.scan
        expect(seen[:restart]).to be(false)

        agent_leaves(21)
        store.update("%5") { |current| current.merge!("stopped" => true, "prompt_seen" => true) }
        hooks[:deliver] = lambda {
          seen[:resume_only] = entry["prompt_seen"]
          agent_resumes(pid: 22, answers: false)
        }
        next_attempt
        expect(seen[:resume_only]).to be(false)
      end

      it "doesn't take a prompt the worker read before typing for the answer" do
        due_entry
        resume_swallows_enter
        hooks[:wait] = -> { event("user_prompt") }
        desk.scan

        expect(outcomes).to eq(["no_response"])
      end

      it "is resumed once the hook arrives, and goes to watching" do
        due_entry
        healthy_run
        desk.scan

        expect(outcomes).to eq(["resumed"])
        expect(sleeps.count(described_class::POLL_INTERVAL)).to be < described_class::PROMPT_WAIT
        expect(entry).to include("phase" => "watching", "draft_text" => nil)
      end

      it "lets the next attempt stop that agent with our text in its input line" do
        due_entry
        resume_swallows_enter
        desk.scan
        typed = messages.first
        tmux.screen = "#{rule_prompt}#{typed}\n"

        hooks[:signal] = -> { agent_leaves(21) }
        hooks[:deliver] = lambda {
          tmux.screen = empty_prompt
          agent_resumes(pid: 22)
        }
        next_attempt

        expect(signals).to eq([["INT", 20], ["INT", 21]])
        expect(outcomes).to eq(%w[no_response resumed])
        expect(entry).to include("phase" => "watching", "agent_pid" => 22, "draft_text" => nil)
      end

      it "covers a resume_only attempt the same way" do
        due_entry(attempts: 2, stopped: true)
        ledger.record("event" => "session_end", "session_id" => sid)
        gone!
        hooks[:deliver] = -> { agent_resumes(answers: false) }
        desk.scan

        expect(signals).to eq([])
        expect(outcomes).to eq(["no_response"])
        expect(entry).to include("stopped" => false, "agent_pid" => 21, "draft_text" => a_string_matching(message))
        expect_rescheduled(3)

        typed = messages.first
        tmux.screen = "#{rule_prompt}#{typed}\n"
        hooks[:signal] = -> { agent_leaves(21) }
        hooks[:deliver] = lambda {
          tmux.screen = empty_prompt
          agent_resumes(pid: 22)
        }
        next_attempt

        expect(signals).to eq([["INT", 21]])
        expect(outcomes).to eq(%w[no_response resumed])
      end

      it "doesn't read a person's draft as ours after no_response" do
        due_entry
        resume_swallows_enter
        desk.scan
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }
        tmux.screen = "#{rule_prompt}a person's draft\n"

        expect(answer).to eq(:defer)
      end

      it "recognises our text after a kill during the wait" do
        due_entry
        resume_swallows_enter
        allow(desk).to receive(:await_prompt) do
          tmux.screen = "#{rule_prompt}#{messages.first}\n"
          raise "killed"
        end
        desk.scan
        desk.scan
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }

        expect(outcomes).to eq(["interrupted"])
        expect(entry).to include("phase" => "waiting", "stopped" => false, "agent_pid" => 21)
        expect(answer).to eq(:go)
      end

      it "keeps the draft of the attempt before while that agent won't stop" do
        due_entry(draft_text: "ours")
        desk.scan

        expect(outcomes).to eq(["not_stopped"])
        expect(entry["draft_text"]).to eq("ours")
      end

      it "takes a stop in the wait ahead of no_response" do
        due_entry
        resume_swallows_enter
        hooks[:sleep] = -> { event("stop") if entry["phase"] == "attempting" && messages.any? }
        desk.scan

        expect(entry).to be_nil
        expect(outcomes).to eq(["no_response"])
      end

      it "takes a failed turn in the wait ahead of no_response" do
        due_entry
        resume_swallows_enter
        hooks[:sleep] = -> { failed("overloaded") if entry["error"] == "server_error" && messages.any? }
        desk.scan

        expect(entry).to include("phase" => "waiting", "attempts" => 2, "error" => "overloaded")
        expect(entry).not_to include("failed_during_attempt")
      end

      it "leaves stopped false when the resumed agent sends SessionEnd in the wait, and gives up with nothing typed" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = lambda {
          agent_leaves(21)
          event("session_end")
        }
        desk.scan

        expect(outcomes).to eq(["no_response"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(resumes.size).to eq(1)
        expect(signals).to eq([["INT", 20]])
      end

      it "stays resumed, and resolves, when a Stop came before the pane emptied" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = lambda {
          event("user_prompt")
          event("stop")
          agent_leaves(21)
        }
        desk.scan

        expect(outcomes).to eq(["resumed"])
        expect(entry).to be_nil
      end

      it "doesn't watch an agent that took the message and ended before step 6" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = lambda {
          event("user_prompt")
          agent_leaves(21)
          event("session_end")
        }
        desk.scan

        expect(outcomes).to eq(["agent_left"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(resumes.size).to eq(1)
      end

      it "gives up when the pane reads as gone at step 6, with stopped false" do
        due_entry
        healthy_run
        allow(desk).to receive(:await_prompt) do
          tmux.details = [{id: "%9", window: 0, index: 2, pid: 99, command: "zsh"}]
          "typed"
        end
        desk.scan

        expect(outcomes).to eq(["agent_left"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
      end

      it "forgets the signal once an agent is found, with no SessionStart seen" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        hooks[:deliver] = -> { agent_appears }
        desk.scan

        expect(outcomes).to eq(["not_ready"])
        expect(entry).to include("stopped" => false, "last_signal_at" => nil, "agent_pid" => 21)

        agent_leaves(21)
        event("session_end")
        expect_gave_up("unconfirmed")
        expect(entry["stopped"]).to be(false)
      end

      it "stays resumed, and watches, when the last read fails" do
        due_entry
        healthy_run
        allow(desk).to receive(:await_prompt) do
          tree_broken[0] = true
          "typed"
        end
        desk.scan

        expect(outcomes).to eq(["resumed"])
        expect(entry["phase"]).to eq("watching")
      end

      it "gives up unconfirmed at 12 on agent_left, going round no more" do
        due_entry(attempts: 11)
        resume_swallows_enter
        hooks[:enter] = lambda {
          event("user_prompt")
          agent_leaves(21)
        }
        desk.scan

        expect(outcomes).to eq(["agent_left"])
        expect_gave_up("unconfirmed")
        expect(entry["attempts"]).to eq(12)
      end

      it "doesn't resume an agent that vanished in the wait with no hook: it may have been a person's to end" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = -> { agent_leaves(21) }
        desk.scan

        expect(outcomes).to eq(["no_response"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(resumes.size).to eq(1)
        expect(signals).to eq([["INT", 20]])
      end

      it "doesn't resume after a SessionEnd in the ready wait, of the agent the resume line brought up" do
        due_entry
        resume_swallows_enter
        hooks[:wait] = lambda {
          agent_leaves(21)
          event("session_end")
        }
        desk.scan

        expect(outcomes).to eq(["not_ready"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(resumes.size).to eq(1)
      end

      it "doesn't resume after a SessionEnd taken just after step 6 read the pane empty" do
        due_entry
        resume_swallows_enter
        hooks[:enter] = -> { agent_leaves(21) }
        desk.scan
        event("session_end")

        expect_gave_up("unconfirmed")
        expect(events.count { |type, _, _| type == "agent_recovery_gave_up" }).to eq(1)
        expect(resumes.size).to eq(1)
      end
    end

    describe "our own session_start in the attempt" do
      before { due_entry }

      it "leaves the phase alone, clears stopped, and keeps the hold past rebind_queue" do
        seen = {}
        hooks[:signal] = -> { agent_exits }
        hooks[:deliver] = lambda {
          agent_resumes
          seen[:after_hook] = entry
        }
        hooks[:rebind] = -> { seen[:holding] = desk.holding?("%5") }
        desk.scan

        expect(seen[:after_hook]).to include("phase" => "attempting", "stopped" => false, "attempt_session_id" => sid)
        expect(seen[:holding]).to be(true)
      end

      it "reaches step 6 with a stop right after it" do
        healthy_run
        hooks[:wait] = -> { event("stop") }
        desk.scan

        expect(entry).to be_nil
        expect(outcomes).to eq(["resumed"])
      end

      it "reaches step 6 with a turn_failed right after it" do
        healthy_run
        hooks[:wait] = -> { failed }
        desk.scan

        expect_rescheduled(2)
        expect(entry["failed_at"]).not_to eq(stamp(t0))
      end

      it "is not_ready with stopped false when the agent that reported dies before step 4, and nothing is typed" do
        healthy_run
        hooks[:wait] = lambda {
          ledger.record("event" => "session_end", "session_id" => sid)
          gone!
          processes.reject! { |process| process[:pid] == 21 }
        }
        desk.scan

        expect(outcomes).to eq(["not_ready"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(signals.size).to eq(1)
        expect(resumes.size).to eq(1)
      end
    end

    describe "a not_stopped signal" do
      def exits_late
        processes.reject! { |process| process[:pid] == 20 }
        ledger.record("event" => "session_end", "session_id" => sid)
        gone!
      end

      def signal_goes_unheeded
        due_entry
        desk.scan
        expect(outcomes).to eq(["not_stopped"])
        expect(signals).to eq([["INT", 20]])
      end

      it "resumes an agent that exits late, its SessionEnd arriving after the attempt closed" do
        signal_goes_unheeded
        expect(entry).to include("phase" => "waiting", "stopped" => false)

        now[0] += 60
        exits_late
        event("session_end")
        expect(entry).to include("phase" => "waiting", "stopped" => true)

        hooks[:deliver] = -> { agent_resumes }
        now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
        expect(desk.check("%5", entry)).to have_attributes(answer: :go, mode: :resume_only)
        desk.scan

        expect(signals).to eq([["INT", 20]])
        expect(resumes.size).to eq(1)
        expect(outcomes).to eq(%w[not_stopped resumed])
        expect(lines.last).to include("attempt" => 3, "mode" => "restart")
      end

      it "gives up, nothing typed, when the SessionEnd arrived inside the attempt" do
        due_entry
        ended = false
        hooks[:sleep] = lambda {
          next if ended || signals.empty?
          ended = true
          event("session_end")
        }
        desk.scan
        hooks[:sleep] = nil
        expect(outcomes).to eq(["not_stopped"])
        expect(entry).to include("phase" => "waiting", "stopped" => false)

        exits_late
        now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
        desk.scan
        expect(entry).to include("phase" => "waiting", "stopped" => false)
        expect(entry["defer_since"]).not_to be_nil

        now[0] += Workspace::AgentRecoveryStore::SIGNAL_HOLD
        desk.scan

        expect_gave_up("unconfirmed")
        expect(signals).to eq([["INT", 20]])
        expect(tmux.sent_keys).to eq([])
        expect(tmux.sent_key_names).to eq([])
      end

      it "gives up at once on a SessionEnd after the 5 minutes, leaving stopped false" do
        signal_goes_unheeded
        now[0] += Workspace::AgentRecoveryStore::SIGNAL_HOLD + 1
        exits_late
        event("session_end")

        expect_gave_up("unconfirmed")
        expect(entry["stopped"]).to be(false)
        expect(tmux.sent_keys).to eq([])
      end
    end

    describe "resume_only" do
      def shell_left(**fields)
        due_entry(attempts: 2, stopped: true, **fields)
        ledger.record("event" => "session_end", "session_id" => sid)
        gone!
        hooks[:deliver] = -> { agent_resumes }
      end

      it "resumes from a real SessionEnd, with no signal, no marker and no defer" do
        shell_left
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "watching", "attempts" => 3)
        expect(resumes.size).to eq(1)
        expect(outcomes).to eq(["resumed"])
      end

      it "writes no marker" do
        shell_left
        expect(marker).not_to receive(:mark)
        desk.scan
      end

      it "resumes after an interrupted attempt" do
        shell_left(phase: "attempting")
        desk.scan
        expect(outcomes).to eq(["interrupted"])

        now[0] += 480
        desk.scan

        expect(outcomes).to eq(%w[interrupted resumed])
        expect(signals).to eq([])
      end
    end

    describe "an agent we didn't start" do
      before { due_entry }

      it "gives up in step 2 on another id, nothing typed" do
        hooks[:signal] = lambda {
          agent_exits
          agent_resumes(session: other_sid)
        }
        desk.scan

        expect_gave_up("fresh_conversation")
        expect(outcomes).to eq(["fresh_agent"])
        expect(texts).to eq([])
      end

      it "gives up in step 2 with no session_start; the monitor's old id proves nothing" do
        hooks[:signal] = lambda {
          agent_exits
          agent_appears
        }
        desk.scan

        expect_gave_up("fresh_conversation")
        expect(texts).to eq([])
        expect(entry["agent_pid"]).to eq(20)
      end

      it "gives up in step 4 on another id, with no message" do
        hooks[:signal] = -> { agent_exits }
        hooks[:deliver] = -> { agent_resumes(session: other_sid) }
        desk.scan

        expect_gave_up("fresh_conversation")
        expect(outcomes).to eq(["fresh_agent"])
        expect(messages).to eq([])
      end

      it "reads as not_ready in step 4 with no session_start: our command started it" do
        hooks[:signal] = -> { agent_exits }
        hooks[:deliver] = -> { agent_appears }
        desk.scan

        expect(outcomes).to eq(["not_ready"])
        expect(messages).to eq([])
        expect(inbox.list).to eq([])
      end

      it "is a person's resume on the entry's id, in step 2" do
        hooks[:signal] = lambda {
          agent_exits
          agent_resumes
        }
        facts[:agent_pid] = 99
        desk.scan

        expect(outcomes).to eq(["person_resumed"])
        expect(entry).to include("phase" => "watching", "stopped" => false, "last_signal_at" => nil, "agent_pid" => 21,
          "agent_started" => later)
        expect(rebound).to eq([["%5", 99]])
        expect(texts).to eq([])
      end

      it "gives up through T8 when a || agent arrives after not_stopped" do
        desk.scan
        expect(outcomes).to eq(["not_stopped"])

        event("session_start", session: other_sid, source: "startup")

        expect_gave_up("fresh_conversation")
      end

      it "gives up through step 3 on another id; its pid is never stored" do
        hooks[:signal] = -> { agent_exits }
        clear_twice_then { agent_resumes(session: other_sid) }
        desk.scan

        expect_gave_up("fresh_conversation")
        expect(resumes).to eq([])
        expect(entry["agent_pid"]).to eq(20)
      end

      it "is a person's resume through step 3, and moves the queue" do
        hooks[:signal] = -> { agent_exits }
        clear_twice_then { agent_resumes }
        desk.scan

        expect(outcomes).to eq(["person_resumed"])
        expect(resumes).to eq([])
        expect(rebound.size).to eq(1)
      end
    end

    describe "step 2" do
      it "types nothing while a wrapper pane reads as a shell with the agent alive" do
        due_entry
        tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "bash"}]
        desk.scan

        expect(texts).to eq([])
        expect(outcomes).to eq(["not_stopped"])
      end

      it "types nothing on a single pane_clear? read" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        reads = 0
        allow(stopper).to receive(:pane_clear?) { (reads += 1).odd? }
        desk.scan

        expect(texts).to eq([])
        expect(outcomes).to eq(["not_stopped"])
      end

      it "sends one signal at the deadline, and leaves the marker" do
        due_entry
        desk.scan

        expect(signals).to eq([["INT", 20]])
        expect(outcomes).to eq(["not_stopped"])
        expect(marker.marked?(sid)).to be(true)
        expect_rescheduled(2)
        expect(entry["stopped"]).to be(false)
      end
    end

    describe "the safety review's guards" do
      it "empties the shell's line, in its own call, right before the resume command" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        keys = []
        hooks[:deliver] = lambda {
          keys.concat(tmux.sent_key_names)
          agent_resumes
        }
        desk.scan

        expect(keys).to eq([{session: "api", pane: "%5", key: "C-u"}])
      end

      it "types nothing when the C-u call fails" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        allow(tmux).to receive(:send_key).and_return(false)
        desk.scan

        expect(texts).to eq([])
        expect(outcomes).to eq(["not_delivered"])
      end

      it "targets the pane by id, for every delivery" do
        due_entry
        healthy_run
        desk.scan

        expect(tmux.sent_keys.map { |key| key[:pane] }.uniq).to eq(["%5"])
      end

      it "is pane_not_clear when a process elsewhere holds the session" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        clear_twice_then { processes.push(proc_entry(40, 1, "claude --resume #{sid}")) }
        desk.scan

        expect(texts).to eq([])
        expect(outcomes).to eq(["pane_not_clear"])
      end

      it "resumes past a process that only mentions the session" do
        due_entry
        healthy_run
        processes.push(proc_entry(40, 1, "tail -f /tmp/#{sid}.jsonl"), proc_entry(41, 1, "rg #{sid}"))
        desk.scan

        expect(outcomes).to eq(["resumed"])
      end

      it "makes the clear look the last read before C-u, with the session check ahead of it" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        order = []
        looks = 0
        hooks[:snapshot] = -> { order << :snapshot if looks >= 2 }
        allow(stopper).to receive(:session_held?).and_wrap_original do |original, **args|
          order << :held if looks >= 2
          original.call(**args)
        end
        allow(stopper).to receive(:pane_clear?).and_wrap_original do |original, **args|
          looks += 1
          order << :look if looks > 2
          original.call(**args)
        end
        allow(tmux).to receive(:send_key).and_wrap_original do |original, *args|
          order << :key
          original.call(*args)
        end
        desk.scan

        expect(order.first(5)).to eq(%i[snapshot held snapshot look key])
      end

      it "still reads a person's resume in the pane as a resume, though it holds the session" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        clear_twice_then do
          processes.push(proc_entry(21, 10, "claude --resume #{sid}", lstart: later))
          tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "claude"}]
          start_session(sid)
          event("session_start", source: "resume")
        end
        desk.scan

        expect(outcomes).to eq(["person_resumed"])
      end

      it "is pane_not_clear when the tree can't be read at the session check" do
        due_entry
        hooks[:signal] = -> { agent_exits }
        reads = 0
        allow(stopper).to receive(:pane_clear?).and_wrap_original do |original, **args|
          answer = original.call(**args)
          reads += 1
          answer
        end
        broke = false
        hooks[:snapshot] = lambda {
          next unless reads == 2 && !broke
          broke = true
          raise Workspace::Error, "could not read the process table"
        }
        desk.scan

        expect(texts).to eq([])
        expect(outcomes).to eq(["pane_not_clear"])
      end

      it "defers resume_only while a process elsewhere holds the session" do
        due_entry(attempts: 2, stopped: true)
        ledger.record("event" => "session_end", "session_id" => sid)
        gone!
        processes.push(proc_entry(40, 1, "claude --resume #{sid}"))
        desk.scan

        expect(entry).to include("phase" => "waiting", "attempts" => 2)
        expect(entry["defer_since"]).not_to be_nil
        expect(texts).to eq([])
      end

      it "moves the queue when the last read finds another agent" do
        due_entry
        facts[:agent_pid] = 99
        allow(desk).to receive(:restart_steps) do
          processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(21, 10, "claude", lstart: later)])
          ["not_stopped"]
        end
        desk.scan

        expect(rebound).to eq([["%5", 99]])
      end

      it "doesn't move the queue when the last read finds the same agent" do
        due_entry
        allow(desk).to receive(:restart_steps).and_return(["not_stopped"])
        desk.scan

        expect(rebound).to eq([])
      end

      it "gives up when a session other than the entry's opened during the attempt" do
        due_entry
        allow(desk).to receive(:restart_steps) do
          event("session_start", session: other_sid, source: "startup")
          ["not_stopped"]
        end
        desk.scan

        expect_gave_up("fresh_conversation")
      end

      it "sends no signal without the marker, and takes the attempt back" do
        due_entry
        allow(marker).to receive(:mark).and_return(false)
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1, "stopped" => false)
        expect(entry["defer_since"]).not_to be_nil
      end

      it "defers on a prompt that arrives after step 1's check" do
        due_entry
        allow(desk).to receive(:confirmed_error).and_wrap_original do |original, *args|
          result = original.call(*args)
          facts[:last_user_prompt_at] = now[0] if restarting.include?("%5")
          result
        end
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
      end

      it "doesn't hold the delivery lock across the quiet wait" do
        due_entry
        held = []
        hooks[:sleep] = -> { held << delivery_lock.locked? if signals.empty? }
        healthy_run
        desk.scan

        expect(held).to eq([false, false])
      end

      it "defers when the screen moved between the quiet wait and the lock" do
        due_entry
        allow(desk).to receive(:safe_check).and_wrap_original do |original, *args, **options|
          tmux.screen = "#{empty_prompt}moved\n" if restarting.include?("%5")
          original.call(*args, **options)
        end
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
      end

      it "writes the inbox item of a give-up through a kill" do
        due_entry(attempts: 11)
        allow(desk).to receive(:restart_steps).and_return(["not_stopped"])
        hooks[:record] = lambda {
          worker = Thread.current
          Thread.new { worker.kill }.join
        }
        Thread.new { desk.scan }.join

        expect(entry["phase"]).to eq("gave_up")
        expect(inbox.list.size).to eq(1)
        expect(restarting).to eq([])
      end

      describe "step 5's identity check" do
        before { healthy_run }

        before { allow(typer).to receive(:type).and_call_original }

        it "types no message once the claim is gone" do
          due_entry
          hooks[:rebind] = -> { restarting.clear }
          desk.scan

          expect(messages).to eq([])
          expect(outcomes).to eq(["claim_lost"])
        end

        {"a shell that took the terminal back" => [21, 10], "a group that can't be read" => []}.each do |name, ids|
          it "types no message to the resumed agent with #{name}" do
            due_entry
            hooks[:rebind] = -> { group_ids.replace(ids) }
            desk.scan

            expect(messages).to eq([])
            expect(typer).not_to have_received(:type)
            expect(outcomes).to eq(["pane_not_clear"])
          end
        end

        it "types no message once no agent is left" do
          due_entry
          hooks[:rebind] = -> { processes.reject! { |process| process[:pid] == 21 } }
          desk.scan

          expect(messages).to eq([])
          expect(outcomes).to eq(["pane_not_clear"])
          expect(entry["stopped"]).to be(false)
        end

        it "types no message to an agent that isn't the attempt's" do
          due_entry
          hooks[:rebind] = -> { processes.find { |process| process[:pid] == 21 }[:lstart] = "Mon Oct 26 12:00:00 2026" }
          desk.scan

          expect(messages).to eq([])
          expect(typer).not_to have_received(:type)
        end
      end
    end

    describe "step 3" do
      def expect_no_typing_and_rescheduled(outcome, attempts = 2)
        expect(outcomes).to eq([outcome])
        expect(readiness).not_to have_received(:wait)
        expect(sleeps.max).to be <= 2
        expect(messages).to eq([])
        expect(typer).not_to have_received(:type)
        expect_rescheduled(attempts)
        expect(entry["stopped"]).to be(true)
      end

      before do
        allow(typer).to receive(:type).and_call_original
        hooks[:signal] = -> { agent_exits }
      end

      it "types no resume line once a new agent reported, even with the pane clear again at the keystroke" do
        due_entry
        allow(desk).to receive(:await_exit).and_wrap_original do |original, attempt|
          original.call(attempt).tap { event("session_start", source: "resume") }
        end
        desk.scan

        expect(resumes).to eq([])
        expect(tmux.sent_key_names).to eq([])
        expect(outcomes).to eq(["pane_not_clear"])
        expect_gave_up("unconfirmed")
      end

      it "is pane_not_clear when the third read is false, with no agent" do
        due_entry
        allow(stopper).to receive(:pane_clear?).and_return(true, true, false)
        desk.scan

        expect(resumes).to eq([])
        expect_no_typing_and_rescheduled("pane_not_clear")
      end

      it "is claim_lost when the claim went" do
        due_entry
        clear_twice_then { restarting.clear }
        desk.scan

        expect(resumes).to eq([])
        expect_no_typing_and_rescheduled("claim_lost")
      end

      it "is not_delivered when the command doesn't land, sent once" do
        due_entry
        tries = 0
        allow(tmux).to receive(:deliver) do
          tries += 1
          Workspace::Tmux::Delivery.new(status: :failed, message: "gone")
        end
        desk.scan

        expect(tries).to eq(1)
        expect_no_typing_and_rescheduled("not_delivered")
      end

      it "gives up at 12 from a step 3 refusal" do
        due_entry(attempts: 11)
        allow(stopper).to receive(:pane_clear?).and_return(true, true, false)
        desk.scan

        expect_gave_up("attempts_exhausted")
        expect(entry["attempts"]).to eq(12)
        expect(outcomes).to eq(["pane_not_clear"])
      end

      it "types nothing when the session opened in another pane, then deletes and resolves the item" do
        failed("authentication_failed")
        failed
        store.update("%5") do |current|
          current.merge!("cwd" => "/work", "attempts" => 1, "agent_pid" => 20, "agent_started" => started, "last_turn_uuid" => "u-err",
            "failed_at" => stamp(t0), "next_attempt_at" => stamp(t0 + 60))
        end
        now[0] = t0 + 61
        expect(inbox.list.first["state"]).to eq("open")
        hooks[:signal] = lambda {
          agent_exits
          start_session(sid, pane: "%9")
          event("session_start", pane: "%9", source: "resume")
        }
        desk.scan

        expect(texts).to eq([])
        expect(entry).to be_nil
        expect(inbox.list.first["state"]).to eq("done")
        expect(outcomes).to eq(["resumed_elsewhere"])
        expect(marker.marked?(sid)).to be(false)
      end
    end

    describe "step 1" do
      it "defers on a prompt the monitor holds and the worker hasn't reached" do
        due_entry
        calls = 0
        allow(desk).to receive(:check).and_wrap_original do |original, *args, **options|
          calls += 1
          facts[:last_user_prompt_at] = now[0] if calls == 2
          original.call(*args, **options)
        end
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
        expect(entry["defer_since"]).not_to be_nil
        expect(lines).to eq([])
      end

      it "costs no attempt on a :clear, and writes no attempt line" do
        due_entry
        calls = 0
        allow(desk).to receive(:check).and_wrap_original do |original, *args, **options|
          calls += 1
          write_transcript(good_line) if calls == 2
          original.call(*args, **options)
        end
        desk.scan

        expect(signals).to eq([])
        expect_gave_up("unconfirmed")
        expect(entry["attempts"]).to eq(1)
        expect(lines).to eq([])
      end

      it "does nothing for an entry a hook moved on" do
        due_entry
        allow(desk).to receive(:safe_check).and_wrap_original do |original, *args, **options|
          result = original.call(*args, **options)
          event("user_prompt") if restarting.include?("%5")
          result
        end
        desk.scan

        expect(signals).to eq([])
        expect(entry["phase"]).to eq("watching")
      end

      it "defers with no signal when the resume command goes nil" do
        due_entry
        allow(resume_command).to receive(:call).and_return("cd -- /work && claude --resume #{sid}", nil)
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
      end

      it "types the flags read in step 1" do
        due_entry
        healthy_run
        allow(resume_command).to receive(:flags_for).and_return(["--scan"], ["--model", "x"], nil)
        desk.scan

        expect(resumes).to eq(["cd -- /work && claude --model x --resume #{sid}"])
      end

      describe ":stale, a pid reused after step 1's read" do
        def stale_stop
          allow(marker).to receive(:mark).and_wrap_original do |original, *args|
            processes.find { |process| process[:pid] == 20 }[:lstart] = later
            original.call(*args)
          end
        end

        it "takes the attempt back and gives up as unconfirmed above 0" do
          due_entry
          stale_stop
          desk.scan

          expect(signals).to eq([])
          expect_gave_up("unconfirmed")
          expect(entry).to include("attempts" => 1, "stopped" => false, "last_signal_at" => nil)
          expect(marker.marked?(sid)).to be(false)
          expect(lines).to eq([])
        end

        it "takes the attempt back and deletes at 0" do
          due_entry(attempts: 0)
          stale_stop
          allow(desk).to receive(:check).and_return(described_class::Verdict.new(answer: :go, mode: :restart, command: "resume"))
          allow(desk).to receive(:confirmed_error)
          desk.send(:restart_attempt, "%5", nil)

          expect(entry).to be_nil
          expect(signals).to eq([])
          expect(marker.marked?(sid)).to be(false)
        end
      end

      describe "a stop that can't read the process table, after stopped was written" do
        before do
          allow(marker).to receive(:mark).and_wrap_original do |original, *args|
            tree_broken[0] = true
            original.call(*args)
          end
        end

        it "takes the attempt back and defers, with nothing sent" do
          due_entry(defer_since: stamp(t0 + 30))
          desk.scan

          expect(signals).to eq([])
          expect(entry).to include("phase" => "waiting", "attempts" => 1, "stopped" => false, "last_signal_at" => nil,
            "defer_since" => stamp(t0 + 30))
          expect(marker.marked?(sid)).to be(false)
          expect(desk.holding?("%5")).to be(false)
          expect(lines).to eq([])
          expect(restarting).to eq([])
        end

        it "ends at the defer limit" do
          due_entry
          2.times do
            tree_broken[0] = false
            desk.scan
            now[0] += 1800
          end

          expect_gave_up("deferred")
          expect(signals).to eq([])
          expect(entry["attempts"]).to eq(1)
        end

        it "still honours a stop that arrived after stopped was written" do
          due_entry
          allow(stopper).to receive(:stop).and_wrap_original do |original, **args|
            event("stop")
            original.call(**args)
          end
          desk.scan

          expect(entry).to be_nil
        end
      end

      it "takes stopped back when the agent left between the check and the stop, and resumes nothing" do
        due_entry
        allow(stopper).to receive(:stop) do
          processes.reject! { |process| process[:pid] == 20 }
          ledger.record("event" => "session_end", "session_id" => sid)
          gone!
          event("session_end")
          :not_running
        end
        desk.scan

        expect(lines).to eq([])
        expect(entry).to include("stopped" => false, "attempts" => 1)
        expect_gave_up("unconfirmed")
        expect(signals).to eq([])
        expect(resumes).to eq([])
      end

      it "leaves the marker on :not_running, and waits for an earlier signal's SessionEnd" do
        due_entry(last_signal_at: stamp(now[0] - 100))
        allow(stopper).to receive(:stop) do
          processes.reject! { |process| process[:pid] == 20 }
          gone!
          :not_running
        end
        desk.scan

        expect(marker.marked?(sid)).to be(true)
        expect(entry).to include("phase" => "waiting", "stopped" => false)

        event("session_end")
        expect(entry).to include("phase" => "waiting", "stopped" => true)
      end

      it "can't set stopped on a take-back: no signal went out" do
        due_entry
        allow(stopper).to receive(:stop) do
          failed("overloaded")
          gone!
          :background
        end
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("stopped" => false, "error" => "overloaded")
      end

      describe "a background agent, not the terminal's foreground group" do
        let(:group_read) { ->(pid) { (pid == 20) ? [20, 10] : [10, 10] } }

        it "gets no signal, costs no attempt, and ends at the defer limit" do
          due_entry
          desk.scan

          expect(signals).to eq([])
          expect(entry).to include("phase" => "waiting", "attempts" => 1, "stopped" => false)
          expect(entry["defer_since"]).not_to be_nil

          now[0] += 1800
          desk.scan
          expect_gave_up("deferred")
          expect(signals).to eq([])
        end
      end
    end

    describe "step 4" do
      before { hooks[:signal] = -> { agent_exits } }

      it "waits on the pane alone, then rescans it" do
        due_entry
        hooks[:deliver] = -> { agent_resumes }
        desk.scan

        expect(readiness).to have_received(:wait).with("api", deadline: 60, only_pane: "%5", detector: anything)
        expect(monitor).to have_received(:rescan_pane).with("%5").at_least(:once)
      end

      it "stores the agent on not_ready, keeps the queue, and the next attempt goes ahead" do
        due_entry
        hooks[:deliver] = -> { agent_appears }
        facts[:agent_pid] = 99
        desk.scan

        expect(outcomes).to eq(["not_ready"])
        expect(entry).to include("agent_pid" => 21, "agent_started" => later, "stopped" => false)
        expect(rebound).to eq([["%5", 99]])

        # The late SessionStart the ledger needs, which the desk found no need to wait for.
        start_session(sid)
        now[0] += 240
        hooks[:signal] = nil
        desk.scan

        expect(signals).to eq([["INT", 20], ["INT", 21]])
      end
    end

    describe "step 5" do
      let(:rule_prompt) { "────────\n❯ " }

      before do
        healthy_run
        due_entry
      end

      it "stores the agent on not_typed, and the agent dying later sets stopped" do
        allow(typer).to receive(:type).and_return(Workspace::PromptTyper::Result.new(outcome: :failed))
        desk.scan

        expect(outcomes).to eq(["not_typed"])
        expect(entry).to include("agent_pid" => 21, "stopped" => false)
        expect_rescheduled(2)
      end

      it "leaves stopped false when the agent dies after step 4 and before the last update" do
        allow(typer).to receive(:type) do
          processes.reject! { |process| process[:pid] == 21 }
          Workspace::PromptTyper::Result.new(outcome: :failed)
        end
        desk.scan

        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
      end

      it "presses Enter once on :not_submitted and never retypes" do
        allow(typer).to receive(:type) do |text:, **|
          tmux.screen = "#{rule_prompt}#{text}\n"
          Workspace::PromptTyper::Result.new(outcome: :not_submitted)
        end
        desk.scan

        expect(typer).to have_received(:type).once
        expect(texts.count("")).to eq(1)
        expect(outcomes).to eq(["resumed"])
      end

      it "never presses Enter when the shell takes the terminal after the paste" do
        allow(tmux).to receive(:deliver).and_wrap_original do |original, session, pane, text, enter: true|
          original.call(session, pane, text, enter: enter).tap { group_ids.replace([21, 10]) unless enter }
        end
        desk.scan

        expect(texts).not_to include("")
        expect(outcomes).to eq(["not_submitted"])
        expect(entry["draft_text"]).to match(/workspace restarted Claude Code/)
      end

      it "reads the groups on every try" do
        reads = []
        allow(typer).to receive(:type).and_return(Workspace::PromptTyper::Result.new(outcome: :refused, reason: "unknown"))
        allow(stopper).to receive(:foreground?).and_wrap_original do |original, **args|
          reads << args[:pid]
          original.call(**args)
        end
        desk.scan

        expect(typer).to have_received(:type).exactly(described_class::TYPE_TRIES).times
        expect(reads.count(21)).to eq(described_class::TYPE_TRIES)
      end

      it "stops trying when the terminal is lost between tries, typing nothing more" do
        tries = 0
        allow(typer).to receive(:type) do
          tries += 1
          allow(stopper).to receive(:foreground?).and_return(false)
          Workspace::PromptTyper::Result.new(outcome: :refused, reason: "unknown")
        end
        desk.scan

        expect(tries).to eq(1)
        expect(outcomes).to eq(["pane_not_clear"])
      end

      it "doesn't press Enter on :not_submitted once the shell holds the terminal" do
        allow(typer).to receive(:type) do |text:, **|
          tmux.screen = "#{rule_prompt}#{text}\n"
          allow(stopper).to receive(:foreground?).and_return(false)
          Workspace::PromptTyper::Result.new(outcome: :not_submitted)
        end
        desk.scan

        expect(texts).not_to include("")
        expect(outcomes).to eq(["not_submitted"])
      end

      it "leaves draft_text after a failed Enter, and the next check answers :go" do
        typed = nil
        allow(typer).to receive(:type) do |text:, **|
          typed = text
          tmux.screen = "#{rule_prompt}#{text}\n"
          allow(tmux).to receive(:deliver).and_return(Workspace::Tmux::Delivery.new(status: :failed, message: "no"))
          Workspace::PromptTyper::Result.new(outcome: :not_submitted)
        end
        desk.scan

        expect(outcomes).to eq(["not_submitted"])
        expect(entry["draft_text"]).to eq(typed)
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }
        expect(answer).to eq(:go)
      end

      it "doesn't press Enter when the input line lost the text" do
        allow(typer).to receive(:type).and_return(Workspace::PromptTyper::Result.new(outcome: :not_submitted))
        desk.scan

        expect(texts).not_to include("")
        expect(outcomes).to eq(["not_submitted"])
      end

      it "releases the delivery lock between tries, and tries 20 times on unknown" do
        held = []
        allow(typer).to receive(:type) do
          hooks[:sleep] = -> { held << delivery_lock.locked? }
          Workspace::PromptTyper::Result.new(outcome: :refused, reason: "unknown")
        end
        desk.scan

        expect(typer).to have_received(:type).exactly(20).times
        expect(held.size).to be >= 19
        expect(held).to all(be(false))
        expect(outcomes).to eq(["not_typed"])
      end

      it "doesn't try again on any other refusal" do
        allow(typer).to receive(:type) { Workspace::PromptTyper::Result.new(outcome: :refused, reason: "waiting") }
        desk.scan

        expect(typer).to have_received(:type).once
        expect(outcomes).to eq(["not_typed"])
      end

      it "stops the paste on a person's prompt to the resumed agent, as not_typed" do
        hooks[:wait] = -> { facts[:last_user_prompt_at] = now[0] + 1 }
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["not_typed"])
      end

      it "takes the delivery lock for each try" do
        locked = []
        allow(typer).to receive(:type) do
          locked << delivery_lock.owned?
          Workspace::PromptTyper::Result.new(outcome: :failed)
        end
        desk.scan

        expect(locked).to eq([true])
      end
    end

    describe "step 6" do
      failing = %w[not_stopped claim_lost pane_not_clear not_delivered not_ready not_typed not_submitted no_response agent_left]
      agent = {pid: 21, started: "Mon Oct 26 11:00:00 2026"}

      def run_to(outcome, agent: nil, &hook)
        allow(desk).to receive(:restart_steps) do
          hook&.call
          [outcome, agent]
        end
        desk.scan
      end

      (failing + %w[resumed typed resumed_elsewhere person_resumed fresh_agent]).each do |outcome|
        found = (outcome == "person_resumed") ? agent : nil

        it "honours a stop during #{outcome}" do
          due_entry
          run_to(outcome, agent: found) { event("stop") }

          expect(entry).to be_nil
          expect(outcomes).to eq([outcome])
        end

        it "honours a retryable failure during #{outcome}" do
          due_entry
          run_to(outcome, agent: found) { failed("overloaded") }

          expect(entry).to include("phase" => "waiting", "attempts" => 2, "error" => "overloaded")
          expect(entry).not_to include("failed_during_attempt")
          expect(entry["agent_pid"]).not_to be_nil
        end

        it "gives up on a non-retryable error during #{outcome}" do
          due_entry
          run_to(outcome, agent: found) { failed("billing_error") }

          expect_gave_up("not_retryable")
          expect(entry["attempts"]).to eq(2)
        end
      end

      failing.each do |outcome|
        it "schedules #{outcome} with the count raised" do
          due_entry(stopped: false)
          run_to(outcome)

          expect_rescheduled(2)
          expect(entry["stopped"]).to be(false)
        end

        it "gives up at 12 with one item on #{outcome}" do
          due_entry(attempts: 11)
          run_to(outcome)

          expect_gave_up("attempts_exhausted")
          expect(entry["attempts"]).to eq(12)
          expect(events.map(&:first)).to eq(%w[agent_recovery_attempt agent_recovery_gave_up])
        end

        it "sets stopped on #{outcome} when no agent is left" do
          due_entry
          run_to(outcome) { gone! }

          expect(entry["stopped"]).to be(true)
        end
      end

      it "leaves the stopped our signal set when the pane reads as gone" do
        due_entry(stopped: false)
        run_to("not_ready") { tmux.details = [{id: "%9", window: 0, index: 2, pid: 99, command: "zsh"}] }

        expect(signals).to eq([["INT", 20]])
        expect(entry).to include("stopped" => true, "phase" => "waiting")
      end

      it "keeps stopped when the last read fails" do
        due_entry
        run_to("not_stopped") do
          store.update("%5") { |current| current["stopped"] = true }
          tree_broken[0] = true
        end

        expect(entry["stopped"]).to be(true)
      end

      it "sets draft_text on not_submitted and no_response, nowhere else" do
        due_entry
        run_to("no_response")
        expect(entry["draft_text"]).to match(message)

        store.delete("%5")
        due_entry(draft_text: "ours")
        run_to("resumed")
        expect(entry["draft_text"]).to be_nil
      end

      it "moves a typed attempt to watching, for T13" do
        due_entry(draft_text: "ours")
        run_to("typed")

        expect(entry).to include("phase" => "watching", "draft_text" => nil)
      end

      it "moves the queue before the hold ends on person_resumed" do
        due_entry
        held = []
        hooks[:rebind] = -> { held << desk.holding?("%5") }
        run_to("person_resumed", agent: agent)

        expect(held).to eq([true])
      end

      it "writes no line for an entry reconcile already took" do
        due_entry
        run_to("not_ready") { store.update("%5") { |current| current["phase"] = "waiting" } }

        expect(lines).to eq([])
      end
    end

    describe "the claim" do
      it "skips the attempt when a restart holds the pane" do
        due_entry
        refuse_claim[0] = true
        desk.scan

        expect(signals).to eq([])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
      end

      it "is released after an attempt, and with nothing to do" do
        due_entry
        healthy_run
        desk.scan
        expect(restarting).to eq([])
      end

      it "runs on the spawned thread" do
        due_entry
        spawned = 0
        spawn_desk = build_desk(stub_attempts: false, spawn: ->(&block) {
          spawned += 1
          block.call
        })
        hooks[:signal] = -> { agent_exits }
        spawn_desk.scan

        expect(spawned).to eq(1)
      end

      it "leaves an attempt that raises to the next scan, marker kept until then" do
        due_entry
        allow(desk).to receive(:restart_steps) do
          gone!
          raise "boom"
        end
        desk.scan

        expect(entry["phase"]).to eq("attempting")
        expect(restarting).to eq([])
        expect(marker.marked?(sid)).to be(true)

        desk.scan

        expect(outcomes).to eq(["interrupted"])
        expect(marker.marked?(sid)).to be(false)
        expect(entry["phase"]).to eq("waiting")
      end
    end
  end

  describe "a typed attempt" do
    include_context "a real attempt"

    let(:message) { "An API error stopped your last turn (server_error). Continue where you left off." }
    let(:rule_prompt) { "────────\n❯ " }

    def agent_answers = hooks[:enter] = -> { event("user_prompt") }

    def before_typing(&block)
      allow(desk).to receive(:type_message).and_wrap_original do |original, attempt|
        block.call
        original.call(attempt)
      end
    end

    def typer_answers(outcome, **fields)
      allow(typer).to receive(:type).and_return(Workspace::PromptTyper::Result.new(outcome: outcome, **fields))
    end

    def next_attempt
      now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
      desk.scan
    end

    def replace_agent
      processes.reject! { |process| process[:pid] == 20 }
      agent_appears
    end

    def expect_no_stop
      expect(signals).to eq([])
      expect(marker.marked?(sid)).to be(false)
      expect(resumes).to eq([])
      expect(tmux.sent_key_names).to eq([])
    end

    def expect_restart_after(outcome)
      expect(outcomes).to eq([outcome])
      expect_no_stop
      expect(readiness).not_to have_received(:wait)
      expect_rescheduled(1)

      allow(desk).to receive(:type_message).and_call_original
      allow(typer).to receive(:type).and_call_original
      healthy_run
      next_attempt
      expect(signals).to eq([["INT", 20]])
      expect(outcomes).to eq([outcome, "resumed"])
      expect(lines.map { |line| line["mode"] }).to eq(%w[typed restart])
      expect(entry["attempts"]).to eq(2)
    end

    describe "a first failure" do
      it "types at the live prompt and nothing else" do
        expect(marker).not_to receive(:mark)
        expect(Workspace::PaneBindings).not_to receive(:new)
        agent_answers
        failed
        now[0] = t0 + 61
        desk.scan

        expect(texts).to eq([message, ""])
        expect_no_stop
        expect(readiness).not_to have_received(:wait)
        expect(rebound).to eq([])
        expect(entry).to include("phase" => "watching", "attempts" => 1, "stopped" => false, "draft_text" => nil)
        expect(entry).not_to include("prompt_seen", "attempt_session_id")
        expect(lines).to eq([{"attempt" => 1, "session_id" => sid, "pane_id" => "%5", "error" => "server_error",
                              "mode" => "typed", "outcome" => "typed"}])
      end

      it "writes attempting, clearing defer_since, before anything is typed" do
        due_entry(attempts: 0, defer_since: stamp(t0))
        seen = nil
        hooks[:enter] = -> { seen ||= entry }
        desk.scan

        expect(seen).to include("phase" => "attempting", "attempts" => 1, "prompt_seen" => false, "attempt_session_id" => nil,
          "defer_since" => nil, "stopped" => false, "draft_text" => message)
      end

      it "stays holding for the length of the attempt" do
        due_entry(attempts: 0)
        held = []
        hooks[:enter] = lambda {
          held << desk.holding?("%5")
          event("user_prompt")
        }
        desk.scan

        expect(held).to eq([true])
      end

      it "keeps user text out of the event lines" do
        due_entry(attempts: 0)
        agent_answers
        desk.scan

        expect(events).not_to be_empty
        expect(events.to_s).not_to include("Continue where")
      end

      it "leaves a marker an earlier not_stopped left to expire" do
        due_entry(attempts: 0)
        marker.mark(sid)
        agent_answers
        desk.scan

        expect(outcomes).to eq(["typed"])
        expect(marker.marked?(sid)).to be(true)
      end
    end

    describe "step 1" do
      before { due_entry(attempts: 0) }

      def after_the_scan_check(&block)
        allow(desk).to receive(:typed_attempt).and_wrap_original do |original, *args|
          block.call
          original.call(*args)
        end
      end

      def expect_nothing_counted
        expect(messages).to eq([])
        expect(lines).to eq([])
      end

      it "defers at no cost when the screen turns busy" do
        after_the_scan_check { tmux.screen = "esc to interrupt\n#{empty_prompt}" }
        desk.scan

        expect_nothing_counted
        expect(entry).to include("phase" => "waiting", "attempts" => 0, "defer_since" => stamp(now[0]))
      end

      it "deletes the entry when the transcript has moved on to another error" do
        after_the_scan_check { write_transcript(error_line("u-new")) }
        desk.scan

        expect_nothing_counted
        expect(entry).to be_nil
      end

      it "deletes the entry when the pane has another session open" do
        after_the_scan_check { start_session(other_sid) }
        desk.scan

        expect_nothing_counted
        expect(entry).to be_nil
      end

      it "defers on a prompt the monitor has and the worker queue doesn't, after the transcript read" do
        reads = 0
        allow(desk).to receive(:confirmed_error).and_wrap_original do |original, *args|
          reads += 1
          facts[:last_user_prompt_at] = t0 + 60 if reads == 3
          original.call(*args)
        end
        desk.scan

        expect(reads).to eq(3)
        expect_nothing_counted
        expect(entry).to include("phase" => "waiting", "attempts" => 0)
      end

      it "skips the attempt when a restart holds the pane" do
        refuse_claim[0] = true
        desk.scan

        expect_nothing_counted
        expect(entry).to include("phase" => "waiting", "attempts" => 0)
      end
    end

    describe "after the message reaches the agent" do
      before do
        due_entry(attempts: 0)
        agent_answers
        desk.scan
      end

      it "ends on a stop, and the next outage types first again" do
        event("stop")
        expect(entry).to be_nil
        expect(signals).to eq([])

        failed
        now[0] += 61
        desk.scan
        expect(entry).to include("attempts" => 1, "phase" => "watching")
        expect(outcomes).to eq(%w[typed typed])
        expect(signals).to eq([])
      end

      it "schedules a restart at wait 2 on a turn_failed, never a second typing" do
        failed
        expect(entry).to include("phase" => "waiting", "attempts" => 1,
          "next_attempt_at" => stamp(now[0] + Workspace::AgentRecoveryStore.wait_before(2)))

        healthy_run
        next_attempt
        expect(signals).to eq([["INT", 20]])
        expect(messages).to eq([message])
        expect(lines.map { |line| line["mode"] }).to eq(%w[typed restart])
      end

      it "never times an idle agent in watching" do
        5.times do
          now[0] += 86_400
          desk.scan
        end

        expect(entry).to include("phase" => "watching", "attempts" => 1)
        expect(signals).to eq([])
        expect(messages).to eq([message])
      end

      it "leaves a bound workflow step to its hooks" do
        expect(Workspace::PaneBindings).not_to receive(:new)
        failed
        expect(entry["phase"]).to eq("waiting")
        event("user_prompt")
        event("stop")
        expect(entry).to be_nil
      end
    end

    describe "a stop or failure while the prompt wait runs" do
      before { due_entry(attempts: 0) }

      it "takes a stop after the prompt" do
        hooks[:enter] = lambda {
          event("user_prompt")
          event("stop")
        }
        desk.scan

        expect(outcomes).to eq(["typed"])
        expect(entry).to be_nil
      end

      it "takes a retryable failure after the prompt, as a restart at wait 2" do
        hooks[:enter] = lambda {
          event("user_prompt")
          failed("overloaded")
        }
        desk.scan

        expect(outcomes).to eq(["typed"])
        expect(entry).to include("phase" => "waiting", "attempts" => 1, "error" => "overloaded", "draft_text" => nil)
      end

      it "waits 30 seconds for the prompt, and a late one still counts" do
        waited = 0
        hooks[:enter] = -> { hooks[:sleep] = -> { event("user_prompt") if (waited += 1) == 30 } }
        desk.scan

        expect(outcomes).to eq(["typed"])
      end

      it "stops waiting at 30 seconds" do
        typed_at = ended_at = nil
        hooks[:enter] = -> { typed_at = now[0] }
        hooks[:record] = -> { ended_at = now[0] }
        desk.scan

        expect(outcomes).to eq(["no_response"])
        expect(ended_at - typed_at).to eq(30)
      end
    end

    describe "step 6's hooks, for each outcome" do
      agent = {pid: 21, started: "Mon Oct 26 11:00:00 2026"}

      def run_to(outcome, agent: nil, &hook)
        allow(desk).to receive(:typed_steps) do
          hook.call
          [outcome, agent]
        end
        desk.scan
      end

      before { due_entry(attempts: 0) }

      %w[typed no_response claim_lost pane_not_clear not_typed not_submitted person_resumed fresh_agent].each do |outcome|
        found = (outcome == "person_resumed") ? agent : nil

        it "honours a stop during #{outcome}" do
          run_to(outcome, agent: found) { event("stop") }

          expect(entry).to be_nil
          expect(outcomes).to eq([outcome])
        end

        it "honours a retryable failure during #{outcome}" do
          run_to(outcome, agent: found) { failed("overloaded") }

          expect(entry).to include("phase" => "waiting", "attempts" => 1, "error" => "overloaded")
          expect(entry).not_to include("failed_during_attempt")
        end

        it "gives up on a non-retryable error during #{outcome}" do
          run_to(outcome, agent: found) { failed("billing_error") }

          expect_gave_up("not_retryable")
          expect(entry["attempts"]).to eq(1)
        end
      end
    end

    describe "an attempt that fails" do
      before { due_entry(attempts: 0) }

      it "claim_lost types nothing and leads to a restart" do
        before_typing { restarting.clear }
        desk.scan

        expect(messages).to eq([])
        expect_restart_after("claim_lost")
      end

      it "a person's /exit before the paste gives up with nothing typed into their shell" do
        before_typing { gone! }
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["pane_not_clear"])
        expect(entry).to include("stopped" => false, "attempts" => 1)
        expect_gave_up("unconfirmed")
        expect(texts).to eq([])
        expect_no_stop
        expect(outcomes).to eq(["pane_not_clear"])
      end

      it "pane_not_clear with no agent and no clear pane leaves stopped false too" do
        before_typing do
          gone!
          tmux.details = [{id: "%5", window: 0, index: 1, pid: 10, command: "vim"}]
        end
        desk.scan

        expect(outcomes).to eq(["pane_not_clear"])
        expect(entry["stopped"]).to be(false)
      end

      it "a failure hook with the agent gone gives up at once, leaving nothing a late hook could silence" do
        hooks[:enter] = lambda {
          failed("overloaded")
          gone!
        }
        desk.scan

        expect(entry).to include("stopped" => false, "error" => "overloaded")
        expect_gave_up("unconfirmed")
        event("tool_use")
        expect(entry["phase"]).to eq("gave_up")
        expect(resumes).to eq([])
        expect(tmux.sent_key_names).to eq([])
      end

      it "never signals a person who resumes after a failure hook and a SessionEnd in the attempt" do
        hooks[:enter] = lambda {
          failed("overloaded")
          event("session_end", reason: "prompt_input_exit")
          gone!
        }
        desk.scan
        hooks[:enter] = nil
        agent_appears(pid: 31)
        start_session(sid)
        event("session_start", source: "resume")
        tmux.screen = empty_prompt
        now[0] += 3600
        desk.scan

        expect_gave_up("unconfirmed")
        expect(signals).to eq([])
      end

      it "a non-retryable failure hook with the agent gone stays not_retryable" do
        hooks[:enter] = lambda {
          failed("billing_error")
          gone!
        }
        desk.scan

        expect_gave_up("not_retryable")
      end

      [[:refused, {reason: "waiting"}], [:aborted, {}], [:not_landed, {}], [:failed, {}]].each do |typer_outcome, fields|
        it "#{typer_outcome} is not_typed, tried once, and leads to a restart" do
          typer_answers(typer_outcome, **fields)
          desk.scan

          expect(typer).to have_received(:type).once
          expect_restart_after("not_typed")
        end
      end

      it "recognises a :not_landed paste that renders late" do
        allow(typer).to receive(:type) do |text:, **|
          tmux.screen = "#{rule_prompt}#{text}\n"
          Workspace::PromptTyper::Result.new(outcome: :not_landed)
        end
        desk.scan
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }

        expect(outcomes).to eq(["not_typed"])
        expect(answer).to eq(:go)
      end

      it "recognises text left by a kill between the paste and Enter" do
        allow(desk).to receive(:typed_steps) do
          tmux.screen = "#{rule_prompt}#{message}\n"
          raise "killed"
        end
        desk.scan
        desk.scan
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }

        expect(outcomes).to eq(["interrupted"])
        expect(entry).to include("phase" => "waiting", "draft_text" => message)
        expect(answer).to eq(:go)
      end

      it "gives up when the agent leaves after the prompt hook, typing nothing more" do
        hooks[:enter] = lambda {
          event("user_prompt")
          gone!
        }
        desk.scan

        expect(outcomes).to eq(["agent_left"])
        expect(entry).to include("stopped" => false, "attempts" => 1)
        expect_gave_up("unconfirmed")
        expect(messages).to eq([message])
        expect_no_stop
      end

      it "gives up after a no_response turn whose agent left, typing nothing more" do
        hooks[:enter] = -> { gone! }
        desk.scan
        expect(outcomes).to eq(["no_response"])
        expect(entry["stopped"]).to be(false)
        expect_gave_up("unconfirmed")
        expect(messages).to eq([message])
        expect_no_stop
      end

      it "a person's prompt in the retry window stops the paste, as not_typed" do
        before_typing { facts[:last_user_prompt_at] = now[0] + 1 }
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["not_typed"])
        expect(entry).to include("phase" => "waiting", "attempts" => 1)
        expect(answer).to eq(:defer)
      end

      {"a shell that took the terminal back" => [20, 10], "a group that can't be read" => []}.each do |name, ids|
        it "types and presses nothing with #{name} after the check passed" do
          allow(typer).to receive(:type).and_call_original
          before_typing { group_ids.replace(ids) }
          desk.scan

          expect(tmux.sent_keys).to eq([])
          expect(typer).not_to have_received(:type)
          expect(outcomes).to eq(["pane_not_clear"])
          expect(entry).to include("phase" => "waiting", "attempts" => 1)
          expect_no_stop
        end
      end

      describe "the shell taking the terminal after the paste" do
        before do
          flipped = false
          allow(tmux).to receive(:deliver).and_wrap_original do |original, session, pane, text, enter: true|
            original.call(session, pane, text, enter: enter).tap do
              next if enter || flipped
              flipped = true
              group_ids.replace([20, 10])
            end
          end
          desk.scan
        end

        it "never presses Enter, and leaves our text as the draft" do
          expect(texts).to eq([message])
          expect(outcomes).to eq(["not_submitted"])
          expect(entry["draft_text"]).to eq(message)
        end

        it "empties the line with C-u ahead of the resume, on a restart once the agent has it back" do
          group_ids.replace([10, 10])
          expect_restart_after("not_submitted")

          expect(tmux.sent_key_names.map { |key| key[:key] }).to eq(["C-u"])
        end
      end

      it "presses no Enter on :not_submitted once the shell holds the terminal" do
        allow(typer).to receive(:type) do |text:, **|
          tmux.screen = "#{rule_prompt}#{text}\n"
          allow(stopper).to receive(:foreground?).and_return(false)
          Workspace::PromptTyper::Result.new(outcome: :not_submitted)
        end
        desk.scan

        expect(texts).not_to include("")
        expect(outcomes).to eq(["not_submitted"])
        expect(entry["draft_text"]).to eq(message)
      end

      it "an input line that lost the text is not_submitted, and leads to a restart" do
        typer_answers(:not_submitted)
        desk.scan

        expect(typer).to have_received(:type).once
        expect(texts).not_to include("")
        expect(entry["draft_text"]).to eq(message)
        expect_restart_after("not_submitted")
      end

      describe "a failed Enter" do
        before do
          allow(tmux).to receive(:deliver).and_wrap_original do |original, session, pane, text, enter: true|
            next Workspace::Tmux::Delivery.new(status: :failed, message: "no") if text.empty?
            original.call(session, pane, text, enter: enter)
          end
          desk.scan
          store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }
        end

        it "never retypes, and the next check takes the exact draft" do
          expect(messages).to eq([message])
          expect(outcomes).to eq(["not_submitted"])
          expect(entry["draft_text"]).to eq(message)
          expect(answer).to eq(:go)
        end

        it "doesn't read a person's longer draft as ours" do
          tmux.screen = "#{rule_prompt}#{message} and then\n"

          expect(answer).to eq(:defer)
        end
      end

      it "no_response leads to a restart" do
        desk.scan

        expect(messages).to eq([message])
        expect(entry["draft_text"]).to eq(message)
        expect_restart_after("no_response")
      end

      it "a process that never answers leaves stopped alone" do
        desk.scan

        expect(entry).to include("stopped" => false, "agent_pid" => 20)
      end
    end

    describe "after no_response" do
      before do
        due_entry(attempts: 0)
        desk.scan
        now[0] = Time.iso8601(entry["next_attempt_at"]) + 1
      end

      it "answers :go with our text in the input and the error still the last record" do
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }
        tmux.screen = "#{rule_prompt}#{message}\n"

        expect(answer).to eq(:go)
      end

      it "gives up as unconfirmed when the agent has moved on" do
        write_transcript(error_line, good_line)
        desk.scan

        expect_gave_up("unconfirmed")
        expect(signals).to eq([])
      end

      it "defers while the agent is working" do
        store.update("%5") { |current| current["last_turn_uuid"] = "u-err" }
        tmux.screen = "esc to interrupt\n#{empty_prompt}"
        desk.scan

        expect(entry).to include("phase" => "waiting", "defer_since" => stamp(now[0]))
        expect(signals).to eq([])
      end

      it "moves to watching on a late user_prompt" do
        event("user_prompt")

        expect(entry).to include("phase" => "watching", "attempts" => 1)
      end
    end

    describe "a different agent" do
      before { due_entry(attempts: 0) }

      it "with no session_start is never typed to, and its pid never stored" do
        before_typing { replace_agent }
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["fresh_agent"])
        expect_gave_up("fresh_conversation")
        expect(entry["agent_pid"]).to eq(20)
      end

      it "with another session gives up the same way" do
        before_typing do
          replace_agent
          event("session_start", session: other_sid, source: "startup")
        end
        desk.scan

        expect(messages).to eq([])
        expect_gave_up("fresh_conversation")
        expect(entry["agent_pid"]).to eq(20)
      end

      it "with the same pid and a new start time is a different agent" do
        before_typing { processes.find { |process| process[:pid] == 20 }[:lstart] = later }
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["fresh_agent"])
      end

      it "with our session is a person's resume" do
        before_typing do
          replace_agent
          event("session_start", source: "resume")
        end
        desk.scan

        expect(messages).to eq([])
        expect(outcomes).to eq(["person_resumed"])
        expect(entry).to include("phase" => "watching", "agent_pid" => 21, "attempts" => 1, "draft_text" => nil)
        expect(rebound).to eq([["%5", 10]])
      end

      it "arriving in the prompt wait isn't stored by the last read" do
        hooks[:enter] = -> { replace_agent }
        desk.scan

        expect(outcomes).to eq(["fresh_agent"])
        expect(entry["agent_pid"]).to eq(20)
      end

      it "arriving with a lost claim isn't stored by the last read" do
        before_typing do
          restarting.clear
          replace_agent
        end
        desk.scan

        expect(outcomes).to eq(["fresh_agent"])
        expect(entry["agent_pid"]).to eq(20)
      end
    end

    describe "the attempts running out" do
      it "gives up at the last attempt from a typed one, and its line says typed" do
        stub_const("Workspace::AgentRecoveryStore::MAX_ATTEMPTS", 1)
        due_entry(attempts: 0)
        desk.scan

        expect_gave_up("attempts_exhausted")
        expect(lines.map { |line| line.values_at("mode", "outcome") }).to eq([%w[typed no_response]])
      end

      it "gives up at the last attempt from a restart, and its line says restart" do
        due_entry(attempts: 11)
        hooks[:signal] = -> { agent_exits }
        desk.scan

        expect_gave_up("attempts_exhausted")
        expect(lines.map { |line| line.values_at("mode", "outcome") }).to eq([%w[restart not_ready]])
      end

      it "sends one SIGINT per attempt to an agent that answers nothing, and gives up at 12 with one item" do
        due_entry(attempts: 0)
        desk.scan
        11.times { next_attempt }

        expect(outcomes).to eq(["no_response"] + ["not_stopped"] * 11)
        expect(lines.map { |line| line["attempt"] }).to eq((1..12).to_a)
        expect(signals).to eq([["INT", 20]] * 11)
        expect_gave_up("attempts_exhausted")
      end

      it "gives a pane that can't be restarted the typed attempt, then cannot_restart" do
        tmux.start_commands = [{window: 0, index: 1, id: "%5", start_command: "claude"}]
        due_entry(attempts: 0)
        desk.scan
        expect(messages).to eq([message])

        next_attempt
        expect_gave_up("cannot_restart")
        expect(signals).to eq([])
      end
    end

    it "drives a whole outage to success, and the next outage types first again" do
      after_each = lambda do |attempts|
        expect(entry).to include("phase" => "waiting", "attempts" => attempts, "stopped" => false)
        expect(entry["last_signal_at"]).to be_nil
      end

      failed
      now[0] = t0 + 61
      hooks[:enter] = lambda {
        event("user_prompt")
        failed
      }
      desk.scan
      expect(outcomes).to eq(["typed"])
      expect(signals).to eq([])
      expect(resumes).to eq([])
      after_each.call(1)

      hooks[:enter] = nil
      hooks[:signal] = -> { agent_exits }
      hooks[:deliver] = -> { agent_resumes(answers: false) }
      next_attempt
      expect(outcomes).to eq(%w[typed no_response])
      expect(signals).to eq([["INT", 20]])
      expect(resumes.size).to eq(1)
      after_each.call(2)
      expect(entry).to include("agent_pid" => 21, "draft_text" => a_string_matching(/workspace restarted Claude Code/))

      tmux.screen = "#{rule_prompt}#{entry["draft_text"]}\n"
      hooks[:signal] = lambda {
        processes.reject! { |process| process[:pid] == 21 }
        agent_exits
      }
      hooks[:deliver] = lambda {
        tmux.screen = empty_prompt
        agent_resumes(pid: 22)
      }
      next_attempt
      expect(outcomes).to eq(%w[typed no_response resumed])
      expect(lines.map { |line| line["attempt"] }).to eq([1, 2, 3])
      expect(lines.map { |line| line["mode"] }).to eq(%w[typed restart restart])
      expect(signals).to eq([["INT", 20], ["INT", 21]])
      expect(resumes.size).to eq(2)
      expect(entry).to include("phase" => "watching", "attempts" => 3, "stopped" => false, "last_signal_at" => nil,
        "agent_pid" => 22)

      event("stop")
      expect(entry).to be_nil
      expect(inbox.list.map { |item| item["state"] } - ["done"]).to eq([])

      hooks[:signal] = nil
      hooks[:deliver] = nil
      failed
      now[0] += 61
      hooks[:enter] = -> { event("user_prompt") }
      desk.scan

      expect(lines.last).to include("attempt" => 1, "mode" => "typed", "outcome" => "typed")
      expect(signals).to eq([["INT", 20], ["INT", 21]])
      expect(resumes.size).to eq(2)
    end

    it "goes from a failure through a typed attempt and a restart to a stop, entry gone, lines in order" do
      failed
      now[0] = t0 + 61
      desk.scan
      expect(signals).to eq([])

      healthy_run
      next_attempt
      event("stop")

      expect(entry).to be_nil
      expect(signals).to eq([["INT", 20]])
      base = {"session_id" => sid, "pane_id" => "%5", "error" => "server_error"}
      expect(events).to eq([
        ["agent_recovery_attempt", "api", base.merge("attempt" => 1, "mode" => "typed", "outcome" => "no_response")],
        ["agent_recovery_attempt", "api", base.merge("attempt" => 2, "mode" => "restart", "outcome" => "resumed")]
      ])
    end
  end
end
