require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AlertConfig do
  let(:dir) { Dir.mktmpdir("ws-alert-config") }
  let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:error_output) { StringIO.new }
  let(:alert_config) { described_class.new(project_settings: project_settings, error_output: error_output) }

  after { FileUtils.remove_entry(dir) }

  describe ".parse_idle_after" do
    it "parses seconds and durations" do
      expect(described_class.parse_idle_after("90")).to eq(90.0)
      expect(described_class.parse_idle_after("15m")).to eq(900.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "-1", "later"].each do |bad|
        expect { described_class.parse_idle_after(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".parse_notify" do
    it "rejects a blank command" do
      expect { described_class.parse_notify("   ") }.to raise_error(ArgumentError, /blank/)
    end
  end

  describe "#for_workspace with an unparseable project config" do
    it "warns and sends no alerts instead of raising" do
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "app.yml"), "a: [\n")

      expect(alert_config.for_workspace("app")).to eq(notify: nil, idle_after: 600)
      expect(error_output.string).to include("Cannot parse", "app.yml", "No alerts will be sent")
    end
  end

  describe "#for_workspace" do
    it "sends no alerts and uses the default idle threshold when unset" do
      expect(alert_config.for_workspace("app")).to eq(notify: nil, idle_after: 600)
    end

    it "reads alerts.notify and alerts.idle_after" do
      project_settings.save("app", {"alerts" => {"notify" => " say hi ", "idle_after" => "15m"}})

      expect(alert_config.for_workspace("app")).to eq(notify: "say hi", idle_after: 900.0)
    end

    it "warns and falls back when a hand-edited value is invalid" do
      project_settings.save("app", {"alerts" => {"notify" => "", "idle_after" => "soon"}})

      expect(alert_config.for_workspace("app")).to eq(notify: nil, idle_after: 600)
      expect(error_output.string).to include("invalid alerts.notify for 'app'", "no alerts will be sent")
      expect(error_output.string).to include("invalid alerts.idle_after for 'app'", "using 600s")
    end

    it "ignores an alerts block that is not a mapping" do
      project_settings.save("app", {"alerts" => "say hi"})

      expect(alert_config.for_workspace("app")).to eq(notify: nil, idle_after: 600)
    end

    context "for a worktree workspace" do
      let(:root) { Dir.mktmpdir("ws-alert-root") }
      let(:project_config) { instance_double(Workspace::ProjectConfig) }
      let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
      let(:alert_config) do
        described_class.new(project_settings: project_settings, project_config: project_config,
          lineage: lineage, error_output: error_output)
      end

      after { FileUtils.remove_entry(root) }

      it "reads the parent project's settings, where config set stores them" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).with(cwd: root)
          .and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
        project_settings.save("app", {"alerts" => {"notify" => "say hi"}})

        expect(alert_config.for_workspace("app-PROJ-1")[:notify]).to eq("say hi")
      end

      it "reads the workspace's own name when its root can't be found" do
        allow(project_config).to receive(:project_root_for).with("gone").and_return(nil)
        project_settings.save("gone", {"alerts" => {"notify" => "say gone"}})

        expect(alert_config.for_workspace("gone")[:notify]).to eq("say gone")
      end

      it "reads the workspace's own name when its lineage can't be resolved" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no git")
        project_settings.save("app-PROJ-1", {"alerts" => {"notify" => "say own"}})

        expect(alert_config.for_workspace("app-PROJ-1")[:notify]).to eq("say own")
      end
    end
  end
end
