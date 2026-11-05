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
  let(:global_config_dir) { Dir.mktmpdir }
  let(:project_settings) { Workspace::ProjectSettings.new(config: instance_double(Workspace::Config, workspace_config_dir: global_config_dir)) }
  let(:user_settings_dir) { Dir.mktmpdir }
  let(:user_settings_path) { File.join(user_settings_dir, "user-settings.json") }

  subject(:installer) { described_class.new(backup: backup, output: output, input: input, user_settings_path: user_settings_path) }

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

  describe "local: true (a worktree)" do
    let(:local_path) { File.join(tmpdir, ".claude", "settings.local.json") }
    let(:statusline) { "workspace statusline" }

    def local_settings = JSON.parse(File.read(local_path))

    def install_all
      installer.install(provider, tmpdir, command, quiet: true, local: true)
      installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true, local: true)
    end

    it "writes hooks and statusLine to settings.local.json and leaves settings.json untouched" do
      write_settings("permissions" => {"allow" => []})
      before = File.read(settings_path)

      install_all

      expect(local_settings["hooks"]).to have_key("PreToolUse")
      expect(local_settings["statusLine"]).to include("command" => statusline)
      expect(File.read(settings_path)).to eq(before)
    end

    it "writes nothing when the tracked settings.json already holds equal entries" do
      installer.install(provider, tmpdir, command, quiet: true)
      installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true)
      before = File.read(settings_path)

      expect(installer.install(provider, tmpdir, command, quiet: true, local: true)).to be false
      expect(installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true, local: true)).to eq([])

      expect(File).not_to exist(local_path)
      expect(File.read(settings_path)).to eq(before)
    end

    it "writes nothing a second time when settings.local.json already holds them" do
      install_all
      before = File.read(local_path)

      install_all

      expect(File.read(local_path)).to eq(before)
    end

    it "merges into an existing settings.local.json instead of replacing it" do
      FileUtils.mkdir_p(File.dirname(local_path))
      File.write(local_path, JSON.generate("permissions" => {"allow" => ["Bash(ls)"]}, "hooks" => {"PreToolUse" => [{"matcher" => "Bash", "hooks" => [{"type" => "command", "command" => "mine.sh"}]}]}))

      install_all

      expect(local_settings["permissions"]).to eq("allow" => ["Bash(ls)"])
      expect(local_settings["hooks"]["PreToolUse"].flat_map { |g| g["hooks"].map { |h| h["command"] } }).to include("mine.sh", provider.hook_command(command))
    end

    it "preserves a differing tracked statusLine with the notice and does not modify settings.json" do
      write_settings("statusLine" => {"type" => "command", "command" => "mine.sh"})
      before = File.read(settings_path)

      notices = installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true, local: true)

      expect(notices.join).to include("mine.sh")
      expect(local_settings["statusLine"]["command"]).to eq(statusline)
      expect(File.read(settings_path)).to eq(before)
    end

    it "writes nothing to local when the tracked file holds an older workspace hook, and says how to refresh it" do
      stale = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => provider.hook_command(command)}]}]}}
      write_settings(stale)
      before = File.read(settings_path)

      expect(installer.install(provider, tmpdir, command, local: true)).to be false

      expect(File).not_to exist(local_path)
      expect(File.read(settings_path)).to eq(before)
      expect(output.string).to include("workspace init --install-hooks")
      expect(installer.stale_tracked_hooks?(provider, tmpdir, command)).to be true
    end

    it "calls a checkout whose hooks lack StopFailure stale" do
      installer.install(provider, tmpdir, command, quiet: true)
      without = settings
      without["hooks"].delete("StopFailure")
      write_settings(without)

      expect(installer.stale_tracked_hooks?(provider, tmpdir, command)).to be true

      installer.install(provider, tmpdir, command, quiet: true)

      expect(settings["hooks"]).to include("StopFailure")
      expect(installer.stale_tracked_hooks?(provider, tmpdir, command)).to be false
    end

    it "chains a differing tracked statusLine command into statusline.command and routes through workspace in local" do
      write_settings("statusLine" => {"type" => "command", "command" => "mine.sh"})

      installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true, local: true)

      expect(project_settings.load_global.dig("statusline", "command")).to eq("mine.sh")
      expect(local_settings["statusLine"]).to eq("type" => "command", "command" => statusline)
    end

    it "raises for a malformed settings.local.json and leaves it as it was" do
      FileUtils.mkdir_p(File.dirname(local_path))
      File.write(local_path, "{nope")

      expect { installer.install(provider, tmpdir, command, quiet: true, local: true) }.to raise_error(Workspace::Error, /not valid JSON/)
      expect(File.read(local_path)).to eq("{nope")
    end

    it "leaves a clean git tree and lists settings.local.json in info/exclude when nothing is tracked" do
      system("git", "init", "-q", tmpdir, exception: true)
      git = Workspace::Git.new(output: StringIO.new, input: StringIO.new)
      excluder = Workspace::BookkeepingExclude.new(git: git, git_exclude: Workspace::GitExclude.new(git: git))
      excluding_backup = Workspace::FileBackup.new(output: output, excluder: excluder)
      excluding = described_class.new(backup: excluding_backup, output: output, input: input, user_settings_path: user_settings_path, excluder: excluder)

      excluding.install(provider, tmpdir, command, quiet: true, local: true)
      excluding.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true, local: true)

      expect(File).to exist(local_path)
      expect(`git -C #{tmpdir} status --porcelain -uall`).to eq("")
      expect(File.read(File.join(tmpdir, ".git", "info", "exclude"))).to include("/.claude/settings.local.json")
    end

    it "leaves a clean git tree when the tracked file already holds the hooks and statusLine" do
      system("git", "init", "-q", tmpdir, exception: true)
      installer.install(provider, tmpdir, command, quiet: true)
      installer.install_statusline(provider, tmpdir, command: statusline, project_settings: project_settings, quiet: true)
      system("git", "-C", tmpdir, "add", ".", exception: true)
      system("git", "-C", tmpdir, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x", exception: true)

      install_all

      expect(`git -C #{tmpdir} status --porcelain`).to eq("")
    end
  end

  describe "#install" do
    it "creates the settings file when the project has none" do
      installer.install(provider, tmpdir, command)

      expect(settings["hooks"]).to include("SessionStart", "SubagentStop", "PreToolUse", "StopFailure")
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

    it "upgrades a previously installed Task-only PreToolUse entry to the new matcher, without duplicating it" do
      write_settings(
        "hooks" => {
          "PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => command}]}]
        }
      )

      installer.install(provider, tmpdir, command)

      pre_tool_use = settings["hooks"]["PreToolUse"]
      expect(pre_tool_use.size).to eq(1)
      expect(pre_tool_use.first).not_to have_key("matcher")
    end

    it "is idempotent after upgrading a Task-only PreToolUse entry" do
      write_settings(
        "hooks" => {
          "PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => command}]}]
        }
      )
      installer.install(provider, tmpdir, command)
      before = settings

      installer.install(provider, tmpdir, command)

      expect(settings).to eq(before)
      expect(settings["hooks"]["PreToolUse"].size).to eq(1)
    end

    it "lists PermissionRequest once, not doubled on reinstall" do
      installer.install(provider, tmpdir, command)
      installer.install(provider, tmpdir, command)

      expect(settings["hooks"]["PermissionRequest"].size).to eq(1)
    end

    it "refuses to touch a settings file it cannot parse" do
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{ not json")

      expect { installer.install(provider, tmpdir, command) }
        .to raise_error(Workspace::Error, /not valid JSON/)
      expect(File.read(settings_path)).to eq("{ not json")
    end

    it "refuses a settings file whose hooks are not an object" do
      write_settings("hooks" => [])

      expect { installer.install(provider, tmpdir, command) }
        .to raise_error(Workspace::Error, /"hooks" object/)
    end

    it "says whether it changed the file" do
      expect(installer.install(provider, tmpdir, command)).to be true
      expect(installer.install(provider, tmpdir, command)).to be false
    end

    it "keeps an updated entry where it stood, so the groups after it keep their place" do
      own = {"hooks" => [{"type" => "command", "command" => "/bin/own"}]}
      old = {"hooks" => [{"type" => "command", "command" => command, "timeout" => 99}]}
      write_settings("hooks" => {"Stop" => [old, own]})

      installer.install(provider, tmpdir, command)

      expect(settings["hooks"]["Stop"]).to eq([{"hooks" => [{"type" => "command", "command" => command}]}, own])
    end
  end

  describe "for Codex, whose hooks are user-level" do
    let(:codex) { Workspace::AgentProvider.find("codex") }
    let(:home) { Dir.mktmpdir }
    let(:codex_path) { File.join(home, ".codex", "hooks.json") }

    subject(:installer) { described_class.new(backup: backup, output: output, input: input, env: {}, home: home) }

    after { FileUtils.remove_entry(home) }

    def codex_hooks
      JSON.parse(File.read(codex_path))["hooks"]
    end

    def write_codex(hash)
      FileUtils.mkdir_p(File.dirname(codex_path))
      File.write(codex_path, JSON.generate(hash))
    end

    let(:unguarded) { "workspace session-event --agent codex" }
    let(:guarded) { codex.hook_command(command) }
    let(:own) { {"hooks" => [{"type" => "command", "command" => "/bin/own"}]} }

    it "upgrades an unguarded entry to the guarded command where it stood, without a duplicate" do
      write_codex("hooks" => {"Stop" => [{"hooks" => [{"type" => "command", "command" => unguarded, "timeout" => 10}]}, own]})

      expect(installer.installed?(codex, tmpdir, command)).to be false
      installer.install(codex, tmpdir, command)

      expect(codex_hooks["Stop"].map { |g| g["hooks"].first["command"] }).to eq([guarded, "/bin/own"])
      expect(codex_hooks.values.flatten.flat_map { |g| g["hooks"] }.map { |h| h["command"] }).not_to include(unguarded)
      expect(installer.installed?(codex, tmpdir, command)).to be true
    end

    describe "#uninstall" do
      it "takes out only workspace's handlers, the old unguarded ones too, keeping the person's and other keys" do
        mixed = {"hooks" => [{"type" => "command", "command" => "/bin/mine"}, {"type" => "command", "command" => unguarded}]}
        write_codex("description" => "mine", "hooks" => {"Stop" => [own, mixed], "PreToolUse" => []})
        installer.install(codex, tmpdir, command)

        result = installer.uninstall(codex, tmpdir, command)

        expect(result[:removed]).to eq(11)
        expect(result[:backup]).to start_with("#{codex_path}.workspace-backup-")
        settings = JSON.parse(File.read(codex_path))
        expect(settings["description"]).to eq("mine")
        expect(settings["hooks"]).to eq("Stop" => [own, {"hooks" => [{"type" => "command", "command" => "/bin/mine"}]}])
      end

      it "drops the hooks key when nothing of the person's is left in it" do
        write_codex("description" => "mine")
        installer.install(codex, tmpdir, command)

        installer.uninstall(codex, tmpdir, command)

        expect(JSON.parse(File.read(codex_path))).to eq("description" => "mine")
      end

      it "keeps an event the person left empty" do
        write_codex("hooks" => {"Notification" => []})
        installer.install(codex, tmpdir, command)

        installer.uninstall(codex, tmpdir, command)

        expect(codex_hooks).to eq("Notification" => [])
      end

      it "changes nothing, and backs nothing up, the second time" do
        installer.install(codex, tmpdir, command)
        installer.uninstall(codex, tmpdir, command)
        before = File.read(codex_path)
        backups = Dir.glob("#{codex_path}.workspace-backup-*").size

        expect(installer.uninstall(codex, tmpdir, command)).to include(removed: 0, backup: nil)
        expect(File.read(codex_path)).to eq(before)
        expect(Dir.glob("#{codex_path}.workspace-backup-*").size).to eq(backups)
      end

      it "counts but writes nothing on a dry run" do
        installer.install(codex, tmpdir, command)
        before = File.read(codex_path)

        expect(installer.uninstall(codex, tmpdir, command, dry_run: true)).to include(removed: 10, backup: nil)
        expect(File.read(codex_path)).to eq(before)
      end

      it "reports nothing to remove when there is no file" do
        expect(installer.uninstall(codex, tmpdir, command)).to eq(path: codex_path, removed: 0, backup: nil)
        expect(File.exist?(codex_path)).to be false
      end

      it "refuses a file it cannot parse, with a code, and leaves it alone" do
        FileUtils.mkdir_p(File.dirname(codex_path))
        File.write(codex_path, "{ nope")

        expect { installer.uninstall(codex, tmpdir, command) }
          .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("hook_settings_unreadable") }
        expect(File.read(codex_path)).to eq("{ nope")
      end
    end

    it "writes the home directory's hooks.json, whatever the project" do
      installer.install(codex, tmpdir, command)

      expect(installer.settings_path_for(codex, tmpdir)).to eq(codex_path)
      expect(codex_hooks["PermissionRequest"].first["hooks"].first)
        .to eq("type" => "command", "command" => "if [ -n \"$TMUX_PANE\" ]; then workspace session-event --agent codex; else cat >/dev/null; fi", "timeout" => 10)
      expect(File.exist?(settings_path)).to be false
      expect(installer.installed?(codex, "/elsewhere", command)).to be true
    end

    it "writes under CODEX_HOME when it is set" do
      moved = File.join(home, "moved")
      installer = described_class.new(backup: backup, output: output, input: input, env: {"CODEX_HOME" => moved}, home: home)

      installer.install(codex, tmpdir, command)

      expect(File.exist?(File.join(moved, "hooks.json"))).to be true
    end

    it "appends after the person's own groups, keeps them as they were, and backs the file up" do
      FileUtils.mkdir_p(File.dirname(codex_path))
      own = {"hooks" => [{"type" => "command", "command" => "/bin/orca-hook", "timeout" => 10}]}
      File.write(codex_path, JSON.generate("description" => "mine", "hooks" => {"PreToolUse" => [own]}))

      installer.install(codex, tmpdir, command)

      expect(JSON.parse(File.read(codex_path))["description"]).to eq("mine")
      expect(codex_hooks["PreToolUse"].first).to eq(own)
      expect(codex_hooks["PreToolUse"].size).to eq(2)
      expect(Dir.glob("#{codex_path}.workspace-backup-*").size).to eq(1)
      expect(output.string).to include("note    Codex skips new or changed hooks")
    end

    it "is a no-op the second time, with no note and no backup" do
      installer.install(codex, tmpdir, command)
      output.truncate(0)
      output.rewind

      expect(installer.install(codex, tmpdir, command)).to be false
      expect(output.string).to include("skip")
      expect(output.string).not_to include("note")
      expect(Dir.glob("#{codex_path}.workspace-backup-*")).to be_empty
    end

    it "writes through a symlinked hooks.json, keeping the link and the file's mode, and leaves no temp file" do
      real = File.join(home, "dotfiles", "hooks.json")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, JSON.generate("hooks" => {}))
      File.chmod(0o600, real)
      FileUtils.mkdir_p(File.dirname(codex_path))
      File.symlink(real, codex_path)

      installer.install(codex, tmpdir, command)

      expect(File.symlink?(codex_path)).to be true
      expect(JSON.parse(File.read(real))["hooks"]).to have_key("PreToolUse")
      expect(File.stat(real).mode & 0o777).to eq(0o600)
      expect(Dir.glob(File.join(home, "**", "*workspace-tmp*"))).to be_empty
    end

    it "prints no note when quiet" do
      installer.install(codex, tmpdir, command, quiet: true)

      expect(output.string).to eq("")
    end
  end

  describe "#installed?" do
    it "is false before install and true after" do
      expect(installer.installed?(provider, tmpdir, command)).to be false
      installer.install(provider, tmpdir, command)
      expect(installer.installed?(provider, tmpdir, command)).to be true
    end
  end

  describe "#statusline_installed?" do
    let(:statusline_command) { "workspace statusline" }

    it "is false when statusLine isn't set" do
      expect(installer.statusline_installed?(provider, tmpdir, statusline_command)).to be false
    end

    it "is true once install_statusline has run" do
      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)
      expect(installer.statusline_installed?(provider, tmpdir, statusline_command)).to be true
    end

    it "is false when a different command is configured" do
      write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh"})
      expect(installer.statusline_installed?(provider, tmpdir, statusline_command)).to be false
    end
  end

  describe "#install_statusline" do
    let(:statusline_command) { "workspace statusline" }

    def global_config
      project_settings.load_global
    end

    it "adds the statusLine entry when none is configured" do
      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(settings["statusLine"]).to eq("type" => "command", "command" => statusline_command)
    end

    it "backs the settings file up before changing it" do
      write_settings("hooks" => {})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      backup_file = Dir[File.join(tmpdir, ".claude", "*workspace-backup*")].first
      expect(backup_file).not_to be_nil
    end

    it "is a no-op when the command is already installed" do
      write_settings("statusLine" => {"type" => "command", "command" => statusline_command})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(output.string).to include("already routed")
      expect(Dir[File.join(tmpdir, ".claude", "*workspace-backup*")]).to be_empty
    end

    it "moves a different existing command into the global statusline.command config" do
      write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh", "padding" => 0})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(settings["statusLine"]).to eq("type" => "command", "command" => statusline_command, "padding" => 0)
      expect(global_config.dig("statusline", "command")).to eq("bash ~/.claude/statusline-command.sh")
    end

    it "never overwrites a statusline.command the user has already set" do
      project_settings.with_global_lock { |data| data.merge("statusline" => {"command" => "my-existing-choice"}) }
      write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh"})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(global_config.dig("statusline", "command")).to eq("my-existing-choice")
    end

    it "preserves unrelated settings" do
      write_settings("permissions" => {"allow" => ["Bash(ls:*)"]})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(settings["permissions"]).to eq("allow" => ["Bash(ls:*)"])
    end

    it "makes no changes on a dry run" do
      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings, dry_run: true)

      expect(File.exist?(settings_path)).to be false
    end

    it "reports what a dry run would preserve instead of silently doing nothing" do
      write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh"})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings, dry_run: true)

      expect(output.string).to include("(dry run) would save previous statusLine command -> statusline.command (bash ~/.claude/statusline-command.sh)")
    end

    it "reports a dry-run conflict instead of silently doing nothing" do
      project_settings.with_global_lock { |data| data.merge("statusline" => {"command" => "my-existing-choice"}) }
      write_settings("statusLine" => {"type" => "command", "command" => "bash ~/.claude/statusline-command.sh"})

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings, dry_run: true)

      expect(output.string).to include("(dry run) statusline.command is already set to \"my-existing-choice\"; would not overwrite it")
    end

    it "preserves a command found in settings.local.json when settings.json has none of its own" do
      local_settings_path = File.join(tmpdir, ".claude", "settings.local.json")
      FileUtils.mkdir_p(File.dirname(local_settings_path))
      File.write(local_settings_path, JSON.pretty_generate("statusLine" => {"type" => "command", "command" => "bash ~/.claude/local-statusline.sh"}))

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(global_config.dig("statusline", "command")).to eq("bash ~/.claude/local-statusline.sh")
    end

    it "warns that settings.local.json still shadows the statusLine it just installed" do
      local_settings_path = File.join(tmpdir, ".claude", "settings.local.json")
      FileUtils.mkdir_p(File.dirname(local_settings_path))
      File.write(local_settings_path, JSON.pretty_generate("statusLine" => {"type" => "command", "command" => "bash ~/.claude/local-statusline.sh"}))

      installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings)

      expect(output.string).to include("settings.local.json")
      expect(output.string).to include("still routes statusLine through \"bash ~/.claude/local-statusline.sh\"")
    end

    it "tolerates an unparsable settings.local.json without raising or writing to it" do
      local_settings_path = File.join(tmpdir, ".claude", "settings.local.json")
      FileUtils.mkdir_p(File.dirname(local_settings_path))
      File.write(local_settings_path, "{ not json")

      expect { installer.install_statusline(provider, tmpdir, command: statusline_command, project_settings: project_settings) }
        .not_to raise_error
      expect(File.read(local_settings_path)).to eq("{ not json")
    end
  end

  describe "#local_statusline_command" do
    it "is nil when settings.local.json has no statusLine" do
      expect(installer.local_statusline_command(provider, tmpdir)).to be_nil
    end

    it "reads the command from settings.local.json" do
      local_settings_path = File.join(tmpdir, ".claude", "settings.local.json")
      FileUtils.mkdir_p(File.dirname(local_settings_path))
      File.write(local_settings_path, JSON.pretty_generate("statusLine" => {"type" => "command", "command" => "bash ~/.claude/local-statusline.sh"}))

      expect(installer.local_statusline_command(provider, tmpdir)).to eq("bash ~/.claude/local-statusline.sh")
    end
  end

  describe "#preview" do
    it "prints the fragment that would be added" do
      installer.preview(provider, command)

      expect(output.string).to include("SubagentStop", command)
    end
  end

  describe "#summary" do
    it "comma-joins every hook event and names the command in one line" do
      events = provider.hook_settings(command)["hooks"].keys

      expect(installer.summary(provider, command)).to eq("#{events.join(", ")} hooks running `#{command}`")
    end
  end
