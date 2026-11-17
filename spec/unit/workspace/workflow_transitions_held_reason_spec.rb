require "spec_helper"
require "time"

RSpec.describe "Workspace::WorkflowTransitions.held_reason" do
  let(:now) { Time.utc(2026, 1, 1) }

  def run_with(**more)
    {"state" => "waiting", "current" => "build", "reason" => nil,
     "steps" => {"build" => {"state" => "running"}}}.merge(more.transform_keys(&:to_s))
  end

  def held(run)
    Workspace::WorkflowTransitions.held_reason(run)
  end

  it "is nil for a run nothing holds" do
    expect(held(run_with)).to be_nil
  end

  it "names a paused run" do
    expect(held(run_with(paused: {"by" => "me"}))).to eq("paused")
  end

  it "names a retry blocked from its pane" do
    expect(held(run_with(backoff: {"to" => "build", "blocked" => true}))).to eq("retry_blocked")
  end

  it "does not hold a scheduled backoff" do
    expect(held(run_with(backoff: {"to" => "build", "until" => (now + 60).iso8601}))).to be_nil
  end

  it "does not hold a scheduled backoff with the retry_backoff reason the engine writes" do
    reason = {"code" => "retry_backoff", "details" => {"step" => "build"}}
    expect(held(run_with(reason: reason, backoff: {"to" => "build", "until" => (now + 60).iso8601}))).to be_nil
  end

  it "names a blocked backoff even with the retry_backoff reason" do
    reason = {"code" => "retry_backoff"}
    expect(held(run_with(reason: reason, backoff: {"to" => "build", "blocked" => true}))).to eq("retry_blocked")
  end

  it "names a budget hold and a timeout hold" do
    expect(held(run_with(budget_hold: {"step" => "build"}))).to eq("budget_hold")
    expect(held(run_with(timeout_hold: {"step" => "build"}))).to eq("timeout_hold")
  end

  it "names a reviewing step stopped with a reason" do
    run = run_with(reason: {"code" => "review_rejected"}, steps: {"build" => {"state" => "reviewing"}})
    expect(held(run)).to eq("round_held")
  end

  it "names a reason on a step that is not reviewing" do
    expect(held(run_with(reason: {"code" => "check_failed"}))).to eq("reason")
  end

  it "does not hold a waiting_lock reason" do
    expect(held(run_with(reason: {"code" => "waiting_lock"}))).to be_nil
    run = run_with(reason: {"code" => "waiting_lock"}, steps: {"build" => {"state" => "reviewing"}})
    expect(held(run)).to be_nil
  end

  it "names a gate waiting for a person" do
    expect(held(run_with(steps: {"build" => {"state" => "passed", "gate" => {"state" => "waiting"}}}))).to eq("gate_waiting")
  end

  it "names a parked resume" do
    expect(held(run_with(parked: {"expires_at" => (now + 60).iso8601}))).to eq("parked")
  end

  it "answers the first of several holds" do
    run = run_with(paused: {}, budget_hold: {}, reason: {"code" => "x"})
    expect(held(run)).to eq("paused")
  end
end
