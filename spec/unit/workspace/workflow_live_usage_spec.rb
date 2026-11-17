require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Workspace::WorkflowLiveUsage do
  around do |example|
    Dir.mktmpdir("wf-live") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:now) { Time.utc(2026, 10, 4, 12, 10, 0) }
  let(:cache_dir) { File.join(@dir, "runs", "live") }
  let(:ledger_path) { File.join(@dir, "ledger.jsonl") }
  let(:ledger) { Workspace::SessionLedger.new(path: ledger_path) }
  let(:transcript) { File.join(@dir, "s1.jsonl") }
  let(:max_read_bytes) { Workspace::TranscriptUsage::MAX_TRANSCRIPT_BYTES }
  let(:read_counts) { [] }
  let(:read_bytes) do
    ->(file, offset, length) do
      file.seek(offset)
      file.read(length).to_s.tap { |data| read_counts << data.bytesize }
    end
  end
  subject(:live) { described_class.new(dir: cache_dir, ledger: ledger, max_read_bytes: max_read_bytes, read_bytes: read_bytes) }

  let(:run) do
    {"id" => "wr_1", "workspace" => "ws", "pane" => "%5", "current" => "impl",
     "steps" => {"impl" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => "2026-10-04T12:00:00Z"}]}}}
  end

  def start_session(id, at, path: transcript, source: "startup")
    File.open(ledger_path, "a") do |file|
      file.puts(JSON.generate("at" => at, "event" => "session_start", "workspace" => "ws", "pane_id" => "%5", "session_id" => id,
        "transcript_path" => path, "source" => source))
    end
  end

  def assistant(id, at, input: 0, output: 0, cache_creation: 0, cache_read: 0, **more)
    usage = {"input_tokens" => input, "output_tokens" => output, "cache_creation_input_tokens" => cache_creation, "cache_read_input_tokens" => cache_read}
    JSON.generate({"type" => "assistant", "timestamp" => at, "message" => {"id" => id, "usage" => usage}}.merge(more))
  end

  def append(path, *lines)
    File.open(path, "a") { |file| lines.each { |line| file.write("#{line}\n") } }
  end

  before { start_session("s1", "2026-10-04T12:00:01Z") }

  it "rises as lines are appended while the step runs, counting input, output and cache creation but not cache reads" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10, output: 5, cache_creation: 3, cache_read: 1000))
    expect(live.reading(run, now: now)).to eq(18)

    append(transcript, assistant("m2", "2026-10-04T12:01:00Z", input: 100, output: 2))
    expect(live.reading(run, now: now)).to eq(120)
  end

  it "reads no bytes on a second call when nothing was written, however long the transcript" do
    lines = (1..2000).map { |i| assistant("m#{i}", "2026-10-04T12:00:02Z", input: 1, output: 1) }
    append(transcript, *lines)
    expect(live.reading(run, now: now)).to eq(4000)

    read_counts.clear
    expect(live.reading(run, now: now)).to eq(4000)
    expect(read_counts.sum).to eq(0)
  end

  it "counts a streamed message once, as its last line says, across two reads" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10, output: 1))
    expect(live.reading(run, now: now)).to eq(11)

    append(transcript, assistant("m1", "2026-10-04T12:00:03Z", input: 10, output: 40))
    expect(live.reading(run, now: now)).to eq(50)
  end

  it "leaves a line still being written until its newline lands" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    partial = assistant("m2", "2026-10-04T12:00:03Z", input: 7)
    File.write(transcript, partial[0, 20], mode: "a")
    expect(live.reading(run, now: now)).to eq(10)

    File.write(transcript, "#{partial[20..]}\n", mode: "a")
    expect(live.reading(run, now: now)).to eq(17)
  end

  it "leaves out lines from before the attempt and sub-agent lines in the main transcript" do
    append(transcript, assistant("old", "2026-10-04T11:59:00Z", input: 999),
      assistant("m1", "2026-10-04T12:00:02Z", input: 10),
      assistant("side", "2026-10-04T12:00:03Z", input: 500, isSidechain: true))
    expect(live.reading(run, now: now)).to eq(10)
  end

  it "starts again when the transcript is truncated" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1000), assistant("m2", "2026-10-04T12:00:03Z", input: 1000))
    expect(live.reading(run, now: now)).to eq(2000)

    File.write(transcript, "#{assistant("m3", "2026-10-04T12:00:04Z", input: 3)}\n")
    expect(live.reading(run, now: now)).to eq(3)
  end

  it "starts again when the transcript is replaced by another file, even a longer one" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1000))
    expect(live.reading(run, now: now)).to eq(1000)

    other = File.join(@dir, "other.jsonl")
    append(other, assistant("n1", "2026-10-04T12:00:02Z", input: 1), assistant("n2", "2026-10-04T12:00:03Z", input: 2),
      assistant("n3", "2026-10-04T12:00:04Z", input: 4))
    File.rename(other, transcript)
    expect(live.reading(run, now: now)).to eq(7)
  end

  it "counts only the new session after a /clear, as the attempt record does" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1000))
    expect(live.reading(run, now: now)).to eq(1000)

    cleared = File.join(@dir, "s2.jsonl")
    start_session("s2", "2026-10-04T12:05:00Z", path: cleared, source: "clear")
    append(cleared, assistant("c1", "2026-10-04T12:05:01Z", input: 6))
    expect(live.reading(run, now: now)).to eq(6)
  end

  it "is nil without a transcript, without a session, or with a usage line that has no time" do
    expect(live.reading(run, now: now)).to be_nil

    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1), assistant("m2", nil, input: 5))
    expect(live.reading(run, now: now)).to be_nil

    File.delete(ledger_path)
    File.write(transcript, "#{assistant("m1", "2026-10-04T12:00:02Z", input: 1)}\n")
    expect(live.reading(run, now: now)).to be_nil
  end

  it "is nil for another agent than Claude Code" do
    File.write(ledger_path, "")
    File.open(ledger_path, "a") do |file|
      file.puts(JSON.generate("at" => "2026-10-04T12:00:01Z", "event" => "session_start", "workspace" => "ws", "pane_id" => "%5",
        "session_id" => "s1", "transcript_path" => transcript, "kind" => "codex"))
    end
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1))
    expect(live.reading(run, now: now)).to be_nil
  end

  context "with a transcript written past the read limit since the attempt began" do
    let(:max_read_bytes) { 1000 }

    it "is nil on the first call and gives the whole figure once the back scan reaches the attempt's start" do
      append(transcript, assistant("old", "2026-10-04T11:59:00Z", input: 999))
      lines = (1..40).map { |i| assistant("m#{i}", "2026-10-04T12:00:02Z", input: 1, output: 1) }
      append(transcript, *lines)
      expect(File.size(transcript)).to be > 3 * max_read_bytes

      readings = Array.new(20) { live.reading(run, now: now) }
      expect(readings.first).to be_nil
      expect(readings.last).to eq(80)
      expect(read_counts.max).to be <= max_read_bytes
    end

    it "catches up a forward read past the limit over later calls" do
      append(transcript, assistant("m0", "2026-10-04T12:00:02Z", input: 1))
      expect(live.reading(run, now: now)).to eq(1)

      append(transcript, *(1..40).map { |i| assistant("m#{i}", "2026-10-04T12:01:00Z", input: 1) })
      readings = Array.new(20) { live.reading(run, now: now) }
      expect(readings.first).to be_nil
      expect(readings.last).to eq(41)
    end

    it "counts a message whose lines were read backward as one read in file order would" do
      append(transcript, assistant("old", "2026-10-04T11:59:00Z", input: 999))
      append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10, output: 1))
      append(transcript, *(1..20).map { |i| assistant("x#{i}", "2026-10-04T12:00:03Z", input: 1) })
      append(transcript, assistant("m1", "2026-10-04T12:00:04Z", input: 10, output: 90))

      readings = Array.new(20) { live.reading(run, now: now) }
      expect(readings.last).to eq(100 + 20)
    end
  end

  it "counts a sub-agent's own transcript, all of whose lines are sidechain" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    subagents = File.join(@dir, "s1", "subagents")
    FileUtils.mkdir_p(subagents)
    append(File.join(subagents, "agent-a.jsonl"), assistant("a1", "2026-10-04T12:00:05Z", input: 30, isSidechain: true))
    expect(live.reading(run, now: now)).to eq(40)

    append(File.join(subagents, "agent-a.jsonl"), assistant("a2", "2026-10-04T12:00:06Z", output: 2, isSidechain: true))
    expect(live.reading(run, now: now)).to eq(42)
  end

  it "is nil when a sub-agent file is a link" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    subagents = File.join(@dir, "s1", "subagents")
    FileUtils.mkdir_p(subagents)
    target = File.join(@dir, "elsewhere.jsonl")
    append(target, assistant("a1", "2026-10-04T12:00:05Z", input: 30))
    File.symlink(target, File.join(subagents, "agent-a.jsonl"))
    expect(live.reading(run, now: now)).to be_nil
  end

  it "is nil for a finished attempt and removes the run's cache" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    expect(live.reading(run, now: now)).to eq(10)
    expect(Dir.exist?(File.join(cache_dir, "wr_1"))).to be(true)

    run["steps"]["impl"]["state"] = "passed"
    expect(live.reading(run, now: now)).to be_nil
    expect(Dir.exist?(File.join(cache_dir, "wr_1"))).to be(false)
  end

  it "never writes beside the run files the run store lists" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    live.reading(run, now: now)
    expect(Dir.glob(File.join(@dir, "runs", "*.json"))).to eq([])
  end

  it "leaves a readable cache when two readers write it at once" do
    append(transcript, *(1..500).map { |i| assistant("m#{i}", "2026-10-04T12:00:02Z", input: 1) })
    readers = Array.new(2) { described_class.new(dir: cache_dir, ledger: ledger) }
    readings = readers.map { |reader| Thread.new { Array.new(5) { reader.reading(run, now: now) } } }.flat_map(&:value)

    expect(readings.uniq).to eq([500])
    expect(JSON.parse(File.read(File.join(cache_dir, "wr_1", "usage.json")))).to be_a(Hash)
    expect(live.reading(run, now: now)).to eq(500)
  end

  it "starts again from a cache it can't read" do
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    live.reading(run, now: now)
    File.write(File.join(cache_dir, "wr_1", "usage.json"), "{not json")
    expect(live.reading(run, now: now)).to eq(10)
  end

  context "with many sub-agent files and a small read limit" do
    let(:max_read_bytes) { 1000 }

    it "reads no more than the limit in one call over every file, and gives the figure on a later call" do
      append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 1))
      subagents = File.join(@dir, "s1", "subagents")
      FileUtils.mkdir_p(subagents)
      10.times do |i|
        append(File.join(subagents, "agent-#{i}.jsonl"),
          *(1..3).map { |j| assistant("a#{i}-#{j}", "2026-10-04T12:00:05Z", input: 1, isSidechain: true) })
      end

      readings = Array.new(10) do
        read_counts.clear
        live.reading(run, now: now).tap { expect(read_counts.sum).to be <= max_read_bytes }
      end
      expect(readings.first).to be_nil
      expect(readings.last).to eq(31)
    end
  end

  it "keeps no usage for messages that began before the attempt, and never counts their later lines" do
    append(transcript, *(1..200).map { |i| assistant(nil, "2026-10-04T11:59:00Z", input: i) })
    append(transcript, assistant("straddle", "2026-10-04T11:59:30Z", input: 1))
    append(transcript, assistant("m1", "2026-10-04T12:00:02Z", input: 10))
    expect(live.reading(run, now: now)).to eq(10)

    append(transcript, assistant("straddle", "2026-10-04T12:00:03Z", input: 500))
    expect(live.reading(run, now: now)).to eq(10)
    expect(File.size(File.join(cache_dir, "wr_1", "usage.json"))).to be < 1000
  end

  describe "#prune" do
    it "removes the caches of runs no longer going and keeps the rest" do
      FileUtils.mkdir_p(File.join(cache_dir, "wr_done"))
      FileUtils.mkdir_p(File.join(cache_dir, "wr_going"))

      expect(live.prune(["wr_going"])).to eq(["wr_done"])
      expect(Dir.children(cache_dir)).to eq(["wr_going"])
    end

    it "does nothing when there is no cache directory" do
      expect(live.prune([])).to eq([])
    end
  end
end
