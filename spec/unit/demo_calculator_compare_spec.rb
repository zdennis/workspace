require "spec_helper"
require File.join(PROJECT_ROOT, "script/demo_calculator/compare")

RSpec.describe DemoCalculator::Compare do
  def doc(stamp, defs: {"a" => "1"}, totals: {}, header: {})
    {"record" => {"stamp" => stamp, "definitions" => defs, "branch" => "calc-demo/#{stamp}"},
     "header" => {"model" => "m", "agent_version" => "1", "base_sha" => "b", "workspace_sha" => "w",
                  "price_date" => "2026-11-01"}.merge(header),
     "totals" => totals}
  end

  describe ".median" do
    it "takes the middle of an odd count" do
      expect(described_class.median([5, 1, 3])).to eq(3)
    end

    it "averages the middle two of an even count" do
      expect(described_class.median([4, 1, 2, 10])).to eq(3.0)
    end

    it "is nil for no values" do
      expect(described_class.median([])).to be_nil
    end
  end

  describe ".select" do
    it "groups across definition edits and takes the last K by stamp" do
      docs = [doc("4"), doc("2"), doc("3", defs: {"a" => "2"}), doc("1"), doc("5", defs: {"a" => "9"})]
      expect(described_class.select(docs, last: 3).map { |d| d["record"]["stamp"] }).to eq(%w[3 4 5])
    end

    it "does not group runs of other items, another model or another agent version" do
      docs = [doc("1", defs: {"b" => "1"}), doc("2", header: {"model" => "n"}), doc("3", header: {"agent_version" => "2"}), doc("4")]
      expect(described_class.select(docs).map { |d| d["record"]["stamp"] }).to eq(%w[4])
    end

    it "skips docs without a stamp" do
      expect(described_class.select([{"x" => 1}, doc("1")]).size).to eq(1)
    end
  end

  describe ".stat" do
    it "leaves unknowns out and marks the stat partial" do
      docs = [doc("1", totals: {"attempts" => 4}), doc("2", totals: {"attempts" => nil}),
        doc("3", totals: {"attempts" => "?"}), doc("4", totals: {"attempts" => 8})]
      expect(described_class.stat(docs, "attempts")).to include(median: 6.0, min: 4, max: 8, known: 2, partial: true)
    end

    it "reads distinct review rounds, falling back to the raw total in an older eval.json" do
      docs = [doc("1", totals: {"review_rounds_distinct" => 2, "review_rounds" => 3}), doc("2", totals: {"review_rounds" => 4})]
      expect(described_class.stat(docs, "review_rounds_distinct")).to include(median: 3.0, min: 2, max: 4, known: 2, partial: false)
      expect(described_class::METRICS.map(&:first)).to include("review_rounds_distinct")
      expect(described_class::METRICS.map(&:first)).not_to include("review_rounds")
    end

    it "marks a lower-bound metric partial" do
      docs = [doc("1", totals: {"input" => 5, "partial" => ["input"]}), doc("2", totals: {"input" => 7})]
      expect(described_class.stat(docs, "input")[:partial]).to be true
    end

    it "is not partial when every run has the value" do
      docs = [doc("1", totals: {"lint" => 0}), doc("2", totals: {"lint" => 2})]
      expect(described_class.stat(docs, "lint")).to include(median: 1.0, partial: false)
    end
  end

  describe ".header" do
    it "flags the fields that differ" do
      docs = [doc("1"), doc("2", header: {"model" => "n"})]
      header = described_class.header(docs)
      expect(header["model"][:differs]).to be true
      expect(header["base_sha"][:differs]).to be false
    end
  end

  describe ".render" do
    it "compares two runs when asked for the last 2, and says which definitions differ" do
      docs = [doc("1", defs: {"a" => "1", "b" => "1"}, totals: {"attempts" => 2}), doc("2", defs: {"a" => "1", "b" => "2"}, totals: {"attempts" => 4})]
      text = described_class.render(docs, last: 2)
      expect(text).to include("Median [min–max] over 2 runs")
      expect(text).to include("definition a: same (file)", "definition b: differs (file)")
    end

    it "reads the resolved definition hash from the rows, so a changed parent shows as differs" do
      with_row = ->(stamp, sha) { doc(stamp, defs: {"a" => "same-file"}).merge("rows" => [{"workflow" => "a", "definition_sha256" => sha}]) }
      text = described_class.render([with_row.call("1", "x"), with_row.call("2", "y")], last: 2)
      expect(text).to include("definition a: differs (resolved)")
      same = described_class.render([with_row.call("1", "x"), with_row.call("2", "x")], last: 2)
      expect(same).to include("definition a: same (resolved)")
    end

    it "compares file hashes when only some documents carry a resolved hash" do
      old = doc("1", defs: {"a" => "same-file"})
      new = doc("2", defs: {"a" => "same-file"}).merge("rows" => [{"workflow" => "a", "definition_sha256" => "resolved"}])
      expect(described_class.render([old, new], last: 2)).to include("definition a: same (file)")
      changed = doc("2", defs: {"a" => "other-file"}).merge("rows" => [{"workflow" => "a", "definition_sha256" => "resolved"}])
      expect(described_class.render([old, changed], last: 2)).to include("definition a: differs (file)")
    end

    it "uses the file hash for documents whose rows carry no definition hash" do
      text = described_class.render([doc("1", defs: {"a" => "1"}), doc("2", defs: {"a" => "2"})], last: 2)
      expect(text).to include("definition a: differs (file)")
    end

    it "says unknown when neither hash is on every document" do
      old = doc("1", defs: {"a" => "1"})
      new = doc("2", defs: {"b" => "1"}).merge("rows" => [{"workflow" => "a", "definition_sha256" => "r"}])
      expect(described_class.definition_status([old, new])["a"]).to eq("unknown")
    end

    it "still wants 3 runs by default" do
      expect(described_class.render([doc("1"), doc("2")], last: 3)).to include("need 3 for a comparison")
    end

    it "lists runs only with fewer than 3 matching runs" do
      text = described_class.render([doc("1"), doc("2")])
      expect(text).to include("Only 2 matching runs", "calc-demo/1", "calc-demo/2")
      expect(text).not_to include("Median")
    end

    it "prints median [min–max] with ≥ for a metric with unknowns" do
      docs = [doc("1", totals: {"attempts" => 3, "cost_usd" => 1.0, "wall" => 90}),
        doc("2", totals: {"attempts" => 5, "cost_usd" => nil, "wall" => 3700}),
        doc("3", totals: {"attempts" => 4, "cost_usd" => 3.0, "wall" => 30})]
      text = described_class.render(docs)
      expect(text).to include("Median [min–max] over 3 runs")
      expect(text).to match(/attempts\s+4 \[3–5\]\n/)
      expect(text).to match(/cost\s+≥≈\$2\.00 \[≈\$1\.00–≈\$3\.00\]/)
      expect(text).to match(/wall\s+1m30s \[30s–1h01m\]/)
      expect(text).to match(/lint offenses\s+\?\n/)
      expect(text).to include("differing: none")
    end

    it "names the header fields that differ" do
      docs = [doc("1"), doc("2", header: {"base_sha" => "c"}), doc("3", header: {"price_date" => "x"})]
      expect(described_class.render(docs)).to include("differing: base_sha, price_date")
    end

    it "says so with no runs" do
      expect(described_class.render([])).to include("No eval runs")
    end
  end
end
