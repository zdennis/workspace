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
  end
end
