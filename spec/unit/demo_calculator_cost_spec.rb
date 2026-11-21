require "spec_helper"
require File.join(PROJECT_ROOT, "script/demo_calculator/cost")

RSpec.describe DemoCalculator do
  let(:usage) do
    {"input_tokens" => 100, "output_tokens" => 50,
     "cache_creation_input_tokens" => 10, "cache_read_input_tokens" => 1000}
  end

  describe DemoCalculator::Tokens do
    it "counts a missing cache key as 0" do
      sum = described_class.sum([{"usage" => {"input_tokens" => 5, "output_tokens" => 2}}])
      expect(sum).to include(input: 5, output: 2, cache_creation: 0, cache_read: 0, partial: false)
    end

    it "adds attempts and round usage" do
      attempts = [{"usage" => usage, "rounds" => [{"usage" => usage}, {"usage" => usage}]}, {"usage" => usage}]
      expect(described_class.sum(attempts)).to include(input: 400, output: 200, cache_creation: 40, cache_read: 4000)
    end

    it "marks a nil usage partial" do
      sum = described_class.sum([{"usage" => usage}, {"usage" => nil}])
      expect(sum).to include(input: 100, partial: true)
    end

    it "marks a nil round usage partial" do
      sum = described_class.sum([{"usage" => usage, "rounds" => [{"usage" => nil}]}])
      expect(sum[:partial]).to be true
    end

    it "counts shared usage as shared, not unknown" do
      sum = described_class.sum([{"usage" => nil, "usage_shared" => {"group" => "finish"}}])
      expect(sum).to include(input: 0, partial: false, shared: true)
    end
  end

  describe DemoCalculator::Cost do
    let(:pricing) { {"models" => {"m" => {"input" => 10.0, "output" => 20.0, "cache_creation" => 0.0, "cache_read" => 1.0}}} }

    it "prices known models" do
      tokens = {input: 1_000_000, output: 500_000, cache_creation: 0, cache_read: 2_000_000}
      expect(described_class.price(tokens, "m", pricing)).to eq("≈$22.00")
    end

    it "returns ? for an unknown or missing model" do
      expect(described_class.price({input: 1}, "x", pricing)).to eq("?")
      expect(described_class.price({input: 1}, nil, pricing)).to eq("?")
    end

    it "loads the shipped pricing file" do
      pricing = described_class.load_pricing(File.join(PROJECT_ROOT, "demo/pricing.yml"))
      expect(pricing["price_date"]).to eq("2026-11-21")
      expect(pricing["models"].keys).to include("claude-opus-5-5", "claude-fable-5-2")
    end
  end

  describe DemoCalculator::Fmt do
    it "shows ? for nil" do
      expect(described_class.value(nil)).to eq("?")
      expect(described_class.value(0)).to eq("0")
    end

    it "prefixes partial totals with ≥ but leaves ? alone" do
      expect(described_class.total("≈$1.00", true)).to eq("≥≈$1.00")
      expect(described_class.total("≈$1.00", false)).to eq("≈$1.00")
      expect(described_class.total("?", true)).to eq("?")
    end

    it "says not run" do
      expect(described_class.not_run).to eq("not run")
    end
  end
end
