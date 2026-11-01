require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow simulate through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-simulate-cli") do |dir|
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

  def run_cli(*args, verb: "simulate")
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", verb, *args])
  rescue SystemExit => e
    exits << e.status
  end

  def script(text, name: "script.yml")
    File.join(@home, name).tap { |path| File.write(path, text) }
  end

  def tree
    Dir.glob(File.join(@home, "**", "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.", "/..") }.sort
  end

  let(:verify_twice) do
    script(<<~YAML)
      inputs: {task: add a hello script}
      steps:
        plan:
          - {gate: reject, note: narrow it}
        verify:
          - {check: fail, log: "2 failures", tokens: 40000}
          - {check: fail}
          - {}
    YAML
  end

  it "plays rpiv, prints the transitions and leaves the state directory and config as they were" do
    path = verify_twice
    before = tree
    run_cli("rpiv", "--script", path)

    expect(exits).to eq([])
    expect(out.string).to include("outcome completed", "gate_rejected", "step_looped  from=verify to=implement count=2", "run_completed")
    expect(out.string).to include("verify: 3 attempts: failed (check_failed), failed (check_failed), passed")
    expect(tree).to eq(before)
  end

  it "prints one document under --json, with --input winning over the script's" do
    run_cli("rpiv", "--script", verify_twice, "--input", "task=other", "--json")
    doc = JSON.parse(out.string)

    expect(doc).to include("ok" => true, "workflow" => "rpiv", "outcome" => "completed", "capped" => false, "stopped" => nil, "max_actions" => 200)
    expect(doc["steps"].find { |step| step["id"] == "verify" }["attempts"].map { |each| each["outcome"] }).to eq(%w[failed failed passed])
    expect(doc["transitions"].first).to include("n" => 1, "at" => 0, "type" => "run_started")
    expect(doc["transitions"].map { |each| each["type"] }).to include("simulated_agent", "simulated_person")
  end

  it "stops, with exit 0, where a person is needed" do
    path = script("inputs: {task: x}\nsteps:\n  implement:\n    - {require: {commits: fail}}\n")
    run_cli("rpiv", "--script", path, "--json")
    doc = JSON.parse(out.string)

    expect(exits).to eq([])
    expect(doc).to include("outcome" => "stopped", "stopped" => {"step" => "implement", "attempt" => 1, "reason" => "failed_check"})
  end

  it "lists every problem of a bad script under invalid_script, as an envelope under --json" do
    path = script("inputs: {nope: 1}\nsteps:\n  verify:\n    - {check: maybe, wat: 1}\n  ghost: []\nextra: 1\n")
    run_cli("rpiv", "--script", path, "--json")
    doc = JSON.parse(out.string)

    expect(doc).to include("ok" => false, "code" => "invalid_script")
    expect(doc["details"]["count"]).to eq(5)
    expect(doc["details"]["problems"].join("\n")).to include("unknown key \"extra\"", "inputs.nope", "steps.ghost", "unknown key \"wat\"", "check must be one of")
    expect(exits).to eq([1])
  end

  it "needs --script, and refuses --script for another verb" do
    run_cli("rpiv")
    expect(err.string).to include("workflow simulate needs --script FILE")

    run_cli("rpiv", "plan", "--script", "x.yml", verb: "render")
    expect(err.string).to include("--script is for `workflow simulate ID`")
  end

  it "refuses a script it can't read, an unknown workflow and a missing input with their codes" do
    run_cli("rpiv", "--script", File.join(@home, "nope.yml"))
    expect(err.string).to include("Can't read")

    run_cli("ghost", "--script", verify_twice, "--json")
    expect(JSON.parse(out.string)).to include("code" => "unknown_workflow")

    run_cli("rpiv", "--script", script("steps: {}\n"), "--json")
    expect(JSON.parse(out.string)).to include("code" => "input_required")
  end
end
