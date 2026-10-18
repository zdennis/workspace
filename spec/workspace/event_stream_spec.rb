require "tmpdir"

RSpec.describe Workspace::EventStream do
  let(:root) { Dir.mktmpdir }
  let(:lifecycle) { File.join(root, ".workspace-events.jsonl") }
  let(:hook_dir) { File.join(root, ".events") }
  let(:clock) { double(now: Time.utc(2026, 10, 17, 13, 0, 0)) }

  before { FileUtils.mkdir_p(hook_dir) }
  after { FileUtils.remove_entry(root) }

  def stream
    described_class.new(lifecycle_path: lifecycle, hook_dir: hook_dir, clock: clock)
  end

  def at(second)
    Time.utc(2026, 10, 17, 12, 0, second).iso8601(3)
  end

  def life(second, type = "plan_changed", project: "proj", data: {"workspace" => "proj"})
    File.open(lifecycle, "a") { |f| f.puts JSON.generate("timestamp" => at(second), "type" => type, "project" => project, "data" => data) }
  end

  def hook(workspace, second, seq, type = "tool_started", boot: "B1")
    File.open(File.join(hook_dir, "#{workspace}.jsonl"), "a") do |f|
      f.puts JSON.generate("type" => type, "at" => at(second), "workspace" => workspace, "pane_id" => "%1", "boot_id" => boot, "seq" => seq)
    end
  end

  def summary(lines)
    lines.map { |line| [line["source"], line["workspace"], line["type"], line["seq"]].compact }
  end

  it "reads the lifecycle log and every daemon's file as one stream, oldest first" do
    life(1)
    hook("alpha", 2, 1)
    life(3, "inbox_changed", project: "", data: {"scope" => "global"})
    hook("beta", 4, 1)
    hook("alpha", 5, 2, "tool_finished")

    s = stream
    expect(s.open(at: :start)).to eq([])
    lines = s.read

    expect(summary(lines)).to eq([
      ["lifecycle", "proj", "plan_changed"], ["hook", "alpha", "tool_started", 1], ["lifecycle", "", "inbox_changed"],
      ["hook", "beta", "tool_started", 1], ["hook", "alpha", "tool_finished", 2]
    ])
    expect(lines.first).to include("at" => at(1), "timestamp" => at(1), "project" => "proj", "data" => {"workspace" => "proj"})
    expect(lines.map { |line| line["cursor"] }).to all(start_with("1."))
  end

  it "resumes after the line whose cursor it is given, across every source" do
    life(1)
    hook("alpha", 2, 1)
    hook("alpha", 3, 2)
    life(4)
    first = stream.tap { |s| s.open(at: :start) }.read
    hook("alpha", 5, 3)

    s = stream
    expect(s.open(cursor: first[1]["cursor"])).to eq([])

    expect(summary(s.read)).to eq([["hook", "alpha", "tool_started", 2], ["lifecycle", "proj", "plan_changed"], ["hook", "alpha", "tool_started", 3]])
  end

  it "starts at the end of every file when following without a cursor, and reads what is written next" do
    life(1)
    hook("alpha", 2, 1)
    s = stream
    s.open(at: :end)
    expect(s.read).to eq([])

    hook("alpha", 3, 2)
    life(4)

    expect(summary(s.read)).to eq([["hook", "alpha", "tool_started", 2], ["lifecycle", "proj", "plan_changed"]])
  end

  it "waits for a line still being written" do
    s = stream
    s.open(at: :end)
    File.write(lifecycle, JSON.generate("timestamp" => at(1), "type" => "x", "project" => "p")[0, 20])

    expect(s.read).to eq([])
    File.write(lifecycle, JSON.generate("timestamp" => at(1), "type" => "x", "project" => "p") + "\n")

    expect(summary(s.read)).to eq([["lifecycle", "p", "x"]])
  end

  it "picks up a daemon file that appears while following, from its start" do
    s = stream
    s.open(at: :end)
    hook("gamma", 1, 1)
    hook("gamma", 2, 2)

    expect(s.read(discover: false)).to eq([])
    expect(summary(s.read)).to eq([["hook", "gamma", "tool_started", 1], ["hook", "gamma", "tool_started", 2]])
  end

  it "follows a daemon file through its rotation without losing or repeating a line" do
    hook("alpha", 1, 1)
    s = stream
    s.open(at: :end)
    hook("alpha", 2, 2)
    path = File.join(hook_dir, "alpha.jsonl")
    File.rename(path, "#{path}.1")
    expect(summary(s.read)).to eq([["hook", "alpha", "tool_started", 2]])

    hook("alpha", 3, 3)
    hook("alpha", 4, 4)

    expect(summary(s.read).map(&:last)).to eq([3, 4])
  end

  it "reads a whole rotated file it missed when the file rotated twice between reads" do
    hook("alpha", 1, 1)
    s = stream
    s.open(at: :end)
    path = File.join(hook_dir, "alpha.jsonl")
    hook("alpha", 2, 2)
    File.rename(path, "#{path}.1")
    hook("alpha", 3, 3)
    File.rename(path, "#{path}.1")
    hook("alpha", 4, 4)

    expect(summary(s.read).map(&:last)).to eq([2, 3, 4])
  end

  it "goes on in a compacted lifecycle log with only the lines after the last one read" do
    config = instance_double(Workspace::Config, event_log_file: lifecycle)
    log = Workspace::EventLog.new(config: config, clock: double(now: Time.utc(2026, 10, 17, 12, 0, 1)))
    log.append(type: "launched", project: "proj", data: {"unique_id" => "u"})
    log.append(type: "agent_state", project: "proj", data: {"pane_id" => "%1", "state" => "working", "since" => at(1)})
    s = stream
    s.open(at: :end)
    later = Workspace::EventLog.new(config: config, clock: double(now: Time.utc(2026, 10, 17, 12, 0, 9)))
    later.compact
    later.append(type: "plan_changed", project: "proj", data: {"workspace" => "proj"})

    expect(summary(s.read)).to eq([["lifecycle", "proj", "compacted"], ["lifecycle", "proj", "plan_changed"]])
  end

  it "resumes in the rotated copy the cursor's file became, then the new file" do
    hook("alpha", 1, 1)
    hook("alpha", 2, 2)
    cursor = stream.tap { |s| s.open(at: :start) }.read.first["cursor"]
    path = File.join(hook_dir, "alpha.jsonl")
    File.rename(path, "#{path}.1")
    hook("alpha", 3, 3)

    s = stream
    expect(s.open(cursor: cursor)).to eq([])
    expect(summary(s.read).map(&:last)).to eq([2, 3])
  end

  it "prints a gap when the cursor's file is no longer kept, then the lines after the cursor's time" do
    hook("alpha", 1, 1)
    hook("alpha", 2, 2)
    cursor = stream.tap { |s| s.open(at: :start) }.read.first["cursor"]
    path = File.join(hook_dir, "alpha.jsonl")
    File.rename(path, "#{path}.1")
    hook("alpha", 3, 3)
    File.rename(path, "#{path}.1")
    hook("alpha", 4, 4)

    s = stream
    gaps = s.open(cursor: cursor)

    expect(gaps).to eq([{"type" => "gap", "at" => "2026-10-17T13:00:00.000Z", "source" => "hook", "workspace" => "alpha",
                         "reason" => "cursor_not_retained", "cursor" => gaps.first["cursor"]}])
    expect(summary(s.read).map(&:last)).to eq([3, 4])
  end

  it "drops a removed workspace from the cursor without a word" do
    hook("alpha", 1, 1)
    hook("beta", 2, 1)
    cursor = stream.tap { |s| s.open(at: :start) }.read.last["cursor"]
    File.unlink(File.join(hook_dir, "alpha.jsonl"))
    hook("beta", 3, 2)

    s = stream
    expect(s.open(cursor: cursor)).to eq([])
    expect(summary(s.read)).to eq([["hook", "beta", "tool_started", 2]])
    expect(described_class.decode_cursor(s.cursor_string)["h"].keys).to eq(["beta"])
  end

  it "ends a source whose files are removed while following" do
    hook("alpha", 1, 1)
    s = stream
    s.open(at: :end)
    File.unlink(File.join(hook_dir, "alpha.jsonl"))

    expect(s.read(discover: false)).to eq([])
    expect(described_class.decode_cursor(s.cursor_string)["h"]).to eq({})
  end

  it "reads a daemon file the cursor doesn't name from its start" do
    hook("alpha", 1, 1)
    cursor = stream.tap { |s| s.open(at: :start) }.read.last["cursor"]
    hook("beta", 2, 1)

    s = stream
    s.open(cursor: cursor)
    expect(summary(s.read)).to eq([["hook", "beta", "tool_started", 1]])
  end

  it "skips a line that isn't a JSON object" do
    File.write(lifecycle, "not json\n[1]\n")
    life(1)

    s = stream
    s.open(at: :start)
    expect(summary(s.read)).to eq([["lifecycle", "proj", "plan_changed"]])
  end

  it "keeps a daemon's line written in the same millisecond as the last one read, across a rotation" do
    hook("alpha", 1, 1)
    s = stream
    s.open(at: :end)
    path = File.join(hook_dir, "alpha.jsonl")
    File.rename(path, "#{path}.1")
    hook("alpha", 1, 2)

    expect(summary(s.read).map(&:last)).to eq([2])
  end

  it "prints a gap when resuming from a cursor taken before event-log compact, then only the newer lines" do
    config = instance_double(Workspace::Config, event_log_file: lifecycle)
    Workspace::EventLog.new(config: config, clock: double(now: Time.utc(2026, 10, 17, 12, 0, 1))).append(type: "launched", project: "proj", data: {"unique_id" => "u"})
    cursor = stream.tap { |s| s.open(at: :start) }.read.last["cursor"]
    later = Workspace::EventLog.new(config: config, clock: double(now: Time.utc(2026, 10, 17, 12, 0, 9)))
    later.compact
    later.append(type: "plan_changed", project: "proj", data: {"workspace" => "proj"})

    s = stream
    expect(s.open(cursor: cursor).map { |gap| gap.values_at("type", "source", "workspace") }).to eq([["gap", "lifecycle", nil]])
    expect(summary(s.read)).to eq([["lifecycle", "proj", "compacted"], ["lifecycle", "proj", "plan_changed"]])
  end

  it "reads a line that reached the old file just before it was replaced" do
    hook("alpha", 1, 1)
    s = stream
    s.open(at: :end)
    path = File.join(hook_dir, "alpha.jsonl")
    replaced = false
    allow(File).to receive(:stat).and_wrap_original do |original, file|
      if file == path && !replaced
        replaced = true
        hook("alpha", 2, 2)
        File.rename(path, "#{path}.1")
        hook("alpha", 3, 3)
      end
      original.call(file)
    end

    expect(summary(s.read).map(&:last)).to eq([2, 3])
  end

  it "resumes in the right file when it rotates between finding the cursor's file and opening it" do
    hook("alpha", 1, 1)
    hook("alpha", 2, 2)
    cursor = stream.tap { |s| s.open(at: :start) }.read.first["cursor"]
    path = File.join(hook_dir, "alpha.jsonl")
    rotated = false
    allow(File).to receive(:open).and_wrap_original do |original, file, *args, **kw, &block|
      if file == path && !rotated
        rotated = true
        File.rename(path, "#{path}.1")
        hook("alpha", 3, 3)
      end
      original.call(file, *args, **kw, &block)
    end

    s = stream
    expect(s.open(cursor: cursor)).to eq([])
    expect(summary(s.read).map(&:last)).to eq([2, 3])
  end

  it "reads a large backlog a bounded piece at a time, and says when there is more" do
    stub_const("#{described_class}::Source::MAX_READ", 300)
    5.times { |n| hook("alpha", n, n + 1) }
    s = stream
    s.open(at: :start)

    seqs = s.read.map { |line| line["seq"] }
    expect(s.more?).to be(true)
    seqs.concat(s.read.map { |line| line["seq"] }) while s.more?

    expect(seqs).to eq([1, 2, 3, 4, 5])
  end

  it "refuses a cursor it can't read, with the invalid_cursor code" do
    ["nope", "1.!!!", described_class.encode_cursor([]),
      described_class.encode_cursor("h" => {"a" => {"i" => "x", "o" => 1}}),
      described_class.encode_cursor("h" => {"a" => {"i" => 1, "o" => -1}}),
      described_class.encode_cursor("h" => []),
      described_class.encode_cursor("h" => {"a" => "x"})].each do |cursor|
      expect { stream.open(cursor: cursor) }.to raise_error(described_class::InvalidCursor) { |e| expect(e.code).to eq("invalid_cursor") }
    end
  end
end
