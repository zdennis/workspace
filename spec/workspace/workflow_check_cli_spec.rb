require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe "workspace workflow check through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-check-cli") do |dir|
      saved = ENV.to_h
      @home = File.realpath(dir)
      @plain = File.join(@home, "plain")
      @fixture = File.join(@home, "fixture")
      FileUtils.mkdir_p([@plain, @fixture, File.join(@home, ".config", "workspace", "workflows")])
      File.write(File.join(@home, ".config", "workspace", "workflows", "probe.yml"), <<~YAML)
        steps:
          verify:
            prompt: Verify.
            status:
              run: 'echo "ran in $(pwd)"; test -f "$WORKSPACE_RUN_ARTIFACTS/ok.txt"'
          long:
            prompt: Long.
            status: {run: 'seq 1 100; exit 2'}
          plain:
            prompt: Plain.
            produces: [x.md]
      YAML
      begin
        ENV.replace("HOME" => @home, "PATH" => ENV["PATH"], "TMPDIR" => @home)
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
    [out, err].each do |io|
      io.truncate(0)
      io.rewind
    end
    exits.clear
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "check", *args])
  rescue SystemExit => e
    exits << e.status
  end

  def state_tree
    Dir.glob(File.join(@home, "{.local,.config,.workspace*}", "**", "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.", "/..") }.sort
  end

  it "passes against a fixture directory, prints the output and writes no run state" do
    File.write(File.join(@fixture, "ok.txt"), "x")
    before = state_tree

    run_cli("probe", "verify", "--artifacts", "../fixture")

    expect(exits).to eq([])
    expect(out.string).to eq("ran in #{@plain}\n")
    expect(err.string).to include("check passed: exit 0", "artifacts #{@fixture}")
    expect(state_tree).to eq(before)
    expect(Dir.glob(File.join(@home, "**", ".workflow"))).to eq([])
    expect(Dir.glob(File.join(@home, "**", "*.events.jsonl"))).to eq([])
  end

  it "exits 1 when the check fails, and says so in --json with ok: true" do
    run_cli("probe", "verify", "--json")
    doc = JSON.parse(out.string)

    expect(exits).to eq([1])
    expect(doc).to include("ok" => true, "passed" => false, "exit_code" => 1, "timed_out" => false, "artifacts_created" => true, "step" => "verify")
    expect(File.read(doc["log"])).to include("ran in")
    expect(doc["log"]).to start_with(@home)
  end

  it "refuses a step with no status, an unknown step, a bad artifacts path and an unknown workflow" do
    {["probe", "plain"] => "step_without_status", ["probe", "nope"] => "unknown_step",
     ["probe", "verify", "--artifacts", "missing"] => "artifacts_not_directory", ["ghost", "verify"] => "unknown_workflow"}.each do |args, code|
      run_cli(*args, "--json")
      expect(JSON.parse(out.string)).to include("ok" => false, "code" => code)
    end
  end

  it "shows the last 40 lines of a long log, whole in --json's tail" do
    run_cli("probe", "long")
    expect(out.string.lines).to eq((61..100).map { |n| "#{n}\n" })
    expect(exits).to eq([1])

    run_cli("probe", "long", "--json")
    expect(JSON.parse(out.string)["tail"].lines.size).to eq(40)
  end

  it "refuses --input, and an empty --artifacts" do
    run_cli("probe", "verify", "--input", "a=b", "--json")
    expect(err.string + out.string).to include("takes no inputs")

    run_cli("probe", "verify", "--artifacts", "", "--json")
    expect(JSON.parse(out.string)).to include("code" => "artifacts_not_directory")
  end

  it "runs at the checkout's root from a subdirectory" do
    repo = File.join(@home, "repo")
    FileUtils.mkdir_p(File.join(repo, "sub"))
    system("git", "init", "-q", repo, exception: true)
    Dir.chdir(File.join(repo, "sub")) do
      run_cli("probe", "verify", "--artifacts", @fixture)
      expect(out.string).to eq("ran in #{File.realpath(repo)}\n")
    end
  end

  it "warns not_in_checkout in --json outside a checkout" do
    run_cli("probe", "verify", "--json")

    expect(JSON.parse(out.string)["warnings"].map { |w| w["code"] }).to eq(["not_in_checkout"])
  end

  it "needs an ID and a STEP" do
    run_cli("probe")

    expect(err.string).to include("workflow check needs an ID and a STEP")
  end

  it "keeps --artifacts to check" do
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "render", "probe", "verify", "--artifacts", "x"])
  rescue SystemExit => e
    expect([e.status, err.string]).to match([satisfy { |status| status != 0 }, include("--artifacts is for `workflow check ID STEP`")])
  else
    raise "render with --artifacts was not refused"
  end

  it "warns not_in_checkout and runs in place inside the .git directory" do
    repo = File.join(@home, "repo2")
    system("git", "init", "-q", repo, exception: true)
    Dir.chdir(File.join(repo, ".git")) do
      run_cli("probe", "verify", "--artifacts", @fixture, "--json")
      expect(JSON.parse(out.string)["warnings"].map { |w| w["code"] }).to eq(["not_in_checkout"])
    end
  end
end
