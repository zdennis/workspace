RSpec.describe Workspace::ErrorCodes do
  let(:root) { File.expand_path("../..", __dir__) }

  it "describes every code" do
    expect(described_class::REGISTRY).to all(satisfy { |code, text| code.match?(/\A[a-z_]+\z/) && !text.empty? })
    expect(described_class::REGISTRY).to be_frozen
  end

  it "knows registered codes only" do
    expect(described_class.known?("usage")).to be true
    expect(described_class.known?("made_up")).to be false
  end

  it "registers every code a raise site names in lib" do
    literals = Dir[File.join(root, "lib/**/*.rb")].flat_map do |path|
      File.read(path).scan(/\bcode: "([a-z_]+)"|\bCODE = "([a-z_]+)"|ConnectionError\.new\([^\n]*, "([a-z_]+)"\)/).flatten.compact
    end
    expect(literals).not_to be_empty
    expect(literals.uniq - described_class::REGISTRY.keys).to eq([])
  end

  it "registers every code the agent daemon can reply with" do
    sources = %w[lib/workspace/commands/agent.rb lib/workspace/agent_restart.rb].map { |path| File.read(File.join(root, path)) }.join
    literals = sources.scan(/"error" => "([a-z_]+)"|restart_error\("([a-z_]+)"|\bfailure\("([a-z_]+)"|\? "([a-z_]+)" : "([a-z_]+)"\)/).flatten.compact
    expect(literals).to include("pane_busy", "not_delivered", "not_submitted", "stale_token")
    expect(literals.uniq - described_class::REGISTRY.keys).to eq([])
  end

  it "documents every registered code in docs/README.json.md" do
    doc = File.read(File.join(root, "docs/README.json.md"))
    missing = described_class::REGISTRY.keys.reject { |code| doc.include?("`#{code}`") }
    expect(missing).to eq([])
  end
end
