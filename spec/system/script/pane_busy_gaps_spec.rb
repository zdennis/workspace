require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "time"

RSpec.describe "script/pane-busy-gaps" do
  let(:script) { File.join(PROJECT_ROOT, "script", "pane-busy-gaps") }
  let(:dir) { Dir.mktmpdir }
  let(:state) { File.join(dir, "state") }
  let(:base) { Time.utc(2026, 11, 22, 10, 0, 0) }

  before do
    FileUtils.mkdir_p(File.join(state, ".workflows", "archive"))
    FileUtils.mkdir_p(File.join(state, ".events"))
  end

  after { FileUtils.remove_entry(dir) }

  def iso(offset)
    (base + offset).utc.iso8601(3)
  end

  def refused(n, started, ended, extra = {})
    {"n" => n, "started_at" => iso(started), "ended_at" => iso(ended), "outcome" => "not_delivered", "code" => "pane_busy",
     "refusal" => {"error" => "pane_busy", "reason" => "no_input_prompt"}}.merge(extra)
  end

  def delivered(n, started, ended)
    {"n" => n, "started_at" => iso(started), "ended_at" => iso(ended), "outcome" => "passed"}
  end

  def write_run(id, attempts, hooks: [], dispatches: [], workspace: "ws", pane: "%1", dir_name: "archive")
    run = {"id" => id, "workspace" => workspace, "pane" => pane, "steps" => {"implement" => {"attempts" => attempts}}}
    path = File.join(state, ".workflows", dir_name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "#{id}.json"), JSON.generate(run))
    File.write(File.join(path, "#{id}.events.jsonl"), dispatches.map { |d| JSON.generate({"type" => "step_dispatching", "step" => "implement", "pane" => pane}.merge(d)) }.join("\n") + "\n")
    File.open(File.join(state, ".events", "#{workspace}.jsonl"), "a") do |f|
      hooks.each { |h| f.puts JSON.generate({"workspace" => workspace, "pane_id" => pane, "run_id" => id}.merge(h)) }
    end
  end

  def advance(offset, pane: "%1")
    {"type" => "workflow_advance_started", "at" => iso(offset), "pane_id" => pane}
  end

  def run_script(*args)
    out, err, status = Open3.capture3({"HOME" => dir}, RbConfig.ruby, script, "--state-dir", state, *args)
    [out, err, status.exitstatus]
  end

  def rows_of(*args)
    JSON.parse(run_script("--json", *args).first)["rows"]
  end

  it "measures a positive busy duration from a later workflow_advance_started" do
    write_run("wr_a", [refused(1, 0, 10), delivered(2, 40, 60)], hooks: [advance(25)])
    expect(rows_of).to contain_exactly(include("run" => "wr_a", "n" => 1, "busy" => 15.0, "basis" => "advance_after", "gap" => 30.0, "reason" => "no_input_prompt"))
  end

  it "measures a negative busy duration when the turn ended before the refusal" do
    write_run("wr_b", [refused(1, 0, 10), delivered(2, 40, 60)], hooks: [advance(-20), advance(50)])
    expect(rows_of).to contain_exactly(include("busy" => -30.0, "basis" => "advance_before"))
  end

  it "falls back to the last hook event and marks the row" do
    write_run("wr_c", [refused(1, 0, 10, "refusal" => nil), delivered(2, 40, 60)], hooks: [{"type" => "prompt_submitted", "at" => iso(-5)}])
    row = rows_of.first
    expect(row).to include("busy" => -15.0, "basis" => "last_hook", "reason" => "none")
    out, = run_script
    expect(out).to match(/last_hook/)
  end

  it "reads an attempt whose refusal is not a hash as having no reason" do
    write_run("wr_c2", [refused(1, 0, 10, "refusal" => "oops"), delivered(2, 40, 60)], hooks: [advance(-20)])
    expect(rows_of.first).to include("reason" => "none")
  end

  it "reads a redelivery that is not a number as zero" do
    write_run("wr_c3", [refused(1, 0, 10, "redelivery" => "a"), delivered(2, 40, 60)], hooks: [advance(-20)])
    out, _err, status = run_script
    expect(status).to eq(0)
    expect(out).to match(/wr_c3/)
    expect(rows_of.first).to include("redelivery" => 0)
  end

  it "reports no busy duration when the pane has no hook events" do
    write_run("wr_d", [refused(1, 0, 10)], hooks: [advance(5, pane: "%9")])
    result = JSON.parse(run_script("--json").first)
    expect(result["rows"].first).to include("busy" => nil, "basis" => "none", "gap" => nil, "next_code" => nil)
    expect(result["blocks"].first).to include("length" => nil, "replay" => nil)
    expect(result["summary"]).to include("blocks" => 1, "blocks_open" => 1)
    expect(result["summary"]["replay"]["15/300/900"]).to include("blocks" => 0)
  end

  it "starts a block at the first refusal with a readable ended_at" do
    write_run("wr_d2", [refused(1, 0, 10, "ended_at" => nil), refused(2, 20, 30), delivered(3, 50, 70)])
    blocks = JSON.parse(run_script("--json").first)["blocks"]
    expect(blocks).to contain_exactly(include("n" => 2, "length" => 20.0))
  end

  it "takes the first dispatch of an attempt as how it started" do
    write_run("wr_d3", [refused(1, 0, 10), delivered(2, 40, 60)],
      dispatches: [{"attempt" => 2, "cause" => "resume", "actor" => "person"}, {"attempt" => 2, "cause" => "tick"}])
    expect(rows_of.first).to include("next_via" => "resume")
  end

  it "names a person's resume as how the next attempt started" do
    write_run("wr_e", [refused(1, 0, 10), refused(2, 20, 30), delivered(3, 50, 70)],
      hooks: [advance(-5)],
      dispatches: [{"attempt" => 2, "cause" => "resume", "actor" => "person"}, {"attempt" => 3, "cause" => "tick"}])
    first, second = rows_of
    expect(first).to include("n" => 1, "next_code" => "pane_busy", "next_via" => "resume", "gap" => 10.0)
    expect(second).to include("n" => 2, "next_code" => "passed", "next_via" => "retry")
  end

  it "reads runs under runs/live too and counts post-fix rows" do
    write_run("wr_f", [refused(1, 0, 10), delivered(2, 40, 60)], hooks: [advance(-20)], dir_name: "runs/live")
    out, = run_script
    expect(out).to include("rows=1 post_fix_rows=1 post_fix_busy_median=-30.0s post_fix_busy_max=-30.0s")
  end

  it "replays each schedule against one block of 1229s" do
    write_run("wr_g", [refused(1, 0, 10), delivered(2, 1239, 1300)], hooks: [advance(-20)])
    result = JSON.parse(run_script("--json").first)
    expect(result["blocks"].first).to include("length" => 1229.0)
    expect(result["blocks"].first["replay"]).to eq(
      "15/300/900" => {"retries" => 3, "waste" => 886.0},
      "15/60/300" => {"retries" => 5, "waste" => 46.0},
      "15/30/60/300" => {"retries" => 6, "waste" => 76.0}
    )
    expect(result["summary"]["replay"]["15/300/900"]).to eq("blocks" => 1, "retries" => 3, "waste" => 886.0)
  end

  it "counts first-retry refusals busy at 15s by hooks" do
    write_run("wr_h", [refused(1, 0, 10, "redelivered" => true), delivered(2, 40, 60)], hooks: [advance(30)])
    summary = JSON.parse(run_script("--json").first)["summary"]
    expect(summary).to include("first_retry_refusals" => 1, "first_retry_busy_at_15s" => 1)
  end

  it "filters by --since" do
    write_run("wr_i", [refused(1, 0, 10), delivered(2, 40, 60)])
    expect(rows_of("--since", iso(11))).to be_empty
    expect(rows_of("--since", iso(10)).size).to eq(1)
  end

  it "prints a text table and summary" do
    write_run("wr_j", [refused(1, 0, 10), delivered(2, 40, 60)], hooks: [advance(25)])
    out, _, code = run_script
    expect(code).to eq(0)
    expect(out).to include("wr_j", "advance_after", "rows=1", "Replay")
  end

  it "prints an empty summary for an empty state dir" do
    out, _, code = run_script
    expect(code).to eq(0)
    expect(out).to include("rows=0 post_fix_rows=0")
  end

  it "leaves the state dir's files unchanged" do
    write_run("wr_k", [refused(1, 0, 10), delivered(2, 40, 60)], hooks: [advance(25)])
    snapshot = lambda do
      Dir.glob(File.join(state, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sort.map { |p| [p, File.mtime(p), File.read(p)] }
    end
    before = snapshot.call
    expect(before.size).to eq(3)
    run_script
    run_script("--json")
    expect(snapshot.call).to eq(before)
  end

  it "exits 2 with a message for a bad --since" do
    out, err, code = run_script("--since", "nope")
    expect([out, code]).to eq(["", 2])
    expect(err).to include("pane-busy-gaps: --since: expected an ISO8601 time")
  end

  it "exits 2 with a message for an unknown flag" do
    out, err, code = run_script("--nope")
    expect([out, code]).to eq(["", 2])
    expect(err).to include("pane-busy-gaps:", "--nope")
  end

  it "exits 2 when the state dir has no .workflows directory" do
    FileUtils.rm_rf(File.join(state, ".workflows"))
    out, err, code = run_script("--json")
    expect([out, code]).to eq(["", 2])
    expect(err).to include("no .workflows directory under #{state}")
  end
end
