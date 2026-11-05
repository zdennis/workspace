require "spec_helper"

RSpec.describe Workspace::WorkspaceCheckout do
  let(:git) { instance_double(Workspace::Git, worktree_branch: "feature/x") }
  let(:project_config) { instance_double(Workspace::ProjectConfig, project_root_for: "/src/api") }
  let(:project_detector) { instance_double(Workspace::ProjectDetector, detect: "api") }
  subject(:checkout) { described_class.new(git: git, project_config: project_config, project_detector: project_detector) }

  it "resolves the named workspace to its checkout and branch" do
    expect(checkout.resolve("api", working_dir: "/elsewhere")).to eq("workspace" => "api", "path" => "/src/api", "branch" => "feature/x")
    expect(project_detector).not_to have_received(:detect)
  end

  it "detects the workspace of the working directory without a name" do
    expect(checkout.resolve(nil, working_dir: "/src/api/lib")).to include("workspace" => "api")
    expect(project_detector).to have_received(:detect).with("/src/api/lib")
  end

  it "raises not_in_workspace when nothing is detected" do
    allow(project_detector).to receive(:detect).and_return(nil)

    expect { checkout.resolve(nil, working_dir: "/tmp") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("not_in_workspace")
      expect(e.details).to eq("path" => "/tmp")
    }
  end

  it "raises unknown_workspace for a name with no checkout" do
    allow(project_config).to receive(:project_root_for).and_return(nil)

    expect { checkout.resolve("nope", working_dir: "/tmp") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_workspace")
      expect(e.details).to eq("name" => "nope")
    }
  end

  it "refuses a detached HEAD" do
    allow(git).to receive(:worktree_branch).and_return(nil)

    expect { checkout.resolve("api", working_dir: "/tmp") }.to raise_error(Workspace::Error, /detached HEAD/)
  end

  it "returns a nil branch for a detached HEAD when asked to allow one" do
    allow(git).to receive(:worktree_branch).and_return(nil)

    expect(checkout.resolve("api", working_dir: "/tmp", allow_detached: true)).to include("branch" => nil, "path" => "/src/api")
  end
end
