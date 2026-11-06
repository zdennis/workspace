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
      handler = Object.new
      handler.define_singleton_method(:exit) { |code = 0| exits << code }
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

    describe "the agent recovery desk factory" do
      around do |example|
        Dir.mktmpdir("ws-recovery-wiring") do |dir|
          saved = ENV.to_h
          home = File.realpath(dir)
          ENV.replace("HOME" => home, "PATH" => saved["PATH"], "XDG_STATE_HOME" => File.join(home, "state"), "XDG_CONFIG_HOME" => File.join(home, "config"))
          example.run
        ensure
          ENV.replace(saved)
        end
      end

      def recovery_desk(*config_settings)
        cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {})
        config_settings.each { |key, value| cli.run(["config", "set", "--scope", "global", key, value]) }
        factory = cli.instance_variable_get(:@agent_command).instance_variable_get(:@agent_recovery_desk_factory)
        factory.call(workspace: "ws-smoke", session_name: "ws", session_monitor: instance_double(Workspace::SessionMonitor),
          delivery_lock: Mutex.new, event_log: nil, restarting: ->(_) { false }, claim_restart: ->(_) {},
          release_restart: ->(*) {}, rebind_queue: ->(*) {})
      end

      it "builds a desk with the defaults" do
        expect(recovery_desk).to be_a(Workspace::AgentRecoveryDesk)
      end

      it "builds no desk with agent.recovery.enabled off" do
        expect(recovery_desk(["agent.recovery.enabled", "false"])).to be_nil
      end

      it "builds no desk when the workspace's agent.kind is not claude" do
        expect(recovery_desk(["agent.kind", "codex"])).to be_nil
      end
    end

    it "gives lock and dev the same view of which run a pane is bound to, from the bindings `binding set` writes" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      bound_run = cli.instance_variable_get(:@lock_command).instance_variable_get(:@bound_run)
      binding_command = cli.instance_variable_get(:@binding_command)

      expect(bound_run).to be_a(Workspace::BoundRun)
      expect(cli.instance_variable_get(:@dev_command).instance_variable_get(:@bound_run)).to equal(bound_run)
      expect(bound_run.instance_variable_get(:@pane_bindings)).to equal(binding_command.instance_variable_get(:@bindings))
    end

    it "checks a run holder's liveness against the run files in the state directory, in the CLI and in the daemon's reaper" do
      Dir.mktmpdir("ws-run-wiring") do |state|
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", anything).and_return(state)
        cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)
        runs = File.join(state, "workspace", ".workflows", "runs")
        FileUtils.mkdir_p(runs)
        File.write(File.join(runs, "wr_live.json"), JSON.generate("state" => "running"))
        File.write(File.join(runs, "wr_done.json"), JSON.generate("state" => "completed"))

        holders = [
          cli.instance_variable_get(:@lock_command).instance_variable_get(:@lock_holder),
          cli.instance_variable_get(:@agent_command).instance_variable_get(:@lock_reaper).instance_variable_get(:@lock_holder)
        ]

        holders.each do |holder|
          expect(holder.run_alive?("wr_live")).to be(true)
          expect(holder.run_alive?("wr_done")).to be(false)
          expect(holder.run_alive?("wr_none")).to be(false)
        end
      end
    end

    it "wires the binding command into launch, so a delivered play binds the pane binding set and session-event use" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      binding_command = cli.instance_variable_get(:@binding_command)
      launch_command = cli.instance_variable_get(:@launch_command)

      expect(launch_command.instance_variable_get(:@binder)).to equal(binding_command)
    end

    it "wires restore to the ledger session-event writes and the bindings binding set writes" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      restore = cli.instance_variable_get(:@restore_command)
      session_event = cli.instance_variable_get(:@session_event_command)
      binding_command = cli.instance_variable_get(:@binding_command)

      expect(restore).to be_a(Workspace::Commands::Restore)
      expect(restore.instance_variable_get(:@ledger)).to equal(session_event.instance_variable_get(:@session_ledger))
      expect(restore.instance_variable_get(:@pane_bindings)).to equal(binding_command.instance_variable_get(:@bindings))
      expect(restore.instance_variable_get(:@tmuxinator_report)).to equal(cli.instance_variable_get(:@tmuxinator_report))
      expect(restore.instance_variable_get(:@process_tree)).to be_a(Workspace::ProcessTree)
      expect(restore.instance_variable_get(:@agent_ensurer)).to equal(cli.instance_variable_get(:@ensure_agent_command))
    end

    it "wires the dev environment's release to session end, and the same dev command and ledger into kill and dev up" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      session_event = cli.instance_variable_get(:@session_event_command)
      dev = cli.instance_variable_get(:@dev_command)
      kill = cli.instance_variable_get(:@kill_command)

      expect(session_event.instance_variable_get(:@dev_session_release)).to be_a(Workspace::DevSessionRelease)
      expect(kill.instance_variable_get(:@dev)).to equal(dev)
      expect(dev.instance_variable_get(:@session_ledger)).to equal(session_event.instance_variable_get(:@session_ledger))
    end

    it "wires one workflow engine into the workflow command and kill, over the run files the lock store reads" do
      Dir.mktmpdir("ws-workflow-wiring") do |state|
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("XDG_STATE_HOME", anything).and_return(state)
        cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

        workflow = cli.instance_variable_get(:@workflow_command)
        engine = workflow.instance_variable_get(:@engine)
        store = engine.instance_variable_get(:@store)
        panes = engine.instance_variable_get(:@panes)

        expect(workflow).to be_a(Workspace::Commands::Workflow)
        expect(cli.instance_variable_get(:@kill_command).instance_variable_get(:@workflow_runs)).to equal(engine)
        expect(workflow.instance_variable_get(:@store)).to equal(store)
        expect(workflow.instance_variable_get(:@status).instance_variable_get(:@store)).to equal(store)
        expect(engine.instance_variable_get(:@resources)).to be_a(Workspace::RunResources)
        expect(engine.instance_variable_get(:@composer)).to equal(cli.instance_variable_get(:@instructions_command).instance_variable_get(:@composer))
        expect(engine.instance_variable_get(:@composer).instance_variable_get(:@workflow_config)).to be_a(Workspace::WorkflowConfig)
        expect(panes.instance_variable_get(:@bindings)).to equal(cli.instance_variable_get(:@binding_command).instance_variable_get(:@bindings))
        expect(panes.instance_variable_get(:@agent_ensurer)).to equal(cli.instance_variable_get(:@ensure_agent_command))

        # Approve and status name a gate's note through one resolver, over the notes command; the caller checks read tmux and ps.
        gate_note = engine.instance_variable_get(:@gate_note)
        expect(gate_note).to be_a(Workspace::WorkflowGateNote)
        expect(workflow.instance_variable_get(:@status).instance_variable_get(:@gate_note)).to equal(gate_note)
        expect(gate_note.instance_variable_get(:@notes)).to be_a(Workspace::Commands::Notes)
        expect(workflow.instance_variable_get(:@tmux)).to be_a(Workspace::Tmux)
        expect(workflow.instance_variable_get(:@process_tree)).to be_a(Workspace::ProcessTree)
        expect(workflow.instance_variable_get(:@lock_holder)).to be_a(Workspace::LockHolder)

        # The engine's events go to the one shared log, and the environment a run left is stopped through `dev`.
        dev = cli.instance_variable_get(:@dev_command)
        expect(engine.instance_variable_get(:@event_log)).to be_a(Workspace::EventLog)
        expect(engine.instance_variable_get(:@event_log)).to equal(cli.instance_variable_get(:@kill_command).instance_variable_get(:@event_log))
        allow(dev).to receive(:down_for_run).and_return(exit_code: 0)
        engine.instance_variable_get(:@env_stopper).call(run_id: "wr_1", worktree: "/src/app")
        expect(dev).to have_received(:down_for_run).with("wr_1", working_dir: "/src/app")

        # A run the store creates is alive to the lock holder the run's locks are checked with.
        run = store.create("state" => "running", "workspace" => "app", "current" => "a", "steps" => {"a" => {"state" => "running", "attempts" => []}},
          "definition" => {"steps" => [{"id" => "a"}]})
        lock_holder = engine.instance_variable_get(:@resources).instance_variable_get(:@lock_holder)
        expect(lock_holder.run_alive?(run["id"])).to be true
        expect(File.dirname(File.dirname(store.events_path(run["id"])))).to eq(File.join(state, "workspace", ".workflows"))
      end
    end

    it "builds a doctor that no longer reports mixed-case workspace names" do
      require "tmpdir"
      saved = %w[HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME].to_h { |k| [k, ENV[k]] }
      Dir.mktmpdir("wsd", File.realpath("/tmp")) do |home|
        ENV["HOME"] = home
        ENV["XDG_CONFIG_HOME"] = File.join(home, ".config")
        ENV["XDG_STATE_HOME"] = File.join(home, ".local", "state")
        ENV["XDG_DATA_HOME"] = File.join(home, ".local", "share")
        ENV["XDG_CACHE_HOME"] = File.join(home, ".cache")
        FileUtils.mkdir_p(File.join(home, ".config", "tmuxinator"))
        FileUtils.mkdir_p(File.join(home, ".config", "workspace", "projects"))
        File.write(File.join(home, ".config", "tmuxinator", "workspace.Notes.yml"), "name: workspace-Notes\n")
        File.write(File.join(home, ".config", "workspace", "projects", "Notes.yml"), "{}\n")
        File.write(File.join(home, ".workspace-state.json"), JSON.generate("Notes" => {"iterm_window_id" => 1}))

        cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new, env: {})
        rows = cli.instance_variable_get(:@doctor).report(headless: true)[:rows]

        expect(rows.map { |r| r[:id] }).not_to include("mixed-case-workspaces")
        expect(rows.map { |r| r[:message] }.join("\n")).not_to match(/capitals/)
      end
    ensure
      ENV.update(saved)
    end
  end
end
