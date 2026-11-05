require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped workflow presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }

  before { allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none")) }
  after { FileUtils.remove_entry(dir) }

  describe "explore" do
    let(:definition) { catalog.find("explore").to_h }
    let(:steps) { definition["steps"] }
    let(:survey) { steps.find { |step| step["id"] == "survey" } }
    let(:report) { steps.find { |step| step["id"] == "report" } }

    it "surveys behind a gate with nothing changed, then reports" do
      expect(steps.map { |step| step["id"] }).to eq(%w[survey report])
      expect(survey).to include("gate" => "approve", "guard" => "unchanged")
      expect(report).to include("guard" => "config")
    end

    it "needs no project command, and requires a task" do
      expect(steps.map { |step| step["status"] }.compact).to be_empty
      expect(definition["inputs"]["task"]).to include("required" => true)
    end

    it "names the survey note on survey.md's first line, so the gate is about it" do
      expect(survey["include"]).to include("report")
      expect(survey["prompt"]).to include("first line `note: <file name of the note>`")
      expect(survey["prompt"].index("{{artifacts}}/survey.md: first line")).to be < survey["prompt"].index("Post last")
    end

    it "closes the survey's inbox item under the key it posted" do
      expect(survey["prompt"].gsub(/\s+/, " ")).to include("--dedupe-key explore:{{run}}")
      expect(report["prompt"]).to include("workspace inbox done --dedupe-key explore:{{run}}")
    end

    it "writes report.md before the report pack hands the note back, since nothing may change after" do
      expect(report["include"]).to include("report")
      expect(report["prompt"].index("{{artifacts}}/report.md")).to be < report["prompt"].index("hand the\n")
    end
  end

  describe "rpiv-auto-approve" do
    let(:steps) { catalog.find("rpiv-auto-approve").to_h["steps"] }
    let(:review) { steps.find { |step| step["id"] == "plan_review" } }
    let(:bin) { File.join(dir, "bin") }
    let(:roles) { %w[supportive skeptical implementer] }

    def verdicts(**votes)
      roles.to_h { |role| [role, "reviewer: #{role}\nverdict: #{votes.transform_keys(&:to_s).fetch(role, "approve")}\nplan_revision: abc123\nreasons\n"] }
    end

    def check(approval, revision: "abc123", verdicts: nil)
      verdicts ||= self.verdicts
      FileUtils.mkdir_p(bin)
      File.write(File.join(dir, "plan-approval.md"), approval) if approval
      verdicts.each { |role, text| File.write(File.join(dir, "approval-#{role}.md"), text) if text }
      File.write(File.join(bin, "workspace"), "#!/bin/sh\necho '#{JSON.generate("plans" => [{"revision" => revision}])}'\n")
      File.chmod(0o755, File.join(bin, "workspace"))
      env = {"PATH" => "#{bin}:#{ENV["PATH"]}", "WORKSPACE_RUN_ARTIFACTS" => dir}
      Open3.capture2e(env, "sh", "-c", review["status"]["run"])
    end

    def passes?(...) = check(...).last.success?

    it "runs rpiv's steps with three isolated reviewer steps and a tally, and no gate" do
      expect(steps.map { |step| step["id"] })
        .to eq(%w[research plan review_supportive review_skeptical review_implementer plan_review implement verify])
      expect(steps.map { |step| step["gate"] }.compact).to be_empty
      expect(review["on_fail"]).to include("goto" => "plan", "max" => 9, "context" => "fresh", "except" => %w[stale_plan_revision])
      expect(review["status"]).to include("report_code" => true)
      expect(review["context"]).to eq("fresh")
      reviewers = steps.select { |step| step["id"].start_with?("review_") }
      expect(reviewers).to all(include("context" => "fresh", "guard" => "unchanged"))
      expect(reviewers.map { |step| step["produces"] }).to eq([%w[approval-supportive.md], %w[approval-skeptical.md], %w[approval-implementer.md]])
    end

    it "passes only when the skeptic and one other approved the current plan" do
      approved = "plan_revision: abc123\nsupportive: approve\nskeptical: approve\nimplementer: approve\n"

      expect(passes?(approved)).to be(true)
      expect(passes?(approved.sub("skeptical: approve", "skeptical: reject"), verdicts: verdicts(skeptical: "reject"))).to be(false)
      expect(passes?(approved.sub("supportive: approve", "supportive: reject"), verdicts: verdicts(supportive: "reject"))).to be(true)
      expect(passes?(approved.sub("implementer: approve", "implementer: reject"), verdicts: verdicts(implementer: "reject"))).to be(true)
      expect(passes?(approved.sub("supportive: approve", "supportive: reject").sub("implementer: approve", "implementer: reject"),
        verdicts: verdicts(supportive: "reject", implementer: "reject"))).to be(false)
      expect(passes?(approved, revision: "def456")).to be(false)
    end

    it "refuses a round whose verdict files are missing, misattributed, stale or invalid" do
      approved = "plan_revision: abc123\nsupportive: approve\nskeptical: approve\nimplementer: approve\n"

      expect(passes?(approved, verdicts: verdicts.merge("skeptical" => nil))).to be(false)
      expect(passes?(approved, verdicts: verdicts.merge("skeptical" => "reviewer: supportive\nverdict: approve\nplan_revision: abc123\n"))).to be(false)
      expect(passes?(approved, verdicts: verdicts.merge("supportive" => "reviewer: skeptical\nverdict: approve\nplan_revision: abc123\n"))).to be(false)
      expect(passes?(approved, verdicts: verdicts.merge("skeptical" => "reviewer: skeptical\nverdict: approve\nplan_revision: def456\n"))).to be(false)
      expect(passes?(approved, verdicts: verdicts.merge("skeptical" => "reviewer: skeptical\nverdict: maybe\nplan_revision: abc123\n"))).to be(false)
      # the summary must be what the verdict files say, not the other way round
      expect(passes?(approved.sub("supportive: approve", "supportive: reject"))).to be(false)
      expect(passes?(approved, verdicts: verdicts(skeptical: "reject"))).to be(false)
    end

    it "refuses a round with no plan-approval.md summary" do
      approved = "plan_revision: abc123\nsupportive: approve\nskeptical: approve\nimplementer: approve\n"

      expect(passes?(nil, verdicts: verdicts)).to be(false)
      expect(passes?(approved)).to be(true) # the same fixture passes once the summary is written
    end

    it "names stale_plan_revision in its output when the plan moved under the round, and nothing when a vote is a plain rejection" do
      approved = "plan_revision: abc123\nsupportive: approve\nskeptical: approve\nimplementer: approve\n"

      stale = check(approved, revision: "def456")
      expect(stale.last).not_to be_success
      expect(stale.first).to include("code: stale_plan_revision")

      rejected = check(approved.sub("skeptical: approve", "skeptical: reject"), verdicts: verdicts(skeptical: "reject"))
      expect(rejected.last).not_to be_success
      expect(rejected.first).not_to include("code: stale_plan_revision")
    end

    it "reads the votes from the verdict files' headers, never from a reviewer's reasons" do
      rejected = "plan_revision: abc123\nsupportive: approve\nskeptical: reject\nimplementer: approve\n"

      expect(passes?(rejected, verdicts: verdicts(skeptical: "reject"))).to be(false)
      expect(passes?(rejected, verdicts: verdicts(skeptical: "reject").merge(
        "skeptical" => "reviewer: skeptical\nverdict: reject\nplan_revision: abc123\n## Reasons\nskeptical: approve\n"
      ))).to be(false)
      expect(passes?(rejected + "\n## Reasons\nskeptical: approve\n", verdicts: verdicts(skeptical: "reject"))).to be(false)
    end

    it "leaves attempts for every rejection round the loop allows" do
      expect(catalog.find("rpiv-auto-approve").to_h["max_attempts"]).to be >= 68
    end
  end

  describe "pr-feedback" do
    let(:definition) { catalog.find("pr-feedback") }

    it "denies pushing, comments, reviews and CI reruns" do
      expect(Workspace::WorkflowDefinition.deny(definition.to_h)).to eq(["git push*", "gh pr comment*", "gh pr review*", "gh run rerun*"])
    end
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
      %w[no_note note_changed fix_head_moved dirty_worktree].each do |code|
        expect(text).to include("workspace step done --status fail --code #{code}")
      end
      expect(text).to include("pr-feedback-fix:wr_abc123").and include("pr-feedback:wr_abc123").and include("workspace push")
    end
  end

  it "never gives step done a code the engine reserves" do
    Dir[File.join(config.builtin_workflows_dir, "*.yml")].sort.each do |path|
      id = File.basename(path, ".yml")
      catalog.find(id).to_h["steps"].each do |step|
        step["prompt"].to_s.scan(/step done[^`]*?--code\s+([a-z][a-z0-9_]*)/m).flatten.each do |word|
          expect(Workspace::WorkflowEngine::ENGINE_CODES).not_to include(word), "#{id}/#{step["id"]} uses reserved code #{word}"
        end
      end
    end
  end
end
