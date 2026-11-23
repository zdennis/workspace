require "spec_helper"
require "stringio"

RSpec.describe Workspace::WatchLoop do
  let(:tty_class) do
    Class.new(StringIO) do
      def tty?
        true
      end
    end
  end
  let(:interval) { 2 }

  def loop_over(output, frames, sleeper: ->(_) {})
    frames = frames.dup
    described_class.new(output: output, sleeper: sleeper).run(interval: interval) do |io|
      io.print(frames.shift)
      frames.empty?
    end
  end

  it "clears the screen before each frame on a TTY" do
    out = tty_class.new
    loop_over(out, %w[a b])
    expect(out.string).to eq("\e[H\e[2Ja\e[H\e[2Jb")
  end

  it "appends frames without escapes on a non-TTY" do
    out = StringIO.new
    loop_over(out, %w[a b])
    expect(out.string).to eq("ab")
  end

  it "does not reprint an unchanged frame" do
    out = StringIO.new
    loop_over(out, %w[a a b b])
    expect(out.string).to eq("ab")
  end

  it "stops without sleeping when the block returns truthy" do
    sleeps = []
    result = loop_over(StringIO.new, %w[a], sleeper: ->(i) { sleeps << i })
    expect(sleeps).to be_empty
    expect(result).to eq({exit_code: 0})
  end

  it "sleeps the interval between frames" do
    sleeps = []
    loop_over(StringIO.new, %w[a b c], sleeper: ->(i) { sleeps << i })
    expect(sleeps).to eq([2, 2])
  end

  it "returns exit 0 on Interrupt and prints a newline on a TTY" do
    out = tty_class.new
    result = described_class.new(output: out, sleeper: ->(_) { raise Interrupt }).run(interval: 1) { |io| io.print("x") && false }
    expect(result).to eq({exit_code: 0})
    expect(out.string).to end_with("x\n")
  end

  it "prints no newline on Interrupt off a TTY" do
    out = StringIO.new
    described_class.new(output: out, sleeper: ->(_) { raise Interrupt }).run(interval: 1) { |io| io.print("x") && false }
    expect(out.string).to eq("x")
  end

  it "returns exit 0 on EPIPE" do
    out = StringIO.new
    allow(out).to receive(:print).and_raise(Errno::EPIPE)
    expect(loop_over(out, %w[a])).to eq({exit_code: 0})
  end

  it "lets a Workspace::Error from the block propagate" do
    watch = described_class.new(output: StringIO.new, sleeper: ->(_) {})
    expect { watch.run(interval: 1) { raise Workspace::Error, "boom" } }.to raise_error(Workspace::Error, "boom")
  end
end
