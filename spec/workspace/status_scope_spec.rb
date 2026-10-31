require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::StatusScope do
  include FakeCheckouts

  let(:vcs) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:roots) { {} }
  let(:config) { Workspace::Config.new(workspace_dir: @root) }
  let(:project_config) do
    Workspace::ProjectConfig.new(config: config, output: StringIO.new, git: vcs).tap do |pc|
      allow(pc).to receive(:available_projects) { roots.keys.sort }
      allow(pc).to receive(:project_root_for) { |name| roots[name] }
    end
  end
  let(:catalog) { Workspace::ProjectCatalog.new(project_config: project_config, git: vcs) }
  let(:detected) { nil }
  let(:detector) { instance_double(Workspace::ProjectDetector, detect: detected) }
  let(:working_dir) { @root }
  subject(:scope) { described_class.new(project_detector: detector, catalog: catalog) }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def resolve(name: nil, project: nil, all: nil, dir: working_dir)
    scope.resolve(name: name, project: project, all: all, working_dir: dir)
  end

  let(:app) { make_main_checkout(File.join(@root, "app")) }
  let(:login) { make_linked_worktree(app, File.join(app, ".worktrees", "login")) }

  before do
    roots["app"] = app
    roots["app.worktree-login"] = login
  end

  it "resolves --all" do
    expect(resolve(all: true)).to have_attributes(kind: :all, workspace: nil, project: nil)
  end

  it "resolves --name without checking it" do
    expect(resolve(name: "ghost")).to have_attributes(kind: :workspace, workspace: "ghost", project: nil)
  end

  it "resolves no flag to the detected workspace" do
    allow(detector).to receive(:detect).with(working_dir).and_return("app.worktree-login")

    expect(resolve).to have_attributes(kind: :workspace, workspace: "app.worktree-login", project: nil)
  end

  it "keeps a detected workspace that has no config" do
    allow(detector).to receive(:detect).and_return("loose")

    expect(resolve).to have_attributes(kind: :workspace, workspace: "loose")
  end

  it "does not read the catalog when the detector finds the workspace" do
    allow(detector).to receive(:detect).and_return("app")
    expect(catalog).not_to receive(:all)

    resolve
  end

  it "resolves --project NAME from outside any workspace" do
    result = resolve(project: "app")

    expect(result.kind).to eq(:project)
    expect(result.project.name).to eq("app")
  end

  it "refuses an unknown --project NAME as unknown_workspace" do
    expect { resolve(project: "nope") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_workspace")
      expect(e.details).to eq("name" => "nope")
    }
  end

  it "resolves a bare --project from a worktree workspace to its project" do
    allow(detector).to receive(:detect).and_return("app.worktree-login")

    expect(resolve(project: true).project.name).to eq("app")
  end

  it "refuses a bare --project for a detected workspace in no project" do
    allow(detector).to receive(:detect).and_return("loose")

    expect { resolve(project: true) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_workspace")
      expect(e.details).to eq("name" => "loose")
    }
  end

  it "refuses each pair of flags with a usage error" do
    [{name: "a", project: true}, {name: "a", all: true}, {project: "a", all: true}, {name: "a", project: "b", all: true}].each do |flags|
      expect { resolve(**flags) }.to raise_error(Workspace::UsageError, "Give only one of --name, --project and --all.")
    end
  end

  context "when the directory is in a configured checkout the detector does not know" do
    it "finds the main checkout with no flag" do
      expect(resolve(dir: app)).to have_attributes(kind: :workspace, workspace: "app")
    end

    it "finds the main checkout's project with a bare --project" do
      expect(resolve(project: true, dir: app)).to have_attributes(kind: :project, workspace: nil)
      expect(resolve(project: true, dir: app).project.name).to eq("app")
    end

    it "picks the deepest member for a worktree inside the main checkout" do
      expect(resolve(dir: File.join(login, "lib"))).to have_attributes(workspace: "app.worktree-login")
    end

    it "resolves a linked worktree with no config to the main workspace" do
      unconfigured = make_linked_worktree(app, File.join(app, ".worktrees", "spike"))

      expect(resolve(dir: unconfigured)).to have_attributes(workspace: "app")
    end
  end

  context "when the directory is in no workspace" do
    it "refuses with not_in_workspace naming the flags, with no flag" do
      expect { resolve }.to raise_error(Workspace::Error) { |e|
        expect(e.code).to eq("not_in_workspace")
        expect(e.details).to eq("path" => working_dir)
        expect(e.message).to include("--name", "--project NAME", "--all")
      }
    end

    it "refuses a bare --project the same way" do
      expect { resolve(project: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end

    it "stays not_in_workspace when a config holds a disallowed YAML class" do
      pc = Workspace::ProjectConfig.new(config: config, output: StringIO.new, git: vcs)
      allow(config).to receive(:tmuxinator_dir).and_return(@root)
      allow(config).to receive(:config_path_for) { |name| File.join(@root, "workspace.#{name}.yml") }
      File.write(File.join(@root, "workspace.odd.yml"), "name: odd\nroot: !ruby/object:Object {}\n")
      real_catalog = Workspace::ProjectCatalog.new(project_config: pc, git: vcs)
      outside = described_class.new(project_detector: detector, catalog: real_catalog)

      expect { outside.resolve(name: nil, project: nil, all: nil, working_dir: @root) }
        .to raise_error(Workspace::Error) { |e| expect(e.code).to eq("not_in_workspace") }
    end
  end
end
