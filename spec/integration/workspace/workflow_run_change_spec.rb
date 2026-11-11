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

  # Whether another change of the run would have to wait: the run's lock is held.
  def locked?(id)
    store.update(id, nonblocking: true) { true }.nil?
  end

  describe "#call" do
    it "writes the block's change under the run's lock and returns the run as stored" do
      held = nil
      result = change.call(run_id) do |stored, _ctx|
        held = locked?(run_id)
        stored["note"] = "changed"
      end

      expect(held).to be(true)
      expect(result["note"]).to eq("changed")
      expect(store.find(run_id)["note"]).to eq("changed")
    end

    it "gives every call a Context of its own" do
      contexts = []
      change.call(run_id) do |_stored, ctx|
        ctx.deliver({"pane" => "%1"})
        contexts << ctx
      end
      change.call(run_id) { |_stored, ctx| contexts << ctx }

      expect(contexts.uniq(&:object_id).size).to eq(2)
      expect(contexts.last.delivery).to be_nil
    end

    it "types a registered line through deliver once the lock is given up, and returns what deliver returns" do
      result = change.call(run_id) { |_stored, ctx| ctx.deliver({"step" => "a", "pane" => "%1"}) }

      expect(result).to eq(:typed)
      expect(delivered).to eq([[run_id, {"step" => "a", "pane" => "%1"}, false]])
    end

    it "lets deliver make a change of its own after the first one is written" do
      nested = nil
      nested = described_class.new(store: store, attempt_record: attempt_record, alerts: alerts, event_log: event_log,
        deliver: ->(id, _delivery) { nested.call(id) { |stored, _ctx| stored["typed"] = true } })

      result = nested.call(run_id) do |stored, ctx|
        stored["dispatched"] = true
        ctx.deliver({"step" => "a"})
      end

      expect(result.values_at("dispatched", "typed")).to eq([true, true])
      expect(store.find(run_id).values_at("dispatched", "typed")).to eq([true, true])
    end

    it "never runs a check: one registered is only handed back through the Context" do
      registered = nil
      result = change.call(run_id) do |_stored, ctx|
        ctx.check({"step" => "a", "command" => "true"})
        registered = ctx.check
      end

      expect(registered).to eq({"step" => "a", "command" => "true"})
      expect(result["id"]).to eq(run_id)
      expect(delivered).to be_empty
    end

    it "returns nil and runs no block when nonblocking finds the run busy" do
      ran = false
      inner = :not_called
      change.call(run_id) do |_stored, _ctx|
        inner = change.call(run_id, nonblocking: true) { ran = true }
      end

      expect(inner).to be_nil
      expect(ran).to be(false)
    end

    it "writes workflow_changed when what a reader sees moved, and nothing when it did not" do
      change.call(run_id) { |stored, _ctx| stored["state"] = "waiting" }
      change.call(run_id) { |stored, _ctx| stored["note"] = "unseen" }

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

      change.call(run_id) { |stored, _ctx| stored["steps"]["a"]["gate"] = {"state" => "waiting"} }

      expect(seen.first(2)).to eq([[:marks, true], [:fire, false, nil]])
      expect(spawned.size).to eq(1)
      expect(spawned.first[1]).to include("WORKSPACE_ALERT_EVENT" => "gate")
    end

    it "keeps the attempt's reasons: a reason the block sets opens on the attempt that is open" do
      change.call(run_id) do |stored, _ctx|
        stored["state"] = "waiting"
        stored["reason"] = {"code" => "waiting_you", "since" => now.iso8601, "details" => {}}
      end

      expect(store.find(run_id)["steps"]["a"]["attempts"].last["reasons"]).to eq([{"code" => "waiting_you", "since" => now.iso8601, "until" => nil}])
    end
  end

  describe "#event" do
    it "appends the line to the run's history at once, under the lock" do
      lines = nil
      change.call(run_id) do |stored, _ctx|
        change.event(stored, "step_reported", "step" => "a")
        lines = File.readlines(store.events_path(run_id)).map { |line| JSON.parse(line) }
      end

      expect(lines).to eq([{"ts" => now.iso8601, "type" => "step_reported", "step" => "a"}])
    end
  end
end
