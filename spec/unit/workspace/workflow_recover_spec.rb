require "spec_helper"
require "tmpdir"

# Records what recover asks of `workspace restore`. It can raise, answer a failed row for the workspace itself or for
# one pane slot, or leave the session down; otherwise it brings the session up (+live+) and moves the bindings of the
# runs in +moves+ to new, alive panes, as a real restore does. +after+ runs once a restore is done.
class RecoverFakeRestore
  attr_reader :calls, :raises, :fails, :slot_fails, :moves, :stays_down
  attr_accessor :after

  def initialize(panes, live)
    @panes = panes
    @live = live
    @calls = []
    @raises = {}
    @fails = {}
    @slot_fails = {}
    @moves = {}
    @stays_down = []
    @after = nil
  end

  def call(workspaces, dry_run: false, &launch)
    @calls << [workspaces, dry_run, !launch.nil?]
    workspace = workspaces.first
    raise @raises[workspace] if @raises[workspace]
    if @fails[workspace]
      return {exit_code: 1, results: [{"workspace" => workspace, "kind" => "workspace", "outcome" => dry_run ? "unmatched" : "failed", "reason" => "no_config", "message" => @fails[workspace]}]}
    end
    rows = [{"workspace" => workspace, "kind" => "workspace", "outcome" => dry_run ? "would_launch" : "launched"}]
    rows << {"workspace" => workspace, "kind" => "pane", "outcome" => "failed", "reason" => "split_failed", "message" => @slot_fails[workspace]} if @slot_fails[workspace]
    unless dry_run
      @live[workspace] = true unless @stays_down.include?(workspace)
      @moves.each do |run_id, pane|
        @panes.unbind(run_id)
        @panes.stale.delete(run_id)
        @panes.bind(workspace: workspace, pane: pane, run_id: run_id)
      end
      @after&.call
    end
    {exit_code: (rows.any? { |each| each["outcome"] == "failed" }) ? 1 : 0, results: rows}
  end

  def workspaces = @calls.map(&:first).flatten
end

# Answers ready (or not) for every pane and records the waits.
class RecoverFakeReadiness
  attr_reader :waits
  attr_accessor :ready

  def initialize
    @waits = []
    @ready = true
  end

  def deadline_in(seconds) = seconds

  def wait(session, deadline:, only_pane: nil)
    @waits << [session, only_pane]
    Workspace::AgentReadiness::Result.new(ready: @ready, pane: only_pane, pane_id: only_pane, label: "Claude Code", reason: @ready ? nil : "agent prompt never appeared")
  end
end

# Records restart_refusal, resume and tick. restart_refusal raises a scripted refusal of the run's own state or limits
# (the codes in RAISED) and returns any other, so both shapes are covered. A resume answers the next scripted error for
# its run, else restarts the step in the run file as the real engine does (closes the attempt, opens the next, raises
# reboot_recoveries).
class RecoverFakeEngine
  attr_reader :calls, :errors, :refusals
  attr_accessor :ticked, :refusal_error

  def initialize(dir)
    @dir = dir
    @calls = []
    @errors = Hash.new { |hash, key| hash[key] = [] }
    @refusals = {}
    @ticked = nil
    @refusal_error = nil
  end

  RAISED = %w[run_paused gate_waiting attempts_spent step_attempts_spent budget_spent run_timed_out].freeze

  def restart_refusal(run, bound: "unknown")
    @calls << [:restart_refusal, run.id, {bound: bound}]
    raise @refusal_error if @refusal_error && run.id == "wr_1"
    refusal = @refusals[run.id]
    raise refusal if refusal && RAISED.include?(refusal.code)
    refusal
  end

  def resume(run_id, **args)
    @calls << [:resume, run_id, args]
    error = @errors[run_id].shift
    raise error if error
    path = File.join(@dir, "#{run_id}.json")
    run = JSON.parse(File.read(path))
    attempts = run["steps"][run["current"]]["attempts"]
    attempts.last["ended_at"] = "2026-11-17T12:00:00Z"
    attempts << {"n" => attempts.last["n"] + 1, "started_at" => "2026-11-17T12:00:00Z"}
    run["reboot_recoveries"] = run["reboot_recoveries"].to_i + 1
    File.write(path, JSON.pretty_generate(run))
    run
  end

  def tick(run_id, actor:)
    @calls << [:tick, run_id, {actor: actor}]
    @ticked
  end

  def changes = @calls.reject { |each| each.first == :restart_refusal }

  def resumes = @calls.select { |each| each.first == :resume }.map { |each| each[1] }

  def ticks = @calls.select { |each| each.first == :tick }.map { |each| each[1] }
