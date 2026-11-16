require "spec_helper"

RSpec.describe Workspace::WorkflowRecovery, "stall spans on the attempt" do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:clock_at) { [now] }
  let(:store) { RecordingRunStore.new }
  let(:recovery) do
    described_class.new(change: RecordingRunChange.new(store.runs), store: store, dispatch: RecordingDispatch.new,
      progress: RecordingProgress.new, evaluation: RecordingEvaluation.new(store.runs), clock: -> { clock_at.first })
  end

  def run_hash(attempts = [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}])
    {"id" => "wr_1", "current" => "build", "state" => "running", "steps" => {"build" => {"state" => "running", "attempts" => attempts}}}
  end

  def stall(cause) = recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: attempts.last["n"], cause: cause)

  def recover(cause) = recovery.note_recovery("wr_1", actor: "sweep", step: "build", attempt: attempts.last["n"], cause: cause, action: "x")

  def attempts = store.runs["wr_1"]["steps"]["build"]["attempts"]

  def stored_run(hash = run_hash) = store.runs["wr_1"] = hash

  %w[pane_gone agent_gone turn_failed].each do |cause|
    context "for #{cause}" do
      it "writes the entry once per attempt and closes it with a recovery mark" do
        stored_run
        expect(stall(cause)).to eq(:recorded)
        expect(stall(cause)).to eq(:repeat)
        expect(attempts[0]["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z"}])

        clock_at[0] = now + 600
        recover(cause)
        expect(attempts[0]["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z", "until" => "2026-11-10T12:10:00Z"}])
      end

      it "still closes an open entry when recovered is already set, keeping the first until" do
        stored_run
        stall(cause)
        store.runs["wr_1"]["sweep"]["recovered"][cause] = "2026-11-10T11:59:00Z"
        clock_at[0] = now + 60
        expect(recover(cause)).to eq(:repeat)
        expect(attempts[0]["stalls"][0]["until"]).to eq("2026-11-10T12:01:00Z")
        clock_at[0] = now + 120
        recover(cause)
        expect(attempts[0]["stalls"][0]["until"]).to eq("2026-11-10T12:01:00Z")
      end

      it "keeps an earlier attempt's stall when a later attempt is marked" do
        stored_run
        stall(cause)
        attempts << {"n" => 2, "started_at" => "2026-11-10T12:30:00Z"}
        clock_at[0] = now + 3600
        expect(stall(cause)).to eq(:recorded)
        recover(cause)
        first, second = attempts
        expect(first["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z"}])
        expect(second["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T13:00:00Z", "until" => "2026-11-10T13:00:00Z"}])
      end
    end
  end

  it "writes no entry for a cause outside the list" do
    stored_run
    stall("undelivered")
    recover("undelivered")
    expect(attempts[0]).not_to have_key("stalls")
  end
end
