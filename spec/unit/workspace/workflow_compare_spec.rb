require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

RSpec.describe Workspace::WorkflowCompare do
  let(:dir) { Dir.mktmpdir("wf-compare") }
  let(:runs_dir) { File.join(dir, "runs") }
  let(:archive_dir) { File.join(dir, "archive") }
  let(:store) { Workspace::WorkflowRunStore.new(dir: runs_dir, archive_dir: archive_dir) }
  let(:loader) { Workspace::WorkflowRunLoader.new(store: store, clock: -> { Time.utc(2026, 11, 1, 12) }) }
  subject(:compare) { described_class.new(loader: loader) }

  after { FileUtils.rm_rf(dir) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def attempt(n, outcome, packs: nil, **rest)
    {"n" => n, "outcome" => outcome, "started_at" => "2026-10-30T09:00:00Z", "ended_at" => "2026-10-30T09:01:00Z"}.merge(packs ? {"packs" => packs} : {}).merge(rest)
  end

  def pack(name, text) = {"ref" => "play/#{name}", "sha256" => sha(text)}

  def put(id, attempts:, state: "completed", definition: sha("d1"), events: [], created: "2026-10-30T09:00:00Z", workflow: "rpiv", reason: nil)
    run = {"id" => id, "workflow" => workflow, "workspace" => "app", "state" => state, "current" => "plan", "created_at" => created,
           "definition" => {"steps" => [{"id" => "plan"}]}, "steps" => {"plan" => {"state" => "passed", "attempts" => attempts}}}
    run["definition_sha256"] = definition if definition
    run["reason"] = {"code" => reason} if reason
    target = %w[completed cancelled failed].include?(state) ? archive_dir : runs_dir
    FileUtils.mkdir_p(target)
    File.write(File.join(target, "#{id}.json"), JSON.generate(run))
    File.write(File.join(target, "#{id}.events.jsonl"), events.map { |each| JSON.generate(each) + "\n" }.join) unless events.empty?
  end

  def read(by: "definition", **args) = compare.read(workflow: "rpiv", by: by, **args)

  def group(result, key) = result["groups"].find { |each| each["sha"] == key }

  describe "--by definition" do
    it "groups runs by their definition sha with first-try share and resumes per run" do
      put("wr_1", attempts: [attempt(1, "passed")])
      put("wr_2", attempts: [attempt(1, "failed"), attempt(2, "passed")], events: [{"type" => "run_resumed", "step" => "plan"}, {"type" => "run_resumed"}])
      put("wr_3", attempts: [attempt(1, "passed")], definition: sha("d2"))

      result = read

      expect(group(result, sha("d1"))).to include("runs" => 2, "settled" => 2, "first_try" => 1, "pass_first_percent" => 50, "resumes" => 2, "resumes_per_run" => 1.0)
      expect(group(result, sha("d2"))).to include("runs" => 1, "pass_first_percent" => 100, "resumes_per_run" => 0.0)
      expect(result).to include("runs" => 3, "matched" => 3, "unreadable" => 0)
    end

    it "puts a run stored without a definition hash in the unknown group, last, never drops it" do
      put("wr_old", attempts: [attempt(1, "passed")], definition: nil)
      put("wr_1", attempts: [attempt(1, "passed")])

      result = read

      expect(result["groups"].map { |each| each["sha"] }).to eq([sha("d1"), "unknown"])
    end

    it "reads the hash from the attempts when the run has none, and calls disagreeing attempts mixed" do
      put("wr_1", attempts: [attempt(1, "passed", "definition_sha256" => sha("a"))], definition: nil)
      put("wr_2", attempts: [attempt(1, "failed", "definition_sha256" => sha("a")), attempt(2, "passed", "definition_sha256" => sha("b"))], definition: nil)

      expect(read["groups"].map { |each| [each["sha"], each["runs"]] }).to eq([[sha("a"), 1], ["mixed", 1]])
    end

    it "treats a stored value that is no sha as unknown" do
      put("wr_1", attempts: [attempt(1, "passed")], definition: "\e[31mevil")
      expect(read["groups"].map { |each| each["sha"] }).to eq(["unknown"])
    end
  end

  describe "PASS-1ST" do
    it "counts a completed run whose steps each passed once as a first try" do
      put("wr_1", attempts: [attempt(1, "passed")])
      put("wr_2", attempts: [])
      expect(group(read, sha("d1"))).to include("settled" => 2, "first_try" => 2, "pass_first_percent" => 100)
    end

    it "is null when nothing settled" do
      put("wr_1", attempts: [attempt(1, nil)], state: "running")
      expect(group(read, sha("d1"))).to include("pass_first_percent" => nil, "running" => 1)
    end

    it "does not count an attempt that never reached the agent as a miss" do
      put("wr_1", attempts: [attempt(1, "not_delivered"), attempt(2, "failed", "redelivered" => true), attempt(3, "passed")])
      expect(group(read, sha("d1"))["pass_first_percent"]).to eq(100)
    end

    it "counts a gate rejected then passed as a miss: the rejected attempt stays passed and a second one runs" do
      put("wr_1", attempts: [attempt(1, "passed"), attempt(2, "passed")])
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 2, "first_try" => 1, "pass_first_percent" => 50)
    end

    it "counts a `resume --from` rerun as a miss" do
      put("wr_1", attempts: [attempt(1, "passed"), attempt(2, nil), attempt(3, "passed")])
      expect(group(read, sha("d1"))["pass_first_percent"]).to eq(0)
    end

    it "counts a failed step that later passed as a miss" do
      put("wr_1", attempts: [attempt(1, "failed"), attempt(2, "passed")])
      expect(group(read, sha("d1"))["pass_first_percent"]).to eq(0)
    end

    it "settles a run cancelled after a failure as a miss" do
      put("wr_1", attempts: [attempt(1, "failed")], state: "cancelled")
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 2, "first_try" => 1, "pass_first_percent" => 50, "cancelled" => 0)
    end

    it "leaves a run cancelled with an attempt closed as cancelled out, like old data with no outcome" do
      put("wr_1", attempts: [attempt(1, "cancelled")], state: "cancelled")
      put("wr_2", attempts: [attempt(1, nil)], state: "cancelled")
      put("wr_3", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 1, "pass_first_percent" => 100, "cancelled" => 2)
    end

    it "does not count an interrupted attempt as a miss, in a run cancelled or completed on its retry" do
      put("wr_1", attempts: [attempt(1, "interrupted")], state: "cancelled")
      put("wr_2", attempts: [attempt(1, "interrupted"), attempt(2, "passed", retry_of: 1)])
      expect(group(read, sha("d1"))).to include("settled" => 1, "first_try" => 1, "pass_first_percent" => 100, "cancelled" => 1)
    end

    it "leaves a clean cancelled run out" do
      put("wr_1", attempts: [attempt(1, nil)], state: "cancelled")
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 1, "pass_first_percent" => 100, "cancelled" => 1)
    end

    it "does not let nine cancelled-after-failure runs and one clean run read as 100%" do
      9.times { |i| put("wr_f#{i}", attempts: [attempt(1, "failed")], state: "cancelled") }
      put("wr_ok", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))["pass_first_percent"]).to eq(10)
    end

    it "counts a run waiting on failed_check or budget_spent as a miss while it waits" do
      put("wr_1", attempts: [attempt(1, "failed")], state: "waiting", reason: "failed_check")
      put("wr_2", attempts: [attempt(1, "passed"), attempt(2, "passed")], state: "waiting", reason: "budget_spent")
      put("wr_3", attempts: [attempt(1, "passed")])

      expect(group(read, sha("d1"))).to include("runs" => 3, "settled" => 3, "stuck" => 2, "first_try" => 1, "running" => 0)
    end

    it "counts a run held by its timeout as stuck after a miss" do
      put("wr_1", attempts: [attempt(1, "failed")], state: "waiting", reason: "run_timed_out")

      expect(group(read, sha("d1"))).to include("settled" => 1, "stuck" => 1)
    end

    it "leaves out a run that waits for any other reason, or waits without a miss" do
      put("wr_1", attempts: [attempt(1, "failed")], state: "waiting", reason: "retry_backoff")
      put("wr_2", attempts: [attempt(1, "passed")], state: "waiting", reason: "failed_check")
      put("wr_3", attempts: [attempt(1, nil)], state: "running")
      put("wr_4", attempts: [attempt(1, "passed")])

      expect(group(read, sha("d1"))).to include("settled" => 1, "stuck" => 0, "running" => 3)
    end

    it "counts a completed run with a delivered attempt that has no outcome as a miss (resume --from passed it over)" do
      put("wr_1", attempts: [attempt(1, nil)])
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 2, "first_try" => 1, "pass_first_percent" => 50)
    end

    it "settles a run that completed through an override but does not count it as a first try" do
      put("wr_1", attempts: [attempt(1, "overridden")])
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 2, "first_try" => 1, "pass_first_percent" => 50)
    end

    it "leaves a run waiting on a person out of both settled and stuck, even with a miss" do
      put("wr_1", attempts: [attempt(1, "passed"), attempt(2, nil)], state: "running", reason: "waiting_you")
      expect(group(read, sha("d1"))).to include("settled" => 0, "stuck" => 0, "running" => 1)
    end

    it "counts a single attempt with an outcome other than passed as a miss" do
      put("wr_1", attempts: [attempt(1, "abandoned")])
      expect(group(read, sha("d1"))).to include("first_try" => 0, "pass_first_percent" => 0)
    end

    it "reads an old run stored with state failed as still going, not as a failure" do
      put("wr_1", attempts: [attempt(1, "failed")], state: "failed")
      put("wr_2", attempts: [attempt(1, "passed")])
      expect(group(read, sha("d1"))).to include("settled" => 1, "pass_first_percent" => 100)
    end
  end

  describe "the settled boundary" do
    def runs_of(sha_text, count, prefix)
      count.times { |i| put("wr_#{prefix}#{i}", attempts: [attempt(1, "passed")], definition: sha(sha_text)) }
    end

    it "keeps the clause at 19 settled runs and drops it at 20 and 21" do
      runs_of("a", 19, "a")
      runs_of("b", 21, "b")
      expect(read["warning"]).to start_with("Too few runs")

      put("wr_extra", attempts: [attempt(1, "passed")], definition: sha("a"))
      expect(read["warning"]).to start_with("Tasks also differ")

      put("wr_extra2", attempts: [attempt(1, "passed")], definition: sha("a"))
      expect(read["warning"]).to start_with("Tasks also differ")
    end

    it "counts settled runs, not runs: 20 runs with 5 still going keeps the clause" do
      runs_of("a", 30, "a")
      runs_of("b", 15, "b")
      5.times { |i| put("wr_run#{i}", attempts: [attempt(1, nil)], state: "running", definition: sha("b")) }
      expect(read["warning"]).to start_with("Too few runs")
    end

    it "keeps the clause when any one group is under the threshold" do
      runs_of("a", 25, "a")
      runs_of("b", 3, "b")
      expect(read["warning"]).to start_with("Too few runs")
    end

    it "sorts mixed last even when it has the most runs" do
      put("wr_1", attempts: [attempt(1, "passed", "definition_sha256" => sha("x")), attempt(2, "passed", "definition_sha256" => sha("y"))], definition: nil)
      put("wr_2", attempts: [attempt(1, "passed", "definition_sha256" => sha("x")), attempt(2, "passed", "definition_sha256" => sha("y"))], definition: nil)
      put("wr_3", attempts: [attempt(1, "passed")])

      expect(read["groups"].map { |each| each["sha"] }).to eq([sha("d1"), "mixed"])
    end

    it "reads attempts that agree on a sha, with no run-level sha, as that sha and not mixed" do
      put("wr_1", attempts: [attempt(1, "failed", "definition_sha256" => sha("x")), attempt(2, "passed", "definition_sha256" => sha("x"))], definition: nil)
      expect(read["groups"].map { |each| each["sha"] }).to eq([sha("x")])
    end
  end

  describe "--by pack:NAME" do
    it "groups by the pack text the delivered attempts were sent" do
      put("wr_1", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v1"), pack("notes", "n")])])
      put("wr_2", attempts: [attempt(1, "failed", packs: [pack("plan-review", "v1")])], state: "cancelled")
      put("wr_3", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v2")])])

      result = read(by: "pack:plan-review")

      expect(result["groups"].map { |each| [each["sha"], each["runs"]] }).to eq([[sha("v1"), 2], [sha("v2"), 1]])
      expect(group(result, sha("v1"))["pass_first_percent"]).to eq(50)
    end

    it "matches the full ref too" do
      put("wr_1", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v1")])])
      expect(read(by: "pack:play/plan-review")["matched"]).to eq(1)
    end

    it "puts a run whose pack text changed between attempts in mixed, under neither sha" do
      put("wr_1", attempts: [attempt(1, "failed", packs: [pack("plan-review", "v1")]), attempt(2, "passed", packs: [pack("plan-review", "v2")])])

      expect(read(by: "pack:plan-review")["groups"].map { |each| [each["sha"], each["runs"]] }).to eq([["mixed", 1]])
    end

    it "puts an old run with no packs recorded, or a pack with no hash, in unknown" do
      put("wr_old", attempts: [attempt(1, "passed")])
      put("wr_nohash", attempts: [attempt(1, "passed", packs: [{"ref" => "play/plan-review"}])])

      expect(read(by: "pack:plan-review")["groups"]).to contain_exactly(a_hash_including("sha" => "unknown", "runs" => 2))
    end

    it "counts a run that did not use the pack, and a run with no delivered attempt, apart" do
      put("wr_1", attempts: [attempt(1, "passed", packs: [pack("notes", "n")])])
      put("wr_2", attempts: [attempt(1, "not_delivered", packs: [pack("plan-review", "v1")])])
      put("wr_3", attempts: [])
      put("wr_4", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v1")])])

      result = read(by: "pack:plan-review")

      expect(result).to include("runs" => 4, "matched" => 1, "without_pack" => 1, "no_attempts" => 2)
    end

    it "gives no groups, not an error, for a pack no run used" do
      put("wr_1", attempts: [attempt(1, "passed", packs: [pack("notes", "n")])])

      result = read(by: "pack:nope")

      expect(result).to include("groups" => [], "matched" => 0, "without_pack" => 1)
      expect(result["warning"]).to start_with("Too few runs")
    end
  end

  describe "the warning" do
    it "is always present and says the sample is too small for a few runs" do
      put("wr_1", attempts: [attempt(1, "passed")])
      expect(read["warning"]).to eq("Too few runs to call this a difference; tasks also differ between runs, so this shows a direction and does not prove a cause.")
    end

    it "drops only the first clause once every group has enough settled runs" do
      30.times { |i| put("wr_a#{i}", attempts: [attempt(1, "passed")]) }
      30.times { |i| put("wr_b#{i}", attempts: [attempt(1, "passed")], definition: sha("d2")) }

      expect(read["warning"]).to eq("Tasks also differ between runs, so this shows a direction and does not prove a cause.")
    end

    it "stays small with one group however many runs" do
      30.times { |i| put("wr_a#{i}", attempts: [attempt(1, "passed")]) }
      expect(read["warning"]).to start_with("Too few runs")
    end
  end

  describe "--by version" do
    def put_versioned(id, version, **rest)
      put(id, attempts: [attempt(1, "passed")], **rest)
      file = File.join(archive_dir, "#{id}.json")
      run = JSON.parse(File.read(file))
      run["definition"]["version"] = version unless version.nil?
      File.write(file, JSON.generate(run))
    end

    it "groups runs by the stored definition's version and keeps sha equal to key" do
      put_versioned("wr_1", 2)
      put_versioned("wr_2", 2, definition: sha("other"))
      put_versioned("wr_3", 3)

      result = read(by: "version")

      expect(result["by"]).to eq("version")
      expect(result["groups"].map { |each| [each["key"], each["sha"], each["runs"]] }).to eq([["2", "2", 2], ["3", "3", 1]])
    end

    it "puts a run whose definition has no version, or a bad one, in unknown, last" do
      put_versioned("wr_old", nil)
      put_versioned("wr_bad", "7")
      put_versioned("wr_1", 1)

      result = read(by: "version")

      expect(result["groups"].map { |each| each["key"] }).to eq(%w[1 unknown])
      expect(result["groups"].last["runs"]).to eq(2)
    end

    it "sorts numerically, so 10 comes after 2" do
      put_versioned("wr_a", 10)
      put_versioned("wr_b", 2)
      put_versioned("wr_c", 2)

      expect(read(by: "version")["groups"].map { |each| each["key"] }).to eq(%w[2 10])
    end

    it "adds key to definition groups too" do
      put("wr_1", attempts: [attempt(1, "passed")])
      expect(read["groups"].first).to include("key" => sha("d1"), "sha" => sha("d1"))
    end
  end

  it "refuses a --by that is neither definition nor pack:NAME" do
    ["", "pack:", "packs:x", "pack:a b", "sha"].each do |by|
      expect { read(by: by) }.to raise_error(Workspace::UsageError, /--by needs definition, version or pack:NAME/)
    end
  end

  it "counts unreadable files and leaves out other workflows" do
    put("wr_1", attempts: [attempt(1, "passed")])
    put("wr_other", attempts: [attempt(1, "passed")], workflow: "other")
    File.write(File.join(archive_dir, "wr_bad.json"), "{nope")

    result = read

    expect(result["unreadable"]).to eq(1)
    expect(result["runs"]).to eq(1)
  end

  it "counts a run of the wrong shape as unreadable, not as a group member" do
    put("wr_1", attempts: [attempt(1, "passed")])
    loaded = loader.load(workflow: "rpiv")
    loaded["runs"] << {"id" => 7, "state" => "completed", "steps" => 5, "definition_sha256" => Object.new}

    result = compare.read(workflow: "rpiv", by: "definition", loaded: loaded)

    expect(result).to include("runs" => 1, "unreadable" => 1)
  end

  it "can take runs the caller already loaded" do
    put("wr_1", attempts: [attempt(1, "passed")])
    loaded = loader.load(workflow: "rpiv")
    expect(compare.read(workflow: "ignored", by: "definition", loaded: loaded)["runs"]).to eq(1)
  end

  describe "a step being reviewed (spec/fixtures/workflow_runs/reviewing.json)" do
    def put_reviewing(id, state:, reason: nil)
      run = JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/workflow_runs/reviewing.json"))).merge("id" => id, "workflow" => "rpiv", "state" => state, "reason" => reason)
      target = (state == "running" || state == "waiting") ? runs_dir : archive_dir
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "#{id}.json"), JSON.generate(run))
    end

    it "leaves a checks_passed attempt out until its round rewrites it: a cancelled run is not a miss" do
      put_reviewing("wr_1", state: "cancelled")

      row = read["groups"].first

      expect(row).to include("runs" => 1, "settled" => 0, "cancelled" => 1, "first_try" => 0)
    end

    it "does not call a run waiting on failed_check stuck for a checks_passed attempt alone" do
      put_reviewing("wr_1", state: "waiting", reason: {"code" => "failed_check"})

      expect(read["groups"].first).to include("running" => 1, "stuck" => 0, "settled" => 0)
    end
  end
  describe "run_ids" do
    it "lists each definition group's run ids, newest first" do
      put("wr_a", attempts: [attempt(1, "passed")], created: "2026-10-30T09:00:00Z")
      put("wr_b", attempts: [attempt(1, "passed")], created: "2026-10-30T11:00:00Z")
      put("wr_c", attempts: [attempt(1, "passed")], created: "2026-10-30T10:00:00Z", definition: sha("d2"))

      result = read

      expect(group(result, sha("d1"))["run_ids"]).to eq(%w[wr_b wr_a])
      expect(group(result, sha("d2"))["run_ids"]).to eq(%w[wr_c])
    end

    it "lists each version group's run ids" do
      %w[wr_1 wr_2].each_with_index do |id, index|
        put(id, attempts: [attempt(1, "passed")], created: "2026-10-30T0#{index}:00:00Z")
        file = File.join(archive_dir, "#{id}.json")
        run = JSON.parse(File.read(file))
        run["definition"]["version"] = 2
        File.write(file, JSON.generate(run))
      end

      expect(read(by: "version")["groups"]).to contain_exactly(a_hash_including("key" => "2", "run_ids" => %w[wr_2 wr_1]))
    end

    it "leaves runs outside every pack group, and malformed runs, out of the ids" do
      put("wr_1", attempts: [attempt(1, "passed", packs: [pack("notes", "n")])])
      put("wr_2", attempts: [])
      put("wr_3", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v1")])])
      put("wr_bad", attempts: [attempt(1, "passed", packs: [pack("plan-review", "v1")])])
      File.write(File.join(archive_dir, "wr_bad.json"), JSON.generate("id" => "wr_bad", "workflow" => "rpiv", "state" => "completed", "steps" => "nope"))

      result = read(by: "pack:plan-review")

      expect(result["groups"].flat_map { |each| each["run_ids"] }).to eq(%w[wr_3])
    end
  end
end
