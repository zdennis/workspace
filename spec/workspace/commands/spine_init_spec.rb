require "spec_helper"
require "tmpdir"
require "stringio"
require "json"

RSpec.describe Workspace::Commands::SpineInit do
  around do |example|
    Dir.mktmpdir("spine-init") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:notes) { instance_double(Workspace::Commands::Notes) }
  let(:project_config) { instance_double(Workspace::ProjectConfig) }
  let(:lineage) { instance_double(Workspace::WorkspaceLineage) }
  let(:git) { instance_double(Workspace::Git, worktree_branch: "zd/fix-oauth") }
  let(:task_store) { instance_double(Workspace::TaskStore, active_for: {"title" => "Fix OAuth refresh (ACME-412)"}) }
  let(:config) do
    instance_double(Workspace::Config, library_dir: File.join(@dir, "library"),
      builtin_library_dir: File.expand_path("../../../lib/library", __dir__))
  end
  let(:library) { Workspace::Library.new(config: config, lineage: lineage, project_config: project_config) }
  let(:checkout) { File.join(@dir, "checkout") }
  let(:notes_dir) { File.join(@dir, "notes") }
  let(:spine_dir) { File.join(notes_dir, "spine") }
  subject(:command) { described_class.new(notes: notes, library: library, project_config: project_config, git: git, task_store: task_store, output: output) }

  before do
    FileUtils.mkdir_p(checkout)
    allow(project_config).to receive(:project_root_for) { |name| (name == "nope") ? nil : checkout }
    allow(project_config).to receive(:exists?).and_return(true)
    allow(lineage).to receive(:resolve).and_return(Workspace::WorkspaceLineage::Lineage.new(name: "api"))
    allow(notes).to receive(:info) do |name:, create: false|
      FileUtils.mkdir_p(notes_dir) if create
      {"workspace" => name, "dir" => notes_dir}
    end
  end

  def global_template(name, files)
    files.each do |rel, text|
      path = File.join(@dir, "library/global/spine", name, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
  end

  def document
    JSON.parse(output.string)
  end

  it "writes the built-in default into a worktree's notes directory, creating it, and says so in one document" do
    command.call(name: "api.worktree-fix", json: true)

    expect(output.string.lines.size).to eq(1)
    expect(document).to include("schema_version" => 1, "ok" => true, "workspace" => "api.worktree-fix", "outcome" => "created",
      "template" => {"name" => "default", "scope" => "builtin"}, "dir" => spine_dir)
    expect(document["files"]).to eq(%w[10-research.md 20-plan.md 30-implement.md 40-verify.md 50-review.md 60-ship.md README.md goal.md])
    expect(Dir.children(spine_dir).sort).to eq(document["files"].sort)
    expect(Dir.children(notes_dir)).to eq(["spine"])
  end

  it "gives a main checkout the default without its ship stage" do
    command.call(name: "api", json: true)

    expect(document["files"]).not_to include("60-ship.md")
    expect(document["files"]).to include("50-review.md", "goal.md", "README.md")
    expect(File.exist?(File.join(spine_dir, "60-ship.md"))).to be(false)
  end

  it "fills the workspace, branch and task title and copies the rest as it is" do
    command.call(name: "api.worktree-fix", json: true)

    goal = File.read(File.join(spine_dir, "goal.md"))
    expect(goal).to include("title: Fix OAuth refresh (ACME-412)", "branch zd/fix-oauth", "api.worktree-fix")
    expect(File.read(File.join(spine_dir, "README.md"))).to include("# Plan spine for api.worktree-fix")
    expect(Dir.glob(File.join(spine_dir, "*")).map { |f| File.read(f) }.join).not_to match(/\{\{(WORKSPACE|BRANCH|TITLE)\}\}/)
  end

  it "falls back from the task title to the branch, then the name, on one line" do
    allow(task_store).to receive(:active_for).and_return({"title" => "  two\nlines  "})
    command.call(name: "api.worktree-fix", json: true)
    expect(File.read(File.join(spine_dir, "goal.md"))).to include("title: two lines\n")

    FileUtils.rm_rf(spine_dir)
    allow(task_store).to receive(:active_for).and_return(nil)
    command.call(name: "api.worktree-fix", json: true)
    expect(File.read(File.join(spine_dir, "goal.md"))).to include("title: zd/fix-oauth\n")

    FileUtils.rm_rf(spine_dir)
    allow(git).to receive(:worktree_branch).and_return(nil)
    command.call(name: "api.worktree-fix", json: true)
    expect(File.read(File.join(spine_dir, "goal.md"))).to include("title: api.worktree-fix\n")
  end

  it "reads back with spine show: zero warnings, six stages for a worktree, five for a main checkout" do
    command.call(name: "api.worktree-fix", json: true)
    tree = Workspace::SpineTree.read(notes_dir)
    stages = []
    tree.each_stage { |stage| stages << stage }

    expect(stages.map(&:id)).to eq(%w[research plan implement verify review ship])
    expect(stages.map(&:status).uniq).to eq(["not_started"])
    expect(stages.map(&:kind)).to eq(%w[research plan implement verify review ship])
    expect(stages.flat_map(&:all_warnings)).to eq([])
    expect(tree.warnings).to eq([])
    expect(tree.goal.value("title")).to eq("Fix OAuth refresh (ACME-412)")
    expect(stages.map { |s| s.file.done_when["total"] }).to all(be > 0)
    expect(stages.find { |s| s.id == "ship" }.gates).to eq(%w[pushed pr ci merged])

    FileUtils.rm_rf(notes_dir)
    command.call(name: "api", json: true)
    main = Workspace::SpineTree.read(notes_dir)
    ids = []
    main.each_stage { |stage| ids << stage.id }
    expect(ids).to eq(%w[research plan implement verify review])
    expect(main.warnings).to eq([])
  end

  it "never overwrites: an existing spine/ answers exists and is left as it was" do
    FileUtils.mkdir_p(spine_dir)
    File.write(File.join(spine_dir, "mine.md"), "mine\n")

    command.call(name: "api", json: true)

    expect(document).to include("outcome" => "exists", "files" => [], "dir" => spine_dir)
    expect(Dir.children(spine_dir)).to eq(["mine.md"])
    expect(File.read(File.join(spine_dir, "mine.md"))).to eq("mine\n")
  end

  it "writes nothing on a dry run, not even the notes directory, and lists the files" do
    command.call(name: "api.worktree-fix", dry_run: true, json: true)

    expect(document).to include("outcome" => "would_create", "dir" => spine_dir)
    expect(document["files"].size).to eq(8)
    expect(File.exist?(notes_dir)).to be(false)
    expect(notes).not_to have_received(:info).with(name: "api.worktree-fix", create: true)
  end

  it "answers exists on a dry run too" do
    FileUtils.mkdir_p(spine_dir)
    command.call(name: "api", dry_run: true, json: true)
    expect(document["outcome"]).to eq("exists")
  end

  it "refuses a spine that is a link, writing nothing through it" do
    target = File.join(@dir, "elsewhere")
    FileUtils.mkdir_p(target)
    FileUtils.mkdir_p(notes_dir)
    File.symlink(target, spine_dir)

    expect { command.call(name: "api", json: true) }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("spine_unwritable")
      expect(e.details).to eq("path" => spine_dir)
    }
    expect(Dir.children(target)).to eq([])
  end

  it "refuses a dangling link too" do
    FileUtils.mkdir_p(notes_dir)
    File.symlink(File.join(@dir, "gone"), spine_dir)

    expect { command.call(name: "api", json: true) }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("spine_unwritable") }
  end

  it "reports a notes directory that can't be made as spine_unwritable and leaves nothing behind" do
    allow(notes).to receive(:info).with(name: "api", create: true).and_raise(Workspace::Error.new("no", code: "notes_dir_unwritable"))
    allow(notes).to receive(:info).with(name: "api").and_return({"dir" => notes_dir})

    expect { command.call(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("spine_unwritable") }
    expect(File.exist?(notes_dir)).to be(false)
  end

  it "lets the notes errors through" do
    allow(notes).to receive(:info).and_raise(Workspace::Error.new("no branch", code: "notes_dir_unresolved"))
    expect { command.call(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("notes_dir_unresolved") }
  end

  it "refuses an unknown workspace before anything else" do
    expect { command.call(name: "nope") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_workspace")
      expect(e.details).to eq("name" => "nope")
    }
  end

  it "refuses an unknown template, or a badly named one, writing nothing" do
    expect { command.call(name: "api", template: "nope") }.to raise_error(Workspace::Error) { |e|
      expect(e.code).to eq("unknown_template")
      expect(e.details["template"]).to eq("nope")
      expect(e.details["scopes"]).to include("global", "builtin")
    }
    expect { command.call(name: "api", template: "../etc") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_template") }
    expect(File.exist?(notes_dir)).to be(false)
  end

  it "uses a global template over the built-in one of the same name, and any of its files" do
    global_template("default", "10-mine.md" => "---\nspine: 1\n---\nfor {{WORKSPACE}}\n", "sub/20-x.md" => "x\n")

    command.call(name: "api.worktree-fix", json: true)

    expect(document["template"]).to eq("name" => "default", "scope" => "global")
    expect(document["files"]).to eq(%w[10-mine.md sub/20-x.md])
    expect(File.read(File.join(spine_dir, "10-mine.md"))).to include("for api.worktree-fix")
  end

  it "omits a custom template's ship stage in a main checkout, file or folder" do
    global_template("team", "10-research.md" => "r\n", "60-ship.md" => "s\n", "60-ship/10-pr.md" => "p\n", "65-shipping.md" => "keep\n")

    command.call(name: "api", template: "team", json: true)

    expect(document["files"]).to eq(%w[10-research.md 65-shipping.md])
  end

  it "reads a linked template through the link and does not copy links inside it or dot files" do
    source = File.join(@dir, "vault")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "10-research.md"), "linked\n")
    File.write(File.join(source, ".hidden.md"), "h\n")
    File.write(File.join(@dir, "secret.txt"), "s")
    File.symlink(File.join(@dir, "secret.txt"), File.join(source, "20-secret.md"))
    FileUtils.mkdir_p(File.dirname(File.join(@dir, "library/global/spine")))
    FileUtils.mkdir_p(File.join(@dir, "library/global/spine"))
    File.symlink(source, File.join(@dir, "library/global/spine/vault"))

    command.call(name: "api", template: "vault", json: true)

    expect(document["files"]).to eq(["10-research.md"])
    expect(File.read(File.join(spine_dir, "10-research.md"))).to eq("linked\n")
  end

  it "copies a file that is not UTF-8 as it is" do
    global_template("bin", {})
    path = File.join(@dir, "library/global/spine/bin/10-a.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "\xFF{{TITLE}}".b)

    command.call(name: "api", template: "bin", json: true)

    expect(File.binread(File.join(spine_dir, "10-a.md"))).to eq("\xFF{{TITLE}}".b)
  end

  it "leaves no temporary folder behind and answers exists when another writer wins the rename" do
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      raise Errno::ENOTEMPTY, to if to == spine_dir
      original.call(from, to)
    end

    command.call(name: "api", json: true)

    expect(document["outcome"]).to eq("exists")
    expect(Dir.children(notes_dir)).to eq([])
  end

  it "reports a write that fails as spine_unwritable without leaving a half-written spine" do
    allow(File).to receive(:binwrite).and_raise(Errno::ENOSPC)

    expect { command.call(name: "api") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("spine_unwritable") }
    expect(Dir.children(notes_dir)).to eq([])
  end

  it "prints a short summary without --json" do
    command.call(name: "api.worktree-fix")

    expect(output.string).to start_with("api.worktree-fix: wrote 8 files to #{spine_dir} from template default.")
    expect(output.string).to include("  10-research.md")
  end
end
