RSpec.describe Workspace::PaneView do
  let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
  let(:providers) { Workspace::AgentProvider.all }
  let(:all_events) { Workspace::AgentProvider::HOOK_EVENT_TYPES }
  let(:agent) { Workspace::PaneEvents.new_pane("%2").merge(kind: "claude", index: 1, last_activity_at: now - 10) }
  let(:shell) { Workspace::PaneEvents.new_pane("%1").merge(kind: "shell", index: 0, last_activity_at: now) }
  let(:reading) { {pct: 55, error: nil, updated_at: "2026-09-27T00:00:00Z"} }

  def row(pane, label: nil, context: nil)
    described_class.row(pane, now, idle_after: 30, providers: providers, label: label, context: context)
  end

  describe ".document" do
    it "orders panes by index, an unindexed one first" do
      panes = [{"index" => 2}, {"index" => nil}, {"index" => 1}]

      doc = described_class.document(workspace: "proj", now: now, features: ["parked_resume"], task: nil, panes: panes)

      expect(doc["panes"].map { |p| p["index"] }).to eq([nil, 1, 2])
    end

    it "names the workspace, when it was taken and what the daemon can do, with no task" do
      doc = described_class.document(workspace: "proj", now: now, features: ["parked_resume"], task: nil, panes: [])

      expect(doc).to eq("workspace" => "proj", "updated_at" => now.iso8601, "features" => ["parked_resume"],
        "task" => nil, "panes" => [])
    end
  end

  describe ".row" do
    it "builds the row in the order sessions prints it" do
      expect(row(agent, context: reading).keys).to eq(%w[pane_id index kind label title cwd state state_since
        activity_state main_turn_over_since transcript_path open_tools idle_seconds waiting_since waiting_seconds
        waiting_message waiting_tool waiting_input waits stop_reason turn_failed session_id display_label agents
        context_pct context_error context_updated_at last_event_at current_tool current_tool_since subagents
        hook_mode hook_events])
    end

    it "reports the oldest wait and each wait by agent" do
      agent[:waits].merge!("a1" => {since: now - 5, tool: "Bash"}, nil => {since: now - 9, message: "needs you"})

      expect(row(agent)).to include("state" => "waiting", "waiting_since" => (now - 9).iso8601, "waiting_seconds" => 9,
        "waiting_message" => "needs you", "waits" => [
          {"agent_id" => "a1", "tool" => "Bash", "input" => nil, "since" => (now - 5).iso8601},
          {"agent_id" => nil, "tool" => nil, "input" => nil, "since" => (now - 9).iso8601}
        ])
    end

    it "keeps the logged state's start while the state is the one logged" do
      agent.merge!(logged_state: "working", state_since: now - 100)

      expect(row(agent)).to include("state" => "working", "state_since" => (now - 100).iso8601, "idle_seconds" => 10)
    end

    it "carries the label given as display_label" do
      expect(row(agent, label: "Fix login")["display_label"]).to eq("Fix login")
    end

    it "stamps the context reading given onto an agent pane" do
      expect(row(agent, context: reading)).to include("context_pct" => 55, "context_error" => nil,
        "context_updated_at" => "2026-09-27T00:00:00Z")
    end

    it "leaves the context fields off without a reading" do
      expect(row(agent)).not_to have_key("context_pct")
    end

    it "never stamps context, tool status or hook mode onto a shell pane" do
      keys = row(shell, context: reading).keys

      expect(keys).not_to include("context_pct", "context_error", "last_event_at", "current_tool",
        "current_tool_since", "subagents", "hook_mode", "hook_events")
    end

    it "reports nulls and no sub-agents for an agent pane no hook has reached" do
      expect(row(agent)).to include("last_event_at" => nil, "current_tool" => nil,
        "current_tool_since" => nil, "subagents" => [])
    end

    it "reports the latest open tool and the running sub-agents" do
      agent[:open_tools] = {"t1" => {tool: "Read", since: now - 4}, "t2" => {tool: "Grep", since: now - 2}}
      agent[:agents] << {name: "x", state: "running", started_at: now - 3} << {name: "y", state: "done"}

      expect(row(agent)).to include("open_tools" => %w[Read Grep], "current_tool" => "Grep",
        "current_tool_since" => (now - 2).iso8601, "subagents" => [{"agent_id" => nil, "description" => "x", "since" => (now - 3).iso8601}])
    end

    it "is scrape for a recognized agent with no hook event, hooks once its kind sent one" do
      expect(row(agent)).to include("hook_mode" => "scrape", "hook_events" => all_events)
      agent[:hook_kind] = "claude"
      expect(row(agent)["hook_mode"]).to eq("hooks")
    end

    it "lists no events for an agent with no hooks" do
      agent[:kind] = "opencode"

      expect(row(agent)).to include("hook_mode" => "scrape", "hook_events" => [])
    end

    it "is none for a pane not identified yet" do
      expect(row(Workspace::PaneEvents.new_pane("%9"))).to include("kind" => "unknown", "hook_mode" => "none", "hook_events" => [])
    end

    it "dates a proven turn's end to the millisecond" do
      agent.merge!(hook_kind: "claude", main_stopped_at: now - 1.5)

      expect(row(agent)["main_turn_over_since"]).to eq("2026-09-26T11:59:58.500Z")
    end
  end

  describe ".task_row" do
    let(:task) { {"id" => "ab12cd34", "title" => "Fix login", "ref" => "PROJ-1", "branch" => "PROJ-1", "workspace" => "proj"} }

    def status(*states)
      rows = states.map { |s| {"kind" => "claude", "state" => s} } + [{"kind" => "shell", "state" => "waiting"}]
      described_class.task_row(task, rows)["status"]
    end

    it "is nil without a task, and the task's identity with one" do
      expect(described_class.task_row(nil, [])).to be_nil
      expect(described_class.task_row(task, [])).to eq("id" => "ab12cd34", "title" => "Fix login", "ref" => "PROJ-1",
        "branch" => "PROJ-1", "status" => "idle")
    end

    it "is idle when no agent works, waits or is done, whatever a shell pane says" do
      expect(status("idle")).to eq("idle")
    end

    it "is working while an agent works" do
      expect(status("idle", "working")).to eq("working")
    end

    it "is done once an agent ended its turn" do
      expect(status("idle", "done")).to eq("done")
    end

    it "is blocked while any agent waits" do
      expect(status("done", "working", "waiting")).to eq("blocked")
    end
  end

  describe ".task_title" do
    it "is the title cleaned and cut to a label's length, nil when not a String" do
      expect(described_class.task_title({"title" => "Fix\n" + "x" * 200})).to eq(("Fix " + "x" * 200)[0, 80])
      expect(described_class.task_title({"title" => nil})).to be_nil
      expect(described_class.task_title(nil)).to be_nil
    end
  end
end
