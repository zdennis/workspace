require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "workspace workflow install through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-install-cli") do |dir|
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
  let(:gh_calls) { [] }
  let(:runner) do
    ->(argv, chdir:, timeout:) do
      gh_calls << argv
      if argv.include?("-H")
        ["title: Remote\nsteps:\n  a:\n    prompt: P\n", "", true]
      else
        [JSON.generate([{"type" => "file", "name" => "remote.yml", "path" => "wf/remote.yml", "sha" => "r1"}]), "", true]
      end
    end
  end
  let(:source_dir) { File.join(@home, "src") }

  def cli
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, workflow_source_runner: runner)
  end

  def run_cli(*args)
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    exits.clear
    cli.run(args)
  rescue SystemExit => e
    exits << e.status
  end

  def set_sources(*entries)
    run_cli("config", "set", "workflows.sources", entries.join(","), "--scope", "global")
    expect(exits).to eq([])
  end

  def write(dir, id, yaml)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), yaml)
  end

  let(:yaml) { "title: T\nsteps:\n  a:\n    prompt: P\n" }

  it "lists the verb in the missing-subcommand message and the help" do
    run_cli("workflow")
    expect(err.string + out.string).to include("install")
  end

  it "installs a local source and a stubbed GitHub source, in list order" do
    write(source_dir, "ship", yaml)
    set_sources(source_dir, "acme/widgets/wf")

    run_cli("workflow", "install")

    expect(exits).to eq([])
    expect(out.string).to include("source:1 #{source_dir}: local")
    expect(out.string).to include("source:2 acme/widgets/wf: installed")
    expect(out.string).to include("new: remote (source:2)")
    expect(gh_calls.size).to eq(2)
    run_cli("workflow", "show", "remote", "--json")
    expect(JSON.parse(out.string)["workflow"]["source"]).to eq("source:2")
  end

  it "re-runs as an update with no changes" do
    set_sources("acme/widgets/wf")
    run_cli("workflow", "install")

    run_cli("workflow", "install", "--json")

    doc = JSON.parse(out.string)
    expect(doc).to include("ok" => true)
    expect(doc["results"].first).to include("outcome" => "unchanged")
    expect(doc["results"].first["sources"].first).to include("installed" => [], "changed" => [], "removed" => [])
  end

  it "answers one document under --json, with the sources, problems and warnings" do
    write(source_dir, "rpiv", yaml)
    write(source_dir, "bad", "steps: nope\n")
    set_sources(source_dir)

    run_cli("workflow", "install", "--json")

    expect(exits).to eq([1])
    row = JSON.parse(out.string)["results"].first
    expect(row).to include("outcome" => "failed")
    expect(row["sources"].first).to include("index" => 1, "source" => source_dir, "outcome" => "refused")
    expect(row["sources"].first["problems"].first.keys).to eq(%w[file code message])
    expect(out.string.lines.size).to eq(1)
  end

  it "reports a shadowed preset in the document" do
    write(source_dir, "rpiv", yaml)
    set_sources(source_dir)

    run_cli("workflow", "install", "--json")

    expect(JSON.parse(out.string)["results"].first["warnings"].map { |w| w["code"] }).to eq(["shadowed"])
  end

  it "installs only the Nth source with --source N" do
    write(source_dir, "ship", yaml)
    set_sources(source_dir, "acme/widgets/wf")

    run_cli("workflow", "install", "--source", "2")

    expect(out.string).not_to include("source:1")
    expect(out.string).to include("source:2 acme/widgets/wf")
  end

  it "refuses a position outside the list and a non-number" do
    set_sources(source_dir)
    write(source_dir, "ship", yaml)

    run_cli("workflow", "install", "--source", "5")
    expect(exits).to eq([2]).or eq([1])
    expect(err.string).to include("--source 5 is not a position")

    run_cli("workflow", "install", "--source", "x")
    expect(err.string).to include("not a position")

    run_cli("workflow", "install", "--source")
    expect(err.string).to include("needs N")

    run_cli("workflow", "install", "2")
    expect(err.string).to include("takes no argument")
  end

  it "writes nothing under the user's workflows directory" do
    set_sources("acme/widgets/wf")

    run_cli("workflow", "install")

    expect(Dir.exist?(File.join(@home, ".config", "workspace", "workflows"))).to be(false)
  end

  it "says gh is missing as the registered code" do
    set_sources("acme/widgets/wf")
    missing = ->(argv, chdir:, timeout:) { raise Errno::ENOENT }
    begin
      Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}, workflow_source_runner: missing).run(["workflow", "install", "--json"])
    rescue SystemExit => e
      exits << e.status
    end

    expect(JSON.parse(out.string.lines.last)["code"]).to eq("workflow_source_gh_missing")
    expect(exits).to eq([1])
  end
end
