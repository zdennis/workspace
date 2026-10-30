require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::InboxStore do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-store") }
  let(:path) { File.join(tmpdir, ".inbox", "workspace", "api.json") }
  let(:now) { Time.utc(2026, 10, 16, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:err) { StringIO.new }
  let(:store) { described_class.new(path: path, scope: "workspace:api", clock: -> { clock.call }, error_output: err) }
  let(:fields) { {"type" => "todo", "scope" => {"kind" => "workspace", "key" => "api", "name" => "api"}, "title" => "Check the deploy"} }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  describe "#upsert" do
    let(:keyed) { fields.merge("dedupe_key" => "github_check:x:rspec:abc", "body" => nil, "source" => {"kind" => "cli"}, "links" => {"pr" => nil}, "expires_at" => nil) }

    it "creates the item when no item holds the key" do
      result = store.upsert(keyed)

      expect(result.outcome).to eq("created")
      expect(result.record).to include("dedupe_key" => "github_check:x:rspec:abc", "state" => "open")
      expect(store.list).to eq([result.record])
    end

    it "updates the fields of an open item and keeps its id, state and creation time" do
      first = store.upsert(keyed).record
      later = Time.utc(2026, 10, 16, 13, 0, 0)
      clock = -> { later }
      store2 = described_class.new(path: path, scope: "workspace:api", clock: clock, error_output: err)

      result = store2.upsert(keyed.merge("title" => "Newer", "body" => "more", "expires_at" => "2026-10-17T00:00:00Z"))

      expect(result.outcome).to eq("updated")
      expect(result.record).to include("id" => first["id"], "state" => "open", "title" => "Newer", "body" => "more",
        "expires_at" => "2026-10-17T00:00:00Z", "created_at" => "2026-10-16T12:00:00Z", "updated_at" => "2026-10-16T13:00:00Z")
      expect(store2.list.size).to eq(1)
    end

    it "keeps a snoozed item snoozed" do
      id = store.upsert(keyed).record["id"]
      store.transition(id, to: "snoozed", snooze_until: "2026-10-17T00:00:00Z")

      result = store.upsert(keyed.merge("title" => "Newer"))

      expect(result.outcome).to eq("updated")
      expect(result.record).to include("state" => "snoozed", "snooze_until" => "2026-10-17T00:00:00Z", "title" => "Newer")
    end

    it "keeps the stored type when a repeat passes a different one" do
      first = store.upsert(keyed.merge("type" => "review_request")).record

      result = store.upsert(keyed.merge("type" => "note"))

      expect(result.outcome).to eq("updated")
      expect(result.record).to include("id" => first["id"], "type" => "review_request")
    end

    it "refreshes source.ref on a repeat" do
      store.upsert(keyed.merge("source" => {"kind" => "agent", "ref" => "aaaa1111"}))

      result = store.upsert(keyed.merge("source" => {"kind" => "agent", "ref" => "bbbb2222"}))

      expect(result.record["source"]).to include("kind" => "agent", "ref" => "bbbb2222")
    end

    it "leaves a resolved item alone as suppressed" do
      id = store.upsert(keyed).record["id"]
      store.transition(id, to: "dismissed", by: {"kind" => "user"})

      result = store.upsert(keyed.merge("title" => "Newer"))

      expect(result.outcome).to eq("suppressed")
      expect(result.record).to include("state" => "dismissed", "title" => "Check the deploy")
      expect(store.list.size).to eq(1)
      expect(store.find(id)).to include("state" => "dismissed", "title" => "Check the deploy")
    end

    it "reopens a resolved item with the new fields when asked" do
      id = store.upsert(keyed).record["id"]
      store.transition(id, to: "done", by: {"kind" => "user"})

      result = store.upsert(keyed.merge("title" => "Newer"), reopen: true)

      expect(result.outcome).to eq("reopened")
      expect(result.record).to include("id" => id, "state" => "open", "title" => "Newer", "resolved_at" => nil, "resolved_by" => nil)
    end

    it "treats an expired item as resolved" do
      store.upsert(keyed.merge("expires_at" => "2026-10-16T11:00:00Z"))

      expect(store.upsert(keyed).outcome).to eq("suppressed")
      expect(store.upsert(keyed, reopen: true)).to have_attributes(outcome: "reopened", record: a_hash_including("state" => "open", "expires_at" => nil))
    end

    it "does not match items with other keys, or without one" do
      store.add(fields)
      store.upsert(keyed)

      expect(store.upsert(keyed.merge("dedupe_key" => "other")).outcome).to eq("created")
      expect(store.list.size).to eq(3)
    end

    it "refuses a record without a key" do
      expect { store.upsert(fields) }.to raise_error(ArgumentError)
    end
  end

  describe "#transition_by_key" do
    it "moves the item holding the key, in one lock, or returns nil" do
      id = store.upsert(fields.merge("dedupe_key" => "k")).record["id"]

      moved = store.transition_by_key("k", to: "done", by: {"kind" => "cli"})

      expect(moved).to have_attributes(changed: true, record: a_hash_including("id" => id, "state" => "done"))
      expect(store.transition_by_key("k", to: "done").changed).to be(false)
      expect(store.transition_by_key("nope", to: "done")).to be_nil
    end

    it "raises on an unreadable store instead of reading no match" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "not json")

      expect { store.transition_by_key("k", to: "done") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("inbox_store_unreadable") }
    end
  end

  describe "#add" do
    it "stores an open item with a 10 hex id and the clock's timestamps" do
      item = store.add(fields)

      expect(item).to include("title" => "Check the deploy", "state" => "open", "snooze_until" => nil,
        "created_at" => "2026-10-16T12:00:00Z", "updated_at" => "2026-10-16T12:00:00Z",
        "resolved_at" => nil, "resolved_by" => nil)
      expect(item["id"]).to match(/\A\h{10}\z/)
      expect(store.list).to eq([item])
    end

    it "never reuses an id already in the file" do
      allow(SecureRandom).to receive(:hex).with(5).and_return("aaaaaaaaaa", "aaaaaaaaaa", "bbbbbbbbbb")

      ids = 2.times.map { store.add(fields)["id"] }

      expect(ids).to eq(%w[aaaaaaaaaa bbbbbbbbbb])
    end

    it "writes the file 0600 and its directories 0700" do
      store.add(fields)

      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
      expect(File.stat(File.join(tmpdir, ".inbox")).mode & 0o777).to eq(0o700)
    end
  end

  describe "#list" do
    it "reads an absent store as empty without creating anything" do
      expect(store.list).to eq([])
      expect(File.exist?(File.join(tmpdir, ".inbox"))).to be(false)
    end

    it "reads a corrupt file as empty with one warning" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{nope")

      2.times { expect(store.list).to eq([]) }

      expect(err.string.lines.size).to eq(1)
      expect(err.string).to include(path, "not valid JSON")
    end

    it "reads a snooze whose time has passed as open, without writing" do
      item = store.add(fields)
      store.update(item["id"]) { |r| r.merge!("state" => "snoozed", "snooze_until" => "2026-10-16T13:00:00Z") }
      before = File.read(path)

      expect(store.list.first["state"]).to eq("snoozed")
      now_later = Time.utc(2026, 10, 16, 13, 0, 0)
      later = described_class.new(path: path, clock: -> { now_later })
      expect(later.list.first).to include("state" => "open", "snooze_until" => nil)
      expect(File.read(path)).to eq(before)
    end

    it "reads an item whose expiry has passed as dismissed by expiry, without writing" do
      item = store.add(fields.merge("expires_at" => "2026-10-16T12:30:00Z"))
      before = File.read(path)
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 12, 30, 0) })

      expect(later.find(item["id"])).to include("state" => "dismissed", "resolved_at" => "2026-10-16T12:30:00Z",
        "resolved_by" => {"kind" => "expiry"})
      expect(File.read(path)).to eq(before)
    end

    it "does not expire a resolved item or change one without an expiry" do
      item = store.add(fields.merge("expires_at" => "2026-10-16T12:30:00Z"))
      store.transition(item["id"], to: "done", by: {"kind" => "user"})
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 17) })

      expect(later.find(item["id"])).to include("state" => "done", "resolved_by" => {"kind" => "user"})
    end
  end

  describe "#find" do
    it "returns the item or nil" do
      item = store.add(fields)

      expect(store.find(item["id"])).to eq(item)
      expect(store.find("0000000000")).to be_nil
    end
  end

  describe "#update" do
    it "yields the stored record under the lock, stamps updated_at and keeps the rest" do
      item = store.add(fields)
      other = store.add(fields.merge("title" => "Other"))
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 0) })

      result = later.update(item["id"]) { |r| r["title"] = "New" }

      expect(result).to include("title" => "New", "updated_at" => "2026-10-16T13:00:00Z", "created_at" => "2026-10-16T12:00:00Z")
      expect(later.find(other["id"])).to eq(other)
    end

    it "leaves updated_at alone when the block changes nothing" do
      item = store.add(fields)
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 0) })

      result = later.update(item["id"]) { |r| r["title"] = r["title"].dup }

      expect(result["updated_at"]).to eq("2026-10-16T12:00:00Z")
    end

    it "yields a record whose passed snooze has already woken" do
      item = store.add(fields)
      store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-16T12:30:00Z")
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 0) })

      later.update(item["id"]) { |r| expect(r).to include("state" => "open", "snooze_until" => nil) }
      expect(later.find(item["id"])["state"]).to eq("open")
    end

    it "returns nil without yielding when no record has the id" do
      store.add(fields)

      expect { |b| expect(store.update("0000000000", &b)).to be_nil }.not_to yield_control
    end
  end

  describe "#transition" do
    let!(:item) { store.add(fields) }

    it "resolves an open item, recording when and by whom" do
      result = store.transition(item["id"], to: "done", by: {"kind" => "agent", "pane" => "%3"})

      expect(result.changed).to be(true)
      expect(result.record).to include("state" => "done", "resolved_at" => "2026-10-16T12:00:00Z",
        "resolved_by" => {"kind" => "agent", "pane" => "%3"})
      expect(store.find(item["id"])).to eq(result.record)
    end

    it "leaves an item already in the state untouched" do
      store.transition(item["id"], to: "dismissed", by: {"kind" => "user"})
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 14, 0, 0) })

      result = later.transition(item["id"], to: "dismissed", by: {"kind" => "cli"})

      expect(result.changed).to be(false)
      expect(result.record).to include("resolved_at" => "2026-10-16T12:00:00Z", "resolved_by" => {"kind" => "user"})
    end

    it "reopens a resolved item, clearing the resolution" do
      store.transition(item["id"], to: "done", by: {"kind" => "user"})

      result = store.transition(item["id"], to: "open")

      expect(result.record).to include("state" => "open", "resolved_at" => nil, "resolved_by" => nil)
    end

    it "snoozes an item until the given time, and refuses to snooze without one" do
      result = store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-17T00:00:00Z")

      expect(result.record).to include("state" => "snoozed", "snooze_until" => "2026-10-17T00:00:00Z")
      expect { store.transition(item["id"], to: "snoozed") }.to raise_error(ArgumentError)
    end

    it "moves the wake time of an item already snoozed, and leaves one snoozed to the same time" do
      store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-17T00:00:00Z")

      same = store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-17T00:00:00Z")
      moved = store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-18T00:00:00Z")

      expect(same.changed).to be(false)
      expect(moved).to have_attributes(changed: true, record: include("snooze_until" => "2026-10-18T00:00:00Z"))
    end

    it "drops a passed expiry when reopening, so the item stays open" do
      expiring = store.add(fields.merge("expires_at" => "2026-10-16T12:30:00Z"))
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 0) })

      result = later.transition(expiring["id"], to: "open")

      expect(result.record).to include("state" => "open", "expires_at" => nil, "resolved_by" => nil)
      expect(later.find(expiring["id"])["state"]).to eq("open")
    end

    it "keeps an expiry still ahead when reopening" do
      expiring = store.add(fields.merge("expires_at" => "2026-10-20T00:00:00Z"))
      store.transition(expiring["id"], to: "done")

      expect(store.transition(expiring["id"], to: "open").record["expires_at"]).to eq("2026-10-20T00:00:00Z")
    end

    it "reopens a snoozed item and clears its snooze" do
      store.update(item["id"]) { |r| r.merge!("state" => "snoozed", "snooze_until" => "2026-10-17T00:00:00Z") }

      result = store.transition(item["id"], to: "open")

      expect(result).to have_attributes(changed: true, record: include("state" => "open", "snooze_until" => nil))
    end

    it "treats an item whose expiry has passed as already dismissed" do
      expiring = store.add(fields.merge("expires_at" => "2026-10-16T12:10:00Z"))
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 13, 0, 0) })

      result = later.transition(expiring["id"], to: "dismissed", by: {"kind" => "user"})

      expect(result.changed).to be(false)
      expect(result.record).to include("state" => "dismissed", "resolved_by" => {"kind" => "expiry"})
    end

    it "returns nil for an unknown id and rejects an unknown state" do
      expect(store.transition("0000000000", to: "done")).to be_nil
      expect { store.transition(item["id"], to: "gone") }.to raise_error(ArgumentError)
    end
  end

  describe "storing a passed snooze or expiry on write" do
    let(:later) { Time.utc(2026, 10, 16, 15, 0, 0) }
    let(:store_later) { described_class.new(path: path, scope: "workspace:api", clock: -> { later }, error_output: err) }

    def raw
      JSON.parse(File.read(path))
    end

    it "does not write on a read" do
      store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))

      expect(store_later.list.first["state"]).to eq("dismissed")
      expect(raw.first).to include("state" => "open", "resolved_by" => nil)
    end

    it "stores an expiry as dismissed by expiry on the next write, at the expiry time" do
      expiring = store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))

      store_later.add(fields.merge("title" => "another"))

      expect(raw.find { |r| r["id"] == expiring["id"] }).to include("state" => "dismissed",
        "resolved_at" => "2026-10-16T13:00:00Z", "resolved_by" => {"kind" => "expiry"}, "snooze_until" => nil)
    end

    it "stores a passed snooze as open on the next write" do
      snoozed = store.add(fields)
      store.transition(snoozed["id"], to: "snoozed", snooze_until: "2026-10-16T13:00:00Z")

      store_later.add(fields)

      expect(raw.find { |r| r["id"] == snoozed["id"] }).to include("state" => "open", "snooze_until" => nil)
    end

    it "keeps a snooze that has not passed" do
      snoozed = store.add(fields)
      store.transition(snoozed["id"], to: "snoozed", snooze_until: "2026-10-16T18:00:00Z")

      store_later.add(fields)

      expect(raw.find { |r| r["id"] == snoozed["id"] }).to include("state" => "snoozed", "snooze_until" => "2026-10-16T18:00:00Z")
    end

    it "reports each item that expired in the write, once, after the write" do
      a = store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))
      b = store.add(fields.merge("expires_at" => "2026-10-16T14:00:00Z"))
      store.add(fields.merge("expires_at" => "2026-10-16T20:00:00Z"))
      store.transition(store.add(fields.merge("expires_at" => "2026-10-16T13:30:00Z"))["id"], to: "done")
      seen = []
      store_later.on_expired = ->(record) { seen << [record["id"], record["state"], raw.size] }

      store_later.add(fields)
      store_later.add(fields)

      expect(seen).to contain_exactly([a["id"], "dismissed", 5], [b["id"], "dismissed", 5])
    end

    it "reports an item that expired under a transition on another item" do
      expiring = store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))
      other = store.add(fields)
      seen = []
      store_later.on_expired = ->(record) { seen << record["id"] }

      store_later.transition(other["id"], to: "done")

      expect(seen).to eq([expiring["id"]])
    end

    it "reports nothing for a read" do
      store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))
      seen = []
      store_later.on_expired = ->(record) { seen << record }

      store_later.list

      expect(seen).to be_empty
    end

    it "refuses to snooze a done, dismissed or expired item, leaving it as it was" do
      done = store.add(fields)
      store.transition(done["id"], to: "done")
      expiring = store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))

      expect { store.transition(done["id"], to: "snoozed", snooze_until: "2026-10-16T18:00:00Z") }
        .to raise_error(Workspace::Error) { |e| expect([e.code, e.details["field"]]).to eq(["invalid_inbox_item", "state"]) }
      expect { store_later.transition(expiring["id"], to: "snoozed", snooze_until: "2026-10-16T18:00:00Z") }
        .to raise_error(Workspace::Error, /dismissed/)
      expect(raw.find { |r| r["id"] == done["id"] }["state"]).to eq("done")
    end

    it "warns and keeps going when the expiry callback raises" do
      store.add(fields.merge("expires_at" => "2026-10-16T13:00:00Z"))
      store_later.on_expired = ->(_record) { raise "log is gone" }

      added = store_later.add(fields)

      expect(raw.map { |r| r["id"] }).to include(added["id"])
      expect(err.string).to match(/could not report the expiry of inbox item \w+ \(RuntimeError\)/)
    end

    it "snoozes an open item and a reopen clears the snooze" do
      item = store.add(fields)

      snoozed = store.transition(item["id"], to: "snoozed", snooze_until: "2026-10-16T18:00:00Z")
      reopened = store.transition(item["id"], to: "open")

      expect(snoozed.record).to include("state" => "snoozed", "snooze_until" => "2026-10-16T18:00:00Z")
      expect(reopened.record).to include("state" => "open", "snooze_until" => nil)
    end
  end

  describe "an unreadable file" do
    before do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "[{\"id\":")
    end

    it "refuses a write with inbox_store_unreadable and leaves the file as it was" do
      expect { store.add(fields) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("inbox_store_unreadable")
        expect(e.details).to eq("scope" => "workspace:api")
      }
      expect(File.read(path)).to eq("[{\"id\":")
    end

    it "refuses a file that is JSON but not a list" do
      File.write(path, "{}")

      expect { store.add(fields) }.to raise_error(Workspace::Error, /not a JSON list/)
    end
  end

  it "keeps entries that are not objects on disk" do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "[7]")

    store.add(fields)

    expect(JSON.parse(File.read(path)).first).to eq(7)
    expect(store.list.size).to eq(1)
  end

  describe "retention" do
    def resolved_item(id, resolved_at, state: "done")
      fields.merge("id" => id, "state" => state, "resolved_at" => resolved_at, "snooze_until" => nil, "expires_at" => nil)
    end

    def seed(items)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(items))
    end

    before { stub_const("Workspace::InboxStore::LIVE_LIMIT", 3) }

    it "refuses the item past the live limit as inbox_full and writes nothing" do
      3.times { store.add(fields) }
      before = File.read(path)

      expect { store.add(fields) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("inbox_full")
        expect(e.details).to eq("scope" => "workspace:api", "limit" => 3)
      }
      expect(File.read(path)).to eq(before)
    end

    it "counts snoozed items as live and not done ones" do
      a = store.add(fields)
      store.add(fields)
      store.add(fields)
      store.transition(a["id"], to: "done")

      expect { store.add(fields) }.not_to raise_error
      expect { store.add(fields) }.to raise_error(Workspace::Error, /full/)
    end

    it "refuses a created upsert when full but still updates the existing key" do
      store.upsert(fields.merge("dedupe_key" => "k"))
      2.times { store.add(fields) }

      expect(store.upsert(fields.merge("dedupe_key" => "k", "title" => "New")).outcome).to eq("updated")
      expect { store.upsert(fields.merge("dedupe_key" => "other")) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("inbox_full") }
    end

    it "refuses reopening a resolved item when full, through transition and upsert" do
      done = store.add(fields.merge("dedupe_key" => "k"))
      store.transition(done["id"], to: "done")
      3.times { store.add(fields) }

      expect { store.transition(done["id"], to: "open") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("inbox_full") }
      expect { store.upsert(fields.merge("dedupe_key" => "k"), reopen: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("inbox_full") }
      expect(store.find(done["id"])["state"]).to eq("done")
    end

    it "keeps the newest 200 resolved items by resolved_at on the next write" do
      items = (0...205).map { |i| resolved_item("r#{i}", (Time.utc(2026, 10, 1) + i * 60).iso8601, state: (i.even? ? "done" : "dismissed")) }
      seed(items.reverse)

      store.add(fields)

      kept = JSON.parse(File.read(path)).map { |r| r["id"] }
      expect(kept.grep(/\Ar/).size).to eq(200)
      expect(kept).not_to include("r0", "r1", "r2", "r3", "r4")
      expect(kept).to include("r5", "r204")
      expect(kept.size).to eq(201)
    end

    it "drops a resolved item with no resolved_at first and keeps live ones whatever their age" do
      items = (1..200).map { |i| resolved_item("r#{i}", (Time.utc(2026, 10, 1) + i * 60).iso8601) }
      items << resolved_item("none", nil)
      items << fields.merge("id" => "live", "state" => "open", "created_at" => "2020-01-01T00:00:00Z", "snooze_until" => nil, "expires_at" => nil, "resolved_at" => nil)
      seed(items)

      store.update("live") { |r| r["title"] = "x" }

      kept = JSON.parse(File.read(path)).map { |r| r["id"] }
      expect(kept).not_to include("none")
      expect(kept).to include("live", "r1")
    end

    it "counts an item that just expired as resolved" do
      items = (1..200).map { |i| resolved_item("r#{i}", (Time.utc(2026, 10, 2) + i * 60).iso8601) }
      items << fields.merge("id" => "exp", "state" => "open", "expires_at" => "2026-10-16T11:00:00Z", "snooze_until" => nil, "resolved_at" => nil)
      seed(items)

      store.add(fields)

      kept = JSON.parse(File.read(path)).map { |r| r["id"] }
      expect(kept).to include("exp")
      expect(kept).not_to include("r1")
    end

    it "does not trim on a read" do
      seed((0...205).map { |i| resolved_item("r#{i}", (Time.utc(2026, 10, 1) + i * 60).iso8601) })

      store.list

      expect(JSON.parse(File.read(path)).size).to eq(205)
    end
  end
end
