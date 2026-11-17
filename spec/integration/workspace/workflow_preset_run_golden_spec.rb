require "spec_helper"
require "tmpdir"
require "digest"
require "fileutils"
require "json"

# Pins the run file and events file a real WorkflowEngine leaves for two shipped presets, parsed as shipped, over real
# require proofs and a real inbox (the setup of the e2e spec; the guard, check and panes are fakes, so no process
# starts): pr-feedback's approved note with its sha256, and investigate's diagnose step with and without the inbox
# item it requires. The tmpdir realpath and each prompt_sha256 become tokens. Regenerate a fixture deliberately with
# GOLDEN_UPDATE=1.
RSpec.describe Workspace::WorkflowEngine, "golden preset run files" do
  around do |example|
    Dir.mktmpdir("wf-preset-golden") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_run_golden") }
  let(:workspace) { "app.worktree-x" }
  let(:worktree) { File.join(@dir, "app") }
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:clock) { -> { now.first } }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: clock, id_generator: -> { "wr_1" }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: lock_dir}) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:checker) { ->(**) { {exit_code: 0, timed_out: false} } }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) do
    instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, check: nil, config_change: nil, commits_since: 1, round_snapshot: {"head" => "1" * 40, "tree_sha256" => "t" * 64}, round_check: nil)
  end
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir})) }
  let(:inbox) { Workspace::InboxStore.new(path: File.join(@dir, "state", ".inbox", "#{workspace}.json"), clock: clock) }
  let(:require_check) do
    Workspace::WorkflowRequire.new(guard: guard, notes_dir_of: ->(_name) { notes_dir }, commands_config: commands_config, checker: checker, inbox_for: ->(_name) { inbox })
  end
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note,
      env_stopper: ->(**) {}, workspace_known: ->(_name) { false }, task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}),
      require_check: require_check, inbox_for: ->(_name) { inbox }, clock: clock)
  end

  before { FileUtils.mkdir_p([File.join(worktree, ".git"), notes_dir]) }

  def definition(id)
    path = File.join(PROJECT_ROOT, "lib", "workflows", "#{id}.yml")
    Workspace::WorkflowDefinition.parse(File.read(path), id: id, source: "preset", path: path)
  end

  def begin_run(id, inputs)
    engine.start(actor: "person", definition: definition(id), workspace: workspace, worktree: worktree, inputs: inputs, pane: "%5")
  end

  def artifact(name, text)
    path = File.join(worktree, ".workflow", "wr_1", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.utime(now.first, now.first, path)
  end

  def turn_ended
    now[0] += 60
    engine.turn_ended("wr_1", actor: "agent", pane: "%5")
  end

  def item(key) = inbox.upsert({"type" => "review_request", "title" => "Report", "dedupe_key" => key}, reopen: true)

  def tokens(text)
    text.gsub(@dir, "<TMP>").gsub(PROJECT_ROOT, "<ROOT>").gsub(/("prompt_sha256": )"[0-9a-f]{64}"/, '\1"<PROMPT_SHA>"')
  end

  def golden(name, run_id = "wr_1")
    file = [runs_dir, archive_dir].map { |dir| File.join(dir, "#{run_id}.json") }.find { |path| File.exist?(path) }
    run = JSON.pretty_generate(JSON.parse(File.read(file))) + "\n"
    events = File.readlines(File.join(File.dirname(file), "#{run_id}.events.jsonl")).map { |line| JSON.pretty_generate(JSON.parse(line)) }.join("\n") + "\n"
    {"#{name}.json" => tokens(run), "#{name}.events.json" => tokens(events)}.each do |file, text|
      path = File.join(fixtures, file)
      File.write(path, text) if ENV["GOLDEN_UPDATE"]
      expect(File.read(path)).to eq(text)
    end
  end

  describe "pr-feedback's triage gate" do
    let(:note_text) { "### F1\nFix the typo.\n" }
    let(:note_sha) { Digest::SHA256.hexdigest(note_text) }

    def triaged
      begin_run("pr-feedback", {"task" => "PR 7 feedback", "pr" => "7"})
      File.write(File.join(notes_dir, "2026-10-04-pr-7-feedback.md"), note_text)
      artifact("triage.md", "note: 2026-10-04-pr-7-feedback.md\n1 fix\n")
      now[0] += 60
      item("pr-feedback:wr_1")
      turn_ended
    end

    it "records the approved note's path and sha256 on the gate and in the gate_approved event" do
      expect(triaged).to include("state" => "waiting")

      run = engine.approve("wr_1", actor: "person", note_sha256: note_sha)

      expect(run).to include("current" => "fix")
      expect(run["steps"]["triage"]["gate"]["file"]).to include("sha256" => note_sha)
      golden("pr-feedback-approved-note")
    end

    it "refuses a hash that is not the note's and leaves the gate waiting" do
      triaged

      expect { engine.approve("wr_1", actor: "person", note_sha256: "0" * 64) }
        .to raise_error(Workspace::Error) { |error| expect(error.code).to eq("stale_revision") }

      run = stored_run(store, "wr_1")
      expect(run).to include("state" => "waiting", "current" => "triage")
      expect(run["steps"]["triage"]["gate"]).to include("state" => "waiting")
      expect(File.read(store.events_path("wr_1"))).not_to include("gate_approved")
    end
  end

  describe "investigate's diagnose step" do
    def diagnosed
      begin_run("investigate", {"task" => "The suite is red"})
      artifact("repro.md", "reproduced: yes\n")
      turn_ended
      artifact("diagnosis.md", "note: bug-investigation-wr-1.md\n")
      now[0] += 60
    end

    it "passes and waits at its gate once the report's inbox item was updated during the attempt" do
      diagnosed
      item("investigate:wr_1")

      run = turn_ended

      expect(run).to include("state" => "waiting", "current" => "diagnose")
      expect(run["steps"]["diagnose"]).to include("state" => "passed", "gate" => include("state" => "waiting"))
      golden("investigate-inbox-item")
    end

    it "does not pass without the inbox item, and says which proof failed" do
      diagnosed

      run = turn_ended

      stored = stored_run(store, "wr_1")
      expect(run["steps"]["diagnose"]).to include("state" => "failed")
      expect(stored["steps"]["diagnose"]["attempts"].last).to include("outcome" => "failed", "code" => "require_inbox_item")
      golden("investigate-inbox-item-missing")
    end
  end
end
