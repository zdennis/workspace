require "workspace"
require "tmpdir"
require "yaml"
require "fileutils"

RSpec.describe Workspace::ProjectSettings do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Workspace::Config, workspace_config_dir: tmpdir)
  end
  let(:settings) { described_class.new(config: config) }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#load" do
    it "returns empty hash when no config file exists" do
      expect(settings.load("nonexistent")).to eq({})
    end

    it "returns parsed YAML data" do
      projects_dir = File.join(tmpdir, "projects")
      FileUtils.mkdir_p(projects_dir)
      File.write(File.join(projects_dir, "myproject.yml"), YAML.dump({"hooks" => {"post_launch" => "echo hi"}}))

      data = settings.load("myproject")
      expect(data).to eq({"hooks" => {"post_launch" => "echo hi"}})
    end

    it "returns empty hash for corrupt YAML" do
      projects_dir = File.join(tmpdir, "projects")
      FileUtils.mkdir_p(projects_dir)
      File.write(File.join(projects_dir, "bad.yml"), "---\n\t\tinvalid: yaml: broken")

      expect(settings.load("bad")).to eq({})
    end
  end

  describe "#save" do
    it "writes YAML to the project config path" do
      data = {"hooks" => {"post_launch" => "bin/setup"}}
      settings.save("myproject", data)

      path = File.join(tmpdir, "projects", "myproject.yml")
      expect(File.exist?(path)).to be true
      expect(YAML.safe_load_file(path)).to eq(data)
    end

    it "creates the projects directory if it does not exist" do
      settings.save("newproject", {"key" => "value"})

      path = File.join(tmpdir, "projects", "newproject.yml")
      expect(File.exist?(path)).to be true
    end
  end

  describe "#load_global" do
    it "returns empty hash when no global config exists" do
      expect(settings.load_global).to eq({})
    end

    it "returns parsed global config" do
      File.write(File.join(tmpdir, "config.yml"), YAML.dump({"layouts" => {"coding" => "layout-string"}}))

      expect(settings.load_global).to eq({"layouts" => {"coding" => "layout-string"}})
    end

    it "returns empty hash for corrupt global YAML" do
      File.write(File.join(tmpdir, "config.yml"), "---\n\t\tinvalid")

      expect(settings.load_global).to eq({})
    end
  end

  describe "#hook_for" do
    it "returns nil when no hooks are configured" do
      expect(settings.hook_for("myproject", "post_launch")).to be_nil
    end

    it "returns the hook script for the given event" do
      projects_dir = File.join(tmpdir, "projects")
      FileUtils.mkdir_p(projects_dir)
      File.write(
        File.join(projects_dir, "myproject.yml"),
        YAML.dump({"hooks" => {"post_launch" => "echo launched"}})
      )

      expect(settings.hook_for("myproject", "post_launch")).to eq("echo launched")
    end

    it "returns nil for unconfigured events" do
      projects_dir = File.join(tmpdir, "projects")
      FileUtils.mkdir_p(projects_dir)
      File.write(
        File.join(projects_dir, "myproject.yml"),
        YAML.dump({"hooks" => {"post_launch" => "echo hi"}})
      )

      expect(settings.hook_for("myproject", "post_kill")).to be_nil
    end
  end

  describe "#layouts_for" do
    it "returns empty hash when no layouts exist" do
      expect(settings.layouts_for("myproject")).to eq({})
    end

    it "returns global layouts when no project layouts exist" do
      File.write(File.join(tmpdir, "config.yml"), YAML.dump({"layouts" => {"coding" => "global-layout"}}))

      expect(settings.layouts_for("myproject")).to eq({"coding" => "global-layout"})
    end

    it "merges project layouts over global layouts" do
      File.write(File.join(tmpdir, "config.yml"), YAML.dump({"layouts" => {"coding" => "global", "equal" => "global-equal"}}))

      projects_dir = File.join(tmpdir, "projects")
      FileUtils.mkdir_p(projects_dir)
      File.write(
        File.join(projects_dir, "myproject.yml"),
        YAML.dump({"layouts" => {"coding" => "project-override"}})
      )

      layouts = settings.layouts_for("myproject")
      expect(layouts["coding"]).to eq("project-override")
      expect(layouts["equal"]).to eq("global-equal")
    end
  end

  describe "#project_config_path" do
    it "returns the path to the project config file" do
      expect(settings.project_config_path("myproject")).to eq(File.join(tmpdir, "projects", "myproject.yml"))
    end
  end

  describe "#global_config_path" do
    it "returns the path to the global config file" do
      expect(settings.global_config_path).to eq(File.join(tmpdir, "config.yml"))
    end
  end
end
