require "spec_helper"

RSpec.describe Workspace::WorkflowRecovery, "stall spans on the attempt" do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:clock_at) { [now] }
  let(:recovery) do
    described_class.new(change: RecordingRunChange.new({}), store: RecordingRunStore.new, dispatch: RecordingDispatch.new,
      progress: RecordingProgress.new, evaluation: RecordingEvaluation.new({}), clock: -> { clock_at.first })
  end

  def run_hash(attempts = [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}])
    {"id" => "wr_1", "current" => "build", "state" => "running", "steps" => {"build" => {"state" => "running", "attempts" => attempts}}}
  end

  def stall(run, cause) = recovery.send(:mark_stall, run, cause, {})

  def recover(run, cause) = recovery.send(:mark_recovery, run, cause, "x")

  %w[pane_gone agent_gone turn_failed].each do |cause|
    context "for #{cause}" do
      it "writes the entry once per attempt and closes it with a recovery mark" do
        run = run_hash
        expect(stall(run, cause)).to be true
        expect(stall(run, cause)).to be false
        expect(run["steps"]["build"]["attempts"][0]["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z"}])

        clock_at[0] = now + 600
        recover(run, cause)
        expect(run["steps"]["build"]["attempts"][0]["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z", "until" => "2026-11-10T12:10:00Z"}])
      end

      it "still closes an open entry when recovered is already set, keeping the first until" do
        run = run_hash
        stall(run, cause)
        run["sweep"]["recovered"][cause] = "2026-11-10T11:59:00Z"
        clock_at[0] = now + 60
        expect(recover(run, cause)).to be false
        expect(run["steps"]["build"]["attempts"][0]["stalls"][0]["until"]).to eq("2026-11-10T12:01:00Z")
        clock_at[0] = now + 120
        recover(run, cause)
        expect(run["steps"]["build"]["attempts"][0]["stalls"][0]["until"]).to eq("2026-11-10T12:01:00Z")
      end

      it "keeps an earlier attempt's stall when a later attempt is marked" do
        run = run_hash
        stall(run, cause)
        run["steps"]["build"]["attempts"] << {"n" => 2, "started_at" => "2026-11-10T12:30:00Z"}
        clock_at[0] = now + 3600
        expect(stall(run, cause)).to be true
        recover(run, cause)
        first, second = run["steps"]["build"]["attempts"]
        expect(first["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T12:00:00Z"}])
        expect(second["stalls"]).to eq([{"cause" => cause, "since" => "2026-11-10T13:00:00Z", "until" => "2026-11-10T13:00:00Z"}])
      end
    end
  end

  it "writes no entry for a cause outside the list" do
    run = run_hash
    stall(run, "undelivered")
    recover(run, "undelivered")
    expect(run["steps"]["build"]["attempts"][0]).not_to have_key("stalls")
  end
end
