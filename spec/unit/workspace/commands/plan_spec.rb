require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Plan do
  around do |example|
    Dir.mktmpdir("plan-cmd") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:now) { Time.utc(2026, 10, 12, 14, 0, 0) }
  let(:notes_dirs) { {"api" => File.join(@dir, "api-notes"), "api.worktree-x" => File.join(@dir, "x-notes")} }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:members) do
    [Workspace::ProjectCatalog::Member.new(workspace: "api", path: "/r/api", kind: "main", configured: true, exists: true),
      Workspace::ProjectCatalog::Member.new(workspace: "api.worktree-x", path: "/r/x", kind: "worktree", configured: true, exists: true),
      Workspace::ProjectCatalog::Member.new(workspace: nil, path: "/r/y", kind: "worktree", configured: false, exists: true),
      Workspace::ProjectCatalog::Member.new(workspace: "api.worktree-gone", path: "/r/g", kind: "worktree", configured: true, exists: false)]
  end
  let(:catalog) { instance_double(Workspace::ProjectCatalog, all: [Workspace::ProjectCatalog::Project.new(name: "api", id: "/r/api/.git", path: "/r/api", vcs: "git", members: members)]) }
  let(:groups) { instance_double(Workspace::ProjectGroups) }
  let(:tmux) { instance_double(Workspace::Tmux, sessions: ["api", "api-worktree-x"], custom_socket_option: nil) }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:ask_store) { instance_double(Workspace::AskStore, list: []) }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: nil) }
  let(:plan_config) { instance_double(Workspace::PlanConfig, stall_seconds_for: 300) }
  let(:dispatch) { instance_double(Workspace::Commands::PlanDispatch) }
  let(:events_log) { [] }
  let(:event_log) do
    instance_double(Workspace::EventLog).tap do |log|
      allow(log).to receive(:record) { |type:, project:, data: {}| events_log << {type: type, project: project, data: data} }
    end
  end
  let(:binder) { instance_double(Workspace::Commands::Binding, owning_run: nil, refuse_owned!: nil) }
  let(:real_binding) { Workspace::Commands::Binding.new(bindings: nil, locator: nil, tmux: nil) }
  let(:run_panes) { {} }
  subject(:command) do
    described_class.new(notes: notes, access: Workspace::PlanAccess.new(notes: notes, tmux: tmux, event_log: event_log), dispatch: dispatch,
      catalog: catalog, groups: groups, plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config,
      snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { ask_store }, task_store: task_store, binder: binder, clock: -> { now }, output: output)
  end

  before do
    allow(binder).to receive(:owning_run) { |pane:| run_panes.dig(pane, "run") }
    allow(binder).to receive(:refuse_owned!) do |pane:, workspace:, action:, **opts|
      found = run_panes[pane]
      next unless found
      refused = real_binding.refusal(found, workspace: workspace, action: action, **opts)
      raise Workspace::Error.new(refused[:message], code: refused[:code], details: refused[:details])
    end
    allow(notes).to receive(:info) do |name:, create: false|
      dir = notes_dirs.fetch(name) { raise Workspace::Error.new("Unknown workspace '#{name}'.", code: "unknown_workspace", details: {"name" => name}) }
      FileUtils.mkdir_p(dir) if create
      {"workspace" => name, "dir" => dir, "source" => "default", "exists" => Dir.exist?(dir)}
    end
    allow(tmux).to receive(:session_name_for) { |name| name.tr(".", "-") }
  end

  def plan_path(name = "api") = File.join(notes_dirs.fetch(name), "IMPLEMENTATION_PLAN.md")

  def write_plan(name, text)
    FileUtils.mkdir_p(notes_dirs.fetch(name))
    File.write(plan_path(name), text)
  end

  def document = JSON.parse(output.string)

  let(:plan_text) do
    <<~MD
      ---
      title: Auth rewrite
      owner_pane: "%19"
      ---
      ## Tasks
      ### Phase 1
      - [x] T1 First
      - [~] T2 Second
      - [ ] T3 Third
    MD
  end

  describe "#status_group" do
    let(:other_members) { [Workspace::ProjectCatalog::Member.new(workspace: "web", path: "/r/web", kind: "main", configured: true, exists: true)] }
    let(:repositories) do
      [Workspace::ProjectGroups::Repository.new(id: "/r/api/.git", path: "/r/api", name: "api", exists: true),
        Workspace::ProjectGroups::Repository.new(id: "/r/web/.git", path: "/r/web", name: "web", exists: true),
        Workspace::ProjectGroups::Repository.new(id: "/r/none/.git", path: "/r/none", name: "none", exists: false)]
    end
    let(:group) { Workspace::ProjectGroups::Group.new(slug: "billing", name: "Billing", path: "/g/billing.yml", repositories: repositories) }

    before do
      notes_dirs["web"] = File.join(@dir, "web-notes")
      allow(catalog).to receive(:all).and_return([
        Workspace::ProjectCatalog::Project.new(name: "api", id: "/r/api/.git", path: "/r/api", vcs: "git", members: members),
        Workspace::ProjectCatalog::Project.new(name: "web", id: "/r/web/.git", path: "/r/web", vcs: "git", members: other_members)
      ])
      allow(groups).to receive(:find).with("billing").and_return(group)
      write_plan("api", "## Tasks\n- [ ] T1 a\n")
      write_plan("web", "## Tasks\n- [x] T1 a\n")
    end

    it "prints today's rows for every workspace of every member repository, with the group and each row's repository" do
      command.status_group(group: "billing", json: true)

      expect(document).to include("schema_version" => 1, "ok" => true, "group" => {"id" => "group:billing", "name" => "Billing"})
      expect(document["plans"].map { |row| [row["workspace"], row["repository"]] }).to eq(
        [["api", "/r/api/.git"], ["api.worktree-x", "/r/api/.git"], ["web", "/r/web/.git"]]
      )
      expect(document["repositories"].map { |r| [r["name"], r["exists"]] }).to eq([["api", true], ["web", true], ["none", false]])
      expect(document["plans"].first).to include("project" => "api", "exists" => true, "counts" => a_hash_including("total" => 1))
    end

    it "prints rows under a heading per repository, with repositories that have no workspaces or no checkout" do
      command.status_group(group: "billing")

      lines = output.string.lines.map(&:chomp)
      expect(lines.first).to eq("Billing (group:billing)")
      expect(lines).to include("api  /r/api", "web  /r/web", "none  /r/none  (checkout missing)", "  no workspaces")
      expect(lines.index("web  /r/web")).to be > lines.index("api  /r/api")
      expect(lines).to include(a_string_starting_with("  web  "))
    end

    it "turns a workspace whose notes directory can't be worked out into a warning row" do
      notes_dirs.delete("api.worktree-x")

      command.status_group(group: "billing", json: true)

      row = document["plans"].find { |r| r["workspace"] == "api.worktree-x" }
      expect(row).to include("path" => nil, "repository" => "/r/api/.git")
      expect(row["warnings"].first).to include("code" => "unknown_workspace")
    end

    it "says how to add a repository to an empty group" do
      allow(groups).to receive(:find).with("billing").and_return(Workspace::ProjectGroups::Group.new(slug: "billing", name: "Billing", path: "/g", repositories: []))

      command.status_group(group: "billing")

      expect(output.string.lines.map(&:chomp)).to eq(["Billing (group:billing)", "  no repositories: add one with 'workspace projects group add GROUP PATH'"])
    end

    it "prints an empty group" do
      allow(groups).to receive(:find).with("billing").and_return(Workspace::ProjectGroups::Group.new(slug: "billing", name: "Billing", path: "/g", repositories: []))

      command.status_group(group: "billing", json: true)

      expect(document).to include("group" => {"id" => "group:billing", "name" => "Billing"}, "plans" => [])
    end

    it "passes the unknown_group error on" do
      allow(groups).to receive(:find).and_raise(Workspace::Error.new("Unknown group 'x'.", code: "unknown_group"))

      expect { command.status_group(group: "x") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_group") }
    end
  end

  describe "#status" do
    context "with run ownership" do
      let(:run_panes) { {"%19" => {"run" => "wr_9", "pane" => "%19", "paused" => false}} }

      before { allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}]) }

      it "gives the owning run in --json and prints a run line in text" do
        write_plan("api", plan_text)

        command.status(names: ["api"], json: true)
        expect(document["plans"].first["run"]).to eq("wr_9")

        output.truncate(0)
        output.rewind
        command.status(names: ["api"])
        expect(output.string).to include("  run wr_9 is going in pane %19\n")
        expect(output.string).not_to include("plan start")
      end

      it "says a paused plan stalls the run's agent and names plan start" do
        write_plan("api", plan_text.sub("---\ntitle", "---\nstatus: paused\ntitle"))

        command.status(names: ["api"])

        expect(output.string).to include("run wr_9 is going in pane %19; the plan is paused, so the run's agent stops at every attempt: `workspace plan start api` sets it back to active")
      end

      it "has the key, null, on a missing plan and a --file row" do
        command.status(names: ["api"], json: true)
        expect(document["plans"].first).to include("exists" => false, "run" => nil)

        path = File.join(@dir, "other.md")
        File.write(path, "## Tasks\n- [ ] T1 a\n")
        output.truncate(0)
        output.rewind
        command.status(file: path, json: true)
        expect(document["plans"].first).to include("run" => nil)
      end

      it "gives run nil and no line when no run owns the pane, or the owner_pane is not a %N id" do
        write_plan("api", plan_text.sub("%19", "0.1"))

        command.status(names: ["api"], json: true)
        expect(document["plans"].first["run"]).to be_nil
        expect(binder).not_to have_received(:owning_run)

        output.truncate(0)
        output.rewind
        write_plan("api", plan_text)
        run_panes.clear
        command.status(names: ["api"])
        expect(output.string).not_to include("run ")
      end
    end

    it "reports a workspace's plan with its state from the session, the owner pane and the open questions" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).with("api", timeout: 1.0)
        .and_return("panes" => [{"pane_id" => "%19", "state" => "working", "state_since" => "2026-10-12T13:00:00Z"}])

      command.status(names: ["api"], json: true)

      expect(document).to include("schema_version" => 1, "ok" => true)
      row = document["plans"].first
      expect(row).to include("workspace" => "api", "project" => "api", "path" => plan_path, "exists" => true, "title" => "Auth rewrite",
        "state" => "working", "pane_state" => "working", "owner_pane" => "%19", "percent" => 33, "open_asks" => 0)
      expect(row["current"]).to eq("id" => "T2", "title" => "Second", "phase" => "Phase 1")
      expect(row["tasks"].size).to eq(3)
    end

    it "asks the daemon for the task owners' states when only tasks have owners" do
      write_plan("api", "## Tasks\n- [~] T1 a <!-- owner: %7 -->\n- [ ] T2 b\n")
      allow(snapshot_client).to receive(:fetch).with("api", timeout: 1.0).and_return("panes" => [{"pane_id" => "%7", "state" => "working"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["tasks"].first).to include("id" => "T1", "owner" => "%7", "owner_state" => "working")
    end

    it "names the parent project of a worktree workspace" do
      write_plan("api.worktree-x", "## Tasks\n- [ ] T1 a\n")

      command.status(names: ["api.worktree-x"], json: true)

      expect(document["plans"].first).to include("workspace" => "api.worktree-x", "project" => "api")
    end

    it "reports a missing plan as a row, not an error" do
      command.status(names: ["api"], json: true)

      expect(tmux).not_to have_received(:sessions)

      expect(document["plans"].first).to include("workspace" => "api", "exists" => false, "state" => "empty", "path" => plan_path)
    end

    it "reads a plan with no tasks without asking the session, the daemon or the questions" do
      write_plan("api", "# Plan\n## Tasks\n")

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("empty")
      expect(tmux).not_to have_received(:sessions)
      expect(ask_store).not_to have_received(:list)
    end

    it "reads the plan as stopped when the workspace's session is not running" do
      write_plan("api", plan_text)
      allow(tmux).to receive(:sessions).and_return([])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first).to include("state" => "stopped", "pane_state" => nil)
    end

    it "does not ask the daemon for a plan that names no owner pane" do
      write_plan("api", "## Tasks\n- [ ] T1 a\n")
      allow(snapshot_client).to receive(:fetch)

      command.status(names: ["api"], json: true)

      expect(snapshot_client).not_to have_received(:fetch)
      expect(document["plans"].first["state"]).to eq("idle")
    end

    it "does not ask the daemon when the session is not running" do
      write_plan("api", plan_text)
      allow(tmux).to receive(:sessions).and_return([])
      allow(snapshot_client).to receive(:fetch)

      command.status(names: ["api"], json: true)

      expect(snapshot_client).not_to have_received(:fetch)
    end

    it "leaves the pane state out when the daemon does not answer" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("down", reason: :no_daemon))

      command.status(names: ["api"], json: true)

      row = document["plans"].first
      expect(row).to include("pane_state" => nil, "state" => "idle")
      expect(row["warnings"]).to eq([])
    end

    it "reads a daemon reply without panes as no panes" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).and_return({})

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["warnings"].map { |w| w["code"] }).to eq(["owner_pane_unknown"])
    end

    it "leaves the pane state out when the daemon's reply is unreadable" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::Error, "Malformed reply")

      command.status(names: ["api"], json: true)

      expect(document["plans"].first).to include("pane_state" => nil)
    end

    it "does not call a workspace stopped when tmux can't be asked" do
      write_plan("api", plan_text)
      allow(tmux).to receive(:sessions).and_raise(Workspace::Error, "tmux broke")
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("working")
    end

    it "does not call a workspace stopped when tmux fails with a system error" do
      write_plan("api", plan_text)
      allow(tmux).to receive(:sessions).and_raise(Errno::ENOENT)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("working")
    end

    it "does not call a workspace stopped when it runs on a custom tmux socket" do
      write_plan("api", plan_text)
      allow(tmux).to receive(:custom_socket_option).with("api").and_return(["-L", "x"])
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "waiting"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("waiting")
    end

    it "counts open questions and reads the plan as waiting" do
      write_plan("api", "## Tasks\n- [ ] T1 a\n")
      allow(ask_store).to receive(:list).with(open_only: true).and_return([{"id" => "a1"}, {"id" => "a2"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first).to include("state" => "waiting", "open_asks" => 2)
    end

    it "reads an unreadable question store as no questions" do
      write_plan("api", "## Tasks\n- [ ] T1 a\n")
      allow(ask_store).to receive(:list).and_raise(Workspace::Error, "Could not access question store")

      command.status(names: ["api"], json: true)

      expect(document["plans"].first).to include("state" => "idle", "open_asks" => 0)
    end

    it "uses the project's stall limit" do
      write_plan("api", plan_text)
      allow(plan_config).to receive(:stall_seconds_for).with("api").and_return(60)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "idle", "state_since" => "2026-10-12T13:58:00Z"}])

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("stalled")
    end

    it "fails for a workspace it does not know" do
      expect { command.status(names: ["nope"], json: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
    end

    describe "--all" do
      it "reports every configured workspace whose checkout exists, plan or not" do
        write_plan("api.worktree-x", "## Tasks\n- [x] T1 a\n")

        command.status(all: true, json: true)

        expect(document["plans"].map { |r| [r["workspace"], r["exists"], r["state"]] }).to eq([["api", false, "empty"], ["api.worktree-x", true, "done"]])
      end

      it "reads a project's configured members whose checkout exists, in member order, an empty plan as its own row" do
        write_plan("api.worktree-x", "## Tasks\n- [x] T1 a\n")

        command.status(project: catalog.all.first, json: true)

        expect(document["plans"].map { |r| [r["workspace"], r["exists"], r["state"]] }).to eq([["api", false, "empty"], ["api.worktree-x", true, "done"]])
      end

      it "prints a text row for each of a project's members" do
        write_plan("api.worktree-x", "## Tasks\n- [x] T1 a\n")

        command.status(project: catalog.all.first)

        expect(output.string.lines.map { |line| line.split.first }).to eq(["api", "api.worktree-x"])
      end

      it "turns a project member whose notes directory can't be worked out into a broken row" do
        allow(notes).to receive(:info).with(name: "api").and_raise(Workspace::Error.new("Can't work out the notes directory", code: "notes_dir_unresolved"))
        write_plan("api.worktree-x", "## Tasks\n- [ ] T1 a\n")

        command.status(project: catalog.all.first, json: true)

        broken, fine = document["plans"]
        expect(broken).to include("workspace" => "api", "path" => nil)
        expect(broken["warnings"].first).to include("code" => "notes_dir_unresolved")
        expect(fine["exists"]).to be true
      end

      it "says so when the project has no workspace to read" do
        empty = Workspace::ProjectCatalog::Project.new(name: "none", id: "x", path: "/r", vcs: "git", members: [members[2], members[3]])

        command.status(project: empty)

        expect(output.string).to eq("No plans in project none.\n")
      end

      it "answers an empty list as JSON when the project has no workspace to read" do
        empty = Workspace::ProjectCatalog::Project.new(name: "none", id: "x", path: "/r", vcs: "git", members: [members[2], members[3]])

        command.status(project: empty, json: true)

        expect(JSON.parse(output.string)).to include("ok" => true, "plans" => [])
      end

      it "asks tmux once" do
        write_plan("api", "## Tasks\n- [ ] T1 a\n")
        write_plan("api.worktree-x", "## Tasks\n- [ ] T1 a\n")

        command.status(all: true, json: true)

        expect(tmux).to have_received(:sessions).once
      end

      it "reports a workspace whose notes directory can't be worked out as a row with a warning, and carries on" do
        allow(notes).to receive(:info).with(name: "api").and_raise(Workspace::Error.new("Can't work out the notes directory\nmore", code: "notes_dir_unresolved"))
        write_plan("api.worktree-x", "## Tasks\n- [ ] T1 a\n")

        command.status(all: true, json: true)

        broken, fine = document["plans"]
        expect(broken).to include("workspace" => "api", "path" => nil, "exists" => false)
        expect(broken["warnings"]).to eq([{"code" => "notes_dir_unresolved", "line" => nil, "message" => "Can't work out the notes directory"}])
        expect(fine["exists"]).to be true
      end
    end

    describe "--file" do
      it "reads any file with no workspace and a state from the file alone" do
        path = File.join(@dir, "other.md")
        File.write(path, plan_text)

        command.status(file: path, json: true)

        expect(document["plans"]).to match([a_hash_including("workspace" => nil, "project" => nil, "path" => path, "exists" => true,
          "state" => "idle", "pane_state" => nil, "owner_pane" => "%19")])
        expect(tmux).not_to have_received(:sessions)
      end

      it "reports a file that is not there as a row with exists false" do
        command.status(file: File.join(@dir, "none.md"), json: true)

        expect(document["plans"].first).to include("workspace" => nil, "exists" => false)
      end

      it "expands a relative path" do
        Dir.chdir(@dir) do
          File.write("rel.md", "## Tasks\n- [ ] T1 a\n")
          command.status(file: "rel.md", json: true)
        end

        expect(document["plans"].first["path"]).to eq(File.join(@dir, "rel.md"))
      end
    end

    describe "as text" do
      it "prints one line per plan with its state, progress and current task" do
        write_plan("api", plan_text)
        allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}])

        command.status(names: ["api"])

        expect(output.string).to eq("api  working  1/3 (33%)  T2 Second\n")
      end

      it "says when there is no plan, and when a plan is finished or empty" do
        write_plan("api.worktree-x", "## Tasks\n- [x] T1 a\n")

        command.status(all: true)

        expect(output.string.lines).to eq(["api  no plan\n", "api.worktree-x  done  1/1 (100%)\n"])
      end

      it "prints the warnings under the plan" do
        write_plan("api", "## Tasks\n- [ ] Words only\n")

        command.status(names: ["api"])

        expect(output.string.lines.last).to match(/\A  line 2: no_id: /)
      end

      it "labels a file with its path" do
        path = File.join(@dir, "other.md")
        File.write(path, "## Tasks\n- [ ] T1 a\n")

        command.status(file: path)

        expect(output.string).to start_with("#{path}  idle  0/1 (0%)  T1 a")
      end

      it "prints a warning for a warning without a line" do
        write_plan("api", "---\nowner_pane: \"%2\"\n---\n## Tasks\n- [ ] T1 a\n")
        allow(snapshot_client).to receive(:fetch).and_return("panes" => [])

        command.status(names: ["api"])

        expect(output.string).to include("  owner_pane_unknown: ")
      end
    end
  end

  describe "next actions" do
    let(:blocked_text) { "## Tasks\n- [!] T1 a -- waiting on keys\n- [!] T2 b\n- [x] T4 d\n" }
    let(:stalled_actions) do
      [{"action" => "plan show", "args" => ["--name", "api"], "needs" => [],
        "why" => "the plan has work left but its agent has been idle past the stall limit"},
        {"action" => "plan start", "args" => ["--name", "api"], "needs" => [],
         "why" => "sets the plan active and re-sends it to the owner pane, launching the workspace if it is stopped"}]
    end

    def stall!
      write_plan("api", plan_text)
      allow(plan_config).to receive(:stall_seconds_for).with("api").and_return(60)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "idle", "state_since" => "2026-10-12T13:58:00Z"}])
    end

    it "is empty at the top level and on each row when nothing is stalled or blocked" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}])

      command.status(names: ["api", "api.worktree-x"], json: true)

      expect(document["next_actions"]).to eq([])
      expect(document["plans"].map { |row| row["next_actions"] }).to eq([[], []])
    end

    it "offers plan show then plan start for a stalled plan" do
      stall!

      command.status(names: ["api"], json: true)

      expect(document["plans"].first["state"]).to eq("stalled")
      expect(document["plans"].first["next_actions"]).to eq(stalled_actions)
      expect(document["next_actions"]).to eq(stalled_actions)
    end

    describe "--summary" do
      it "leaves out each row's tasks in JSON and keeps the rest, next_actions included" do
        stall!

        command.status(names: ["api"], json: true, summary: true)

        row = document["plans"].first
        expect(row).not_to have_key("tasks")
        expect(row).to include("counts", "current", "percent", "state" => "stalled", "warnings" => [], "next_actions" => stalled_actions)
        expect(document["next_actions"]).to eq(stalled_actions)
      end

      it "keeps the tasks without it" do
        stall!

        command.status(names: ["api"], json: true)

        expect(document["plans"].first["tasks"].size).to eq(3)
      end

      it "leaves out the next: line in text and keeps the status line" do
        stall!

        command.status(names: ["api"], summary: true)

        expect(output.string).to include("api  stalled")
        expect(output.string).not_to include("next:")
      end

      it "prints the next: line in text without it" do
        stall!

        command.status(names: ["api"])

        expect(output.string).to include("  next: workspace plan show")
      end

      it "leaves out tasks for a --file row too" do
        path = File.join(@dir, "other.md")
        File.write(path, plan_text)

        command.status(file: path, json: true, summary: true)

        expect(document["plans"].first).not_to have_key("tasks")
        expect(document["plans"].first).to include("exists" => true, "state" => "idle")
      end
    end

    it "offers one set-state to todo per blocked task, then plan show" do
      write_plan("api", blocked_text)

      command.status(names: ["api"], json: true)

      expected = [
        {"action" => "plan task set-state", "args" => ["--name", "api", "--task", "T1", "--state", "todo"], "needs" => [], "why" => "waiting on keys"},
        {"action" => "plan task set-state", "args" => ["--name", "api", "--task", "T2", "--state", "todo"], "needs" => [], "why" => "T2 is blocked"},
        {"action" => "plan show", "args" => ["--name", "api"], "needs" => [], "why" => "read the plan to see what blocks it"}
      ]
      expect(document["plans"].first["state"]).to eq("blocked")
      expect(document["plans"].first["next_actions"]).to eq(expected)
      expect(document["next_actions"]).to eq(expected)
    end

    it "lists every row's actions at the top level in row order" do
      stall!
      write_plan("api.worktree-x", blocked_text)

      command.status(names: ["api", "api.worktree-x"], json: true)

      expect(document["next_actions"]).to eq(document["plans"].flat_map { |row| row["next_actions"] })
      expect(document["next_actions"].first(2)).to eq(stalled_actions)
      expect(document["next_actions"].size).to eq(5)
    end

    it "gives a row for a workspace that cannot be read no actions" do
      allow(notes).to receive(:info).with(name: "api").and_raise(Workspace::Error.new("no notes", code: "unknown_workspace"))

      command.status(all: true, json: true)

      expect(document["plans"].first["next_actions"]).to eq([])
    end

    it "gives a blocked --file plan no actions and no hint line" do
      path = File.join(@dir, "blocked.md")
      File.write(path, blocked_text)

      command.status(file: path, json: true)

      expect(document["plans"].first).to include("state" => "blocked", "next_actions" => [])
      expect(document["next_actions"]).to eq([])

      output.truncate(0)
      output.rewind
      expect { command.status(file: path) }.not_to raise_error
      expect(output.string).not_to include("next:")
    end

    it "builds only states that IdPatterns::TASK_STATES allows" do
      stall!
      write_plan("api.worktree-x", blocked_text)

      command.status(names: ["api", "api.worktree-x"], json: true)

      states = document["next_actions"].filter_map do |action|
        action["args"][action["args"].index("--state") + 1] if action["args"].include?("--state")
      end
      expect(states).not_to be_empty
      expect(states - Workspace::IdPatterns::TASK_STATES).to eq([])
    end

    it "prints the first action under a stalled row" do
      stall!

      command.status(names: ["api"])

      expect(output.string.lines.first(2)).to eq(["api  stalled  1/3 (33%)  T2 Second\n", "  next: workspace plan show --name api\n"])
    end

    it "prints the first action under a blocked row" do
      write_plan("api", "## Tasks\n- [!] T1 a\n")

      command.status(names: ["api"])

      expect(output.string).to include("  next: workspace plan task set-state --name api --task T1 --state todo\n")
    end

    it "prints no hint under a row in another state" do
      write_plan("api", plan_text)
      allow(snapshot_client).to receive(:fetch).and_return("panes" => [{"pane_id" => "%19", "state" => "working"}])

      command.status(names: ["api"])

      expect(output.string).not_to include("next:")
    end
  end

  describe "#path" do
    it "prints the plan's absolute path alone" do
      command.path(name: "api")

      expect(output.string).to eq("#{plan_path}\n")
    end

    it "prints the document with whether the file exists and the notes directory" do
      write_plan("api", "## Tasks\n")

      command.path(name: "api", json: true)

      expect(document).to eq("schema_version" => 1, "ok" => true, "path" => plan_path, "exists" => true, "notes_dir" => notes_dirs["api"])
    end

    it "does not make the directory" do
      command.path(name: "api", json: true)

      expect(document["exists"]).to be false
      expect(Dir.exist?(notes_dirs["api"])).to be false
    end
  end

  describe "#path_for" do
    it "returns the plan's path without printing" do
      expect(command.path_for("api")).to eq(plan_path)
      expect(output.string).to eq("")
    end
  end

  describe "#show" do
    it "fails with a coded error when the plan path can't be read as a file" do
      FileUtils.mkdir_p(plan_path)

      expect { command.show(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("error") }
    end

    it "prints the file as it is" do
      write_plan("api", "no newline at the end")

      command.show(name: "api")

      expect(output.string).to eq("no newline at the end")
    end

    it "fails with no_plan when there is no file" do
      expect { command.show(name: "api") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("no_plan")
        expect(e.details).to eq("name" => "api", "path" => plan_path)
        expect(e.message).to include("workspace plan init")
      }
    end
  end

  describe "#init" do
    it "writes a plan with frontmatter and an empty task list, and makes the notes directory" do
      result = command.init(name: "api", title: "Auth rewrite")

      expect(result).to eq("path" => plan_path, "message" => nil)
      parsed = Workspace::PlanFile.read(plan_path)
      expect(parsed).to have_attributes(title: "Auth rewrite", status: "active", tasks: [], warnings: [])
      expect(parsed.frontmatter["plan"]).to eq("1")
      expect(File.read(plan_path)).to include("# Auth rewrite", "## Tasks", "## Task details")
      expect(output.string).to eq("Created #{plan_path}\n")
    end

    it "prints nothing with print: false" do
      command.init(name: "api", title: "Auth rewrite", print: false)

      expect(output.string).to eq("")
      expect(File).to exist(plan_path)
    end

    it "takes the title from the task store when none is given" do
      allow(task_store).to receive(:active_for).with("api").and_return("title" => "From the task")

      command.init(name: "api")

      expect(Workspace::PlanFile.read(plan_path).title).to eq("From the task")
    end

    it "leaves the title out when there is none, and heads the file Implementation plan" do
      command.init(name: "api")

      expect(Workspace::PlanFile.read(plan_path).title).to be_nil
      expect(File.read(plan_path)).to include("# Implementation plan")
    end

    it "reads a task store it can't open as having no title" do
      allow(task_store).to receive(:active_for).and_raise(Workspace::Error, "Could not access task store")

      command.init(name: "api")

      expect(File.exist?(plan_path)).to be true
    end

    it "writes a title with a colon or quote so it reads back the same" do
      command.init(name: "api", title: %(Auth: "v2"\nrewrite))

      expect(Workspace::PlanFile.read(plan_path).title).to eq(%(Auth: "v2" rewrite))
    end

    it "fails with plan_exists and leaves the file when a plan is there" do
      write_plan("api", "mine\n")

      expect { command.init(name: "api") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("plan_exists")
        expect(e.details).to eq("path" => plan_path)
      }
      expect(File.read(plan_path)).to eq("mine\n")
    end

    it "fails with plan_exists when a plan appears between the check and the write" do
      allow(notes).to receive(:info).with(name: "api", create: true) do
        FileUtils.mkdir_p(notes_dirs["api"])
        File.write(plan_path, "theirs\n")
        {"workspace" => "api", "dir" => notes_dirs["api"], "source" => "default", "exists" => true}
      end

      expect { command.init(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_exists") }

      expect(File.read(plan_path)).to eq("theirs\n")
      expect(Dir.children(notes_dirs["api"])).to eq(["IMPLEMENTATION_PLAN.md"])
    end

    it "replaces the plan with --force" do
      write_plan("api", "mine\n")

      command.init(name: "api", title: "New", force: true)

      expect(Workspace::PlanFile.read(plan_path).title).to eq("New")
      expect(Dir.children(notes_dirs["api"])).to eq(["IMPLEMENTATION_PLAN.md"])
    end

    it "leaves no temporary file behind when a plan already exists" do
      write_plan("api", "mine\n")

      expect { command.init(name: "api") }.to raise_error(Workspace::Error)

      expect(Dir.children(notes_dirs["api"])).to eq(["IMPLEMENTATION_PLAN.md"])
    end

    it "imports a document without frontmatter under new frontmatter" do
      source = File.join(@dir, "old.md")
      File.write(source, "# Old\n\n## Tasks\n- [x] T1 done\n- [ ] T2 next\n")

      result = command.init(name: "api", title: "Imported", from: source)

      expect(result["message"]).to be_nil
      parsed = Workspace::PlanFile.read(plan_path)
      expect(parsed).to have_attributes(title: "Imported", status: "active")
      expect(parsed.tasks.map(&:id)).to eq(%w[T1 T2])
      expect(File.read(plan_path)).to end_with("- [ ] T2 next\n")
    end

    it "imports a document that has its own frontmatter as it is" do
      source = File.join(@dir, "old.md")
      File.write(source, "---\nplan: 1\ntitle: Mine\nstatus: paused\n---\n## Tasks\n- [ ] T1 a\n")

      command.init(name: "api", title: "Ignored", from: source)

      expect(File.read(plan_path)).to eq(File.read(source))
    end

    it "says so when the imported document has no tasks to count" do
      source = File.join(@dir, "old.md")
      File.write(source, "# Notes\njust prose\n")

      result = command.init(name: "api", from: source)

      expect(result["message"]).to include("no tasks")
      expect(output.string).to include("no tasks")
    end

    it "fails when the file to import is not there, before making anything" do
      expect { command.init(name: "api", from: File.join(@dir, "none.md")) }.to raise_error(Workspace::Error, /Can't read/)
      expect(Dir.exist?(notes_dirs["api"])).to be false
    end

    it "fails with notes_dir_unwritable when the plan can't be written, and leaves no temporary file" do
      allow(File).to receive(:link).and_raise(Errno::EACCES)

      expect { command.init(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("notes_dir_unwritable") }
      expect(Dir.children(notes_dirs["api"])).to eq([])
    end
  end
  describe "the verbs" do
    let(:paused_text) { "---\ntitle: T\nstatus: paused\nowner_pane: \"%19\"\n---\n## Tasks\n- [~] T1 a\n- [ ] T2 b\n" }
    let(:active_text) { paused_text.sub("status: paused", "status: active") }

    def written = Workspace::PlanFile.read(plan_path)

    def events = events_log.map { |event| [event[:project], event[:type], event[:data]] }

    describe "#pause" do
      it "sets status: paused, prints it, records plan_changed, and types nothing" do
        write_plan("api", active_text)

        result = command.pause(name: "api")

        expect(result).to eq("outcome" => "paused", "reason" => nil, "message" => nil, "path" => plan_path, "pane" => nil)
        expect(written.status).to eq("paused")
        expect(File.read(plan_path)).to eq(paused_text)
        expect(output.string).to eq("Paused the plan for api.\n")
        expect(events).to eq([["api", "plan_changed", {"workspace" => "api", "status" => "paused"}]])
      end

      it "adds the dispatch object's interrupts to the row only when asked" do
        write_plan("api", active_text)
        plan = Workspace::PlanFile.read(plan_path)
        allow(dispatch).to receive(:interrupt_owners).and_return([[{"pane" => "%19", "outcome" => "sent"}], []])

        expect(command.pause(name: "api")).not_to have_key("interrupts")
        expect(dispatch).not_to have_received(:interrupt_owners)

        write_plan("api", active_text)
        result = command.pause(name: "api", interrupt: true)

        expect(result).to include("interrupts" => [{"pane" => "%19", "outcome" => "sent"}], "warnings" => [])
        expect(dispatch).to have_received(:interrupt_owners).with("api", have_attributes(tasks: plan.tasks))
      end

      context "when a going run owns an owner pane" do
        let(:run_panes) { {"%19" => {"run" => "wr_9", "pane" => "%19", "paused" => false}} }

        it "refuses with pane_bound_to_run naming workflow pause and writes nothing" do
          write_plan("api", active_text)
          before = File.binread(plan_path)

          expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e|
            expect(e.code).to eq("pane_bound_to_run")
            expect(e.message).to include("workspace workflow pause wr_9")
          }
          expect(File.binread(plan_path)).to eq(before)
          expect(output.string).to eq("")
          expect(events_log).to eq([])
        end

        it "refuses when only a task still left names the run-owned pane" do
          text = "---\ntitle: T\nstatus: active\n---\n## Tasks\n- [~] T1 a <!-- owner: %19 -->\n- [ ] T2 b\n"
          write_plan("api", text)

          expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("pane_bound_to_run") }
          expect(File.read(plan_path)).to eq(text)
        end

        it "names workflow status when the run is already paused" do
          run_panes["%19"] = {"run" => "wr_9", "pane" => "%19", "paused" => true}
          write_plan("api", active_text)

          expect { command.pause(name: "api") }.to raise_error(Workspace::Error, /already paused.*workspace workflow status wr_9/)
        end

        it "is unchanged, with no error, when the plan is already paused" do
          write_plan("api", paused_text)

          expect(command.pause(name: "api")["outcome"]).to eq("unchanged")
          expect(binder).not_to have_received(:refuse_owned!)
        end

        it "skips an owner_pane that is not a %N id and pauses" do
          write_plan("api", active_text.sub("owner_pane: \"%19\"", "owner_pane: \"0.1\""))

          expect(command.pause(name: "api")["outcome"]).to eq("paused")
          expect(binder).not_to have_received(:refuse_owned!)
        end
      end

      it "pauses as before when no run owns the owner pane" do
        write_plan("api", active_text)

        expect(command.pause(name: "api")["outcome"]).to eq("paused")
        expect(binder).to have_received(:refuse_owned!).with(pane: "%19", workspace: "api", action: :pause)
      end

      it "is unchanged, and records nothing, when the plan is already paused" do
        write_plan("api", paused_text)
        before = File.stat(plan_path).mtime

        result = command.pause(name: "api")

        expect(result["outcome"]).to eq("unchanged")
        expect(File.stat(plan_path).mtime).to eq(before)
        expect(output.string).to eq("The plan for api is already paused.\n")
        expect(events).to eq([])
      end

      it "adds frontmatter to a plan that has none" do
        write_plan("api", "## Tasks\n- [ ] T1 a\n")

        command.pause(name: "api")

        expect(written.status).to eq("paused")
      end

      it "fails with no_plan when there is no plan, and writes nothing" do
        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("no_plan")
          expect(e.details).to eq("name" => "api", "path" => plan_path)
        }
        expect(File.exist?(plan_path)).to be false
        expect(events).to eq([])
      end

      it "fails with plan_done when the status is done, or nothing is left" do
        write_plan("api", "---\nstatus: done\n---\n## Tasks\n- [ ] T1 a\n")
        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("plan_done")
          expect(e.details).to eq("name" => "api", "path" => plan_path)
        }

        write_plan("api", "## Tasks\n- [x] T1 a\n- [-] T2 b -- no\n")
        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_done") }
        expect(File.read(plan_path)).not_to include("paused")
      end

      it "pauses a plan with no tasks yet" do
        write_plan("api", "---\nstatus: active\n---\n## Tasks\n")

        expect(command.pause(name: "api")["outcome"]).to eq("paused")
      end

      it "fails with notes_dir_unwritable when the file can't be written" do
        write_plan("api", active_text)
        allow(Workspace::PlanFile).to receive(:set_status).and_raise(Errno::EACCES)

        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("notes_dir_unwritable")
          expect(e.details).to eq("path" => notes_dirs["api"])
        }
      end

      it "passes plan_write_conflict on" do
        write_plan("api", active_text)
        allow(Workspace::PlanFile).to receive(:set_status).and_raise(Workspace::Error.new("changed", code: "plan_write_conflict"))

        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("plan_write_conflict") }
      end

      it "fails with no_plan when the plan is deleted between the read and the write" do
        write_plan("api", active_text)
        allow(Workspace::PlanFile).to receive(:set_status).and_raise(Errno::ENOENT)

        expect { command.pause(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
      end
    end

    describe "#delete" do
      it "renames the plan with a timestamp and leaves the session and the notes directory alone" do
        write_plan("api", active_text)
        File.write(File.join(notes_dirs["api"], "other.md"), "x")

        result = command.delete(name: "api", yes: true)

        deleted = "#{plan_path}.deleted-20261012T140000Z"
        expect(result).to eq("outcome" => "deleted", "reason" => nil, "message" => "Renamed to #{deleted}.", "path" => plan_path, "pane" => nil)
        expect(File.exist?(plan_path)).to be false
        expect(File.read(deleted)).to eq(active_text)
        expect(File.exist?(File.join(notes_dirs["api"], "other.md"))).to be true
        expect(output.string).to eq("Deleted the plan for api: renamed to #{deleted}.\n")
        expect(events).to eq([["api", "plan_changed", {"workspace" => "api", "status" => "deleted"}]])
      end

      it "fails with confirmation_required without yes, and changes nothing" do
        write_plan("api", active_text)

        expect { command.delete(name: "api", yes: false) }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("confirmation_required")
          expect(e.message).to include("--yes")
          expect(e.details).to eq("name" => "api", "path" => plan_path)
          expect(e.retry).to eq("flags" => ["--yes"], "destructive" => true)
        }
        expect(File.read(plan_path)).to eq(active_text)
        expect(events).to eq([])
      end

      it "checks the plan exists before asking for confirmation" do
        expect { command.delete(name: "api", yes: false) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
      end

      it "fails with no_plan the second time, so a repeat changes nothing" do
        write_plan("api", active_text)
        command.delete(name: "api", yes: true)

        expect { command.delete(name: "api", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
      end

      it "does not overwrite an earlier deleted plan from the same second" do
        write_plan("api", "first\n")
        command.delete(name: "api", yes: true)
        write_plan("api", "second\n")

        result = command.delete(name: "api", yes: true)

        expect(result["message"]).to eq("Renamed to #{plan_path}.deleted-20261012T140000Z-1.")
        expect(File.read("#{plan_path}.deleted-20261012T140000Z")).to eq("first\n")
        expect(File.read("#{plan_path}.deleted-20261012T140000Z-1")).to eq("second\n")
      end

      it "deletes a plan whose status is done" do
        write_plan("api", "---\nstatus: done\n---\n## Tasks\n- [x] T1 a\n")

        expect(command.delete(name: "api", yes: true)["outcome"]).to eq("deleted")
      end

      it "fails with no_plan when the plan is deleted by someone else before the rename" do
        write_plan("api", active_text)
        allow(File).to receive(:rename).and_raise(Errno::ENOENT)

        expect { command.delete(name: "api", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_plan") }
      end

      it "fails with notes_dir_unwritable when the rename fails" do
        write_plan("api", active_text)
        allow(File).to receive(:rename).and_raise(Errno::EACCES)

        expect { command.delete(name: "api", yes: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("notes_dir_unwritable") }
        expect(File.exist?(plan_path)).to be true
      end
    end
  end

  describe "#init events" do
    it "records plan_changed with the plan's status" do
      command.init(name: "api", title: "T")

      expect(events_log.map { |e| [e[:project], e[:type], e[:data]] }).to eq([["api", "plan_changed", {"workspace" => "api", "status" => "active"}]])
    end

    it "records the status of an imported plan" do
      source = File.join(@dir, "old.md")
      File.write(source, "---\nstatus: paused\n---\n## Tasks\n- [ ] T1 a\n")

      command.init(name: "api", from: source)

      expect(events_log.last[:data]).to eq("workspace" => "api", "status" => "paused")
    end

    it "records nothing when the plan was not written" do
      write_plan("api", "mine\n")

      expect { command.init(name: "api") }.to raise_error(Workspace::Error)

      expect(events_log).to eq([])
    end
  end
end
