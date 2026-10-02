require "tmpdir"

RSpec.describe Workspace::SessionLedger do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, "state", "workspace", "ledger.jsonl") }
  let(:now) { Time.utc(2026, 10, 2, 12, 0, 0) }
  let(:ledger) { described_class.new(path: path, clock: -> { now }, logger: Workspace::Logger.new) }

  after { FileUtils.remove_entry(tmpdir) }

  def lines
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  it "appends one JSON line stamped with the clock, creating the directory" do
    expect(ledger.record("event" => "session_start", "pane_slot" => "proj:0.1")).to be(true)

    expect(lines).to eq([{"at" => "2026-10-02T12:00:00.000000Z", "event" => "session_start", "pane_slot" => "proj:0.1"}])
  end

  it "keeps earlier lines and never rewrites them" do
    ledger.record("event" => "session_start")
    ledger.record("event" => "session_end")

    expect(lines.map { |line| line["event"] }).to eq(%w[session_start session_end])
  end

  it "leaves nil fields out" do
    ledger.record("event" => "session_end", "pane_slot" => nil)

    expect(lines.first).not_to have_key("pane_slot")
  end

  it "keeps the file and directory private" do
    ledger.record("event" => "session_start")

    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
  end

  it "does not interleave lines written from several processes" do
    ledger
    pids = 4.times.map do |i|
      fork do
        25.times { ledger.record("event" => "session_start", "session_id" => "#{i}-" + "x" * 5000) }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    expect(lines.size).to eq(100)
  end

  it "returns false instead of raising when the file can't be written" do
    FileUtils.mkdir_p(path)

    expect(ledger.record("event" => "session_start")).to be(false)
  end
end
