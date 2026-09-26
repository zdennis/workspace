require "stringio"

RSpec.describe Workspace::Warn do
  it "writes the message plain when the stream is not a tty" do
    io = StringIO.new
    allow(io).to receive(:tty?).and_return(false)

    described_class.puts(io, "something went wrong")

    expect(io.string).to eq("something went wrong\n")
  end

  it "wraps the message in yellow ANSI codes when the stream is a tty" do
    io = StringIO.new
    allow(io).to receive(:tty?).and_return(true)

    described_class.puts(io, "something went wrong")

    expect(io.string).to eq("\e[33msomething went wrong\e[0m\n")
  end
end
