RSpec.describe Workspace::Which do
  describe ".call" do
    it "returns true for an executable on PATH" do
      expect(described_class.call("ruby")).to be true
    end

    it "returns false for an executable not on PATH" do
      expect(described_class.call("definitely-not-a-real-executable-xyz")).to be false
    end
  end
end
