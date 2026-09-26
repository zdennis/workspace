require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::Commands::Config do
  def build_command(output: StringIO.new)
    dir = Dir.mktmpdir("ws-config")
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
    lineage = Workspace::WorkspaceLineage.new
    file_backup = Workspace::FileBackup.new(output: output)
    command = described_class.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output)
    [command, project_settings]
  end

  describe "#set" do
    it "sets a dotted key under the project inferred from cwd" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")

      command.set("dev.up", "./start-dev", cwd: project_dir)

      expect(output.string).to include("Set dev.up = ./start-dev")
      name = File.basename(project_dir)
      expect(project_settings.load(name)).to eq({"dev" => {"up" => "./start-dev"}})
    end

    it "preserves other keys already in the project config" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"hooks" => {"post_launch" => "echo hi"}})

      command.set("dev.up", "./start-dev", cwd: project_dir)

      data = project_settings.load(name)
      expect(data["hooks"]).to eq({"post_launch" => "echo hi"})
      expect(data["dev"]).to eq({"up" => "./start-dev"})
    end

    it "sets a key on an explicit project, ignoring cwd" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      command.set("dev.ready", "port:3000", project: "otherapp", cwd: project_dir)

      expect(project_settings.load("otherapp")).to eq({"dev" => {"ready" => "port:3000"}})
    end

    it "rejects an unknown key" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("dev.bogus", "x", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Unknown config key 'dev.bogus'/)
    end

    it "rejects an invalid dev.stop_timeout duration" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("dev.stop_timeout", "soon", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Invalid dev.stop_timeout/)
    end

    it "accepts a dev.stop_timeout duration like 20s" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("dev.stop_timeout", "20s", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"dev" => {"stop_timeout" => "20s"}})
    end

    it "backs up the project config file before writing to it" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {"up" => "bin/dev"}})
      path = project_settings.project_config_path(name)

      command.set("dev.up", "bin/dev2", cwd: project_dir)

      backups = Dir.glob("#{path}.workspace-backup-*")
      expect(backups).not_to be_empty
    end
  end

  describe "#get" do
    it "gets a previously set key" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {"up" => "bin/dev"}})

      command.get("dev.up", cwd: project_dir)

      expect(output.string.strip).to eq("bin/dev")
    end

    it "prints (unset) for a key with no value" do
      output = StringIO.new
      command, = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")

      command.get("dev.up", cwd: project_dir)

      expect(output.string.strip).to eq("(unset)")
    end

    it "rejects an unknown key" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.get("dev.bogus", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Unknown config key 'dev.bogus'/)
    end
  end

  describe "#unset" do
    it "unsets a key without disturbing others" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {"up" => "bin/dev", "ready" => "port:3000"}})

      command.unset("dev.ready", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"dev" => {"up" => "bin/dev"}})
    end

    it "backs up the project config file before writing to it" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {"up" => "bin/dev"}})
      path = project_settings.project_config_path(name)

      command.unset("dev.up", cwd: project_dir)

      backups = Dir.glob("#{path}.workspace-backup-*")
      expect(backups).not_to be_empty
    end

    it "rejects an unknown key" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.unset("dev.bogus", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Unknown config key 'dev.bogus'/)
    end
  end
end
