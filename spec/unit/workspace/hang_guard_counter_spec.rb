require "tmpdir"
require "json"

RSpec.describe Workspace::HangGuardCounter do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "hang-guard.json") }
  let(:now) { Time.utc(2026, 11, 23, 12, 0, 0) }
  let(:clock) { -> { now } }

  subject(:counter) { described_class.new(path: path, wait: 0.05, clock: clock) }

  after { FileUtils.remove_entry(dir) }

  def stored = JSON.parse(File.read(path))

  describe ".key_for" do
    it "keys an author by run, step and attempt" do
      binding = {"kind" => "run", "id" => "wr_1", "step" => "fix", "attempt" => 2}
      expect(described_class.key_for(binding: binding, pane_id: "%1", session_id: "s")).to eq("run:wr_1:fix:2")
    end

    it "adds the round for a reviewer" do
      binding = {"kind" => "run", "id" => "wr_1", "step" => "fix", "attempt" => 2, "role" => "reviewer", "round" => 3}
      expect(described_class.key_for(binding: binding, pane_id: "%1", session_id: "s")).to eq("run:wr_1:fix:2:r3")
    end

    it "keys a fan_out group pane by group and bound_at" do
      binding = {"kind" => "run", "id" => "wr_1", "group" => "g", "bound_at" => "2026-11-23T10:00:00Z"}
      expect(described_class.key_for(binding: binding, pane_id: "%1", session_id: "s")).to eq("run:wr_1:group:g:2026-11-23T10:00:00Z")
    end

    it "keys an unbound pane by pane and session" do
      expect(described_class.key_for(binding: nil, pane_id: "%1", session_id: "s")).to eq("pane:%1:s")
    end

    it "keys a run binding without step and attempt, or of another kind, as unbound" do
      expect(described_class.key_for(binding: {"kind" => "run", "id" => "wr_1"}, pane_id: "%1", session_id: "s")).to eq("pane:%1:s")
      expect(described_class.key_for(binding: {"kind" => "play", "id" => "p"}, pane_id: "%1", session_id: "s")).to eq("pane:%1:s")
    end
  end

  describe "#take" do
    it "denies and counts until the cap, then reports capped without counting" do
      expect(counter.take("k", max: 2)).to eq(:deny)
      expect(counter.take("k", max: 2)).to eq(:deny)
      expect(counter.take("k", max: 2)).to eq(:capped)
      expect(stored["k"]).to eq("count" => 2, "updated_at" => "2026-11-23T12:00:00Z")
    end

    it "denies exactly max times when threads race on one key" do
      racer = described_class.new(path: path, wait: 5, clock: clock)
      results = Array.new(8) { Thread.new { racer.take("k", max: 2) } }.map(&:value)
      expect(results.count(:deny)).to eq(2)
      expect(results.count(:capped)).to eq(6)
    end

    it "does not rewrite the file once capped or when clear_pane changes nothing" do
      counter.take("k", max: 1)
      before = File.mtime(path)
      File.utime(before - 100, before - 100, path)
      stamp = File.mtime(path)
      counter.take("k", max: 1)
      counter.clear_pane("%9")
      expect(File.mtime(path)).to eq(stamp)
    end

    it "counts each key apart" do
      counter.take("a", max: 1)
      expect(counter.take("b", max: 1)).to eq(:deny)
      expect(counter.take("a", max: 1)).to eq(:capped)
    end

    it "answers the count with take_counted" do
      expect(counter.take_counted("k", max: 2)).to eq([:deny, 1])
      expect(counter.take_counted("k", max: 2)).to eq([:deny, 2])
      expect(counter.take_counted("k", max: 2)).to eq([:capped, 2])
    end

    it "returns unknown when the lock is held past the wait" do
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |held|
        held.flock(File::LOCK_EX)
        expect(counter.take("k", max: 2)).to eq(:unknown)
      end
      expect(File.exist?(path)).to be(false)
    end

    it "returns unknown when the directory can't be made" do
      blocker = File.join(dir, "file")
      File.write(blocker, "x")
      expect(described_class.new(path: File.join(blocker, "sub", "hang-guard.json"), wait: 0.05).take("k", max: 2)).to eq(:unknown)
    end

    it "drops entries over a day old at each write and keeps fresh ones" do
      File.write(path, JSON.generate(
        "old" => {"count" => 2, "updated_at" => (now - 86_401).iso8601},
        "fresh" => {"count" => 1, "updated_at" => (now - 3600).iso8601},
        "bad" => {"count" => 1, "updated_at" => "yesterday"}
      ))
      counter.take("k", max: 2)
      expect(stored.keys).to contain_exactly("fresh", "k")
    end

    it "starts over from a corrupt file" do
      File.write(path, "{nope")
      expect(counter.take("k", max: 1)).to eq(:deny)
      expect(stored.keys).to eq(["k"])
    end
  end

  describe "#clear_pane" do
    it "removes only that pane's unbound entries" do
      counter.take("pane:%1:s1", max: 3)
      counter.take("pane:%1:s2", max: 3)
      counter.take("pane:%12:s1", max: 3)
      counter.take("run:wr_1:fix:1", max: 3)
      counter.clear_pane("%1")
      expect(stored.keys).to contain_exactly("pane:%12:s1", "run:wr_1:fix:1")
      expect(counter.take("pane:%1:s1", max: 1)).to eq(:deny)
    end

    it "takes no lock and writes nothing when the file holds no entry of the pane" do
      counter.take("pane:%12:s1", max: 3)
      counter.take("run:wr_1:fix:1", max: 3)
      before = File.read(path)
      patient = described_class.new(path: path, wait: 5, clock: clock)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |held|
        held.flock(File::LOCK_EX)
        patient.clear_pane("%1")
      end
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(File.read(path)).to eq(before)
    end

    it "does not make the file or its lock when there is none" do
      counter.clear_pane("%1")
      expect(Dir.children(dir)).to be_empty
    end

    it "does nothing when the lock wait runs out" do
      counter.take("pane:%1:s", max: 3)
      File.open("#{path}.lock", File::RDWR, 0o600) do |held|
        held.flock(File::LOCK_EX)
        expect(counter.clear_pane("%1")).to be_nil
      end
      expect(stored.keys).to eq(["pane:%1:s"])
    end
  end
end
