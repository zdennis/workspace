require "spec_helper"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::Skills do
  include SkillsFixture

  let(:on_path) { [] }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:stdin) { StringIO.new }
  let(:input) { Workspace::PromptInput.new(stdin) }
  let(:harnesses) { Workspace::SkillHarnesses.new(home: home, env: {}, which: ->(exe) { on_path.include?(exe) }) }
  let(:state) { Workspace::SkillsState.new(dir: state_dir) }
  let(:links) { Workspace::SkillLinks.new(state_dir: state_dir, clock: -> { Time.utc(2026, 10, 30, 12) }) }
  subject(:command) do
    described_class.new(harnesses: harnesses, source: Workspace::SkillSource.new(workspace_dir: checkout), links: links, state: state,
      input: input, output: output, error_output: error_output, version: "9.9.9")
  end

  def skills_dir(harness_dir) = File.join(home, harness_dir, "skills")

  def linked?(dir) = SkillsFixture::NAMES.all? { |n| File.symlink?(File.join(dir, n)) }

  def document = JSON.parse(output.string)

  before { FileUtils.mkdir_p(%W[#{home}/.claude #{home}/.codex]) }

  describe "#install" do
    it "asks once for the harnesses found on one screen and links those chosen, recording the rest as declined" do
      stdin.string = "claude\n"

      expect(command.install).to be(true)

      expect(output.string).to include("1. Claude Code", "2. Codex", "Choose numbers or names, \"all\", or \"none\" [all]: ")
      expect(linked?(skills_dir(".claude"))).to be(true)
      expect(File.exist?(skills_dir(".codex"))).to be(false)
      expect(state.declined).to eq(["codex"])
      expect(output.string).to include("Declined: Codex")
    end

    it "takes numbers, a blank line as all, and re-asks on bad input" do
      stdin.string = "7\nfoo\n2\n"

      command.install

      expect(output.string.scan("Not understood").size).to eq(2)
      expect(linked?(skills_dir(".codex"))).to be(true)
      expect(File.exist?(skills_dir(".claude"))).to be(false)
      expect(state.declined).to eq(["claude"])
    end

    it "treats a blank answer as all" do
      stdin.string = "\n"

      command.install

      expect(linked?(skills_dir(".claude"))).to be(true)
      expect(linked?(skills_dir(".codex"))).to be(true)
      expect(state.declined).to eq([])
    end

    it "treats end of input as no answer: nothing is installed and nothing is recorded as declined" do
      expect(command.install).to be(true)

      expect(Dir.exist?(skills_dir(".claude"))).to be(false)
      expect(File.exist?(state.path)).to be(false)
      expect(output.string).to include("No answer: nothing installed, nothing recorded")
    end

    it "records declines for an explicit none" do
      stdin.string = "none\n"

      command.install

      expect(state.declined).to eq(%w[claude codex])
    end

    it "does not ask again about a declined harness" do
      state.declined = ["codex"]
      stdin.string = "all\n"

      command.install

      expect(output.string).not_to include("Codex   ")
      expect(output.string.scan("Choose numbers").size).to eq(1)
      expect(File.exist?(skills_dir(".codex"))).to be(false)
      expect(state.declined).to eq(["codex"])
    end

    it "does not re-ask a harness that is already linked, and says already current" do
      stdin.string = "all\n"
      command.install
      output.truncate(0)
      output.rewind

      expect(command.install).to be(true)

      expect(output.string).not_to include("Choose numbers")
      expect(output.string).to include("already current")
    end

    it "refreshes a stale link of ours on a re-run and says what changed" do
      stdin.string = "all\n"
      command.install
      other = File.join(@tmp, "other")
      build_checkout(other)
      File.unlink("#{skills_dir(".claude")}/workspace")
      File.symlink("#{other}/lib/skills/workspace", "#{skills_dir(".claude")}/workspace")
      output.truncate(0)
      output.rewind

      command.install

      expect(output.string).to match(/relinked\s+workspace/)
      expect(File.readlink("#{skills_dir(".claude")}/workspace")).to eq("#{root}/workspace")
    end

    it "--install-all asks nothing, installs for every harness found, and clears declines" do
      state.declined = ["codex"]

      command.install(install_all: true)

      expect(output.string).not_to include("Choose")
      expect(linked?(skills_dir(".claude"))).to be(true)
      expect(linked?(skills_dir(".codex"))).to be(true)
      expect(state.declined).to eq([])
    end

    it "also links ~/.agents/skills when it exists, and never creates it otherwise" do
      FileUtils.mkdir_p("#{home}/.agents/skills")
      command.install(install_all: true)

      expect(linked?("#{home}/.agents/skills")).to be(true)

      FileUtils.rm_rf("#{home}/.agents")
      FileUtils.rm_rf("#{home}/.claude/skills")
      command.install(install_all: true)
      expect(File.exist?("#{home}/.agents")).to be(false)
    end

    it "raises confirmation_required under --no-input when it would have to ask" do
      input.no_input!

      expect { command.install }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("confirmation_required")
        expect(e.retry).to eq("flags" => ["--install-all"], "destructive" => false)
      }
      expect(state.declined).to eq([])
    end

    it "raises confirmation_required when WORKSPACE_NO_INPUT is set" do
      env_input = Workspace::PromptInput.new(stdin, no_input: Workspace::PromptInput.env_truthy?({"WORKSPACE_NO_INPUT" => "1"}))
      from_env = described_class.new(harnesses: harnesses, source: Workspace::SkillSource.new(workspace_dir: checkout), links: links, state: state,
        input: env_input, output: output, error_output: error_output)

      expect { from_env.install }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("confirmation_required") }
    end

    it "does not refuse under --no-input when there is nothing to ask" do
      command.install(install_all: true)
      input.no_input!

      expect(command.install).to be(true)
    end

    it "installs under --no-input with --install-all" do
      input.no_input!

      expect(command.install(install_all: true)).to be(true)
      expect(linked?(skills_dir(".claude"))).to be(true)
    end

    it "--dry-run writes nothing: no directories, no state, no backups" do
      FileUtils.mkdir_p("#{home}/.agents/skills")
      stdin.string = "claude\n"

      expect(command.install(dry_run: true)).to be(true)

      expect(Dir.exist?(skills_dir(".claude"))).to be(false)
      expect(File.exist?(state.path)).to be(false)
      expect(Dir.exist?(state_dir)).to be(false)
      expect(output.string).to include("Would link")
    end

    it "shows a harness whose directory is also the shared one with its skills, once" do
      FileUtils.mkdir_p("#{home}/.agents/skills")
      same = Workspace::SkillHarnesses.new(home: home, env: {"CODEX_HOME" => "#{home}/.agents"}, which: ->(_) { false })

      cmd = described_class.new(harnesses: same, source: Workspace::SkillSource.new(workspace_dir: checkout), links: links, state: state,
        input: input, output: output, error_output: error_output)
      cmd.install(install_all: true, json: true)

      codex = document["harnesses"].find { |h| h["key"] == "codex" }
      expect(codex["skills"].size).to eq(4)
    end

    it "raises no_harness_found when none is there" do
      FileUtils.rm_rf(%W[#{home}/.claude #{home}/.codex])

      expect { command.install }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("no_harness_found") }
    end

    it "reports a partial refusal, returns false, links none in the refused directory and all in the other" do
      FileUtils.mkdir_p("#{skills_dir(".claude")}/workspace-inbox")
      File.write("#{skills_dir(".claude")}/workspace-inbox/SKILL.md", "mine")

      expect(command.install(install_all: true)).to be(false)

      expect(linked?(skills_dir(".codex"))).to be(true)
      expect(Dir.children(skills_dir(".claude"))).to eq(["workspace-inbox"])
      expect(output.string).to include("skill_path_exists", "to keep it, run: mkdir -p", "refused")
    end

    it "refuses from a linked worktree whatever HOME and PATH are" do
      main = File.join(@tmp, "main")
      wt = File.join(@tmp, "main-wt")
      build_checkout(main)
      FileUtils.rm_rf("#{main}/.git")
      git_in(@tmp, "init", "-q", main)
      git_in(main, "add", "-A")
      git_in(main, "commit", "-q", "-m", "x")
      git_in(main, "worktree", "add", "-q", "-b", "f", wt)
      from_wt = described_class.new(harnesses: harnesses, source: Workspace::SkillSource.new(workspace_dir: wt), links: links, state: state,
        input: input, output: output, error_output: error_output)
      stdin.string = "all\n"

      expect { from_wt.install(install_all: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("skill_source_worktree") }
      expect(Dir.exist?(skills_dir(".claude"))).to be(false)
      expect(File.exist?(state.path)).to be(false)
    end

    context "with --json" do
      it "prints one document on stdout and sends the question to stderr" do
        stdin.string = "claude\n"

        command.install(json: true)

        expect(error_output.string).to include("Choose numbers")
        expect(output.string.lines.size).to eq(1)
        expect(document).to include("ok" => true, "version" => "9.9.9", "source" => root, "dry_run" => false)
        rows = document["harnesses"].to_h { |h| [h["key"], h] }
        expect(rows["claude"]["status"]).to eq("linked")
        expect(rows["claude"]["skills"].map { |s| s["outcome"] }).to all(eq("linked"))
        expect(rows["claude"]["skills"].first).to include("name" => "workspace", "from" => nil, "to" => "#{root}/workspace", "code" => nil)
        expect(rows["codex"]["status"]).to eq("declined")
        expect(rows["pi"]["status"]).to eq("skipped")
        expect(document["warnings"]).to eq([])
      end

      it "reports ok false with the refusal's code and mv when something is refused" do
        FileUtils.mkdir_p("#{skills_dir(".claude")}/workspace")
        File.write("#{skills_dir(".claude")}/workspace/SKILL.md", "mine")

        expect(command.install(install_all: true, json: true)).to be(false)

        expect(document["ok"]).to be(false)
        row = document["harnesses"].find { |h| h["key"] == "claude" }["skills"].find { |s| s["name"] == "workspace" }
        expect(row).to include("outcome" => "refused", "code" => "skill_path_exists")
        expect(document["harnesses"].find { |h| h["key"] == "claude" }["status"]).to eq("refused")
        expect(row["mv"]).to start_with("mkdir -p ")
      end
    end
  end

  describe "state" do
    it "reads a corrupt file as empty" do
      FileUtils.mkdir_p(state_dir)
      File.write(state.path, "{nope")

      expect(state.declined).to eq([])
    end

    it "reads a file of the wrong shape as empty" do
      FileUtils.mkdir_p(state_dir)
      File.write(state.path, %({"declined": "claude"}))

      expect(state.declined).to eq([])
    end

    it "is written as {\"declined\": [...]} and leaves no temp file" do
      state.declined = %w[pi pi]

      expect(JSON.parse(File.read(state.path))).to eq("declined" => ["pi"])
      expect(Dir.children(state_dir).grep(/tmp/)).to eq([])
    end
  end

  describe "#uninstall" do
    it "removes only our links in every known directory, dangling included, and records no decline" do
      command.install(install_all: true)
      FileUtils.mkdir_p("#{home}/.pi/agent/skills")
      File.symlink("#{@tmp}/gone-workspace/lib/skills/workspace", "#{home}/.pi/agent/skills/workspace")
      File.unlink("#{skills_dir(".codex")}/workspace-inbox")
      FileUtils.mkdir_p("#{skills_dir(".codex")}/workspace-inbox")
      File.unlink("#{skills_dir(".claude")}/workspace-lifecycle")
      File.symlink("/elsewhere/workspace-lifecycle", "#{skills_dir(".claude")}/workspace-lifecycle")
      FileUtils.mkdir_p("#{skills_dir(".claude")}/synced")
      File.delete(state.path) if File.exist?(state.path)
      output.truncate(0)
      output.rewind

      expect(command.uninstall).to be(true)

      expect(Dir.children(skills_dir(".claude")).sort).to eq(%w[synced workspace-lifecycle])
      expect(Dir.children(skills_dir(".codex")).sort).to eq(["workspace-inbox"])
      expect(Dir.children("#{home}/.pi/agent/skills")).to eq([])
      expect(File.exist?(state.path)).to be(false)
      expect(output.string).to include("skill_link_foreign", "skill_path_exists", "left")
      expect(output.string).to match(/Removed \d+ skill links; left 2/)
    end

    it "--dry-run removes nothing" do
      command.install(install_all: true)

      command.uninstall(dry_run: true)

      expect(linked?(skills_dir(".claude"))).to be(true)
      expect(output.string).to include("Would remove 8")
    end

    it "prints one document with --json" do
      command.install(install_all: true)
      output.truncate(0)
      output.rewind

      command.uninstall(json: true)

      expect(document).to include("ok" => true, "source" => nil)
      claude = document["harnesses"].find { |h| h["key"] == "claude" }
      expect(claude["status"]).to eq("removed")
      expect(claude["skills"].map { |s| s["outcome"] }).to all(eq("removed"))
    end

    it "works from a linked worktree, which install refuses" do
      command.install(install_all: true)
      FileUtils.rm_rf(checkout)

      expect(command.uninstall).to be(true)
      expect(Dir.children(skills_dir(".claude"))).to eq([])
    end
  end
end
