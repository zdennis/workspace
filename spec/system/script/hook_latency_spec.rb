require "spec_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "script/hook-latency" do
  let(:script) { File.join(PROJECT_ROOT, "script", "hook-latency") }
  let(:dir) { Dir.mktmpdir }
  let(:log) { File.join(dir, "ws.jsonl") }

  after { FileUtils.remove_entry(dir) }

  def line(type, id, at, tool: "Read", pane: "%1")
    JSON.generate("type" => type, "at" => at, "pane_id" => pane, "tool" => tool, "tool_use_id" => id)
  end

  def run_script(*args)
    out, err, status = Open3.capture3(RbConfig.ruby, script, *args)
    [out, err, status.exitstatus]
  end

  def write_log(*lines)
    File.write(log, lines.join("\n") + "\n")
  end

  it "prints n, median and p90 of the paired deltas" do
    write_log(
      line("tool_started", "a", "2026-11-21T10:00:00.000Z"), line("tool_finished", "a", "2026-11-21T10:00:00.100Z"),
      line("tool_started", "b", "2026-11-21T10:00:01.000Z"), line("tool_finished", "b", "2026-11-21T10:00:01.300Z"),
      line("tool_started", "c", "2026-11-21T10:00:02.000Z"), line("tool_finished", "c", "2026-11-21T10:00:02.500Z")
    )
    out, _, code = run_script("--file", log)
    expect(code).to eq(0)
    expect(out.strip).to eq("n=3 median=0.300s p90=0.500s")
  end

  it "ignores unmatched, malformed and unrelated lines" do
    write_log(
      line("tool_started", "a", "2026-11-21T10:00:00.000Z"),
      line("tool_finished", "orphan", "2026-11-21T10:00:00.100Z"),
      "not json",
      JSON.generate("type" => "prompt_submitted", "at" => "2026-11-21T10:00:00Z"),
      line("tool_started", "b", "2026-11-21T10:00:01.000Z"), line("tool_finished", "b", "2026-11-21T10:00:01.200Z")
    )
    out, = run_script("--file", log, "--json")
    expect(JSON.parse(out)).to include("n" => 1, "median" => 0.2)
  end

  it "filters by tool" do
    write_log(
      line("tool_started", "a", "2026-11-21T10:00:00.000Z"), line("tool_finished", "a", "2026-11-21T10:00:00.100Z"),
      line("tool_started", "b", "2026-11-21T10:00:01.000Z", tool: "Bash"), line("tool_finished", "b", "2026-11-21T10:00:02.000Z", tool: "Bash")
    )
    out, = run_script("--file", log, "--tool", "Bash", "--json")
    expect(JSON.parse(out)).to include("n" => 1, "median" => 1.0, "tool" => "Bash")
  end

  it "filters by --since on the start time" do
    write_log(
      line("tool_started", "a", "2026-11-21T09:00:00.000Z"), line("tool_finished", "a", "2026-11-21T09:00:00.900Z"),
      line("tool_started", "b", "2026-11-21T11:00:00.000Z"), line("tool_finished", "b", "2026-11-21T11:00:00.200Z")
    )
    out, = run_script("--file", log, "--since", "2026-11-21T10:00:00Z", "--json")
    expect(JSON.parse(out)).to include("n" => 1, "median" => 0.2)
  end

  it "reports n=0 for an empty or missing file" do
    File.write(log, "")
    out, _, code = run_script("--file", log)
    expect(code).to eq(0)
    expect(out.strip).to eq("n=0 median=- p90=-")
    out, = run_script("--file", File.join(dir, "none.jsonl"), "--json")
    expect(JSON.parse(out)).to include("n" => 0, "median" => nil)
  end

  it "fails with usage when no source is given" do
    _, err, code = run_script
    expect(code).to eq(2)
    expect(err).to include("Usage")
  end

  it "times a stub --bin with --process" do
    stub = File.join(dir, "stub.rb")
    File.write(stub, "$stdin.read\nexit 0\n")
    out, _, code = run_script("--process", "2", "--bin", stub, "--json")
    expect(code).to eq(0)
    expect(JSON.parse(out)).to include("n" => 2, "mode" => "process")
  end
end
