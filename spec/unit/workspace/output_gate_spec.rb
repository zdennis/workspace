require "stringio"

RSpec.describe Workspace::OutputGate do
  let(:io) { StringIO.new }
  let(:other) { StringIO.new }
  subject(:gate) { described_class.new(io) }

  it "writes to the stream it wraps" do
    gate.puts "hello"
    gate.print "a", "b"
    expect(io.string).to eq("hello\nab")
  end

  it "sends writes to the other stream while diverted, then goes back" do
    gate.divert_to(other) { gate.puts "diverted" }
    gate.puts "back"

    expect(other.string).to eq("diverted\n")
    expect(io.string).to eq("back\n")
  end

  it "goes back when the block raises" do
    expect { gate.divert_to(other) { raise "boom" } }.to raise_error("boom")

    gate.puts "after"
    expect(io.string).to eq("after\n")
  end

  it "returns the block's value" do
    expect(gate.divert_to(other) { :done }).to eq(:done)
  end

  it "answers what the target answers" do
    expect(gate).to respond_to(:puts)
    expect(gate).not_to respond_to(:no_such_method)
    expect { gate.no_such_method }.to raise_error(NoMethodError)
    expect(gate.tty?).to be(false)
  end
end
