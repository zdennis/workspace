require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

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

    it "accepts locks.ps_timeout as seconds or a duration within [1s, 60s]" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("locks.ps_timeout", "15s", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "15s"}})
      command.set("locks.ps_timeout", "10", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "10"}})
      command.set("locks.ps_timeout", "1", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "1"}})
      command.set("locks.ps_timeout", "60s", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"locks" => {"ps_timeout" => "60s"}})
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

    ["0.5", "0.01", "61", "90s", "2m"].each do |bad|
      it "rejects out-of-range locks.ps_timeout #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("locks.ps_timeout", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid locks.ps_timeout.*must be at least 1s and at most 60s/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts alerts.notify and alerts.idle_after" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("alerts.notify", "say \"$WORKSPACE_ALERT_TEXT\"", cwd: project_dir)
      command.set("alerts.idle_after", "15m", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"alerts" => {"notify" => "say \"$WORKSPACE_ALERT_TEXT\"", "idle_after" => "15m"}})
    end

    it "rejects a blank alerts.notify without writing it" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("alerts.notify", "  ", cwd: project_dir) }
        .to raise_error(Workspace::UsageError, /Invalid alerts.notify: must not be blank/)
      expect(project_settings.load(File.basename(project_dir))).to eq({})
    end

    ["0", "-5", "soon"].each do |bad|
      it "rejects alerts.idle_after #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("alerts.idle_after", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid alerts.idle_after/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "accepts handoff.threshold, handoff.check_prompt, and handoff.resume_prompt" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("handoff.threshold", "20", cwd: project_dir)
      command.set("handoff.check_prompt", "Save %{usage} now", cwd: project_dir)
      command.set("handoff.resume_prompt", "Resume %{doc}", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"handoff" => {"threshold" => "20", "check_prompt" => "Save %{usage} now",
                                                               "resume_prompt" => "Resume %{doc}"}})
    end

    ["0", "101", "soon"].each do |bad|
      it "rejects handoff.threshold #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("handoff.threshold", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid handoff.threshold/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
    end

    it "rejects a blank handoff.check_prompt without writing it" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("handoff.check_prompt", "  ", cwd: project_dir) }
        .to raise_error(Workspace::UsageError, /Invalid handoff.check_prompt: must not be blank/)
      expect(project_settings.load(File.basename(project_dir))).to eq({})
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

    it "names the daemon to restart after a restart-required key, for a plain project" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("locks.reap_interval", "1m", cwd: project_dir)

      output = command.instance_variable_get(:@output)
      expect(output.string).to include("workspace agentd #{name} --force, or relaunch")
    end

    it "names the worktree's own daemon (not the parent project) after a restart-required key, inside a worktree" do
      output = StringIO.new
      dir = Dir.mktmpdir("ws-config")
      fake_path_config = Struct.new(:workspace_config_dir).new(dir)
      project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
      lineage = Workspace::WorkspaceLineage.new
      file_backup = Workspace::FileBackup.new(output: output)
      command = described_class.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output)

      root = Dir.mktmpdir("ws-config-repo")
      system("git", "init", "-q", root, out: File::NULL, err: File::NULL)
      system("git", "-C", root, "commit", "--allow-empty", "-q", "-m", "init", out: File::NULL, err: File::NULL)
      worktree_path = File.join(root, ".worktrees", "wt1")
      FileUtils.mkdir_p(File.dirname(worktree_path))
      system("git", "-C", root, "worktree", "add", "-q", "-b", "wt1-branch", worktree_path, out: File::NULL, err: File::NULL)
      File.write(File.join(worktree_path, ".workspace-project"), "myapp.worktree-wt1")

      command.set("locks.reap_interval", "1m", cwd: worktree_path)

      expect(output.string).to include("workspace agentd myapp.worktree-wt1 --force, or relaunch")
      expect(output.string).not_to include("workspace agentd myapp --force")
    ensure
      FileUtils.remove_entry(root) if root && File.directory?(root)
    end

    it "doesn't add a restart hint for a key that takes effect immediately" do
      command, = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      command.set("dev.up", "./start-dev", cwd: project_dir)

      output = command.instance_variable_get(:@output)
      expect(output.string).not_to include("Takes effect")
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

  describe "global keys" do
    it "writes statusline.command to the global config, not a project's" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      command.set("statusline.command", "~/bin/my-statusline", cwd: project_dir)

      expect(project_settings.load_global).to eq({"statusline" => {"command" => "~/bin/my-statusline"}})
      expect(project_settings.load(File.basename(project_dir))).to eq({})
    end

    it "reads statusline.command back with #get" do
      command, = build_command
      command.set("statusline.command", "~/bin/my-statusline")

      expect(command.get("statusline.command")).to be(true)
    end

    it "reports unset when a global key has no value" do
      command, = build_command
      expect(command.get("statusline.command")).to be(false)
    end

    it "unsets a global key" do
      command, project_settings = build_command
      command.set("context.source", "scrape")

      command.unset("context.source")

      expect(project_settings.load_global.dig("context", "source")).to be_nil
    end

    it "accepts context.source of statusline or scrape" do
      command, = build_command
      expect { command.set("context.source", "scrape") }.not_to raise_error
      expect { command.set("context.source", "bogus") }.to raise_error(Workspace::UsageError, /Invalid context.source/)
    end

    it "stores launch.headless globally, accepting only true or false" do
      command, project_settings = build_command
      command.set("launch.headless", "true")

      expect(project_settings.load_global.dig("launch", "headless")).to eq("true")
      expect { command.set("launch.headless", "yes") }.to raise_error(Workspace::UsageError, /Invalid launch.headless/)
    end

    it "requires context.pattern to have exactly one capture group" do
      command, = build_command
      expect { command.set("context.pattern", '(\d+)% ctx') }.not_to raise_error
      expect { command.set("context.pattern", "no groups here") }.to raise_error(Workspace::UsageError, /exactly one capture group/)
      expect { command.set("context.pattern", '(\d+)% (ctx)') }.to raise_error(Workspace::UsageError, /exactly one capture group/)
    end

    it "rejects an invalid regex" do
      command, = build_command
      expect { command.set("context.pattern", "(unterminated") }.to raise_error(Workspace::UsageError)
    end

    it "serializes concurrent global writers" do
      command, project_settings = build_command
      threads = 5.times.map do |i|
        Thread.new { command.set("statusline.command", "cmd-#{i}") }
      end
      threads.each(&:join)

      expect(%w[cmd-0 cmd-1 cmd-2 cmd-3 cmd-4]).to include(project_settings.load_global.dig("statusline", "command"))
    end
  end
end
