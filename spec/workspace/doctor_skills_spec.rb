require "spec_helper"
require "stringio"

RSpec.describe Workspace::Doctor, "skills" do
  include SkillsFixture

  let(:output) { StringIO.new }
  let(:project_detector) { double("project_detector", detect: nil) }
  let(:hook_installer) { double("hook_installer", statusline_installed?: true, local_statusline_command: nil, settings_path_for: "/x", install: false) }
  let(:harnesses) { Workspace::SkillHarnesses.new(home: home, env: {}, which: ->(_exe) { false }) }
  let(:state) { Workspace::SkillsState.new(dir: state_dir) }
  let(:links) { Workspace::SkillLinks.new(state_dir: state_dir) }
  let(:skills) do
    Workspace::Commands::Skills.new(harnesses: harnesses, source: Workspace::SkillSource.new(workspace_dir: checkout), links: links, state: state, output: StringIO.new, error_output: StringIO.new)
  end
  let(:doctor) do
    described_class.new(config: Workspace::Config.new, state: CLITestHelpers::FakeState.new, hook_installer: hook_installer, project_detector: project_detector,
      output: output, project_settings: CLITestHelpers::FakeProjectSettings.new, skills: skills, which: ->(_exe) { true },
      launch_mode: Workspace::LaunchMode.new(project_settings: CLITestHelpers::FakeProjectSettings.new, platform: "arm64-darwin", env: {}, which: ->(_exe) { true }))
  end
  let(:claude_dir) { File.join(home, ".claude", "skills") }

  def rows(id = "skills-claude") = doctor.report(fix: false)[:rows].select { |row| row[:id] == id }

  def link_all(dir, root: self.root)
    FileUtils.mkdir_p(dir)
    SkillsFixture::NAMES.each { |name| File.symlink(File.join(root, name), File.join(dir, name)) }
  end

  before { FileUtils.mkdir_p(File.join(home, ".claude")) }

  it "warns with the install command when nothing is linked" do
    row = rows.fetch(0)

    expect(row).to include(status: "warn", fix_command: "workspace skills install")
    expect(row[:message]).to include("Claude Code skills", "not installed")
  end

  it "is ok when the links resolve, whichever install they point at" do
    other = File.join(@tmp, "other-workspace")
    build_checkout(other)
    link_all(claude_dir, root: File.join(other, "lib", "skills"))

    expect(rows.map { |row| row[:status] }).to eq(["ok"])
  end

  it "fails on a dangling link of ours" do
    link_all(claude_dir)
    FileUtils.rm_rf(root)

    row = rows.fetch(0)

    expect(row).to include(status: "fail", fix_command: "workspace doctor --fix")
  end

  it "warns on a real directory or someone else's link, and says it is left alone" do
    FileUtils.mkdir_p(File.join(claude_dir, "workspace"))
    File.symlink("/nowhere/elsewhere", File.join(claude_dir, "workspace-inbox"))

    expect(rows.fetch(0)).to include(status: "warn")
    expect(rows.fetch(0)[:message]).to include("left alone")
  end

  it "gives a declined harness no row" do
    state.declined = ["claude"]

    expect(doctor.report[:rows].map { |row| row[:id] }).not_to include("skills-claude")
  end

  it "gives no rows when no harness is found" do
    FileUtils.rm_rf(File.join(home, ".claude"))

    expect(doctor.report[:rows].map { |row| row[:id] }.grep(/skills/)).to be_empty
  end

  describe "--fix" do
    def fix = doctor.report(fix: true)

    it "does a first install for an undeclined harness, outside a project, without counting an issue for it" do
      result = fix

      expect(SkillsFixture::NAMES.map { |n| File.realpath(File.join(claude_dir, n)) }).to eq(SkillsFixture::NAMES.map { |n| File.join(root, n) })
      expect(result[:rows].select { |row| row[:id] == "skills-claude" }.map { |row| row[:status] }).to eq(["ok"])
      expect(result[:rows].map { |row| row[:id] }).not_to include("fix")
      expect(output.string).to include("--fix: Claude Code skills linked")
    end

    it "counts no issue for a repair made outside a project" do
      allow_any_instance_of(described_class).to receive(:dependency_checks).and_return([])
      allow_any_instance_of(described_class).to receive(:check_templates)

      expect(fix[:issues]).to eq(0)
    end

    it "names each refusal once and offers no fix command when the repair was refused" do
      FileUtils.mkdir_p(File.join(claude_dir, "workspace"))

      messages = fix[:rows].select { |row| row[:id] == "skills" }.map { |row| row[:message] }

      expect(messages).to eq(messages.uniq)
    end

    it "repairs a dangling link and leaves a resolving link of another root alone" do
      other = File.join(@tmp, "other-workspace")
      build_checkout(other)
      link_all(claude_dir)
      FileUtils.rm_rf(root)
      build_checkout(checkout)
      File.unlink(File.join(claude_dir, "workspace-inbox"))
      File.symlink(File.join(other, "lib", "skills", "workspace-inbox"), File.join(claude_dir, "workspace-inbox"))

      fix

      expect(File.readlink(File.join(claude_dir, "workspace"))).to eq(File.join(root, "workspace"))
      expect(File.readlink(File.join(claude_dir, "workspace-inbox"))).to eq(File.join(other, "lib", "skills", "workspace-inbox"))
    end

    it "never replaces a real directory or a foreign link, and links nothing else in that directory" do
      FileUtils.mkdir_p(File.join(claude_dir, "workspace"))

      result = fix

      expect(File.symlink?(File.join(claude_dir, "workspace"))).to be(false)
      expect(File.exist?(File.join(claude_dir, "workspace-inbox"))).to be(false)
      expect(result[:rows].find { |row| row[:id] == "skills-claude" }[:status]).to eq("warn")
      expect(result[:rows].map { |row| row[:message] }.join).to include("--fix:")
    end

    it "leaves a declined harness unlinked" do
      state.declined = ["claude"]

      fix

      expect(File.exist?(claude_dir)).to be(false)
    end

    it "links ~/.agents/skills too when it exists, never creating it otherwise" do
      FileUtils.mkdir_p(File.join(home, ".agents", "skills"))

      fix

      expect(File.symlink?(File.join(home, ".agents", "skills", "workspace"))).to be(true)
    end

    it "skips the repair with a warning from a linked worktree" do
      FileUtils.rm_rf(File.join(checkout, ".git"))
      common = File.join(@tmp, "main.git", "worktrees", "wt")
      FileUtils.mkdir_p(common)
      File.write(File.join(common, "commondir"), "../..\n")
      File.write(File.join(checkout, ".git"), "gitdir: #{common}\n")

      result = fix

      expect(File.exist?(claude_dir)).to be(false)
      warning = result[:rows].find { |row| row[:id] == "skills" }
      expect(warning).to include(status: "warn")
      expect(warning[:message]).to include("linked git worktree")
      expect(result[:rows].find { |row| row[:id] == "skills-claude" }).to include(fix_command: nil)
      expect(result[:rows].select { |row| row[:id].start_with?("skills") && row[:status] == "fail" }).to be_empty
    end
  end
end
