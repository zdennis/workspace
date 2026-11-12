require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::Invocation do
  it "holds a run's streams, exit handler, flags and environment, and is frozen" do
    out = StringIO.new
    err = StringIO.new
    invocation = described_class.new(output: out, error_output: err, exit_handler: FakeExitHandler, help_asked: true, quiet: false, env: {"A" => "1"})

    expect([invocation.output, invocation.error_output, invocation.exit_handler]).to eq([out, err, FakeExitHandler])
    expect([invocation.help_asked, invocation.quiet, invocation.env]).to eq([true, false, {"A" => "1"}])
    expect(invocation).to be_frozen
  end

  it "builds a second invocation over other streams and leaves the first alone" do
    first = described_class.new(output: StringIO.new, error_output: StringIO.new, exit_handler: FakeExitHandler, help_asked: false, quiet: false, env: {})
    buffer = StringIO.new
    second = first.with(output: buffer)

    expect(second.output).to be(buffer)
    expect(first.output).not_to be(buffer)
  end
end
