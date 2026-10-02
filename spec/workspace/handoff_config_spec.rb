require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::HandoffConfig do
  let(:dir) { Dir.mktmpdir("ws-handoff-config") }
  let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:error_output) { StringIO.new }
  let(:handoff_config) { described_class.new(project_settings: project_settings, error_output: error_output) }

  after { FileUtils.remove_entry(dir) }

  describe ".parse_threshold" do
    it "parses an integer percent" do
      expect(described_class.parse_threshold("42")).to eq(42)
    end

    it "rejects out-of-range and non-integer values" do
      ["0", "101", "soon", ""].each do |bad|
        expect { described_class.parse_threshold(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".parse_prompt" do
    it "rejects a blank prompt" do
      expect { described_class.parse_prompt("   ") }.to raise_error(ArgumentError, /blank/)
    end

    it "accepts any non-blank text" do
      expect(described_class.parse_prompt("Save your state.")).to eq("Save your state.")
    end
  end

  describe "#for_workspace with an unparseable project config" do
    it "warns and uses defaults instead of raising" do
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "app.yml"), "a: [\n")

      expect(handoff_config.for_workspace("app")[:threshold]).to eq(described_class::DEFAULT_THRESHOLD)
      expect(error_output.string).to include("Cannot parse", "app.yml", "Using handoff defaults")
    end
  end

  describe "#for_workspace" do
    it "uses the default threshold and no prompt overrides when unset" do
      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: nil, resume_prompt: nil)
    end

    it "reads handoff.threshold, handoff.check_prompt, and handoff.resume_prompt" do
      project_settings.save("app", {"handoff" => {"threshold" => "20", "check_prompt" => "Save %{usage}",
                                                  "resume_prompt" => "Resume %{doc}"}})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 20, check_prompt: "Save %{usage}",
        resume_prompt: "Resume %{doc}")
    end

    it "warns and falls back when a hand-edited value is invalid" do
      project_settings.save("app", {"handoff" => {"threshold" => "0", "check_prompt" => "  "}})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: nil, resume_prompt: nil)
      expect(error_output.string).to include("invalid handoff.threshold for 'app'")
      expect(error_output.string).to include("invalid handoff.check_prompt for 'app'")
    end

    it "ignores a handoff block that is not a mapping" do
      project_settings.save("app", {"handoff" => "later"})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: nil, resume_prompt: nil)
    end

    context "for a worktree workspace" do
      let(:root) { Dir.mktmpdir("ws-handoff-root") }
      let(:project_config) { instance_double(Workspace::ProjectConfig) }
      let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
      let(:handoff_config) do
        described_class.new(project_settings: project_settings, project_config: project_config,
          lineage: lineage, error_output: error_output)
      end

      after { FileUtils.remove_entry(root) }

      it "reads the parent project's settings, where config set stores them" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).with(cwd: root)
          .and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))
        project_settings.save("app", {"handoff" => {"threshold" => "30"}})

        expect(handoff_config.for_workspace("app-PROJ-1")[:threshold]).to eq(30)
      end

      it "reads the workspace's own name when its lineage can't be resolved" do
        allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
        allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no git")
        project_settings.save("app-PROJ-1", {"handoff" => {"threshold" => "33"}})

        expect(handoff_config.for_workspace("app-PROJ-1")[:threshold]).to eq(33)
      end
    end
  end
end
