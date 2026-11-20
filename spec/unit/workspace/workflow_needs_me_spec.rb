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

  it "passes the first action on as the builder's hash, key order included" do
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", details: {"code" => "test"}))])
    expect(rows.first["next_action"].to_a).to eq(Workspace::NextAction.build("workflow resume", "wr_1").to_a)
  end

  it "names a failed check's code as the detail" do
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", details: {"code" => "test"}))])
    expect(rows.first).to include("code" => "failed_check", "detail" => "test", "next_action" => resume("wr_1"))
  end

  it "shows only cancel when that is all the reason offers" do
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", actions: [cancel("wr_1")]))])
    expect(rows.first["next_action"]).to eq(cancel("wr_1"))
  end

  it "keeps cancel first for an unrecoverable guard stop, ahead of the accept-guard forms" do
    accept = {"action" => "workflow resume", "args" => ["wr_1", "--accept-guard"], "needs" => [{"name" => "note", "flag" => "--note"}]}
    rows = needs_me.rows([run("wr_1", reason: reason("failed_check", actions: [cancel("wr_1"), accept]))])
    expect(rows.first["next_action"]).to eq(cancel("wr_1"))
  end

  %w[turn_ended_incomplete pane_gone].each do |code|
    it "lists #{code}" do
      expect(needs_me.rows([run("wr_1", reason: reason(code))]).map { |row| row["code"] }).to eq([code])
    end
  end

  it "lists a paused run with unpause as its next command" do
    unpause = {"action" => "workflow unpause", "args" => ["wr_1"], "needs" => []}
    rows = needs_me.rows([run("wr_1", reason: reason("paused", actions: [unpause, cancel("wr_1")]))])

    expect(rows.map { |row| row["code"] }).to eq(["paused"])
    expect(rows.first["next_action"]).to eq(unpause)
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

  describe "a stall with an automatic restart" do
    let(:stalled) { {"code" => "stalled", "cause" => "pane_gone", "since" => "2026-10-04T12:30:00Z", "actions" => [resume("wr_1"), cancel("wr_1")]} }

    def with_retry(state)
      run("wr_1", stuck: stalled, state: "running").tap { |r| r["current"]["infra_retry"] = {"cause" => "pane_gone", "n" => 1, "max" => 2, "due" => nil, "state" => state, "reason" => nil} }
    end

    it "leaves out a run whose restart is scheduled or under way" do
      expect(needs_me.rows([with_retry("scheduled"), with_retry("restarting")])).to eq([])
    end

    it "lists a run whose restarts are spent, and one whose mark ended (no infra_retry shows)" do
      expect(needs_me.rows([with_retry("exhausted")]).map { |row| row["code"] }).to eq(["stalled"])
      expect(needs_me.rows([run("wr_1", stuck: stalled, state: "running").tap { |r| r["current"]["infra_retry"] = nil }]).size).to eq(1)
    end

    it "still lists a paused run, which waits for an unpause" do
      paused = run("wr_1", reason: reason("paused"), state: "waiting").tap { |r| r["current"]["infra_retry"] = {"state" => "scheduled"} }
      expect(needs_me.rows([paused]).map { |row| row["code"] }).to eq(["paused"])
    end
  end

  it "lists a run stalled by a turn that failed on an API error" do
    stalled = {"code" => "stalled", "cause" => "turn_failed", "since" => "2026-10-04T12:30:00Z", "actions" => [resume("wr_1"), cancel("wr_1")]}
    rows = needs_me.rows([run("wr_1", stuck: stalled, state: "running")])

    expect(rows.map { |row| row.values_at("run", "code", "detail") }).to eq([["wr_1", "stalled", "turn_failed"]])
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

  describe "a step being reviewed" do
    def reviewing(id, reason:)
      row = run(id, reason: reason)
      row["current"] = row["current"].merge("step" => "build", "state" => "reviewing")
      row
    end

    def resume_from(id) = {"action" => "workflow resume", "args" => [id, "--from", "build"], "needs" => []}

    %w[review_incomplete review_tampered review_stale review_guard review_rejected].each do |code|
      it "lists a round stopped on #{code}, resume first" do
        actions = [resume("wr_1"), resume_from("wr_1"), cancel("wr_1")]
        rows = needs_me.rows([reviewing("wr_1", reason: reason(code, details: {"step" => "build", "round" => 1, "problem" => "missing"}, actions: actions))])

        expect(rows.map { |row| row.slice("code", "step", "next_action") }).to eq([{"code" => code, "step" => "build", "next_action" => resume("wr_1")}])
      end
    end

    it "lists a review pane waiting on a permission prompt" do
      prompt = reason("waiting_you", details: {"kind" => "prompt", "role" => "reviewer", "pane" => "%9"}, actions: [{"action" => "focus", "args" => ["app", "--pane", "%9"], "needs" => []}])

      expect(needs_me.rows([reviewing("wr_1", reason: prompt)]).map { |row| row["kind"] }).to eq(["prompt"])
    end

    it "leaves out a round that is running, which has no reason" do
      expect(needs_me.rows([reviewing("wr_1", reason: nil)])).to eq([])
    end
  end
  describe "a run with fan_out siblings under way" do
    def sibling(id, reason: nil, flags: [], attempt: 1, state: "failed")
      {"id" => id, "state" => state, "group" => "checks", "group_state" => "failed", "looping" => false, "attempt" => attempt,
       "reason" => reason, "flags" => flags}
    end

    def grouped(cursor_reason:, siblings:)
      current = {"step" => "lint", "attempt" => 1, "state" => "failed", "reason" => cursor_reason, "flags" => []}
      {"id" => "wr_1", "workflow" => "ci", "workspace" => "app", "state" => "waiting", "current" => current,
       "steps" => [{"id" => "build", "state" => "passed"}] + siblings}
    end

    it "lists a waiting sibling that is not the cursor as its own row, beside the cursor's" do
      failed = reason("failed_check", details: {"code" => "test"})
      rows = needs_me.rows([grouped(cursor_reason: failed, siblings: [sibling("lint", reason: failed), sibling("spec", reason: failed, attempt: 2)])])

      expect(rows.map { |row| [row["step"], row["attempt"], row["code"], row["detail"]] }).to eq([["lint", 1, "failed_check", "test"], ["spec", 2, "failed_check", "test"]])
    end

    it "lists the sibling when the cursor sits on a sibling that waits for nothing" do
      rows = needs_me.rows([grouped(cursor_reason: nil, siblings: [sibling("lint", state: "running"), sibling("spec", reason: reason("failed_check"))])])

      expect(rows.map { |row| row["step"] }).to eq(["spec"])
    end

    it "carries the group and its state on a sibling's row, the cursor's included" do
      failed = reason("failed_check")
      rows = needs_me.rows([grouped(cursor_reason: failed, siblings: [sibling("lint", reason: failed), sibling("spec", reason: failed)])])

      expect(rows.map { |row| [row["step"], row["group"], row["group_state"]] }).to eq([%w[lint checks failed], %w[spec checks failed]])
    end

    it "leaves group and group_state off the row of an ordinary step" do
      row = needs_me.rows([run("wr_1", reason: reason("failed_check"))]).first

      expect(row).not_to have_key("group")
      expect(row).not_to have_key("group_state")
    end

    it "leaves out a failed sibling that waits on its group's owed move, and lists one whose group move was blocked" do
      owed = sibling("lint").merge("looping" => true, "group_state" => "draining")
      expect(needs_me.rows([grouped(cursor_reason: nil, siblings: [owed, sibling("spec", state: "running")])])).to eq([])

      failed = reason("failed_check", details: {"code" => "test"})
      blocked = sibling("lint", reason: failed)
      rows = needs_me.rows([grouped(cursor_reason: failed, siblings: [blocked, sibling("spec", reason: failed)])])
      expect(rows.map { |row| [row["step"], row["code"], row["group_state"]] }).to eq([%w[lint failed_check failed], %w[spec failed_check failed]])
    end

    it "leaves out a sibling with no reason, a passed one and a finished run's" do
      siblings = [sibling("lint", state: "running"), {"id" => "spec", "state" => "passed", "group" => "checks"}]
      expect(needs_me.rows([grouped(cursor_reason: nil, siblings: siblings)])).to eq([])
      done = grouped(cursor_reason: nil, siblings: [sibling("spec", reason: reason("failed_check"))]).merge("state" => "failed")
      expect(needs_me.rows([done])).to eq([])
    end
  end
end
