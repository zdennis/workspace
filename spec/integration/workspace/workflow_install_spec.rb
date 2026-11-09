require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "workflow install over a real cache directory" do
  around do |example|
    Dir.mktmpdir("wf-install") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:global_dir) { File.join(@dir, "global") }
  let(:builtin_dir) { File.join(@dir, "builtin") }
  let(:state) { File.join(@dir, "state") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:entries) { [] }
  let(:responses) { {} }
  let(:calls) { [] }
  let(:runner) do
    ->(argv, chdir:, timeout:) do
      calls << argv
      next [JSON.generate(responses.fetch(:listing)), "", true] unless argv.include?("-H")
      [responses.fetch(:files).fetch(argv.last.split("/").last.sub(/\?.*/, "")), "", true]
    end
  end
  let(:config) do
    instance_double(Workspace::Config, workflows_dir: global_dir, builtin_workflows_dir: builtin_dir, workspace_projects_dir: File.join(@dir, "projects")).tap do |double|
      allow(double).to receive(:project_workflows_dir).and_return(nil)
    end
  end
  let(:resolver) { double(view: double(raw: entries.join(","))) }
  let(:source_dirs) { Workspace::WorkflowSourceDirs.new(config_resolver: resolver, state_dir: state, home: @dir) }
  let(:installer) do
    Workspace::WorkflowSourceInstaller.new(config: config, source_dirs: source_dirs, state_dir: state,
      fetcher: Workspace::WorkflowSourceFetcher.new(state_dir: state, runner: runner, home: @dir, clock: -> { Time.utc(2026, 11, 9) }))
  end
  let(:command) do
    Workspace::Commands::Workflow.new(lint: double, catalog: double, engine: double, status: double, store: double, panes: double, files: double,
      run_files: double, tmux: double, process_tree: double, lock_holder: double, source_installer: installer, output: out, error_output: err)
  end

  def step_yaml(extra = "") = "title: T\n#{extra}steps:\n  a:\n    prompt: P\n"

  def write(dir, id, yaml)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), yaml)
  end

  def local(name)
    File.join(@dir, name)
  end

  before { write(builtin_dir, "rpiv", step_yaml) }

  it "refuses to run without an installer wired" do
    bare = Workspace::Commands::Workflow.new(lint: double, catalog: double, engine: double, status: double, store: double, panes: double, files: double,
      run_files: double, tmux: double, process_tree: double, lock_holder: double)

    expect { bare.install }.to raise_error(Workspace::Error, /not available/)
  end

  it "says so when no source is listed" do
    row = command.install

    expect(row).to include("outcome" => "unchanged", "sources" => [])
    expect(out.string).to include("No workflows.sources are set")
  end

  describe "a local source" do
    let(:entries) { [local("src")] }

    it "checks the files in place, copies nothing and lists the ids" do
      write(local("src"), "ship", step_yaml)

      row = command.install

      expect(row["outcome"]).to eq("unchanged")
      expect(row["sources"].first).to include("kind" => "local", "outcome" => "local", "workflows" => ["ship"], "path" => local("src"))
      expect(File.exist?(state)).to be(false)
      expect(Dir.exist?(global_dir)).to be(false)
    end

    it "accepts a workflow that extends a preset" do
      write(local("src"), "ship", step_yaml("extends: rpiv\n").sub(/steps:.*/m, ""))

      expect(command.install["outcome"]).to eq("unchanged")
    end

    it "resolves a sibling extend within the one source" do
      write(local("src"), "base", step_yaml)
      write(local("src"), "derived", "extends: base\ntitle: D\n")

      row = command.install

      expect(row["sources"].first["problems"]).to eq([])
      expect(row["sources"].first["workflows"]).to eq(%w[base derived])
    end

    it "resolves a source rpiv that extends rpiv to the preset and does not warn" do
      write(local("src"), "rpiv", "extends: rpiv\ntitle: Mine\n")

      row = command.install

      expect(row["sources"].first["problems"]).to eq([])
      expect(row["warnings"]).to eq([])
    end

    it "warns when a source file hides a preset of its id" do
      write(local("src"), "rpiv", step_yaml)

      row = command.install

      expect(row["warnings"].map { |w| w["code"] }).to eq(["shadowed"])
      expect(row["warnings"].first["message"]).to include("builtin")
      expect(err.string).to include("warning:")
    end

    it "refuses a source with one invalid file and reports the problems" do
      write(local("src"), "good", step_yaml)
      write(local("src"), "bad", "title: T\nsteps: nope\n")

      row = command.install

      expect(row["outcome"]).to eq("failed")
      source = row["sources"].first
      expect(source["outcome"]).to eq("refused")
      expect(source["problems"].map { |p| p["file"] }.uniq).to eq(["bad.yml"])
      expect(out.string).to include("bad.yml")
    end

    it "refuses an extends that finds nothing" do
      write(local("src"), "ship", "extends: missing\ntitle: T\n")

      expect(command.install["sources"].first["problems"].join).to include("extends missing")
    end

    it "refuses a definition that sets prompt_file" do
      write(local("src"), "ship", "title: T\nsteps:\n  a:\n    prompt_file: p.md\n")

      problems = command.install["sources"].first["problems"]

      expect(problems.map { |p| p["code"] }).to eq(["workflow_source_prompt_file"])
    end
  end

  describe "a GitHub source" do
    let(:entries) { ["acme/widgets/wf"] }
    let(:cache) { Workspace::WorkflowSourceDirs.cache_dir(state, "acme/widgets/wf") }
    let(:responses) do
      {listing: [{"type" => "file", "name" => "ship.yml", "path" => "wf/ship.yml", "sha" => "s1"},
        {"type" => "file", "name" => "extra.yml", "path" => "wf/extra.yml", "sha" => "x1"}],
       files: {"ship.yml" => step_yaml, "extra.yml" => step_yaml}}
    end

    it "caches the files with a manifest and reports the ids as new" do
      row = command.install

      expect(row["outcome"]).to eq("installed")
      expect(row["sources"].first).to include("kind" => "github", "installed" => %w[extra ship], "changed" => [], "removed" => [], "path" => cache)
      expect(Dir.children(cache).sort).to eq(%w[extra.yml manifest.json ship.yml])
      expect(Dir.children(File.dirname(cache))).to eq([File.basename(cache)])
      expect(out.string).to include("new: ship (source:1)")
      expect(Dir.exist?(global_dir)).to be(false)
    end

    it "reports no change on an identical re-run" do
      command.install

      row = command.install

      expect(row["outcome"]).to eq("unchanged")
      expect(row["sources"].first).to include("outcome" => "unchanged", "installed" => [], "changed" => [], "removed" => [])
    end

    it "reports changed and removed ids against the previous manifest" do
      command.install
      responses[:listing] = [{"type" => "file", "name" => "ship.yml", "path" => "wf/ship.yml", "sha" => "s2"},
        {"type" => "file", "name" => "new.yml", "path" => "wf/new.yml", "sha" => "n1"}]
      responses[:files] = {"ship.yml" => step_yaml, "new.yml" => step_yaml}

      source = command.install["sources"].first

      expect(source).to include("installed" => ["new"], "changed" => ["ship"], "removed" => ["extra"])
      expect(Dir.children(cache).sort).to eq(%w[manifest.json new.yml ship.yml])
    end

    it "keeps the previous cache when the new version has an invalid file" do
      command.install
      before = File.read(File.join(cache, "ship.yml"))
      responses[:listing] = [{"type" => "file", "name" => "ship.yml", "path" => "wf/ship.yml", "sha" => "s2"}]
      responses[:files] = {"ship.yml" => "title: T\nsteps: nope\n"}

      row = command.install

      expect(row["sources"].first["outcome"]).to eq("refused")
      expect(File.read(File.join(cache, "ship.yml"))).to eq(before)
      expect(Dir.children(cache).sort).to eq(%w[extra.yml manifest.json ship.yml])
      expect(Dir.children(File.dirname(cache))).to eq([File.basename(cache)])
    end

    it "leaves nothing behind when the first install is refused" do
      responses[:files] = {"ship.yml" => "steps: nope\n", "extra.yml" => step_yaml}

      command.install

      expect(Dir.exist?(cache)).to be(false)
      expect(Dir.children(File.dirname(cache))).to eq([])
    end
  end

  describe "--source N" do
    let(:entries) { [local("one"), local("two")] }

    before do
      write(local("one"), "a", step_yaml)
      write(local("two"), "b", step_yaml)
    end

    it "installs only that source" do
      row = command.install(source: 2)

      expect(row["sources"].map { |s| [s["index"], s["workflows"]] }).to eq([[2, ["b"]]])
    end

    it "refuses a position outside the list" do
      expect { command.install(source: 3) }.to raise_error(Workspace::UsageError, /--source 3 is not a position/)
      expect { command.install(source: 0) }.to raise_error(Workspace::UsageError)
    end

    it "validates a later source against the sources that stay as they are" do
      write(local("one"), "base", step_yaml)
      write(local("two"), "derived", "extends: base\n")

      expect(command.install(source: 2)["sources"].first["problems"]).to eq([])
    end
  end
end
