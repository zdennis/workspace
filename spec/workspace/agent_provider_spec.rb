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

    it "returns nil for an unknown key" do
      expect(described_class.find("nope")).to be_nil
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
  end
end
