require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::ScanSlotLimiter do
  let(:dir) { File.join(Dir.mktmpdir("ws-scan-slots"), "scan-slots") }
  let(:log) { StringIO.new }
  let(:logger) { Workspace::Logger.new(output: log, enabled: true) }

  after { FileUtils.remove_entry(File.dirname(dir)) }

  def limiter(limit: nil)
    described_class.new(dir: dir, limit: limit, logger: logger)
  end

  # Holds one slot for the duration of the block, as another monitor's scan
  # would, without depending on threads: flock is taken per open fd, so a
  # second file handle on the same slot file does not take it over.
  def holding_slot
    described_class.new(dir: dir, limit: 4, logger: logger).send(:take_slot).tap do |slot|
      yield slot
    ensure
      slot&.close
    end
  end

  it "defaults to one concurrent scan" do
    expect(limiter.limit).to eq(1)
  end

  it "runs the block and returns its value when a slot is taken" do
    expect(limiter.with_scan_slot { :scanned }).to eq(:scanned)
    expect(Dir.children(dir).size).to eq(1)
  end

  it "releases its slot once the block completes, so the next scan can take it" do
    limiter(limit: 1).with_scan_slot { :first }

    expect(limiter(limit: 1).with_scan_slot { :second }).to eq(:second)
  end

  it "returns nil when every slot is held" do
    holding_slot do |slot|
      expect(slot).not_to be_nil

      expect(limiter(limit: 1).with_scan_slot { :scanned }).to be_nil
    end
  end

  it "releases its slot when the block raises, so the raise can't leak it" do
    begin
      limiter(limit: 1).with_scan_slot { raise "scan blew up" }
    rescue RuntimeError
      nil
    end

    expect(limiter(limit: 1).with_scan_slot { :next_scan }).to eq(:next_scan)
  end

  it "fails open, running the scan without a slot, when a slot file can't be created" do
    # A regular file where the slot directory belongs, so mkdir_p fails.
    FileUtils.touch(dir)

    expect(limiter.with_scan_slot { :scanned }).to eq(:scanned)
    expect(log.string).to include("scanning without one")
  end

  describe "WORKSPACE_SCAN_CONCURRENCY" do
    around do |example|
      old = ENV["WORKSPACE_SCAN_CONCURRENCY"]
      begin
        example.run
      ensure
        ENV["WORKSPACE_SCAN_CONCURRENCY"] = old
      end
    end

    it "overrides the default limit" do
      ENV["WORKSPACE_SCAN_CONCURRENCY"] = "8"

      expect(limiter.limit).to eq(8)
    end

    it "falls back to the default when the value is not a positive integer" do
      ["", "many", "0", "-2", "2.5"].each do |value|
        ENV["WORKSPACE_SCAN_CONCURRENCY"] = value

        expect(limiter.limit).to eq(1), "expected the default for #{value.inspect}"
      end
    end

    it "caps an environment value above the maximum" do
      ENV["WORKSPACE_SCAN_CONCURRENCY"] = "65"

      expect(limiter.limit).to eq(described_class::MAX_LIMIT)
    end

    it "is ignored when a limit is given" do
      ENV["WORKSPACE_SCAN_CONCURRENCY"] = "8"

      expect(limiter(limit: 2).limit).to eq(2)
    end

    it "falls back to the default when an explicit limit is not a positive integer" do
      expect(limiter(limit: 0).limit).to eq(1)
      expect(limiter(limit: -1).limit).to eq(1)
      expect(limiter(limit: "many").limit).to eq(1)
    end
  end

  it "skips a scan when all configured slots are held" do
    first = described_class.new(dir: dir, limit: 2, logger: logger).send(:take_slot)
    second = described_class.new(dir: dir, limit: 2, logger: logger).send(:take_slot)

    expect(first).not_to be_nil
    expect(second).not_to be_nil
    expect(limiter(limit: 2).with_scan_slot { :scanned }).to be_nil
  ensure
    first&.close
    second&.close
  end
end
