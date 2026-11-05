RSpec.describe Workspace::ByteSize do
  it "parses a byte count and binary KB, MB and GB suffixes" do
    expect(described_class.parse("5242880")).to eq(5_242_880)
    expect(described_class.parse(4096)).to eq(4096)
    expect(described_class.parse("512KB")).to eq(524_288)
    expect(described_class.parse("1mb")).to eq(1_048_576)
    expect(described_class.parse(" 1.5 MB ")).to eq(1_572_864)
    expect(described_class.parse("2GB")).to eq(2 * 1024**3)
    expect(described_class.parse("10B")).to eq(10)
  end

  it "refuses anything else" do
    ["", "abc", "-1MB", "1TB", "MB", "1 2"].each do |bad|
      expect { described_class.parse(bad) }.to raise_error(ArgumentError, /expected a size/)
    end
  end

  it "refuses a size below the minimum" do
    expect { described_class.parse_at_least("10KB", min: 65_536) }.to raise_error(ArgumentError, /at least 64KB, got "10KB"/)
    expect(described_class.parse_at_least("64KB", min: 65_536)).to eq(65_536)
  end

  it "renders whole sizes short" do
    expect(described_class.humanize(5 * 1024**2)).to eq("5MB")
    expect(described_class.humanize(65_536)).to eq("64KB")
    expect(described_class.humanize(1000)).to eq("1000B")
  end
end
