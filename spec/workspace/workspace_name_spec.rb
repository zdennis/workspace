require "spec_helper"

RSpec.describe Workspace::WorkspaceName do
  let(:projects) { ["Notes", "api"] }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: projects) }
  subject(:names) { described_class.new(project_config: project_config) }

  describe ".normalize" do
    it "lowercases and leaves nil alone" do
      expect(described_class.normalize("Notes")).to eq("notes")
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe ".same?" do
    it "ignores case" do
      expect(described_class.same?("notes", "Notes")).to be(true)
      expect(described_class.same?("notes", "api")).to be(false)
    end

    it "is false when either side is nil" do
      expect(described_class.same?(nil, "notes")).to be(false)
      expect(described_class.same?("notes", nil)).to be(false)
    end
  end

  describe "#resolve" do
    it "gives the on-disk name for a name that matches a config ignoring case" do
      expect(names.resolve("notes")).to eq("Notes")
      expect(names.resolve("NOTES")).to eq("Notes")
      expect(names.resolve("Notes")).to eq("Notes")
    end

    it "gives the lowercase name when no config matches" do
      expect(names.resolve("Fresh")).to eq("fresh")
    end

    it "keeps nil" do
      expect(names.resolve(nil)).to be_nil
    end

    it "prefers the exact spelling when configs differ only in case" do
      projects.replace(["notes", "Notes"])
      expect(names.resolve("Notes")).to eq("Notes")
      expect(names.resolve("notes")).to eq("notes")
    end
  end

  describe "#match" do
    it "is nil when no config matches, or for nil" do
      expect(names.match("fresh")).to be_nil
      expect(names.match(nil)).to be_nil
    end

    it "finds the config ignoring case" do
      expect(names.match("nOtEs")).to eq("Notes")
    end
  end
end
