require "spec_helper"

# The goal read on the step it is given while a fan_out group is under way: a sibling's own `steps` entry, which
# {Workspace::WorkflowStatus} fills for a sibling under way, rather than the run's cursor.
RSpec.describe Workspace::GoalState, "with a fan_out group" do
  let(:member) { {"plan" => nil, "spine" => nil, "running" => true, "daemon" => {"up" => true}, "questions" => []} }

  def run(cursor_reason: nil, sibling_reason: nil)
    {"id" => "r_1", "current" => {"step" => "lint", "state" => "running", "reason" => cursor_reason, "flags" => []},
     "steps" => [{"id" => "lint", "state" => "running", "group" => "checks", "flags" => []},
       {"id" => "test", "state" => "passed", "group" => "checks", "reason" => sibling_reason, "flags" => []},
       {"id" => "report", "state" => "pending"}]}
  end

  def goal(run, step: nil)
    described_class.new(name: "ws", member: member, run: run, turn: {"state" => "working"}, pane: nil, plan_present: true, step: step)
  end

  let(:gate) { {"code" => "waiting_you", "details" => {"kind" => "gate"}, "actions" => [{"action" => "workflow approve"}]} }

  it "reads a sibling waiting at its gate when the cursor's step waits for nobody" do
    expect(goal(run(sibling_reason: gate))).to have_attributes(state: "waiting", waiting_on: "person",
      next_step: {"event" => "gate_approved", "action" => {"action" => "workflow approve"}})
  end

  it "reads the step it is given" do
    expect(goal(run(sibling_reason: gate), step: "lint").state).to eq("working")
    expect(goal(run(sibling_reason: gate), step: "test").state).to eq("waiting")
  end

  it "reads the cursor when no sibling waits, or when the cursor's step waits too" do
    expect(goal(run).state).to eq("working")
    failed = {"code" => "failed_check"}
    expect(goal(run(cursor_reason: failed, sibling_reason: gate)).next_step).to include("event" => "check_passed")
  end
end
