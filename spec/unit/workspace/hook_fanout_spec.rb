require "spec_helper"

RSpec.describe Workspace::HookFanout do
  let(:order) { [] }
  let(:monitor) { RecordingHookMonitor.new(order: order) }
  let(:hook_log) { RecordingHookLog.new(order: order) }
  let(:handoff_watcher) { RecordingHandoffWatcher.new(order: order) }
  let(:queue_desk) { RecordingHookDesk.new(order: order, label: :queue_desk) }
  let(:recovery_desk) { RecordingHookDesk.new(order: order, label: :recovery_desk) }
  let(:log_output) { StringIO.new }

  def fanout(**given)
    Workspace::HookFanout.new(monitor: monitor, hook_log: hook_log, subscribers: [handoff_watcher, queue_desk, recovery_desk],
      logger: Workspace::Logger.new(output: log_output, enabled: true), **given)
  end

  def event(name, **extra) = {"type" => "session_event", "workspace" => "myapp", "event" => name, "pane_id" => "%1"}.merge(extra)

  describe "#session_event" do
    it "runs the before_record subscribers, then the monitor, the hook log, then the session_event subscribers" do
      fanout.session_event(event("stop"))

      expect(order).to eq([[:handoff_watcher, :before_record], [:monitor, :record], [:hook_log, :record],
        [:queue_desk, :session_event], [:recovery_desk, :session_event]])
    end

    it "calls only the subscribers that respond to the event" do
      fanout.session_event(event("user_prompt"))

      expect(handoff_watcher.calls.map(&:first)).to eq([:before_record])
      expect(queue_desk.calls.map(&:first)).to eq([:session_event])
    end

    it "keeps going when a before_record subscriber raises, logging it" do
      failing = RecordingHandoffWatcher.new(order: order, fail_with: RuntimeError.new("boom"))
      fanout(subscribers: [failing, queue_desk]).session_event(event("user_prompt"))

      expect(order.map(&:first)).to eq(%i[handoff_watcher monitor hook_log queue_desk])
      expect(log_output.string).to include("agent: RecordingHandoffWatcher before_record failed (RuntimeError: boom)")
    end

    it "logs a session_event subscriber that raises and still runs the ones after it" do
      failing = RecordingHookDesk.new(order: order, label: :queue_desk, fail_with: RuntimeError.new("full"))
      fanout(subscribers: [failing, recovery_desk]).session_event(event("user_prompt"))

      expect(order.map(&:first)).to eq(%i[monitor hook_log queue_desk recovery_desk])
      expect(recovery_desk.calls.size).to eq(1)
      expect(log_output.string).to include("agent: RecordingHookDesk session_event failed (RuntimeError: full)")
    end

    it "does not run the session_event subscribers when the monitor raises" do
      allow(monitor).to receive(:record).and_raise(RuntimeError, "monitor down")

      expect { fanout.session_event(event("stop")) }.to raise_error(RuntimeError, "monitor down")
      expect(queue_desk.calls).to be_empty
    end

    it "needs only the monitor: the optional parts left out are skipped" do
      Workspace::HookFanout.new(monitor: monitor, subscribers: [nil]).session_event(event("stop"))

      expect(order).to eq([[:monitor, :record]])
    end
  end

  describe "#scan" do
    it "scans the subscribers that respond to it, in order" do
      work_queue_desk = RecordingWorkQueueDesk.new(order: order)
      fanout(subscribers: [handoff_watcher, queue_desk, recovery_desk, work_queue_desk]).scan

      expect(order).to eq([[:queue_desk, :scan], [:recovery_desk, :scan], [:work_queue_desk, :scan]])
    end

    it "scans the next subscriber when one raises, logging it" do
      failing = RecordingHookDesk.new(order: order, label: :queue_desk, fail_with: RuntimeError.new("wedged"))
      work_queue_desk = RecordingWorkQueueDesk.new(order: order)
      fanout(subscribers: [failing, recovery_desk, work_queue_desk]).scan

      expect(order).to eq([[:queue_desk, :scan], [:recovery_desk, :scan], [:work_queue_desk, :scan]])
      expect(log_output.string).to include("agent: RecordingHookDesk scan failed (RuntimeError: wedged)")
    end
  end

  describe "#tick" do
    it "reaches the subscribers that respond to it" do
      ticker = Class.new do
        attr_reader :ticks

        def tick = (@ticks = @ticks.to_i + 1)
      end.new
      fanout(subscribers: [queue_desk, ticker]).tick

      expect(ticker.ticks).to eq(1)
      expect(queue_desk.calls).to be_empty
    end
  end

  describe "#turn_ended" do
    it "reaches the subscribers that respond to it" do
      work_queue_desk = RecordingWorkQueueDesk.new(order: order)
      fanout(subscribers: [queue_desk, work_queue_desk]).turn_ended

      expect(order).to eq([[:work_queue_desk, :turn_ended]])
    end
  end

  describe "#notify" do
    it "passes a later event's arguments to the subscribers that respond to it" do
      listener = Class.new do
        attr_reader :seen

        def wait_opened(pane) = (@seen = pane)
      end.new
      fanout(subscribers: [queue_desk, listener]).notify(:wait_opened, "%3")

      expect(listener.seen).to eq("%3")
      expect(queue_desk.calls).to be_empty
    end
  end

  describe Workspace::HookFanout::OwnerFinished do
    let(:report) { RecordingOwnerReport.new(order: order) }
    let(:spawned) { [] }
    let(:finished) { described_class.new(report: report, spawn: ->(&work) { spawned << work }) }

    it "hands the owner report to spawn for a main agent's Stop, not running it on the caller's thread" do
      finished.session_event(event("stop"))

      expect(report.calls).to be_empty
      expect(spawned.size).to eq(1)
      spawned.first.call
      expect(report.calls).to eq([[:turn_ended, "%1"]])
    end

    it "ignores a sub-agent's Stop and the main agent's other events" do
      finished.session_event(event("stop", "agent_id" => "a1"))
      finished.session_event(event("user_prompt"))

      expect(spawned).to be_empty
    end

    it "does not respond to turn_ended, the registry's turn-settled event" do
      expect(finished).not_to respond_to(:turn_ended)
    end

    it "reports from a fan-out's session_event phase" do
      fanout(subscribers: [finished]).session_event(event("stop"))

      expect(spawned.size).to eq(1)
    end
  end
end
