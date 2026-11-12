require "spec_helper"

RSpec.describe Workspace::RecoveryAttempts do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:now) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:calls) { [] }
  let(:log) { StringIO.new }
  let(:store) { RecordingRecoveryStore.new(calls: calls) }
  let(:facts) do
    RecordingOpeningFacts.new(transcript: {"uuid" => "u-err", "api_error" => true}, ledger: {"session_id" => sid},
      calls: calls)
  end
  let(:outcomes) { RecordingRecoveryOutcomes.new(calls: calls) }
  let(:attempt_runner) { RecordingStepRunner.new(calls: calls) }
  let(:stopper) { RecordingRecoveryStopper.new(calls: calls) }
  let(:marker) { RecordingStopMarker.new(calls: calls) }
  let(:steps) { Workspace::AgentRecoverySteps.new }
  let(:claim) { [:token] }
  let(:spawned) { [] }
  let(:lines) { [] }
  let(:checked) { [] }
  let(:verdict) { Workspace::AgentRecoveryDesk::Verdict.new(answer: :go, mode: :restart, command: "claude --resume #{sid}") }
  let(:check) do
    lambda { |pane_id, entry, screen: nil|
      checked << [pane_id, entry["attempts"], screen]
      verdict
    }
  end

  subject(:attempts) do
    described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, steps: steps,
      stopper: stopper, marker: marker,
      resume_command: ->(**fields) {
        lines << fields
        "claude --resume #{fields[:session_id]}"
      },
      delivery_lock: Mutex.new,
      claim_restart: ->(pane_id) {
        calls << [:claim, pane_id]
        claim[0]
      },
      release_restart: ->(pane_id, token) { calls << [:release, pane_id, token] },
      spawn: ->(&block) {
        spawned << block
        block.call
      },
      clock: BlockClock.new { now }, logger: Workspace::Logger.new(output: log, enabled: true))
  end

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  def waiting(**fields)
    {"session_id" => sid, "transcript_path" => "/t/session.jsonl", "cwd" => "/work", "error" => "server_error",
     "attempts" => 1, "phase" => "waiting", "stopped" => false, "failed_at" => stamp(now - 60),
     "next_attempt_at" => stamp(now), "agent_pid" => 20, "agent_started" => "Mon", "agent_flags" => [],
     "last_turn_uuid" => "u-err"}.merge(fields.transform_keys(&:to_s))
  end

  def entry = store.get("%5")

  describe "#start" do
    it "claims the pane, reads a quiet screen, checks it, signals, runs the restart and ends it, on its own thread" do
      store.put("%5", waiting)
      calls.clear
      attempts.start("%5", :restart, check: check)

      expect(spawned.size).to eq(1)
      expect(checked).to eq([["%5", 1, "❯ "]])
      expect(calls).to eq([
        [:claim, "%5"], [:get, "%5"], [:still_screen, "%5"], [:transcript_error, sid], [:ledger_session, "%5"],
        [:prompt_since_failure?, "%5"], [:pane_detail, "%5"], [:update, "%5"], [:mark, sid], [:stop, 20, 10],
        [:restart, 2], [:finish, 2, "resumed", nil], [:clear_marker, sid], [:release, "%5", :token]
      ])
      expect(entry).to include("phase" => "attempting", "attempts" => 2, "stopped" => true, "last_signal_at" => stamp(now),
        "attempt_session_id" => nil, "defer_since" => nil, "prompt_seen" => false)
    end

    it "types the first attempt's message with no signal or marker, and keeps it on the entry" do
      store.put("%5", waiting(attempts: 0))
      typed = Workspace::AgentRecoveryDesk::Verdict.new(answer: :go, mode: :typed)
      attempts.start("%5", :typed, check: ->(*_args, **_opts) { typed })

      expect(calls).to include([:typed, 1], [:finish, 1, "typed", nil])
      expect(calls.map(&:first)).not_to include(:mark, :stop, :clear_marker)
      expect(entry["draft_text"]).to eq(format(described_class::TYPED_MESSAGE, error: "server_error"))
    end

    it "does nothing while the claim is held" do
      claim[0] = nil
      store.put("%5", waiting)
      attempts.start("%5", :restart, check: check)

      expect(calls.map(&:first)).to eq([:put, :claim])
    end

    it "defers, through the outcomes, a pane whose screen didn't stand still" do
      store.put("%5", waiting)
      facts = RecordingOpeningFacts.new(screen: nil, calls: calls)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, stopper: stopper,
        marker: marker, resume_command: ->(**) {}, delivery_lock: Mutex.new, spawn: ->(&block) { block.call })
        .start("%5", :restart, check: check)

      expect(calls).to include([:refuse, "%5", :defer])
      expect(checked).to eq([])
    end

    it "acts on the check's refusal, and costs no attempt" do
      store.put("%5", waiting)
      never = Workspace::AgentRecoveryDesk::Verdict.new(answer: :never)
      attempts.start("%5", :restart, check: ->(*_args, **_opts) { never })

      expect(calls.last(2)).to eq([[:refuse, "%5", :never], [:release, "%5", :token]])
      expect(entry["attempts"]).to eq(1)
    end

    it "refuses a failure the transcript no longer shows" do
      store.put("%5", waiting(last_turn_uuid: "u-old"))
      attempts.start("%5", :restart, check: check)

      expect(calls).to include([:refuse, "%5", :clear])
      expect(calls.map(&:first)).not_to include(:stop)
    end

    it "takes the attempt back when the agent was stale, and clears the marker" do
      stopper = RecordingRecoveryStopper.new(stopped: :stale, calls: calls)
      store.put("%5", waiting)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, stopper: stopper,
        marker: marker, resume_command: ->(**) {}, delivery_lock: Mutex.new, spawn: ->(&block) { block.call })
        .start("%5", :restart, check: check)

      expect(calls.select { |call| %i[clear_marker take_back refuse].include?(call.first) }).to eq([
        [:clear_marker, sid], [:take_back, 2, :clear], [:refuse, "%5", :clear]
      ])
    end

    it "keeps the marker of an agent that was already gone" do
      stopper = RecordingRecoveryStopper.new(stopped: :not_running, calls: calls)
      store.put("%5", waiting)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, stopper: stopper,
        marker: marker, resume_command: ->(**) {}, delivery_lock: Mutex.new, spawn: ->(&block) { block.call })
        .start("%5", :restart, check: check)

      expect(calls).to include([:take_back, 2, :defer], [:refuse, "%5", :defer])
      expect(calls.map(&:first)).not_to include(:clear_marker)
    end

    it "sends no signal when the marker can't be written" do
      store.put("%5", waiting)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, stopper: stopper,
        marker: RecordingStopMarker.new(marks: false, calls: calls), resume_command: ->(**) {}, delivery_lock: Mutex.new,
        spawn: ->(&block) { block.call }).start("%5", :restart, check: check)

      expect(calls).to include([:take_back, 2, :defer])
      expect(calls.map(&:first)).not_to include(:stop)
    end

    it "runs the steps AgentRecoverySteps picks" do
      fixed = Workspace::AgentRecoverySteps.running(restart: ->(_attempt) { ["not_ready", nil] })
      store.put("%5", waiting)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, steps: fixed,
        stopper: stopper, marker: marker, resume_command: ->(**) {}, delivery_lock: Mutex.new, spawn: ->(&block) { block.call })
        .start("%5", :restart, check: check)

      expect(calls).to include([:finish, 2, "not_ready", nil])
      expect(calls.map(&:first)).not_to include(:restart)
    end

    it "logs an attempt that raises, keeps its marker for the reconcile, and releases the claim" do
      raising = Workspace::AgentRecoverySteps.running(restart: ->(_attempt) { raise "pane vanished" })
      store.put("%5", waiting)
      described_class.new(store: store, facts: facts, outcomes: outcomes, attempt_runner: attempt_runner, steps: raising,
        stopper: stopper, marker: marker, resume_command: ->(**) {}, delivery_lock: Mutex.new, spawn: ->(&block) { block.call },
        claim_restart: ->(_pane_id) { :token }, release_restart: ->(pane_id, token) { calls << [:release, pane_id, token] },
        logger: Workspace::Logger.new(output: log, enabled: true)).start("%5", :restart, check: check)

      expect(log.string).to include("agent recovery: attempt in %5 failed (RuntimeError: pane vanished)")
      expect(calls.map(&:first)).not_to include(:clear_marker, :finish)
      expect(calls.last).to eq([:release, "%5", :token])
    end

    it "opens with prompt_seen false, a restart and a resume_only alike" do
      store.put("%5", waiting(prompt_seen: true))
      seen = {}
      attempts.start("%5", :restart, check: check)
      seen[:restart] = entry["prompt_seen"]
      expect(seen[:restart]).to be(false)

      store.put("%5", waiting(attempts: 2, stopped: true, prompt_seen: true))
      resume_only = Workspace::AgentRecoveryDesk::Verdict.new(answer: :go, mode: :resume_only, command: "claude --resume #{sid}")
      attempts.start("%5", :restart, check: ->(*_args, **_opts) { resume_only })
      seen[:resume_only] = entry["prompt_seen"]
      expect(seen[:resume_only]).to be(false)
    end

    describe "resume_only" do
      let(:verdict) { Workspace::AgentRecoveryDesk::Verdict.new(answer: :go, mode: :resume_only, command: "claude --resume #{sid}") }

      it "writes no marker" do
        store.put("%5", waiting(attempts: 2, stopped: true, agent_pid: nil, agent_started: nil))
        expect(marker).not_to receive(:mark)
        attempts.start("%5", :restart, check: check)
      end
    end
  end

  describe "#resume_line" do
    it "builds the line from the entry's directory, session and flags" do
      expect(attempts.resume_line(waiting(agent_flags: ["--model", "opus"]))).to eq("claude --resume #{sid}")
      expect(lines).to eq([{cwd: "/work", session_id: sid, flags: ["--model", "opus"]}])
    end

    it "has no line for an entry with no directory" do
      expect(attempts.resume_line(waiting(cwd: nil))).to be_nil
      expect(lines).to eq([])
    end
  end
end
