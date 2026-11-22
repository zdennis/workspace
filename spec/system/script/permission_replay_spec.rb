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

  def request(seq, command, tool: "Bash", workspace: "ws")
    JSON.generate("type" => "permission_requested", "at" => "2026-11-21T10:00:0#{seq}Z", "workspace" => workspace,
      "pane_id" => "%1", "seq" => seq, "tool" => tool, "agent_id" => nil, "input" => command)
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
    expect(data["counts"]).to include("requests" => 1, "allowed_candidate" => 1, "allowed_today" => 0)
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
    expect(data["unsafe_allowed"].map { |r| r["seq"] }).to eq([1])
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
    expect(data.keys).to eq(%w[requests counts unsafe_allowed])
    expect(data["requests"].first.keys).to include("at", "workspace", "seq", "mark", "today", "candidate", "reason", "command")
    expect(data["counts"].keys).to eq(%w[requests allowed_today allowed_candidate unsafe_allowed])
  end

  it "prints a text table with counts" do
    write_log(request(1, "bundle exec rspec x_spec.rb"))
    write_rules(allow_rspec)
    out, _, code = run_script("--file", log, "--rules", rules_file)
    expect(code).to eq(0)
    expect(out).to include("requests: 1", "allowed candidate: 1", "bundle exec rspec x_spec.rb")
  end

  it "fails with a message and exit 2 for an invalid rules file" do
    write_log(request(1, "ls"))
    File.write(rules_file, YAML.dump("rules" => [{"tool" => "Bash", "action" => "maybe"}]))
    out, err, code = run_script("--file", log, "--rules", rules_file)
    expect(code).to eq(2)
    expect(out).to be_empty
    expect(err).to include("rules[0]")
  end
end
