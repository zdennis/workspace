require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Workspace::WorkflowAudit do
  around do |example|
    Dir.mktmpdir("wf-audit") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:evidence_dir) { File.join(@dir, "evidence") }
  let(:art) { File.join(@dir, "art") }
  let(:copies) { File.join(evidence_dir, "wr_1") }
  let(:recorder) { Workspace::WorkflowEvidence.new(dir: evidence_dir) }
  subject(:audit) { described_class.new(attempts: Workspace::WorkflowAttempts.new, dir: evidence_dir) }

  before { FileUtils.mkdir_p(File.join(art, "steps")) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def put(name, text)
    path = File.join(art, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # A run whose attempt 1 of "implement" has its prompt, check log and output copied for real.
  def recorded_run(extra = {})
    run = {"id" => "wr_1", "artifacts_dir" => art, "definition" => {"steps" => [{"id" => "implement", "produces" => ["out.md"]}]}}
    put("steps/implement.1.prompt.md", "prompt")
    put("steps/implement.1.check.log", "log")
    put("out.md", "out")
    attempt = {"n" => 1, "started_at" => "2026-11-01T09:00:00Z", "prompt_file" => File.join(art, "steps", "implement.1.prompt.md"),
               "check" => {"log" => "x"}, "prompt_sha256" => "not-the-file-hash"}
    attempt["evidence"] = recorder.prompt(run: run, step_id: "implement", attempt: attempt)
    attempt["evidence"] += recorder.copy(run: run, step: {"id" => "implement", "produces" => ["out.md"]}, attempt: attempt)
    run.merge("steps" => {"implement" => {"attempts" => [attempt]}}).merge(extra)
  end

  def statuses(result) = result["files"].to_h { |each| [each["kind"], each["status"]] }

  it "finds every copy intact, whatever prompt_sha256 says" do
    result = audit.read(recorded_run)

    expect(statuses(result)).to eq("prompt" => "ok", "check_log" => "ok", "output" => "ok")
    expect(result).to include("clean" => true, "counts" => {"ok" => 3}, "directory" => copies, "without_evidence" => [])
    expect(result["files"].map { |each| each["source_status"] }).to eq(%w[same same] + [nil])
  end

  it "reports a copy that was edited, with both hashes" do
    run = recorded_run
    File.write(File.join(copies, "implement.1.check.log"), "edited")

    row = audit.read(run)["files"].find { |each| each["kind"] == "check_log" }

    expect(row).to include("status" => "changed", "recorded_sha256" => sha("log"), "now_sha256" => sha("edited"))
    expect(audit.read(run)["clean"]).to be(false)
  end

  it "reports a deleted copy, and every copy when the evidence directory is gone" do
    run = recorded_run
    File.delete(File.join(copies, "implement.1.prompt.md"))
    expect(statuses(audit.read(run))).to include("prompt" => "missing")

    FileUtils.rm_rf(copies)
    result = audit.read(run)
    expect(result["files"].map { |each| each["status"] }.uniq).to eq(["missing"])
    expect(result["files"].first["reason"]).to eq("no_evidence_directory")
    expect(result["clean"]).to be(false)
  end

  it "reports a copy replaced by a link without reading through it" do
    run = recorded_run
    secret = File.join(@dir, "secret")
    File.write(secret, "log")
    File.delete(File.join(copies, "implement.1.check.log"))
    File.symlink(secret, File.join(copies, "implement.1.check.log"))

    row = audit.read(run)["files"].find { |each| each["kind"] == "check_log" }

    expect(row).to include("status" => "replaced", "reason" => "symlink", "now_sha256" => nil)
  end

  it "treats a linked evidence directory as missing" do
    run = recorded_run
    moved = File.join(@dir, "moved")
    FileUtils.mv(copies, moved)
    File.symlink(moved, copies)

    result = audit.read(run)

    expect(result["files"].map { |each| each["status"] }.uniq).to eq(["missing"])
    expect(result["files"].first["reason"]).to eq("no_evidence_directory")
  end

  it "never leaves the evidence directory for a stored name" do
    run = recorded_run
    File.write(File.join(@dir, "evidence", "outside"), "log")
    run["steps"]["implement"]["attempts"][0]["evidence"][1]["name"] = "../outside"
    run["steps"]["implement"]["attempts"][0]["evidence"][1]["sha256"] = sha("log")

    row = audit.read(run)["files"][1]

    expect(row).to include("status" => "missing", "reason" => "invalid_name")
  end

  it "reports a name that is not a string as invalid_name" do
    run = recorded_run
    run["steps"]["implement"]["attempts"][0]["evidence"][0]["name"] = nil

    expect(audit.read(run)["files"][0]).to include("status" => "missing", "reason" => "invalid_name")
  end

  it "does not crash on a NUL in a source or the artifacts directory" do
    run = recorded_run
    run["steps"]["implement"]["attempts"][0]["evidence"][0]["source"] = "a\0b"
    expect(audit.read(run)["files"][0]["source_status"]).to be_nil

    run = recorded_run("artifacts_dir" => "#{art}\0x")
    expect(audit.read(run)["files"].map { |each| each["status"] }).to eq(%w[ok ok ok])
  end

  it "counts an entry with no hash, problem or size flag as changed" do
    run = recorded_run
    run["steps"]["implement"]["attempts"][0]["evidence"][0]["sha256"] = nil

    result = audit.read(run)

    expect(result["files"][0]).to include("status" => "changed", "reason" => "no_recorded_hash")
    expect(result["clean"]).to be(false)
  end

  it "counts a problem or too_large entry whose copy is there as changed" do
    run = recorded_run
    entries = run["steps"]["implement"]["attempts"][0]["evidence"]
    entries[0] = entries[0].merge("sha256" => nil, "problem" => "missing")
    entries[1] = entries[1].merge("sha256" => nil, "too_large" => true)

    result = audit.read(run)

    expect(result["files"].first(2).map { |each| [each["status"], each["reason"]] }).to eq([["changed", "unexpected_copy"], ["changed", "unexpected_copy"]])
    expect(result["clean"]).to be(false)
  end

  it "reports a problem or a size limit as nothing kept, not tampering" do
    run = recorded_run
    entries = run["steps"]["implement"]["attempts"][0]["evidence"]
    entries[0] = entries[0].merge("sha256" => nil, "bytes" => nil, "problem" => "outside_artifacts")
    entries[1] = entries[1].merge("sha256" => nil, "too_large" => true, "budget" => true, "bytes" => 9)
    entries[2] = entries[2].merge("sha256" => nil, "too_large" => true)
    [0, 1, 2].each { |i| File.delete(File.join(copies, entries[i]["name"])) }

    result = audit.read(run)

    expect(result["files"].map { |each| [each["status"], each["reason"]] }).to eq([["not_copied", "outside_artifacts"], ["too_large", "budget"], ["too_large", "size"]])
    expect(result["clean"]).to be(true)
  end

  it "notes a prompt edited in the checkout since it was copied, and a source that is gone" do
    run = recorded_run
    File.write(File.join(art, "steps", "implement.1.prompt.md"), "edited")
    File.delete(File.join(art, "steps", "implement.1.check.log"))

    sources = audit.read(run)["files"].map { |each| each["source_status"] }

    expect(sources).to eq(["differs", "gone", nil])
    expect(audit.read(run)["clean"]).to be(true)
  end

  it "lists an attempt from before evidence existed instead of failing" do
    run = {"id" => "wr_1", "artifacts_dir" => art, "definition" => {"steps" => [{"id" => "plan"}]},
           "steps" => {"plan" => {"attempts" => [{"n" => 1}, {"n" => 2, "evidence" => []}]}}}

    result = audit.read(run)

    expect(result).to include("files" => [], "without_evidence" => [{"step" => "plan", "attempt" => 1}], "clean" => true)
  end

  it "audits a retry's attempts apart, and one step on request" do
    run = recorded_run
    second = {"n" => 2, "started_at" => "2026-11-01T09:10:00Z", "prompt_file" => File.join(art, "steps", "implement.2.prompt.md")}
    put("steps/implement.2.prompt.md", "second")
    second["evidence"] = recorder.prompt(run: run, step_id: "implement", attempt: second)
    run["steps"]["implement"]["attempts"] << second
    File.write(File.join(copies, "implement.1.prompt.md"), "x")

    files = audit.read(run)["files"]

    expect(files.map { |each| [each["attempt"], each["kind"], each["status"]] }).to eq([[1, "prompt", "changed"], [1, "check_log", "ok"], [1, "output", "ok"], [2, "prompt", "ok"]])
    expect { audit.read(run, step: "nope") }.to raise_error(Workspace::Error) { |e| expect(e.code).to eq("unknown_step") }
  end

  it "refuses to look under a run id that is not one" do
    run = recorded_run("id" => "../x")

    expect(audit.read(run)["directory"]).to be_nil
    expect(audit.read(run)["files"].map { |each| each["status"] }.uniq).to eq(["missing"])
  end
end
