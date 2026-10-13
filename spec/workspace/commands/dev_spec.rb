require "spec_helper"
require "tmpdir"
require "timeout"
require "rbconfig"
require "socket"
require "json"

RSpec.describe Workspace::Commands::Dev do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-dev-command")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:main) { File.join(tmpdir, "app") }
  let(:login) { File.join(tmpdir, "app-login") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:spawned) { [] }
  let(:dev_settings) { {"up" => "exec sleep 30", "stop_timeout" => 2, "startup_timeout" => 10} }
  let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
  let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => dev_settings})) }
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:tmux) { FakeDevWindowTmux.new(method(:spawn_wrapper)) }

  let(:wrapper_script) do
    <<~RUBY
      $LOAD_PATH.unshift #{lib_dir.inspect}
      require "workspace"
      lock_dir, settings, wait = ARGV
      ns = Struct.new(:dir) { def resolve(cwd:) = {dir: dir} }.new(lock_dir)
      store = Struct.new(:data) { def load(_name) = data }.new(JSON.parse(settings))
      liveness = Workspace::LockHolder.new
      dev = Workspace::Commands::Dev.new(lock_namespace: ns, lock_holder: liveness, lineage: Workspace::WorkspaceLineage.new,
        dev_config: Workspace::DevConfig.new(project_settings: store),
        dev_runner: Workspace::DevRunner.new(liveness: liveness, env: {"TMUX_PANE" => "%9"}.merge(ENV.to_h.slice("WORKSPACE_DEV_SESSION", "WORKSPACE_DEV_STARTED_BY_PANE")), poll: 0.05),
        terminator: Workspace::ProcessGroupTerminator.new, tmux: nil, executable: "unused")
      begin
        exit dev.run(wait: wait == "1", working_dir: Dir.pwd)[:exit_code]
      rescue Workspace::Error => e
        warn e.message
        exit 1
      end
    RUBY
  end

  def spawn_wrapper(cwd, wait, env = {})
    log = File.join(tmpdir, "wrapper-#{spawned.size}.log")
    pid = Process.spawn({"SKIP_SIMPLECOV" => "1", **env}, RbConfig.ruby, "-e", wrapper_script, lock_dir,
      JSON.generate("dev" => dev_settings), wait ? "1" : "0", chdir: cwd, pgroup: true, in: File::NULL, out: log, err: log)
    Process.detach(pid)
    spawned << pid
    pid
  end

  def git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) or raise "git #{args.join(" ")} failed"
  end

  def dev(**opts)
    defaults = {lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
                lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: nil,
                terminator: Workspace::ProcessGroupTerminator.new(poll_interval: 0.05), tmux: tmux, executable: "/ws/bin/workspace",
                output: output, error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 0.05}
    described_class.new(**defaults, **opts)
  end

  def holder
    Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new).status("devenv").dig("devenv", "holder")
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    result
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  around do |example|
    Timeout.timeout(40) { example.run }
  end

  before do
    git("init", "-q", "-b", "main", main)
    git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
    git("-C", main, "worktree", "add", "-q", "-b", "feat/login", login)
  end

  after do
    spawned.each do |pid|
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  describe "#up" do
    it "opens a devenv window running the hidden wrapper and waits for it to hold the lock" do
      result = dev.up(working_dir: login)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Dev environment running for app-login (feat/login) in app:devenv.")
      expect(tmux.windows).to eq([{session: "app", name: "devenv", cwd: login, command: [RbConfig.ruby, "/ws/bin/workspace", "dev", "__run"]}])
      expect(holder).to include("kind" => "process", "pid" => spawned.last, "pgid" => spawned.last, "worktree" => login, "branch" => "feat/login")
    end

    it "is idempotent when this worktree already holds the lock" do
      dev.up(working_dir: login)

      result = dev.up(working_dir: login)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Dev environment is already running for app-login (feat/login).")
      expect(tmux.windows.size).to eq(1)
    end

    it "refuses with the holder's worktree and branch when another worktree holds it" do
      dev.up(working_dir: login)

      result = dev.up(working_dir: main)

      expect(result).to eq(exit_code: 1)
      expect(error_output.string).to include("Dev environment is running for app-login (feat/login). Use --wait to queue or --force (formerly --takeover) to switch.")
      expect(tmux.windows.size).to eq(1)
    end

    it "takes over: stops the other worktree's env before starting its own" do
      dev.up(working_dir: login)
      first = spawned.last

      result = dev.up(takeover: true, working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Taking over: stopping dev environment for app-login (feat/login)...")
      expect(alive?(first)).to be(false)
      expect(holder).to include("pid" => spawned.last, "worktree" => main, "branch" => "main")
    end

    it "queues with --wait and starts once the holder stops" do
      dev.up(working_dir: login)
      stopper = Thread.new do
        wait_until { output.string.include?("Trying to obtain workspace devenv lock") }
        dev(output: StringIO.new).down(working_dir: login)
      end

      result = dev.up(wait: true, working_dir: main)
      stopper.join

      expect(result).to eq(exit_code: 0)
      expect(tmux.windows.last[:command]).to end_with("__run", "--wait")
      expect(holder).to include("pid" => spawned.last, "worktree" => main)
    end

    it "exits 75 and withdraws the queued wrapper when --max-wait passes" do
      dev.up(working_dir: login)

      # Generous deadline: the wrapper is a real subprocess whose Ruby boot must
      # register it in the lock queue before the deadline, or the wait reads as
      # a failure (exit 1) instead of still-queued (exit 75). 0.5s flaked under
      # suite load.
      result = dev.up(wait: true, max_wait: 3, working_dir: main)

      expect(result).to eq(exit_code: 75)
      wait_until { !alive?(spawned.last) }
      expect(Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new).status("devenv").dig("devenv", "queue")).to be_empty
    end

    context "with a ready check" do
      it "waits until the ready port accepts connections" do
        port = free_port
        dev_settings.merge!("up" => %(exec #{RbConfig.ruby} -rsocket -e 'sleep 0.3; s = TCPServer.new("127.0.0.1", #{port}); loop { s.accept.close }'),
          "ready" => "port:#{port}")

        result = dev.up(working_dir: login)

        expect(result).to eq(exit_code: 0)
        expect { TCPSocket.new("127.0.0.1", port).close }.not_to raise_error
      end

      it "exits 6, stops the env, and releases the lock when the check times out" do
        dev_settings["ready"] = "port:#{free_port}"
        dev_settings["ready_timeout"] = 0.5

        result = dev.up(working_dir: login)

        expect(result).to eq(exit_code: 6)
        expect(error_output.string).to include("did not pass within")
        expect(alive?(spawned.last)).to be(false)
        expect(holder).to be_nil
      end

      it "skips the check with ready: false" do
        dev_settings["ready"] = "false"

        expect(dev.up(ready: false, working_dir: login)).to eq(exit_code: 0)
      end

      it "treats a non-port check as a shell command run in the worktree" do
        dev_settings["ready"] = "test -f ready.txt"
        File.write(File.join(login, "ready.txt"), "")

        expect(dev.up(working_dir: login)).to eq(exit_code: 0)
      end
    end

    it "raises with setup instructions when no dev command is configured" do
      dev_settings.delete("up")

      expect { dev.up(working_dir: login) }.to raise_error(Workspace::Error, 'No dev command configured. Set one with: workspace config set dev.up "<command>"')
    end
  end

  describe "#up with an unparseable project config" do
    it "refuses instead of running with defaults" do
      broken = Struct.new(:x) { def load(_name) = raise(Workspace::ConfigParseError.new("/cfg/app.yml", "bad yaml")) }.new
      broken_dev = dev(dev_config: Workspace::DevConfig.new(project_settings: broken))

      expect { broken_dev.up(working_dir: main) }.to raise_error(Workspace::ConfigParseError)
      expect(spawned).to be_empty
    end
  end

  describe "who started the environment" do
    let(:ledger_path) { File.join(tmpdir, "ledger.jsonl") }
    let(:ledger) { Workspace::SessionLedger.new(path: ledger_path) }

    def start_session(id, pane: "%1", server: "4242")
      ledger.record("event" => "session_start", "session_id" => id, "pane_id" => pane, "tmux_server" => server, "workspace" => "app")
    end

    def end_session(id, reason: "other")
      ledger.record("event" => "session_end", "session_id" => id, "reason" => reason, "workspace" => "app")
    end

    describe "#up" do
      it "records the session and pane of the agent pane it ran from on the holder" do
        start_session("sess-1")

        dev(session_ledger: ledger).up(working_dir: login)

        expect(holder["started_by"]).to eq("session_id" => "sess-1", "pane" => "%1")
      end

      it "follows a /clear to the session that replaced it" do
        start_session("sess-1")
        end_session("sess-1", reason: "clear")
        start_session("sess-2")

        dev(session_ledger: ledger).up(working_dir: login)

        expect(holder.dig("started_by", "session_id")).to eq("sess-2")
      end

      it "records nothing when the pane has no open session, the session ended, or it is another tmux server's" do
        start_session("sess-1")
        end_session("sess-1")
        start_session("sess-9", server: "1111")

        dev(session_ledger: ledger).up(working_dir: login)

        expect(holder).not_to have_key("started_by")
      end

      it "records nothing without a session ledger or outside tmux" do
        start_session("sess-1")
        no_pane = described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
          lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: nil,
          terminator: Workspace::ProcessGroupTerminator.new(poll_interval: 0.05), tmux: tmux, executable: "/ws/bin/workspace",
          output: output, error_output: error_output, env: {}, poll: 0.05, session_ledger: ledger)

        no_pane.up(working_dir: login)

        expect(holder).not_to have_key("started_by")
      end

      it "still starts the environment, with no started_by, when tmux cannot be asked about the pane" do
        start_session("sess-1")
        allow(tmux).to receive(:server_pid_for_pane).and_raise(Errno::ENOENT)

        expect(dev(session_ledger: ledger).up(working_dir: login)).to eq(exit_code: 0)

        expect(holder).not_to have_key("started_by")
      end

      it "keeps started_by on the holder when a queued wrapper is promoted" do
        start_session("sess-1", pane: "%1")
        dev.up(working_dir: main)
        queued = dev(session_ledger: ledger).up(queue: true, working_dir: login)
        expect(queued[:status]).to eq("queued")

        dev.down(working_dir: main)

        wait_until { holder && holder["worktree"] == login }
        expect(holder.dig("started_by", "session_id")).to eq("sess-1")
      end
    end

    describe "#release_for_session" do
      let(:recorded) { [] }
      let(:dev_events) do
        events = recorded
        log = Object.new.tap { |l| l.define_singleton_method(:record) { |type:, project:, data: {}| events << [type, data["reason"]] } }
        Workspace::DevEvents.new(event_log: log, lineage: Workspace::WorkspaceLineage.new)
      end

      before do
        start_session("sess-1")
        dev(session_ledger: ledger).up(working_dir: login)
        @wrapper = spawned.last
      end

      it "stops the environment that session started, and logs dev_stopped with reason down" do
        result = dev(dev_events: dev_events).release_for_session(session_id: "sess-1", working_dir: login)

        expect(result).to eq(exit_code: 0, outcome: "released")
        expect(alive?(@wrapper)).to be(false)
        expect(holder).to be_nil
        expect(recorded).to eq([["dev_stopped", "down"]])
      end

      it "leaves it running for another session" do
        result = dev.release_for_session(session_id: "sess-2", working_dir: login)

        expect(result).to eq(exit_code: 0, outcome: "not_started_by_session")
        expect(alive?(@wrapper)).to be(true)
      end

      it "reports kept, and leaves the lock, when the environment could not be stopped" do
        command = dev
        allow(command).to receive(:down).and_return(exit_code: 1)

        expect(command.release_for_session(session_id: "sess-1", working_dir: login)).to eq(exit_code: 1, outcome: "kept")
        expect(alive?(@wrapper)).to be(true)
      end

      it "leaves it running when the repository cannot be resolved" do
        lineage = instance_double(Workspace::WorkspaceLineage)
        allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no repository")

        result = dev(lineage: lineage).release_for_session(session_id: "sess-1", working_dir: login)

        expect(result).to eq(exit_code: 0, outcome: "unreadable")
        expect(alive?(@wrapper)).to be(true)
      end

      it "leaves it running when the session id is empty" do
        expect(dev.release_for_session(session_id: "", working_dir: login)).to eq(exit_code: 0, outcome: "not_started_by_session")
        expect(alive?(@wrapper)).to be(true)
      end

      it "leaves it running when dev.release_on_session_end is false" do
        off = Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => dev_settings.merge("release_on_session_end" => false)}))

        result = dev(dev_config: off).release_for_session(session_id: "sess-1", working_dir: login)

        expect(result).to eq(exit_code: 0, outcome: "disabled")
        expect(alive?(@wrapper)).to be(true)
        expect(holder).not_to be_nil
      end

      it "leaves it running when the project's config cannot be read" do
        broken = Struct.new(:x) { def load(_name) = raise(Workspace::ConfigParseError.new("/cfg/app.yml", "bad yaml")) }.new

        result = dev(dev_config: Workspace::DevConfig.new(project_settings: broken)).release_for_session(session_id: "sess-1", working_dir: login)

        expect(result).to eq(exit_code: 0, outcome: "unreadable")
        expect(alive?(@wrapper)).to be(true)
      end

      it "does nothing when nothing is running" do
        dev.down(working_dir: login)

        expect(dev.release_for_session(session_id: "sess-1", working_dir: login)).to eq(exit_code: 0, outcome: "not_started_by_session")
      end
    end

    describe "#down_when_held" do
      it "stops the environment this worktree holds" do
        dev.up(working_dir: login)
        wrapper = spawned.last

        result = dev.down_when_held(working_dir: login)

        expect(result).to eq(exit_code: 0, stopped: true)
        expect(alive?(wrapper)).to be(false)
      end

      it "leaves everything running when the lock store cannot be read" do
        dev.up(working_dir: login)
        wrapper = spawned.last
        File.write(File.join(lock_dir, "locks.json"), "{ not json")

        expect(dev.down_when_held(working_dir: login)).to eq(exit_code: 0, stopped: false)
        expect(alive?(wrapper)).to be(true)
      end

      it "leaves another worktree's environment running" do
        dev.up(working_dir: main)
        wrapper = spawned.last

        result = dev.down_when_held(working_dir: login)

        expect(result).to eq(exit_code: 0, stopped: false)
        expect(alive?(wrapper)).to be(true)
      end

      it "leaves a worktree that is only queued in line, and does nothing when nothing runs" do
        expect(dev.down_when_held(working_dir: login)).to eq(exit_code: 0, stopped: false)

        dev.up(working_dir: main)
        dev.up(queue: true, working_dir: login)
        queued = spawned.last

        expect(dev.down_when_held(working_dir: login)).to eq(exit_code: 0, stopped: false)
        expect(alive?(queued)).to be(true)
      end
    end
  end

  describe "#down" do
    it "stops the env from any worktree of the repo and frees the lock" do
      dev.up(working_dir: login)
      wrapper = spawned.last

      result = dev.down(working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(output.string).to include("Stopped dev environment for app-login (feat/login).")
      expect(alive?(wrapper)).to be(false)
      expect(holder).to be_nil
    end

    it "still stops the env, with a warning, when the project config can't be parsed" do
      dev.up(working_dir: login)
      wrapper = spawned.last
      broken = Struct.new(:x) { def load(_name) = raise(Workspace::ConfigParseError.new("/cfg/app.yml", "bad yaml")) }.new
      broken_dev = dev(dev_config: Workspace::DevConfig.new(project_settings: broken))

      result = broken_dev.down(working_dir: main)

      expect(result).to eq(exit_code: 0)
      expect(error_output.string).to include("Cannot parse /cfg/app.yml", "default timeouts")
      expect(alive?(wrapper)).to be(false)
    end

    it "reports nothing to stop" do
      expect(dev.down(working_dir: main)).to eq(exit_code: 0)
      expect(output.string).to eq("No dev environment is running.\n")
    end

    it "reports a SIGKILLed wrapper's orphaned group, and kills it with force" do
      dev.up(working_dir: login)
      wrapper = spawned.last
      Process.kill("KILL", wrapper)
      wait_until { !alive?(wrapper) }
      expect(Workspace::ProcessGroupTerminator.new.running?(wrapper)).to be(true)

      expect(dev.down(working_dir: main)).to eq(exit_code: 1)
      expect(error_output.string).to include("process group #{wrapper} is still running", "workspace dev down --force")

      expect(dev.down(force: true, working_dir: main)).to eq(exit_code: 0)
      expect(output.string).to include("Killed orphaned dev process group #{wrapper}")
      expect(Workspace::ProcessGroupTerminator.new.running?(wrapper)).to be(false)
      expect(holder).to be_nil
    end
  end

  describe "#status" do
    it "shows the holder, branch, pid, pane, uptime and readiness" do
      dev_settings["ready"] = "true"
      dev.up(working_dir: login)
      output.truncate(0)
      output.rewind

      dev.status(working_dir: main)

      expect(output.string).to include("Dev environment: running for app-login (feat/login)")
      expect(output.string).to match(/pid #{spawned.last}, pgid #{spawned.last}, pane %9, up \d+s/)
      expect(output.string).to include("ready: yes (true)")
    end

    it "reports no environment" do
      dev.status(working_dir: main)

      expect(output.string).to eq("No dev environment is running.\n")
    end

    describe "#status_payload" do
      it "returns the --json payload without printing it" do
        payload = dev.status_payload(working_dir: main)

        expect(payload).to eq("schema_version" => 1, "ok" => true, "running" => false, "holder" => nil, "ready" => nil, "queue" => [])
        expect(output.string).to eq("")
      end

      it "matches what `status --json` prints for a running environment" do
        dev_settings["ready"] = "true"
        dev.up(working_dir: login)
        payload = dev.status_payload(working_dir: main)
        output.truncate(0)
        output.rewind
        dev.status(working_dir: main, json: true)

        expect(payload["running"]).to be true
        expect(payload["ready"]).to be true
        expect(JSON.parse(output.string)).to eq(payload)
      end

      it "raises Workspace::Error for a corrupt locks.json" do
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        expect { dev.status_payload(working_dir: main) }.to raise_error(Workspace::Error, /corrupt/)
      end
    end

    describe "--json" do
      it "reports not running for an empty store" do
        dev.status(working_dir: main, json: true)

        expect(JSON.parse(output.string)).to eq(
          "schema_version" => 1, "ok" => true, "running" => false, "holder" => nil, "ready" => nil, "queue" => []
        )
      end

      it "reports the holder and readiness for a running environment" do
        dev_settings["ready"] = "true"
        dev.up(working_dir: login)
        output.truncate(0)
        output.rewind

        dev.status(working_dir: main, json: true)

        payload = JSON.parse(output.string)
        expect(payload["schema_version"]).to eq(1)
        expect(payload["running"]).to be true
        expect(payload["holder"]).to include("pid" => spawned.last, "branch" => "feat/login")
        expect(payload["ready"]).to be true
      end

      it "emits a JSON error object on stdout, exit 1, for a corrupt locks.json" do
        FileUtils.mkdir_p(lock_dir)
        File.write(File.join(lock_dir, "locks.json"), "{not json")

        result = dev.status(working_dir: main, json: true)

        expect(result).to eq(exit_code: 1)
        payload = JSON.parse(output.string)
        expect(payload["schema_version"]).to eq(1)
        expect(payload["error"]).to include("corrupt")
      end
    end
  end

  describe "#run" do
    it "runs the configured command for this worktree through the dev runner" do
      runner = double("dev_runner")
      allow(runner).to receive(:call).and_return(3)

      result = described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
        lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: runner,
        terminator: nil, tmux: nil, executable: "unused", env: {}).run(wait: true, working_dir: login)

      expect(result).to eq(exit_code: 3)
      expect(runner).to have_received(:call).with(store: an_instance_of(Workspace::LockStore), command: "exec sleep 30",
        worktree: login, branch: "feat/login", wait: true, priority: false, delegate_for: nil, project: "app", workspace: nil)
    end

    it "queues ahead of everyone when its window was opened by a takeover" do
      runner = double("dev_runner")
      allow(runner).to receive(:call).and_return(0)

      described_class.new(lock_namespace: lock_namespace, lock_holder: Workspace::LockHolder.new,
        lineage: Workspace::WorkspaceLineage.new, dev_config: dev_config, dev_runner: runner, terminator: nil, tmux: nil,
        executable: "unused", env: {"WORKSPACE_DEV_TAKEOVER" => "1"}).run(wait: true, working_dir: login)

      expect(runner).to have_received(:call).with(hash_including(wait: true, priority: true))
    end
  end
  describe "under a workflow run that holds the devenv lock" do
    let(:bound_run) { instance_double(Workspace::BoundRun, run_id: "wr_1") }
    let(:store) { Workspace::LockStore.new(dir: lock_dir, liveness: Workspace::LockHolder.new) }

    before { store.acquire_run(["devenv"], run: {run_id: "wr_1", step: "implement", worktree: login, pane: "%1"}) }

    it "starts the environment from the run's pane as the run's delegate, and `down` stops it while the run keeps the lock" do
      result = dev(bound_run: bound_run).up(working_dir: login)

      expect(result).to eq(exit_code: 0)
      expect(tmux.windows.last[:command]).to eq([RbConfig.ruby, "/ws/bin/workspace", "dev", "__run"])
      expect(holder).to include("kind" => "run", "run_id" => "wr_1")
      expect(holder["delegate"]).to include("pid" => spawned.last, "pgid" => spawned.last, "worktree" => login, "branch" => "feat/login")
      expect(output.string).to include("Dev environment running for app-login (feat/login) in app:devenv.")

      expect(dev.down(working_dir: main)).to eq(exit_code: 0)

      expect(alive?(spawned.last)).to be(false)
      expect(holder).to include("kind" => "run", "run_id" => "wr_1")
      expect(holder).not_to include("delegate")
      expect(output.string).to include("Stopped dev environment for app-login (feat/login); the devenv lock stays with app-login (run wr_1, step implement).")
    end

    it "leaves the lock naming the running environment when the run releases it, and `down` then frees it" do
      dev(bound_run: bound_run).up(working_dir: login)

      store.release_run("wr_1")

      expect(holder).to include("kind" => "process", "pid" => spawned.last, "worktree" => login)
      expect(dev.down(working_dir: main)).to eq(exit_code: 0)
      expect(alive?(spawned.last)).to be(false)
      expect(holder).to be_nil
    end
  end
end

RSpec.describe Workspace::Commands::Dev, "with fake processes and clock" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("ws-dev-unit")) }
  let(:lock_dir) { File.join(tmpdir, "locks") }
  let(:worktree) { tmpdir }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:settings) { {"up" => "run-dev", "stop_timeout" => 2, "startup_timeout" => 5, "ready_timeout" => 5} }
  let(:liveness) { FakeLockLiveness.new }
  let(:lock_namespace) { Struct.new(:dir) { def resolve(cwd:) = {key: dir, display: "app", dir: dir} }.new(lock_dir) }
  let(:dev_config) { Workspace::DevConfig.new(project_settings: Struct.new(:data) { def load(_name) = data }.new({"dev" => settings})) }
  let(:lineage) { double("lineage", resolve: double(name: "app", worktree: nil)) }
  # A real terminator, so dev's orphan rule runs as written, with every
  # signal stubbed: nothing here may reach a real process group.
  let(:terminator) do
    Workspace::ProcessGroupTerminator.new(kill: ->(*) { raise "unexpected signal" }, own_pgid: 1).tap do |t|
      allow(t).to receive(:running?).and_return(false)
    end
  end
  let(:tmux) { double("tmux", session_name_for_pane: "app", sessions: ["app"], session_name_for: "app", close_dead_pane: nil) }
  let(:dead_pids) { [] }
  let(:signals) { [] }
  let(:now) { [0.0] }
  let(:on_sleep) { [] }

  def dev(**opts)
    described_class.new(lock_namespace: lock_namespace, lock_holder: liveness, lineage: lineage, dev_config: dev_config,
      dev_runner: nil, terminator: terminator, tmux: tmux, executable: "/ws/bin/workspace", output: output,
      error_output: error_output, env: {"TMUX_PANE" => "%1"}, poll: 1,
      clock: Struct.new(:now_ref) { def now = now_ref[0] }.new(now),
      sleeper: ->(seconds) {
        now[0] += seconds
        on_sleep.shift&.call
      },
      kill: ->(signal, pid) {
        signals << [signal, pid] unless signal == 0
        raise Errno::ESRCH if dead_pids.include?(pid)
        1
      }, **opts)
  end

  def store
    Workspace::LockStore.new(dir: lock_dir, liveness: liveness)
  end

  def process_identity(pid, worktree: "/w/other", branch: "feat/other")
    {kind: "process", pid: pid, started: "s-#{pid}", pgid: pid, pane: "%7", worktree: worktree, branch: branch}
  end

  def hold(pid, **opts)
    store.acquire("devenv", identity: process_identity(pid, **opts), waiter_pid: pid, waiter_started: "s-#{pid}")
  end

  def enqueue(pid, **opts)
    store.acquire("devenv", identity: process_identity(pid, **opts), waiter_pid: pid, waiter_started: "s-#{pid}", wait: true)
  end

  def holder
    store.status("devenv").dig("devenv", "holder")
  end

  def orphan(pid)
    hold(pid)
    liveness.kill(pid)
    dead_pids << pid
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  # Stands in for the `dev __run` wrapper tmux would start: it takes or
  # queues for the lock the way DevRunner does, with the window env given.
  def wrapper_joins(pid, wait: true)
    allow(tmux).to receive(:new_window) do |_session, env:, **|
      store.acquire("devenv", identity: process_identity(pid, worktree: worktree, branch: nil), waiter_pid: pid,
        waiter_started: "s-#{pid}", wait: wait, priority: env["WORKSPACE_DEV_TAKEOVER"] == "1")
      pid
    end
  end

  describe "#up --force" do
    it "queues the new wrapper ahead of an earlier waiter so the stopped holder's lock passes to it" do
      hold(700)
      enqueue(800)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:new_window).with("app", hash_including(env: {"WORKSPACE_DEV_TAKEOVER" => "1"}))
      expect(holder).to include("pid" => 555)
      expect(store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }).to eq([800])
    end

    it "names the startup timeout, not --max-wait, when its queued wrapper never takes the lock and no --max-wait was given" do
      hold(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder).and_return(:terminated)

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 75)
      expect(signals).to eq([["TERM", 555]])
      expect(error_output.string).to include("Still queued for devenv lock after startup timeout; re-run to keep waiting.")
      expect(error_output.string).not_to include("--max-wait")
    end
  end

  describe "#up --force --max-wait" do
    before { hold(700) }

    it "exits 75 and stops its queued wrapper when the stopped holder hasn't let go by the deadline" do
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        now[0] += 2
        :terminated
      end

      expect(dev.up(takeover: true, max_wait: 3, working_dir: worktree)).to eq(exit_code: 75)
      expect(now[0]).to eq(4)
      expect(signals).to eq([["TERM", 555]])
      expect(error_output.string).to include("Still queued for devenv lock after --max-wait; re-run to keep waiting.")
    end

    it "leaves the holder running when the deadline passes before it is stopped" do
      allow(tmux).to receive(:new_window).and_return(555)
      on_sleep << -> {} << -> {
        store.acquire("devenv", identity: process_identity(555, worktree: worktree, branch: nil), waiter_pid: 555,
          waiter_started: "s-555", wait: true, priority: true)
      }
      allow(terminator).to receive(:stop_holder)

      expect(dev.up(takeover: true, max_wait: 2, working_dir: worktree)).to eq(exit_code: 75)
      expect(terminator).not_to have_received(:stop_holder)
      expect(signals).to eq([["TERM", 555]])
      expect(holder).to include("pid" => 700)
    end

    it "stops a wrapper that hasn't queued by the deadline, before the startup timeout" do
      allow(tmux).to receive(:new_window).and_return(555)
      allow(terminator).to receive(:stop_holder)

      expect(dev.up(takeover: true, max_wait: 2, working_dir: worktree)).to eq(exit_code: 1)
      expect(now[0]).to eq(2)
      expect(signals).to eq([["TERM", 555]])
      expect(terminator).not_to have_received(:stop_holder)
      expect(error_output.string).to include("did not acquire the devenv lock within 2s; stopped it.")
    end
  end

  describe "the devenv window" do
    it "is opened with remain-on-exit so a crash stays readable" do
      wrapper_joins(555, wait: false)

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:new_window).with("app", hash_including(remain_on_exit: true))
    end

    it "is closed by `down` once tmux marks the stopped wrapper's pane dead" do
      hold(700)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end
      allow(tmux).to receive(:close_dead_pane).and_return(false, true)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700).twice
    end

    it "is closed by `down` for a stale holder whose lock it removed" do
      orphan(700)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700)
    end

    it "is left open when `down` refuses to touch a running orphan" do
      orphan(700)
      allow(terminator).to receive(:running?).and_return(true)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(tmux).not_to have_received(:close_dead_pane)
    end

    it "gives up waiting for a pane that never dies" do
      hold(700)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end
      allow(tmux).to receive(:close_dead_pane).and_return(false)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:close_dead_pane).exactly(3).times
    end

    it "of the holder a takeover stopped is closed" do
      hold(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 0)
      expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700)
    end
  end

  describe "finding the tmux session" do
    let(:tmux) { double("tmux", session_name_for_pane: nil, sessions: [], session_name_for: "app") }

    it "says so when the tmux server is not running" do
      allow(tmux).to receive(:server_running?).and_return(false)

      expect { dev.up(working_dir: worktree) }.to raise_error(Workspace::Error,
        "tmux server not running; start the workspace with `workspace launch`, then run `workspace dev up` again.")
    end

    it "names the missing session when the server is running" do
      allow(tmux).to receive(:server_running?).and_return(true)

      expect { dev.up(working_dir: worktree) }.to raise_error(Workspace::Error, /No tmux session found for app/)
    end
  end

  describe "#down --force of an orphaned group" do
    before do
      orphan(700)
      allow(terminator).to receive(:running?).with(700).and_return(true)
    end

    it "re-checks for a reused pgid right before signalling, not only before deciding to" do
      guard_before = guard_after = nil
      allow(terminator).to receive(:terminate) do |_pgid, guard:, **|
        guard_before = guard.call
        dead_pids.delete(700) # the group exited and a new process took its id
        guard_after = guard.call
        :terminated
      end

      expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)
      expect([guard_before, guard_after]).to eq([true, false])
    end

    it "reports the reused pgid, not a kill, when the guard stopped the first signal" do
      allow(terminator).to receive(:terminate) do
        dead_pids.delete(700)
        :not_running
      end

      expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)
      expect(output.string).to include("now belongs to an unrelated process, left alone")
      expect(output.string).not_to include("Killed")
      expect(holder).to be_nil
    end
  end

  def locks_path = File.join(lock_dir, "locks.json")

  def edit_lock
    data = JSON.parse(File.read(locks_path))
    yield data["devenv"]
    File.write(locks_path, JSON.generate(data))
  end

  describe "#up clearing the way" do
    it "refuses while a dead wrapper's process group is still running" do
      orphan(700)
      allow(terminator).to receive(:running?).with(700).and_return(true)
      wrapper_joins(555, wait: false)

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("process group 700 is still running (its wrapper pid 700 is gone). Stop it with: workspace dev down --force")
      expect(tmux).not_to have_received(:new_window)
    end

    it "with --force, kills the orphaned group and starts its own" do
      orphan(700)
      allow(terminator).to receive(:running?).with(700).and_return(true)
      allow(terminator).to receive(:terminate).and_return(:terminated)
      wrapper_joins(555, wait: false)

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 0)
      expect(terminator).to have_received(:terminate).with(700, stop_timeout: 2, guard: an_instance_of(Proc))
      expect(output.string).to include("Killed orphaned dev process group 700")
      expect(holder).to include("pid" => 555)
    end

    it "refuses without --wait when others are queued for a free lock" do
      FileUtils.mkdir_p(lock_dir)
      File.write(locks_path, JSON.generate("devenv" => {"holder" => nil, "queue" => [
        {"waiter_pid" => 800, "waiter_started" => "s-800", "agent_pid" => 800, "agent_started" => "s-800", "worktree" => "/w/other"}
      ]}))
      wrapper_joins(555, wait: false)

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("Others are queued for the devenv lock. Use --wait to queue.")
      expect(tmux).not_to have_received(:new_window)
    end
  end

  describe "#up waiting for the wrapper" do
    it "stops a wrapper that never takes the lock within the startup timeout" do
      allow(tmux).to receive(:new_window).and_return(555)

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 1)
      expect(signals).to eq([["TERM", 555]])
      expect(error_output.string).to include("The dev wrapper (pid 555) did not acquire the devenv lock within 5s; stopped it.")
    end

    it "fails when the wrapper exits before taking the lock" do
      allow(tmux).to receive(:new_window).and_return(555)
      dead_pids << 555

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("The dev wrapper (pid 555) exited before it acquired the devenv lock.")
    end

    it "exits 4 when the lock is cleared while its wrapper is queued" do
      hold(700)
      wrapper_joins(555)
      on_sleep << -> { store.clear("devenv") }

      expect(dev.up(wait: true, working_dir: worktree)).to eq(exit_code: 4)
      expect(output.string).to include("Trying to obtain workspace devenv lock (held by other (feat/other))...")
      expect(error_output.string).to include("devenv lock was cleared while waiting.")
    end

    it "exits 75 and stops its queued wrapper once --max-wait passes" do
      hold(700)
      wrapper_joins(555)

      expect(dev.up(wait: true, max_wait: 3, working_dir: worktree)).to eq(exit_code: 75)
      expect(signals).to eq([["TERM", 555]])
      expect(now[0]).to eq(3)
      expect(error_output.string).to include("Still queued for devenv lock after --max-wait; re-run to keep waiting.")
    end

    it "queues instead of refusing when given max_wait with wait: false" do
      hold(700)
      wrapper_joins(555)

      expect(dev.up(wait: false, max_wait: 3, working_dir: worktree)).to eq(exit_code: 75)
      expect(tmux).to have_received(:new_window).with("app", hash_including(command: end_with("__run", "--wait")))
      expect(error_output.string).to include("Still queued for devenv lock after --max-wait")
    end
  end

  describe "#up --queue" do
    it "returns at once as queued, in line behind the holder, and leaves the wrapper running" do
      hold(700)
      wrapper_joins(555)

      result = dev.up(queue: true, working_dir: worktree)

      expect(result).to eq(exit_code: 0, status: "queued", position: 1)
      expect(tmux).to have_received(:new_window).with("app", hash_including(command: end_with("__run", "--wait")))
      expect(signals).to be_empty
      expect(output.string).to include("Queued for the devenv lock at position 1")
      expect(output.string).to include("workspace dev wait")
    end

    it "counts the waiters already queued ahead" do
      hold(700)
      enqueue(701)
      wrapper_joins(555)

      expect(dev.up(queue: true, working_dir: worktree)).to include(status: "queued", position: 2)
    end

    it "returns running when the lock is free, without waiting for the ready check" do
      settings["ready"] = "false"
      wrapper_joins(555)

      result = dev.up(queue: true, working_dir: worktree)

      expect(result).to eq(exit_code: 0, status: "running", position: nil)
      expect(output.string).to include("Dev environment starting for")
    end

    it "does not open a second wrapper when this worktree is already queued" do
      hold(700)
      enqueue(555, worktree: worktree)
      allow(tmux).to receive(:new_window)

      result = dev.up(queue: true, working_dir: worktree)

      expect(result).to eq(exit_code: 0, status: "queued", position: 1)
      expect(tmux).not_to have_received(:new_window)
      expect(output.string).to include("Already queued")
    end

    it "does not open a second wrapper when this worktree already holds the lock" do
      hold(555, worktree: worktree)
      allow(tmux).to receive(:new_window)

      result = dev.up(queue: true, working_dir: worktree)

      expect(result).to eq(exit_code: 0, status: "running", position: nil)
      expect(tmux).not_to have_received(:new_window)
    end

    it "stops a wrapper that never reaches the queue and exits 1 with no status" do
      allow(tmux).to receive(:new_window).and_return(555)

      expect(dev.up(queue: true, working_dir: worktree)).to eq(exit_code: 1, status: nil, position: nil)
      expect(signals).to eq([["TERM", 555]])
    end

    it "refuses a dead wrapper's process group that is still running, as --wait does" do
      orphan(700)
      allow(terminator).to receive(:orphan_running?).and_return(true)

      result = dev.up(queue: true, working_dir: worktree)

      expect(result).to include(exit_code: 1)
      expect(error_output.string).to include("still running")
    end

    it "refuses --force and --max-wait together with --queue" do
      expect { dev.up(queue: true, takeover: true, working_dir: worktree) }.to raise_error(Workspace::UsageError, /--queue/)
      expect { dev.up(queue: true, max_wait: 5, working_dir: worktree) }.to raise_error(Workspace::UsageError, /--queue/)
    end
  end

  describe "#wait" do
    it "returns running once the queued wrapper is promoted" do
      hold(700)
      enqueue(555, worktree: worktree)
      on_sleep << -> { store.release("devenv", 700) }

      result = dev.wait(working_dir: worktree)

      expect(result).to eq(exit_code: 0, status: "running", position: nil)
      expect(holder).to include("pid" => 555)
    end

    it "returns at once when this worktree already holds the lock and there is no ready check" do
      hold(555, worktree: worktree)

      expect(dev.wait(working_dir: worktree)).to eq(exit_code: 0, status: "running", position: nil)
      expect(now[0]).to eq(0)
    end

    it "exits 75 after --max-wait and leaves the wrapper queued" do
      hold(700)
      enqueue(555, worktree: worktree)

      result = dev.wait(max_wait: 3, working_dir: worktree)

      expect(result).to eq(exit_code: 75, status: "queued", position: 1)
      expect(signals).to be_empty
      expect(store.status("devenv").dig("devenv", "queue").size).to eq(1)
      expect(error_output.string).to include("Still queued for devenv lock after --max-wait")
    end

    it "exits 4 when the lock is cleared while waiting" do
      hold(700)
      enqueue(555, worktree: worktree)
      on_sleep << -> { store.clear("devenv") }

      result = dev.wait(working_dir: worktree)

      expect(result).to eq(exit_code: 4, status: nil, position: nil)
      expect(error_output.string).to include("devenv lock was cleared while waiting.")
    end

    it "exits 4 when this worktree is neither queued nor running" do
      hold(700)

      result = dev.wait(working_dir: worktree)

      expect(result).to eq(exit_code: 4, status: nil, position: nil)
      expect(error_output.string).to include("not queued for the devenv lock")
      expect(error_output.string).to include("workspace dev up --queue")
    end

    it "exits 6 when the environment is running but its ready check never passes" do
      settings["ready"] = "false"
      hold(555, worktree: worktree)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(555)
        :terminated
      end

      result = dev.wait(working_dir: worktree)

      expect(result).to include(exit_code: 6, status: nil)
    end

    it "skips the ready check with ready: false" do
      settings["ready"] = "false"
      hold(555, worktree: worktree)

      expect(dev.wait(ready: false, working_dir: worktree)).to include(exit_code: 0, status: "running")
    end

    it "exits 1 when the queued wrapper has exited" do
      hold(700)
      enqueue(555, worktree: worktree)
      dead_pids << 555

      result = dev.wait(working_dir: worktree)

      expect(result).to eq(exit_code: 1, status: nil, position: nil)
      expect(error_output.string).to include("exited before it acquired")
    end

    it "rejects a --max-wait of zero" do
      expect { dev.wait(max_wait: 0, working_dir: worktree) }.to raise_error(Workspace::UsageError, /--max-wait/)
    end
  end

  describe "#leave" do
    it "signals the queued wrapper, removes its place and reports left" do
      hold(700)
      enqueue(555, worktree: worktree)

      result = dev.leave(working_dir: worktree)

      expect(result).to eq(exit_code: 0, outcome: "left")
      expect(signals).to eq([["TERM", 555]])
      expect(store.status("devenv").dig("devenv", "queue")).to be_empty
      expect(holder).to include("pid" => 700)
    end

    it "leaves other worktrees' places alone" do
      hold(700)
      enqueue(701)
      enqueue(555, worktree: worktree)

      dev.leave(working_dir: worktree)

      expect(store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }).to eq([701])
    end

    it "ignores a place whose wrapper is already gone" do
      hold(700)
      enqueue(555, worktree: worktree)
      liveness.kill(555)

      expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "not_queued")
      expect(signals).to be_empty
    end

    it "closes the wrapper's dead window" do
      hold(700)
      enqueue(555, worktree: worktree)

      dev.leave(working_dir: worktree)

      expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 555).at_least(:once)
    end

    it "reports not_queued, exit 0, when this worktree is not in line" do
      hold(700)

      expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "not_queued")
      expect(signals).to be_empty
    end

    it "reports not_queued and keeps the lock when this worktree holds it" do
      hold(555, worktree: worktree)

      expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "not_queued")
      expect(holder).to include("pid" => 555)
      expect(output.string).to include("workspace dev down")
    end

    it "reports not_queued when nothing is held at all" do
      expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "not_queued")
    end
  end

  describe "#up recording devenv waits in the event log" do
    let(:recorded) { [] }
    let(:event_log) do
      events = recorded
      Object.new.tap do |log|
        log.define_singleton_method(:record) { |type:, project:, data: {}| events << [project, type, data] }
      end
    end

    it "records the wait's start and the acquire, with how long it waited" do
      hold(700)
      wrapper_joins(555)
      on_sleep << -> {} << -> {
        liveness.kill(700)
        store.release("devenv", identity: process_identity(700))
      }

      expect(dev(event_log: event_log).up(wait: true, ready: false, working_dir: worktree)).to eq(exit_code: 0)
      expect(recorded.map { |project, type, _| [project, type] }).to eq([["app", "lock_wait_started"], ["app", "lock_acquired"]])
      expect(recorded[0][2]).to include("lock" => "devenv", "pid" => 555, "holder" => include("pid" => 700))
      expect(recorded[1][2]).to include("lock" => "devenv", "pid" => 555, "waited_seconds" => 2.0)
    end

    it "records giving up after --max-wait and a wait ended by clear" do
      hold(700)
      wrapper_joins(555)
      dev(event_log: event_log).up(wait: true, max_wait: 3, working_dir: worktree)
      expect(recorded.last[1..]).to eq(["lock_wait_gave_up", {"lock" => "devenv", "pid" => 555, "waited_seconds" => 3.0}])

      on_sleep << -> { store.clear("devenv") }
      store.clear("devenv")
      hold(700)
      wrapper_joins(556)
      dev(event_log: event_log).up(wait: true, working_dir: worktree)
      expect(recorded.last[1]).to eq("lock_wait_cleared")
    end

    it "records a takeover naming the holder it stops" do
      hold(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      dev(event_log: event_log).up(takeover: true, ready: false, working_dir: worktree)

      takeover = recorded.find { |_, type, _| type == "lock_takeover" }
      expect(takeover[2]).to include("lock" => "devenv", "pid" => 555, "from" => include("pid" => 700, "worktree" => "/w/other"))
    end
  end

  describe "#up --force waiting for its wrapper to queue" do
    before { hold(700) }

    it "stops a wrapper that never queues within the startup timeout, leaving the holder alone" do
      allow(tmux).to receive(:new_window).and_return(555)
      allow(terminator).to receive(:stop_holder)

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)
      expect(signals).to eq([["TERM", 555]])
      expect(terminator).not_to have_received(:stop_holder)
      expect(holder).to include("pid" => 700)
    end

    it "fails when the wrapper exits before queueing" do
      allow(tmux).to receive(:new_window).and_return(555)
      dead_pids << 555

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("The dev wrapper (pid 555) exited before it queued for the devenv lock.")
    end
  end

  describe "#up waiting for the ready check" do
    before { settings["ready"] = "false" }

    it "exits 6 when the dev command exits before the check passes" do
      wrapper_joins(555, wait: false)
      on_sleep << -> { liveness.kill(555) }

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 6)
      expect(error_output.string).to include("The dev command exited before its ready check (false) passed; see the devenv window.")
    end

    it "stops the env and exits 6 when the check does not pass in time, leaving its window open" do
      wrapper_joins(555, wait: false)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(555)
        :terminated
      end

      expect(dev.up(working_dir: worktree)).to eq(exit_code: 6)
      expect(error_output.string).to include("Ready check (false) did not pass within 5s; stopped the dev environment and released the devenv lock.")
      expect(holder).to be_nil
      expect(tmux).not_to have_received(:close_dead_pane)
    end
  end

  describe "#status uptime" do
    before { hold(700) }

    it "shows hours and minutes for a long-running env" do
      edit_lock { |entry| entry["holder"]["acquired_at"] = (Time.now - 7260).utc.iso8601 }

      dev.status(working_dir: worktree)

      expect(output.string).to include("pid 700, pgid 700, pane %7, up 2h 1m")
    end

    it "shows ? for an unreadable acquired_at" do
      edit_lock { |entry| entry["holder"]["acquired_at"] = "not a time" }

      dev.status(working_dir: worktree)

      expect(output.string).to include("pid 700, pgid 700, pane %7, up ?")
    end
  end

  describe "a process group this user may not signal" do
    let(:foreign) { Workspace::Error.new("process group 700 has running processes this user is not permitted to signal") }

    it "`status` reports it instead of failing" do
      orphan(700)
      allow(terminator).to receive(:running?).and_raise(foreign)

      expect(dev.status(working_dir: worktree)).to eq(exit_code: 0)
      expect(output.string).to include("wrapper pid 700 is gone; process group 700 has running processes this user is not permitted to signal")
    end

    it "`down --force` raises and keeps the stale lock" do
      orphan(700)
      allow(terminator).to receive(:running?).and_raise(foreign)

      expect { dev.down(force: true, working_dir: worktree) }.to raise_error(Workspace::Error, /not permitted/)
      expect(File.read(File.join(lock_dir, "locks.json"))).to include('"pid": 700')
    end

    it "`down` of a live holder keeps its lock, exits 1 and says how to stop the group" do
      hold(700)
      allow(terminator).to receive(:stop_holder).and_raise(foreign)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(holder).to include("pid" => 700)
      expect(error_output.string).to include("Could not stop process group 700 (pid 700): process group 700 has running processes",
        "Kept devenv lock", "kill -TERM -700", "then run: workspace dev down")
      expect(output.string).not_to include("Stopped dev environment")
      expect(tmux).not_to have_received(:close_dead_pane)
    end

    it "`down` keeps the lock when a member outlives SIGKILL and its wrapper, so it is not reaped" do
      hold(700)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :killed
      end
      allow(terminator).to receive(:running?).with(700).and_raise(foreign)
      allow(terminator).to receive(:orphan_running?).and_raise(foreign)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("still running 2s after SIGKILL", "Kept devenv lock")
      expect(holder).to include("pid" => 700, "kept" => true)
      expect(store.acquire("devenv", identity: process_identity(555), waiter_pid: 555, waiter_started: "s-555")[:status]).to eq(:held)
    end
  end

  describe "#down when the wrapper exits just before its SIGTERM" do
    before do
      hold(700)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :not_running
      end
    end

    it "keeps the lock while its group still runs" do
      allow(terminator).to receive(:orphan_running?).and_return(true)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("its wrapper pid 700 is gone, but the group is still running", "Kept devenv lock")
      expect(output.string).not_to include("Stopped")
      expect(holder).to include("pid" => 700)
    end

    it "removes the lock without claiming to have stopped anything once the group is gone" do
      allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
      expect(output.string).to include("was not running; removed its stale lock")
      expect(output.string).not_to include("Stopped")
      expect(holder).to be_nil
    end
  end

  describe "#up --force of a group that can't be stopped" do
    it "keeps the holder's lock, exits 1 and leaves its own wrapper queued first" do
      hold(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder).and_raise(Workspace::Error, "process group 700 has running processes this user is not permitted to signal")

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)
      expect(holder).to include("pid" => 700)
      expect(store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }).to eq([555])
      expect(error_output.string).to include("Kept devenv lock", "stays queued first for the devenv lock")
    end

    it "tells the reader to have the group's owner stop it, with no sudo advice" do
      hold(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder).and_raise(Workspace::Error, "process group 700 has running processes this user is not permitted to signal")

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)
      expect(error_output.string).to include("Run `workspace dev status` to watch it",
        "Have its owner run `kill -TERM -700`", "the lock frees on its own once the group is empty")
      expect(error_output.string).not_to include("sudo")
    end
  end

  describe "a holder another process is already stopping" do
    let(:clearer) { {"pid" => 901, "started" => "start-901"} }

    def mark_held_by_clearer(pid)
      hold(pid)
      store.mark_clearing("devenv", holder, clearer)
    end

    it "`down` signals nothing, says who is stopping it and exits 1" do
      mark_held_by_clearer(700)
      allow(terminator).to receive(:stop_holder)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(terminator).not_to have_received(:stop_holder)
      expect(error_output.string).to include("devenv lock is already being cleared by pid 901")
      expect(holder["clearing"]).to eq(clearer)
    end

    it "`up --force` signals nothing and leaves its own wrapper queued first" do
      mark_held_by_clearer(700)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder)

      expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)
      expect(terminator).not_to have_received(:stop_holder)
      expect(store.status("devenv").dig("devenv", "queue").map { |w| w["waiter_pid"] }).to eq([555])
      expect(error_output.string).to include("already being cleared by pid 901", "stays queued first")
    end

    it "`down` stops a holder whose marker names a process no longer running, then drops its own marker" do
      mark_held_by_clearer(700)
      liveness.kill(901)
      allow(terminator).to receive(:stop_holder).and_return(:terminated)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
      expect(terminator).to have_received(:stop_holder)
      expect(holder["clearing"]).to be_nil
    end
  end

  describe "`down` with dev.kill_grace set" do
    let(:settings) { {"up" => "run-dev", "stop_timeout" => 2, "startup_timeout" => 5, "ready_timeout" => 5, "kill_grace" => 7} }

    it "waits that long after SIGKILL before keeping the lock" do
      hold(700)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :killed
      end
      allow(terminator).to receive(:running?).with(700).and_return(true)

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)
      expect(now[0]).to be >= 7
      expect(error_output.string).to include("still running 7s after SIGKILL", "Kept devenv lock")
    end
  end

  describe "under a workflow run that holds the devenv lock" do
    let(:bound_run) { instance_double(Workspace::BoundRun, run_id: "wr_1") }
    let(:other_run) { instance_double(Workspace::BoundRun, run_id: "wr_2") }
    let(:unbound) { instance_double(Workspace::BoundRun, run_id: nil) }
    let(:run) { {run_id: "wr_1", step: "implement", workflow: "rpiv", workspace: "app.worktree-a", worktree: worktree, pane: "%1"} }

    before { store.acquire_run(["devenv"], run: run) }

    # Stands in for the wrapper `dev up` starts for a run: it records itself
    # on the run's hold the way DevRunner does, from the window env given.
    def delegate_joins(pid)
      allow(tmux).to receive(:new_window) do |_session, env:, **|
        store.delegate("devenv", run_id: env.fetch("WORKSPACE_DEV_RUN"), identity: process_identity(pid, worktree: worktree, branch: "feat/a"))
        pid
      end
    end

    def delegate(pid)
      store.delegate("devenv", run_id: "wr_1", identity: process_identity(pid, worktree: worktree, branch: "feat/a"))
    end

    let(:recorded) { [] }
    let(:dev_events) do
      events = recorded
      log = Object.new.tap { |l| l.define_singleton_method(:record) { |type:, project:, data: {}| events << [type, data["reason"]] } }
      Workspace::DevEvents.new(event_log: log, lineage: lineage)
    end

    describe "#release_for_session" do
      before { allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false) }

      def delegate_started_by(pid, session)
        store.delegate("devenv", run_id: "wr_1", identity: process_identity(pid, worktree: worktree, branch: "feat/a").merge(started_by: {"session_id" => session, "pane" => "%1"}))
      end

      it "stops the run's environment that session started, and leaves the lock with the run" do
        delegate_started_by(700, "sess-1")
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end

        result = dev(dev_events: dev_events).release_for_session(session_id: "sess-1", working_dir: worktree)

        expect(result).to eq(exit_code: 0, outcome: "released")
        expect(holder).to include("run_id" => "wr_1")
        expect(holder).not_to include("delegate")
        expect(recorded).to eq([["dev_stopped", "down"]])
      end

      it "leaves a run's environment another session started" do
        delegate_started_by(700, "sess-1")
        expect(terminator).not_to receive(:stop_holder)

        result = dev.release_for_session(session_id: "sess-2", working_dir: worktree)

        expect(result).to eq(exit_code: 0, outcome: "not_started_by_session")
        expect(holder).to include("delegate" => include("pid" => 700))
      end

      it "does nothing when the run has no environment under it" do
        expect(dev.release_for_session(session_id: "sess-1", working_dir: worktree)).to eq(exit_code: 0, outcome: "not_started_by_session")
      end

      it "leaves a holder whose wrapper is gone for dev down --force" do
        hold(800, worktree: worktree)
        store.release("devenv", 800)
        store.acquire("devenv", identity: process_identity(801, worktree: worktree).merge(started_by: {"session_id" => "sess-1", "pane" => "%1"}), waiter_pid: 801, waiter_started: "s-801")
        liveness.kill(801)
        expect(terminator).not_to receive(:stop_holder)

        result = dev.release_for_session(session_id: "sess-1", working_dir: worktree)

        expect(result).to eq(exit_code: 0, outcome: "not_started_by_session")
      end
    end

    describe "#down_for_run" do
      before { allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false) }

      it "writes dev_stopped with reason down for the environment it stops, and nothing when it cannot" do
        delegate(700)
        store.release_run("wr_1")
        allow(terminator).to receive(:stop_holder).and_return(:kept)
        dev(dev_events: dev_events).down_for_run("wr_1", working_dir: worktree)
        expect(recorded).to be_empty

        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end
        dev(dev_events: dev_events).down_for_run("wr_1", working_dir: worktree)
        expect(recorded).to eq([["dev_stopped", "down"]])
      end

      it "stops the environment the run left running when it gave the lock up, and frees the lock" do
        delegate(700)
        store.release_run("wr_1")
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end

        expect(dev.down_for_run("wr_1", working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to eq("Stopped dev environment for #{File.basename(worktree)} (feat/a), which run wr_1 no longer uses.\n")
        expect(holder).to be_nil
        expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700)
      end

      it "writes one dev_stopped with reason reaped when the environment's wrapper exited just before the stop" do
        delegate(700)
        store.release_run("wr_1")
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :not_running
        end

        dev(dev_events: dev_events).down_for_run("wr_1", working_dir: worktree)

        expect(recorded).to eq([["dev_stopped", "reaped"]])
      end

      it "leaves alone an environment another run left, one started outside a run, and a lock a run holds" do
        delegate(700)
        allow(terminator).to receive(:stop_holder)

        expect(dev.down_for_run("wr_1", working_dir: worktree)).to eq(exit_code: 0)
        store.release_run("wr_1")
        expect(dev.down_for_run("wr_2", working_dir: worktree)).to eq(exit_code: 0)

        expect(terminator).not_to have_received(:stop_holder)
        expect(holder).to include("kind" => "process", "pid" => 700, "from_run" => "wr_1")
        expect(output.string).to eq("")
      end

      it "exits 1 and keeps the lock naming an environment it could not stop" do
        delegate(700)
        store.release_run("wr_1")
        allow(terminator).to receive(:stop_holder).and_raise(Workspace::Error, "Operation not permitted")
        allow(terminator).to receive(:running?).and_return(true)

        expect(dev.down_for_run("wr_1", working_dir: worktree)).to eq(exit_code: 1)

        expect(holder).to include("pid" => 700, "kept" => true)
      end

      it "does nothing when the lock is free" do
        store.release_run("wr_1")

        expect(dev.down_for_run("wr_1", working_dir: worktree)).to eq(exit_code: 0)
      end
    end

    describe "#up from the pane bound to that run" do
      it "opens the wrapper with the run's id and no --wait, and returns once it is the run's delegate" do
        delegate_joins(700)

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 0)

        expect(tmux).to have_received(:new_window).with("app", hash_including(
          command: [RbConfig.ruby, "/ws/bin/workspace", "dev", "__run"], env: {"WORKSPACE_DEV_RUN" => "wr_1"}
        ))
        expect(holder).to include("run_id" => "wr_1", "delegate" => include("pid" => 700))
        expect(store.status("devenv").dig("devenv", "queue")).to eq([])
        expect(output.string).to include("Dev environment running for")
      end

      it "is idempotent while the run's environment is running" do
        delegate(700)
        allow(tmux).to receive(:new_window)

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 0)

        expect(tmux).not_to have_received(:new_window)
        expect(output.string).to eq("Dev environment is already running for #{File.basename(worktree)} (feat/a) under run wr_1.\n")
      end

      it "starts a new one once the run's last environment has died" do
        delegate(600)
        liveness.kill(600)
        delegate_joins(700)

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 0)
        expect(holder["delegate"]).to include("pid" => 700)
      end

      it "fails when the wrapper exits before it is recorded" do
        allow(tmux).to receive(:new_window).and_return(700)
        dead_pids << 700

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 1)
        expect(error_output.string).to include("exited before it acquired the devenv lock")
      end

      it "stops the delegate and exits 6 when the ready check does not pass, and the run keeps the lock" do
        settings.merge!("ready" => "false", "ready_timeout" => 3)
        delegate_joins(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 6)

        expect(terminator).to have_received(:stop_holder).with(hash_including("pid" => 700), liveness: liveness, stop_timeout: 2)
        expect(error_output.string).to include("did not pass within 3s; stopped the dev environment; the devenv lock stays with its run")
        expect(holder).to include("run_id" => "wr_1")
        expect(holder).not_to include("delegate")
      end

      it "reports the environment it started when the run ends during start-up" do
        allow(tmux).to receive(:new_window) do |_session, env:, **|
          store.delegate("devenv", run_id: env.fetch("WORKSPACE_DEV_RUN"), identity: process_identity(700, worktree: worktree, branch: "feat/a"))
          liveness.end_run("wr_1")
          700
        end

        expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to include("Dev environment running for")
        expect(signals).to eq([])
      end
    end

    describe "#up --queue under the run" do
      it "starts the environment as the run's delegate from the bound pane and reports running" do
        delegate_joins(700)

        result = dev(bound_run: bound_run).up(queue: true, working_dir: worktree)

        expect(result).to eq(exit_code: 0, status: "running", position: nil)
        expect(holder).to include("run_id" => "wr_1", "delegate" => include("pid" => 700))
      end

      it "reports an environment already running under the run without opening a window" do
        delegate(700)
        allow(tmux).to receive(:new_window)

        result = dev(bound_run: bound_run).up(queue: true, working_dir: worktree)

        expect(result).to eq(exit_code: 0, status: "running", position: nil)
        expect(tmux).not_to have_received(:new_window)
      end

      it "exits 1 with no status when the run's wrapper fails to start" do
        allow(tmux).to receive(:new_window).and_return(700)
        dead_pids << 700

        result = dev(bound_run: bound_run).up(queue: true, working_dir: worktree)

        expect(result).to eq(exit_code: 1, status: nil, position: nil)
      end

      it "queues behind the run from a pane that is not bound to it, without refusing" do
        wrapper_joins(555)

        expect(dev(bound_run: other_run).up(queue: true, working_dir: worktree)).to eq(exit_code: 0, status: "queued", position: 1)

        expect(error_output.string).to eq("")
        expect(holder).to include("run_id" => "wr_1")
      end
    end

    describe "#wait and #leave under the run" do
      it "wait returns running for a worktree whose wrapper is the run's delegate, using the delegate's pid" do
        settings["ready"] = "true"
        delegate(700)

        result = dev.wait(working_dir: worktree)

        expect(result).to eq(exit_code: 0, status: "running", position: nil)
        expect(error_output.string).to eq("")
      end

      it "wait exits 4 for a delegate whose wrapper has died" do
        delegate(700)
        liveness.kill(700)

        expect(dev.wait(working_dir: worktree)).to include(exit_code: 4)
      end

      it "wait exits 4 when the run holds the lock but this worktree has no environment under it" do
        result = dev.wait(working_dir: worktree)

        expect(result).to eq(exit_code: 4, status: nil, position: nil)
      end

      it "leave reports not_queued and points at dev down when this worktree's environment runs under the run" do
        delegate(700)

        expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "not_queued")
        expect(output.string).to include("workspace dev down")
        expect(signals).to be_empty
      end

      it "leave does not mistake the run's own queue entry for this worktree's wrapper" do
        enqueue(555, worktree: worktree)
        store.acquire_run(["devenv"], run: {run_id: "wr_2", step: "x", workflow: "rpiv", workspace: "app", worktree: worktree, pane: "%2"})

        queue = store.status("devenv").dig("devenv", "queue")
        expect(queue.map { |w| w["run_id"] }.compact).to eq(["wr_2"])
        expect(dev.leave(working_dir: worktree)).to eq(exit_code: 0, outcome: "left")
        expect(store.status("devenv").dig("devenv", "queue").map { |w| w["run_id"] }).to eq(["wr_2"])
      end
    end

    describe "#up from anywhere else" do
      before { allow(tmux).to receive(:new_window) }

      it "refuses, naming the run, from a pane that is not bound" do
        [dev, dev(bound_run: unbound), dev(bound_run: other_run)].each do |command|
          expect(command.up(working_dir: worktree)).to eq(exit_code: 1)
        end

        expect(tmux).not_to have_received(:new_window)
        expect(error_output.string.lines.uniq).to eq(
          ["The devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement). Use --wait to queue. If that run is no longer going, free the lock with: workspace lock clear devenv\n"]
        )
      end

      it "says so when the run has an environment running" do
        delegate(700)

        dev.up(working_dir: worktree)

        expect(error_output.string).to eq("The devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement), " \
          "with a dev environment running for #{File.basename(worktree)} (feat/a). Use --wait to queue. If that run is no longer going, free the lock with: workspace lock clear devenv\n")
      end

      it "refuses --force: a run's lock is not taken over, and nothing is signalled" do
        delegate(700)

        expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)

        expect(tmux).not_to have_received(:new_window)
        expect(signals).to eq([])
        expect(error_output.string).to eq("The devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement); " \
          "--force does not take a lock from a run. Use --wait to queue behind it. If that run is no longer going, free the lock with: workspace lock clear devenv\n")
      end

      it "refuses --force when the run takes the lock back while the new wrapper queues, and stops only that wrapper" do
        store.delegate("devenv", run_id: "wr_1", identity: process_identity(700))
        store.release_run("wr_1")
        allow(tmux).to receive(:new_window) do
          store.acquire_run(["devenv"], run: run)
          store.acquire("devenv", identity: process_identity(555, worktree: worktree, branch: nil), waiter_pid: 555,
            waiter_started: "s-555", wait: true, priority: true)
          555
        end
        allow(terminator).to receive(:stop_holder)

        expect(dev.up(takeover: true, working_dir: worktree)).to eq(exit_code: 1)

        expect(terminator).not_to have_received(:stop_holder)
        expect(signals).to eq([["TERM", 555]])
        expect(error_output.string).to eq("The devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement); " \
          "--force does not take a lock from a run. Use --wait to queue behind it. If that run is no longer going, free the lock with: workspace lock clear devenv\n")
        expect(output.string).not_to include("Taking over")
        expect(holder).to include("run_id" => "wr_1", "delegate" => include("pid" => 700))
      end

      it "queues behind the run with --wait and starts once the run releases the lock" do
        wrapper_joins(800)
        on_sleep << -> { store.release_run("wr_1") }

        expect(dev.up(wait: true, working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to include("Trying to obtain workspace devenv lock (held by #{File.basename(worktree)} (run wr_1, step implement))...")
        expect(holder).to include("kind" => "process", "pid" => 800)
      end
    end

    describe "#up after the run has ended" do
      before { liveness.end_run("wr_1") }

      it "starts as usual once the ended run's hold is reaped" do
        wrapper_joins(800, wait: false)

        expect(dev.up(working_dir: worktree)).to eq(exit_code: 0)
        expect(holder).to include("kind" => "process", "pid" => 800)
      end
    end

    describe "#down" do
      it "says nothing is running, and leaves the run's lock, when the run has no environment" do
        expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to eq("No dev environment is running; the devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement).\n")
        expect(holder).to include("run_id" => "wr_1")
      end

      it "stops the run's environment and leaves the lock with the run" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :killed
        end

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to eq("Stopped dev environment for #{File.basename(worktree)} (feat/a) (SIGKILL after 2s); " \
          "the devenv lock stays with #{File.basename(worktree)} (run wr_1, step implement).\n")
        expect(holder).to include("run_id" => "wr_1")
        expect(holder).not_to include("delegate")
        expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700)
      end

      it "writes dev_stopped with reason down for the delegate it stops" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end

        dev(dev_events: dev_events).down(working_dir: worktree)

        expect(recorded).to eq([["dev_stopped", "down"]])
      end

      it "writes dev_stopped with reason down when the delegate had to be killed" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :killed
        end

        dev(dev_events: dev_events).down(working_dir: worktree)

        expect(recorded).to eq([["dev_stopped", "down"]])
      end

      it "writes one dev_stopped with reason reaped when the delegate's wrapper exited just before the stop" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :not_running
        end
        allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

        dev(dev_events: dev_events).down(working_dir: worktree)

        expect(recorded).to eq([["dev_stopped", "reaped"]])
      end

      it "writes nothing for a delegate it could not stop" do
        delegate(700)
        allow(terminator).to receive(:stop_holder).and_raise(Workspace::Error, "live members owned by root")

        dev(dev_events: dev_events).down(working_dir: worktree)

        expect(recorded).to be_empty
      end

      it "says the environment was not running when its wrapper exited just before the stop" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :not_running
        end
        allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)

        expect(output.string).to eq("Dev environment for #{File.basename(worktree)} (feat/a) was not running; " \
          "the devenv lock stays with #{File.basename(worktree)} (run wr_1, step implement).\n")
        expect(holder).not_to include("delegate")
      end

      it "keeps the delegate on the lock and exits 1 when its group may not be signalled" do
        delegate(700)
        allow(terminator).to receive(:stop_holder).and_raise(Workspace::Error, "process group 700 has live members owned by root")

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

        expect(error_output.string).to include("Could not stop process group 700 (pid 700): process group 700 has live members owned by root")
        expect(holder["delegate"]).to include("pid" => 700)
      end

      it "keeps the delegate when its wrapper exited just before the stop but its group runs on" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :not_running
        end
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

        expect(error_output.string).to include("Could not stop process group 700 (pid 700): its wrapper pid 700 is gone, but the group is still running")
        expect(output.string).to eq("")
        expect(holder["delegate"]).to include("pid" => 700, "kept" => true)
      end

      context "when the group is still running after SIGKILL and its wrapper is gone" do
        before do
          delegate(700)
          allow(terminator).to receive(:stop_holder) do
            liveness.kill(700)
            :killed
          end
          allow(terminator).to receive(:running?).with(700).and_return(true)
          allow(terminator).to receive(:orphan_running?).and_return(true)
        end

        it "exits 1 and the lock goes on naming it, through later lock operations" do
          expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

          expect(error_output.string).to include("Could not stop process group 700 (pid 700): it was still running 2s after SIGKILL",
            "The devenv lock still names it, so no second dev environment starts while process group 700 runs.",
            "kill -TERM -700", "then run: workspace dev down")
          store_with_terminator = Workspace::LockStore.new(dir: lock_dir, liveness: liveness, terminator: terminator)
          store_with_terminator.reap
          expect(holder).to include("run_id" => "wr_1", "delegate" => include("pid" => 700, "kept" => true, "stale" => true))
          expect(tmux).not_to have_received(:close_dead_pane)
        end

        it "refuses to start a second one from the run's pane" do
          dev.down(working_dir: worktree)
          allow(tmux).to receive(:new_window)

          expect(dev(bound_run: bound_run).up(working_dir: worktree)).to eq(exit_code: 1)

          expect(tmux).not_to have_received(:new_window)
          expect(error_output.string).to include("A previous dev environment's process group 700 is still running under run wr_1 " \
            "(its wrapper pid 700 is gone). Stop it with: workspace dev down --force (for another user's processes, " \
            "have its owner run `kill -TERM -700`), then run `workspace dev up` again.")
        end

        it "is not reported as running, and `down` drops it once the group is gone" do
          dev.down(working_dir: worktree)
          expect(dev.status_payload(working_dir: worktree)).to include("running" => false)
          allow(terminator).to receive(:stop_holder).and_return(:gone)
          allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

          expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)

          expect(output.string).to include("was not running; the devenv lock stays with")
          expect(holder).to include("run_id" => "wr_1")
          expect(holder).not_to include("delegate")
        end

        it "`status` says its process group is still running, where --json has `running` false and the kept delegate" do
          dev.down(working_dir: worktree)

          dev.status(working_dir: worktree)

          name = File.basename(worktree)
          expect(output.string).to eq("Dev environment: STALE for #{name} (feat/a) under run wr_1 (wrapper pid 700 is gone; " \
            "its process group 700 is still running — stop it with `workspace dev down --force`); " \
            "the devenv lock is held by #{name} (run wr_1, step implement)\n")
          payload = dev.status_payload(working_dir: worktree)
          expect(payload).to include("running" => false, "ready" => nil)
          expect(payload["holder"]["delegate"]).to include("pid" => 700, "kept" => true, "stale" => true)
        end

        it "`status` says the group is gone once it is, before any command has dropped the record" do
          dev.down(working_dir: worktree)
          allow(terminator).to receive(:orphan_running?).and_return(false)

          dev.status(working_dir: worktree)

          expect(output.string).to start_with("Dev environment: STALE for #{File.basename(worktree)} (feat/a) under run wr_1 (wrapper pid 700 is gone); the devenv lock is held by")
        end

        it "`down --force` kills the group left behind and drops it from the run's hold" do
          dev.down(working_dir: worktree)
          dead_pids << 700
          allow(terminator).to receive(:terminate).and_return(:killed)

          expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)

          expect(terminator).to have_received(:terminate).with(700, hash_including(stop_timeout: 2))
          expect(output.string).to eq("Killed orphaned dev process group 700 (wrapper pid 700 was gone); " \
            "the devenv lock stays with #{File.basename(worktree)} (run wr_1, step implement).\n")
          expect(holder).to include("run_id" => "wr_1")
          expect(holder).not_to include("delegate")
        end

        it "`down --force` writes dev_stopped with reason forced for the group it kills" do
          dev.down(working_dir: worktree)
          dead_pids << 700
          allow(terminator).to receive(:terminate).and_return(:killed)

          dev(dev_events: dev_events).down(force: true, working_dir: worktree)

          expect(recorded).to eq([["dev_stopped", "forced"]])
        end

        it "`down --force` writes nothing when there was no group left to kill" do
          dev.down(working_dir: worktree)
          dead_pids << 700
          allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

          dev(dev_events: dev_events).down(force: true, working_dir: worktree)

          expect(recorded).to be_empty
        end

        it "`down` without --force still only reports it, and says `down --force` kills the group" do
          dev.down(working_dir: worktree)
          allow(terminator).to receive(:terminate)

          expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

          expect(terminator).not_to have_received(:terminate)
          expect(holder["delegate"]).to include("pid" => 700, "kept" => true)
          expect(error_output.string).to end_with("Stop it with: workspace dev down --force (for another user's processes, " \
            "have its owner run `kill -TERM -700`, then run: workspace dev down)\n")
        end

        it "`down --force` closes the environment's window once the group is killed" do
          dev.down(working_dir: worktree)
          dead_pids << 700
          allow(terminator).to receive(:terminate).and_return(:killed)

          dev.down(force: true, working_dir: worktree)

          expect(tmux).to have_received(:close_dead_pane).with("%7", pid: 700)
        end

        it "`down --force` says the group was not running when it exits before the kill, checking first that its id was not reused" do
          dev.down(working_dir: worktree)
          dead_pids << 700
          guarded = []
          allow(terminator).to receive(:pgid_reused?).and_return(false)
          allow(terminator).to receive(:terminate) do |_pgid, guard:, **|
            guarded << guard.call
            :not_running
          end

          expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)

          expect(guarded).to eq([true])
          expect(output.string).to eq("Dev environment for #{File.basename(worktree)} (feat/a) was not running; " \
            "the devenv lock stays with #{File.basename(worktree)} (run wr_1, step implement).\n")
          expect(holder).not_to include("delegate")
        end

        it "`down --force` raises, signals nothing and leaves the record kept when the group is another user's" do
          dev.down(working_dir: worktree)
          allow(terminator).to receive(:orphan_running?).and_raise(Workspace::Error, "process group 700 has live members owned by root")
          allow(terminator).to receive(:terminate)

          expect { dev.down(force: true, working_dir: worktree) }.to raise_error(Workspace::Error, /owned by root/)

          expect(terminator).not_to have_received(:terminate)
          expect(holder["delegate"]).to include("pid" => 700, "kept" => true)
        end

        it "`down --force` drops a kept delegate whose group is already gone, without a kill" do
          dev.down(working_dir: worktree)
          allow(terminator).to receive(:stop_holder).and_return(:gone)
          allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)
          allow(terminator).to receive(:terminate)

          expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)

          expect(terminator).not_to have_received(:terminate)
          expect(output.string).to include("was not running; the devenv lock stays with")
          expect(holder).not_to include("delegate")
        end
      end

      it "`down --force` stops a live delegate the usual way, through its wrapper" do
        delegate(700)
        allow(terminator).to receive(:terminate)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          :terminated
        end

        expect(dev.down(force: true, working_dir: worktree)).to eq(exit_code: 0)

        expect(terminator).not_to have_received(:terminate)
        expect(output.string).to start_with("Stopped dev environment for #{File.basename(worktree)} (feat/a); the devenv lock stays with")
      end

      it "puts the delegate back on the run's hold, kept, when it was dropped while its failed stop waited out the kill" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          liveness.kill(700)
          # Another lock command lands here: the wrapper is dead and not yet marked kept, so its record is dropped.
          store.reap
          :killed
        end
        allow(terminator).to receive(:running?).with(700).and_return(true)
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

        expect(error_output.string).to include("The devenv lock still names it")
        expect(holder).to include("run_id" => "wr_1", "delegate" => include("pid" => 700, "kept" => true))
      end

      it "says the lock no longer names the environment when it changed hands for good during a stop that fails" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          store.release_run("wr_1")
          liveness.kill(700)
          store.reap
          :killed
        end
        allow(terminator).to receive(:running?).with(700).and_return(true)
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

        expect(error_output.string).to include("The devenv lock no longer names it (the lock changed hands during the stop), while process group 700 " \
          "may still be running. Have its owner run `kill -TERM -700`, and see: workspace dev status")
        expect(error_output.string).not_to include("still names it")
        expect(holder).to be_nil
      end

      it "keeps the lock naming the environment when the run gives the lock up during a stop that fails" do
        delegate(700)
        allow(terminator).to receive(:stop_holder) do
          store.release_run("wr_1")
          liveness.kill(700)
          :killed
        end
        allow(terminator).to receive(:running?).with(700).and_return(true)
        allow(terminator).to receive(:orphan_running?).and_return(true)

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 1)

        Workspace::LockStore.new(dir: lock_dir, liveness: liveness, terminator: terminator).reap
        expect(holder).to include("kind" => "process", "pid" => 700, "kept" => true)
      end

      it "frees the lock of a run that has ended" do
        liveness.end_run("wr_1")

        expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
        expect(output.string).to eq("No dev environment is running.\n")
        expect(holder).to be_nil
      end
    end

    describe "#status" do
      it "says the environment is not running and who holds the lock" do
        dev.status(working_dir: worktree)

        expect(output.string).to eq("Dev environment: not running; the devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement)\n")
      end

      it "shows the run's environment, its run, and anyone queued behind it" do
        delegate(700)
        enqueue(800)
        store.acquire_run(["devenv"], run: run.merge(run_id: "wr_2", worktree: "/w/b"))

        dev.status(working_dir: worktree)

        expect(output.string.lines.map(&:chomp)).to match([
          "Dev environment: running for #{File.basename(worktree)} (feat/a) under run wr_1",
          a_string_matching(/\A  pid 700, pgid 700, pane %7, up \d+s\z/),
          "  ready: not configured",
          "  1. queued: other (feat/other) (pid 800)",
          "  2. queued: b (run wr_2, step implement)"
        ])
      end

      it "marks a run that has ended, without changing the store" do
        liveness.end_run("wr_1")
        before = File.read(File.join(lock_dir, "locks.json"))

        dev.status(working_dir: worktree)

        expect(output.string).to eq("Dev environment: not running; the devenv lock is held by #{File.basename(worktree)} (run wr_1, step implement) " \
          "(the run has ended; the next lock or dev command frees it)\n")
        expect(File.read(File.join(lock_dir, "locks.json"))).to eq(before)
      end

      it "still reports the environment of a run that has ended, in text and in --json alike" do
        settings["ready"] = "true"
        delegate(700)
        liveness.end_run("wr_1")

        dev.status(working_dir: worktree)
        payload = dev.status_payload(working_dir: worktree)

        expect(output.string.lines.first).to eq("Dev environment: running for #{File.basename(worktree)} (feat/a) under run wr_1 " \
          "(the run has ended; the next lock or dev command frees it)\n")
        expect(payload).to include("running" => true, "ready" => true)
        expect(payload["holder"]).to include("kind" => "run", "stale" => true, "delegate" => include("pid" => 700, "stale" => false))
      end

      describe "--json" do
        it "is not running, with the run as the holder, while the run has no environment" do
          payload = dev.status_payload(working_dir: worktree)

          expect(payload).to include("running" => false, "ready" => nil, "queue" => [])
          expect(payload["holder"]).to include("kind" => "run", "run_id" => "wr_1", "step" => "implement", "workflow" => "rpiv",
            "workspace" => "app.worktree-a", "worktree" => worktree, "stale" => false)
          expect(payload["holder"]).not_to include("delegate", "pid")
        end

        it "is running, and probes readiness, once the run has an environment" do
          settings["ready"] = "true"
          delegate(700)

          payload = dev.status_payload(working_dir: worktree)

          expect(payload).to include("running" => true, "ready" => true)
          expect(payload["holder"]).to include("kind" => "run", "run_id" => "wr_1")
          expect(payload["holder"]["delegate"]).to include("kind" => "process", "pid" => 700, "pgid" => 700, "branch" => "feat/a", "stale" => false)
        end

        it "is not running once the run's environment has died" do
          delegate(700)
          liveness.kill(700)

          expect(dev.status_payload(working_dir: worktree)).to include("running" => false, "ready" => nil)
        end
      end
    end

    describe "#run" do
      it "hands the wrapper the run named in its window's environment" do
        runner = instance_double(Workspace::DevRunner, call: 0)

        dev(dev_runner: runner, env: {"WORKSPACE_DEV_RUN" => "wr_1"}).run(working_dir: worktree)
        dev(dev_runner: runner, env: {"WORKSPACE_DEV_RUN" => ""}).run(working_dir: worktree)

        expect(runner).to have_received(:call).with(hash_including(delegate_for: "wr_1")).once
        expect(runner).to have_received(:call).with(hash_including(delegate_for: nil)).once
      end
    end
  end

  describe "#status_payload for a reader that follows along" do
    let(:wall) { [Time.at(Time.now.to_i)] }
    let(:snapshot_client) { double("snapshot_client") }
    let(:panes) { [] }

    before { allow(snapshot_client).to receive(:fetch).with("app").and_return("panes" => panes) }

    def payload(**opts)
      dev(snapshot_client: snapshot_client, wall_clock: -> { wall[0] }).status_payload(working_dir: worktree, **opts)
    end

    def edit_enqueued_at(pid, time)
      path = File.join(lock_dir, "locks.json")
      data = JSON.parse(File.read(path))
      data["devenv"]["queue"].find { |w| w["waiter_pid"] == pid }["enqueued_at"] = time.utc.iso8601
      File.write(path, JSON.generate(data))
    end

    it "numbers each queue entry from 1 and says how long it has waited" do
      hold(700)
      enqueue(800)
      enqueue(801)
      edit_enqueued_at(800, wall[0] - 140)
      edit_enqueued_at(801, wall[0] - 20)

      queue = payload["queue"]

      expect(queue.map { |w| w["position"] }).to eq([1, 2])
      expect(queue.map { |w| w["waiting_seconds"] }).to eq([140, 20])
    end

    it "leaves waiting_seconds null for a waiter with no readable enqueue time" do
      hold(700)
      enqueue(800)
      edit_enqueued_at(800, wall[0])
      path = File.join(lock_dir, "locks.json")
      data = JSON.parse(File.read(path))
      data["devenv"]["queue"][0]["enqueued_at"] = "not a time"
      File.write(path, JSON.generate(data))

      expect(payload["queue"][0]).to include("position" => 1, "waiting_seconds" => nil)
    end

    it "keeps an empty queue empty" do
      expect(payload).to include("holder" => nil, "queue" => [])
    end

    it "reports the holder's agent as working while any agent pane there works" do
      hold(700, worktree: worktree)
      panes.push({"kind" => "claude", "state" => "idle", "state_since" => "2026-10-13T10:00:00Z"},
        {"kind" => "claude", "state" => "working", "state_since" => "2026-10-13T10:05:00Z"})

      expect(payload["holder"]).to include("agent_state" => "working", "idle_since" => nil)
    end

    it "reports idle with the time the agent last stopped working" do
      hold(700, worktree: worktree)
      panes.push({"kind" => "claude", "state" => "idle", "state_since" => "2026-10-13T10:00:00Z"},
        {"kind" => "codex", "state" => "done", "state_since" => "2026-10-13T10:07:00Z"})

      expect(payload["holder"]).to include("agent_state" => "idle", "idle_since" => "2026-10-13T10:07:00Z")
    end

    it "counts an agent waiting for the person as idle" do
      hold(700, worktree: worktree)
      panes.push({"kind" => "claude", "state" => "waiting", "state_since" => "2026-10-13T10:03:00Z"})

      expect(payload["holder"]).to include("agent_state" => "idle", "idle_since" => "2026-10-13T10:03:00Z")
    end

    it "reports none when the worktree has only shell panes or a closed agent" do
      hold(700, worktree: worktree)
      panes.push({"kind" => "shell", "state" => "idle", "state_since" => "2026-10-13T10:00:00Z"},
        {"kind" => "claude", "state" => "closed", "state_since" => "2026-10-13T10:01:00Z"})

      expect(payload["holder"]).to include("agent_state" => "none", "idle_since" => nil)
    end

    it "reports none when the daemon is down or does not answer" do
      hold(700, worktree: worktree)
      allow(snapshot_client).to receive(:fetch).and_raise(Workspace::AgentSnapshotClient::Unavailable.new("down", reason: :no_daemon))

      expect(payload["holder"]).to include("agent_state" => "none", "idle_since" => nil)
    end

    it "reports none when it has no client to ask" do
      hold(700, worktree: worktree)

      expect(dev.status_payload(working_dir: worktree)["holder"]).to include("agent_state" => "none", "idle_since" => nil)
    end

    it "does not ask the daemon, and adds neither key, with agent_state: false" do
      hold(700, worktree: worktree)

      holder = payload(agent_state: false)["holder"]

      expect(snapshot_client).not_to have_received(:fetch)
      expect(holder).not_to have_key("agent_state")
    end

    it "prints the same payload from `status --json`" do
      hold(700, worktree: worktree)
      enqueue(800)
      panes.push({"kind" => "claude", "state" => "working", "state_since" => "2026-10-13T10:00:00Z"})

      dev(snapshot_client: snapshot_client, wall_clock: -> { wall[0] }).status(working_dir: worktree, json: true)

      printed = JSON.parse(output.string)
      expect(printed["holder"]).to include("agent_state" => "working")
      expect(printed["queue"][0]).to include("position" => 1)
    end
  end

  describe "dev_stopped events for the stops this command makes" do
    let(:recorded) { [] }
    let(:event_log) do
      events = recorded
      Object.new.tap { |log| log.define_singleton_method(:record) { |type:, project:, data: {}| events << [project, type, data] } }
    end
    let(:dev_events) { Workspace::DevEvents.new(event_log: event_log, lineage: lineage) }

    def stops
      recorded.select { |_, type, _| type == "dev_stopped" }.map { |project, _, data| [project, data["reason"], data["workspace"]] }
    end

    it "writes reason down when `down` stops the holder" do
      hold(700, worktree: worktree)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      dev(dev_events: dev_events).down(working_dir: worktree)

      expect(stops).to eq([["app", "down", "app"]])
      expect(recorded.last[2]).to eq("workspace" => "app", "lock" => "devenv", "reason" => "down")
    end

    it "writes reason down when the holder had to be killed" do
      hold(700, worktree: worktree)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :killed
      end

      dev(dev_events: dev_events).down(working_dir: worktree)

      expect(stops).to eq([["app", "down", "app"]])
    end

    it "writes nothing when the holder cannot be stopped" do
      hold(700, worktree: worktree)
      allow(terminator).to receive(:stop_holder).and_return(:kept)

      dev(dev_events: dev_events).down(working_dir: worktree)

      expect(stops).to be_empty
    end

    it "writes reason reaped once, not twice, when `down` only removes a dead holder's lock" do
      orphan_in_worktree(700)
      allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

      dev(dev_events: dev_events).down(working_dir: worktree)

      expect(stops).to eq([["app", "reaped", "app"]])
    end

    it "writes reason forced when `down --force` kills what a dead wrapper left running" do
      orphan_in_worktree(700)
      allow(terminator).to receive_messages(orphan_running?: true, pgid_reused?: false, terminate: :terminated)

      dev(dev_events: dev_events).down(force: true, working_dir: worktree)

      expect(stops).to eq([["app", "forced", "app"]])
    end

    it "writes reason forced for the holder `up --force` stops" do
      other = File.join(tmpdir, "other").tap { |dir| FileUtils.mkdir_p(dir) }
      hold(700, worktree: other)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      dev(dev_events: dev_events).up(takeover: true, working_dir: worktree)

      expect(stops).to eq([["app", "forced", "app"]])
    end

    it "writes nothing when `up --force` could not stop the holder" do
      other = File.join(tmpdir, "other").tap { |dir| FileUtils.mkdir_p(dir) }
      hold(700, worktree: other)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder).and_return(:kept)

      dev(dev_events: dev_events).up(takeover: true, working_dir: worktree)

      expect(stops).to be_empty
    end

    it "writes reason reaped when the holder `up --force` meant to stop was already gone" do
      other = File.join(tmpdir, "other").tap { |dir| FileUtils.mkdir_p(dir) }
      hold(700, worktree: other)
      wrapper_joins(555)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :not_running
      end
      allow(terminator).to receive_messages(orphan_running?: false, pgid_reused?: false)

      dev(dev_events: dev_events).up(takeover: true, working_dir: worktree)

      expect(stops).to eq([["app", "reaped", "app"]])
    end

    it "writes nothing when it has no events to write to" do
      hold(700, worktree: worktree)
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      expect(dev.down(working_dir: worktree)).to eq(exit_code: 0)
    end

    it "skips a holder whose worktree is gone rather than naming it wrongly" do
      hold(700, worktree: File.join(tmpdir, "gone"))
      allow(terminator).to receive(:stop_holder) do
        liveness.kill(700)
        :terminated
      end

      dev(dev_events: dev_events).down(working_dir: worktree)

      expect(stops).to be_empty
    end

    def orphan_in_worktree(pid)
      hold(pid, worktree: worktree)
      liveness.kill(pid)
      dead_pids << pid
    end
  end
end
