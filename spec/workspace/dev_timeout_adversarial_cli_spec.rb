require "spec_helper"
require "stringio"
require "tmpdir"

# Adversarial probing of the `dev.startup_timeout` / `dev.ready_timeout`
# config keys added in 8016f33. See spec/workspace/commands/config_spec.rb
# and spec/workspace/dev_config_spec.rb for the happy-path coverage this
# commit already added.
RSpec.describe "dev.startup_timeout / dev.ready_timeout adversarial probing" do
  def build_config_command(output: StringIO.new)
    dir = Dir.mktmpdir("ws-config")
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
    lineage = Workspace::WorkspaceLineage.new
    file_backup = Workspace::FileBackup.new(output: output)
    command = Workspace::Commands::Config.new(project_settings: project_settings, lineage: lineage,
      file_backup: file_backup, output: output)
    [command, project_settings]
  end

  # DT1: `locks.idle_grace` (same commit family, same Duration.parse-based
  # validation pattern) rejects 0 via Workspace::LockConfig.parse_idle_grace
  # ("must be greater than 0"). dev.startup_timeout and dev.ready_timeout
  # guard real waits the same way idle_grace guards lock takeover, but
  # validate_value! in lib/workspace/commands/config.rb only calls
  # Workspace::Duration.parse for them, which happily accepts "0" and "0s".
  # A user who fat-fingers `workspace config set dev.ready_timeout 0`
  # (instead of, say, "30") gets no error at set time, and every future
  # `dev up` will fail its ready check (exit 6) instantly regardless of how
  # fast the environment actually starts, silently defeating readiness.
  it "DT1 rejects a zero dev.ready_timeout the same way locks.idle_grace rejects a zero idle_grace" do
    command, = build_config_command
    project_dir = Dir.mktmpdir("ws-config-project")

    expect { command.set("dev.ready_timeout", "0", cwd: project_dir) }
      .to raise_error(Workspace::UsageError, /Invalid dev.ready_timeout/)
  end

  it "DT1 rejects a zero dev.startup_timeout the same way locks.idle_grace rejects a zero idle_grace" do
    command, = build_config_command
    project_dir = Dir.mktmpdir("ws-config-project")

    expect { command.set("dev.startup_timeout", "0s", cwd: project_dir) }
      .to raise_error(Workspace::UsageError, /Invalid dev.startup_timeout/)
  end
end
