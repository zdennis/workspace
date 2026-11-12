require "spec_helper"

RSpec.describe Workspace::HookFanout do
  let(:order) { [] }
  let(:monitor) { RecordingHookMonitor.new(order: order) }
  let(:hook_log) { RecordingHookLog.new(order: order) }
  let(:handoff_watcher) { RecordingHandoffWatcher.new(order: order) }
  let(:nudger) { RecordingNudger.new(order: order) }
  let(:owner_report) { RecordingOwnerReport.new(order: order) }
  let(:queue_desk) { RecordingHookDesk.new(order: order, label: :queue_desk) }
  let(:recovery_desk) { RecordingHookDesk.new(order: order, label: :recovery_desk) }
  let(:now) { Time.utc(2026, 11, 11, 12, 0, 0) }
  let(:log_output) { StringIO.new }
  let(:spawned) { [] }

  def fanout(**given)
    described_class.new(workspace: "myapp", monitor: monitor, hook_log: hook_log, handoff_watcher: handoff_watcher,
      nudger: nudger, owner_report: owner_report, desks: [queue_desk, recovery_desk], clock: -> { now },
      spawn: ->(&work) { spawned << work },
      logger: Workspace::Logger.new(output: log_output, enabled: true), **given)
  end

  def event(name, **extra) = {"type" => "session_event", "workspace" => "myapp", "event" => name, "pane_id" => "%1"}.merge(extra)

  describe "#session_event" do
    it "hands a main agent's Stop to the watcher, monitor, hook log, nudger, owner report, queue desk and recovery desk in that order" do
      fanout(spawn: ->(&work) { work.call }).session_event(event("stop"))

      expect(order).to eq([[:handoff_watcher, :session_event], [:monitor, :record], [:hook_log, :record],
        [:nudger, :turn_ended], [:owner_report, :turn_ended], [:queue_desk, :session_event], [:recovery_desk, :session_event]])
    end

    it "hands the owner report to spawn rather than running it on the caller's thread" do
      fanout.session_event(event("stop"))

      expect(spawned.size).to eq(1)
      expect(order).to eq([[:handoff_watcher, :session_event], [:monitor, :record], [:hook_log, :record],
        [:nudger, :turn_ended], [:queue_desk, :session_event], [:recovery_desk, :session_event]])
      spawned.first.call
      expect(owner_report.calls).to eq([[:turn_ended, "%1"]])
    end

    it "leaves the nudger and the owner report out for a sub-agent's event" do
      fanout.session_event(event("stop", "agent_id" => "a1"))

      expect(order.map(&:first)).to eq(%i[handoff_watcher monitor hook_log queue_desk recovery_desk])
      expect(spawned).to be_empty
    end

    it "tells the nudger when the turn that ended began, and forgets it at a new session" do
      subject = fanout
      subject.session_event(event("user_prompt"))
      subject.session_event(event("stop", "background_tasks" => ["b1"]))
      subject.session_event(event("session_start"))
      subject.session_event(event("stop"))

      expect(nudger.calls).to eq([
        [:turn_ended, "myapp", "%1", {turn_started: now, background: ["b1"]}],
        [:turn_ended, "myapp", "%1", {turn_started: nil, background: nil}]
      ])
    end

    it "keeps going when the handoff watcher raises, logging it" do
      fanout(handoff_watcher: RecordingHandoffWatcher.new(order: order, fail_with: RuntimeError.new("boom"))).session_event(event("user_prompt"))

      expect(order.map(&:first)).to eq(%i[handoff_watcher monitor hook_log queue_desk recovery_desk])
      expect(log_output.string).to include("handoff watcher: RuntimeError: boom")
    end

    it "lets a desk that raises stop the desks after it" do
      failing = RecordingHookDesk.new(order: order, label: :queue_desk, fail_with: RuntimeError.new("full"))

      expect { fanout(desks: [failing, recovery_desk]).session_event(event("user_prompt")) }.to raise_error(RuntimeError, "full")
      expect(recovery_desk.calls).to be_empty
    end

    it "needs only the monitor: the optional parts left out are skipped" do
      described_class.new(workspace: "myapp", monitor: monitor, desks: [nil]).session_event(event("stop"))

      expect(order).to eq([[:monitor, :record]])
    end
  end

  describe "#scan_desks" do
    it "scans the queue desk then the recovery desk" do
      fanout.scan_desks

      expect(order).to eq([[:queue_desk, :scan], [:recovery_desk, :scan]])
    end

    it "scans the next desk when one raises, logging it" do
      failing = RecordingHookDesk.new(order: order, label: :queue_desk, fail_with: RuntimeError.new("wedged"))
      fanout(desks: [failing, recovery_desk]).scan_desks

      expect(order).to eq([[:queue_desk, :scan], [:recovery_desk, :scan]])
      expect(log_output.string).to include("agent: RecordingHookDesk scan failed (RuntimeError: wedged)")
    end
  end
end
