require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Review do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  def member(name, kind: "worktree", exists: true, configured: true)
    Workspace::ProjectCatalog::Member.new(workspace: name, path: "/src/#{name}", kind: kind, configured: configured, exists: exists)
  end

  let(:members) { [member("app", kind: "main"), member("app.worktree-fix"), member("app.worktree-new")] }
  let(:project) { Workspace::ProjectCatalog::Project.new(name: "app", id: "/src/app/.git", path: "/src/app", vcs: "git", members: members) }

  let(:catalog) do
    proj = project
    Class.new do
      define_method(:all) { [proj] }
      define_method(:find) { |token| (token == "app" || proj.members.any? { |m| m.workspace == token }) ? proj : raise(Workspace::Error.new("Unknown project '#{token}'", code: "unknown_workspace")) }
      define_method(:for_cwd) { |_cwd| proj }
    end.new
  end

  # Canned git answers by checkout path; a missing path reads as git failing.
  let(:git_facts) do
    {
      "/src/app" => {base: "origin/main", ahead: 0, branch: "main", changed: 0, unpushed: 0, stat: [], commits: []},
      "/src/app.worktree-fix" => {base: "origin/main", ahead: 2, branch: "fix", changed: 1, unpushed: 2,
                                  stat: [{"path" => "a.rb", "added" => 5, "removed" => 1}, {"path" => "b.bin", "added" => nil, "removed" => nil}],
                                  commits: [{"sha" => "abc1234", "subject" => "fix it"}, {"sha" => "def5678", "subject" => "start"}]},
      "/src/app.worktree-new" => {base: "origin/main", ahead: 3, branch: "new", changed: 0, unpushed: 3, stat: [], commits: []}
    }
  end
  let(:git) do
    facts = git_facts
    Class.new do
      define_method(:base_ref) { |path| facts.dig(path, :base) }
      define_method(:commits_ahead_of) { |path, _base| facts.dig(path, :ahead) }
      define_method(:worktree_branch) { |path| facts.dig(path, :branch) }
      define_method(:changed_files_count) { |path| facts.dig(path, :changed) }
      define_method(:unpushed_commit_count) { |path| facts.dig(path, :unpushed) }
      define_method(:diff_stat) { |path, _base| facts.dig(path, :stat) }
      define_method(:commits_since) { |path, _base, limit:| facts.dig(path, :commits)&.first(limit) }
    end.new
  end

  def pane(id, state, kind: "claude", **extra)
    {"pane_id" => id, "index" => 0, "kind" => kind, "state" => state, "state_since" => "2026-10-02T10:00:00Z"}.merge(extra)
  end

  let(:snapshots) do
    {
      "app" => {"panes" => [pane("%1", "working")]},
      "app.worktree-fix" => {"panes" => [pane("%2", "done", "stop_reason" => "end_turn"), pane("%3", "idle", kind: "shell")]},
      "app.worktree-new" => Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :no_daemon)
    }
  end
  let(:snapshot_client) do
    table = snapshots
    Class.new do
      define_method(:fetch) do |name, timeout: nil|
        reply = table.fetch(name)
        raise reply if reply.is_a?(Exception)
        reply
      end
    end.new
  end

  let(:tasks) { {"app.worktree-fix" => {"id" => "t1", "title" => "Fix login", "ref" => "JIRA-1", "created_at" => "2026-10-02T09:00:00Z"}} }
  let(:task_store) do
    table = tasks
    Class.new { define_method(:active_for) { |name| table[name] } }.new
  end

  let(:config) do
    dir = tmpdir
    Class.new { define_method(:ask_state_path) { |name| File.join(dir, name, "asks.json") } }.new
  end
  let(:ask_store_for) { ->(workspace) { Workspace::AskStore.new(path: config.ask_state_path(workspace), error_output: error_output) } }
  let(:session_ledger) { Workspace::SessionLedger.new(path: File.join(tmpdir, "ledger.jsonl"), logger: Workspace::Logger.new) }
  let(:pull_request) { {"available" => true, "found" => true, "number" => 7, "state" => "OPEN", "draft" => false, "url" => "https://x/7", "checks" => {"passing" => 2, "failing" => 0, "pending" => 1, "total" => 3, "failed" => []}} }
  let(:pull_request_calls) { [] }
  let(:pull_request_status) do
    result = pull_request
    calls = pull_request_calls
    Class.new { define_method(:call) { |path| calls << path && result } }.new
  end

  subject(:review) do
    described_class.new(catalog: catalog, git: git, snapshot_client: snapshot_client, task_store: task_store, ask_store_for: ask_store_for,
      session_ledger: session_ledger, transcript_summary: Workspace::TranscriptSummary.new, pull_request_status: pull_request_status,
      output: output, error_output: error_output, git_timeout: 2)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def parsed = JSON.parse(output.string)

  def write_transcript(name, *texts)
    File.join(tmpdir, name).tap do |path|
      File.write(path, texts.map { |t| JSON.generate("type" => "assistant", "message" => {"role" => "assistant", "content" => [{"type" => "text", "text" => t}]}, "timestamp" => "2026-10-02T10:30:00Z") }.join("\n") + "\n")
    end
  end

  def add_ask(workspace, question, default, answered: false)
    store = Workspace::AskStore.new(path: config.ask_state_path(workspace))
    record = store.add(question: question, default: default, pane: "%2")
    store.answer(record["id"], "yes") if answered
  end

  describe "#show" do
    it "builds the packet for a ready workspace" do
      result = review.show(name: "app.worktree-fix", json: true)

      expect(result).to eq(exit_code: 0)
      expect(parsed).to include(
        "schema_version" => 1, "ok" => true, "workspace" => "app.worktree-fix", "path" => "/src/app.worktree-fix", "kind" => "worktree", "ready" => true,
        "task" => {"id" => "t1", "title" => "Fix login", "ref" => "JIRA-1", "created_at" => "2026-10-02T09:00:00Z"}
      )
      expect(parsed["agent"]).to include("available" => true, "state" => "done", "stop_reason" => "end_turn", "done_pane_id" => "%2")
      expect(parsed["agent"]["panes"].map { |p| p["pane_id"] }).to eq(["%2"])
      expect(parsed["git"]).to include("available" => true, "branch" => "fix", "base" => "origin/main", "ahead" => 2, "changed_files" => 1, "unpushed_commits" => 2)
      expect(parsed["git"]["diffstat"]).to eq("files" => 2, "added" => 5, "removed" => 1, "truncated" => false,
        "entries" => [{"path" => "a.rb", "added" => 5, "removed" => 1}, {"path" => "b.bin", "added" => nil, "removed" => nil}])
      expect(parsed["git"]["commits"].map { |c| c["subject"] }).to eq(["fix it", "start"])
      expect(parsed["pull_request"]).to include("found" => true, "number" => 7)
      expect(pull_request_calls).to eq(["/src/app.worktree-fix"])
    end

    it "is not ready when the agent is still working" do
      git_facts["/src/app"][:ahead] = 4

      expect(review.show(name: "app", json: true)).to eq(exit_code: 0)
      expect(parsed).to include("ready" => false)
      expect(parsed["agent"]["state"]).to eq("working")
    end

    it "is not ready when the branch is not ahead of its base" do
      git_facts["/src/app.worktree-fix"][:ahead] = 0

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["ready"]).to be(false)
    end

    it "puts waiting before working before done" do
      snapshots["app.worktree-fix"] = {"panes" => [pane("%2", "done"), pane("%4", "waiting"), pane("%5", "working")]}

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["agent"]).to include("state" => "waiting", "stop_reason" => nil, "state_since" => nil)
    end

    it "reports a workspace with no agent pane as having no state" do
      snapshots["app.worktree-fix"] = {"panes" => [pane("%3", "idle", kind: "shell")]}

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["agent"]).to include("available" => true, "state" => nil, "panes" => [])
      expect(parsed["ready"]).to be(false)
    end

    it "reports an agent daemon that isn't answering as unavailable, not idle" do
      review.show(name: "app.worktree-new", json: true)

      expect(parsed["agent"]).to eq("available" => false, "reason" => "no_daemon")
      expect(parsed["ready"]).to be(false)
    end

    it "cuts a long daemon error detail" do
      snapshots["app.worktree-new"] = Workspace::Error.new("e" * 900)

      review.show(name: "app.worktree-new", json: true)

      expect(parsed["agent"]["detail"].length).to eq(500)
    end

    it "reports a daemon error with its first message line" do
      snapshots["app.worktree-new"] = Workspace::Error.new("bad reply\nmore")

      review.show(name: "app.worktree-new", json: true)

      expect(parsed["agent"]).to eq("available" => false, "reason" => "error", "detail" => "bad reply")
    end

    it "caps the files and commits listed but counts them all" do
      stat = Array.new(250) { |i| {"path" => "f#{i}", "added" => 1, "removed" => 0} }
      git_facts["/src/app.worktree-fix"][:stat] = stat
      git_facts["/src/app.worktree-fix"][:commits] = Array.new(80) { |i| {"sha" => "s#{i}", "subject" => "c#{i}"} }

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["git"]["diffstat"]).to include("files" => 250, "added" => 250, "truncated" => true)
      expect(parsed["git"]["diffstat"]["entries"].size).to eq(200)
      expect(parsed["git"]["commits"].size).to eq(50)
    end

    it "reports no base branch as git unavailable" do
      git_facts["/src/app.worktree-fix"][:base] = nil

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["git"]).to eq("available" => false, "reason" => "no_base")
      expect(parsed["ready"]).to be(false)
    end

    it "reports git failing to count changed files or unpushed commits as unavailable, never as clean" do
      git_facts["/src/app.worktree-fix"][:changed] = nil
      review.show(name: "app.worktree-fix", json: true)
      expect(parsed["git"]).to eq("available" => false, "reason" => "error")

      git_facts["/src/app.worktree-fix"][:changed] = 0
      git_facts["/src/app.worktree-fix"][:unpushed] = nil
      output.truncate(0)
      output.rewind
      review.list(json: true)
      expect(parsed["unavailable"]).to eq([{"workspace" => "app.worktree-fix", "reason" => "error"}])
    end

    it "reports git failing to count commits as unavailable, never as zero ahead" do
      git_facts["/src/app.worktree-fix"][:ahead] = nil

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["git"]).to eq("available" => false, "reason" => "error")
    end

    it "reports git that outlives the time limit as unavailable" do
      slow = git
      allow(slow).to receive(:base_ref) { sleep 5 }
      subject = described_class.new(catalog: catalog, git: slow, snapshot_client: snapshot_client, task_store: task_store, ask_store_for: ask_store_for,
        session_ledger: session_ledger, transcript_summary: Workspace::TranscriptSummary.new, pull_request_status: pull_request_status,
        output: output, error_output: error_output, git_timeout: 0.2)

      subject.show(name: "app.worktree-fix", json: true)

      expect(parsed["git"]).to eq("available" => false, "reason" => "timeout")
    end

    it "unwinds a git read that outlives the limit, so Git stops its process group" do
      unwound = Queue.new
      slow = git
      allow(slow).to receive(:base_ref) do
        sleep 5
      ensure
        unwound << :unwound
      end
      subject = described_class.new(catalog: catalog, git: slow, snapshot_client: snapshot_client, task_store: task_store, ask_store_for: ask_store_for,
        session_ledger: session_ledger, transcript_summary: Workspace::TranscriptSummary.new, pull_request_status: pull_request_status,
        output: output, error_output: error_output, git_timeout: 0.2)

      subject.show(name: "app.worktree-fix", json: true)

      expect(Timeout.timeout(2) { unwound.pop }).to eq(:unwound)
    end

    it "does not raise on a malformed task or ledger time" do
      tasks["app.worktree-fix"] = tasks["app.worktree-fix"].merge("created_at" => "not a time")
      session_ledger.record("event" => "session_start", "workspace" => "app.worktree-fix", "session_id" => "s1", "at" => "garbage",
        "transcript_path" => write_transcript("t.jsonl", "report"))

      expect(review.show(name: "app.worktree-fix", json: true)).to eq(exit_code: 0)
      expect(parsed["sessions"]).to eq("count" => 1)
    end

    it "treats a task store failing with a system error as unavailable, not as a crash" do
      allow(task_store).to receive(:active_for).and_raise(Errno::EACCES)

      expect(review.show(name: "app.worktree-fix", json: true)).to eq(exit_code: 0)
      expect(parsed).to include("task" => nil, "task_unavailable" => true)
    end

    it "says in text when the task store or ledger is unreadable" do
      allow(task_store).to receive(:active_for).and_raise(Errno::EACCES)
      path = File.join(tmpdir, "ledger.jsonl")
      File.write(path, "")
      File.chmod(0o000, path)

      review.show(name: "app.worktree-fix")

      expect(output.string).to include("Task    unavailable (task store unreadable)", "Sessions  unavailable (ledger unreadable)")
    ensure
      File.chmod(0o600, path) if path
    end

    it "lists open questions (the defaults the agent took) and counts answered ones" do
      add_ask("app.worktree-fix", "Rename the column?", "no", answered: false)
      add_ask("app.worktree-fix", "Use sqlite?", "yes", answered: true)
      add_ask("app.worktree-fix", "q" * 900, "d" * 900)

      review.show(name: "app.worktree-fix", json: true)

      asks = parsed["asks"]
      expect(asks["answered"]).to eq(1)
      expect(asks["open"].map { |a| a["question"][0, 10] }).to eq(["Rename the", "q" * 10])
      expect(asks["open"].first).to include("default" => "no")
      expect(asks["open"].last["question"].length).to eq(500)
      expect(asks["open"].last["default"].length).to eq(500)
    end

    it "keeps going when the question store is unreadable, and says so" do
      path = config.ask_state_path("app.worktree-fix")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{")

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["asks"]).to include("open" => [], "answered" => 0)
      expect(error_output.string).to include("ignoring question store")
    end

    describe "sessions and the last message" do
      def ledger(event, session, path: nil, at: nil, pane_id: "%2")
        entry = {"event" => event, "workspace" => "app.worktree-fix", "session_id" => session, "pane_id" => pane_id, "transcript_path" => path}.compact
        session_ledger.record(entry)
      end

      it "counts distinct sessions and reads the last assistant message of the done pane's latest session" do
        old = write_transcript("old.jsonl", "old report")
        newer = write_transcript("new.jsonl", "first", "the final report")
        other = write_transcript("other.jsonl", "another pane")
        ledger("session_start", "s1", path: old)
        ledger("session_start", "s2", path: newer)
        ledger("session_start", "s9", path: other, pane_id: "%9")

        review.show(name: "app.worktree-fix", json: true)

        expect(parsed["sessions"]).to eq("count" => 3)
        expect(parsed["last_message"]).to eq("text" => "the final report", "truncated" => false, "at" => "2026-10-02T10:30:00Z", "session_id" => "s2")
      end

      it "falls back to the latest session when the ledger doesn't know the done pane" do
        path = write_transcript("t.jsonl", "report")
        ledger("session_start", "s1", path: path, pane_id: "%77")

        review.show(name: "app.worktree-fix", json: true)

        expect(parsed["last_message"]).to include("text" => "report", "session_id" => "s1")
      end

      it "does not match a ledger entry with no pane id when no pane is done" do
        snapshots["app.worktree-fix"] = {"panes" => [pane("%2", "working")]}
        ledger("session_start", "s1", path: write_transcript("a.jsonl", "from the pane-less entry"), pane_id: nil)
        ledger("session_start", "s2", path: write_transcript("b.jsonl", "latest"), pane_id: "%5")

        review.show(name: "app.worktree-fix", json: true)

        expect(parsed["last_message"]).to include("text" => "latest", "session_id" => "s2")
      end

      it "counts only sessions since the task began" do
        session_ledger.record("event" => "session_start", "workspace" => "app.worktree-fix", "session_id" => "before")
        tasks["app.worktree-fix"] = tasks["app.worktree-fix"].merge("created_at" => (Time.now + 3600).utc.iso8601)

        review.show(name: "app.worktree-fix", json: true)

        expect(parsed["sessions"]).to eq("count" => 0)
        expect(parsed["last_message"]).to be_nil
      end

      it "has no last message when the ledger has nothing or the transcript is gone" do
        review.show(name: "app.worktree-fix", json: true)
        expect(parsed["last_message"]).to be_nil

        ledger("session_start", "s1", path: File.join(tmpdir, "gone.jsonl"))
        output.truncate(0)
        output.rewind
        review.show(name: "app.worktree-fix", json: true)
        expect(parsed["last_message"]).to be_nil
      end

      it "never puts the transcript path in the packet" do
        ledger("session_start", "s1", path: write_transcript("t.jsonl", "report"))

        review.show(name: "app.worktree-fix", json: true)

        expect(output.string).not_to include(tmpdir)
      end
    end

    it "reads the task as null when the workspace has none" do
      review.show(name: "app.worktree-new", json: true)

      expect(parsed["task"]).to be_nil
    end

    it "reports an unknown workspace as a JSON error with its code" do
      result = review.show(name: "nope", json: true)

      expect(result).to eq(exit_code: 1)
      expect(parsed).to include("ok" => false, "code" => "unknown_workspace", "details" => {"name" => "nope"})
    end

    it "raises the same error without --json" do
      expect { review.show(name: "nope") }.to raise_error(Workspace::Error, /Unknown workspace 'nope'/)
    end

    it "refuses a workspace whose checkout is gone, with its own code" do
      members << member("app.worktree-gone", exists: false)

      expect { review.show(name: "app.worktree-gone") }.to raise_error(Workspace::Error, /checkout .* is gone/) { |e| expect(e.code).to eq("checkout_missing") }

      review.show(name: "app.worktree-gone", json: true)
      expect(parsed).to include("code" => "checkout_missing", "details" => {"name" => "app.worktree-gone", "path" => "/src/app.worktree-gone"})
    end

    it "reports git unavailable when the diffstat or commit list can't be read" do
      allow(git).to receive(:diff_stat).and_return(nil)

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["git"]).to eq("available" => false, "reason" => "error")
      expect(parsed["ready"]).to be(false)
    end

    it "marks an unreadable task store instead of reading it as no task" do
      allow(task_store).to receive(:active_for).and_raise(Workspace::Error, "bad task file")

      review.show(name: "app.worktree-fix", json: true)
      expect(parsed).to include("task" => nil, "task_unavailable" => true)

      output.truncate(0)
      output.rewind
      review.list(json: true)
      expect(parsed["reviews"].first).to include("task" => nil, "task_unavailable" => true)
    end

    it "marks an unreadable ledger, without failing the packet" do
      path = File.join(tmpdir, "ledger.jsonl")
      File.write(path, "")
      File.chmod(0o000, path)

      review.show(name: "app.worktree-fix", json: true)

      expect(parsed["sessions"]).to eq("count" => nil, "unavailable" => true)
      expect(parsed["last_message"]).to be_nil
    ensure
      File.chmod(0o600, path) if path
    end

    it "drops terminal control characters from text output but keeps newlines" do
      git_facts["/src/app.worktree-fix"][:branch] = "fix\e[31m"
      session_ledger.record("event" => "session_start", "workspace" => "app.worktree-fix", "session_id" => "s1", "pane_id" => "%2",
        "transcript_path" => write_transcript("t.jsonl", "a\e]0;title\a\nb"))

      review.show(name: "app.worktree-fix")

      expect(output.string).not_to match(/[\e\a]/)
      expect(output.string).to include("  a]0;title", "  b")
    end

    it "reports a malformed --json run as the envelope even when the failure is after parsing" do
      expect(review.list(project: "nope", json: true)).to eq(exit_code: 1)
    end

    it "prints a readable packet" do
      add_ask("app.worktree-fix", "Rename the column?", "no")
      session_ledger.record("event" => "session_start", "workspace" => "app.worktree-fix", "session_id" => "s1", "pane_id" => "%2",
        "transcript_path" => write_transcript("t.jsonl", "line one\nline two"))

      expect(review.show(name: "app.worktree-fix")).to eq(exit_code: 0)

      expect(output.string).to include(
        "Review  app.worktree-fix", "Task    Fix login", "Agent   done (end_turn) since 2026-10-02T10:00:00Z", "Ready   yes",
        "fix is 2 ahead of origin/main, 1 uncommitted, 2 unpushed", "Diff    2 files, +5 -1", "+5     -1     a.rb", "+bin   -bin   b.bin",
        "#7 OPEN  checks: 2 passing, 0 failing, 1 pending  https://x/7", "Asks    1 open, 0 answered", "Rename the column?  (took: no)",
        "Sessions  1", "Last message", "  line one", "  line two"
      )
    end

    it "prints a binary file as bin and keeps the other fields" do
      review.show(name: "app.worktree-fix")

      expect(output.string).to include("+bin   -bin   b.bin")
    end

    it "prints unavailable sources in words" do
      snapshots["app.worktree-fix"] = Workspace::AgentSnapshotClient::Unavailable.new("none", reason: :timeout)
      git_facts["/src/app.worktree-fix"][:base] = nil
      pull_request.replace("available" => false, "reason" => "gh_missing")

      review.show(name: "app.worktree-fix")

      expect(output.string).to include("Agent   unavailable (timeout)", "Branch  unavailable (no_base)", "PR      unavailable (gh_missing)", "Last message  none found")
    end
  end

  describe "#list" do
    it "lists the workspaces whose agent is done and whose branch is ahead" do
      add_ask("app.worktree-fix", "Rename?", "no")

      expect(review.list(json: true)).to eq(exit_code: 0)

      expect(parsed["project"]).to eq("name" => "app", "id" => "/src/app/.git", "path" => "/src/app")
      expect(parsed["reviews"]).to eq([{
        "workspace" => "app.worktree-fix", "path" => "/src/app.worktree-fix", "branch" => "fix", "base" => "origin/main", "ahead" => 2,
        "changed_files" => 1, "agent" => {"state" => "done", "stop_reason" => "end_turn", "state_since" => "2026-10-02T10:00:00Z"},
        "task" => {"id" => "t1", "title" => "Fix login", "ref" => "JIRA-1", "created_at" => "2026-10-02T09:00:00Z"}, "open_asks" => 1
      }])
      expect(parsed["unavailable"]).to eq([])
      expect(parsed["summary"]).to eq("checked" => 3, "ready" => 1, "not_running" => 1, "unavailable" => 0)
    end

    it "does not call gh" do
      review.list(json: true)

      expect(pull_request_calls).to eq([])
    end

    it "leaves out a done workspace that is not ahead of its base" do
      git_facts["/src/app.worktree-fix"][:ahead] = 0

      review.list(json: true)

      expect(parsed["reviews"]).to eq([])
      expect(parsed["summary"]).to include("ready" => 0, "unavailable" => 0)
    end

    it "runs git only for workspaces whose agent is done" do
      calls = []
      allow(git).to receive(:base_ref) { |path| calls << path && "origin/main" }

      review.list(json: true)

      expect(calls).to eq(["/src/app.worktree-fix"])
    end

    it "names a workspace whose daemon timed out instead of reading it as not ready" do
      snapshots["app.worktree-new"] = Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout)

      review.list(json: true)

      expect(parsed["unavailable"]).to eq([{"workspace" => "app.worktree-new", "reason" => "timeout"}])
      expect(parsed["summary"]).to include("not_running" => 0, "unavailable" => 1)
    end

    it "names a done workspace git couldn't answer for" do
      git_facts["/src/app.worktree-fix"][:ahead] = nil

      review.list(json: true)

      expect(parsed["reviews"]).to eq([])
      expect(parsed["unavailable"]).to eq([{"workspace" => "app.worktree-fix", "reason" => "error"}])
    end

    it "passes git's own reason through for a done workspace it couldn't read" do
      git_facts["/src/app.worktree-fix"][:base] = nil

      review.list(json: true)

      expect(parsed["unavailable"]).to eq([{"workspace" => "app.worktree-fix", "reason" => "no_base"}])
    end

    it "gives a row null open_asks and a marker when the question store is unreadable, and counts open ones otherwise" do
      add_ask("app.worktree-fix", "Rename?", "no")
      add_ask("app.worktree-fix", "Again?", "no")
      review.list(json: true)
      expect(parsed["reviews"].first).to include("open_asks" => 2)
      expect(parsed["reviews"].first).not_to have_key("asks_unavailable")

      output.truncate(0)
      output.rewind
      File.chmod(0o000, config.ask_state_path("app.worktree-fix"))
      review.list(json: true)
      expect(parsed["reviews"].first).to include("open_asks" => nil, "asks_unavailable" => true)
    ensure
      File.chmod(0o600, config.ask_state_path("app.worktree-fix"))
    end

    it "raises for an unknown project without --json" do
      expect { review.list(project: "nope") }.to raise_error(Workspace::Error, /Unknown project 'nope'/)
    end

    it "names a workspace whose daemon answered with an error" do
      snapshots["app.worktree-new"] = Workspace::Error.new("bad reply")

      review.list(json: true)

      expect(parsed["unavailable"]).to eq([{"workspace" => "app.worktree-new", "reason" => "error"}])
    end

    it "skips configured members whose checkout is gone and members with no config" do
      members << member("app.worktree-gone", exists: false) << member(nil, configured: false)

      review.list(json: true)

      expect(parsed["summary"]["checked"]).to eq(3)
    end

    it "resolves the project from a name or from the working directory" do
      expect(catalog).to receive(:find).with("app.worktree-fix").and_call_original
      review.list(project: "app.worktree-fix", json: true)

      expect(catalog).to receive(:for_cwd).with("/somewhere").and_call_original
      review.list(cwd: "/somewhere", json: true)
    end

    it "reports an unknown project as a JSON error" do
      expect(review.list(project: "nope", json: true)).to eq(exit_code: 1)
      expect(parsed).to include("ok" => false, "code" => "unknown_workspace")
    end

    it "prints a table, and the unavailable ones on stderr" do
      snapshots["app.worktree-new"] = Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout)

      review.list

      expect(output.string.lines.first).to match(/\AWORKSPACE\s+BRANCH\s+AHEAD\s+ASKS\s+TASK\Z/)
      expect(output.string.lines.last).to match(/\Aapp\.worktree-fix\s+fix\s+2\s+0\s+Fix login\Z/)
      expect(error_output.string).to eq("workspace review: could not check app.worktree-new (timeout)\n")
    end

    it "drops control characters from the notes on stderr" do
      members << member("app.worktree-\e[2Jx")
      snapshots["app.worktree-\e[2Jx"] = Workspace::AgentSnapshotClient::Unavailable.new("slow", reason: :timeout)

      review.list

      expect(error_output.string).to include("could not check app.worktree-[2Jx (timeout)")
      expect(error_output.string).not_to include("\e")
    end

    it "says plainly when nothing is ready" do
      git_facts["/src/app.worktree-fix"][:ahead] = 0

      review.list

      expect(output.string).to eq("Nothing ready for review in app.\n")
    end
  end
end
