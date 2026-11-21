require "spec_helper"
require File.join(PROJECT_ROOT, "script/demo_calculator/eval_report")

RSpec.describe DemoCalculator::EvalReport do
  let(:pricing) { {"models" => {"m" => {"input" => 10.0, "output" => 20.0, "cache_creation" => 0.0, "cache_read" => 1.0}}} }

  def run_with(*attempts)
    {"steps" => {"s" => {"attempts" => attempts}}}
  end

  def ran_row(features:, usage:)
    {workflow: "w", state: "done", ran: true, features: features, attempts: 1, retries: 0, review_rounds: 0,
     wall: 1, active: 1, stopped: 0, gap: 0, usage: usage, acceptance: nil, item: 1}
  end

  def row_cells(row)
    described_class.table([row], described_class.totals([row], acceptance_passed: nil, lint: nil)).lines[2].split(/\s{2,}/)
  end

  it "shows fired, armed, missed and unknown feature counts apart, omitting zeros" do
    features = {"a" => "fired", "b" => "fired", "c" => "fired", "d" => "armed", "e" => "missed", "f" => "?"}
    cells = row_cells(ran_row(features: features, usage: described_class.usage(run_with, pricing)))
    expect(cells[2]).to eq("3f 1a 1m 1?")
    cells = row_cells(ran_row(features: {"a" => "fired"}, usage: described_class.usage(run_with, pricing)))
    expect(cells[2]).to eq("1f")
  end

  it "prints shared tokens and an unknown cost when every attempt shares its usage" do
    usage = described_class.usage(run_with({"usage" => nil, "usage_shared" => {"group" => "g"}}), pricing)
    cells = row_cells(ran_row(features: {}, usage: usage))
    expect(cells).to include("shared")
    expect(cells).not_to include("≥0")
    expect(usage[:cost_usd]).to be_nil
  end

  it "prices round usage of an attempt with no usage, as partial" do
    round = {"usage" => {"input_tokens" => 1_000_000}}
    usage = described_class.usage(run_with({"usage" => nil, "agent" => {"model" => "m"}, "rounds" => [round]}), pricing)
    expect(usage[:cost_usd]).to eq(10.0)
    expect(usage[:cost_partial]).to be(true)
  end
end
