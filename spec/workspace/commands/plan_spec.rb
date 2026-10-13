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
  let(:tmux) { instance_double(Workspace::Tmux, sessions: ["api", "api-worktree-x"], custom_socket_option: nil) }
  let(:snapshot_client) { instance_double(Workspace::AgentSnapshotClient) }
  let(:ask_store) { instance_double(Workspace::AskStore, list: []) }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: nil) }
  let(:plan_config) { instance_double(Workspace::PlanConfig, stall_seconds_for: 300) }
  subject(:command) do
    described_class.new(notes: notes, catalog: catalog, plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config,
      tmux: tmux, snapshot_client: snapshot_client, ask_store_for: ->(_workspace) { ask_store }, task_store: task_store, output: output)
  end

  before do
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

  describe "#status" do
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
      FileUtils.mkdir_p(notes_dirs["api"])
      File.write(plan_path, "theirs\n")
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(plan_path).and_return(false)

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
end
