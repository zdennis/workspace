RSpec.describe Workspace::ErrorCodes do
  let(:root) { PROJECT_ROOT }

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
    sources = %w[lib/workspace/commands/agent.rb lib/workspace/pipeline_desk.rb lib/workspace/agentd_router.rb lib/workspace/agentd_restart_desk.rb lib/workspace/agentd_socket_server.rb lib/workspace/hook_fanout.rb lib/workspace/core/agent_protocol.rb lib/workspace/agent_restart.rb lib/workspace/agent_status_desk.rb lib/workspace/typing_safety.rb].map { |path| File.read(File.join(root, path)) }.join
    literals = sources.scan(/"error" => "([a-z_]+)"|restart_error\("([a-z_]+)"|\bfailure\("([a-z_]+)"|\? "([a-z_]+)" : "([a-z_]+)"\)|\berror\("([a-z_]+)"|code: "([a-z_]+)"/).flatten.compact
    expect(literals).to include("pane_busy", "not_delivered", "not_submitted", "stale_token", "status_request_open", "pane_not_ready")
    expect(literals.uniq - described_class::REGISTRY.keys).to eq([])
  end

  it "registers every code and warning code promote can give, its move's and its notes carry's included" do
    sources = %w[lib/workspace/checkout_move.rb lib/workspace/notes_carry.rb lib/workspace/commands/promote.rb].map { |path| File.read(File.join(root, path)) }.join
    warnings = sources.scan(/"code" => "([a-z_]+)"|warn_item\("([a-z_]+)"/).flatten.compact
    warnings += %w[notes_not_file notes_not_directory] # NotesCarry builds these two from the item's kind
    expect(warnings).to include("default_ahead", "carry_note_already_carried", "start_note", "agent_state_unknown")
    codes = Workspace::CheckoutMove::CODES + [Workspace::Commands::Promote::AGENT_WORKING]
    expect(codes).to include("hidden_files", "path_conflicts", "move_incomplete")
    expect((codes + warnings).uniq - described_class::REGISTRY.keys).to eq([])
  end

  it "registers every code and warning code rename can give" do
    source = File.read(File.join(root, "lib/workspace/rename_plan.rb"))
    codes = source.scan(/refusal\("([a-z_]+)"/).flatten.uniq
    warnings = source.scan(/"code" => "([a-z_]+)"/).flatten.uniq
    expect(codes).to include("workspace_running", "run_active", "dev_lock_held", "rename_target_taken", "rename_in_progress")
    doc = File.read(File.join(root, "docs/README.json.md"))
    expect(codes - described_class::REGISTRY.keys).to eq([])
    expect(warnings.reject { |code| doc.include?("`#{code}`") }).to eq([])
  end

  it "registers every row and warning code template apply gives" do
    source = File.read(File.join(root, "lib/workspace/template_apply.rb"))
    codes = source.scan(/"code" => "([a-z_]+)"|failed\(name, "([a-z_]+)"/).flatten.compact.uniq
    expect(codes).to include("template_modified", "workspace_locked", "rollback_left_file", "prune_failed")
    expect(codes - described_class::REGISTRY.keys).to eq([])
  end

  it "registers every relaunch code and warning code template apply and restore give" do
    source = File.read(File.join(root, "lib/workspace/cli/template.rb")) + File.read(File.join(root, "lib/workspace/cli/relauncher.rb"))
    codes = source.scan(/"(relaunch_[a-z_]+)"/).flatten.uniq - ["relaunch_code"] # the row field, not a code
    expect(codes).to include("relaunch_stop_failed", "relaunch_launch_failed", "relaunch_failed", "relaunch_skipped", "relaunch_stop_warning", "relaunch_own_workspace", "relaunch_not_active", "relaunch_own_workspace_unknown")
    expect(codes - described_class::REGISTRY.keys).to eq([])
  end

  it "documents every registered code in docs/README.json.md" do
    doc = File.read(File.join(root, "docs/README.json.md"))
    missing = described_class::REGISTRY.keys.reject { |code| doc.include?("`#{code}`") }
    expect(missing).to eq([])
  end
end
