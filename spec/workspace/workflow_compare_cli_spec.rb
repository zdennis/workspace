require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"

RSpec.describe "workspace workflow compare through build_cli" do
  around do |example|
    Dir.mktmpdir("wf-compare-cli") do |dir|
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

  def sha(text) = Digest::SHA256.hexdigest(text)

  def put(id, outcomes, text: "v1", workspace: "app", state: "completed", created: (Time.now - 3600).utc.iso8601, dir: config.workflow_archive_dir, events: [], packs: true)
    FileUtils.mkdir_p(dir)
    attempts = outcomes.each_with_index.map do |outcome, i|
      {"n" => i + 1, "outcome" => outcome}.merge(packs ? {"packs" => [{"ref" => "play/plan-review", "sha256" => sha(text)}]} : {})
    end
    run = {"id" => id, "workflow" => "rpiv", "workspace" => workspace, "state" => state, "current" => "plan", "created_at" => created,
           "definition_sha256" => sha("def-#{text}"), "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"attempts" => attempts}}}
    File.write(File.join(dir, "#{id}.json"), JSON.generate(run))
    File.write(File.join(dir, "#{id}.events.jsonl"), events.map { |each| JSON.generate(each) + "\n" }.join) unless events.empty?
  end

  def run_cli(*args)
    Workspace.build_cli(output: out, error_output: err, input: StringIO.new, env: {}).run(["workflow", "compare", *args])
  rescue SystemExit => e
    exits << e.status
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

  it "prints the table, the notes and the warning" do
    put("wr_1", %w[passed], text: "v1")
    put("wr_2", %w[failed passed], text: "v1", events: [{"type" => "run_resumed", "step" => "plan"}, {"type" => "run_resumed", "step" => "plan"}, {"type" => "run_resumed", "step" => "plan"}])
    put("wr_3", %w[passed], text: "v2")
    put("wr_4", [nil], text: "v2", state: "running", dir: config.workflow_runs_dir)

    run_cli("rpiv", "--by", "pack:plan-review")

    lines = out.string.lines.map(&:rstrip)
    expect(lines[0].split).to eq(%w[SHA RUNS PASS-1ST RESUMES/RUN])
    expect(lines[1].split).to eq([sha("v1")[0, 8], "2", "50%", "1.5"])
    expect(lines[0]).to match(/\ASHA {7}RUNS  PASS-1ST  RESUMES\/RUN\z/)
    expect(lines[1]).to end_with("  2       50%          1.5")
    expect(lines[2].split).to eq([sha("v2")[0, 8], "2", "100%", "0.0"])
    expect(lines).to include("4 runs of rpiv, grouped by pack:plan-review.")
    expect(out.string).to include("1 run still going and 0 cancelled with no miss, left out of PASS-1ST.")
    expect(lines.last).to eq("Too few runs to call this a difference; tasks also differ between runs, so this shows a direction and does not prove a cause.")
    expect(exits).to eq([])
  end

  it "groups by definition when --by is omitted, and says what unknown and mixed mean" do
    put("wr_1", %w[passed], packs: false)
    run_cli("rpiv")
    expect(out.string.lines[1].split.first).to eq(sha("def-v1")[0, 8])

    out.truncate(0)
    out.rewind
    File.write(File.join(config.workflow_archive_dir, "wr_1.json"), File.read(File.join(config.workflow_archive_dir, "wr_1.json")).sub(/"definition_sha256":"[0-9a-f]+",/, ""))
    run_cli("rpiv")
    expect(out.string).to include("unknown")
    expect(out.string).to include("unknown: runs stored without the hash; mixed: runs that saw more than one.")
  end

  it "prints full shas, the counts and the warning with --json" do
    put("wr_1", %w[passed], text: "v1")
    put("wr_2", %w[passed], text: "v2", workspace: "lib")

    run_cli("rpiv", "--by", "pack:plan-review", "--name", "lib", "--last", "2w", "--json")

    document = JSON.parse(out.string)
    expect(document).to include("schema_version" => 1, "ok" => true, "workflow" => "rpiv", "status" => "ok", "by" => "pack:plan-review", "workspace" => "lib", "last" => "2w", "runs" => 1, "matched" => 1)
    expect(document["groups"]).to eq([{"sha" => sha("v2"), "runs" => 1, "settled" => 1, "first_try" => 1, "pass_first_percent" => 100, "running" => 0, "cancelled" => 0, "stuck" => 0, "resumes" => 0, "resumes_per_run" => 0.0}])
    expect(document["warning"]).to start_with("Too few runs")
  end

  it "says no run used a pack no run used, still prints the warning and exits 0" do
    put("wr_1", %w[passed])
    run_cli("rpiv", "--by", "pack:nope")
    expect(out.string.lines.first).to eq("No run of rpiv used pack nope.\n")
    expect(out.string).to include("Too few runs")
    expect(exits).to eq([])
  end

  it "says there are no runs, with the warning, for a workflow with none" do
    run_cli("ghost", "--json")
    document = JSON.parse(out.string)
    expect(document).to include("runs" => 0, "groups" => [], "status" => "ok")
    expect(document["warning"]).to be_a(String)
  end

  it "escapes stored text in the output" do
    put("wr_1", %w[passed])
    path = File.join(config.workflow_archive_dir, "wr_1.json")
    File.write(path, File.read(path).sub(/"definition_sha256":"[0-9a-f]+"/, '"definition_sha256":"\u001b[31mx"'))
    run_cli("rpiv")
    expect(out.string).not_to include("\e")
  end

  it "exits 3 with status partial when a run file cannot be read" do
    put("wr_1", %w[passed])
    File.write(File.join(config.workflow_archive_dir, "wr_bad.json"), "{nope")

    run_cli("rpiv", "--json")

    expect(JSON.parse(out.string)).to include("status" => "partial", "unreadable" => 1)
    expect(exits).to eq([3])

    out.truncate(0)
    out.rewind
    run_cli("rpiv")
    expect(out.string).to include("Warning: 1 run file could not be read; the figures are incomplete.")
  end

  it "refuses a bad --by, --by on another verb, --all, a bad --last and a missing ID" do
    expect(refused("workflow", "compare", "rpiv", "--by", "sha")).to include("--by needs definition or pack:NAME")
    expect(exits).to eq([1])
    expect(refused("workflow", "stats", "rpiv", "--by", "definition")).to include("--by is for `workflow compare ID`.")
    expect(refused("workflow", "compare", "rpiv", "--all")).to include("--all is not needed")
    expect(refused("workflow", "compare", "rpiv", "--last", "soon")).to include("--last needs a duration")
    expect(refused("workflow", "compare")).to include("needs a workflow ID")
  end
end
