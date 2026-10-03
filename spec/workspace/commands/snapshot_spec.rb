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
    Class.new do
      define_method(:for_project) do |project, **|
        members = project.members.map do |m|
          {"workspace" => m.workspace, "path" => m.path, "kind" => m.kind, "configured" => true, "exists" => true, "running" => false,
           "headless" => false, "open_asks" => 0, "pipeline" => {"entries" => 2}, "agents" => nil}
        end
        {members: members, locks: {"edit" => {"holder" => {"workspace" => "app", "path" => "/src/app", "pid" => 9, "stale" => false}, "queue" => []}},
         dev: {"running" => true, "ready" => true, "holder_workspace" => "app"}, errors: {}}
      end
      define_method(:git_facts) { |_project, members, deadline:| members.map { |m| git_table[m.path] } }
      define_method(:git_deadline) { 0.0 }
    end.new
  end
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

  let(:git) do
    Class.new { define_method(:base_ref) { |path| (path == "/src/other") ? raise(Workspace::Error, "no base") : "origin/main" } }.new
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

  subject(:snapshot) do
    described_class.new(catalog: catalog, facts: facts, tmux: tmux, state: state, config: config, snapshot_client: snapshot_client,
      sessions: sessions, git: git, pull_request_status: pull_request_status, ask_store_for: ask_store_for, output: output,
      error_output: error_output, clock: clock)
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
        "state_since" => "2026-10-02T20:00:00Z", "stop_reason" => nil, "waiting_message" => "Allow Bash?", "context_pct" => 71,
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

    it "never includes an actions map" do
      expect(output.string).not_to include("\"actions\"")
    end
  end

  describe "git" do
    before { snapshot.call }

    it "reports branch, base, change counts, ahead and upstream" do
      expect(member_row(parsed, "app.worktree-fix")["git"]).to eq(
        "available" => true, "branch" => "fix", "changed_files" => 3, "ahead" => 2, "upstream" => nil, "unpushed_commits" => 2, "unsaved" => "yes", "base" => "origin/main"
      )
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

      expect(member_row(parsed, "app")["git"]).to include("available" => true, "base" => nil)
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
      expect(member_row(parsed, "app")).not_to have_key("task")
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
end
