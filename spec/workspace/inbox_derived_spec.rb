require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::InboxDerived do
  let(:tmpdir) { Dir.mktmpdir("ws-inbox-derived") }
  let(:now) { Time.utc(2026, 10, 16, 12, 0, 0) }
  let(:error_output) { StringIO.new }

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  let(:ask_store_for) do
    dir = tmpdir
    ->(workspace, sink = StringIO.new) { Workspace::AskStore.new(path: File.join(dir, "asks", workspace, "asks.json"), error_output: sink) }
  end

  def pane(id, state, since: "2026-10-16T11:50:00Z", message: nil)
    {"pane_id" => id, "index" => 1, "kind" => "claude", "title" => "Claude Code", "state" => state, "state_since" => since,
     "waiting_message" => message, "agents" => []}
  end

  # Mirrors AgentSnapshotClient#fetch: a Hash reply, or Unavailable with its reason.
  let(:daemon_replies) do
    {
      "api" => {"workspace" => "api", "panes" => [pane("%1", "working")]},
      "api.worktree-a" => {"workspace" => "api-wt-a", "panes" => [pane("%5", "waiting", message: "Allow Bash?"), pane("%6", "idle")]},
      "api.worktree-b" => {"workspace" => "api-wt-b", "panes" => []},
      "api.worktree-c" => Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon)
    }
  end
  let(:fetch_calls) { Queue.new }
  let(:snapshot_client) do
    table = daemon_replies
    calls = fetch_calls
    Class.new do
      define_method(:fetch) do |name, timeout: nil|
        calls << [name, timeout]
        reply = table.fetch(name)
        raise reply if reply.is_a?(Exception)
        reply
      end
    end.new
  end

  let(:tmux_sessions) { %w[api api-wt-a api-wt-b] }
  let(:tmux) do
    table = tmux_sessions
    Class.new do
      define_method(:sessions) do |strict: false|
        raise table if table.is_a?(Exception)
        table
      end
      define_method(:session_name_for) { |name| name.sub(".worktree-", "-wt-") }
      define_method(:custom_socket_option) { |_name| nil }
    end.new
  end

  let(:plan_paths) { Hash.new { |_, name| File.join(tmpdir, "notes", name, "IMPLEMENTATION_PLAN.md") } }
  let(:plan) do
    table = plan_paths
    Class.new do
      define_method(:path_for) do |name|
        value = table[name]
        raise value if value.is_a?(Exception)
        value
      end
    end.new
  end
  let(:plan_state) { Workspace::PlanState.new(clock: -> { now }) }
  let(:plan_config) { Class.new { define_method(:stall_seconds_for) { |_name| 300 } }.new }

  def write_plan(workspace, text)
    path = plan_paths[workspace]
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  let(:blocked_plan) do
    <<~MD
      ---
      plan: 1
      title: Ship it
      status: active
      ---
      # Ship it

      ## Tasks

      - [x] T1 First
      - [!] T2 Waiting on access
    MD
  end

  # Mirrors WorkflowStatus#runs: {"runs" => [...], "warnings" => [strings]}.
  def workflow_run(id, workspace:, code:, kind:, gate: "waiting", step: "plan", since: "2026-10-16T11:30:00Z")
    {"id" => id, "workflow" => "rpiv", "title" => "Fix login", "workspace" => workspace, "project" => "api", "state" => "waiting",
     "current" => {"step" => step, "attempt" => 1, "state" => "passed",
                   "reason" => {"code" => code, "since" => since, "details" => {"kind" => kind, "step" => step}, "actions" => []},
                   "flags" => []},
     "steps" => [{"id" => "research", "title" => "Research", "state" => "passed", "attempts" => 1, "gate" => nil},
       {"id" => step, "title" => "Plan", "state" => "passed", "attempts" => 1, "gate" => gate}]}
  end
  let(:workflow_reply) do
    {"runs" => [workflow_run("r-gate", workspace: "api.worktree-c", code: "waiting_you", kind: "gate"),
      workflow_run("r-prompt", workspace: "api.worktree-c", code: "waiting_you", kind: "prompt"),
      workflow_run("r-lock", workspace: "api.worktree-c", code: "waiting_lock", kind: nil),
      workflow_run("r-other", workspace: "elsewhere", code: "waiting_you", kind: "gate")],
     "warnings" => []}
  end
  let(:workflow_status) do
    reply = workflow_reply
    Class.new do
      define_method(:runs) do |workspace: nil, all: false|
        raise reply if reply.is_a?(Exception)
        reply
      end
    end.new
  end

  let(:lock_dir) { File.join(tmpdir, "locks", "api-0123") }
  let(:lock_namespace) do
    dir = lock_dir
    Class.new { define_method(:resolve) { |cwd:| {key: "/src/api/.git", display: "api", dir: dir} } }.new
  end

  def holder(**extra)
    {"kind" => "agent", "pid" => 4411, "started" => "x", "pane" => "%12", "worktree" => "api.worktree-a", "task" => nil,
     "acquired_at" => "2026-10-16T10:00:00Z", "idle_since" => nil, "stale" => false}.merge(extra.transform_keys(&:to_s))
  end

  def waiter(stale: false)
    {"waiter_pid" => 5120, "waiter_started" => "y", "agent_pid" => 4502, "pane" => "%13", "worktree" => "api.worktree-b",
     "task" => nil, "enqueued_at" => "2026-10-16T10:05:00Z", "stale" => stale}
  end

  # Mirrors LockStore#status: name => {"holder", "queue"}, each record annotated with `stale`.
  let(:lock_entries) do
    {
      "edit" => {"holder" => holder(stale: true), "queue" => [waiter]},
      "nobody-waits" => {"holder" => holder(stale: true), "queue" => [waiter(stale: true)]},
      "free" => {"holder" => nil, "queue" => []},
      "being-cleared" => {"holder" => holder(stale: true, clearing: {"pid" => 1, "started" => "z"}), "queue" => [waiter]},
      "idle-agent" => {"holder" => holder(idle_since: now.to_i - 301, acquired_at: "2026-10-16T09:00:00Z"), "queue" => [waiter]},
      "idle-briefly" => {"holder" => holder(idle_since: now.to_i - 10), "queue" => [waiter]},
      "devenv" => {"holder" => holder(kind: "process", idle_since: now.to_i - 9999), "queue" => [waiter]}
    }
  end
  let(:lock_store_for) do
    entries = lock_entries
    ->(_dir) do
      Class.new do
        define_method(:status) do |name = nil|
          raise entries if entries.is_a?(Exception)
          entries
        end
      end.new
    end
  end
  let(:lock_config) { Class.new { define_method(:idle_grace_for) { |_name| 300 } }.new }

  let(:project) do
    Workspace::ProjectCatalog::Project.new(name: "api", id: "/src/api/.git", path: "/src/api", vcs: "git", members: [])
  end
  let(:workspaces) { %w[api api.worktree-a api.worktree-b api.worktree-c] }

  subject(:derived) do
    described_class.new(snapshot_client: snapshot_client, tmux: tmux, ask_store_for: ask_store_for, plan: plan, plan_state: plan_state,
      plan_config: plan_config, workflow_status: workflow_status, lock_namespace: lock_namespace, lock_store_for: lock_store_for,
      lock_config: lock_config, clock: -> { now }, agent_timeout: 0.25)
  end

  def read(**opts)
    derived.rows(workspaces: workspaces, projects: [project], **opts)
  end

  before { FileUtils.mkdir_p(lock_dir) }

  context "with one of each source waiting on a person" do
    let(:lock_entries) { {"edit" => {"holder" => holder(stale: true), "queue" => [waiter]}} }
    let!(:ask) { ask_store_for.call("api").add(question: "Which port?", default: "3000", pane: "%1") }
    let!(:plan_path) { write_plan("api.worktree-b", blocked_plan) }

    it "has one row per source with the Design ids and fingerprints" do
      result = read
      sha = Digest::SHA1.hexdigest("/src/api/.git")[0, 12]

      expect(result[:rows].map { |row| [row["id"], row["fingerprint"]] }).to contain_exactly(
        ["ask:api:#{ask["id"]}", ask["asked_at"]],
        ["pane:waiting:api.worktree-a:%5", "2026-10-16T11:50:00Z"],
        ["plan:blocked:api.worktree-b", File.mtime(plan_path).utc.iso8601],
        ["workflow:waiting_you:r-gate", "plan:2026-10-16T11:30:00Z"],
        ["lock:stale:#{sha}:edit", "2026-10-16T10:00:00Z"]
      )
      expect(result[:rows]).to all(include("derived" => true, "state" => "open", "type" => "alert"))
      expect(result[:warnings]).to eq([])
    end

    it "gives each row its scope, title, links and time" do
      rows = read[:rows].to_h { |row| [row["kind"], row] }

      expect(rows["ask"]).to include("scope" => {"kind" => "workspace", "key" => "api", "name" => "api"}, "title" => "Which port?",
        "updated_at" => ask["asked_at"])
      expect(rows["ask"]["links"]).to include("pane" => "%1")
      expect(rows["pane_waiting"]).to include("body" => "Allow Bash?", "links" => a_hash_including("pane" => "%5"))
      expect(rows["plan_blocked"]).to include("title" => "Plan blocked in api.worktree-b", "body" => "Ship it")
      expect(rows["workflow_waiting_you"]).to include("scope" => a_hash_including("key" => "api.worktree-c"),
        "links" => a_hash_including("run_id" => "r-gate"))
      expect(rows["lock_stale"]).to include("scope" => {"kind" => "project", "key" => "/src/api/.git", "name" => "api"},
        "links" => a_hash_including("pane" => "%12"))
    end

    it "leaves out an ask once it is withdrawn" do
      ask_store_for.call("api").withdraw(ask["id"])

      expect(read[:rows].map { |row| row["kind"] }).not_to include("ask")
    end

    it "reads the daemons in parallel, each with its own timeout, and skips a stopped workspace's" do
      read
      calls = []
      calls << fetch_calls.pop until fetch_calls.empty?

      expect(calls).to contain_exactly(["api", 0.25], ["api.worktree-a", 0.25], ["api.worktree-b", 0.25])
    end

    it "has every daemon read in flight at once" do
      arrived = Queue.new
      release = Queue.new
      gate = Class.new do
        define_method(:fetch) do |name, timeout: nil|
          arrived << name
          release.pop(timeout: 2) || raise(Workspace::AgentSnapshotClient::Unavailable.new("serial", reason: :timeout))
          {"panes" => []}
        end
      end.new
      reader = described_class.new(snapshot_client: gate, tmux: tmux, ask_store_for: ask_store_for, plan: plan, plan_state: plan_state,
        plan_config: plan_config, workflow_status: workflow_status, lock_namespace: lock_namespace, lock_store_for: lock_store_for,
        lock_config: lock_config, clock: -> { now })
      opener = Thread.new do
        3.times { arrived.pop(timeout: 2) }
        3.times { release << true }
      end

      result = reader.rows(workspaces: workspaces, projects: [])
      opener.join

      expect(result[:warnings].map { |w| w["code"] }).not_to include("daemons_unavailable")
    end

    context "when a daemon times out" do
      let(:daemon_replies) do
        super().merge("api.worktree-a" => Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout))
      end

      it "warns daemons_unavailable and leaves that workspace's panes out" do
        result = read

        expect(result[:rows].map { |row| row["kind"] }).to contain_exactly("ask", "plan_blocked", "workflow_waiting_you", "lock_stale")
        expect(result[:warnings]).to contain_exactly(a_hash_including("code" => "daemons_unavailable", "workspace" => "api.worktree-a"))
        expect(result[:warnings].first["message"]).to include("timeout")
      end
    end
  end

  it "reads nothing when there is nothing to read" do
    tmux_reads = 0
    allow(tmux).to receive(:sessions) { tmux_reads += 1 }

    expect(derived.rows(workspaces: [], projects: [])).to eq(rows: [], warnings: [])
    expect(fetch_calls).to be_empty
    expect(tmux_reads).to eq(0)
  end

  describe "plans" do
    it "counts a stalled plan (owner pane idle past plan.stall_seconds)" do
      write_plan("api.worktree-a", blocked_plan.sub("status: active", "status: active\nowner_pane: \"%6\"").sub("[!] T2", "[ ] T2"))
      daemon_replies["api.worktree-a"]["panes"][1]["state_since"] = "2026-10-16T11:00:00Z"

      row = read[:rows].find { |r| r["kind"] == "plan_stalled" }

      expect(row).to include("id" => "plan:stalled:api.worktree-a", "links" => a_hash_including("plan_task" => "T2"))
    end

    it "leaves out a plan that is waiting, working, idle or done, and one blocked while a question is open" do
      write_plan("api", blocked_plan)
      ask_store_for.call("api").add(question: "Which port?", default: "3000")
      write_plan("api.worktree-c", blocked_plan.sub("[!] T2", "[x] T2"))

      expect(read[:rows].map { |r| r["kind"] }).not_to include("plan_blocked", "plan_stalled")
    end

    it "warns plan_unreadable when a plan can't be located" do
      plan_paths["api.worktree-b"] = Workspace::Error.new("notes.dir is not readable")

      result = read

      expect(result[:warnings]).to include(a_hash_including("code" => "plan_unreadable", "workspace" => "api.worktree-b"))
    end
  end

  describe "questions" do
    it "warns questions_unreadable and adds no question rows when the store raises" do
      broken = ->(_workspace, _sink) { raise Workspace::Error, "locked out" }
      reader = described_class.new(snapshot_client: snapshot_client, tmux: tmux, ask_store_for: broken, plan: plan,
        plan_state: plan_state, plan_config: plan_config, workflow_status: workflow_status, lock_namespace: lock_namespace,
        lock_store_for: lock_store_for, lock_config: lock_config, clock: -> { now })

      result = reader.rows(workspaces: ["api"], projects: [])

      expect(result[:rows].map { |r| r["kind"] }).not_to include("ask")
      expect(result[:warnings]).to include(a_hash_including("code" => "questions_unreadable", "workspace" => "api"))
    end

    it "warns questions_unreadable when the store file is not valid JSON, rather than reading it as empty" do
      path = File.join(tmpdir, "asks", "api", "asks.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json")

      result = read

      expect(result[:rows].map { |r| r["kind"] }).not_to include("ask")
      expect(result[:warnings]).to include(a_hash_including("code" => "questions_unreadable", "workspace" => "api"))
    end

    it "keeps a long or multi-line question's title to one line of 200 characters" do
      ask_store_for.call("api").add(question: "#{"x" * 300}\nsecond line", default: "no")

      row = read[:rows].find { |r| r["kind"] == "ask" }

      expect(row["title"]).to eq("#{"x" * 197}...")
      expect(row["body"]).to include("second line")
    end
  end

  describe "workflow gates" do
    it "counts only a gate still waiting, in the workspaces read" do
      expect(read[:rows].select { |r| r["kind"] == "workflow_waiting_you" }.map { |r| r["id"] }).to eq(["workflow:waiting_you:r-gate"])
    end

    it "skips a gate whose step's own gate is no longer waiting" do
      workflow_reply["runs"] = [workflow_run("r-gate", workspace: "api.worktree-c", code: "waiting_you", kind: "gate", gate: "approved")]

      expect(read[:rows].map { |r| r["kind"] }).not_to include("workflow_waiting_you")
    end

    it "passes the workflow warnings on and warns workflow_unreadable when the runs can't be read" do
      workflow_reply["warnings"] = ["The run file /x.json can't be read"]
      expect(read[:warnings]).to include({"code" => "workflow_unreadable", "message" => "The run file /x.json can't be read"})
    end

    context "when WorkflowStatus raises" do
      let(:workflow_reply) { Workspace::Error.new("runs dir unreadable") }

      it "warns workflow_unreadable and adds no workflow rows" do
        result = read

        expect(result[:rows].map { |r| r["kind"] }).not_to include("workflow_waiting_you")
        expect(result[:warnings]).to include(a_hash_including("code" => "workflow_unreadable"))
      end
    end
  end

  describe "locks" do
    it "counts a dead holder or an agent idle past the grace, with a live waiter; never a process holder or one being cleared" do
      rows = read[:rows].select { |r| r["kind"] == "lock_stale" }

      expect(rows.map { |r| r["id"].split(":").last }).to contain_exactly("edit", "idle-agent")
      expect(rows.find { |r| r["id"].end_with?(":idle-agent") }["fingerprint"]).to eq("2026-10-16T09:00:00Z:#{now.to_i - 301}")
    end

    it "reads no lock store for a project that has never held a lock" do
      FileUtils.rm_rf(lock_dir)

      expect(read[:rows].map { |r| r["kind"] }).not_to include("lock_stale")
      expect(Dir.exist?(lock_dir)).to be(false)
    end

    context "when the lock store can't be read" do
      let(:lock_entries) { Workspace::Error.new("Could not access lock store") }

      it "warns locks_unreadable and adds no lock rows" do
        result = read

        expect(result[:rows].map { |r| r["kind"] }).not_to include("lock_stale")
        expect(result[:warnings]).to include(a_hash_including("code" => "locks_unreadable", "project" => "api"))
      end
    end
  end

  context "when tmux can't be asked" do
    let(:tmux_sessions) { Workspace::Error.new("no server") }

    it "asks every workspace's daemon and warns tmux_unavailable" do
      result = read
      calls = []
      calls << fetch_calls.pop until fetch_calls.empty?

      expect(calls.map(&:first)).to contain_exactly(*workspaces)
      expect(result[:warnings]).to include(a_hash_including("code" => "tmux_unavailable"))
      expect(result[:warnings]).to include(a_hash_including("code" => "daemons_unavailable", "workspace" => "api.worktree-c"))
    end
  end
end
