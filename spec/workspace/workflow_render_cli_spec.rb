require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow render through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-render-cli") do |dir|
      saved = ENV.to_h
      @home = File.realpath(dir)
      @plain = File.join(@home, "plain")
      FileUtils.mkdir_p(@plain)
      begin
        ENV.replace("HOME" => @home, "PATH" => ENV["PATH"])
        ENV.delete("TMUX")
        ENV.delete("TMUX_PANE")
        Dir.chdir(@plain) { example.run }
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:exits) { [] }

  def run_cli(*args)
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "render", *args])
  rescue SystemExit => e
    exits << e.status
  end

  def tree
    Dir.glob(File.join(@home, "**", "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.", "/..") }.sort
  end

  it "prints a preset's step outside a git checkout and tmux, with the previews on stderr and no file written" do
    before = tree
    run_cli("rpiv", "plan", "--input", "task=add a hello script")

    expect(exits).to eq([])
    expect(out.string).to include("## From pack binding (built-in)", "add a hello script", "wr_preview")
    expect(err.string).to include("warning:", "is not in a git checkout", "{{workspace}} = <workspace>", "{{run}} = wr_preview", "has gate: approve")
    expect(tree).to eq(before)
  end

  it "prints one document under --json" do
    run_cli("rpiv", "research", "--input", "task=x", "--json")
    doc = JSON.parse(out.string)

    expect(doc).to include("ok" => true, "workflow" => "rpiv", "step" => "research", "workspace" => "<workspace>", "inputs" => {"task" => "x", "spec" => ""})
    expect(doc["text"]).to include("x")
    expect(doc["warnings"].map { |w| w["code"] }).to eq(["not_in_checkout"])
    expect(doc["previews"].map { |w| w["name"] }).to eq(%w[run workspace artifacts])
    expect(err.string).to eq("")
  end

  it "refuses an unknown step, a missing input and an unknown workflow with their stable codes" do
    run_cli("rpiv", "nope", "--input", "task=x", "--json")
    expect(JSON.parse(out.string)).to include("ok" => false, "code" => "unknown_step", "details" => hash_including("steps" => include("plan")))
    run_cli("rpiv", "plan", "--json")
    expect(JSON.parse(out.string)).to include("code" => "input_required")
    run_cli("ghost", "plan", "--json")
    expect(JSON.parse(out.string)).to include("code" => "unknown_workflow")
  end

  it "needs an ID and a STEP" do
    run_cli("rpiv")

    expect(exits).to eq([2]).or eq([1])
    expect(err.string).to include("workflow render needs an ID and a STEP")
  end

  it "leaves --step-less flags for other verbs refused" do
    run_cli("rpiv", "plan", "--input", "task=x", "--prompt", "y")

    expect(err.string).to include("--prompt is for `workflow start")
  end
end
