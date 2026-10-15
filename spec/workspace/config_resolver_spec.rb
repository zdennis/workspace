require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::ConfigResolver do
  let(:dir) { Dir.mktmpdir }
  let(:config) { instance_double(Workspace::Config, workspace_config_dir: dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  subject(:resolver) { described_class.new(project_settings: settings) }

  after { FileUtils.rm_rf(dir) }

  def write(name, text)
    path = (name == :global) ? settings.global_config_path : settings.project_config_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  it "reads a :parent key from the project's file even for a worktree" do
    write("api", "dev:\n  up: ./start\n")
    write("api.worktree-x", "dev:\n  up: ./other\n")
    resolution = resolver.view(workspace: "api.worktree-x").resolve("dev.up")
    expect(resolution.winner.layer).to eq("project")
    expect(resolution.winner.value).to eq("./start")
  end

  it "reads notes.dir from a worktree's own file and a main checkout's project file" do
    write("api", "notes:\n  dir: /p\n")
    write("api.worktree-x", "notes:\n  dir: /w\n")
    expect(resolver.view(workspace: "api.worktree-x").raw("notes.dir")).to eq("/w")
    expect(resolver.view(workspace: "api").raw("notes.dir")).to eq("/p")
  end

  it "reports set? and a nil raw for an unset key" do
    view = resolver.view(workspace: "api")
    expect(view.set?("dev.up")).to be(false)
    expect(view.raw("dev.up")).to be_nil
    expect(view.resolve("dev.up").hits).to eq([])
  end

  it "uses project: for the parent instead of splitting the name" do
    write("api", "dev:\n  up: ./start\n")
    write("other", "dev:\n  up: ./no\n")
    expect(resolver.view(workspace: "api.worktree-x", project: "api").raw("dev.up")).to eq("./start")
  end

  it "reads a global key from the global file without parsing a broken project file" do
    write(:global, "context:\n  source: scrape\n")
    write("api", "dev: [unclosed\n")
    expect(resolver.view(workspace: "api").raw("context.source")).to eq("scrape")
  end

  it "reads a project file strictly and the global file leniently" do
    write("api", "dev: [unclosed\n")
    expect { resolver.view(workspace: "api").raw("dev.up") }.to raise_error(Workspace::ConfigParseError)
    write(:global, "context: [unclosed\n")
    expect(resolver.view(workspace: "api").raw("context.source")).to be_nil
  end

  it "drops the layers above upto" do
    write("api", "dev:\n  up: ./start\n")
    expect(resolver.view(workspace: "api", upto: "global").raw("dev.up")).to be_nil
    expect(resolver.view(workspace: "api", upto: "project").raw("dev.up")).to eq("./start")
  end

  it "refuses an unknown upto and an undeclared key" do
    expect { resolver.view(workspace: "api", upto: "worktree") }.to raise_error(ArgumentError, /upto/)
    expect { resolver.view(workspace: "api").resolve("nope.key") }.to raise_error(KeyError)
  end

  it "loads each layer file once per view" do
    write("api", "dev:\n  up: ./start\n  ready: ok\n")
    allow(settings).to receive(:load).and_call_original
    view = resolver.view(workspace: "api")
    view.raw("dev.up")
    view.raw("dev.ready")
    expect(settings).to have_received(:load).once
  end
end
