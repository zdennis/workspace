require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::LaunchHookCheck do
  let(:tmpdir) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:io) { StringIO.new }
  let(:backup) { Workspace::FileBackup.new(output: output) }
  let(:claude) { Workspace::AgentProvider.find("claude") }
  let(:codex) { Workspace::AgentProvider.find("codex") }
  let(:command) { "workspace session-event" }
  let(:on_path) { %w[claude] }
  let(:hooks_config) { nil }
  let(:env) { {} }
  let(:home) { Dir.mktmpdir }
  let(:codex_home) { Dir.mktmpdir }

  let(:installer) do
    Workspace::HookInstaller.new(backup: backup, output: output, env: env, home: codex_home)
  end

  subject(:checker) { described_class.new(hook_installer: installer, hooks_config: hooks_config, which: ->(exe) { on_path.include?(exe) }) }

  after do
    FileUtils.remove_entry(tmpdir)
    FileUtils.remove_entry(home)
    FileUtils.remove_entry(codex_home)
  end

  def claude_settings_path = File.join(tmpdir, ".claude", "settings.json")

  def claude_local_path = File.join(tmpdir, ".claude", "settings.local.json")

  def codex_hooks_path = File.join(codex_home, ".codex", "hooks.json")

  def write_json(path, hash)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(hash))
  end

  def install_hooks(provider, root, local: false)
    installer.install(provider, root, command, quiet: true, local: local)
  end

  def notes
    io.string.lines.grep(/\ANote:/)
  end

  it "stays silent when the current hooks sit in the tracked settings file alone" do
    install_hooks(claude, tmpdir, local: false)

    checker.check(tmpdir, io: io)

    expect(notes).to be_empty
  end

  it "stays silent when the current hooks sit in the local settings file alone, where start installs them" do
    install_hooks(claude, tmpdir, local: true)

    checker.check(tmpdir, io: io)

    expect(notes).to be_empty
  end

  it "notes a stale tracked entry beside a current local one, reusing the stale notice" do
    install_hooks(claude, tmpdir, local: true)
    stale = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => claude.hook_command(command)}]}]}}
    write_json(claude_settings_path, stale)

    checker.check(tmpdir, io: io)

    expect(notes).to eq(["Note: #{installer.stale_message(claude, tmpdir, command)}\n"])
  end

  it "notes a tracked file holding an older workspace hook alone as missing or stale" do
    stale = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => claude.hook_command(command)}]}]}}
    write_json(claude_settings_path, stale)

    checker.check(tmpdir, io: io)

    expect(notes.join).to include("Claude Code hooks missing or stale")
  end

  it "notes an agent whose hooks are missing entirely" do
    checker.check(tmpdir, io: io)

    expect(notes).to eq(["Note: Claude Code hooks missing or stale for this checkout's agents; " \
      "#{Workspace::LaunchHookCheck::FIX_HINT}.\n"])
    expect(notes.join).to include("run `workspace init --install-hooks` in this checkout to install them.")
  end

  it "skips an agent whose executable is not on PATH" do
    on_path.clear

    checker.check(tmpdir, io: io)

    expect(notes).to be_empty
  end

  context "with a user-scoped provider (Codex)" do
    let(:env) { {"CODEX_HOME" => File.join(codex_home, ".codex")} }
    let(:on_path) { %w[claude codex] }

    it "reads the user-level hook file only, never a local settings file beside it" do
      install_hooks(claude, tmpdir, local: false)
      install_hooks(codex, tmpdir, local: false)
      # A corrupt local file beside the user hook file would raise if the check read it.
      File.write(File.join(codex_home, ".codex", "settings.local.json"), "{not json")

      checker.check(tmpdir, io: io)

      expect(notes).to be_empty
    end

    it "never reads a local settings file for a user-scoped agent: a current local file beside a missing user hook file still notes Codex" do
      current_hooks = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => codex.hook_command(command)}]}]}}
      write_json(File.join(codex_home, ".codex", "settings.local.json"), current_hooks)

      checker.check(tmpdir, io: io)

      expect(notes.join).to include("Codex hooks missing or stale")
    end

    context "with codex alone on PATH" do
      let(:on_path) { %w[codex] }

      it "stays silent when codex.hooks.install is off, as start does" do
        off_config = instance_double(Workspace::HooksConfig)
        allow(off_config).to receive(:install_user_hooks?).and_return(true)
        allow(off_config).to receive(:install_user_hooks?).with(codex).and_return(false)
        codex_only = described_class.new(hook_installer: installer, hooks_config: off_config, which: ->(exe) { on_path.include?(exe) })

        codex_only.check(tmpdir, io: io)

        expect(notes).to be_empty
      end
    end

    it "still checks Codex when no hooks config was wired" do
      checker.check(tmpdir, io: io)

      expect(notes.join).to include("Codex hooks missing or stale")
      expect(notes.join).to include("Claude Code hooks missing or stale")
    end
  end

  it "notes an unreadable settings file instead of failing the launch" do
    FileUtils.mkdir_p(File.dirname(claude_settings_path))
    File.write(claude_settings_path, "{not json")

    expect { checker.check(tmpdir, io: io) }.not_to raise_error
    expect(notes.join).to include("Claude Code hooks not installed")
  end

  it "notes a settings path that cannot be read at all (a directory there) instead of failing" do
    FileUtils.mkdir_p(claude_settings_path)

    expect { checker.check(tmpdir, io: io) }.not_to raise_error
    expect(notes.join).to include("Claude Code hooks not installed")
  end

  context "with only:" do
    let(:on_path) { %w[claude codex] }

    it "checks exactly the given providers: only claude prints Claude's note and no Codex note" do
      checker.check(tmpdir, io: io, only: [claude])

      expect(notes.join).to include("Claude Code hooks missing or stale")
      expect(notes.join).not_to include("Codex")
    end

    it "prints nothing for an empty list" do
      checker.check(tmpdir, io: io, only: [])

      expect(notes).to be_empty
    end

    context "when the executable is not on PATH" do
      let(:on_path) { [] }

      it "still notes the given provider" do
        checker.check(tmpdir, io: io, only: [claude])

        expect(notes.join).to include("Claude Code hooks missing or stale")
      end
    end
  end
end
