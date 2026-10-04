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

    it "wires the binding command into launch, so a delivered play binds the pane binding set and session-event use" do
      cli = Workspace.build_cli(output: StringIO.new, error_output: StringIO.new, input: StringIO.new)

      binding_command = cli.instance_variable_get(:@binding_command)
      launch_command = cli.instance_variable_get(:@launch_command)

      expect(launch_command.instance_variable_get(:@binder)).to equal(binding_command)
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
