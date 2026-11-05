require "tmpdir"
require "json"
require "fileutils"

# Adversarial coverage for H4 (statusLine install): settings-file handling,
# backups, and idempotency edge cases not covered by hook_installer_spec.rb.
RSpec.describe "statusLine install settings-file adversarial cases" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:backup) { Workspace::FileBackup.new(output: output) }
  let(:provider) { Workspace::AgentProvider.find("claude") }
  let(:statusline_command) { "workspace statusline" }
  let(:settings_path) { File.join(tmpdir, ".claude", "settings.json") }
  let(:global_config_dir) { Dir.mktmpdir }
  let(:project_settings) { Workspace::ProjectSettings.new(config: instance_double(Workspace::Config, workspace_config_dir: global_config_dir)) }
  let(:user_settings_dir) { Dir.mktmpdir }
  let(:user_settings_path) { File.join(user_settings_dir, "user-claude-settings.json") }

  subject(:installer) { described_class_installer }

  def described_class_installer
    Workspace::HookInstaller.new(backup: backup, output: output, input: StringIO.new(""), user_settings_path: user_settings_path)
  end

  after do
    FileUtils.remove_entry(tmpdir)
    FileUtils.remove_entry(global_config_dir)
    FileUtils.remove_entry(user_settings_dir)
  end

  def write_settings(hash)
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, JSON.pretty_generate(hash))
  end

  def settings
    JSON.parse(File.read(settings_path))
  end

  def global_config
    project_settings.load_global
  end

  # HS1: user-level settings.json (e.g. ~/.claude/settings.json) is never
  # consulted. install_statusline only reads/writes the project-scoped file
  # (settings_path_for), so a user whose custom statusLine command lives only
  # at the user level has it silently shadowed by Claude's project-settings
  # precedence once workspace writes a project-level statusLine -- and
  # nothing preserves that command into statusline.command, because the
  # installer never even looks for it.
  it "HS1: preserves a user-level statusLine command that isn't present in the project settings file (currently not preserved -- no user-level path is ever read)" do
    File.write(user_settings_path, JSON.pretty_generate("statusLine" => {"type" => "command", "command" => "bash ~/user-statusline.sh"}))

    # No project-level statusLine configured at all.
    installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

    # Expected behavior per AGENT-CONTEXT-RESEARCH.md: the user's pre-existing
    # (non-workspace) command should end up preserved in statusline.command,
    # even though it lived only in the user-level file, not the project file.
    expect(global_config.dig("statusline", "command")).to eq("bash ~/user-statusline.sh")
  end

  # HS2: idempotency check only compares `command`, not `type`. A hand-edited
  # statusLine with a non-"command" type (e.g. Claude adds other types in the
  # future, or a user manually sets something odd) but with our command string
  # already present as the "command" key is treated as fully installed, even
  # though "type" would never actually be honored as "command" by Claude.
  it "HS2: treats a hand-edited statusLine with a non-'command' type as installed merely because 'command' matches" do
    write_settings("statusLine" => {"type" => "not-a-real-type", "command" => statusline_command})

    # A statusLine entry whose type isn't "command" is not actually routed
    # through workspace by Claude, so this should be false; the current
    # implementation only compares the command string and reports true.
    expect(installer.statusline_installed?(provider, tmpdir, statusline_command)).to be false
  end

  # HS3: preserve_existing_statusline_command uses `||=`, so a second project
  # (or worktree) with a *different* pre-existing statusLine command doesn't
  # overwrite the first-preserved one, but must not be dropped silently
  # either: a warning naming both commands lets the user choose.
  it "HS3: warns naming both commands instead of silently dropping a second project's different pre-existing statusLine command" do
    # First project: preserves "first-command" into statusline.command.
    other_root = Dir.mktmpdir
    begin
      FileUtils.mkdir_p(File.join(other_root, ".claude"))
      File.write(File.join(other_root, ".claude", "settings.json"),
        JSON.pretty_generate("statusLine" => {"type" => "command", "command" => "first-command"}))
      installer.install_statusline(provider, other_root, command: statusline_command, project_settings: project_settings)

      # Second project: has a *different* pre-existing command.
      write_settings("statusLine" => {"type" => "command", "command" => "second-command"})
      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(global_config.dig("statusline", "command")).to eq("first-command")
      # "second-command" isn't silently lost: it's named in a warning, along
      # with the value that's already saved, so the user can choose.
      expect(output.string).to include("second-command")
      expect(output.string).to include("first-command")
    ensure
      FileUtils.remove_entry(other_root)
    end
  end

  # HS4: a statusLine value that is a String (or other non-Hash) rather than
  # a Hash -- a form Claude itself accepts for simple shell commands -- makes
  # `current["command"]` blow up, or (per current guard `current.is_a?(Hash)`)
  # is silently treated as "no existing statusLine" and clobbered without
  # preserving the string command anywhere.
  it "HS4: silently drops a string-form statusLine value instead of preserving it" do
    write_settings("statusLine" => "bash ~/legacy-statusline.sh")

    installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

    expect(settings["statusLine"]).to eq("type" => "command", "command" => statusline_command)
    # The legacy string command is gone with no trace in global config.
    expect(global_config.dig("statusline", "command")).to eq("bash ~/legacy-statusline.sh")
  end

  # HS5: if project_settings.with_global_lock raises (e.g. disk full, or the
  # global config dir is unwritable) partway through preserving the existing
  # command, install_statusline should not proceed to overwrite the project
  # settings file with the new statusLine -- otherwise the old command is
  # lost from both places: not preserved in global config (write failed) and
  # no longer present in the settings file (overwritten anyway).
  it "HS5: does not overwrite the settings file's statusLine when preserving the old command into global config fails" do
    write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh"})

    failing_project_settings = instance_double(Workspace::ProjectSettings)
    allow(failing_project_settings).to receive(:with_global_lock).and_raise(Errno::ENOSPC, "no space left")

    expect {
      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: failing_project_settings)
    }.to raise_error(Errno::ENOSPC)

    # The original command must still be intact in the settings file: nothing
    # should have been overwritten given the preservation write failed.
    expect(settings["statusLine"]).to eq("type" => "command", "command" => "bash ~/.claude/statusline-command.sh")
  end
end
