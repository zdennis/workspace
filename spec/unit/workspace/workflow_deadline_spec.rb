require "spec_helper"
require "json"
require "time"

RSpec.describe Workspace::WorkflowDeadline do
  let(:dir) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs") }
  let(:start) { Time.utc(2026, 1, 1) }

  def fixture(name, timeout: nil, **top)
    hash = JSON.parse(File.read(File.join(dir, "#{name}.json")))
    hash["definition"]["timeout"] = timeout if timeout
    hash.merge!(top.transform_keys(&:to_s))
    hash
  end

  it "reads nothing for a run whose definition has no timeout" do
    expect(described_class.reading(fixture("legacy_minimal"), start + 10)).to be_nil
    expect(described_class.reading(fixture("waiting_gate"), start + 10)).to be_nil
  end

  it "counts a finished run from its first attempt to its end" do
    reading = described_class.reading(fixture("legacy_minimal", timeout: 100.0), start + 3600)

    expect(reading).to include("timeout" => 100.0, "action" => "hold", "limit" => 100.0, "used" => 2.0, "spent" => false, "needed" => nil, "suggested" => nil)
  end

  it "leaves out the time a gate waits on a person, open to now" do
    reading = described_class.reading(fixture("waiting_gate", timeout: 100.0), start + 11)

    expect(reading["used"]).to eq(1.0)
  end

  it "counts a retry backoff as machine time, an open one to now" do
    reading = described_class.reading(fixture("retry_backoff", timeout: 1000.0), start + 130)

    expect(reading).to include("used" => 130.0, "spent" => false)
  end

  it "leaves out a held run's own stop, which stays open" do
    reading = described_class.reading(fixture("budget_spent", timeout: 100.0), start + 500)

    expect(reading["used"]).to eq(3.0)
  end

  describe "run_timed_out.json" do
    it "is spent: three seconds against two" do
      reading = described_class.reading(fixture("run_timed_out"), start + 500)

      expect(reading).to include("limit" => 2.0, "used" => 3.0, "spent" => true, "needed" => 2, "suggested" => 900, "extra_seconds" => 0)
    end

    it "adds extra_seconds to the limit" do
      reading = described_class.reading(fixture("run_timed_out", extra_seconds: 1), start + 500)
      expect(reading).to include("limit" => 3.0, "spent" => true, "needed" => 1)

      reading = described_class.reading(fixture("run_timed_out", extra_seconds: 2), start + 500)
      expect(reading).to include("limit" => 4.0, "spent" => false, "needed" => nil)
    end

    it "takes the action from the definition" do
      hash = fixture("run_timed_out")
      hash["definition"]["timeout_action"] = "interrupt"

      expect(described_class.reading(hash, start)["action"]).to eq("interrupt")
    end

    it "takes a run as a WorkflowRun" do
      run = Workspace::WorkflowRun.from_h(fixture("run_timed_out"))

      expect(described_class.reading(run, start + 5)["spent"]).to be(true)
    end
  end

  describe "the clock" do
    def run_with(attempt_start: "2026-01-01T00:00:10Z", ended: nil, attempt_reasons: [], run_reasons: [])
      {"definition" => {"timeout" => 1000.0},
       "ended_at" => ended,
       "reasons" => run_reasons,
       "steps" => {"a" => {"attempts" => [{"n" => 1, "started_at" => attempt_start, "reasons" => attempt_reasons}]}}}
    end

    it "starts at an earlier waiting_lock entry" do
      hash = run_with(run_reasons: [{"code" => "waiting_lock", "since" => "2026-01-01T00:00:00Z", "until" => "2026-01-01T00:00:10Z", "step" => "a"}])

      expect(described_class.reading(hash, start + 20)["used"]).to eq(20.0)
    end

    it "does not start before a waiting_you entry that came first" do
      hash = run_with(run_reasons: [{"code" => "waiting_you", "since" => "2026-01-01T00:00:00Z", "until" => "2026-01-01T00:00:10Z", "step" => "a"}])

      expect(described_class.reading(hash, start + 20)["used"]).to eq(10.0)
    end

    it "counts overlapping stops once" do
      stop = {"code" => "waiting_you", "since" => "2026-01-01T00:00:12Z", "until" => "2026-01-01T00:00:16Z"}
      other = {"code" => "parked", "since" => "2026-01-01T00:00:14Z", "until" => "2026-01-01T00:00:18Z"}
      hash = run_with(attempt_reasons: [stop], run_reasons: [other.merge("step" => "a")])

      expect(described_class.reading(hash, start + 20)["used"]).to eq(10.0 - 6.0)
    end

    it "counts a waiting_lock inside the span as machine time" do
      hash = run_with(attempt_reasons: [{"code" => "waiting_lock", "since" => "2026-01-01T00:00:12Z", "until" => nil}])

      expect(described_class.reading(hash, start + 20)["used"]).to eq(10.0)
    end

    it "stops at the run's end" do
      hash = run_with(ended: "2026-01-01T00:00:15Z")

      expect(described_class.reading(hash, start + 9999)["used"]).to eq(5.0)
    end

    it "reads zero before any attempt, and ignores a bad time" do
      expect(described_class.reading(run_with(attempt_start: "soon"), start + 20)["used"]).to eq(0.0)
      expect(described_class.reading({"definition" => {"timeout" => 5.0}}, start)["used"]).to eq(0.0)
    end

    it "rounds the suggestion up to 15 minutes" do
      hash = run_with(attempt_start: "2026-01-01T00:00:00Z")
      reading = described_class.reading(hash, start + 1000 + 900)

      expect(reading).to include("spent" => true, "needed" => 901, "suggested" => 1800)
    end
  end
end
