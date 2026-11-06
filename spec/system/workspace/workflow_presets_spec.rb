require "spec_helper"
require "tmpdir"

RSpec.describe "the shipped workflow presets" do
  let(:config) { Workspace::Config.new }
  let(:dir) { Dir.mktmpdir }
  let(:catalog) { Workspace::WorkflowCatalog.new(config: config) }
  let(:ids) { Dir[File.join(config.builtin_workflows_dir, "*.yml")].map { |path| File.basename(path, ".yml") }.sort }

  before { allow(config).to receive(:workflows_dir).and_return(File.join(dir, "none")) }
  after { FileUtils.remove_entry(dir) }

  it "parses every file in lib/workflows" do
    expect(ids).to include("rpiv", "rpiv-auto-approve", "pr-feedback", "investigate", "explore")
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
      "explore" => %w[survey report],
      "pr-feedback" => %w[triage fix],
      "investigate" => %w[diagnose fix],
      "rpiv" => [],
      "rpiv-auto-approve" => []
    }
    expect(expected.keys.sort).to eq(ids)
    expected.each do |id, step_ids|
      proven = catalog.find(id).to_h["steps"].select { |step| Array(step["require"]).any? { |entry| entry.key?("inbox_item") } }
      expect(proven.map { |step| step["id"] }).to eq(step_ids), id
    end
  end

  describe "rpiv and rpiv-auto-approve" do
    %w[rpiv rpiv-auto-approve].each do |id|
      it "#{id} requires a commit and a done plan to implement, and a passing lint to verify" do
        steps = catalog.find(id).to_h["steps"]
        by_id = ->(name) { steps.find { |step| step["id"] == name } }

        expect(by_id.call("implement")["require"]).to eq([{"commits" => 1}, {"plan_status" => "done"}])
        expect(by_id.call("verify")["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(by_id.call("implement")["prompt"]).to include("then set the plan's\n`status: done`")
      end
    end

    it "guards research and plan (and the reviewer steps and plan_review in rpiv-auto-approve) as unchanged, and nothing else" do
      %w[rpiv rpiv-auto-approve].each do |id|
        guards = catalog.find(id).to_h["steps"].to_h { |step| [step["id"], step["guard"]] }
        expect(guards.select { |_, guard| guard }).to eq({"research" => "unchanged", "plan" => "unchanged"}.merge((id == "rpiv-auto-approve") ? {
          "review_supportive" => "unchanged", "review_skeptical" => "unchanged", "review_implementer" => "unchanged", "plan_review" => "unchanged"
        } : {})), id
      end
    end

    %w[rpiv rpiv-auto-approve].each do |id|
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
        engine = Workspace::WorkflowEngine.new(store: store,
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
      %w[rpiv rpiv-auto-approve].each do |id|
        verify = catalog.find(id).to_h["steps"].find { |step| step["id"] == "verify" }
        expect(verify["require"]).to eq([{"command" => "lint", "optional" => true}])
        expect(verify["prompt"]).to include("lint command, when it has one, must pass")
      end
    end

    it "tells implement never to amend or rebase, and to commit empty when nothing needs changing" do
      %w[rpiv rpiv-auto-approve].each do |id|
        implement = catalog.find(id).to_h["steps"].find { |step| step["id"] == "implement" }
        expect(implement["prompt"].gsub(/\s+/, " ")).to include("never amend or rebase").and include("git commit --allow-empty -m '<why>'")
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

    it "refuses a topic with a space or a placeholder through the engine's input check, and takes a slug or none" do
      data = catalog.find("explore").to_h
      check = ->(topic) { Workspace::WorkflowEngine.allocate.send(:check_inputs, data, {"task" => "q", "topic" => topic}) }
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
end
