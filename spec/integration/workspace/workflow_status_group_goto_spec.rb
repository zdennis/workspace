require "spec_helper"
require "tmpdir"

# What `workflow status`, `workflow needs-me` and `workflow sweep` show of a run whose fan_out group owes its `on_fail`
# goto, with the run built by the real engine. FakeWorkflowPanes stands in for tmux and the agent daemon, so nothing
# starts a process.
RSpec.describe Workspace::WorkflowStatus, "with a fan_out group's owed goto" do
  around do |example|
    Dir.mktmpdir("wf-group-goto-status") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after { EventKeysCheck.verify!(runs_dir, archive_dir) }

  let(:worktree) { File.join(@dir, "app") }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:archive_dir) { File.join(@dir, "state", ".workflows", "archive") }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { "wr_1" }) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: RunFileLiveness.new(runs_dir), wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:interrupter) { ->(*) {} }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
      checker: checker,
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes),
      interrupter: interrupter, clock: -> { now.first })
  end
  # Each `status:` command named in failing_checks fails, writing a log of three lines that name it.
  let(:failing_checks) { [] }
  let(:checker) do
    lambda do |command:, log:, **|
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, (1..3).map { |n| "#{command} line #{n}" }.join("\n") + "\n")
      {exit_code: failing_checks.include?(command) ? 1 : 0, timed_out: false}
    end
  end
  let(:sweep) do
    reviews = Workspace::WorkflowReviewSweep.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { now.first })
    Workspace::WorkflowSweep.new(store: store, engine: engine, panes: panes, interrupter: interrupter, reviews: reviews,
      infra_retry_max: -> { 2 }, clock: -> { now.first })
  end

  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient, fetch: {"panes" => [{"pane_id" => "%5", "kind" => "claude", "state" => "working"}]}) }
  let(:ask_store) { instance_double(Workspace::AskStore, list: []) }
  let(:notes_status) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  subject(:status) do
    described_class.new(store: store, panes: panes, snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { ask_store },
      gate_note: Workspace::WorkflowGateNote.new(notes: notes_status), clock: -> { now.first },
      recovery_entry: ->(_workspace, _pane) {}, live_usage: instance_double(Workspace::WorkflowLiveUsage, reading: nil))
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def reviewers = %w[r1 r2 r3]

  # plan, a group `reviews` of three reviewers (id to extra YAML lines) with the group's on_fail, then tally.
  # max_attempts 9 is what `on_fail_exceeds_max_attempts` suggests for this shape.
  def flow(extra = {}, on_fail: "{goto: plan, max: 2}", max_attempts: 9)
    body = reviewers.map do |id|
      "      #{id}:\n        prompt: Review #{id}.\n        produces: [#{id}.md]\n#{extra[id].to_s.lines.map { |line| "        #{line}" }.join}"
    end.join
    yaml = "max_attempts: #{max_attempts}\nsteps:\n  plan:\n    prompt: Plan.\n    produces: [plan.md]\n" \
      "  reviews:\n    checkout: shared\n    on_fail: #{on_fail}\n    fan_out:\n#{body}" \
      "  tally:\n    prompt: Tally.\n    produces: [tally.md]\n"
    Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")
  end

  def start(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def run = stored_run(store, "wr_1")

  def state(step) = run["steps"][step]["state"]

  def attempts(step) = run["steps"][step]["attempts"]

  def pane(step) = run["steps"][step]["pane"] || "%5"

  def write(step)
    path = File.join(worktree, ".workflow", "wr_1", "#{step}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
  end

  def pass(step)
    write(step)
    engine.turn_ended("wr_1", actor: "agent", pane: pane(step), step: step)
  end

  def fail(step)
    write(step)
    engine.report("wr_1", actor: "agent", status: "fail", summary: "#{step} broke", step: step)
    engine.turn_ended("wr_1", actor: "agent", pane: pane(step), step: step)
  end

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def typed(type) = events.select { |line| line["type"] == type }

  def dispatched = typed("step_dispatching").map { |line| [line["step"], line["cause"]] }

  def round(failing: [])
    passing = reviewers - failing
    failing.each { |id| fail(id) }
    passing.each { |id| pass(id) }
  end

  def row = status.run("wr_1")["runs"].first

  def step(id) = row["steps"].find { |each| each["id"] == id }

  def looping = reviewers.select { |id| step(id)["looping"] }

  def moving = reviewers.select { |id| step(id)["moving"] }

  def needs_me = Workspace::WorkflowNeedsMe.new(clock: -> { now.first }).rows([row])

  def backoff_flow = flow({}, on_fail: "{goto: plan, max: 2, backoff: 1m}")

  it "reads every failed sibling as looping and the group as draining while the move waits out its backoff" do
    start(backoff_flow)
    pass("plan")
    fail("r1")
    fail("r3")
    pass("r2")

    expect(run["steps"]["r1"]["pending_move"]).to include("group" => "reviews")
    expect(run["steps"]["r3"]).not_to have_key("pending_move")
    expect(looping).to eq(%w[r1 r3])
    expect(row["groups"]["reviews"]["state"]).to eq("draining")
    expect(step("r2")).to include("looping" => false)
    expect(needs_me).to eq([])
  end

  it "leaves a run waiting out the group move's backoff to the tick: a sweep records nothing against it and starts nothing" do
    start(backoff_flow)
    pass("plan")
    fail("r1")
    pass("r2")
    pass("r3")

    before = run
    rows = sweep.call

    expect(rows.map { |each| [each["step"], each["outcome"], each["reason"]] }).to eq([%w[r1 nothing not_running]])
    expect(run.slice("state", "current", "loops")).to eq(before.slice("state", "current", "loops"))
    expect(run["steps"].values.map { |each| each["sweep"] }.compact).to eq([])
    expect(attempts("plan").size).to eq(1)

    now[0] += 61
    engine.tick("wr_1", actor: "daemon")
    expect(dispatched.last).to eq(%w[plan loop])
  end

  it "stops reading the failed siblings as looping once the move is applied, as a sibling's own applied move does" do
    start
    pass("plan")
    fail("r1")
    fail("r3")
    pass("r2")

    expect(run).to include("current" => "plan")
    expect(run["steps"]["r1"]).not_to have_key("pending_move")
    expect(looping).to eq([])
    expect(moving).to eq([])
    expect(row["groups"]["reviews"]["state"]).not_to eq("draining")
  end

  it "reads a blocked group move as a group that is not draining, no sibling looping, and a run that needs a person" do
    start(flow({"r1" => "on_fail: stop\n"}))
    pass("plan")
    fail("r2")
    fail("r1")
    pass("r3")

    expect(run).to include("state" => "waiting")
    expect(row["groups"]["reviews"]["state"]).to eq("failed")
    expect(looping).to eq([])
    expect(moving).to eq([])
    expect(needs_me.map { |each| [each["run"], each["code"]] }).to include(%w[wr_1 failed_check])
  end

  it "reads a group as failed when a sibling's own move was granted but its max_attempts is spent, and the run needs a person" do
    start(flow({"r3" => "on_fail: {goto: r1, max: 2}\nmax_attempts: 1\n"}))
    pass("plan")
    fail("r3")
    pass("r1")
    pass("r2")
    pass("r1")

    expect(run).to include("state" => "waiting")
    expect(row["groups"]["reviews"]["state"]).to eq("failed")
    expect(looping).to eq([])
    expect(needs_me.map { |each| [each["step"], each["code"]] }).to include(%w[r3 failed_check])
  end
end
