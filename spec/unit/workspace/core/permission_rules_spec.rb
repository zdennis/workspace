require "spec_helper"

RSpec.describe Workspace::PermissionRules do
  def parse(value, **opts) = described_class.parse(value, label: "rules", **opts)

  it "reads nil as none and an empty list as valid" do
    expect(parse(nil)).to eq([])
    expect(parse([])).to eq([])
  end

  it "returns string-key hashes, with pattern only when given" do
    rules = parse([{"tool" => "Bash", "pattern" => "git *", "action" => "allow"}, {tool: "Edit", action: "ask"}])
    expect(rules).to eq([{"tool" => "Bash", "pattern" => "git *", "action" => "allow"}, {"tool" => "Edit", "action" => "ask"}])
  end

  it "feeds the policy a rule it can decide with" do
    rules = parse([{"tool" => "Bash", "pattern" => "rm *", "action" => "deny"}])
    layers = [{source: "global", rules: rules, default: "allow"}]
    decision = Workspace::PermissionPolicy.new(layers: layers).decide(tool_name: "Bash", tool_input: {"command" => "rm -rf x"}, cwd: "/tmp")
    expect(decision[:action]).to eq("deny")
  end

  it "raises for a value that is not an Array, never reading it as empty" do
    [{}, "Bash", 3, false].each do |bad|
      expect { parse(bad) }.to raise_error(ArgumentError, /rules must be a list/)
    end
  end

  {
    "a non-Hash entry" => ["x", /rules\[0\] must be a mapping/],
    "an unknown key" => [{"tool" => "Bash", "action" => "ask", "why" => 1}, /rules\[0\] has unknown key "why"/],
    "an empty tool" => [{"tool" => " ", "action" => "ask"}, /rules\[0\]\.tool/],
    "a missing tool" => [{"action" => "ask"}, /rules\[0\]\.tool/],
    "a bad action" => [{"tool" => "Bash", "action" => "permit"}, /rules\[0\]\.action must be one of allow, ask, deny/],
    "a non-string pattern" => [{"tool" => "Bash", "action" => "ask", "pattern" => 3}, /rules\[0\]\.pattern must be a non-empty string/],
    "an empty pattern" => [{"tool" => "Bash", "action" => "ask", "pattern" => ""}, /rules\[0\]\.pattern/],
    "a long pattern" => [{"tool" => "Bash", "action" => "ask", "pattern" => "a" * 201}, /longer than 200/],
    "many wildcards" => [{"tool" => "Bash", "action" => "ask", "pattern" => "*" * 9}, /more than 8 wildcards/]
  }.each do |name, (entry, message)|
    it "raises for #{name}" do
      expect { parse([entry]) }.to raise_error(ArgumentError, message)
    end
  end

  it "names the index of the bad entry" do
    expect { parse([{"tool" => "Bash", "action" => "ask"}, "x"]) }.to raise_error(ArgumentError, /rules\[1\]/)
  end

  it "restricts actions when asked" do
    expect { parse([{"tool" => "Bash", "action" => "allow"}], actions: %w[deny ask]) }.to raise_error(ArgumentError, /rules\[0\]\.action must be one of deny, ask/)
    expect(parse([{"tool" => "Bash", "action" => "deny"}], actions: %w[deny ask]).size).to eq(1)
  end

  it "shares its pattern limits with workflow deny lists" do
    expect(Workspace::WorkflowDefinition::MAX_DENY_LENGTH).to eq(described_class::MAX_PATTERN_LENGTH)
    expect(Workspace::WorkflowDefinition::MAX_DENY_WILDCARDS).to eq(described_class::MAX_PATTERN_WILDCARDS)
  end
end
