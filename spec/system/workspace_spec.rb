require "stringio"

RSpec.describe Workspace do
  describe ".build_cli" do
    it "returns a CLI instance" do
      cli = Workspace.build_cli(
        output: StringIO.new,
        error_output: StringIO.new,
        input: StringIO.new
      )
      expect(cli).to be_a(Workspace::CLI)
    end

    it "builds a CLI that prints help for --help" do
      output = StringIO.new
      cli = Workspace.build_cli(
        output: output,
        error_output: StringIO.new,
        input: StringIO.new
      )
      cli.run(["--help"])
      expect(output.string).to match(/Usage: workspace/)
    end

    it "sends the process exit to the exit_handler it is given" do
      exits = []
      handler = Struct.new(:exits) { def exit(code = 0) = exits << code }.new(exits)
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {}, exit_handler: handler)
      cli.run(["bogus"])
      expect(exits).to include(1)
    end

    it "accepts a logger parameter" do
      logger = Workspace::Logger.new(enabled: true)
      cli = Workspace.build_cli(
        output: StringIO.new,
        error_output: StringIO.new,
        input: StringIO.new,
        logger: logger
      )
      expect(cli).to be_a(Workspace::CLI)
    end

    it "enables logger when WORKSPACE_DEBUG is set" do
      original = ENV["WORKSPACE_DEBUG"]
      ENV["WORKSPACE_DEBUG"] = "1"
      error_output = StringIO.new
      cli = Workspace.build_cli(
        output: StringIO.new,
        error_output: error_output,
        input: StringIO.new
      )
      cli.run(["--help"])
      expect(error_output.string).to include("[DEBUG]")
    ensure
      if original
        ENV["WORKSPACE_DEBUG"] = original
      else
        ENV.delete("WORKSPACE_DEBUG")
      end
    end
  end

  describe "wired through a temporary HOME" do
    let(:home) { File.realpath(Dir.mktmpdir("ws-wiring", "/tmp")) }
    let(:repo) { File.join(home, "repo") }
    let(:config) { Workspace::Config.new }
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    around do |example|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => home, "PATH" => saved["PATH"], "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8",
          "XDG_STATE_HOME" => File.join(home, "state"), "XDG_CONFIG_HOME" => File.join(home, "config"),
          "XDG_DATA_HOME" => File.join(home, "data"), "XDG_CACHE_HOME" => File.join(home, "cache"), "TMUX_TMPDIR" => home)
        example.run
      ensure
        system("tmux", "kill-server", err: File::NULL, out: File::NULL)
        ENV.replace(saved)
        FileUtils.rm_rf(home)
      end
    end

    def cli(input: "")
      out.truncate(0)
      out.rewind
      err.truncate(0)
      err.rewind
      Workspace.build_cli(output: out, error_output: err, input: StringIO.new(input), env: {}, exit_handler: FakeExitHandler)
    end

    def run_cli(*args, input: "")
      cli(input: input).run(args)
      0
    rescue FakeSystemExit => e
      e.status
    end

    def git_repo
      _, status = Open3.capture2e("git", "init", "-q", repo)
      raise "git init failed" unless status.success?
    end

    def start_session(name)
      _, status = Open3.capture2e("tmux", "new-session", "-d", "-s", name, "-c", repo)
      raise "tmux new-session failed" unless status.success?
      Open3.capture2("tmux", "list-panes", "-t", "=#{name}", "-F", "\#{pane_id}").first.strip
    end

    def run_store
      Workspace::WorkflowRunStore.new(dir: config.workflow_runs_dir, archive_dir: config.workflow_archive_dir)
    end

    def lock_store
      namespace = Workspace::LockNamespace.new(lineage: LineageSupport.lineage, config: config).resolve(cwd: repo)
      liveness = Workspace::LockHolder.new(run_liveness: Workspace::RunLiveness.new(dir: config.workflow_runs_dir))
      Workspace::LockStore.new(dir: namespace[:dir], liveness: liveness)
    end

    def hold_lock_for(run_id, name: "test-db")
      lock_store.acquire_run([name], run: {run_id: run_id, step: "verify", workflow: "rpiv", workspace: "bindws", worktree: repo, pane: "%0"})
    end

    it "tells the pane bound by `binding set` that its run already holds the lock" do
      git_repo
      pane = start_session("bindws")
      FileUtils.mkdir_p(config.workflow_runs_dir)
      File.write(File.join(config.workflow_runs_dir, "wr_1.json"), JSON.generate("state" => "running"))
      hold_lock_for("wr_1")
      expect(run_cli("binding", "set", "bindws", "--pane", pane, "--kind", "run", "--id", "wr_1")).to eq(0)
      ENV["TMUX_PANE"] = pane

      status = Dir.chdir(repo) { run_cli("lock", "acquire", "test-db") }

      expect(status).to eq(0)
      expect(out.string).to eq("test-db lock is already held for this pane by run wr_1; there is nothing to acquire or release.\n")
    end

    it "shows a lock held by a running run and drops it once the run's file says it finished" do
      git_repo
      FileUtils.mkdir_p(config.workflow_runs_dir)
      run_file = File.join(config.workflow_runs_dir, "wr_live.json")
      File.write(run_file, JSON.generate("state" => "running"))
      hold_lock_for("wr_live")

      Dir.chdir(repo) { run_cli("lock", "status", "test-db") }
      expect(out.string).to include("held by run wr_live")
      expect(out.string).not_to include("STALE")

      File.write(run_file, JSON.generate("state" => "completed"))
      Dir.chdir(repo) { run_cli("lock", "status", "test-db") }
      expect(out.string).to match(/held by run wr_live.*STALE/)
    end

    it "reads a run from the run files under XDG_STATE_HOME" do
      run = run_store.create("workflow" => "rpiv", "workspace" => "app", "state" => "running", "current" => "plan",
        "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"attempts" => []}})

      expect(run_cli("workflow", "status", run["id"], "--json")).to eq(0)

      expect(JSON.parse(out.string).to_s).to include(run["id"])
      expect(File.exist?(File.join(home, "state", "workspace", ".workflows", "runs", "#{run["id"]}.json"))).to be(true)
    end

    it "restores from the ledger that session-event writes" do
      git_repo
      pane = start_session("bindws")
      ENV["TMUX_PANE"] = pane
      transcript = File.join(home, "transcript.jsonl")
      File.write(transcript, "{}\n")
      FileUtils.mkdir_p(File.dirname(config.config_path_for("bindws")))
      File.write(config.config_path_for("bindws"), "name: bindws\nroot: #{repo}\nwindows:\n  - main:\n      panes:\n        - claude\n")
      payload = JSON.generate("hook_event_name" => "SessionStart", "session_id" => "abc-123", "source" => "startup", "transcript_path" => transcript, "cwd" => repo)
      expect(run_cli("session-event", "--workspace", "bindws", input: payload)).to eq(0)

      expect(run_cli("restore", "bindws", "--dry-run", "--json")).to eq(0)

      expect(out.string).to include("abc-123")
    end

    it "builds a doctor that no longer reports mixed-case workspace names" do
      FileUtils.mkdir_p(File.join(home, "config", "tmuxinator"))
      FileUtils.mkdir_p(File.join(home, "config", "workspace", "projects"))
      File.write(File.join(home, "config", "tmuxinator", "workspace.Notes.yml"), "name: workspace-Notes\n")
      File.write(File.join(home, "config", "workspace", "projects", "Notes.yml"), "{}\n")
      File.write(File.join(home, ".workspace-state.json"), JSON.generate("Notes" => {"iterm_window_id" => 1}))

      run_cli("doctor", "--headless", "--json")

      expect(out.string).not_to match(/mixed-case-workspaces|capitals/)
      expect(JSON.parse(out.string)).to include("ok")
    end

    describe "the agent daemon's scan slots" do
      let(:slot_dir) { File.join(config.state_dir, "scan-slots") }
      let(:ws) { "slotws" }

      def snapshot
        UNIXSocket.open(config.agent_socket_path(ws)) do |socket|
          socket.puts({"type" => "sessions", "workspace" => ws}.to_json)
          JSON.parse(socket.gets)
        end
      end

      def wait_for(timeout: 15)
        deadline = Time.now + timeout
        sleep 0.1 until yield || Time.now > deadline
      end

      around do |example|
        previous = Signal.trap("TERM", "DEFAULT")
        example.run
      ensure
        Signal.trap("TERM", previous)
      end

      it "scans only when a slot under <state>/scan-slots is free" do
        git_repo
        start_session(ws)
        FileUtils.mkdir_p(File.dirname(config.config_path_for(ws)))
        File.write(config.config_path_for(ws), "name: #{ws}\nroot: #{repo}\nwindows:\n  - main:\n      panes:\n        - claude\n")
        FileUtils.mkdir_p(File.join(home, "config", "workspace", "projects"))
        File.write(File.join(home, "config", "workspace", "projects", "#{ws}.yml"), "agentd:\n  poll_interval: 1\n")
        holder = HeldScanSlot.take(dir: slot_dir, limit: 1)
        expect(holder).to be_held

        daemon = Thread.new { run_cli("agentd", ws) }
        begin
          wait_for { File.socket?(config.agent_socket_path(ws)) }
          sleep 2.5
          expect(snapshot["panes"]).to be_empty

          holder.release
          wait_for { snapshot["panes"].any? }
          expect(snapshot["panes"]).not_to be_empty
        ensure
          holder.release unless holder.nil? || !holder.held?
          Process.kill("TERM", Process.pid) if daemon.alive?
          daemon.join(5)
        end
      end
    end
  end

  describe "the bin/workspace executable" do
    it "prints help and exits 0 for every subcommand in the main help" do
      exe = File.join(PROJECT_ROOT, "bin", "workspace")
      listing, = Open3.capture2e(exe, "--help")
      names = listing[/Subcommands:\n(.*?)\n\n/m, 1].scan(/^  (\S+)\s{2,}\S/).flatten - %w[help run-and-report report-run-status]
      expect(names.size).to be > 40

      failures = names.reject do |name|
        text, status = Open3.capture2e(exe, name, "--help")
        status.success? && !text.strip.empty?
      end

      expect(failures).to eq([])
    end
  end
end
