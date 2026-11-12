require "spec_helper"

RSpec.describe Workspace::TemplateInUse do
  let(:template_config) { instance_double(Workspace::TmuxinatorTemplateConfig) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: %w[api api.worktree-x web]) }
  let(:global) { Workspace::LibraryStore.new(dir: "/lib", scope: "global") }
  let(:project) { Workspace::LibraryStore.new(dir: "/lib/api", scope: "project", project: "api") }
  subject(:in_use) { described_class.new(template_config: template_config, project_config: project_config) }

  def selects(workspace, project_name: "default", project_source: "default", worktree_name: "default", worktree_source: "default")
    allow(template_config).to receive(:name).with(:project, workspace: workspace).and_return("name" => project_name, "source" => project_source)
    allow(template_config).to receive(:name).with(:worktree, workspace: workspace).and_return("name" => worktree_name, "source" => worktree_source)
  end

  before { [nil, "api", "api.worktree-x", "web"].each { |w| selects(w) } }

  it "finds nothing when only the default is in effect, even for a set named default" do
    expect(in_use.users("default", global)).to eq([])
    expect { in_use.check!("default", global, verb: "remove") }.not_to raise_error
  end

  it "lists each workspace and kind a key selects, the global file as nil" do
    selects(nil, project_name: "team", project_source: "global")
    selects("web", worktree_name: "team", worktree_source: "project")

    expect(in_use.users("team", global)).to eq([
      {"workspace" => nil, "kind" => "project", "layer" => "global"},
      {"workspace" => "web", "kind" => "worktree", "layer" => "project"}
    ])
  end

  it "looks only at the project's workspaces for a project-scope set" do
    selects(nil, project_name: "team", project_source: "global")
    selects("web", project_name: "team", project_source: "project")
    selects("api.worktree-x", project_name: "team", project_source: "worktree")

    expect(in_use.users("team", project).map { |u| u["workspace"] }).to eq(["api.worktree-x"])
  end

  it "leaves out a config file that can't be read" do
    allow(template_config).to receive(:name).with(:project, workspace: "web").and_raise(Workspace::ConfigParseError.new("web.yml", "bad"))

    expect(in_use.users("team", global)).to eq([])
  end

  it "raises template_in_use with the users and a --force retry" do
    selects(nil, project_name: "team", project_source: "global")

    expect { in_use.check!("team", global, verb: "replace") }.to raise_error(Workspace::Error) { |e|
      expect([e.code, e.details["count"], e.details["users"].first]).to eq(["template_in_use", 1, {"workspace" => nil, "kind" => "project", "layer" => "global"}])
      expect(e.message).to include("Won't replace the tmuxinator template 'team'")
      expect(e.retry).to include("flags" => ["--force"])
    }
  end
end

RSpec.describe Workspace::TemplateInUse, "default and warning" do
  let(:template_config) { instance_double(Workspace::TmuxinatorTemplateConfig) }
  let(:project_config) { instance_double(Workspace::ProjectConfig, available_projects: %w[web]) }
  let(:global) { Workspace::LibraryStore.new(dir: "/lib", scope: "global") }
  subject(:in_use) { described_class.new(template_config: template_config, project_config: project_config) }

  it "refuses a set named default in a user store as template_in_use" do
    expect { in_use.check_default!("default", global) }.to raise_error(Workspace::Error) { |e|
      expect([e.code, e.details["hides"], e.retry]).to eq(["template_in_use", "default", {"flags" => ["--force"], "destructive" => true}])
    }
  end

  it "lets other names and the built-in store through" do
    expect { in_use.check_default!("team", global) }.not_to raise_error
    expect { in_use.check_default!("default", Workspace::LibraryStore.new(dir: "/b", scope: "builtin")) }.not_to raise_error
  end

  it "words a warning naming the keys that still select the set, nil when none" do
    allow(template_config).to receive(:name).and_return("name" => "default", "source" => "default")
    expect(in_use.warning("team", global)).to be_nil

    allow(template_config).to receive(:name).with(:project, workspace: nil).and_return("name" => "team", "source" => "global")
    warning = in_use.warning("team", global)
    expect(warning).to include("code" => "template_in_use", "keys" => [{"workspace" => nil, "kind" => "project", "layer" => "global"}])
    expect(warning["message"]).to include("1 setting still name the tmuxinator template 'team'").and include("global project via global")
  end
end
