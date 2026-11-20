require "spec_helper"
require "tmpdir"

# A fan_out group's own `on_fail` goto through the real engine over a real run store in a temporary directory: a
# sibling's failure with no `on_fail` of its own is held as one group move per drain, the group drains, the run goes
# back to the goto step once, counted on the edge `GROUP->STEP`, and the group fans out again as new attempts when the
# run comes back to it. A stop in the drain blocks the move and leaves nothing for a tick or a sweep to wake.
# FakeWorkflowPanes stands in for tmux and the agent daemon, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine, "with a fan_out group's on_fail goto" do
  around do |example|
    Dir.mktmpdir("wf-fan-out-group-goto") do |dir|
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
  subject(:engine) do
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

  it "(a) drains the group, goes back to plan once with the group's context, then runs every reviewer again and moves on" do
    start(flow({}, on_fail: "{goto: plan, max: 2, context: fresh}"))
    pass("plan")

    fail("r2")
    expect(run["loops"]).to eq("reviews->plan" => 1)
    expect(run["steps"]["r2"]["pending_move"]).to include("group" => "reviews", "to" => "plan", "count" => 1, "was" => nil, "context" => "fresh")
    expect(attempts("r2").last).to include("group_move" => {"group" => "reviews", "to" => "plan", "count" => 1})
    expect(attempts("r2").last).not_to have_key("move")
    expect(run["state"]).to eq("running")
    expect(state("plan")).to eq("passed")

    pass("r1")
    expect(state("plan")).to eq("passed")
    pass("r3")

    expect(run).to include("state" => "running", "current" => "plan")
    expect(dispatched.last).to eq(%w[plan loop])
    expect(panes.kicks.last).to include(pane: "%5", fresh: true)
    expect(typed("step_looped")).to match([include("from" => "r2", "to" => "plan", "count" => 1, "group" => "reviews")])
    expect(typed("step_retry_started").last).to include("from" => "r2", "to" => "plan", "group" => "reviews", "failed" => ["r2"])
    expect(attempts("plan").last["context"]).to match([a_string_matching(/\AThe reviews group failed .*\(time 1 of 2\)\. Its failed steps: r2 \(its agent reported failure: r2 broke\)\./)])
    expect(run["steps"]["r2"]).not_to have_key("pending_move")

    pass("plan")
    reviewers.each do |id|
      expect(state(id)).to eq("running")
      expect(attempts(id).size).to eq(2)
    end
    round

    expect(run).to include("state" => "running", "current" => "tally")
    expect(state("tally")).to eq("running")
    expect(run["loops"]).to eq("reviews->plan" => 1)
  end

  it "(b) holds one move for two failures in one drain, counted once" do
    start
    pass("plan")

    fail("r1")
    fail("r3")
    expect(run["steps"]["r3"]).not_to have_key("pending_move")
    expect(attempts("r3").last["group_move"]).to eq("group" => "reviews", "joined" => true)
    pass("r2")

    expect(run["loops"]).to eq("reviews->plan" => 1)
    expect(typed("step_looped").size).to eq(1)
    expect(dispatched.count { |each| each == %w[plan loop] }).to eq(1)
    expect(typed("step_retry_started").last).to include("from" => "r1", "failed" => %w[r1 r3])
    reviewers.each { |id| expect(run["steps"][id]).not_to have_key("pending_move") }
  end

  it "(c) stops for a person with failed_check once the reviewers fail past max" do
    start
    pass("plan")
    round(failing: %w[r2])
    pass("plan")
    round(failing: %w[r2])
    expect(run["loops"]).to eq("reviews->plan" => 2)
    pass("plan")

    round(failing: %w[r1 r2])

    expect(run).to include("state" => "waiting", "current" => "r1")
    expect(run["loops"]).to eq("reviews->plan" => 2)
    %w[r1 r2].each do |id|
      expect(run["steps"][id]["reason"]).to include("code" => "failed_check", "details" => include("group" => "reviews", "failed" => %w[r1 r2]))
      expect(run["steps"][id]).not_to have_key("pending_move")
    end
    expect(attempts("plan").size).to eq(3)
    expect(state("tally")).to eq("pending")
    # The stop is the group goto's max (loops 2 of 2): nothing checks the run's cap of 9 at the fan-out, so the third
    # round's reviewers ran as attempts 10 to 12, and the reason names no limit.
    expect(run["steps"]["r2"]["reason"]["details"]).to include("loops" => {"reviews->plan" => 2}, "attempts" => 12, "max_attempts" => 9)
    expect(run["steps"]["r2"]["reason"]["details"]).not_to have_key("limit")
  end

  it "(d) holds the move until its backoff is over, then the tick applies it" do
    start(flow({}, on_fail: "{goto: plan, max: 2, backoff: 1m}"))
    pass("plan")

    fail("r2")
    expect(run["steps"]["r2"]["pending_move"]).to include("group" => "reviews", "until" => (now.first + 60).utc.iso8601)
    pass("r1")
    pass("r3")

    expect(run).to include("state" => "waiting", "current" => "r2")
    expect(run["steps"]["r2"]["reason"]).to include("code" => "retry_backoff", "details" => include("to" => "plan", "group" => "reviews"))
    expect(Workspace::WorkflowTransitions.join_due(run, now.first)).to be_nil
    expect(engine.tick("wr_1", actor: "daemon")).to be_nil
    expect(attempts("plan").size).to eq(1)

    now[0] += 61
    expect(Workspace::WorkflowTransitions.join_due(run, now.first)).to eq("reviews")
    engine.tick("wr_1", actor: "daemon")

    expect(attempts("plan").size).to eq(2)
    expect(dispatched.last).to eq(%w[plan loop])
    expect(run["steps"]["r2"]).not_to have_key("pending_move")
    expect(run["steps"]["r2"]["reason"]).to be_nil
  end

  it "applies the group move ahead of a sibling-local move, which never runs, and runs every reviewer again" do
    start(flow({"r3" => "on_fail: {goto: r1, max: 2}\n"}))
    pass("plan")

    fail("r3")
    expect(run["steps"]["r3"]["pending_move"]).to include("to" => "r1", "edge" => "r3->r1")
    fail("r2")
    pass("r1")

    expect(dispatched.last).to eq(%w[plan loop])
    expect(attempts("r1").size).to eq(1)
    expect(attempts("r3").last["move"]).to include("to" => "r1", "failed" => "group_move")
    expect(run["steps"]["r3"]).not_to have_key("pending_move")
    expect(run["loops"]).to eq("r3->r1" => 1, "reviews->plan" => 1)
    expect(typed("step_retry_started").last).to include("from" => "r2", "failed" => %w[r2 r3])

    pass("plan")
    reviewers.each { |id| expect(attempts(id).size).to eq(2) }
  end

  it "blocks the drain when a failure's cause is one of the group goto's except" do
    failing_checks << "bin/check-r1"
    start(flow({"r1" => "status: bin/check-r1\n"}, on_fail: "{goto: plan, max: 2, except: [reported]}"))
    pass("plan")

    pass("r1")
    expect(run["steps"]["r1"]["pending_move"]).to include("group" => "reviews")
    fail("r2")
    pass("r3")

    expect(run).to include("state" => "waiting", "current" => "r1")
    expect(run["loops"]).to eq({})
    expect(attempts("r1").last["group_move"]).to include("failed" => "sibling_stopped")
    expect(run["steps"]["r2"]["reason"]).to include("code" => "failed_check", "details" => include("cause" => "reported", "failed" => %w[r1 r2]))
    expect(attempts("plan").size).to eq(1)
  end

  it "hands plan the log tail of every failed check under the group's log_tail" do
    failing_checks.push("bin/check-r1", "bin/check-r3")
    start(flow({"r1" => "status: bin/check-r1\n", "r3" => "status: bin/check-r3\n"}, on_fail: "{goto: plan, max: 2, log_tail: 2}"))
    pass("plan")

    round

    context = attempts("plan").last["context"].join("\n")
    expect(context).to match(/Its failed steps: r1 \(.*\); r3 \(.*\)\./)
    expect(context).to include("bin/check-r1 line 3", "bin/check-r3 line 3")
    expect(context).not_to include("bin/check-r1 line 1")
  end

  it "blocks at once when a reviewer stops beside a group move still waiting out its backoff" do
    start(flow({"r1" => "on_fail: stop\n"}, on_fail: "{goto: plan, max: 2, backoff: 1m}"))
    pass("plan")

    fail("r2")
    fail("r1")
    pass("r3")

    expect(run).to include("state" => "waiting", "current" => "r1")
    expect(run["loops"]).to eq({})
    %w[r1 r2].each { |id| expect(run["steps"][id]["reason"]).to include("code" => "failed_check") }
    expect(run["steps"]["r2"]).not_to have_key("pending_move")
    expect(typed("step_retry_blocked")).to match([include("from" => "r2", "code" => "sibling_stopped")])
    expect(Workspace::WorkflowTransitions.join_due(run, now.first + 120)).to be_nil
  end

  it "(e) blocks the same way when the reviewer that takes the group goto fails before the one that stops" do
    start(flow({"r1" => "on_fail: stop\n"}, max_attempts: 20))
    pass("plan")

    fail("r2")
    expect(run["steps"]["r2"]["pending_move"]).to include("group" => "reviews")
    fail("r1")
    pass("r3")

    expect(run).to include("state" => "waiting", "current" => "r1")
    expect(run["loops"]).to eq({})
    expect(attempts("r2").last["group_move"]).to include("failed" => "sibling_stopped")
    expect(typed("step_retry_blocked").size).to eq(1)
    expect(attempts("plan").size).to eq(1)
  end

  describe "(e) a reviewer's own on_fail: stop beside one that takes the group goto" do
    before do
      start(flow({"r1" => "on_fail: stop\n"}, max_attempts: 20))
      pass("plan")
      fail("r1")
      fail("r2")
      pass("r3")
    end

    it "stops the run for a person with no loop counted, and a tick and a sweep change nothing" do
      expect(run).to include("state" => "waiting", "current" => "r1")
      expect(run["loops"]).to eq({})
      %w[r1 r2].each do |id|
        expect(run["steps"][id]["reason"]).to include("code" => "failed_check", "details" => include("group" => "reviews", "failed" => %w[r1 r2]))
        expect(run["steps"][id]).not_to have_key("pending_move")
      end
      expect(run["steps"]["r2"]["reason"]["details"]).to include("move" => {"to" => "plan", "error" => "sibling_stopped", "group" => "reviews"})
      expect(attempts("r2").last["group_move"]).to include("failed" => "sibling_stopped")
      expect(typed("step_retry_blocked")).to match([include("from" => "r2", "to" => "plan", "code" => "sibling_stopped", "group" => "reviews")])
      expect(attempts("plan").size).to eq(1)

      stored = run
      engine.tick("wr_1", actor: "daemon")
      sweep.call

      expect(run.slice("state", "current", "loops", "steps")).to eq(stored.slice("state", "current", "loops", "steps"))
      expect(typed("step_retry_blocked").size).to eq(1)
    end

    it "counts a fresh loop on the restored count after plain resumes, and stops at max, never past it" do
      engine.resume("wr_1", actor: "person")
      expect(dispatched.last).to eq(%w[r1 resume])
      pass("r1")
      expect(run).to include("state" => "waiting", "current" => "r2")
      expect(run["steps"]["r2"]["reason"]).to include("code" => "failed_check")
      expect(run["loops"]).to eq({})

      engine.resume("wr_1", actor: "person")
      expect(dispatched.last).to eq(%w[r2 resume])
      fail("r2")

      expect(run["loops"]).to eq("reviews->plan" => 1)
      expect(dispatched.last).to eq(%w[plan loop])
      expect(attempts("r3").size).to eq(1)
      pass("plan")
      round(failing: %w[r2])
      expect(run["loops"]).to eq("reviews->plan" => 2)
      pass("plan")
      round(failing: %w[r2])

      expect(run).to include("state" => "waiting", "current" => "r2")
      expect(run["loops"]).to eq("reviews->plan" => 2)
      expect(run["steps"]["r2"]["reason"]).to include("code" => "failed_check")
      expect(attempts("plan").size).to eq(3)
      expect(Workspace::WorkflowTransitions.attempts_made(run)).to be < 20
    end
  end

  # Every sibling runs again when the group loops, so a sibling's spent cap stops the loop at the failure, as a spent
  # goto step's cap does: no loop is counted and nothing goes back to plan.
  it "(f) stops for a person naming a reviewer whose max_attempts: 1 is spent, with no loop counted" do
    start(flow({"r1" => "max_attempts: 1\n"}))
    pass("plan")

    round(failing: %w[r1])

    expect(run).to include("state" => "waiting", "current" => "r1")
    expect(run["loops"]).to eq({})
    expect(typed("step_looped")).to eq([])
    expect(attempts("plan").size).to eq(1)
    expect(run["steps"]["r1"]).not_to have_key("pending_move")
    expect(run["steps"]["r1"]["reason"]).to include("code" => "failed_check",
      "details" => include("limit" => "step", "limit_step" => "r1", "group" => "reviews", "failed" => %w[r1]))
  end
end