end

# Which going runs `workflow recover` restarts, wakes or leaves alone, in what order, and what each row says. A real
# run store in a temporary directory; fakes for restore, readiness, panes and the engine, so nothing starts a process.
RSpec.describe Workspace::WorkflowRecover do
  around do |example|
    Dir.mktmpdir("wf-recover") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:runs_dir) { File.join(@dir, "runs") }
  let(:now) { [Time.utc(2026, 11, 17, 12, 0, 0)] }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: File.join(@dir, "archive"), clock: -> { now.first }) }
  let(:panes) { FakeWorkflowPanes.new }
  let(:restore) { RecoverFakeRestore.new(panes, live) }
  let(:readiness) { RecoverFakeReadiness.new }
  let(:engine) { RecoverFakeEngine.new(runs_dir) }
  let(:live) { Hash.new(false) }
  let(:removed) { [] }
  let(:max) { [2] }
  let(:sleeps) { [] }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:config) { instance_double(Workspace::WorkflowConfig) }
  let(:sleeper) do
    lambda do |seconds|
      sleeps << seconds
      now[0] += seconds
    end
  end
  let(:recover) do
    described_class.new(store: store, engine: engine, restore: restore, readiness: readiness, panes: panes,
      liveness: ->(names) { names.to_h { |name| [name, live[name]] } }, project_config: project_config, config: config,
      session_name: ->(workspace) { "s-#{workspace}" }, sleeper: sleeper, clock: -> { now.first })
  end

  before do
    FileUtils.mkdir_p(runs_dir)
    allow(project_config).to receive(:project_root_for) { |name| removed.include?(name) ? nil : "/src/#{name}" }
    allow(config).to receive(:recover_max_per_run) { max.first }
  end

  def iso(offset) = (now.first + offset).utc.iso8601

  def add_run(id, workspace, age, step: "running", open: true, pane: "%1", extra: {})
    attempt = {"n" => 1, "started_at" => iso(-600)}
    attempt["ended_at"] = iso(-300) unless open
    run = {"id" => id, "workspace" => workspace, "state" => "running", "current" => "build", "pane" => pane, "created_at" => iso(-age), "definition" => {"steps" => [{"id" => "build", "prompt" => "Build it."}]},
           "steps" => {"build" => {"state" => step, "attempts" => [attempt]}}}.merge(extra)
    File.write(path(id), JSON.pretty_generate(run))
    panes.bind(workspace: workspace, pane: pane, run_id: id) if pane
    run
  end

  def path(id) = File.join(runs_dir, "#{id}.json")

  def bytes(id) = File.binread(path(id))

  def stored(id) = JSON.parse(File.read(path(id)))

  def rows = recover.call { {} }[:results]

  def row_of(result, id) = result[:results].find { |each| each["run_id"] == id }

  describe "order" do
    it "recovers one workspace at a time, in the order of each one's oldest run" do
      add_run("wr_b1", "beta", 300)
      add_run("wr_a1", "alpha", 200, pane: "%2")
      add_run("wr_b2", "beta", 100, pane: "%3")
      result = recover.call { {} }

      expect(restore.calls).to eq([[["beta"], false, true], [["alpha"], false, true]])
      expect(engine.resumes).to eq(%w[wr_b1 wr_b2 wr_a1])
      expect(result[:results].map { |each| each["run_id"] }).to eq(%w[wr_b1 wr_a1 wr_b2])
      expect(result[:results].map { |each| each["outcome"] }.uniq).to eq(["restarted"])
      expect(result[:exit_code]).to eq(0)
    end
  end

  describe "a mid-turn step in a stopped workspace" do
    it "re-reads the pane after the restore, waits for it, and restarts the step counting a reboot recovery" do
      add_run("wr_1", "app", 100, pane: "%1")
      restore.moves["wr_1"] = "%9"
      result = recover.call { {} }

      expect(readiness.waits).to eq([["s-app", "%9"]])
      expect(engine.changes.first).to eq([:resume, "wr_1", {actor: "person", restart_step: true, bound: "idle", reboot_recovery: {"workspace" => "app", "attempt" => 1}}])
      expect(row_of(result, "wr_1")).to include("outcome" => "restarted", "attempt" => 2, "step" => "build", "workspace" => "app")
      expect(row_of(result, "wr_1")["message"]).to include("pane %9", "reboot recovery 1 of 2")
      expect(stored("wr_1")["reboot_recoveries"]).to eq(1)
    end

    it "fails with no_pane when no pane is bound after the restore, naming the manual commands" do
      add_run("wr_1", "app", 100, pane: nil)
      found = rows.first
      expect(found).to include("outcome" => "failed", "reason" => "no_pane")
      expect(found["next_actions"].map { |each| [each["action"], each["args"]] }).to eq([["restore", ["app"]], ["workflow resume", ["wr_1", "--restart-step"]]])
      expect(engine.resumes).to be_empty
    end

    it "fails with no_pane when the bound pane id is stale after the restore (tmux pane ids start again after a reboot)" do
      add_run("wr_1", "app", 100, pane: "%0")
      panes.stale << "wr_1"
      before = bytes("wr_1")
      found = rows.first

      expect(found).to include("outcome" => "failed", "reason" => "no_pane")
      expect(found["message"]).to include("pane %0")
      expect(readiness.waits).to be_empty
      expect(engine.resumes).to be_empty
      expect(bytes("wr_1")).to eq(before)
    end

    it "fails with pane_not_ready and leaves the run file unchanged when the agent never gets ready" do
      add_run("wr_1", "app", 100)
      before = bytes("wr_1")
      readiness.ready = false
      result = recover.call { {} }

      expect(row_of(result, "wr_1")).to include("outcome" => "failed", "reason" => "pane_not_ready")
      expect(row_of(result, "wr_1")["message"]).to include("agent prompt never appeared")
      expect(row_of(result, "wr_1")["next_actions"].map { |each| each["action"] }).to eq(["restore", "workflow resume"])
      expect(engine.resumes).to be_empty
      expect(bytes("wr_1")).to eq(before)
      expect(result[:exit_code]).to eq(1)
    end

    it "restarts a step whose stale infra retry claim was left in a stopped session" do
      add_run("wr_1", "app", 100, extra: {"sweep" => {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => iso(-900)},
                                                      "infra_retry" => {"cause" => "pane_gone", "n" => 1, "max" => 2, "due" => iso(-800), "claimed_at" => iso(-700), "claimed_by" => {"pid" => 1, "started" => "x"}}}})
      expect(rows.first).to include("outcome" => "restarted")
    end

    it "skips a step whose infra retry claim is fresh, even in a stopped session (the agent daemon outlives tmux)" do
      add_run("wr_1", "app", 100, extra: {"sweep" => {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => iso(-900)},
                                                      "infra_retry" => {"cause" => "pane_gone", "n" => 1, "max" => 2, "due" => iso(-800), "claimed_at" => iso(-30), "claimed_by" => {"pid" => 1, "started" => "x"}}}})
      expect(rows.first).to include("outcome" => "skipped", "reason" => "infra_retry_pending")
      expect(restore.calls).to be_empty
    end

    it "restarts a step whose pane is gone in a live session with no infra retry pending" do
      live["app"] = true
      add_run("wr_1", "app", 100)
      panes.stale << "wr_1"
      restore.moves["wr_1"] = "%9"
      expect(rows.first).to include("outcome" => "restarted")
    end

    it "does not fail a run whose own pane came back when another pane slot's restore row failed" do
      add_run("wr_1", "app", 100)
      restore.slot_fails["app"] = "could not split a pane for slot app:0.2"
      expect(rows.first).to include("outcome" => "restarted")
    end

    it "refuses every restart when max_per_run is 0, with no restore" do
      max[0] = 0
      add_run("wr_1", "app", 100)
      expect(rows.first).to include("outcome" => "refused", "reason" => "limit_reached")
      expect(restore.calls).to be_empty
    end
  end

  describe "refusals from the restart" do
    before { add_run("wr_1", "app", 100) }

    let(:still_working) { Workspace::Error.new("Step build's line is still being typed.", code: "step_still_working") }

    it "tries step_still_working again with the sleeper until it gives up, naming the manual restart" do
      engine.errors["wr_1"].concat(Array.new(20) { still_working })
      result = recover.call { {} }

      found = row_of(result, "wr_1")
      expect(found).to include("outcome" => "failed", "reason" => "step_still_working")
      expect(found["next_actions"]).to eq([{"action" => "workflow resume", "args" => ["wr_1", "--restart-step"], "needs" => [], "why" => "step_still_working"}])
      expect(result[:extra]["next_actions"]).to eq(found["next_actions"])
      expect(sleeps).to all(eq(described_class::STILL_WORKING_POLL))
      expect(engine.resumes.size).to eq(sleeps.size + 1)
      expect(sleeps.sum).to be >= described_class::STILL_WORKING_SECONDS
    end

    it "restarts once step_still_working clears" do
      engine.errors["wr_1"] << still_working
      expect(rows.first).to include("outcome" => "restarted")
      expect(sleeps).to eq([described_class::STILL_WORKING_POLL])
    end

    it "gives skipped/moved_on when the pinned attempt changed between tries" do
      engine.errors["wr_1"] << still_working
      sleeps_and_move = lambda do |_seconds|
        run = stored("wr_1")
        run["steps"]["build"]["attempts"] << {"n" => 2, "started_at" => iso(0)}
        File.write(path("wr_1"), JSON.generate(run))
      end
      recover = described_class.new(store: store, engine: engine, restore: restore, readiness: readiness, panes: panes,
        liveness: ->(names) { names.to_h { |name| [name, false] } }, project_config: project_config, config: config,
        session_name: ->(workspace) { workspace }, sleeper: sleeps_and_move, clock: -> { now.first })
      expect(recover.call { {} }[:results].first).to include("outcome" => "skipped", "reason" => "moved_on")
      expect(engine.resumes).to eq(["wr_1"])
    end

    it "skips a run whose infra retry was claimed after it was sorted" do
      engine.errors["wr_1"] << still_working
      claim = lambda do |_seconds|
        run = stored("wr_1")
        run["sweep"] = {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => iso(-60)},
                        "infra_retry" => {"cause" => "pane_gone", "n" => 1, "claimed_at" => iso(0), "claimed_by" => {"pid" => 2, "started" => "y"}}}
        File.write(path("wr_1"), JSON.generate(run))
      end
      recover = described_class.new(store: store, engine: engine, restore: restore, readiness: readiness, panes: panes,
        liveness: ->(names) { names.to_h { |name| [name, false] } }, project_config: project_config, config: config,
        session_name: ->(workspace) { workspace }, sleeper: claim, clock: -> { now.first })
      expect(recover.call { {} }[:results].first).to include("outcome" => "skipped", "reason" => "infra_retry_pending")
      expect(engine.resumes).to eq(["wr_1"])
    end

    it "maps the engine's infra_retry_not_claimed (a claim seen under the run's lock) to skipped/infra_retry_pending" do
      engine.errors["wr_1"] << Workspace::Error.new("claimed", code: "infra_retry_not_claimed")
      expect(rows.first).to include("outcome" => "skipped", "reason" => "infra_retry_pending")
    end

    it "tries restart_not_closed once more, after a pause" do
      engine.errors["wr_1"] << Workspace::Error.new("not closed", code: "restart_not_closed")
      expect(rows.first).to include("outcome" => "restarted")
      expect(engine.resumes.size).to eq(2)
      expect(sleeps).to eq([described_class::STILL_WORKING_POLL])
    end

    it "restarts a line still being typed after waiting, rather than refusing it up front" do
      engine.refusals["wr_1"] = Workspace::Error.new("Step build's line is still being typed.", code: "step_still_working")
      expect(rows.first).to include("outcome" => "restarted")
    end

    it "refuses after a second restart_not_closed" do
      2.times { engine.errors["wr_1"] << Workspace::Error.new("not closed", code: "restart_not_closed") }
      expect(rows.first).to include("outcome" => "refused", "reason" => "restart_not_closed")
    end

    it "gives skipped/moved_on for no_open_attempt" do
      engine.errors["wr_1"] << Workspace::Error.new("nothing running", code: "no_open_attempt")
      expect(rows.first).to include("outcome" => "skipped", "reason" => "moved_on")
    end

    it "refuses with the code of any other refusal" do
      engine.errors["wr_1"] << Workspace::Error.new("budget used", code: "budget_spent")
      expect(rows.first).to include("outcome" => "refused", "reason" => "budget_spent", "message" => "budget used")
    end
  end

  describe "runs left alone" do
    {
      "paused" => {"paused" => {"since" => "2026-11-17T11:00:00Z", "by" => "person"}},
      "gate_waiting" => {"steps" => {"build" => {"state" => "passed", "gate" => {"state" => "waiting"}, "attempts" => [{"n" => 1, "ended_at" => "2026-11-17T11:00:00Z"}]}}},
      "parked" => {"parked" => {"id" => "p1"}},
      "reason" => {"reason" => {"code" => "turn_ended_incomplete"}}
    }.each do |code, extra|
      it "skips a #{code} run and never restores its workspace" do
        add_run("wr_1", "app", 100, extra: extra)
        before = bytes("wr_1")
        expect(rows.first).to include("outcome" => "skipped", "reason" => code)
        expect(restore.calls).to be_empty
        expect(engine.changes).to be_empty
        expect(bytes("wr_1")).to eq(before)
      end
    end

    [
      ["a retry blocked on a gone pane", {"state" => "waiting", "backoff" => {"to" => "build", "blocked" => "pane_gone"}, "reason" => {"code" => "pane_gone"}}, "retry_blocked"],
      ["a pane_gone reason", {"reason" => {"code" => "pane_gone"}}, "reason"]
    ].each do |label, extra, code|
      it "skips #{label} and says to restore the workspace and resume the run" do
        add_run("wr_1", "app", 100, extra: extra)
        found = rows.first
        expect(found).to include("outcome" => "skipped", "reason" => code)
        expect(found["message"]).to include("restore the workspace", "workspace workflow resume wr_1")
        expect(found["next_actions"].map { |each| each["action"] }).to eq(["restore", "workflow resume"])
        expect(found["next_actions"].last).to include("args" => ["wr_1"], "why" => code)
        expect(restore.calls).to be_empty
      end
    end

    it "gives a paused run with a pane_gone reason the paused row, since a resume would be refused" do
      add_run("wr_1", "app", 100, extra: {"paused" => true, "reason" => {"code" => "pane_gone"}})
      found = rows.first
      expect(found).to include("outcome" => "skipped", "reason" => "paused")
      expect(found["message"]).not_to include("restore the workspace")
    end

    %w[pane_has_run pane_changed].each do |blocked|
      it "gives a retry blocked by #{blocked} the plain held row, since a restore would not unblock it" do
        add_run("wr_1", "app", 100, extra: {"state" => "waiting", "backoff" => {"to" => "build", "blocked" => blocked}, "reason" => {"code" => "waiting_you"}})
        found = rows.first
        expect(found).to include("outcome" => "skipped", "reason" => "retry_blocked")
        expect(found["message"]).to include("waits for a person")
        expect(found["message"]).not_to include("restore the workspace")
        expect(restore.calls).to be_empty
      end
    end

    it "never sees a cancelled run, which is not going" do
      add_run("wr_1", "app", 100, extra: {"state" => "cancelled"})
      expect(rows).to be_empty
      expect(restore.calls).to be_empty
    end

    it "skips a run whose workspace was removed" do
      removed << "gone"
      add_run("wr_1", "gone", 100)
      expect(rows.first).to include("outcome" => "skipped", "reason" => "workspace_removed")
      expect(restore.calls).to be_empty
    end

    it "skips a run whose workspace's liveness is unknown" do
      live["app"] = nil
      add_run("wr_1", "app", 100)
      expect(rows.first).to include("outcome" => "skipped", "reason" => "unknown_liveness")
      expect(restore.calls).to be_empty
    end

    it "skips a between-turns run in a live session" do
      live["app"] = true
      add_run("wr_1", "app", 100, step: "reviewing")
      expect(rows.first).to include("outcome" => "skipped", "reason" => "nothing_to_restart")
      expect(restore.calls).to be_empty
      expect(engine.changes).to be_empty
    end

    it "skips a run whose bound pane is alive in a live session" do
      live["app"] = true
      add_run("wr_1", "app", 100)
      expect(rows.first).to include("outcome" => "skipped", "reason" => "pane_alive")
    end

    it "skips a run with an infra retry pending in a live session" do
      live["app"] = true
      add_run("wr_1", "app", 100, extra: {"sweep" => {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => iso(-60)},
                                                      "infra_retry" => {"cause" => "pane_gone", "n" => 1, "due" => iso(60)}}})
      panes.stale << "wr_1"
      expect(rows.first).to include("outcome" => "skipped", "reason" => "infra_retry_pending")
      expect(restore.calls).to be_empty
    end

    it "refuses a run at its limit with the manual commands and never restores its workspace" do
      add_run("wr_1", "app", 100, extra: {"reboot_recoveries" => 2})
      result = recover.call { {} }

      found = row_of(result, "wr_1")
      expect(found).to include("outcome" => "refused", "reason" => "limit_reached")
      expect(found["next_actions"].map { |each| [each["action"], each["args"]] }).to eq([["restore", ["app"]], ["workflow resume", ["wr_1", "--restart-step"]]])
      expect(restore.calls).to be_empty
      expect(result[:exit_code]).to eq(1)
    end

    it "gives partial (exit 3) when some runs are refused and others restarted" do
      add_run("wr_1", "app", 200, extra: {"reboot_recoveries" => 2})
      add_run("wr_2", "other", 100, pane: "%2")
      expect(recover.call { {} }[:exit_code]).to eq(3)
    end

    %w[attempts_spent budget_spent].each do |code|
      it "refuses a restart the engine would refuse (#{code}) before any restore, in a real run and a dry run" do
        add_run("wr_1", "app", 100)
        engine.refusals["wr_1"] = Workspace::Error.new("no allowance left", code: code)
        [false, true].each do |dry_run|
          result = recover.call(dry_run: dry_run) { {} }
          expect(result[:results].first).to include("outcome" => "refused", "reason" => code, "message" => "no allowance left")
          expect(result).to include(status: "failed", exit_code: 1)
        end
        expect(engine.calls.select { |each| each.first == :restart_refusal }.map(&:last)).to eq([{bound: "gone"}] * 2)
        expect(restore.calls).to be_empty
        expect(engine.changes).to be_empty
      end
    end

    it "gives a run that can't be read as a run failed/unreadable_run, from its id and workspace, and goes on" do
      add_run("wr_1", "app", 200, extra: {"backoff" => "not a hash"})
      add_run("wr_2", "other", 100, pane: "%2")
      result = recover.call { {} }

      expect(row_of(result, "wr_1")).to include("outcome" => "failed", "reason" => "unreadable_run", "workspace" => "app", "step" => nil)
      expect(row_of(result, "wr_2")).to include("outcome" => "restarted")
      expect(restore.workspaces).to eq(["other"])
    end

    it "gives a run whose later read raises failed/unreadable_run and goes on to other runs" do
      add_run("wr_1", "app", 200)
      add_run("wr_2", "other", 100, pane: "%2")
      engine.refusal_error = KeyError.new("no such key")
      result = recover.call { {} }

      expect(row_of(result, "wr_1")).to include("outcome" => "failed", "reason" => "unreadable_run", "workspace" => "app")
      expect(row_of(result, "wr_2")).to include("outcome" => "restarted")
    end

    it "gives each run file the store can't read a failed/unreadable_run row and lists it in extra" do
      add_run("wr_1", "app", 100)
      File.write(path("wr_bad"), "{not json")
      result = recover.call { {} }

      expect(row_of(result, "wr_bad")).to include("outcome" => "failed", "reason" => "unreadable_run", "workspace" => nil)
      expect(row_of(result, "wr_1")).to include("outcome" => "restarted")
      expect(result[:extra]["unreadable_files"]).to eq([path("wr_bad")])
      expect(result[:exit_code]).to eq(3)
    end
  end

  describe "between-turns runs in a stopped workspace" do
    it "restores the workspace and ticks a reviewing run once, with no resume and no count" do
      add_run("wr_1", "app", 100, step: "reviewing")
      engine.ticked = {"id" => "wr_1"}
      found = rows.first

      expect(restore.workspaces).to eq(["app"])
      expect(engine.changes).to eq([[:tick, "wr_1", {actor: "sweep"}]])
      expect(found).to include("outcome" => "restored", "reason" => "woken")
      expect(stored("wr_1")).not_to have_key("reboot_recoveries")
    end

    it "restores and ticks a checking run, saying when tick found nothing due" do
      add_run("wr_1", "app", 100, step: "checking")
      found = rows.first

      expect(engine.ticks).to eq(["wr_1"])
      expect(engine.resumes).to be_empty
      expect(found).to include("outcome" => "restored", "reason" => "nothing_due")
      expect(found["message"]).to include("daemon and the sweep")
      expect(stored("wr_1")).not_to have_key("reboot_recoveries")
    end

    it "restores a scheduled backoff's workspace, gives the due time and the sweep as next action" do
      add_run("wr_1", "app", 100, step: "failed", open: false, extra: {"state" => "waiting", "backoff" => {"until" => iso(300), "to" => "build"}, "reason" => {"code" => "retry_backoff", "details" => {"step" => "build"}}})
      found = rows.first

      expect(restore.workspaces).to eq(["app"])
      expect(engine.ticks).to eq(["wr_1"])
      expect(engine.resumes).to be_empty
      expect(found).to include("outcome" => "restored", "reason" => "backoff", "due" => iso(300))
      expect(found["next_actions"]).to eq([{"action" => "workflow sweep", "args" => ["wr_1"], "needs" => [], "why" => "backoff"}])
      expect(stored("wr_1")).not_to have_key("reboot_recoveries")
    end

    it "wakes a running step with no open attempt instead of restarting it" do
      add_run("wr_1", "app", 100, open: false)
      expect(rows.first).to include("outcome" => "restored")
      expect(engine.resumes).to be_empty
    end

    it "wakes a run whose fan_out group owes its goto, as it wakes a sibling's deferred move" do
      add_run("wr_1", "app", 100, step: "failed", open: false, extra: {"state" => "waiting", "current" => "build",
                                                                       "definition" => {"steps" => [{"id" => "build", "group" => "checks"}, {"id" => "lint", "group" => "checks"}]}})
      run = stored("wr_1")
      run["steps"]["build"].merge!("reason" => {"code" => "retry_backoff"}, "pending_move" => {"group" => "checks", "to" => "plan", "until" => iso(300)})
      run["steps"]["lint"] = {"state" => "failed", "attempts" => [{"n" => 1, "group_move" => {"group" => "checks", "joined" => true}}]}
      File.write(path("wr_1"), JSON.generate(run))

      expect(rows.map { |each| each["outcome"] }.uniq).to eq(["restored"])
      expect(engine.ticks.uniq).to eq(["wr_1"])
      expect(engine.resumes).to be_empty
    end

    it "gives skipped/moved_on and no tick when the run changed while the workspace was restored" do
      add_run("wr_1", "app", 100, step: "checking")
      restore.after = lambda do
        run = stored("wr_1")
        run["steps"]["build"]["state"] = "passed"
        File.write(path("wr_1"), JSON.generate(run))
      end
      expect(rows.first).to include("outcome" => "skipped", "reason" => "moved_on")
      expect(engine.ticks).to be_empty
    end

    it "still ticks a run whose step changed only in what waking does not read" do
      add_run("wr_1", "app", 100, step: "checking")
      restore.after = lambda do
        run = stored("wr_1")
        run["steps"]["build"]["redelivery_pending"] = true
        File.write(path("wr_1"), JSON.generate(run))
      end
      expect(rows.first).to include("outcome" => "restored")
      expect(engine.ticks).to eq(["wr_1"])
    end

    it "gives skipped/moved_on when the step's last attempt ended while the workspace was restored" do
      add_run("wr_1", "app", 100, step: "checking")
      restore.after = lambda do
        run = stored("wr_1")
        run["steps"]["build"]["attempts"].last["ended_at"] = iso(0)
        File.write(path("wr_1"), JSON.generate(run))
      end
      expect(rows.first).to include("outcome" => "skipped", "reason" => "moved_on")
      expect(engine.ticks).to be_empty
    end

    it "restarts a workspace's mid-turn runs before it wakes its between-turns runs" do
      add_run("wr_1", "app", 300, step: "reviewing")
      add_run("wr_2", "app", 200, pane: "%2")
      result = recover.call { {} }

      expect(restore.calls.size).to eq(1)
      expect(engine.changes.map { |each| each.first(2) }).to eq([[:resume, "wr_2"], [:tick, "wr_1"]])
      expect(result[:results].map { |each| each.values_at("run_id", "outcome") }).to eq([%w[wr_1 restored], %w[wr_2 restarted]])
    end

    it "fails with the tick's code when tick raises" do
      add_run("wr_1", "app", 100, step: "checking")
      allow(engine).to receive(:tick).and_raise(Workspace::Error.new("busy", code: "run_not_active"))
      expect(rows.first).to include("outcome" => "failed", "reason" => "run_not_active")
    end
  end

  describe "failed restores" do
    it "fails the first workspace's runs when its restore raises and still recovers the second" do
      add_run("wr_1", "first", 200, step: "checking")
      add_run("wr_2", "first", 150, pane: "%2")
      add_run("wr_3", "second", 100, pane: "%3")
      restore.raises["first"] = Workspace::Error.new("Can't read the session ledger: boom")
      before = [bytes("wr_1"), bytes("wr_2")]
      result = recover.call { {} }

      expect(result[:results].map { |each| each.values_at("run_id", "outcome", "reason") }).to eq([
        ["wr_1", "failed", "restore_failed"], ["wr_2", "failed", "restore_failed"], ["wr_3", "restarted", nil]
      ])
      expect(row_of(result, "wr_1")["message"]).to include("Can't read the session ledger")
      expect(engine.resumes).to eq(["wr_3"])
      expect(engine.ticks).to be_empty
      expect([bytes("wr_1"), bytes("wr_2")]).to eq(before)
      expect(result[:exit_code]).to eq(3)
    end

    it "fails a workspace's runs on a failed restore row and leaves the run file unchanged" do
      add_run("wr_1", "app", 100)
      restore.fails["app"] = "no tmuxinator config"
      before = bytes("wr_1")
      found = rows.first

      expect(found).to include("outcome" => "failed", "reason" => "restore_failed")
      expect(found["message"]).to include("no tmuxinator config")
      expect(found["next_actions"].map { |each| each["action"] }).to eq(["restore", "workflow resume"])
      expect(engine.changes).to be_empty
      expect(bytes("wr_1")).to eq(before)
    end

    it "fails a workspace's runs when its restore raises SystemCallError" do
      add_run("wr_1", "app", 100, step: "checking")
      restore.raises["app"] = Errno::ENOENT.new("tmux")
      found = rows.first
      expect(found).to include("outcome" => "failed", "reason" => "restore_failed")
      expect(found["next_actions"].map { |each| each["action"] }).to eq(["restore"])
    end

    it "fails a wake run whose session is still down after the restore, without a tick" do
      add_run("wr_1", "app", 100, step: "checking")
      restore.stays_down << "app"
      expect(rows.first).to include("outcome" => "failed", "reason" => "restore_failed")
      expect(engine.ticks).to be_empty
    end
  end

  describe "dry run" do
    it "writes nothing, calls no tick or resume, and reports would_restart and would_restore" do
      add_run("wr_1", "app", 200)
      add_run("wr_2", "app", 100, step: "failed", open: false, pane: "%2", extra: {"state" => "waiting", "backoff" => {"until" => iso(300), "to" => "build"}, "reason" => {"code" => "retry_backoff", "details" => {"step" => "build"}}})
      before = [bytes("wr_1"), bytes("wr_2")]
      result = recover.call(dry_run: true) { {} }

      expect(restore.calls).to eq([[["app"], true, false]])
      expect(engine.changes).to be_empty
      expect(readiness.waits).to be_empty
      expect([bytes("wr_1"), bytes("wr_2")]).to eq(before)
      expect(result[:results].map { |each| each["outcome"] }).to eq(%w[would_restart would_restore])
      expect(row_of(result, "wr_2")["due"]).to eq(iso(300))
      expect(result).to include(status: "dry_run", exit_code: 0)
      expect(result[:extra]["next_actions"].last).to include("action" => "workflow recover", "args" => [])
    end

    it "reports a line still being typed as would_restart, saying the real run waits for it" do
      add_run("wr_1", "app", 100)
      engine.refusals["wr_1"] = Workspace::Error.new("Step build's line is still being typed.", code: "step_still_working")
      result = recover.call(dry_run: true) { {} }
      expect(result[:results].first).to include("outcome" => "would_restart")
      expect(result[:results].first["message"]).to include("still being typed", "waits up to 30 seconds")
      expect(result).to include(status: "dry_run", exit_code: 0)
    end

    it "reports a workspace whose restore would fail (its own row unmatched, no config)" do
      add_run("wr_1", "app", 200)
      add_run("wr_2", "ok", 100, pane: "%2")
      restore.fails["app"] = "no tmuxinator config"
      result = recover.call(dry_run: true) { {} }
      expect(result[:results].first).to include("outcome" => "failed", "reason" => "restore_failed")
      expect(result).to include(status: "partial", exit_code: 3)
    end
  end

  describe "a fan_out group under way" do
    def add_group(id, workspace)
      attempt = {"n" => 1, "started_at" => iso(-600)}
      run = {"id" => id, "workspace" => workspace, "state" => "running", "current" => "lint", "pane" => "%1", "created_at" => iso(-100),
             "definition" => {"steps" => [{"id" => "lint", "group" => "checks"}, {"id" => "test", "group" => "checks"}]},
             "steps" => {"lint" => {"state" => "running", "pane" => "%1", "attempts" => [attempt]}, "test" => {"state" => "running", "pane" => "%2", "attempts" => [attempt]}}}
      File.write(path(id), JSON.pretty_generate(run))
      panes.bind(workspace: workspace, pane: "%1", run_id: id, step: "lint")
      panes.bind(workspace: workspace, pane: "%2", run_id: id, step: "test")
    end

    it "sorts and restarts each sibling on its own step and pane, a row for each" do
      add_group("wr_1", "app")

      result = recover.call { {} }

      expect(result[:results].map { |each| [each["run_id"], each["step"], each["outcome"]] }).to eq([%w[wr_1 lint restarted], %w[wr_1 test restarted]])
      expect(readiness.waits).to eq([["s-app", "%1"], ["s-app", "%2"]])
      expect(engine.changes.map { |kind, id, args| [kind, id, args[:step]] }).to eq([[:resume, "wr_1", "lint"], [:resume, "wr_1", "test"]])
    end

    it "leaves a sibling whose pane is alive in a live session, sorting the other on its own" do
      add_group("wr_1", "app")
      live["app"] = true
      panes.stale << "%2"

      result = recover.call { {} }

      expect(result[:results].map { |each| [each["step"], each["reason"]] }).to include(["lint", "pane_alive"])
      expect(result[:results].find { |each| each["step"] == "test" }["reason"]).not_to eq("pane_alive")
    end
  end
end
