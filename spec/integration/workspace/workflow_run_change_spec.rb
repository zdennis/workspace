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
    Interceptable.subclass(Workspace::WorkflowRunStore, :record_event)
      .new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive"), clock: -> { now }, id_generator: -> { "wr_1" })
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
    work = run.thawed
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
      result = change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
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
      result = change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
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

      expect { change.call(run_id, actor: "engine", cause: "test") { |run, _ctx| run.thawed } }.to raise_error(TypeError, /returned Hash/)
      expect(File.read(File.join(@dir, "runs", "#{run_id}.json"))).to eq(before)
    end

    it "gives every call a Context of its own" do
      contexts = []
      change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        ctx.deliver({"pane" => "%1"})
        contexts << ctx
        nil
      end
      change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        contexts << ctx
        nil
      end

      expect(contexts.uniq(&:object_id).size).to eq(2)
      expect(contexts.last.delivery).to be_nil
    end

    it "hands a registered review round back on the context and runs nothing for it" do
      seen = nil
      result = change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        ctx.review({"round" => 1})
        seen = ctx
        nil
      end

      expect(seen.review).to eq("round" => 1)
      expect(result).to be_a(Workspace::WorkflowRun)
      expect(delivered).to eq([])
    end

    it "types a registered line through deliver once the lock is given up, and returns what deliver returns" do
      result = change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        ctx.deliver({"step" => "a", "pane" => "%1"})
        nil
      end

      expect(result).to eq(:typed)
      expect(delivered).to eq([[run_id, {"step" => "a", "pane" => "%1"}, false]])
    end

    it "lets deliver make a change of its own after the first one is written" do
      nested = nil
      nested = described_class.new(store: store, attempt_record: attempt_record, alerts: alerts, event_log: event_log,
        deliver: ->(id, _delivery) { nested.call(id, actor: "engine", cause: "test") { |run, _ctx| edited(run) { |work| work["typed"] = true } } })

      result = nested.call(run_id, actor: "engine", cause: "test") do |run, ctx|
        ctx.deliver({"step" => "a"})
        edited(run) { |work| work["dispatched"] = true }
      end

      expect(result.to_h.values_at("dispatched", "typed")).to eq([true, true])
      expect(stored_run(store, run_id).values_at("dispatched", "typed")).to eq([true, true])
    end

    it "never runs a check: one registered is only handed back through the Context" do
      registered = nil
      result = change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        ctx.check({"step" => "a", "command" => "true"})
        registered = ctx.check
        nil
      end

      expect(registered).to eq({"step" => "a", "command" => "true"})
      expect(result.id).to eq(run_id)
      expect(delivered).to be_empty
    end

    it "runs what the block registered to follow the lock once it is given up, with the run as stored, dropping one that raises" do
      seen = []
      result = change.call(run_id, actor: "engine", cause: "test") do |run, ctx|
        ctx.after_lock { |_stored| raise ArgumentError, "a notice that fails" }
        ctx.after_lock { |stored| seen << [stored.note, locked?(run_id)] }
        edited(run) { |work| work["note"] = "changed" }
      end

      expect(seen).to eq([["changed", false]])
      expect(result.note).to eq("changed")
    end

    it "runs nothing registered to follow the lock when the block raises" do
      seen = []

      expect do
        change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
          ctx.after_lock { |_stored| seen << :ran }
          raise Workspace::Error.new("refused", code: "refused")
        end
      end.to raise_error(Workspace::Error)
      expect(seen).to be_empty
    end

    it "returns nil and runs no block when nonblocking finds the run busy" do
      ran = false
      inner = :not_called
      change.call(run_id, actor: "engine", cause: "test") do |_run, _ctx|
        inner = change.call(run_id, actor: "engine", cause: "test", nonblocking: true) { ran = true }
        nil
      end

      expect(inner).to be_nil
      expect(ran).to be(false)
    end

    it "writes workflow_changed when what a reader sees moved, and nothing when it did not" do
      change.call(run_id, actor: "engine", cause: "test") { |run, _ctx| edited(run) { |work| work["state"] = "waiting" } }
      change.call(run_id, actor: "engine", cause: "test") { |run, _ctx| edited(run) { |work| work["note"] = "unseen" } }

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

      change.call(run_id, actor: "engine", cause: "test") { |run, _ctx| edited(run) { |work| work["steps"]["a"]["gate"] = {"state" => "waiting"} } }

      expect(seen.first(2)).to eq([[:marks, true], [:fire, false, nil]])
      expect(spawned.size).to eq(1)
      expect(spawned.first[1]).to include("WORKSPACE_ALERT_EVENT" => "gate")
    end

    it "keeps the attempt's reasons: a reason the block sets opens on the attempt that is open" do
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        edited(run) do |work|
          work["state"] = "waiting"
          work["reason"] = {"code" => "waiting_you", "since" => now.iso8601, "details" => {}}
        end
      end

      expect(stored_run(store, run_id)["steps"]["a"]["attempts"].last["reasons"]).to eq([{"code" => "waiting_you", "since" => now.iso8601, "until" => nil}])
    end
  end

  describe "#call when the history can't be written" do
    it "still saves the run and the loss shows in event_errors" do
      log_path = File.join(@dir, "event-errors.log")
      failing = Workspace::WorkflowRunStore.new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive"), clock: -> { now }, event_errors_path: log_path)
      FileUtils.mkdir_p(failing.events_path(run_id))
      failing_change = described_class.new(store: failing, attempt_record: attempt_record, deliver: deliver, alerts: alerts, event_log: event_log)

      failing_change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        failing_change.event(run, "step_reported", "step" => "a")
        edited(run) { |work| work["note"] = "changed" }
      end

      expect(stored_run(failing, run_id)["note"]).to eq("changed")
      expect(failing.event_errors(run_id).map { |entry| [entry["type"], entry["errno"]] }).to eq([%w[step_reported EISDIR]])
    end
  end

  describe "#event" do
    def lines(id = run_id)
      File.exist?(store.events_path(id)) ? File.readlines(store.events_path(id)).map { |line| JSON.parse(line) } : []
    end

    it "queues a line written inside the block and writes it once the run is stored, still under the lock" do
      seen = nil
      store.on(:record_event) do |original, *args|
        seen = [File.exist?(File.join(@dir, "runs", "#{run_id}.json")) && stored_run(store, run_id)["note"], locked?(run_id)]
        original.call(*args)
      end
      inside = nil
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        change.event(run, "step_reported", "step" => "a")
        inside = lines
        edited(run) { |work| work["note"] = "changed" }
      end

      expect(inside).to eq([])
      expect(seen).to eq(["changed", true])
      expect(lines).to eq([{"ts" => now.iso8601(3), "type" => "step_reported", "step" => "a", "from_state" => "running", "to_state" => "running", "actor" => "engine", "cause" => "test"}])
    end

    it "gives a queued line the change's from_state and to_state, and keeps a key the event has of its own" do
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        change.event(run.to_h, "step_failed", "step" => "a", "to_state" => "own")
        change.event(run, "run_failed")
        edited(run) { |work| work["state"] = "failed" }
      end

      expect(lines.map { |line| line.values_at("type", "from_state", "to_state") }).to eq([%w[step_failed running own], %w[run_failed running failed]])
      expect(store.events_path(run_id)).to start_with(File.join(@dir, "archive"))
    end

    it "writes the change's actor on every queued line, and keeps an actor the event has of its own" do
      change.call(run_id, actor: "sweep", cause: "test") do |run, _ctx|
        change.event(run, "step_stalled", "step" => "a")
        change.event(run, "noted", "actor" => "own")
        nil
      end

      expect(lines.map { |line| line["actor"] }).to eq(%w[sweep own])
    end

    it "accepts each of engine, agent, person, sweep and daemon, and refuses any other actor before it changes anything" do
      %w[engine agent person sweep daemon].each { |actor| expect { change.call(run_id, actor: actor, cause: "test") { nil } }.not_to raise_error }
      ran = false
      expect { change.call(run_id, actor: "robot", cause: "test") { ran = true } }.to raise_error(ArgumentError, /unknown actor "robot"/)
      expect { change.call(run_id, actor: nil, cause: "test") { ran = true } }.to raise_error(ArgumentError)
      expect(ran).to be(false)
    end

    it "writes the change's cause on every queued line, and keeps a cause the event has of its own" do
      change.call(run_id, actor: "sweep", cause: "sweep_stall") do |run, _ctx|
        change.event(run, "step_stalled", "step" => "a")
        change.event(run, "step_failed", "cause" => "own")
        nil
      end

      expect(lines.map { |line| line["cause"] }).to eq(%w[sweep_stall own])
    end

    it "refuses a missing, empty or non-string cause before it changes anything" do
      ran = false
      expect { change.call(run_id, actor: "engine") { ran = true } }.to raise_error(ArgumentError, /missing keyword: :cause/)
      expect { change.call(run_id, actor: "engine", cause: "") { ran = true } }.to raise_error(ArgumentError, /needs a cause/)
      expect { change.call(run_id, actor: "engine", cause: :tick) { ran = true } }.to raise_error(ArgumentError, /needs a cause/)
      expect(ran).to be(false)
    end

    it "writes no line when the block raises after queueing one" do
      expect do
        change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
          change.event(run, "attempts_extended", "step" => "a")
          raise Workspace::Error.new("refused", code: "refused")
        end
      end.to raise_error(Workspace::Error, "refused")

      expect(lines).to eq([])
    end

    it "writes no line when the store can't write the run" do
      expect do
        change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
          change.event(run, "budget_extended", "step" => "a")
          edited(run) { |work| work["note"] = Float::NAN }
        end
      end.to raise_error(Workspace::Error)

      expect(lines).to eq([])
    end

    it "writes a line for another run at once" do
      other = Workspace::WorkflowRunStore.new(dir: File.join(@dir, "runs"), archive_dir: File.join(@dir, "archive"), clock: -> { now }, id_generator: -> { "wr_2" })
        .create({"workflow" => "wf", "state" => "running"})["id"]
      inside = nil
      change.call(run_id, actor: "engine", cause: "test") do |_run, _ctx|
        change.event({"id" => other}, "noted")
        inside = lines(other)
        nil
      end

      expect(inside).to eq([{"ts" => now.iso8601(3), "type" => "noted"}])
    end

    it "writes queued lines before the step_dispatched line deliver writes" do
      typing = described_class.new(store: store, attempt_record: attempt_record, alerts: alerts, event_log: event_log,
        deliver: ->(id, delivery) { store.record_event(id, "step_dispatched", "step" => delivery["step"]) })
      typing.call(run_id, actor: "engine", cause: "test") do |run, ctx|
        typing.event(run, "step_dispatching", "step" => "a")
        ctx.deliver({"step" => "a"})
        nil
      end

      expect(lines.map { |line| line["type"] }).to eq(%w[step_dispatching step_dispatched])
    end

    it "writes a line from an after-lock block at once, and keeps the outer queue past a nested change of the same run" do
      after = nil
      change.call(run_id, actor: "engine", cause: "test") do |run, ctx|
        change.call(run_id, actor: "engine", cause: "test", nonblocking: true) { nil }
        change.event(run, "late")
        ctx.after_lock do |stored|
          change.event(stored, "noticed")
          after = lines.map { |line| line["type"] }
        end
        nil
      end

      expect(after).to eq(%w[late noticed])
      expect(lines.map { |line| line.key?("from_state") }).to eq([true, false])
    end

    it "keeps the lines of changes one after the other in change order, each from_state the last to_state" do
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        change.event(run, "first")
        edited(run) { |work| work["state"] = "waiting" }
      end
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        change.event(run, "second")
        edited(run) { |work| work["state"] = "running" }
      end

      expect(lines.map { |line| line.values_at("type", "from_state", "to_state") }).to eq([%w[first running waiting], %w[second waiting running]])
    end

    it "writes no line for a nonblocking change that finds the run busy" do
      inner = :not_called
      change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        inner = change.call(run_id, actor: "engine", cause: "test", nonblocking: true) { |busy, _inner_ctx| change.event(busy, "never") }
        nil
      end

      expect(inner).to be_nil
      expect(lines).to eq([])
    end

    it "keeps the stored change and the other lines when writing one queued line raises" do
      store.on(:record_event) do |original, id, type, data|
        raise IOError, "disk gone" if type == "broken"
        original.call(id, type, data)
      end
      result = change.call(run_id, actor: "engine", cause: "test") do |run, _ctx|
        change.event(run, "broken")
        change.event(run, "kept")
        edited(run) { |work| work["note"] = "stored" }
      end

      expect(result.note).to eq("stored")
      expect(stored_run(store, run_id)["note"]).to eq("stored")
      expect(lines.map { |line| line["type"] }).to eq(["kept"])
    end

    it "writes Context#event lines as it writes queued ones" do
      change.call(run_id, actor: "engine", cause: "test") do |_run, ctx|
        ctx.event("step_reported", "step" => "a")
        nil
      end

      expect(lines.map { |line| line.values_at("type", "from_state") }).to eq([%w[step_reported running]])
    end
  end
end
