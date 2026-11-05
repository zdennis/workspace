require "spec_helper"

RSpec.describe Workspace::DeferredSignals do
  subject(:signals) { described_class.new }

  def catching(name)
    caught = []
    previous = Signal.trap(name) { caught << name }
    yield caught
  ensure
    Signal.trap(name, previous)
  end

  %w[INT TERM HUP].each do |name|
    it "holds SIG#{name} until the block ends, then sends it on" do
      catching(name) do |caught|
        seen = signals.hold do
          Process.kill(name, Process.pid)
          sleep 0.01 until signals.caught
          caught.dup
        end

        expect(seen).to eq([])
        expect(signals.caught).to eq(name)
        expect(caught).to eq([name])
      end
    end
  end

  it "keeps the first of two signals" do
    catching("TERM") do
      signals.hold do
        Process.kill("TERM", Process.pid)
        sleep 0.01 until signals.caught
        signals.note("INT")
      end
    end

    expect(signals.caught).to eq("TERM")
  end

  it "sends nothing when no signal came, and gives the block's value" do
    catching("TERM") do |caught|
      expect(signals.hold { :done }).to eq(:done)
      expect(signals.caught).to be_nil
      expect(signals.report).to eq({})
      expect(caught).to eq([])
    end
  end

  it "leaves an ignored SIGHUP ignored, catching nothing and sending nothing" do
    previous = Signal.trap("HUP", "IGNORE")
    signals.hold do
      Process.kill("HUP", Process.pid)
      sleep 0.05
    end

    expect(signals.caught).to be_nil
    expect(Signal.trap("HUP", "IGNORE")).to eq("IGNORE")
  ensure
    Signal.trap("HUP", previous)
  end

  it "puts the old handlers back" do
    catching("TERM") do
      handler = Signal.trap("TERM", "DEFAULT")
      Signal.trap("TERM", handler)

      signals.hold { :nothing }

      expect(Signal.trap("TERM", handler)).to eq(handler)
    end
  end

  it "sends on a signal #note took, once the handlers are back" do
    catching("INT") do |caught|
      signals.hold { signals.note("INT") }

      expect(caught).to eq(["INT"])
    end
  end

  it "does not send a signal named by #report" do
    catching("TERM") do |caught|
      report = signals.hold do
        Process.kill("TERM", Process.pid)
        sleep 0.01 until signals.caught
        signals.report
      end

      expect(report).to eq("signal" => "SIGTERM")
      expect(caught).to eq([])
    end
  end

  it "sends on when the block raises and nothing reported the signal" do
    catching("TERM") do |caught|
      expect {
        signals.hold do
          Process.kill("TERM", Process.pid)
          sleep 0.01 until signals.caught
          raise "stopped"
        end
      }.to raise_error("stopped")

      expect(caught).to eq(["TERM"])
    end
  end
end
