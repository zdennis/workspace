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

  def table_for(rows)
    described_class.table(rows, described_class.totals(rows, acceptance_passed: 2, acceptance_of: 3, lint: nil)).lines.map(&:chomp)
  end

  def usage_row(**extra)
    ran_row(features: {}, usage: described_class.usage(run_with, pricing)).merge(review_rounds: 2, review_rounds_distinct: 1, manual: 0, **extra)
  end

  it "prints distinct review rounds and the manual count, per row and in the total" do
    lines = table_for([usage_row(manual: 3)])
    expect(lines[0].split(/\s+/).values_at(5, 6)).to eq(%w[rnd manual])
    expect(lines[2].split(/\s{2,}/).values_at(5, 6)).to eq(%w[1 3])
    expect(lines[3]).to match(/\s1\s+3\s+1s/)
  end

  it "shows how many items completed and what became of the rest, and the acceptance total over its groups" do
    rows = [usage_row(state: "completed"), usage_row(state: "cancelled"), {workflow: "w3", ran: false, state: "not run"}]
    total = table_for(rows).last.split(/\s{2,}/)
    expect(total[1]).to eq("1/3 completed, 1 cancelled, 1 not run")
    expect(total.last).to eq("2/3")
  end

  it "shows a dash for the gap of the item no item follows, and ? when a next item has no time" do
    cells = ->(row) { table_for([row])[2].split(/\s{2,}/) }
    expect(cells.call(usage_row(gap: nil, final: true))).to include("–")
    expect(cells.call(usage_row(gap: nil, final: false))).to include("?")
  end

  it "marks a completed item whose own group fails and explains the mark under the table" do
    failing = {passed: [], failed: [1], regressions: []}
    lines = table_for([usage_row(state: "completed", acceptance: failing)])
    expect(lines[2]).to match(/\Aw\s+completed\*/)
    expect(lines.last).to eq("* completed while its own acceptance group fails")
    expect(table_for([usage_row(state: "completed", acceptance: {passed: [1], failed: [], regressions: []})].map { |r| r }).join).not_to include("*")
  end

  describe ".mark_regressions" do
    def acceptance(item, passed, failed) = {item: item, acceptance: {passed: passed, failed: failed, regressions: failed.select { |n| n < item }}}

    it "calls a failing group a regression only when it passed at an earlier item's head" do
      rows = [acceptance(1, [1], []), acceptance(2, [2], [1]), acceptance(3, [1, 3], [2]), acceptance(4, [1, 2, 4], [3])]
      described_class.mark_regressions(rows)
      expect(rows.map { |r| r[:acceptance][:regressions] }).to eq([[], [1], [2], [3]])
    end

    it "does not call a group that never passed a regression" do
      rows = [acceptance(1, [], [1]), acceptance(2, [2], [1])]
      expect(described_class.mark_regressions(rows).map { |r| r[:acceptance][:regressions] }).to eq([[], []])
    end
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
