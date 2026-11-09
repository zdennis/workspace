require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

# Pins the run file and the events file a real WorkflowEngine leaves after a park, a resume, a cancel,
# a killed workspace and a sweep stall, with a stubbed guard, fixed run ids and a fixed clock (the
# setup of the system engine spec, with no git process). The tmpdir realpath, each prompt_sha256 and the random park id
# become tokens. Regenerate a fixture deliberately with GOLDEN_UPDATE=1.
RSpec.describe Workspace::WorkflowEngine, "golden run files" do
  around do |example|
    Dir.mktmpdir("wf-run-golden") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_run_golden") }
  let(:worktree) { File.join(@dir, "app") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:ids) { %w[wr_1 wr_2] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  # The engine only asks the checkout's branch and whether it is a git checkout.
  let(:git) do
    Class.new do
      def worktree_branch(_path) = "feature/x"

      def common_dir_from_files(_path) = nil
    end.new
  end
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: notes) }
  let(:engine) do
    described_class.new(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
      checker: ->(**) { {exit_code: 0, timed_out: false} }, commands_config: commands_config, lineage: lineage, git: git, guard: guard,
      excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, env_stopper: ->(**) {}, workspace_known: ->(_name) { false },
      event_log: instance_double(Workspace::EventLog, record: nil), task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}),
      clock: -> { now.first })
  end
  let(:flow) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      stall: 20m
      steps:
        build:
          prompt: Build it.
          produces: [out.md]
          context: continue
        verify:
          prompt: Verify it.
          context: continue
    YAML
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def begin_run
    engine.start(definition: flow, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def tokens(text)
    text.gsub(@dir, "<TMP>")
      .gsub(/("prompt_sha256": )"[0-9a-f]{64}"/, '\1"<PROMPT_SHA>"')
      .gsub(/("id": )"[0-9a-f]{16}"/, '\1"<PARK_ID>"')
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

  it "records a park" do
    begin_run
    engine.turn_ended("wr_1", pane: "%5")
    engine.park("wr_1", note: "later")

    golden("parked")
  end

  it "records a parked resume once it is released" do
    begin_run
    engine.turn_ended("wr_1", pane: "%5")
    id = engine.park("wr_1")["parked"]["id"]
    now[0] += 5
    engine.release_park("wr_1", id)

    golden("park_released")
  end

  it "records a resume of a step whose turn ended without its files" do
    begin_run
    engine.turn_ended("wr_1", pane: "%5")
    now[0] += 5
    engine.resume("wr_1", note: "again")

    golden("resumed")
  end

  it "records a cancel" do
    begin_run
    engine.cancel("wr_1")

    golden("cancelled")
  end

  it "records a killed workspace" do
    begin_run
    engine.workspace_killed("app.worktree-x")

    golden("workspace_killed")
  end

  it "records a sweep stall" do
    begin_run
    now[0] += 1500
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "idle", "idle_seconds" => 1500, "state_since" => now.first.utc.iso8601}
    sweep = Workspace::WorkflowSweep.new(store: store, engine: engine, panes: panes, interrupter: ->(*) {}, clock: -> { now.first })
    sweep.call

    golden("sweep_stall")
  end
end
