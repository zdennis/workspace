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

  it "does not read the tag inside a sentence or a longer word" do
    expect(parse("I will end with WORKFLOW_STATUS: stuck next.")).to be_nil
    expect(parse("XWORKFLOW_STATUS: stuck — no")).to be_nil
  end

  it "finds the line within the tail of a long message" do
    text = ("x" * 5000) + "\nWORKFLOW_STATUS: done — ok\nThanks!\n"
    expect(parse(text)).to eq(state: "done", detail: "ok Thanks!")
  end

  it "ignores a line further back than the tail" do
    expect(parse("WORKFLOW_STATUS: done — ok\n" + ("x" * 500))).to be_nil
  end

  it "reads a last line longer than the tail whole" do
    detail = "verified " + ("y" * 240)
    text = ("prose line\n" * 400) + "WORKFLOW_STATUS: done — #{detail}\n"
    expect(parse(text)).to eq(state: "done", detail: detail)
  end

  it "reads a line that starts exactly at the tail's cut" do
    line = "WORKFLOW_STATUS: done — " + ("w" * (described_class::TAIL_CHARS - 24))
    text = ("p" * 50) + "\n" + line
    expect(text.length - described_class::TAIL_CHARS).to eq(51)
    expect(parse(text)).to eq(state: "done", detail: "w" * (described_class::TAIL_CHARS - 24))
  end

  it "reads a long line that starts the message" do
    detail = "z" * 300
    expect(parse("WORKFLOW_STATUS: stuck — #{detail}")).to eq(state: "stuck", detail: detail)
  end

  it "ignores a tag that starts more than MAX_LINE_BACK before the tail" do
    text = "intro\nWORKFLOW_STATUS: done — " + ("x" * (described_class::TAIL_CHARS + described_class::MAX_LINE_BACK + 10))
    expect(parse(text)).to be_nil
  end

  it "does not read a tag in the middle of a line where the window begins" do
    head = "a" * 100
    text = head + "WORKFLOW_STATUS: done — " + ("x" * (described_class::TAIL_CHARS + described_class::MAX_LINE_BACK - 24))
    expect(text.length - described_class::TAIL_CHARS - described_class::MAX_LINE_BACK).to eq(head.length)
    expect(parse(text)).to be_nil
  end

  it "reads the last of two consecutive tagged lines" do
    expect(parse("WORKFLOW_STATUS: running — a\nWORKFLOW_STATUS: done — b")).to eq(state: "done", detail: "b")
  end

  it "reads the last tagged line when a blank line separates two" do
    expect(parse("x\nWORKFLOW_STATUS: running — a\nmore\n\nWORKFLOW_STATUS: done — b")).to eq(state: "done", detail: "b")
  end

  it "reads the final line over an interim one the tail's cut lands in" do
    interim = "WORKFLOW_STATUS: running — " + ("i" * 250)
    text = ("prose line\n" * 50) + interim + "\nWORKFLOW_STATUS: done — final"
    expect(parse(text)).to eq(state: "done", detail: "final")
  end

  it "does not raise on invalid bytes" do
    expect(parse("\xFF\xFE\nWORKFLOW_STATUS: done".b.force_encoding("UTF-8"))).to eq(state: "done", detail: "")
  end

  # Synthetic final messages in the shapes S2 measured; the prose before each line puts it past the 200-char tail.
  describe "golden final-message shapes" do
    golden = File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_reported_status_golden")
    expected = JSON.parse(File.read(File.join(golden, "expected.json")))

    it "has an expected parse for every fixture and a fixture for every expected parse" do
      expect(Dir.children(golden).grep(/\.txt\z/).sort).to eq(expected.keys.sort)
    end

    expected.each do |name, want|
      it "parses #{name} as expected" do
        got = parse(File.read(File.join(golden, name)))
        expect(got&.transform_keys(&:to_s)).to eq(want)
      end
    end
  end

  describe ".words and .shown" do
    it "words a report as state, or state and detail" do
      expect(described_class.words({"state" => "stuck", "detail" => "no access"})).to eq("stuck: no access")
      expect(described_class.words({"state" => "done", "detail" => ""})).to eq("done")
      expect(described_class.words(nil)).to be_nil
      expect(described_class.words({"state" => ""})).to be_nil
      expect(described_class.words({"state" => 5, "detail" => "x"})).to be_nil
      expect(described_class.words("done")).to be_nil
    end

    it "cuts a report to state, detail and at, and gives nil for none" do
      expect(described_class.shown({"state" => "done", "detail" => "x", "at" => "t", "source" => "report"})).to eq({"state" => "done", "detail" => "x", "at" => "t"})
      expect(described_class.shown({})).to be_nil
      expect(described_class.shown(nil)).to be_nil
      expect(described_class.shown("done")).to be_nil
      expect(described_class.shown({"state" => 3})).to be_nil
    end
  end
end
