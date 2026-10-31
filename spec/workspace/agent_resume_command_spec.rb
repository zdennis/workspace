require "spec_helper"

RSpec.describe Workspace::AgentResumeCommand do
  let(:id) { "123e4567-e89b-12d3-a456-426614174000" }
  let(:panes) { [{"kind" => "claude", "flags" => ["--dangerously-skip-permissions", "--model", "opus"]}] }
  let(:report) { instance_double(Workspace::TmuxinatorReport, show: {"windows" => [{"panes" => panes}]}) }
  let(:agent_commands) { nil }
  let(:command) { described_class.new(tmuxinator_report: report, agent_commands: agent_commands) }

  describe "#flags_for" do
    it "keeps only the carried flags of the claude pane" do
      expect(command.flags_for("ws")).to eq(["--dangerously-skip-permissions"])
    end

    it "answers an empty list when the pane has none" do
      allow(report).to receive(:show).and_return({"windows" => [{"panes" => [{"kind" => "shell"}]}]})
      expect(command.flags_for("ws")).to eq([])
    end

    it "answers nil when the config can't be read" do
      allow(report).to receive(:show).and_raise(Workspace::Error, "no config")
      expect(command.flags_for("ws")).to be_nil
    end
  end

  describe "#call" do
    def line(**overrides)
      command.call(workspace: "ws", cwd: "/work/ws", session_id: id, flags: [], **overrides)
    end

    it "changes into the directory and resumes the session" do
      expect(line).to eq("cd -- /work/ws && claude --resume #{id}")
    end

    it "keeps the flags before --resume" do
      expect(line(flags: ["--dangerously-skip-permissions"])).to eq("cd -- /work/ws && claude --dangerously-skip-permissions --resume #{id}")
    end

    it "quotes an odd directory" do
      expect(line(cwd: "/work/my dir/$x")).to eq("cd -- /work/my\\ dir/\\$x && claude --resume #{id}")
    end

    it "uses the configured command" do
      agent_commands = instance_double(Workspace::AgentCommands)
      allow(agent_commands).to receive(:command_for).with("ws", "claude").and_return("claude-dev")
      command = described_class.new(tmuxinator_report: report, agent_commands: agent_commands)
      expect(command.call(workspace: "ws", cwd: "/w", session_id: id, flags: [])).to eq("cd -- /w && claude-dev --resume #{id}")
    end

    it "answers nil for a session id that isn't one" do
      expect(line(session_id: "latest")).to be_nil
      expect(line(session_id: nil)).to be_nil
    end

    it "answers nil when the flags could not be read" do
      expect(line(flags: nil)).to be_nil
    end
  end
end
