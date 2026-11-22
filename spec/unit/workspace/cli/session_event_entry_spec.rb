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

    %w[SessionStart SessionEnd PermissionRequest].each do |hook|
      it "hands a #{hook} payload to Workspace.build_cli with the raw payload as input" do
        raw = %({"hook_event_name":"#{hook}","session_id":"s1"})
        cli = double("cli", run: nil)
        input = nil
        allow(Workspace).to receive(:build_cli) { |**kwargs|
          input = kwargs[:input]
          cli
        }
        argv = %w[session-event --agent codex]

        code = described_class.run(argv, stdin: StringIO.new(raw), stdout: StringIO.new, stderr: StringIO.new, env: {})

        expect(code).to eq(0)
        expect(cli).to have_received(:run).with(argv)
        expect(input.read).to eq(raw)
      end
    end

    it "does not build the whole CLI for a PreToolUse payload" do
      allow(Workspace).to receive(:build_cli)
      command = double("command", call: {exit_code: 0})
      allow(Workspace::CLI::SessionEventWiring).to receive(:build).and_return(command)
      raw = %({"hook_event_name":"PreToolUse","tool_name":"Read"})

      described_class.run(%w[session-event --agent codex], stdin: StringIO.new(raw), stdout: StringIO.new, stderr: StringIO.new, env: {})

      expect(Workspace).not_to have_received(:build_cli)
      expect(command).to have_received(:call).with(workspace: nil, agent: "codex")
    end

    context "on the fast route" do
      let(:stderr) { StringIO.new }
      let(:command) { double("command") }

      before { allow(Workspace::CLI::SessionEventWiring).to receive(:build).and_return(command) }

      def run_entry
        described_class.run(%w[session-event --agent codex], stdin: StringIO.new(%({"hook_event_name":"PostToolUse"})), stdout: StringIO.new, stderr: stderr, env: {})
      end

      it "answers the exit code the command returns" do
        allow(command).to receive(:call).and_return({exit_code: 2})

        expect(run_entry).to eq(2)
        expect(stderr.string).to eq("")
      end

      it "prints a UsageError message as it is and answers 1" do
        allow(command).to receive(:call).and_raise(Workspace::UsageError, "bad")

        expect(run_entry).to eq(1)
        expect(stderr.string).to eq("bad\n")
      end

      it "prints a Workspace::Error as Error: MESSAGE with control characters escaped and answers 1" do
        allow(command).to receive(:call).and_raise(Workspace::Error, "boom\e[31m")

        expect(run_entry).to eq(1)
        expect(stderr.string).to eq("Error: boom\\e[31m\n")
      end
    end
  end
end
