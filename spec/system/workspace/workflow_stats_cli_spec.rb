require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "workspace workflow stats through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-stats-cli") do |dir|
      saved = ENV.to_h
      begin
        ENV.replace("HOME" => File.realpath(dir), "PATH" => File.dirname(RbConfig.ruby))
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

  def put(id, steps, workspace: "app", state: "running", created: (Time.now - 3600).utc.iso8601, dir: config.workflow_runs_dir, events: [])
    FileUtils.mkdir_p(dir)
    attempts = steps.transform_values do |list|
      {"state" => "passed", "attempts" => list.each_with_index.map do |(outcome, usage), i|
        {"n" => i + 1, "outcome" => outcome, "started_at" => "2026-10-30T09:00:00Z", "ended_at" => "2026-10-30T09:06:00Z", "usage" => usage}
      end}
    end
    run = {"id" => id, "workflow" => "rpiv", "workspace" => workspace, "state" => state, "current" => steps.keys.first, "created_at" => created,
           "definition" => {"steps" => steps.keys.map { |each| {"id" => each} }}, "steps" => attempts}
    File.write(File.join(dir, "#{id}.json"), JSON.generate(run))
    File.write(File.join(dir, "#{id}.events.jsonl"), events.map { |each| JSON.generate(each) + "\n" }.join) unless events.empty?
  end

  def run_cli_strict(*args) = Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "stats", *args])

  def usage(total) = {"input_tokens" => total, "output_tokens" => 0, "cache_creation_input_tokens" => 0}

  def run_cli(*args)
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "stats", *args])
  rescue SystemExit => e
    exits << e.status
  end

  it "prints a table with the median, resumes and a token mean" do
    put("wr_1", {"research" => [["passed", usage(310_000)]], "plan" => [["passed", usage(400_000)], ["failed", usage(20_000)]]},
      events: [{"type" => "run_resumed", "step" => "plan"}])

    run_cli("rpiv")

    lines = out.string.lines.map(&:rstrip)
    expect(lines[0].split).to eq(%w[STEP ATTEMPTS PASSED FAILED MEDIAN RESUMES TOKENS/RUN])
    expect(lines[1].split).to eq(%w[research 1 1 0 6m 0 310k])
    expect(lines[2].split).to eq(%w[plan 2 1 1 6m 1 420k])
    expect(lines).to include("1 run of rpiv.")
    expect(exits).to eq([])
  end

  it "marks a token mean that leaves out runs, and a step with none counted" do
    put("wr_1", {"plan" => [["passed", usage(1000)]], "verify" => [["passed", nil]]})
    put("wr_2", {"plan" => [["passed", nil]], "verify" => [["passed", nil]]})

    run_cli("rpiv")

    expect(out.string).to match(/^plan\s+2\s+2\s+0\s+6m\s+0\s+1k\*$/)
    expect(out.string).to match(/^verify\s+2\s+2\s+0\s+6m\s+0\s+-$/)
    expect(out.string).to include("TOKENS/RUN is the mean over the runs that recorded tokens")
  end

  it "explains tokens counted from an attempt that ended with no result, and says nothing when there is none" do
    put("wr_1", {"plan" => [[nil, usage(15)]]}, state: "cancelled", dir: config.workflow_archive_dir)
    run_cli("rpiv")
    expect(out.string).to match(/^plan\s+0\s+0\s+0\s+\S+\s+0\s+15$/)
    expect(out.string).to include("TOKENS/RUN also counts the tokens of 1 attempt that ended with no result")

    out.truncate(0)
    out.rewind
    FileUtils.rm_f(Dir.glob(File.join(config.workflow_archive_dir, "*")))
    put("wr_2", {"plan" => [["passed", usage(15)]]})
    run_cli("rpiv")
    expect(out.string).not_to include("ended with no result")
  end

  it "says how many attempts never reached the agent" do
    put("wr_1", {"plan" => [["not_delivered", nil], ["passed", usage(5)]]})
    run_cli("rpiv")
    expect(out.string).to include("1 attempt never reached the agent and is left out.")
  end

  it "answers plainly for a workflow with no runs" do
    run_cli("nothing", "--last", "30d")
    expect(out.string).to eq("No runs of nothing started in the last 30d.\n")
    expect(exits).to eq([])
  end

  it "prints one JSON document" do
    put("wr_1", {"plan" => [["passed", usage(7)]]})
    run_cli("rpiv", "--json", "--last", "2w", "--name", "app")
    document = JSON.parse(out.string)
    expect(document).to include("schema_version" => 1, "ok" => true, "workflow" => "rpiv", "status" => "ok", "last" => "2w", "workspace" => "app", "runs" => 1, "unreadable" => 0)
    expect(document["steps"].first).to include("step" => "plan", "attempts" => 1, "tokens" => {"mean" => 7, "runs_counted" => 1, "runs_uncounted" => 0})
    expect(document["since"]).to match(/\A\d{4}-\d\d-\d\dT/)
  end

  it "reads archived runs and narrows to a workspace with --name" do
    put("wr_1", {"plan" => [["passed", usage(1)]]}, workspace: "app", dir: config.workflow_archive_dir)
    put("wr_2", {"plan" => [["failed", usage(1)]]}, workspace: "lib")
    run_cli("rpiv", "--name", "lib", "--json")
    expect(JSON.parse(out.string)["steps"].first).to include("passed" => 0, "failed" => 1)
  end

  it "exits 3 with status partial when a run file cannot be read" do
    put("wr_1", {"plan" => [["passed", usage(1)]]})
    File.write(File.join(config.workflow_runs_dir, "wr_bad.json"), "{nope")

    run_cli("rpiv", "--json")

    expect(JSON.parse(out.string)).to include("status" => "partial", "unreadable" => 1)
    expect(exits).to eq([3])
  end

  it "warns in text when a run file cannot be read" do
    put("wr_1", {"plan" => [["passed", usage(1)]]})
    File.write(File.join(config.workflow_runs_dir, "wr_bad.json"), "{nope")
    run_cli("rpiv")
    expect(out.string).to include("Warning: 1 run file could not be read; the figures are incomplete.")
    expect(exits).to eq([3])
  end

  def refused(*args)
    err.truncate(0)
    err.rewind
    exits.clear
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(args)
  rescue SystemExit => e
    exits << e.status
    err.string
  end

  it "refuses a bad --last as a usage error" do
    expect(refused("workflow", "stats", "rpiv", "--last", "soon")).to include("--last needs a duration")
    expect(exits).to eq([1])
    expect(refused("workflow", "stats", "rpiv", "--last", "0d")).to include("greater than 0")
  end

  it "refuses --last on another verb, --all, and a missing ID" do
    expect(refused("workflow", "status", "--last", "1d")).to include("--last is for")
    expect(refused("workflow", "stats", "rpiv", "--all")).to include("--all is not needed")
    expect(refused("workflow", "stats")).to include("needs a workflow ID")
  end
end
