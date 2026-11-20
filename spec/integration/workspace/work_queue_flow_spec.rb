require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

# The work queue's done-when flow through `CLI::WorkQueue` over the real `Commands::WorkQueue`, store, history,
# advance pass and starters, and a real `Commands::Workflow` over a real engine and run store in a temporary
# directory. The panes, guard, check and composer are fakes and `WorkflowStart` and `Go` are doubles, so nothing
# starts a process. The queue's checkout is named with `--name` from a directory that is not in it.
RSpec.describe "a work queue from add to history over real runs" do
  around do |example|
    Dir.mktmpdir("wq-flow") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after { EventKeysCheck.verify!(runs_dir, archive_dir) }

  # The engine's panes, plus the one pane `workflow run` picks when it is given none.
  let(:panes_class) do
    Class.new(FakeWorkflowPanes) do
      def default_pane(_workspace, start_daemon: true) = "%5"
    end
  end

  let(:workspace) { "app.worktree-x" }
  let(:worktree) { File.join(@dir, "app") }
  let(:elsewhere) { File.join(@dir, "elsewhere") }
  let(:state_dir) { File.join(@dir, "state") }
  let(:runs_dir) { File.join(state_dir, ".workflows", "runs") }
  let(:archive_dir) { File.join(state_dir, ".workflows", "archive") }
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:now) { [Time.utc(2026, 11, 20, 12, 0, 0)] }
  let(:clock) { -> { now.first } }
  # The queue classes read time as `Time` does, through `#now`.
  let(:queue_clock) { Struct.new(:times) { def now = times.first }.new(now) }
  let(:run_ids) { %w[wr_1 wr_2 wr_3] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: clock, id_generator: -> { run_ids.shift }) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: File.join(state_dir, "locks", "ns")}) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { panes_class.new }
  let(:check_results) { [] }
  let(:checker) { ->(**) { check_results.shift || {exit_code: 0, timed_out: false} } }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, check: nil, config_change: nil) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir}) }
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: notes) }
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: checker,
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: "bin/test", lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note, env_stopper: ->(**) {},
      workspace_known: ->(_name) { false }, event_log: instance_double(Workspace::EventLog, record: nil),
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), clock: clock)
  end

  let(:definitions) do
    {
      "gated" => <<~YAML,
        inputs:
          task: {description: What the run is about., required: true}
        steps:
          plan:
            prompt: Plan {{inputs.task}}.
            gate: approve
          build:
            prompt: Build {{inputs.task}}.
      YAML
      "checked" => <<~YAML
        inputs:
          task: {description: What the run is about., required: true}
        steps:
          verify:
            prompt: Test {{inputs.task}}.
            status: {command: test, timeout: 5m}
      YAML
    }
  end
  let(:catalog) do
    texts = definitions
    Class.new do
      define_method(:find) do |id, project: nil|
        Workspace::WorkflowDefinition.parse(texts.fetch(id), id: id, source: "global", path: "/defs/#{id}.yml")
      end
    end.new
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:gate) { Workspace::OutputGate.new(out) }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:status) do
    Workspace::WorkflowStatus.new(store: store, panes: panes, snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { instance_double(Workspace::AskStore, list: []) },
      gate_note: gate_note, clock: clock)
  end
  let(:workflow_command) do
    Workspace::Commands::Workflow.new(lint: nil, catalog: catalog, engine: engine, status: status, store: store, panes: panes, files: nil, run_files: nil,
      process_tree: nil, lock_holder: liveness, clock: clock, output: gate, error_output: err)
  end
  let(:workflow_start) { instance_double(Workspace::Commands::WorkflowStart, locate_project: {project_workspace: "app"}, check_agent!: nil) }
  let(:go) { instance_double(Workspace::Commands::Go) }
  let(:starters) do
    Workspace::WorkQueueStarters.new(workflow: workflow_command, workflow_start: workflow_start, go: go,
      workflow_project: instance_double(Workspace::WorkflowProject, for_directory: nil), catalog: catalog)
  end
  let(:lock_holder) { instance_double(Workspace::LockHolder, holder_alive?: false, start_time: "start-1") }
  let(:history_for) { ->(name) { Workspace::WorkQueueHistory.new(path: File.join(state_dir, name, "work-queue-history.jsonl"), clock: queue_clock) } }
  let(:item_ids) { %w[aaaa1111 bbbb2222 cccc3333] }
  let(:store_for) do
    ids = item_ids
    ->(name) { Workspace::WorkQueueStore.new(path: File.join(state_dir, name, "work-queue.json"), history: history_for.call(name), clock: queue_clock, id_generator: -> { ids.shift }) }
  end
  let(:advance) { Workspace::WorkQueueAdvance.new(store_factory: store_for, run_store: store, starters: starters.to_h, lock_holder: lock_holder, status: status, clock: queue_clock) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:checkout) do
    Workspace::WorkspaceCheckout.new(git: git, project_config: project_config, project_detector: instance_double(Workspace::ProjectDetector, detect: nil))
  end
  let(:queue_command) do
    Workspace::Commands::WorkQueue.new(store_factory: store_for, history_factory: history_for, advance: advance, decisions: engine, run_store: store,
      checkout: checkout, go: go, status_scope: instance_double(Workspace::StatusScope), clock: queue_clock, working_dir: elsewhere, output: gate, error_output: err)
  end
  let(:cli) { Workspace::CLI::WorkQueue.new(work_queue_command: queue_command, common: Workspace::CLI::Common.new) }

  before do
    FileUtils.mkdir_p([File.join(worktree, ".git"), elsewhere, notes_dir, state_dir])
    allow(project_config).to receive(:project_root_for).with(workspace).and_return(worktree)
    allow(snapshot_client).to receive(:fetch) { {"panes" => panes.rows.values} }
  end

  # Runs one `wq` command line for the workspace; returns what it printed and its exit status.
  def wq(*args)
    out.truncate(0)
    out.rewind
    invocation = Workspace::CLI::Invocation.new(output: gate, error_output: err, exit_handler: FakeExitHandler, help_asked: false, quiet: args.include?("--json"), env: {})
    code = begin
      cli.call("wq", [*args, "--name", workspace], invocation)
      0
    rescue FakeSystemExit => e
      e.status
    end
    [out.string, code]
  end

  # The same line with --json: its document, after checking it exited 0 unless +exit+ says otherwise.
  def wq_json(*args, exit: 0)
    text, code = wq(*args, "--json")
    expect(code).to eq(exit), "wq #{args.join(" ")} exited #{code}: #{text}"
    JSON.parse(text)
  end

  def queue = wq_json("list").fetch("queues").first

  def run(id) = stored_run(store, id)

  def turn_ended(id)
    now[0] += 60
    engine.turn_ended(id, actor: "agent", pane: "%5")
  end

  def add_two
    first = wq_json("add", "workflow", "gated", "--prompt", "First task")
    second = wq_json("add", "workflow", "gated", "--input", "task=Second task")
    [first.dig("results", 0, "id"), second.dig("results", 0, "id")]
  end

  it "adds two items, reorders them, and runs each through its gate to history, by hand and in JSON" do
    first = wq_json("add", "workflow", "gated", "--prompt", "First task")
    expect(first).to include("action" => "work-queue add", "status" => "ok", "queue" => workspace)
    expect(first["results"]).to eq([{"workspace" => workspace, "outcome" => "added", "id" => "aaaa1111", "position" => 1, "kind" => "workflow"}])
    second = wq_json("add", "workflow", "gated", "--input", "task=Second task")
    expect(second.dig("results", 0)).to include("outcome" => "added", "id" => "bbbb2222", "position" => 2)

    text, code = wq("list")
    expect(code).to eq(0)
    expect(text).to include("aaaa1111", "bbbb2222")
    expect(queue).to include("workspace" => workspace, "state" => "off")
    expect(queue["items"].map { |item| item["id"] }).to eq(%w[aaaa1111 bbbb2222])
    expect(queue["items"].map { |item| item.values_at("position", "state", "what") }).to eq([[1, "queued", "gated First task"], [2, "queued", "gated"]])
    expect(wq_json("show", "bbbb2222")["item"]).to include("spec" => {"workflow" => "gated", "inputs" => {"task" => "Second task"}}, "position" => 2)

    moved = wq_json("move", "bbbb2222", "--top")
    expect(moved.dig("results", 0)).to include("outcome" => "moved", "id" => "bbbb2222", "position" => 1)
    expect(queue["items"].map { |item| item["id"] }).to eq(%w[bbbb2222 aaaa1111])

    expect(wq_json("enable").dig("results", 0, "outcome")).to eq("enabled")
    expect(queue["state"]).to eq("on")

    started = wq_json("advance")
    expect(started["status"]).to eq("ok")
    expect(started["results"]).to contain_exactly(include("outcome" => "started", "id" => "bbbb2222", "run_id" => "wr_1"))
    expect(run("wr_1")).to include("workspace" => workspace, "worktree" => worktree, "workflow" => "gated", "current" => "plan")
    expect(run("wr_1")["inputs"]).to include("task" => "Second task")
    expect(run("wr_1")["note"]).to match(/\AStarted by work-queue item bbbb2222 \(claim \h+\)\z/)
    active = wq_json("active")
    expect(active["item"]).to include("id" => "bbbb2222", "state" => "active", "run_id" => "wr_1", "position" => 1)
    expect(active["waiting_on"]).to include("run_id" => "wr_1", "step" => "plan")

    expect(turn_ended("wr_1")["reason"]).to include("code" => "waiting_you", "details" => include("kind" => "gate"))
    held = wq_json("advance")
    expect(held["results"]).to contain_exactly(include("outcome" => "held", "id" => "bbbb2222", "reason" => "gate", "run_id" => "wr_1"))
    expect(held.dig("results", 0, "next_actions")).to include(include("action" => "workflow approve", "args" => ["wr_1"]))
    expect(queue["items"].first).to include("id" => "bbbb2222", "state" => "held")

    engine.approve("wr_1", actor: "person")
    expect(turn_ended("wr_1")["state"]).to eq("completed")

    passed = wq_json("advance")
    expect(passed["status"]).to eq("ok")
    expect(passed["results"].map { |row| row.values_at("outcome", "id", "run_id") }).to eq([["succeeded", "bbbb2222", "wr_1"], ["started", "aaaa1111", "wr_2"]])
    # The item queued with only --prompt gets it as the definition's task input.
    expect(run("wr_2")["inputs"]).to include("task" => "First task")
    expect(queue["items"].map { |item| item.values_at("id", "state") }).to eq([%w[aaaa1111 active]])

    expect(turn_ended("wr_2")["reason"]).to include("code" => "waiting_you", "details" => include("kind" => "gate"))
    engine.approve("wr_2", actor: "person")
    expect(turn_ended("wr_2")["state"]).to eq("completed")
    done = wq_json("advance")
    expect(done["results"].map { |row| row.values_at("outcome", "id", "reason") }).to eq([["succeeded", "aaaa1111", nil], ["unchanged", nil, "empty"]])

    text, code = wq("history", "list")
    expect(code).to eq(0)
    expect(text).to include("aaaa1111", "bbbb2222")
    entries = wq_json("history", "list").fetch("entries")
    expect(entries.map { |entry| entry.values_at("id", "outcome") }).to eq([%w[bbbb2222 succeeded], %w[aaaa1111 succeeded]])
    expect(entries.map { |entry| entry.dig("result", "run_id") }).to eq(%w[wr_1 wr_2])
    expect(queue["items"]).to be_empty
  end

  it "pauses the queue when its running item is cancelled, and starts the next one after resume" do
    add_two
    wq_json("enable")
    expect(wq_json("advance").dig("results", 0)).to include("outcome" => "started", "id" => "aaaa1111", "run_id" => "wr_1")

    cancelled = wq_json("cancel")
    expect(cancelled.dig("results", 0)).to include("outcome" => "cancelled", "id" => "aaaa1111", "run_id" => "wr_1")
    expect(run("wr_1")["state"]).to eq("cancelled")
    expect(queue).to include("state" => "paused", "paused_reason" => "cancelled")
    expect(queue["items"].map { |item| item.values_at("id", "state") }).to eq([%w[bbbb2222 queued]])
    expect(wq_json("history", "show", "aaaa1111")["entry"]).to include("outcome" => "cancelled")

    refused = wq_json("advance")
    expect(refused["results"]).to contain_exactly(include("outcome" => "unchanged", "reason" => "paused"))
    expect(refused.dig("results", 0, "next_actions")).to include(include("action" => "work-queue resume"))

    wq_json("resume")
    expect(wq_json("advance").dig("results", 0)).to include("outcome" => "started", "id" => "bbbb2222", "run_id" => "wr_2")
  end

  it "holds and pauses on a failed check, finishes the item once workflow resume completes its run, and starts the next after wq resume" do
    wq_json("add", "workflow", "checked", "--prompt", "Checked task")
    wq_json("add", "workflow", "gated", "--prompt", "Next task")
    wq_json("enable")
    expect(wq_json("advance").dig("results", 0)).to include("outcome" => "started", "id" => "aaaa1111", "run_id" => "wr_1")

    check_results << {exit_code: 1, timed_out: false}
    expect(turn_ended("wr_1")["reason"]).to include("code" => "failed_check")
    held = wq_json("advance")
    expect(held["results"]).to contain_exactly(include("outcome" => "held", "id" => "aaaa1111", "reason" => "failed_check", "run_id" => "wr_1"))
    expect(held.dig("results", 0, "next_actions").map { |action| action["action"] }).to eq(["workflow status", "work-queue skip"])
    expect(queue).to include("state" => "paused", "paused_reason" => "failed_check")

    engine.resume("wr_1", actor: "person")
    expect(turn_ended("wr_1")["state"]).to eq("completed")

    finished = wq_json("advance")
    expect(finished["results"].map { |row| row.values_at("outcome", "id", "reason") }).to eq([["succeeded", "aaaa1111", nil], ["unchanged", nil, "paused"]])
    expect(wq_json("history", "list")["entries"].map { |entry| entry.values_at("id", "outcome") }).to eq([%w[aaaa1111 succeeded]])

    wq_json("resume")
    expect(queue["state"]).to eq("on")
    expect(wq_json("advance").dig("results", 0)).to include("outcome" => "started", "id" => "bbbb2222", "run_id" => "wr_2")
  end
end
