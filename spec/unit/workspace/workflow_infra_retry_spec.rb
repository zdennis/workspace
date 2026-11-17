require "spec_helper"

RSpec.describe Workspace::WorkflowInfraRetry do
  let(:now) { Time.utc(2026, 10, 4, 12, 2, 0) }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:dispatch) { instance_double(Workspace::PaneDispatch) }
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:lock_holder) { instance_double(Workspace::LockHolder, start_time: "Sun Oct  4 12:00:00 2026") }
  let(:agent_commands) { instance_double(Workspace::AgentCommands, kind: "claude") }
  let(:claimant) { {"pid" => 4242, "started" => "Sun Oct  4 12:00:00 2026"} }
  let(:ready) { Workspace::PaneDispatch::Spawned.new(pane: "%9", ready: Workspace::AgentReadiness::Result.new(ready: true, reason: nil), label: "Claude Code", closed: false) }
  let(:target) { {actor: "daemon", step: "build", attempt: 1} }

  subject(:retrier) { described_class.new(engine: engine, store: store, dispatch: dispatch, lock_holder: lock_holder, agent_commands: agent_commands, pid: 4242, clock: -> { now }) }

  before do
    allow(engine).to receive(:claim_infra_retry).and_return([:claimed, 1])
    allow(engine).to receive(:resume).and_return({})
    allow(engine).to receive(:give_up_infra_retry).and_return(:recorded)
    allow(engine).to receive(:release_infra_retry).and_return(:released)
    allow(dispatch).to receive(:session_live?).and_return(true)
    allow(dispatch).to receive(:spawn).and_return(ready)
    allow(dispatch).to receive(:close_unused).and_return(true)
    allow(dispatch).to receive(:deliver)
    # Read again only after a restart that raised: by default the run is where the claim left it.
    allow(store).to receive(:run).with("wr_1") { run }
  end

  def run(cause = "agent_gone", mark: {})
    Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "app.worktree-x", "current" => "build", "state" => "running", "pane" => "%5",
      "steps" => {"build" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T11:50:00Z"}]}},
      "sweep" => {"step" => "build", "attempt" => 1, "stalled" => {cause => {"at" => "2026-10-04T12:00:00Z"}},
                  "infra_retry" => {"cause" => cause, "n" => 1, "max" => 2, "scheduled_at" => "2026-10-04T12:00:00Z", "due" => "2026-10-04T12:01:00Z"}.merge(mark)})
  end

  def refused(code) = Workspace::Error.new("refused", code: code, details: {"run_id" => "wr_1"})

  %w[agent_gone pane_gone].each do |cause|
    it "claims a due #{cause} retry, splits a new Claude Code pane and restarts the step there, typing into no old pane" do
      expect(retrier.call(run(cause))).to eq([:restarted, 1, "%9"])

      expect(engine).to have_received(:claim_infra_retry).with("wr_1", **target, claimant: claimant, alive: an_instance_of(Method))
      expect(dispatch).to have_received(:spawn).with("app.worktree-x", "claude").once
      expect(engine).to have_received(:resume).with("wr_1", actor: "daemon", restart_step: true, bound: "unknown", infra_retry: claimant, pane: "%9")
      expect(dispatch).not_to have_received(:deliver)
      expect(dispatch).not_to have_received(:close_unused)
      expect(engine).not_to have_received(:give_up_infra_retry)
    end
  end

  it "asks the lock holder whether a claim's process still runs, and takes an unreadable process table as alive" do
    alive = nil
    allow(engine).to receive(:claim_infra_retry) { |*, **kw| alive = kw[:alive] and :not_due }
    allow(lock_holder).to receive(:alive?).with(pid: 5151, started: "x").and_return(false)
    allow(lock_holder).to receive(:alive?).with(pid: 6161, started: "y").and_raise(Workspace::Error, "ps failed")

    retrier.call(run)

    expect(alive.call("pid" => 5151, "started" => "x")).to be(false)
    expect(alive.call("pid" => 6161, "started" => "y")).to be(true)
  end

  it "spawns nothing when another process holds the claim" do
    allow(engine).to receive(:claim_infra_retry).and_return(:not_due)

    expect(retrier.call(run)).to eq(:not_due)
    expect(dispatch).not_to have_received(:session_live?)
    expect(dispatch).not_to have_received(:spawn)
    expect(engine).not_to have_received(:resume)
  end

  it "spawns nothing when the claim gives the retry up on a refusal the run can answer" do
    allow(engine).to receive(:claim_infra_retry).and_return([:gave_up, "attempts_spent"])

    expect(retrier.call(run)).to eq([:gave_up, "attempts_spent"])
    expect(dispatch).not_to have_received(:spawn)
    expect(engine).not_to have_received(:give_up_infra_retry)
  end

  it "claims nothing when this process's start time can't be read" do
    allow(lock_holder).to receive(:start_time).and_raise(Workspace::Error, "ps failed")

    expect(retrier.call(run)).to eq(:no_claimant)
    expect(engine).not_to have_received(:claim_infra_retry)
  end

  it "does nothing for a run with no infra retry mark" do
    plain = Workspace::WorkflowRun.from_h(run.to_h.merge("sweep" => {}))

    expect(retrier.call(plain)).to eq(:not_due)
    expect(engine).not_to have_received(:claim_infra_retry)
  end

  it "gives up with no_session when the workspace's tmux session is gone, spawning nothing" do
    allow(dispatch).to receive(:session_live?).with("app.worktree-x").and_return(false)

    expect(retrier.call(run)).to eq([:gave_up, "no_session"])
    expect(engine).to have_received(:give_up_infra_retry).with("wr_1", **target, cause: "agent_gone", reason: "no_session")
    expect(dispatch).not_to have_received(:spawn)
  end

  it "takes a session it can't tell about as running" do
    allow(dispatch).to receive(:session_live?).and_return(nil)

    expect(retrier.call(run).first).to eq(:restarted)
  end

  it "gives up with agent_kind_unsupported when the workspace's agent is not Claude Code, spawning nothing" do
    allow(agent_commands).to receive(:kind).with("app.worktree-x").and_return("codex")

    expect(retrier.call(run)).to eq([:gave_up, "agent_kind_unsupported"])
    expect(dispatch).not_to have_received(:spawn)
  end

  it "gives up with agent_not_ready when the new agent never gets ready, and restarts nothing" do
    not_ready = Workspace::PaneDispatch::Spawned.new(pane: "%9", ready: Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout"), label: "Claude Code", closed: true)
    allow(dispatch).to receive(:spawn).and_return(not_ready)

    expect(retrier.call(run("pane_gone"))).to eq([:gave_up, "agent_not_ready"])
    expect(engine).to have_received(:give_up_infra_retry).with("wr_1", **target, cause: "pane_gone", reason: "agent_not_ready")
    expect(engine).not_to have_received(:resume)
  end

  it "names the screen a new agent waits at when its pane is kept for a person" do
    waiting = Workspace::PaneDispatch::Spawned.new(pane: "%9", ready: Workspace::AgentReadiness::Result.new(ready: false, reason: "timeout"), label: "Claude Code", closed: false, waiting: "sign_in")
    allow(dispatch).to receive(:spawn).and_return(waiting)

    expect(retrier.call(run)).to eq([:gave_up, "agent_waiting_sign_in"])
    expect(dispatch).not_to have_received(:close_unused)
  end

  it "gives up with agent_not_ready when the wait for the agent raises, and spawn_failed when no pane was made" do
    allow(dispatch).to receive(:spawn).and_raise(Workspace::Error.new("no agent", details: {"pane_id" => "%9", "pane_closed" => true}))
    expect(retrier.call(run)).to eq([:gave_up, "agent_not_ready"])

    allow(dispatch).to receive(:spawn).and_raise(Workspace::Error, "Failed to split window for 'app'")
    expect(retrier.call(run)).to eq([:gave_up, "spawn_failed"])
    expect(engine).not_to have_received(:resume)
  end

  it "closes the new pane and gives the claim back when the agent is at work again" do
    allow(engine).to receive(:resume).and_raise(refused("step_still_working"))

    expect(retrier.call(run)).to eq(:released)
    expect(dispatch).to have_received(:close_unused).with("app.worktree-x", "%9")
    expect(engine).to have_received(:release_infra_retry).with("wr_1", **target, claimant: claimant)
    expect(engine).not_to have_received(:give_up_infra_retry)
  end

  it "passes on the release's give-up for a second working agent on one mark" do
    allow(engine).to receive(:resume).and_raise(refused("step_still_working"))
    allow(engine).to receive(:release_infra_retry).and_return([:gave_up, "still_working"])

    expect(retrier.call(run)).to eq([:gave_up, "still_working"])
    expect(dispatch).to have_received(:close_unused).once
  end

  it "closes the new pane and stops when the retry is no longer claimed (its stall ended), spawning nothing on the next wake" do
    allow(engine).to receive(:resume).and_raise(refused("infra_retry_not_claimed"))

    expect(retrier.call(run)).to eq(:not_claimed)
    expect(dispatch).to have_received(:close_unused).with("app.worktree-x", "%9")
    expect(engine).not_to have_received(:give_up_infra_retry)
    expect(engine).not_to have_received(:release_infra_retry)

    allow(engine).to receive(:claim_infra_retry).and_return(:not_due)
    expect(retrier.call(run(mark: {"ended" => {"at" => "2026-10-04T12:01:30Z", "reason" => "agent_back"}}))).to eq(:not_due)
    expect(dispatch).to have_received(:spawn).once
  end

  it "closes the new pane and gives up with the refusal's code when the restart is refused after the spawn" do
    allow(engine).to receive(:resume).and_raise(refused("attempts_spent"))

    expect(retrier.call(run)).to eq([:gave_up, "attempts_spent"])
    expect(dispatch).to have_received(:close_unused).with("app.worktree-x", "%9")
    expect(engine).to have_received(:give_up_infra_retry).with("wr_1", **target, cause: "agent_gone", reason: "attempts_spent")
  end

  it "always restarts with the bound pane unknown, whatever the new pane is" do
    retrier.call(run)
    retrier.call(run("pane_gone"))

    expect(engine).to have_received(:resume).with("wr_1", hash_including(bound: "unknown")).twice
  end
  it "closes the new pane, gives up with restart_error and raises again for an unexpected error from a restart that was not stored" do
    allow(engine).to receive(:resume).and_raise(NoMethodError, "boom")

    expect { retrier.call(run) }.to raise_error(NoMethodError, "boom")
    expect(dispatch).to have_received(:close_unused).with("app.worktree-x", "%9")
    expect(engine).to have_received(:give_up_infra_retry).with("wr_1", **target, cause: "agent_gone", reason: "restart_error")
  end

  it "keeps the pane and raises again, giving nothing up, for an unexpected error when the run can't be read again" do
    allow(store).to receive(:run).with("wr_1").and_raise(Errno::EACCES)
    allow(engine).to receive(:resume).and_raise(NoMethodError, "boom")

    expect { retrier.call(run) }.to raise_error(NoMethodError, "boom")
    expect(dispatch).not_to have_received(:close_unused)
    expect(engine).not_to have_received(:give_up_infra_retry)
  end

  context "when the restart was stored before it raised" do
    def restarted_run(attempt:, pane:)
      hash = run.to_h
      attempts = [{"n" => 1, "started_at" => "2026-10-04T11:50:00Z", "ended_at" => "2026-10-04T12:02:00Z"}]
      attempts << {"n" => 2, "started_at" => "2026-10-04T12:02:00Z"} if attempt == 2
      Workspace::WorkflowRun.from_h(hash.merge("pane" => pane, "steps" => {"build" => {"state" => "running", "attempts" => attempts}}))
    end

    it "keeps the pane and answers restarted when the run is past the claimed attempt" do
      allow(store).to receive(:run).with("wr_1").and_return(restarted_run(attempt: 2, pane: "%5"))
      allow(engine).to receive(:resume).and_raise(refused("pane_not_found"))

      expect(retrier.call(run)).to eq([:restarted, 1, "%9"])
      expect(dispatch).not_to have_received(:close_unused)
      expect(engine).not_to have_received(:give_up_infra_retry)
    end

    it "keeps the pane and answers restarted when the run is bound to the new pane, whatever the error" do
      allow(store).to receive(:run).with("wr_1").and_return(restarted_run(attempt: 1, pane: "%9"))
      allow(engine).to receive(:resume).and_raise(RuntimeError, "typed and failed")

      expect(retrier.call(run)).to eq([:restarted, 1, "%9"])
      expect(dispatch).not_to have_received(:close_unused)
      expect(engine).not_to have_received(:give_up_infra_retry)
    end

    it "keeps the pane when the run can't be read again" do
      allow(store).to receive(:run).with("wr_1").and_raise(Workspace::Error.new("gone", code: "unknown_run"))
      allow(engine).to receive(:resume).and_raise(refused("attempts_spent"))

      expect(retrier.call(run)).to eq(:unconfirmed)
      expect(dispatch).not_to have_received(:close_unused)
      expect(engine).not_to have_received(:give_up_infra_retry)
    end
  end
end
