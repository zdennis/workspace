RSpec.describe Workspace::WorkflowSeed do
  describe ".task_text" do
    it "joins key, title and url" do
      ticket = {"key" => "PROJ-1", "title" => "Fix it", "url" => "https://x.test/PROJ-1"}
      expect(described_class.task_text(ticket, nil)).to eq("PROJ-1: Fix it (https://x.test/PROJ-1)")
    end

    it "reads a pull request ticket" do
      ticket = {"key" => "#12", "title" => "Title", "url" => "https://github.com/o/r/pull/12"}
      expect(described_class.task_text(ticket, nil)).to eq("#12: Title (https://github.com/o/r/pull/12)")
    end

    it "leaves out a missing title" do
      expect(described_class.task_text({"key" => "PROJ-1", "url" => "https://x.test"}, nil)).to eq("PROJ-1 (https://x.test)")
    end

    it "leaves out a missing url" do
      expect(described_class.task_text({"key" => "PROJ-1", "title" => "T"}, nil)).to eq("PROJ-1: T")
    end

    it "appends the prompt after a blank line" do
      expect(described_class.task_text({"key" => "PROJ-1", "title" => "T"}, "do it")).to eq("PROJ-1: T\n\ndo it")
    end

    it "gives the prompt alone without a ticket" do
      expect(described_class.task_text(nil, "do it")).to eq("do it")
    end

    it "is nil for nothing" do
      expect(described_class.task_text(nil, nil)).to be_nil
    end
  end

  describe ".fillable?" do
    let(:definition) { double(to_h: {"inputs" => {"task" => {}}}) }

    it "is true for a declared input not given" do
      expect(described_class.fillable?(definition, "task", {})).to be true
    end

    it "is false for a given input, even an empty one" do
      expect(described_class.fillable?(definition, "task", {"task" => ""})).to be false
    end

    it "is false for an undeclared input" do
      expect(described_class.fillable?(definition, "spec", {})).to be false
    end
  end
end
