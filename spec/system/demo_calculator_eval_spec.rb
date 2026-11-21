require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"

load File.join(PROJECT_ROOT, "script", "demo-calculator")
load File.join(PROJECT_ROOT, "script", "demo_calculator", "compare.rb")

RSpec.describe DemoCalculator::Evaluation do
  let(:tmp) { Dir.mktmpdir }
  let(:state) { File.join(tmp, "state") }
  let(:run_dir) { File.join(tmp, "rundir") }
  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "demo_calculator", "runs") }
  let(:plain) { JSON.parse(File.read(File.join(fixtures, "plain_pass.json"))) }
  let(:missing) { JSON.parse(File.read(File.join(fixtures, "missing_usage.json"))) }
  let(:pricing_path) { File.join(PROJECT_ROOT, "demo", "pricing.yml") }
  let(:stubs) { File.join(tmp, "stubs") }

  after { FileUtils.rm_rf(tmp) }

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def write_run(sub, fixture)
    id = fixture["run"]["id"]
    write_json(File.join(state, ".workflows", sub, "#{id}.json"), fixture["run"])
    File.write(File.join(state, ".workflows", sub, "#{id}.events.jsonl"), fixture["events"].map { |e| JSON.generate(e) }.join("\n") + "\n")
    write_json(File.join(stubs, "trace-#{id}.json"), {"totals" => fixture["totals"]})
  end

  let(:workspace) do
    path = File.join(tmp, "fake-workspace")
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "capabilities" ]; then cat #{stubs}/caps.json
      elif [ "$1 $2 $3" = "work-queue history list" ]; then cat #{stubs}/history.json
      elif [ "$1 $2" = "work-queue list" ]; then cat #{stubs}/queue.json
      elif [ "$1 $2" = "workflow trace" ]; then cat #{stubs}/trace-$3.json
      else echo "unexpected: $@" >&2; exit 1; fi
    SH
    File.chmod(0o755, path)
    path
  end

  before do
    FileUtils.mkdir_p(stubs)
    write_json(File.join(stubs, "caps.json"), {"paths" => {"hook_events" => File.join(state, ".events")}})
    write_run("archive", plain)
    write_run("runs", missing)
    write_json(File.join(stubs, "history.json"), {"entries" => [{"id" => "q1", "result" => {"run_id" => plain["run"]["id"]}}]})
    write_json(File.join(stubs, "queue.json"), {"queues" => [{"workspace" => "ws", "items" => [{"id" => "q2", "run_id" => missing["run"]["id"]}]}]})
    write_json(File.join(run_dir, "run.json"), {
      "stamp" => "20261121T050000Z", "branch" => "calc-demo/20261121T050000Z", "base_sha" => "b" * 40,
      "workspace" => {"sha" => "w" * 40, "version" => "1.0"},
      "items" => [{"workflow" => "calc-01-add-sub", "id" => "q1"}, {"workflow" => "calc-02-mul-div", "id" => "q2"},
        {"workflow" => "calc-03-div-zero", "id" => "q3"}],
      "definitions" => {"calc-01-add-sub" => "x"}
    })
  end

  let(:checks) do
    Class.new do
      attr_reader :acceptance_calls, :transcripts

      def acceptance(base_sha:, head:, index:)
        (@acceptance_calls ||= []) << [head, index]
        raise DemoCalculator::EvalChecks::Error, "eval: no groups" if index == 2
        {passed: (1..index).to_a, failed: [], regressions: []}
      end

      def lint(head:, gemfile:) = 4

      def leak_check(hook_files:, transcripts:, from:, to: nil)
        @transcripts = transcripts
        {hook: 0, transcript: {}}
      end
    end.new
  end

  def evaluation(**options)
    described_class.new(root: PROJECT_ROOT, workspace: workspace, pricing_path: pricing_path, run_dir: run_dir,
      checks: checks, err: StringIO.new, **options)
  end

  it "maps items to runs, shows not run after the stop and ? and >= where data is missing" do
    result = evaluation.call
    text = described_class.render(result)
    lines = text.lines.map(&:chomp)
    expect(lines.grep(/\Acalc-03-div-zero\s+not run/)).not_to be_empty
    second = lines.find { |l| l.start_with?("calc-02-mul-div") }
    expect(second).to include("?")
    expect(lines.find { |l| l.start_with?("total") }).to include("≥")
    expect(text).to include("lint: 4 offenses")
    expect(result[:rows].map { |r| r[:ran] }).to eq([true, true, false])
  end

  it "writes eval.json with the keys Compare reads" do
    evaluation.call
    document = JSON.parse(File.read(File.join(run_dir, "eval.json")))
    expect(document.keys).to eq(%w[record header rows totals lint leak])
    expect(document["header"].keys).to eq(%w[model agent_version base_sha workspace_sha price_date])
    totals = document["totals"]
    expect(totals).to include("attempts", "retries", "review_rounds", "wall", "active", "stopped", "input", "output",
      "cache_creation", "cache_read", "cost_usd", "acceptance_passed", "lint", "partial")
    expect(totals["cost_usd"]).to be_a(Numeric)
    expect(totals["partial"]).to include("cost_usd")
    expect(totals["lint"]).to eq(4)
    expect(totals["acceptance_passed"]).to be_nil
    expect(document["rows"][2]["state"]).to eq("not run")
    expect(DemoCalculator::Compare.select([document], last: 1)).to eq([document])
  end

  it "scores acceptance per item at its own ending head and shows ? when the check raises" do
    result = evaluation.call
    expect(checks.acceptance_calls.map(&:last)).to eq([1, 2])
    expect(result[:rows][1][:acceptance]).to be_nil
  end

  it "scans the sessions of review rounds as well as of attempts for reads of the acceptance tests" do
    attempt = plain["run"]["steps"]["implement"]["attempts"].first
    attempt["session"] = {"transcript" => "/t/attempt.jsonl"}
    attempt["rounds"] = [{"round" => 1, "session" => nil}, {"round" => 1, "session" => {"transcript" => "/t/round.jsonl"}}]
    write_run("archive", plain)
    evaluation.call
    expect(checks.transcripts).to contain_exactly("/t/attempt.jsonl", "/t/round.jsonl")
  end

  it "reports acceptance over the groups checked in the total, and the manual count in each row" do
    result = evaluation.call
    expect(result[:totals]).to include("acceptance_of" => nil, "manual" => 0, "review_rounds_distinct" => 0)
    expect(JSON.parse(File.read(File.join(run_dir, "eval.json")))["rows"][0]).to include("manual" => 0)
  end

  it "reads the workspace asks store into the manual counts, and the person wait and run definition hash into eval.json" do
    write_json(File.join(state, "ws", "asks.json"), [
      {"id" => "a1", "status" => "answered", "asked_at" => "2026-11-21T05:05:00Z"},
      {"id" => "a2", "status" => "open", "asked_at" => "2026-11-21T05:06:00Z"}
    ])
    evaluation.call
    row = JSON.parse(File.read(File.join(run_dir, "eval.json")))["rows"][0]
    expect(row).to include("manual_asks" => 1, "manual_inputs" => 0, "manual_events" => 0, "manual" => 1)
    expect(row).to have_key("person_wait")
    expect(row).to have_key("definition_sha256")
  end

  it "scores without an asks store" do
    expect(evaluation.call[:rows][0]).to include(manual_asks: 0)
  end

  it "finds the newest record when no run dir is given" do
    newer = File.join(tmp, "root", "tmp", "demo-calculator", "runs", "20270101T000000Z")
    FileUtils.mkdir_p(newer)
    FileUtils.cp(File.join(run_dir, "run.json"), File.join(newer, "run.json"))
    FileUtils.mkdir_p(File.join(tmp, "root", "tmp", "demo-calculator", "runs", "20260101T000000Z"))
    File.write(File.join(tmp, "root", "tmp", "demo-calculator", "runs", "20260101T000000Z", "run.json"), "{}")
    described_class.new(root: File.join(tmp, "root"), workspace: workspace, pricing_path: pricing_path, checks: checks, err: StringIO.new).call
    expect(File.exist?(File.join(newer, "eval.json"))).to be(true)
  end

  it "refuses with a clear error when run.json has no items" do
    File.write(File.join(run_dir, "run.json"), JSON.generate("stamp" => "x"))
    expect { evaluation.call }.to raise_error(described_class::Error, /no items/)
  end

  it "refuses with a clear error when there is no record" do
    expect { described_class.new(root: tmp, workspace: workspace, pricing_path: pricing_path, checks: checks).call }
      .to raise_error(described_class::Error, /no run record/)
  end

  describe "the eval verb" do
    it "prints one parseable document with --json" do
      out = StringIO.new
      ENV["WORKSPACE_BIN"] = workspace
      status = DemoCalculator.main(["eval", "--run", run_dir, "--json"], out: out, err: StringIO.new)
      expect(status).to eq(0)
      document = JSON.parse(out.string)
      expect(document["rows"].size).to eq(3)
      expect(document["totals"]["acceptance_passed"]).to be_nil
      expect(File.exist?(File.join(run_dir, "eval.json"))).to be(true)
    ensure
      ENV.delete("WORKSPACE_BIN")
    end

    it "prints the table by default" do
      out = StringIO.new
      ENV["WORKSPACE_BIN"] = workspace
      DemoCalculator.main(["eval", "--run", run_dir], out: out, err: StringIO.new)
      expect(out.string).to include("not run").and include("Eval of 20261121T050000Z")
    ensure
      ENV.delete("WORKSPACE_BIN")
    end
  end
  describe "eval --compare" do
    let(:root) { File.join(tmp, "croot") }

    def write_eval(stamp, definitions: {"calc-01" => "d"}, attempts: 2)
      write_json(File.join(root, "tmp", "demo-calculator", "runs", stamp, "eval.json"), {
        "record" => {"stamp" => stamp, "branch" => "calc-demo/#{stamp}", "definitions" => definitions},
        "header" => {"model" => "m", "agent_version" => "1", "base_sha" => "b", "workspace_sha" => "w", "price_date" => "2026-11-01"},
        "totals" => {"attempts" => attempts, "partial" => []}
      })
    end

    def compare(*extra)
      out = StringIO.new
      status = DemoCalculator.main(["eval", "--compare", *extra], out: out, err: StringIO.new, root: root)
      [status, out.string]
    end

    it "prints one median table over three eval.json files and ignores run.json" do
      write_eval("20261121T010000Z", attempts: 1)
      write_eval("20261121T020000Z", attempts: 5)
      write_eval("20261121T030000Z", attempts: 3)
      write_json(File.join(root, "tmp", "demo-calculator", "runs", "20261121T040000Z", "run.json"), {"stamp" => "20261121T040000Z"})
      status, text = compare
      expect(status).to eq(0)
      expect(text).to include("Median [min–max] over 3 runs").and match(/attempts\s+3 \[1–5\]/)
    end

    it "lists the runs only with fewer than three matching, and --last limits the set" do
      write_eval("20261121T010000Z", definitions: {"calc-other" => "old"})
      write_eval("20261121T020000Z")
      write_eval("20261121T030000Z")
      _, text = compare
      expect(text).to include("Only 2 matching runs").and include("20261121T030000Z")
      expect(text).not_to include("20261121T010000Z")
      _, text = compare("--last", "1")
      expect(text).to include("Only 1 matching run ")
      _, text = compare("--last", "2")
      expect(text).to include("Median [min–max] over 2 runs")
    end

    it "compares runs whose definitions were edited between them and says which item differs" do
      write_eval("20261121T010000Z", definitions: {"calc-01" => "old"})
      write_eval("20261121T020000Z", definitions: {"calc-01" => "new"})
      _, text = compare("--last", "2")
      expect(text).to include("Median [min–max] over 2 runs", "definition calc-01: differs")
    end
  end
end
