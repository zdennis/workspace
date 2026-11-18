require "spec_helper"

RSpec.describe Workspace::WorkflowReportedStatus do
  def parse(text) = described_class.parse(text)

  it "reads each of the four states" do
    described_class::STATES.each do |state|
      expect(parse("Work.\nWORKFLOW_STATUS: #{state} — about it")).to eq(state: state, detail: "about it")
    end
  end

  it "returns nil when there is no line" do
    expect(parse("All finished, nothing to report.")).to be_nil
  end

  it "returns nil for an empty string, nil and non-strings" do
    expect(parse("")).to be_nil
    expect(parse(nil)).to be_nil
    expect(parse(42)).to be_nil
  end

  it "returns an empty detail when none is given" do
    expect(parse("WORKFLOW_STATUS: done")).to eq(state: "done", detail: "")
    expect(parse("WORKFLOW_STATUS: done —")).to eq(state: "done", detail: "")
  end

  it "ignores trailing whitespace and a closing fence" do
    expect(parse("WORKFLOW_STATUS: done — shipped  \n```\n\n  ")).to eq(state: "done", detail: "shipped")
  end

  it "joins a wrapped detail" do
    text = "WORKFLOW_STATUS: needs_input — which database\n  should the migration use?\n"
    expect(parse(text)).to eq(state: "needs_input", detail: "which database should the migration use?")
  end

  it "matches the state without regard to case" do
    expect(parse("workflow_status: STUCK - no access")).to eq(state: "stuck", detail: "no access")
  end

  it "accepts each separator and plain whitespace" do
    ["—", "--", "|", "-", ""].each do |sep|
      expect(parse("WORKFLOW_STATUS: running #{sep} on it")).to eq(state: "running", detail: "on it")
    end
  end

  it "keeps pipes and dashes inside the detail" do
    expect(parse("WORKFLOW_STATUS: stuck — a | b -- c - d")).to eq(state: "stuck", detail: "a | b -- c - d")
  end

  it "returns nil for an unknown state" do
    expect(parse("WORKFLOW_STATUS: finished — yes")).to be_nil
  end

  it "finds the line within the tail of a long message" do
    text = ("x" * 5000) + "\nWORKFLOW_STATUS: done — ok\nThanks!\n"
    expect(parse(text)).to eq(state: "done", detail: "ok Thanks!")
  end

  it "ignores a line further back than the tail" do
    expect(parse("WORKFLOW_STATUS: done — ok\n" + ("x" * 500))).to be_nil
  end

  it "does not raise on invalid bytes" do
    expect(parse("\xFF\xFE WORKFLOW_STATUS: done".b.force_encoding("UTF-8"))).to eq(state: "done", detail: "")
  end
end
