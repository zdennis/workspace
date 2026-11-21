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

  it "appends the workflow nudger's decision lines with a null pane and the envelope every line carries" do
    %w[workflow_advance_started workflow_run_skipped workflow_sweep_started workflow_process_exited].each_with_index do |type, i|
      expect(log.append(type, nil, "run_id" => "wr_1")).to include("type" => type, "pane_id" => nil, "boot_id" => "BOOT1", "seq" => i + 1, "run_id" => "wr_1")
    end
    expect(lines.map { |l| l["seq"] }).to eq([1, 2, 3, 4])
  end

  it "times a finish from its start, by pane and tool use id" do
    log.record(event("tool_start", tool: "Bash", tool_use_id: "toolu_1"))
    seconds[0] = 112.3456
    log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_1", ok: true))

    expect(lines.last).to include("type" => "tool_finished", "seq" => 2, "tool" => "Bash", "ok" => true, "duration_ms" => 12346)
    expect(lines.last).not_to have_key("path")
  end

  it "keeps a sha256 on a tool finish when it is 64 hex characters, and drops any other value" do
    hash = "ab" * 32
    log.record(event("tool_use", tool: "Write", tool_use_id: "toolu_1", ok: true, sha256: hash))
    log.record(event("tool_use", tool: "Write", tool_use_id: "toolu_2", ok: true, sha256: "xyz"))
    log.record(event("tool_use", tool: "Write", tool_use_id: "toolu_3", ok: true, sha256: "ab" * 33))
    log.record(event("tool_use", tool: "Write", tool_use_id: "toolu_4", ok: true, sha256: 7))

    expect(lines.map { |l| l["sha256"] }).to eq([hash, nil, nil, nil])
    expect(lines.last).not_to have_key("sha256")
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
    log = described_class.new(dir: dir, workspace: "Proj", boot_id: "BOOT1", clock: clock, monotonic: monotonic, max_open_tools: 2)
    %w[a b c].each { |id| log.record(event("tool_start", tool_use_id: id)) }
    log.record(event("tool_use", tool_use_id: "a"))
    log.record(event("tool_use", tool_use_id: "c"))

    expect(lines.last(2).map { |l| l["duration_ms"] }).to eq([nil, 0])
  end

  describe "permission requests" do
    def summary(rows = lines)
      rows.map { |l| l.slice("type", "seq", "tool", "agent_id", "outcome", "by", "wait_ms") }
    end

    it "writes a request, then its approval before the tool's finish, timed from the request" do
      log.record(event("tool_start", tool: "Bash", tool_use_id: "toolu_1", input: "rm -rf build"))
      log.record(event("permission_request", tool: "Bash", input: "rm -rf build"))
      seconds[0] = 104.2504
      log.record(event("tool_use", tool: "Bash", tool_use_id: "toolu_1", ok: true))

      expect(lines.map { |l| l["type"] }).to eq(%w[tool_started permission_requested permission_resolved tool_finished])
      expect(lines[1].except("at", "workspace", "boot_id")).to eq({"type" => "permission_requested", "pane_id" => "%2", "seq" => 2,
                                                                   "tool" => "Bash", "agent_id" => nil, "input" => "rm -rf build"})
      expect(lines[2].except("at", "workspace", "boot_id")).to eq({"type" => "permission_resolved", "pane_id" => "%2", "seq" => 3,
                                                                   "tool" => "Bash", "agent_id" => nil, "input" => "rm -rf build",
                                                                   "outcome" => "approved", "by" => "tool_use", "wait_ms" => 4250})
    end

    it "returns the resolved line along with the event's own lines" do
      log.record(event("permission_request", tool: "Bash"))

      expect(log.record(event("tool_use", tool: "Bash")).map { |l| l["type"] }).to eq(%w[permission_resolved tool_finished])
    end

    it "ends the main agent's request as denied on its stop or failed turn, and writes no line for the stop itself" do
      log.record(event("permission_request", tool: "Bash"))
      log.record(event("stop"))
      log.record(event("permission_request", tool: "Edit"))
      log.record(event("turn_failed"))

      expect(summary.map { |l| l.values_at("type", "tool", "outcome", "by") }).to eq([
        ["permission_requested", "Bash", nil, nil], ["permission_resolved", "Bash", "denied", "stop"],
        ["permission_requested", "Edit", nil, nil], ["permission_resolved", "Edit", "denied", "turn_failed"]
      ])
    end

    it "ends every pending request of the pane as interrupted on a prompt, a session start or a session end" do
      %w[user_prompt session_start session_end].each do |name|
        log.record(event("permission_request", tool: "Bash"))
        log.record(event("permission_request", tool: "Read", agent_id: "sub-1"))
        written = log.record(event(name))

        resolved = written.select { |l| l["type"] == "permission_resolved" }
        expect(resolved.map { |l| l.values_at("agent_id", "outcome", "by") }).to eq([[nil, "interrupted", name], ["sub-1", "interrupted", name]])
      end
    end

    it "ends a sub-agent's request on that sub-agent's stop, not on the main agent's or another sub-agent's" do
      log.record(event("permission_request", tool: "Read", agent_id: "sub-1"))
      log.record(event("stop"))
      log.record(event("stop", agent_id: "sub-1"))
      log.record(event("subagent_stop", agent_id: "sub-2"))
      log.record(event("subagent_stop", agent_id: "sub-1"))

      resolved = lines.select { |l| l["type"] == "permission_resolved" }
      expect(resolved.map { |l| l.values_at("agent_id", "outcome", "by") }).to eq([["sub-1", "denied", "subagent_stop"]])
    end

    it "approves only on the same agent's finish of the same tool" do
      log.record(event("permission_request", tool: "Bash"))
      log.record(event("tool_use", tool: "Read"))
      log.record(event("tool_use", tool: "Bash", agent_id: "sub-1"))

      expect(lines.map { |l| l["type"] }).to eq(%w[permission_requested tool_finished tool_finished])
      log.record(event("tool_use", tool: "Bash"))
      expect(lines.last(2).map { |l| l.values_at("type", "outcome") }).to eq([["permission_resolved", "approved"], ["tool_finished", nil]])
    end

    it "ends a pending request as superseded when the same agent asks again" do
      log.record(event("permission_request", tool: "Bash"))
      seconds[0] = 101.0
      log.record(event("permission_request", tool: "Edit"))

      expect(summary.map { |l| l.values_at("type", "tool", "outcome", "wait_ms") }).to eq([
        ["permission_requested", "Bash", nil, nil], ["permission_resolved", "Bash", "superseded", 1000], ["permission_requested", "Edit", nil, nil]
      ])
    end

    it "leaves another pane's request pending" do
      log.record(event("permission_request", tool: "Bash"))
      log.record(event("user_prompt", pane_id: "%3"))
      log.record(event("tool_use", tool: "Bash", pane_id: "%3"))

      expect(lines.map { |l| l["type"] }).to eq(%w[permission_requested prompt_submitted tool_finished])
    end

    it "forgets the oldest pending requests past its limit" do
      log = described_class.new(dir: dir, workspace: "Proj", boot_id: "BOOT1", clock: clock, monotonic: monotonic, max_pending_permissions: 2)
      %w[a b c].each { |id| log.record(event("permission_request", tool: "Bash", agent_id: id)) }
      written = log.record(event("user_prompt"))

      expect(written.select { |l| l["type"] == "permission_resolved" }.map { |l| l["agent_id"] }).to eq(%w[b c])
    end

    it "writes Codex's approval prompt, which arrives as a notification, as a request that its tool's finish approves" do
      log.record(event("notification", agent_kind: "codex", notification_type: "permission_request", tool: "Bash", input: "cargo test",
        message: "Approval requested for Bash"))
      seconds[0] = 102.0
      log.record(event("tool_use", agent_kind: "codex", tool: "Bash", tool_use_id: "c1", ok: true))

      expect(lines.map { |l| l.except("at", "workspace", "boot_id", "pane_id") }).to eq([
        {"type" => "permission_requested", "seq" => 1, "tool" => "Bash", "agent_id" => nil, "input" => "cargo test"},
        {"type" => "permission_resolved", "seq" => 2, "tool" => "Bash", "agent_id" => nil, "input" => "cargo test",
         "outcome" => "approved", "by" => "tool_use", "wait_ms" => 2000},
        {"type" => "tool_finished", "seq" => 3, "tool" => "Bash", "tool_use_id" => "c1", "agent_id" => nil, "ok" => true, "duration_ms" => nil}
      ])
    end

    it "ends Codex's approval prompt as denied on an Interrupt, which arrives as a stop" do
      log.record(event("notification", agent_kind: "codex", notification_type: "permission_request", tool: "Bash"))
      log.record(event("stop", agent_kind: "codex"))

      expect(lines.last).to include("type" => "permission_resolved", "outcome" => "denied", "by" => "stop")
    end

    it "caps a request's input and writes only the fields it knows" do
      log.record(event("permission_request", tool: "Bash", input: "ls " + "z" * 400, tool_input: {"command" => "secret"}, message: "secret"))

      expect(lines.last["input"].bytesize).to eq(300)
      expect(lines.last.keys).to eq(%w[type at workspace pane_id boot_id seq tool agent_id input])
      expect(File.read(log.path)).not_to include("secret")
    end
  end

  it "writes a Task start as a tool start and a sub-agent start" do
    log.record(event("subagent_start", tool: "Task", tool_use_id: "toolu_9", description: "Review the diff", subagent_type: "reviewer",
      agent: {"name" => "reviewer"}))

    expect(lines.map { |l| [l["type"], l["seq"]] }).to eq([["tool_started", 1], ["subagent_started", 2]])
    expect(lines.last).to include("agent_id" => nil, "tool_use_id" => "toolu_9", "description" => "Review the diff", "subagent_type" => "reviewer")
  end

  it "writes a sub-agent the agent names itself (Codex) as a sub-agent start alone, with its id" do
    log.record(event("subagent_start", subagent_id: "sub-7", subagent_type: "explorer", agent_kind: "codex"))

    expect(lines.map { |l| l["type"] }).to eq(["subagent_started"])
    expect(lines.last).to include("agent_id" => "sub-7", "subagent_type" => "explorer")
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
    expect(log.record(event("tool_start").merge("pane_id" => nil))).to eq([])
    expect(File.exist?(log.path)).to be(false)
  end

  it "writes a notification with its type and agent, and never its message" do
    written = log.record(event("notification", notification_type: "idle_prompt", message: "Claude is waiting for your secret input"))

    expect(written.map { |l| l.except("at", "workspace", "boot_id") }).to eq([
      {"type" => "notification", "pane_id" => "%2", "seq" => 1, "notification_type" => "idle_prompt", "agent_id" => nil}
    ])
    expect(File.read(log.path)).not_to include("secret")
  end

  it "leaves a pending permission request pending through a permission_prompt notification" do
    log.record(event("permission_request", tool: "Bash"))
    log.record(event("notification", notification_type: "permission_prompt", message: "Claude needs your permission to use Bash"))
    log.record(event("tool_use", tool: "Bash"))

    expect(lines.map { |l| l.values_at("type", "outcome") }).to eq([
      ["permission_requested", nil], ["notification", nil], ["permission_resolved", "approved"], ["tool_finished", nil]
    ])
  end

  it "writes only the fields it knows, cleaned and cut, whatever a sender adds" do
    log.record(event("tool_start", tool: "Ed\e[31mit" + "x" * 100, tool_input: {"command" => "secret"}, prompt: "secret", path: 5))

    line = lines.last
    expect(line["tool"]).to start_with("Ed [31mit")
    expect(line["tool"].length).to eq(described_class::MAX_NAME)
    expect(line).not_to have_key("path")
    expect(File.read(log.path)).not_to include("secret")
  end

  it "writes a tool call's input on a start and a finish, cleaned and capped again, and leaves it out when absent" do
    log.record(event("tool_start", tool: "Bash", tool_use_id: "t1", input: "ls\e[0m " + "z" * 400))
    log.record(event("tool_use", tool: "Bash", tool_use_id: "t1", input: "ls"))
    log.record(event("tool_use", tool: "Bash", tool_use_id: "t2", input: 5))

    expect(lines[0]["input"].bytesize).to eq(300)
    expect(lines[0]["input"]).to start_with("ls [0m z").and end_with("…")
    expect(lines[1]["input"]).to eq("ls")
    expect(lines[2]).not_to have_key("input")
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

  it "rotates at the size it is given" do
    one_kb = described_class.new(dir: dir, workspace: "Proj", boot_id: "B", clock: clock, rotate_threshold: Workspace::ByteSize.parse("1KB"))
    20.times { one_kb.record(event("tool_start", tool: "Read")) }

    expect(File.exist?("#{one_kb.path}.1")).to be(true)
    expect(File.size(one_kb.path)).to be <= 1024 + 200
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
