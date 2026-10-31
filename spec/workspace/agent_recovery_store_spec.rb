require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentRecoveryStore do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "api", "agent-recovery.json") }
  let(:now) { [Time.utc(2026, 10, 19, 12, 0, 0)] }
  let(:clock) { double("clock").tap { |c| allow(c).to receive(:now) { now[0] } } }

  subject(:store) { described_class.new(path: path, clock: clock) }

  after { FileUtils.remove_entry(dir) }

  def stamp(seconds_ago) = described_class.stamp(now[0] - seconds_ago)

  describe ".wait_before" do
    it "doubles from 60 seconds to a 900 cap" do
      expect((1..6).map { |n| described_class.wait_before(n) }).to eq([60, 120, 240, 480, 900, 900])
    end

    it "adds up to 135 minutes over the 12 attempts" do
      expect((1..described_class::MAX_ATTEMPTS).sum { |n| described_class.wait_before(n) }).to eq(8100)
    end
  end

  describe "#put, #get, #update and #delete" do
    it "writes an entry that a new store object on the same path reads back" do
      store.put("%5", {session_id: "s1", attempts: 0, phase: "waiting"})

      again = described_class.new(path: path, clock: clock)
      expect(again.get("%5")).to eq("session_id" => "s1", "attempts" => 0, "phase" => "waiting")
      expect(again.entries.keys).to eq(["%5"])
    end

    it "replaces the entry on put" do
      store.put("%5", {session_id: "s1", attempts: 3})
      store.put("%5", {session_id: "s2"})

      expect(store.get("%5")).to eq("session_id" => "s2")
    end

    it "changes one entry in place and answers it" do
      store.put("%5", {attempts: 1, phase: "waiting"})

      result = store.update("%5") { |e| e["attempts"] += 1 }

      expect(result).to eq("attempts" => 2, "phase" => "waiting")
      expect(store.get("%5")["attempts"]).to eq(2)
    end

    it "creates an entry for a pane without one" do
      result = store.update("%9") { |e| e.merge!(attempts: 0, phase: "waiting") }

      expect(result).to eq("attempts" => 0, "phase" => "waiting")
      expect(store.get("%9")).to eq("attempts" => 0, "phase" => "waiting")
    end

    it "removes the entry when the block clears it" do
      store.put("%5", {attempts: 1})

      expect(store.update("%5", &:clear)).to be_nil
      expect(store.get("%5")).to be_nil
      expect(store.entries).to eq({})
    end

    it "replaces the entry when the block clears and refills it" do
      store.put("%5", {session_id: "s1", attempts: 4, stopped: true})

      store.update("%5") do |e|
        e.clear
        e[:session_id] = "s2"
        e[:attempts] = 0
      end

      expect(store.get("%5")).to eq("session_id" => "s2", "attempts" => 0)
    end

    it "writes nothing for a pane left without an entry" do
      expect(store.update("%9") { |e| e }).to be_nil
      expect(File.exist?(path)).to be(false)
    end

    it "returns and stores symbol keys as strings" do
      expect(store.update("%5") { |e| e[:phase] = "waiting" }).to eq("phase" => "waiting")
      expect(store.get("%5").keys).to eq(["phase"])
    end

    it "removes an entry and answers it" do
      store.put("%5", {attempts: 1})
      store.put("%6", {attempts: 2})

      expect(store.delete("%5")).to eq("attempts" => 1)
      expect(store.delete("%5")).to be_nil
      expect(store.entries.keys).to eq(["%6"])
    end

    it "reads as empty when the file is missing" do
      expect(store.get("%5")).to be_nil
      expect(store.entries).to eq({})
    end

    it "reads a corrupt file as empty and writes over it" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")
      expect(store.get("%5")).to be_nil

      store.put("%5", {attempts: 1})

      expect(store.get("%5")).to eq("attempts" => 1)
    end

    it "reads a file of the wrong shape as empty" do
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "[1, 2]")

      expect(store.entries).to eq({})
    end

    it "keeps every write from concurrent writers" do
      store.put("%0", {count: 0})
      threads = 8.times.map do |n|
        Thread.new do
          s = described_class.new(path: path, clock: clock)
          s.update("%#{n + 1}") { |e| e[:n] = n }
          5.times { s.update("%0") { |e| e["count"] += 1 } }
        end
      end
      threads.each(&:join)

      expect(store.get("%0")["count"]).to eq(40)
      expect(store.entries.size).to eq(9)
    end
  end

  describe "#holding?" do
    it "is false for a pane without an entry" do
      expect(store.holding?("%5")).to be(false)
    end

    it "is true in attempting" do
      store.put("%5", {phase: "attempting"})
      expect(store.holding?("%5")).to be(true)
    end

    %w[waiting watching].each do |phase|
      it "is false in #{phase} with nothing signalled" do
        store.put("%5", {phase: phase, stopped: false})
        expect(store.holding?("%5")).to be(false)
      end

      it "is true in #{phase} while stopped" do
        store.put("%5", {phase: phase, stopped: true})
        expect(store.holding?("%5")).to be(true)
      end

      it "is true in #{phase} with a signal under 5 minutes old" do
        store.put("%5", {phase: phase, stopped: false, last_signal_at: stamp(299)})
        expect(store.holding?("%5")).to be(true)
      end

      it "is false in #{phase} with a signal 5 minutes old" do
        store.put("%5", {phase: phase, stopped: false, last_signal_at: stamp(300)})
        expect(store.holding?("%5")).to be(false)
      end
    end

    it "is false in gave_up with stopped true" do
      store.put("%5", {phase: "gave_up", stopped: true})
      expect(store.holding?("%5")).to be(false)
    end

    it "is false in gave_up with a recent signal" do
      store.put("%5", {phase: "gave_up", stopped: false, last_signal_at: stamp(5)})
      expect(store.holding?("%5")).to be(false)
    end

    it "is false with an unreadable signal time" do
      store.put("%5", {phase: "waiting", last_signal_at: "soon"})
      expect(store.holding?("%5")).to be(false)
    end
  end
end
