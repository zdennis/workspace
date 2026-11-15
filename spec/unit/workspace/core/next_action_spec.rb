require "spec_helper"

RSpec.describe Workspace::NextAction do
  describe ".build" do
    it "returns action, args and needs in that order, with no why key" do
      entry = described_class.build("workflow resume", "wr_1")
      expect(entry.to_a).to eq([["action", "workflow resume"], ["args", ["wr_1"]], ["needs", []]])
    end

    it "adds why last when given" do
      entry = described_class.build("focus", "app", "--pane", "%1", why: "the pane waits")
      expect(entry.keys).to eq(%w[action args needs why])
      expect(entry["why"]).to eq("the pane waits")
    end

    it "carries the needs it is given" do
      need = described_class.need("note", "--note")
      expect(described_class.build("workflow reject", "wr_1", needs: [need])["needs"]).to eq([need])
    end

    it "gives no args as an empty list" do
      expect(described_class.build("launch")["args"]).to eq([])
    end
  end

  describe ".need" do
    it "returns name and flag" do
      expect(described_class.need("note", "--note").to_a).to eq([["name", "note"], ["flag", "--note"]])
    end

    it "keeps a nil flag for a positional value" do
      expect(described_class.need("answer", nil)).to eq({"name" => "answer", "flag" => nil})
    end

    it "appends string-keyed extras after name and flag" do
      need = described_class.need("extra_tokens", "--extra-tokens", "min" => 5, "suggested" => 10)
      expect(need.to_a).to eq([["name", "extra_tokens"], ["flag", "--extra-tokens"], ["min", 5], ["suggested", 10]])
    end
  end
end
