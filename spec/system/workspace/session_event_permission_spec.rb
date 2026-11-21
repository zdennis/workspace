require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"

# Runs the real `bin/workspace session-event` with a PermissionRequest on stdin, in a
# throwaway HOME, and reads what an agent would read from its stdout.
RSpec.describe "workspace session-event answering a PermissionRequest" do
  around do |example|
    Dir.mktmpdir("wsp", "/tmp") do |dir|
      @home = File.realpath(dir)
      example.run
    end
  end

  def write_config(yaml)
    path = File.join(@home, ".config", "workspace", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, yaml)
  end

  def env
    {"PATH" => ENV.fetch("PATH"), "HOME" => @home, "TMUX_PANE" => "%99",
     "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config"),
     "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"], "BUNDLE_PATH" => ENV["BUNDLE_PATH"]}.compact
  end

  def session_event(*args, tool: "Bash", command: "ls")
    payload = JSON.generate("hook_event_name" => "PermissionRequest", "session_id" => "s1", "cwd" => @home,
      "tool_name" => tool, "tool_input" => {"command" => command})
    Open3.capture3(env, RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace"), "session-event", "--workspace", "permws", *args,
      stdin_data: payload, unsetenv_others: true, chdir: @home)
  end

  def decision_of(out)
    JSON.parse(out).fetch("hookSpecificOutput")
  end

  it "prints exactly one allow line for a default of allow" do
    write_config("agent:\n  permissions:\n    default: allow\n")

    out, err, status = session_event

    expect(status.exitstatus).to eq(0)
    expect(out.lines.size).to eq(1)
    expect(decision_of(out)).to eq("hookEventName" => "PermissionRequest", "decision" => {"behavior" => "allow"})
    expect(err).to eq("")
  end

  it "prints one deny line naming the rule for a matching deny rule" do
    write_config("agent:\n  permissions:\n    default: allow\n    rules:\n      - {tool: Bash, pattern: \"rm *\", action: deny}\n")

    out, _err, status = session_event(command: "rm -rf x")

    expect(status.exitstatus).to eq(0)
    expect(out.lines.size).to eq(1)
    expect(decision_of(out)["decision"]).to eq("behavior" => "deny", "message" => "Denied by workspace permission policy (global:rules[0])")
    expect(out).not_to match(/updatedInput|updatedPermissions|interrupt/)
  end

  it "names the project layer's rule when a project file holds the deny rule" do
    path = File.join(@home, ".config", "workspace", "projects", "permws.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "agent:\n  permissions:\n    rules:\n      - {tool: Bash, pattern: \"rm *\", action: deny}\n")

    out, err, status = session_event(command: "rm -rf x")

    expect([err, status.exitstatus]).to eq(["", 0])
    expect(decision_of(out)["decision"]).to eq("behavior" => "deny", "message" => "Denied by workspace permission policy (project:rules[0])")
  end

  it "prints nothing for an ask" do
    write_config("agent:\n  permissions:\n    default: ask\n")

    out, err, status = session_event

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  it "prints nothing when no policy is configured" do
    out, err, status = session_event

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  it "prints nothing, and exits 0, when the permissions setting is broken" do
    write_config("agent:\n  permissions:\n    default: sometimes\n    rules: nope\n")

    out, _err, status = session_event

    expect([out, status.exitstatus]).to eq(["", 0])
  end

  it "prints nothing when a config file can't be parsed" do
    write_config("agent: [unclosed\n")

    out, _err, status = session_event

    expect([out, status.exitstatus]).to eq(["", 0])
  end

  it "answers Codex's request with the same reply and no reserved field" do
    write_config("agent:\n  permissions:\n    default: allow\n")

    out, _err, status = session_event("--agent", "codex")

    expect(status.exitstatus).to eq(0)
    expect(out.lines.size).to eq(1)
    expect(decision_of(out)["decision"]).to eq("behavior" => "allow")
  end
end
