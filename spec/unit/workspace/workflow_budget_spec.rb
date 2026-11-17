require "spec_helper"

RSpec.describe Workspace::WorkflowBudget do
  def run(attempts, budget: {"tokens" => 1000, "action" => "stop"}, extra: nil, state: "passed")
    definition = budget ? {"budget" => budget} : {}
    stored = {"definition" => definition, "current" => "a", "steps" => {"a" => {"state" => state, "attempts" => attempts}}}
    stored["extra_tokens"] = extra if extra
    stored
  end

  def ended(usage, outcome: "passed") = {"n" => 1, "outcome" => outcome, "usage" => usage}

  it "reads nil for a run whose definition declares no budget, or a bad stored one" do
    expect(described_class.reading(run([ended({"input_tokens" => 5})], budget: nil))).to be_nil
    expect(described_class.reading(run([], budget: {"tokens" => "lots"}))).to be_nil
    expect(described_class.reading(run([], budget: {"tokens" => 0}))).to be_nil
    expect(described_class.reading({})).to be_nil
    expect(described_class.reading({"definition" => {"budget" => {"tokens" => 5}}, "steps" => nil})).to be_nil
  end

  it "adds input, output and cache creation tokens, and leaves cache reads out" do
    usage = {"input_tokens" => 100, "output_tokens" => 50, "cache_creation_input_tokens" => 25, "cache_read_input_tokens" => 9_000_000}

    expect(described_class.reading(run([ended(usage)]))).to include("used" => 175, "counted" => 1, "uncounted" => 0, "spent" => false, "needed" => nil, "allowance" => 1000)
  end

  it "sums an attempt's usage as recorded, which includes its sub-agents' tokens" do
    usage = {"input_tokens" => 130, "output_tokens" => 52}

    expect(described_class.reading(run([ended(usage)]))).to include("used" => 182, "counted" => 1, "uncounted" => 0)
  end

  it "counts a null or malformed usage as uncounted, not as zero, and leaves out attempts that ran nothing" do
    attempts = [ended({"input_tokens" => 300}), ended(nil), ended({"input_tokens" => "x"}), ended({"input_tokens" => -1}), ended("lots"),
      ended(nil, outcome: "not_delivered")]

    expect(described_class.reading(run(attempts))).to include("used" => 300, "counted" => 1, "uncounted" => 4, "measured" => true)
  end

  describe "review rounds" do
    def reviewed(usage, rounds) = ended(usage, outcome: "checks_passed").merge("rounds" => rounds)

    it "adds each round's usage to its attempt's, and never the verdict rows' own" do
      rounds = [{"round" => 1, "pane" => "%9", "ended" => "incomplete", "usage" => {"input_tokens" => 40, "output_tokens" => 2}},
        {"round" => 2, "pane" => "%9", "ended" => "approved", "usage" => {"input_tokens" => 8}, "reviews" => [{"reviewer" => "skeptic", "usage" => {"input_tokens" => 999}}]}]

      expect(described_class.reading(run([reviewed({"input_tokens" => 100}, rounds)], state: "reviewing"))).to include("used" => 150, "counted" => 3, "uncounted" => 0)
    end

    it "counts a round whose usage could not be read as uncounted" do
      rounds = [{"round" => 1, "pane" => "%9", "ended" => "cancelled", "usage" => nil}, {"round" => 2, "pane" => "%9", "ended" => "redelivered", "usage" => {"input_tokens" => 5}}]

      expect(described_class.reading(run([reviewed({"input_tokens" => 100}, rounds)]))).to include("used" => 105, "counted" => 2, "uncounted" => 1, "measured" => true)
    end

    it "leaves out a round with no pane, which ran nothing, rather than counting it uncounted" do
      rounds = [{"round" => 1, "pane" => nil, "ended" => "review_tampered", "usage" => nil}, {"round" => 2, "ended" => "redelivered", "usage" => nil},
        {"round" => 3, "pane" => "", "usage" => nil}]
      attempt = reviewed({"input_tokens" => 100}, rounds)

      expect(described_class.reading(run([attempt]))).to include("used" => 100, "counted" => 1, "uncounted" => 0)
      expect(described_class.attempt_tokens(Workspace::WorkflowRun::Attempt.from_h(attempt))).to eq(100)
    end

    it "reads an attempt with no rounds, or rounds that are not records, as before" do
      expect(described_class.reading(run([reviewed({"input_tokens" => 7}, "lots")]))).to include("used" => 7, "counted" => 1, "uncounted" => 0)
    end

    it "gives an attempt's tokens with its rounds', nil when any part is unreadable" do
      attempt = ->(hash) { Workspace::WorkflowRun::Attempt.from_h(hash) }

      expect(described_class.attempt_tokens(attempt.call(reviewed({"input_tokens" => 7}, [{"pane" => "%9", "usage" => {"output_tokens" => 3}}])))).to eq(10)
      expect(described_class.attempt_tokens(attempt.call(reviewed({"input_tokens" => 7}, [{"pane" => "%9", "usage" => nil}])))).to be_nil
      expect(described_class.attempt_tokens(attempt.call(ended({"input_tokens" => 7})))).to eq(7)
    end
  end

  describe "an attempt the sweep interrupted for the budget" do
    def interrupted(usage, record) = ended(usage, outcome: "interrupted").merge("budget_interrupt" => record)

    let(:record) { {"tokens" => 1200, "used" => 1200, "allowance" => 1000, "at" => "2026-11-17T00:00:00Z"} }

    it "counts the record's live figure when the usage could not be read, and says it is an estimate" do
      expect(described_class.reading(run([interrupted(nil, record)]))).to include("used" => 1200, "counted" => 1, "uncounted" => 0, "estimated" => 1, "spent" => true, "measured" => true)
    end

    it "counts a readable usage alone, never the record as well" do
      expect(described_class.reading(run([interrupted({"input_tokens" => 900}, record)]))).to include("used" => 900, "counted" => 1, "estimated" => 0, "spent" => false)
    end

    it "leaves an attempt with a record that is not the recorded shape uncounted" do
      attempts = [interrupted(nil, record.merge("tokens" => "lots")), interrupted(nil, record.merge("tokens" => -5)), interrupted(nil, "lots"), interrupted(nil, nil)]

      expect(described_class.reading(run(attempts))).to include("used" => 0, "counted" => 0, "uncounted" => 4, "estimated" => 0)
    end

    it "keeps attempt_tokens, which workflow stats reads, to the measured usage" do
      expect(described_class.attempt_tokens(Workspace::WorkflowRun::Attempt.from_h(interrupted(nil, record)))).to be_nil
      expect(described_class.attempt_tokens(Workspace::WorkflowRun::Attempt.from_h(interrupted({"input_tokens" => 900}, record)))).to eq(900)
    end
  end

  it "is not measured when every ended attempt is uncounted, and never spent" do
    reading = described_class.reading(run([ended(nil), ended(nil)]))

    expect(reading).to include("used" => 0, "counted" => 0, "uncounted" => 2, "measured" => false, "spent" => false)
  end

  it "leaves out the attempt in progress, which has not ended, and is measured with nothing else to count" do
    expect(described_class.reading(run([{"n" => 1}], state: "running"))).to include("measured" => true, "uncounted" => 0, "used" => 0)
    expect(described_class.reading(run([{"n" => 1, "usage" => {"input_tokens" => 900}}], state: "checking"))).to include("used" => 0, "uncounted" => 0)
  end

  it "counts an interrupted attempt\x27s usage once, and still leaves out the running retry" do
    attempts = [ended({"input_tokens" => 100}, outcome: "interrupted"), {"n" => 2, "retry_of" => 1, "usage" => {"input_tokens" => 900}}]

    expect(described_class.reading(run(attempts, state: "running"))).to include("used" => 100, "counted" => 1, "uncounted" => 0)
  end

  it "counts an attempt left without an outcome when a resume replaced it: its usage if it has one, else as uncounted" do
    attempts = [{"n" => 1, "usage" => {"input_tokens" => 700}}, {"n" => 2}, {"n" => 3}]

    expect(described_class.reading(run(attempts, state: "running"))).to include("used" => 700, "counted" => 1, "uncounted" => 1)
    expect(described_class.reading(run(attempts, state: "passed"))).to include("used" => 700, "counted" => 1, "uncounted" => 2)
    expect(described_class.reading(run(attempts, state: "running"), live: false)).to include("used" => 700, "counted" => 1, "uncounted" => 2)
  end

  it "is spent at the allowance, needs the overrun plus one, and suggests a round figure" do
    reading = described_class.reading(run([ended({"input_tokens" => 1000})]))
    expect(reading).to include("spent" => true, "needed" => 1, "suggested" => 100_000)

    reading = described_class.reading(run([ended({"input_tokens" => 4_120_000})], budget: {"tokens" => 4_000_000, "action" => "stop"}))
    expect(reading).to include("spent" => true, "needed" => 120_001, "suggested" => 200_000)
  end

  it "carries the stored interrupt action" do
    reading = described_class.reading(run([ended({"input_tokens" => 10})], budget: {"tokens" => 1000, "action" => "interrupt"}))
    expect(reading).to include("action" => "interrupt")
  end

  it "adds the run's extra_tokens to the allowance, and ignores one that is not a whole number" do
    attempts = [ended({"input_tokens" => 1200})]

    expect(described_class.reading(run(attempts, extra: 500))).to include("allowance" => 1500, "spent" => false, "extra_tokens" => 500)
    expect(described_class.reading(run(attempts, extra: "500"))).to include("allowance" => 1000, "spent" => true, "extra_tokens" => 0)
    expect(described_class.reading(run(attempts, extra: -5))).to include("allowance" => 1000)
  end
end
