require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentdConfig do
  let(:dir) { Dir.mktmpdir("ws-agentd-config") }
  let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:error_output) { StringIO.new }
  let(:agentd_config) { described_class.new(project_settings: project_settings, error_output: error_output) }

  after { FileUtils.remove_entry(dir) }

  describe ".parse_poll_interval" do
    it "parses seconds and durations" do
      expect(described_class.parse_poll_interval("45")).to eq(45.0)
      expect(described_class.parse_poll_interval("1m")).to eq(60.0)
    end

    it "rejects zero, negative and malformed values" do
      ["0", "-1", "later"].each do |bad|
        expect { described_class.parse_poll_interval(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "#poll_interval_for with an unparseable project config" do
    it "warns and uses the default instead of raising" do
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "app.yml"), "a: [\n")

      expect(agentd_config.poll_interval_for("app")).to eq(10)
      expect(error_output.string).to include("Cannot parse", "app.yml", "Using the default poll interval")
    end
  end

  describe "#poll_interval_for" do
    it "uses the default scan interval when unset" do
      expect(agentd_config.poll_interval_for("app")).to eq(10)
    end

    it "reads agentd.poll_interval as seconds or a duration" do
      project_settings.save("app", {"agentd" => {"poll_interval" => "45"}})

      expect(agentd_config.poll_interval_for("app")).to eq(45.0)

      project_settings.save("app", {"agentd" => {"poll_interval" => "1m"}})
      expect(agentd_config.poll_interval_for("app")).to eq(60.0)
    end

    it "warns and falls back when a hand-edited value is invalid" do
      project_settings.save("app", {"agentd" => {"poll_interval" => "soon"}})

      expect(agentd_config.poll_interval_for("app")).to eq(10)
      expect(error_output.string).to include("invalid agentd.poll_interval for 'app'", "using 10s")
    end

    it "ignores an agentd block that is not a mapping" do
      project_settings.save("app", {"agentd" => "fast"})

      expect(agentd_config.poll_interval_for("app")).to eq(10)
    end

    context "for a worktree workspace" do
      let(:root) { Dir.mktmpdir("ws-agentd-root") }
      let(:project_config) { instance_double(Workspace::ProjectConfig) }
      let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
      let(:agentd_config) do
        described_class.new(project_settings: project_settings, project_config: project_config,
          lineage: lineage, error_output: error_output)
      end

      after { FileUtils.remove_entry(root) }

      it "reads the parent project's settings, where config set stores them" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).with(cwd: root)
          .and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
        project_settings.save("app", {"agentd" => {"poll_interval" => "45"}})

        expect(agentd_config.poll_interval_for("app-PROJ-1")).to eq(45.0)
      end

      it "reads the workspace's own name when its root can't be found" do
        allow(project_config).to receive(:project_root_for).with("gone").and_return(nil)
        project_settings.save("gone", {"agentd" => {"poll_interval" => "45"}})

        expect(agentd_config.poll_interval_for("gone")).to eq(45.0)
      end

      it "reads the workspace's own name when its lineage can't be resolved" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no git")
        project_settings.save("app-PROJ-1", {"agentd" => {"poll_interval" => "45"}})

        expect(agentd_config.poll_interval_for("app-PROJ-1")).to eq(45.0)
      end
    end
  end
end
