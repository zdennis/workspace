require "spec_helper"

RSpec.describe Workspace::TemplateSelection do
  let(:app) { Workspace::ProjectCatalog::Project.new(name: "app", members: [Workspace::ProjectCatalog::Member.new(workspace: "app", configured: true), Workspace::ProjectCatalog::Member.new(workspace: "app.worktree-login", configured: true), Workspace::ProjectCatalog::Member.new(workspace: nil, configured: false)]) }
  let(:lib) { Workspace::ProjectCatalog::Project.new(name: "lib", members: [Workspace::ProjectCatalog::Member.new(workspace: "lib", configured: true), Workspace::ProjectCatalog::Member.new(workspace: "lib.worktree-x", configured: false)]) }
  let(:catalog) { instance_double(Workspace::ProjectCatalog, all: [app, lib]) }
  let(:status_scope) { instance_double(Workspace::StatusScope) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  subject(:selection) { described_class.new(status_scope: status_scope, catalog: catalog, project_config: project_config) }

  before { allow(project_config).to receive(:exists?) { |name| %w[app lib].include?(name) } }

  it "takes the workspace of the working directory when nothing is given" do
    allow(status_scope).to receive(:resolve).with(name: nil, project: nil, all: nil, working_dir: "/w")
      .and_return(Workspace::StatusScope::Scope.new(kind: :workspace, workspace: "app"))

    expect(selection.call(working_dir: "/w")).to eq(["app"])
  end

  it "takes the configured workspaces of a project" do
    allow(status_scope).to receive(:resolve).with(name: nil, project: "app", all: nil, working_dir: "/w")
      .and_return(Workspace::StatusScope::Scope.new(kind: :project, project: app))

    expect(selection.call(project: "app", working_dir: "/w")).to eq(%w[app app.worktree-login])
  end

  it "takes the current workspace's project for a bare --project" do
    allow(status_scope).to receive(:resolve).with(name: nil, project: true, all: nil, working_dir: "/w")
      .and_return(Workspace::StatusScope::Scope.new(kind: :project, project: lib))

    expect(selection.call(project: true, working_dir: "/w")).to eq(["lib"])
  end

  it "takes every configured workspace of every project for --all" do
    allow(status_scope).to receive(:resolve).with(name: nil, project: nil, all: true, working_dir: "/w")
      .and_return(Workspace::StatusScope::Scope.new(kind: :all))

    expect(selection.call(all: true, working_dir: "/w")).to eq(%w[app app.worktree-login lib])
  end

  it "takes names as given, each once" do
    expect(selection.call(names: %w[lib app lib])).to eq(%w[lib app])
  end

  it "refuses a name with no config" do
    expect { selection.call(names: %w[app nope]) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_workspace")
      expect(e.details).to eq("name" => "nope")
    }
  end

  it "refuses names beside --all or --project, and both flags" do
    expect { selection.call(names: ["app"], all: true) }.to raise_error(Workspace::UsageError, /not a mix/)
    expect { selection.call(names: ["app"], project: true) }.to raise_error(Workspace::UsageError, /not a mix/)
    expect { selection.call(all: true, project: "app") }.to raise_error(Workspace::UsageError, /only one/)
  end

  it "says outside a workspace what these verbs take, not --name, and keeps the code and details" do
    allow(status_scope).to receive(:resolve).and_raise(Workspace::Error.new("Not in a workspace. pass --name WORKSPACE", code: "not_in_workspace", details: {"path" => "/w"}))

    expect { selection.call(working_dir: "/w") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("not_in_workspace")
      expect(e.details).to eq("path" => "/w")
      expect(e.message).to include("workspace NAMEs, --project NAME or --all").and(satisfy { |m| !m.include?("--name") })
    }
  end

  it "lets the scope's other errors through" do
    allow(status_scope).to receive(:resolve).and_raise(Workspace::Error.new("No project", code: "unknown_workspace"))

    expect { selection.call(project: "x", working_dir: "/w") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_workspace") }
  end
end
