require "tmpdir"
require "socket"

RSpec.describe Workspace::Commands::Sessions do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config) }
  let(:socket_path) { File.join(tmpdir, "agent.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }

  let(:payload) do
    {
      "workspace" => "proj",
      "updated_at" => "2026-09-26T12:00:00Z",
      "panes" => [
        {"pane_id" => "%1", "index" => 0, "kind" => "claude", "label" => "Claude Code",
         "state" => "working", "idle_seconds" => 0,
         "agents" => [{"name" => "eval-baseline", "state" => "running"}]},
        {"pane_id" => "%2", "index" => 1, "kind" => "shell", "label" => "zsh",
         "state" => "idle", "idle_seconds" => 192, "agents" => []}
      ]
    }
  end

  subject(:command) do
    described_class.new(config: config, output: output, error_output: error_output)
  end

  before do
    allow(config).to receive(:agent_socket_path).with("proj").and_return(socket_path)
    allow(config).to receive(:ask_state_path).with("proj").and_return(File.join(tmpdir, "asks.json"))
  end

  after { FileUtils.remove_entry(tmpdir) }

  # Stands in for the agent daemon: answers one request with the payload.
  def with_daemon(reply: payload)
    server = UNIXServer.new(socket_path)
    received = nil
    listener = Thread.new do
      client = server.accept
      received = JSON.parse(client.gets)
      client.puts(JSON.generate(reply)) if reply
      client.close
    end
    yield
    listener.join(2)
    received
  ensure
    server&.close
  end

  describe "#call" do
    it "asks the daemon for its sessions" do
      request = with_daemon { command.call(name: "proj") }

      expect(request).to eq("type" => "sessions", "workspace" => "proj")
    end

    it "renders a table with a row per pane and its sub-agents" do
      with_daemon { command.call(name: "proj") }

      expect(output.string).to include("workspace: proj")
      expect(output.string).to match(/0\.0\s+claude\s+Claude Code\s+working/)
      expect(output.string).to match(/0\.1\s+shell\s+zsh\s+idle\s+3m12s/)
      expect(output.string).to include("└─ eval-baseline")
    end

    it "emits the payload with a leading schema_version with --json" do
      with_daemon { command.call(name: "proj", json: true) }

      expected = payload.merge("panes" => payload["panes"].map { |pane| pane.merge("open_questions" => 0) })
      expect(JSON.parse(output.string)).to eq({"schema_version" => 1, "ok" => true}.merge(expected))
    end

    it "puts schema_version as the first key of the --json payload" do
      with_daemon { command.call(name: "proj", json: true) }

      expect(JSON.parse(output.string).keys.first).to eq("schema_version")
    end

    it "returns exit_code 0 on success" do
      result = nil
      with_daemon { result = command.call(name: "proj") }

      expect(result).to eq({exit_code: 0})
    end

    it "writes a schema_version error to stdout and returns exit_code 1 when --json and no daemon is listening" do
      result = command.call(name: "proj", json: true)

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => false, "code" => "no_daemon",
        "error" => "No agent daemon for 'proj'.\nStart one with:  workspace agentd proj"
      )
      expect(result).to eq({exit_code: 1})
    end

    it "shows a waiting pane with the agent's message on the line below" do
      waiting = {"workspace" => "proj", "panes" => [
        {"pane_id" => "%1", "index" => 0, "kind" => "claude", "label" => "Claude Code",
         "state" => "waiting", "idle_seconds" => 40, "waiting_since" => "2026-09-26T12:00:00Z",
         "waiting_seconds" => 40, "waiting_message" => "Claude needs your\npermission to use Bash\e[2J", "agents" => []}
      ]}
      with_daemon(reply: waiting) { command.call(name: "proj") }

      expect(output.string).to match(/0\.0\s+claude\s+Claude Code\s+waiting\s+40s/)
      expect(output.string).to include("└─ Claude needs your permission to use Bash [2J")
      expect(output.string).not_to include("\e")
    end

    it "cleans the waiting message in --json too, even from a daemon that didn't" do
      waiting = {"workspace" => "proj", "panes" => [
        {"pane_id" => "%1", "index" => 0, "state" => "waiting", "waiting_message" => "needs your\n\e[31mpermission", "agents" => []}
      ]}
      with_daemon(reply: waiting) { command.call(name: "proj", json: true) }

      expect(JSON.parse(output.string)["panes"].first["waiting_message"]).to eq("needs your [31mpermission")
    end

    it "says so when the workspace has no panes" do
      with_daemon(reply: {"workspace" => "proj", "panes" => []}) { command.call(name: "proj") }

      expect(output.string).to include("no panes")
    end

    it "tells the user how to start a daemon when none is listening" do
      expect { command.call(name: "proj") }
        .to raise_error(Workspace::Error, /No agent daemon for 'proj'.*workspace agentd proj/m)
    end

    it "reports a daemon that closes without answering" do
      expect {
        with_daemon(reply: nil) { command.call(name: "proj") }
      }.to raise_error(Workspace::Error, /closed the connection/)
    end

    context "when the daemon accepts but never answers" do
      let(:quick_client) { Workspace::AgentSnapshotClient.new(config: config, timeout: 0.03) }
      let(:command) { described_class.new(config: config, snapshot_client: quick_client, output: output, error_output: error_output) }

      def with_hung_daemon
        server = UNIXServer.new(socket_path)
        listener = Thread.new do
          conn = server.accept
          conn.gets
          sleep 0.1
          conn.close
        end
        yield
        listener.join(2)
      ensure
        server&.close
      end

      it "gives up after the read timeout with an error instead of blocking" do
        expect {
          with_hung_daemon { command.call(name: "proj") }
        }.to raise_error(Workspace::Error, /did not answer within 0.03s/)
      end

      it "writes the timeout as a schema_version error with --json" do
        result = nil
        with_hung_daemon { result = command.call(name: "proj", json: true) }

        expect(result).to eq(exit_code: 1)
        expect(JSON.parse(output.string)).to eq("schema_version" => 1, "ok" => false, "code" => "no_daemon", "error" => "Agent daemon for 'proj' did not answer within 0.03s.")
      end
    end

    def with_raw_daemon(raw_reply)
      server = UNIXServer.new(socket_path)
      listener = Thread.new do
        client = server.accept
        client.gets
        client.puts(raw_reply)
        client.close
      end
      yield
      listener.join(2)
    ensure
      server&.close
    end

    it "raises a clear error when the daemon sends a malformed reply" do
      expect {
        with_raw_daemon("not json") { command.call(name: "proj") }
      }.to raise_error(Workspace::Error, /malformed reply from session monitor/i)
    end

    it "writes a schema_version error to stdout for a malformed reply with --json" do
      result = nil
      with_raw_daemon("not json") { result = command.call(name: "proj", json: true) }

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => false, "code" => "error",
        "error" => "Malformed reply from session monitor for 'proj'."
      )
      expect(result).to eq({exit_code: 1})
    end

    it "stops --watch and reports a schema_version error on a malformed reply" do
      watcher = described_class.new(config: config, output: output, error_output: error_output)

      with_raw_daemon("not json") { watcher.call(name: "proj", watch: true, json: true) }

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => false, "code" => "error",
        "error" => "Malformed reply from session monitor for 'proj'."
      )
    end

    it "keeps the command's own schema_version even if the daemon supplies one" do
      with_daemon(reply: payload.merge("schema_version" => 999)) { command.call(name: "proj", json: true) }

      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(1)
      expect(parsed.keys.first).to eq("schema_version")
    end
  end

  describe "lock column" do
    let(:lock_dir) { File.join(tmpdir, "locks") }
    let(:lock_namespace) { instance_double(Workspace::LockNamespace, resolve: {key: "ns", display: "app", dir: lock_dir}) }
    let(:lock_holder) { FakeLockLiveness.new }
    let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: "/projects/proj") }
    let(:command) do
      described_class.new(config: config, lock_namespace: lock_namespace, lock_holder: lock_holder,
        project_config: project_config, output: output, error_output: error_output)
    end

    def acquire(pid:, pane:, wait: false)
      store = Workspace::LockStore.new(dir: lock_dir, liveness: lock_holder)
      identity = {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
      store.acquire("edit", identity: identity, waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
    end

    it "marks the holder's pane and a waiter's pane, leaving the rest blank" do
      acquire(pid: 100, pane: "%1")
      acquire(pid: 200, pane: "%2", wait: true)

      with_daemon { command.call(name: "proj") }

      expect(output.string).to match(/0\.0\s+claude\s+Claude Code\s+working\s+\S*\s*edit ✓/)
      expect(output.string).to match(/0\.1\s+shell\s+zsh\s+idle\s+\S+\s+edit #1/)
    end

    it "loads the lock store exactly once per render, not once per pane" do
      acquire(pid: 100, pane: "%1")
      call_count = 0
      dir = lock_dir
      counting_namespace = Object.new
      counting_namespace.define_singleton_method(:resolve) do |cwd:|
        call_count += 1
        {key: "ns", display: "app", dir: dir}
      end
      command = described_class.new(config: config, lock_namespace: counting_namespace, lock_holder: lock_holder,
        project_config: project_config, output: output, error_output: error_output)

      with_daemon { command.call(name: "proj") }

      expect(call_count).to eq(1)
    end

    it "leaves every pane blank when the lock is free" do
      with_daemon { command.call(name: "proj") }

      expect(output.string).not_to include("edit")
    end

    it "stamps the lock field on each pane in --json too" do
      acquire(pid: 100, pane: "%1")

      with_daemon { command.call(name: "proj", json: true) }

      panes = JSON.parse(output.string)["panes"]
      expect(panes.find { |p| p["pane_id"] == "%1" }["lock"]).to eq("edit ✓")
      expect(panes.find { |p| p["pane_id"] == "%2" }["lock"]).to eq("")
    end

    it "stamps structured lock fields for the holder's pane" do
      acquire(pid: 100, pane: "%1")

      with_daemon { command.call(name: "proj", json: true) }

      pane = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%1" }
      expect(pane["lock_state"]).to eq("held")
      expect(pane["lock_position"]).to be_nil
      expect(pane["lock_name"]).to eq("edit")
    end

    it "stamps structured lock fields for a queued waiter's pane" do
      acquire(pid: 100, pane: "%1")
      acquire(pid: 200, pane: "%2", wait: true)

      with_daemon { command.call(name: "proj", json: true) }

      pane = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%2" }
      expect(pane["lock_state"]).to eq("queued")
      expect(pane["lock_position"]).to eq(1)
      expect(pane["lock_name"]).to eq("edit")
    end

    it "stamps nil structured lock fields for a pane holding no lock" do
      acquire(pid: 100, pane: "%1")

      with_daemon { command.call(name: "proj", json: true) }

      pane = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%2" }
      expect(pane["lock_state"]).to be_nil
      expect(pane["lock_position"]).to be_nil
      expect(pane["lock_name"]).to be_nil
    end

    it "leaves the structured lock fields absent when the column is hidden" do
      acquire(pid: 100, pane: "%1")
      allow(project_config).to receive(:project_root_for).with("proj").and_return(nil)

      with_daemon { command.call(name: "proj", json: true) }

      pane = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%1" }
      expect(pane).not_to have_key("lock_state")
      expect(pane).not_to have_key("lock_position")
      expect(pane).not_to have_key("lock_name")
      expect(pane).not_to have_key("lock")
    end

    it "skips a stale holder and numbers the queue over live waiters only" do
      acquire(pid: 100, pane: "%1")
      acquire(pid: 200, pane: "%2", wait: true)
      lock_holder.kill(100)

      with_daemon { command.call(name: "proj") }

      expect(output.string).not_to match(/0\.0.*edit ✓/)
      expect(output.string).to match(/0\.1\s+shell\s+zsh\s+idle\s+\S+\s+edit #1/)
    end

    it "hides the column when the workspace's project root can't be resolved" do
      acquire(pid: 100, pane: "%1")
      allow(project_config).to receive(:project_root_for).with("proj").and_return(nil)

      with_daemon { command.call(name: "proj") }

      expect(output.string).not_to include("edit")
    end

    def acquire_lock(name, pid:, pane:, wait: false)
      store = Workspace::LockStore.new(dir: lock_dir, liveness: lock_holder)
      identity = {kind: "agent", pid: pid, started: "start-#{pid}", pane: pane, worktree: "app"}
      store.acquire(name, identity: identity, waiter_pid: pid, waiter_started: "start-#{pid}", wait: wait)
    end

    it "shows every lock a pane holds or waits on, edit first then alphabetical" do
      acquire_lock("devenv", pid: 300, pane: "%1")
      acquire(pid: 100, pane: "%1")

      with_daemon { command.call(name: "proj") }

      expect(output.string).to match(/0\.0.*edit ✓ devenv ✓/)
    end

    it "includes a locks array with every lock the pane is party to, in --json" do
      acquire_lock("devenv", pid: 300, pane: "%2")
      acquire_lock("devenv", pid: 301, pane: "%1", wait: true)
      acquire(pid: 100, pane: "%1")

      with_daemon { command.call(name: "proj", json: true) }

      pane1 = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%1" }
      expect(pane1["locks"]).to eq(
        [{"name" => "edit", "state" => "held", "position" => nil},
          {"name" => "devenv", "state" => "queued", "position" => 1}]
      )
    end

    it "falls back to the pane's first lock for the legacy fields when it doesn't hold edit" do
      acquire_lock("devenv", pid: 300, pane: "%2")

      with_daemon { command.call(name: "proj", json: true) }

      pane2 = JSON.parse(output.string)["panes"].find { |p| p["pane_id"] == "%2" }
      expect(pane2["lock_name"]).to eq("devenv")
      expect(pane2["lock_state"]).to eq("held")
    end
  end

  describe "ask column" do
    let(:ask_path) { File.join(tmpdir, "asks.json") }

    before { allow(config).to receive(:ask_state_path).with("proj").and_return(ask_path) }

    it "counts a pane's open questions and leaves panes with none blank" do
      Workspace::AskStore.new(path: ask_path).add(question: "q1", default: "d1", pane: "%1")

      with_daemon { command.call(name: "proj") }

      expect(output.string).to match(/0\.0\s+claude\s+Claude Code\s+working.*1 asked/)
      expect(output.string).not_to match(/0\.1.*asked/)
    end

    it "counts more than one open question for the same pane" do
      store = Workspace::AskStore.new(path: ask_path)
      store.add(question: "q1", default: "d1", pane: "%1")
      store.add(question: "q2", default: "d2", pane: "%1")

      with_daemon { command.call(name: "proj") }

      expect(output.string).to match(/0\.0.*2 asked/)
    end

    it "does not count an answered question" do
      store = Workspace::AskStore.new(path: ask_path)
      record = store.add(question: "q1", default: "d1", pane: "%1")
      store.answer(record["id"], "resolved")

      with_daemon { command.call(name: "proj") }

      expect(output.string).not_to match(/asked/)
    end

    it "includes open_questions per pane in --json" do
      Workspace::AskStore.new(path: ask_path).add(question: "q1", default: "d1", pane: "%1")

      with_daemon { command.call(name: "proj", json: true) }

      panes = JSON.parse(output.string)["panes"]
      expect(panes.find { |p| p["pane_id"] == "%1" }["open_questions"]).to eq(1)
      expect(panes.find { |p| p["pane_id"] == "%2" }["open_questions"]).to eq(0)
    end

    it "still lists sessions, with a warning, when asks.json is unparseable" do
      File.write(ask_path, "not json")

      with_daemon { command.call(name: "proj", json: true) }

      panes = JSON.parse(output.string)["panes"]
      expect(panes.map { |p| p["open_questions"] }).to eq([0, 0])
      expect(error_output.string).to include("ignoring question store")
    end

    it "still lists sessions when asks.json holds entries that aren't objects" do
      File.write(ask_path, JSON.generate([nil, {"id" => "abc123", "status" => "open", "pane" => "%1"}]))

      with_daemon { command.call(name: "proj") }

      expect(output.string).to match(/0\.0.*1 asked/)
    end

    it "leaves the ASK counts off, with a warning, when the store can't be read at all" do
      FileUtils.mkdir_p(ask_path)

      with_daemon { command.call(name: "proj", json: true) }

      panes = JSON.parse(output.string)["panes"]
      expect(panes).to all(satisfy { |p| !p.key?("open_questions") })
      expect(error_output.string).to include("workspace sessions: not showing open questions")
    end
  end

  describe "--worktrees" do
    let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: %w[proj proj.worktree-a proj.worktree-b proj.staging proj-bar other]) }
    let(:command) do
      described_class.new(config: config, project_config: project_config, output: output, error_output: error_output)
    end
    let(:sockets) { {} }

    before do
      allow(config).to receive(:agent_socket_path) { |name| sockets[name] ||= File.join(tmpdir, "#{name}.sock") }
      allow(config).to receive(:ask_state_path) { |name| File.join(tmpdir, "#{name}-asks.json") }
    end

    # Stands in for the agent daemon for a specific member workspace, unless
    # `up` is false, in which case no daemon listens at all (simulating a
    # workspace with no running agent daemon).
    def with_member_daemons(members)
      servers = members.filter_map { |name, up|
        next unless up
        server = UNIXServer.new(sockets[name] ||= File.join(tmpdir, "#{name}.sock"))
        Thread.new do
          client = server.accept
          client.gets
          client.puts(JSON.generate(payload.merge("workspace" => name)))
          client.close
        end
        server
      }
      yield
    ensure
      servers&.each(&:close)
    end

    it "lists the root plus every child worktree workspace, root first" do
      with_member_daemons("proj" => true, "proj.worktree-a" => true, "proj.worktree-b" => true) do
        command.call(name: "proj", worktrees: true)
      end

      out = output.string
      expect(out.index("workspace: proj\n")).to be < out.index("workspace: proj.worktree-a")
      expect(out.index("workspace: proj.worktree-a")).to be < out.index("workspace: proj.worktree-b")
      expect(out).not_to include("workspace: other")
    end

    it "excludes a non-worktree sibling config and a prefix-sharing project" do
      with_member_daemons("proj" => true, "proj.worktree-a" => true, "proj.staging" => true, "proj-bar" => true) do
        command.call(name: "proj", worktrees: true)
      end

      expect(output.string).not_to include("workspace: proj.staging")
      expect(output.string).not_to include("workspace: proj-bar")
    end

    it "omits a member whose agent daemon isn't running, without erroring" do
      with_member_daemons("proj" => true, "proj.worktree-a" => false, "proj.worktree-b" => true) do
        command.call(name: "proj", worktrees: true)
      end

      expect(output.string).to include("workspace: proj\n")
      expect(output.string).to include("workspace: proj.worktree-b")
      expect(output.string).not_to include("worktree-a")
    end

    it "separates sections with a blank line" do
      with_member_daemons("proj" => true, "proj.worktree-a" => true, "proj.worktree-b" => false) do
        command.call(name: "proj", worktrees: true)
      end

      expect(output.string).to match(/workspace: proj\n.*\n\nworkspace: proj\.worktree-a/m)
    end

    it "resolves a worktree name argument to its parent, so the family is shown either way" do
      with_member_daemons("proj" => true, "proj.worktree-a" => true, "proj.worktree-b" => true) do
        command.call(name: "proj.worktree-a", worktrees: true)
      end

      expect(output.string).to include("workspace: proj\n")
      expect(output.string).to include("workspace: proj.worktree-b")
    end

    it "raises the usual no-daemon error when no member answers" do
      expect {
        with_member_daemons("proj" => false, "proj.worktree-a" => false, "proj.worktree-b" => false) do
          command.call(name: "proj", worktrees: true)
        end
      }.to raise_error(Workspace::Error, /No agent daemon for 'proj'/)
    end

    it "writes the usual schema_version error and exit_code 1 with --json when no member answers" do
      result = nil
      with_member_daemons("proj" => false, "proj.worktree-a" => false, "proj.worktree-b" => false) do
        result = command.call(name: "proj", worktrees: true, json: true)
      end

      expect(JSON.parse(output.string)).to eq(
        "schema_version" => 1, "ok" => false, "code" => "no_daemon",
        "error" => "No agent daemon for 'proj'.\nStart one with:  workspace agentd proj"
      )
      expect(result).to eq({exit_code: 1})
    end

    it "nests each member's payload under a workspaces array in --json" do
      with_member_daemons("proj" => true, "proj.worktree-a" => true, "proj.worktree-b" => false) do
        command.call(name: "proj", worktrees: true, json: true)
      end

      parsed = JSON.parse(output.string)
      expect(parsed["schema_version"]).to eq(1)
      expect(parsed["workspaces"].map { |w| w["workspace"] }).to eq(%w[proj proj.worktree-a])
      expect(parsed["workspaces"]).to all(include("schema_version" => 1))
    end

    it "leaves default (non --worktrees) behavior unchanged" do
      with_member_daemons("proj" => true) { command.call(name: "proj") }

      expect(output.string).to include("workspace: proj")
      expect(output.string).not_to include("workspaces")
    end

    it "propagates a different Workspace::Error from a member instead of swallowing it" do
      server = UNIXServer.new(sockets["proj.worktree-a"] ||= File.join(tmpdir, "proj.worktree-a.sock"))
      listener = Thread.new do
        client = server.accept
        client.gets
        client.puts("not json")
        client.close
      end

      expect {
        with_member_daemons("proj" => true, "proj.worktree-b" => true) do
          command.call(name: "proj", worktrees: true)
        end
      }.to raise_error(Workspace::Error, /Malformed reply/)
      listener.join(2)
    ensure
      server&.close
    end

    it "redraws every member's section across watch ticks" do
      draws = 0
      sleeper = ->(_seconds) {
        draws += 1
        raise Interrupt if draws >= 2
      }
      watcher = described_class.new(config: config, project_config: project_config, output: output,
        error_output: error_output, sleeper: sleeper)

      servers = %w[proj proj.worktree-a].map { |name|
        server = UNIXServer.new(sockets[name] ||= File.join(tmpdir, "#{name}.sock"))
        Thread.new do
          2.times do
            client = server.accept
            client.gets
            client.puts(JSON.generate(payload.merge("workspace" => name)))
            client.close
          end
        end
        server
      }

      watcher.call(name: "proj", watch: true, worktrees: true)

      expect(output.string.scan("workspace: proj\n").size).to eq(2)
      expect(output.string.scan("workspace: proj.worktree-a").size).to eq(2)
    ensure
      servers&.each(&:close)
    end
  end

  describe "--watch" do
    it "redraws on an interval until interrupted" do
      draws = 0
      sleeper = ->(_seconds) {
        draws += 1
        raise Interrupt if draws >= 2
      }
      watcher = described_class.new(config: config, output: output,
        error_output: error_output, sleeper: sleeper)

      server = UNIXServer.new(socket_path)
      listener = Thread.new do
        2.times do
          client = server.accept
          client.gets
          client.puts(JSON.generate(payload))
          client.close
        end
      end
      watcher.call(name: "proj", watch: true)
      listener.join(2)
      server.close

      expect(draws).to eq(2)
      expect(output.string.scan("workspace: proj").size).to eq(2)
      expect(output.string).to include("\e[2J")
    end
  end
end
