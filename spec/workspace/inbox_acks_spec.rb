require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::InboxAcks do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-acks") }
  let(:path) { File.join(tmpdir, ".inbox", "acks.json") }
  let(:now) { Time.utc(2026, 10, 16, 12, 0, 0) }
  let(:clock) { -> { now } }

  subject(:acks) { described_class.new(path: path, clock: clock) }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def row(id, fingerprint)
    {"id" => id, "fingerprint" => fingerprint, "derived" => true}
  end

  def stored
    JSON.parse(File.read(path))
  end

  describe "#ack" do
    it "stores the id, the fingerprint and when it was acked, and says it changed" do
      expect(acks.ack("pane:waiting:api:%5", "f1")).to be(true)

      expect(stored).to eq([{"id" => "pane:waiting:api:%5", "fingerprint" => "f1", "acked_at" => "2026-10-16T12:00:00Z"}])
    end

    it "is unchanged, and writes nothing, for the same fingerprint again" do
      acks.ack("a:1", "f1")
      before = File.mtime(path)
      File.utime(before - 10, before - 10, path)

      expect(acks.ack("a:1", "f1")).to be(false)
      expect(File.mtime(path)).to eq(before - 10)
    end

    it "replaces the entry for a new fingerprint, so one id holds one entry" do
      acks.ack("a:1", "f1")
      expect(acks.ack("a:1", "f2")).to be(true)

      expect(stored.map { |e| [e["id"], e["fingerprint"]] }).to eq([["a:1", "f2"]])
    end

    it "turns a snooze into an ack" do
      acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z")
      expect(acks.ack("a:1", "f1")).to be(true)

      expect(stored.first).not_to have_key("until")
    end

    it "creates the directory private to the person" do
      acks.ack("a:1", "f1")

      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end
  end

  describe "#snooze" do
    it "stores the same record with an until, and says it changed" do
      expect(acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z")).to be(true)

      expect(stored).to eq([{"id" => "a:1", "fingerprint" => "f1", "acked_at" => "2026-10-16T12:00:00Z", "until" => "2026-10-16T14:00:00Z"}])
    end

    it "is unchanged for the same fingerprint and time, and moves for a new time" do
      acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z")

      expect(acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z")).to be(false)
      expect(acks.snooze("a:1", "f1", "2026-10-16T15:00:00Z")).to be(true)
      expect(stored.map { |e| e["until"] }).to eq(["2026-10-16T15:00:00Z"])
    end
  end

  describe "#filter" do
    it "leaves an acked row out while its fingerprint matches" do
      acks.ack("a:1", "f1")

      result = acks.filter([row("a:1", "f1"), row("a:2", "f1")])

      expect(result[:rows].map { |r| r["id"] }).to eq(["a:2"])
      expect(result[:warnings]).to eq([])
    end

    it "shows the row again when its fingerprint changes" do
      acks.ack("a:1", "f1")

      expect(acks.filter([row("a:1", "f2")])[:rows].size).to eq(1)
    end

    it "hides a snoozed row until its time, then shows it" do
      acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z")

      expect(acks.filter([row("a:1", "f1")])[:rows]).to be_empty
      later = described_class.new(path: path, clock: -> { Time.utc(2026, 10, 16, 14, 0, 0) })
      expect(later.filter([row("a:1", "f1")])[:rows].size).to eq(1)
    end

    it "reads nothing from a missing file and never creates it" do
      expect(acks.filter([row("a:1", "f1")])[:rows].size).to eq(1)
      expect(File.exist?(path)).to be(false)
    end

    it "does not rewrite the file" do
      acks.ack("a:1", "f1")
      before = File.read(path)

      acks.filter([row("a:1", "f1")])

      expect(File.read(path)).to eq(before)
    end

    it "warns and shows every row when the file can't be read" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")

      result = acks.filter([row("a:1", "f1")])

      expect(result[:rows].size).to eq(1)
      expect(result[:warnings].map { |w| w["code"] }).to eq(["inbox_store_unreadable"])
      expect(result[:warnings].first["message"]).to include(path)
    end

    it "ignores entries that are not objects" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(["junk", 3, {"id" => "a:1", "fingerprint" => "f1", "acked_at" => "2026-10-16T11:00:00Z"}]))

      expect(acks.filter([row("a:1", "f1")])[:rows]).to be_empty
    end
  end

  describe "dropping old entries on write" do
    it "drops acks older than 30 days and snoozes past their time, keeps the rest" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate([
        {"id" => "old:1", "fingerprint" => "f", "acked_at" => "2026-09-15T11:59:59Z"},
        {"id" => "new:1", "fingerprint" => "f", "acked_at" => "2026-09-16T12:00:00Z"},
        {"id" => "woke:1", "fingerprint" => "f", "acked_at" => "2026-10-16T09:00:00Z", "until" => "2026-10-16T12:00:00Z"},
        {"id" => "asleep:1", "fingerprint" => "f", "acked_at" => "2026-08-01T09:00:00Z", "until" => "2026-10-16T12:00:01Z"}
      ]))

      acks.ack("fresh:1", "f")

      expect(stored.map { |e| e["id"] }).to eq(%w[new:1 asleep:1 fresh:1])
    end

    it "drops a snooze whose until can't be read, and never hides a row with one" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate([{"id" => "a:1", "fingerprint" => "f1", "acked_at" => "2026-10-16T11:00:00Z", "until" => "soon"}]))

      expect(acks.filter([row("a:1", "f1")])[:rows].size).to eq(1)
      acks.ack("b:1", "f")
      expect(stored.map { |e| e["id"] }).to eq(["b:1"])
    end

    it "keeps acks it can't read the time of, and entries that are not objects" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(["junk", {"id" => "odd:1", "fingerprint" => "f", "acked_at" => "never"}]))

      acks.ack("fresh:1", "f")

      expect(stored.size).to eq(3)
      expect(stored.first).to eq("junk")
    end

    it "does not write when nothing changed, even if there is something to drop" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate([{"id" => "old:1", "fingerprint" => "f", "acked_at" => "2026-01-01T00:00:00Z"},
        {"id" => "a:1", "fingerprint" => "f1", "acked_at" => "2026-10-16T11:00:00Z"}]))

      expect(acks.ack("a:1", "f1")).to be(false)
      expect(stored.size).to eq(2)
    end
  end

  describe "an unreadable file" do
    it "refuses a write as inbox_store_unreadable and leaves the file as it was" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")

      expect { acks.ack("a:1", "f1") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("inbox_store_unreadable")
        expect(e.details).to eq("scope" => "acks")
      }
      expect(File.read(path)).to eq("{not json")
    end

    it "reports a directory it can't create as inbox_store_unreadable too" do
      File.write(File.join(tmpdir, ".inbox"), "in the way")

      expect { acks.ack("a:1", "f1") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("inbox_store_unreadable") }
    end

    it "refuses a write when the file is not a list" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")

      expect { acks.snooze("a:1", "f1", "2026-10-16T14:00:00Z") }.to raise_error(Workspace::Error, /can't be read/)
    end
  end
end
