require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"

load File.join(PROJECT_ROOT, "script", "demo-calculator2")

RSpec.describe DemoCalculator2::Evaluation do
  let(:tmp) { Dir.mktmpdir }
  let(:state) { File.join(tmp, "state") }
  let(:run_dir) { File.join(tmp, "rundir") }
  let(:stubs) { File.join(tmp, "stubs") }
  let(:fixture) { JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/demo_calculator/runs/plain_pass.json"))) }
  let(:spans) do
    [{"kind" => "attempt", "step" => "implement", "started_at" => "2026-11-21T05:01:00Z", "ended_at" => "2026-11-21T05:09:00Z"},
      {"kind" => "attempt", "step" => "acceptance", "started_at" => "2026-11-21T05:09:00Z", "ended_at" => "2026-11-21T05:09:10Z"},
      {"kind" => "attempt", "step" => "acceptance", "started_at" => "2026-11-21T05:09:20Z", "ended_at" => "2026-11-21T05:09:30Z"}]
  end

  after { FileUtils.rm_rf(tmp) }

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  let(:workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "capabilities" ]; then cat #{stubs}/caps.json
      elif [ "$1 $2 $3" = "work-queue history list" ]; then cat #{stubs}/history.json
      elif [ "$1 $2" = "work-queue list" ]; then cat #{stubs}/queue.json
      elif [ "$1 $2" = "workflow trace" ]; then cat #{stubs}/trace.json
      else echo "unexpected: $@" >&2; exit 1; fi
    SH
    File.chmod(0o755, path)
    path
  end

  let(:checks) do
    Class.new do
      attr_reader :diff_args

      attr_reader :acceptance_heads, :acceptance_goals, :leak_args

      def acceptance(base_sha:, head:, goal:)
        (@acceptance_heads ||= []) << head
        (@acceptance_goals ||= []) << goal
        (head == "dirty-head") ? {passed: [], failed: [goal], regressions: []} : {passed: [goal], failed: [], regressions: []}
      end

      def lint(head:, gemfile:) = 0

      def leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
        @leak_args = {head: head, removal: removal}
        {hook: 1, transcript: {}}
      end

      def diff_scan(base_sha:, head:, since:)
        @diff_args = [base_sha, head, since]
        {paths: [], copied: ["x"]}
      end
    end.new
  end

  before do
    run = fixture["run"]
    run["steps"]["acceptance"] = {"state" => "passed", "attempts" => [{"n" => 1, "outcome" => "failed", "head" => {"before" => "h0"}, "started_at" => "2026-11-21T05:09:00Z"},
      {"n" => 2, "outcome" => "passed", "started_at" => "2026-11-21T05:09:20Z"}]}
    run["steps"]["implement"]["attempts"] << {"n" => 2, "outcome" => "passed", "started_at" => "2026-11-21T05:09:12Z"}

    write_json(File.join(state, ".workflows", "archive", "#{run["id"]}.json"), run)
    File.write(File.join(state, ".workflows", "archive", "#{run["id"]}.events.jsonl"), "")
    FileUtils.mkdir_p(stubs)
    write_json(File.join(stubs, "caps.json"), {"paths" => {"hook_events" => File.join(state, ".events")}})
    write_json(File.join(stubs, "trace.json"), {"totals" => fixture["totals"], "spans" => spans})
    write_json(File.join(stubs, "history.json"), {"entries" => [{"id" => "q1", "result" => {"run_id" => run["id"]}}]})
    write_json(File.join(stubs, "queue.json"), {"queues" => [{"workspace" => "ws", "items" => []}]})
    write_json(File.join(run_dir, "run.json"), {
      "stamp" => "20261121T050000Z", "branch" => "calc-demo/20261121T050000Z", "base_sha" => "b" * 40,
      "acceptance_ref" => {"name" => "refs/demo-calc2/acceptance-base", "sha" => "a" * 40, "removal_sha" => "r" * 40},
      "workspace" => {"sha" => "w" * 40, "version" => "1.0"},
      "items" => [{"workflow" => "deliver-goal", "id" => "q1"}, {"workflow" => "deliver-goal", "id" => "q2"}], "definitions" => {}
    })
  end

  let(:fixture_rounds) { DemoCalculator::EvalRows.rows([{workflow: "deliver-goal", run: fixture["run"], events: [], totals: fixture["totals"]}]).first[:review_rounds] }

  let(:result) do
    described_class.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: File.join(PROJECT_ROOT, "demo", "pricing.yml"),
      run_dir: run_dir, checks: checks, err: StringIO.new).call
  end

  it "adds step wall time, first-pass acceptance and acceptance loops to a run's row, and drops features" do
    row = result[:rows].first
    expect(row[:step_wall]).to eq("implement" => 480.0, "acceptance" => 20.0)
    expect(row).to include(accept_first_pass: true, accept_first_recorded: false, accept_first_disagrees: true, accept_loops: 1, goal: "01-add-sub")
    expect(checks.acceptance_heads).to include("h0")
    expect(row).not_to have_key(:features)
    expect(result[:totals]).to include("first_pass" => 1, "first_disagreements" => 1, "accept_loops" => 1, "acceptance_passed" => 1, "acceptance_of" => 1)
  end

  it "labels rows and checks acceptance by the record's goals when only some were queued" do
    record = JSON.parse(File.read(File.join(run_dir, "run.json")))
    write_json(File.join(run_dir, "run.json"), record.merge("goals" => %w[03-div-zero 05-mod-pow]))
    expect(result[:rows].map { |row| row[:goal] }).to eq(%w[03-div-zero 05-mod-pow])
    expect(checks.acceptance_goals.uniq).to eq(["03-div-zero"])
    expect(described_class.render(result)).to match(/^05-mod-pow\s+not run/)
  end

  it "counts a completed goal that fails its own acceptance as unmet in a subset record" do
    record = JSON.parse(File.read(File.join(run_dir, "run.json")))
    write_json(File.join(run_dir, "run.json"), record.merge("goals" => %w[03-div-zero 05-mod-pow]))
    archived = Dir.glob(File.join(state, ".workflows", "archive", "*.json")).first
    write_json(archived, JSON.parse(File.read(archived)).merge("state" => "completed"))
    allow(checks).to receive(:acceptance) { |goal:, **| {passed: [], failed: [goal], regressions: []} }
    expect(result[:rows].first).to include(goal: "03-div-zero", state: "completed")
    expect(result[:totals]["completed_unmet"]).to eq(1)
  end

  it "labels rows by all of GOALS for a record without goals" do
    expect(result[:rows].map { |row| row[:goal] }).to eq(%w[01-add-sub 02-mul-div])
    expect(checks.acceptance_goals.uniq).to eq(["01-add-sub"])
  end

  it "refuses a record whose goals do not match its items" do
    record = JSON.parse(File.read(File.join(run_dir, "run.json")))
    write_json(File.join(run_dir, "run.json"), record.merge("goals" => %w[03-div-zero]))
    expect { result }.to raise_error(DemoCalculator::Evaluation::Error, /1 goals for 2 items/)
  end

  it "reports review rounds per row and in the totals" do
    expect(result[:rows].first[:review_rounds]).to eq(fixture_rounds)
    expect(result[:totals]["review_rounds"]).to eq(fixture_rounds)
    expect(JSON.parse(File.read(File.join(run_dir, "eval.json")))["totals"]["review_rounds"]).to eq(fixture_rounds)
  end

  it "does not count a first attempt it cannot check, and gives rows that never ran the keys with nil" do
    run = JSON.parse(File.read(Dir.glob(File.join(state, ".workflows", "archive", "*.json")).first))
    run["steps"]["acceptance"]["attempts"][0].delete("head")
    File.write(File.join(state, ".workflows", "archive", "#{run["id"]}.json"), JSON.generate(run))
    expect(result[:rows].first).to include(accept_first_pass: nil, accept_first_disagrees: false)
    expect(result[:rows].last).to include(ran: false, accept_first_pass: nil, accept_loops: nil, step_wall: nil, acceptance: nil, usage: nil)
  end

  it "scans the diff
 from the acceptance ref's sha and adds it to the leak" do
    expect(result[:leak]).to include(hook: 1, diff: {paths: [], copied: ["x"]})
    expect(checks.diff_args).to eq(["a" * 40, result[:lint][:head], "r" * 40])
    expect(result[:lint][:head]).to be_a(String)
    expect(checks.leak_args).to eq(head: result[:lint][:head], removal: "r" * 40)
  end

  it "renders the table, the step table and the leak line, and writes eval.json" do
    text = described_class.render(result)
    expect(text).to include("1st-pass", "a-loops", "step wall", "implement", "leak: hook 1", "0 acceptance paths touched, 1 copied line")
    expect(text).to match(/^01-add-sub\s+done\s/)
    expect(text.lines.grep(/\A02-mul-div\s+not run/)).not_to be_empty
    expect(JSON.parse(File.read(File.join(run_dir, "eval.json"))).keys).to eq(%w[record header rows totals lint leak])
  end
end
