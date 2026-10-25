require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::DeliveryLog do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, "state", "session-event.log") }
  let(:now) { Time.utc(2026, 10, 25, 12, 0, 0) }
  let(:clock) { -> { now } }

  subject(:log) { described_class.new(path: path, clock: -> { clock.call }) }

  after { FileUtils.remove_entry(tmpdir) }

  it "writes one timestamped line per record, with newlines in the message replaced" do
    log.record("a\nb\r\nc")

    expect(File.read(path)).to eq("2026-10-25T12:00:00Z a b c\n")
  end

  it "holds back a repeat of a key until the throttle has passed" do
    expect(log.record("first", key: "k")).to be(true)
    expect(log.record("again", key: "k")).to be(false)
    expect(log.record("other", key: "j")).to be(true)

    later = now + described_class::THROTTLE + 1
    allow(clock).to receive(:call).and_return(later)
    expect(log.record("later", key: "k")).to be(true)
    expect(File.readlines(path).size).to eq(3)
  end

  it "removes throttle markers older than the throttle window" do
    log.record("old", key: "old")
    allow(clock).to receive(:call).and_return(now + described_class::THROTTLE + 1)

    log.record("new", key: "new")

    expect(Dir.glob("#{path}.*.throttle").size).to eq(1)
  end

  it "moves a log past its limit to .1 instead of truncating it" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "x" * (described_class::LIMIT + 1))

    log.record("fresh")

    expect(File.size("#{path}.1")).to eq(described_class::LIMIT + 1)
    expect(File.read(path)).to end_with("fresh\n")
    expect(File.size(path)).to be < 100
  end

  it "answers false rather than raising when the log cannot be written" do
    FileUtils.mkdir_p(path)

    expect(log.record("x")).to be(false)
  end
end
