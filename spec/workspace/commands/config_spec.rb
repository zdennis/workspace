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

    it "accepts locks.idle_grace as seconds or a duration" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("locks.idle_grace", "10m", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"locks" => {"idle_grace" => "10m"}})
      command.set("locks.idle_grace", "90", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"idle_grace" => "90"}})
    end

    ["0", "0s", "-5", "soon", "5d", ""].each do |bad|
      it "rejects locks.idle_grace #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("locks.idle_grace", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid locks.idle_grace/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts locks.ps_timeout as seconds or a duration" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("locks.ps_timeout", "15s", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "15s"}})
      command.set("locks.ps_timeout", "10", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "10"}})
    end

    ["0", "0s", "-5", "soon", "5d", ""].each do |bad|
      it "rejects locks.ps_timeout #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("locks.ps_timeout", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid locks.ps_timeout/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts locks.reap_interval as seconds or a duration" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("locks.reap_interval", "1m", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"locks" => {"reap_interval" => "1m"}})
      command.set("locks.reap_interval", "45", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"reap_interval" => "45"}})
    end

    ["0", "0s", "-5", "soon", "5d", ""].each do |bad|
      it "rejects locks.reap_interval #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("locks.reap_interval", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid locks.reap_interval/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts dev.kill_grace as seconds or a duration, up to the 60s cap" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      command.set("dev.kill_grace", "10s", cwd: project_dir)

      expect(project_settings.load(File.basename(project_dir))).to eq({"dev" => {"kill_grace" => "10s"}})
      command.set("dev.kill_grace", "60s", cwd: project_dir)
      expect(project_settings.load(File.basename(project_dir))).to eq({"dev" => {"kill_grace" => "60s"}})
    end

    ["0", "0s", "-5", "soon", "61s", "2m"].each do |bad|
      it "rejects dev.kill_grace #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("dev.kill_grace", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid dev.kill_grace/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts a dev.stop_timeout duration like 20s" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("dev.stop_timeout", "20s", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"dev" => {"stop_timeout" => "20s"}})
    end

    ["dev.startup_timeout", "dev.ready_timeout"].each do |key|
      it "accepts a #{key} duration like 45s" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")
        name = File.basename(project_dir)

        command.set(key, "45s", cwd: project_dir)

        expect(project_settings.load(name)).to eq({"dev" => {key.split(".").last => "45s"}})
      end

      it "rejects an invalid #{key} duration" do
        command, = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set(key, "soon", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Invalid #{Regexp.escape(key)}/)
      end
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

    it "serializes concurrent set calls via flock instead of clobbering each other" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {}})
      path = project_settings.project_config_path(name)

      threads = 10.times.map do |i|
        Thread.new { command.set("dev.up", "cmd-#{i}", cwd: project_dir) }
      end
      threads.each(&:join)

      # Every write took the lock in turn; the file is left with one
      # consistent value, not a torn/partial write from an interleaved
      # read-modify-write.
      data = project_settings.load(name)
      expect(data["dev"]["up"]).to match(/\Acmd-\d\z/)
      expect(File.exist?("#{path}.lock")).to eq(true)
    end
  end

  describe "#get" do
    it "gets a previously set key and returns true" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"dev" => {"up" => "bin/dev"}})

      result = command.get("dev.up", cwd: project_dir)

      expect(output.string.strip).to eq("bin/dev")
      expect(result).to eq(true)
    end

    it "prints nothing on stdout, a note on stderr, and returns false for a key with no value" do
      output = StringIO.new
      error_output = StringIO.new
      dir = Dir.mktmpdir("ws-config")
      fake_path_config = Struct.new(:workspace_config_dir).new(dir)
      project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
      lineage = Workspace::WorkspaceLineage.new
      file_backup = Workspace::FileBackup.new(output: output)
      command = described_class.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output, error_output: error_output)
      project_dir = Dir.mktmpdir("ws-config-project")

      result = command.get("dev.up", cwd: project_dir)

      expect(output.string).to eq("")
      expect(error_output.string).to include("dev.up is not set")
      expect(result).to eq(false)
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
