require "spec_helper"

RSpec.describe Workspace::RecoveryVerdicts do
  let(:now) { Time.utc(2026, 11, 11, 12, 0, 0) }
  let(:session_id) { "0b6d3c1e-6f0a-4f6e-9d2b-3a1c5e7f9a10" }

  def iso(time) = time.utc.iso8601

  it ".signalled_lately? holds within SIGNAL_HOLD of a signal that parses" do
    hold = Workspace::AgentRecoveryStore::SIGNAL_HOLD
    expect(described_class.signalled_lately?({"last_signal_at" => iso(now - hold + 1)}, now)).to be(true)
    expect(described_class.signalled_lately?({"last_signal_at" => iso(now - hold)}, now)).to be(false)
    expect(described_class.signalled_lately?({}, now)).to be(false)
    expect(described_class.signalled_lately?({"last_signal_at" => "soon"}, now)).to be(false)
  end

  it ".started_since_signal? is true only for a start after the signal, both known" do
    entry = {"last_signal_at" => iso(now)}
    expect(described_class.started_since_signal?(entry, iso(now + 1))).to be(true)
    expect(described_class.started_since_signal?(entry, iso(now))).to be(false)
    expect(described_class.started_since_signal?(entry, nil)).to be(false)
    expect(described_class.started_since_signal?({}, iso(now + 1))).to be(false)
  end

  it ".resumable? needs a line and a session id a resume line may carry" do
    expect(described_class.resumable?("claude --resume x", {"session_id" => session_id})).to be(true)
    expect(described_class.resumable?(nil, {"session_id" => session_id})).to be(false)
    expect(described_class.resumable?("claude --resume x", {"session_id" => "$(rm -rf ~)"})).to be(false)
    expect(described_class.resumable?("claude --resume x", {})).to be(false)
  end

  it ".same_process? matches pid and start time, and a pid never read proves nothing" do
    entry = {"agent_pid" => 42, "agent_started" => "Mon"}
    expect(described_class.same_process?(entry, {pid: 42, started: "Mon"})).to be(true)
    expect(described_class.same_process?(entry, {pid: 42, started: "Tue"})).to be(false)
    expect(described_class.same_process?(entry, {pid: 43, started: "Mon"})).to be(false)
    expect(described_class.same_process?({"agent_pid" => nil}, {pid: nil, started: nil})).to be(false)
  end

  it ".prompt_after? is true with no facts, else compares the last prompt" do
    expect(described_class.prompt_after?(nil, now)).to be(true)
    expect(described_class.prompt_after?({last_user_prompt_at: now + 1}, now)).to be(true)
    expect(described_class.prompt_after?({last_user_prompt_at: now}, now)).to be(false)
    expect(described_class.prompt_after?({last_user_prompt_at: nil}, now)).to be(false)
  end

  it ".subagents_recent? takes the later of the last sub-agent event and the failure" do
    quiet = described_class::SUBAGENT_QUIET
    entry = {"last_subagent_at" => iso(now - quiet - 5), "failed_at" => iso(now - 10)}
    expect(described_class.subagents_recent?(entry, now)).to be(true)
    expect(described_class.subagents_recent?(entry.merge("failed_at" => iso(now - quiet)), now)).to be(false)
    expect(described_class.subagents_recent?({}, now)).to be(true)
  end

  it ".screen_busy? is true for a screen that moved or shows Claude Code at work" do
    expect(described_class.screen_busy?(nil)).to be(true)
    expect(described_class.screen_busy?("Retrying in 4s")).to be(true)
    expect(described_class.screen_busy?("thinking (esc to interrupt)")).to be(true)
    expect(described_class.screen_busy?("> ")).to be(false)
  end

  describe ".transcript_verdict" do
    let(:entry) { {"last_turn_uuid" => "u1"} }

    it "goes on while the last record is the stored failure" do
      expect(described_class.transcript_verdict({"api_error" => true, "uuid" => "u1"}, entry)).to be_nil
    end

    it "defers with no record or no stored turn" do
      expect(described_class.transcript_verdict(nil, entry)).to eq(:defer)
      expect(described_class.transcript_verdict({"api_error" => true, "uuid" => "u1"}, {})).to eq(:defer)
    end

    it "clears once the transcript moved on" do
      expect(described_class.transcript_verdict({"api_error" => true, "uuid" => "u2"}, entry)).to eq(:clear)
      expect(described_class.transcript_verdict({"uuid" => "u1"}, entry)).to eq(:clear)
    end
  end

  it ".session_verdict goes on for the stored session, clears for another, defers for no reading" do
    entry = {"session_id" => session_id}
    expect(described_class.session_verdict({"session_id" => session_id}, entry)).to be_nil
    expect(described_class.session_verdict({"session_id" => "other"}, entry)).to eq(:clear)
    expect(described_class.session_verdict(nil, entry)).to eq(:defer)
    expect(described_class.session_verdict(:unreadable, entry)).to eq(:defer)
  end

  it ".first_attempt? is true at zero attempts, missing counting as zero" do
    expect(described_class.first_attempt?({"attempts" => 0})).to be(true)
    expect(described_class.first_attempt?({})).to be(true)
    expect(described_class.first_attempt?({"attempts" => 1})).to be(false)
  end

  it ".start_command_verdict defers for an unreadable pane, never for a pane started with a command" do
    expect(described_class.start_command_verdict(:gone)).to eq(:defer)
    expect(described_class.start_command_verdict("claude")).to eq(:never)
    expect(described_class.start_command_verdict(nil)).to be_nil
  end

  it ".time_of parses ISO 8601 and answers nil for anything else" do
    expect(described_class.time_of(iso(now))).to eq(now)
    expect(described_class.time_of(nil)).to be_nil
    expect(described_class.time_of("noon")).to be_nil
  end
end
