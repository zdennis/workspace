require "tmpdir"

RSpec.describe Workspace::ContextStore do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "context.json") }
  let(:store) { described_class.new(path: path) }

  after { FileUtils.remove_entry(dir) }

  it "returns nil for a pane with no reading" do
    expect(store.reading_for_pane("%1")).to be_nil
  end

  it "records and reads back a reading by pane id" do
    store.record(pct: 42, pane_id: "%1", session_id: "sess-1", cwd: "/tmp/proj", recorded_at: Time.at(1_700_000_000))

    reading = store.reading_for_pane("%1")
    expect(reading["pct"]).to eq(42)
    expect(reading["session_id"]).to eq("sess-1")
    expect(reading["cwd"]).to eq("/tmp/proj")
    expect(reading["recorded_at"]).to eq(Time.at(1_700_000_000).utc.iso8601)
  end

  it "records by pid when pane_id is nil" do
    store.record(pct: 7, pid: 4321)
    expect(store.reading_for_pane("%1")).to be_nil
    expect(store.reading_for_pid(4321)["pct"]).to eq(7)
    expect(store.reading_for_pid("4321")["pct"]).to eq(7)
  end

  it "records the pid's start time so a reused pid can be told apart" do
    store.record(pct: 7, pid: 4321, started: "Sun Sep 27 10:00:00 2026")
    expect(store.reading_for_pid(4321)["started"]).to eq("Sun Sep 27 10:00:00 2026")
  end

  it "does nothing when both pane_id and pid are nil" do
    store.record(pct: 7)
    expect(File.exist?(path)).to be(false)
  end

  it "overwrites a pane's previous reading" do
    store.record(pct: 10, pane_id: "%1")
    store.record(pct: 90, pane_id: "%1")
    expect(store.reading_for_pane("%1")["pct"]).to eq(90)
  end

  it "keeps separate readings for different panes" do
    store.record(pct: 10, pane_id: "%1")
    store.record(pct: 20, pane_id: "%2")
    expect(store.reading_for_pane("%1")["pct"]).to eq(10)
    expect(store.reading_for_pane("%2")["pct"]).to eq(20)
  end

  it "survives a corrupt JSON file by treating it as empty" do
    FileUtils.mkdir_p(dir)
    File.write(path, "{not json")
    expect(store.reading_for_pane("%1")).to be_nil
    store.record(pct: 5, pane_id: "%1")
    expect(store.reading_for_pane("%1")["pct"]).to eq(5)
  end

  it "never raises when the store directory can't be written" do
    bad_store = described_class.new(path: "/nonexistent-root-xyz/sub/context.json")
    expect { bad_store.record(pct: 1, pane_id: "%1") }.not_to raise_error
  end

  it "serializes concurrent writers without losing either write" do
    threads = 5.times.map do |i|
      Thread.new { store.record(pct: i, pane_id: "%#{i}") }
    end
    threads.each(&:join)

    5.times { |i| expect(store.reading_for_pane("%#{i}")["pct"]).to eq(i) }
  end
end
