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

  def ctx = Workspace::WorkflowRunChange::Context.new

  describe "#dispatch" do
    it "stores the attempt as delivering, binds the pane and registers the line, returning a new run and leaving the one given alone" do
      given = run_hash
      before = deep_copy(given)
      context = ctx

      run = dispatch.dispatch(given, ctx: context)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(before)
      path = File.join(@dir, ".workflow", "wr_1", "steps", "plan.1.prompt.md")
      expect(run.step("plan").attempts.map(&:to_h)).to eq([{"n" => 1, "started_at" => "2026-11-10T12:00:00.000Z", "context" => ["from before"],
                                                            "delivery" => "delivering", "prompt_file" => path, "prompt_sha256" => "sha256-of-the instructions"}])
      expect(run.to_h).to include("state" => "running", "pane" => "%3", "reason" => nil, "pending_context" => [], "artifacts_dir" => File.join(@dir, ".workflow", "wr_1"))
      expect(run.step("plan").state).to eq("running")
      expect(context.delivery).to eq("step" => "plan", "attempt" => 1, "workspace" => "app", "pane" => "%3", "text" => "Read #{path} and follow it.",
        "fresh" => false, "remote_baseline" => false, "worktree" => @dir)
      expect(panes.calls).to include([:bind, {workspace: "app", pane: "%3", run_id: "wr_1", step: "plan", attempt: 1, instructions: path, artifacts: File.join(@dir, ".workflow", "wr_1")}])
      expect(resources.calls.first).to eq([:acquire, {run_id: "wr_1", step: "plan", uses: ["devenv"], worktree: @dir, workflow: "flow", workspace: "app", pane: "%3"}])
      expect(attempt_record.calls).to eq([[:start, "wr_1", 1]])
      expect(change.events).to eq([["wr_1", "step_dispatching", {"step" => "plan", "attempt" => 1, "pane" => "%3"}]])
    end

    it "drops a park as moved_on, carrying its note into the attempt's context" do
      run = dispatch.dispatch(run_hash("parked" => {"id" => "p1", "note" => "mind the flake"}), ctx: ctx)

      expect(run.parked).to be_nil
      expect(run.step("plan").last_attempt.context).to eq(["from before", "Note from the person who resumed the run: mind the flake"])
      expect(change.events.first).to eq(["wr_1", "resume_parked_ended", {"step" => "plan", "how" => "moved_on"}])
    end

    it "waits for a lock another holder has, writing the wait to the event log and typing nothing" do
      resources = RecordingRunResources.new(acquired: {waiting: {name: "devenv", position: 1, total: 2, holder: {"run_id" => "wr_9", "pane" => "%5", "kind" => "run"}}})
      dispatch = described_class.new(change: change, store: store, resources: resources, panes: panes, prompt: prompt, attempt_record: attempt_record,
        guard: guard, event_log: event_log, clock: -> { now })
      context = ctx

      run = dispatch.dispatch(run_hash, ctx: context)

      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "waiting_lock", "since" => "2026-11-10T12:00:00Z",
        "details" => {"resource" => "devenv", "step" => "plan", "position" => 1, "total" => 2, "holder" => {"run_id" => "wr_9", "kind" => "run"}})
      expect(run.step("plan").attempts).to be_empty
      expect(context.delivery).to be_nil
      expect(event_log.events).to eq([{"type" => "lock_wait_started", "project" => "app",
                                       "data" => {"lock" => "devenv", "run_id" => "wr_1", "step" => "plan", "workspace" => "app", "position" => 1, "holder" => {"run_id" => "wr_9", "pane" => "%5"}}}])
    end

    it "holds the attempt when the token budget is spent, keeping the context for the resume" do
      spent = run_hash("definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})

      run = dispatch.dispatch(spent, ctx: ctx, context: "fresh")

      expect(run.budget_hold).to eq("context" => "fresh", "pane" => "%3", "identity" => "identity-of-wr_1")
      expect(run.state).to eq("waiting")
      expect(run.reason).to include("code" => "budget_spent")
      expect(run.reason["details"]).to include("kind" => "budget", "run_id" => "wr_1", "used" => 150, "allowance" => 100)
      expect(run.step("plan").attempts.size).to eq(1)
      expect(change.events.last).to eq(["wr_1", "budget_spent", {"used" => 150, "allowance" => 100, "counted" => 1, "uncounted" => 0, "step" => "plan"}])
    end

    it "starts the attempt over a spent budget when told not to hold it (a redelivery)" do
      spent = run_hash("definition" => run_hash["definition"].merge("budget" => {"tokens" => 100}),
        "steps" => {"plan" => {"state" => "failed", "attempts" => [{"n" => 1, "outcome" => "failed", "usage" => {"input_tokens" => 150}}]}})

      run = dispatch.dispatch(spent, ctx: ctx, budgeted: false)

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
        run = dispatch.dispatch(timed, ctx: ctx, context: "fresh")

        expect(run.timeout_hold).to eq("context" => "fresh", "pane" => "%3", "identity" => "identity-of-wr_1")
        expect(run.budget_hold).to be_nil
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "run_timed_out")
        expect(run.reason["details"]).to include("kind" => "timeout", "run_id" => "wr_1", "step" => "plan", "used" => 7200, "limit" => 3600, "needed" => 3601, "suggested" => 4500)
        expect(run.step("plan").attempts.size).to eq(1)
        expect(change.events.last).to eq(["wr_1", "run_timed_out", {"used" => 7200.0, "limit" => 3600, "timeout" => 3600, "extra_seconds" => 0, "step" => "plan"}])
      end

      it "starts the attempt when told not to hold it (a redelivery), when the lock wait it ends was allowed, or when --extra-time covers it" do
        expect(dispatch.dispatch(timed, ctx: ctx, budgeted: false).step("plan").attempts.map(&:n)).to eq([1, 2])
        waited = timed.merge("reason" => {"code" => "waiting_lock", "since" => "2026-11-10T11:00:00Z", "details" => {}})
        expect(dispatch.dispatch(waited, ctx: ctx).timeout_hold).to be_nil
        extended = timed.merge("extra_seconds" => 3601)
        expect(dispatch.dispatch(extended, ctx: ctx).state).to eq("running")
      end

      it "holds under both limits when the token budget is spent too, naming the budget and carrying the timeout's details" do
        both = timed.merge("definition" => timed["definition"].merge("budget" => {"tokens" => 100}))
        both["steps"]["plan"]["attempts"][0]["usage"] = {"input_tokens" => 150}

        run = dispatch.dispatch(both, ctx: ctx, context: "fresh")

        expect(run.reason).to include("code" => "budget_spent")
        expect(run.reason["details"]["run_timed_out"]).to include("kind" => "timeout", "limit" => 3600)
        expect(run.budget_hold).to eq(run.timeout_hold)
        expect(change.events.map { |event| event[1] }.last(2)).to eq(%w[budget_spent run_timed_out])
      end
    end

    it "leaves the run waiting for a person when the checkout is gone" do
      run = dispatch.dispatch(run_hash("worktree" => File.join(@dir, "gone")), ctx: ctx)

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

  describe "#deliver" do
    let(:path) { File.join(@dir, ".workflow", "wr_1", "steps", "plan.1.prompt.md") }
    let(:delivery) { {"step" => "plan", "attempt" => 1, "workspace" => "app", "pane" => "%3", "text" => "Read #{path} and follow it.", "fresh" => false, "worktree" => @dir} }

    def delivering(**attempt)
      run_hash("state" => "running", "steps" => {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "context" => ["told"], "delivery" => "delivering"}.merge(attempt)]}})
    end

    it "types the line and settles the mark, recording the answer in the run's history" do
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(run.step("plan").last_attempt.to_h).to eq("n" => 1, "context" => ["told"])
      expect(panes.calls).to include([:kick, {workspace: "app", pane: "%3", text: "Read #{path} and follow it.", fresh: false, run_id: "wr_1"}])
      expect(store.events).to eq([["wr_1", "step_dispatched", {"step" => "plan", "attempt" => 1, "pane" => "%3", "delivered" => true}]])
    end

    it "reads the remote first for a step with a remote_unchanged proof" do
      store.runs["wr_1"] = delivering

      run = dispatch.deliver("wr_1", delivery.merge("remote_baseline" => true))

      expect(run.step("plan").last_attempt.remote).to eq("sha" => "abc")
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
