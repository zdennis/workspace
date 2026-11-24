require "spec_helper"
require "stringio"
require "tmpdir"
require "json"

RSpec.describe Workspace::AgentHookSetup do
  let(:tmpdir) { Dir.mktmpdir }
  let(:home) { Dir.mktmpdir }
  let(:output) { StringIO.new }
  let(:excluder) { instance_double(Workspace::BookkeepingExclude, created: true) }
  let(:backup) { Workspace::FileBackup.new(output: output) }
  let(:claude) { Workspace::AgentProvider.find("claude") }
  let(:on_path) { %w[claude] }
  let(:asked) { [] }
  let(:which) { ->(exe) { asked << exe && on_path.include?(exe) } }
  let(:hooks_config) { nil }
  let(:agent_commands) { nil }
  let(:project_settings) { CLITestHelpers::FakeProjectSettings.new }
  let(:installer) do
    Workspace::HookInstaller.new(backup: backup, output: output, excluder: excluder,
      user_settings_path: File.join(home, "settings.json"), env: {"CODEX_HOME" => home}, home: home)
  end

  subject(:setup) do
    described_class.new(hook_installer: installer, hooks_config: hooks_config, agent_commands: agent_commands,
      project_settings: project_settings, which: which)
  end

  after do
    FileUtils.remove_entry(tmpdir)
    FileUtils.remove_entry(home)
  end

  def local_path = File.join(tmpdir, ".claude", "settings.local.json")

  def tracked_path = File.join(tmpdir, ".claude", "settings.json")

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  it "installs Claude's hooks and statusLine into settings.local.json" do
    result = setup.install(tmpdir, "proj", quiet: true)

    settings = JSON.parse(File.read(local_path))
    expect(settings["hooks"]).to have_key("PreToolUse")
    expect(settings["statusLine"]).to eq("type" => "command", "command" => "workspace statusline")
    expect(File).not_to exist(tracked_path)
    expect(result.leftovers).to eq([])
  end

  it "creates nothing under a checkout directory that is gone" do
    gone = File.join(tmpdir, "moved-worktree")

    result = setup.install(gone, "proj", quiet: true)

    expect(File).not_to exist(gone)
    expect(result.notes).to eq([])
    expect(result.leftovers).to eq([])
  end

  it "returns a frozen result and prints nothing itself" do
    result = setup.install(tmpdir, "proj", quiet: true)

    expect(result).to be_frozen
    expect(result.notes).to be_frozen
    expect(output.string).to eq("")
  end

  it "writes nothing and says nothing when the hooks are current" do
    setup.install(tmpdir, "proj", quiet: true)
    before = [File.read(local_path), File.mtime(local_path)]
    sleep 0.02

    result = setup.install(tmpdir, "proj", quiet: true)

    expect([File.read(local_path), File.mtime(local_path)]).to eq(before)
    expect(result.notes).to eq([])
    expect(result.texts).to eq([])
  end

  it "replaces stale local entries" do
    stale = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => claude.hook_command("workspace session-event")}]}]}}
    write_json(local_path, stale)

    setup.install(tmpdir, "proj", quiet: true)

    expect(JSON.parse(File.read(local_path))["hooks"]).not_to eq(stale["hooks"])
    expect(installer.stale_tracked_hooks?(claude, tmpdir, Workspace::HookInstaller::HOOK_COMMAND)).to be(false)
  end

  it "leaves a stale tracked settings.json alone and reports it as a stale note and a leftover" do
    stale = {"hooks" => {"PreToolUse" => [{"matcher" => "Task", "hooks" => [{"type" => "command", "command" => claude.hook_command("workspace session-event")}]}]}}
    write_json(tracked_path, stale)
    tracked_before = File.read(tracked_path)
    setup.install(tmpdir, "proj", quiet: true)

    result = setup.install(tmpdir, "proj", quiet: true)

    expect(File.read(tracked_path)).to eq(tracked_before)
    note = result.notes.find { |n| n.kind == :stale }
    expect(note.provider).to eq(claude)
    expect(note.text).to eq("Note: #{installer.stale_message(claude, tmpdir, Workspace::HookInstaller::HOOK_COMMAND)}.")
    expect(result.leftovers).to eq([claude])
  end

  context "with Codex on PATH and codex.hooks.install false" do
    let(:on_path) { %w[codex] }
    let(:hooks_config) { instance_double(Workspace::HooksConfig, install_user_hooks?: false) }

    it "writes no hooks.json and returns a refused note" do
      result = setup.install(tmpdir, "proj", quiet: true)

      expect(File).not_to exist(File.join(home, "hooks.json"))
      expect(result.notes.map(&:kind)).to eq([:refused])
      expect(result.texts.first).to match(/\ANote: Codex hooks not installed: codex\.hooks\.install is false/)
      expect(result.leftovers).to eq([])
    end
  end

  context "when the installer raises" do
    let(:installer) { instance_double(Workspace::HookInstaller) }

    it "turns a Workspace::Error into a leftover note" do
      allow(installer).to receive(:install).and_raise(Workspace::Error, "bad json")
      allow(installer).to receive(:install_statusline).and_raise(Workspace::Error, "bad json")

      result = setup.install(tmpdir, "proj", quiet: true)

      expect(result.texts).to eq(["Note: Claude Code hooks not installed: bad json", "Note: Claude Code statusLine not routed: bad json"])
      expect(result.notes.map(&:kind)).to eq([:leftover, :leftover])
      expect(result.leftovers).to eq([claude])
    end

    it "turns Errno::EACCES into a leftover note" do
      allow(installer).to receive(:install).and_raise(Errno::EACCES, "settings.local.json")
      allow(installer).to receive(:install_statusline).and_return([])

      result = nil
      expect { result = setup.install(tmpdir, "proj", quiet: true) }.not_to raise_error

      expect(result.notes.map(&:kind)).to eq([:leftover])
      expect(result.texts.first).to match(/\ANote: Claude Code hooks not installed: .*Permission denied/)
      expect(result.leftovers).to eq([claude])
    end

    it "turns Errno::EACCES from the statusLine install into a leftover note" do
      allow(installer).to receive(:install).and_return([])
      allow(installer).to receive(:install_statusline).and_raise(Errno::EACCES, "settings.local.json")

      result = nil
      expect { result = setup.install(tmpdir, "proj", quiet: true) }.not_to raise_error

      expect(result.notes.map(&:kind)).to eq([:leftover])
      expect(result.texts.first).to match(/\ANote: Claude Code statusLine not routed: .*Permission denied/)
      expect(result.leftovers).to eq([claude])
    end
  end

  context "with a configured agent command" do
    let(:agent_commands) { instance_double(Workspace::AgentCommands) }
    let(:on_path) { %w[claude-dev] }

    it "asks which about the configured executable" do
      allow(agent_commands).to receive(:executable_for) { |_name, kind| (kind == "claude") ? "claude-dev" : kind }

      setup.install(tmpdir, "proj.wt", quiet: true)

      expect(agent_commands).to have_received(:executable_for).with("proj.wt", "claude").at_least(:once)
      expect(asked).to include("claude-dev")
      expect(asked).not_to include("claude")
      expect(File).to exist(local_path)
    end
  end
end
