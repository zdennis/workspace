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

  describe ".give_up" do
    it "ends the wait with the reason" do
      entry = {"phase" => "waiting", "next_attempt_at" => "x", "defer_since" => "y"}
      described_class.give_up(entry, "deferred")

      expect(entry).to eq("phase" => "gave_up", "give_up_reason" => "deferred", "next_attempt_at" => nil, "defer_since" => nil)
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

    it "gives up with the attempts used up, without reading the clock" do
      entry = {"attempts" => 3}

      expect(described_class.schedule_next(entry, max_attempts: 3, clock: nil)).to be(true)
      expect(entry).to include("phase" => "gave_up", "give_up_reason" => "attempts_exhausted")
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
end
