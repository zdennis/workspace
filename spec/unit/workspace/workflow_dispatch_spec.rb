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

    it "leaves the run waiting for a person when the checkout is gone" do
      run = dispatch.dispatch(run_hash("worktree" => File.join(@dir, "gone")), ctx: ctx)

      expect(run.state).to eq("waiting")
      expect(run.reason["details"]).to include("kind" => "dispatch", "error" => "error", "message" => "the checkout #{File.join(@dir, "gone")} is gone")
      expect(resources.calls.map(&:first)).to eq([:release])
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
