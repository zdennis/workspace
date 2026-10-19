require "tmpdir"
require "json"
require "open3"

RSpec.describe Workspace::Commands::Hooks do
  let(:home) { Dir.mktmpdir }
  let(:codex_path) { File.join(home, ".codex", "hooks.json") }
  let(:installer) { Workspace::HookInstaller.new(backup: Workspace::FileBackup.new(output: StringIO.new), output: StringIO.new, env: {}, home: home) }
  let(:codex) { Workspace::AgentProvider.find("codex") }

  subject(:command) { described_class.new(hook_installer: installer, working_dir: home) }

  after { FileUtils.remove_entry(home) }

  describe "#uninstall" do
    it "removes workspace's Codex hooks and says from where, in any case of the agent's name" do
      installer.install(codex, home, "workspace session-event", quiet: true)

      result = command.uninstall(agent: "Codex")

      expect(result).to include("agent" => "codex", "path" => codex_path, "removed" => 10, "dry_run" => false)
      expect(result["backup"]).to start_with("#{codex_path}.workspace-backup-")
      expect(JSON.parse(File.read(codex_path))).not_to have_key("hooks")
    end

    it "refuses an agent workspace installs no hooks for, naming the ones it does" do
      expect { command.uninstall(agent: "opencode") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_agent_kind")
        expect(e.details).to eq("kind" => "opencode", "known" => %w[claude codex])
      }
    end
  end

  describe "#uninstall_in" do
    let(:claude) { Workspace::AgentProvider.find("claude") }
    let(:main_dir) { Dir.mktmpdir }
    let(:wt_dir) { Dir.mktmpdir }
    let(:members) do
      [Workspace::ProjectCatalog::Member.new(workspace: "app", path: main_dir, kind: "main", configured: true, exists: true),
        Workspace::ProjectCatalog::Member.new(workspace: nil, path: wt_dir, kind: "worktree", configured: false, exists: true),
        Workspace::ProjectCatalog::Member.new(workspace: "gone", path: "/nope/gone", kind: "worktree", configured: true, exists: false)]
    end
    let(:project) { Workspace::ProjectCatalog::Project.new(name: "app", id: main_dir, path: main_dir, vcs: "git", members: members) }
    let(:catalog) do
      double("catalog", find: project, for_cwd: project).tap do |c|
        allow(c).to receive(:members).with(project, include_unconfigured: true).and_return(members)
      end
    end
    let(:checkout) { double("checkout") }
    subject(:command) { described_class.new(hook_installer: installer, working_dir: home, checkout: checkout, catalog: catalog) }

    after { FileUtils.remove_entry(main_dir) && FileUtils.remove_entry(wt_dir) }

    it "removes the hooks from every checkout of the project, skipping a missing one" do
      installer.install(claude, main_dir, "workspace session-event", quiet: true)
      installer.install(claude, wt_dir, "workspace session-event", quiet: true)

      rows = command.uninstall_in(agent: "claude", project: "app")

      expect(rows.map { |r| r.values_at("workspace", "checkout", "outcome") }).to eq(
        [["app", main_dir, "removed"], [nil, wt_dir, "removed"], ["gone", "/nope/gone", "skipped"]]
      )
      expect(rows.last).to include("reason" => "checkout_missing")
      expect(JSON.parse(File.read(File.join(main_dir, ".claude/settings.json")))).not_to have_key("hooks")
    end

    it "uses the current directory's project for a bare --project and changes nothing on a dry run" do
      installer.install(claude, main_dir, "workspace session-event", quiet: true)

      rows = command.uninstall_in(agent: "claude", project: true, dry_run: true)

      expect(catalog).to have_received(:for_cwd).with(home)
      expect(rows.first["outcome"]).to eq("would_remove")
      expect(JSON.parse(File.read(File.join(main_dir, ".claude/settings.json")))).to have_key("hooks")
    end

    it "makes an unreadable file a failed row and still handles the others" do
      File.write(File.join(main_dir, ".claude/settings.json").tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, "[]")
      installer.install(claude, wt_dir, "workspace session-event", quiet: true)

      rows = command.uninstall_in(agent: "claude", project: "app")

      expect(rows.first).to include("outcome" => "failed", "reason" => "hook_settings_unreadable")
      expect(rows[1]["outcome"]).to eq("removed")
    end

    it "targets one workspace's checkout with name" do
      allow(checkout).to receive(:resolve).with("app", working_dir: home, allow_detached: true)
        .and_return({"workspace" => "app", "path" => main_dir, "branch" => nil})

      rows = command.uninstall_in(agent: "Claude", name: "app")

      expect(rows).to contain_exactly(a_hash_including("workspace" => "app", "checkout" => main_dir, "outcome" => "not_installed"))
    end

    it "refuses codex with either flag, and both flags together" do
      expect { command.uninstall_in(agent: "codex", name: "app") }.to raise_error(Workspace::UsageError, /user-level/)
      expect { command.uninstall_in(agent: "codex", project: true) }.to raise_error(Workspace::UsageError, /user-level/)
      expect { command.uninstall_in(agent: "claude", name: "a", project: "b") }.to raise_error(Workspace::UsageError, /combined/)
    end
  end

  describe "the CLI" do
    let(:bin) { File.expand_path("../../../bin/workspace", __dir__) }

    def cli(*args)
      Open3.capture3({"CODEX_HOME" => File.dirname(codex_path)}, bin, "hooks", "uninstall", *args)
    end

    before { installer.install(codex, home, "workspace session-event", quiet: true) }

    it "prints one action document, dry run first, then removes, then finds nothing" do
      out, _err, status = cli("--agent=codex", "--dry-run", "--json")
      doc = JSON.parse(out)
      expect([status.exitstatus, doc["status"], doc["results"].first["outcome"], doc["results"].first["removed"]]).to eq([0, "dry_run", "would_remove", 10])

      out, = cli("--agent", "codex", "--json")
      expect(JSON.parse(out)["results"].first).to include("outcome" => "removed", "removed" => 10)

      out, = cli("--agent", "codex", "--json")
      expect(JSON.parse(out)["results"].first).to include("outcome" => "not_installed", "removed" => 0, "backup" => nil)
    end

    it "requires --agent" do
      out, _err, status = cli("--json")

      expect(status.exitstatus).to eq(1)
      expect(JSON.parse(out)).to include("ok" => false, "code" => "usage")
    end
  end
end
