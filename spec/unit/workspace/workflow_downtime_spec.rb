require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowDowntime do
  let(:dir) { Dir.mktmpdir }
  let(:now) { [Time.utc(2026, 11, 1, 12, 0, 0)] }
  let(:downtime) do
    described_class.new(heartbeat_path: File.join(dir, "heartbeat"), downtime_path: File.join(dir, "downtime.jsonl"),
      downtime_after: -> { 120 }, clock: -> { now.first })
  end

  after { FileUtils.rm_rf(dir) }

  def at(time, grace: 0)
    now[0] = time
    downtime.beat(grace: grace)
  end

  it "records one span for two beats 9h apart" do
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    at(Time.utc(2026, 11, 1, 9, 0, 0))
    expect(downtime.spans).to eq([{"since" => "2026-11-01T00:00:00.000Z", "until" => "2026-11-01T09:00:00.000Z"}])
  end

  it "records none for beats 15s apart" do
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    at(Time.utc(2026, 11, 1, 0, 0, 15))
    expect(downtime.spans).to eq([])
  end

  it "records none for a gap at the threshold" do
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    at(Time.utc(2026, 11, 1, 0, 2, 0))
    expect(downtime.spans).to eq([])
  end

  it "records none when the clock goes backwards" do
    at(Time.utc(2026, 11, 1, 9, 0, 0))
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    expect(downtime.spans).to eq([])
  end

  it "shows an open gap when the heartbeat is 9h old, without recording it" do
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    now[0] = Time.utc(2026, 11, 1, 9, 0, 0)
    expect(downtime.spans).to eq([{"since" => "2026-11-01T00:00:00.000Z"}])
    expect(File.exist?(File.join(dir, "downtime.jsonl"))).to be(false)
  end

  it "is wall with no spans when no heartbeat exists" do
    expect(downtime.clock_kind).to eq("wall")
    expect(downtime.spans).to eq([])
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    expect(downtime.clock_kind).to eq("active")
  end

  it "prunes a span whose end is 31 days old and keeps a newer one" do
    File.write(File.join(dir, "downtime.jsonl"), [
      {"from" => "2026-09-20T00:00:00Z", "to" => "2026-09-30T00:00:00Z"},
      {"from" => "2026-10-20T00:00:00Z", "to" => "2026-10-21T00:00:00Z"}
    ].map { |h| JSON.generate(h) }.join("\n") + "\n")
    at(Time.utc(2026, 11, 1, 0, 0, 0))
    at(Time.utc(2026, 11, 1, 9, 0, 0))
    expect(downtime.spans.map { |s| s["until"] }).to eq(["2026-10-21T00:00:00.000Z", "2026-11-01T09:00:00.000Z"])
  end

  it "still writes the heartbeat when the threshold cannot be read" do
    failing = described_class.new(heartbeat_path: File.join(dir, "heartbeat"), downtime_path: File.join(dir, "downtime.jsonl"),
      downtime_after: -> { raise "bad config" }, clock: -> { now.first })
    now[0] = Time.utc(2026, 11, 1, 0, 0, 0)
    failing.beat
    now[0] = Time.utc(2026, 11, 1, 9, 0, 0)
    failing.beat
    expect(File.read(File.join(dir, "heartbeat"))).to eq("2026-11-01T09:00:00.000Z 0")
    expect(failing.spans.size).to eq(1)
  end

  it "skips bad lines and never raises from a beat" do
    File.write(File.join(dir, "downtime.jsonl"), "junk\n{\"from\":\"x\"}\n")
    expect(downtime.spans).to eq([])
    File.write(File.join(dir, "heartbeat"), "garbage")
    expect { at(Time.utc(2026, 11, 1, 0, 0, 0)) }.not_to raise_error
    expect(downtime.spans).to eq([])
  end

  describe "sweep grace" do
    it "records none for two sweep beats 300s apart" do
      at(Time.utc(2026, 11, 1, 0, 0, 0), grace: 300)
      at(Time.utc(2026, 11, 1, 0, 5, 0), grace: 300)
      expect(downtime.spans).to eq([])
    end

    it "shows no open gap 200s after a sweep beat" do
      at(Time.utc(2026, 11, 1, 0, 0, 0), grace: 300)
      expect(downtime.spans(Time.utc(2026, 11, 1, 0, 3, 20))).to eq([])
    end

    it "shows an open gap once threshold plus grace has passed" do
      at(Time.utc(2026, 11, 1, 0, 0, 0), grace: 300)
      expect(downtime.spans(Time.utc(2026, 11, 1, 0, 7, 1))).to eq([{"since" => "2026-11-01T00:00:00.000Z"}])
    end

    it "records one span for a sweep beat followed 9h later by any beat" do
      at(Time.utc(2026, 11, 1, 0, 0, 0), grace: 300)
      at(Time.utc(2026, 11, 1, 9, 0, 0))
      expect(downtime.spans).to eq([{"since" => "2026-11-01T00:00:00.000Z", "until" => "2026-11-01T09:00:00.000Z"}])
    end

    it "reads a legacy heartbeat file holding only a time as grace 0" do
      File.write(File.join(dir, "heartbeat"), "2026-11-01T00:00:00.000Z")
      at(Time.utc(2026, 11, 1, 0, 5, 0))
      expect(downtime.spans).to eq([{"since" => "2026-11-01T00:00:00.000Z", "until" => "2026-11-01T00:05:00.000Z"}])
    end

    it "reads the clock inside the lock" do
      held = false
      lock = instance_double(Workspace::FileLock)
      allow(Workspace::FileLock).to receive(:new).and_return(lock)
      allow(lock).to receive(:hold) do |&block|
        held = true
        block.call
      end
      reads = []
      timed = described_class.new(heartbeat_path: File.join(dir, "heartbeat"), downtime_path: File.join(dir, "downtime.jsonl"),
        downtime_after: -> { 120 }, clock: -> { reads << held && now.first })
      timed.beat
      expect(reads).to eq([true])
    end
  end
end
