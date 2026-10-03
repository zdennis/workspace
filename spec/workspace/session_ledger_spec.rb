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

RSpec.describe Workspace::SessionLedger, "#entries_for" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, "ledger.jsonl") }
  let(:ledger) { described_class.new(path: path, logger: Workspace::Logger.new) }

  after { FileUtils.remove_entry(tmpdir) }

  it "returns one workspace's entries, oldest first" do
    ledger.record("event" => "session_start", "workspace" => "a", "session_id" => "1")
    ledger.record("event" => "session_start", "workspace" => "b", "session_id" => "2")
    ledger.record("event" => "session_end", "workspace" => "a", "session_id" => "1")

    expect(ledger.entries_for("a").map { |e| [e["event"], e["session_id"]] }).to eq([%w[session_start 1], %w[session_end 1]])
  end

  it "skips a torn line and lines that aren't objects" do
    ledger.record("event" => "session_start", "workspace" => "a")
    File.open(path, "a") { |f| f.write("{\"workspace\":\"a\", torn\n[1,2]\n\"a\"\n") }
    ledger.record("event" => "session_end", "workspace" => "a")

    expect(ledger.entries_for("a").map { |e| e["event"] }).to eq(%w[session_start session_end])
  end

  it "raises rather than read as empty when the ledger exists but can't be read" do
    ledger.record("event" => "session_start", "workspace" => "a")
    File.chmod(0o000, path)

    expect { ledger.entries_for("a") }.to raise_error(Errno::EACCES)
  ensure
    File.chmod(0o600, path)
  end

  it "is empty when there is no ledger" do
    expect(ledger.entries_for("a")).to eq([])
  end
end
