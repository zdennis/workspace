require "spec_helper"

RSpec.describe Workspace::WorkflowRoundHolder do
  let(:lock_holder) { instance_double(Workspace::LockHolder) }
  subject(:holder) { described_class.new(lock_holder: lock_holder, pid: 4321) }

  describe "#identity" do
    it "reads the start time until ps gives one, keeps nothing unread, then keeps the first one read" do
      answers = [Workspace::Error.new("ps failed"), Errno::EAGAIN.new("fork"), "Sat Nov 14 11:59:00 2026", "Sun Nov 15 08:00:00 2026"]
      allow(lock_holder).to receive(:start_time).with(4321) do
        answer = answers.shift
        answer.is_a?(Exception) ? raise(answer) : answer
      end

      expect(holder.identity).to eq("pid" => 4321, "started" => nil)
      expect(holder.identity).to eq("pid" => 4321, "started" => nil)
      expect(holder.identity).to eq("pid" => 4321, "started" => "Sat Nov 14 11:59:00 2026")
      expect(holder.identity).to eq("pid" => 4321, "started" => "Sat Nov 14 11:59:00 2026")

      expect(lock_holder).to have_received(:start_time).exactly(3).times
      expect(answers).to eq(["Sun Nov 15 08:00:00 2026"])
    end
  end

  describe "#alive?" do
    it "asks the lock holder by pid and start time" do
      allow(lock_holder).to receive(:holder_alive?).with(pid: 41, started: "x").and_return(false)

      expect(holder.alive?({"pid" => 41, "started" => "x"})).to be(false)
    end

    it "hands a holder with no start time on, for the pid alone to decide" do
      allow(lock_holder).to receive(:holder_alive?).with(pid: 41, started: nil).and_return(true)

      expect(holder.alive?({"pid" => 41, "started" => nil})).to be(true)
    end

    it "counts a holder alive when the process table can't be read" do
      allow(lock_holder).to receive(:holder_alive?).and_raise(Workspace::Error, "ps failed")
      expect(holder.alive?({"pid" => 41, "started" => "x"})).to be(true)

      allow(lock_holder).to receive(:holder_alive?).and_raise(Errno::EAGAIN)
      expect(holder.alive?({"pid" => 41, "started" => "x"})).to be(true)
    end
  end
end
