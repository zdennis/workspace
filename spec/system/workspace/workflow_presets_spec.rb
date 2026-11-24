require "spec_helper"
require "tmpdir"
require "digest"

RSpec.describe "the shipped workflow presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:ids) { Dir[File.join(config.builtin_workflows_dir, "*.yml")].map { |path| File.basename(path, ".yml") }.sort }

  before { allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none")) }
  after { FileUtils.remove_entry(dir) }

  it "parses every file in lib/workflows" do
    expect(ids).to include("rpiv", "rpiv-auto-approve", "rpiv-auto-approve-v2", "pr-feedback", "investigate", "explore", "explore-parallel", "bugfix")
    ids.each { |id| expect(catalog.find(id).source).to eq("builtin") }
  end

  it "ties every inbox_item proof to a key its step's prompt posts with --reopen" do
    ids.each do |id|
      catalog.find(id).to_h["steps"].each do |step|
        Array(step["require"]).filter_map { |entry| entry["inbox_item"] }.each do |key|
          prompt = step["prompt"].gsub(/\s+/, " ")
          expect(prompt).to include("--dedupe-key #{key}"), "#{id}/#{step["id"]} never posts #{key}"
          expect(prompt).to match(/--dedupe-key #{Regexp.escape(key)}[^`]*--reopen|--reopen[^`]*--dedupe-key #{Regexp.escape(key)}/), "#{id}/#{step["id"]} posts #{key} without --reopen"
        end
      end
    end
  end

  it "proves the inbox item of exactly the steps that post one on every successful path" do
    expected = {
      "bugfix" => [],
      "explore" => %w[survey report],
      "explore-parallel" => [],
      "pr-feedback" => %w[triage fix],
      "investigate" => %w[diagnose fix],
      "rpiv" => [],
      "rpiv-auto-approve" => [],
      "rpiv-auto-approve-v2" => []
    }
    expect(expected.keys.sort).to eq(ids)
    expected.each do |id, step_ids|
      proven = catalog.find(id).to_h["steps"].select { |step| Array(step["require"]).any? { |entry| entry.key?("inbox_item") } }
      expect(proven.map { |step| step["id"] }).to eq(step_ids), id
    end
  end

  describe "rpiv, rpiv-auto-approve and rpiv-auto-approve-v2" do
    %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
      it "#{id} requires a commit and a done plan to implement, and a passing lint to verify" do
        steps = catalog.find(id).to_h["steps"]
        by_id = ->(name) { steps.find { |step| step["id"] == name } }

        expect(by_id.call("implement")["require"]).to eq([{"commits" => 1}, {"plan_status" => "done"}])
        expect(by_id.call("verify")["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(by_id.call("verify")["status"]).to eq({"command" => "test", "timeout" => 2400.0})
        expect(by_id.call("implement")["prompt"]).to include("then set the plan's\n`status: done`")
      end
    end

    # The step implement's failure loops back into is config, so it reruns after implement's commit instead of
    # stopping head_moved: plan in rpiv and v2, plan_review in rpiv-auto-approve.
    it "guards research (and plan and the reviewer steps in rpiv-auto-approve) as unchanged, the step implement loops back into as config, and nothing else" do
      %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
        guards = catalog.find(id).to_h["steps"].to_h { |step| [step["id"], step["guard"]] }
        expect(guards.select { |_, guard| guard }).to eq((id == "rpiv-auto-approve") ? {
          "research" => "unchanged", "plan" => "unchanged", "review_supportive" => "unchanged", "review_skeptical" => "unchanged",
          "review_implementer" => "unchanged", "plan_review" => "config"
        } : {"research" => "unchanged", "plan" => "config"}), id
      end
    end

    it "pins on_fail and the run allowance the loop default was tuned against" do
      expect(catalog.find("rpiv").to_h["max_attempts"]).to eq(14)
      expect(catalog.find("rpiv-auto-approve").to_h["max_attempts"]).to eq(67)
      expect(catalog.find("rpiv-auto-approve-v2").to_h["max_attempts"]).to eq(21)

      rpiv = catalog.find("rpiv").to_h["steps"].find { |step| step["id"] == "verify" }
      expect(rpiv["on_fail"]).to include("goto" => "implement", "max" => 3)

      auto = catalog.find("rpiv-auto-approve").to_h["steps"].to_h { |step| [step["id"], step["on_fail"]] }
      # The three reviewers sit in one fan_out group and carry no on_fail of their own: a
      # reviewer that fails takes the group's goto back to plan, and the tally loops back on a
      # rejected round.
      expect(auto.slice("review_supportive", "review_skeptical", "review_implementer").values).to all(be_nil)
      expect(catalog.find("rpiv-auto-approve").to_h["groups"]["reviewers"]["on_fail"]).to eq({"goto" => "plan", "max" => 2, "context" => "fresh", "except" => ["guard", "check_error"]})
      expect(auto["plan_review"]).to eq({"goto" => "plan", "max" => 9, "context" => "fresh", "except" => ["stale_plan_revision", "guard", "check_error"]})

      # A step whose failure is a deliberate stop for a person never loops.
      stops = ->(id, *names) { catalog.find(id).to_h["steps"].to_h { |step| [step["id"], step["on_fail"]] }.values_at(*names) }
      expect(stops.call("investigate", "reproduce", "diagnose", "fix")).to all(eq("stop"))
      expect(stops.call("pr-feedback", "fix")).to all(eq("stop"))
    end

    %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
      it "#{id} refuses a dirty checkout at preflight and accepts a clean one" do
        definition = catalog.find(id)
        worktree = File.join(File.realpath(dir), "app")
        FileUtils.mkdir_p(worktree)
        system("git", "-C", worktree, "init", "-q", "-b", "feature/x", exception: true)
        QuietGit.configure(worktree)
        File.write(File.join(worktree, "a.txt"), "1")
        system("git", "-C", worktree, "add", "a.txt", exception: true)
        system("git", "-C", worktree, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "a", exception: true)
        git = Workspace::Git.new(output: StringIO.new, input: StringIO.new)
        lock_namespace = instance_double(Workspace::LockNamespace)
        allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: File.join(dir, "locks"))
        store = Workspace::WorkflowRunStore.new(dir: File.join(dir, "runs"), archive_dir: File.join(dir, "archive"))
        engine = Workspace.build_workflow_engine(store: store,
          resources: Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(File.join(dir, "runs"))),
          composer: FakeStepComposer.new, panes: FakeWorkflowPanes.new, checker: ->(**) { {exit_code: 0, timed_out: false} },
          commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "t", lint: nil}),
          lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git, guard: Workspace::WorkflowGuard.new,
          excludes: Workspace::GitExclude.new(git: git), gate_note: instance_double(Workspace::WorkflowGateNote, notes_dir_of: nil),
          env_stopper: ->(**) {}, event_log: instance_double(Workspace::EventLog, record: nil),
          task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}))
        run = -> { engine.preflight(definition: definition, workspace: "app", worktree: worktree, inputs: {"task" => "x"}) }

        expect(run.call["step"]).to eq("research")
        File.write(File.join(worktree, "a.txt"), "2")
        expect { run.call }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("dirty_worktree") }
      end
    end

    it "makes the lint proof optional, so a project without a lint command still runs" do
      %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
        verify = catalog.find(id).to_h["steps"].find { |step| step["id"] == "verify" }
        expect(verify["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(verify["prompt"].gsub(/\s+/, " ")).to include("lint command, when it has one, must pass")
      end
    end

    it "tells implement never to amend or rebase, and to commit empty when nothing needs changing" do
      %w[rpiv rpiv-auto-approve rpiv-auto-approve-v2].each do |id|
        implement = catalog.find(id).to_h["steps"].find { |step| step["id"] == "implement" }
        expect(implement["prompt"].gsub(/\s+/, " ")).to include("never amend or rebase").and include("git commit --allow-empty -m '<why>'")
      end
    end
  end

  describe "rpiv-auto-approve-v2" do
    let(:definition) { catalog.find("rpiv-auto-approve-v2") }
    let(:data) { definition.to_h }
    let(:plan) { data["steps"].find { |step| step["id"] == "plan" } }

    it "is listed by the catalog as a builtin and validates with no warnings" do
      expect(catalog.list.map { |row| [row["id"], row["source"]] }).to include(["rpiv-auto-approve-v2", "builtin"])
      expect(catalog.known?("rpiv-auto-approve-v2")).to be(true)
      expect(definition.warnings).to eq([])
    end

    it "reviews the plan in place of the gate: skeptic plus one other, six rounds, caps from the design" do
      expect(plan["gate"]).to be_nil
      expect(Workspace::WorkflowDefinition.review(plan)).to include("from" => %w[supportive skeptical implementer], "need" => 2, "must" => ["skeptical"], "max_rounds" => 6)
      expect(Workspace::WorkflowDefinition.step_max_attempts(plan)).to eq(8)
      expect(Workspace::WorkflowDefinition.reviewers(data).keys).to eq(%w[supportive skeptical implementer])
      expect(data["max_attempts"]).to eq(21)
      expect(Workspace::WorkflowDefinition.run_timeout(data)).to include("seconds" => 28_800.0, "action" => "hold")
      expect(Workspace::WorkflowDefinition.budget(data)).to include("tokens" => 40_000_000)
    end

    it "hashes the workspace plan into the review revision and keeps plan.md among the produced files" do
      expect(plan["produces"]).to eq(["plan.md"])
      expect(plan["review"]["revision"]).to eq(%q(workspace plan status --json | ruby -rjson -e 'data = JSON.parse($stdin.read); abort "no plans" unless data.key?("plans"); puts data["plans"].to_a.first&.dig("revision")'))
    end

    it "keeps the plan step's include, status check and timeout" do
      expect(plan["include"]).to eq(%w[notes implementation-plan])
      expect(plan["status"]["run"]).to eq(catalog.find("rpiv").to_h["steps"].find { |step| step["id"] == "plan" }["status"]["run"])
      expect(plan["timeout"]).to eq(2700.0)
    end

    it "titles its reviewers and has each prompt use the subject and the previous write-up" do
      reviewers = Workspace::WorkflowDefinition.reviewers(data)
      expect(reviewers.transform_values { |reviewer| reviewer["title"] }).to eq("supportive" => "Supportive review", "skeptical" => "Skeptical review", "implementer" => "Implementer review")
      reviewers.each_value do |reviewer|
        expect(reviewer["prompt"].gsub(/\s+/, " ")).to include("{{review.subject}}").and include("{{review.previous}}").and include("Do not edit the plan")
      end
    end

    it "pins the sha256 of rpiv.yml and rpiv-auto-approve.yml, so an edit to either is made on purpose" do
      sha = ->(id) { Digest::SHA256.file(File.join(config.builtin_workflows_dir, "#{id}.yml")).hexdigest }
      expect(sha.call("rpiv")).to eq("d213a87f75099f5fccdfbd44020e6d47f0455e5e049aaa31e3b8c1df0edd4403")
      expect(sha.call("rpiv-auto-approve")).to eq("f8a1a4764e580d9d60cace77807c8b135057d8206dc0e4566185a25f2a4c0983")
    end

    it "imports research and implement from lib/workflows/steps/ in rpiv and rpiv-auto-approve, each equal to the library step" do
      %w[rpiv rpiv-auto-approve].each do |id|
        path = File.join(config.builtin_workflows_dir, "#{id}.yml")
        raw = YAML.safe_load_file(path)
        inline = raw.merge("steps" => raw["steps"].to_h do |step_id, step|
          next [step_id, step] unless %w[research implement].include?(step_id)
          expect(step).to eq("import" => step_id), "#{id}/#{step_id} is not a bare import"
          library = YAML.safe_load_file(File.join(config.builtin_workflows_dir, "steps", "#{step_id}.yml"))
          [step_id, library["steps"].fetch(step_id)]
        end)
        written_out = Workspace::WorkflowDefinition.parse(YAML.dump(inline), id: id, source: "builtin", path: path)
        imported = catalog.find(id)

        %w[research implement].each do |step_id|
          step = ->(definition) { definition.to_h["steps"].find { |each| each["id"] == step_id } }
          expect(step.call(imported)).to eq(step.call(written_out)), "#{id}/#{step_id} differs from steps/#{step_id}.yml"
        end
      end
    end
  end

  describe "explore" do
    let(:steps) { catalog.find("explore").to_h["steps"] }

    it "sends the brief once, in the instructions, with an optional one-line topic" do
      data = catalog.find("explore").to_h
      texts = [data["instructions"]] + steps.map { |step| step["prompt"] }
      expect(texts.sum { |text| text.scan("{{inputs.task}}").size }).to eq(1)
      expect(data["instructions"]).to include("{{inputs.task}}")
      expect(data["inputs"]["topic"]).to include("required" => false)
      topic = Regexp.new("\\A(?:#{data["inputs"]["topic"]["pattern"]})\\z")
      expect(topic).to match("upload-resume")
      expect(topic).not_to match("two\nlines")
      expect(topic).not_to match("two words")
    end

    it "refuses a topic with a space or a placeholder through the input check, and takes a slug or none" do
      data = catalog.find("explore").to_h
      check = ->(topic) { Workspace::WorkflowInputs.check(data, {"task" => "q", "topic" => topic}) }
      ["bad{{", "two words", "a\nb", "-lead"].each do |bad|
        expect { check.call(bad) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("invalid_input")
          expect(error.details).to include("input" => "topic")
        }
      end
      expect(check.call("upload-resume")).to include("topic" => "upload-resume")
      expect(check.call("")).to include("topic" => "")
    end

    it "puts notes in the notes directory and only the run files under the artifacts directory" do
      instructions = catalog.find("explore").to_h["instructions"].gsub(/\s+/, " ")
      expect(instructions).not_to include("Every artifact goes under")
      expect(instructions).to include("notes go in the notes directory").and include("run files")
    end

    it "points the report at the approval note and keeps the brief's report requirements for it" do
      survey, report = steps.map { |step| step["prompt"].gsub(/\s+/, " ") }
      expect(survey).to include("belong to the report step")
      expect(report).to include("## For this attempt").and include("gate_note")
    end

    it "keys the report's item apart from the survey's, which the report closes" do
      survey, report = steps.map { |step| [step["prompt"].gsub(/\s+/, " "), step["require"].first["inbox_item"]] }
      expect(survey.last).not_to eq(report.last)
      expect(report.first).to include("workspace inbox done --dedupe-key #{survey.last}").and include("--dedupe-key #{report.last} --reopen")
    end
  end

  describe "bugfix" do
    let(:definition) { catalog.find("bugfix") }
    let(:data) { definition.to_h }
    let(:by_id) { data["steps"].to_h { |step| [step["id"], step] } }

    it "stands alone at version 1, is marked experimental and validates with no warnings" do
      expect(data["steps"].map { |step| step["id"] }).to eq(%w[reproduce fix verify])
      expect(data).not_to have_key("extends")
      expect(data["version"]).to eq(1)
      expect(data["use_when"]).to start_with("Experimental:").and include("commands.test_files").and include("step expect-fail")
      expect(definition.warnings).to eq([])
    end

    it "proves the new test fails with failure.txt's text before the reproduce gate, with the checker timing out first" do
      reproduce = by_id["reproduce"]
      expect(reproduce).to include("guard" => "config", "gate" => "approve", "produces" => %w[repro.md failure.txt])
      exec = reproduce["require"].first
      expect(exec["exec"]).to eq(%w[workspace step expect-fail --timeout 840 --match-file {{artifacts}}/failure.txt -- {{changed.tests}}])
      expect(exec["timeout"]).to eq(900.0)
    end

    it "requires a commit and the tests to fix, lint to verify, and loops verify back to fix three times within the caps" do
      expect(by_id["fix"]["require"]).to eq([{"commits" => 1}])
      expect(by_id["fix"]["status"]).to include("command" => "test")
      expect(by_id["verify"]["status"]).to include("command" => "test")
      expect(by_id["verify"]["require"]).to eq([{"command" => "lint", "optional" => true}])
      expect(by_id["verify"]["uses"]).to eq([])
      expect(by_id["verify"]["on_fail"]).to include("goto" => "fix", "max" => 3, "context" => "continue", "log_tail" => 40)
      expect(by_id.transform_values { |step| Workspace::WorkflowDefinition.step_max_attempts(step) }).to eq("reproduce" => 4, "fix" => 6, "verify" => 5)
      expect(data["max_attempts"]).to eq(15)
    end

    it "keeps one untracked test for the proof: reproduce clears an earlier attempt's tests and fix drops strays" do
      reproduce, fix = %w[reproduce fix].map { |id| by_id[id]["prompt"].gsub(/\s+/, " ") }
      expect(reproduce).to include("runs every untracked file that matches commands.test_files").and include("exactly one new test file is untracked")
      expect(fix).to include("delete the test files an earlier reproduce attempt of this run wrote").and include("leave any other")
    end

    it "denies the agent changing the config the proofs read the test command from" do
      expect(data["deny"]).to eq(["workspace config set*", "workspace config unset*"])
    end
  end
end
