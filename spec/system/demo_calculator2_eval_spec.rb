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
    [{"kind" => "attempt", "step" => "implement", "started_at" => "2026-11-21T05:01:00Z", "ended_at" => "2026-11-21T05:09:00Z", "attempt" => 1, "tokens" => {"total" => 1000}},
      {"kind" => "review_round", "step" => "implement", "attempt" => 1, "round" => 1, "started_at" => "2026-11-21T05:08:00Z", "ended_at" => "2026-11-21T05:08:30Z", "tokens" => {"total" => 300}},
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
    expect(row).to include(step_tokens: {"implement" => 700}, review_wall: 30.0, review_tokens: 300)
    expect(row).not_to have_key(:features)
    expect(result[:totals]).to include("first_pass" => 1, "first_disagreements" => 1, "accept_loops" => 1, "acceptance_passed" => 1, "acceptance_of" => 1)
  end

  it "shows a dash for the gap of the last item, as v1 does, and ? for a next item with no time" do
    gap = described_class::HEADER.index("gap")
    expect(described_class.ran_cells(result[:rows].first.merge(gap: nil, final: true))[gap]).to eq("–")
    expect(described_class.ran_cells(result[:rows].first.merge(gap: nil, final: false))[gap]).to eq("?")
  end

  it "shows a dash, not zeros, in the review row of an item with no trace, and notes a round with no attempt" do
    ran = {ran: true, goal: "01-add-sub", step_wall: {"plan" => 60.0}, step_tokens: {"plan" => 1000}, review_wall: nil, review_tokens: nil, review_unmatched: 0}
    unmatched = ran.merge(goal: "02-mul-div", review_wall: 5.0, review_tokens: 50, review_unmatched: 1)
    expect(described_class.step_table([ran]).lines.last).to match(/^review\s+–$/)
    table = described_class.step_token_table([ran, unmatched])
    expect(table).to match(/^review\s+–\s+50$/)
    expect(table).to include("note: 02-mul-div has 1 review round(s) with no attempt of their own")
  end

  it "prices a review round's sub-agents at the model they ran on" do
    pricing = DemoCalculator::Cost.load_pricing(File.join(PROJECT_ROOT, "demo", "pricing.yml"))
    evaluation = described_class.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: File.join(PROJECT_ROOT, "demo", "pricing.yml"), run_dir: run_dir, checks: checks, err: StringIO.new)
    session = "d717cf1b-ab46-44bb-bdf9-60a2d9c17ddc"
    transcript = File.join(tmp, "proj", "#{session}.jsonl")
    FileUtils.mkdir_p(File.join(tmp, "proj", session, "subagents"))
    line = {"type" => "assistant", "timestamp" => "2026-11-21T05:01:10Z", "message" => {"id" => "m1", "model" => "claude-sonnet-5-5", "usage" => {"cache_read_input_tokens" => 1_000_000}}}
    File.write(File.join(tmp, "proj", session, "subagents", "agent-a.jsonl"), JSON.generate(line) + "\n")
    File.write(transcript, "")
    usage = {tokens: {}, cost_usd: 1.0, cost_partial: false, models: ["claude-opus-5-5"]}
    round = {"started_at" => "2026-11-21T05:01:00Z", "ended_at" => "2026-11-21T05:02:00Z", "usage" => {}, "agent" => {"model" => "claude-opus-5-5"}, "session" => {"id" => session, "transcript" => transcript}}
    run = {"steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "passed", "usage" => {}, "agent" => {"model" => "claude-opus-5-5"}, "rounds" => [round]}]}}}
    priced = evaluation.reviewer_priced(usage, run, pricing)
    expect(priced[:cost_usd]).to be_within(1e-9).of(1.0 + 0.30 - 0.50)
    expect(priced[:models]).to eq(%w[claude-opus-5-5 claude-sonnet-5-5])
    expect(priced[:cost_partial]).to be(false)
    File.write(File.join(tmp, "proj", session, "subagents", "agent-b.jsonl"), "[1]\n\"x\"\n")
    expect(evaluation.reviewer_priced(usage, run, pricing)[:cost_usd]).to be_within(1e-9).of(1.0 + 0.30 - 0.50)
    round["session"]["transcript"] = nil
    expect(evaluation.reviewer_priced(usage, run, pricing)).to include(cost_usd: 1.0, cost_partial: true)
    round["session"]["transcript"] = transcript
    File.delete(transcript)
    expect(evaluation.reviewer_priced(usage, run, pricing)).to include(cost_usd: 1.0, cost_partial: true)
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
    expect(text).to include("1st-pass", "a-loops", "step wall", "review", "step tokens", "implement", "leak: hook 1", "0 acceptance paths touched, 1 copied line")
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
      expect(text).to match(/stopped\s+wait_p\s+bg\s+redeliv\s+lockw\s+rv-wait\s+wall-wait\s+act-wait\s+gap/)
      expect(text).to match(/^01-add-sub\s+done\s.*\b10m00s\s+9m00s\s+1m00s\s+\S+\s+\S+\s+\S+\s+1m40s\s+0s\s+8m20s\s+7m20s\s/)
    end

    it "sums the waits in the totals, with no partial mark when every ran row knows them" do
      waits("wr_plain", {"waiting_lock" => 100.0})
      second_run("retry_backoff" => 30.0)
      expect(result[:totals]).to include("machine_wait" => 130.0, "wall_ex_wait" => 1070.0, "active_ex_wait" => 950.0)
      expect(result[:totals]["partial"]).not_to include("machine_wait")
      expect(described_class.render(result)).to match(/^total\s.*\s2m10s\s+0s\s+17m50s\s+15m50s\s/)
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

RSpec.describe DemoCalculator2::LanesEvaluation do
  let(:tmp) { Dir.mktmpdir }
  let(:state) { File.join(tmp, "state") }
  let(:run_dir) { File.join(tmp, "rundir") }
  let(:stubs) { File.join(tmp, "stubs") }
  let(:fixture) { JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/demo_calculator/runs/plain_pass.json"))) }
  let(:integration) do
    {"branch" => "calc-demo/20261121T050000Z-b", "started_at" => "2026-11-21T05:20:00Z", "ended_at" => "2026-11-21T05:24:00Z", "merge" => "conflict", "conflict" => true,
     "first_pass" => false, "head" => "i" * 40, "integrate_run" => {"item" => "qi", "outcome" => "succeeded", "run_id" => "wr_i", "passed" => true}}
  end

  after { FileUtils.rm_rf(tmp) }

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  # A run of the plain-pass fixture that began and ended at the given times, plus one failed verify attempt and a rejecting review.
  def archive(id, from, to, lock: 0)
    run = Marshal.load(Marshal.dump(fixture["run"]))
    run.merge!("id" => id, "started_at" => "2026-11-21T#{from}Z", "ended_at" => "2026-11-21T#{to}Z")
    run["steps"].each_value { |step| step["attempts"].each { |attempt| attempt["started_at"] = "2026-11-21T#{from}Z" } }
    run["steps"]["acceptance"] = {"state" => "passed", "attempts" => [{"n" => 1, "outcome" => "passed", "head" => {"before" => "h2"}, "started_at" => "2026-11-21T#{to}Z"}]}
    run["steps"]["verify"] = {"state" => "passed", "attempts" => [{"n" => 1, "outcome" => "failed"}, {"n" => 2, "outcome" => "passed"}]}
    run["steps"]["plan"]["attempts"].first["reviews"] = [{"reviewer" => "skeptic", "verdict" => "reject"}]
    write_json(File.join(state, ".workflows", "archive", "#{id}.json"), run)
    File.write(File.join(state, ".workflows", "archive", "#{id}.events.jsonl"), "")
    write_json(File.join(stubs, "trace-#{id}.json"), {"totals" => fixture["totals"].merge("machine_waiting_seconds" => {"waiting_lock" => lock, "retry_backoff" => 0}), "spans" => [{"kind" => "attempt", "step" => "implement", "attempt" => 1, "started_at" => "2026-11-21T#{from}Z", "ended_at" => "2026-11-21T#{to}Z", "tokens" => {"total" => 100}}]})
  end

  let(:workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      case "$*" in
        capabilities*) cat #{stubs}/caps.json ;;
        "work-queue history list"*ws-b*) cat #{stubs}/history-b.json ;;
        "work-queue history list"*) cat #{stubs}/history-a.json ;;
        "work-queue list"*ws-b*) cat #{stubs}/queue.json ;;
        "work-queue list"*) cat #{stubs}/queue.json ;;
        "workflow trace"*) cat #{stubs}/trace-$3.json ;;
        *) echo "unexpected: $@" >&2; exit 1 ;;
      esac
    SH
    File.chmod(0o755, path)
    path
  end

  let(:checks) do
    Class.new do
      attr_reader :acceptance_calls, :leak_args, :diff_args, :lint_head

      def acceptance(base_sha:, head:, goal:, dag: false)
        (@acceptance_calls ||= []) << {head: head, goal: goal, dag: dag}
        {passed: [goal], failed: [], regressions: []}
      end

      def lint(head:, gemfile:)
        @lint_head = head
        0
      end

      def leak_check(hook_files:, transcripts:, from:, to: nil, head: nil, removal: nil)
        @leak_args = {hook_files: hook_files.map { |path| File.basename(path) }, head: head}
        {hook: 0, transcript: {}}
      end

      def diff_scan(base_sha:, head:, since:)
        @diff_args = head
        {paths: [], copied: []}
      end
    end.new
  end

  let(:record) do
    {"stamp" => "20261121T050000Z", "branch" => "calc-demo/20261121T050000Z", "base_sha" => "b" * 40, "workspace" => {"sha" => "w" * 40, "version" => "1.0"},
     "acceptance_ref" => {"name" => "refs/demo-calc2/acceptance-base", "sha" => "a" * 40, "removal_sha" => "r" * 40},
     "goals" => %w[02-mul-div 03-div-zero], "items" => [{"workflow" => "deliver-goal-fast", "id" => "q1"}, {"workflow" => "deliver-goal-fast", "id" => "q2"}], "definitions" => {},
     "fork" => {"at" => "2026-11-21T05:12:20Z", "sha" => "f" * 40, "acceptance_base" => "a" * 40, "goal" => "03-div-zero", "item" => "q2"},
     "lanes" => {"workflow" => "deliver-goal-fast", "started_at" => "2026-11-21T05:00:00Z", "first_item_at" => "2026-11-21T05:00:00Z", "fork_after" => "03-div-zero", "a" => {"workspace" => "ws", "goals" => %w[02-mul-div 03-div-zero]},
                 "b" => {"workspace" => "ws-b", "branch" => "calc-demo/20261121T050000Z-b", "goals" => %w[06-json],
                         "items" => [{"workflow" => "deliver-goal-fast", "id" => "q3", "goal" => "06-json"}]}},
     "integration" => integration}
  end

  before do
    FileUtils.mkdir_p(stubs)
    archive("wr_a1", "05:00:00", "05:06:00")
    archive("wr_a2", "05:06:00", "05:12:00")
    archive("wr_b1", "05:12:30", "05:20:00", lock: 12)
    archive("wr_i", "05:21:00", "05:23:30")
    write_json(File.join(stubs, "caps.json"), {"paths" => {"hook_events" => File.join(state, ".events")}})
    write_json(File.join(stubs, "queue.json"), {"queues" => [{"workspace" => "ws", "items" => []}]})
    write_json(File.join(stubs, "history-a.json"), {"entries" => [{"id" => "q1", "result" => {"run_id" => "wr_a1"}}, {"id" => "q2", "result" => {"run_id" => "wr_a2"}}, {"id" => "qi", "result" => {"run_id" => "wr_i"}}]})
    write_json(File.join(stubs, "history-b.json"), {"entries" => [{"id" => "q3", "result" => {"run_id" => "wr_b1"}}]})
    write_json(File.join(run_dir, "run.json"), record)
  end

  def build(**options)
    described_class.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: File.join(PROJECT_ROOT, "demo", "pricing.yml"), run_dir: run_dir, checks: checks, err: StringIO.new, **options)
  end

  let(:result) { build.call }

  it "tells a lanes record from a plain one" do
    expect(DemoCalculator2::Evaluation.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: File.join(PROJECT_ROOT, "demo", "pricing.yml"), run_dir: run_dir, checks: checks, err: StringIO.new).lanes?).to be(true)
    write_json(File.join(run_dir, "run.json"), record.except("lanes"))
    expect(DemoCalculator2::Evaluation.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: File.join(PROJECT_ROOT, "demo", "pricing.yml"), run_dir: run_dir, checks: checks, err: StringIO.new).lanes?).to be(false)
  end

  it "reads both workspaces' items as rows tagged with their lane, lane A first" do
    expect(result[:rows].map { |row| row.values_at(:lane, :goal, :column, :item) }).to eq([["A", "02-mul-div", "A02", 1], ["A", "03-div-zero", "A03", 2], ["B", "06-json", "B06", 3]])
    expect(result[:rows].map { |row| row[:started_at] }).to eq(%w[2026-11-21T05:00:00Z 2026-11-21T05:06:00Z 2026-11-21T05:12:30Z])
  end

  it "checks each item's acceptance on the groups it depends on, and the integrated head on the plain 07 run" do
    result
    items = checks.acceptance_calls.select { |call| call[:dag] }
    expect(items.map { |call| call[:goal] }.uniq).to eq(%w[02-mul-div 03-div-zero 06-json])
    expect(checks.acceptance_calls.last).to eq(head: "i" * 40, goal: "07-repl", dag: false)
    expect(result[:lanes][:integration][:plain_acceptance]).to be(true)
  end

  it "lints, diff-scans and leak-scans the integrated branch, reading both workspaces' hook logs" do
    result
    expect(checks.lint_head).to eq("i" * 40)
    expect(checks.diff_args).to eq("i" * 40)
    expect(checks.leak_args).to eq(hook_files: %w[ws.jsonl ws.jsonl.1 ws-b.jsonl ws-b.jsonl.1], head: "i" * 40)
  end

  it "measures wall to the end of the integration and a critical path that adds up to it" do
    lanes = result[:lanes]
    expect(lanes[:wall]).to eq(24 * 60)
    expect(lanes[:critical_path]).to include(span: 12 * 60, fork_latency: 30, b_tail: 450, integration: 240, lane: "B")
    expect(lanes[:critical_path][:check]).to include(ok: true, delta: 0)
    expect(lanes[:sequential]).to eq(result[:rows].sum { |row| row[:wall] } + 240)
  end

  it "shows lane B's lock wait and flags it" do
    expect(result[:lanes][:lock_waits]).to eq("A" => {seconds: 0.0, flagged: false}, "B" => {seconds: 12.0, flagged: true})
  end

  it "reports the integration row: conflict, no first pass, and the integrate run's attempts" do
    expect(result[:lanes][:integration]).to include(merge: "conflict", conflict: true, first_pass: false, integrate_passed: true, integrate_attempts: 5)
  end

  it "counts verify fixes and review rejections per lane" do
    expect(result[:lanes][:catches]).to eq("A" => {verify_fixes: 2, review_rejections: 2}, "B" => {verify_fixes: 1, review_rejections: 1})
  end

  it "prints the lane-tagged table, the lane lines and the integrated lint, and writes the lanes into eval.json" do
    text = described_class.render(result)
    expect(text).to include("lanes: A ws, B ws-b, workflow deliver-goal-fast")
    expect(text).to match(/^A 02-mul-div\s/)
    expect(text).to match(/^B 06-json\s/)
    expect(text).to match(/^step wall\s+A02\s+A03\s+B06/)
    expect(text).to include("wall: 24m00s", "critical path: 01-03 12m00s + fork 30s + tail 7m30s + harness lag 0s (lane B;", "lock waits: A 0s, B 12s (nonzero", "integration: merge conflict, first pass no, conflict yes, integrate run attempts 5",
      "catches: lane A verify fixes 2, review rejections 2; lane B verify fixes 1, review rejections 1", "(the integrated branch)")
    expect(JSON.parse(File.read(File.join(run_dir, "eval.json"))).dig("lanes", "critical_path", "check", "ok")).to be(true)
  end

  it "reads a run with no fork yet and no integration without failing" do
    write_json(File.join(run_dir, "run.json"), record.except("fork", "integration").merge("lanes" => record["lanes"].merge("b" => record["lanes"]["b"].merge("items" => []))))
    expect(result[:rows].map { |row| row[:lane] }).to eq(%w[A A])
    expect(result[:lanes]).to include(wall: nil, critical_path: nil)
    expect(described_class.render(result)).to include("critical path: ?")
  end
end
