require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Workspace::WorkflowStats do
  let(:now) { Time.utc(2026, 11, 1, 12, 0, 0) }
  let(:dir) { Dir.mktmpdir("wf-stats") }
  let(:runs_dir) { File.join(dir, "runs") }
  let(:archive_dir) { File.join(dir, "archive") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir) }
  subject(:stats) { described_class.new(store: store, clock: -> { now }) }

  after { FileUtils.rm_rf(dir) }

  def attempt(n, outcome, seconds: 60, usage: {"input_tokens" => 100, "output_tokens" => 50, "cache_creation_input_tokens" => 10, "cache_read_input_tokens" => 99_999}, **rest)
    started = Time.utc(2026, 10, 30, 9, 0, 0) + n * 1000
    {"n" => n, "outcome" => outcome, "started_at" => started.iso8601, "ended_at" => (started + seconds).iso8601, "usage" => usage}.merge(rest)
  end

  def put(id, steps:, created: "2026-10-30T09:00:00Z", archived: false, workflow: "rpiv", workspace: "app", events: [], order: steps.keys, extra: {})
    run = {"id" => id, "workflow" => workflow, "workspace" => workspace, "state" => archived ? "completed" : "running", "current" => order.first,
           "created_at" => created, "definition" => {"steps" => order.map { |each| {"id" => each} }},
           "steps" => steps.transform_values { |attempts| {"state" => "passed", "attempts" => attempts} }}.merge(extra)
    target = archived ? archive_dir : runs_dir
    FileUtils.mkdir_p(target)
    File.write(File.join(target, "#{id}.json"), JSON.generate(run))
    File.write(File.join(target, "#{id}.events.jsonl"), events.map { |each| JSON.generate(each) + "\n" }.join) unless events.empty?
  end

  def row(result, step) = result["steps"].find { |each| each["step"] == step }

  it "counts passed and failed attempts, the median time and the token mean" do
    put("wr_1", archived: true, steps: {"plan" => [attempt(1, "failed", seconds: 600), attempt(2, "passed", seconds: 120)]})
    put("wr_2", steps: {"plan" => [attempt(1, "passed", seconds: 300)]})

    plan = row(stats.read(workflow: "rpiv"), "plan")

    expect(plan).to include("attempts" => 3, "passed" => 2, "failed" => 1, "not_delivered" => 0, "unfinished" => 0, "median_seconds" => 300)
    expect(plan["tokens"]).to eq("mean" => 240, "runs_counted" => 2, "runs_uncounted" => 0)
  end

  it "takes the middle of two middle times for an even count" do
    put("wr_1", steps: {"plan" => [attempt(1, "passed", seconds: 100), attempt(2, "passed", seconds: 200)]})
    expect(row(stats.read(workflow: "rpiv"), "plan")["median_seconds"]).to eq(150)
  end

  it "never counts cache reads, and sums a step's attempts per run" do
    put("wr_1", steps: {"plan" => [attempt(1, "failed"), attempt(2, "passed")]})
    expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]["mean"]).to eq(320)
  end

  describe "an attempt that did no work" do
    it "keeps a not_delivered one and a redelivered one out of the pass counts, median and tokens" do
      put("wr_1", steps: {"plan" => [attempt(1, "not_delivered", usage: nil), attempt(2, "failed", redelivered: true, usage: nil, seconds: 5000), attempt(3, "passed", seconds: 60)]})

      plan = row(stats.read(workflow: "rpiv"), "plan")

      expect(plan).to include("attempts" => 1, "passed" => 1, "failed" => 0, "not_delivered" => 2, "median_seconds" => 60)
      expect(plan["tokens"]).to include("mean" => 160, "runs_uncounted" => 0)
    end

    it "lists an attempt with no outcome as unfinished and leaves it out of everything else" do
      put("wr_1", steps: {"plan" => [attempt(1, nil, usage: nil), attempt(2, "interrupted")]})
      expect(row(stats.read(workflow: "rpiv"), "plan")).to include("attempts" => 0, "unfinished" => 2, "median_seconds" => nil)
    end
  end

  describe "tokens" do
    it "reports a run with a null usage as uncounted, not as zero" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed", usage: nil)]})
      put("wr_2", steps: {"plan" => [attempt(1, "passed")]})

      expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]).to eq("mean" => 160, "runs_counted" => 1, "runs_uncounted" => 1)
    end

    it "gives no mean when no run has a count" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed", usage: nil)]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]).to eq("mean" => nil, "runs_counted" => 0, "runs_uncounted" => 1)
    end

    it "makes a run uncounted when any one of its attempts has no usage" do
      put("wr_1", steps: {"plan" => [attempt(1, "failed", usage: nil), attempt(2, "passed")]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]).to include("mean" => nil, "runs_uncounted" => 1)
    end

    it "counts the tokens of an attempt a cancel or resume --from ended without an outcome, as the budget does" do
      put("wr_1", steps: {"plan" => [attempt(1, nil, usage: {"input_tokens" => 50_000}), attempt(2, "passed")]})

      plan = row(stats.read(workflow: "rpiv"), "plan")

      expect(plan).to include("attempts" => 1, "unfinished" => 1, "median_seconds" => 60)
      expect(plan["tokens"]).to eq("mean" => 50_160, "runs_counted" => 1, "runs_uncounted" => 0)
      run = JSON.parse(File.read(File.join(runs_dir, "wr_1.json")))
      expect(Workspace::WorkflowBudget.reading(run.merge("definition" => run["definition"].merge("budget" => {"tokens" => 1_000_000}), "state" => "cancelled"))["used"]).to eq(50_160)
    end

    it "leaves out the attempt still going in a run that is going" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed"), attempt(2, nil, usage: nil)]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]).to eq("mean" => 160, "runs_counted" => 1, "runs_uncounted" => 0)
    end

    it "treats a usage of the wrong shape as uncounted" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed", usage: {"input_tokens" => "many"})]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["tokens"]["runs_uncounted"]).to eq(1)
    end
  end

  describe "resumes" do
    it "counts each run_resumed on the step it names, a --from step first" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")], "implement" => [attempt(1, "passed")]}, events: [
        {"ts" => "2026-10-30T10:00:00Z", "type" => "run_started"},
        {"type" => "run_resumed", "step" => "plan", "state" => "failed"},
        {"type" => "run_resumed", "from" => "implement"},
        {"type" => "run_resumed", "step" => "implement", "budget" => "released"},
        {"type" => "step_started", "step" => "plan"}
      ])

      result = stats.read(workflow: "rpiv")

      expect(row(result, "plan")["resumes"]).to eq(1)
      expect(row(result, "implement")["resumes"]).to eq(2)
    end

    it "counts a resume that names both from and step on from" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")], "implement" => [attempt(1, "passed")]}, events: [{"type" => "run_resumed", "from" => "implement", "step" => "plan"}])
      result = stats.read(workflow: "rpiv")
      expect(row(result, "implement")["resumes"]).to eq(1)
      expect(row(result, "plan")["resumes"]).to eq(0)
    end

    it "keeps a resume that names no step apart" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")]}, events: [{"type" => "run_resumed"}])
      result = stats.read(workflow: "rpiv")
      expect(result["unattributed_resumes"]).to eq(1)
      expect(row(result, "plan")["resumes"]).to eq(0)
    end

    it "reads a run with no history file as no resumes" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["resumes"]).to eq(0)
    end

    it "reads past the first page of a long history" do
      events = Array.new(1200) { {"type" => "run_resumed", "step" => "plan"} }
      put("wr_1", steps: {"plan" => [attempt(1, "passed")]}, events: events)
      expect(row(stats.read(workflow: "rpiv"), "plan")["resumes"]).to eq(1200)
    end
  end

  describe "which runs" do
    it "keeps to the workflow asked for, and answers plainly when none ran" do
      put("wr_1", workflow: "other", steps: {"plan" => [attempt(1, "passed")]})
      expect(stats.read(workflow: "rpiv")).to eq("runs" => 0, "unreadable" => 0, "undated" => 0, "steps" => [], "unattributed_resumes" => 0)
    end

    it "reads archived runs of a definition that has since been deleted" do
      put("wr_1", archived: true, steps: {"plan" => [attempt(1, "passed")]}, workflow: "gone")
      expect(row(stats.read(workflow: "gone"), "plan")["passed"]).to eq(1)
    end

    it "reads a run found in both directories once, from the runs directory" do
      put("wr_1", steps: {"plan" => [attempt(1, "failed")]})
      put("wr_1", archived: true, steps: {"plan" => [attempt(1, "passed")]})

      result = stats.read(workflow: "rpiv")

      expect(result["runs"]).to eq(1)
      expect(row(result, "plan")).to include("failed" => 1, "passed" => 0)
    end

    it "narrows with the include callable" do
      put("wr_1", workspace: "app", steps: {"plan" => [attempt(1, "passed")]})
      put("wr_2", workspace: "lib", steps: {"plan" => [attempt(1, "failed")]})
      result = stats.read(workflow: "rpiv", include: ->(run) { run["workspace"] == "lib" })
      expect(row(result, "plan")).to include("passed" => 0, "failed" => 1)
    end

    describe "--last" do
      before do
        put("wr_in", created: (now - 3600).iso8601, steps: {"plan" => [attempt(1, "passed")]})
        put("wr_edge", created: (now - 3600 - 1).iso8601, steps: {"plan" => [attempt(1, "failed")]})
        put("wr_out", created: (now - 3600 - 2).iso8601, steps: {"plan" => [attempt(1, "failed")]})
      end

      it "includes a run that started exactly at the cutoff and excludes one just before" do
        result = stats.read(workflow: "rpiv", last: 3601)
        expect(result["runs"]).to eq(2)
        expect(row(result, "plan")).to include("passed" => 1, "failed" => 1)
      end

      it "reads every run with no window" do
        expect(stats.read(workflow: "rpiv")["runs"]).to eq(3)
      end

      it "counts a run with no usable start time as undated and leaves it out" do
        put("wr_undated", created: "yesterday-ish", steps: {"plan" => [attempt(1, "passed")]})
        result = stats.read(workflow: "rpiv", last: 7200)
        expect(result).to include("runs" => 3, "undated" => 1)
      end
    end
  end

  describe "step order" do
    it "follows the newest run's definition, then steps only older runs had" do
      put("wr_old", created: "2026-10-01T00:00:00Z", steps: {"research" => [attempt(1, "passed")], "plan" => [attempt(1, "passed")], "legacy" => [attempt(1, "passed")]}, order: %w[research plan legacy])
      put("wr_new", created: "2026-10-30T00:00:00Z", steps: {"plan" => [attempt(1, "passed")], "implement" => [], "research" => [attempt(1, "passed")]}, order: %w[plan implement research])

      expect(stats.read(workflow: "rpiv")["steps"].map { |each| each["step"] }).to eq(%w[plan implement research legacy])
    end

    it "merges a step across definition versions by id" do
      put("wr_old", created: "2026-10-01T00:00:00Z", steps: {"plan" => [attempt(1, "passed")]})
      put("wr_new", created: "2026-10-30T00:00:00Z", steps: {"plan" => [attempt(1, "passed")]})
      expect(stats.read(workflow: "rpiv")["steps"].size).to eq(1)
    end
  end

  describe "run files that are not whole" do
    it "counts an unreadable file in the runs directory and in the archive" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")]})
      File.write(File.join(runs_dir, "wr_bad.json"), "{not json")
      FileUtils.mkdir_p(archive_dir)
      File.write(File.join(archive_dir, "wr_worse.json"), "[]")

      result = stats.read(workflow: "rpiv")

      expect(result["unreadable"]).to eq(2)
      expect(row(result, "plan")["passed"]).to eq(1)
    end

    it "does not raise on a run from before attempts recorded times, outcomes or usage" do
      put("wr_old", steps: {"plan" => [{"n" => 1}, {"n" => 2, "outcome" => "passed"}]})
      plan = row(stats.read(workflow: "rpiv"), "plan")
      expect(plan).to include("attempts" => 1, "passed" => 1, "unfinished" => 1, "median_seconds" => nil)
      expect(plan["tokens"]["runs_uncounted"]).to eq(1)
    end

    it "ignores a time that is not a time, or that runs backwards" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed", started_at: "soon"), attempt(2, "passed", started_at: "2026-10-30T10:00:00Z", ended_at: "2026-10-30T09:00:00Z"), attempt(3, "passed", seconds: 30)]})
      expect(row(stats.read(workflow: "rpiv"), "plan")["median_seconds"]).to eq(30)
    end

    it "goes on past a recorded step whose state is not a hash" do
      put("wr_1", steps: {"plan" => [attempt(1, "passed")]})
      path = File.join(runs_dir, "wr_1.json")
      run = JSON.parse(File.read(path))
      run["steps"]["odd"] = "text"
      File.write(path, JSON.generate(run))

      result = stats.read(workflow: "rpiv")

      expect(row(result, "plan")["passed"]).to eq(1)
      expect(row(result, "odd")).to include("attempts" => 0)
    end
  end
  describe "runs whose content the store accepted but the reader cannot use" do
    let(:fake_store) do
      Class.new do
        attr_reader :runs

        def initialize(runs, error: nil)
          @runs = runs
          @error = error
        end

        def active = @runs

        def archived = []

        def unreadable(archived: false) = []

        def events(_id, since: 0, limit: 1000)
          raise @error if @error
          {"events" => [], "truncated" => false, "next_since" => since, "warnings" => []}
        end
      end
    end

    def good(id) = {"id" => id, "workflow" => "rpiv", "created_at" => "2026-10-30T09:00:00Z", "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"attempts" => [{"n" => 1, "outcome" => "passed"}]}}}

    it "counts a run whose definition is a String as unreadable, and goes on" do
      runs = [good("wr_1"), good("wr_2").merge("definition" => "text")]
      result = described_class.new(store: fake_store.new(runs), clock: -> { now }).read(workflow: "rpiv")
      expect(result).to include("runs" => 1, "unreadable" => 1)
      expect(row(result, "plan")["passed"]).to eq(1)
    end

    it "reads a run with steps as an Array, a step without attempts, or no definition, without raising" do
      runs = [good("wr_1").merge("steps" => []), good("wr_2").merge("steps" => {"plan" => {}}), good("wr_3").except("definition")]
      result = described_class.new(store: fake_store.new(runs), clock: -> { now }).read(workflow: "rpiv")
      expect(result).to include("runs" => 3, "unreadable" => 0)
    end

    it "counts a run whose history cannot be read as unreadable" do
      error = Workspace::Error.new("no access", code: "store_unavailable")
      result = described_class.new(store: fake_store.new([good("wr_1")], error: error), clock: -> { now }).read(workflow: "rpiv")
      expect(result).to include("runs" => 0, "unreadable" => 1)
    end
  end
end
