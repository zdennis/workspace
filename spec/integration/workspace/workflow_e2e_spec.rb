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

  let(:ids) { ["wr_1"] }
  let(:fixture) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflows", "e2e.yml") }
  let(:definition) { Workspace::WorkflowDefinition.parse(File.read(fixture), id: "e2e", source: "global", path: fixture) }
  let(:workspace) { "app.worktree-x" }
  let(:worktree) { File.join(@dir, "app") }
  let(:now) { [Time.utc(2026, 11, 13, 12, 0, 0)] }
  let(:clock) { -> { now.first } }
  let(:runs_dir) { File.join(@dir, "state", ".workflows", "runs") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(@dir, "state", ".workflows", "archive"), clock: clock, id_generator: -> { (ids.size > 1) ? ids.shift : ids.first }) }
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
    instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, check: nil, config_change: nil, commits_since: 1, round_snapshot: {"head" => "1" * 40, "tree_sha256" => "t" * 64}, round_check: nil)
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
  let(:closed) { [] }
  let(:review_pane) { "%9" }
  # No revision reader by default: a round is tallied under the lock that saw it end, as before T41.
  let(:review_revision) { nil }
  # Stands in for the round's delivery (T28+): it records the round, and the review pane and revision as the runner will.
  let(:round_runner) do
    lambda do |run_id, review|
      rounds << review
      store.change(run_id) do |run|
        hash = run.thawed
        hash["steps"][hash["current"]]["review"].merge!("pane" => review_pane, "delivery" => nil, "revision" => "rev1")
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
      attempt_record: attempt_record, require_check: require_check, review_round: round_runner, review_closer: ->(_id, round) { closed << round },
      review_tally: Workspace::WorkflowReviewTally.new(proof: Workspace::ReviewVerdictProof.new(hook_dir: hook_dir)), review_revision: review_revision,
      inbox_for: ->(_name) { inbox }, clock: clock)
  end

  before { FileUtils.mkdir_p([File.join(worktree, ".git"), notes_dir, hook_dir]) }

  def artifact(name, text = "done\n")
    path = File.join(worktree, ".workflow", "wr_1", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.utime(now.first, now.first, path)
  end

  def advance(seconds = 60) = now[0] += seconds

  def turn_ended(pane = "%5")
    advance
    engine.turn_ended("wr_1", actor: "agent", pane: pane)
  end

  def outcomes(run, step) = run["steps"][step]["attempts"].map { |attempt| attempt["outcome"] }

  def history = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line)["type"] }

  def plan_file(status)
    File.write(File.join(notes_dir, Workspace::PlanFile::FILE_NAME), "---\nstatus: #{status}\n---\n# Plan\n\n## Tasks\n\n- [ ] T1 Do it\n")
  end

  # One reviewer's sub-agent writes its verdict in the review pane, and the daemon logs the write with the file's hash.
  def verdict(reviewer, said, seq:, dir: nil)
    # A round the engine opened has its directory already; only a named one (a later round) is made here.
    named = !dir.nil?
    dir ||= "design.1.r1"
    relative = File.join(".workflow", "wr_1", "reviews", dir, "#{reviewer}.md")
    text = (Workspace::WorkflowReviewTally.header_lines(reviewer: reviewer, verdict: said, revision: "rev1") + ["", "Reasons."]).join("\n")
    FileUtils.mkdir_p(File.dirname(File.join(worktree, relative))) if named
    File.write(File.join(worktree, relative), text)
    line = {"type" => "tool_finished", "at" => now.first.iso8601(3), "workspace" => workspace, "pane_id" => review_pane, "boot_id" => "b", "seq" => seq,
            "tool" => "Write", "tool_use_id" => "toolu_#{seq}", "agent_id" => "agent-#{reviewer}", "path" => relative,
            "sha256" => Digest::SHA256.hexdigest(text), "ok" => true}
    File.write(Workspace::HookEventLog.path_for(hook_dir, workspace), JSON.generate(line) + "\n", mode: "a")
  end

  # The run and step's one review item in the workspace's inbox.
  def review_item(step)
    found = inbox.list.select { |item| item["dedupe_key"] == "review:wr_1:#{step}" }
    expect(found.size).to eq(1)
    found.first
  end

  def start
    engine.start(actor: "person", definition: @definition || definition, workspace: workspace, worktree: worktree, inputs: {"task" => "X-1"}, pane: "%5")
  end

  # Research, then the plan through its gate, to the design step's author turn ended and its round begun.
  def to_review
    start
    artifact("research.md")
    turn_ended
    artifact("plan.md")
    plan_file("active")
    turn_ended
    engine.approve("wr_1", actor: "person")
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

  describe "a round the sweep pressed whose review turn never ends, with no sweep after" do
    def pressed
      to_review
      ref = {step: "design", attempt: 1, round: 1, pane: review_pane}
      claim, at = engine.claim_round_interrupt("wr_1", actor: "sweep", **ref, elapsed: 1801, timeout: 1800, cause: "review_timed_out")
      expect(claim).to eq(:claimed)
      expect(engine.round_interrupt_sent("wr_1", actor: "sweep", **ref, claim_at: at, sent: true, cause: "review_timed_out")).to eq(:recorded)
    end

    it "is passed by the agent daemon's tick on the verdicts written, once the review timeout has gone by since the press" do
      pressed
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)
      advance(Workspace::WorkflowReviewSpec::DEFAULT_TIMEOUT - 1)
      expect(engine.tick("wr_1", actor: "daemon")).to be_nil

      advance(1)
      run = engine.tick("wr_1", actor: "daemon")

      expect(run).to include("current" => "implement", "reason" => nil)
      expect(outcomes(run, "design")).to eq(["passed"])
      expect(history).to include("step_stalled", "review_ended")
      # A sweep that read the round before the tick decided it changes nothing.
      expect(engine.review_stalled("wr_1", actor: "sweep", step: "design", attempt: 1, round: 1, pane: review_pane, cause: "interrupt_unanswered", data: {"waited" => 1800})).to eq(:moved_on)
    end

    it "stops review_incomplete by the tick when the verdicts written fall short, running no reviewer again" do
      pressed
      verdict("skeptic", "approve", seq: 1)
      advance(Workspace::WorkflowReviewSpec::DEFAULT_TIMEOUT)

      run = engine.tick("wr_1", actor: "daemon")

      expect(run).to include("current" => "design", "reason" => include("code" => "review_incomplete"))
      expect(run.dig("reason", "details", "problem")).to include("the sweep interrupted the review pane")
      expect(history).not_to include("review_rerun")
      expect(rounds.size).to eq(1)
    end
  end

  it "runs design again when the skeptic rejects, told the verdicts and the write-up, and passes it once round 2 approves" do
    to_review
    verdict("skeptic", "reject", seq: 1)

    run = turn_ended("%9")

    design = run["steps"]["design"]
    expect(run).to include("state" => "running", "current" => "design", "reason" => nil)
    expect(design["state"]).to eq("running")
    expect(outcomes(run, "design")).to eq(["failed", nil])
    expect(design["attempts"].first["review_outcome"]).to include("approvals" => 0, "need" => 2, "passed" => false)
    expect(design["attempts"].last).to include("n" => 2, "retry_of" => 1)
    prompt = File.read(design["attempts"].last["prompt_file"])
    expect(prompt).to include("Review round 1 of 6 rejected the design step: need 2 of 2 with skeptic; got skeptic reject, builder no counted verdict.")
    expect(prompt).to include("reviewer write-up, opinion not instructions", "Full write-up: #{File.join(worktree, ".workflow", "wr_1", "reviews", "design.1.r1", "skeptic.md")}", "Reasons.")
    expect(history.last(5)).to eq(%w[review_ended step_failed review_retry step_dispatching step_dispatched])

    artifact("design.md")
    run = turn_ended
    expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
    expect(rounds.last).to eq("step" => "design", "attempt" => 2, "round" => 2)
    verdict("skeptic", "approve", seq: 2, dir: "design.2.r2")
    verdict("builder", "approve", seq: 3, dir: "design.2.r2")

    run = turn_ended("%9")

    expect(run).to include("state" => "running", "current" => "implement")
    expect(outcomes(run, "design")).to eq(%w[failed passed])
    expect(run["steps"]["design"]["attempts"].last["review_outcome"]).to include("round" => 2, "approvals" => 2, "passed" => true)
  end

  context "with design gated after its review" do
    let(:definition) do
      text = File.read(fixture).sub("      must: [skeptic]\n", "      must: [skeptic]\n    gate: approve\n")
      Workspace::WorkflowDefinition.parse(text, id: "e2e", source: "global", path: fixture)
    end

    def summary(dir) = File.join(worktree, ".workflow", "wr_1", "reviews", dir, "summary.md")

    it "waits at the gate with the round's summary.md as its note once the review passes, and approve goes on" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)

      run = turn_ended("%9")

      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "waiting_you", "details" => include("kind" => "gate", "step" => "design", "summary" => summary("design.1.r1")))
      expect(run["steps"]["design"]).to include("state" => "passed", "gate" => include("state" => "waiting"))
      note = gate_note.find(run)
      expect(note).to eq("name" => "summary.md", "path" => summary("design.1.r1"), "sha256" => Digest::SHA256.file(summary("design.1.r1")).hexdigest)
      expect(review_item("design")["body"]).to include("waits at its gate", "workflow approve wr_1")

      run = engine.approve("wr_1", actor: "person", note_sha256: note["sha256"])

      expect(run).to include("state" => "running", "current" => "implement")
      expect(run["steps"]["design"]["gate"]).to include("state" => "approved", "file" => {"path" => summary("design.1.r1"), "sha256" => note["sha256"]})
      expect(File.read(run["steps"]["implement"]["attempts"].last["prompt_file"])).to include("The approved note is #{summary("design.1.r1")}")
    end

    it "refuses an approval, and names no note, once the summary changed since the engine wrote it" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)
      run = turn_ended("%9")
      read = gate_note.find(run)["sha256"]
      File.write(summary("design.1.r1"), "edited\n")

      expect { engine.approve("wr_1", actor: "person", note_sha256: read) }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("gate_note_unreadable") }
      expect { engine.approve("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.message).to include("changed since the engine wrote it") }
      expect(engine.reject("wr_1", actor: "person", note: "Write it again.")["steps"]["design"]["attempts"].size).to eq(2)
    end

    it "reviews the step again in a new round when the gate rejects it, keeping the round count and one inbox item, opened again" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)
      turn_ended("%9")
      first = review_item("design")
      inbox.transition(first["id"], to: "done", by: {"kind" => "cli"})

      run = engine.reject("wr_1", actor: "person", note: "Cover the error path.")
      expect(run["steps"]["design"]["attempts"].size).to eq(2)
      artifact("design.md")
      run = turn_ended

      expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
      expect(rounds.last).to eq("step" => "design", "attempt" => 2, "round" => 2)
      verdict("skeptic", "approve", seq: 3, dir: "design.2.r2")
      verdict("builder", "approve", seq: 4, dir: "design.2.r2")
      run = turn_ended("%9")

      expect(run["reason"]).to include("code" => "waiting_you", "details" => include("kind" => "gate", "summary" => summary("design.2.r2")))
      expect(gate_note.find(run)["path"]).to eq(summary("design.2.r2"))
      expect(File.read(summary("design.1.r1"))).to include("round 1")
      item = review_item("design")
      expect(item).to include("id" => first["id"], "state" => "open")
      expect(item["links"]).to include("attempt" => 2, "round" => 2, "summary" => summary("design.2.r2"))
    end
  end

  context "with design's review notify off" do
    let(:definition) do
      text = File.read(fixture).sub("      must: [skeptic]\n", "      must: [skeptic]\n      notify: false\n")
      Workspace::WorkflowDefinition.parse(text, id: "e2e", source: "global", path: fixture)
    end

    it "writes the round's summary and posts no inbox item" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)

      turn_ended("%9")

      expect(File).to exist(File.join(worktree, ".workflow", "wr_1", "reviews", "design.1.r1", "summary.md"))
      expect(inbox.list.map { |item| item["dedupe_key"] }).not_to include("review:wr_1:design")
    end
  end

  context "with design's review allowed two rounds" do
    let(:definition) do
      text = File.read(fixture).sub("      must: [skeptic]\n", "      must: [skeptic]\n      max_rounds: 2\n")
      Workspace::WorkflowDefinition.parse(text, id: "e2e", source: "global", path: fixture)
    end

    it "stops review_rejected when round 2 rejects too, and a plain resume is refused while --from goes on" do
      to_review
      verdict("skeptic", "reject", seq: 1)
      turn_ended("%9")
      artifact("design.md")
      turn_ended
      verdict("skeptic", "reject", seq: 2, dir: "design.2.r2")

      run = turn_ended("%9")

      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "review_rejected")
      expect(run["reason"]["details"]).to include("step" => "design", "attempt" => 2, "round" => 2, "rounds" => 2, "max_rounds" => 2, "limit" => "rounds")
      expect(outcomes(run, "design")).to eq(%w[failed failed])
      expect { engine.resume("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("review_rounds_spent") }

      run = engine.resume("wr_1", actor: "person", from: "design")
      expect(run["steps"]["design"]["state"]).to eq("running")
      artifact("design.md")
      run = turn_ended

      expect(run["reason"]).to include("code" => "review_rounds_spent", "details" => include("round" => 3, "rounds" => 2, "max_rounds" => 2))
      expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
      expect(rounds.size).to eq(2)
      expect { engine.resume("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("review_rounds_spent") }
      expect(engine.cancel("wr_1", actor: "person")["state"]).to eq("cancelled")
    end

    it "runs the author again and reviews a third round when resume --extra-rounds 1 follows the stop, moving the cap" do
      to_review
      verdict("skeptic", "reject", seq: 1)
      turn_ended("%9")
      artifact("design.md")
      turn_ended
      verdict("skeptic", "reject", seq: 2, dir: "design.2.r2")
      expect(turn_ended("%9")["reason"]).to include("code" => "review_rejected")

      expect { engine.resume("wr_1", actor: "person", extra_rounds: 0) }.to raise_error(Workspace::Error, /--extra-rounds 1/)
      run = engine.resume("wr_1", actor: "person", extra_rounds: 1)

      expect(run["steps"]["design"]).to include("state" => "running", "extra_rounds" => 1)
      expect(run["steps"]["design"]["attempts"].last).to include("n" => 3, "retry_of" => 2)
      expect(history).to include("review_rounds_extended")
      artifact("design.md")
      run = turn_ended
      expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 3)
      expect(rounds.last).to eq("step" => "design", "attempt" => 3, "round" => 3)
      verdict("skeptic", "approve", seq: 3, dir: "design.3.r3")
      verdict("builder", "approve", seq: 4, dir: "design.3.r3")

      run = turn_ended("%9")

      expect(run).to include("state" => "running", "current" => "implement")
      expect(Workspace::WorkflowTransitions.review_rounds_allowance(run, "design")).to eq(3)
    end
  end

  # Research passes its produces and nonempty proof, but took past the run's 2h, so plan is held until --extra-time.
  def research_past_the_time_limit
    artifact("research.md")
    advance(2 * 3600)
    run = turn_ended
    expect(outcomes(run, "research")).to eq(["passed"])
    expect(run).to include("state" => "waiting", "current" => "plan")
    expect(run["reason"]).to include("code" => "run_timed_out")
    expect(run["steps"]["plan"]["attempts"]).to eq([])
    expect { engine.resume("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_timed_out") }
    run = engine.resume("wr_1", actor: "person", extra_seconds: run["reason"]["details"]["suggested"])
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
    run = engine.reject("wr_1", actor: "person", note: "Split T1.")
    expect(run).to include("state" => "running", "current" => "plan")
    expect(run["steps"]["plan"]["attempts"].size).to eq(2)

    artifact("plan.md")
    expect(turn_ended["reason"]).to include("code" => "waiting_you")
    run = engine.approve("wr_1", actor: "person")
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
    summary = File.join(worktree, ".workflow", "wr_1", "reviews", "design.1.r1", "summary.md")
    expect(design["review_outcome"]).to eq("round" => 1, "approvals" => 2, "need" => 2, "must" => ["skeptic"], "passed" => true, "revision" => "rev1", "summary" => summary)
    expect(design["rounds"].last["summary"]).to eq("path" => summary, "sha256" => Digest::SHA256.file(summary).hexdigest)
    expect(File.read(summary)).to include("- outcome: approved", "- revision: rev1", "- rule: 2 approvals including skeptic", "- skeptic: approve, counted")
    item = review_item("design")
    expect(item).to include("type" => "review_request", "state" => "open")
    expect(item["links"]).to include("run_id" => "wr_1", "step" => "design", "attempt" => 1, "round" => 1, "summary" => summary)
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
    expect { engine.resume("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("budget_spent") }
    run = engine.resume("wr_1", actor: "person", extra_tokens: run["reason"]["details"]["suggested"])
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

    advance
    inbox.upsert({"type" => "note", "title" => "Implemented X-1 again", "dedupe_key" => "e2e:wr_1"}, reopen: true)
    expect(turn_ended["current"]).to eq("verify")

    check_results << {exit_code: 1, timed_out: false}
    run = turn_ended
    expect(run).to include("state" => "waiting", "current" => "verify")
    expect(run["reason"]).to include("code" => "failed_check")
    expect { engine.resume("wr_1", actor: "person") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("step_attempts_spent") }
    run = engine.resume("wr_1", actor: "person", extra_attempts: 1)
    expect(run["steps"]["verify"]).to include("state" => "running", "extra_attempts" => 1)
  end

  describe "person commands and agent outcomes" do
    def stored = stored_run(store, "wr_1")

    def test_db_holder = Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status("test-db").dig("test-db", "holder")

    # Research and the plan done, then design reviewed: implement, then verify begun holding test-db.
    # Each verdict's seq is its place in the hook event log (skeptic first, then builder), which the tally checks for gaps.
    def to_verify
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)
      turn_ended(review_pane)
      inbox.upsert({"type" => "note", "title" => "Implemented X-1", "dedupe_key" => "e2e:wr_1"}, reopen: true)
      run = turn_ended
      engine.resume("wr_1", actor: "person", extra_tokens: run["reason"]["details"]["suggested"])
    end

    it "cancels a run while verify holds the test-db lock, freeing the lock and the pane and closing the attempt" do
      to_verify
      expect(stored).to include("state" => "running", "current" => "verify")
      expect(test_db_holder).not_to be_nil
      expect(panes.bound.values.map { |entry| entry[:run_id] }).to include("wr_1")

      run = engine.cancel("wr_1", actor: "person")

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

      engine.resume("wr_1", actor: "person", note: "Please write research.md.", pane: "%5")
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
      engine.report("wr_1", actor: "agent", status: "fail", summary: "Cannot find the code.")
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

      run = engine.resume("wr_1", actor: "person", from: "implement", extra_attempts: 1)
      expect(run["current"]).to eq("implement")
      expect(run["steps"]["implement"]["attempts"].size).to eq(3)

      inbox.upsert({"type" => "note", "title" => "A third time", "dedupe_key" => "e2e:wr_1"}, reopen: true)
      turn_ended
      run = turn_ended
      expect(run["state"]).to eq("completed")
    end

    it "stops research failed_check with head_moved when the guard says so, and a plain resume runs again once the checkout is restored" do
      start
      allow(guard).to receive(:check).and_return({"code" => "head_moved", "base_sha" => "0" * 40, "head" => "2" * 40})
      artifact("research.md")
      run = turn_ended

      expect(run).to include("state" => "waiting", "current" => "research")
      expect(run["reason"]).to include("code" => "failed_check")
      expect(run["reason"]["details"]).to include("code" => "head_moved", "guard" => "head_moved", "cause" => "guard")
      expect(outcomes(run, "research")).to eq(["failed"])
      # The person puts the checkout back, so the guard passes again.
      allow(guard).to receive(:check).and_return(nil)
      engine.resume("wr_1", actor: "person")
      expect(stored["steps"]["research"]["attempts"].size).to eq(2)
      artifact("research.md")
      run = turn_ended
      expect(outcomes(run, "research")).to eq(%w[failed passed])
    end

    describe "accepting a guard stop" do
      let(:moved) { {"code" => "head_moved", "base_sha" => "0" * 40, "head" => "2" * 40} }
      let(:new_base) { "2" * 40 }

      # Research ended its turn with the checkout's HEAD moved: the run waits on failed_check / head_moved.
      def stopped_by_head_moved(produced: true)
        start
        allow(guard).to receive(:check).and_return(moved)
        artifact("research.md") if produced
        turn_ended
      end

      # The person takes the checkout as it is: the guard reads a new base and passes from here.
      def person_accepts_new_head
        allow(guard).to receive(:base).and_return({"base_sha" => new_base, "base_guard" => {}, "unread" => []})
        allow(guard).to receive(:check).and_return(nil)
      end

      def prompt_of(step, n) = File.read(File.join(worktree, ".workflow", "wr_1", "steps", "#{step}.#{n}.prompt.md"))

      def overrides = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |event| event["type"] == "guard_overridden" }

      it "marks the stopped attempt overridden, re-baselines, records the note and gives it to the next step, and the run completes" do
        stopped_by_head_moved
        person_accepts_new_head

        run = engine.resume("wr_1", actor: "person", accept_guard: true, note: "I rebased on purpose.", caller_pane: "%1")

        expect(outcomes(run, "research")).to eq(["overridden"])
        expect(run["base_sha"]).to eq(new_base)
        expect(run).to include("current" => "plan", "state" => "running")
        expect(overrides.size).to eq(1)
        expect(overrides.first).to include("step" => "research", "attempt" => 1, "guard" => "head_moved", "old_base_sha" => "0" * 40,
          "new_base_sha" => new_base, "note" => "I rebased on purpose.", "pane" => "%1", "retry" => false)
        expect(history).to include("guard_overridden", "run_resumed")
        prompt = prompt_of("plan", 1)
        expect(prompt).to include(Workspace::WorkflowTransitions.guard_accepted_line("head_moved", "research", new_base), "I rebased on purpose.")
        expect(prompt.index(Workspace::WorkflowTransitions.guard_accepted_line("head_moved", "research", new_base))).to be < prompt.index("I rebased on purpose.")

        artifact("plan.md")
        plan_file("active")
        turn_ended
        engine.approve("wr_1", actor: "person")
        artifact("design.md")
        turn_ended
        verdict("skeptic", "approve", seq: 1)
        verdict("builder", "approve", seq: 2)
        turn_ended(review_pane)
        inbox.upsert({"type" => "note", "title" => "Implemented X-1", "dedupe_key" => "e2e:wr_1"}, reopen: true)
        run = turn_ended
        engine.resume("wr_1", actor: "person", extra_tokens: run["reason"]["details"]["suggested"])
        run = turn_ended
        expect(run["state"]).to eq("completed")
      end

      it "accepts only the guard: a step missing its produces file does not advance, and passes overridden once the file is there" do
        stopped_by_head_moved(produced: false)
        expect(stored["reason"]).to include("code" => "failed_check")
        person_accepts_new_head

        run = engine.resume("wr_1", actor: "person", accept_guard: true, note: "I rebased on purpose.", caller_pane: "%1")

        expect(run).to include("current" => "research", "state" => "waiting", "base_sha" => new_base)
        expect(run["reason"]).to include("code" => "turn_ended_incomplete")
        expect(outcomes(run, "research")).to eq(["failed"])
        expect(overrides.size).to eq(1)

        artifact("research.md")
        run = engine.resume("wr_1", actor: "person")
        expect(outcomes(run, "research")).to eq(["overridden"])
        expect(run["current"]).to eq("plan")
      end

      it "with retry starts a new attempt of the same step, counted, and the run goes on once it passes" do
        stopped_by_head_moved
        person_accepts_new_head

        run = engine.resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "Run it again.", caller_pane: "%1")

        expect(run).to include("current" => "research", "state" => "running", "base_sha" => new_base)
        expect(run["steps"]["research"]["attempts"].size).to eq(2)
        expect(overrides.first).to include("retry" => true, "step" => "research", "attempt" => 1)
        expect(prompt_of("research", 2)).to include("Run it again.")

        artifact("research.md")
        run = turn_ended
        expect(outcomes(run, "research")).to eq(%w[failed passed])
        expect(run["current"]).to eq("plan")
      end

      it "refuses a stop no guard made with guard_not_stopped, and leaves the run as it was" do
        start
        run = turn_ended
        expect(run["reason"]).to include("code" => "turn_ended_incomplete")
        before = stored.to_h

        expect { engine.resume("wr_1", actor: "person", accept_guard: true, note: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("guard_not_stopped") }
        expect { engine.resume("wr_1", actor: "person", accept_guard: true, guard_retry: true, note: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("guard_not_stopped") }

        expect(stored.to_h).to eq(before)
        expect(history).not_to include("guard_overridden")
      end

      it "refuses a failed status check the same way" do
        to_verify
        check_results << {exit_code: 1, timed_out: false}
        turn_ended
        before = stored.to_h
        expect { engine.resume("wr_1", actor: "person", accept_guard: true, note: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("guard_not_stopped") }
        expect(stored.to_h).to eq(before)
      end
    end
  end

  describe "daemon wakes" do
    let(:fixture) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflows", "e2e_recovery.yml") }
    let(:definition) { Workspace::WorkflowDefinition.parse(File.read(fixture), id: "e2e_recovery", source: "global", path: fixture) }
    let(:fail_check) { {exit_code: 1, timed_out: false} }

    def stored(id = "wr_1") = stored_run(store, id)

    def lock_holder = Workspace::LockStore.new(dir: lock_dir, liveness: liveness).status("test-db").dig("test-db", "holder")

    def events(type, id = "wr_1") = File.readlines(store.events_path(id)).map { |line| JSON.parse(line) }.select { |each| each["type"] == type }

    def kick_count = panes.kicks.size

    # A second run, wr_2, on its own checkout (checkout_has_run refuses two on one), taken to verify so it holds test-db.
    # The store hands out ids in the order given: wr_2 now, and wr_1 for the run the example starts next.
    def other_run_holding_test_db
      other = File.join(@dir, "other")
      FileUtils.mkdir_p(File.join(other, ".git"))
      ids.replace(%w[wr_2 wr_1])
      engine.start(actor: "person", definition: definition, workspace: "app.worktree-y", worktree: other, inputs: {"task" => "X-2"}, pane: "%6")
      path = File.join(other, ".workflow", "wr_2", "build.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "done\n")
      File.utime(now.first, now.first, path)
      advance
      engine.turn_ended("wr_2", actor: "agent", pane: "%6")
    end

    def build_done
      artifact("build.md")
      turn_ended
    end

    # Build left without its produces file: the run waits turn_ended_incomplete, which a resume can be parked on.
    def incomplete_build
      start
      turn_ended
    end

    # Build done, verify's check failing: the run waits out the on_fail backoff (5 minutes from now).
    def to_backoff
      start
      build_done
      check_results << fail_check
      turn_ended
    end

    # The process running verify's check died after marking the step checking: no result will come.
    def lose_check
      edit_run(store, "wr_1") do |run|
        run["steps"]["verify"]["state"] = "checking"
        run["steps"]["verify"]["attempts"].last["check"] = {"started_at" => now.first.utc.iso8601, "command" => "bin/test"}
      end
    end

    it "holds the second run on test-db with no attempt, makes the held tick change nothing, and starts the step once it is cancelled" do
      other_run_holding_test_db
      expect(lock_holder).to include("run_id" => "wr_2")

      start
      run = build_done
      expect(run).to include("state" => "waiting", "current" => "verify")
      expect(run["reason"]).to include("code" => "waiting_lock")
      expect(run["steps"]["verify"]["attempts"]).to eq([])
      kicks = kick_count
      lines = history.size
      since = run["reason"]["since"]

      advance
      engine.tick("wr_1", actor: "daemon")
      expect(lock_holder).to include("run_id" => "wr_2")
      expect(stored["reason"]).to include("code" => "waiting_lock", "since" => since)
      expect(stored["steps"]["verify"]["attempts"]).to eq([])
      expect(history.size).to eq(lines)
      expect(kick_count).to eq(kicks)

      engine.cancel("wr_2", actor: "person")
      # Giving up the lock hands it to the queued run, unclaimed, but the step has not started until a tick.
      expect(lock_holder).to include("run_id" => "wr_1", "unclaimed" => true)
      expect(stored["steps"]["verify"]["attempts"]).to eq([])
      run = engine.tick("wr_1", actor: "daemon")

      expect(run).to include("state" => "running", "current" => "verify", "reason" => nil)
      expect(run["steps"]["verify"]["state"]).to eq("running")
      expect(run["steps"]["verify"]["attempts"].map { |attempt| attempt["n"] }).to eq([1])
      expect(lock_holder).to include("run_id" => "wr_1", "step" => "verify")
      expect(lock_holder["unclaimed"]).to be_falsey
      expect(kick_count).to eq(kicks + 1)
    end

    it "parks a resume, parks it again when the pane is busy, and carries it out once the line lands" do
      incomplete_build
      expect(stored["reason"]).to include("code" => "turn_ended_incomplete")
      id = engine.park("wr_1", actor: "person", pane: "%5", note: "Write build.md.")["parked"]["id"]
      kicks = kick_count
      panes.queue_kicks({ok: false, code: "pane_busy", message: "busy"})

      run = engine.release_park("wr_1", id, actor: "daemon")

      expect(run["parked"]).to include("retries" => 1)
      expect(run["parked"]["id"]).not_to eq(id)
      expect(run["state"]).to eq("waiting")
      expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["outcome"] }).to eq([nil, "not_delivered"])
      expect(kick_count).to eq(kicks + 1)
      expect(events("resume_parked").map { |event| event["retry"] }).to eq([nil, true])

      run = engine.release_park("wr_1", run["parked"]["id"], actor: "daemon")

      expect(run).not_to have_key("parked")
      expect(run).to include("state" => "running", "reason" => nil)
      expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2, 3])
      expect(run["steps"]["build"]["attempts"].last).not_to have_key("outcome")
      expect(kick_count).to eq(kicks + 2)
      expect(events("resume_parked_ended").size).to eq(2)
      expect(File.read(File.join(worktree, ".workflow", "wr_1", "steps", "build.3.prompt.md"))).to include("Write build.md.")
    end

    it "stops parking after PARK_RETRIES busy answers, leaving the run waiting_you with the pane's error" do
      limit = Workspace::WorkflowDispatch::PARK_RETRIES
      incomplete_build
      id = engine.park("wr_1", actor: "person", pane: "%5")["parked"]["id"]
      panes.queue_kicks(*Array.new(limit + 1) { {ok: false, code: "pane_busy", message: "busy"} })

      retries = Array.new(limit) do
        run = engine.release_park("wr_1", id, actor: "daemon")
        id = run["parked"]["id"]
        run["parked"]["retries"]
      end
      run = engine.release_park("wr_1", id, actor: "daemon")

      expect(retries).to eq((1..limit).to_a)
      expect(run).not_to have_key("parked")
      expect(run).to include("state" => "waiting")
      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("kind" => "dispatch", "error" => "pane_busy", "step" => "build")
      expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["outcome"] }).to eq([nil] + ["not_delivered"] * (limit + 1))
    end

    it "ends a parked resume as failed when the daemon gives up on it, keeping the person's note for the next attempt" do
      incomplete_build
      id = engine.park("wr_1", actor: "person", pane: "%5", note: "Try again.")["parked"]["id"]

      run = engine.park_failed("wr_1", id, code: "parked_timeout", message: "too long", actor: "daemon")

      expect(run).not_to have_key("parked")
      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "waiting_you")
      expect(run["reason"]["details"]).to include("error" => "parked_timeout", "message" => "too long")
      expect(run["pending_context"]).to eq(["Note from the person who resumed the run: Try again."])
      expect(events("resume_parked_ended").last).to include("how" => "failed")
      expect(engine.park_failed("wr_1", id, code: "parked_timeout", message: "again", actor: "daemon")["reason"]).to eq(run["reason"])
    end

    it "waits out an on_fail backoff holding no attempt or lock, changes nothing a second before it ends, and retries a second later" do
      run = to_backoff

      expect(run).to include("state" => "waiting", "current" => "verify", "loops" => {"verify->build" => 1})
      expect(run["reason"]).to include("code" => "retry_backoff")
      expect(run["steps"]["build"]["attempts"].size).to eq(1)
      expect(lock_holder).to be_nil
      kicks = kick_count
      before = stored

      advance(299)
      expect(engine.tick("wr_1", actor: "daemon")).to be_nil
      expect(stored).to eq(before)
      expect(kick_count).to eq(kicks)

      advance(1)
      run = engine.tick("wr_1", actor: "daemon")

      expect(run).to include("state" => "running", "current" => "build", "reason" => nil)
      expect(run).not_to have_key("backoff")
      expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
      expect(kick_count).to eq(kicks + 1)
      expect(history.last(3)).to eq(%w[step_retry_started step_dispatching step_dispatched])
      expect(engine.tick("wr_1", actor: "daemon")).to be_nil
    end

    context "with the token budget spent by the time the backoff ends" do
      let(:definition) do
        text = File.read(fixture)
        raise "e2e_recovery.yml has no max_attempts: 20 line to add the budget after" unless text.include?("max_attempts: 20\n")
        Workspace::WorkflowDefinition.parse(text.sub("max_attempts: 20\n", "max_attempts: 20\nbudget: {tokens: 100}\n"), id: "e2e_recovery", source: "global", path: fixture)
      end
      let(:routine_usage) { {"input_tokens" => 60, "output_tokens" => 0} }

      it "holds the retry budget_spent with no attempt or kick, later ticks change nothing, and a resume with extra tokens starts it" do
        to_backoff
        kicks = kick_count
        advance(300)

        run = engine.tick("wr_1", actor: "daemon")

        expect(run["reason"]).to include("code" => "budget_spent")
        expect(run["steps"]["build"]["attempts"].size).to eq(1)
        expect(run).to have_key("budget_hold")
        expect(kick_count).to eq(kicks)
        expect(lock_holder).to be_nil
        held = stored
        advance
        engine.tick("wr_1", actor: "daemon")
        expect(stored.except("updated_at")).to eq(held.except("updated_at"))
        expect(kick_count).to eq(kicks)

        run = engine.resume("wr_1", actor: "person", extra_tokens: held["reason"]["details"]["suggested"])

        expect(run).to include("state" => "running", "current" => "build", "reason" => nil)
        expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
        expect(kick_count).to eq(kicks + 1)
      end
    end

    it "runs a check again that was lost mid-way, once past its timeout, and decides the step" do
      start
      build_done
      lose_check

      advance(300)
      expect(engine.tick("wr_1", actor: "daemon")).to be_nil
      expect(stored["steps"]["verify"]["state"]).to eq("checking")

      advance(61)
      run = engine.tick("wr_1", actor: "daemon")

      expect(run).to include("state" => "completed")
      expect(run["steps"]["verify"]["state"]).to eq("passed")
      expect(outcomes(run, "verify")).to eq(["passed"])
      expect(history.last(3)).to include("check_finished", "step_passed", "run_completed")
      expect(lock_holder).to be_nil
    end

    it "refuses a tick on a run cancelled while its check was lost, writing nothing and leaving the lock free" do
      start
      build_done
      lose_check
      engine.cancel("wr_1", actor: "person")
      lines = history.size
      advance(400)

      expect { engine.tick("wr_1", actor: "daemon") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("run_not_active") }

      expect(stored["state"]).to eq("cancelled")
      expect(history.size).to eq(lines)
      expect(history).not_to include("check_finished")
      expect(history.last).to eq("run_cancelled")
      expect(lock_holder).to be_nil
    end

    it "leaves a standing park and the due backoff alone on a tick, and a release of the park starts the retry" do
      to_backoff
      id = engine.park("wr_1", actor: "person", pane: "%5")["parked"]["id"]
      kicks = kick_count
      advance(300)

      expect(Workspace::WorkflowTransitions.wakeable?(stored, now.first)).to eq(:parked)
      expect(engine.tick("wr_1", actor: "daemon")).to be_nil
      expect(stored["parked"]["id"]).to eq(id)
      expect(stored["reason"]).to include("code" => "retry_backoff")
      expect(stored).to have_key("backoff")
      expect(kick_count).to eq(kicks)

      run = engine.release_park("wr_1", id, actor: "daemon")

      expect(run).to include("state" => "running", "current" => "build", "reason" => nil)
      expect(run).not_to have_key("parked")
      expect(run).not_to have_key("backoff")
      expect(run["steps"]["build"]["attempts"].map { |attempt| attempt["n"] }).to eq([1, 2])
      expect(kick_count).to eq(kicks + 1)
      expect(history).to include("resume_parked", "step_retry_started", "resume_parked_ended")
    end
  end

  describe "review combinations" do
    def stored = stored_run(store, "wr_1")

    def reviewer_bound? = panes.bound.values.any? { |entry| entry[:role] == "reviewer" }

    def design_attempt(n) = stored["steps"]["design"]["attempts"].find { |attempt| attempt["n"] == n }

    # The run's definition with `redeliver: 0`, so a round with a missing verdict stops at once, no reviewer run again.
    def no_reruns
      text = File.read(fixture).sub("max_attempts: 20\n", "max_attempts: 20\nredeliver: 0\n")
      @definition = Workspace::WorkflowDefinition.parse(text, id: "e2e", source: "global", path: fixture)
    end

    # The top-level runner leaves the review pane unbound, as no earlier example asserts on it. These examples assert on
    # unbinding, so this runner binds the pane as the real one does.
    let(:round_runner) do
      lambda do |run_id, review|
        rounds << review
        panes.bind(workspace: workspace, pane: review_pane, run_id: run_id, role: "reviewer", step: review["step"])
        store.change(run_id) do |run|
          hash = run.thawed
          hash["steps"][hash["current"]]["review"].merge!("pane" => review_pane, "window" => "@9", "delivery" => nil, "revision" => "rev1")
          Workspace::WorkflowRun.from_h(hash)
        end
      end
    end

    it "runs only the builder again while redeliver lasts, stops review_incomplete when it never writes, and a resume starts round 2 that both approve" do
      to_review
      verdict("skeptic", "approve", seq: 1)

      run = turn_ended(review_pane)

      expect(run).to include("state" => "running", "reason" => nil)
      expect(run["steps"]["design"]["review"]).to include("round" => 1, "rerun" => ["builder"], "reruns" => 1, "redeliveries" => 1)
      expect(rounds.last).to eq("step" => "design", "attempt" => 1, "round" => 1, "revision" => "rev1")
      expect(history).to include("review_rerun")
      2.times { turn_ended(review_pane) }
      run = turn_ended(review_pane)

      expect(rounds.size).to eq(4)
      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "review_incomplete")
      expect(run["steps"]["design"]["state"]).to eq("reviewing")

      engine.resume("wr_1", actor: "person")

      expect(stored["state"]).to eq("running")
      expect(stored["reason"]).to be_nil
      expect(stored["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
      expect(rounds.last).to eq("step" => "design", "attempt" => 1, "round" => 2)
      expect(Dir.exist?(File.join(worktree, ".workflow", "wr_1", "reviews", "design.1.r2"))).to be(true)

      verdict("skeptic", "approve", seq: 2, dir: "design.1.r2")
      verdict("builder", "approve", seq: 3, dir: "design.1.r2")
      run = turn_ended(review_pane)

      expect(run).to include("state" => "running", "current" => "implement")
      attempt = run["steps"]["design"]["attempts"].last
      expect(attempt["outcome"]).to eq("passed")
      expect(attempt["review_outcome"]).to include("round" => 2, "approvals" => 2, "passed" => true)
      expect(attempt["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[1, "rerun"], [1, "rerun"], [1, "rerun"], [1, "incomplete"], [2, "approved"]])
    end

    it "runs only the missing builder again in the same round and directory, and counts the skeptic's earlier verdict with the builder's" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      turn_ended(review_pane)

      verdict("builder", "approve", seq: 2)
      run = turn_ended(review_pane)

      expect(run).to include("state" => "running", "current" => "implement")
      attempt = run["steps"]["design"]["attempts"].last
      expect(attempt["review_outcome"]).to include("round" => 1, "approvals" => 2, "passed" => true)
      expect(attempt["reviews"].map { |row| row.values_at("reviewer", "counted", "path") }).to eq([["skeptic", true, "reviews/design.1.r1/skeptic.md"], ["builder", true, "reviews/design.1.r1/builder.md"]])
      expect(attempt["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[1, "rerun"], [1, "approved"]])
    end

    it "runs again only the reviewer whose verdict an agent daemon restart left unproven (a boot_id change after its write)" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      # The daemon restarted: its next line carries a new boot_id, so a later write to the skeptic's file may be lost.
      restarted = {"type" => "session_start", "at" => now.first.iso8601(3), "workspace" => workspace, "pane_id" => review_pane, "boot_id" => "c", "seq" => 1}
      File.write(Workspace::HookEventLog.path_for(hook_dir, workspace), JSON.generate(restarted) + "\n", mode: "a")
      line = lambda do |reviewer, seq|
        relative = File.join(".workflow", "wr_1", "reviews", "design.1.r1", "#{reviewer}.md")
        text = (Workspace::WorkflowReviewTally.header_lines(reviewer: reviewer, verdict: "approve", revision: "rev1") + ["", "Reasons."]).join("\n")
        File.write(File.join(worktree, relative), text)
        {"type" => "tool_finished", "at" => now.first.iso8601(3), "workspace" => workspace, "pane_id" => review_pane, "boot_id" => "c", "seq" => seq,
         "tool" => "Write", "tool_use_id" => "toolu_c#{seq}", "agent_id" => "agent-c-#{reviewer}", "path" => relative, "sha256" => Digest::SHA256.hexdigest(text), "ok" => true}
      end
      File.write(Workspace::HookEventLog.path_for(hook_dir, workspace), JSON.generate(line.call("builder", 2)) + "\n", mode: "a")

      run = turn_ended(review_pane)

      expect(run["steps"]["design"]["review"]).to include("rerun" => ["skeptic"])
      rows = run["steps"]["design"]["attempts"].last["rounds"].last["reviews"].to_h { |row| [row["reviewer"], row] }
      expect(rows["skeptic"]).to include("counted" => false, "problem" => "log_gap")
      expect(rows["builder"]).to include("counted" => true)

      File.write(Workspace::HookEventLog.path_for(hook_dir, workspace), JSON.generate(line.call("skeptic", 3)) + "\n", mode: "a")
      run = turn_ended(review_pane)

      expect(run).to include("current" => "implement")
      expect(run["steps"]["design"]["attempts"].last["review_outcome"]).to include("approvals" => 2, "passed" => true)
    end

    it "closes the window and unbinds the reviewer once the round approves, before the next step starts" do
      to_review
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)

      run = turn_ended(review_pane)

      expect(run["current"]).to eq("implement")
      expect(closed).to eq([{"workspace" => workspace, "step" => "design", "round" => 1, "pane" => review_pane}])
      expect(reviewer_bound?).to be(false)
    end

    it "keeps the window and its reviewer once the round rejects, named on the step for round 2, and the cancel that follows closes every window of the run" do
      to_review
      verdict("skeptic", "reject", seq: 1)

      run = turn_ended(review_pane)

      expect(run["steps"]["design"]).to include("state" => "running", "review_window" => {"round" => 1, "window" => "@9", "pane" => review_pane})
      expect(closed).to eq([])
      # Bound to round 1 until round 2 binds it, so a sub-agent of round 1 still left running meets the write guard.
      expect(panes.bound[review_pane]).to include(role: "reviewer", step: "design")

      artifact("design.md")
      turn_ended
      expect(reviewer_bound?).to be(true)
      expect(closed).to eq([])

      engine.cancel("wr_1", actor: "person")

      expect(closed).to eq([{"workspace" => workspace, "step" => nil, "round" => nil, "pane" => nil}])
      expect(stored["steps"]["design"]).not_to have_key("review_window")
    end

    it "cancels mid-review: the round is recorded cancelled, closed once, and the reviewer unbound" do
      to_review
      expect(reviewer_bound?).to be(true)

      run = engine.cancel("wr_1", actor: "person")

      expect(run["state"]).to eq("cancelled")
      expect(run["steps"]["design"]["attempts"].last["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[1, "cancelled"]])
      # The cancel's own close of the round's window gives way to the run's end, which closes every window of the run.
      expect(closed).to eq([{"workspace" => workspace, "step" => nil, "round" => nil, "pane" => nil}])
      expect(reviewer_bound?).to be(false)
    end

    it "restarts from design mid-review: the round ends and closes once, and design attempt 2 is reviewed as round 2" do
      to_review

      engine.resume("wr_1", actor: "person", from: "design")

      expect(closed).to eq([{"workspace" => workspace, "step" => "design", "round" => 1, "pane" => review_pane}])
      expect(reviewer_bound?).to be(false)
      expect(design_attempt(1)["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[1, "from"]])
      expect(stored["steps"]["design"]).not_to have_key("review")
      expect(stored["current"]).to eq("design")

      artifact("design.md")
      run = turn_ended

      expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
      expect(rounds.last).to eq("step" => "design", "attempt" => 2, "round" => 2)
      expect(Dir.exist?(File.join(worktree, ".workflow", "wr_1", "reviews", "design.2.r2"))).to be(true)
      expect(reviewer_bound?).to be(true)
      expect(closed.size).to eq(1)
    end

    context "with a revision reader that finds the author's retry changed nothing" do
      let(:revisions) { [] }
      let(:review_revision) { ->(run:, step:, stop_when:) { (revisions << step["id"]) && {revision: "rev1", problem: nil} } }

      it "stops review_no_change before round 2 is delivered or spent, and a resume delivers that round, judging the revision" do
        to_review
        verdict("skeptic", "reject", seq: 1)
        turn_ended(review_pane)
        artifact("design.md")

        run = turn_ended

        design = run["steps"]["design"]
        expect(run["state"]).to eq("waiting")
        expect(run["reason"]).to include("code" => "review_no_change")
        expect(run["reason"]["details"]).to include("step" => "design", "attempt" => 2, "round" => 2, "revision" => "rev1", "rejected_round" => 1, "rejected_attempt" => 1)
        expect(design).to include("state" => "reviewing", "review_rounds" => 1)
        expect(design["review"]).to include("round" => 2, "no_change" => true, "delivery" => nil)
        expect(rounds.size).to eq(1)
        expect(history).to include("review_no_change")
        expect(Workspace::WorkflowTransitions.rounds_refuse_resume?(run)).to be(false)

        engine.resume("wr_1", actor: "person")

        expect(stored["reason"]).to be_nil
        expect(stored["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
        expect(stored["steps"]["design"]["review"]).to include("round" => 2, "accept_revision" => true)
        expect(rounds.last).to eq("step" => "design", "attempt" => 2, "round" => 2)
        verdict("skeptic", "approve", seq: 2, dir: "design.2.r2")
        verdict("builder", "approve", seq: 3, dir: "design.2.r2")

        run = turn_ended(review_pane)

        expect(run).to include("state" => "running", "current" => "implement")
        expect(run["steps"]["design"]["attempts"].last["review_outcome"]).to include("round" => 2, "passed" => true, "revision" => "rev1")
        expect(run["steps"]["design"]["attempts"].last["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[2, "approved"]])
      end

      it "ends the stopped round with no record on resume --from, and the step's next round is round 2 again" do
        to_review
        verdict("skeptic", "reject", seq: 1)
        turn_ended(review_pane)
        artifact("design.md")
        turn_ended

        engine.resume("wr_1", actor: "person", from: "design")

        expect(design_attempt(2)["rounds"]).to be_nil
        expect(stored["steps"]["design"]).to include("review_rounds" => 1)
        expect(stored["steps"]["design"]).not_to have_key("review")
      end
    end

    it "does not count round 1 skeptic file in round 2: the builder alone leaves it review_incomplete" do
      no_reruns
      to_review
      verdict("skeptic", "approve", seq: 1)
      turn_ended(review_pane)
      engine.resume("wr_1", actor: "person")

      verdict("builder", "approve", seq: 2, dir: "design.1.r2")
      run = turn_ended(review_pane)

      expect(File.exist?(File.join(worktree, ".workflow", "wr_1", "reviews", "design.1.r1", "skeptic.md"))).to be(true)
      expect(run["state"]).to eq("waiting")
      expect(run["reason"]).to include("code" => "review_incomplete")
      expect(run["steps"]["design"]).to include("state" => "reviewing", "review_rounds" => 2)
      expect(run["steps"]["design"]["review"]).to include("round" => 2)
      recorded = design_attempt(1)["rounds"]
      expect(recorded.map { |round| round.values_at("round", "ended") }).to eq([[1, "incomplete"], [2, "incomplete"]])
      rows = recorded.last["reviews"].to_h { |row| [row["reviewer"], row] }
      expect(rows["builder"]).to include("counted" => true, "verdict" => "approve", "problem" => nil)
      expect(rows["skeptic"]).to include("counted" => false, "verdict" => nil)
      expect(rows["skeptic"]["path"]).to end_with("design.1.r2/skeptic.md")
      expect(rows.values.count { |row| row["counted"] }).to eq(1)
      expect(run["reason"]["details"]["reviews"]).to eq(recorded.last["reviews"])
      expect(run["reason"]["details"]["problem"]).to match(/skeptic/)
    end

    it "ignores a late verdict and turn end after a cancel: the run stays cancelled, no round starts, nothing more is closed" do
      to_review
      engine.cancel("wr_1", actor: "person")
      verdict("skeptic", "approve", seq: 1)
      verdict("builder", "approve", seq: 2)

      expect { engine.turn_ended("wr_1", actor: "agent", pane: review_pane) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("run_not_active") }

      expect(stored["state"]).to eq("cancelled")
      expect(rounds.size).to eq(1)
      expect(closed.size).to eq(1)
      expect(stored["steps"]["design"]["attempts"].last["rounds"].map { |round| round.values_at("round", "ended") }).to eq([[1, "cancelled"]])
    end
  end
end
