require "spec_helper"

# The next actions of a sweep row for a fan_out sibling: read on the row's own step and pane, not the cursor's.
RSpec.describe Workspace::WorkflowSweepActions, "for a fan_out sibling" do
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes) }
  let(:status) { instance_double(Workspace::WorkflowStatus, limit_needs: []) }
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
  let(:attempt) { {"n" => 1, "started_at" => "2026-10-04T11:00:00Z", "stalls" => [{"cause" => "pane_gone", "since" => "2026-10-04T11:50:00Z"}]} }
  let(:marks) do
    {"step" => "test", "attempt" => 1, "stalled" => {"pane_gone" => "2026-10-04T11:50:00Z"}, "recovered" => {},
     "infra_retry" => {"cause" => "pane_gone", "n" => 1, "max" => 2, "scheduled_at" => "2026-10-04T11:50:00Z", "due" => "2026-10-04T11:51:00Z"}}
  end
  let(:stored) do
    Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "app", "state" => "running", "current" => "lint",
      "definition" => {"steps" => [{"id" => "lint", "group" => "checks"}, {"id" => "test", "group" => "checks"}]},
      "steps" => {"lint" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T11:00:00Z"}]},
                  "test" => {"state" => "running", "attempts" => [attempt], "sweep" => marks}})
  end

  subject(:actions) { described_class.new(store: store, panes: panes, status: status, clock: -> { now }) }

  before { allow(store).to receive(:run).with("wr_1").and_return(stored) }

  def row(outcome, **rest)
    {"workspace" => "app", "outcome" => outcome, "reason" => nil, "message" => "m", "run_id" => "wr_1", "step" => "test", "attempt" => 1, "cause" => nil, "action" => nil}.merge(rest)
  end

  it "says when the sibling's own restart is due" do
    found = actions.call([row("recorded", "cause" => "pane_gone", "action" => "infra_retry_scheduled")], run: nil, name: nil)

    expect(found).to eq([{"action" => "workflow status", "args" => ["wr_1"], "needs" => [],
                          "why" => "wait: the step restarts on its own (pane closed) at 2026-10-04T11:51:00Z; no action needed"}])
  end

  it "focuses the pane a sibling's own permission_wait reason names" do
    hash = JSON.parse(JSON.generate(stored.to_h)).merge("state" => "waiting")
    hash["steps"]["test"] = hash["steps"]["test"].merge("state" => "failed", "reason" => {"code" => "failed_check", "details" => {"cause" => "permission_wait", "pane" => "%12"}})
    allow(store).to receive(:run).with("wr_1").and_return(Workspace::WorkflowRun.from_h(hash))

    found = actions.call([row("timed_out", "cause" => "permission_wait", "action" => "fail")], run: nil, name: nil)

    expect(found.first).to eq("action" => "focus", "args" => ["app", "--pane", "%12"], "needs" => [], "why" => "permission_wait")
  end

  it "offers no --restart-step for a sibling off the cursor, which it would not restart" do
    found = actions.call([row("recorded", "cause" => "pane_gone", "action" => "record")], run: nil, name: nil)

    expect(found.map { |each| each["args"] }).to eq([["wr_1"], ["wr_1"]])
  end

  it "focuses the sibling's own pane for a prompt row" do
    allow(panes).to receive(:pane_of).with("wr_1", step: "test").and_return("%8")

    found = actions.call([row("nothing", "reason" => "prompt")], run: nil, name: nil)

    expect(found).to eq([{"action" => "focus", "args" => ["app", "--pane", "%8"], "needs" => [], "why" => "prompt"}])
  end

  describe "for a sibling that runs as a sub-agent of the run's own pane" do
    let(:stored) do
      Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "app", "state" => "running", "current" => "lint", "pane" => "%5",
        "definition" => {"steps" => [{"id" => "lint", "group" => "checks", "execution_mode" => "subagents"},
          {"id" => "test", "group" => "checks", "execution_mode" => "subagents"}]},
        "steps" => {"lint" => {"state" => "running", "attempts" => [{"n" => 1}]}, "test" => {"state" => "running", "attempts" => [attempt], "sweep" => marks}})
    end

    it "focuses the run's pane for a prompt row, as the sibling has none of its own" do
      allow(panes).to receive(:pane_of).with("wr_1").and_return("%5")

      found = actions.call([row("nothing", "reason" => "prompt")], run: nil, name: nil)

      expect(found).to eq([{"action" => "focus", "args" => ["app", "--pane", "%5"], "needs" => [], "why" => "prompt"}])
      expect(panes).not_to have_received(:pane_of).with("wr_1", step: "test")
    end
  end
end
