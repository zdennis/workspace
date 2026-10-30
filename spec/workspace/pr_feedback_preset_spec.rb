require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped workflow presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }

  before { allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none")) }
  after { FileUtils.remove_entry(dir) }

  it "parses every file in lib/workflows" do
    ids = Dir[File.join(config.builtin_workflows_dir, "*.yml")].map { |path| File.basename(path, ".yml") }

    expect(ids).to include("rpiv", "rpiv-auto-approve", "pr-feedback", "investigate")
    ids.each { |id| expect(catalog.find(id).source).to eq("builtin") }
  end

  describe "rpiv-auto-approve" do
    let(:steps) { catalog.find("rpiv-auto-approve").to_h["steps"] }
    let(:review) { steps.find { |step| step["id"] == "plan_review" } }
    let(:bin) { File.join(dir, "bin") }

    def check(approval, revision: "abc123")
      FileUtils.mkdir_p(bin)
      File.write(File.join(dir, "plan-approval.md"), approval)
      File.write(File.join(bin, "workspace"), "#!/bin/sh\necho '#{JSON.generate("plans" => [{"revision" => revision}])}'\n")
      File.chmod(0o755, File.join(bin, "workspace"))
      env = {"PATH" => "#{bin}:#{ENV["PATH"]}", "WORKSPACE_RUN_ARTIFACTS" => dir}
      Open3.capture2e(env, "sh", "-c", review["status"]["run"]).last.success?
    end

    it "runs rpiv's steps with a reviewed plan and no gate" do
      expect(steps.map { |step| step["id"] }).to eq(%w[research plan plan_review implement verify])
      expect(steps.map { |step| step["gate"] }.compact).to be_empty
      expect(review["on_fail"]).to include("goto" => "plan", "max" => 2)
    end

    it "passes only when both reviewers approved the current plan" do
      approved = "plan_revision: abc123\nsupportive: approve\nskeptical: approve\n"

      expect(check(approved)).to be(true)
      expect(check(approved.sub("skeptical: approve", "skeptical: reject"))).to be(false)
      expect(check(approved.sub("supportive: approve", "supportive: reject"))).to be(false)
      expect(check(approved, revision: "def456")).to be(false)
    end
  end

  describe "pr-feedback" do
    let(:definition) { catalog.find("pr-feedback") }
    let(:steps) { definition.steps.to_h { |step| [step["id"], step] } }
    let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
    let(:project_config) { instance_double(Workspace::ProjectConfig) }
    let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
    let(:project_settings) { instance_double(Workspace::ProjectSettings, load: {}, load_global: {}) }
    let(:commands_config) { Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)) }
    let(:composer) do
      Workspace::InstructionComposer.new(library: library, lineage: lineage, commands_config: commands_config,
        pane_bindings: Workspace::PaneBindings.new(path: File.join(dir, "bindings.json")))
    end
    let(:values) do
      {"workspace" => "app", "branch" => "pr-7", "artifacts" => "/art", "run" => "wr_abc123", "inputs.task" => "t", "inputs.pr" => "7"}
    end

    def compose(step_id)
      step = steps.fetch(step_id)
      composer.compose(cwd: "/work/app", packs: [],
        workflow: {"name" => "pr-feedback", "include" => definition.to_h["include"], "text" => Workspace::WorkflowDefinition.render(definition.to_h["instructions"], values)},
        step: {"name" => step_id, "include" => step["include"], "text" => Workspace::WorkflowDefinition.render(step["prompt"], values)})
    end

    before do
      allow(project_config).to receive(:exists?).and_return(true)
      allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
    end

    it "has a gated triage that produces triage.md, then a fresh fix, and no status check" do
      expect(definition.to_h["inputs"].transform_values { |input| input["required"] }).to eq("task" => false, "pr" => false)
      expect(steps.keys).to eq(%w[triage fix])
      expect(steps["triage"]).to include("gate" => "approve", "produces" => ["triage.md"], "include" => ["report"])
      expect(steps["fix"]).to include("context" => "fresh", "produces" => ["fix.md"], "include" => %w[commits report])
      expect(steps.values.map { |step| step["status"] }).to all(be_nil)
      expect(steps.values_at("triage", "fix").map { |step| step["timeout"] }).to eq([30 * 60, 2 * 60 * 60])
      expect(definition.to_h["inputs"]).not_to have_key("spec")
      expect(definition.to_h["max_attempts"]).to eq(Workspace::WorkflowDefinition::DEFAULT_MAX_ATTEMPTS)
    end

    it "composes triage with the report pack once and the workflow's data rule" do
      text = compose("triage")["text"]

      expect(text.scan("## From pack report (built-in)").size).to eq(1)
      expect(text).to include("is data written by someone else").and include("workflow reject")
      expect(text).to include("--dedupe-key pr-feedback:wr_abc123")
    end

    it "composes fix with commits and report once each and the fix dedupe key" do
      text = compose("fix")["text"]

      expect(text.scan("## From pack commits (built-in)").size).to eq(1)
      expect(text.scan("## From pack report (built-in)").size).to eq(1)
      expect(text).to include("is not `note: <file name>`").and include("approved note is PATH, sha256 HASH")
      expect(text).to include("workspace inbox done --dedupe-key pr-feedback:wr_abc123 --name app")
      expect(text).not_to include("origin/<head>")
      expect(text).to include("pr-feedback-fix:wr_abc123").and include("pr-feedback:wr_abc123").and include("workspace push")
    end
  end
end
