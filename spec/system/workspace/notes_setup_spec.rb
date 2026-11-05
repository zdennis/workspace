require "spec_helper"
require "tmpdir"
require "open3"
require "stringio"
require "yaml"

RSpec.describe Workspace::NotesSetup do
  around do |example|
    Dir.mktmpdir("notes-setup") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:repo) { File.join(@dir, "api") }
  let(:linked) { File.join(@dir, "api-x") }
  let(:config_dir) { File.join(@dir, "config") }
  let(:git) { Workspace::Git.new(output: StringIO.new, input: StringIO.new) }
  let(:config) { instance_double(Workspace::Config, workspace_config_dir: config_dir) }
  let(:settings) { Workspace::ProjectSettings.new(config: config) }
  let(:roots) { {"api" => repo, "api.worktree-x" => linked} }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:notes) do
    Workspace::Commands::Notes.new(notes_dir: Workspace::NotesDir.new(git: git, home: "/home/me"), project_config: project_config,
      config_resolver: Workspace::ConfigResolver.new(project_settings: settings), git_exclude: Workspace::GitExclude.new(git: git), output: StringIO.new)
  end
  subject(:setup) { described_class.new(notes: notes, project_settings: settings) }

  def sh(*args, dir: repo)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "gc.auto=0", "-c", "maintenance.auto=false", *args)
    raise out unless status.success?
  end

  def write_config(name, text)
    path = settings.project_config_path(name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def stored(name) = settings.load(name).dig("notes", "dir")

  before do
    FileUtils.mkdir_p(repo)
    sh("init", "-q")
    sh("commit", "-q", "--allow-empty", "-m", "start")
    sh("worktree", "add", "-q", "-b", "feature/x", linked)
    allow(project_config).to receive(:project_root_for) { |name| roots[name] }
  end

  it "writes the computed path as the worktree's notes.dir, makes the directory and lists it in info/exclude" do
    result = setup.call("api.worktree-x")

    expect(result).to eq("dir" => "#{repo}/tmp/workspace-notes/feature-x", "warnings" => [])
    expect(stored("api.worktree-x")).to eq("#{repo}/tmp/workspace-notes/feature-x")
    expect(Dir.exist?("#{repo}/tmp/workspace-notes/feature-x")).to be true
    expect(File.read(File.join(repo, ".git", "info", "exclude")).lines.map(&:chomp)).to include("/tmp/workspace-notes/feature-x/")
  end

  it "warns when the directory already holds files, as a second branch with the same safe name would find it" do
    FileUtils.mkdir_p("#{repo}/tmp/workspace-notes/feature-x")
    File.write("#{repo}/tmp/workspace-notes/feature-x/a.md", "a")

    result = setup.call("api.worktree-x")

    expect(result["warnings"].size).to eq(1)
    expect(result["warnings"].first).to include("already holds files")
    expect(stored("api.worktree-x")).to eq("#{repo}/tmp/workspace-notes/feature-x")
  end

  it "does not warn for a directory already holding files once the path is the worktree's own, nor for an empty one" do
    FileUtils.mkdir_p("#{repo}/tmp/workspace-notes/feature-x")
    expect(setup.call("api.worktree-x")["warnings"]).to eq([])
    File.write("#{repo}/tmp/workspace-notes/feature-x/a.md", "a")

    expect(setup.call("api.worktree-x")["warnings"]).to eq([])
  end

  it "writes the project's notes.dir plus the branch when the project sets one" do
    write_config("api", "notes:\n  dir: #{@dir}/my-notes\n")

    result = setup.call("api.worktree-x")

    expect(result["dir"]).to eq("#{@dir}/my-notes/feature-x")
    expect(stored("api.worktree-x")).to eq("#{@dir}/my-notes/feature-x")
    expect(Dir.exist?("#{@dir}/my-notes/feature-x")).to be true
  end

  it "keeps the stored default when the project's notes.dir changes, and a later notes.dir still overrides it" do
    setup.call("api.worktree-x")
    write_config("api", "notes:\n  dir: #{@dir}/my-notes\n")
    expect(notes.info(name: "api.worktree-x")["dir"]).to eq("#{repo}/tmp/workspace-notes/feature-x")

    data = settings.load("api.worktree-x")
    data["notes"]["dir"] = "#{@dir}/mine"
    settings.save("api.worktree-x", data)

    expect(notes.info(name: "api.worktree-x")["dir"]).to eq("#{@dir}/mine")
  end

  it "gives a worktree with no config file the usual defaults beside notes.dir" do
    setup.call("api.worktree-x")

    expect(settings.load("api.worktree-x")).to eq("hooks" => {}, "layouts" => {}, "notes" => {"dir" => "#{repo}/tmp/workspace-notes/feature-x"})
  end

  it "fixes the path from the project's rule, so a later change to the rule does not move it" do
    write_config("api", "notes:\n  default_dir: #{@dir}/notes/{workspace}\n")

    setup.call("api.worktree-x")
    write_config("api", "notes:\n  default_dir: #{@dir}/elsewhere/{workspace}\n")

    expect(stored("api.worktree-x")).to eq("#{@dir}/notes/api.worktree-x")
    expect(notes.info(name: "api.worktree-x")["dir"]).to eq("#{@dir}/notes/api.worktree-x")
    expect(Dir.exist?("#{@dir}/notes/api.worktree-x")).to be true
  end

  it "keeps the rest of the worktree's config" do
    write_config("api.worktree-x", "hooks:\n  post_launch: echo hi\nnotes:\n  other: 1\n")

    setup.call("api.worktree-x")

    expect(settings.load("api.worktree-x")).to eq("hooks" => {"post_launch" => "echo hi"}, "notes" => {"other" => 1, "dir" => "#{repo}/tmp/workspace-notes/feature-x"})
  end

  it "never writes over an existing notes.dir, and sets up the directory that value names" do
    write_config("api.worktree-x", "notes:\n  dir: #{@dir}/mine\n")

    result = setup.call("api.worktree-x")

    expect(stored("api.worktree-x")).to eq("#{@dir}/mine")
    expect(result["dir"]).to eq("#{@dir}/mine")
    expect(Dir.exist?("#{@dir}/mine")).to be true
    expect(Dir.exist?("#{linked}/tmp")).to be false
  end

  it "makes the directory but pins no notes.dir for a name that is not a worktree name" do
    roots["api-y"] = linked

    result = setup.call("api-y")

    expect(result["warnings"]).to eq([])
    expect(Dir.exist?("#{linked}/tmp/workspace-notes")).to be true
    expect(File.exist?(settings.project_config_path("api-y"))).to be false
  end

  it "leaves a notes value that is not a mapping as it is" do
    write_config("api.worktree-x", "notes: nope\n")

    setup.call("api.worktree-x")

    expect(settings.load("api.worktree-x")).to eq("notes" => "nope")
  end

  it "still makes the directory when the config can't be written, and warns once" do
    allow(settings).to receive(:save).and_raise(Errno::EACCES)

    result = setup.call("api.worktree-x")

    expect(Dir.exist?("#{repo}/tmp/workspace-notes/feature-x")).to be true
    expect(result["warnings"].size).to eq(1)
    expect(result["warnings"].first).to include("could not record the notes directory")
  end

  it "is safe to repeat" do
    2.times { setup.call("api.worktree-x") }

    expect(File.read(File.join(repo, ".git", "info", "exclude")).lines.map(&:chomp).count("/tmp/workspace-notes/feature-x/")).to eq(1)
  end

  it "keeps the written path when the directory can't be made, and says so as a warning" do
    File.write("#{repo}/tmp", "a file where the directory should go")

    result = setup.call("api.worktree-x")

    expect(stored("api.worktree-x")).to eq("#{repo}/tmp/workspace-notes/feature-x")
    expect(result["dir"]).to eq("#{repo}/tmp/workspace-notes/feature-x")
    expect(result["warnings"].size).to eq(1)
    expect(result["warnings"].first).to start_with("Warning: could not finish setting up the notes directory for api.worktree-x").and include("#{repo}/tmp/workspace-notes/feature-x")
  end

  it "warns and writes nothing when the path can't be worked out" do
    write_config("api", "notes:\n  default_dir: /notes/{branch}\n")
    sh("checkout", "-q", "--detach", dir: linked)

    result = setup.call("api.worktree-x")

    expect(result["dir"]).to be_nil
    expect(result["warnings"].first).to include("api.worktree-x").and include("detached HEAD")
    expect(stored("api.worktree-x")).to be_nil
  end

  it "warns and leaves a config file it can't parse as it is" do
    write_config("api.worktree-x", "notes: [unclosed\n")

    result = setup.call("api.worktree-x")

    expect(result["dir"]).to be_nil
    expect(result["warnings"].size).to eq(1)
    expect(File.read(settings.project_config_path("api.worktree-x"))).to eq("notes: [unclosed\n")
  end

  it "warns for a workspace with no checkout" do
    result = setup.call("nope")

    expect(result["dir"]).to be_nil
    expect(result["warnings"].first).to include("nope")
  end
end
