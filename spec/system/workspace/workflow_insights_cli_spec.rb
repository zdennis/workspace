require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow insights through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-insights-cli") do |dir|
      saved = ENV.to_h
      begin
        @home = File.realpath(dir)
        ENV.replace("HOME" => @home, "PATH" => File.dirname(RbConfig.ruby))
        example.run
      ensure
        ENV.replace(saved)
      end
    end
  end

  let(:config) { Workspace::Config.new }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:exits) { [] }

  def put(id, outcomes, workspace: "app", created: (Time.now - 3600).utc.iso8601)
    FileUtils.mkdir_p(config.workflow_runs_dir)
    attempts = outcomes.each_with_index.map do |outcome, i|
      {"n" => i + 1, "outcome" => outcome, "started_at" => "2026-10-30T09:00:00Z", "ended_at" => "2026-10-30T09:06:00Z"}
    end
    run = {"id" => id, "workflow" => "rpiv", "workspace" => workspace, "state" => "running", "current" => "plan", "created_at" => created,
           "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"state" => "passed", "attempts" => attempts}}}
    File.write(File.join(config.workflow_runs_dir, "#{id}.json"), JSON.generate(run))
  end

  def run_cli(*args)
    exits.clear
    out.truncate(0)
    out.rewind
    err.truncate(0)
    err.rewind
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "insights", *args])
  rescue SystemExit => e
    exits << e.status
  end

  def state_tree
    Dir.glob(File.join(@home, "**", "*"), File::FNM_DOTMATCH).reject { |path| path.end_with?("/.", "/..") }.sort.map { |path| [path, File.mtime(path)] }
  end

  it "prints the header and the hot steps in text, and writes nothing" do
    3.times { |i| put("wr_#{i}", %w[failed passed]) }
    before = state_tree

    run_cli("rpiv")

    expect(out.string).to include("Insights for rpiv: 3 runs read, of 3 matching runs stored.")
    expect(out.string).to include("plan")
    expect(exits).to eq([])
    expect(state_tree).to eq(before)
  end

  it "prints one JSON document with next_actions that parse as commands" do
    3.times { |i| put("wr_#{i}", %w[failed passed]) }

    run_cli("rpiv", "--json", "--last", "2w", "--name", "app", "--runs", "2")

    document = JSON.parse(out.string)
    expect(document).to include("ok" => true, "workflow" => "rpiv", "status" => "ok", "runs" => 2, "last" => "2w", "workspace" => "app")
    expect(document["next_actions"]).not_to be_empty

    document["next_actions"].select { |each| each["action"].start_with?("workflow stats", "workflow compare") }.each do |action|
      exits.clear
      Workspace.build_cli(output: StringIO.new, error_output: err, input: StringIO.new, env: {}).run(action["action"].split + action["args"].to_a)
      expect(err.string).to eq("")
    end
    expect(document["next_actions"].map { |each| each["action"] }).to include("workflow stats")
  end

  it "says plainly that a workflow has no runs" do
    run_cli("nothing")
    expect(out.string).to start_with("No runs of nothing.")
    expect(exits).to eq([])
  end

  it "exits 3 with status partial when a run file cannot be read" do
    3.times { |i| put("wr_#{i}", %w[passed]) }
    File.write(File.join(config.workflow_runs_dir, "wr_bad.json"), "{nope")

    run_cli("rpiv", "--json")

    expect(JSON.parse(out.string)).to include("status" => "partial")
    expect(exits).to eq([3])
  end

  it "refuses a bad --runs, a bad --last, --runs on another verb, --all and a missing ID" do
    run_cli("rpiv", "--runs", "0")
    expect(err.string).to include("--runs needs a whole number from 1 up")
    expect(exits).to eq([1])
    run_cli("rpiv", "--runs", "x")
    expect(err.string).to include("--runs needs a whole number from 1 up")
    expect(exits).to eq([1])
    run_cli("rpiv", "--last", "soon")
    expect(err.string).to include("--last needs a duration")
    run_cli("rpiv", "--all")
    expect(err.string).to include("--all is not needed")
    run_cli
    expect(err.string).to include("needs a workflow ID")
  end

  it "refuses --runs on another verb" do
    expect {
      Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "stats", "rpiv", "--runs", "3"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    expect(err.string).to include("--runs is for `workflow insights ID`.")
  end
end
