require "spec_helper"
require "json"

RSpec.describe Workspace::Commands::SessionEvent, ".full_wiring?" do
  full = %w[SessionStart SessionEnd PermissionRequest]

  {"claude" => described_class::CLAUDE_EVENTS, "codex" => described_class::CODEX_EVENTS}.each do |agent, table|
    table.each_key do |hook|
      it "is #{full.include?(hook)} for #{agent}'s #{hook}" do
        expect(described_class.full_wiring?(JSON.generate("hook_event_name" => hook), agent)).to be(full.include?(hook))
      end
    end
  end

  it "reads a payload with no --agent as Claude Code's" do
    expect(described_class.full_wiring?('{"hook_event_name":"SessionStart"}', nil)).to be(true)
    expect(described_class.full_wiring?('{"hook_event_name":"PreToolUse"}', nil)).to be(false)
  end

  it "reads --agent ignoring case, as the command does" do
    expect(described_class.full_wiring?('{"hook_event_name":"SessionEnd"}', "Codex")).to be(true)
  end

  it "is false for an agent with no table, which the command drops" do
    expect(described_class.full_wiring?('{"hook_event_name":"SessionStart"}', "gemini")).to be(false)
  end

  it "is false for a hook neither table names" do
    expect(described_class.full_wiring?('{"hook_event_name":"Interrupt"}', "claude")).to be(false)
  end

  [nil, "", "   ", "not json", "{", "[]", "\"SessionStart\"", "42", "null", "{\"hook_event_name\":[\"SessionStart\"]}"].each do |raw|
    it "is false for the payload #{raw.inspect}" do
      expect(described_class.full_wiring?(raw, "claude")).to be(false)
    end
  end

  it "reads a payload with invalid UTF-8 bytes as the command does" do
    raw = "{\"hook_event_name\":\"SessionStart\",\"x\":\"\xFF\"}".b
    expect(described_class.full_wiring?(raw, "claude")).to be(true)
  end
end
