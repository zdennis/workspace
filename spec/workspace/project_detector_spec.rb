require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::ProjectDetector do
  let(:state) { instance_double(Workspace::State, load: nil, keys: []) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: ["Notes"]) }
  let(:workspace_name) { Workspace::WorkspaceName.new(project_config: project_config) }
  let(:dir) { File.realpath(Dir.mktmpdir) }

  after { FileUtils.remove_entry(dir) }

  it "gives a marker's name in the spelling of the existing config" do
    File.write(File.join(dir, ".workspace-project"), "notes\n")
    detector = described_class.new(state: state, project_config: project_config, workspace_name: workspace_name)

    expect(detector.detect(dir)).to eq("Notes")
    expect(detector.detect_from_marker(dir)).to eq("Notes")
  end

  it "returns the marker's name as written without a workspace name" do
    File.write(File.join(dir, ".workspace-project"), "notes\n")

    expect(described_class.new(state: state, project_config: project_config).detect(dir)).to eq("notes")
  end

  it "keeps a marker's name as written when no config matches it" do
    File.write(File.join(dir, ".workspace-project"), "Headless\n")
    detector = described_class.new(state: state, project_config: project_config, workspace_name: workspace_name)

    expect(detector.detect(dir)).to eq("Headless")
  end

  it "settles a name found from the active roots" do
    allow(state).to receive(:keys).and_return(["notes"])
    allow(project_config).to receive(:project_root_for).with("notes").and_return(dir)
    detector = described_class.new(state: state, project_config: project_config, workspace_name: workspace_name)

    expect(detector.detect(dir)).to eq("Notes")
  end

  it "is nil when nothing is detected" do
    detector = described_class.new(state: state, project_config: project_config, workspace_name: workspace_name)

    expect(detector.detect(dir)).to be_nil
  end
end
