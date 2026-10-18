require "spec_helper"

RSpec.describe Workspace::PlanState do
  let(:now) { Time.utc(2026, 10, 12, 14, 0, 0) }
  subject(:state) { described_class.new(clock: -> { now }) }

  def plan(*task_lines, frontmatter: nil)
    text = [frontmatter && "---\n#{frontmatter}\n---", "## Tasks", *task_lines].compact.join("\n") + "\n"
    Workspace::PlanFile.parse(text)
  end

  def derive(plan, **facts) = state.derive(plan: plan, **facts)

  describe "#derive" do
    it "is empty for a plan with no tasks, whatever else is true" do
      expect(derive(plan, session_live: false)).to eq("empty")
      expect(derive(plan(frontmatter: "status: done"))).to eq("empty")
    end

    it "is done when nothing is left, or when status says done" do
      expect(derive(plan("- [x] T1 a", "- [-] T2 b -- no"), session_live: false)).to eq("done")
      expect(derive(plan("- [ ] T1 a", frontmatter: "status: done"), session_live: false)).to eq("done")
    end

    it "is paused ahead of everything below it" do
      paused = plan("- [ ] T1 a", frontmatter: "status: paused")

      expect(derive(paused, session_live: false, pane_state: "working", open_asks: 2)).to eq("paused")
    end

    it "is stopped when the workspace has no live session" do
      expect(derive(plan("- [~] T1 a"), session_live: false, pane_state: "working", open_asks: 1)).to eq("stopped")
    end

    it "does not call a workspace stopped when whether it runs is unknown" do
      expect(derive(plan("- [ ] T1 a"), session_live: nil)).to eq("idle")
    end

    it "is waiting when the owner pane waits or a question is open" do
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "waiting")).to eq("waiting")
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "working", open_asks: 1)).to eq("waiting")
    end

    it "is working when the owner pane works" do
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "working")).to eq("working")
    end

    it "is blocked when every task left is blocked" do
      expect(derive(plan("- [x] T1 a", "- [!] T2 b -- why", "- [!] T3 c -- why"), session_live: true, pane_state: "idle")).to eq("blocked")
    end

    it "is blocked rather than stalled, waiting before blocked, and done before paused" do
      blocked = plan("- [!] T1 a -- why")
      since = (now - 999).utc.iso8601

      expect(derive(blocked, session_live: true, pane_state: "idle", pane_since: since, stall_seconds: 300)).to eq("blocked")
      expect(derive(blocked, session_live: true, pane_state: "idle", open_asks: 1)).to eq("waiting")
      expect(derive(plan("- [x] T1 a", frontmatter: "status: paused"))).to eq("done")
    end

    it "is not blocked while other work is left" do
      expect(derive(plan("- [!] T2 b -- why", "- [ ] T3 c"), session_live: true, pane_state: "idle")).to eq("idle")
    end

    it "is working rather than blocked while the owner pane works" do
      expect(derive(plan("- [!] T2 b -- why"), session_live: true, pane_state: "working")).to eq("working")
    end

    it "is stalled when the owner pane has been idle longer than the limit" do
      since = (now - 301).utc.iso8601

      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: since, stall_seconds: 300)).to eq("stalled")
    end

    it "stalls after five minutes when no limit is given" do
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: (now - 301).utc.iso8601)).to eq("stalled")
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: (now - 299).utc.iso8601)).to eq("idle")
    end

    it "is idle when the owner pane has been idle for the limit or less" do
      since = (now - 300).utc.iso8601

      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: since, stall_seconds: 300)).to eq("idle")
    end

    it "is idle when the idle pane's start time is unknown or unreadable" do
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: nil)).to eq("idle")
      expect(derive(plan("- [ ] T1 a"), session_live: true, pane_state: "idle", pane_since: "yesterday")).to eq("idle")
    end

    it "is idle with no facts at all" do
      expect(derive(plan("- [ ] T1 a"))).to eq("idle")
    end
  end

  describe "#row" do
    let(:parsed) do
      Workspace::PlanFile.parse("---\ntitle: Auth\nowner_pane: \"%19\"\n---\n## Tasks\n### Phase 1\n- [x] T1 a\n- [~] T2 b\n",
        signature: "1:2", updated_at: "2026-10-12T14:03:11Z")
    end
    let(:panes) { [{"pane_id" => "%19", "state" => "working", "state_since" => "2026-10-12T13:00:00Z"}] }

    it "reports the plan, the state and the owner pane's state in the order the document lists them" do
      row = state.row(workspace: "api.worktree-x", project: "api", path: "/n/IMPLEMENTATION_PLAN.md", plan: parsed, session_live: true,
        panes: panes, open_asks: 0)

      expect(row.keys).to eq(%w[workspace project path exists title status state owner_pane pane_state updated_at signature counts percent
        current tasks open_asks warnings])
      expect(row).to include("workspace" => "api.worktree-x", "project" => "api", "exists" => true, "title" => "Auth", "status" => "active",
        "state" => "working", "owner_pane" => "%19", "pane_state" => "working", "updated_at" => "2026-10-12T14:03:11Z", "signature" => "1:2",
        "percent" => 50, "open_asks" => 0, "warnings" => [])
      expect(row["current"]).to eq("id" => "T2", "title" => "b", "phase" => "Phase 1")
      expect(row["tasks"].first).to eq("id" => "T1", "title" => "a", "state" => "done", "reason" => nil, "phase" => "Phase 1", "line" => 7,
        "owner" => nil, "owner_state" => nil)
    end

    describe "task owners" do
      let(:owned) do
        Workspace::PlanFile.parse("## Tasks\n- [~] T1 a <!-- owner: %19 -->\n- [~] T2 b <!-- owner: %4 -->\n- [ ] T3 c\n")
      end

      it "gives each task its owner and the owner pane's state from the daemon" do
        row = state.row(workspace: "w", project: "w", path: "/p", plan: owned, session_live: true,
          panes: [{"pane_id" => "%19", "state" => "working"}, {"pane_id" => "%4", "state" => "idle"}])

        expect(row["tasks"].map { |task| task.values_at("id", "state", "owner", "owner_state") }).to eq([
          ["T1", "in_progress", "%19", "working"], ["T2", "in_progress", "%4", "idle"], ["T3", "todo", nil, nil]
        ])
        expect(row["warnings"]).to eq([])
      end

      it "warns task_owner_unknown, with the task's line, for an owner the daemon does not list" do
        row = state.row(workspace: "w", project: "w", path: "/p", plan: owned, session_live: true, panes: [{"pane_id" => "%19", "state" => "idle"}])

        expect(row["warnings"]).to contain_exactly(a_hash_including("code" => "task_owner_unknown", "line" => 3))
        expect(row["tasks"][1]["owner_state"]).to be_nil
      end

      it "does not warn about the gone owner of a done or skipped task, and sorts the warnings by line" do
        plan = Workspace::PlanFile.parse("## Tasks\n- [x] T1 a <!-- owner: %1 -->\n- [-] T2 b -- no <!-- owner: %1 -->\n- [ ] T3 c <!-- owner: %1 -->\n- [ ] no id\n")
        row = state.row(workspace: "w", project: "w", path: "/p", plan: plan, session_live: true, panes: [])

        expect(row["warnings"].map { |w| w.values_at("code", "line") }).to eq([["task_owner_unknown", 4], ["no_id", 5]])
      end

      it "leaves owner_state null and does not warn when the panes are unknown or the session is stopped" do
        [[true, nil], [false, []]].each do |live, panes|
          row = state.row(workspace: "w", project: "w", path: "/p", plan: owned, session_live: live, panes: panes)

          expect(row["tasks"].map { |task| task["owner_state"] }).to eq([nil, nil, nil])
          expect(row["warnings"]).to eq([])
        end
      end

      it "does not let a task owner decide the plan's state" do
        row = state.row(workspace: "w", project: "w", path: "/p", plan: owned, session_live: true, panes: [{"pane_id" => "%19", "state" => "working"}, {"pane_id" => "%4", "state" => "idle"}])

        expect(row).to include("state" => "idle", "owner_pane" => nil, "pane_state" => nil)
      end
    end

    it "warns owner_pane_unknown when the daemon knows panes and none is the owner" do
      row = state.row(workspace: "w", project: "w", path: "/p", plan: parsed, session_live: true,
        panes: [{"pane_id" => "%3", "state" => "idle"}], open_asks: 0)

      expect(row["warnings"]).to contain_exactly(a_hash_including("code" => "owner_pane_unknown", "line" => nil))
      expect(row["pane_state"]).to be_nil
      expect(row["state"]).to eq("idle")
    end

    it "does not warn when the panes could not be read" do
      row = state.row(workspace: "w", project: "w", path: "/p", plan: parsed, session_live: true, panes: nil, open_asks: 0)

      expect(row["warnings"]).to eq([])
    end

    it "does not warn when the session is not running" do
      row = state.row(workspace: "w", project: "w", path: "/p", plan: parsed, session_live: false, panes: [], open_asks: 0)

      expect(row["warnings"]).to eq([])
      expect(row["state"]).to eq("stopped")
    end

    it "keeps the file's own warnings and adds its own after them" do
      broken = Workspace::PlanFile.parse("---\nowner_pane: \"%9\"\n---\n## Tasks\n- [ ] no id here\n")
      row = state.row(workspace: "w", project: "w", path: "/p", plan: broken, session_live: true, panes: [], open_asks: 0)

      expect(row["warnings"].map { |w| w["code"] }).to eq(%w[no_id owner_pane_unknown])
    end

    it "does not change the file's own warnings" do
      state.row(workspace: "w", project: "w", path: "/p", plan: parsed, session_live: true, panes: [], open_asks: 0)

      expect(parsed.warnings).to eq([])
    end

    it "reports a missing plan as a row with exists false and state empty" do
      row = state.row(workspace: "w", project: "w", path: "/n/IMPLEMENTATION_PLAN.md", plan: nil)

      expect(row).to eq("workspace" => "w", "project" => "w", "path" => "/n/IMPLEMENTATION_PLAN.md", "exists" => false, "title" => nil,
        "status" => nil, "state" => "empty", "owner_pane" => nil, "pane_state" => nil, "updated_at" => nil, "signature" => nil,
        "counts" => {"total" => 0, "done" => 0, "in_progress" => 0, "skipped" => 0, "blocked" => 0, "todo" => 0, "left" => 0},
        "percent" => 0, "current" => nil, "tasks" => [], "open_asks" => 0, "warnings" => [])
    end

    it "reads a file on its own as a state from the file alone, with no workspace" do
      row = state.row(workspace: nil, project: nil, path: "/x/plan.md", plan: parsed)

      expect(row).to include("workspace" => nil, "project" => nil, "state" => "idle", "pane_state" => nil)
    end

    it "passes the stall limit to the state" do
      since = (now - 120).utc.iso8601
      pane = [{"pane_id" => "%19", "state" => "idle", "state_since" => since}]
      row = ->(limit) { state.row(workspace: "w", project: "w", path: "/p", plan: parsed, session_live: true, panes: pane, open_asks: 0, stall_seconds: limit) }

      expect(row.call(60)["state"]).to eq("stalled")
      expect(row.call(600)["state"]).to eq("idle")
    end
  end
end
