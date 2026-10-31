require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::HandoffConfig do
  let(:dir) { Dir.mktmpdir("ws-handoff-config") }
  let(:project_settings) { Workspace::ProjectSettings.new(config: Struct.new(:workspace_config_dir).new(dir)) }
  let(:error_output) { StringIO.new }
  let(:handoff_config) { described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), error_output: error_output) }

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
    it "reads the follow-up keys, and accepts 0 for followup_max" do
      project_settings.save("app", {"handoff" => {"followup_interval" => "2m", "followup_max" => "0", "followup_prompt" => "Run %{new_cmd}"}})

      expect(handoff_config.for_workspace("app")).to include(followup_interval: 120, followup_max: 0, followup_prompt: "Run %{new_cmd}")
    end

    it "warns and falls back when followup_max is not a non-negative integer" do
      project_settings.save("app", {"handoff" => {"followup_max" => "-1"}})

      expect(handoff_config.for_workspace("app")).to include(followup_max: 10)
      expect(error_output.string).to include("invalid handoff.followup_max for 'app'")
    end

    it "uses the default threshold and the built-in prompts when unset" do
      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: Workspace::ConfigSchema.default("handoff.check_prompt"),
        resume_prompt: Workspace::ConfigSchema.default("handoff.resume_prompt"),
        followup_interval: 30, followup_max: 10,
        followup_prompt: Workspace::ConfigSchema.default("handoff.followup_prompt"))
    end

    it "reads handoff.threshold, handoff.check_prompt, and handoff.resume_prompt" do
      project_settings.save("app", {"handoff" => {"threshold" => "20", "check_prompt" => "Save %{usage}",
                                                  "resume_prompt" => "Resume %{doc}"}})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 20, check_prompt: "Save %{usage}",
        resume_prompt: "Resume %{doc}", followup_interval: 30, followup_max: 10,
        followup_prompt: Workspace::ConfigSchema.default("handoff.followup_prompt"))
    end

    it "warns and falls back when a hand-edited value is invalid" do
      project_settings.save("app", {"handoff" => {"threshold" => "0", "check_prompt" => "  "}})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: Workspace::ConfigSchema.default("handoff.check_prompt"),
        resume_prompt: Workspace::ConfigSchema.default("handoff.resume_prompt"),
        followup_interval: 30, followup_max: 10,
        followup_prompt: Workspace::ConfigSchema.default("handoff.followup_prompt"))
      expect(error_output.string).to include("invalid handoff.threshold for 'app'")
      expect(error_output.string).to include("invalid handoff.check_prompt for 'app'")
    end

    it "ignores a handoff block that is not a mapping" do
      project_settings.save("app", {"handoff" => "later"})

      expect(handoff_config.for_workspace("app")).to eq(threshold: 11, check_prompt: Workspace::ConfigSchema.default("handoff.check_prompt"),
        resume_prompt: Workspace::ConfigSchema.default("handoff.resume_prompt"),
        followup_interval: 30, followup_max: 10,
        followup_prompt: Workspace::ConfigSchema.default("handoff.followup_prompt"))
    end

    context "for a worktree workspace" do
      let(:root) { Dir.mktmpdir("ws-handoff-root") }
      let(:project_config) { instance_double(Workspace::ProjectConfig) }
      let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
      let(:handoff_config) do
        described_class.new(config_resolver: Workspace::ConfigResolver.new(project_settings: project_settings), project_config: project_config,
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

  describe "#auto?" do
    it "is off when handoff.auto is unset or the project has no handoff block" do
      expect(handoff_config.auto?("app")).to be(false)
      project_settings.save("app", {"handoff" => {"threshold" => "20"}})
      expect(handoff_config.auto?("app")).to be(false)
    end

    it "is on for true, written as a boolean or as the string config set stores" do
      [true, "true"].each do |value|
        project_settings.save("app", {"handoff" => {"auto" => value}})
        expect(handoff_config.auto?("app")).to be(true)
      end
    end

    it "is off for false" do
      project_settings.save("app", {"handoff" => {"auto" => "false"}})
      expect(handoff_config.auto?("app")).to be(false)
    end

    it "warns and stays off for a hand-edited value that is not true or false" do
      project_settings.save("app", {"handoff" => {"auto" => "maybe"}})

      expect(handoff_config.auto?("app")).to be(false)
      expect(error_output.string).to include("invalid handoff.auto for 'app'")
    end

    it "warns and stays off when the project config cannot be parsed" do
      FileUtils.mkdir_p(File.join(dir, "projects"))
      File.write(File.join(dir, "projects", "app.yml"), "a: [
")

      expect(handoff_config.auto?("app")).to be(false)
      expect(error_output.string).to include("Cannot parse")
    end

    it "leaves the hash #for_workspace returns as it was" do
      project_settings.save("app", {"handoff" => {"auto" => "true"}})

      expect(handoff_config.for_workspace("app").keys).to eq(%i[threshold check_prompt resume_prompt followup_interval followup_max followup_prompt])
    end
  end

  describe "a worktree name with no lineage wired (the instruction composer's wiring)" do
    it "reads the worktree's own file over the parent project's, key by key" do
      project_settings.save("app", {"handoff" => {"threshold" => "30", "auto" => "true"}})
      project_settings.save("app.worktree-x", {"handoff" => {"threshold" => "50"}})

      expect(handoff_config.for_workspace("app.worktree-x")[:threshold]).to eq(50)
      expect(handoff_config.auto?("app.worktree-x")).to be(true)
    end

    it "reads the worktree's own file when the parent project has none" do
      project_settings.save("app.worktree-x", {"handoff" => {"threshold" => "50", "auto" => "true"}})

      expect(handoff_config.for_workspace("app.worktree-x")[:threshold]).to eq(50)
      expect(handoff_config.auto?("app.worktree-x")).to be(true)
    end
  end
end
