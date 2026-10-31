require "spec_helper"

RSpec.describe Workspace::GoalState do
  def member_row(plan: nil, spine: nil, running: true, daemon_up: true, questions: [])
    {"plan" => plan && {"state" => plan}, "spine" => spine, "running" => running, "daemon" => {"up" => daemon_up}, "questions" => questions}
  end

  def run(reason: nil, flags: [], state: "running")
    {"id" => "r_1", "current" => {"state" => state, "reason" => reason, "flags" => flags}}
  end

  def goal(member: member_row, run: nil, turn_state: nil, pane: nil, plan_present: true)
    described_class.new(name: "ws", member: member, run: run, turn: turn_state && {"state" => turn_state}, pane: pane, plan_present: plan_present)
  end

  it "is done when every spine stage is completed or skipped, or the plan is done with no run" do
    spine = {"exists" => true, "stages" => 3, "counts" => {"completed" => 2, "skipped" => 1}}

    expect(goal(member: member_row(spine: spine))).to have_attributes(state: "done", waiting_on: "nothing", next_step: nil)
    expect(goal(member: member_row(plan: "done")).state).to eq("done")
    expect(goal(member: member_row(plan: "done"), run: run).state).not_to eq("done")
  end

  describe "delivery" do
    let(:merged) { {"base" => "origin/main", "pushed" => true, "merged" => true, "ahead_of_base" => 0} }
    let(:unmerged) { {"base" => "origin/main", "pushed" => false, "merged" => false, "ahead_of_base" => 4} }
    let(:finished) { run.merge("state" => "completed") }

    def judged(facts, **options)
      described_class.new(name: "ws", member: member_row(plan: "done"), run: options[:run], turn: nil, pane: nil, plan_present: true, delivery: -> { facts })
    end

    it "does not call a completed run with unmerged commits done" do
      result = judged(unmerged, run: finished)

      expect(result).to have_attributes(state: "waiting", waiting_on: "person", not_yet: [{"code" => "not_pushed", "text" => "not pushed"}, {"code" => "not_merged", "text" => "not on main (4 commits ahead)", "ahead_of_base" => 4}])
      expect(result.next_step).to eq("event" => "delivered", "action" => nil)
    end

    it "is done once merged, with nothing left" do
      expect(judged(merged, run: finished)).to have_attributes(state: "done", waiting_on: "nothing", not_yet: [], done_means: [{"code" => "merged_into_base", "text" => "branch merged into main"}])
    end

    it "is not done when git cannot answer" do
      expect(judged(nil)).to have_attributes(state: "waiting", waiting_on: "nothing", next_step: nil, not_yet: [{"code" => "delivery_unknown", "text" => "delivery unknown: git could not be read"}])
    end

    it "is not done with a completed run when git cannot answer" do
      expect(judged(nil, run: finished)).to have_attributes(state: "waiting", delivered: nil, delivery_unknown?: true)
    end

    it "lists nothing missing for a merged branch, even unpushed or with its upstream gone" do
      expect(judged(merged.merge("pushed" => false, "upstream_gone" => true)).not_yet).to eq([])
    end

    it "does not make delivery_unknown? true for a goal that is not finished" do
      result = described_class.new(name: "ws", member: member_row(plan: "working"), run: nil, turn: nil, pane: nil, plan_present: true, delivery: -> {})

      expect(result).to have_attributes(delivery_unknown?: false)
    end

    it "names an upstream that was deleted instead of an unpushed branch" do
      gone = unmerged.merge("upstream_gone" => true)

      expect(judged(gone).not_yet.map { |item| item["code"] }).to eq(%w[upstream_gone not_merged])
    end

    describe "precedence over a finished plan with unmerged delivery" do
      def with(member: member_row(plan: "done"), run: nil, turn_state: nil, pane: nil)
        described_class.new(name: "ws", member: member, run: run, turn: turn_state && {"state" => turn_state}, pane: pane, plan_present: true, delivery: -> { unmerged })
      end

      it "gives a waiting run reason's own event" do
        reason = {"code" => "failed_check"}

        expect(with(run: run(reason: reason).merge("state" => "completed"))).to have_attributes(state: "waiting")
        expect(with(run: run(reason: reason).merge("state" => "completed")).next_step["event"]).to eq("check_passed")
      end

      it "gives a waiting plan's own event" do
        result = with(member: member_row(plan: "waiting"))

        expect(result.next_step["event"]).to eq("prompt_answered")
      end

      it "gives a waiting pane's own event" do
        expect(with(turn_state: "waiting", pane: {"pane_id" => "%5"}).next_step["event"]).to eq("prompt_answered")
      end

      it "reads a working turn as working, not undelivered" do
        expect(with(turn_state: "working")).to have_attributes(state: "working")
      end
    end

    it "does not judge delivery when no source is given" do
      expect(goal(member: member_row(plan: "done"))).to have_attributes(state: "done", not_yet: [])
    end
  end

  it "waits on a person at a gate, with the run's first action" do
    reason = {"code" => "waiting_you", "details" => {"kind" => "gate"}, "actions" => [{"action" => "workflow approve", "args" => ["r_1"], "needs" => []}]}

    result = goal(run: run(reason: reason))

    expect(result).to have_attributes(state: "waiting", waiting_on: "person")
    expect(result.next_step).to include("event" => "gate_approved", "action" => {"action" => "workflow approve", "args" => ["r_1"], "needs" => []})
  end

  it "maps each waiting reason to its event" do
    events = {"failed_check" => "check_passed", "turn_ended_incomplete" => "turn_ended"}

    events.each do |code, event|
      expect(goal(run: run(reason: {"code" => code})).next_step["event"]).to eq(event)
    end
    expect(goal(run: run(reason: {"code" => "waiting_you", "details" => {}})).next_step["event"]).to eq("answered")
  end

  it "is working on the agent when a turn ended incomplete but the turn is working again" do
    reason = {"code" => "turn_ended_incomplete"}

    expect(goal(run: run(reason: reason), turn_state: "working")).to have_attributes(state: "working", waiting_on: "agent")
    expect(goal(run: run(reason: reason), turn_state: "idle")).to have_attributes(state: "waiting", waiting_on: "person")
    expect(goal(run: run(reason: {"code" => "failed_check"}), turn_state: "working").state).to eq("waiting")
  end

  it "reads a hold on background work as working on the agent, but stuck with no daemon or past the timeout" do
    held = run(flags: ["background_work"])

    expect(goal(run: held, turn_state: "idle")).to have_attributes(state: "working", waiting_on: "agent")
    expect(goal(member: member_row(daemon_up: false), run: held)).to have_attributes(state: "stuck")
    expect(goal(run: run(flags: ["background_work", "timed_out"]), turn_state: "idle").state).to eq("stuck")
  end

  it "reads an idle pane as stuck only once the run flags it idle" do
    expect(goal(run: run(flags: []), turn_state: "idle").state).not_to eq("stuck")
    expect(goal(run: run(flags: ["idle"]), turn_state: "idle")).to have_attributes(state: "stuck", waiting_on: "person")
  end

  it "waits on an open ask, then on the pane's prompt" do
    asked = goal(member: member_row(questions: [{"id" => 7}]), turn_state: "waiting")
    prompted = goal(turn_state: "waiting", pane: {"pane_id" => "%5"})

    expect(asked.next_step).to include("event" => "ask_answered")
    expect(asked.next_step["action"]).to include("action" => "ask answer", "args" => ["7", "--name", "ws"])
    expect(prompted.next_step).to include("event" => "prompt_answered", "action" => {"action" => "focus", "args" => ["ws", "--pane", "%5"], "needs" => []})
  end

  it "waits on a lock, naming the resource" do
    reason = {"code" => "waiting_lock", "details" => {"resource" => "devenv", "holder" => {"run_id" => "r_9"}}, "actions" => []}

    expect(goal(run: run(reason: reason))).to have_attributes(state: "waiting_lock", waiting_on: "lock")
  end

  it "is working on the agent when the turn or the plan is working" do
    expect(goal(turn_state: "working")).to have_attributes(state: "working", waiting_on: "agent")
    expect(goal(member: member_row(plan: "working")).next_step).to eq("event" => "turn_ended", "action" => nil)
  end

  it "is stuck for an idle or timed-out run, a gone pane, a stalled plan, or a running run with no daemon" do
    expect(goal(run: run(flags: ["idle"])).state).to eq("stuck")
    expect(goal(run: run(flags: ["timed_out"])).state).to eq("stuck")
    expect(goal(run: run(reason: {"code" => "pane_gone"})).state).to eq("stuck")
    expect(goal(member: member_row(plan: "stalled")).state).to eq("stuck")
    expect(goal(member: member_row(daemon_up: false), run: run).state).to eq("stuck")
    expect(goal(run: run(flags: ["idle"])).next_step).to include("event" => "workflow_resumed")
    expect(goal(member: member_row(plan: "stalled")).next_step).to include("event" => "agent_restarted")
  end

  it "is stopped with no session, and idle with structure and nothing moving" do
    expect(goal(member: member_row(running: false)).next_step).to include("event" => "launched")
    expect(goal(member: member_row(plan: "idle"))).to have_attributes(state: "idle", waiting_on: "person")
  end

  it "picks task_started only for a plan with no run, else stage_started" do
    expect(goal(member: member_row(plan: "idle")).next_step["event"]).to eq("task_started")
    expect(goal(member: member_row(plan: "idle"), plan_present: false).next_step["event"]).to eq("stage_started")
    expect(goal(run: run(state: "pending")).next_step["event"]).to eq("stage_started")
  end

  it "is none with no run, plan or spine" do
    expect(goal).to have_attributes(state: "none", waiting_on: "nothing", next_step: nil)
    expect(goal(member: member_row(plan: "empty")).state).to eq("none")
  end

  it "only ever gives waiting_on and next events from its listed sets" do
    expect(described_class::WAITING_ON).to eq(%w[nothing person agent lock])
    expect(described_class::EVENTS).to include("gate_approved", "lock_released", "task_started")
  end
end
