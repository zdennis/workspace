require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::Commands::Goal do
  let(:member_struct) { Struct.new(:workspace) }
  let(:project_struct) { Struct.new(:name, :members) }

  around do |example|
    Dir.mktmpdir("goal-cmd") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:projects) { [project_struct.new("lab-wc", [member_struct.new("lab-wc-lab-1")])] }
  let(:catalog) { instance_double(Workspace::ProjectCatalog, all: projects) }
  let(:tasks) { {} }
  let(:task_store) { instance_double(Workspace::TaskStore, latest_by_workspace: tasks) }
  let(:runs) { [] }
  let(:archived_runs) { [] }
  let(:run_warnings) { [] }
  let(:workflow_status) do
    instance_double(Workspace::WorkflowStatus).tap do |status|
      allow(status).to receive(:runs) do |workspace: nil, all: false|
        all_runs = runs + (all ? archived_runs : [])
        all_runs = all_runs.select { |run| run["workspace"] == workspace } if workspace
        {"runs" => all_runs, "warnings" => run_warnings}
      end
    end
  end
  let(:parsed_ref) { Struct.new(:branch, :key) }
  let(:start_ref) { instance_double(Workspace::StartRef) }
  let(:plan_path) { File.join(@dir, "IMPLEMENTATION_PLAN.md") }
  let(:plan) { instance_double(Workspace::Commands::Plan, path_for: plan_path) }
  let(:daemon_panes) { [] }
  let(:delivery_facts) do
    instance_double(Workspace::DeliveryFacts, read: {"base" => "origin/main", "branch" => "lab-1", "remote" => true, "upstream" => "origin/lab-1",
                                                     "pushed" => true, "ahead_of_upstream" => 0, "merged" => true, "ahead_of_base" => 0})
  end
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient, fetch: {"panes" => daemon_panes}) }
  let(:member) { member_row }
  let(:snapshot_calls) { [] }
  let(:snapshot) do
    instance_double(Workspace::Commands::Snapshot).tap do |double|
      allow(double).to receive(:document) do |names:, **options|
        snapshot_calls << [names, options]
        document([member])
      end
    end
  end

  subject(:command) do
    described_class.new(snapshot: snapshot, catalog: catalog, task_store: task_store, workflow_status: workflow_status,
      start_ref: start_ref, plan: plan, snapshot_client: snapshot_client, delivery: delivery_facts, output: output)
  end

  def pane(id, state, kind: "claude", index: 0, **extra)
    {"pane_id" => id, "index" => index, "kind" => kind, "state" => state, "state_since" => "2026-10-24T14:02:11Z",
     "waiting_message" => nil, "context_pct" => 41, "agents" => []}.merge(extra)
  end

  def member_row(workspace: "lab-wc-lab-1", panes: [pane("%5", "idle")], plan: {"state" => "empty"}, spine: {"exists" => false, "inferred" => {"path" => "plan", "title" => "Plan", "status" => "in_progress", "owner" => nil, "source" => "inferred"}}, running: true, daemon_up: true, task: nil, questions: [], branch: "lab-1")
    {"workspace" => workspace, "path" => File.join(@dir, workspace), "running" => running, "daemon" => {"up" => daemon_up},
     "git" => {"branch" => branch}, "panes" => daemon_up ? panes : nil, "questions" => questions, "plan" => plan, "spine" => spine, "task" => task}
  end

  def document(members, project: "lab-wc")
    {"projects" => [{"name" => project, "members" => members}], "warnings" => []}
  end

  def run_row(id: "r_91c", workspace: "lab-wc-lab-1", step: "plan", state: "waiting", reason: nil, flags: [], pane: "%5", step_state: "waiting")
    {"id" => id, "workflow" => "rpiv", "workspace" => workspace, "state" => state, "created_at" => "2026-10-24T14:00:00Z", "pane" => pane,
     "current" => {"step" => step, "attempt" => 1, "state" => step_state, "reason" => reason, "flags" => flags}}
  end

  def gate_reason
    {"code" => "waiting_you", "details" => {"kind" => "gate"}, "actions" => [{"action" => "workflow approve", "args" => ["r_91c"], "needs" => []}]}
  end

  def write_plan(*lines) = File.write(plan_path, lines.join("\n") + "\n")

  def goal = JSON.parse(output.string)["goal"]

  before do
    allow(start_ref).to receive(:call) { |ref| parsed_ref.new(ref, ref) }
  end

  describe "#show" do
    it "reports a run at a gate as waiting on a person, with the stage inferred" do
      write_plan("# Plan", "## Tasks")
      runs << run_row(reason: gate_reason)

      command.show("lab-wc-lab-1", json: true)

      expect(JSON.parse(output.string)).to include("schema_version" => 1, "ok" => true)
      expect(goal).to include("workspace" => "lab-wc-lab-1", "project" => "lab-wc", "state" => "waiting", "waiting_on" => "person")
      expect(goal["step"]).to include("source" => "workflow", "run" => "r_91c", "step" => "plan")
      expect(goal["step"]["reason"]["details"]).to eq("kind" => "gate")
      expect(goal["next"]["action"]["action"]).to eq("workflow approve")
      expect(goal["stage"]).to include("title" => "Plan", "source" => "inferred")
    end

    context "with a recorded task" do
      let(:member) { member_row(task: {"id" => "t_3f2a", "title" => "Total row", "ref" => "LAB-1", "branch" => "lab-1"}) }

      it "takes the title, ref and task id from it" do
        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("title" => "Total row", "ref" => "LAB-1", "task_id" => "t_3f2a")
      end
    end

    it "resolves the same workspace from a run id, a task id and a ticket key" do
      runs << run_row
      tasks["lab-wc-lab-1"] = {"id" => "t_3f2a", "workspace" => "lab-wc-lab-1", "title" => "Total row", "ref" => "LAB-1", "branch" => "lab-1"}

      %w[lab-wc-lab-1 r_91c t_3f2a LAB-1].each do |ref|
        output.truncate(0)
        output.rewind
        command.show(ref, json: true)
        expect(goal["workspace"]).to eq("lab-wc-lab-1")
      end
    end

    it "shows a finished run's workspace with a warning that the run is archived" do
      archived_runs << run_row(id: "r_old", state: "completed", reason: nil)

      command.show("r_old", json: true)

      expect(goal["workspace"]).to eq("lab-wc-lab-1")
      expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).to include("run_archived")
    end

    context "with a working pane" do
      let(:member) { member_row(panes: [pane("%5", "working")]) }

      it "names the tool and its start" do
        daemon_panes << {"pane_id" => "%5", "current_tool" => "Bash", "current_tool_since" => "2026-10-24T14:03:00Z", "last_event_at" => "2026-10-24T14:03:00Z"}

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "working")
        expect(goal["tool"]).to include("current" => "Bash", "since" => "2026-10-24T14:03:00Z")
      end
    end

    context "with a plan and no run or spine" do
      let(:member) { member_row(panes: [pane("%4", "idle", index: 1), pane("%1", "idle", index: 0)], plan: {"state" => "idle"}) }

      it "takes the step from the plan's current task and the turn from its owner" do
        write_plan("## Tasks", "- [x] T1 One", "- [~] T2 Two <!-- owner: %4 -->", "- [ ] T3 Three")

        command.show("lab-wc-lab-1", json: true)

        expect(goal["step"]).to include("source" => "plan")
        expect(goal["step"]["task"]).to include("id" => "T2", "state" => "in_progress", "owner" => "%4")
        expect(goal["turn"]["pane"]).to eq("%4")
        expect(goal["stage"]).to include("source" => "inferred")
      end
    end

    context "with a spine and no run" do
      let(:member) do
        member_row(panes: [pane("%4", "idle")], spine: {"exists" => true, "current" => "20-plan.md", "title" => "Plan", "status" => "in_progress", "owner" => "%4", "stages" => 3,
                                                        "counts" => {"completed" => 1}})
      end

      it "takes the stage from the spine, has no step, and takes the turn from the stage owner" do
        command.show("lab-wc-lab-1", json: true)

        expect(goal["stage"]).to include("path" => "20-plan.md", "source" => "spine")
        expect(goal["step"]).to be_nil
        expect(goal["turn"]["pane"]).to eq("%4")
        expect(goal["state"]).to eq("idle")
      end
    end

    context "with no structure" do
      it "is none, infers a stage, and shows the main agent pane" do
        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "none", "waiting_on" => "nothing", "next" => nil)
        expect(goal["stage"]).to include("source" => "inferred")
        expect(goal["turn"]["pane"]).to eq("%5")
      end
    end

    context "when the agent daemon is down while a run is running" do
      let(:member) { member_row(daemon_up: false) }

      it "is stuck with no turn and a warning naming the daemon, and writes nothing" do
        runs << run_row(state: "running", step: "implement", step_state: "running")
        write_plan("## Tasks", "- [~] T1 Build")
        before_bytes = File.binread(plan_path)

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "stuck", "turn" => nil)
        expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).to include("no_daemon", "turn_unavailable")
        expect(File.binread(plan_path)).to eq(before_bytes)
      end
    end

    context "when the agent daemon is down and no run is going" do
      let(:member) { member_row(daemon_up: false) }

      it "has a null turn and a turn_unavailable warning, but no no_daemon one" do
        command.show("lab-wc-lab-1", json: true)

        codes = JSON.parse(output.string)["warnings"].map { |w| w["code"] }
        expect(goal["turn"]).to be_nil
        expect(codes).to include("turn_unavailable")
        expect(codes).not_to include("no_daemon")
      end
    end

    context "when the workspace is stopped" do
      let(:member) { member_row(running: false, daemon_up: false) }

      it "has a null turn and no warning, since there is no daemon to ask" do
        command.show("lab-wc-lab-1", json: true)

        expect(goal["turn"]).to be_nil
        expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).not_to include("turn_unavailable")
      end
    end

    it "keeps the rest of the goal when the run files can't be read" do
      run_warnings << "The run file x can't be read"

      command.show("lab-wc-lab-1", json: true)

      expect(goal["workspace"]).to eq("lab-wc-lab-1")
      expect(JSON.parse(output.string)["warnings"]).to include(a_hash_including("code" => "workflow_runs_unavailable"))
    end

    it "is the same goal for a second active run, listing both" do
      runs << run_row(id: "r_2", state: "running", step: "implement", step_state: "running", reason: nil).merge("created_at" => "2026-10-24T15:00:00Z")
      runs << run_row(id: "r_1")

      command.show("lab-wc-lab-1", json: true)

      expect(goal["step"]["run"]).to eq("r_2")
      expect(goal["runs"].map { |r| r["id"] }).to eq(%w[r_2 r_1])
    end

    it "reports a waiting_lock run with the lock as what it waits on" do
      reason = {"code" => "waiting_lock", "details" => {"resource" => "devenv", "holder" => {"run_id" => "r_9"}}, "actions" => []}
      runs << run_row(state: "waiting", reason: reason, step_state: "running")

      command.show("lab-wc-lab-1", json: true)

      expect(goal).to include("state" => "waiting_lock", "waiting_on" => "lock")
      expect(goal["next"]).to include("event" => "lock_released", "resource" => "devenv")
    end

    it "makes no gh call and reads the snapshot once, for the one workspace, without pull requests" do
      command.show("lab-wc-lab-1", json: true)

      expect(snapshot_calls).to eq([[["lab-wc-lab-1"], {inferred: true}]])
    end

    it "reads the snapshot once when it resolves a branch" do
      command.show("lab-1", json: true)

      expect(snapshot_calls.size).to eq(1)
    end

    it "prints exactly the documented keys" do
      write_plan("## Tasks")
      command.show("lab-wc-lab-1", json: true)

      expect(JSON.parse(output.string).keys).to eq(%w[schema_version ok goal warnings])
      expect(goal.keys).to eq(%w[workspace project title ref branch task_id state waiting_on next stage step runs turn done_means not_yet delivery tool])
    end

    it "warns plan_unavailable and keeps the goal when the plan can't be located" do
      allow(plan).to receive(:path_for).and_raise(Workspace::Error.new("no notes dir", code: "x"))

      command.show("lab-wc-lab-1", json: true)

      expect(goal["step"]).to be_nil
      expect(JSON.parse(output.string)["warnings"]).to include(a_hash_including("code" => "plan_unavailable", "workspace" => "lab-wc-lab-1"))
    end

    it "carries the snapshot's own warnings" do
      allow(snapshot).to receive(:document).and_return(document([member]).merge("warnings" => [{"code" => "cursor_unavailable", "message" => "x"}]))

      command.show("lab-wc-lab-1", json: true)

      expect(JSON.parse(output.string)["warnings"]).to include(a_hash_including("code" => "cursor_unavailable"))
    end

    context "with a paused plan whose owner pane is working" do
      let(:member) { member_row(panes: [pane("%5", "working")], plan: {"state" => "paused"}) }

      it "takes the state from the turn and still has a plan step" do
        write_plan("---", "status: paused", "---", "## Tasks", "- [~] T1 One")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "working", "waiting_on" => "agent")
        expect(goal["step"]["task"]).to include("id" => "T1")
      end
    end

    context "with a blocked plan and an idle pane" do
      let(:member) { member_row(plan: {"state" => "blocked"}) }

      it "is idle, waiting on a person" do
        write_plan("## Tasks", "- [!] T1 One")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "idle", "waiting_on" => "person")
      end
    end

    context "when the current stage disagrees with a done goal" do
      let(:blocked_stage) { {"path" => "verify", "title" => "Verify", "status" => "blocked", "owner" => nil, "source" => "inferred"} }
      let(:member) { member_row(plan: {"state" => "done"}, spine: {"exists" => false, "inferred" => blocked_stage}) }

      it "reports both as they are and warns stage_disagrees with the stage" do
        write_plan("## Tasks", "- [x] T1 One")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done")
        expect(goal["stage"]).to include("status" => "blocked")
        expect(JSON.parse(output.string)["warnings"]).to include(
          a_hash_including("code" => "stage_disagrees", "details" => {"stage" => "verify", "status" => "blocked"})
        )
      end

      it "does not warn when the stage is completed" do
        done_stage = blocked_stage.merge("status" => "completed")
        allow(snapshot).to receive(:document).and_return(document([member_row(plan: {"state" => "done"}, spine: {"exists" => false, "inferred" => done_stage})]))
        write_plan("## Tasks", "- [x] T1 One")

        command.show("lab-wc-lab-1", json: true)

        expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).not_to include("stage_disagrees")
      end
    end

    context "with real git repositories" do
      let(:member) { member_row(plan: {"state" => "done"}, daemon_up: false, running: false, branch: "feat").merge("path" => File.join(@dir, "clone")) }
      let(:delivery_facts) { Workspace::DeliveryFacts.new(git: Workspace::Git.new(output: StringIO.new)) }

      def sh(dir, *args)
        out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args)
        raise out unless status.success?
        out
      end

      def commit(dir, name)
        File.write(File.join(dir, name), name)
        sh(dir, "add", name)
        sh(dir, "commit", "-qm", name)
      end

      def clone_with_origin
        origin = File.join(@dir, "origin.git")
        Open3.capture2e("git", "init", "-q", "--bare", "-b", "main", origin)
        Open3.capture2e("git", "clone", "-q", origin, File.join(@dir, "clone"))
        clone = File.join(@dir, "clone")
        sh(clone, "checkout", "-q", "-b", "main")
        commit(clone, "base")
        sh(clone, "push", "-q", "-u", "origin", "main")
        sh(clone, "checkout", "-q", "-b", "feat")
        commit(clone, "work")
        clone
      end

      before { write_plan("## Tasks", "- [x] T1 One") }

      def codes = goal["not_yet"].map { |item| item["code"] }

      it "reads a stale origin as not merged until it is fetched" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")
        sh(File.join(@dir, "origin.git"), "fetch", "-q", clone, "feat:main")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "waiting")
        expect(goal["delivery"]).to include("merged" => false, "base" => "origin/main")

        sh(clone, "fetch", "-q", "origin")
        output.truncate(0)
        output.rewind
        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done")
      end

      it "reads a remote whose default branch was never fetched as not merged, not falling back to local main" do
        clone = clone_with_origin
        sh(clone, "update-ref", "-d", "refs/remotes/origin/main")
        sh(clone, "update-ref", "-d", "refs/remotes/origin/HEAD") if system("git", "-C", clone, "rev-parse", "-q", "--verify", "refs/remotes/origin/HEAD", out: File::NULL)

        command.show("lab-wc-lab-1", json: true)

        expect(goal["delivery"]).to include("merged" => false, "base" => nil, "ahead_of_base" => nil)
        expect(codes).to include("not_merged")
      end

      it "reads a merged branch whose remote copy was deleted as done, with nothing missing" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")
        sh(clone, "push", "-q", "origin", "feat:main")
        sh(clone, "push", "-q", "origin", "--delete", "feat")
        sh(clone, "fetch", "-q", "origin")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done", "not_yet" => [])
        expect(goal["delivery"]).to include("upstream_gone" => true, "merged" => true)
      end

      it "warns delivery_unavailable only for a goal that is otherwise finished" do
        FileUtils.mkdir_p(File.join(@dir, "clone"))
        command.show("lab-wc-lab-1", json: true)
        expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).to include("delivery_unavailable")

        output.truncate(0)
        output.rewind
        allow(snapshot).to receive(:document).and_return(document([member_row(plan: {"state" => "working"}, branch: "feat").merge("path" => File.join(@dir, "clone"))]))
        command.show("lab-wc-lab-1", json: true)

        expect(JSON.parse(output.string)["warnings"].map { |w| w["code"] }).not_to include("delivery_unavailable")
        expect(goal["not_yet"].map { |item| item["code"] }).to eq(%w[delivery_unknown])
      end

      it "reads a master-only repository with no remote against its local master" do
        clone = File.join(@dir, "clone")
        Open3.capture2e("git", "init", "-q", "-b", "master", clone)
        commit(clone, "base")
        sh(clone, "checkout", "-q", "-b", "feat")
        commit(clone, "work")

        command.show("lab-wc-lab-1", json: true)

        expect(goal["delivery"]).to include("base" => "master", "merged" => false, "remote" => false)
      end

      it "says the upstream was deleted instead of not pushed" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")
        sh(clone, "push", "-q", "origin", "--delete", "feat")

        command.show("lab-wc-lab-1", json: true)

        expect(codes).to eq(%w[upstream_gone not_merged])
        expect(goal["delivery"]).to include("upstream_gone" => true, "pushed" => false)
      end

      it "reads a done plan with no commits ahead as done" do
        clone = clone_with_origin
        sh(clone, "checkout", "-q", "main")
        sh(clone, "checkout", "-q", "-B", "feat")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done")
      end

      it "is not done when the work is completed but never pushed" do
        clone_with_origin
        runs << run_row(state: "completed", step_state: "passed")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "waiting", "waiting_on" => "person", "done_means" => [{"code" => "merged_into_base", "text" => "branch merged into main"}])
        expect(goal["next"]).to eq("event" => "delivered", "action" => nil)
        expect(goal["not_yet"]).to eq([{"code" => "not_pushed", "text" => "not pushed"}, {"code" => "not_merged", "text" => "not on main (1 commit ahead)", "ahead_of_base" => 1}])
        expect(goal["delivery"]).to include("pushed" => false, "merged" => false, "ahead_of_base" => 1, "base" => "origin/main", "remote" => true)
      end

      it "is not done when the branch is pushed but not merged" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "waiting")
        expect(codes).to eq(%w[not_merged])
        expect(goal["delivery"]).to include("pushed" => true, "upstream" => "origin/feat", "merged" => false)
      end

      it "is not done when a push is only partly through" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")
        commit(clone, "more")

        command.show("lab-wc-lab-1", json: true)

        expect(codes).to eq(%w[not_pushed not_merged])
        expect(goal["not_yet"].last).to include("ahead_of_base" => 2)
        expect(goal["delivery"]).to include("ahead_of_upstream" => 1)
      end

      it "is done once the commits are on origin's default branch" do
        clone = clone_with_origin
        sh(clone, "push", "-q", "-u", "origin", "feat")
        sh(clone, "push", "-q", "origin", "feat:main")
        sh(clone, "fetch", "-q", "origin")

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done", "waiting_on" => "nothing", "not_yet" => [])
        expect(goal["delivery"]).to include("merged" => true, "pushed" => true)
      end

      it "is done with no remote when the commits are on the local default branch" do
        clone = File.join(@dir, "clone")
        Open3.capture2e("git", "init", "-q", "-b", "main", clone)
        commit(clone, "base")
        sh(clone, "checkout", "-q", "-b", "feat")
        commit(clone, "work")

        command.show("lab-wc-lab-1", json: true)
        expect(goal).to include("state" => "waiting")
        expect(codes).to eq(%w[not_merged])
        expect(goal["delivery"]).to include("remote" => false, "pushed" => nil)

        sh(clone, "checkout", "-q", "main")
        sh(clone, "merge", "-q", "--ff-only", "feat")
        sh(clone, "checkout", "-q", "feat")
        output.truncate(0)
        output.rewind
        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "done", "not_yet" => [])
      end

      it "judges a goal with no run the same way" do
        clone_with_origin

        command.show("lab-wc-lab-1", json: true)

        expect(goal["runs"]).to eq([])
        expect(goal).to include("state" => "waiting")
      end

      it "is not done, and says why, when git cannot be read" do
        FileUtils.mkdir_p(File.join(@dir, "clone"))

        command.show("lab-wc-lab-1", json: true)

        expect(goal).to include("state" => "waiting", "delivery" => nil, "next" => nil, "waiting_on" => "nothing")
        expect(codes).to eq(%w[delivery_unknown])
        expect(JSON.parse(output.string)["warnings"]).to include(a_hash_including("code" => "delivery_unavailable", "workspace" => "lab-wc-lab-1"))
      end

      it "prints done means and not yet in text" do
        clone_with_origin

        command.show("lab-wc-lab-1")

        expect(output.string).to include("Done means: branch merged into main", "Not yet:    not pushed; not on main (1 commit ahead)")
      end
    end

    describe "errors" do
      it "raises unknown_goal with what was tried" do
        expect { command.show("nope", json: true) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("unknown_goal")
          expect(error.details).to eq("ref" => "nope", "tried" => %w[workspace run task ref branch])
        }
        expect(output.string).to eq("")
      end

      it "raises ambiguous_goal for a branch held by two projects' workspaces" do
        two = document([member_row(workspace: "a-main", branch: "main")]).merge("projects" => [
          {"name" => "a", "members" => [member_row(workspace: "a-main", branch: "main")]},
          {"name" => "b", "members" => [member_row(workspace: "b-main", branch: "main")]}
        ])
        allow(snapshot).to receive(:document).and_return(two)

        expect { command.show("main", json: true) }.to raise_error(Workspace::Error) { |error|
          expect(error.code).to eq("ambiguous_goal")
          expect(error.details["matches"]).to eq([
            {"workspace" => "a-main", "project" => "a", "branch" => "main"}, {"workspace" => "b-main", "project" => "b", "branch" => "main"}
          ])
        }
      end

      it "resolves a branch that only a workspace's checkout holds" do
        command.show("lab-1", json: true)

        expect(goal["workspace"]).to eq("lab-wc-lab-1")
      end
    end
  end

  describe "#list" do
    it "gives each row delivered and its not_yet codes" do
      write_plan("## Tasks", "- [x] T1 One")
      allow(delivery_facts).to receive(:read).and_return(nil)

      command.list(all: true, json: true)

      row = JSON.parse(output.string)["goals"].first
      expect(row).to include("delivered" => nil, "not_yet_codes" => ["delivery_unknown"])
    end

    let(:projects) { [project_struct.new("lab-wc", [member_struct.new("lab-wc-lab-1"), member_struct.new("lab-wc-lab-2")])] }
    let(:snapshot) do
      instance_double(Workspace::Commands::Snapshot).tap do |double|
        allow(double).to receive(:document) do |**|
          document([member_row(plan: {"state" => "idle"}), member_row(workspace: "lab-wc-lab-2", panes: [pane("%7", "idle")])])
        end
      end
    end

    before do
      runs << run_row(workspace: "lab-wc-lab-1", reason: gate_reason)
    end

    it "gives a row per goal with structure, without the tool block, and all of them with --all" do
      write_plan("## Tasks")
      command.list(json: true)

      parsed = JSON.parse(output.string)
      expect(parsed["goals"].map { |g| g["workspace"] }).to eq(%w[lab-wc-lab-1])
      expect(parsed["goals"].first).not_to have_key("tool")

      output.truncate(0)
      output.rewind
      command.list(all: true, json: true)
      expect(JSON.parse(output.string)["goals"].map { |g| g["state"] }).to eq(%w[waiting none])
    end

    it "prints one line per goal in text" do
      write_plan("## Tasks")
      command.list

      expect(output.string.lines.size).to eq(1)
      expect(output.string).to match(/\Alab-wc-lab-1  waiting  Plan  rpiv\/plan  idle$/)
    end
  end

  describe "text output of show" do
    it "prints the levels and the next step" do
      write_plan("## Tasks")
      runs << run_row(reason: gate_reason)

      command.show("lab-wc-lab-1")

      expect(output.string).to include("State:  waiting (on person)", "Stage:  Plan (inferred", "run r_91c rpiv/plan", "Next:   gate_approved  ->  workspace workflow approve r_91c")
    end
  end
end
