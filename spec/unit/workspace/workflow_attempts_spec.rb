# frozen_string_literal: true

require "spec_helper"

RSpec.describe Workspace::WorkflowAttempts do
  it "shows an overridden attempt as its own outcome" do
    run = {"id" => "wr_1", "definition" => {"steps" => [{"id" => "plan"}]},
           "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "overridden", "code" => "head_moved"}, {"n" => 2, "outcome" => "passed"}]}}}

    rows = described_class.new.read(run)["attempts"]

    expect(rows.map { |row| row["outcome"] }).to eq(%w[overridden passed])
  end
end
