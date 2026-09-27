require "spec_helper"

RSpec.describe Workspace::Duration do
  describe ".parse" do
    it "parses a plain number of seconds" do
      expect(described_class.parse("20")).to eq(20.0)
    end

    it "parses a number with a trailing s" do
      expect(described_class.parse("20s")).to eq(20.0)
    end

    it "accepts a Numeric directly" do
      expect(described_class.parse(20)).to eq(20.0)
    end

    it "parses minute and hour suffixes" do
      expect(described_class.parse("5m")).to eq(300.0)
      expect(described_class.parse("1.5h")).to eq(5400.0)
      expect(described_class.parse("2M")).to eq(120.0)
    end

    it "rejects an unknown unit" do
      expect { described_class.parse("5d") }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for an unparseable value" do
      expect { described_class.parse("soon") }.to raise_error(ArgumentError)
    end
  end
end
