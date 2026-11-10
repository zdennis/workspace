require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

RSpec.describe "workspace workflow uninstall through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-uninstall-cli") do |dir|
      saved = ENV.to_h
      begin
        @home = File.realpath(dir)
        ENV.replace("HOME" => @home, "PATH" => File.dirname(RbConfig.ruby), "XDG_STATE_HOME" => File.join(@home, "state"))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:exits) { [] }
  let(:runner) do
    lambda do |argv, chdir:, timeout:|
      if argv.include?("-H")
        ["title: Remote\nsteps:\n  a:\n    prompt: P\n", "", true]
      else
        [JSON.generate([{"type" => "file", "name" => "remote.yml", "path" => "wf/remote.yml", "sha" => "r1"}]), "", true]
      end
    end
  end
  let(:source_dir) { File.join(@home, "src") }
  let(:cache_root) { File.join(@home, "state", "workspace", ".workflows-sources") }
  let(:yaml) { "title: T\nsteps:\n  a:\n    prompt: P\n" }

  def cli(input = StringIO.new)
    Workspace.build_cli(output: out, error_output: err, input: input, env: {}, workflow_source_runner: runner)
  end

  def run_cli(*args, input: nil)
    out.truncate(0)
    out.rewind
    err.truncate(0)
    exits.clear
    input ? cli(input).run(args) : cli.run(args)
  rescue SystemExit => e
    exits << e.status
  end

  def write(dir, id, text)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), text)
  end

  def set_sources(*entries)
    run_cli("config", "set", "workflows.sources", entries.join(","), "--scope", "global")
    expect(exits).to eq([])
  end

  def install_sources(*entries)
    write(source_dir, "ship", yaml)
    set_sources(*entries)
    run_cli("workflow", "install")
    expect(exits).to eq([])
  end

  def cached_dirs
    Dir.exist?(cache_root) ? Dir.children(cache_root).sort : []
  end

  it "removes every GitHub cache on --yes and leaves a local source alone" do
    install_sources(source_dir, "acme/widgets/wf")
    expect(cached_dirs.size).to eq(1)

    run_cli("workflow", "uninstall", "--yes")

    expect(exits).to eq([])
    expect(cached_dirs).to eq([])
    expect(out.string).to include("Removed 1 of 1 source caches")
    expect(out.string).to include("source:1 #{source_dir}: read in place; nothing to remove")
    expect(out.string).to include("workspace config unset workflows.sources")
  end

  it "removes nothing under --dry-run" do
    install_sources(source_dir, "acme/widgets/wf")

    run_cli("workflow", "uninstall", "--dry-run")

    expect(exits).to eq([])
    expect(cached_dirs.size).to eq(1)
    expect(out.string).to include("Would remove 1 of 1 source caches")
  end

  it "removes nothing when the prompt is declined" do
    install_sources("acme/widgets/wf")

    run_cli("workflow", "uninstall", input: StringIO.new("n\n"))

    expect(exits).to eq([])
    expect(cached_dirs.size).to eq(1)
    expect(out.string).to include("Cancelled.")
  end

  it "answers one document under --json, and cancelled for a declined prompt" do
    install_sources("acme/widgets/wf")

    run_cli("workflow", "uninstall", "--yes", "--json")

    doc = JSON.parse(out.string)
    expect(doc).to include("ok" => true)
    expect(doc["results"].first).to include("outcome" => "uninstalled", "reason" => nil)
    expect(doc["results"].first["sources"].first).to include("outcome" => "removed", "kind" => "github")
    expect(cached_dirs).to eq([])

    install_sources("acme/widgets/wf")
    run_cli("workflow", "uninstall", "--json", input: StringIO.new("n\n"))

    cancelled = JSON.parse(out.string)
    expect(cancelled).to include("ok" => true, "status" => "cancelled")
  end

  it "says there is nothing to remove with no sources set" do
    run_cli("workflow", "uninstall", "--yes", "--json")

    row = JSON.parse(out.string)["results"].first
    expect(row).to include("outcome" => "unchanged")
    expect(row["message"]).to include("No workflows.sources are set")
  end

  it "fails with the reason naming the unreadable list" do
    config = File.join(@home, ".config", "workspace", "config.yml")
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, "workflows:\n  sources: 5\n")

    run_cli("workflow", "uninstall", "--yes", "--json")

    expect(exits).to eq([1])
    row = JSON.parse(out.string)["results"].first
    expect(row).to include("outcome" => "failed", "reason" => "workflows_sources_unreadable")
    expect(row["message"]).to include("can't be read")
  end

  it "lists the verb in the missing-subcommand message and the help" do
    run_cli("workflow")
    expect(err.string + out.string).to include("uninstall")
  end
end
