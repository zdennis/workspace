require "spec_helper"

RSpec.describe Workspace::WorkflowNeedsMe do
  let(:now) { Time.utc(2026, 10, 4, 13, 0, 0) }
  subject(:needs_me) { described_class.new(clock: -> { now }) }

  def resume(id) = {"action" => "workflow resume", "args" => [id], "needs" => []}

  def cancel(id) = {"action" => "workflow cancel", "args" => [id], "needs" => []}

  def run(id, reason: nil, stuck: nil, state: "waiting", workspace: "app")
    current = {"step" => "plan", "attempt" => 2, "state" => "running", "reason" => reason, "flags" => []}
    current["stuck"] = stuck if stuck
    {"id" => id, "workflow" => "rpiv", "workspace" => workspace, "state" => state, "current" => current}
  end

  def reason(code, since: "2026-10-04T12:00:00Z", details: {}, actions: nil, id: "wr_1")
    {"code" => code, "since" => since, "details" => details, "actions" => actions || [resume(id), cancel(id)]}
  end

  it "lists a gate with approve as its next command, and the wait in whole seconds" do
    approve = {"action" => "workflow approve", "args" => ["wr_1", "--step", "plan", "--attempt", "2"], "needs" => []}
    rows = needs_me.rows([run("wr_1", reason: reason("waiting_you", details: {"kind" => "gate"}, actions: [approve, cancel("wr_1")]))])

    expect(rows).to eq([{"run" => "wr_1", "workflow" => "rpiv", "workspace" => "app", "step" => "plan", "attempt" => 2, "code" => "waiting_you",
                         "kind" => "gate", "gate_file" => nil, "detail" => nil, "since" => "2026-10-04T12:00:00Z", "waiting_seconds" => 3600,
                         "next_action" => approve, "actions" => [approve, cancel("wr_1")]}])
  end

  it "names a failed check's code as the detail" do
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", details: {"code" => "test"}))])
    expect(rows.first).to include("code" => "failed_check", "detail" => "test", "next_action" => resume("wr_1"))
  end

  it "shows only cancel when that is all the reason offers" do
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", actions: [cancel("wr_1")]))])
    expect(rows.first["next_action"]).to eq(cancel("wr_1"))
  end

  %w[turn_ended_incomplete pane_gone].each do |code|
    it "lists #{code}" do
      expect(needs_me.rows([run("wr_1", reason: reason(code))]).map { |row| row["code"] }).to eq([code])
    end
  end

  %w[turn_ended_background retry_backoff].each do |code|
    it "leaves out #{code}, which clears by itself" do
      expect(needs_me.rows([run("wr_1", reason: reason(code))])).to eq([])
    end
  end

  it "lists a reason code it does not know" do
    expect(needs_me.rows([run("wr_1", reason: reason("something_new"))]).map { |row| row["code"] }).to eq(["something_new"])
  end

  describe "a lock wait" do
    def lock(since) = run("wr_1", reason: reason("waiting_lock", since: since))

    it "is left out up to 30 minutes, and with no since" do
      expect(needs_me.rows([lock("2026-10-04T12:30:00Z")])).to eq([])
      expect(needs_me.rows([lock(nil)])).to eq([])
    end

    it "has no next command when only cancel is offered, and keeps cancel in actions" do
      only_cancel = run("wr_1", reason: reason("waiting_lock", since: "2026-10-04T12:00:00Z", actions: [cancel("wr_1")]))
      rows = needs_me.rows([only_cancel])
      expect(rows.first).to include("next_action" => nil, "actions" => [cancel("wr_1")])
    end

    it "offers the lock reading when the reason has one" do
      lock_status = {"action" => "lock status", "args" => ["test-db", "--name", "app"], "needs" => []}
      rows = needs_me.rows([run("wr_1", reason: reason("waiting_lock", since: "2026-10-04T12:00:00Z", actions: [lock_status, cancel("wr_1")]))])
      expect(rows.first["next_action"]).to eq(lock_status)
    end

    it "is listed past 30 minutes, with the reason's own first action" do
      rows = needs_me.rows([lock("2026-10-04T12:29:59Z")])
      expect(rows.map { |row| [row["code"], row["next_action"]] }).to eq([["waiting_lock", resume("wr_1")]])
    end
  end

  it "lists a retry_backoff whose resume needs another pane" do
    held = {"action" => "workflow resume", "args" => ["wr_1"], "needs" => [{"name" => "pane", "flag" => "--pane"}]}
    expect(needs_me.rows([run("wr_1", reason: reason("retry_backoff", actions: [held, cancel("wr_1")]))]).size).to eq(1)
  end

  it "leaves out a run that is working (no reason, not stuck) and finished runs" do
    runs = [run("wr_1", state: "running"), run("wr_2", state: "completed", reason: reason("failed_check")), run("wr_3", state: "cancelled")]
    expect(needs_me.rows(runs)).to eq([])
  end

  it "lists a stalled or idle run from its stuck block, naming the cause" do
    stalled = {"code" => "stalled", "cause" => "agent_gone", "since" => "2026-10-04T12:30:00Z", "actions" => [resume("wr_1"), cancel("wr_1")]}
    idle = {"code" => "idle", "cause" => nil, "since" => nil, "actions" => [resume("wr_2"), cancel("wr_2")]}
    rows = needs_me.rows([run("wr_1", stuck: stalled, state: "running"), run("wr_2", stuck: idle, state: "running")])

    expect(rows.map { |row| row.values_at("run", "code", "detail", "waiting_seconds") }).to eq([["wr_1", "stalled", "agent_gone", 1800], ["wr_2", "idle", nil, nil]])
  end

  it "sorts the longest wait first and a wait with no start last" do
    rows = needs_me.rows([run("wr_a", reason: reason("pane_gone", since: nil)), run("wr_b", reason: reason("pane_gone", since: "2026-10-04T12:50:00Z")),
      run("wr_c", reason: reason("pane_gone", since: "2026-10-04T11:00:00Z"))])
    expect(rows.map { |row| row["run"] }).to eq(%w[wr_c wr_b wr_a])
  end

  it "reads a since that does not parse, or lies in the future, without failing" do
    rows = needs_me.rows([run("wr_1", reason: reason("pane_gone", since: "soon")), run("wr_2", reason: reason("pane_gone", since: "2026-10-04T14:00:00Z"))])
    expect(rows.map { |row| row["waiting_seconds"] }).to eq([0, nil])
  end

  it "carries a gate's note" do
    note = {"name" => "plan.md", "path" => "/n/plan.md", "sha256" => "ab"}
    rows = needs_me.rows([run("wr_1", reason: reason("waiting_you", details: {"kind" => "gate", "gate_file" => note}))])
    expect(rows.first["gate_file"]).to eq(note)
  end

  it "tolerates a row with no current block" do
    expect(needs_me.rows([{"id" => "wr_1", "state" => "running"}])).to eq([])
  end
end
