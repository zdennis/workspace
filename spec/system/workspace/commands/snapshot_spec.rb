require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Snapshot do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:now) { Time.utc(2026, 10, 2, 20, 30, 1, 120_000) }
  let(:clock) { Struct.new(:time) { def now = time }.new(now) }

  def member(name, kind: "worktree", exists: true, configured: true)
    Workspace::ProjectCatalog::Member.new(workspace: name, path: "/src/#{name}", kind: kind, configured: configured, exists: exists)
  end

  let(:app_members) { [member("app", kind: "main"), member("app.worktree-fix")] }
  let(:app) { Workspace::ProjectCatalog::Project.new(name: "app", id: "/src/app/.git", path: "/src/app", vcs: "git", members: app_members) }
  let(:other) { Workspace::ProjectCatalog::Project.new(name: "other", id: "/src/other/.git", path: "/src/other", vcs: "git", members: [member("other", kind: "main")]) }
  let(:projects) { [app, other] }
  let(:catalog) do
    list = projects
    Class.new { define_method(:all) { list } }.new
  end

  # Mirrors ProjectFacts: for_project returns member hashes in member order.
  let(:facts) do
    git_table = git_by_path
    asks_fact = ->(name) { fact_open_asks.fetch(name, 0) }
    Class.new do
      define_method(:for_project) do |project, **|
        members = project.members.map do |m|
          {"workspace" => m.workspace, "path" => m.path, "kind" => m.kind, "configured" => true, "exists" => true, "running" => false,
           "headless" => false, "open_asks" => asks_fact.call(m.workspace), "pipeline" => {"entries" => 2}, "agents" => nil}
        end
        {members: members, locks: {"edit" => {"holder" => {"workspace" => "app", "path" => "/src/app", "pid" => 9, "stale" => false}, "queue" => []}},
         dev: {"running" => true, "ready" => true, "holder_workspace" => "app"}, errors: {}}
      end
      define_method(:git_facts) { |_project, members, deadline:| members.map { |m| git_table[m.path] } }
      define_method(:git_deadline) { 0.0 }
    end.new
  end
  let(:fact_open_asks) { {} }
  let(:git_by_path) do
    {
      "/src/app" => {"available" => true, "branch" => "main", "changed_files" => 0, "ahead" => 0, "upstream" => "origin/main", "unpushed_commits" => 0, "unsaved" => "no"},
      "/src/app.worktree-fix" => {"available" => true, "branch" => "fix", "changed_files" => 3, "ahead" => 2, "upstream" => nil, "unpushed_commits" => 2, "unsaved" => "yes"},
      "/src/other" => {"available" => false, "reason" => "timeout", "branch" => nil, "changed_files" => nil, "ahead" => nil, "upstream" => nil,
                       "unpushed_commits" => nil, "unsaved" => "unknown"}
    }
  end

  let(:tmux_sessions) { ["app", "app-wt-fix"] }
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

  let(:state) do
    Class.new do
      define_method(:load) { nil }
      define_method(:[]) { |key| (key == "app.worktree-fix") ? {"iterm_window_id" => 31337} : nil }
    end.new
  end

  let(:event_log) { File.join(tmpdir, "events.jsonl") }
  let(:config) do
    log = event_log
    Class.new do
      define_method(:event_log_file) { log }
      define_method(:agent_log_path) { |name| "/logs/workspace-#{name}.log" }
    end.new
  end

  def pane(id, state, **extra)
    {"pane_id" => id, "index" => 1, "kind" => "claude", "title" => "Claude Code", "display_label" => "Fix login", "state" => state,
     "state_since" => "2026-10-02T20:00:00Z", "waiting_message" => nil, "context_pct" => 71, "agents" => [{"name" => "reviewer", "state" => "working"}],
     "lock_name" => "edit", "lock_state" => "held", "open_questions" => 1}.merge(extra)
  end

  let(:daemon_replies) do
    {
      "app" => Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon),
      "other" => Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon),
      "app.worktree-fix" => {"workspace" => "app-wt-fix", "task" => {"id" => "t1"}, "panes" => [pane("%19", "waiting", "waiting_message" => "Allow Bash?")]}
    }
  end
  let(:fetch_calls) { [] }
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
  let(:annotated) { [] }
  let(:sessions) do
    log = annotated
    Class.new { define_method(:annotate) { |name, snapshot| (log << name) && snapshot } }.new
  end

  let(:upstream_config_calls) { [] }
  let(:upstream_configs) { {} }
  let(:git) do
    calls = upstream_config_calls
    configs = upstream_configs
    Class.new do
      define_method(:base_ref) { |path| (path == "/src/other") ? raise(Workspace::Error, "no base") : "origin/main" }
      define_method(:upstream_config) { |path, branch| (calls << [path, branch]) && configs[path] }
      define_method(:commits_ahead_of) { |path, base| (path == "/src/app") ? nil : 4 }
    end.new
  end
  let(:pr_calls) { [] }
  let(:pr_result) { {"available" => true, "found" => true, "number" => 812, "url" => "https://x/812", "state" => "OPEN", "draft" => false, "review_decision" => nil, "checks" => {"total" => 3, "passing" => 1, "failing" => 1, "pending" => 1, "failed" => ["ci"]}} }
  let(:pull_request_status) do
    calls = pr_calls
    result = pr_result
    Class.new { define_method(:call) { |path| (calls << path) && result } }.new
  end
  let(:ask_store_for) do
    dir = tmpdir
    ->(workspace) { Workspace::AskStore.new(path: File.join(dir, workspace, "asks.json"), error_output: error_output) }
  end

  let(:plan_paths) { Hash.new { |_, name| File.join(tmpdir, "notes", name, "IMPLEMENTATION_PLAN.md") } }
  let(:plan_command) do
    table = plan_paths
    Class.new do
      define_method(:path_for) do |name|
        value = table[name]
        raise value if value.is_a?(Exception)
        value
      end
    end.new
  end
  let(:task_records) { {} }
  let(:task_store) do
    records = task_records
    Class.new { define_method(:latest_by_workspace) { records } }.new
  end
  let(:groups) { nil }
  let(:stall_seconds) { 300 }
  let(:plan_config) do
    seconds = stall_seconds
    Class.new { define_method(:stall_seconds_for) { |_name| seconds } }.new
  end

  let(:review_agent) { {"available" => true, "state" => "done"} }
  let(:review_ahead) { 2 }
  let(:review) do
    agent = review_agent
    ahead = review_ahead
    Class.new do
      define_method(:agent_facts_from) { |_workspace, **| agent }
      define_method(:commits_ahead_of_base) { |_path| ahead }
    end.new
  end
  let(:spine_facts) do
    Workspace::SpineFacts.new(git: git, pull_request_status: pull_request_status, snapshot_client: snapshot_client, review: review,
      ask_store_for: ask_store_for, which: ->(_) {})
  end
  let(:notes_dirs) { Hash.new { |_, name| File.join(tmpdir, "notes", name) } }
  let(:spine) do
    dirs = notes_dirs
    notes = Class.new do
      define_method(:info) do |name:|
        dir = dirs[name]
        raise dir if dir.is_a?(Exception)
        {"dir" => dir}
      end
    end.new
    Workspace::Commands::Spine.new(notes: notes)
  end

  subject(:snapshot) do
    described_class.new(catalog: catalog, facts: facts, tmux: tmux, state: state, config: config, snapshot_client: snapshot_client,
      sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: ask_store_for, plan: plan_command,
      plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config, task_store: task_store, spine: spine, spine_facts: spine_facts, output: output,
      error_output: error_output, clock: clock, groups: groups)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def parsed = JSON.parse(output.string)

  def member_row(doc, name) = doc["projects"].flat_map { |p| p["members"] }.find { |m| m["workspace"] == name }

  describe "the document" do
    before do
      File.write(event_log, "{}\n")
      store = Workspace::AskStore.new(path: File.join(tmpdir, "app.worktree-fix", "asks.json"))
      store.add(question: "Use Postgres 16?", default: "yes", pane: "%19")
      snapshot.call
    end

    it "is one schema-versioned document with a timestamp and a cursor" do
      stat = File.stat(event_log)

      expect(parsed).to include("schema_version" => 1, "ok" => true, "generated_at" => "2026-10-02T20:30:01.120Z", "cursor" => "ev:#{stat.ino}:3")
      expect(parsed.keys).to eq(%w[schema_version ok generated_at cursor projects daemons_unavailable warnings])
    end

    it "groups members under projects and carries workspace names, paths and tmux sessions" do
      expect(parsed["projects"].map { |p| [p["id"], p["name"], p["members"].map { |m| m["workspace"] }] }).to eq([
        ["/src/app/.git", "app", ["app", "app.worktree-fix"]], ["/src/other/.git", "other", ["other"]]
      ])
      expect(member_row(parsed, "app.worktree-fix")).to include("kind" => "worktree", "path" => "/src/app.worktree-fix", "tmux_session" => "app-wt-fix",
        "running" => true, "headless" => false, "iterm_window_id" => 31337)
      expect(member_row(parsed, "other")["running"]).to eq(false)
    end

    it "reports the daemon, its panes with lock and question columns, and the task" do
      row = member_row(parsed, "app.worktree-fix")

      expect(row["daemon"]).to eq("up" => true, "pid" => nil, "log_path" => "/logs/workspace-app.worktree-fix.log")
      expect(row["panes"]).to eq([{
        "pane_id" => "%19", "index" => 1, "kind" => "claude", "title" => "Claude Code", "display_label" => "Fix login", "state" => "waiting",
        "state_since" => "2026-10-02T20:00:00Z", "stop_reason" => nil, "waiting_message" => "Allow Bash?", "waiting_tool" => nil, "waiting_input" => nil, "context_pct" => 71,
        "agents" => [{"name" => "reviewer", "state" => "working"}], "lock" => "edit", "lock_state" => "held", "open_questions" => 1
      }])
      expect(row["task"]).to eq("id" => "t1")
      expect(annotated).to include("app.worktree-fix")
    end

    it "lists the open questions and the pipeline entry count" do
      row = member_row(parsed, "app.worktree-fix")

      expect(row["questions"].map { |q| q.slice("question", "default", "pane", "status") }).to eq([
        {"question" => "Use Postgres 16?", "default" => "yes", "pane" => "%19", "status" => "open"}
      ])
      expect(row["pipeline"]).to eq("entries" => 2)
    end

    it "gives each project its locks as a list and its dev environment, with workspace names" do
      project = parsed["projects"].first

      expect(project["locks"]).to eq([{"name" => "edit", "holder" => {"workspace" => "app", "path" => "/src/app", "pid" => 9, "stale" => false}, "queue" => []}])
      expect(project["dev"]).to eq("running" => true, "ready" => true, "holder_workspace" => "app")
    end

    context "with a permission wait that names its tool" do
      let(:daemon_replies) do
        super().merge("app.worktree-fix" => {"workspace" => "app-wt-fix", "task" => {"id" => "t1"},
                                             "panes" => [pane("%19", "waiting", "waiting_tool" => "Bash", "waiting_input" => "rm -rf build")]})
      end

      it "carries waiting_tool and waiting_input into the pane row" do
        expect(member_row(parsed, "app.worktree-fix")["panes"].first).to include("waiting_tool" => "Bash", "waiting_input" => "rm -rf build")
      end
    end

    it "never includes an actions map" do
      expect(output.string).not_to include("\"actions\"")
    end
  end

  describe "plan" do
    def write_plan(name, text)
      path = plan_paths[name]
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end

    let(:plan_text) do
      <<~MD
        ---
        plan: 1
        title: Ship it
        status: active
        owner_pane: "%19"
        ---
        # Ship it

        ## Tasks

        - [x] T1 First
        - [~] T9 Second
        - [ ] T10 Third
      MD
    end

    it "is null for a member with no plan file" do
      snapshot.call

      expect(parsed["projects"].flat_map { |p| p["members"] }.map { |m| m["plan"] }).to all(be_nil)
      expect(parsed["warnings"]).to eq([])
    end

    it "reports state, status, signature, counts, percent, current and updated_at, without tasks" do
      path = write_plan("app.worktree-fix", plan_text)
      stat = File.stat(path)
      snapshot.call
      block = member_row(parsed, "app.worktree-fix")["plan"]

      expect(block.keys).to eq(%w[state status signature counts percent current updated_at])
      expect(block).to include("state" => "waiting", "status" => "active", "percent" => 33, "current" => {"id" => "T9", "phase" => nil, "title" => "Second"})
      expect(block["signature"]).to eq("#{stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec}:#{stat.size}")
      expect(block["updated_at"]).to eq(stat.mtime.utc.iso8601)
      expect(block["counts"]).to include("total" => 3, "done" => 1)
    end

    it "matches what plan status reports for the same file" do
      path = write_plan("app", plan_text)
      snapshot.call
      row = Workspace::PlanState.new(clock: -> { now }).row(workspace: "app", project: nil, path: path, plan: Workspace::PlanFile.read(path),
        session_live: true, panes: nil)

      expect(member_row(parsed, "app")["plan"]).to eq(row.slice("state", "status", "signature", "counts", "percent", "current", "updated_at"))
    end

    it "reads the owner pane from the panes the snapshot already holds, not a second daemon read" do
      write_plan("app.worktree-fix", plan_text)
      snapshot.call

      expect(fetch_calls.count { |name, _| name == "app.worktree-fix" }).to eq(1)
    end

    it "counts the open questions the snapshot read toward waiting" do
      daemon_replies["app.worktree-fix"]["panes"] = [pane("%19", "idle")]
      write_plan("app.worktree-fix", plan_text)
      store = Workspace::AskStore.new(path: File.join(tmpdir, "app.worktree-fix", "asks.json"))
      store.add(question: "Use Postgres 16?", default: "yes", pane: "%19")
      snapshot.call

      expect(member_row(parsed, "app.worktree-fix")["plan"]["state"]).to eq("waiting")
    end

    it "falls back to the open-question count in the member facts when the ask store can't be read" do
      fact_open_asks["app.worktree-fix"] = 1
      daemon_replies["app.worktree-fix"]["panes"] = [pane("%19", "idle")]
      write_plan("app.worktree-fix", plan_text)
      broken = ->(_workspace) { raise IOError, "ask store broken" }
      described_class.new(catalog: catalog, facts: facts, tmux: tmux, state: state, config: config, snapshot_client: snapshot_client,
        sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: broken, plan: plan_command,
        plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config, task_store: task_store, spine: spine, spine_facts: spine_facts, output: output, error_output: error_output,
        clock: clock).call

      expect(member_row(parsed, "app.worktree-fix")["plan"]["state"]).to eq("waiting")
    end

    it "reads stopped for a workspace with no live session and paused ahead of it" do
      write_plan("other", plan_text)
      write_plan("app", plan_text.sub("status: active", "status: paused"))
      snapshot.call

      expect(member_row(parsed, "other")["plan"]["state"]).to eq("stopped")
      expect(member_row(parsed, "app")["plan"]["state"]).to eq("paused")
    end

    it "does not call a plan stopped when tmux can't be asked" do
      write_plan("other", plan_text)
      table = Class.new do
        def sessions(strict: false) = raise(Workspace::Error, "tmux down")

        def session_name_for(name) = name

        def custom_socket_option(_name)
        end
      end.new
      described_class.new(catalog: catalog, facts: facts, tmux: table, state: state, config: config, snapshot_client: snapshot_client,
        sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: ask_store_for, plan: plan_command,
        plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config, task_store: task_store, spine: spine, spine_facts: spine_facts, output: output, error_output: error_output,
        clock: clock).call

      expect(member_row(parsed, "other")["plan"]["state"]).to eq("idle")
    end

    it "uses the stall limit the config gives" do
      daemon_replies["app.worktree-fix"]["panes"] = [pane("%19", "idle", "state_since" => (now - 120).utc.iso8601)]
      write_plan("app.worktree-fix", plan_text)
      described_class.new(catalog: catalog, facts: facts, tmux: tmux, state: state, config: config, snapshot_client: snapshot_client,
        sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: ask_store_for, plan: plan_command,
        plan_state: Workspace::PlanState.new(clock: -> { now }),
        plan_config: Class.new { def stall_seconds_for(_name) = 60 }.new, task_store: task_store, spine: spine, spine_facts: spine_facts, output: output, error_output: error_output, clock: clock).call

      expect(member_row(parsed, "app.worktree-fix")["plan"]["state"]).to eq("stalled")
    end

    it "gives a malformed plan a block with no tasks counted, not a failure" do
      write_plan("app", "\x00\xFF not a plan\n---\n- [?] nope\n")
      expect(snapshot.call).to eq(exit_code: 0)

      expect(member_row(parsed, "app")["plan"]).to include("state" => "empty", "percent" => 0)
    end

    it "gives an unreadable plan file a block, and the rest of the snapshot is unharmed" do
      path = write_plan("app", plan_text)
      File.chmod(0o000, path)
      begin
        expect(snapshot.call).to eq(exit_code: 0)
      ensure
        File.chmod(0o600, path)
      end

      expect(member_row(parsed, "app")["plan"]).to include("state" => "empty")
      expect(member_row(parsed, "other")["plan"]).to be_nil
    end

    it "gives a plan path that is a directory a block, not a failure" do
      FileUtils.mkdir_p(plan_paths["app"])
      expect(snapshot.call).to eq(exit_code: 0)

      expect(member_row(parsed, "app")["plan"]).to include("state" => "empty")
    end

    it "makes the plan null with a plan_unavailable warning when the notes directory can't be worked out" do
      plan_paths["other"] = Workspace::Error.new("No branch", code: "notes_dir_unresolved")
      snapshot.call

      expect(member_row(parsed, "other")["plan"]).to be_nil
      expect(parsed["warnings"]).to include("code" => "plan_unavailable", "workspace" => "other", "message" => "No branch")
      expect(member_row(parsed, "app")["plan"]).to be_nil
    end
  end

  describe "git" do
    before { snapshot.call }

    it "reports branch, base, change counts, ahead and upstream" do
      expect(member_row(parsed, "app.worktree-fix")["git"]).to eq(
        "available" => true, "branch" => "fix", "changed_files" => 3, "ahead" => 2, "upstream" => nil, "unpushed_commits" => 2, "unsaved" => "yes", "base" => "origin/main", "ahead_of_base" => 4
      )
    end

    it "gives ahead_of_base as null when the count is unavailable or the branch has no base" do
      expect(member_row(parsed, "app")["git"]).to include("base" => "origin/main", "ahead_of_base" => nil)
      expect(member_row(parsed, "other")["git"]).to include("base" => nil, "ahead_of_base" => nil)
    end

    it "marks a read git could not answer as unavailable and unsaved unknown, never clean" do
      git = member_row(parsed, "other")["git"]

      expect(git).to include("available" => false, "reason" => "timeout", "unsaved" => "unknown", "base" => nil)
    end

    it "has no pr key without --pr" do
      expect(member_row(parsed, "app")["git"]).not_to have_key("pr")
      expect(pr_calls).to be_empty
    end
  end

  describe "--pr" do
    it "adds a compact pull request to each readable branch" do
      snapshot.call(pr: true)

      expect(member_row(parsed, "app.worktree-fix")["git"]["pr"]).to eq(
        "available" => true, "found" => true, "number" => 812, "url" => "https://x/812", "state" => "open", "draft" => false, "review_decision" => nil, "checks" => "failing"
      )
      expect(pr_calls).to contain_exactly("/src/app", "/src/app.worktree-fix")
      expect(member_row(parsed, "other")["git"]["pr"]).to eq("available" => false, "reason" => "git_unavailable")
    end

    it "reports gh failing as unavailable and a branch without one as not found" do
      allow(pull_request_status).to receive(:call).and_return({"available" => false, "reason" => "gh_missing"})
      snapshot.call(pr: true)
      expect(member_row(parsed, "app")["git"]["pr"]).to eq("available" => false, "reason" => "gh_missing")

      output.truncate(0)
      output.rewind
      allow(pull_request_status).to receive(:call).and_return({"available" => true, "found" => false})
      snapshot.call(pr: true)
      expect(member_row(parsed, "app")["git"]["pr"]).to eq("available" => true, "found" => false)
    end
  end

  describe "unexpected failures" do
    it "turns a daemon read that blows up into an unreadable_reply row, not an error document" do
      daemon_replies["app"] = JSON::ParserError.new("bad json")
      daemon_replies["app.worktree-fix"] = Errno::ECONNRESET.new
      snapshot.call

      expect(parsed["ok"]).to eq(true)
      expect(parsed["daemons_unavailable"]).to contain_exactly(a_hash_including("workspace" => "app", "code" => "unreadable_reply"), a_hash_including("workspace" => "app.worktree-fix", "code" => "unreadable_reply"))
    end

    it "reports an ask store that raises anything as null questions with a warning" do
      allow(ask_store_for).to receive(:call).and_raise(Errno::EACCES)
      snapshot.call

      expect(parsed["ok"]).to eq(true)
      expect(member_row(parsed, "app")["questions"]).to be_nil
      expect(parsed["warnings"]).to include(a_hash_including("code" => "questions_unavailable", "workspace" => "app"))
    end

    it "turns a stamping failure in the sessions reader into an unreadable_reply row" do
      allow(sessions).to receive(:annotate).and_raise(Workspace::Error, "lock store exploded")
      snapshot.call

      expect(parsed["ok"]).to eq(true)
      expect(parsed["daemons_unavailable"]).to include(a_hash_including("workspace" => "app.worktree-fix", "code" => "unreadable_reply"))
      expect(member_row(parsed, "app.worktree-fix")["panes"]).to be_nil
    end

    it "reports a pull request read that raises as unavailable with reason error" do
      allow(pull_request_status).to receive(:call).and_raise(RuntimeError, "boom")
      snapshot.call(pr: true)

      expect(member_row(parsed, "app")["git"]["pr"]).to include("available" => false, "reason" => "error", "detail" => "boom")
    end

    it "gives a null base when the base ref cannot be read" do
      allow(git).to receive(:base_ref).and_raise(Workspace::Error, "no base")
      snapshot.call

      expect(member_row(parsed, "app")["git"]).to include("available" => true, "base" => nil, "ahead_of_base" => nil)
    end

    it "gives a null ahead_of_base when the count raises" do
      allow(git).to receive(:commits_ahead_of).and_raise(Workspace::Error, "boom")
      snapshot.call

      expect(member_row(parsed, "app.worktree-fix")["git"]).to include("base" => "origin/main", "ahead_of_base" => nil)
    end

    it "refuses a --name that is only a worktree without a workspace config, like any unknown name" do
      result = snapshot.call(names: ["app.worktree-unconfigured"])

      expect(result).to eq(exit_code: 1)
      expect(parsed).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "explains a named workspace whose checkout is gone with a warning, not silence" do
      app.members << member("app.worktree-old", exists: false)
      snapshot.call(names: ["app.worktree-old"])

      expect(parsed["warnings"]).to include(a_hash_including("code" => "checkout_missing", "workspace" => "app.worktree-old"))
    end

    it "turns a failure outside any one source into an error envelope" do
      allow(catalog).to receive(:all).and_raise(Workspace::Error, "catalog broke")

      expect(snapshot.call).to eq(exit_code: 1)
      expect(parsed).to include("ok" => false)
    end

    it "leaves git null for a project without git" do
      git_by_path.delete("/src/other")
      snapshot.call(pr: true)

      expect(member_row(parsed, "other")["git"]).to be_nil
    end

    it "gives git.pr an unavailable reason when git could not be read" do
      snapshot.call(pr: true)

      expect(member_row(parsed, "other")["git"]["pr"]).to eq("available" => false, "reason" => "git_unavailable")
    end
  end

  describe "Workspace.build_cli snapshot wiring" do
    it "gives the snapshot command the plan reader, state and config" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {})
      snapshot = cli.instance_variable_get(:@snapshot_command)

      expect(snapshot.instance_variable_get(:@plan)).to be_a(Workspace::Commands::Plan)
      expect(snapshot.instance_variable_get(:@plan_state)).to be_a(Workspace::PlanState)
      expect(snapshot.instance_variable_get(:@plan_config)).to be_a(Workspace::PlanConfig)
    end
  end

  describe "agent daemons" do
    it "reads the running workspaces in parallel, each with a 1 second bound, and skips ones that are not running" do
      arrived = Queue.new
      overlapped = []
      allow(snapshot_client).to receive(:fetch) do |name, timeout:|
        fetch_calls << [name, timeout]
        arrived << name
        # A serial fan-out never gets a second arrival while this call waits.
        overlapped << (Timeout.timeout(2) { sleep 0.005 until arrived.size >= 2 } || true) if name == "app"
        r = daemon_replies.fetch(name)
        r.is_a?(Exception) ? raise(r) : r
      end
      snapshot.call

      expect(overlapped).to eq([true])
      expect(fetch_calls.map(&:first)).to contain_exactly("app", "app.worktree-fix")
      expect(fetch_calls.map(&:last).uniq).to eq([1.0])
    end

    it "lists a running workspace without a daemon as a row and reports its panes as null, not empty" do
      snapshot.call

      expect(parsed["daemons_unavailable"]).to eq([{"workspace" => "app", "code" => "no_daemon"}])
      expect(member_row(parsed, "app")).to include("panes" => nil, "daemon" => {"up" => false, "pid" => nil, "log_path" => "/logs/workspace-app.log"})
      expect(member_row(parsed, "app")["task"]).to be_nil
    end

    it "reports the recorded task of a stopped workspace, and an archived one with its outcome" do
      task_records.merge!("other" => {"id" => "t9", "title" => "Fix login", "ref" => "PROJ-1", "branch" => "fix-login"},
        "app" => {"id" => "t2", "title" => "Old", "ref" => nil, "branch" => "old", "outcome" => "merged"})
      snapshot.call

      expect(member_row(parsed, "other")["task"]).to eq("id" => "t9", "title" => "Fix login", "ref" => "PROJ-1", "branch" => "fix-login", "status" => "stopped", "outcome" => nil)
      expect(member_row(parsed, "app")["task"]).to include("id" => "t2", "status" => "archived", "outcome" => "merged")
    end

    it "reports a null task and one task_store_unavailable warning when the store can't be read" do
      allow(task_store).to receive(:latest_by_workspace).and_raise(Errno::EACCES)
      snapshot.call

      expect(member_row(parsed, "other")["task"]).to be_nil
      expect(parsed["warnings"].count { |w| w["code"] == "task_store_unavailable" }).to eq(1)
    end

    it "reads the task store once for all stopped members" do
      allow(task_store).to receive(:latest_by_workspace).and_call_original
      snapshot.call

      expect(task_store).to have_received(:latest_by_workspace).once
    end

    it "reports a null task when none was recorded" do
      snapshot.call

      expect(member_row(parsed, "other")["task"]).to be_nil
    end

    it "does not ask a workspace that is not running, and does not list it as unavailable" do
      snapshot.call

      expect(fetch_calls.map(&:first)).not_to include("other")
      expect(parsed["daemons_unavailable"].map { |r| r["workspace"] }).not_to include("other")
      expect(member_row(parsed, "other")["panes"]).to be_nil
    end

    it "maps a slow daemon to timeout and a bad reply to unreadable_reply" do
      daemon_replies["app"] = Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout)
      daemon_replies["app.worktree-fix"] = Workspace::Error.new("Malformed reply")
      snapshot.call

      expect(parsed["daemons_unavailable"]).to contain_exactly({"workspace" => "app", "code" => "timeout"}, {"workspace" => "app.worktree-fix", "code" => "unreadable_reply"})
    end
  end

  describe "when tmux cannot answer" do
    let(:tmux_sessions) { Workspace::Error.new("tmux: no server") }

    it "reports running as null with a warning instead of false, and still asks the daemons" do
      snapshot.call

      expect(member_row(parsed, "app")["running"]).to be_nil
      expect(parsed["warnings"]).to include(a_hash_including("code" => "tmux_unavailable"))
      expect(fetch_calls.map(&:first)).to contain_exactly("app", "app.worktree-fix", "other")
    end
  end

  describe "--name" do
    it "keeps only the named members, with their project's locks and dev" do
      snapshot.call(names: ["app.worktree-fix"])

      expect(parsed["projects"].map { |p| p["name"] }).to eq(["app"])
      expect(parsed["projects"].first["members"].map { |m| m["workspace"] }).to eq(["app.worktree-fix"])
      expect(parsed["projects"].first["locks"]).not_to be_empty
      expect(fetch_calls.map(&:first)).to eq(["app.worktree-fix"])
    end

    it "fails with an unknown_workspace error envelope for a name nothing matches" do
      result = snapshot.call(names: ["nope"])

      expect(result).to eq(exit_code: 1)
      expect(parsed).to include("ok" => false, "code" => "unknown_workspace")
    end
  end

  describe "sources that cannot answer" do
    it "reports an unreadable lock store as null locks with a warning" do
      allow(facts).to receive(:for_project).and_wrap_original do |original, project, **kw|
        original.call(project, **kw).merge(locks: nil, errors: {"locks" => "lock store unreadable"})
      end
      snapshot.call

      expect(parsed["projects"].first["locks"]).to be_nil
      expect(parsed["warnings"]).to include("code" => "locks_unavailable", "message" => "lock store unreadable")
    end

    it "reports an unreadable ask store as null questions, not none" do
      allow(ask_store_for).to receive(:call).and_raise(Workspace::Error, "bad asks")
      snapshot.call

      expect(member_row(parsed, "app")["questions"]).to be_nil
    end

    it "reports a missing checkout as a warning instead of a member" do
      gone = member("app.worktree-old", exists: false)
      app.members << gone
      snapshot.call

      expect(member_row(parsed, "app.worktree-old")).to be_nil
      expect(parsed["warnings"]).to include(a_hash_including("code" => "checkout_missing", "workspace" => "app.worktree-old"))
    end
  end

  describe "the cursor" do
    it "is ev:0:0 for a log that does not exist yet" do
      snapshot.call

      expect(parsed["cursor"]).to eq("ev:0:0")
    end

    it "is null with a warning when the log cannot be read" do
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(event_log).and_raise(Errno::EACCES)
      snapshot.call

      expect(parsed["cursor"]).to be_nil
      expect(parsed["warnings"]).to include(a_hash_including("code" => "cursor_unavailable"))
    end

    it "is taken before the sources are read" do
      File.write(event_log, "a\n")
      allow(facts).to receive(:for_project).and_wrap_original do |original, project, **kw|
        File.open(event_log, "a") { |f| f.puts "appended while reading" }
        original.call(project, **kw)
      end
      snapshot.call

      expect(parsed["cursor"]).to end_with(":2")
    end
  end

  describe "the group key" do
    let(:lookups) { [] }
    let(:groups) do
      calls = lookups
      group = Struct.new(:id, :name).new("group:billing", "Billing")
      Class.new do
        define_method(:groups_by_project_id) { (calls << :read) && {"/src/app/.git" => group} }
      end.new
    end

    it "is the group's id and name on a grouped project and null on the rest" do
      snapshot.call

      expect(parsed["projects"].to_h { |p| [p["name"], p["group"]] }).to eq(
        "app" => {"id" => "group:billing", "name" => "Billing"}, "other" => nil
      )
    end

    it "reads the groups once for the whole document" do
      snapshot.call

      expect(lookups).to eq([:read])
    end

    context "without a groups store" do
      let(:groups) { nil }

      it "is null on every project" do
        snapshot.call

        expect(parsed["projects"].map { |p| p["group"] }).to eq([nil, nil])
      end
    end
  end

  describe "spine" do
    def write_spine(name, relative, text)
      path = File.join(tmpdir, "notes", name, "spine", relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def write_plan(name, text)
      path = plan_paths[name]
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def spine_of(name) = member_row(parsed, name)["spine"]

    def call_again(**options)
      output.truncate(0)
      output.rewind
      snapshot.call(**options)
    end

    it "is {exists: false} for a member with no spine folder" do
      snapshot.call

      expect(parsed["projects"].flat_map { |p| p["members"] }.map { |m| m["spine"] }).to all(eq({"exists" => false}))
      expect(parsed["warnings"].map { |w| w["code"] }).not_to include("spine_unavailable")
    end

    describe "#document" do
      it "returns the hash #call prints, and raises instead of printing for an unknown workspace" do
        document = snapshot.document

        expect(document).to include("schema_version" => 1, "ok" => true)
        expect(document["projects"].map { |p| p["name"] }).to eq(%w[app other])
        expect { snapshot.document(names: ["nope"]) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
        expect(output.string).to eq("")
      end

      context "with inferred: true" do
        let(:spine_inferred) { instance_double(Workspace::SpineInferred) }
        let(:snapshot) do
          described_class.new(catalog: catalog, facts: facts, tmux: tmux, state: state, config: config, snapshot_client: snapshot_client,
            sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: ask_store_for, plan: plan_command,
            plan_state: Workspace::PlanState.new(clock: -> { now }), plan_config: plan_config, task_store: task_store, spine: spine, spine_facts: spine_facts,
            output: output, error_output: error_output, clock: clock, groups: groups, spine_inferred: spine_inferred)
        end

        it "gives a member with no spine folder its inferred stage, and leaves the default document alone" do
          stage = {"path" => "plan", "title" => "Plan", "status" => "in_progress", "owner" => nil, "source" => "inferred"}
          allow(spine_inferred).to receive(:current_stage).and_return(stage)

          blocks = snapshot.document(inferred: true)["projects"].flat_map { |p| p["members"] }.map { |m| m["spine"] }
          expect(blocks).to all(eq({"exists" => false, "inferred" => stage}))
          expect(snapshot.document["projects"].flat_map { |p| p["members"] }.map { |m| m["spine"] }).to all(eq({"exists" => false}))
        end
      end
    end

    it "summarises the stages: the current one, its owner, the top-level counts and a signature" do
      write_spine("app.worktree-fix", "goal.md", "---\ntitle: Ship it\n---\n")
      write_spine("app.worktree-fix", "10-research.md", "---\nstatus: done\n---\n")
      write_spine("app.worktree-fix", "20-implement.md", "---\nstatus: active\nowner: \"%19\"\ntitle: Build it\n---\n")
      write_spine("app.worktree-fix", "30-ship.md", "---\nstatus: todo\n---\n")
      snapshot.call

      block = spine_of("app.worktree-fix")
      expect(block).to include("exists" => true, "current" => "implement", "title" => "Build it", "state" => "in_progress",
        "status" => "in_progress", "owner" => "%19", "owner_state" => "waiting", "stages" => 3, "partial" => false)
      expect(block["counts"]).to eq({"completed" => 1, "in_progress" => 1, "not_started" => 1, "blocked" => 0, "skipped" => 0, "unknown" => 0, "disputed" => 0, "checking" => 0, "check_failed" => 0})
      expect(block["signature"]).to match(/\A\h{8}\z/)
    end

    it "reads a completed stage whose check has no passing verdict as checking, and a failed one as check_failed" do
      write_spine("app", "10-a.md", "---\nstatus: completed\ncheck: pending\n---\n")
      write_spine("app", "20-b.md", "---\nstatus: completed\ncheck: failed\n---\n")
      write_spine("app", "30-c.md", "---\nstatus: completed\ncheck: passed\n---\n")
      snapshot.call

      expect(spine_of("app")).to include("current" => "a", "state" => "checking", "status" => "completed")
      expect(spine_of("app")["counts"]).to include("completed" => 1, "checking" => 1, "check_failed" => 1)
    end

    it "has no current stage when every stage is done" do
      write_spine("app", "10-research.md", "---\nstatus: done\n---\n")
      snapshot.call

      expect(spine_of("app")).to include("exists" => true, "current" => nil, "title" => nil, "state" => nil, "owner_state" => nil, "stages" => 1)
    end

    describe "signature" do
      before do
        write_spine("app", "10-a.md", "---\nstatus: todo\n---\n")
        write_spine("app", "20-b.md", "---\nstatus: todo\n---\n")
      end

      it "is the same for the same files and changes when a status is edited" do
        snapshot.call
        first = spine_of("app")["signature"]
        call_again
        expect(spine_of("app")["signature"]).to eq(first)

        write_spine("app", "20-b.md", "---\nstatus: active\n---\n")
        call_again
        expect(spine_of("app")["signature"]).not_to eq(first)
      end

      it "also covers goal.md" do
        snapshot.call
        first = spine_of("app")["signature"]
        write_spine("app", "goal.md", "---\ntitle: New goal\n---\n")
        call_again

        expect(spine_of("app")["signature"]).not_to eq(first)
      end
    end

    describe "gates from the snapshot's own reads" do
      it "passes the plan gate when the plan file already read has no open task" do
        write_plan("app", "---\nplan: 1\nstatus: active\n---\n\n## Tasks\n\n- [x] T1 Done thing\n")
        write_spine("app", "10-build.md", "---\nstatus: done\ngates: [plan]\n---\n")
        snapshot.call

        expect(spine_of("app")["counts"]).to include("completed" => 1, "disputed" => 0)
      end

      it "disputes a completed stage whose plan gate fails" do
        write_plan("app", "---\nplan: 1\nstatus: active\n---\n\n## Tasks\n\n- [ ] T1 Open thing\n")
        write_spine("app", "10-build.md", "---\nstatus: done\ngates: [plan]\n---\n")
        snapshot.call

        expect(spine_of("app")).to include("current" => "build", "state" => "disputed", "status" => "completed")
        expect(spine_of("app")["counts"]["disputed"]).to eq(1)
      end

      it "leaves the pull request gates unchecked and the block partial without --pr, and reads no pull request" do
        write_spine("app", "10-ship.md", "---\nstatus: done\ngates: [pr, ci]\n---\n")
        snapshot.call

        expect(pr_calls).to be_empty
        expect(spine_of("app")).to include("current" => nil, "partial" => true)
        expect(spine_of("app")["counts"]).to include("completed" => 1)
      end

      it "uses the pull request the snapshot read with --pr, and is then not partial" do
        write_spine("app", "10-ship.md", "---\nstatus: done\ngates: [pr, ci]\n---\n")
        snapshot.call(pr: true)

        expect(pr_calls.size).to eq(2)
        expect(spine_of("app")).to include("partial" => false, "state" => "disputed")
      end

      it "decides a review gate on the agent alone without --pr, and says partial" do
        write_spine("app", "10-review.md", "---\nstatus: done\ngates: [review]\n---\n")
        snapshot.call

        expect(spine_of("app")).to include("current" => nil, "partial" => true)
      end

      it "is not partial for a review gate when the pull request was read with --pr" do
        write_spine("app", "10-review.md", "---\nstatus: done\ngates: [review]\n---\n")
        snapshot.call(pr: true)

        expect(spine_of("app")).to include("partial" => false)
      end

      it "is partial when only a sub-stage declares an unchecked gate" do
        write_spine("app", "10-ship.md", "---\nstatus: active\n---\n")
        write_spine("app", "10-ship/10-pr.md", "---\nstatus: done\ngates: [pr]\n---\n")
        snapshot.call

        expect(spine_of("app")).to include("partial" => true, "stages" => 1)
      end

      it "reads a deleted remote branch as unchecked, not never pushed, with one upstream_config read" do
        write_spine("app.worktree-fix", "10-push.md", "---\nstatus: done\ngates: [pushed]\n---\n")
        upstream_configs["/src/app.worktree-fix"] = ["origin", "refs/heads/fix"]
        snapshot.call

        expect(upstream_config_calls).to eq([["/src/app.worktree-fix", "fix"]])
        expect(spine_of("app.worktree-fix")).to include("current" => nil, "partial" => true)
      end

      it "calls a branch with no upstream and no config never pushed" do
        write_spine("app.worktree-fix", "10-push.md", "---\nstatus: done\ngates: [pushed]\n---\n")
        snapshot.call

        expect(spine_of("app.worktree-fix")).to include("state" => "disputed", "partial" => false)
      end
    end

    describe "partial facts" do
      it "leaves gates unchecked and the owner unknown when git and the daemon gave nothing" do
        write_spine("other", "10-build.md", "---\nstatus: done\nowner: \"%3\"\ngates: [pushed]\n---\n")
        write_spine("other", "20-next.md", "---\nstatus: active\nowner: \"%3\"\n---\n")
        snapshot.call

        expect(spine_of("other")).to include("exists" => true, "current" => "next", "owner_state" => "unknown", "partial" => true)
      end
    end

    it "is null with a spine_unavailable warning when the notes directory can't be worked out" do
      notes_dirs["app"] = Workspace::Error.new("no notes dir", code: "notes_dir_unresolved")
      snapshot.call

      expect(member_row(parsed, "app")["spine"]).to be_nil
      expect(parsed["warnings"]).to include(a_hash_including("code" => "spine_unavailable", "workspace" => "app"))
    end
  end
end
