RSpec.describe Workspace::AgentProvider do
  describe ".all" do
    it "includes Claude Code with hook support" do
      claude = described_class.find("claude")

      expect(claude.label).to eq("Claude Code")
      expect(claude.supports_hooks?).to be true
      expect(claude.settings_path).to eq(File.join(".claude", "settings.json"))
    end

    it "includes agents that have no hook system yet" do
      expect(described_class.find("codex").supports_hooks?).to be false
    end

    it "only Claude Code supports statusLine routing" do
      expect(described_class.find("claude").supports_statusline?).to be true
      expect(described_class.find("codex").supports_statusline?).to be false
      expect(described_class.find("opencode").supports_statusline?).to be false
      expect(described_class.find("pi").supports_statusline?).to be false
    end

    it "returns nil for an unknown key" do
      expect(described_class.find("nope")).to be_nil
    end

    it "lists Escape as the interrupt key of Claude Code and Codex, and none for the agents not checked yet" do
      expect(%w[claude codex opencode pi].to_h { |key| [key, described_class.find(key).interrupt_keys] })
        .to eq("claude" => ["Escape"], "codex" => ["Escape"], "opencode" => [], "pi" => [])
    end

    it "gives Claude Code a ready pattern matching its prompt, but leaves other providers without one" do
      claude = described_class.find("claude")

      expect(claude.ready_pattern).to match(("─" * 20) + "\n❯ Try something")
      expect(claude.ready_pattern).to match(("─" * 20) + "\n❯\u00A0\n")
      expect(claude.ready_pattern).not_to match("Do you trust the files in this folder?\n│ ❯ 1. Yes │")
      expect(described_class.find("codex").ready_pattern).to be_nil
    end

    it "opts pi out of the path-segment matching heuristic" do
      expect(described_class.find("pi").path_segment_matching?).to be false
    end

    it "leaves path-segment matching on for the other providers" do
      expect(described_class.find("claude").path_segment_matching?).to be true
      expect(described_class.find("codex").path_segment_matching?).to be true
      expect(described_class.find("opencode").path_segment_matching?).to be true
    end

    it "has a unique executable per provider" do
      executables = described_class.all.map(&:executable)

      expect(executables.uniq).to eq(executables)
    end

    it "lets handoff clear and resume Claude Code and Codex, and a pane not identified yet" do
      expect(described_class.restartable_kinds).to eq(%w[claude codex unknown])
      expect(described_class.find("opencode").restartable?).to be false
      expect(described_class.find("pi").restartable?).to be false
    end

    it "types /clear for every agent, Codex included" do
      expect(described_class.all.map(&:clear_command).uniq).to eq(["/clear"])
    end

    it "reads Codex context from the percent used in its status footer" do
      codex = described_class.find("codex")

      expect(codex.context_remaining?).to be false
      expect(Regexp.new(codex.context_pattern).match("  gpt-5  Context 72% used · Context 28% left")[1]).to eq("72")
      expect(Regexp.new(codex.context_pattern).match("Context 0% used · Context 100% left")[1]).to eq("0")
      expect(Regexp.new(codex.context_pattern).match("72% context left")).to be_nil
      expect(described_class.find("claude").context_pattern).to be_nil
      expect(described_class.find("claude").context_remaining?).to be false
    end
  end

  describe "#hook_settings" do
    subject(:settings) { described_class.find("claude").hook_settings("workspace session-event") }

    it "routes every subscribed event to the command" do
      commands = settings["hooks"].values.flatten.flat_map { |e| e["hooks"] }.map { |h| h["command"] }

      expect(commands.uniq).to eq(["workspace session-event"])
    end

    it "matches every tool, not just Task, so any tool use marks a lock holder active" do
      expect(settings["hooks"]["PreToolUse"].first).not_to have_key("matcher")
    end

    it "omits the matcher for events that are not tool-scoped" do
      expect(settings["hooks"]["Stop"].first).not_to have_key("matcher")
    end

    it "subscribes to Notification and PostToolUse, which start and end a pane's wait" do
      expect(settings["hooks"]).to include("Notification", "PostToolUse")
      expect(settings["hooks"]["PostToolUse"].first).not_to have_key("matcher")
    end
  end
end
