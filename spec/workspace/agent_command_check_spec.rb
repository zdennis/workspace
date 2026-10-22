require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Workspace::AgentCommandCheck do
  let(:on_path) { %w[claude codex] }
  let(:which) { ->(name) { on_path.include?(name) } }
  let(:dir) { Dir.mktmpdir("agent-command-check") }
  let(:check) { described_class.new(which: which) }

  after { FileUtils.rm_rf(dir) }

  def make_file(name, mode)
    File.join(dir, name).tap do |path|
      File.write(path, "#!/bin/sh\n")
      File.chmod(mode, path)
    end
  end

  def reason_for(command)
    check.call("agent.commands.claude", command)
    nil
  rescue Workspace::Error => e
    expect(e.code).to eq("agent_command_not_executable")
    e.details
  end

  it "accepts an executable absolute path" do
    path = make_file("claude-dev", 0o755)

    expect(check.call("agent.commands.claude", "#{path} --flag")).to eq([])
  end

  it "follows a symlink to the executable" do
    path = make_file("claude-real", 0o755)
    link = File.join(dir, "claude-link")
    File.symlink(path, link)

    expect(check.call("agent.commands.claude", link)).to eq([])
  end

  it "refuses a missing absolute path" do
    path = File.join(dir, "claude-gone")

    expect(reason_for(path)).to eq("path" => path, "reason" => "missing")
  end

  it "refuses a file that is not executable" do
    path = make_file("claude-plain", 0o644)

    expect(reason_for(path)).to eq("path" => path, "reason" => "not_executable")
  end

  it "refuses a directory" do
    expect(reason_for(dir)).to eq("path" => dir, "reason" => "not_a_file")
  end

  it "checks the program past VAR=value words" do
    path = make_file("claude-dev", 0o755)
    missing = File.join(dir, "claude-gone")

    expect(check.call("agent.commands.claude", "FOO=x #{path}")).to eq([])
    expect(reason_for("FOO=x #{missing}")).to eq("path" => missing, "reason" => "missing")
  end

  it "warns when a bare name is not on PATH" do
    expect(check.call("agent.commands.claude", "claude-dev")).to eq(["claude-dev is not on PATH"])
  end

  it "warns when the program does not look like the agent" do
    expect(check.call("agent.commands.codex", "claude-dev")).to eq(["claude-dev is not on PATH", "claude-dev does not look like a codex command"])
    expect(check.call("agent.commands.codex", "codex")).to eq([])
    expect(check.call("agent.commands.codex", "codexx")).to include("codexx does not look like a codex command")
  end

  it "warns about the family for an absolute path too" do
    path = make_file("other", 0o755)

    expect(check.call("agent.commands.claude", path)).to eq(["other does not look like a claude command"])
  end

  it "checks nothing for another key" do
    expect(check.call("commands.test", "/no/such/thing")).to eq([])
  end
end

RSpec.describe Workspace::Commands::Config, "agent.commands check" do
  let(:dir) { Dir.mktmpdir("agent-command-config") }
  let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:command) do
    described_class.new(project_settings: settings, lineage: Workspace::WorkspaceLineage.new, file_backup: Workspace::FileBackup.new(output: err),
      agent_command_check: Workspace::AgentCommandCheck.new(which: ->(_) { false }), output: out, error_output: err)
  end

  after { FileUtils.rm_rf(dir) }

  it "writes nothing when the absolute path is missing" do
    expect { command.set("agent.commands.claude", "/no/such/claude", scope: "global") }
      .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("agent_command_not_executable") }

    expect(settings.load_global).to eq({})
  end

  it "sets a bare name that is not on PATH, with a warning on stderr and in the result" do
    result = command.set("agent.commands.claude", "claude-dev", scope: "global")

    expect(settings.load_global).to eq("agent" => {"commands" => {"claude" => "claude-dev"}})
    expect(result.warnings).to eq(["claude-dev is not on PATH"])
    expect(err.string).to eq("Warning: claude-dev is not on PATH\n")
  end

  it "reports no warnings for a key without any" do
    result = command.set("alerts.idle_after", "15m", scope: "global")

    expect(result.warnings).to eq([])
    expect(err.string).to eq("")
  end

  it "still masks the value in config show --json" do
    command.set("agent.commands.claude", "claude-dev", scope: "global")
    report = Workspace::ConfigReport.new(project_settings: settings, project_config: instance_double(Workspace::ProjectConfig, available_projects: %w[api], project_root_for: nil),
      notes_dir: Workspace::NotesDir.new(git: Workspace::Git.new))

    row = report.show("api", key: "agent.commands.claude")["keys"].first

    expect(row).to include("value" => nil, "masked" => true)
  end
end
