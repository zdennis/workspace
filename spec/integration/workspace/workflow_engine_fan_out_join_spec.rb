require "spec_helper"
require "tmpdir"

# A fan_out group's join through the real engine over a real run store in a temporary directory: what follows each
# sibling's attempt (passed, failed, at its gate) is decided only once the group is at rest, failure moves are
# deferred to the join and applied one at a time, a failed sibling is run again once its move has run, and the step
# after the group starts from the group's place in the definition. FakeWorkflowPanes stands in for tmux and the agent
# daemon, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine do
  around do |example|
    Dir.mktmpdir("wf-fan-out-join") do |dir|
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
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:composer) { FakeStepComposer.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  subject(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: composer, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  # A definition with one group of the siblings given (id to extra YAML lines), an optional step before it, and a
  # report step after it.
  def flow(siblings = {}, before: false, report: "", max_attempts: 40, **named)
    body = siblings.merge(named).map do |id, extra|
      "      #{id}:\n        prompt: Do #{id}.\n        produces: [#{id}.md]\n#{extra.to_s.lines.map { |line| "        #{line}" }.join}"
    end.join
    plan = before ? "  plan:\n    prompt: Plan.\n    produces: [plan.md]\n" : ""
    yaml = "max_attempts: #{max_attempts}\nsteps:\n#{plan}  checks:\n    checkout: shared\n    execution_mode: process_separation\n    fan_out:\n#{body}  report:\n    prompt: Report.\n    produces: [report.md]\n#{report.lines.map { |line| "    #{line}" }.join}"
    Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")
  end

  def start(definition)
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

  def kicks_into(pane_id) = panes.kicks.select { |kick| kick[:pane] == pane_id }

  def events = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }

  def dispatched = events.select { |line| line["type"] == "step_dispatching" }.map { |line| [line["step"], line["cause"]] }

  it "starts the step after the group once every sibling passed" do
    start(flow("lint" => nil, "test" => nil))

    pass("lint")
    expect(state("report")).to eq("pending")
    expect(run).to include("state" => "running", "current" => "test")
    pass("test")

    expect(state("report")).to eq("running")
    expect(run).to include("state" => "running", "current" => "report")
    expect(dispatched.last).to eq(["report", "next_step"])
  end

  it "lets the group drain after one sibling's failure is spent, then stops the run at the join with that sibling's reason" do
    start(flow("lint" => nil, "test" => nil))

    fail("lint")
    expect(state("lint")).to eq("failed")
    expect(state("test")).to eq("running")
    expect(run["state"]).to eq("running")
    expect(run["steps"]["lint"]["reason"]).to be_nil
    expect(attempts("test").size).to eq(1)

    pass("test")

    expect(run).to include("state" => "waiting", "current" => "lint")
    expect(run["steps"]["lint"]["reason"]).to include("code" => "failed_check",
      "details" => include("step" => "lint", "attempt" => 1, "cause" => "reported", "group" => "checks", "failed" => ["lint"]))
    expect(state("report")).to eq("pending")
    expect(run["steps"]["test"]["reason"]).to be_nil
  end

  it "walks a goto chain toward the group's head without leaving it" do
    start(flow({"lint" => nil, "test" => "on_fail: {goto: lint, max: 2}\n", "docs" => "on_fail: {goto: test, max: 2}\n"}, before: true))
    pass("plan")
    pass("lint")
    pass("test")

    fail("docs")
    expect(dispatched.last).to eq(["test", "loop"])
    # The move's target is started in its own pane, its binding made again for the new attempt.
    expect(run["steps"]["test"]["pane"]).to eq("%101")
    expect(panes.bound["%101"]).to include(run_id: "wr_1", step: "test", attempt: 2)
    expect(panes.kicks.last).to include(pane: "%101", text: "Read #{attempts("test").last["prompt_file"]} and follow it.")
    expect(panes.bound["%102"]).to include(step: "docs", attempt: 1)
    fail("test")
    expect(dispatched.last).to eq(["lint", "loop"])
    pass("lint")
    expect(dispatched.last(2)).to eq([["test", "next_step"], ["docs", "next_step"]])
    pass("test")
    pass("docs")

    expect(state("report")).to eq("running")
    expect(attempts("plan").size).to eq(1)
    expect(run["loops"]).to eq("docs->test" => 1, "test->lint" => 1)
  end

  describe "a sibling with no on_fail" do
    before do
      start(flow({"lint" => nil, "test" => nil}, before: true))
      pass("plan")
    end

    it "loops to the sibling before it" do
      fail("test")
      expect(run["steps"]["test"]["pending_move"]).to include("to" => "lint", "count" => 1)
      pass("lint")
      expect(dispatched.last).to eq(["lint", "loop"])
      pass("lint")
      expect(dispatched.last).to eq(["test", "next_step"])
      pass("test")

      expect(state("report")).to eq("running")
      expect(attempts("plan").size).to eq(1)
      expect(run["loops"]).to eq("test->lint" => 1)
    end

    it "stops the group's first sibling at the join instead of going to the step before the group" do
      fail("lint")
      expect(run["steps"]["lint"]).not_to have_key("pending_move")
      pass("test")

      expect(attempts("plan").size).to eq(1)
      expect(run["loops"]).to eq({})
      expect(run).to include("state" => "waiting", "current" => "lint")
      expect(run["steps"]["lint"]["reason"]).to include("code" => "failed_check")
      expect(state("report")).to eq("pending")
    end
  end

  it "does nothing for a sibling's waited move until its wait is over and the group at rest, and the tick then runs the join" do
    start(flow("lint" => nil, "test" => "on_fail: {goto: lint, max: 2, backoff: 1m}\n"))

    fail("test")
    expect(run["steps"]["test"]["pending_move"]).to include("to" => "lint", "until" => (now.first + 60).utc.iso8601)
    expect(run["steps"]["test"]).not_to have_key("backoff")
    expect(run).not_to have_key("backoff")
    pass("lint")

    expect(run).to include("state" => "waiting", "current" => "test")
    expect(run["steps"]["test"]["reason"]).to include("code" => "retry_backoff", "details" => include("step" => "test", "to" => "lint"))
    kicked = panes.kicks.size
    expect(engine.tick("wr_1", actor: "daemon")).to be_nil
    expect(panes.kicks.size).to eq(kicked)

    now[0] += 61
    engine.tick("wr_1", actor: "daemon")

    expect(panes.kicks.size).to eq(kicked + 1)
    expect(panes.kicks.last[:pane]).to eq("%5")
    expect(attempts("lint").size).to eq(2)
    expect(run["steps"]["test"]).not_to have_key("pending_move")
    expect(run["steps"]["test"]["reason"]).to be_nil
    expect(dispatched.last).to eq(["lint", "loop"])
    expect(events.map { |line| line["type"] }).not_to include("step_retry_blocked")
  end

  describe "the step after the group failing with no on_fail" do
    it "skips the group's siblings and loops to the step before the group" do
      start(flow({"lint" => nil, "test" => nil}, before: true))
      pass("plan")
      pass("lint")
      pass("test")

      fail("report")

      expect(run["loops"]).to eq("report->plan" => 1)
      expect(dispatched.last).to eq(["plan", "loop"])
      expect(attempts("lint").size).to eq(1)
      expect(attempts("test").size).to eq(1)
    end

    it "types the second fan-out into the siblings' own live panes, spawns none, and lets the second round pass" do
      start(flow({"lint" => nil, "test" => nil, "docs" => nil}, before: true))
      pass("plan")
      %w[lint test docs].each { |id| pass(id) }
      panes_before = %w[lint test docs].to_h { |id| [id, pane(id)] }
      fail("report")

      pass("plan")

      expect(panes.spawns.size).to eq(2)
      expect(%w[lint test docs].to_h { |id| [id, pane(id)] }).to eq(panes_before)
      expect(kicks_into(panes_before["test"]).size).to eq(2)
      expect(kicks_into(panes_before["docs"]).size).to eq(2)
      %w[lint test docs].each { |id| pass(id) }

      expect(run).to include("state" => "running", "current" => "report")
      expect(state("report")).to eq("running")
      expect(attempts("test").size).to eq(2)
    end

    it "spawns a new pane for a sibling whose pane is gone, drops its stale binding, and sees its turn end" do
      start(flow({"lint" => nil, "test" => nil, "docs" => nil}, before: true))
      pass("plan")
      %w[lint test docs].each { |id| pass(id) }
      old = pane("test")
      kept = pane("docs")
      fail("report")
      panes.stale << old

      pass("plan")

      expect(panes.spawns.size).to eq(3)
      expect(pane("test")).not_to eq(old)
      expect(pane("docs")).to eq(kept)
      expect(panes.bound).not_to have_key(old)
      expect(panes.bound[pane("test")]).to include(run_id: "wr_1", step: "test")
      panes.stale.clear
      %w[lint test docs].each { |id| pass(id) }

      expect(run).to include("state" => "running", "current" => "report")
    end

    it "types the first sibling into the run's new pane when a resume --pane moved the run between rounds" do
      start(flow({"lint" => nil, "test" => nil}, before: true))
      pass("plan")
      %w[lint test].each { |id| pass(id) }
      old = pane("lint")
      fail("report")
      expect(run["current"]).to eq("plan")

      engine.resume("wr_1", actor: "person", pane: "%9")
      write("plan")
      engine.turn_ended("wr_1", actor: "agent", pane: "%9", step: "plan")

      expect(old).not_to eq("%9")
      expect(kicks_into("%9").map { |kick| kick[:text] }.join).to match(%r{steps/lint\.})
      expect(pane("lint")).to eq("%9")
    end

    it "stops for a group at the workflow's start rather than loop into a sibling" do
      start(flow("lint" => nil, "test" => nil))
      pass("lint")
      pass("test")

      fail("report")

      expect(run["loops"]).to eq({})
      expect(run).to include("state" => "waiting", "current" => "report")
      expect(run["reason"]).to include("code" => "failed_check")
      expect(attempts("lint").size).to eq(1)
      expect(attempts("test").size).to eq(1)
    end
  end

  it "starts the step after the group from the group's place once a middle sibling's loop is done, whatever the cursor names" do
    start(flow("lint" => nil, "test" => nil, "docs" => nil))
    pass("docs")
    pass("lint")

    fail("test")
    pass("lint")
    pass("test")

    expect(state("report")).to eq("running")
    expect(run["current"]).to eq("report")
    expect(attempts("docs").size).to eq(1)
    expect(dispatched.count { |step, _| step == "docs" }).to eq(1)
  end

  it "defers a move whose target is still at work, then runs the target, the failed sibling, and only then the step after the group" do
    start(flow("lint" => nil, "test" => nil))

    fail("test")

    expect(attempts("lint").size).to eq(1)
    expect(attempts("lint").first).not_to have_key("ended_at")
    expect(kicks_into("%5").size).to eq(1)
    expect(run["steps"]["test"]["pending_move"]).to include("to" => "lint")
    expect(run).to include("state" => "running", "current" => "lint")

    pass("lint")
    expect(attempts("lint").size).to eq(2)
    expect(kicks_into("%5").size).to eq(2)
    expect(run["steps"]["test"]).not_to have_key("pending_move")
    expect(state("report")).to eq("pending")

    pass("lint")
    expect(attempts("test").size).to eq(2)
    expect(state("report")).to eq("pending")

    pass("test")
    expect(state("report")).to eq("running")
  end

  describe "a goto's relay" do
    let(:goto) { flow("lint" => nil, "test" => nil, "docs" => "on_fail: {goto: lint, max: 3}\n") }

    it "runs the failed sibling again once its move's target passed, then starts the step after the group" do
      start(goto)
      pass("lint")
      pass("test")

      fail("docs")
      expect(dispatched.last).to eq(["lint", "loop"])
      pass("lint")
      expect(dispatched.last).to eq(["docs", "next_step"])
      pass("docs")

      expect(state("report")).to eq("running")
      expect(attempts("test").size).to eq(1)
    end

    it "stops at the join with every one of its loops run once they are spent" do
      start(goto)
      pass("lint")
      pass("test")

      3.times do
        fail("docs")
        pass("lint")
      end
      fail("docs")

      expect(attempts("docs").size).to eq(4)
      expect(attempts("lint").size).to eq(4)
      expect(run["loops"]).to eq("docs->lint" => 3)
      expect(run).to include("state" => "waiting", "current" => "docs")
      expect(run["steps"]["docs"]["reason"]).to include("code" => "failed_check", "details" => include("step" => "docs", "attempt" => 4))
      expect(state("report")).to eq("pending")
    end
  end

  it "waits for a sibling at its gate, and goes on once a person approves it" do
    start(flow("lint" => "gate: approve\n", "test" => nil))

    pass("lint")
    expect(run["steps"]["lint"]["gate"]).to include("state" => "waiting")
    expect(run).to include("state" => "running", "current" => "test")

    pass("test")
    expect(run).to include("state" => "waiting", "current" => "lint")
    expect(state("report")).to eq("pending")
    expect(run["steps"]["lint"]["reason"]).to include("code" => "waiting_you")

    engine.approve("wr_1", actor: "person", step: "lint")

    expect(state("lint")).to eq("passed")
    expect(state("report")).to eq("running")
  end

  it "applies two moves naming one target one at a time, never typing twice into its pane in one turn" do
    start(flow("lint" => nil, "test" => nil, "docs" => "on_fail: {goto: lint, max: 2}\n"))
    pass("lint")

    fail("test")
    expect(kicks_into("%5").size).to eq(1)
    fail("docs")

    expect(kicks_into("%5").size).to eq(2)
    expect(attempts("lint").size).to eq(2)
    expect(run["steps"]["test"]).not_to have_key("pending_move")
    expect(run["steps"]["docs"]["pending_move"]).to include("to" => "lint")

    pass("lint")
    expect(kicks_into("%5").size).to eq(3)
    expect(attempts("lint").size).to eq(3)
    expect(run["steps"]["docs"]).not_to have_key("pending_move")

    pass("lint")
    expect(dispatched.last(2)).to eq([["test", "next_step"], ["docs", "next_step"]])
    pass("test")
    pass("docs")

    expect(state("report")).to eq("running")
  end

  it "does not run a target whose own failure is spent, and stops the group with both failures" do
    start(flow("lint" => nil, "test" => nil))

    fail("lint")
    fail("test")

    expect(attempts("lint").size).to eq(1)
    expect(kicks_into("%5").size).to eq(1)
    expect(%w[lint test].map { |step| [state(step), attempts(step).map { |attempt| attempt["outcome"] }] }).to eq(
      [["failed", ["failed"]], ["failed", ["failed"]]]
    )
    expect(run["steps"]["test"]).not_to have_key("pending_move")
    expect(attempts("test").last["move"]).to include("to" => "lint", "failed" => "target_failed")
    expect(events.select { |line| line["type"] == "step_retry_blocked" }.map { |line| line.slice("from", "to", "code") }).to eq(
      [{"from" => "test", "to" => "lint", "code" => "target_failed"}]
    )
    expect(run).to include("state" => "waiting", "current" => "lint")
    expect(run["steps"]["lint"]["reason"]).to include("code" => "failed_check", "details" => include("failed" => %w[lint test]))
    expect(run["steps"]["test"]["reason"]).to include("code" => "failed_check",
      "details" => include("move" => {"to" => "lint", "error" => "target_failed"}))
  end

  it "keeps a waited move off a target still at work, the tick typing nothing, and applies it once after both are over" do
    start(flow("lint" => nil, "test" => nil, "docs" => "on_fail: {goto: lint, max: 2, backoff: 1m}\n"))
    pass("test")

    fail("docs")
    expect(run).not_to have_key("backoff")
    expect(run["steps"]["docs"]).not_to have_key("backoff")
    now[0] += 61
    engine.tick("wr_1", actor: "daemon")

    expect(kicks_into("%5").size).to eq(1)
    expect(attempts("lint").size).to eq(1)
    expect(events.map { |line| line["type"] }).not_to include("step_retry_started")

    pass("lint")

    expect(kicks_into("%5").size).to eq(2)
    expect(attempts("lint").size).to eq(2)
    expect(run["steps"]["docs"]).not_to have_key("pending_move")
    expect(run["steps"]["docs"]["reason"]).to be_nil
    engine.tick("wr_1", actor: "daemon")
    expect(kicks_into("%5").size).to eq(2)
    expect(events.count { |line| line["type"] == "step_retry_started" }).to eq(1)
  end

  describe "a subagents group's turn end" do
    def sub_flow(on_fail: false)
      yaml = <<~YAML
        max_attempts: 40
        steps:
          checks:
            execution_mode: subagents
            fan_out:
              lint:
                prompt: Do lint.
                produces: [lint.md]
              test:
                prompt: Do test.
                produces: [test.md]
          report:
            prompt: Report.
            produces: [report.md]
      YAML
      yaml = yaml.sub("        produces: [test.md]\n", "        produces: [test.md]\n        on_fail: {goto: lint, max: 2}\n") if on_fail
      Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")
    end

    it "judges every sibling still without an outcome when the run pane's turn ends, and starts the step after the group" do
      start(sub_flow)
      write("lint")
      write("test")

      engine.turn_ended("wr_1", actor: "agent", pane: "%5", group: "checks")

      expect(state("lint")).to eq("passed")
      expect(state("test")).to eq("passed")
      expect(state("report")).to eq("running")
      expect(run).to include("state" => "running", "current" => "report")
    end

    it "judges a sibling that reported pass from its report, and the unreported one from its files" do
      start(sub_flow)
      write("lint")
      engine.report("wr_1", actor: "agent", status: "pass", summary: "lint done", step: "lint")
      write("test")

      engine.turn_ended("wr_1", actor: "agent", pane: "%5", group: "checks")

      expect(state("report")).to eq("running")
      expect(attempts("lint").last).to include("reported" => include("status" => "pass"))
    end

    it "drives the group's failure loop from a reported fail, re-attempting the target with a one-sibling line" do
      start(sub_flow(on_fail: true))

      write("lint")
      write("test")
      engine.report("wr_1", actor: "agent", status: "fail", summary: "test broke", step: "test")
      engine.turn_ended("wr_1", actor: "agent", pane: "%5", group: "checks")

      expect(dispatched).to include(["lint", "loop"])
      expect(attempts("lint").size).to eq(2)
      lint_file = attempts("lint").last["prompt_file"]
      last_kick = kicks_into("%5").last
      expect(last_kick[:text]).to include(Workspace::WorkflowDispatch::SUBAGENT_KICK)
      expect(last_kick[:text]).to include("Step lint: Read #{lint_file} and follow it.")
      expect(last_kick[:text]).not_to include("Step test")
    end
  end

  describe "a move back into a group that ran before" do
    def through_group
      write("plan")
      engine.turn_ended("wr_1", actor: "agent", pane: "%5", step: "plan")
      pass("lint")
      pass("test")
    end

    def expect_group_running_again
      expect(state("lint")).to eq("running")
      expect(state("test")).to eq("running")
      expect(attempts("lint").size).to eq(2)
      expect(attempts("test").size).to eq(2)
      expect(kicks_into("%101").size).to eq(2)
      expect(panes.spawns.size).to eq(1)
    end

    it "runs every sibling again when a goto from the step after the group sends the run back before it, and joins them again" do
      start(flow({"lint" => nil, "test" => nil}, before: true, report: "on_fail: {goto: plan, max: 2}\n"))
      through_group
      fail("report")
      expect(dispatched.last).to eq(["plan", "loop"])

      through_group
      expect(dispatched.last(3)).to eq([%w[lint next_step], %w[test next_step], %w[report next_step]])
      expect(attempts("lint").size).to eq(2)
      expect(attempts("test").size).to eq(2)
      expect(Workspace::WorkflowTransitions.attempts_made(run)).to eq(8)
    end

    it "waits at the join for every sibling run again before the step after the group starts" do
      start(flow({"lint" => nil, "test" => nil}, before: true, report: "on_fail: {goto: plan, max: 2}\n"))
      through_group
      fail("report")
      write("plan")
      engine.turn_ended("wr_1", actor: "agent", pane: "%5", step: "plan")
      expect_group_running_again

      pass("lint")
      expect(attempts("report").size).to eq(1)
      expect(run).to include("state" => "running", "current" => "test")

      pass("test")
      expect(state("report")).to eq("running")
      expect(attempts("report").size).to eq(2)
      pass("report")
      expect(run["state"]).to eq("completed")
    end

    it "runs the whole group again on resume --from one sibling after the run stopped past the group" do
      start(flow({"lint" => nil, "test" => nil}, before: true, report: "on_fail: stop\n"))
      through_group
      fail("report")
      expect(run["state"]).to eq("waiting")

      engine.resume("wr_1", actor: "person", from: "test")

      expect_group_running_again
      expect(dispatched.last(2)).to eq([%w[lint resume], %w[test resume]])
      pass("lint")
      pass("test")
      expect(state("report")).to eq("running")
    end

    it "runs the whole group again when a gate after it is rejected back to a sibling" do
      start(flow({"lint" => nil, "test" => nil}, before: true, report: "gate: approve\n"))
      through_group
      pass("report")
      expect(run["state"]).to eq("waiting")

      engine.reject("wr_1", actor: "person", note: "look again", to: "lint")

      expect_group_running_again
      expect(dispatched.last(2)).to eq([%w[lint gate_rejected], %w[test gate_rejected]])
    end
  end
end
