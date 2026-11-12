require "spec_helper"

RSpec.describe Workspace::RecoveryAttemptRunner do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:t0) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:now) { [t0] }
  let(:calls) { [] }
  let(:sleeps) { [] }
  let(:on_sleep) { [nil] }
  let(:old_agent) { {pid: 20, started: "Mon", flags: ["--model", "opus"]} }
  let(:new_agent) { {pid: 30, started: "Tue", flags: ["--model", "opus"]} }
  let(:detail) { {id: "%5", pid: 10} }
  let(:agents) { [old_agent] }
  let(:facts_options) { {} }
  let(:facts) { RecordingAttemptFacts.new(detail: detail, agents: agents, calls: calls, **facts_options) }
  let(:entry) { {"phase" => "attempting", "session_id" => sid, "attempts" => 2, "stopped" => true, "last_signal_at" => "x"} }
  let(:store) { RecordingRecoveryStore.new(entries: {"%5" => entry}) }
  let(:monitor) { RecordingRecoveryMonitor.new(agent_pid: 30, calls: calls) }
  let(:readiness) { RecordingReadiness.new(calls: calls) }
  let(:marker) { RecordingStopMarker.new(calls: calls) }
  let(:typer_options) { {} }
  let(:typer) { RecordingAttemptTyper.new(calls: calls, **typer_options) }
  let(:pane) { FakePane.new(id: "%5", session_name: "api") }
  let(:claimed) { ["%5"] }
  let(:rebound) { [] }
  let(:on_rebind) { [nil] }

  subject(:runner) do
    described_class.new(panes: FakePaneFactory.new(panes: [pane]), session_name: "api", store: store, facts: facts,
      session_monitor: monitor, readiness: readiness, detector: :detector, marker: marker, prompt_typer: typer,
      delivery_lock: Mutex.new, restarting: ->(pane_id) { claimed.include?(pane_id) },
      rebind_queue: ->(pane_id, pid) {
        rebound << [pane_id, pid]
        on_rebind[0]&.call
      },
      clock: BlockClock.new { now[0] },
      sleeper: ->(seconds) {
        sleeps << seconds
        now[0] += seconds
        on_sleep[0]&.call
      })
  end

  def attempt(**fields)
    Workspace::RecoveryAttemptRunner::Attempt.new(pane_id: "%5", session_id: sid, number: 2, mode: "restart", pid: 20, started: "Mon",
      command: "claude --resume #{sid}", message: "Continue where you left off.", resume_only: false, opened_at: t0 - 1,
      **fields)
  end

  def set(**fields) = store.put("%5", store.get("%5").merge(fields.transform_keys(&:to_s)))

  def typed_texts = calls.select { |call| call.first == :type }.map(&:last)

  # What the agent was typed through the typer, and what reached the pane through tmux.
  def messages = typer.calls.select { |call| call.first == :type }.map(&:last)

  def texts = pane.deliveries.map { |sent| sent[:text] }

  def resumes = texts.grep(/--resume/)

  describe "#typed" do
    it "types the message under the claim, then answers typed once a user_prompt hook says it arrived" do
      on_sleep[0] = -> { set(prompt_seen: true) }

      expect(runner.typed(attempt)).to eq(["typed"])
      expect(typed_texts).to eq(["Continue where you left off."])
      expect(calls.first(4)).to eq([[:pane_detail, "%5"], [:agent, detail], [:foreground?, 20, detail], [:type, "%5", "Continue where you left off."]])
    end

    it "answers no_response when no hook comes in the prompt wait" do
      expect(runner.typed(attempt)).to eq(["no_response"])
      expect(sleeps.count(described_class::POLL_INTERVAL)).to eq(described_class::PROMPT_WAIT)
    end

    it "types nothing once the claim is lost" do
      claimed.clear

      expect(runner.typed(attempt)).to eq(["claim_lost"])
      expect(typed_texts).to be_empty
    end

    it "types nothing to an agent whose process group doesn't hold the terminal" do
      facts_options[:foreground] = false

      expect(runner.typed(attempt)).to eq(["pane_not_clear"])
      expect(typed_texts).to be_empty
    end

    it "names an agent it didn't start person_resumed when it holds the attempt's session" do
      agents.replace([new_agent])
      set(attempt_session_id: sid)

      expect(runner.typed(attempt)).to eq(["person_resumed", new_agent])
      expect(typed_texts).to be_empty
    end

    it "names it fresh_agent when no SessionStart of the attempt's session comes in the session wait" do
      agents.replace([new_agent])

      expect(runner.typed(attempt)).to eq(["fresh_agent"])
      expect(sleeps.sum).to eq(described_class::SESSION_WAIT)
    end

    it "presses Enter itself after a paste whose Enter wasn't confirmed, once the pane is read again" do
      typer_options[:outcomes] = [{outcome: :not_submitted}]
      on_sleep[0] = -> { set(prompt_seen: true) }

      expect(runner.typed(attempt)).to eq(["typed"])
      expect(calls).to include([:check, "%5", {pasted: "Continue where you left off."}])
      expect(pane.deliveries).to eq([{text: "", enter: true}])
    end

    it "leaves the text unsubmitted when the input line no longer holds it" do
      typer_options[:outcomes] = [{outcome: :not_submitted}]
      typer_options[:refusal] = {code: "input_not_empty"}

      expect(runner.typed(attempt)).to eq(["not_submitted"])
      expect(pane.deliveries).to be_empty
    end

    it "tries again while the pane's state is unknown, and gives up not_typed after the last try" do
      typer_options[:outcomes] = [{outcome: :refused, reason: "unknown"}]

      expect(runner.typed(attempt)).to eq(["not_typed"])
      expect(typed_texts.size).to eq(described_class::TYPE_TRIES)
    end

    it "pastes nothing after a prompt the monitor saw since the attempt opened" do
      facts_options[:prompt_after] = true

      expect(runner.typed(attempt)).to eq(["not_typed"])
      expect(calls).to include([:prompt_after?, "%5", t0 - 1])
    end
  end

  describe "#restart" do
    let(:agents) { [old_agent, nil, nil, nil, new_agent] }
    let(:facts_options) { {live: new_agent} }

    before { set(attempt_session_id: sid) }

    it "waits for the agent to leave, types the resume line, waits for the new agent and types the message" do
      on_sleep[0] = -> { set(prompt_seen: true) if store.get("%5")["draft_text"] }
      running = attempt

      expect(runner.restart(running)).to eq(["resumed", nil])
      expect(pane.keys).to eq(["C-u"])
      expect(pane.deliveries).to eq([{text: "claude --resume #{sid}", enter: true}])
      expect(calls).to include([:wait, "api", described_class::READY_WAIT, "%5"], [:clear_marker, sid])
      expect(running.pid).to eq(30)
      expect(rebound).to eq([["%5", 30]])
      expect(store.get("%5")).to include("agent_pid" => 30, "agent_started" => "Tue", "stopped" => false,
        "last_signal_at" => nil, "draft_text" => "Continue where you left off.")
      expect(typed_texts).to eq(["Continue where you left off."])
    end

    it "answers not_stopped when the agent is still there after the stop wait" do
      agents.replace([old_agent])

      expect(runner.restart(attempt)).to eq(["not_stopped"])
      expect(sleeps.sum).to eq(described_class::STOP_WAIT)
      expect(pane.deliveries).to be_empty
    end

    it "skips the exit wait for a resume_only attempt" do
      agents.replace([nil, new_agent])
      on_sleep[0] = -> { set(prompt_seen: true) }

      expect(runner.restart(attempt(resume_only: true, pid: nil, started: nil))).to eq(["resumed", nil])
      expect(calls.first).to eq([:session_held?, sid])
    end

    it "types no resume line while another process holds the session" do
      facts_options[:held] = true

      expect(runner.restart(attempt)).to eq(["pane_not_clear"])
      expect(pane.keys).to be_empty
    end

    it "types no resume line once the conversation was resumed elsewhere" do
      on_sleep[0] = -> { set(resumed_elsewhere: true) }

      expect(runner.restart(attempt)).to eq(["resumed_elsewhere"])
      expect(pane.deliveries).to be_empty
    end

    it "answers not_ready when no agent comes up after the resume line" do
      facts_options[:live] = nil

      expect(runner.restart(attempt)).to eq(["not_ready"])
      expect(typed_texts).to be_empty
    end

    it "answers fresh_agent when the new agent starts another session" do
      set(attempt_session_id: other_sid)

      expect(runner.restart(attempt)).to eq(["fresh_agent"])
      expect(rebound).to be_empty
    end

    it "registers no binding" do
      expect(Workspace::PaneBindings).not_to receive(:new)
      on_sleep[0] = -> { set(prompt_seen: true) if store.get("%5")["draft_text"] }
      runner.restart(attempt)
    end

    it "doesn't take a prompt the worker read before typing for the answer" do
      set(prompt_seen: true)
      outcomes = runner.restart(attempt).first(1)

      expect(outcomes).to eq(["no_response"])
    end

    describe "the flags a resume carries" do
      let(:skip) { "--dangerously-skip-permissions" }
      let(:resumed) { {pid: 21, started: "Tue", flags: [skip]} }
      let(:agents) { [old_agent, nil, nil, nil, resumed] }
      let(:facts_options) { {live: resumed} }
      let(:opening) { {"phase" => "attempting", "session_id" => sid, "attempts" => 2, "stopped" => true, "agent_flags" => [skip]} }
      let(:store) { RecordingRecoveryStore.new(entries: {"%5" => opening}) }

      def entry = store.get("%5")

      it "stores the flags of an agent we resumed, so the next attempt carries them" do
        runner.restart(attempt)

        expect(resumes.size).to eq(1)
        expect(entry).to include("agent_pid" => 21, "agent_flags" => [skip])
      end
    end

    describe "step 2" do
      it "types nothing on a single pane_clear? read" do
        agents.replace([nil])
        reads = 0
        allow(facts).to receive(:pane_clear?) { (reads += 1).odd? }
        outcomes = runner.restart(attempt).first(1)

        expect(texts).to eq([])
        expect(outcomes).to eq(["not_stopped"])
      end
    end

    describe "the safety review's guards" do
      it "empties the shell's line, in its own call, right before the resume command" do
        keys = []
        pane.tmux.on_deliver = ->(text) { keys.concat(pane.tmux.sent_key_names) if text.include?("--resume") }
        runner.restart(attempt)

        expect(keys).to eq([{session: "api", pane: "%5", key: "C-u"}])
      end

      it "types nothing when the C-u call fails" do
        allow(pane).to receive(:send_key).and_return(false)
        outcomes = runner.restart(attempt).first(1)

        expect(texts).to eq([])
        expect(outcomes).to eq(["not_delivered"])
      end
    end

    describe "step 5's identity check" do
      it "types no message once the claim is gone" do
        on_rebind[0] = -> { claimed.clear }
        outcomes = runner.restart(attempt).first(1)

        expect(messages).to eq([])
        expect(outcomes).to eq(["claim_lost"])
      end

      context "with a typer of its own calls" do
        let(:typer) { RecordingAttemptTyper.new(**typer_options) }

        it "types no message to an agent that isn't the attempt's" do
          agents.replace([old_agent, nil, nil, nil, new_agent.merge(started: "Mon Oct 26 12:00:00 2026")])
          runner.restart(attempt)

          expect(messages).to eq([])
          expect(typer.calls).to be_empty
        end
      end
    end
  end

  describe "#rebind" do
    it "rescans the pane, then moves its queued prompts to the monitor's agent pid" do
      runner.rebind("%5")

      expect(calls).to eq([[:rescan_pane, "%5"], [:agent_pid, "%5"]])
      expect(rebound).to eq([["%5", 30]])
    end

    it "moves nothing while the monitor names no agent" do
      monitor = RecordingRecoveryMonitor.new(calls: calls)
      runner = described_class.new(panes: FakePaneFactory.new, session_name: "api", store: store, facts: facts,
        session_monitor: monitor, readiness: readiness, detector: :detector, marker: marker, prompt_typer: typer,
        delivery_lock: Mutex.new, restarting: ->(_) { true }, rebind_queue: ->(pane_id, pid) { rebound << [pane_id, pid] })

      runner.rebind("%5")

      expect(rebound).to be_empty
    end
  end

  describe described_class::Attempt do
    it "knows its own agent by pid and start time" do
      expect(attempt.ours?(old_agent)).to be(true)
      expect(attempt.ours?(old_agent.merge(started: "Tue"))).to be(false)
    end

    it "knows its entry by phase, session and attempt number" do
      expect(attempt.current?(entry)).to be(true)
      expect(attempt.current?(entry.merge("attempts" => 3))).to be(false)
      expect(attempt.current?(entry.merge("phase" => "waiting"))).to be(false)
    end
  end
end