end

RSpec.describe Workspace::HookInstaller, "bookkeeping excludes" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:excluder) { instance_double(Workspace::BookkeepingExclude, created: true) }
  let(:provider) { Workspace::AgentProvider.find("claude") }
  let(:settings_path) { File.join(tmpdir, ".claude", "settings.json") }
  let(:installer) do
    described_class.new(backup: Workspace::FileBackup.new(output: output), output: output, input: StringIO.new,
      user_settings_path: File.join(tmpdir, "none.json"), excluder: excluder)
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "lists a settings file it created" do
    installer.install(provider, tmpdir, "workspace session-event", quiet: true)

    expect(excluder).to have_received(:created).with(settings_path)
  end

  context "when install_statusline writes the file" do
    let(:global_dir) { Dir.mktmpdir }
    let(:project_settings) { Workspace::ProjectSettings.new(config: instance_double(Workspace::Config, workspace_config_dir: global_dir)) }

    after { FileUtils.remove_entry(global_dir) }

    it "lists a settings file it created" do
      installer.install_statusline(provider, tmpdir, command: "workspace statusline", project_settings: project_settings, quiet: true)

      expect(excluder).to have_received(:created).with(settings_path)
    end

    it "leaves a settings file that already existed alone" do
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, "{}")

      installer.install_statusline(provider, tmpdir, command: "workspace statusline", project_settings: project_settings, quiet: true)

      expect(excluder).not_to have_received(:created)
    end
  end

  it "leaves a settings file that already existed alone" do
    FileUtils.mkdir_p(File.dirname(settings_path))
    File.write(settings_path, "{}")

    installer.install(provider, tmpdir, "workspace session-event", quiet: true)

    expect(excluder).not_to have_received(:created)
  end
end
