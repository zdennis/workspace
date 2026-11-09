require "spec_helper"

RSpec.describe Workspace::IdPatterns do
  describe "LIBRARY_NAME" do
    it "accepts lowercase words joined by single hyphens" do
      expect(%w[a notes my-pack-2 9]).to all(match(described_class::LIBRARY_NAME))
    end

    it "refuses uppercase, underscores, doubled, leading or trailing hyphens and newlines" do
      ["Notes", "a_b", "a--b", "-a", "a-", "", "a\nb", "a/b"].each do |name|
        expect(name).not_to match(described_class::LIBRARY_NAME)
      end
    end
  end

  describe "WORKFLOW_ID" do
    it "accepts ids up to 40 characters" do
      expect(%w[rpiv a pr-feedback step_1 1x]).to all(match(described_class::WORKFLOW_ID))
      expect("a" * 40).to match(described_class::WORKFLOW_ID)
    end

    it "refuses a leading separator, uppercase, 41 characters and newlines" do
      ["-a", "_a", "A", "a b", "", "a" * 41, "a\nb"].each do |id|
        expect(id).not_to match(described_class::WORKFLOW_ID)
      end
    end
  end

  it "words the workflow id rule for messages" do
    expect(described_class::WORKFLOW_ID_RULE).to eq("lowercase letters, digits, '-' and '_'")
  end
end
