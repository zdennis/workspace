require "tmpdir"

RSpec.describe Workspace::HookEventLog do
  let(:dir) { File.join(Dir.mktmpdir, ".events") }
  let(:now) { Time.utc(2026, 10, 17, 12, 0, 0) }
  let(:clock) { double(now: now) }
  let(:seconds) { [100.0] }
  let(:monotonic) { -> { seconds.first } }
  let(:log) { described_class.new(dir: dir, workspace: "Proj", boot_id: "BOOT1", clock: clock, monotonic: monotonic) }

  after { FileUtils.remove_entry(File.dirname(dir)) }

  def lines(path = log.path)
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def event(name, **fields)
    {"type" => "session_event", "workspace" => "Proj", "event" => name, "pane_id" => "%2"}.merge(fields.transform_keys(&:to_s))
  end

  it "writes a tool start with the envelope every line carries" do
    log.record(event("tool_start", tool: "Edit", tool_use_id: "toolu_1", path: "src/x.ts"))

    expect(lines).to eq([{"type" => "tool_started", "at" => "2026-10-17T12:00:00.000Z", "workspace" => "Proj", "pane_id" => "%2",
                          "boot_id" => "BOOT1", "seq" => 1, "tool" => "Edit", "tool_use_id" => "toolu_1", "agent_id" => nil, "path" => "src/x.ts"}])
    expect(File.stat(log.path).mode & 0o777).to eq(0o600)
    expect(File.stat(dir).mode & 0o777).to eq(0o700)
  end

  it "times a finish from its start, by pane and tool use id" do
    log.record(event("tool_start", tool: "Bash", tool_use_id: "toolu_1"))
    seconds[0] = 112.3456
    log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_1", ok: true))

    expect(lines.last).to include("type" => "tool_finished", "seq" => 2, "tool" => "Bash", "ok" => true, "duration_ms" => 12346)
    expect(lines.last).not_to have_key("path")
  end

  it "prefers the payload's own duration, and reports none when it saw no start" do
    log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_1", duration_ms: 40))
    log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_2", ok: false))

    expect(lines.map { |l| l.values_at("duration_ms", "ok") }).to eq([[40, true], [nil, false]])
  end

  it "doesn't pair a finish with another pane's start" do
    log.record(event("tool_start", tool: "Bash", tool_use_id: "toolu_1"))
    log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_1", pane_id: "%3"))

    expect(lines.last["duration_ms"]).to be_nil
  end

  it "forgets the oldest open starts past its limit" do
    stub_const("#{described_class}::MAX_OPEN_TOOLS", 2)
    %w[a b c].each { |id| log.record(event("tool_start", tool_use_id: id)) }
    log.record(event("tool_use", tool_use_id: "a"))
    log.record(event("tool_use", tool_use_id: "c"))

    expect(lines.last(2).map { |l| l["duration_ms"] }).to eq([nil, 0])
  end

  it "writes a Task start as a tool start and a sub-agent start" do
    log.record(event("subagent_start", tool: "Task", tool_use_id: "toolu_9", description: "Review the diff", subagent_type: "reviewer",
      agent: {"name" => "reviewer"}))

    expect(lines.map { |l| [l["type"], l["seq"]] }).to eq([["tool_started", 1], ["subagent_started", 2]])
    expect(lines.last).to include("agent_id" => nil, "tool_use_id" => "toolu_9", "description" => "Review the diff", "subagent_type" => "reviewer")
  end

  it "writes sub-agent stops, session starts and ends, and prompts" do
    log.record(event("subagent_stop", agent_id: "sub-1"))
    log.record(event("session_start", kind: "claude", source: "resume"))
    log.record(event("session_end", kind: "claude", reason: "logout"))
    log.record(event("user_prompt", prompt: "deploy with password hunter2"))

    expect(lines.map { |l| l.except("at", "workspace", "pane_id", "boot_id") }).to eq([
      {"type" => "subagent_stopped", "seq" => 1, "agent_id" => "sub-1"},
      {"type" => "session_started", "seq" => 2, "kind" => "claude", "source" => "resume"},
      {"type" => "session_ended", "seq" => 3, "kind" => "claude", "reason" => "logout"},
      {"type" => "prompt_submitted", "seq" => 4}
    ])
    expect(File.read(log.path)).not_to include("hunter2")
  end

  it "writes nothing for events the stream doesn't carry, or without a pane" do
    expect(log.record(event("stop"))).to eq([])
    expect(log.record(event("notification", message: "needs permission"))).to eq([])
    expect(log.record(event("tool_start").merge("pane_id" => nil))).to eq([])
    expect(File.exist?(log.path)).to be(false)
  end

  it "writes only the fields it knows, cleaned and cut, whatever a sender adds" do
    log.record(event("tool_start", tool: "Ed\e[31mit" + "x" * 100, tool_input: {"command" => "secret"}, prompt: "secret", path: 5))

    line = lines.last
    expect(line["tool"]).to start_with("Ed [31mit")
    expect(line["tool"].length).to eq(described_class::MAX_NAME)
    expect(line).not_to have_key("path")
    expect(File.read(log.path)).not_to include("secret")
  end

  it "starts seq again for a new boot, in the same file" do
    log.record(event("user_prompt"))
    other = described_class.new(dir: dir, workspace: "Proj", boot_id: "BOOT2", clock: clock)
    other.record(event("user_prompt"))

    expect(lines.map { |l| l.values_at("boot_id", "seq") }).to eq([["BOOT1", 1], ["BOOT2", 1]])
  end

  it "rotates to .1 past the threshold, replacing the old .1, and keeps counting" do
    small = described_class.new(dir: dir, workspace: "Proj", boot_id: "B", clock: clock, rotate_threshold: 400)
    7.times { small.record(event("tool_start", tool: "Read")) }

    expect(lines("#{small.path}.1").map { |l| l["seq"] }).to eq([4, 5, 6])
    expect(lines(small.path).map { |l| l["seq"] }).to eq([7])
  end

  it "leaves the rotation to the writer holding the lock, and keeps appending" do
    small = described_class.new(dir: dir, workspace: "Proj", boot_id: "B", clock: clock, rotate_threshold: 200)
    small.record(event("tool_start", tool: "Read"))
    File.open("#{small.path}.lock", File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      2.times { small.record(event("tool_start", tool: "Read")) }
    end

    expect(File.exist?("#{small.path}.1")).to be(false)
    expect(lines(small.path).map { |l| l["seq"] }).to eq([1, 2, 3])
  end

  it "appends a line of a known type directly, and refuses an unknown one" do
    expect(log.append("prompt_submitted", "%4", {})).to include("seq" => 1, "pane_id" => "%4")
    expect(log.append("agent_said", "%4", {})).to be_nil
    expect(lines.size).to eq(1)
  end

  it "writes nothing for a workspace name that would leave the directory" do
    %w[../escape a/b .hidden].each do |name|
      unsafe = described_class.new(dir: dir, workspace: name, boot_id: "B", clock: clock)
      expect(unsafe.record(event("user_prompt"))).to eq([])
    end
    expect(Dir.exist?(dir)).to be(false)
  end

  it "never raises when the directory can't be made" do
    blocked = File.join(File.dirname(dir), "file")
    File.write(blocked, "")
    broken = described_class.new(dir: File.join(blocked, ".events"), workspace: "Proj", boot_id: "B", clock: clock)

    expect(broken.record(event("user_prompt"))).to eq([])
  end
end
