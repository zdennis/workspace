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
      elif [ "$1 $2" = "workflow trace" ]; then f=#{stubs}/trace-$3.json; [ -f $f ] || f=#{stubs}/trace.json; cat $f
      else echo "unexpected: $@" >&2; exit 1; fi
    SH
    File.chmod(0o755, path)
    path
  end

  let(:checks) do
    Class.new do
      attr_reader :diff_args

      attr_reader :acceptance_heads, :acceptance_goals, :leak_args
      attr_accessor :possible_classes

      def acceptance(base_sha:, head:, goal:)
        (@acceptance_heads ||= []) << head
        (@acceptance_goals ||= []) << goal
        (head == "dirty-head") ? {passed: [], failed: [goal], regressions: []} : {passed: [goal], failed: [], regressions: []}
      end

      def lint(head:, gemfile:) = 0

      def leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
        @leak_args = {head: head, removal: removal}
        {hook: 1, transcript: {}, possible_classes: @possible_classes}.compact
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

  describe "machine waits" do
    def waits(run_id, buckets)
      write_json(File.join(stubs, "trace-#{run_id}.json"), {"totals" => fixture["totals"].merge("machine_waiting_seconds" => buckets), "spans" => spans})
    end

    def second_run(buckets)
      run = JSON.parse(File.read(File.join(state, ".workflows", "archive", "wr_plain.json")))
      run["id"] = "wr_two"
      write_json(File.join(state, ".workflows", "archive", "wr_two.json"), run)
      File.write(File.join(state, ".workflows", "archive", "wr_two.events.jsonl"), "")
      write_json(File.join(stubs, "history.json"), {"entries" => [{"id" => "q1", "result" => {"run_id" => "wr_plain"}}, {"id" => "q2", "result" => {"run_id" => "wr_two"}}]})
      waits("wr_two", buckets) if buckets
    end

    it "takes the waits off each row's wall and active and shows them in the table" do
      waits("wr_plain", {"waiting_lock" => 100.0})
      row = result[:rows].first
      expect(row).to include(machine_wait: 100.0, wall_ex_wait: 500.0, active_ex_wait: 440.0)
      text = described_class.render(result)
      expect(text).to match(/stopped\s+wait_p\s+bg\s+redeliv\s+lockw\s+wall-lw\s+act-lw\s+gap/)
      expect(text).to match(/^01-add-sub\s+done\s.*\b10m00s\s+9m00s\s+1m00s\s+\S+\s+\S+\s+\S+\s+1m40s\s+8m20s\s+7m20s\s/)
    end

    it "sums the waits in the totals, with no partial mark when every ran row knows them" do
      waits("wr_plain", {"waiting_lock" => 100.0})
      second_run("retry_backoff" => 30.0)
      expect(result[:totals]).to include("machine_wait" => 130.0, "wall_ex_wait" => 1070.0, "active_ex_wait" => 950.0)
      expect(result[:totals]["partial"]).not_to include("machine_wait")
      expect(described_class.render(result)).to match(/^total\s.*\s2m10s\s+17m50s\s+15m50s\s/)
    end

    it "gives nil totals and a plain table when no row has waits" do
      expect(result[:rows].first).to include(machine_wait: nil, wall_ex_wait: nil, active_ex_wait: nil)
      expect(result[:totals]).to include("machine_wait" => nil, "wall_ex_wait" => nil, "active_ex_wait" => nil)
      expect(result[:totals]["partial"]).not_to include("machine_wait")
    end

    it "marks the waits partial when only some ran rows know them" do
      waits("wr_plain", {"waiting_lock" => 100.0})
      second_run(nil)
      expect(result[:rows].map { |row| row[:machine_wait] }).to eq([100.0, nil])
      expect(result[:totals]).to include("machine_wait" => 100.0)
      expect(result[:totals]["partial"]).to include("machine_wait")
    end

    it "leaves the wait columns nil for a row that never ran, and dashes them in the table" do
      waits("wr_plain", {"waiting_lock" => 100.0})
      expect(result[:rows].last).to include(ran: false, machine_wait: nil, wall_ex_wait: nil, active_ex_wait: nil)
      dash = Regexp.escape(DemoCalculator::EvalReport::DASH)
      expect(described_class.render(result)).to match(/^02-mul-div\s+not run(\s+#{dash}){#{described_class::HEADER.size - 2}}$/)
    end

    it "prints the possible-hit lines under the leak line" do
      counts = {false_positive: 1, stat_only: 2, near_miss: 1, unresolved: 0}
      checks.possible_classes = {hook: counts, transcript: counts, near_misses: [{source: "hook", command: "git diff a..b > f"}]}
      leak = described_class.render(result).lines.map(&:chomp).drop_while { |line| !line.start_with?("leak:") }
      expect(leak[1..3]).to eq(["possible hits (hook): 1 false positive, 2 stat only, 1 near miss, 0 unresolved",
        "possible hits (transcript): 1 false positive, 2 stat only, 1 near miss, 0 unresolved", "near-miss (hook): git diff a..b > f"])
    end
  end
end
