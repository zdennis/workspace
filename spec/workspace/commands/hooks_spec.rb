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
      expect(JSON.parse(File.read(codex_path))["hooks"]).to eq({})
    end

    it "refuses an agent workspace installs no hooks for, naming the ones it does" do
      expect { command.uninstall(agent: "opencode") }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("unknown_agent_kind")
        expect(e.details).to eq("kind" => "opencode", "known" => %w[claude codex])
      }
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
