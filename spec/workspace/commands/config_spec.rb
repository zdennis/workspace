require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::Commands::Config do
  def build_command(output: StringIO.new, error_output: StringIO.new)
    dir = Dir.mktmpdir("ws-config")
    fake_path_config = Struct.new(:workspace_config_dir).new(dir)
    project_settings = Workspace::ProjectSettings.new(config: fake_path_config)
    lineage = Workspace::WorkspaceLineage.new
    file_backup = Workspace::FileBackup.new(output: output)
    command = described_class.new(project_settings: project_settings, lineage: lineage, file_backup: file_backup, output: output, error_output: error_output)
    remember_last_write(command)
    [command, project_settings]
  end

  # Keeps the result of the latest set or unset on the command, for the specs that look at the write alone.
  def remember_last_write(command)
    command.singleton_class.class_eval do
      attr_reader :last_write

      %i[set unset].each do |name|
        define_method(name) { |*args, **opts| super(*args, **opts).tap { |result| @last_write = result } }
      end
    end
  end

  describe "unparseable config" do
    def corrupt_project(project_settings, name)
      path = project_settings.project_config_path(name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "hooks: [unclosed\n\tbad: yaml")
      path
    end

    it "set refuses and leaves the file as written" do
      command, project_settings = build_command
      path = corrupt_project(project_settings, "broken")

      expect { command.set("dev.up", "x", project: "broken", cwd: Dir.pwd) }
        .to raise_error(Workspace::ConfigParseError, /Cannot parse #{Regexp.escape(path)}/)
      expect(File.read(path)).to eq("hooks: [unclosed\n\tbad: yaml")
      expect(Dir.glob("#{path}.workspace-backup-*")).to be_empty
    end

    it "set tells the user to fix or remove the file" do
      command, project_settings = build_command
      corrupt_project(project_settings, "broken")

      expect { command.set("dev.up", "x", project: "broken", cwd: Dir.pwd) }
        .to raise_error(Workspace::ConfigParseError, /Fix or remove the file, then retry\.\z/)
    end

    it "unset refuses and leaves the file as written" do
      command, project_settings = build_command
      path = corrupt_project(project_settings, "broken")

      expect { command.unset("dev.up", project: "broken", cwd: Dir.pwd) }.to raise_error(Workspace::ConfigParseError)
      expect(File.read(path)).to eq("hooks: [unclosed\n\tbad: yaml")
      expect(Dir.glob("#{path}.workspace-backup-*")).to be_empty
    end

    it "set refuses a global key when the global file is unparseable" do
      command, project_settings = build_command
      path = project_settings.global_config_path
      File.write(path, "a: [\n")

      expect { command.set("launch.headless", "true") }.to raise_error(Workspace::ConfigParseError)
      expect(File.read(path)).to eq("a: [\n")
    end
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

    it "returns the project it set the key for, and nil for a global key" do
      command, = build_command
      expect(command.set("dev.up", "./start-dev", project: "api", cwd: Dir.pwd)).to have_attributes(workspace: "api")
      expect(command.set("launch.headless", "true")).to have_attributes(workspace: nil, layer: "global", scope: "global")
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

      expect { command.set("dev.bogus", "x", cwd: project_dir) }.to raise_error(Workspace::Error, /Unknown config key 'dev.bogus'/) { |e| expect(e.code).to eq("unknown_config_key") }
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

    it "accepts commands.test and commands.lint, reads them back, and refuses a blank one" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("commands.test", "bundle exec rspec", cwd: project_dir)
      command.set("commands.lint", "bundle exec standardrb lib/ spec/", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"commands" => {"test" => "bundle exec rspec", "lint" => "bundle exec standardrb lib/ spec/"}})
      expect(Workspace::CommandsConfig.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings)).for_project(name))
        .to eq(test: "bundle exec rspec", lint: "bundle exec standardrb lib/ spec/")
      expect { command.set("commands.test", "  ", cwd: project_dir) }.to raise_error(Workspace::UsageError, /Invalid commands.test/)
      expect(project_settings.load(name)["commands"]["test"]).to eq("bundle exec rspec")
    end

    it "sets, gets and unsets notes.dir as the raw absolute path" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("notes.dir", "/Users/me/My Notes", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"notes" => {"dir" => "/Users/me/My Notes"}})

      output.truncate(0)
      output.rewind
      expect(command.get("notes.dir", cwd: project_dir)).to eq(true)
      expect(output.string.strip).to eq("/Users/me/My Notes")

      command.unset("notes.dir", cwd: project_dir)
      expect(project_settings.load(name).dig("notes", "dir")).to be_nil
    end

    it "get on an unset notes.dir returns false and writes nothing to stdout" do
      output = StringIO.new
      error_output = StringIO.new
      dir = Dir.mktmpdir("ws-config")
      project_settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir))
      command = described_class.new(project_settings: project_settings, lineage: Workspace::WorkspaceLineage.new, file_backup: Workspace::FileBackup.new(output: output), output: output, error_output: error_output)

      expect(command.get("notes.dir", cwd: Dir.mktmpdir("ws-config-project"))).to eq(false)
      expect(output.string).to eq("")
      expect(error_output.string).to include("is not set")
    end

    describe "notes.dir in a worktree" do
      let(:output) { StringIO.new }
      let(:error_output) { StringIO.new }
      let(:dir) { Dir.mktmpdir("ws-config") }
      let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
      let(:command) do
        described_class.new(project_settings: project_settings, lineage: Workspace::WorkspaceLineage.new,
          file_backup: Workspace::FileBackup.new(output: output), output: output, error_output: error_output)
      end
      let(:root) { Dir.mktmpdir("ws-config-repo") }
      let(:worktree_path) { File.join(root, ".worktrees", "wt1") }

      before do
        system("git", "init", "-q", root, out: File::NULL, err: File::NULL)
        system("git", "-C", root, "commit", "--allow-empty", "-q", "-m", "init", out: File::NULL, err: File::NULL)
        FileUtils.mkdir_p(File.dirname(worktree_path))
        system("git", "-C", root, "worktree", "add", "-q", "-b", "wt1-branch", worktree_path, out: File::NULL, err: File::NULL)
        File.write(File.join(worktree_path, ".workspace-project"), "myapp.worktree-wt1")
      end

      after do
        FileUtils.remove_entry(root) if File.directory?(root)
        FileUtils.remove_entry(dir) if File.directory?(dir)
      end

      it "get does not return the parent project's value" do
        project_settings.save("myapp", {"notes" => {"dir" => "/parent/notes"}})

        expect(command.get("notes.dir", cwd: worktree_path)).to eq(false)
        expect(output.string).to eq("")
        expect(error_output.string).to include("not set for 'myapp.worktree-wt1'")
      end

      it "get returns the worktree's own value" do
        project_settings.save("myapp", {"notes" => {"dir" => "/parent/notes"}})
        project_settings.save("myapp.worktree-wt1", {"notes" => {"dir" => "/wt/notes"}})

        expect(command.get("notes.dir", cwd: worktree_path)).to eq(true)
        expect(output.string.strip).to eq("/wt/notes")
      end

      it "set from the worktree writes the worktree's own file and leaves the project's alone" do
        project_settings.save("myapp", {"notes" => {"dir" => "/parent/notes"}})

        expect(command.set("notes.dir", "/wt/notes", cwd: worktree_path).workspace).to eq("myapp.worktree-wt1")

        expect(project_settings.load("myapp.worktree-wt1")).to eq({"notes" => {"dir" => "/wt/notes"}})
        expect(project_settings.load("myapp")).to eq({"notes" => {"dir" => "/parent/notes"}})
      end

      it "unset from the worktree removes only the worktree's value" do
        project_settings.save("myapp", {"notes" => {"dir" => "/parent/notes"}})
        project_settings.save("myapp.worktree-wt1", {"notes" => {"dir" => "/wt/notes"}})

        command.unset("notes.dir", cwd: worktree_path)

        expect(project_settings.load("myapp.worktree-wt1").dig("notes", "dir")).to be_nil
        expect(project_settings.load("myapp").dig("notes", "dir")).to eq("/parent/notes")
      end

      it "set with a project name from the worktree writes that project's file" do
        command.set("notes.dir", "/shared/notes", project: "myapp", cwd: worktree_path)

        expect(project_settings.load("myapp").dig("notes", "dir")).to eq("/shared/notes")
        expect(project_settings.load("myapp.worktree-wt1")).to eq({})
      end

      it "set with a worktree name writes that worktree's file from anywhere" do
        command.set("notes.dir", "/wt/notes", project: "myapp.worktree-other", cwd: Dir.pwd)

        expect(project_settings.load("myapp.worktree-other").dig("notes", "dir")).to eq("/wt/notes")
      end

      it "refuses to guess when a worktree has no workspace marker" do
        File.delete(File.join(worktree_path, ".workspace-project"))

        expect { command.set("notes.dir", "/wt/notes", cwd: worktree_path) }
          .to raise_error(Workspace::UsageError, /no workspace name.*--name/)
        expect(project_settings.load("myapp")).to eq({})
      end

      it "refuses --scope workspace set, get and unset without writing, when the worktree has no marker" do
        File.delete(File.join(worktree_path, ".workspace-project"))

        expect { command.set("dev.ready_timeout", "90s", scope: "workspace", cwd: worktree_path) }.to raise_error(Workspace::UsageError, /no workspace name/)
        expect { command.get("dev.ready_timeout", scope: "workspace", cwd: worktree_path) }.to raise_error(Workspace::UsageError, /no workspace name/)
        expect { command.unset("dev.ready_timeout", scope: "workspace", cwd: worktree_path) }.to raise_error(Workspace::UsageError, /no workspace name/)
        expect(Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }).to be_empty
      end

      it "refuses edit --scope workspace without writing, when the worktree has no marker" do
        File.delete(File.join(worktree_path, ".workspace-project"))

        expect { command.edit(scope: "workspace", cwd: worktree_path) }.to raise_error(Workspace::UsageError, /no workspace name/)
        expect(Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }).to be_empty
      end

      it "still writes the project file with --scope project from a worktree with no marker" do
        File.delete(File.join(worktree_path, ".workspace-project"))

        result = command.set("dev.ready_timeout", "90s", scope: "project", cwd: worktree_path)

        expect(result.layer).to eq("project")
        expect(project_settings.load(result.workspace).dig("dev", "ready_timeout")).to eq("90s")
      end

      it "set from the main checkout writes the project's file" do
        command.set("notes.dir", "/shared/notes", cwd: root)

        expect(project_settings.load(File.basename(root)).dig("notes", "dir")).to eq("/shared/notes")
      end

      it "sets project-only keys from the worktree in the parent project" do
        command.set("locks.idle_grace", "9m", cwd: worktree_path)

        expect(project_settings.load("myapp").dig("locks", "idle_grace")).to eq("9m")
        expect(project_settings.load("myapp.worktree-wt1")).to eq({})
      end

      it "sets a widened key from the worktree in the worktree's own file" do
        command.set("dev.ready_timeout", "90s", cwd: worktree_path)

        expect(project_settings.load("myapp.worktree-wt1").dig("dev", "ready_timeout")).to eq("90s")
        expect(project_settings.load("myapp")).to eq({})
      end

      it "sets a widened key in the worktree's own file for --name <worktree>, and a project-only key in the parent's" do
        command.set("dev.ready_timeout", "90s", project: "myapp.worktree-other")
        command.set("locks.idle_grace", "9m", project: "myapp.worktree-other")

        expect(project_settings.load("myapp.worktree-other")).to eq("dev" => {"ready_timeout" => "90s"})
        expect(project_settings.load("myapp")).to eq("locks" => {"idle_grace" => "9m"})
        expect(command.get("dev.ready_timeout", project: "myapp.worktree-other")).to be(true)
      end

      it "sets a widened key in the project's file from a main checkout" do
        command.set("dev.ready_timeout", "90s", cwd: root)

        expect(project_settings.load(File.basename(root)).dig("dev", "ready_timeout")).to eq("90s")
      end
    end

    it "refuses a notes.dir with a newline and writes nothing" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("notes.dir", "/x\ny", cwd: project_dir) }
        .to raise_error(Workspace::UsageError, /newline or other control character/)
      expect(project_settings.load(File.basename(project_dir))).to eq({})
    end

    it "refuses a padded absolute notes.dir and writes nothing" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")

      expect { command.set("notes.dir", "  /pad ", cwd: project_dir) }
        .to raise_error(Workspace::UsageError, /leading or trailing whitespace/)
      expect(project_settings.load(File.basename(project_dir))).to eq({})
    end

    ["notes/app", "~/notes", " "].each do |bad|
      it "refuses notes.dir #{bad.inspect} and writes nothing" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("notes.dir", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid notes.dir/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
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

    it "accepts agentd.poll_interval as seconds or a duration, with a restart hint" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)

      command.set("agentd.poll_interval", "45", cwd: project_dir)

      expect(project_settings.load(name)).to eq({"agentd" => {"poll_interval" => "45"}})
      expect(output.string).to include("Takes effect the next time the session monitor starts")
      command.set("agentd.poll_interval", "1m", cwd: project_dir)
      expect(project_settings.load(name)).to eq({"agentd" => {"poll_interval" => "1m"}})
    end

    ["0", "0s", "-5", "soon", "5d", ""].each do |bad|
      it "rejects agentd.poll_interval #{bad.inspect} without writing it" do
        command, project_settings = build_command
        project_dir = Dir.mktmpdir("ws-config-project")

        expect { command.set("agentd.poll_interval", bad, cwd: project_dir) }
          .to raise_error(Workspace::UsageError, /Invalid agentd.poll_interval/)
        expect(project_settings.load(File.basename(project_dir))).to eq({})
      end
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

      command.set("agentd.poll_interval", "1m", cwd: worktree_path)

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

    it "gets a previously set agentd.poll_interval" do
      output = StringIO.new
      command, project_settings = build_command(output: output)
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"agentd" => {"poll_interval" => "45"}})

      result = command.get("agentd.poll_interval", cwd: project_dir)

      expect(output.string.strip).to eq("45")
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

      expect { command.get("dev.bogus", cwd: project_dir) }.to raise_error(Workspace::Error, /Unknown config key 'dev.bogus'/) { |e| expect(e.code).to eq("unknown_config_key") }
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

    it "unsets agentd.poll_interval without disturbing a neighboring alerts block" do
      command, project_settings = build_command
      project_dir = Dir.mktmpdir("ws-config-project")
      name = File.basename(project_dir)
      project_settings.save(name, {"agentd" => {"poll_interval" => "45"}, "alerts" => {"idle_after" => "15m"}})

      command.unset("agentd.poll_interval", cwd: project_dir)

      # The emptied `agentd` block stays behind, like every other unset leaf.
      expect(project_settings.load(name)).to eq({"agentd" => {}, "alerts" => {"idle_after" => "15m"}})
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

      expect { command.unset("dev.bogus", cwd: project_dir) }.to raise_error(Workspace::Error, /Unknown config key 'dev.bogus'/) { |e| expect(e.code).to eq("unknown_config_key") }
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

  describe "backups and comment loss" do
    let(:error_output) { StringIO.new }
    let(:project_dir) { Dir.mktmpdir("ws-config-project") }

    def project_path(project_settings)
      project_settings.project_config_path(File.basename(project_dir))
    end

    it "backs up the global file before a global set and unset" do
      command, project_settings = build_command(error_output: error_output)
      path = project_settings.global_config_path
      project_settings.save_global({"context" => {"source" => "statusline"}})

      command.set("context.source", "scrape")
      expect(Dir.glob("#{path}.workspace-backup-*").size).to eq(1)
      command.unset("context.source")
      expect(Dir.glob("#{path}.workspace-backup-*").size).to eq(2)
      expect(error_output.string).to be_empty
      expect(command.last_write.comments_preserved).to be(true)
    end

    it "notes the lost comment, naming the backup, on a project set" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# my notes\ndev:\n  up: bin/dev\n")

      command.set("dev.up", "bin/dev2", cwd: project_dir)

      backup = Dir.glob("#{path}.workspace-backup-*").first
      expect(File.read(backup)).to include("# my notes")
      expect(error_output.string).to eq("Note: comments in #{path} were not kept; backup at #{backup}\n")
      expect(command.last_write.comments_preserved).to be(false)
      expect(command.last_write.backup).to eq(backup)
    end

    it "notes the lost comment on a global set" do
      command, project_settings = build_command(error_output: error_output)
      path = project_settings.global_config_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "context:\n  source: statusline # why\n")

      command.set("context.source", "scrape")

      expect(error_output.string).to match(/\ANote: comments in #{Regexp.escape(path)} were not kept; backup at #{Regexp.escape(path)}\.workspace-backup-/)
      expect(command.last_write.comments_preserved).to be(false)
    end

    it "notes the lost comment on unset" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "dev:\n  up: bin/dev  # start\n")

      command.unset("dev.up", cwd: project_dir)

      expect(error_output.string).to include("comments in #{path} were not kept")
      expect(command.last_write.comments_preserved).to be(false)
    end

    it "prints no note for a file without comments" do
      command, project_settings = build_command(error_output: error_output)
      project_settings.save(File.basename(project_dir), {"dev" => {"up" => "bin/dev"}})

      command.set("dev.up", "bin/dev2", cwd: project_dir)
      command.unset("dev.up", cwd: project_dir)

      expect(error_output.string).to be_empty
      expect(command.last_write.comments_preserved).to be(true)
    end

    it "ignores a # inside a quoted scalar or glued to a word" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "dev:\n  up: \"echo # hi\"\nalerts:\n  notify: 'say #1'\n  idle_after: a#b\n")

      command.set("dev.up", "bin/dev2", cwd: project_dir)

      expect(error_output.string).to be_empty
      expect(command.last_write.comments_preserved).to be(true)
    end

    it "counts a comment after a quoted value ending in an escaped backslash" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "a: \"b\\\\\" # c\n")

      command.set("dev.up", "bin/dev", cwd: project_dir)

      expect(command.last_write.comments_preserved).to be(false)
    end

    it "counts a comment-only file" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# just a note\n")

      command.set("dev.up", "bin/dev", cwd: project_dir)

      expect(command.last_write.comments_preserved).to be(false)
      expect(error_output.string).to include("comments in #{path} were not kept")
    end

    it "does not count a # inside a plain value as a comment" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "alerts:\n  notify: open http://x/#y\n")

      command.set("dev.up", "bin/dev", cwd: project_dir)

      expect(command.last_write.comments_preserved).to be(true)
      expect(error_output.string).to be_empty
    end

    it "takes no backup and prints no note for a file that does not exist yet" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)

      command.set("dev.up", "bin/dev", cwd: project_dir)

      expect(Dir.glob("#{path}.workspace-backup-*")).to be_empty
      expect(error_output.string).to be_empty
      expect(command.last_write.backup).to be_nil
      expect(command.last_write.comments_preserved).to be(true)
    end

    it "returns the write on every successful project and global set and unset" do
      command, project_settings = build_command(error_output: error_output)
      project_settings.save_global({})
      [
        -> { command.set("dev.up", "bin/dev", cwd: project_dir) },
        -> { command.unset("dev.up", cwd: project_dir) },
        -> { command.unset("dev.up", cwd: project_dir) },
        -> { command.set("context.source", "scrape") },
        -> { command.unset("context.source") },
        -> { command.unset("context.source") }
      ].each do |step|
        step.call
        expect(command.last_write).to be_a(Workspace::Commands::Config::Result)
      end
    end

    it "still writes through a temp file and rename, leaving no temp file" do
      command, project_settings = build_command(error_output: error_output)
      path = project_path(project_settings)

      expect(File).to receive(:rename).with(/\A#{Regexp.escape(path)}\.tmp\d+\z/, path).and_call_original
      command.set("dev.up", "bin/dev", cwd: project_dir)

      expect(Dir.glob("#{path}.tmp*")).to be_empty
    end

    it "takes no backup and leaves an unparseable global file untouched" do
      command, project_settings = build_command(error_output: error_output)
      path = project_settings.global_config_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "context: [unclosed\n")

      expect { command.set("context.source", "scrape") }.to raise_error(Workspace::ConfigParseError)

      expect(File.read(path)).to eq("context: [unclosed\n")
      expect(Dir.glob("#{path}.workspace-backup-*")).to be_empty
    end
  end

  describe "recording config_changed" do
    let(:event_log) { CLITestHelpers::FakeEventLog.new }

    def build_logged_command(log = event_log)
      dir = Dir.mktmpdir("ws-config-events")
      settings = Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir))
      output = StringIO.new
      described_class.new(project_settings: settings, lineage: Workspace::WorkspaceLineage.new,
        file_backup: Workspace::FileBackup.new(output: output), event_log: log, output: output)
    end

    it "records a project set with the key name and not the value" do
      build_logged_command.set("dev.up", "SECRET_TOKEN=abc ./go", project: "api", cwd: Dir.pwd)

      expect(event_log.events).to eq([{"type" => "config_changed", "project" => "api",
                                       "data" => {"workspace" => "api", "layer" => "project", "via" => "set", "keys" => ["dev.up"]}}])
      expect(event_log.events.to_s).not_to include("SECRET_TOKEN")
    end

    it "records a project unset" do
      command = build_logged_command
      command.set("dev.up", "x", project: "api", cwd: Dir.pwd)
      command.unset("dev.up", project: "api", cwd: Dir.pwd)

      expect(event_log.events.last).to eq({"type" => "config_changed", "project" => "api",
        "data" => {"workspace" => "api", "layer" => "project", "via" => "unset", "keys" => ["dev.up"]}})
    end

    it "records a global set and unset with an empty project string and scope global" do
      command = build_logged_command
      command.set("launch.headless", "true")
      command.unset("launch.headless")

      expect(event_log.events.map { |e| [e["project"], e["data"]["layer"], e["data"]["via"]] })
        .to eq([["", "global", "set"], ["", "global", "unset"]])
      expect(event_log.events.map { |e| e["data"]["scope"] }).to eq(["global", "global"])
      expect(event_log.events.map { |e| e["data"].key?("workspace") }).to eq([false, false])
    end

    it "records nothing for a rejected key, value or unparseable file" do
      command = build_logged_command
      expect { command.set("dev.bogus", "x", project: "api", cwd: Dir.pwd) }.to raise_error(Workspace::Error) { |e| expect(e.details).to eq({"key" => "dev.bogus"}) }
      expect { command.set("dev.stop_timeout", "soon", project: "api", cwd: Dir.pwd) }.to raise_error(Workspace::UsageError)

      expect(event_log.events).to be_empty
    end

    it "writes the config and prints its message when the log can't be written" do
      broken = CLITestHelpers.unwritable_event_log(Dir.mktmpdir("ws-config-broken"))
      command = build_logged_command(broken)

      expect(command.set("dev.up", "./go", project: "api", cwd: Dir.pwd)).to have_attributes(workspace: "api", layer: "project", scope: "project")
    end
  end

  describe "scopes" do
    let(:output) { StringIO.new }
    let(:error_output) { StringIO.new }
    let(:known) { %w[myapp myapp.worktree-a myapp.worktree-b other] }
    let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: known) }
    let(:dir) { Dir.mktmpdir("ws-config-scope") }
    let(:settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
    let(:command) do
      described_class.new(project_settings: settings, lineage: Workspace::WorkspaceLineage.new, file_backup: Workspace::FileBackup.new(output: output),
        project_config: project_config, output: output, error_output: error_output)
    end

    after { FileUtils.rm_rf(dir) }

    def refused(code = "scope_not_allowed")
      raise_error(Workspace::Error) { |e| expect(e.code).to eq(code) }
    end

    describe "#edit" do
      let(:project_file) { settings.project_config_path("myapp") }
      let(:worktree_file) { settings.project_config_path("myapp.worktree-a") }

      it "creates a comment-header stub for the global file, through a rename" do
        result = command.edit(scope: "global", cwd: Dir.pwd)

        expect(result).to have_attributes(workspace: nil, layer: "global", scope: "global", path: settings.global_config_path, created: true)
        expect(File.read(settings.global_config_path)).to eq("# workspace config (global). See docs/README.config.md\n")
        expect(YAML.safe_load_file(settings.global_config_path)).to be_nil
        expect(Dir.glob("#{settings.global_config_path}.tmp*")).to be_empty
      end

      it "opens the project's file for --scope project, even from a worktree name" do
        result = command.edit(scope: "project", project: "myapp.worktree-a")

        expect(result).to have_attributes(workspace: "myapp", layer: "project", scope: "project", path: project_file, created: true)
        expect(File.exist?(worktree_file)).to be(false)
      end

      it "opens the worktree's own file for --scope workspace and by default" do
        expect(command.edit(scope: "workspace", project: "myapp.worktree-a")).to have_attributes(workspace: "myapp.worktree-a", layer: "worktree", scope: "workspace", path: worktree_file, created: true)
        expect(command.edit(scope: "worktree", project: "myapp.worktree-a")).to have_attributes(layer: "worktree", created: false)
        FileUtils.rm_f(worktree_file)
        expect(command.edit(project: "myapp.worktree-a")).to have_attributes(layer: "worktree", path: worktree_file)
      end

      it "treats --scope workspace in a main checkout as the project file" do
        expect(command.edit(scope: "workspace", project: "myapp")).to have_attributes(workspace: "myapp", layer: "project", scope: "project", path: project_file)
      end

      it "leaves an existing file untouched" do
        FileUtils.mkdir_p(File.dirname(project_file))
        File.write(project_file, "# mine\ndev:\n  up: x\n")

        expect(command.edit(scope: "project", project: "myapp")).to have_attributes(created: false)
        expect(File.read(project_file)).to eq("# mine\ndev:\n  up: x\n")
      end

      it "refuses an unknown workspace at workspace scope, writing nothing" do
        expect { command.edit(scope: "workspace", project: "nope.worktree-z") }.to refused("unknown_workspace")
        expect(File.exist?(settings.project_config_path("nope.worktree-z"))).to be(false)
      end

      it "refuses an unknown scope" do
        expect { command.edit(scope: "everywhere", project: "myapp") }.to raise_error(Workspace::UsageError, /Unknown scope 'everywhere'/)
      end
    end

    describe "#set" do
      it "writes the project file from a worktree name with --scope project" do
        result = command.set("dev.ready_timeout", "90s", project: "myapp.worktree-a", scope: "project")

        expect(settings.load("myapp")).to eq({"dev" => {"ready_timeout" => "90s"}})
        expect(File.exist?(settings.project_config_path("myapp.worktree-a"))).to be(false)
        expect(result).to have_attributes(workspace: "myapp", layer: "project", scope: "project", path: settings.project_config_path("myapp"))
      end

      it "writes the worktree's own file with --scope workspace, and --scope worktree is the same" do
        command.set("dev.ready_timeout", "90s", project: "myapp.worktree-a", scope: "workspace")
        result = command.set("dev.ready", "curl x", project: "myapp.worktree-a", scope: "worktree")

        expect(settings.load("myapp.worktree-a")).to eq({"dev" => {"ready_timeout" => "90s", "ready" => "curl x"}})
        expect(settings.load("myapp")).to eq({})
        expect(result).to have_attributes(workspace: "myapp.worktree-a", layer: "worktree", scope: "workspace")
      end

      it "writes the global file with --scope global, for a key that is also layered" do
        result = command.set("alerts.idle_after", "20m", project: "myapp", scope: "global")

        expect(settings.load_global).to eq({"alerts" => {"idle_after" => "20m"}})
        expect(settings.load("myapp")).to eq({})
        expect(result).to have_attributes(workspace: nil, layer: "global", scope: "global", path: settings.global_config_path)
      end

      it "lets a project override a global key (workflows.defaults.include), and keeps writing global with no scope" do
        command.set("workflows.defaults.include", "commits", project: "myapp", scope: "project")
        expect(settings.load("myapp")).to eq({"workflows" => {"defaults" => {"include" => "commits"}}})
        expect(settings.load_global).to eq({})

        command.set("workflows.defaults.include", "review", project: "myapp")
        expect(settings.load_global).to eq({"workflows" => {"defaults" => {"include" => "review"}}})
      end

      it "treats --scope workspace in a main checkout as the project file and says so in the result" do
        result = command.set("dev.ready_timeout", "90s", project: "myapp", scope: "workspace")

        expect(settings.load("myapp")).to eq({"dev" => {"ready_timeout" => "90s"}})
        expect(result).to have_attributes(workspace: "myapp", layer: "project", scope: "project")
      end

      it "with no scope writes the highest allowed layer for an explicit worktree name" do
        command.set("locks.idle_grace", "10m", project: "myapp.worktree-a")
        command.set("dev.ready_timeout", "90s", project: "myapp.worktree-a")
        command.set("notes.dir", "/n", project: "myapp.worktree-a")

        expect(settings.load("myapp")).to eq({"locks" => {"idle_grace" => "10m"}})
        expect(settings.load("myapp.worktree-a")).to eq({"dev" => {"ready_timeout" => "90s"}, "notes" => {"dir" => "/n"}})
      end

      it "refuses a scope the key does not allow, naming the allowed scopes, and writes nothing" do
        expect { command.set("statusline.command", "x", project: "myapp", scope: "project") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("scope_not_allowed")
          expect(e.details).to eq({"key" => "statusline.command", "scope" => "project", "allowed" => ["global"]})
        }
        expect { command.set("locks.idle_grace", "5m", project: "myapp.worktree-a", scope: "workspace") }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to include("key" => "locks.idle_grace", "allowed" => ["project"])
        }
        expect { command.set("notes.default_dir", "x", project: "myapp", scope: "workspace") }.not_to raise_error
        expect { command.set("notes.default_dir", "x", project: "myapp.worktree-a", scope: "workspace") }.to raise_error(Workspace::Error) { |e|
          expect(e.details["allowed"]).to eq(%w[global project])
        }
        expect(Dir.glob(File.join(dir, "**", "*.yml")).map { |f| File.basename(f) }).to eq(["myapp.yml"])
      end

      it "refuses a global scope for a project-only key" do
        expect { command.set("dev.stop_timeout", "20s", project: "myapp", scope: "global") }.to raise_error(Workspace::Error) { |e|
          expect(e.details).to eq({"key" => "dev.stop_timeout", "scope" => "global", "allowed" => ["project"]})
        }
      end

      it "refuses an unknown scope as a usage error" do
        expect { command.set("dev.up", "x", project: "myapp", scope: "team") }.to raise_error(Workspace::UsageError, /Unknown scope 'team'/)
      end

      it "knows a workspace whose name differs from its config only in case" do
        expect { command.set("dev.ready_timeout", "90s", project: "MyApp.worktree-a", scope: "workspace") }.not_to raise_error
      end

      it "refuses --scope workspace for a workspace nothing knows about, but not --scope project" do
        expect { command.set("dev.ready_timeout", "90s", project: "ghost.worktree-x", scope: "workspace") }.to raise_error(Workspace::Error) { |e|
          expect(e.code).to eq("unknown_workspace")
          expect(e.details).to eq({"name" => "ghost.worktree-x"})
        }
        expect(File.exist?(settings.project_config_path("ghost.worktree-x"))).to be(false)

        expect { command.set("dev.ready_timeout", "90s", project: "ghost.worktree-x", scope: "project") }.not_to raise_error
        expect(settings.load("ghost")).to eq({"dev" => {"ready_timeout" => "90s"}})
      end

      it "accepts --scope workspace for a workspace that only has a config file" do
        settings.save("quiet.worktree-q", {})

        expect { command.set("dev.ready_timeout", "90s", project: "quiet.worktree-q", scope: "workspace") }.not_to raise_error
      end

      it "names every daemon a project-scope key reaches, siblings included, when set through a worktree name" do
        command.set("locks.reap_interval", "1m", project: "myapp.worktree-a", scope: "project")

        expect(output.string).to include("Takes effect the next time the session monitor starts " \
          "(workspace agentd myapp --force, workspace agentd myapp.worktree-a --force, workspace agentd myapp.worktree-b --force, or relaunch).")
        expect(output.string).not_to include("agentd other")
      end

      it "names only the workspace's daemon for a workspace-scope write, and every known one for a global write" do
        command.set("agentd.poll_interval", "1m", project: "myapp.worktree-a", scope: "workspace")
        expect(output.string).to include("(workspace agentd myapp.worktree-a --force, or relaunch)")

        output.truncate(0)
        command.set("agentd.poll_interval", "1m", project: "myapp", scope: "global")
        expect(output.string).to include("(4 workspaces' session monitors read it; run `workspace daemon restart --all`, or relaunch)")
      end

      it "returns the write's outcome and logs the real layer" do
        events = []
        event_log = Object.new
        event_log.define_singleton_method(:record) { |**args| events << args }
        logged = described_class.new(project_settings: settings, lineage: Workspace::WorkspaceLineage.new, file_backup: Workspace::FileBackup.new(output: output),
          event_log: event_log, project_config: project_config, output: output, error_output: error_output)

        result = logged.set("dev.ready_timeout", "90s", project: "myapp.worktree-a", scope: "workspace")

        expect(result).to have_attributes(key: "dev.ready_timeout", comments_preserved: true, backup: nil, affects: ["myapp.worktree-a"])
        expect(events.last[:data]).to include("layer" => "worktree", "via" => "set", "workspace" => "myapp.worktree-a")
      end

      it "reports comment loss in the result of a scoped write" do
        path = settings.project_config_path("myapp")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "# keep\ndev:\n  up: a\n")

        result = command.set("dev.up", "b", project: "myapp.worktree-a", scope: "project")

        expect(result.comments_preserved).to be(false)
        expect(result.backup).to start_with("#{path}.workspace-backup-")
      end
    end

    describe "#get" do
      before do
        settings.save("myapp", {"dev" => {"ready_timeout" => "120s"}})
        settings.save("myapp.worktree-a", {"dev" => {"ready_timeout" => "90s"}})
        settings.save_global({"dev" => {"release_on_session_end" => "false"}})
      end

      it "reads only the named layer's file" do
        expect(command.get("dev.ready_timeout", project: "myapp.worktree-a", scope: "project")).to be(true)
        expect(output.string.strip).to eq("120s")
        output.truncate(0)
        expect(command.get("dev.ready_timeout", project: "myapp.worktree-a", scope: "workspace")).to be(true)
        expect(output.string.strip).to eq("90s")
        output.truncate(0)
        expect(command.get("dev.release_on_session_end", project: "myapp.worktree-a", scope: "workspace")).to be(false)
        expect(error_output.string).to include("dev.release_on_session_end is not set for 'myapp.worktree-a'.")
      end

      it "reads the global file for a global scope on a layered key" do
        expect(command.get("dev.release_on_session_end", project: "myapp", scope: "global")).to be(true)
        expect(output.string.strip).to eq("false")
      end

      it "reads the file a no-scope set would write for an explicit worktree name" do
        expect(command.get("dev.ready_timeout", project: "myapp.worktree-a")).to be(true)
        expect(output.string.strip).to eq("90s")
      end

      it "refuses a scope the key does not allow" do
        expect { command.get("statusline.command", project: "myapp", scope: "workspace") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("scope_not_allowed") }
      end
    end

    describe "refusal message" do
      it "echoes the scope typed, says the project file is meant in a main checkout, and gives the reason and the scope to use" do
        expect { command.set("statusline.command", "x", project: "myapp", scope: "workspace") }.to raise_error(Workspace::Error) { |e|
          expect(e.message).to eq("statusline.command is a machine-wide setting, so it can't be set in the workspace scope (the project file here). Use --scope global.")
          expect(e.details).to eq({"key" => "statusline.command", "scope" => "workspace", "allowed" => ["global"]})
        }
      end

      it "names the typed scope for a worktree and for get and unset" do
        expect { command.get("dev.stop_timeout", project: "myapp.worktree-a", scope: "workspace") }.to raise_error(Workspace::Error) { |e|
          expect(e.message).to eq("dev.stop_timeout is a project-wide setting shared by its worktrees, so it can't be read from the workspace scope. Use --scope project.")
        }
        expect { command.unset("statusline.command", project: "myapp", scope: "project") }.to raise_error(Workspace::Error) { |e|
          expect(e.message).to eq("statusline.command is a machine-wide setting, so it can't be unset in the project scope. Use --scope global.")
        }
      end

      it "reports an unknown workspace as Unknown workspace for --scope workspace" do
        expect { command.set("dev.ready_timeout", "90s", project: "nosuch.worktree-x", scope: "workspace") }
          .to raise_error(Workspace::Error, "Unknown workspace 'nosuch.worktree-x'") { |e| expect(e.code).to eq("unknown_workspace") }
      end

      it "rejects an unknown scope as a usage error" do
        expect { command.set("dev.up", "x", project: "myapp", scope: "bogus") }.to raise_error(Workspace::UsageError, "Unknown scope 'bogus'. Use global, project or workspace.")
      end
    end

    describe "unset of a key that is not set" do
      it "is a no-op: nothing written, no backup, and the text says so" do
        settings.save("myapp", {"dev" => {"up" => "x"}})
        path = settings.project_config_path("myapp")
        before_text = File.read(path)

        result = command.unset("dev.ready_timeout", project: "myapp", scope: "project")

        expect(result.changed).to be(false)
        expect(File.read(path)).to eq(before_text)
        expect(Dir.glob("#{path}.workspace-backup-*")).to be_empty
        expect(output.string).to include("dev.ready_timeout was not set for 'myapp'; nothing changed.")
      end

      it "is a no-op for a missing file and for the global file" do
        expect(command.unset("dev.ready_timeout", project: "myapp", scope: "project").changed).to be(false)
        expect(command.unset("launch.headless", project: "myapp").changed).to be(false)
        expect(File.exist?(settings.global_config_path)).to be(false)
      end
    end

    describe "restart hint" do
      it "prints on unset of a restart-required key, listing a few workspaces" do
        settings.save("myapp.worktree-a", {"agentd" => {"poll_interval" => "1m"}})

        command.unset("agentd.poll_interval", project: "myapp.worktree-a", scope: "workspace")

        expect(output.string).to include("Takes effect the next time the session monitor starts (workspace agentd myapp.worktree-a --force, or relaunch).")
      end

      it "condenses a global write over many workspaces to a count and one command" do
        command.set("alerts.idle_after", "20m", project: "myapp", scope: "global")

        expect(output.string).to include("(4 workspaces' session monitors read it; run `workspace daemon restart --all`, or relaunch)")
        expect(output.string).not_to include("agentd myapp --force")
      end
    end

    describe "#unset" do
      before do
        settings.save("myapp", {"dev" => {"ready_timeout" => "120s"}})
        settings.save("myapp.worktree-a", {"dev" => {"ready_timeout" => "90s"}})
      end

      it "removes the key from the named layer only" do
        result = command.unset("dev.ready_timeout", project: "myapp.worktree-a", scope: "workspace")

        expect(settings.load("myapp.worktree-a")).to eq({"dev" => {}})
        expect(settings.load("myapp")).to eq({"dev" => {"ready_timeout" => "120s"}})
        expect(result).to have_attributes(layer: "worktree", scope: "workspace", workspace: "myapp.worktree-a")
      end

      it "removes it from the project file with --scope project" do
        command.unset("dev.ready_timeout", project: "myapp.worktree-a", scope: "project")

        expect(settings.load("myapp")).to eq({"dev" => {}})
        expect(settings.load("myapp.worktree-a")).to eq({"dev" => {"ready_timeout" => "90s"}})
      end

      it "refuses a scope the key does not allow and leaves the files alone" do
        expect { command.unset("dev.stop_timeout", project: "myapp.worktree-a", scope: "workspace") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("scope_not_allowed") }
        expect(settings.load("myapp.worktree-a")).to eq({"dev" => {"ready_timeout" => "90s"}})
      end
    end

    describe "an unparseable file" do
      it "is refused with config_parse, naming the file and quoting no value" do
        path = settings.project_config_path("myapp")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "dev:\n  up: sekrit-token-123\n  ready: [unclosed\n")

        expect { command.set("dev.ready_timeout", "90s", project: "myapp.worktree-a", scope: "project") }.to raise_error(Workspace::ConfigParseError) { |e|
          expect(e.code).to eq("config_parse")
          expect(e.details["path"]).to eq(path)
          expect(e.message).not_to include("sekrit-token-123")
          expect(e.details["reason"]).not_to include("sekrit-token-123")
        }
        expect(File.read(path)).to include("sekrit-token-123")
      end
    end
  end

  describe "#keys" do
    # The key lines of a list view, without the footer.
    def key_rows(**opts)
      keys_output(**opts).split("\n\n").first.lines.map(&:chomp)
    end

    def keys_output(**opts)
      output = StringIO.new
      command, = build_command(output: output)
      command.keys(**opts)
      output.string
    end

    it "lists every key on one line with name, type, default and doc, in aligned columns" do
      lines = key_rows

      expect(lines.size).to eq(Workspace::ConfigSchema.all.size)
      row = lines.find { |line| line.start_with?("dev.stop_timeout") }
      expect(row).to match(/\Adev\.stop_timeout\s+project\s+set\s+duration\s+20s\s+Grace period/)
      expect(lines.find { |line| line.start_with?("dev.up ") }).to match(/\Adev\.up\s+project\s+set\s+command\s+\(unset\)\s+Command that starts/)
      expect(lines.map { |line| line.index("duration") || line.index("command") }.compact.uniq.size).to be <= 3
    end

    it "prints the full entry for a query that equals a key name" do
      text = keys_output(query: "locks.ps_timeout")

      expect(text).to include("locks.ps_timeout", "Type:     duration (unit seconds; min 1; max 60)", "Default:  5s",
        "Layers:   project", "Settable: yes", "Applies:  daemon restart",
        "workspace config set locks.ps_timeout 5s")
    end

    it "derives examples from choices and quotes values that need it" do
      expect(keys_output(query: "launch.headless")).to include("workspace config set launch.headless true", "workspace config set launch.headless false")
      expect(keys_output(query: "commands.test")).to include("workspace config set commands.test 'bundle exec rspec'")
    end

    it "gives no set lines for a key set refuses" do
      text = keys_output(query: "context.patterns")

      expect(text).to include("Settable: no")
      expect(text).not_to include("config set context.patterns")
    end

    it "matches a name prefix or part, in any case, and lists the matches" do
      expect(key_rows(query: "LOCKS.").map { |l| l.split.first }).to eq(%w[locks.idle_grace locks.ps_timeout locks.reap_interval])
      expect(key_rows(query: "ready").map { |l| l.split.first }).to include("dev.ready", "dev.ready_timeout")
    end

    it "matches the doc text" do
      names = key_rows(query: "timeout").map { |l| l.split.first }

      expect(names).to include("dev.startup_timeout", "locks.ps_timeout", "dev.stop_timeout")
      expect(names).not_to include("dev.up")
    end

    it "keeps the text of a Markdown link in the list view" do
      line = key_rows.find { |l| l.start_with?("pipeline") }

      expect(line).to include("Deprecated (use `workspace workflow`)")
    end

    it "shows scope and a settable marker in the list, and a footer that --json lacks" do
      lines = key_rows

      expect(lines.grep(/\Ahooks\s/).map { |l| l.split[1] }).to eq(%w[global project])
      expect(lines.find { |l| l.start_with?("dev.up ") }.split[2]).to eq("set")
      expect(lines.find { |l| l.start_with?("layouts") }.split[2]).to eq("-")
      expect(keys_output.lines.last.chomp).to eq("Run `workspace config keys <name>` for details and examples.")
      expect(keys_output(json: true)).not_to include("Run `workspace config keys")
    end

    it "cuts a long doc at the end of its first sentence when that fits, never inside an e.g. fragment" do
      command, = build_command
      summary = ->(doc) { command.send(:key_summary, doc) }

      expect(summary.call("Short first sentence. " + "More words follow here. " * 5)).to eq("Short first sentence.")
      expect(summary.call("Grace period before force-stopping the dev environment, e.g. `20s` or `20`, and then some more words")).to eq("Grace period before force-stopping the dev environment...")
      expect(summary.call("Size warning threshold (e.g. 10kb). " + "x " * 60)).to start_with("Size warning threshold (e.g. 10kb).").and(end_with("...").or(end_with("10kb).")))
      expect(key_rows.grep(/e\.g\.\s*\.\.\.|\(\.\.\./)).to be_empty
    end

    it "shows the scope in the detail view" do
      expect(keys_output(query: "launch.headless")).to include("Scope:    global")
    end

    it "keeps only settable keys with --settable" do
      names = key_rows(settable: true).map { |l| l.split.first }

      expect(names).to eq(Workspace::ConfigSchema.settable_names)
      expect(names).not_to include("hooks")
    end

    it "prints one document with a keys array for --json, also for one key" do
      doc = JSON.parse(keys_output(query: "dev.kill_grace", json: true))

      expect(doc).to include("ok" => true, "schema_version" => 1)
      expect(doc["keys"].size).to eq(1)
      expect(doc["keys"].first).to eq(
        "name" => "dev.kill_grace", "scope" => "project", "doc" => Workspace::ConfigSchema.key("dev.kill_grace").doc,
        "type" => "duration", "default" => 2, "choices" => nil, "min" => nil, "max" => 60, "unit" => "seconds",
        "layers" => ["project"], "settable" => true, "applies" => "next_call", "restart" => false, "sensitive" => false,
        "examples" => ["2s", "10s"]
      )
      all = JSON.parse(keys_output(json: true))["keys"]
      expect(all.size).to eq(Workspace::ConfigSchema.all.size)
      expect(all.find { |k| k["name"] == "dev.up" }).to include("sensitive" => true, "default" => nil)
    end

    it "says no settable key matches when --settable filters out the exact name" do
      command, = build_command

      expect { command.keys(query: "layouts", settable: true) }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_config_key")
        expect(e.message).to include("No settable config key matches 'layouts'")
        expect(e.details).to eq("key" => "layouts", "settable" => true)
      }
    end

    it "prints the full entry for an exact settable name with --settable" do
      expect(keys_output(query: "dev.up", settable: true)).to include("Settable: yes", "workspace config set dev.up ./bin/dev")
    end

    it "never reads the stored values" do
      command, project_settings = build_command
      expect(project_settings).not_to receive(:load)
      expect(project_settings).not_to receive(:load_global)

      command.keys
    end

    it "fails with unknown_config_key and a hint when nothing matches" do
      command, = build_command

      expect { command.keys(query: "zzz-nope") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_config_key")
        expect(e.message).to include("No config key matches 'zzz-nope'", "workspace config keys")
      }
    end

    it "points the unknown-key error of set at config keys" do
      command, = build_command

      expect { command.set("nope", "x") }.to raise_error(Workspace::Error, /workspace config keys/)
    end
  end
end
