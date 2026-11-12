require "spec_helper"

RSpec.describe Workspace::RecoveryIntake do
  let(:sid) { "11111111-1111-4111-8111-111111111111" }
  let(:other_sid) { "22222222-2222-4222-8222-222222222222" }
  let(:now) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:calls) { [] }
  let(:log) { StringIO.new }
  let(:agent) { {pid: 20, started: "Mon", flags: ["--model", "opus"]} }
  let(:store) { RecordingRecoveryStore.new(calls: calls) }
  let(:facts) { RecordingAgentFacts.new(agents: {"%5" => agent}, calls: calls) }
  let(:monitor) { RecordingRecoveryMonitor.new(agent_pid: 10, calls: calls) }
  let(:gave_up) { [] }
  let(:resolved) { [] }
  let(:rebound) { [] }
  let(:blocks) { [] }
  let(:spawn) { ->(&block) { block.call } }

  def intake(**overrides)
    described_class.new(store: store, session_monitor: monitor, facts: facts,
      report_give_up: ->(pane_id, entry) { gave_up << [pane_id, entry] }, resolve: ->(session_id) { resolved << session_id },
      rebind_queue: ->(pane_id, pid) {
        calls << [:rebind_queue, pane_id, pid]
        rebound << [pane_id, pid]
      },
      max_attempts: 3, clock: BlockClock.new { now }, spawn: spawn, logger: Workspace::Logger.new(output: log, enabled: true),
      **overrides)
  end

  subject(:desk_intake) { intake }

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  def event(name, session: sid, pane: "%5", **fields)
    desk_intake.session_event({"event" => name, "pane_id" => pane, "session_id" => session}.merge(fields.transform_keys(&:to_s)))
  end

  def failed(error = "server_error", session: sid, path: "/t/session.jsonl")
    event("turn_failed", session: session, error: error, transcript_path: path)
  end

  def waiting(**fields)
    {"session_id" => sid, "transcript_path" => "/t/session.jsonl", "error" => "server_error", "attempts" => 1,
     "phase" => "waiting", "stopped" => false, "failed_at" => stamp(now - 60), "next_attempt_at" => stamp(now + 60),
     "agent_pid" => 20, "agent_started" => "Mon"}.merge(fields.transform_keys(&:to_s))
  end

  def entry = store.get("%5")

  describe "#session_event" do
    let(:spawn) { ->(&block) { blocks << block } }

    it "only queues on the caller's thread, starts one worker, and works the queue in order" do
      expect(event("stop")).to be_nil
      event("user_prompt")

      expect(blocks.size).to eq(1)
      expect(calls).to eq([])

      blocks.first.call

      expect(calls).to eq([[:update, "%5"], [:get, "%5"], [:update, "%5"]])
    end

    it "starts a new worker for an event that arrives after the queue ran dry" do
      event("stop")
      blocks.shift.call
      event("stop")

      expect(blocks.size).to eq(1)
    end

    it "ignores a message with no pane and an event it has no rule for" do
      desk_intake.session_event("event" => "stop")
      event("notification")

      expect(blocks).to eq([])
    end

    it "queues a sub-agent's event whatever its name" do
      event("notification", agent_id: "a1")

      expect(blocks.size).to eq(1)
    end

    it "lets the next event start a worker when starting one raised" do
      tries = 0
      spawner = ->(&block) {
        tries += 1
        raise ThreadError, "can't create Thread" if tries == 1
        block.call
      }
      store.put("%5", waiting(phase: "watching"))
      quiet = intake(spawn: spawner)

      quiet.session_event("event" => "stop", "pane_id" => "%5", "session_id" => sid)
      quiet.session_event("event" => "stop", "pane_id" => "%5", "session_id" => sid)

      expect(entry).to be_nil
      expect(log.string).to include("could not start the worker (ThreadError")
    end

    context "with the worker running at once" do
      let(:spawn) { ->(&block) { block.call } }

      it "goes on working through a logger that raises" do
        logger = Object.new
        def logger.debug = raise("log closed")
        failing = Object.new
        def failing.update(_pane_id) = raise(Workspace::Error, "disk gone")
        broken = intake(store: failing, logger: logger)

        expect { broken.session_event("event" => "stop", "pane_id" => "%5", "session_id" => sid) }.not_to raise_error
      end

      it "stamps a sub-agent's event on an existing entry of the same session only" do
        store.put("%5", waiting(phase: "watching"))
        event("stop", agent_id: "a1")
        event("tool_use", pane: "%6", agent_id: "a1")

        expect(entry).to include("phase" => "watching", "last_subagent_at" => stamp(now))
        expect(store.get("%6")).to be_nil
      end
    end
  end

  describe "a failed turn" do
    it "writes a waiting entry with the agent read, a minute out" do
      failed

      expect(entry).to include("phase" => "waiting", "session_id" => sid, "attempts" => 0, "stopped" => false,
        "agent_pid" => 20, "agent_started" => "Mon", "agent_flags" => ["--model", "opus"], "failed_at" => stamp(now),
        "next_attempt_at" => stamp(now + 60), "error" => "server_error", "transcript_path" => "/t/session.jsonl")
      expect(calls.first).to eq([:live_agent, "%5"])
    end

    it "takes no session id a resume line couldn't carry, and no failure without a transcript" do
      failed(session: "not-a-session")
      failed(path: "")

      expect(entry).to be_nil
    end

    it "gives up at once on an error trying again won't fix, and reports it" do
      failed("invalid_request")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "not_retryable")
      expect(gave_up).to eq([["%5", entry]])
    end

    it "gives up once the attempts are used up" do
      store.put("%5", waiting(phase: "watching", attempts: 3))
      failed

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted")
      expect(gave_up.size).to eq(1)
    end

    it "moves the queue to a replaced agent before the update" do
      store.put("%5", waiting(phase: "watching", stopped: true, agent_pid: 19))
      failed

      expect(rebound).to eq([["%5", 10]])
      expect(calls.index([:rebind_queue, "%5", 10])).to be < calls.rindex([:update, "%5"])
      expect(entry).to include("stopped" => false, "agent_pid" => 20)
    end
  end

  describe "a finished turn" do
    it "deletes the entry and resolves its item" do
      store.put("%5", waiting(phase: "watching"))
      event("stop")

      expect(entry).to be_nil
      expect(resolved).to eq([sid])
    end

    it "only marks an attempt's entry, and ignores another session's Stop" do
      store.put("%5", waiting(phase: "attempting"))
      event("stop", session: other_sid)
      event("stop")

      expect(entry).to include("phase" => "attempting", "turn_completed" => true)
      expect(resolved).to eq([])
    end
  end

  describe "the agent at work" do
    it "notes a prompt in an attempt" do
      store.put("%5", waiting(phase: "attempting"))
      event("user_prompt")

      expect(entry["prompt_seen"]).to be(true)
    end

    it "moves a waiting entry to watching" do
      store.put("%5", waiting(defer_since: stamp(now)))
      event("tool_use")

      expect(entry).to include("phase" => "watching", "defer_since" => nil)
    end

    it "takes a stopped entry's replaced agent as the one to watch, moving the queue first" do
      store.put("%5", waiting(stopped: true, agent_pid: 19))
      event("user_prompt")

      expect(rebound).to eq([["%5", 10]])
      expect(entry).to include("phase" => "watching", "stopped" => false, "agent_pid" => 20)
    end
  end

  describe "a session start" do
    it "clears an entry a /clear replaced, and resolves its item" do
      store.put("%5", waiting)
      event("session_start", session: other_sid, source: "clear")

      expect(entry).to be_nil
      expect(resolved).to eq([sid])
    end

    it "gives up fresh_conversation for another session after attempts" do
      store.put("%5", waiting)
      event("session_start", session: other_sid, source: "startup")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "fresh_conversation")
      expect(gave_up.map(&:first)).to eq(["%5"])
    end

    it "records an attempt's session and forgets our signal for the same one" do
      store.put("%5", waiting(phase: "attempting", stopped: true, last_signal_at: stamp(now)))
      event("session_start")

      expect(entry).to include("attempt_session_id" => sid, "stopped" => false, "last_signal_at" => nil)
    end

    it "takes someone's resume of a stopped session as theirs" do
      store.put("%5", waiting(stopped: true))
      event("session_start")

      expect(rebound).to eq([["%5", 10]])
      expect(entry).to include("phase" => "watching", "stopped" => false, "agent_pid" => 20)
    end

    it "lets a stopped session opened in another pane go from its own pane" do
      store.put("%6", waiting(stopped: true, item_open: true))
      store.put("%7", waiting(stopped: true, phase: "attempting"))
      event("session_start", pane: "%5")

      expect(store.get("%6")).to be_nil
      expect(store.get("%7")["resumed_elsewhere"]).to be(true)
      expect(resolved).to eq([sid])
    end
  end

  describe "a session end" do
    it "deletes an entry with no attempts and resolves its item" do
      store.put("%5", waiting(attempts: 0))
      event("session_end")

      expect(entry).to be_nil
      expect(resolved).to eq([sid])
    end

    it "takes the exit after our recent signal as ours" do
      store.put("%5", waiting(last_signal_at: stamp(now - 10)))
      event("session_end")

      expect(entry).to include("phase" => "waiting", "stopped" => true)
    end

    it "gives up unconfirmed after attempts" do
      store.put("%5", waiting(phase: "watching"))
      event("session_end")

      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "unconfirmed")
      expect(gave_up.size).to eq(1)
    end
  end

  describe "the flags a resume carries" do
    let(:skip) { "--dangerously-skip-permissions" }
    let(:agent) { {pid: 20, started: "Mon", flags: nil} }

    it "keeps the flags when a read of the same process gives none" do
      store.put("%5", waiting(phase: "watching", agent_flags: [skip]))
      failed

      expect(entry).to include("agent_pid" => 20, "agent_flags" => [skip])
    end

    it "fills absent flags from a read of the same process that has them" do
      agent[:flags] = [skip]
      store.put("%5", waiting(phase: "watching", agent_flags: nil))
      failed

      expect(entry["agent_flags"]).to eq([skip])
    end

    it "never leaves the old agent's flags beside a different agent read with none" do
      store.put("%5", waiting(phase: "watching", agent_pid: 19, agent_flags: [skip]))
      event("session_start", source: "resume")

      expect(entry).to include("agent_pid" => 20, "agent_flags" => nil)
    end

    it "replaces the flags with a person's agent's" do
      agent[:flags] = []
      store.put("%5", waiting(stopped: true, phase: "watching", agent_pid: 19, agent_flags: [skip]))
      event("session_start", source: "resume")

      expect(entry).to include("agent_pid" => 20, "agent_flags" => [])
    end

    context "with no agent in the pane" do
      let(:agent) { nil }

      it "keeps them through a failure read with no agent in the pane" do
        store.put("%5", waiting(phase: "watching", agent_flags: [skip]))
        failed

        expect(entry).to include("phase" => "waiting", "agent_pid" => nil, "agent_flags" => [skip])
      end
    end
  end
end
