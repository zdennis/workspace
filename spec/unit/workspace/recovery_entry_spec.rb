require "spec_helper"

RSpec.describe Workspace::RecoveryEntry do
  let(:now) { Time.utc(2026, 11, 12, 12, 0, 0) }
  let(:clock) { Struct.new(:now).new(now) }

  def stamp(time) = Workspace::AgentRecoveryStore.stamp(time)

  describe ".store_agent" do
    it "keeps the flags of the same process when a read gave none, and takes another process's as read" do
      entry = {"agent_pid" => 20, "agent_started" => "Mon", "agent_flags" => ["--model", "opus"]}
      described_class.store_agent(entry, {pid: 20, started: "Mon", flags: nil})
      expect(entry["agent_flags"]).to eq(["--model", "opus"])

      described_class.store_agent(entry, {pid: 30, started: "Tue", flags: nil})
      expect(entry).to eq("agent_pid" => 30, "agent_started" => "Tue", "agent_flags" => nil)
    end

    it "blanks the pid and keeps the flags with no agent" do
      entry = {"agent_pid" => 20, "agent_started" => "Mon", "agent_flags" => []}
      described_class.store_agent(entry, nil)

      expect(entry).to eq("agent_pid" => nil, "agent_started" => nil, "agent_flags" => [])
    end
  end

  describe ".apply_failure" do
    let(:sid) { "11111111-1111-4111-8111-111111111111" }
    let(:agent) { {pid: 20, started: "Mon", flags: ["--model", "opus"]} }

    def apply_failure(*args) = described_class.apply_failure(*args, max_attempts: 3, clock: clock)

    def waiting(**fields)
      {"session_id" => sid, "transcript_path" => "/t/session.jsonl", "error" => "server_error", "attempts" => 1,
       "phase" => "waiting", "stopped" => false, "failed_at" => stamp(now - 60), "next_attempt_at" => stamp(now + 60),
       "agent_pid" => 20, "agent_started" => "Mon"}.merge(fields.transform_keys(&:to_s))
    end

    it "only marks an attempt's entry, for the attempt's end to take" do
      entry = waiting(phase: "attempting")

      expect(apply_failure(entry, sid, "overloaded", "/t/session.jsonl", agent)).to be(false)
      expect(entry).to include("phase" => "attempting", "failed_during_attempt" => true, "error" => "overloaded")
    end

    it "reopens an unconfirmed give-up for a live agent, keeping the count" do
      entry = waiting(phase: "gave_up", give_up_reason: "unconfirmed", attempts: 2)

      expect(apply_failure(entry, sid, "server_error", "/t/session.jsonl", agent)).to be(false)
      expect(entry).to include("phase" => "waiting", "attempts" => 2, "give_up_reason" => nil, "item_open" => true,
        "next_attempt_at" => stamp(now + 240))
    end

    it "leaves an unconfirmed give-up alone with no agent" do
      entry = waiting(phase: "gave_up", give_up_reason: "unconfirmed")

      expect(apply_failure(entry, sid, "server_error", "/t/session.jsonl", nil)).to be(false)
      expect(entry).to include("phase" => "gave_up")
    end
  end

  describe ".give_up" do
    it "ends the wait with the reason" do
      entry = {"phase" => "waiting", "next_attempt_at" => "x", "defer_since" => "y"}
      described_class.give_up(entry, "deferred", clock: clock)

      expect(entry).to eq("phase" => "gave_up", "give_up_reason" => "deferred", "gave_up_at" => stamp(now), "next_attempt_at" => nil,
        "defer_since" => nil)
    end
  end

  describe ".forget_signal" do
    it "clears stopped and the signal time" do
      entry = {"stopped" => true, "last_signal_at" => "x"}
      described_class.forget_signal(entry)

      expect(entry).to eq("stopped" => false, "last_signal_at" => nil)
    end
  end

  describe ".schedule_next" do
    it "waits for the next attempt by the schedule" do
      entry = {"attempts" => 2, "phase" => "watching", "last_turn_uuid" => "u", "defer_since" => "d"}

      expect(described_class.schedule_next(entry, max_attempts: 3, clock: clock)).to be(false)
      expect(entry).to eq("attempts" => 2, "phase" => "waiting", "next_attempt_at" => stamp(now + 240), "last_turn_uuid" => nil,
        "defer_since" => nil)
    end

    it "gives up with the attempts used up, stamping when" do
      entry = {"attempts" => 3}

      expect(described_class.schedule_next(entry, max_attempts: 3, clock: clock)).to be(true)
      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted", "gave_up_at" => stamp(now))
    end
  end

  describe ".unreported?" do
    it "is true only with no attempts and no open item" do
      expect(described_class.unreported?({})).to be(true)
      expect(described_class.unreported?({"attempts" => 1})).to be(false)
      expect(described_class.unreported?({"item_open" => true})).to be(false)
    end
  end

  describe ".signalled_lately?" do
    it "holds within SIGNAL_HOLD of a signal, and reads no clock without one" do
      expect(described_class.signalled_lately?({"last_signal_at" => stamp(now - 10)}, clock)).to be(true)
      expect(described_class.signalled_lately?({"last_signal_at" => stamp(now - 301)}, clock)).to be(false)
      expect(described_class.signalled_lately?({}, nil)).to be(false)
    end
  end

  describe ".apply_read" do
    it "stores an agent read and takes back stopped" do
      entry = {"stopped" => true, "agent_pid" => 1, "agent_started" => "Sun"}
      described_class.apply_read(entry, {pid: 20, started: "Mon", flags: ["--model", "opus"]})

      expect(entry).to eq("stopped" => false, "agent_pid" => 20, "agent_started" => "Mon", "agent_flags" => ["--model", "opus"])
    end

    it "changes nothing for an empty pane or a read that failed" do
      [nil, :unread].each do |live|
        entry = {"stopped" => true, "agent_pid" => 1}
        described_class.apply_read(entry, live)
        expect(entry).to eq("stopped" => true, "agent_pid" => 1)
      end
    end
  end

  describe ".agent_gone?" do
    it "is true only for an empty pane that no signal of ours explains" do
      expect(described_class.agent_gone?({"stopped" => false}, nil)).to be(true)
      expect(described_class.agent_gone?({"stopped" => true}, nil)).to be(false)
      expect(described_class.agent_gone?({}, :unread)).to be(false)
      expect(described_class.agent_gone?({}, {pid: 20})).to be(false)
    end
  end

  describe ".same_wait?" do
    it "compares the phase, the session and the failure time only" do
      seen = {"phase" => "waiting", "session_id" => "s", "failed_at" => "t", "attempts" => 1}

      expect(described_class.same_wait?(seen.merge("attempts" => 2), seen)).to be(true)
      %w[phase session_id failed_at].each do |key|
        expect(described_class.same_wait?(seen.merge(key => "other"), seen)).to be(false)
      end
    end
  end

  describe ".failure_since" do
    it "prefers the time the pane shows, else the failure time of the entry of its session" do
      entry = {"session_id" => "s1", "failed_at" => "2026-10-04T12:40:00Z"}
      expect(described_class.failure_since("2026-10-04T12:45:00Z", entry, "s1")).to eq("2026-10-04T12:45:00Z")
      expect(described_class.failure_since(nil, entry, "s1")).to eq("2026-10-04T12:40:00Z")
      expect(described_class.failure_since(nil, entry, "s2")).to be_nil
      expect(described_class.failure_since(nil, nil, "s1")).to be_nil
    end
  end

  describe ".of_session" do
    it "gives the entry only for its own session" do
      entry = {"session_id" => "s1"}
      expect(described_class.of_session(entry, "s1")).to be(entry)
      expect(described_class.of_session(entry, "s2")).to be_nil
      expect(described_class.of_session({}, nil)).to be_nil
      expect(described_class.of_session(nil, "s1")).to be_nil
    end
  end

  describe ".trusted_for_failure" do
    let(:failed_at) { Time.utc(2026, 10, 4, 12, 45) }
    let(:waiting) { {"session_id" => "s1", "phase" => "waiting", "attempts" => 2} }
    let(:gave_up) { {"session_id" => "s1", "phase" => "gave_up", "gave_up_at" => "2026-10-04T12:46:00Z"} }

    def trusted(entry, session_id: "s1", at: failed_at)
      described_class.trusted_for_failure(entry, session_id: session_id, failed_at: at)
    end

    it "gives an entry of the shown session" do
      expect(trusted(waiting)).to be(waiting)
    end

    it "gives nil for no entry, a non-hash, another session or a pane with no session" do
      expect(trusted(nil)).to be_nil
      expect(trusted("x")).to be_nil
      expect(trusted(waiting, session_id: "other")).to be_nil
      expect(trusted({"phase" => "waiting"}, session_id: nil)).to be_nil
    end

    it "trusts a give-up made at or after the failure" do
      expect(trusted(gave_up)).to be(gave_up)
      expect(trusted(gave_up.merge("gave_up_at" => "2026-10-04T12:45:00Z"))).not_to be_nil
    end

    it "does not trust a give-up from before the failure, with no time, or for a failure of no known time" do
      expect(trusted(gave_up.merge("gave_up_at" => "2026-10-04T12:30:00Z"))).to be_nil
      expect(trusted(gave_up.merge("gave_up_at" => nil))).to be_nil
      expect(trusted(gave_up, at: nil)).to be_nil
    end
  end
end
