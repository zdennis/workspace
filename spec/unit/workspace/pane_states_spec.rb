RSpec.describe Workspace::PaneStates do
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:pane) { Workspace::PaneEvents.new_pane("%2").merge(kind: "claude", pid: 200, index: 1, last_activity_at: now - 10) }

  def wait(seconds_ago) = {since: now - seconds_ago}

  describe ".state_of" do
    it "is working before idle_after, idle from it, and waiting with a wait open" do
      expect(described_class.state_of(pane, 29, 30)).to eq("working")
      expect(described_class.state_of(pane, 30, 30)).to eq("idle")
      pane[:waits]["a1"] = wait(5)
      expect(described_class.state_of(pane, 0, 30)).to eq("waiting")
    end
  end

  describe ".reported_state" do
    it "is done for a finished turn, whatever the waits say" do
      pane[:waits]["a1"] = wait(5)
      expect(described_class.reported_state(pane, 0, 30)).to eq("waiting")
      pane[:done] = {since: now - 3}
      expect(described_class.reported_state(pane, 0, 30)).to eq("done")
    end
  end

  describe ".oldest_wait" do
    it "is the wait raised first, or nil with none" do
      expect(described_class.oldest_wait(pane)).to be_nil
      pane[:waits].merge!("a1" => wait(5), nil => wait(9))
      expect(described_class.oldest_wait(pane)).to eq(wait(9))
    end
  end

  describe ".since_for" do
    it "dates each state from its own evidence" do
      pane[:done] = {since: now - 3}
      pane[:waits].merge!("a1" => wait(5), "a2" => wait(7))

      expect(described_class.since_for(pane, "done", now, 30)).to eq(now - 3)
      expect(described_class.since_for(pane, "waiting", now, 30)).to eq(now - 7)
      expect(described_class.since_for(pane, "idle", now, 30)).to eq(now + 20)
      expect(described_class.since_for(pane, "working", now, 30)).to eq(now - 10)
      expect(described_class.since_for(pane.except(:last_activity_at), "working", now, 30)).to eq(now)
    end
  end

  describe ".fresh_since" do
    it "is nil for a shell, an unscanned pane, a pane with a wait and a working pane" do
      expect(described_class.fresh_since(pane.merge(kind: "shell"), now, 5)).to be_nil
      expect(described_class.fresh_since(pane.merge(kind: "unknown"), now, 5)).to be_nil
      expect(described_class.fresh_since(pane, now, 30)).to be_nil
      pane[:waits]["a1"] = wait(5)
      expect(described_class.fresh_since(pane, now, 5)).to be_nil
    end

    it "is the Stop's time when done, else when the output went quiet long enough" do
      expect(described_class.fresh_since(pane, now, 5)).to eq(now - 5)
      pane[:done] = {since: now - 3}
      expect(described_class.fresh_since(pane, now, 30)).to eq(now - 3)
    end

    it "is this monitor's own quiet time for a restored pane" do
      pane.merge!(done: {since: now - 3}, restored_ready: true)
      expect(described_class.fresh_since(pane, now, 30)).to be_nil
      pane[:own_quiet_at] = now - 1
      expect(described_class.fresh_since(pane, now, 30)).to eq(now - 1)
    end
  end

  describe ".main_turn_missing" do
    let(:stopped) { pane.merge(hook_kind: "claude", main_stopped_at: now - 2, open_tools: {}) }

    it "is nil once a hook-mode Claude Code Stop stands alone" do
      expect(described_class.main_turn_missing(stopped)).to be_nil
    end

    it "names the first thing missing, in order" do
      expect(described_class.main_turn_missing(stopped.merge(kind: "codex"))).to eq("not_claude")
      expect(described_class.main_turn_missing(stopped.merge(hook_kind: "codex"))).to eq("no_hooks")
      expect(described_class.main_turn_missing(stopped.except(:main_stopped_at))).to eq("no_stop_seen")
      expect(described_class.main_turn_missing(stopped.merge(main_active_at: now, main_active_event: "user_prompt", turn_failed: {})))
        .to eq("main_prompt_after_stop")
      expect(described_class.main_turn_missing(stopped.merge(turn_failed: {}, waits: {nil => wait(1)}))).to eq("turn_failed")
      expect(described_class.main_turn_missing(stopped.merge(waits: {nil => wait(1)}))).to eq("waiting")
      expect(described_class.main_turn_missing(stopped.merge(open_tools: {"t1" => {tool: "Bash"}}))).to eq("open_tool")
    end
  end

  describe ".state_change" do
    it "logs a new state once, with its since, and keeps the pane's record of it" do
      change = described_class.state_change(pane, now, 30)

      expect(change).to eq("pane_id" => "%2", "pane_pid" => 200, "index" => 1, "kind" => "claude",
        "state" => "working", "since" => (now - 10).utc.iso8601(3))
      expect(pane).to include(logged_state: "working", state_since: now - 10)
      expect(described_class.state_change(pane, now, 30)).to be_nil
    end

    it "carries a done turn's stop reason" do
      pane[:done] = {since: now - 3, stop_reason: "end_turn"}

      expect(described_class.state_change(pane, now, 30)).to include("state" => "done", "stop_reason" => "end_turn")
    end

    it "logs nothing for an unscanned pane, and a shell once as exited" do
      expect(described_class.state_change(pane.merge(kind: "unknown"), now, 30)).to be_nil
      shell = pane.merge(kind: "shell", logged_state: "idle")

      expect(described_class.state_change(shell, now, 30)).to include("state" => "exited", "since" => now.utc.iso8601(3))
      expect(described_class.state_change(shell, now, 30)).to be_nil
    end
  end

  describe ".gone_change" do
    it "logs a pane gone only when it had a state logged and wasn't gone already" do
      expect(described_class.gone_change(pane, "closed", now)).to be_nil
      pane[:logged_state] = "exited"
      expect(described_class.gone_change(pane, "closed", now)).to be_nil
      pane[:logged_state] = "idle"
      expect(described_class.gone_change(pane, "closed", now)).to include("state" => "closed")
      expect(pane[:logged_state]).to eq("closed")
    end
  end
end
