require "tmpdir"
require "json"

RSpec.describe Workspace::WorkQueueHistory do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "api", "work-queue-history.jsonl") }
  let(:now) { Time.utc(2026, 11, 20, 12, 0, 0) }
  let(:clock) { double("clock", now: now) }
  let(:history) { described_class.new(path: path, clock: clock) }

  after { FileUtils.remove_entry(dir) }

  def entry(id, outcome: "succeeded", finished_at: now - 60)
    {"id" => id, "kind" => "workflow", "outcome" => outcome, "finished_at" => finished_at.utc.iso8601(3)}
  end

  def lines
    File.read(path).lines.map { |l| JSON.parse(l) }
  end

  it "defaults the retention to 365 days" do
    expect(described_class::RETENTION).to eq(365 * 24 * 3600)
  end

  describe "#append and #entries" do
    it "reads nothing, and makes no file, when there is none" do
      expect(history.entries).to eq([])
      expect(File.exist?(path)).to be(false)
    end

    it "keeps appended entries oldest first, one line each" do
      history.append(entry("aaaa1111"))
      history.append_locked(entry("bbbb2222"))
      expect(history.entries.map { |e| e["id"] }).to eq(%w[aaaa1111 bbbb2222])
      expect(File.read(path).lines.size).to eq(2)
    end

    it "stamps finished_at from the clock when the entry has none" do
      written = history.append("id" => "aaaa1111", "outcome" => "failed")
      expect(written["finished_at"]).to eq("2026-11-20T12:00:00.000Z")
    end

    it "writes the file with mode 0600" do
      history.append(entry("aaaa1111"))
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      history.prune
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "filters by since, before and state" do
      history.append(entry("old", finished_at: now - 5 * 86_400))
      history.append(entry("mid", outcome: "failed", finished_at: now - 2 * 86_400))
      history.append(entry("new", finished_at: now - 60))

      expect(history.entries(since: now - 3 * 86_400).map { |e| e["id"] }).to eq(%w[mid new])
      expect(history.entries(before: now - 3 * 86_400).map { |e| e["id"] }).to eq(%w[old])
      expect(history.entries(state: "failed").map { |e| e["id"] }).to eq(%w[mid])
      expect(history.entries(since: now - 3 * 86_400, state: "succeeded").map { |e| e["id"] }).to eq(%w[new])
    end
  end

  describe "#find" do
    before do
      history.append(entry("abcd1111"))
      history.append(entry("abef2222"))
      history.append(entry("ab"))
    end

    it "finds one entry by a unique prefix" do
      expect(history.find("abc")["id"]).to eq("abcd1111")
    end

    it "prefers an exact id over longer ids it starts" do
      expect(history.find("ab")["id"]).to eq("ab")
    end

    it "raises ambiguous_queue_item for a prefix of several" do
      expect { history.find("abe") && history.find("a") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("ambiguous_queue_item")
        expect(e.details[:matches]).to match_array(%w[abcd1111 abef2222 ab])
      }
    end

    it "raises unknown_queue_item for none, and for an empty prefix" do
      expect { history.find("zz") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_queue_item") }
      expect { history.find("") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_queue_item") }
    end
  end

  describe "pruning" do
    let(:old) { entry("old", finished_at: now - 366 * 86_400) }

    before do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, [old, entry("fresh")].map { |e| "#{JSON.generate(e)}\n" }.join)
    end

    it "drops old lines on read, and rewrites the file" do
      expect(history.entries.map { |e| e["id"] }).to eq(%w[fresh])
      expect(lines.map { |e| e["id"] }).to eq(%w[fresh])
    end

    it "drops old lines on write, keeping the append" do
      history.append(entry("next"))
      expect(lines.map { |e| e["id"] }).to eq(%w[fresh next])
    end

    it "honours an injected retention" do
      short = described_class.new(path: path, clock: clock, retention: 30)
      expect(short.prune).to eq(2)
      expect(File.read(path)).to eq("")
    end

    it "keeps a line whose time can't be parsed, and one that isn't an object" do
      File.write(path, "#{JSON.generate(old)}\n#{JSON.generate({"id" => "odd", "finished_at" => "soon"})}\nnot json\n[1]\n")
      expect(history.entries.map { |e| e["id"] }).to eq(%w[odd])
      expect(File.read(path).lines.size).to eq(3)
    end

    it "reports how many lines prune dropped" do
      expect(history.prune).to eq(1)
      expect(history.prune).to eq(0)
    end
  end

  describe "#clear" do
    before do
      history.append(entry("old", finished_at: now - 5 * 86_400))
      history.append(entry("new"))
    end

    it "clears the entries finished before a date" do
      expect(history.clear(before: now - 86_400)).to eq(1)
      expect(history.entries.map { |e| e["id"] }).to eq(%w[new])
    end

    it "clears everything" do
      expect(history.clear(all: true)).to eq(2)
      expect(history.entries).to eq([])
    end

    it "needs exactly one of before: and all:" do
      expect { history.clear }.to raise_error(ArgumentError)
      expect { history.clear(before: now, all: true) }.to raise_error(ArgumentError)
    end

    it "clears nothing when there is no file" do
      expect(described_class.new(path: File.join(dir, "none.jsonl"), clock: clock).clear(all: true)).to eq(0)
    end
  end
end
