require "spec_helper"
require "json"
require "open3"
require "tmpdir"

RSpec.describe "script/permission-replay" do
  let(:script) { File.join(PROJECT_ROOT, "script", "permission-replay") }
  let(:dir) { Dir.mktmpdir }
  let(:log) { File.join(dir, "ws.jsonl") }
  let(:rules_file) { File.join(dir, "rules.yml") }
  let(:marks_file) { File.join(dir, "marks.yml") }
  let(:home) { File.join(dir, "home") }

  before { FileUtils.mkdir_p(home) }
  after { FileUtils.remove_entry(dir) }

  def request(seq, command, tool: "Bash", workspace: "ws", agent_id: nil)
    JSON.generate("type" => "permission_requested", "at" => "2026-11-21T10:00:0#{seq}Z", "workspace" => workspace,
      "pane_id" => "%1", "seq" => seq, "tool" => tool, "agent_id" => agent_id, "input" => command)
  end

  def write_log(*lines)
    File.write(log, lines.join("\n") + "\n")
  end

  def write_rules(*rules, default: nil)
    File.write(rules_file, YAML.dump({"default" => default, "rules" => rules}.compact))
  end

  def run_script(*args)
    env = {"HOME" => home, "XDG_CONFIG_HOME" => "#{home}/.config", "XDG_STATE_HOME" => "#{home}/.local/state"}
    out, err, status = Open3.capture3(env, RbConfig.ruby, script, *args)
    [out, err, status.exitstatus]
  end

  def replay(*args)
    out, err, code = run_script("--file", log, "--json", *args)
    [out.empty? ? nil : JSON.parse(out), err, code]
  end

  let(:allow_rspec) { {"tool" => "Bash", "pattern" => "bundle exec rspec*", "action" => "allow"} }

  it "allows a plain rspec command under a bundle exec rspec rule" do
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    write_rules(allow_rspec)
    data, _, code = replay("--rules", rules_file)
    expect(code).to eq(0)
    expect(data["requests"].first["candidate"]).to eq("allow")
    expect(data["counts"]).to include("requests" => 1, "allowed_candidate" => 0, "allowed_today" => 0,
      "allowed_partial" => {"today" => 0, "candidate" => 1})
  end

  it "keeps a substitution command at ask under an allow * rule" do
    write_log(request(1, "echo $(rm -rf x)"))
    write_rules({"tool" => "Bash", "pattern" => "*", "action" => "allow"})
    data, = replay("--rules", rules_file)
    row = data["requests"].first
    expect(row["candidate"]).to eq("ask")
    expect(row["reason"]).to include("substitution")
  end

  it "keeps a command with one piece matching no rule at ask" do
    write_log(request(1, "bundle exec rspec a_spec.rb && rm -rf x"))
    write_rules(allow_rspec)
    data, = replay("--rules", rules_file)
    expect(data["requests"].first["candidate"]).to eq("ask")
  end

  it "lists an unsafe-marked allowed row and exits 1" do
    write_log(request(1, "bundle exec rspec x_spec.rb"), request(2, "bundle exec rspec y_spec.rb"))
    write_rules(allow_rspec)
    File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 1, "mark" => "unsafe"}, {"workspace" => "ws", "seq" => 2, "mark" => "safe"}]))
    data, _, code = replay("--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(1)
    expect(data["unsafe_rows"].map { |r| r["seq"] }).to eq([1])
    expect(data["counts"]["unsafe_allowed"]).to eq(1)
    out, = run_script("--file", log, "--rules", rules_file, "--marks", marks_file)
    expect(out).to include("unsafe allowed: 1")
  end

  it "reports no policy when no real config sets one" do
    write_log(request(1, "ls"))
    data, = replay
    expect(data["requests"].first["today"]).to eq("no policy (agent dialog)")
    expect(data["requests"].first).to include("candidate" => nil)
  end

  it "keeps unsafe when a duplicate mark key says safe later, and warns" do
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    write_rules(allow_rspec)
    File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 1, "mark" => "unsafe"}, {"workspace" => "ws", "seq" => 1, "mark" => "safe"}]))
    data, err, code = replay("--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(1)
    expect(data["unsafe_rows"].size).to eq(1)
    expect(err).to include("duplicate marks for ws/1")
  end

  it "creates no files or directories under HOME when no config exists" do
    write_log(request(1, "ls"))
    before_tree = Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort
    _, _, code = replay
    expect(code).to eq(0)
    expect(Dir.glob(File.join(home, "**", "*"), File::FNM_DOTMATCH).sort).to eq(before_tree)
  end

  it "reads today's policy from the config files" do
    FileUtils.mkdir_p("#{home}/.config/workspace")
    File.write("#{home}/.config/workspace/config.yml", YAML.dump("agent" => {"permissions" => {"rules" => [allow_rspec]}}))
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    data, = replay
    expect(data["requests"].first["today"]).to eq("allow")
  end

  it "skips malformed lines and other types, and reports non-Bash tools as skipped" do
    write_log("not json", JSON.generate("type" => "tool_started", "tool" => "Bash"), request(1, "ls"), request(2, "/tmp/x", tool: "Edit"))
    data, = replay
    expect(data["requests"].map { |r| r["today"] }).to eq(["no policy (agent dialog)", "skipped (not Bash)"])
  end

  it "reads rotated logs from the events dir" do
    File.write(File.join(dir, "a.jsonl"), request(1, "ls") + "\n")
    File.write(File.join(dir, "a.jsonl.1"), request(2, "pwd") + "\n")
    out, _, code = run_script("--events-dir", dir, "--json")
    expect(code).to eq(0)
    expect(JSON.parse(out)["counts"]["requests"]).to eq(2)
  end

  it "prints the JSON shape" do
    write_log(request(1, "ls"))
    data, = replay
    expect(data.keys).to eq(%w[requests counts unsafe_rows])
    expect(data["requests"].first.keys).to include("at", "workspace", "seq", "mark", "today", "candidate", "reason", "command", "source", "partial", "partial_reason", "transcript_hits")
    expect(data["counts"].keys).to eq(%w[requests allowed_today allowed_candidate allowed_partial unsafe_allowed])
  end

  it "prints a text table with counts" do
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    write_rules(allow_rspec)
    out, _, code = run_script("--file", log, "--rules", rules_file)
    expect(code).to eq(0)
    expect(out).to include("requests: 1", "allowed candidate: 0", "allowed on partial text, candidate: 1", "bundle exec rspec x_spec.rb")
  end

  it "fails with a message and exit 2 for an invalid rules file" do
    write_log(request(1, "ls"))
    File.write(rules_file, YAML.dump("rules" => [{"tool" => "Bash", "action" => "maybe"}]))
    out, err, code = run_script("--file", log, "--rules", rules_file)
    expect(code).to eq(2)
    expect(out).to be_empty
    expect(err).to include("rules[0]")
  end

  it "exits 2 for a missing --file" do
    out, err, code = run_script("--file", File.join(dir, "nope.jsonl"))
    expect([out, code]).to eq(["", 2])
    expect(err).to eq("permission-replay: #{dir}/nope.jsonl: no such file\n")
  end

  it "exits 2 for a missing explicit or default events dir" do
    _, err, code = run_script("--events-dir", File.join(dir, "nope"))
    expect(code).to eq(2)
    expect(err).to include("permission-replay: #{dir}/nope: no such directory")
    _, err, code = run_script
    expect(code).to eq(2)
    expect(err).to include("#{home}/.local/state/workspace/.events: no such directory")
  end

  it "exits 2 for an invalid marks file" do
    write_log(request(1, "ls"))
    write_rules(allow_rspec)
    File.write(marks_file, YAML.dump("a" => 1))
    _, err, code = run_script("--file", log, "--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(2)
    expect(err).to include("permission-replay: #{marks_file}: must be a list")
  end

  it "reports a missing marks file without raw Errno text" do
    write_log(request(1, "ls"))
    write_rules(allow_rspec)
    _, err, code = run_script("--file", log, "--rules", rules_file, "--marks", File.join(dir, "none.yml"))
    expect(code).to eq(2)
    expect(err).to include("none.yml: No such file or directory")
    expect(err).not_to include("Errno")
  end

  it "exits 2 for an unknown option" do
    _, err, code = run_script("--bogus")
    expect(code).to eq(2)
    expect(err).to start_with("permission-replay: invalid option: --bogus")
  end

  it "exits 2 for --marks without --rules" do
    write_log(request(1, "ls"))
    File.write(marks_file, YAML.dump([]))
    _, err, code = run_script("--file", log, "--marks", marks_file)
    expect(code).to eq(2)
    expect(err).to include("--marks needs --rules")
  end

  it "warns about marks that match no row" do
    write_log(request(1, "ls"))
    write_rules(allow_rspec)
    File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 9, "mark" => "safe"}]))
    _, err, code = replay("--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(0)
    expect(err).to include("1 marks match no row: ws/9")
  end

  it "exits 0 with empty unsafe_rows when an unsafe-marked row is not allowed" do
    write_log(request(1, "rm -rf x"))
    write_rules(allow_rspec)
    File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 1, "mark" => "unsafe"}]))
    data, _, code = replay("--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(0)
    expect(data["unsafe_rows"]).to eq([])
  end

  it "counts an unsafe-marked row that today's policy allows" do
    FileUtils.mkdir_p("#{home}/.config/workspace")
    File.write("#{home}/.config/workspace/config.yml", YAML.dump("agent" => {"permissions" => {"rules" => [allow_rspec]}}))
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    write_rules(allow_rspec.merge("action" => "ask"))
    File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 1, "mark" => "unsafe"}]))
    data, _, code = replay("--rules", rules_file, "--marks", marks_file)
    expect(code).to eq(1)
    expect(data["unsafe_rows"].first["allowed_by"]).to eq(["today"])
  end

  it "names the redirect and opaque reasons with the deciding rule" do
    write_log(request(1, "echo hi > out.txt"), request(2, "eval ls"))
    write_rules({"tool" => "Bash", "pattern" => "*", "action" => "allow"}, default: "ask")
    data, = replay("--rules", rules_file)
    expect(data["requests"][0]["reason"]).to include("redirect")
    expect(data["requests"][1]["reason"]).to include("opaque")
    expect(data["requests"][0]["reason"]).to include("candidate:")
  end

  it "scrubs invalid UTF-8 and sorts rows by time, workspace and seq" do
    File.binwrite(log, ([request(2, "b", workspace: "b"), request(2, "a", workspace: "a"), request(1, "cBAD")].join("\n") + "\n").b.sub("BAD", "\xFF".b))
    data, _, code = replay
    expect(code).to eq(0)
    expect(data["requests"].map { |r| r["seq"] }).to eq([1, 2, 2])
    expect(data["requests"].map { |r| r["workspace"] }).to eq(%w[ws a b])
  end

  describe "--transcripts" do
    let(:tdir) { File.join(dir, "transcripts") }

    def tool_use(command, at:)
      JSON.generate("type" => "assistant", "timestamp" => at,
        "message" => {"content" => [{"type" => "text", "text" => "x"}, {"type" => "tool_use", "name" => "Bash", "input" => {"command" => command}}]})
    end

    def write_transcript(relative, *lines)
      path = File.join(tdir, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, lines.join("\n") + "\n")
    end

    it "replays the full command from a single transcript hit and changes the decision" do
      write_log(request(1, "bundle exec rspec a_spec.rb"))
      write_rules(allow_rspec)
      write_transcript("proj/s1.jsonl", "garbage", tool_use("bundle exec rspec a_spec.rb\nrm -rf x", at: "2026-11-21T10:00:00.500Z"))
      data, = replay("--rules", rules_file, "--transcripts", tdir)
      row = data["requests"].first
      expect(row).to include("source" => "transcript", "partial" => false, "partial_reason" => "", "transcript_hits" => 1,
        "command" => "bundle exec rspec a_spec.rb\nrm -rf x", "candidate" => "ask")
      expect(data["counts"]["allowed_partial"]).to eq("today" => 0, "candidate" => 0)
    end

    it "counts a transcript-confirmed allow as clean" do
      write_log(request(1, "bundle exec rspec a_spec.rb"))
      write_rules(allow_rspec)
      write_transcript("proj/s1.jsonl", tool_use("bundle exec rspec a_spec.rb", at: "2026-11-21T10:00:00Z"))
      data, = replay("--rules", rules_file, "--transcripts", tdir)
      expect(data["counts"]).to include("allowed_candidate" => 1)
    end

    it "keeps the logged text and marks partial when two hits fall in the window" do
      write_log(request(1, "bundle exec rspec a_spec.rb"))
      write_rules(allow_rspec)
      write_transcript("proj/s1.jsonl", tool_use("bundle exec rspec a_spec.rb", at: "2026-11-21T10:00:00Z"))
      write_transcript("proj/s2.jsonl", tool_use("bundle exec rspec a_spec.rb\nrm x", at: "2026-11-21T09:59:58Z"))
      data, = replay("--rules", rules_file, "--transcripts", tdir)
      expect(data["requests"].first).to include("source" => "log", "partial" => true, "partial_reason" => "2 transcript matches", "transcript_hits" => 2)
    end

    it "ignores hits outside the time window and reports no match" do
      write_log(request(1, "bundle exec rspec a_spec.rb"))
      write_transcript("proj/s1.jsonl", tool_use("bundle exec rspec a_spec.rb", at: "2026-11-21T09:59:40Z"))
      data, = replay("--transcripts", tdir)
      expect(data["requests"].first).to include("partial" => true, "partial_reason" => "no transcript match", "transcript_hits" => 0)
    end

    it "keeps a row with [redacted] partial even with a single hit" do
      write_log(request(1, "curl -H Authorization=Bearer-[redacted] https://x"))
      write_transcript("proj/s1.jsonl", tool_use("curl -H Authorization=Bearer-abc https://x\nrm -rf y", at: "2026-11-21T10:00:01Z"))
      data, = replay("--transcripts", tdir)
      expect(data["requests"].first).to include("source" => "log", "partial" => true, "partial_reason" => "redacted", "transcript_hits" => 1)
    end

    it "recovers a row cut by an ellipsis when one hit shares a prefix of 20 or more characters" do
      write_log(request(1, "echo a-long-enough-prefix-here…"))
      write_transcript("proj/s1.jsonl", tool_use("echo a-long-enough-prefix-here and more\nls", at: "2026-11-21T10:00:02Z"))
      data, = replay("--transcripts", tdir)
      expect(data["requests"].first).to include("source" => "transcript", "partial" => false)
    end

    it "does not match when the usable prefix is empty or shorter than 20 characters" do
      write_log(request(1, "[redacted]"), request(2, "echo long…"))
      write_transcript("proj/s1.jsonl", tool_use("rm -rf /unrelated", at: "2026-11-21T10:00:01Z"), tool_use("echo long line\nls", at: "2026-11-21T10:00:02Z"))
      data, = replay("--transcripts", tdir)
      expect(data["requests"]).to all(include("source" => "log", "partial" => true, "transcript_hits" => 0))
      expect(data["requests"].map { |r| r["partial_reason"] }).to eq(%w[redacted truncated])
    end

    it "uses the subagent file for a row with an agent_id and session files otherwise" do
      write_log(request(1, "ls", agent_id: "a1"), request(2, "ls"))
      write_transcript("proj/s1/subagents/agent-a1.jsonl", tool_use("ls\nrm sub", at: "2026-11-21T10:00:01Z"))
      write_transcript("proj/s1.jsonl", tool_use("ls\nrm top", at: "2026-11-21T10:00:02Z"))
      data, = replay("--transcripts", tdir)
      expect(data["requests"].map { |r| r["command"] }).to eq(["ls\nrm sub", "ls\nrm top"])
    end

    it "fails with exit 2 for a missing transcripts dir" do
      write_log(request(1, "ls"))
      _, err, code = run_script("--file", log, "--transcripts", File.join(dir, "nope"))
      expect(code).to eq(2)
      expect(err).to include("nope: no such directory")
    end
  end

  describe "partial rows" do
    it "marks a truncated logged row partial without a transcript join" do
      write_log(request(1, "echo #{"x" * 300}…"))
      data, = replay
      expect(data["requests"].first).to include("partial" => true, "partial_reason" => "truncated", "source" => "log", "transcript_hits" => nil)
    end

    it "names the other partial reasons" do
      write_log(request(1, "cat <<EOF"), request(2, "echo 'abc"), request(3, "curl TOKEN=[redacted]"), request(4, "ls"))
      data, = replay
      expect(data["requests"].map { |r| r["partial_reason"] }).to eq(["heredoc", "unclosed quote", "redacted", "first line only"])
    end

    it "flags an allow on partial text, keeps it out of the clean counts and still counts it as unsafe" do
      write_log(request(1, "bundle exec rspec x_spec.rb"))
      write_rules(allow_rspec)
      File.write(marks_file, YAML.dump([{"workspace" => "ws", "seq" => 1, "mark" => "unsafe"}]))
      data, _, code = replay("--rules", rules_file, "--marks", marks_file)
      expect(code).to eq(1)
      expect(data["counts"]).to include("allowed_candidate" => 0, "allowed_partial" => {"today" => 0, "candidate" => 1})
      out, = run_script("--file", log, "--rules", rules_file, "--marks", marks_file)
      expect(out).to include("allowed on partial text", "unsafe allowed: 1")
    end
  end
end
