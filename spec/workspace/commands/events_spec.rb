require "tmpdir"

RSpec.describe Workspace::Commands::Events do
  let(:root) { Dir.mktmpdir }
  let(:lifecycle) { File.join(root, ".workspace-events.jsonl") }
  let(:hook_dir) { File.join(root, ".events") }
  let(:output) { StringIO.new }
  let(:clock) { double(now: Time.utc(2026, 10, 17, 13, 0, 0)) }
  let(:writes) { [] }
  let(:sleeper) { ->(_seconds) { writes.shift&.call } }
  let(:command) do
    described_class.new(output: output, clock: clock, sleeper: sleeper,
      stream_factory: -> { Workspace::EventStream.new(lifecycle_path: lifecycle, hook_dir: hook_dir, clock: clock) })
  end

  before { FileUtils.mkdir_p(hook_dir) }
  after { FileUtils.remove_entry(root) }

  def hook(type, seq, tool: "Bash")
    File.open(File.join(hook_dir, "proj.jsonl"), "a") do |f|
      f.puts JSON.generate("type" => type, "at" => "2026-10-17T12:00:0#{seq}.000Z", "workspace" => "proj", "pane_id" => "%1",
        "boot_id" => "B", "seq" => seq, "tool" => tool)
    end
  end

  def life(type)
    File.open(lifecycle, "a") do |f|
      f.puts JSON.generate("timestamp" => "2026-10-17T12:00:05.000Z", "type" => type, "project" => "proj", "data" => {"workspace" => "proj", "status" => "active"})
    end
  end

  def json_lines
    output.string.lines.map { |line| JSON.parse(line) }
  end

  it "prints what is kept as one document with the cursor after it" do
    hook("tool_started", 1)
    life("plan_changed")

    command.call(json: true)

    document = JSON.parse(output.string)
    expect(document).to include("schema_version" => 1, "ok" => true)
    expect(document["events"].map { |e| e["type"] }).to eq(%w[tool_started plan_changed])
    expect(document["cursor"]).to eq(document["events"].last["cursor"])
  end

  it "keeps only the types asked for, and its cursor still covers the lines left out" do
    hook("tool_started", 1)
    hook("tool_finished", 2)

    command.call(json: true, types: ["tool_started"])
    document = JSON.parse(output.string)
    expect(document["events"].map { |e| e["type"] }).to eq(%w[tool_started])

    output.reopen(+"")
    command.call(json: true, since: document["cursor"])
    expect(JSON.parse(output.string)["events"]).to eq([])
  end

  it "follows: a follow_started line with a cursor first, then each new line as it is written" do
    hook("tool_started", 1)
    writes << -> { hook("tool_finished", 2) } << -> { life("plan_changed") }

    command.call(follow: true, json: true, max_polls: 3)

    lines = json_lines
    expect(lines.first).to include("type" => "follow_started", "source" => "stream", "at" => "2026-10-17T13:00:00.000Z")
    expect(lines.first["cursor"]).to start_with("1.")
    expect(lines.drop(1).map { |l| [l["source"], l["type"]] }).to eq([%w[hook tool_finished], %w[lifecycle plan_changed]])
  end

  it "resumes from a follower's last cursor without repeating or dropping a line" do
    hook("tool_started", 1)
    command.call(follow: true, json: true, max_polls: 1)
    cursor = json_lines.first["cursor"]
    hook("tool_finished", 2)

    output.reopen(+"")
    command.call(follow: true, json: true, since: cursor, max_polls: 1)

    expect(json_lines.map { |l| [l["type"], l["seq"]] }).to eq([["follow_started", nil], ["tool_finished", 2]])
  end

  it "always prints gap lines, whatever --types says" do
    hook("tool_started", 1)
    command.call(json: true)
    cursor = JSON.parse(output.string)["cursor"]
    path = File.join(hook_dir, "proj.jsonl")
    2.times do |n|
      File.rename(path, "#{path}.1")
      hook("tool_started", 3 + n)
    end

    output.reopen(+"")
    command.call(json: true, since: cursor, types: ["plan_changed"])

    expect(JSON.parse(output.string)["events"].map { |e| e["type"] }).to eq(["gap"])
  end

  it "prints readable lines without --json" do
    hook("tool_started", 1, tool: "Edit")
    life("plan_changed")

    command.call

    expect(output.string.lines.map(&:chomp)).to eq([
      "2026-10-17T12:00:01.000Z  proj  tool_started  pane_id=%1  tool=Edit",
      "2026-10-17T12:00:05.000Z  proj  plan_changed  workspace=proj  status=active"
    ])
  end

  it "blanks control characters in readable lines" do
    hook("tool_started", 1, tool: "Ed\e[31mit")

    command.call

    expect(output.string).to include("tool=Ed [31mit")
    expect(output.string).not_to include("\e")
  end

  it "reports a file that can't be read mid-follow as an error" do
    stream = instance_double(Workspace::EventStream, open: [], cursor_string: "1.x")
    allow(stream).to receive(:read).and_raise(Errno::EIO)
    failing = described_class.new(output: output, clock: clock, sleeper: sleeper, stream_factory: -> { stream })

    expect { failing.call(follow: true, json: true, max_polls: 1) }.to raise_error(Workspace::Error, /could not read the event files/)
  end

  describe "--name" do
    def hook_for(workspace, type, seq)
      File.open(File.join(hook_dir, "#{workspace}.jsonl"), "a") do |f|
        f.puts JSON.generate("type" => type, "at" => "2026-10-17T12:00:0#{seq}.000Z", "workspace" => workspace, "pane_id" => "%1",
          "boot_id" => "B", "seq" => seq, "tool" => "Bash")
      end
    end

    before do
      hook_for("proj", "tool_started", 1)
      hook_for("proj-feature", "tool_started", 2)
      hook_for("other", "tool_finished", 3)
      life("plan_changed")
    end

    it "keeps only that workspace's hook and lifecycle lines, by exact name" do
      command.call(json: true, name: "proj")

      events = JSON.parse(output.string)["events"]
      expect(events.map { |e| [e["type"], e["workspace"]] }).to eq([%w[tool_started proj], %w[plan_changed proj]])
    end

    it "combines with --types" do
      command.call(json: true, name: "proj", types: ["plan_changed"])

      expect(JSON.parse(output.string)["events"].map { |e| e["type"] }).to eq(%w[plan_changed])
    end

    it "combines with --since, and the cursor still covers the lines left out" do
      command.call(json: true, name: "other")
      cursor = JSON.parse(output.string)["cursor"]
      hook_for("proj", "tool_finished", 4)
      hook_for("other", "tool_started", 5)
      output.reopen(+"")

      command.call(json: true, name: "other", since: cursor)

      expect(JSON.parse(output.string)["events"].map { |e| [e["type"], e["workspace"]] }).to eq([%w[tool_started other]])
    end

    it "filters a follower, and still prints follow_started" do
      writes << -> do
        hook_for("proj", "tool_finished", 4)
        hook_for("other", "tool_finished", 5)
      end

      command.call(follow: true, json: true, name: "proj", max_polls: 2)

      lines = output.string.lines.map { |l| JSON.parse(l) }
      expect(lines.map { |l| [l["type"], l["workspace"]] }).to eq([["follow_started", nil], %w[tool_finished proj]])
    end
  end

  it "stops quietly when the reader goes away" do
    allow(output).to receive(:puts).and_raise(Errno::EPIPE)

    expect { command.call(follow: true, json: true, max_polls: 1) }.not_to raise_error
  end

  it "refuses a cursor it can't read" do
    expect { command.call(json: true, since: "bogus") }.to raise_error(Workspace::EventStream::InvalidCursor)
  end
end
