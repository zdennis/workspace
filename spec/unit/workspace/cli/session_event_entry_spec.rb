require "spec_helper"
require "stringio"

RSpec.describe Workspace::CLI::SessionEventEntry do
  describe ".fast?" do
    {
      %w[session-event] => true,
      %w[session-event --agent codex] => true,
      %w[session-event --agent=codex] => true,
      %w[session-event --workspace proj] => true,
      %w[session-event --workspace=proj] => true,
      %w[session-event --workspace proj --agent codex] => true,
      %w[session-event --agent=codex --workspace=proj] => true,
      %w[session-event --agent codex --agent claude] => false,
      %w[session-event --workspace a --workspace=b] => false,
      %w[session-event --help] => false,
      %w[session-event -h] => false,
      %w[session-event --debug] => false,
      %w[session-event --json] => false,
      %w[session-event --no-input] => false,
      %w[session-event --work proj] => false,
      %w[session-event --agent] => false,
      %w[session-event --agent=] => false,
      %w[session-event --workspace=] => false,
      %w[session-event --agent -x] => false,
      %w[session-event --workspace --agent codex] => false,
      %w[session-event --agent codex extra] => false,
      %w[session-event extra] => false,
      %w[session-event --] => false,
      %w[--debug session-event] => false,
      %w[sessions] => false,
      [] => false
    }.each do |argv, fast|
      it "is #{fast} for #{argv.inspect}" do
        expect(described_class.fast?(argv)).to be(fast)
      end
    end
  end

  describe ".run" do
    it "refuses a command line .fast? does not accept, before reading stdin" do
      stdin = StringIO.new("{}")

      expect {
        described_class.run(%w[session-event --help], stdin: stdin, stdout: StringIO.new, stderr: StringIO.new, env: {})
      }.to raise_error(ArgumentError, /not a fast session-event command line/)
      expect(stdin.pos).to eq(0)
    end
  end
end
