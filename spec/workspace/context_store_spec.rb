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
    expect(reading["recorded_at"]).to eq("2023-11-14T22:13:20.000000Z")
  end

  it "records cost, duration, and model alongside the percentage" do
    store.record(pct: 5, pane_id: "%1", cost_usd: 0.5, duration_ms: 1200, model: "Sonnet 5.5")

    reading = store.reading_for_pane("%1")
    expect(reading).to include("cost_usd" => 0.5, "duration_ms" => 1200, "model" => "Sonnet 5.5")
  end

  it "records cost, duration, and model by pid too" do
    store.record(pct: 5, pid: 9, cost_usd: 2, duration_ms: 3, model: "m")

    expect(store.reading_for_pid(9)).to include("cost_usd" => 2, "duration_ms" => 3, "model" => "m")
  end

  it "keeps a zero cost and duration" do
    store.record(pct: 5, pane_id: "%1", cost_usd: 0, duration_ms: 0)

    expect(store.reading_for_pane("%1")).to include("cost_usd" => 0, "duration_ms" => 0)
  end

  it "drops a cost or duration that is negative or not a number, and a model that is not a string" do
    store.record(pct: 5, pane_id: "%1", cost_usd: -1, duration_ms: "soon", model: 3)

    expect(store.reading_for_pane("%1")).to include("cost_usd" => nil, "duration_ms" => nil, "model" => nil)
  end

  it "still records the percentage when cost, duration, and model are omitted" do
    store.record(pct: 5, pane_id: "%1")

    expect(store.reading_for_pane("%1")).to include("pct" => 5, "cost_usd" => nil, "duration_ms" => nil, "model" => nil)
  end

  it "records the time to the microsecond" do
    store.record(pct: 1, pane_id: "%1", recorded_at: Time.at(1_700_000_000, 250_000, :usec))

    expect(store.reading_for_pane("%1")["recorded_at"]).to eq("2023-11-14T22:13:20.250000Z")
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

  it "records a nil pct as a reading (Claude's JSON null right after start/clear)" do
    store.record(pct: nil, pane_id: "%1", session_id: "sess-2")
    reading = store.reading_for_pane("%1")
    expect(reading["pct"]).to be_nil
    expect(reading["session_id"]).to eq("sess-2")
  end

  it "a nil pct overwrites a prior numeric reading for the same pane" do
    store.record(pct: 90, pane_id: "%1", session_id: "sess-1")
    store.record(pct: nil, pane_id: "%1", session_id: "sess-2")
    reading = store.reading_for_pane("%1")
    expect(reading["pct"]).to be_nil
    expect(reading["session_id"]).to eq("sess-2")
  end

  it "still drops an invalid non-nil pct (string, negative, over 100)" do
    store.record(pct: 90, pane_id: "%1")
    store.record(pct: "N/A", pane_id: "%1")
    store.record(pct: -1, pane_id: "%1")
    store.record(pct: 101, pane_id: "%1")
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
