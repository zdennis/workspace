require "spec_helper"

RSpec.describe Workspace::WorkflowSweepActions do
  let(:store) { instance_double(Workspace::WorkflowRunStore) }
  let(:panes) { instance_double(Workspace::WorkflowPanes, pane_of: "%7", review_pane_of: "%9") }
  let(:status) { instance_double(Workspace::WorkflowStatus, limit_needs: []) }
  let(:stored) { Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "api.worktree-x", "state" => "running", "current" => "plan", "steps" => {"plan" => {"state" => "running"}}) }

  subject(:actions) { described_class.new(store: store, panes: panes, status: status) }

  before { allow(store).to receive(:run).and_return(stored) }

  def row(reason, **rest)
    {"workspace" => "api.worktree-x", "outcome" => "nothing", "reason" => reason, "message" => "m", "run_id" => "wr_1", "step" => "plan", "attempt" => 1, "cause" => nil, "action" => nil}.merge(rest)
  end

  def call(rows, run: nil, name: nil)
    actions.call(rows, run: run, name: name)
  end

  it "is an empty array when nothing needs a person" do
    expect(call([])).to eq([])
    expect(call([row("healthy"), row("backoff"), row("already_recorded")])).to eq([])
  end

  it "resumes a held run" do
    expect(call([row("held")])).to eq([{"action" => "workflow resume", "args" => ["wr_1"], "needs" => [], "why" => "held"}])
  end

  it "unpauses a paused run" do
    expect(call([row("paused")])).to eq([{"action" => "workflow unpause", "args" => ["wr_1"], "needs" => [], "why" => "paused"}])
  end

  it "gives no action for a held or recorded row without a run id" do
    expect(call([row("held", "run_id" => nil), row(nil, "outcome" => "recorded", "run_id" => nil, "cause" => "pane_gone")])).to eq([])
  end

  it "resumes a run whose budget is spent with the needs workflow status gives" do
    need = Workspace::NextAction.need("extra_tokens", "--extra-tokens", "min" => 10, "suggested" => 20)
    allow(status).to receive(:limit_needs).with(stored).and_return([need])

    expect(call([row("budget_spent")])).to eq([{"action" => "workflow resume", "args" => ["wr_1"], "needs" => [need], "why" => "budget_spent"}])
  end

  it "resumes a timed out run with the limit needs, and a blocked retry with a pane need and a cancel" do
    time = Workspace::NextAction.need("extra_time", "--extra-time", "min" => 60, "suggested" => 120)
    allow(status).to receive(:limit_needs).and_return([time])

    expect(call([row("run_timed_out")]).first["needs"]).to eq([time])
    blocked = call([row("retry_blocked")])
    expect(blocked.map { |each| each["action"] }).to eq(["workflow resume", "workflow cancel"])
    expect(blocked.first["needs"]).to eq([{"name" => "pane", "flag" => "--pane"}, time])
  end

  it "launches a stopped workspace by its name" do
    expect(call([row("workspace_stopped", "cause" => "daemon_down")])).to eq([{"action" => "launch", "args" => ["api.worktree-x"], "needs" => [], "why" => "workspace_stopped"}])
  end

  it "gives no launch for a row without a workspace" do
    expect(call([row("workspace_stopped", "workspace" => nil)])).to eq([])
  end

  it "focuses the pane a prompt waits on, and the review pane while reviewing" do
    expect(call([row("prompt")])).to eq([{"action" => "focus", "args" => ["api.worktree-x", "--pane", "%7"], "needs" => [], "why" => "prompt"}])
    reviewing = Workspace::WorkflowRun.from_h("id" => "wr_1", "workspace" => "api.worktree-x", "state" => "running", "current" => "plan", "steps" => {"plan" => {"state" => "reviewing"}})
    allow(store).to receive(:run).and_return(reviewing)

    expect(call([row("prompt")]).first["args"]).to eq(["api.worktree-x", "--pane", "%9"])
  end

  it "resumes or cancels a recorded stall, with its cause as why" do
    expect(call([row(nil, "outcome" => "recorded", "cause" => "pane_gone")])).to eq([
      {"action" => "workflow resume", "args" => ["wr_1"], "needs" => [], "why" => "pane_gone"},
      {"action" => "workflow cancel", "args" => ["wr_1"], "needs" => [], "why" => "pane_gone"}
    ])
  end

  it "suggests the real sweep once after a dry run, saying how many changes it would make" do
    dry = row(nil, "outcome" => "dry_run", "action" => "record")

    expect(call([dry, dry], name: "app")).to eq([{"action" => "workflow sweep", "args" => ["--name", "app"], "needs" => [],
                                                  "why" => "dry run: would make 2 changes; run without --dry-run to apply them"}])
    expect(call([dry], run: "wr_1").first["why"]).to eq("dry run: would make 1 change; run without --dry-run to apply it")
  end

  it "gives none for a refused row, a failed row or a closed orphan review window" do
    orphan = row(nil, "outcome" => "closed", "workspace" => "some-session", "cause" => "orphan_review_window")

    expect(call([row("refused"), row("unreadable_run", "outcome" => "failed", "workspace" => nil, "run_id" => nil), orphan])).to eq([])
  end

  it "gives no action for the row whose run or pane cannot be read, and still the others" do
    allow(store).to receive(:run).with("wr_bad").and_raise(Workspace::Error.new("unreadable"))
    allow(store).to receive(:run).with("wr_2").and_return(stored)

    result = call([row("budget_spent", "run_id" => "wr_bad"), row("prompt", "run_id" => "wr_bad"), row("retry_blocked", "run_id" => "wr_bad"), row("held", "run_id" => "wr_2")])

    expect(result.map { |each| each["args"] }).to eq([["wr_2"]])
    allow(panes).to receive(:pane_of).and_raise(Workspace::Error.new("no pane"))
    expect(call([row("prompt"), row("held")]).map { |each| each["action"] }).to eq(["workflow resume"])
  end
end
