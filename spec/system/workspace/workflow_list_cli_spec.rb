require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe "workspace workflow list through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-list-cli") do |dir|
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

  def cli
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {})
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

  def write(dir, id, yaml)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{id}.yml"), yaml)
  end

  let(:source_dir) { File.join(@home, "src") }
  let(:yaml) { "title: Ship\ndescription: One feature end to end.\nsteps:\n  a:\n    prompt: P\n" }

  it "prints a table of id, source and description over the presets and a source" do
    write(source_dir, "ship", yaml)
    run_cli("config", "set", "workflows.sources", source_dir, "--scope", "global")
    expect(exits).to eq([])

    run_cli("workflow", "list")

    expect(exits).to eq([])
    expect(out.string).to include("ID")
    expect(out.string).to include("SOURCE")
    expect(out.string).to include("DESCRIPTION")
    expect(out.string).to include("ship")
    expect(out.string).to include("source:1")
    expect(out.string).to include("One feature end to end.")
    expect(out.string).to include("rpiv")
    expect(out.string).to include("builtin")
  end

  it "answers one document with --json" do
    run_cli("workflow", "list", "--json")

    expect(exits).to eq([])
    doc = JSON.parse(out.string)
    expect(doc["ok"]).to be(true)
    expect(doc["workflows"].map { |row| row["id"] }).to include("rpiv")
  end

  it "names list in the missing-subcommand message" do
    run_cli("workflow")

    expect(err.string + out.string).to include("list")
  end

  it "refuses --source, which is for show and install" do
    run_cli("workflow", "list", "--source")

    expect(exits).to eq([1])
    expect(err.string).to include("--source is for")
  end
end
