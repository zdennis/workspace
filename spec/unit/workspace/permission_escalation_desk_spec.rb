require "spec_helper"

RSpec.describe Workspace::PermissionEscalationDesk do
  let(:now) { Time.utc(2026, 11, 21, 12, 0, 0) }
  let(:time) { [now] }
  let(:inbox) { FakeEscalationInbox.new(opened_at: now) }
  let(:config) { FakeEscalationConfig.new(true) }
  let(:monitor) { FakeEscalationMonitor.new }
  let(:log) { StringIO.new }
  let(:desk) do
    described_class.new(inbox_store: inbox, policy_config: config, workspace: "ws", project: nil, monitor: monitor,
      clock: -> { time.first }, logger: Workspace::Logger.new(output: log, enabled: true))
  end

  def request(decision: "ask", **extra)
    {"event" => "permission_request", "pane_id" => "%5", "tool" => "Bash", "input" => "rm -rf build\nsecond line",
     "rule" => "Bash:rm *", "decision" => decision, "session_id" => "s1"}.compact.merge(extra)
  end

  it "opens an item on a request the policy answered ask" do
    desk.session_event(request)

    record, reopen = inbox.upserts.first
    expect(record).to include("type" => "alert", "dedupe_key" => "permission:ws:%5:main", "links" => {"pane" => "%5"},
      "title" => "ws pane %5: Bash needs permission")
    expect(record["body"]).to eq("rm -rf build\nEscalated by rule: Bash:rm *")
    expect(reopen).to be(true)
  end

  it "opens on no decision when configured? is true" do
    desk.session_event(request(:decision => nil, "rule" => nil))

    expect(inbox.upserts.size).to eq(1)
    expect(inbox.upserts.first.first["body"]).to include("No rule decided it.")
  end

  it "opens nothing on no decision when none is configured" do
    config.value = false
    desk.session_event(request(decision: nil))

    expect(inbox.upserts).to be_empty
  end

  context "with pane bindings" do
    let(:binding) { {"kind" => "run", "id" => "r1", "session" => "ws", "pane_slot" => "ws:1.0"} }
    let(:bindings) { double("pane_bindings", binding_for: binding, stale?: false) }
    let(:tmux) { double("tmux", session_name_for_pane: "ws", pane_slot: "ws:1.0", server_pid_for_pane: "1") }
    let(:desk) do
      described_class.new(inbox_store: inbox, policy_config: config, workspace: "ws", project: nil, monitor: monitor,
        pane_bindings: bindings, tmux: tmux, clock: -> { time.first }, logger: Workspace::Logger.new(output: log, enabled: true))
    end

    before { config.value = false }

    it "opens an item for an undecided request on a pane bound to a live run, with no policy configured" do
      desk.session_event(request(decision: nil))

      expect(inbox.upserts.size).to eq(1)
    end

    it "opens nothing for an undecided request on an unbound pane with no policy configured" do
      allow(bindings).to receive(:binding_for).and_return(nil)
      desk.session_event(request(decision: nil))

      expect(inbox.upserts).to be_empty
    end

    it "opens nothing when the binding is another kind or stale" do
      allow(bindings).to receive(:binding_for).and_return(binding.merge("kind" => "review"))
      desk.session_event(request(decision: nil))
      allow(bindings).to receive(:binding_for).and_return(binding)
      allow(bindings).to receive(:stale?).and_return(true)
      desk.session_event(request(decision: nil))

      expect(inbox.upserts).to be_empty
    end

    it "counts a binding that cannot be read as unbound" do
      allow(bindings).to receive(:binding_for).and_raise(Workspace::Error.new("bad"))
      desk.session_event(request(decision: nil))

      expect(inbox.upserts).to be_empty
    end

    it "opens an item for the hang guard's cap (ask) and none for its deny" do
      desk.session_event(request(:decision => "deny", "rule" => "hang_guard"))
      expect(inbox.upserts).to be_empty

      desk.session_event(request(:decision => "ask", "rule" => "hang_guard:cap"))
      expect(inbox.upserts.first.first["body"]).to include("Escalated by rule: hang_guard:cap")
    end
  end

  it "opens nothing on allow or deny" do
    desk.session_event(request(decision: "allow"))
    desk.session_event(request(decision: "deny"))

    expect(inbox.upserts).to be_empty
  end

  it "keeps one key per agent" do
    desk.session_event(request)
    desk.session_event(request("agent_id" => "sub1"))

    expect(inbox.upserts.map { |r, _| r["dedupe_key"] }).to eq(%w[permission:ws:%5:main permission:ws:%5:sub1])
    expect(inbox.upserts.last.first["body"]).to include("Sub-agent sub1.")
  end

  it "never copies the raw input past the first capped line" do
    desk.session_event(request("input" => "curl -H 'Authorization: Bearer abc123' x\n#{"y" * 500}"))

    expect(inbox.upserts.first.first["body"]).not_to include("abc123")
    expect(inbox.upserts.first.first["body"]).not_to include("yyy")
  end

  it "closes the item on a later tool_use, stop or prompt of that agent" do
    %w[tool_use stop user_prompt session_end].each do |name|
      desk.session_event(request)
      desk.session_event({"event" => name, "pane_id" => "%5"})
    end

    expect(inbox.transitions.map(&:first).uniq).to eq(["permission:ws:%5:main"])
    expect(inbox.transitions.size).to eq(4)
    expect(inbox.transitions.first[1..]).to eq(["done", {"kind" => "permission_escalation"}])
  end

  it "does not close on a notification, nor close another agent's item" do
    desk.session_event(request)
    desk.session_event({"event" => "notification", "pane_id" => "%5", "notification_type" => "permission_prompt"})
    desk.session_event({"event" => "tool_use", "pane_id" => "%5", "agent_id" => "sub1"})

    expect(inbox.transitions).to be_empty
  end

  it "opens on a Codex permission_request notification with ask" do
    desk.session_event({"event" => "notification", "notification_type" => "permission_request", "pane_id" => "%7",
                        "tool" => "shell", "input" => "ls", "decision" => "ask"})

    expect(inbox.upserts.first.first["dedupe_key"]).to eq("permission:ws:%7:main")
  end

  it "opens nothing for an idle_prompt or other notification" do
    desk.session_event({"event" => "notification", "notification_type" => "idle_prompt", "pane_id" => "%7"})
    desk.session_event({"event" => "notification", "pane_id" => "%7"})

    expect(inbox.upserts).to be_empty
  end

  it "closes a Codex item on the following tool_use or stop" do
    %w[tool_use stop].each do |name|
      desk.session_event({"event" => "notification", "notification_type" => "permission_request", "pane_id" => "%7", "decision" => "ask"})
      desk.session_event({"event" => name, "pane_id" => "%7"})
    end

    expect(inbox.transitions.size).to eq(2)
  end

  describe "#scan" do
    let(:late) { now + described_class::GRACE }

    before { desk.session_event(request) }

    def idle_row(**extra) = {"pane_id" => "%5", "state" => "idle", "waits" => [], "pending_permissions" => 0}.merge(extra)

    it "closes an item whose pane is quiet, once past the grace" do
      monitor.panes = [idle_row]
      time[0] = now + 5
      desk.scan
      expect(inbox.transitions).to be_empty

      time[0] = late
      desk.scan
      expect(inbox.transitions.map(&:first)).to eq(["permission:ws:%5:main"])
    end

    it "keeps an item open past the grace while a request is pending and no notification came" do
      monitor.panes = [idle_row("pending_permissions" => 1, "state" => "working")]
      time[0] = late + 600
      desk.scan

      expect(inbox.transitions).to be_empty
    end

    it "closes an item on a quiet idle pane though a permission request is still counted pending" do
      monitor.panes = [idle_row("pending_permissions" => 2)]
      time[0] = late
      desk.scan

      expect(inbox.transitions.size).to eq(1)
    end

    it "keeps an item open for a pending request on a working pane" do
      monitor.panes = [idle_row("pending_permissions" => 1, "state" => "working")]
      time[0] = late
      desk.scan

      expect(inbox.transitions).to be_empty
    end

    it "keeps an item open for a wait of the main agent, a sub-agent, one filed under nil or the screen" do
      [[{"agent_id" => nil}], [{"agent_id" => "sub1"}], [{"agent_id" => "screen"}]].each do |waits|
        monitor.panes = [idle_row("waits" => waits)]
        time[0] = late
        desk.scan
      end
      monitor.panes = [idle_row("state" => "waiting")]
      desk.scan

      expect(inbox.transitions).to be_empty
    end

    it "keeps a main agent's item open for a sub-agent's wait filed under nil" do
      desk.session_event(request("agent_id" => "sub1"))
      monitor.panes = [idle_row("waits" => [{"agent_id" => nil}])]
      time[0] = late
      desk.scan

      expect(inbox.transitions).to be_empty
    end

    it "closes an item whose pane is gone" do
      time[0] = late
      desk.scan

      expect(inbox.transitions.size).to eq(1)
    end

    it "does not close the main agent's item on a subagent_stop without an agent_id, only on one with its own" do
      desk.session_event({"event" => "subagent_stop", "pane_id" => "%5"})
      expect(inbox.transitions).to be_empty

      desk.session_event(request("agent_id" => "sub1"))
      desk.session_event({"event" => "subagent_stop", "pane_id" => "%5", "agent_id" => "sub1"})
      expect(inbox.transitions.map(&:first)).to eq(["permission:ws:%5:sub1"])
    end

    context "after a daemon restart" do
      let(:fresh) do
        described_class.new(inbox_store: inbox, policy_config: config, workspace: "ws", project: nil, monitor: monitor,
          clock: -> { time.first })
      end

      it "closes an item an earlier daemon opened once the pane is quiet" do
        monitor.panes = [idle_row]
        time[0] = late
        fresh.scan

        expect(inbox.transitions.size).to eq(1)
      end

      it "keeps it while the dialog is re-seen only as a screen wait" do
        monitor.panes = [idle_row("waits" => [{"agent_id" => "screen"}])]
        time[0] = late
        fresh.scan

        expect(inbox.transitions).to be_empty
      end

      it "closes it on a stop, a prompt or a session event, but not on a tool_use" do
        fresh.session_event({"event" => "tool_use", "pane_id" => "%5"})
        expect(inbox.transitions).to be_empty

        %w[stop user_prompt session_start].each { |name| fresh.session_event({"event" => name, "pane_id" => "%5"}) }
        expect(inbox.transitions.size).to eq(3)
        expect(inbox.transitions.map(&:first).uniq).to eq(["permission:ws:%5:main"])
      end
    end
  end

  it "reads the configuration at most once in the cache window" do
    config.value = true
    2.times { desk.session_event(request(decision: nil)) }
    expect(config.calls).to eq(1)

    time[0] = now + described_class::CONFIGURED_TTL
    desk.session_event(request(decision: nil))
    expect(config.calls).to eq(2)
  end

  it "logs and swallows a failure" do
    config.value = :raise

    expect { desk.session_event(request(decision: nil)) }.not_to raise_error
    expect(log.string).to include("permission escalation")

    allow(inbox).to receive(:upsert).and_raise(Workspace::Error, "locked")
    expect { desk.session_event(request) }.not_to raise_error
  end
end
