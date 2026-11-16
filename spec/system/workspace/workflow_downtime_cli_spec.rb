require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

# `workflow status --json` through the real `Workspace.build_cli` wiring cuts the recorded downtime from a run's
# `used`, so a status built without the shared downtime object fails here. The run is written by a real engine over
# the state directory the CLI reads. System tier: `build_cli` runs git while it is built.
RSpec.describe "workflow status --json over recorded downtime" do
  around do |example|
    Dir.mktmpdir("wf-downtime-cli") do |dir|
      @dir = File.realpath(dir)
      old = ENV["XDG_STATE_HOME"]
      ENV["XDG_STATE_HOME"] = File.join(@dir, "state")
      example.run
    ensure
      ENV["XDG_STATE_HOME"] = old
    end
  end

  let(:config) { Workspace::Config.new }
  let(:started) { Time.now.utc - 10 * 3600 }
  let(:now) { [started] }
  let(:ids) { %w[wr_1] }
  let(:store) do
    Workspace::WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift })
  end
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) do
    Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(config.workflow_runs_dir), wall_clock: -> { now.first.to_i })
  end
  let(:git) do
    Class.new do
      def worktree_branch(_path) = "feature/x"

      def common_dir_from_files(_path) = nil
    end.new
  end
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: FakeWorkflowPanes.new,
      checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "true", lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40),
      excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {},
      workspace_known: ->(_name) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: -> { now.first })
  end
  let(:definition) do
    Workspace::WorkflowDefinition.parse(<<~YAML, id: "flow", source: "global", path: "/defs/flow.yml")
      timeout: 8h
      steps:
        build:
          prompt: Build it.
    YAML
  end

  before do
    worktree = File.join(@dir, "app")
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: File.join(@dir, "state", "locks", "ns"))
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
    now[0] = started + 10 * 3600
    engine.cancel("wr_1", actor: "person")
    File.write(config.workflow_downtime_path,
      JSON.generate("from" => (started + 1800).iso8601(3), "to" => (started + 1800 + 9 * 3600).iso8601(3)) + "\n")
    File.write(config.workflow_heartbeat_path, Time.now.utc.iso8601(3))
  end

  it "reads about 1h used of the 8h timeout for a run that spanned 10h with 9h of downtime" do
    output = StringIO.new
    cli = Workspace.build_cli(output: output, error_output: StringIO.new, input: StringIO.new, env: {}, exit_handler: FakeExitHandler)

    cli.run(["workflow", "status", "--all", "--json"])

    run = JSON.parse(output.string)["runs"].find { |each| each["id"] == "wr_1" }
    expect(run["deadline"]).to include("limit" => 8 * 3600, "spent" => false)
    expect(run["deadline"]["used"]).to be_within(1).of(3600)
  end
end
