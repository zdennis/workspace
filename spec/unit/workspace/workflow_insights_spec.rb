require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

RSpec.describe Workspace::WorkflowInsights do
  let(:dir) { Dir.mktmpdir("wf-insights") }
  let(:runs_dir) { File.join(dir, "runs") }
  let(:archive_dir) { File.join(dir, "archive") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir) }
  let(:counting) do
    Class.new(Workspace::WorkflowRunLoader) do
      def calls = (@calls ||= [])

      def resumes(run)
        calls << run.id
        super
      end
    end.new(store: store, clock: -> { Time.utc(2026, 11, 1, 12) })
  end
  let(:loader) { counting }
  let(:stats) { Workspace::WorkflowStats.new(store: store, loader: loader) }
  let(:compare) { Workspace::WorkflowCompare.new(loader: loader) }
  subject(:insights) { described_class.new(loader: loader, stats: stats, compare: compare) }

  after { FileUtils.rm_rf(dir) }

  def attempt(n, outcome, **rest)
    {"n" => n, "outcome" => outcome, "started_at" => "2026-10-30T09:00:00Z", "ended_at" => "2026-10-30T09:01:00Z"}.merge(rest)
  end

  def reject_round(reviewer: "skeptic", **row)
    {"reviews" => [{"reviewer" => reviewer, "verdict" => "reject", "path" => "/secret/path", "summary" => "SECRET PROSE", "counted" => true}.merge(row)]}
  end

  def put(id, attempts: [attempt(1, "passed")], state: "completed", created: nil, events: [], reasons: nil, step: "plan", workflow: "rpiv", extra: {})
    created ||= "2026-10-30T09:%02d:00Z" % (id[/\d+/].to_i % 60)
    run = {"id" => id, "workflow" => workflow, "workspace" => "app", "state" => state, "current" => step, "created_at" => created,
           "definition_sha256" => Digest::SHA256.hexdigest("d1"), "definition" => {"steps" => [{"id" => step}]},
           "steps" => {step => {"state" => "passed", "attempts" => attempts}}}
    run["reasons"] = reasons if reasons
    target = %w[completed cancelled failed].include?(state) ? archive_dir : runs_dir
    FileUtils.mkdir_p(target)
    File.write(File.join(target, "#{id}.json"), JSON.generate(run.merge(extra)))
    File.write(File.join(target, "#{id}.events.jsonl"), events.map { |each| JSON.generate(each) + "\n" }.join) unless events.empty?
  end

  def read(**args) = insights.read(workflow: "rpiv", **args)

  it "pins its constants" do
    expect([described_class::DEFAULT_RUNS, described_class::MIN_RUNS, described_class::THEME_MIN_RUNS, described_class::MAX_PACKS, described_class::MAX_CODE]).to eq([20, 3, 3, 5, 64])
    expect(described_class::HOLD_CODES).to eq(%w[budget_spent run_timed_out failed_check])
  end

  describe "run selection" do
    before { 1.upto(25) { |n| put("run-#{n}") } }

    it "reads the newest 20 by default and reports how many are stored" do
      result = read
      expect(result).to include("runs" => 20, "stored" => 25, "enough" => true)
    end

    it "narrows to the count asked for, newest first" do
      result = read(runs: 4)
      expect(result["runs"]).to eq(4)
      expect(result["effects"]["definition"]["groups"].first["run_ids"]).to eq(%w[run-25 run-24 run-23 run-22])
    end

    it "carries the compare warning, which a small sample always triggers" do
      expect(read["effects"]["definition"]["warning"]).to start_with("Too few runs")
    end
  end

  it "is not enough with fewer than 3 runs" do
    put("run-1")
    put("run-2")
    expect(read).to include("runs" => 2, "enough" => false)
    put("run-3")
    expect(read).to include("runs" => 3, "enough" => true)
  end

  it "counts an unknown workflow as no runs" do
    expect(read).to include("runs" => 0, "stored" => 0, "enough" => false, "hot_steps" => [], "themes" => [])
  end

  describe "review rejections" do
    def rejected_in(id, times, **row)
      put(id, attempts: (1..times).map { |n| attempt(n, "failed", "rounds" => [reject_round(**row)]) })
    end

    it "makes a theme of a key in exactly 3 distinct runs" do
      %w[run-1 run-2 run-3].each { |id| rejected_in(id, 1) }
      result = read
      expect(result["themes"].map { |row| row.slice("step", "reviewer", "verdict", "count") }).to eq([{"step" => "plan", "reviewer" => "skeptic", "verdict" => "reject", "count" => 3}])
      expect(result["themes"].first["run_ids"]).to eq(%w[run-3 run-2 run-1])
      expect(result["observations"]).to be_empty
    end

    it "keeps 2 distinct runs as an observation" do
      %w[run-1 run-2].each { |id| rejected_in(id, 1) }
      result = read
      expect(result["themes"]).to be_empty
      expect(result["observations"].first).to include("count" => 2, "run_ids" => %w[run-2 run-1])
    end

    it "treats 3 rejections in one run as one observation" do
      rejected_in("run-1", 3)
      result = read
      expect(result["themes"]).to be_empty
      expect(result["observations"].first).to include("count" => 3, "run_ids" => ["run-1"])
    end

    it "skips review rows that were not counted" do
      %w[run-1 run-2 run-3].each { |id| rejected_in(id, 1, "counted" => false) }
      result = read
      expect(result["themes"] + result["observations"]).to be_empty
    end

    it "counts reviewer problem codes under their own key" do
      %w[run-1 run-2 run-3].each { |id| rejected_in(id, 1, "counted" => false, "verdict" => nil, "problem" => "wrong_revision") }
      expect(read["themes"].map { |row| row.slice("reviewer", "verdict", "problem") }).to eq([{"reviewer" => "skeptic", "verdict" => nil, "problem" => "wrong_revision"}])
    end

    it "never carries reviewer paths or summaries" do
      %w[run-1 run-2 run-3].each { |id| rejected_in(id, 1) }
      json = JSON.generate(read)
      expect(json).not_to include("SECRET PROSE")
      expect(json).not_to include("/secret/path")
    end
  end

  describe "failures and holds" do
    it "tallies failed attempt codes by step with their runs" do
      put("run-1", attempts: [attempt(1, "failed", "code" => "check_failed"), attempt(2, "passed")])
      put("run-2", attempts: [attempt(1, "failed", "code" => "check_failed")])
      put("run-3", attempts: [attempt(1, "passed", "code" => "ignored")])
      expect(read["failures"]).to eq([{"step" => "plan", "code" => "check_failed", "count" => 2, "run_ids" => %w[run-2 run-1]}])
    end

    it "cuts a long code and keeps control characters raw as data" do
      code = "x" * 100
      put("run-1", attempts: [attempt(1, "failed", "code" => "\e[31m" + code)])
      result = read
      expect(result["failures"].first["code"]).to eq(("\e[31m" + code)[0, 64])
      expect(result["failures"].first["code"].length).to eq(64)
    end

    it "tallies hold reasons on attempts and on the run, ignoring other codes" do
      reasons = [{"code" => "budget_spent"}, {"code" => "retry_backoff"}]
      put("run-1", attempts: [attempt(1, "failed", "reasons" => reasons)], reasons: [{"code" => "run_timed_out", "step" => "plan"}, {"code" => "failed_check"}])
      put("run-2", attempts: [attempt(1, "failed", "reasons" => [{"code" => "budget_spent"}])])
      holds = read["holds"].to_h { |row| [row["code"], row.slice("step", "count", "run_ids")] }
      expect(holds).to eq("budget_spent" => {"step" => "plan", "count" => 2, "run_ids" => %w[run-2 run-1]},
        "run_timed_out" => {"step" => "plan", "count" => 1, "run_ids" => ["run-1"]})
    end
  end

  describe "hot steps" do
    it "lists the runs behind retries, resumes and tokens, and reads each run's events once" do
      usage = {"input_tokens" => 10, "output_tokens" => 5, "cache_creation_input_tokens" => 0}
      put("run-1", attempts: [attempt(1, "failed", "usage" => usage), attempt(2, "passed", "retry_of" => 1, "usage" => usage)],
        events: [{"type" => "run_resumed", "step" => "plan"}])
      put("run-2", attempts: [attempt(1, "passed", "usage" => usage)])
      put("run-3", attempts: [attempt(1, "passed")])
      row = read["hot_steps"].first
      expect(counting.calls).to eq(%w[run-3 run-2 run-1])
      expect(row).to include("step" => "plan", "resumes" => 1, "retry_run_ids" => ["run-1"], "resume_run_ids" => ["run-1"])
      expect(row["token_run_ids"]).to eq(%w[run-2 run-1])
    end

    it "ranks by retry runs when there are enough runs and keeps stats order otherwise" do
      def two_steps(id, retry_step)
        attempts = ->(step) { (step == retry_step) ? [attempt(1, "failed"), attempt(2, "passed")] : [attempt(1, "passed")] }
        put(id, extra: {"definition" => {"steps" => [{"id" => "plan"}, {"id" => "build"}]},
                        "steps" => {"plan" => {"attempts" => attempts.call("plan")}, "build" => {"attempts" => attempts.call("build")}}})
      end
      two_steps("run-1", "build")
      two_steps("run-2", "build")
      expect(read["hot_steps"].map { |row| row["step"] }).to eq(%w[plan build])
      two_steps("run-3", "plan")
      expect(read["hot_steps"].map { |row| row["step"] }).to eq(%w[build plan])
    end
  end

  describe "effects" do
    it "compares by definition and version, plus each pack seen up to the cap" do
      packs = (1..7).map { |n| {"ref" => "play/pack-#{n}", "sha256" => Digest::SHA256.hexdigest("p#{n}")} }
      put("run-1", attempts: [attempt(1, "passed", "packs" => packs)])
      put("run-2", attempts: [attempt(1, "passed", "packs" => packs.first(2))])
      effects = read["effects"]
      expect(effects.keys).to eq(%w[definition version pack:pack-1 pack:pack-2 pack:pack-3 pack:pack-4 pack:pack-5])
      expect(effects["pack:pack-1"]["groups"].first["run_ids"]).to eq(%w[run-2 run-1])
    end
  end

  describe "bad data" do
    it "reads an old-shape run with no rounds, reasons or usage" do
      put("run-1", attempts: [{"n" => 1}], extra: {"reasons" => nil})
      expect(read).to include("runs" => 1, "unreadable" => 0, "failures" => [], "holds" => [], "themes" => [])
    end

    it "counts a malformed run as unreadable and still reads the rest" do
      put("run-1")
      put("run-2", extra: {"steps" => {"plan" => {"attempts" => [1, {"n" => 1, "rounds" => "x", "reasons" => 5}]}}})
      put("run-3", extra: {"steps" => 5})
      result = read
      expect(result["runs"] + result["unreadable"]).to be >= 3
      expect(result["unreadable"]).to be >= 1
      expect(result["effects"]["definition"]["groups"].flat_map { |g| g["run_ids"] }).to include("run-1")
    end

    it "takes unreadable from stats, counting the whole store" do
      put("run-1")
      FileUtils.mkdir_p(runs_dir)
      File.write(File.join(runs_dir, "broken.json"), "{nope")
      expect(read).to include("runs" => 1, "stored" => 1, "unreadable" => 1)
    end

    it "counts a run stats rejects as unreadable and keeps it out of every id list" do
      put("run-1", attempts: [attempt(1, "failed", code: "boom"), attempt(2, "passed")], extra: {"definition" => "not a hash"},
        reasons: [{"step" => "plan", "code" => "failed_check"}])
      put("run-2")
      result = read
      expect(result).to include("runs" => 1, "unreadable" => 1)
      ids = [result["hot_steps"].flat_map { |r| r.values_at("retry_run_ids", "resume_run_ids", "token_run_ids") },
        result["failures"], result["holds"], result["themes"], result["observations"]].flatten
      expect(ids.grep(/run-1/)).to be_empty
      expect(result["effects"]["definition"]["groups"].flat_map { |g| g["run_ids"] }).not_to include("run-1")
    end
  end

  it "keeps a step id longer than the code limit whole, so a failures row joins its hot_steps row" do
    id = "s" * 80
    put("run-1", step: id, attempts: [attempt(1, "failed", code: "boom"), attempt(2, "passed")])
    result = read
    expect(result["failures"].map { |r| r["step"] }).to eq([id])
    expect(result["hot_steps"].map { |r| r["step"] }).to include(id)
  end

  it "leaves the filesystem as it was" do
    %w[run-1 run-2 run-3].each { |id| put(id, events: [{"type" => "run_resumed", "step" => "plan"}]) }
    snapshot = -> { Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.to_h { |path| [path, File.exist?(path) ? File.mtime(path) : nil] } }
    before = snapshot.call
    read
    expect(snapshot.call).to eq(before)
  end
end
