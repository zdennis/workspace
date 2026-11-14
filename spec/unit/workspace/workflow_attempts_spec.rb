# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::WorkflowAttempts do
  it "shows an overridden attempt as its own outcome" do
    run = {"id" => "wr_1", "definition" => {"steps" => [{"id" => "plan"}]},
           "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "overridden", "code" => "head_moved"}, {"n" => 2, "outcome" => "passed"}]}}}

    rows = described_class.new.read(run)["attempts"]

    expect(rows.map { |row| row["outcome"] }).to eq(%w[overridden passed])
  end

  it "names the attempt a review rejected on the attempt that retried it, and none on any other" do
    run = {"id" => "wr_1", "definition" => {"steps" => [{"id" => "plan"}]},
           "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "failed", "code" => "review_rejected"}, {"n" => 2, "retry_of" => 1}, {"n" => 3, "retry_of" => "x"}]}}}

    rows = described_class.new.read(run)["attempts"]

    expect(rows.map { |row| row["retry_of"] }).to eq([nil, 1, nil])
  end

  describe "a reviewed attempt (spec/fixtures/workflow_runs/reviewing.json)" do
    def fixture = JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/workflow_runs/reviewing.json")))

    it "reads a run being reviewed: the checks_passed attempt has no verdicts yet, so no review summary" do
      rows = described_class.new.read(fixture, step: "build")["attempts"]

      expect(rows.map { |row| row.slice("outcome", "review", "review_outcome", "reviews") }).to eq([{"outcome" => "checks_passed", "review" => nil, "review_outcome" => nil, "reviews" => nil}])
    end

    it "summarises the verdicts of a decided attempt and carries its rows with their isolation" do
      run = fixture
      reviews = [{"reviewer" => "skeptic", "verdict" => "reject", "isolation" => "review_pane"}, {"reviewer" => "scribe", "verdict" => "approve", "isolation" => "review_pane"},
        {"reviewer" => "owl", "verdict" => "approve", "isolation" => "review_pane"}, {"reviewer" => "ghost", "verdict" => nil, "problem" => "missing", "isolation" => "review_pane"}]
      run["steps"]["build"]["attempts"][0].merge!("outcome" => "failed", "review_outcome" => {"round" => 1, "approvals" => 2, "need" => 3, "must" => [], "passed" => false}, "reviews" => reviews)

      row = described_class.new.read(run, step: "build")["attempts"].first

      expect(row["review"]).to eq("2/4 approve, skeptic reject, no verdict: ghost")
      expect(row["reviews"]).to eq(reviews)
      expect(row["review_outcome"]).to include("passed" => false)
    end

    it "gives an old attempt no review keys" do
      run = {"id" => "wr_1", "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "passed"}]}}}
      expect(described_class.new.read(run)["attempts"].first).to include("review" => nil, "reviews" => nil)
    end
  end
end
