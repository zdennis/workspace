require "spec_helper"
require "tmpdir"
require "digest"
require "json"
require "fileutils"

# One run of spec/fixtures/workflows/e2e.yml through a real engine, over a real run store, lock store,
# require proofs, inbox and verdict tally in a temporary directory. The spec plays the agent (writes the
# produces files and verdicts, ends turns) and the person (approve, reject, resume with extras); the
# guard, the check and the panes are fakes, so nothing starts a process.
RSpec.describe "a workflow run from start to completed" do
  around do |example|
    Dir.mktmpdir("wf-e2e") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:fixture) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflows", "e2e.yml") }
  let(:definition) { Workspace::WorkflowDefinition.parse(File.read(fixture), id: "e2e", source: "global", path: fixture) }
  let(:workspace) { "app.worktree-x" }
  let(:worktree) { File.join(@dir, "app") }
  let(:now) { [Time.utc(2026, 11, 13, 12, 0, 0)] }
  let(:clock) { -> { now.first } }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(@dir, "state", ".workflows", "archive"), clock: clock, id_generator: -> { "wr_1" }) }
  let(:lock_dir) { File.join(@dir, "state", "locks", "ns") }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: lock_dir}) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:check_results) { [] }
  let(:checker) { ->(stop_when:, **_args) { check_results.shift || {exit_code: 0, timed_out: false} } }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: "bin/test", lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) do
    instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, check: nil, config_change: nil, commits_since: 1)
  end
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:gate_note) { Workspace::WorkflowGateNote.new(notes: instance_double(Workspace::Commands::Notes, info: {"dir" => notes_dir})) }
  let(:inbox) { Workspace::InboxStore.new(path: File.join(@dir, "state", ".inbox", "#{workspace}.json"), clock: clock) }
  let(:require_check) do
    Workspace::WorkflowRequire.new(guard: guard, notes_dir_of: ->(_name) { notes_dir }, commands_config: commands_config, checker: checker, inbox_for: ->(_name) { inbox })
  end
  # Implement spends the token budget in one attempt; every other attempt uses a little, well under it.
  let(:implement_usage) { {"input_tokens" => 1200, "output_tokens" => 0} }
  let(:routine_usage) { {"input_tokens" => 10, "output_tokens" => 0} }
  let(:attempt_record) { UsageAttemptRecord.new(usages: {"implement" => [implement_usage]}, default: routine_usage, guard: guard, clock: clock) }
  let(:hook_dir) { File.join(@dir, "events") }
  let(:rounds) { [] }
  # Stands in for the round's delivery (T28+): it records the round, and the review pane and revision as the runner will.
  let(:round_runner) do
    lambda do |run_id, review|
      rounds << review
      store.change(run_id) do |run|
        hash = run.thawed
        hash["steps"][hash["current"]]["review"].merge!("pane" => "%9", "delivery" => nil, "revision" => "rev1")
        Workspace::WorkflowRun.from_h(hash)
      end
    end
  end
  # Built here rather than through the engine spec's build_engine: that one runs over fakes for the
  # proofs, inbox, gate note and tally, where this run needs the real WorkflowRequire, InboxStore,
  # WorkflowGateNote and WorkflowReviewTally over ReviewVerdictProof.
  let(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: checker,
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git), gate_note: gate_note,
      env_stopper: ->(**) {}, workspace_known: ->(_name) { false }, task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}),
      attempt_record: attempt_record, require_check: require_check, review_round: round_runner,
      review_tally: Workspace::WorkflowReviewTally.new(proof: Workspace::ReviewVerdictProof.new(hook_dir: hook_dir)), clock: clock)
  end

  before { FileUtils.mkdir_p([File.join(worktree, ".git"), notes_dir, hook_dir]) }

  def artifact(name, text = "done\n")
    path = File.join(worktree, ".workflow", "wr_1", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.utime(now.first, now.first, path)
  end

  def tick(seconds = 60) = now[0] += seconds

  def turn_ended(pane = "%5")
    tick
    engine.turn_ended("wr_1", pane: pane)
  end

  def outcomes(run, step) = run["steps"][step]["attempts"].map { |attempt| attempt["outcome"] }

  def history = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line)["type"] }

  def plan_file(status)
    File.write(File.join(notes_dir, Workspace::PlanFile::FILE_NAME), "---\nstatus: #{status}\n---\n# Plan\n\n## Tasks\n\n- [ ] T1 Do it\n")
  end

  # One reviewer's sub-agent writes its verdict in the review pane, and the daemon logs the write with the file's hash.
  def verdict(reviewer, said, seq:)
    relative = File.join(".workflow", "wr_1", "reviews", "design.1.r1", "#{reviewer}.md")
    text = (Workspace::WorkflowReviewTally.header_lines(reviewer: reviewer, verdict: said, revision: "rev1") + ["", "Reasons."]).join("\n")
    File.write(File.join(worktree, relative), text)
    line = {"type" => "tool_finished", "at" => now.first.iso8601(3), "workspace" => workspace, "pane_id" => "%9", "boot_id" => "b", "seq" => seq,
            "tool" => "Write", "tool_use_id" => "toolu_#{seq}", "agent_id" => "agent-#{reviewer}", "path" => relative,
            "sha256" => Digest::SHA256.hexdigest(text), "ok" => true}
    File.write(Workspace::HookEventLog.path_for(hook_dir, workspace), JSON.generate(line) + "\n", mode: "a")
  end

  def start
    engine.start(definition: definition, workspace: workspace, worktree: worktree, inputs: {"task" => "X-1"}, pane: "%5")
  end

  # Research, then the plan through its gate, to the design step's author turn ended and its round begun.
  def to_review
    start
    artifact("research.md")
    turn_ended
    artifact("plan.md")
    plan_file("active")
    turn_ended
    engine.approve("wr_1")
    artifact("design.md")
    turn_ended
  end

  it "walks every step: time hold, gate reject and approve, a proven review, budget hold, the on_fail loop and the step's own cap" do
    run = start
    expect(run).to include("state" => "running", "current" => "research")
    expect(panes.kicks.size).to eq(1)

    research_past_the_time_limit
    plan_rejected_then_approved
    design_reviewed_and_approved
    implement_past_the_budget
    verify_looped_and_capped

    run = turn_ended
    expect(run["state"]).to eq("completed")
    expect(outcomes(run, "verify")).to eq(%w[failed failed passed])
    expect(outcomes(run, "implement")).to eq(%w[passed passed])
    expect(run["steps"].transform_values { |step| step["state"] }).to eq("research" => "passed", "plan" => "passed", "design" => "passed", "implement" => "passed", "verify" => "passed")
    expect(panes.kicks.size).to eq(9)
    expect(Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status("test-db").dig("test-db", "holder")).to be_nil

    # Pinned on purpose, the whole path in order; it changes when T28+ adds the review window's events.
    expect(history).to eq([
      "run_started", "step_dispatching", "step_dispatched", "step_passed",
      "run_timed_out", "time_extended", "run_resumed", "step_dispatching", "step_dispatched", "step_passed",
      "gate_waiting", "gate_rejected", "step_dispatching", "step_dispatched", "step_passed", "gate_waiting", "gate_approved",
      "step_dispatching", "step_dispatched", "step_checks_passed", "review_started", "review_ended", "step_passed",
      "step_dispatching", "step_dispatched", "step_passed",
      "budget_spent", "budget_extended", "run_resumed", "step_dispatching", "step_dispatched", "check_finished", "step_failed",
      "step_looped", "step_dispatching", "step_dispatched", "step_passed",
      "step_dispatching", "step_dispatched", "check_finished", "step_failed",
      "attempts_extended", "run_resumed", "step_dispatching", "step_dispatched", "check_finished", "step_passed", "run_completed"
    ])
  end

  it "stops the run review_rejected when the skeptic rejects, since need 2 can no longer be met" do
    to_review
    verdict("skeptic", "reject", seq: 1)

    run = turn_ended("%9")

    expect(run["state"]).to eq("waiting")
    expect(run["reason"]).to include("code" => "review_rejected")
    expect(run["steps"]["design"]["state"]).to eq("failed")
    expect(run["steps"]["design"]["attempts"].last["review_outcome"]).to include("approvals" => 0, "need" => 2, "passed" => false)
  end

  # Research passes its produces and nonempty proof, but took past the run's 2h, so plan is held until --extra-time.
  def research_past_the_time_limit
    artifact("research.md")
    tick(2 * 3600)
    run = turn_ended
    expect(outcomes(run, "research")).to eq(["passed"])
    expect(run).to include("state" => "waiting", "current" => "plan")
    expect(run["reason"]).to include("code" => "run_timed_out")
    expect(run["steps"]["plan"]["attempts"]).to eq([])
    expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_timed_out") }
    run = engine.resume("wr_1", extra_seconds: run["reason"]["details"]["suggested"])
    expect(run).to include("state" => "running", "current" => "plan")
  end

  # The plan waits at its gate once plan.md exists and the plan is active; a reject sends it back once, then an approve.
  def plan_rejected_then_approved
    artifact("plan.md")
    plan_file("active")
    run = turn_ended
    expect(run["state"]).to eq("waiting")
    expect(run["reason"]).to include("code" => "waiting_you")
    expect(run["steps"]["plan"]["gate"]).to include("state" => "waiting")
    run = engine.reject("wr_1", note: "Split T1.")
    expect(run).to include("state" => "running", "current" => "plan")
    expect(run["steps"]["plan"]["attempts"].size).to eq(2)

    artifact("plan.md")
    expect(turn_ended["reason"]).to include("code" => "waiting_you")
    run = engine.approve("wr_1")
    expect(outcomes(run, "plan")).to eq(%w[passed passed])
    expect(run["current"]).to eq("design")
  end

  # The author attempt passes its checks and round 1 begins in pane %9; the author's own turn end decides nothing,
  # and two proven approvals, the skeptic's among them, pass the step.
  def design_reviewed_and_approved
    artifact("design.md")
    run = turn_ended
    expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 1)
    expect(outcomes(run, "design")).to eq(["checks_passed"])
    expect(rounds).to eq([{"step" => "design", "attempt" => 1, "round" => 1}])

    expect(turn_ended["steps"]["design"]["state"]).to eq("reviewing")
    verdict("skeptic", "approve", seq: 1)
    verdict("builder", "approve", seq: 2)
    run = turn_ended("%9")
    design = run["steps"]["design"]["attempts"].last
    expect(design["outcome"]).to eq("passed")
    expect(design["review_outcome"]).to eq("round" => 1, "approvals" => 2, "need" => 2, "must" => ["skeptic"], "passed" => true)
    expect(design["reviews"].map { |row| row.values_at("reviewer", "verdict", "counted") }).to eq([["skeptic", "approve", true], ["builder", "approve", true]])
    expect(run).to include("state" => "running", "current" => "implement")
  end

  # Implement proves a commit and its inbox item and spends the token budget, so verify is held until --extra-tokens.
  def implement_past_the_budget
    inbox.upsert({"type" => "note", "title" => "Implemented X-1", "dedupe_key" => "e2e:wr_1"}, reopen: true)
    run = turn_ended
    expect(outcomes(run, "implement")).to eq(["passed"])
    expect(run).to include("state" => "waiting", "current" => "verify")
    expect(run["reason"]).to include("code" => "budget_spent")
    expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
    run = engine.resume("wr_1", extra_tokens: run["reason"]["details"]["suggested"])
    expect(run).to include("state" => "running", "current" => "verify")
  end

  # Verify's check fails: on_fail goes back to implement in a fresh context. It fails again with the loop's one
  # retry used, so the run stops, and verify has spent its own max_attempts: 2 until --extra-attempts.
  def verify_looped_and_capped
    check_results << {exit_code: 1, timed_out: false}
    run = turn_ended
    expect(outcomes(run, "verify")).to eq(["failed"])
    expect(run).to include("state" => "running", "current" => "implement")
    expect(run["loops"]).to eq("verify->implement" => 1)
    expect(panes.kicks.last).to include(fresh: true)

    tick
    inbox.upsert({"type" => "note", "title" => "Implemented X-1 again", "dedupe_key" => "e2e:wr_1"}, reopen: true)
    expect(turn_ended["current"]).to eq("verify")

    check_results << {exit_code: 1, timed_out: false}
    run = turn_ended
    expect(run).to include("state" => "waiting", "current" => "verify")
    expect(run["reason"]).to include("code" => "failed_check")
    expect { engine.resume("wr_1") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("step_attempts_spent") }
    run = engine.resume("wr_1", extra_attempts: 1)
    expect(run["steps"]["verify"]).to include("state" => "running", "extra_attempts" => 1)
  end

  describe "person commands and agent outcomes" do
    def stored = stored_run(store, "wr_1")

    def test_db_holder = Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status("test-db").dig("test-db", "holder")

    def review_pane = "%9"

    # Research and the plan done, then design reviewed: implement, then verify begun holding test-db.
    # Each verdict's seq is its place in the hook event log (skeptic first, then builder), which the tally checks for gaps.
    def to_verify
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)
      turn_ended(review_pane)
      inbox.upsert({"type" => "note", "title" => "Implemented X-1", "dedupe_key" => "e2e:wr_1"}, reopen: true)
      run = turn_ended
      engine.resume("wr_1", extra_tokens: run["reason"]["details"]["suggested"])
    end

    it "cancels a run while verify holds the test-db lock, freeing the lock and the pane and closing the attempt" do
      to_verify
      expect(stored).to include("state" => "running", "current" => "verify")
      expect(test_db_holder).not_to be_nil
      expect(panes.bound.values.map { |entry| entry[:run_id] }).to include("wr_1")

      run = engine.cancel("wr_1")

      expect(run).to include("state" => "cancelled", "cancelled_by" => "cancel")
      expect(history).to include("run_cancelled")
      expect(test_db_holder).to be_nil
      expect(panes.bound.values.map { |entry| entry[:run_id] }).not_to include("wr_1")
      attempt = run["steps"]["verify"]["attempts"].last
      expect(attempt).to include("outputs" => [], "usage" => a_kind_of(Hash), "head" => {"before" => "1" * 40, "after" => "1" * 40})
      expect(attempt).to include("ended_at" => now.first.utc.iso8601, "outcome" => "cancelled")
    end

    it "keeps a step that ended its turn without its produces file running, and a resume with a note delivers it again" do
      start
      run = turn_ended
      expect(run["reason"]).to include("code" => "turn_ended_incomplete")
      kicks = panes.kicks.size

      engine.resume("wr_1", note: "Please write research.md.", pane: "%5")
      expect(panes.kicks.size).to eq(kicks + 1)
      expect(File.read(File.join(worktree, ".workflow", "wr_1", "steps", "research.2.prompt.md"))).to include("Please write research.md.")
      expect(stored["steps"]["research"]["attempts"].size).to eq(2)

      artifact("research.md")
      run = turn_ended
      expect(outcomes(run, "research")).to eq([nil, "passed"])
      expect(run["current"]).to eq("plan")
    end

    it "records an agent's fail report on research as a failed attempt that stops the run, research having no on_fail" do
      start
      engine.report("wr_1", status: "fail", summary: "Cannot find the code.")
      artifact("research.md")
      run = turn_ended

      expect(history).to include("step_reported")
      expect(outcomes(run, "research")).to eq(["failed"])
      expect(run["steps"]["research"]["attempts"].last["reported"]).to include("status" => "fail", "summary" => "Cannot find the code.")
      expect(run).to include("state" => "waiting", "current" => "research")
      expect(run["reason"]).to include("code" => "failed_check")
      expect(panes.bound.values.map { |entry| entry[:run_id] }).to include("wr_1")
    end

    it "restarts at implement with an extra attempt once verify has spent its attempts" do
      to_verify
      check_results << {exit_code: 1, timed_out: false}
      run = turn_ended
      expect(run["current"]).to eq("implement")
      inbox.upsert({"type" => "note", "title" => "Again", "dedupe_key" => "e2e:wr_1"}, reopen: true)
      run = turn_ended
      expect(run["current"]).to eq("verify")
      check_results << {exit_code: 1, timed_out: false}
      run = turn_ended
      expect(outcomes(run, "verify")).to eq(%w[failed failed])
      expect(run).to include("state" => "waiting", "current" => "verify")
      expect(run["reason"]).to include("code" => "failed_check")

      run = engine.resume("wr_1", from: "implement", extra_attempts: 1)
      expect(run["current"]).to eq("implement")
      expect(run["steps"]["implement"]["attempts"].size).to eq(3)

      inbox.upsert({"type" => "note", "title" => "A third time", "dedupe_key" => "e2e:wr_1"}, reopen: true)
      turn_ended
      run = turn_ended
      expect(run["state"]).to eq("completed")
    end

    it "stops research failed_check with head_moved when the guard says so, and a plain resume only meets the guard again" do
      start
      allow(guard).to receive(:check).and_return({"code" => "head_moved", "base_sha" => "0" * 40, "head" => "2" * 40})
      artifact("research.md")
      run = turn_ended

      expect(run).to include("state" => "waiting", "current" => "research")
      expect(run["reason"]).to include("code" => "failed_check")
      expect(run["reason"]["details"]).to include("code" => "head_moved", "guard" => "head_moved", "cause" => "guard")
      expect(outcomes(run, "research")).to eq(["failed"])
      # Pinned current behaviour: a plain resume dispatches again though status offers only cancel for a moved HEAD (a fix follows).
      engine.resume("wr_1")
      expect(stored).to include("state" => "running", "current" => "research")
      expect(stored["steps"]["research"]["attempts"].size).to eq(2)
      artifact("research.md")
      run = turn_ended
      expect(run).to include("state" => "waiting", "current" => "research")
      expect(run["reason"]["details"]).to include("guard" => "head_moved")
      expect(outcomes(run, "research")).to eq(%w[failed failed])
    end
  end
end
