require "spec_helper"
require "tmpdir"

# The engine's infra retry acts (schedule, claim, give up, release, the claimant's restart and the end of a retry
# whose stall closed) over a real run store in a temporary directory, so nothing starts a process.
RSpec.describe Workspace::WorkflowEngine do
  around do |example|
    Dir.mktmpdir("wf-infra-retry") do |dir|
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
  let(:ids) { %w[wr_1 wr_2] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir, clock: -> { now.first }, id_generator: -> { ids.shift }) }
  let(:liveness) { RunFileLiveness.new(runs_dir) }
  let(:lock_namespace) { instance_double(Workspace::LockNamespace) }
  let(:resources) { Workspace::RunResources.new(lock_namespace: lock_namespace, lock_holder: liveness, wall_clock: -> { now.first.to_i }) }
  let(:panes) { InterruptibleWorkflowPanes.new }
  let(:commands_config) { instance_double(Workspace::CommandsConfig, for_project: {test: nil, lint: nil}) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage, resolve: Workspace::WorkspaceLineage::Lineage.new(name: "app")) }
  let(:git) { FakeGit.new(worktree_branch: "feature/x") }
  let(:guard) { instance_double(Workspace::WorkflowGuard, base: {"base_sha" => "0" * 40, "base_guard" => {}}, head: "1" * 40, round_snapshot: {"head" => "1" * 40, "tree_sha256" => "t" * 64}, round_check: nil) }
  let(:event_log) { instance_double(Workspace::EventLog, record: nil) }
  let(:notes) { instance_double(Workspace::Commands::Notes, info: {"dir" => File.join(@dir, "notes")}) }
  let(:recorder) { UsageAttemptRecord.new(guard: guard, clock: -> { now.first }) }
  let(:claimant) { {"pid" => 4242, "started" => "Sun Oct  4 12:00:00 2026"} }
  let(:other) { {"pid" => 5151, "started" => "Sun Oct  4 12:00:30 2026"} }
  let(:flow) { definition("max_attempts: 5\nsteps:\n  build:\n    prompt: Build it.\n    produces: [out.md]\n  verify:\n    prompt: Verify it.\n") }

  subject(:engine) do
    Workspace.build_workflow_engine(store: store, resources: resources, composer: FakeStepComposer.new, panes: panes, checker: ->(**) { {exit_code: 0, timed_out: false} },
      commands_config: commands_config, lineage: lineage, git: git, guard: guard, excludes: Workspace::GitExclude.new(git: git),
      gate_note: Workspace::WorkflowGateNote.new(notes: notes), env_stopper: ->(**) {}, workspace_known: ->(_) { false }, event_log: event_log,
      task_store: instance_double(Workspace::TaskStore, active_for: {"id" => "t1"}), attempt_record: recorder, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(worktree)
    allow(lock_namespace).to receive(:resolve).with(cwd: worktree).and_return(key: "ns", display: "app", dir: lock_dir)
  end

  def definition(yaml) = Workspace::WorkflowDefinition.parse(yaml, id: "flow", source: "global", path: "/defs/flow.yml")

  def start(definition = flow)
    engine.start(actor: "person", definition: definition, workspace: "app.worktree-x", worktree: worktree, inputs: {}, pane: "%5")
  end

  def run = stored_run(store, "wr_1")

  def current_attempt = run["steps"][run["current"]]["attempts"].last["n"]

  def stall(cause = "agent_gone", max: 2, step: run["current"], attempt: current_attempt)
    engine.note_stall("wr_1", actor: "sweep", step: step, attempt: attempt, cause: cause, infra_retry: {max: max})
  end

  def claim(who = claimant, alive: ->(_) { true }, step: run["current"], attempt: current_attempt)
    engine.claim_infra_retry("wr_1", actor: "daemon", step: step, attempt: attempt, claimant: who, alive: alive)
  end

  def release(who = claimant) = engine.release_infra_retry("wr_1", actor: "daemon", step: run["current"], attempt: current_attempt, claimant: who)

  def retry_restart(who = claimant) = engine.resume("wr_1", actor: "daemon", restart_step: true, bound: "unknown", infra_retry: who)

  def mark = Workspace::WorkflowTransitions.sweep_marks(run)["infra_retry"]

  def count = Workspace::WorkflowTransitions.infra_retries(run, run["current"])

  def lines(type) = File.readlines(store.events_path("wr_1")).map { |line| JSON.parse(line) }.select { |line| line["type"] == type }

  def wake = Workspace::WorkflowTransitions.wakeable?(run, now.first)

  def run_bytes = [File.binread(File.join(runs_dir, "wr_1.json")), File.binread(store.events_path("wr_1"))]

  def refusal
    yield
    nil
  rescue Workspace::Error => e
    e
  end

  describe "#note_stall with infra_retry" do
    it "writes the mark and its infra_retry_scheduled event once per attempt, due 60s after it was scheduled" do
      start

      expect(stall).to eq(:scheduled)
      now[0] += 5
      expect(stall).to eq(:repeat)

      expect(mark).to eq("cause" => "agent_gone", "n" => 1, "max" => 2, "scheduled_at" => "2026-10-04T12:00:00Z", "due" => "2026-10-04T12:01:00Z")
      expect(lines("infra_retry_scheduled").size).to eq(1)
      expect(lines("infra_retry_scheduled").first).to include("step" => "build", "attempt" => 1, "cause" => "agent_gone", "n" => 1, "max" => 2,
        "due" => "2026-10-04T12:01:00Z", "actor" => "sweep")
      expect(lines("step_stalled").size).to eq(1)
    end

    it "schedules the second retry 300s out, and past max gives the retry up as spent in the same change, once" do
      start
      stall
      now[0] += 60
      claim
      retry_restart

      expect(stall).to eq(:scheduled)
      expect(mark).to include("n" => 2, "due" => "2026-10-04T12:06:00Z")

      now[0] += 300
      claim
      retry_restart
      expect(stall).to eq(:exhausted)
      expect(mark).to include("cause" => "agent_gone", "n" => 2, "max" => 2, "given_up" => {"at" => "2026-10-04T12:06:00Z", "reason" => "retries_spent"})
      expect(lines("infra_retries_exhausted")).to contain_exactly(include("step" => "build", "attempt" => 3, "cause" => "agent_gone", "n" => 2, "max" => 2,
        "reason" => "retries_spent", "actor" => "sweep"))

      now[0] += 300
      expect(stall).to eq(:repeat)
      expect(engine.give_up_infra_retry("wr_1", actor: "sweep", step: "build", attempt: 3, cause: "agent_gone", reason: "retries_spent", max: 2)).to eq(:repeat)
      expect(lines("infra_retries_exhausted").size).to eq(1)
      expect(lines("step_stalled").count { |line| line["attempt"] == 3 }).to eq(1)
      expect(wake).to be_nil
    end

    it "schedules nothing without infra_retry, or for a cause a restart does not get past" do
      start
      expect(engine.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone")).to eq(:recorded)
      expect(engine.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "turn_failed", infra_retry: {max: 2})).to eq(:recorded)

      expect(mark).to be_nil
      expect(lines("infra_retry_scheduled")).to be_empty
    end
  end

  describe "#claim_infra_retry" do
    before do
      start
      stall
    end

    it "is not due before its wait is over" do
      expect(claim).to eq(:not_due)
      expect(count).to eq(0)
    end

    it "lets one of two claims of one due retry win" do
      now[0] += 60

      expect(claim).to eq([:claimed, 1])
      expect(claim(other)).to eq(:not_due)

      expect(mark).to include("n" => 1, "claimed_at" => "2026-10-04T12:01:00Z", "claimed_by" => claimant)
      expect(count).to eq(1)
      expect(lines("infra_retry_claimed").map { |line| line.slice("step", "attempt", "cause", "n", "max") }).to eq([{"step" => "build", "attempt" => 1, "cause" => "agent_gone", "n" => 1, "max" => 2}])
    end

    it "takes over a claim older than the window as the next retry" do
      now[0] += 60
      claim
      now[0] += Workspace::WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW

      expect(claim(other)).to eq([:claimed, 2])
      expect(mark).to include("n" => 2, "claimed_by" => other)
      expect(count).to eq(2)
      expect(lines("infra_retry_claimed").last).to include("n" => 2, "taken_over" => true)
    end

    it "takes over a young claim whose claimant is gone" do
      now[0] += 60
      claim
      now[0] += 5

      expect(claim(other, alive: ->(holder) { holder != claimant })).to eq([:claimed, 2])
    end

    it "gives up with claim_lost when the claim to take over was the last retry" do
      now[0] += 60
      claim
      now[0] += Workspace::WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW
      claim(other)
      now[0] += Workspace::WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW

      expect(claim).to eq([:gave_up, "claim_lost"])
      expect(count).to eq(2)
      expect(lines("infra_retries_exhausted").map { |line| line.slice("cause", "n", "max", "reason") }).to eq([{"cause" => "agent_gone", "n" => 2, "max" => 2, "reason" => "claim_lost"}])
      expect(Workspace::WorkflowTransitions.infra_retry(run, now.first)[:state]).to eq(:exhausted)
      expect(claim).to eq(:not_due)
    end

    it "answers not_due for a run that moved to another attempt" do
      now[0] += 60
      expect(claim(attempt: 9)).to eq(:not_due)
    end
  end

  describe "the claim's refusals" do
    def expect_given_up(reason)
      expect(claim).to eq([:gave_up, reason])
      expect(count).to eq(0)
      expect(mark).not_to have_key("claimed_by")
      expect(lines("infra_retries_exhausted").map { |line| line["reason"] }).to eq([reason])
      expect(lines("infra_retry_claimed")).to be_empty
    end

    it "gives up with attempts_spent for a run with no attempt left" do
      start(definition("max_attempts: 1\nsteps:\n  build:\n    prompt: B\n"))
      stall
      now[0] += 60

      expect_given_up("attempts_spent")
    end

    it "gives up with budget_spent for a run that used its token budget" do
      start(definition("budget: {tokens: 1000}\nsteps:\n  a:\n    prompt: A\n  b:\n    prompt: B\n"))
      engine.turn_ended("wr_1", actor: "agent", pane: "%5")
      edit_run(store, "wr_1") { |stored| stored["steps"]["a"]["attempts"].first["usage"] = {"input_tokens" => 1200, "output_tokens" => 0} }
      stall
      now[0] += 60

      expect_given_up("budget_spent")
    end

    # The mark, the count and the history stay as they were (a park written straight into the run file gets its
    # reason span recorded by the change, so the run file itself is not compared).
    def expect_held
      held = [mark, count, run_bytes.last]
      expect(claim).to eq(:not_due)
      expect([mark, count, run_bytes.last]).to eq(held)
      expect(mark).not_to have_key("given_up")
    end

    it "leaves the retry scheduled for a paused run, and claims it once unpaused" do
      start
      stall
      engine.pause("wr_1", actor: "person")
      now[0] += 60

      expect_held
      engine.unpause("wr_1", actor: "person")
      expect(claim).to eq([:claimed, 1])
    end

    it "leaves the retry scheduled while a resume is parked on the run" do
      start
      stall
      now[0] += 60
      edit_run(store, "wr_1") { |stored| stored["parked"] = {"id" => "p1", "pane" => "%5", "expires_at" => "2026-10-04T13:00:00Z"} }

      expect_held
    end

    it "leaves the retry scheduled while the step's line is being typed" do
      start
      stall
      now[0] += 60
      edit_run(store, "wr_1") { |stored| stored["steps"]["build"]["attempts"].last["delivery"] = "delivering" }

      expect_held
    end

    it "gives up with no_open_attempt for an attempt already closed, the precondition of restart_not_closed" do
      start
      stall
      now[0] += 60
      edit_run(store, "wr_1") { |stored| stored["steps"]["build"]["attempts"].last["ended_at"] = "2026-10-04T12:00:30Z" }

      expect_given_up("no_open_attempt")
    end

    it "refuses a claimant without both pid and started" do
      start
      stall
      now[0] += 60
      before = run_bytes

      expect { claim({"pid" => 4242}) }.to raise_error(ArgumentError, /pid and a String started/)
      expect { claim({started: "x"}) }.to raise_error(ArgumentError)
      expect { release({"pid" => 4242}) }.to raise_error(ArgumentError)
      expect { retry_restart({"started" => "x"}) }.to raise_error(ArgumentError)
      expect(run_bytes).to eq(before)
    end

    it "gives up with gate_waiting for a run at its gate" do
      start(definition("steps:\n  plan:\n    prompt: P\n    gate: approve\n  build:\n    prompt: B\n"))
      engine.turn_ended("wr_1", actor: "agent", pane: "%5")
      stall(step: "plan", attempt: 1)
      now[0] += 60

      expect_given_up("gate_waiting")
    end

    it "gives up with agent_kind_unsupported when the run's agent is not Claude Code" do
      start
      engine.resume("wr_1", actor: "person", restart_step: true, bound: "idle")
      edit_run(store, "wr_1") { |stored| stored["steps"]["build"]["attempts"].first["agent"] = {"kind" => "codex", "version" => nil, "model" => nil} }
      stall
      now[0] += 60

      expect_given_up("agent_kind_unsupported")
    end
  end

  describe "#give_up_infra_retry" do
    it "records once, on the scheduled mark" do
      start
      stall

      args = {actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", reason: "no_session"}
      expect(engine.give_up_infra_retry("wr_1", **args)).to eq(:recorded)
      expect(engine.give_up_infra_retry("wr_1", **args, reason: "agent_not_ready")).to eq(:repeat)

      expect(mark["given_up"]).to eq("at" => "2026-10-04T12:00:00Z", "reason" => "no_session")
      expect(lines("infra_retries_exhausted").map { |line| line.slice("step", "attempt", "cause", "n", "max", "reason") })
        .to eq([{"step" => "build", "attempt" => 1, "cause" => "agent_gone", "n" => 1, "max" => 2, "reason" => "no_session"}])
    end

    it "writes a given-up mark with the step's count when none was scheduled" do
      start
      engine.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone")
      edit_run(store, "wr_1") { |stored| stored["infra_retries"] = {"build" => 2} }

      expect(engine.give_up_infra_retry("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone", reason: "retries_spent", max: 2)).to eq(:recorded)

      expect(mark).to include("cause" => "pane_gone", "n" => 2, "max" => 2, "given_up" => {"at" => "2026-10-04T12:00:00Z", "reason" => "retries_spent"})
      expect(wake).to be_nil
    end
  end

  describe "the claimant's restart" do
    before do
      start
      stall
      now[0] += 60
    end

    it "starts a new attempt that counts toward max_attempts, marked with the retry, not redelivered, loops untouched" do
      loops = run["loops"]
      claim

      after = retry_restart

      first, second = after["steps"]["build"]["attempts"]
      expect(first).to include("outcome" => "interrupted")
      expect(first).not_to have_key("redelivered")
      expect(second).to include("n" => 2, "retry_of" => 1)
      expect(Workspace::WorkflowTransitions.attempts_made(after)).to eq(2)
      expect(after["loops"]).to eq(loops)
      expect(after["infra_retries"]).to eq("build" => 1)
      expect(lines("run_resumed").last).to include("restart_step" => true, "infra_retry" => 1, "actor" => "daemon")
      expect(Workspace::WorkflowTransitions.sweep_marks(after)).to eq({})
    end

    it "writes no infra_retry_ended for the attempt it closes: the restart is the retry's outcome" do
      claim
      retry_restart

      expect(lines("step_recovered").map { |line| line["action"] }).to eq(["restarted"])
      expect(lines("infra_retry_ended")).to be_empty
    end

    it "is refused with infra_retry_not_claimed without the claim, and for another claimant" do
      before = run_bytes
      expect(refusal { retry_restart }&.code).to eq("infra_retry_not_claimed")
      expect(run_bytes).to eq(before)

      claim
      before = run_bytes
      error = refusal { retry_restart(other) }
      expect(error&.code).to eq("infra_retry_not_claimed")
      expect(error.details).to include("run_id" => "wr_1", "step" => "build", "pid" => 5151)
      expect(run_bytes).to eq(before)
    end

    it "is refused with infra_retry_not_claimed once the stall closed and the agent is back" do
      claim
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")
      before = run_bytes

      expect(refusal { retry_restart }&.code).to eq("infra_retry_not_claimed")
      expect(run_bytes).to eq(before)
    end

    it "is refused with infra_retry_not_claimed when its own cause ended though another stall is still open" do
      engine.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone", infra_retry: {max: 2})
      claim
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")
      expect(Workspace::WorkflowTransitions.open_stalls(run)).to eq(["pane_gone"])
      before = run_bytes

      expect(refusal { retry_restart }&.code).to eq("infra_retry_not_claimed")
      expect(run_bytes).to eq(before)
    end

    it "is refused with restart_not_closed when the attempt can't be closed, and the retry is then given up" do
      claim
      allow(recorder).to receive(:abandon) { |stored, **| Workspace::WorkflowRun.from_h(stored) }
      before = run_bytes

      expect(refusal { retry_restart }&.code).to eq("restart_not_closed")
      expect(run_bytes).to eq(before)
      expect(engine.give_up_infra_retry("wr_1", actor: "daemon", step: "build", attempt: 1, cause: "agent_gone", reason: "restart_not_closed")).to eq(:recorded)
      expect(lines("infra_retries_exhausted").map { |line| line["reason"] }).to eq(["restart_not_closed"])
      now[0] += Workspace::WorkflowTransitions::INFRA_RETRY_CLAIM_WINDOW
      expect(claim).to eq(:not_due)
    end
  end

  describe "#release_infra_retry" do
    before do
      start
      stall
      now[0] += 60
      claim
    end

    it "gives the count back, clears the claim and moves due one wait from now" do
      now[0] += 10

      expect(release(other)).to eq(:not_claimant)
      expect(release).to eq(:released)

      expect(count).to eq(0)
      expect(mark).to include("n" => 1, "released" => 1, "due" => "2026-10-04T12:02:10Z")
      expect(mark).not_to have_key("claimed_by")
      expect(lines("infra_retry_released").last).to include("n" => 1, "due" => "2026-10-04T12:02:10Z")
      expect(wake).to be_nil
      now[0] += 60
      expect(wake).to eq(:infra_retry)
    end

    it "gives up with still_working on a second release of one mark, without giving the count back twice" do
      release
      now[0] += 60
      expect(claim).to eq([:claimed, 1])

      expect(release).to eq([:gave_up, "still_working"])

      expect(count).to eq(1)
      expect(lines("infra_retries_exhausted").map { |line| line["reason"] }).to eq(["still_working"])
      expect(claim).to eq(:not_due)
    end

    it "does nothing for a mark whose stall ended" do
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")
      before = run_bytes
      expect(release).to eq(:not_claimant)
      expect(run_bytes).to eq(before)
      expect(count).to eq(1)
    end

    it "does nothing for a mark that gave up" do
      engine.give_up_infra_retry("wr_1", actor: "daemon", step: "build", attempt: 1, cause: "agent_gone", reason: "agent_not_ready")
      before = run_bytes

      expect(release).to eq(:not_claimant)
      expect(run_bytes).to eq(before)
      expect(lines("infra_retry_released")).to be_empty
    end
  end

  describe "a person's resume" do
    it "clears the step's count after the retries were spent, on --restart-step" do
      start
      edit_run(store, "wr_1") { |stored| stored["infra_retries"] = {"build" => 2} }
      expect(stall(max: 2)).to eq(:exhausted)

      after = engine.resume("wr_1", actor: "person", restart_step: true, bound: "shell")

      expect(after["infra_retries"]).to eq({})
      expect(lines("run_resumed").last).not_to have_key("infra_retry")
    end

    it "clears the step's count when the daemon carries out a parked resume" do
      start
      edit_run(store, "wr_1") { |stored| stored["infra_retries"] = {"build" => 2} }
      expect(stall(max: 2)).to eq(:exhausted)
      id = engine.park("wr_1", actor: "person", from: "build")["parked"]["id"]
      expect(run["infra_retries"]).to eq("build" => 2)

      after = engine.release_park("wr_1", id, actor: "daemon")

      expect(after).not_to have_key("unchanged")
      expect(after["infra_retries"]).to eq({})
      expect(lines("resume_parked_ended").map { |line| line["how"] }).to eq(["released"])
    end

    it "keeps the count on the daemon's own restart" do
      start
      stall
      now[0] += 60
      claim

      expect(retry_restart["infra_retries"]).to eq("build" => 1)
    end

    it "keeps the count when the resume does nothing" do
      start
      edit_run(store, "wr_1") { |stored| stored["infra_retries"] = {"build" => 1} }

      after = engine.resume("wr_1", actor: "person")

      expect(after["unchanged"]).to match(/an agent is working/)
      expect(after["infra_retries"]).to eq("build" => 1)
    end
  end

  describe "a stall that ends without a restart" do
    before do
      start
      stall
    end

    def expect_ended(reason)
      expect(lines("infra_retry_ended").map { |line| line.slice("step", "attempt", "cause", "n", "reason") })
        .to eq([{"step" => "build", "attempt" => 1, "cause" => "agent_gone", "n" => 1, "reason" => reason}])
      expect(mark["ended"]).to include("reason" => reason)
      now[0] += 120
      expect(wake).not_to eq(:infra_retry)
      expect(claim).to eq(:not_due)
    end

    it "ends the retry when the sweep sees the agent again" do
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")

      expect_ended("agent_back")
    end

    it "ends the retry when a person's resume keeps the attempt (the turn's end it saw is judged)" do
      engine.resume("wr_1", actor: "person", turn_over: {"step" => "build", "attempt" => 1})

      expect_ended("resumed")
    end
  end

  describe "a pause" do
    before do
      start
      stall
    end

    it "holds a due retry until the unpause" do
      engine.pause("wr_1", actor: "person")
      now[0] += 60
      expect(wake).to be_nil

      engine.unpause("wr_1", actor: "person")

      expect(wake).to eq(:infra_retry)
    end

    it "leaves nothing to wake when the stall closed while the run was paused" do
      engine.pause("wr_1", actor: "person")
      engine.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "agent_gone", action: "agent_back")
      now[0] += 60

      engine.unpause("wr_1", actor: "person")

      expect(wake).to be_nil
      expect(claim).to eq(:not_due)
    end
  end
end
