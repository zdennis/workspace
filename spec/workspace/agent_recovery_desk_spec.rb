require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentRecoveryDesk do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:started) { "Mon Oct 26 10:00:00 2026" }
  let(:empty_prompt) { "────────\n❯ \n" }

  let(:tmux) do
    Class.new(CLITestHelpers::FakeTmux) do
      attr_accessor :details, :screen, :scripted, :start_commands

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

      def pane_start_commands(_session) = @start_commands

      def server_pid_for_pane(_pane_id) = "77"

      def capture_screen(_pane_id) = @scripted ? @scripted.call : @screen

      def deliver(session, pane, text, enter: true)
        @screen = enter ? @empty : @screen.sub(/❯ \n\z/, "❯ #{text}\n")
        sent_keys << {session: session, pane: pane, text: text, enter: enter}
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
        Workspace::ProcessTree::Snapshot.new(processes)
      end
    end
  end
  let(:signals) { [] }
  let(:group_ids) { [10, 10] }
  let(:stopper) do
    Workspace::AgentStopper.new(process_tree: process_tree, signaller: ->(signal, pid) { signals << [signal, pid] },
      group_reader: ->(_pid) { group_ids })
  end

  let(:dir) { Dir.mktmpdir }
  let(:store) { Workspace::AgentRecoveryStore.new(path: File.join(dir, "agent-recovery.json"), clock: clock) }
  let(:ledger) { Workspace::SessionLedger.new(path: File.join(dir, "ledger.jsonl"), logger: Workspace::Logger.new) }
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
      allow(log).to receive(:record) { |type:, project:, data:| events << [type, project, data] }
    end
  end
  let(:restarting) { [] }
  let(:rebound) { [] }
  let(:spawn) { ->(&block) { block.call } }

  def build_desk(store: self.store)
    described_class.new(tmux: tmux, workspace: "api", session_name: "api", session_monitor: monitor, store: store,
      transcript: Workspace::TranscriptSummary.new, stopper: stopper, detector: Workspace::AgentDetector.new,
      process_tree: process_tree, ledger: ledger, resume_command: resume_command, prompt_typer: typer,
      readiness: double("readiness"), marker: marker, inbox: -> { inbox }, event_log: event_log, delivery_lock: Mutex.new,
      restarting: ->(id) { restarting.include?(id) }, rebind_queue: ->(id, pid) { rebound << [id, pid] }, clock: clock,
      sleeper: ->(seconds) { now[0] += seconds }, spawn: spawn).tap do |built|
      allow(built).to receive(:typed_attempt) { |id, answer| attempts << [:typed, id, answer] }
      allow(built).to receive(:restart_attempt) { |id, answer| attempts << [:restart, id, answer] }
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
      %w[attempts_exhausted cannot_restart fresh_conversation deferred unconfirmed].each do |reason|
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
    it "in attempting writes attempt_session_id and nothing else, for either id" do
      [sid, other_sid].each do |id|
        due_entry(phase: "attempting", stopped: true)
        before = entry
        event("session_start", session: id, source: "resume")

        expect(entry).to eq(before.merge("attempt_session_id" => id))
        expect(desk.holding?("%5")).to be(true)
      end
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

    it "in waiting or watching, same id, not stopped: refreshes the pid" do
      %w[waiting watching].each do |phase|
        due_entry(phase: phase)
        processes.replace([proc_entry(10, 1, "-zsh"), proc_entry(31, 10, "claude", lstart: "Wed")])
        event("session_start", source: "resume")

        expect(entry).to include("phase" => phase, "agent_pid" => 31, "agent_started" => "Wed")
        expect(rebound).to eq([])
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

    it "deletes in waiting with an old signal or none, and in watching" do
      [{last_signal_at: stamp(t0 - 400)}, {}, {phase: "watching", last_signal_at: stamp(t0)}].each do |fields|
        due_entry(**fields)
        event("session_end", reason: "prompt_input_exit")
        expect(entry).to be_nil
      end
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
      expect(marker.marked?(sid)).to be(false)
      expect(events.map(&:first)).to eq(["agent_recovery_attempt"])
      expect(events[0][2]).to eq("attempt" => 2, "session_id" => sid, "pane_id" => "%5", "error" => "server_error",
        "mode" => "restart", "outcome" => "interrupted")
    end

    it "names a first attempt typed" do
      due_entry(phase: "attempting", attempts: 1)
      desk.scan

      expect(events[0][2]).to include("mode" => "typed")
    end

    it "sets stopped when no agent is left, so the next attempt is resume_only" do
      due_entry(phase: "attempting", attempts: 2, stopped: false)
      ledger.record("event" => "session_end", "session_id" => sid)
      gone!
      desk.scan

      expect(entry).to include("phase" => "waiting", "stopped" => true)
      now[0] += 300
      desk.scan
      expect(attempts.first[2]).to have_attributes(answer: :go, mode: :resume_only)
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
end
