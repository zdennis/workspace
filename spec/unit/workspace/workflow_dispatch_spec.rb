require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowDispatch do
  around do |example|
    Dir.mktmpdir("wf-dispatch") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new(going: going, parked_on: parked_on, backoff_on: backoff_on) }
  let(:going) { [] }
  let(:parked_on) { {} }
  let(:backoff_on) { {} }
  let(:finished) { [] }
  let(:change) { RecordingRunChange.new(store.runs, finished: finished) }
  let(:resources) { RecordingRunResources.new }
  let(:panes) { RecordingWorkflowPanes.new }
  let(:prompt) { RecordingWorkflowPrompt.new(text: "the instructions") }
  let(:attempt_record) { RecordingAttemptRecord.new }
  let(:guard) { instance_double(Workspace::WorkflowGuard, remote_head: {"sha" => "abc"}) }
  let(:event_log) { CLITestHelpers::FakeEventLog.new }

  subject(:dispatch) do
    described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
      guard: guard, event_log: event_log, clock: -> { now })
  end

  def run_hash(**overrides)
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => @dir, "state" => "waiting",
     "current" => "plan", "pane" => "%3", "loops" => {}, "pending_context" => ["from before"], "reason" => nil,
     "definition" => {"id" => "flow", "steps" => [{"id" => "plan", "prompt" => "Plan.", "produces" => ["plan.md"], "uses" => ["devenv"]}]},
     "steps" => {"plan" => {"state" => "pending", "attempts" => []}}}.merge(overrides)
  end

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def ctx = Workspace::WorkflowRunChange::Context.new("engine", "test")

  describe "#dispatch" do
    it "stores the attempt as delivering, binds the pane and registers the line, returning a new run and leaving the one given alone" do
      given = run_hash
      before = deep_copy(given)
      context = ctx

      run = dispatch.dispatch(given, ctx: context, cause: "first")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(before)
      path = File.join(@dir, ".workflow", "wr_1", "steps", "plan.1.prompt.md")
      expect(run.step("plan").attempts.map(&:to_h)).to eq([{"n" => 1, "started_at" => "2026-11-10T12:00:00.000Z", "context" => ["from before"],
                                                            "delivery" => "delivering", "prompt_file" => path, "prompt_sha256" => "sha256-of-the instructions"}])
      expect(run.to_h).to include("state" => "running", "pane" => "%3", "reason" => nil, "pending_context" => [], "artifacts_dir" => File.join(@dir, ".workflow", "wr_1"))
      expect(run.step("plan").state).to eq("running")
      expect(context.delivery).to eq("step" => "plan", "attempt" => 1, "workspace" => "app", "pane" => "%3", "text" => "Read #{path} and follow it.",
        "fresh" => false, "remote_baseline" => false, "worktree" => @dir, "cause" => "first")
      expect(panes.calls).to include([:bind, {workspace: "app", pane: "%3", run_id: "wr_1", step: "plan", attempt: 1, instructions: path, artifacts: File.join(@dir, ".workflow", "wr_1")}])
      expect(resources.calls.first).to eq([:acquire, {run_id: "wr_1", step: "plan", uses: ["devenv"], worktree: @dir, workflow: "flow", workspace: "app", pane: "%3"}])
      expect(attempt_record.calls).to eq([[:start, "wr_1", 1]])
      expect(change.events).to eq([["wr_1", "step_dispatching", {"step" => "plan", "attempt" => 1, "pane" => "%3", "cause" => "first", "retry_of" => nil}]])
    end

    it "drops a park as moved_on, carrying its note into the attempt's context" do
      run = dispatch.dispatch(run_hash("parked" => {"id" => "p1", "note" => "mind the flake"}), ctx: ctx, cause: "first")

      expect(run.parked).to be_nil
      expect(run.step("plan").last_attempt.context).to eq(["from before", "Note from the person who resumed the run: mind the flake"])
      expect(change.events.first).to eq(["wr_1", "resume_parked_ended", {"step" => "plan", "how" => "moved_on"}])
    end

    it "waits for a lock another holder has, writing the wait to the event log and typing nothing" do
      resources = RecordingRunResources.new(acquired: {waiting: {name: "devenv", position: 1, total: 2, holder: {"run_id" => "wr_9", "pane" => "%5", "kind" => "run"}}})
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, event_log: event_log, clock: -> { now })
      context = ctx

      run = dispatch.dispatch(run_hash, ctx: context, cause: "first")

      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "waiting_lock", "since" => "2026-11-10T12:00:00Z",
        "details" => {"resource" => "devenv", "step" => "plan", "position" => 1, "total" => 2, "holder" => {"run_id" => "wr_9", "kind" => "run"}})
      expect(run.step("plan").attempts).to be_empty
      expect(context.delivery).to be_nil
      expect(event_log.events).to eq([{"type" => "lock_wait_started", "project" => "app",
                                       "data" => {"lock" => "devenv", "run_id" => "wr_1", "step" => "plan", "workspace" => "app", "position" => 1, "holder" => {"run_id" => "wr_9", "pane" => "%5"}}}])
    end

    it "keeps the cause of a dispatch that waited for a lock for the one that ends the wait, and falls back to lock_ended without one" do
      waiting = RecordingRunResources.new(acquired: {waiting: {name: "devenv", position: 1, total: 1, holder: {"run_id" => "wr_9", "kind" => "run"}}})
      blocked = described_class.new(change: change, store: store, resources: waiting, panes: panes, prompt: prompt, attempt_record: attempt_record, guard: guard, clock: -> { now })

      held = blocked.dispatch(run_hash, ctx: ctx, cause: "next_step")

      expect(held.to_h["dispatch_cause_pending"]).to eq("step" => "plan", "cause" => "next_step")
      again = blocked.dispatch(held, ctx: ctx, cause: "lock_ended")
      expect(again.to_h["dispatch_cause_pending"]).to eq("step" => "plan", "cause" => "next_step")

      change.events.clear
      run = dispatch.dispatch(held, ctx: ctx, cause: "lock_ended")
      expect(change.events.last).to include("wr_1", "step_dispatching")
      expect(change.events.last.last).to include("cause" => "next_step")
      expect(run.to_h).not_to have_key("dispatch_cause_pending")

      change.events.clear
      dispatch.dispatch(run_hash, ctx: ctx, cause: "lock_ended")
      expect(change.events.last.last).to include("cause" => "lock_ended")

      change.events.clear
      other = held.thawed.merge("dispatch_cause_pending" => {"step" => "elsewhere", "cause" => "loop"})
      dispatch.dispatch(other, ctx: ctx, cause: "lock_ended")
      expect(change.events.last.last).to include("cause" => "lock_ended")
    end

    it "holds a paused run's attempt before anything is taken, recording what it would have started and typing nothing" do
      paused = run_hash("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"}, "parked" => {"id" => "p1", "note" => "later"},
        "definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})
      context = ctx

      run = dispatch.dispatch(paused, ctx: context, cause: "loop", context: "fresh", retry_of: {"text" => "fix it", "attempt" => 1})

      expect(run.to_h["pause_hold"]).to eq("kind" => "attempt", "cause" => "loop", "context" => "fresh", "budgeted" => true, "pane" => "%3", "identity" => "identity-of-wr_1",
        "text" => "fix it", "retry_of" => 1)
      expect(run.state).to eq("waiting")
      expect(run.reason).to be_nil
      expect(run.budget_hold).to be_nil
      expect(run.parked).to eq("id" => "p1", "note" => "later")
      expect(run.pending_context).to eq(["from before"])
      expect(run.step("plan").state).to eq("failed")
      expect(run.step("plan").attempts.size).to eq(1)
      expect(context.delivery).to be_nil
      expect(resources.calls.map(&:first)).to eq([:release])
      expect(panes.calls.map(&:first)).not_to include(:bind, :kick)
      expect(attempt_record.calls).to be_empty
      expect(change.events).to be_empty
    end

    it "keeps the pane and identity a backoff's retry names, and an unbudgeted dispatch's budgeted, on its pause hold" do
      paused = run_hash("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})

      run = dispatch.dispatch(paused, ctx: ctx, cause: "redelivery", budgeted: false, retry_of: {"pane" => "%8", "identity" => "id-8", "text" => "again"})

      expect(run.to_h["pause_hold"]).to eq("kind" => "attempt", "cause" => "redelivery", "budgeted" => false, "pane" => "%8", "identity" => "id-8", "text" => "again")
    end

    it "keeps the run's locks on a hold that asks it to, as a paused rerun's does" do
      paused = run_hash("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})

      run = dispatch.hold_paused(paused, {"kind" => "round", "cause" => "rerun", "review_round" => 2}, release: false)

      expect(run.to_h["pause_hold"]).to include("cause" => "rerun")
      expect(resources.calls).to be_empty
      expect(dispatch.hold_paused(run_hash, {"kind" => "round"})).to be_nil
    end

    it "keeps the first held dispatch, leaving a run that already holds one as it is" do
      first = {"kind" => "delivery", "step" => "plan", "attempt" => 1, "delivery" => {"step" => "plan"}}
      paused = run_hash("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"}, "pause_hold" => first, "state" => "running")

      run = dispatch.dispatch(paused, ctx: ctx, cause: "next_step")

      expect(run.to_h).to eq(paused)
      expect(dispatch.hold_paused(paused, {"kind" => "round", "review_round" => 1}).to_h).to eq(paused)
      expect(resources.calls).to be_empty
    end

    it "holds the attempt when the token budget is spent, keeping the context for the resume" do
      spent = run_hash("definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})

      run = dispatch.dispatch(spent, ctx: ctx, cause: "first", context: "fresh")

      expect(run.budget_hold).to eq("context" => "fresh", "pane" => "%3", "identity" => "identity-of-wr_1")
      expect(run.state).to eq("waiting")
      expect(run.reason).to include("code" => "budget_spent")
      expect(run.reason["details"]).to include("kind" => "budget", "run_id" => "wr_1", "used" => 150, "allowance" => 100)
      expect(run.step("plan").attempts.size).to eq(1)
      expect(change.events.last).to eq(["wr_1", "budget_spent", {"used" => 150, "allowance" => 100, "counted" => 1, "uncounted" => 0, "step" => "plan"}])
    end

    it "records the attempt a review rejected as the new attempt's retry_of, and keeps it on a hold" do
      failed = run_hash("steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed"}]}})

      run = dispatch.dispatch(failed, ctx: ctx, cause: "review_rejected", retry_of: {"text" => "the verdicts", "attempt" => 1})

      expect(run.step("plan").last_attempt.to_h).to include("n" => 2, "retry_of" => 1)
      expect(change.events.last).to eq(["wr_1", "step_dispatching", {"step" => "plan", "attempt" => 2, "pane" => "%3", "cause" => "review_rejected", "retry_of" => 1}])

      spent = run_hash("definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})

      held = dispatch.dispatch(spent, ctx: ctx, cause: "first", retry_of: {"text" => "the verdicts", "attempt" => 1})

      expect(held.budget_hold).to include("text" => "the verdicts", "retry_of" => 1)
    end

    it "keeps a review's retry_of through a lock wait, for the dispatch that ends it, and only for that step" do
      waiting = RecordingRunResources.new(acquired: {waiting: {name: "devenv", position: 1, total: 1, holder: {"run_id" => "wr_9", "kind" => "run"}}})
      failed = run_hash("steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed"}]}})
      blocked = described_class.new(change: change, store: store, resources: waiting, panes: panes, prompt: prompt, attempt_record: attempt_record, guard: guard, clock: -> { now })

      held = blocked.dispatch(failed, ctx: ctx, cause: "first", context: "fresh", retry_of: {"text" => "the verdicts", "attempt" => 1})

      expect(held.reason["code"]).to eq("waiting_lock")
      expect(held.to_h["retry_of_pending"]).to eq("step" => "plan", "attempt" => 1, "context" => "fresh", "text" => "the verdicts")

      woken = ctx
      run = dispatch.dispatch(held, ctx: woken, cause: "first")

      expect(run.step("plan").last_attempt.to_h).to include("n" => 2, "retry_of" => 1)
      expect(woken.delivery).to include("fresh" => true)
      expect(run.to_h).not_to have_key("retry_of_pending")

      plain = blocked.dispatch(held.thawed.merge("retry_of_pending" => {"step" => "build", "attempt" => 1}), ctx: ctx, cause: "first")
      expect(plain.to_h).not_to have_key("retry_of_pending")

      elsewhere = dispatch.dispatch(held.thawed.merge("retry_of_pending" => {"step" => "build", "attempt" => 1}), ctx: ctx, cause: "first")
      expect(elsewhere.step("plan").last_attempt.to_h).not_to have_key("retry_of")
    end

    it "starts the attempt over a spent budget when told not to hold it (a redelivery)" do
      spent = run_hash("definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})

      run = dispatch.dispatch(spent, ctx: ctx, cause: "first", budgeted: false)

      expect(run.budget_hold).to be_nil
      expect(run.step("plan").attempts.map(&:n)).to eq([1, 2])
      expect(run.state).to eq("running")
    end

    context "with a run timeout" do
      let(:timed) do
        run_hash("definition" => run_hash["definition"].merge("timeout" => 3600),
          "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "started_at" => "2026-11-10T10:00:00.000Z"}]}})
      end

      it "holds the attempt once the machine time is used, keeping the context for the resume" do
        run = dispatch.dispatch(timed, ctx: ctx, cause: "first", context: "fresh")

        expect(run.timeout_hold).to eq("context" => "fresh", "pane" => "%3", "identity" => "identity-of-wr_1")
        expect(run.budget_hold).to be_nil
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "run_timed_out")
        expect(run.reason["details"]).to include("kind" => "timeout", "run_id" => "wr_1", "step" => "plan", "used" => 7200, "limit" => 3600, "needed" => 3601, "suggested" => 4500)
        expect(run.step("plan").attempts.size).to eq(1)
        expect(change.events.last).to eq(["wr_1", "run_timed_out", {"used" => 7200.0, "limit" => 3600, "timeout" => 3600, "extra_seconds" => 0, "step" => "plan"}])
      end

      it "starts the attempt when told not to hold it (a redelivery), when the lock wait it ends was allowed, or when --extra-time covers it" do
        expect(dispatch.dispatch(timed, ctx: ctx, cause: "first", budgeted: false).step("plan").attempts.map(&:n)).to eq([1, 2])
        waited = timed.merge("reason" => {"code" => "waiting_lock", "since" => "2026-11-10T11:00:00Z", "details" => {}})
        expect(dispatch.dispatch(waited, ctx: ctx, cause: "first").timeout_hold).to be_nil
        extended = timed.merge("extra_seconds" => 3601)
        expect(dispatch.dispatch(extended, ctx: ctx, cause: "first").state).to eq("running")
      end

      it "holds under both limits when the token budget is spent too, naming the budget and carrying the timeout's details" do
        both = timed.merge("definition" => timed["definition"].merge("budget" => {"tokens" => 100}))
        both["steps"]["plan"]["attempts"][0]["usage"] = {"input_tokens" => 150}

        run = dispatch.dispatch(both, ctx: ctx, cause: "first", context: "fresh")

        expect(run.reason).to include("code" => "budget_spent")
        expect(run.reason["details"]["run_timed_out"]).to include("kind" => "timeout", "limit" => 3600)
        expect(run.budget_hold).to eq(run.timeout_hold)
        expect(change.events.map { |event| event[1] }.last(2)).to eq(%w[budget_spent run_timed_out])
      end
    end

    it "leaves the run waiting for a person when the checkout is gone" do
      run = dispatch.dispatch(run_hash("worktree" => File.join(@dir, "gone")), ctx: ctx, cause: "first")

      expect(run.state).to eq("waiting")
      expect(run.reason["details"]).to include("kind" => "dispatch", "error" => "error", "message" => "the checkout #{File.join(@dir, "gone")} is gone")
      expect(resources.calls.map(&:first)).to eq([:release])
    end
  end

  describe "#hold_round" do
    def reviewing(**overrides)
      run_hash("state" => "running", "definition" => run_hash["definition"].merge(overrides),
        "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 1,
                               "attempts" => [{"n" => 1, "started_at" => "2026-11-10T10:00:00.000Z", "ended_at" => "2026-11-10T10:30:00Z",
                                               "outcome" => "checks_passed", "usage" => {"input_tokens" => 150}}]}})
    end

    it "holds a round past the token budget with budget_spent, recording the round and no pane, and gives up the locks" do
      given = reviewing("budget" => {"tokens" => 100})
      before = deep_copy(given)

      run = dispatch.hold_round(given, round: 2)

      expect(given).to eq(before)
      expect(run.budget_hold).to eq("review_round" => 2)
      expect(run.timeout_hold).to be_nil
      expect(run.state).to eq("waiting")
      expect(run.reason).to include("code" => "budget_spent")
      expect(run.reason["details"]).to include("kind" => "budget", "step" => "plan", "used" => 150, "allowance" => 100, "review_round" => 2)
      expect(run.step("plan").state).to eq("reviewing")
      expect(resources.calls.map(&:first)).to eq([:release])
      expect(change.events.last).to eq(["wr_1", "budget_spent", {"used" => 150, "allowance" => 100, "counted" => 1, "uncounted" => 0, "step" => "plan"}])
    end

    it "holds a round past the run's timeout with run_timed_out" do
      run = dispatch.hold_round(reviewing("timeout" => 3600), round: 1)

      expect(run.timeout_hold).to eq("review_round" => 1)
      expect(run.budget_hold).to be_nil
      expect(run.reason).to include("code" => "run_timed_out")
      expect(run.reason["details"]).to include("kind" => "timeout", "limit" => 3600, "review_round" => 1)
    end

    it "holds under both limits with the one record, naming the budget" do
      run = dispatch.hold_round(reviewing("budget" => {"tokens" => 100}, "timeout" => 3600), round: 1)

      expect(run.reason["code"]).to eq("budget_spent")
      expect(run.budget_hold).to eq(run.timeout_hold)
      expect(run.reason["details"]["run_timed_out"]).to include("limit" => 3600)
    end

    it "holds a paused run's round ahead of its limits, recording pause_hold of kind round and giving up the locks" do
      given = reviewing("budget" => {"tokens" => 100}).merge("paused" => {"since" => "2026-11-10T11:55:00Z", "by" => "person"})
      before = deep_copy(given)

      run = dispatch.hold_round(given, round: 2)

      expect(given).to eq(before)
      expect(run.to_h["pause_hold"]).to eq("kind" => "round", "review_round" => 2)
      expect(run.budget_hold).to be_nil
      expect(run.state).to eq("waiting")
      expect(run.reason).to be_nil
      expect(run.step("plan").state).to eq("reviewing")
      expect(resources.calls.map(&:first)).to eq([:release])
      expect(change.events).to be_empty
    end

    it "lets the round start within the limits, with no limits, and on a wake from a lock wait" do
      expect(dispatch.hold_round(reviewing("budget" => {"tokens" => 1000}, "timeout" => 36_000), round: 1)).to be_nil
      expect(dispatch.hold_round(reviewing, round: 1)).to be_nil
      waited = reviewing("budget" => {"tokens" => 100}, "timeout" => 3600).merge("reason" => {"code" => "waiting_lock", "since" => "2026-11-10T11:00:00Z", "details" => {}})
      expect(dispatch.hold_round(waited, round: 1)).to be_nil
      expect(change.events).to be_empty
      expect(resources.calls).to be_empty
    end
  end

  describe "#hold_round_lock" do
    def reviewing(uses: ["review-db"])
      review = {"from" => %w[skeptic], "need" => 1, "must" => []}
      review["uses"] = uses if uses
      run_hash("state" => "running",
        "definition" => {"id" => "flow", "steps" => [{"id" => "plan", "prompt" => "Plan.", "produces" => ["plan.md"], "uses" => ["devenv"], "review" => review}]},
        "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 0, "attempts" => [{"n" => 1, "outcome" => "checks_passed"}]}})
    end

    it "takes the review's uses in place of the step's, with no pane, and lets the round start" do
      expect(dispatch.hold_round_lock(reviewing, round: 1, step_state: "reviewing")).to be_nil

      expect(resources.calls).to eq([[:acquire, {run_id: "wr_1", step: "plan", uses: ["review-db"], worktree: @dir, workflow: "flow", workspace: "app", pane: nil}]])
    end

    it "gives up the step's own uses when the review names none" do
      expect(dispatch.hold_round_lock(reviewing(uses: nil), round: 1, step_state: "reviewing")).to be_nil

      expect(resources.calls.first.last).to include(uses: nil)
    end

    context "when a lock the review uses is taken" do
      let(:resources) { RecordingRunResources.new(acquired: {waiting: {name: "review-db", position: 1, total: 1, holder: {"run_id" => "wr_9", "kind" => "run"}}}) }

      it "waits on waiting_lock with the round named, the step left reviewing, and leaves the run given alone" do
        given = reviewing
        before = deep_copy(given)

        run = dispatch.hold_round_lock(given, round: 2, step_state: "reviewing")

        expect(given).to eq(before)
        expect(run.state).to eq("waiting")
        expect(run.step("plan").state).to eq("reviewing")
        expect(run.reason).to include("code" => "waiting_lock", "since" => "2026-11-10T12:00:00Z")
        expect(run.reason["details"]).to include("resource" => "review-db", "step" => "plan", "review_round" => 2, "holder" => {"run_id" => "wr_9", "kind" => "run"})
        expect(event_log.events.map { |each| each["type"] }).to eq(["lock_wait_started"])
      end

      it "keeps the wait's since, and logs no second wait, when asked again for the same lock" do
        waited = reviewing.merge("reason" => {"code" => "waiting_lock", "since" => "2026-11-10T11:00:00Z", "details" => {"resource" => "review-db"}})

        run = dispatch.hold_round_lock(waited, round: 2, step_state: "reviewing")

        expect(run.reason["since"]).to eq("2026-11-10T11:00:00Z")
        expect(event_log.events).to be_empty
      end
    end

    it "keeps the round from starting for a person when the lock store can't be read, giving up none of the run's locks" do
      failing = RecordingRunResources.new(error: Errno::EACCES.new("locks.json"))
      dispatch = described_class.new(change: change, store: store, resources: failing, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, event_log: event_log, clock: -> { now })

      run = dispatch.hold_round_lock(reviewing, round: 1, step_state: "reviewing")

      expect(run.state).to eq("waiting")
      expect(run.step("plan").state).to eq("reviewing")
      expect(run.reason).to include("code" => "waiting_you")
      expect(run.reason["details"]).to include("kind" => "review", "step" => "plan", "review_round" => 1, "error" => "error")
      expect(failing.calls.map(&:first)).to eq([:acquire])
    end
  end

  describe "#type_continue" do
    let(:mark) { {"pane" => "%3", "pid" => 41, "kind" => "claude", "step" => "plan", "attempt" => 1, "since" => "2026-11-10T11:30:00Z"} }

    # The plan step's attempt 1 open and running, as a continue mark names it.
    def open_run(**overrides)
      store.runs["wr_1"] = run_hash("state" => "running", "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}]}}, **overrides)
    end

    def over(panes) = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record, guard: guard, clock: -> { now })

    it "types the line as it is, with no new conversation, and records step_continued, changing no run" do
      open_run

      kick = dispatch.type_continue("wr_1", mark, workspace: "app", text: "Continue step plan.", actor: "person", cause: "unpause")

      expect(kick).to eq(ok: true)
      expect(panes.calls).to eq([[:kick, {workspace: "app", pane: "%3", text: "Continue step plan.", fresh: false, run_id: "wr_1"}]])
      expect(store.events).to eq([["wr_1", "step_continued", {"step" => "plan", "attempt" => 1, "pane" => "%3", "delivered" => true,
                                                              "actor" => "person", "cause" => "unpause", "from_state" => nil, "to_state" => nil}]])
      expect(change.calls).to be_empty
    end

    it "puts the mark back as continue_pending, its since kept, when the pane refuses the line or the kick raises" do
      refusing = over(RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}))
      raising = over(RecordingWorkflowPanes.new(on_kick: ->(**) { raise Workspace::Error.new("no daemon", code: "no_daemon") }))

      open_run
      expect(refusing.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to eq(ok: false, code: "pane_busy", message: "busy", pending: true)
      expect(store.runs["wr_1"]["continue_pending"]).to eq(mark)
      open_run
      expect(raising.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to eq(ok: false, code: "no_daemon", message: "no daemon", pending: true)
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false, actor: "daemon", cause: "tick"}]] * 2)
      expect(store.events.map { |event| event.last.slice("delivered", "code", "pending") }).to eq([
        {"delivered" => false, "code" => "pane_busy", "pending" => true}, {"delivered" => false, "code" => "no_daemon", "pending" => true}
      ])
    end

    it "records the refusal on the marked attempt and the event, and a second refusal replaces the first" do
      seen = {"state" => "working", "changed_by" => "screen", "refusal_reason" => "busy"}
      first = over(RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy", reason: "working", seen: seen}))
      second = over(RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy again\e[2J", reason: "waiting", seen: seen.merge("state" => "waiting")}))
      open_run

      first.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")
      expect(store.runs["wr_1"]["steps"]["plan"]["attempts"].last["refusal"]).to eq("error" => "pane_busy", "message" => "busy", "reason" => "working", "seen" => seen)
      second.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")

      expect(store.runs["wr_1"]["steps"]["plan"]["attempts"].last["refusal"]).to include("message" => "busy again\\e[2J", "reason" => "waiting", "seen" => include("state" => "waiting"))
      expect(store.events.last.last).to include("code" => "pane_busy", "reason" => "waiting", "seen_state" => "waiting", "seen_changed_by" => "screen")
      expect(store.events.last.last).to include("code" => "pane_busy", "message" => "busy again\e[2J")
      expect(store.events.last.last).not_to have_key("error")
      expect(store.events.last.last).not_to have_key("seen_seen_at")
    end

    it "flattens a seen key that already starts with seen_ without prefixing it again" do
      expect(described_class.refusal_event_keys({"error" => "pane_busy", "seen" => {"seen_at" => "t", "state" => "working"}})).to eq("error" => "pane_busy", "seen_at" => "t", "seen_state" => "working")
    end

    it "does not raise when no attempt matches the mark" do
      refusing = over(RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}))
      open_run("steps" => {"plan" => {"state" => "running", "attempts" => []}})

      expect(refusing.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to include(ok: false)
    end

    it "types nothing into a run paused again since its caller's change, and keeps the mark for the next unpause" do
      open_run("paused" => {"since" => "2026-11-10T11:59:00Z", "by" => "person"})

      kick = dispatch.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")

      expect(kick).to include(ok: false, code: "run_paused", pending: true)
      expect(panes.calls).to be_empty
      expect(store.runs["wr_1"]["continue_pending"]).to eq(mark)
    end

    it "keeps no mark for a pane that is gone" do
      open_run
      gone = over(RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_gone", message: "gone"}))

      expect(gone.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to include(pending: false)
      expect(store.runs["wr_1"]).not_to have_key("continue_pending")
    end

    it "types nothing and keeps no mark when the attempt was decided or the run ended since its caller's change" do
      open_run
      store.runs["wr_1"]["steps"]["plan"]["attempts"].last["ended_at"] = "2026-11-10T11:50:00Z"
      expect(dispatch.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to include(ok: false, code: "moved_on", pending: false)

      open_run("state" => "cancelled")
      expect(dispatch.type_continue("wr_1", mark, workspace: "app", text: "go", actor: "daemon", cause: "tick")).to include(ok: false, code: "moved_on", pending: false)

      expect(panes.calls).to be_empty
      expect(change.calls).to be_empty
      expect(store.runs["wr_1"]).not_to have_key("continue_pending")
      expect(store.events.map { |event| event.last["code"] }).to eq(%w[moved_on moved_on])
    end
  end

  describe "#deliver" do
    let(:path) { File.join(@dir, ".workflow", "wr_1", "steps", "plan.1.prompt.md") }
    let(:delivery) { {"step" => "plan", "attempt" => 1, "workspace" => "app", "pane" => "%3", "text" => "Read #{path} and follow it.", "fresh" => false, "worktree" => @dir, "cause" => "next_step"} }

    def delivering(**attempt)
      run_hash("state" => "running", "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "context" => ["told"], "delivery" => "delivering"}.merge(attempt)]}})
    end

    it "settles the mark as the engine, a change of its own after the lock" do
      store.runs["wr_1"] = delivering

      dispatch.deliver("wr_1", delivery)

      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: false, actor: "engine", cause: "delivery"}]])
    end

    it "types the line and settles the mark, recording the answer in the run's history" do
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(run.step("plan").last_attempt.to_h).to eq("n" => 1, "context" => ["told"])
      expect(panes.calls).to include([:kick, {workspace: "app", pane: "%3", text: "Read #{path} and follow it.", fresh: false, run_id: "wr_1"}])
      expect(store.events).to eq([["wr_1", "step_dispatched", {"step" => "plan", "attempt" => 1, "pane" => "%3", "delivered" => true, "actor" => "engine", "cause" => "next_step", "from_state" => nil, "to_state" => nil}]])
    end

    it "reads the remote first for a step with a remote_unchanged proof" do
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery.merge("remote_baseline" => true))

      expect(run.step("plan").last_attempt.remote).to eq("sha" => "abc")
    end

    it "records a pane_busy refusal on the attempt, the run's reason and step_dispatched, escaping pane text" do
      seen = {"state" => "working", "changed_by" => "screen", "refusal_reason" => "shows a prompt"}
      panes = RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "pane \e[2Jbusy", reason: "prompt", seen: seen})
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery)

      refusal = {"error" => "pane_busy", "message" => "pane \\e[2Jbusy", "reason" => "prompt", "seen" => seen}
      expect(run.step("plan").last_attempt.refusal).to eq(refusal)
      expect(run.reason["details"]).to include("seen" => seen, "reason" => "prompt")
      expect(store.events.first.last).to include("delivered" => false, "error" => "pane_busy", "message" => "pane \\e[2Jbusy", "reason" => "prompt",
        "seen_state" => "working", "seen_changed_by" => "screen", "seen_refusal_reason" => "shows a prompt")
    end

    it "parks a released resume again when the pane was only busy, naming the pane it was released into" do
      panes = RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "the agent is working"})
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })
      store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => 0})

      run = dispatch.deliver("wr_1", delivery)

      expect(run.step("plan").last_attempt.to_h).to include("outcome" => "not_delivered", "code" => "pane_busy")
      expect(run.pending_context).to eq(["told", "from before"])
      expect(run.parked).to include("from" => nil, "note" => nil, "pane" => nil, "turn_over" => nil, "requested_at" => "2026-11-10T12:00:00Z",
        "expires_at" => (now + 600).utc.iso8601, "retries" => 1)
      expect(run.parked["id"]).to match(/\A\h{16}\z/)
      expect(change.events).to eq([["wr_1", "resume_parked", {"step" => "plan", "pane" => "%3", "from" => nil, "has_note" => false, "retry" => true}]])
    end

    it "records waiting_you when the daemon says no_such_pane but tmux still lists the pane" do
      panes = RecordingWorkflowPanes.new(kick: {ok: false, code: "no_such_pane", message: "no pane"}, gone: [])
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery)

      expect(panes.gone_checks).to eq([["%3", "app"]])
      expect(run.reason).to include("code" => "waiting_you")
      expect(run.reason["details"]).to include("error" => "no_such_pane")
      expect(run.reason["details"]).not_to have_key("pane_listed")
      expect(run.step("plan").last_attempt.to_h).to include("outcome" => "not_delivered", "code" => "no_such_pane")
    end

    it "records pane_gone when the daemon says no_such_pane and tmux agrees" do
      panes = RecordingWorkflowPanes.new(kick: {ok: false, code: "no_such_pane", message: "no pane"}, gone: ["%3"])
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery)

      expect(run.reason).to include("code" => "pane_gone")
      expect(panes.gone_checks.size).to eq(1)
    end

    def dispatch_with(kick, gone: [])
      panes = RecordingWorkflowPanes.new(kick: kick, gone: gone)
      [described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now }), panes]
    end

    it "parks a released resume again on no_such_pane when tmux still lists the pane" do
      dispatch, = dispatch_with({ok: false, code: "no_such_pane", message: "no pane"})
      store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => 0})

      run = dispatch.deliver("wr_1", delivery)

      expect(run.reason).to include("code" => "waiting_you")
      expect(run.parked).to include("retries" => 1)
      expect(change.events).to eq([["wr_1", "resume_parked", {"step" => "plan", "pane" => "%3", "from" => nil, "has_note" => false, "retry" => true}]])
    end

    it "does not park again on no_such_pane when tmux confirms the pane is gone" do
      dispatch, = dispatch_with({ok: false, code: "no_such_pane", message: "no pane"}, gone: ["%3"])
      store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => 0})

      run = dispatch.deliver("wr_1", delivery)

      expect(run.reason).to include("code" => "pane_gone")
      expect(run.parked).to be_nil
      expect(change.events).to eq([])
    end

    it "parks again on clear_not_confirmed up to PARK_RETRIES times, then waits for a person" do
      dispatch, = dispatch_with({ok: false, code: "clear_not_confirmed", message: "no change"})
      (0...described_class::PARK_RETRIES).each do |n|
        store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => n})
        run = dispatch.deliver("wr_1", delivery)
        expect(run.parked).to include("retries" => n + 1)
        expect(run.step("plan").last_attempt.to_h).to include("outcome" => "not_delivered", "code" => "clear_not_confirmed")
      end

      store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => described_class::PARK_RETRIES})
      run = dispatch.deliver("wr_1", delivery)

      expect(run.parked).to be_nil
      expect(run.reason).to include("code" => "waiting_you")
      expect(run.reason["details"]).to include("error" => "clear_not_confirmed")
    end

    context "when the run was paused after the line was registered" do
      let(:panes) { RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "the agent is working"}) }

      it "types nothing, keeps the attempt open and running with no delivery mark, and holds the registered line" do
        store.runs["wr_1"] = run_hash
        context = ctx
        dispatch.dispatch(store.runs["wr_1"], ctx: context, cause: "next_step").then { |run| store.runs["wr_1"] = run.thawed }
        registered = context.delivery
        store.runs["wr_1"]["steps"]["plan"]["attempts"].last["after_park"] = {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => 0}
        store.runs["wr_1"]["paused"] = {"since" => "2026-11-10T12:00:00Z", "by" => "person"}
        panes.calls.clear
        change.events.clear

        run = dispatch.deliver("wr_1", registered)

        expect(panes.calls.map(&:first)).not_to include(:kick)
        attempt = run.step("plan").last_attempt.to_h
        expect(attempt).not_to include("delivery", "outcome", "ended_at", "code")
        expect(run.step("plan").state).to eq("running")
        expect(run.state).to eq("running")
        expect(run.reason).to be_nil
        expect(run.parked).to be_nil
        expect(run.to_h["pause_hold"]).to eq("kind" => "delivery", "step" => "plan", "attempt" => 1, "delivery" => registered)
        expect(store.events).to eq([["wr_1", "step_dispatched", {"step" => "plan", "attempt" => 1, "pane" => "%3", "delivered" => false, "actor" => "engine",
                                                                 "cause" => "paused", "from_state" => nil, "to_state" => nil}]])
        expect(change.events).to be_empty
      end

      it "leaves the held attempt running when a late answer for the line comes after the pause ends: no not_delivered, no park again" do
        store.runs["wr_1"] = delivering("after_park" => {"expires_at" => (now + 600).utc.iso8601, "pane" => "%3", "retries" => 0})
          .merge("paused" => {"since" => "2026-11-10T12:00:00Z", "by" => "person"})
        dispatch.deliver("wr_1", delivery)
        store.runs["wr_1"].delete("paused")

        run = dispatch.deliver("wr_1", delivery)

        expect(run.step("plan").last_attempt.to_h).not_to include("delivery", "outcome", "code")
        expect(run.step("plan").state).to eq("running")
        expect(run.reason).to be_nil
        expect(run.parked).to be_nil
      end

      it "types nothing and keeps the first hold when the paused run already holds a dispatch" do
        first = {"kind" => "round", "review_round" => 1}
        store.runs["wr_1"] = delivering.merge("paused" => {"since" => "2026-11-10T12:00:00Z", "by" => "person"}, "pause_hold" => first)

        run = dispatch.deliver("wr_1", delivery)

        expect(panes.calls.map(&:first)).not_to include(:kick)
        expect(run.to_h["pause_hold"]).to eq(first)
        expect(store.events).to be_empty
      end

      context "when the pause ends between the read and the hold" do
        let(:store) do
          Class.new(RecordingRunStore) do
            def run(id)
              read = super
              Workspace::WorkflowRun.from_h(read.thawed.merge("paused" => {"since" => "2026-11-10T12:00:00Z", "by" => "person"}))
            end
          end.new(going: going, parked_on: parked_on, backoff_on: backoff_on)
        end

        it "types the line when the pause ended before the hold could be written" do
          store.runs["wr_1"] = delivering

          run = dispatch.deliver("wr_1", delivery)

          expect(panes.calls.map(&:first)).to include(:kick)
          expect(run.to_h).not_to have_key("pause_hold")
        end
      end
    end

    it "keeps a cancel that came while the line was on its way" do
      store.runs["wr_1"] = delivering.merge("state" => "cancelled")
      finished << "wr_1"

      expect(dispatch.deliver("wr_1", delivery).state).to eq("cancelled")
    end
  end

  describe "#check_pane" do
    it "refuses a pane bound to a run still going, and lets one bound to a finished run go" do
      panes = RecordingWorkflowPanes.new(runs_on: {"%3" => "wr_9", "%4" => "wr_8"})
      going << "wr_9"
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })

      expect { dispatch.check_pane("%3") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("pane_has_run")
        expect(e.details).to eq("pane" => "%3", "run_id" => "wr_9")
      }
      expect { dispatch.check_pane("%4") }.not_to raise_error
      expect { dispatch.check_pane(nil) }.not_to raise_error
    end

    it "refuses a review pane of a run still going, for any run, so an agent is never started in it" do
      panes = RecordingWorkflowPanes.new(reviewing: {"%7" => "wr_9"})
      going << "wr_9"
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, clock: -> { now })

      expect { dispatch.check_pane("%7", run_id: "wr_9") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_has_run") }
    end

    it "refuses a pane a parked run waits for, but not to the run that parked" do
      parked_on["%3"] = run_hash("id" => "wr_7")

      expect { dispatch.check_pane("%3", run_id: "wr_1") }.to raise_error(Workspace::Error) { |e| expect(e.details).to eq("pane" => "%3", "run_id" => "wr_7") }
      expect { dispatch.check_pane("%3", run_id: "wr_7") }.not_to raise_error
      expect(store.calls).to include([:parked_on, "%3", {except: "wr_1", now: now}])
    end

    it "refuses a pane a retry waits for while the panes say it is still the same pane" do
      backoff_on["%3"] = run_hash("id" => "wr_6", "backoff" => {"to" => "plan", "identity" => "id-6"})

      expect { dispatch.check_pane("%3") }.to raise_error(Workspace::Error) { |e| expect(e.details["run_id"]).to eq("wr_6") }
      expect(panes.calls).to eq([[:same_pane?, "%3", "id-6"]])
    end
  end

  describe "#release" do
    it "gives up the run's locks and writes lock_released for each" do
      resources = RecordingRunResources.new(released: ["devenv"])
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, event_log: event_log, clock: -> { now })

      dispatch.release(Workspace::WorkflowRun.from_h(run_hash))

      expect(resources.calls).to eq([[:release, {run_id: "wr_1", worktree: @dir, names: nil}]])
      expect(event_log.events).to eq([{"type" => "lock_released", "project" => "app", "data" => {"lock" => "devenv", "run_id" => "wr_1", "step" => "plan", "workspace" => "app"}}])
    end
  end

  describe "#drop_park" do
    it "returns the run without its park and writes how it ended" do
      run = dispatch.drop_park(run_hash("parked" => {"id" => "p1"}), "failed", "error" => "pane_gone")

      expect(run.parked).to be_nil
      expect(change.events).to eq([["wr_1", "resume_parked_ended", {"step" => "plan", "how" => "failed", "error" => "pane_gone"}]])
    end

    it "returns a run with no park as it is, writing nothing" do
      expect(dispatch.drop_park(run_hash, "ended")).to eq(Workspace::WorkflowRun.from_h(run_hash))
      expect(change.events).to be_empty
    end
  end
end
