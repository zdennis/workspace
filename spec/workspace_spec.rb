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

    it "wires a real LockReaper into the agent command's session monitor" do
      cli = Workspace.build_cli(
        output: StringIO.new,
        error_output: StringIO.new,
        input: StringIO.new
      )

      agent_command = cli.instance_variable_get(:@agent_command)
      lock_reaper = agent_command.instance_variable_get(:@lock_reaper)

      expect(lock_reaper).to be_a(Workspace::LockReaper)
      # Ticking with no cwds touches nothing on disk; this only confirms the
      # dependency reaches the command, not stubbing it out.
      expect(lock_reaper.tick([])).to eq(0)
    end

    it "wires the shared ProcessGroupTerminator into the statusline command" do
      cli = Workspace.build_cli(
        output: StringIO.new,
        error_output: StringIO.new,
        input: StringIO.new
      )

      statusline_command = cli.instance_variable_get(:@statusline_command)
      lock_command = cli.instance_variable_get(:@lock_command)

      terminator = statusline_command.instance_variable_get(:@terminator)
      expect(terminator).to be_a(Workspace::ProcessGroupTerminator)
      expect(terminator).to equal(lock_command.instance_variable_get(:@terminator))
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

    it "wires instructions compose to the library start uses and the binding command binding show uses" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      instructions = cli.instance_variable_get(:@instructions_command)
      composer = instructions.instance_variable_get(:@composer)

      expect(instructions).to be_a(Workspace::Commands::Instructions)
      expect(instructions.instance_variable_get(:@bindings)).to equal(cli.instance_variable_get(:@binding_command))
      expect(composer.instance_variable_get(:@library)).to equal(cli.instance_variable_get(:@library))
      expect(composer.instance_variable_get(:@commands_config)).to be_a(Workspace::CommandsConfig)
      expect(composer.instance_variable_get(:@pane_bindings)).to be_a(Workspace::PaneBindings)
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

    it "gives the agent daemon a nudger over the same run files and bindings, which starts this checkout's bin/workspace" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      nudger = cli.instance_variable_get(:@agent_command).instance_variable_get(:@workflow_nudger)
      engine = cli.instance_variable_get(:@workflow_command).instance_variable_get(:@engine)

      expect(nudger).to be_a(Workspace::WorkflowNudger)
      expect(nudger.instance_variable_get(:@store)).to equal(engine.instance_variable_get(:@store))
      expect(nudger.instance_variable_get(:@panes)).to equal(engine.instance_variable_get(:@panes))
      expect(nudger.instance_variable_get(:@executable)).to eq(File.expand_path("../bin/workspace", __dir__))
    end

    it "gives start a library installer that checks tracked files with the shared git" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      start_command = cli.instance_variable_get(:@start_command)
      installer = start_command.instance_variable_get(:@library_installer)

      expect(installer).to be_a(Workspace::LibraryInstaller)
      expect(installer.instance_variable_get(:@git)).to equal(start_command.instance_variable_get(:@git))
    end
  end
end
