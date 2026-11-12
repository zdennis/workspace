require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowRunChange do
  around do |example|
    Dir.mktmpdir("wf-run-change") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
  let(:store) do
    Workspace::WorkflowRunStore.new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive"), clock: -> { now }, id_generator: -> { "wr_1" })
  end
  let(:attempt_record) { Workspace::WorkflowAttemptRecord.new(guard: nil, clock: -> { now }) }
  let(:event_log) { CLITestHelpers::FakeEventLog.new }
  let(:spawned) { [] }
  let(:alert_config) { instance_double(Workspace::AlertConfig, for_workspace: {notify: "notify-me", workflow: ["gate"]}) }
  let(:alerts) do
    Interceptable.subclass(Workspace::WorkflowAlerts, :marks, :fire)
      .new(alert_config: alert_config, spawner: ->(argv, env, _log) { spawned << [argv, env] }, error_output: StringIO.new)
  end
  let(:delivered) { [] }
  let(:deliver) do
    lambda do |run_id, delivery|
      delivered << [run_id, delivery, locked?(run_id)]
      :typed
    end
  end
  let(:change) { described_class.new(store: store, attempt_record: attempt_record, deliver: deliver, alerts: alerts, event_log: event_log) }
  let!(:run_id) do
    store.create({"workflow" => "wf", "workspace" => "app", "state" => "running", "current" => "a", "reason" => nil,
                  "definition" => {"id" => "wf", "steps" => [{"id" => "a"}]},
                  "steps" => {"a" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => now.iso8601}]}}})["id"]
  end

  # The run with the change +edit+ makes to a working copy of it, as a block returns it.
  def edited(run)
    work = Workspace::WorkflowRun.deep_thaw(run.to_h)
    yield work
    Workspace::WorkflowRun.from_h(work)
  end

  # Whether another change of the run would have to wait: the run's lock is held.
  def locked?(id)
    edit_run(store, id, nonblocking: true) { true }.nil?
  end

  describe "#call" do
    it "writes the run the block returns under the run's lock and returns it as stored" do
      held = nil
      result = change.call(run_id) do |run, _ctx|
        held = locked?(run_id)
        edited(run) { |work| work["note"] = "changed" }
      end

      expect(held).to be(true)
      expect(result).to be_a(Workspace::WorkflowRun)
      expect(result.note).to eq("changed")
      expect(stored_run(store, run_id)["note"]).to eq("changed")
    end

    it "gives the block the stored run as a frozen WorkflowRun, and stores it as read when the block returns nil" do
      given = nil
      before = File.read(File.join(@dir, "runs", "#{run_id}.json"))
      result = change.call(run_id) do |run, _ctx|
        given = run
        nil
      end

      expect(given).to be_a(Workspace::WorkflowRun)
      expect(given).to be_frozen
      expect(given.to_h).to be_frozen
      expect(result.to_h).to eq(given.to_h)
      expect(File.read(File.join(@dir, "runs", "#{run_id}.json"))).to eq(before)
    end

    it "refuses a block that returns something other than a run, and writes nothing" do
      before = File.read(File.join(@dir, "runs", "#{run_id}.json"))

      expect { change.call(run_id) { |run, _ctx| Workspace::WorkflowRun.deep_thaw(run.to_h) } }.to raise_error(TypeError, /returned Hash/)
      expect(File.read(File.join(@dir, "runs", "#{run_id}.json"))).to eq(before)
    end

    it "gives every call a Context of its own" do
      contexts = []
      change.call(run_id) do |_run, ctx|
        ctx.deliver({"pane" => "%1"})
        contexts << ctx
        nil
      end
      change.call(run_id) do |_run, ctx|
        contexts << ctx
        nil
      end

      expect(contexts.uniq(&:object_id).size).to eq(2)
      expect(contexts.last.delivery).to be_nil
    end

    it "types a registered line through deliver once the lock is given up, and returns what deliver returns" do
      result = change.call(run_id) do |_run, ctx|
        ctx.deliver({"step" => "a", "pane" => "%1"})
        nil
      end

      expect(result).to eq(:typed)
      expect(delivered).to eq([[run_id, {"step" => "a", "pane" => "%1"}, false]])
    end

    it "lets deliver make a change of its own after the first one is written" do
      nested = nil
      nested = described_class.new(store: store, attempt_record: attempt_record, alerts: alerts, event_log: event_log,
        deliver: ->(id, _delivery) { nested.call(id) { |run, _ctx| edited(run) { |work| work["typed"] = true } } })

      result = nested.call(run_id) do |run, ctx|
        ctx.deliver({"step" => "a"})
        edited(run) { |work| work["dispatched"] = true }
      end

      expect(result.to_h.values_at("dispatched", "typed")).to eq([true, true])
      expect(stored_run(store, run_id).values_at("dispatched", "typed")).to eq([true, true])
    end

    it "never runs a check: one registered is only handed back through the Context" do
      registered = nil
      result = change.call(run_id) do |_run, ctx|
        ctx.check({"step" => "a", "command" => "true"})
        registered = ctx.check
        nil
      end

      expect(registered).to eq({"step" => "a", "command" => "true"})
      expect(result.id).to eq(run_id)
      expect(delivered).to be_empty
    end

    it "returns nil and runs no block when nonblocking finds the run busy" do
      ran = false
      inner = :not_called
      change.call(run_id) do |_run, _ctx|
        inner = change.call(run_id, nonblocking: true) { ran = true }
        nil
      end

      expect(inner).to be_nil
      expect(ran).to be(false)
    end

    it "writes workflow_changed when what a reader sees moved, and nothing when it did not" do
      change.call(run_id) { |run, _ctx| edited(run) { |work| work["state"] = "waiting" } }
      change.call(run_id) { |run, _ctx| edited(run) { |work| work["note"] = "unseen" } }

      expect(event_log.events).to eq([{"type" => "workflow_changed", "project" => "app",
                                       "data" => {"run_id" => run_id, "workflow" => "wf", "workspace" => "app", "state" => "waiting", "step" => "a", "reason" => nil}}])
    end

    it "reads the alert marks inside the lock before the change and fires them once the lock is given up" do
      seen = []
      alerts.on(:marks) do |original, run|
        seen << [:marks, locked?(run_id)]
        original.call(run)
      end
      alerts.on(:fire) do |original, before, run|
        seen << [:fire, locked?(run_id), before[:gate]]
        original.call(before, run)
      end

      change.call(run_id) { |run, _ctx| edited(run) { |work| work["steps"]["a"]["gate"] = {"state" => "waiting"} } }

      expect(seen.first(2)).to eq([[:marks, true], [:fire, false, nil]])
      expect(spawned.size).to eq(1)
      expect(spawned.first[1]).to include("WORKSPACE_ALERT_EVENT" => "gate")
    end

    it "keeps the attempt's reasons: a reason the block sets opens on the attempt that is open" do
      change.call(run_id) do |run, _ctx|
        edited(run) do |work|
          work["state"] = "waiting"
          work["reason"] = {"code" => "waiting_you", "since" => now.iso8601, "details" => {}}
        end
      end

      expect(stored_run(store, run_id)["steps"]["a"]["attempts"].last["reasons"]).to eq([{"code" => "waiting_you", "since" => now.iso8601, "until" => nil}])
    end
  end

  describe "#event" do
    it "appends the line to the run's history at once, under the lock" do
      lines = nil
      change.call(run_id) do |run, _ctx|
        change.event(run, "step_reported", "step" => "a")
        lines = File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line) }
        nil
      end

      expect(lines).to eq([{"ts" => now.iso8601, "type" => "step_reported", "step" => "a"}])
    end
  end
end
