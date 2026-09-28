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
