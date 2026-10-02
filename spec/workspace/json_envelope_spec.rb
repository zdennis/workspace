RSpec.describe Workspace::JsonEnvelope do
  describe ".error" do
    it "builds the error document with a code" do
      expect(described_class.error(1, "boom", code: "usage")).to eq(
        {"schema_version" => 1, "ok" => false, "error" => "boom", "code" => "usage"}
      )
    end

    it "defaults the code to error and omits empty details and retry" do
      expect(described_class.error(1, "boom").keys).to eq(%w[schema_version ok error code])
      expect(described_class.error(1, "boom")["code"]).to eq("error")
    end

    it "includes details and retry when given" do
      doc = described_class.error(1, "dirty", code: "unsaved_work", details: {"changed_files" => 3}, retry_with: {"flags" => ["--force"], "destructive" => true})
      expect(doc["details"]).to eq({"changed_files" => 3})
      expect(doc["retry"]).to eq({"flags" => ["--force"], "destructive" => true})
    end
  end

  describe ".from_exception" do
    it "uses the exception's message, code, details and retry" do
      error = Workspace::Error.new("nope", code: "unknown_workspace", details: {"name" => "x"}, retry_with: {"flags" => ["--all"]})
      expect(described_class.from_exception(1, error)).to eq(
        {"schema_version" => 1, "ok" => false, "error" => "nope", "code" => "unknown_workspace",
         "details" => {"name" => "x"}, "retry" => {"flags" => ["--all"]}}
      )
    end

    it "lets the caller override the message" do
      expect(described_class.from_exception(1, Workspace::Error.new("long\ntext"), message: "long")["error"]).to eq("long")
    end

    it "maps an OptionParser error to the usage code" do
      doc = described_class.from_exception(1, OptionParser::InvalidOption.new("--bogus"))
      expect(doc["code"]).to eq("usage")
      expect(doc["error"]).to eq("invalid option: --bogus")
    end

    it "falls back to the error code for a non-workspace exception" do
      expect(described_class.from_exception(1, RuntimeError.new("x"))["code"]).to eq("error")
    end
  end
end
