require "spec_helper"
require "tmpdir"

# Sweep, recovery, infra retries and a person's decisions on a run whose fan_out group is under way, through the real
# engine over a real run store in a temporary directory: each sibling is looked at and acted on through its own step,
# pane and slots, whichever sibling the run's cursor is on. FakeWorkflowPanes stands in for tmux and the agent daemon,
# so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine, "with a fan_out group under way" do
  around do |example|
    Dir.mktmpdir("wf-fan-out-recovery") do |dir|
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
  let(:presses) { [] }
  let(:interrupter) { ->(workspace, pane, keys) { presses << [workspace, pane, keys] } }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:claimant) { {"pid" => 4242, "started" => "Sun Oct  4 12:00:00 2026"} }
  subject(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes,
      checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}),
      lineage: instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")), git: git,
      guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: Workspace::WorkflowGateNote.new(notes: notes),
      interrupter: interrupter, clock: -> { now.first })
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

  # One group of two siblings, then a report step.
  def flow(lint: "", test: "", before: false)
    plan = before ? "  plan:\n    prompt: Plan.\n    produces: [plan.md]\n" : ""
    yaml = "max_attempts: 20\nsteps:\n#{plan}  checks:\n    checkout: shared\n    fan_out:\n" \
      "      lint:\n        prompt: Do lint.\n        produces: [lint.md]\n#{lint.lines.map { |line| "        #{line}" }.join}" \
      "      test:\n        prompt: Do test.\n        produces: [test.md]\n#{test.lines.map { |line| "        #{line}" }.join}" \
      "  report:\n    prompt: Report.\n    produces: [report.md]\n"
    Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")
  end

  def start(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def run = stored_run(store, "wr_1")

  def state(step) = run["steps"][step]["state"]

  def attempts(step) = run["steps"][step]["attempts"]

  def pane(step) = run["steps"][step]["pane"] || "%5"

  def pass(step)
    path = File.join(worktree, ".workflow", "wr_1", "#{step}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "done\n")
    File.utime(now.first, now.first, path)
    engine.turn_ended("wr_1", actor: "agent", pane: pane(step), step: step)
  end

  def working(*steps)
    steps.each do |step|
      panes.rows[pane(step)] = {"pane_id" => pane(step), "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
    end
  end

  def events(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  it "runs its siblings in panes of their own" do
    start
    expect(state("lint")).to eq("running")
    expect(state("test")).to eq("running")
    expect(pane("lint")).not_to eq(pane("test"))
  end

  def other = (%w[lint test] - [run["current"]]).first

  describe "the sweep" do
    it "keeps the marks of both siblings whose panes are gone in one pass apart, under each one's own step" do
      start
      working("lint", "test")
      now[0] += 600
      panes.stale.push(pane("lint"), pane("test"))

      rows = sweep.call

      expect(rows.map { |row| [row["step"], row["outcome"], row["cause"]] }).to contain_exactly(%w[lint recorded pane_gone], %w[test recorded pane_gone])
      %w[lint test].each do |id|
        expect(run["steps"][id]["sweep"]).to include("step" => id, "attempt" => 1, "stalled" => include("pane_gone"), "infra_retry" => include("n" => 1))
      end
      expect(run).not_to have_key("sweep")
      expect(events("step_stalled").map { |line| line["step"] }).to contain_exactly("lint", "test")
    end

    it "leaves the cursor on a sibling whose line it typed again, as a sibling's turn end does" do
      panes.queue_kicks({ok: false, code: "pane_busy", message: "busy"}, {ok: true})
      start
      undelivered = %w[lint test].find { |id| attempts(id).last["outcome"] == "not_delivered" }
      expect(undelivered).not_to be_nil
      expect(run["current"]).not_to eq(undelivered)
      working((%w[lint test] - [undelivered]).first)
      panes.rows[pane(undelivered)] = {"pane_id" => pane(undelivered), "kind" => "claude", "state" => "idle", "idle_seconds" => 60}
      now[0] += 120

      rows = sweep.call

      expect(rows).to include(include("step" => undelivered, "outcome" => "redelivered"))
      expect(attempts(undelivered).size).to eq(2)
      # Accepted: the act leaves the cursor on the sibling it acted on (WorkflowRecovery#on_step).
      expect(run["current"]).to eq(undelivered)
    end
    it "gives each sibling under way a row of its own, the cursor's first" do
      start
      working("lint", "test")
      now[0] += 600

      rows = sweep.call

      expect(rows.map { |row| [row["step"], row["reason"]] }).to eq([[run["current"], "healthy"], [(%w[lint test] - [run["current"]]).first, "healthy"]])
    end

    it "records a stall and schedules the restart of the sibling whose pane is gone, under its own step, leaving the other alone" do
      start
      working("lint", "test")
      now[0] += 600
      panes.stale << pane("lint")
      before_test = run["steps"]["test"]

      rows = sweep.call

      expect(rows).to include(include("step" => "lint", "outcome" => "recorded", "cause" => "pane_gone", "action" => "infra_retry_scheduled"))
      expect(rows).to include(include("step" => "test", "reason" => "healthy"))
      expect(run["steps"]["lint"]["sweep"]).to include("step" => "lint", "stalled" => include("pane_gone"), "infra_retry" => include("cause" => "pane_gone", "n" => 1))
      expect(run).not_to have_key("sweep")
      expect(run["steps"]["test"].except("sweep")).to eq(before_test)
      expect(run["steps"]["test"]).not_to have_key("sweep")
      expect(events("step_stalled")).to contain_exactly(include("step" => "lint", "cause" => "pane_gone"))
      # A second pass finds the sibling's mark and records nothing again.
      expect(sweep.call).to include(include("step" => "lint", "reason" => "already_recorded"))
    end

    it "sees a gated sibling that is not the cursor's step" do
      start(flow(lint: "gate: approve\n"))
      pass("lint")
      expect(run["current"]).to eq("test")
      working("test")
      now[0] += 600

      rows = sweep.call

      expect(rows.map { |row| row["step"] }).to eq(%w[test lint])
      expect(rows.last).to include("reason" => "not_running")
      expect(Workspace::WorkflowTransitions.held_reason(run, step: "lint")).to eq("reason")
      expect(Workspace::WorkflowTransitions.held_reason(run)).to be_nil
    end
  end

  describe "an infra retry" do
    it "restarts only the sibling whose pane is gone, in a pane of its own" do
      start
      working("lint", "test")
      now[0] += 600
      panes.stale << pane("lint")
      old_lint = pane("lint")
      sweep.call
      test_before = run["steps"]["test"]
      now[0] += 61

      view = Workspace::WorkflowTransitions.at_step(run, "lint")
      expect(Workspace::WorkflowTransitions.step_wake(run, now.first)).to eq([:infra_retry, view])
      attempt = attempts("lint").last["n"]
      expect(engine.claim_infra_retry("wr_1", actor: "daemon", step: "lint", attempt: attempt, claimant: claimant, alive: ->(_) { true }).first).to eq(:claimed)
      engine.resume("wr_1", actor: "daemon", restart_step: true, bound: "unknown", infra_retry: claimant, pane: "%300", step: "lint")

      expect(attempts("lint").map { |each| each["outcome"] }).to eq(["interrupted", nil])
      expect(pane("lint")).to eq("%300")
      expect(pane("lint")).not_to eq(old_lint)
      expect(panes.bound["%300"]).to include(run_id: "wr_1", step: "lint")
      expect(run["steps"]["test"]).to eq(test_before)
      expect(events("run_resumed").last).to include("step" => "lint", "restart_step" => true, "infra_retry" => 1)
    end

    it "is found and restarted by WorkflowInfraRetry for a sibling off the cursor" do
      start
      working("lint", "test")
      now[0] += 600
      off = (%w[lint test] - [run["current"]]).first
      panes.stale << pane(off)
      sweep.call
      now[0] += 61
      spawned = Workspace::PaneDispatch::Spawned.new(pane: "%300", ready: Workspace::AgentReadiness::Result.new(ready: true, reason: nil), label: "Claude Code", closed: false)
      dispatch = instance_double(Workspace::PaneDispatch, session_live?: true, spawn: spawned)
      retry_ = Workspace::WorkflowInfraRetry.new(engine: engine, store: store, dispatch: dispatch, lock_holder: RunFileLiveness.new(runs_dir),
        agent_commands: instance_double(Workspace::AgentCommands, kind: "claude"), pid: 4242, clock: -> { now.first })

      expect(retry_.call(store.run("wr_1"))).to eq([:restarted, 1, "%300"])
      expect(pane(off)).to eq("%300")
      expect(attempts(off).size).to eq(2)
      expect(attempts((%w[lint test] - [off]).first).size).to eq(1)
    end
  end

  describe "the tick" do
    def pause_both
      start
      working("lint", "test")
      panes.pids.merge!(pane("lint") => 11, pane("test") => 12)
      engine.pause("wr_1", actor: "person", interrupt: true)
      engine.unpause("wr_1", actor: "person")
    end

    it "types the continue line of every sibling due in one tick, one act each" do
      pause_both
      expect(%w[lint test].map { |id| run["steps"][id]["continue_pending"] }).to all(be_a(Hash))
      panes.turn_over.push(pane("lint"), pane("test"))

      expect(engine.tick("wr_1", actor: "daemon")).not_to be_nil

      expect(%w[lint test].map { |id| run["steps"][id].key?("continue_pending") }).to eq([false, false])
      expect(panes.kicks.map { |kick| kick[:pane] }).to include(pane("lint"), pane("test"))
      expect(events("step_continued").map { |line| line["step"] }).to contain_exactly("lint", "test")
    end

    it "leaves the cursor where it was when a sibling's wake does nothing" do
      pause_both
      cursor = run["current"]
      panes.turn_over.push(pane(cursor))
      engine.tick("wr_1", actor: "daemon")
      expect(run["steps"][cursor]).not_to have_key("continue_pending")

      expect(engine.tick("wr_1", actor: "daemon")).to be_nil

      expect(run["current"]).to eq(cursor)
      expect(run["steps"][other]["continue_pending"]).to be_a(Hash)
    end
  end

  describe "a person's decisions" do
    it "refuses a restart of a step that is no sibling under way, a typo included, changing nothing" do
      start
      before = File.binread(File.join(runs_dir, "wr_1.json"))

      %w[lnit report].each do |step|
        expect { engine.resume("wr_1", actor: "person", restart_step: true, bound: "gone", step: step) }.to raise_error(Workspace::UsageError, /#{step}.*not a fan_out sibling under way/)
      end
      expect(File.binread(File.join(runs_dir, "wr_1.json"))).to eq(before)
    end

    it "names the step it was given when no such step is under way at a gate" do
      start(flow(lint: "gate: approve\n"))
      pass("lint")

      expect { engine.approve("wr_1", actor: "person", step: "lnit") }.to raise_error(Workspace::Error, /gate of step lnit: it has no such step under way \(the run's step test is running\)/)
    end

    it "fans the group out on unpause when the pause held its dispatch, leaving no sibling stuck" do
      start(flow(before: true))
      engine.pause("wr_1", actor: "person")
      pass("plan")
      expect(state("lint")).to eq("pending")
      expect(state("test")).to eq("pending")

      unpaused = engine.unpause("wr_1", actor: "person")

      expect(unpaused["unpaused"]).to include("action" => "dispatch", "held" => "attempt")
      expect([state("lint"), state("test")]).to eq(%w[running running])
      expect(pane("lint")).not_to eq(pane("test"))
      expect(%w[lint test].map { |id| run["steps"][id]["pause_hold"] }).to eq([nil, nil])
      expect(run).not_to have_key("pause_hold")
    end
    it "approves the gate of a sibling that is not the cursor's step while the other is at work" do
      start(flow(lint: "gate: approve\n"))
      pass("lint")
      expect(run).to include("state" => "running", "current" => "test")

      engine.approve("wr_1", actor: "person", step: "lint")

      expect(state("lint")).to eq("passed")
      expect(run["steps"]["lint"]["gate"]).to include("state" => "approved")
      expect(state("test")).to eq("running")
      expect(state("report")).to eq("pending")
      pass("test")
      expect(state("report")).to eq("running")
    end

    it "still refuses a step that is not waiting at its gate" do
      start(flow(lint: "gate: approve\n"))
      pass("lint")

      expect { engine.approve("wr_1", actor: "person", step: "test") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("gate_not_waiting") }
    end

    it "rejects a sibling's gate, running only that sibling again, and refuses --to another step" do
      start(flow(lint: "gate: approve\n"))
      pass("lint")

      expect { engine.reject("wr_1", actor: "person", note: "no", step: "lint", to: "test") }.to raise_error(Workspace::UsageError, /--to must be lint/)
      engine.reject("wr_1", actor: "person", note: "redo", step: "lint")

      expect(state("lint")).to eq("running")
      expect(attempts("lint").size).to eq(2)
      expect(attempts("test").size).to eq(1)
    end

    it "pauses with --interrupt pressing every sibling at work, and its unpause continues each" do
      start
      working("lint", "test")
      panes.pids.merge!(pane("lint") => 11, pane("test") => 12)

      paused = engine.pause("wr_1", actor: "person", interrupt: true)

      expect(paused["interrupted"]).to be(true)
      expect(presses.map { |each| each[1] }).to contain_exactly(pane("lint"), pane("test"))
      cursor = run["current"]
      other = (%w[lint test] - [cursor]).first
      expect(run["paused"]["interrupt"]).to include("step" => cursor, "pane" => pane(cursor))
      expect(run["paused"]["interrupts"]).to contain_exactly(include("step" => other, "pane" => pane(other)))

      panes.turn_over.push(pane(cursor), pane(other))
      unpaused = engine.unpause("wr_1", actor: "person")

      expect(unpaused["unpaused"]).to include("action" => "continue", "continued" => true)
      expect(run).not_to have_key("paused")
      expect(run["state"]).to eq("running")
      expect(run["steps"][other]["continue_pending"]).to include("step" => other, "pane" => pane(other))
      expect(engine.tick("wr_1", actor: "daemon")).not_to be_nil
      expect(run["steps"][other]).not_to have_key("continue_pending")
      expect(panes.kicks.map { |kick| [kick[:pane], kick[:text]] }).to include(
        [pane(cursor), format(Workspace::WorkflowTransitions::CONTINUE_LINE, cursor, attempts(cursor).last["prompt_file"])],
        [pane(other), format(Workspace::WorkflowTransitions::CONTINUE_LINE, other, attempts(other).last["prompt_file"])]
      )
      expect(state("lint")).to eq("running")
      expect(state("test")).to eq("running")
    end
  end
end
