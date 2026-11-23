require "spec_helper"

class TickingNudger
  def initialize(ticks) = @ticks = ticks

  def tick(workspace, hook_log:) = @ticks << [workspace, hook_log]
end

RSpec.describe Workspace::WorkflowNudge do
  let(:nudger) { RecordingNudger.new }
  let(:hook_log) { Object.new }
  let(:now) { Time.utc(2026, 11, 11, 12, 0, 0) }
  let(:settled) { [] }

  def nudge(**given)
    described_class.new(workspace: "myapp", nudger: nudger, hook_log: hook_log, turn_settled: -> { settled << :settled },
      clock: -> { now }, **given)
  end

  def event(name, **extra) = {"type" => "session_event", "workspace" => "myapp", "event" => name, "pane_id" => "%1"}.merge(extra)

  describe "#session_event" do
    it "leaves a sub-agent's event alone" do
      nudge.session_event(event("stop", "agent_id" => "a1"))

      expect(nudger.calls).to be_empty
      expect(settled).to be_empty
    end

    it "hands the stop event's transcript path to the nudger" do
      nudge.session_event(event("stop", "transcript_path" => "/t/s.jsonl"))

      expect(nudger.calls.last.last[:transcript_path]).to eq("/t/s.jsonl")
    end

    it "tells the nudger when the turn that ended began, and forgets it at a new session or session end" do
      subject = nudge
      subject.session_event(event("user_prompt"))
      subject.session_event(event("stop", "background_tasks" => ["b1"]))
      subject.session_event(event("session_start"))
      subject.session_event(event("stop"))
      subject.session_event(event("user_prompt"))
      subject.session_event(event("session_end"))
      subject.session_event(event("stop"))

      expect(nudger.calls).to eq([
        [:turn_ended, "myapp", "%1", {turn_started: now, background: ["b1"], transcript_path: nil, hook_log: hook_log}],
        [:turn_ended, "myapp", "%1", {turn_started: nil, background: nil, transcript_path: nil, hook_log: hook_log}],
        [:turn_ended, "myapp", "%1", {turn_started: nil, background: nil, transcript_path: nil, hook_log: hook_log}]
      ])
    end

    it "calls turn_settled when the advance the turn woke has exited" do
      woken = RecordingNudger.new(woken: "wr_1")
      nudge(nudger: woken).session_event(event("stop"))

      expect(settled).to be_empty
      woken.exits.each(&:call)
      expect(settled).to eq([:settled])
    end

    it "calls turn_settled at once when the nudger woke no run" do
      nudge.session_event(event("stop"))

      expect(settled).to eq([:settled])
    end

    it "calls turn_settled at once with no nudger" do
      nudge(nudger: nil).session_event(event("stop"))

      expect(settled).to eq([:settled])
    end

    it "does not call turn_settled for events other than a stop" do
      nudge.session_event(event("user_prompt"))

      expect(settled).to be_empty
    end
  end

  describe "#tick" do
    it "passes the workspace and the hook log to the nudger" do
      ticks = []
      ticking = TickingNudger.new(ticks)

      nudge(nudger: ticking).tick

      expect(ticks).to eq([["myapp", hook_log]])
    end

    it "does nothing with no nudger" do
      expect { nudge(nudger: nil).tick }.not_to raise_error
    end
  end
end
