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

  it "counts a null or malformed usage as uncounted, not as zero, and leaves out attempts that ran nothing" do
    attempts = [ended({"input_tokens" => 300}), ended(nil), ended({"input_tokens" => "x"}), ended({"input_tokens" => -1}), ended("lots"),
      ended(nil, outcome: "not_delivered")]

    expect(described_class.reading(run(attempts))).to include("used" => 300, "counted" => 1, "uncounted" => 4, "measured" => true)
  end

  it "is not measured when every ended attempt is uncounted, and never spent" do
    reading = described_class.reading(run([ended(nil), ended(nil)]))

    expect(reading).to include("used" => 0, "counted" => 0, "uncounted" => 2, "measured" => false, "spent" => false)
  end

  it "leaves out the attempt in progress, which has not ended, and is measured with nothing else to count" do
    expect(described_class.reading(run([{"n" => 1}], state: "running"))).to include("measured" => true, "uncounted" => 0, "used" => 0)
    expect(described_class.reading(run([{"n" => 1, "usage" => {"input_tokens" => 900}}], state: "checking"))).to include("used" => 0, "uncounted" => 0)
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

  it "adds the run's extra_tokens to the allowance, and ignores one that is not a whole number" do
    attempts = [ended({"input_tokens" => 1200})]

    expect(described_class.reading(run(attempts, extra: 500))).to include("allowance" => 1500, "spent" => false, "extra_tokens" => 500)
    expect(described_class.reading(run(attempts, extra: "500"))).to include("allowance" => 1000, "spent" => true, "extra_tokens" => 0)
    expect(described_class.reading(run(attempts, extra: -5))).to include("allowance" => 1000)
  end
end
