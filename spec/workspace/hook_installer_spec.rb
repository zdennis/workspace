require "tmpdir"
require "json"

RSpec.describe Workspace::HookInstaller do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new("") }
  let(:backup) { Workspace::FileBackup.new(output: output) }
  let(:provider) { Workspace::AgentProvider.find("claude") }
  let(:command) { "workspace session-event" }
  let(:settings_path) { File.join(tmpdir, ".claude", "settings.json") }

  subject(:installer) { described_class.new(backup: backup, output: output, input: input) }

  after { FileUtils.remove_entry(tmpdir) }

  def write_settings(hash)
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, JSON.pretty_generate(hash))
  end

  def settings
    JSON.parse(File.read(settings_path))
  end

  describe "#install" do
    it "creates the settings file when the project has none" do
      installer.install(provider, tmpdir, command)

      expect(settings["hooks"]).to include("SessionStart", "SubagentStop", "PreToolUse")
    end

    it "preserves unrelated settings and the user's own hooks" do
      write_settings(
        "permissions" => {"allow" => ["Bash(ls:*)"]},
        "hooks" => {"Stop" => [{"hooks" => [{"type" => "command", "command" => "my-own-hook"}]}]}
      )

      installer.install(provider, tmpdir, command)

      expect(settings["permissions"]).to eq("allow" => ["Bash(ls:*)"])
      stop_commands = settings["hooks"]["Stop"].flat_map { |e| e["hooks"] }.map { |h| h["command"] }
      expect(stop_commands).to eq(["my-own-hook", command])
    end

    it "backs the file up before changing it" do
      write_settings("hooks" => {})

      installer.install(provider, tmpdir, command)

      backup_file = Dir[File.join(tmpdir, ".claude", "*workspace-backup*")].first
      expect(backup_file).not_to be_nil
      expect(JSON.parse(File.read(backup_file))).to eq("hooks" => {})
      expect(output.string).to include(backup_file)
    end

    it "is a no-op when its hooks are already installed" do
      installer.install(provider, tmpdir, command)
      before = settings

      installer.install(provider, tmpdir, command)

      expect(settings).to eq(before)
      expect(output.string).to include("already installed")
    end

    it "does not write anything on a dry run" do
      installer.install(provider, tmpdir, command, dry_run: true)

      expect(File.exist?(settings_path)).to be false
    end

    it "refuses to touch a settings file it cannot parse" do
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{ not json")

      expect { installer.install(provider, tmpdir, command) }
        .to raise_error(Workspace::Error, /not valid JSON/)
      expect(File.read(settings_path)).to eq("{ not json")
    end
  end

  describe "#installed?" do
    it "is false before install and true after" do
      expect(installer.installed?(provider, tmpdir, command)).to be false
      installer.install(provider, tmpdir, command)
      expect(installer.installed?(provider, tmpdir, command)).to be true
    end
  end

  describe "#preview" do
    it "prints the fragment that would be added" do
      installer.preview(provider, command)

      expect(output.string).to include("SubagentStop", command)
    end
  end
end
