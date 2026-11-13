require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::TemplateValidator do
  let(:dir) { Dir.mktmpdir("ws-template-validator") }
  let(:builtin) { File.join(PROJECT_ROOT, "lib/library/template/default") }
  let(:project_config) { Workspace::ProjectConfig.new(config: Workspace::Config.new(workspace_dir: dir), git: Workspace::Git.new, output: StringIO.new) }
  subject(:validator) { described_class.new(project_config: project_config) }

  after { FileUtils.rm_rf(dir) }

  def worktree_text(&edit)
    File.read(File.join(builtin, "worktree.yml")).then { |text| edit ? edit.call(text) : text }
  end

  def project_text(&edit)
    File.read(File.join(builtin, "project.yml")).then { |text| edit ? edit.call(text) : text }
  end

  # The built-in set with one file replaced by +text+ (a built-in file is clean, so its problems are the edit's).
  def check(kind, text)
    set = File.join(dir, "set-#{kind}")
    FileUtils.cp_r(builtin, set)
    File.write(File.join(set, "#{kind}.yml"), text)
    validator.call_set(set)
  end

  def codes(result)
    [result.errors.map(&:code), result.warnings.map(&:code)]
  end

  it "passes the built-in default set clean" do
    result = validator.call_set(builtin)

    expect([result.errors, result.warnings]).to eq([[], []])
    expect(result.valid?).to be(true)
  end

  it "reports an unknown placeholder, and one a kind does not fill" do
    expect(codes(check(:worktree, worktree_text { |t| t.sub("# {{CONFIG_PATH}}", "# {{NOPE}}") }))).to eq([["unknown_placeholder"], []])
    result = check(:project, project_text { |t| t + "# {{WORKTREE_PATH}}\n" })
    expect(codes(result)).to eq([["unknown_placeholder"], []])
    expect(result.errors.first.message).to include("not filled in a project template")
  end

  it "derives the placeholders a kind must hold from the TemplateVariables table" do
    project = check(:project, project_text { |t| t.gsub(/\{\{(PROJECT_NAME|PROJECT_ROOT|WORKSPACE_NAME)\}\}/, "x") })

    expect(project.errors.map(&:code)).to eq(["missing_placeholder"] * 3)
    expect(check(:project, project_text { |t| t.gsub("{{DISPLAY_NAME}}", "x").gsub("{{CONFIG_PATH}}", "x") }).errors).to eq([])
  end

  it "reports a required placeholder that does not appear" do
    result = check(:worktree, worktree_text { |t| t.gsub("{{WORKTREE_PATH}}", "/tmp/x") })

    expect(result.errors.map(&:code)).to eq(["missing_placeholder"])
    expect(result.errors.first.message).to include("WORKTREE_PATH")
  end

  it "requires {{PRE_WINDOW}} alone on its line" do
    expect(codes(check(:worktree, worktree_text { |t| t.sub("{{PRE_WINDOW}}", "  {{PRE_WINDOW}}") }))[0]).to eq(["pre_window_not_alone"])
    expect(codes(check(:worktree, worktree_text { |t| t.sub("{{PRE_WINDOW}}", "x: {{PRE_WINDOW}}") }))[0]).to eq(["pre_window_not_alone"])
    expect(codes(check(:worktree, worktree_text))[0]).to eq([])
  end

  it "refuses a quoted or embedded {{AGENT_COMMAND}} in a worktree template" do
    quoted = check(:worktree, worktree_text { |t| t.sub("- {{AGENT_COMMAND}}", "- \"{{AGENT_COMMAND}}\"") })
    inside = check(:worktree, worktree_text { |t| t.sub("- {{AGENT_COMMAND}}", "- exec {{AGENT_COMMAND}}") })

    expect(codes(quoted)).to eq([["agent_command_not_alone"], []])
    expect(codes(inside)).to eq([["agent_command_not_alone"], []])
  end

  it "makes a missing agent pane an error for a worktree and a warning for a project" do
    expect(codes(check(:worktree, worktree_text { |t| t.sub("        - {{AGENT_COMMAND}}\n", "") }))).to eq([["no_agent_pane"], []])
    expect(codes(check(:project, project_text { |t| t.sub("        - {{AGENT_COMMAND}}\n", "") }))).to eq([[], ["no_agent_pane"]])
    expect(codes(check(:project, project_text { |t| t.sub("- {{AGENT_COMMAND}}", "- \"{{AGENT_COMMAND}}\"") }))).to eq([[], ["agent_command_not_alone"]])
  end

  it "accepts a literal claude pane with a warning that names the placeholder" do
    result = check(:worktree, worktree_text { |t| t.sub("{{AGENT_COMMAND}}", "claude --dangerously-skip-permissions --continue || claude --dangerously-skip-permissions") })

    expect(codes(result)).to eq([[], ["literal_agent_pane"]])
    expect(result.warnings.first.message).to include("{{AGENT_COMMAND}}")
  end

  it "reports a render that is not a tmuxinator config" do
    broken = check(:worktree, worktree_text { |t| t.sub("startup_pane: 2", "startup_pane: [") })
    nameless = check(:worktree, worktree_text { |t| t.sub(/^name: .*\n/, "") })

    expect(codes(broken)[0]).to eq(["invalid_yaml"])
    expect(codes(nameless)[0]).to eq(["invalid_yaml"])
    expect(nameless.errors.first.message).to include("name")
  end

  it "reports a {{ left after the render" do
    result = check(:worktree, worktree_text { |t| t.sub("echo 'Worktree", "echo '{{ lowercase }} Worktree") })

    expect(codes(result)[0]).to eq(["unresolved_placeholder"])
  end

  it "reports an unreadable file" do
    set = File.join(dir, "half")
    FileUtils.mkdir_p(set)
    FileUtils.cp(File.join(builtin, "project.yml"), set)
    result = validator.call_set(set)

    expect(codes(result)[0]).to eq(["unreadable"])
    expect(result.errors.first.kind).to eq(:worktree)
  end

  it "answers a problem as a Hash and as text" do
    problem = check(:worktree, worktree_text { |t| t.sub("# {{CONFIG_PATH}}", "# {{NOPE}}") }).errors.first

    expect(problem.to_h).to include("severity" => "error", "code" => "unknown_placeholder", "kind" => "worktree")
    expect(problem.to_s).to start_with("worktree.yml: ")
  end
end
