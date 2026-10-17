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
end
