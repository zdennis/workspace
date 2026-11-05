require "spec_helper"
require "tmpdir"
require "stringio"

RSpec.describe Workspace::StartFileCopies do
  around do |example|
    Dir.mktmpdir("start-file-copies") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:main) { File.join(@dir, "main") }
  let(:worktree) { File.join(@dir, "worktree") }
  let(:project_settings) { instance_double(Workspace::ProjectSettings, load_global: global) }
  let(:global) { {} }
  let(:resolver) { Workspace::ConfigResolver.new(project_settings: project_settings) }
  subject(:copies) { described_class.new(config_resolver: resolver) }

  def project(value)
    allow(project_settings).to receive(:load).with("app").and_return(value)
  end

  def set_key(value, layer: :project)
    case layer
    when :project then project("start" => {"copy_files" => value})
    when :global then allow(project_settings).to receive(:load_global).and_return("start" => {"copy_files" => value})
    end
  end

  def call
    copies.call(project_name: "app", source_root: main, worktree_root: worktree)
  end

  before do
    FileUtils.mkdir_p([main, worktree])
  end

  it "copies nothing when the key is unset, with no reads of the project file's value" do
    project({})

    expect(call).to eq({"copied" => [], "skipped" => [], "warnings" => []})
    expect(Dir.children(worktree)).to eq([])
  end

  it "copies nothing when no config resolver was wired" do
    File.write(File.join(main, ".env"), "SECRET=1")
    set_key(".env")

    bare = described_class.new.call(project_name: "app", source_root: main, worktree_root: worktree)

    expect(bare).to eq({"copied" => [], "skipped" => [], "warnings" => []})
    expect(Dir.children(worktree)).to eq([])
  end

  it "warns and copies nothing when the config file cannot be read" do
    allow(project_settings).to receive(:load).with("app").and_raise(Workspace::ConfigParseError.new("/tmp/app.yml", "bad YAML"))

    result = call
    expect(result["copied"]).to eq([])
    expect(result["warnings"]).to contain_exactly(/could not read start\.copy_files: Cannot parse \/tmp\/app\.yml: bad YAML/)
  end

  it "copies each listed file at the same relative path, creating intermediate directories and keeping the mode" do
    File.write(File.join(main, ".env"), "SECRET=1")
    File.chmod(0o600, File.join(main, ".env"))
    FileUtils.mkdir_p(File.join(main, "config"))
    File.write(File.join(main, "config", "database.yml"), "pool: 5")
    File.chmod(0o741, File.join(main, "config", "database.yml"))
    set_key(".env, config/database.yml")

    expect(call).to eq({"copied" => %w[.env config/database.yml], "skipped" => [], "warnings" => []})
    expect(File.read(File.join(worktree, ".env"))).to eq("SECRET=1")
    expect(File.stat(File.join(worktree, ".env")).mode & 0o7777).to eq(0o600)
    expect(File.read(File.join(worktree, "config", "database.yml"))).to eq("pool: 5")
    expect(File.stat(File.join(worktree, "config", "database.yml")).mode & 0o7777).to eq(0o741)
  end

  it "skips a destination that already exists, byte for byte untouched" do
    File.write(File.join(main, ".env"), "NEW")
    File.write(File.join(worktree, ".env"), "BRANCH LOCAL EDIT")
    set_key(".env")

    expect(call).to eq({"copied" => [], "skipped" => [".env"], "warnings" => []})
    expect(File.read(File.join(worktree, ".env"))).to eq("BRANCH LOCAL EDIT")
  end

  it "skips a dangling symlink at the destination without writing through it" do
    File.write(File.join(main, ".env"), "NEW")
    File.symlink(File.join(@dir, "nowhere"), File.join(worktree, ".env"))
    set_key(".env")

    expect(call).to eq({"copied" => [], "skipped" => [".env"], "warnings" => []})
    expect(File.symlink?(File.join(worktree, ".env"))).to be(true)
    expect(File.exist?(File.join(@dir, "nowhere"))).to be(false)
  end

  it "refuses a symlinked directory in the worktree that would point the write outside it" do
    outside = File.join(@dir, "outside")
    FileUtils.mkdir_p(outside)
    FileUtils.mkdir_p(File.join(main, "config"))
    File.write(File.join(main, "config", "database.yml"), "pool: 5")
    File.symlink(outside, File.join(worktree, "config"))
    set_key("config/database.yml")

    result = call
    expect(result["copied"]).to eq([])
    expect(result["warnings"]).to contain_exactly(/would not land inside the worktree/)
    expect(Dir.children(outside)).to eq([])
  end

  it "refuses a dangling symlinked directory in the worktree rather than stepping past it" do
    FileUtils.mkdir_p(File.join(main, "config"))
    File.write(File.join(main, "config", "database.yml"), "pool: 5")
    File.symlink(File.join(@dir, "nowhere", "config"), File.join(worktree, "config"))
    set_key("config/database.yml")

    result = call
    expect(result["copied"]).to eq([])
    expect(result["warnings"]).to contain_exactly(/would not land inside the worktree/)
    expect(File.exist?(File.join(@dir, "nowhere"))).to be(false)
  end

  it "follows a symlinked directory in the main checkout but never a symlinked file" do
    shared = File.join(@dir, "shared")
    FileUtils.mkdir_p(shared)
    File.write(File.join(shared, "database.yml"), "pool: 5")
    File.symlink(shared, File.join(main, "config"))
    File.symlink(File.join(main, "real.env"), File.join(main, ".env"))
    File.write(File.join(main, "real.env"), "REAL")
    set_key("config/database.yml, .env")

    result = call
    expect(result["copied"]).to eq(["config/database.yml"])
    expect(File.read(File.join(worktree, "config", "database.yml"))).to eq("pool: 5")
    expect(result["warnings"]).to contain_exactly(/\.env in the main checkout is not a regular file/)
    expect(File.exist?(File.join(worktree, ".env"))).to be(false)
  end

  it "warns for a source that is missing or a directory" do
    FileUtils.mkdir_p(File.join(main, "config"))
    set_key("missing.env, config")

    result = call
    expect(result["copied"]).to eq([])
    expect(result["warnings"]).to contain_exactly(/missing\.env is missing from the main checkout/, /config in the main checkout is not a regular file/)
  end

  it "warns and copies nothing for a hand-edited value the parser refuses" do
    File.write(File.join(main, ".env"), "NEW")
    ["/etc/passwd", "../outside.env", "*.env"].each do |bad|
      set_key(bad)
      expect(call["copied"]).to eq([])
      expect(call["warnings"]).to contain_exactly(/start\.copy_files is not valid/)
      expect(Dir.children(worktree)).to eq([])
    end
  end

  it "treats a file that appears between the check and the write as skipped, never clobbered" do
    File.write(File.join(main, ".env"), "NEW")
    set_key(".env")
    allow(copies).to receive(:dest_exists?).and_return(false)
    File.write(File.join(worktree, ".env"), "APPEARED")

    expect(call).to eq({"copied" => [], "skipped" => [".env"], "warnings" => []})
    expect(File.read(File.join(worktree, ".env"))).to eq("APPEARED")
  end

  it "deletes a destination a failed write left midway, so a later start does not skip a truncated file" do
    File.write(File.join(main, ".env"), "SECRET=1")
    set_key(".env")
    allow(IO).to receive(:copy_stream).and_raise(IOError, "disk full")

    result = call
    expect(result["copied"]).to eq([])
    expect(result["warnings"]).to contain_exactly(/could not copy \.env/)
    expect(File.exist?(File.join(worktree, ".env"))).to be(false)
  end

  it "honors a global-layer value, and never reads a worktree layer" do
    project({})
    File.write(File.join(main, ".env"), "SECRET=1")
    set_key(".env", layer: :global)
    allow(project_settings).to receive(:load).with("app.worktree-x").and_return("start" => {"copy_files" => ".env,other"})

    expect(call["copied"]).to eq([".env"])
    expect(project_settings).not_to have_received(:load).with("app.worktree-x")
  end
end
