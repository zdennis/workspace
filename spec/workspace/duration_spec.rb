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

  describe ".parse_capped" do
    it "accepts a positive value at or under the cap" do
      expect(described_class.parse_capped("30s", max: 60)).to eq(30.0)
      expect(described_class.parse_capped("60s", max: 60)).to eq(60.0)
    end

    it "rejects a value over the cap" do
      expect { described_class.parse_capped("61s", max: 60) }.to raise_error(ArgumentError, /at most 60s/)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0s", "-1", "later"].each do |bad|
        expect { described_class.parse_capped(bad, max: 60) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".parse_ranged" do
    it "accepts a value within [min, max]" do
      expect(described_class.parse_ranged("1s", min: 1, max: 60)).to eq(1.0)
      expect(described_class.parse_ranged("30s", min: 1, max: 60)).to eq(30.0)
      expect(described_class.parse_ranged("1m", min: 1, max: 60)).to eq(60.0)
    end

    it "rejects a value below min or above max" do
      expect { described_class.parse_ranged("0.5s", min: 1, max: 60) }.to raise_error(ArgumentError, /must be at least 1s and at most 60s/)
      expect { described_class.parse_ranged("61s", min: 1, max: 60) }.to raise_error(ArgumentError, /must be at least 1s and at most 60s/)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "0s", "-1", "later"].each do |bad|
        expect { described_class.parse_ranged(bad, min: 1, max: 60) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".humanize" do
    it "renders sub-minute durations in seconds" do
      expect(described_class.humanize(45)).to eq("45s")
      expect(described_class.humanize(0)).to eq("0s")
    end

    it "renders minute-scale durations in minutes" do
      expect(described_class.humanize(60)).to eq("1m")
      expect(described_class.humanize(720)).to eq("12m")
    end

    it "renders hour-scale durations as hours and minutes" do
      expect(described_class.humanize(5400)).to eq("1h 30m")
      expect(described_class.humanize(3600)).to eq("1h 0m")
    end
  end
end
