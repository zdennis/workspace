require "stringio"
require "tmpdir"

RSpec.describe Workspace::ClaudeTrustConfig do
  let(:error_output) { StringIO.new }
  let(:view) { instance_double(Workspace::ConfigResolver::View) }
  let(:resolver) { instance_double(Workspace::ConfigResolver, view: view) }

  subject(:config) { described_class.new(config_resolver: resolver, error_output: error_output) }

  it "is off when the key is unset" do
    allow(view).to receive(:raw).with("agent.claude.trust_checkout").and_return(nil)

    expect(config.enabled?("myapp")).to be(false)
  end

  it "reads true and false" do
    allow(view).to receive(:raw).with("agent.claude.trust_checkout").and_return("true", false)

    expect(config.enabled?("myapp")).to be(true)
    expect(config.enabled?("myapp")).to be(false)
  end

  it "falls back to the default with a warning for a bad value" do
    allow(view).to receive(:raw).and_return("maybe")

    expect(config.enabled?("myapp")).to be(false)
    expect(error_output.string).to include("invalid agent.claude.trust_checkout for 'myapp'")
  end

  it "falls back to the default with a warning when a config file can't be parsed" do
    allow(view).to receive(:raw).and_raise(Workspace::ConfigParseError.new("/x.yml", "bad yaml."))

    expect(config.enabled?("myapp")).to be(false)
    expect(error_output.string).to include("bad yaml.")
  end

  describe "for a worktree workspace" do
    let(:root) { Dir.mktmpdir("ws-trust-root") }
    let(:project_config) { instance_double(Workspace::ProjectConfig) }
    let(:lineage) { instance_double(Workspace::WorkspaceLineage) }

    subject(:config) { described_class.new(config_resolver: resolver, project_config: project_config, lineage: lineage, error_output: error_output) }

    before { allow(view).to receive(:raw).with("agent.claude.trust_checkout").and_return("true") }

    after { FileUtils.remove_entry(root) }

    it "reads the parent project, where config set stores the value" do
      allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
      allow(lineage).to receive(:resolve).with(cwd: root).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "app"))

      expect(config.enabled?("app-PROJ-1")).to be(true)
      expect(resolver).to have_received(:view).with(workspace: "app-PROJ-1", project: "app")
    end

    it "passes no project when the root is not a directory" do
      allow(project_config).to receive(:project_root_for).with("gone").and_return(File.join(root, "missing"))

      config.enabled?("gone")

      expect(resolver).to have_received(:view).with(workspace: "gone", project: nil)
    end

    it "passes no project when the lineage cannot be resolved" do
      allow(project_config).to receive(:project_root_for).with("app-PROJ-1").and_return(root)
      allow(lineage).to receive(:resolve).and_raise(Workspace::Error, "no git")

      config.enabled?("app-PROJ-1")

      expect(resolver).to have_received(:view).with(workspace: "app-PROJ-1", project: nil)
    end
  end
end
