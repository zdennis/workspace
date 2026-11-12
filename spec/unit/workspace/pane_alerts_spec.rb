RSpec.describe Workspace::PaneAlerts do
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:pane) do
    Workspace::PaneEvents.new_pane("%2").merge(kind: "claude", label: "Claude Code", pid: 200, index: 1,
      last_activity_at: now - 120)
  end

  def due(pane, stale: false, idle_alert_after: 60)
    described_class.due(pane, now, session_name: "proj", idle_alert_after: idle_alert_after, stale: stale)
  end

  describe ".due" do
    it "has one waiting alert per wait not yet alerted, keyed by pane id and agent id" do
      pane[:waits].merge!(nil => {since: now - 30, message: "Needs approval"}, "a1" => {since: now - 5, alerted: true})

      alerts = due(pane)
      expect(alerts.size).to eq(1)
      alert = alerts.first
      expect(alert.key).to eq(["%2", nil])
      expect(alert.value).to eq(now - 30)
      expect(alert.env).to include("WORKSPACE_ALERT" => "waiting", "WORKSPACE_ALERT_SECONDS" => "30",
        "WORKSPACE_ALERT_TEXT" => "proj pane 0.1 (Claude Code) is waiting: Needs approval")
      expect(alert.logged).to eq("pane_id" => "%2", "pane_pid" => 200, "kind" => "waiting",
        "agent_id" => nil, "waiting_since" => "2026-09-26T11:59:30.000Z")
    end

    it "has an idle alert past idle_alert_after, once per quiet stretch" do
      alerts = due(pane)
      expect(alerts.size).to eq(1)
      alert = alerts.first
      expect(alert.key).to eq(["%2", described_class::IDLE])
      expect(alert.env).to include("WORKSPACE_ALERT" => "idle", "WORKSPACE_ALERT_TEXT" => "proj pane 0.1 (Claude Code) has been idle for 2m")
      expect(alert.logged).to include("kind" => "idle", "idle_since" => "2026-09-26T11:58:00.000Z")

      pane[:alerted_idle_since] = pane[:last_activity_at]
      expect(due(pane)).to be_empty
    end

    it "has no idle alert before the threshold, without one, or on stale activity" do
      expect(due(pane, idle_alert_after: 121)).to be_empty
      expect(due(pane, idle_alert_after: nil)).to be_empty
      expect(due(pane, stale: true)).to be_empty
    end

    it "has nothing for a pane that runs no coding agent" do
      pane[:kind] = "shell"
      pane[:waits][nil] = {since: now - 30}
      expect(due(pane)).to be_empty
    end
  end

  describe ".mark" do
    it "marks the quiet stretch by its start" do
      described_class.mark(pane, described_class::IDLE, now - 120)
      expect(pane[:alerted_idle_since]).to eq(now - 120)
    end

    it "marks the wait under the key only while it is the wait that began at the value" do
      pane[:waits]["a1"] = {since: now - 30}
      described_class.mark(pane, "a1", now - 10)
      expect(pane[:waits]["a1"][:alerted]).to be_nil

      described_class.mark(pane, "a1", now - 30)
      expect(pane[:waits]["a1"][:alerted]).to be(true)
      expect { described_class.mark(pane, "gone", now) }.not_to change { pane[:waits] }
    end
  end

  describe ".restore_waits" do
    let(:alerts) { {"a1" => {"pane_pid" => 200, "waiting_since" => "2026-09-26T11:59:00.000Z"}} }

    it "takes an open wait up as alerted at the logged start" do
      pane[:waits]["a1"] = {since: now}
      described_class.restore_waits(pane, 200, now - 300, alerts)
      expect(pane[:waits]["a1"]).to eq(since: now - 60, alerted: true)
    end

    it "keeps the logged start for the agent's next wait when none is open" do
      described_class.restore_waits(pane, 200, now - 300, alerts)
      expect(pane[:alerted_waits]).to eq("a1" => now - 60)
    end

    it "ignores an alert for another pane process or from before the stretch" do
      described_class.restore_waits(pane, 201, now - 300, alerts)
      described_class.restore_waits(pane, 200, now - 30, alerts)
      expect(pane[:alerted_waits]).to be_nil
    end
  end

  describe ".logged_time" do
    it "reads the time of an alert for this pane process, else nil" do
      alert = {"pane_pid" => 200, "idle_since" => "2026-09-26T11:58:00.000Z"}
      expect(described_class.logged_time(alert, 200, "idle_since")).to eq(now - 120)
      expect(described_class.logged_time(alert, 201, "idle_since")).to be_nil
      expect(described_class.logged_time(alert.merge("idle_since" => "nope"), 200, "idle_since")).to be_nil
      expect(described_class.logged_time(nil, 200, "idle_since")).to be_nil
    end
  end

  describe ".env" do
    it "words a handoff stall and takes NUL bytes out" do
      pane[:label] = "Cla\0ude"
      env = described_class.env(pane, "handoff_stalled", 90.4, nil, session_name: "proj", followups: 3)
      expect(env).to include("WORKSPACE_ALERT_PANE" => "0.1", "WORKSPACE_ALERT_PANE_ID" => "%2",
        "WORKSPACE_ALERT_KIND" => "claude", "WORKSPACE_ALERT_SECONDS" => "90", "WORKSPACE_ALERT_MESSAGE" => "",
        "WORKSPACE_ALERT_TEXT" => "proj pane 0.1 (Claude) has not handed off after 3 follow-ups")
    end
  end
end
