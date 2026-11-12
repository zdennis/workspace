require "spec_helper"

RSpec.describe Workspace::RecoveryOutcomes do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:now) { [Time.utc(2026, 11, 12, 12, 0, 0)] }
  let(:calls) { [] }
  let(:log) { StringIO.new }
  let(:agent) { {pid: 20, started: "Mon", flags: []} }
  let(:details) { {"%5" => {id: "%5", pid: 10}} }
  let(:agents) { {10 => agent} }
  let(:store) { RecordingRecoveryStore.new(calls: calls) }
  let(:facts) { RecordingConfirmerFacts.new(details: details, agents: agents, calls: calls) }
  let(:inbox) { RecordingRecoveryInbox.new(calls: calls) }
  let(:runner) { RecordingStepRunner.new(calls: calls) }
  let(:event_log) { RecordingRecoveryEventLog.new(calls: calls) }

  subject(:outcomes) do
    described_class.new(workspace: "api", store: store, facts: facts, inbox: -> { inbox }, runner: runner, event_log: event_log,
      max_attempts: 3, clock: BlockClock.new { now[0] }, logger: Workspace::Logger.new(output: log, enabled: true))
  end

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  def waiting(**fields)
    {"session_id" => sid, "transcript_path" => "/t/session.jsonl", "error" => "server_error", "attempts" => 1,
     "phase" => "waiting", "stopped" => false, "failed_at" => stamp(now[0] - 60), "next_attempt_at" => stamp(now[0]),
     "agent_pid" => 20, "agent_started" => "Mon"}.merge(fields.transform_keys(&:to_s))
  end

  def attempt(number: 2, mode: "restart")
    Workspace::RecoveryAttemptRunner::Attempt.new(pane_id: "%5", session_id: sid, number: number, mode: mode, pid: 20,
      started: "Mon", message: "go on", resume_only: false, opened_at: now[0])
  end

  def attempting(**fields) = waiting(phase: "attempting", attempts: 2).merge(fields.transform_keys(&:to_s))

  def entry = store.get("%5")

  def gave_up_lines = event_log.lines.select { |type, _, _| type == "agent_recovery_gave_up" }

  describe "#refuse" do
    it "starts the defer clock, then gives up deferred after DEFER_LIMIT, with one line and one item" do
      store.put("%5", waiting)
      outcomes.refuse("%5", entry, :defer)
      expect(entry["defer_since"]).to eq(stamp(now[0]))

      now[0] += described_class::DEFER_LIMIT
      outcomes.refuse("%5", entry, :defer)

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "deferred", "next_attempt_at" => nil)
      expect(gave_up_lines).to eq([["agent_recovery_gave_up", "api",
        {"pane_id" => "%5", "session_id" => sid, "attempts" => 1, "error" => "server_error", "reason" => "deferred"}]])
      expect(inbox.items.map { |item| item["body"] }).to eq([
        "The turn failed with server_error, and the pane stayed busy or unreadable for 30 minutes, so workspace " \
        "stopped trying. Nothing was stopped or typed in those 30 minutes. Session #{sid}."
      ])
    end

    it "deletes an entry with no attempts on :clear, and reports nothing" do
      store.put("%5", waiting(attempts: 0))
      outcomes.refuse("%5", entry, :clear)

      expect(entry).to be_nil
      expect(event_log.lines).to eq([])
      expect(inbox.items).to eq([])
    end

    it "gives up unconfirmed on :clear after attempts" do
      store.put("%5", waiting)
      outcomes.refuse("%5", entry, :clear)

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "unconfirmed")
      expect(inbox.items.first["body"]).to start_with("After 1 recovery attempts workspace can no longer confirm")
    end

    it "gives up cannot_restart on :never" do
      store.put("%5", waiting)
      outcomes.refuse("%5", entry, :never)

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "cannot_restart")
      expect(gave_up_lines.size).to eq(1)
    end

    it "leaves alone an entry a hook changed since the check read it" do
      store.put("%5", waiting)
      seen = entry
      store.put("%5", waiting(failed_at: stamp(now[0])))

      outcomes.refuse("%5", seen, :never)

      expect(entry["phase"]).to eq("waiting")
      expect(event_log.lines).to eq([])
    end
  end

  describe "#report_give_up" do
    it "writes the item for the workspace, keyed on the session, and reopens it" do
      store.put("%5", waiting(phase: "gave_up", give_up_reason: "not_retryable", error: "billing_error"))
      outcomes.report_give_up("%5", entry)

      expect(inbox.items.first).to include("type" => "alert", "scope" => {"kind" => "workspace", "key" => "api", "name" => "api"},
        "title" => "The agent in pane %5 needs you: workspace could not recover it from an API error",
        "dedupe_key" => "agent-recovery:#{sid}", "links" => {"pane" => "%5"},
        "source" => {"kind" => "session", "ref" => sid, "url" => nil})
      expect(calls).to include([:upsert, "agent-recovery:#{sid}", true])
      expect(calls).not_to include(a_collection_including(:transition_by_key))
    end

    it "names both errors when an unconfirmed give-up made no attempt" do
      store.put("%5", waiting(phase: "gave_up", give_up_reason: "unconfirmed", attempts: 0, item_error: "overloaded"))
      outcomes.report_give_up("%5", entry)

      expect(inbox.items.first["body"]).to start_with("A turn failed with overloaded, then with server_error")
    end

    it "resolves the item when the entry is gone or another session's by the time the item is written" do
      gone = RecordingRecoveryInbox.new(on_upsert: -> { store.update("%5", &:clear) }, calls: calls)
      store.put("%5", waiting(phase: "gave_up", give_up_reason: "deferred"))
      seen = entry
      described_class.new(workspace: "api", store: store, facts: facts, inbox: -> { gone }, runner: runner).report_give_up("%5", seen)

      expect(calls).to include([:transition_by_key, "agent-recovery:#{sid}", "done"])
    end

    it "logs an inbox it can't write, after the line" do
      broken = RecordingRecoveryInbox.new(error: Workspace::Error.new("full"), calls: calls)
      store.put("%5", waiting(phase: "gave_up", give_up_reason: "deferred"))
      described_class.new(workspace: "api", store: store, facts: facts, inbox: -> { broken }, runner: runner, event_log: event_log,
        logger: Workspace::Logger.new(output: log, enabled: true)).report_give_up("%5", entry)

      expect(gave_up_lines.size).to eq(1)
      expect(log.string).to include("agent recovery: no inbox item for %5 (Workspace::Error: full)")
    end
  end

  describe "#resolve" do
    it "moves the session's item to done" do
      outcomes.resolve(sid)

      expect(calls).to eq([[:transition_by_key, "agent-recovery:#{sid}", "done"]])
    end
  end

  describe "#finish" do
    it "reads the pane, writes watching for a resumed agent, then the line" do
      store.put("%5", attempting(stopped: true, last_signal_at: stamp(now[0])))
      calls.clear
      outcomes.finish(attempt, "resumed")

      expect(entry).to include("phase" => "watching", "last_signal_at" => nil)
      expect(event_log.lines).to eq([["agent_recovery_attempt", "api",
        {"attempt" => 2, "session_id" => sid, "pane_id" => "%5", "error" => "server_error", "mode" => "restart", "outcome" => "resumed"}]])
      expect(calls.map(&:first).first(3)).to eq([:pane_detail, :agent, :update])
    end

    it "says agent_left when a typed attempt ends with the pane empty, and gives up unconfirmed" do
      agents.clear
      store.put("%5", waiting(phase: "attempting"))
      outcomes.finish(attempt(number: 1, mode: "typed"), "typed")

      expect(event_log.lines.first[2]).to include("mode" => "typed", "outcome" => "agent_left")
      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "unconfirmed")
    end

    it "moves the queue to an agent that isn't the attempt's, before the write" do
      agents[10] = {pid: 30, started: "Tue"}
      store.put("%5", attempting)
      outcomes.finish(attempt, "no_response")

      expect(calls.index([:rebind, "%5"])).to be < calls.index([:update, "%5"])
    end

    it "keeps the message as a draft and waits for the next attempt after no_response" do
      store.put("%5", attempting)
      outcomes.finish(attempt, "no_response")

      expect(entry).to include("phase" => "waiting", "draft_text" => "go on")
    end

    it "gives up attempts_exhausted at the last attempt, with its line first" do
      store.put("%5", attempting(attempts: 3))
      outcomes.finish(attempt(number: 3), "not_stopped")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted")
      expect(event_log.lines.map(&:first)).to eq(%w[agent_recovery_attempt agent_recovery_gave_up])
    end

    it "takes a finished turn a hook left, deleting the entry and resolving its item" do
      store.put("%5", attempting(turn_completed: true))
      outcomes.finish(attempt, "resumed")

      expect(entry).to be_nil
      expect(calls).to include([:transition_by_key, "agent-recovery:#{sid}", "done"])
    end

    it "gives up fresh_conversation when the attempt saw another session start" do
      store.put("%5", attempting(attempt_session_id: other_sid))
      outcomes.finish(attempt, "resumed")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "fresh_conversation")
    end

    it "schedules again a turn that failed during the attempt" do
      store.put("%5", attempting(failed_during_attempt: true))
      outcomes.finish(attempt, "resumed")

      expect(entry).to include("phase" => "waiting", "failed_at" => stamp(now[0]))
      expect(entry).not_to include("failed_during_attempt")
    end

    it "writes nothing for an entry that isn't the attempt's any more" do
      store.put("%5", waiting)
      outcomes.finish(attempt, "resumed")

      expect(event_log.lines).to eq([])
      expect(entry["phase"]).to eq("waiting")
    end
  end

  describe "#take_back" do
    it "puts back what step 1 changed and answers the answer given while the agent is there" do
      seen = waiting(defer_since: stamp(now[0] - 5))
      store.put("%5", attempting(stopped: true, last_signal_at: stamp(now[0]), defer_since: nil))

      expect(outcomes.take_back(attempt, seen, :defer)).to eq(:defer)
      expect(entry).to include("phase" => "waiting", "attempts" => 1, "stopped" => false, "last_signal_at" => nil,
        "defer_since" => stamp(now[0] - 5))
    end

    it "answers :clear for an empty pane no recent signal explains" do
      agents.clear
      store.put("%5", attempting)

      expect(outcomes.take_back(attempt, waiting, :defer)).to eq(:clear)
    end

    it "keeps the answer for an empty pane our recent signal explains" do
      agents.clear
      store.put("%5", attempting)

      expect(outcomes.take_back(attempt, waiting(last_signal_at: stamp(now[0] - 5)), :defer)).to eq(:defer)
    end
  end

  shared_context "an attempt's end" do
    let(:part) do
      described_class.new(workspace: "api", store: store, facts: facts, inbox: -> { inbox }, runner: runner, event_log: event_log,
        clock: BlockClock.new { now[0] }, logger: Workspace::Logger.new(output: log, enabled: true))
    end

    def events = event_log.lines

    def lines = events.select { |type, _, _| type == "agent_recovery_attempt" }.map(&:last)

    # The outcome each attempt line names, so the part under test is +part+ here.
    def outcomes = lines.map { |line| line["outcome"] }

    def expect_rescheduled(attempts)
      expect(entry).to include("phase" => "waiting", "attempts" => attempts, "last_turn_uuid" => nil, "defer_since" => nil,
        "next_attempt_at" => stamp(now[0] + Workspace::AgentRecoveryStore.wait_before(attempts + 1)))
      expect(entry).not_to include("attempt_session_id", "prompt_seen")
    end

    def expect_gave_up(reason, items: 1)
      expect(entry).to include("phase" => "gave_up", "give_up_reason" => reason)
      expect(inbox.items.size).to eq(items)
      expect(events.reverse.find { |type, _, _| type == "agent_recovery_gave_up" }[2]).to include("reason" => reason)
    end
  end

  describe "#finish of a restart attempt" do
    include_context "an attempt's end"

    let(:t0) { now[0] - 3600 }

    def restart_attempt(number: 2)
      Workspace::RecoveryAttemptRunner::Attempt.new(pane_id: "%5", session_id: sid, number: number, mode: "restart", pid: 20,
        started: "Mon", message: format(Workspace::RecoveryAttempts::RESUMED_MESSAGE, error: "server_error"),
        resume_only: false, opened_at: now[0])
    end

    it "keeps user text out of the event lines" do
      store.put("%5", attempting(prompt_seen: true))
      part.finish(restart_attempt, "resumed")

      expect(events.to_s).not_to include("Continue where")
    end

    it "keeps the draft of the attempt before while that agent won't stop" do
      store.put("%5", attempting(draft_text: "ours"))
      part.finish(restart_attempt, "not_stopped")

      expect(outcomes).to eq(["not_stopped"])
      expect(entry["draft_text"]).to eq("ours")
    end

    it "takes a stop in the wait ahead of no_response" do
      store.put("%5", attempting(turn_completed: true))
      part.finish(restart_attempt, "no_response")

      expect(entry).to be_nil
      expect(outcomes).to eq(["no_response"])
    end

    it "takes a failed turn in the wait ahead of no_response" do
      store.put("%5", attempting(failed_during_attempt: true, error: "overloaded"))
      part.finish(restart_attempt, "no_response")

      expect(entry).to include("phase" => "waiting", "attempts" => 2, "error" => "overloaded")
      expect(entry).not_to include("failed_during_attempt")
    end

    it "stays resumed, and resolves, when a Stop came before the pane emptied" do
      agents.clear
      store.put("%5", attempting(turn_completed: true, prompt_seen: true))
      part.finish(restart_attempt, "resumed")

      expect(outcomes).to eq(["resumed"])
      expect(entry).to be_nil
    end

    it "gives up when the pane reads as gone at step 6, with stopped false" do
      details.clear
      store.put("%5", attempting(prompt_seen: true))
      part.finish(restart_attempt, "resumed")

      expect(outcomes).to eq(["agent_left"])
      expect(entry["stopped"]).to be(false)
      expect_gave_up("unconfirmed")
    end

    it "stays resumed, and watches, when the last read fails" do
      store.put("%5", attempting(prompt_seen: true))
      described_class.new(workspace: "api", store: store, facts: RecordingConfirmerFacts.new(details: details, agents: agents,
        tree: nil, calls: calls), inbox: -> { inbox }, runner: runner, event_log: event_log, clock: BlockClock.new { now[0] })
        .finish(restart_attempt, "resumed")

      expect(outcomes).to eq(["resumed"])
      expect(entry["phase"]).to eq("watching")
    end

    it "gives up unconfirmed at 12 on agent_left, going round no more" do
      agents.clear
      store.put("%5", attempting(attempts: 12, prompt_seen: true))
      part.finish(restart_attempt(number: 12), "resumed")

      expect(outcomes).to eq(["agent_left"])
      expect_gave_up("unconfirmed")
      expect(entry["attempts"]).to eq(12)
    end

    it "reaches step 6 with a stop right after it" do
      store.put("%5", attempting(attempt_session_id: sid, turn_completed: true))
      part.finish(restart_attempt, "resumed")

      expect(entry).to be_nil
      expect(outcomes).to eq(["resumed"])
    end

    it "reaches step 6 with a turn_failed right after it" do
      store.put("%5", attempting(attempt_session_id: sid, failed_during_attempt: true, failed_at: stamp(t0)))
      part.finish(restart_attempt, "resumed")

      expect_rescheduled(2)
      expect(entry["failed_at"]).not_to eq(stamp(t0))
    end

    it "gives up when a session other than the entry's opened during the attempt" do
      store.put("%5", attempting(attempt_session_id: other_sid))
      part.finish(restart_attempt, "not_stopped")

      expect_gave_up("fresh_conversation")
    end

    describe "step 6" do
      failing = %w[not_stopped claim_lost pane_not_clear not_delivered not_ready not_typed not_submitted no_response agent_left]
      person = {pid: 21, started: "Mon Oct 26 11:00:00 2026"}

      let(:message) { /\AAn API error stopped your last turn \(server_error\), so workspace restarted Claude Code/ }

      # The entry step 1 left, signal sent, with what the hooks during the attempt wrote on it.
      def opened(**fields) = store.put("%5", attempting(stopped: true, last_signal_at: stamp(now[0]), **fields))

      def run_to(outcome, agent: nil, number: 2) = part.finish(restart_attempt(number: number), outcome, agent: agent)

      (failing + %w[resumed typed resumed_elsewhere person_resumed fresh_agent]).each do |outcome|
        found = (outcome == "person_resumed") ? person : nil

        it "honours a stop during #{outcome}" do
          opened(turn_completed: true)
          run_to(outcome, agent: found)

          expect(entry).to be_nil
          expect(outcomes).to eq([outcome])
        end

        it "honours a retryable failure during #{outcome}" do
          opened(failed_during_attempt: true, error: "overloaded")
          run_to(outcome, agent: found)

          expect(entry).to include("phase" => "waiting", "attempts" => 2, "error" => "overloaded")
          expect(entry).not_to include("failed_during_attempt")
          expect(entry["agent_pid"]).not_to be_nil
        end

        it "gives up on a non-retryable error during #{outcome}" do
          opened(failed_during_attempt: true, error: "billing_error")
          run_to(outcome, agent: found)

          expect_gave_up("not_retryable")
          expect(entry["attempts"]).to eq(2)
        end
      end

      failing.each do |outcome|
        it "schedules #{outcome} with the count raised" do
          opened
          run_to(outcome)

          expect_rescheduled(2)
          expect(entry["stopped"]).to be(false)
        end

        it "gives up at 12 with one item on #{outcome}" do
          opened(attempts: 12)
          run_to(outcome, number: 12)

          expect_gave_up("attempts_exhausted")
          expect(entry["attempts"]).to eq(12)
          expect(events.map(&:first)).to eq(%w[agent_recovery_attempt agent_recovery_gave_up])
        end

        it "sets stopped on #{outcome} when no agent is left" do
          agents.clear
          opened
          run_to(outcome)

          expect(entry["stopped"]).to be(true)
        end
      end

      it "keeps stopped when the last read fails" do
        opened
        described_class.new(workspace: "api", store: store, facts: RecordingConfirmerFacts.new(details: details, agents: agents,
          tree: nil, calls: calls), inbox: -> { inbox }, runner: runner, event_log: event_log, clock: BlockClock.new { now[0] })
          .finish(restart_attempt, "not_stopped")

        expect(entry["stopped"]).to be(true)
      end

      it "sets draft_text on not_submitted and no_response, nowhere else" do
        opened
        run_to("no_response")
        expect(entry["draft_text"]).to match(message)

        opened(draft_text: "ours")
        run_to("resumed")
        expect(entry["draft_text"]).to be_nil
      end

      it "moves a typed attempt to watching, for T13" do
        opened(draft_text: "ours")
        run_to("typed")

        expect(entry).to include("phase" => "watching", "draft_text" => nil)
      end

      it "writes no line for an entry reconcile already took" do
        opened(phase: "waiting")
        run_to("not_ready")

        expect(lines).to eq([])
      end

      it "gives up at the last attempt from a restart, and its line says restart" do
        agents.clear
        opened(attempts: 12)
        run_to("not_ready", number: 12)

        expect_gave_up("attempts_exhausted")
        expect(lines.map { |line| line.values_at("mode", "outcome") }).to eq([%w[restart not_ready]])
      end
    end
  end

  describe "#finish of a typed attempt" do
    include_context "an attempt's end"

    def typed_attempt
      Workspace::RecoveryAttemptRunner::Attempt.new(pane_id: "%5", session_id: sid, number: 1, mode: "typed", pid: 20,
        started: "Mon", message: format(Workspace::RecoveryAttempts::TYPED_MESSAGE, error: "server_error"),
        resume_only: false, opened_at: now[0])
    end

    def opened(**fields) = store.put("%5", attempting(attempts: 1, draft_text: typed_attempt.message, **fields))

    it "keeps user text out of the event lines" do
      opened(prompt_seen: true)
      part.finish(typed_attempt, "typed")

      expect(events).not_to be_empty
      expect(events.to_s).not_to include("Continue where")
    end

    it "a non-retryable failure hook with the agent gone stays not_retryable" do
      agents.clear
      opened(failed_during_attempt: true, error: "billing_error")
      part.finish(typed_attempt, "no_response")

      expect_gave_up("not_retryable")
    end

    it "a process that never answers leaves stopped alone" do
      opened
      part.finish(typed_attempt, "no_response")

      expect(entry).to include("stopped" => false, "agent_pid" => 20)
    end

    it "gives up at the last attempt from a typed one, and its line says typed" do
      opened
      described_class.new(workspace: "api", store: store, facts: facts, inbox: -> { inbox }, runner: runner, event_log: event_log,
        max_attempts: 1, clock: BlockClock.new { now[0] }).finish(typed_attempt, "no_response")

      expect_gave_up("attempts_exhausted")
      expect(lines.map { |line| line.values_at("mode", "outcome") }).to eq([%w[typed no_response]])
    end

    describe "step 6's hooks, for each outcome" do
      agent = {pid: 21, started: "Mon Oct 26 11:00:00 2026"}

      def run_to(outcome, agent: nil) = part.finish(typed_attempt, outcome, agent: agent)

      %w[typed no_response claim_lost pane_not_clear not_typed not_submitted person_resumed fresh_agent].each do |outcome|
        found = (outcome == "person_resumed") ? agent : nil

        it "honours a stop during #{outcome}" do
          opened(turn_completed: true)
          run_to(outcome, agent: found)

          expect(entry).to be_nil
          expect(outcomes).to eq([outcome])
        end

        it "honours a retryable failure during #{outcome}" do
          opened(failed_during_attempt: true, error: "overloaded")
          run_to(outcome, agent: found)

          expect(entry).to include("phase" => "waiting", "attempts" => 1, "error" => "overloaded")
          expect(entry).not_to include("failed_during_attempt")
        end

        it "gives up on a non-retryable error during #{outcome}" do
          opened(failed_during_attempt: true, error: "billing_error")
          run_to(outcome, agent: found)

          expect_gave_up("not_retryable")
          expect(entry["attempts"]).to eq(1)
        end
      end
    end
  end
end
