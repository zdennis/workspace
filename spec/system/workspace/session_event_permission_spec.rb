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
      write_fake_tmux
      example.run
    end
  end

  def write_config(yaml)
    path = File.join(@home, ".config", "workspace", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, yaml)
  end

  def state_dir = File.join(@home, "state", "workspace")

  # A tmux that answers for pane %99 in session permws, so a binding there reads as live and no real server is asked.
  def write_fake_tmux
    bin = File.join(@home, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "tmux"), <<~'SH')
      #!/bin/sh
      for a in "$@"; do last="$a"; done
      case "$last" in
        '#{session_name}') echo permws ;;
        '#{session_name}:#{window_index}.#{pane_index}') echo permws:0.0 ;;
        '#{pid}') echo 4242 ;;
        *) exit 1 ;;
      esac
    SH
    File.chmod(0o755, File.join(bin, "tmux"))
  end

  def bind_run(state: "running", hang_guard: nil)
    runs = File.join(state_dir, ".workflows", "runs")
    FileUtils.mkdir_p(runs)
    definition = {"steps" => [{"id" => "fix"}]}
    definition["hang_guard"] = hang_guard if hang_guard
    File.write(File.join(runs, "wr_1.json"), JSON.generate("id" => "wr_1", "workflow" => "w", "workspace" => "permws", "current" => "fix",
      "state" => state, "definition" => definition, "steps" => {"fix" => {"attempts" => []}}))
    File.write(File.join(state_dir, "bindings.json"), JSON.generate("%99" => {"kind" => "run", "id" => "wr_1", "step" => "fix", "attempt" => 1,
                                                                              "session" => "permws", "pane_slot" => "permws:0.0", "workspace" => "permws", "pane_id" => "%99", "bound_at" => "2026-11-23T00:00:00Z"}))
  end

  def hang_guard_counts
    JSON.parse(File.read(File.join(state_dir, "hang-guard.json"))).transform_values { |entry| entry["count"] }
  end

  def env
    {"PATH" => "#{File.join(@home, "bin")}:#{ENV.fetch("PATH")}", "HOME" => @home, "TMUX_PANE" => "%99",
     "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config"),
     "BUNDLE_GEMFILE" => ENV["BUNDLE_GEMFILE"], "BUNDLE_PATH" => ENV["BUNDLE_PATH"]}.compact
  end

  def session_event(*args, tool: "Bash", command: "ls")
    payload = JSON.generate("hook_event_name" => "PermissionRequest", "session_id" => "s1", "cwd" => @home,
      "tool_name" => tool, "tool_input" => (tool == "Bash") ? {"command" => command} : {})
    Open3.capture3(env, RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace"), "session-event", "--workspace", "permws", *args,
      stdin_data: payload, unsetenv_others: true, chdir: @home)
  end

  def hint(where, shape) = Workspace::Commands::SessionEvent::HANG_GUARD_HINTS.fetch([where, shape])

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

  it "prints nothing for an ask with the hang guard off" do
    write_config("agent:\n  permissions:\n    default: ask\n    hang_guard: \"off\"\n")

    out, err, status = session_event

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  it "prints nothing when no policy is configured and the hang guard is off" do
    write_config("agent:\n  permissions:\n    hang_guard: \"off\"\n")

    out, err, status = session_event

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  it "denies an undecided compound Bash call with the unbound hint when nothing is configured, counted under the pane" do
    out, err, status = session_event(command: "for f in $(ls); do echo $f; done")

    expect([err, status.exitstatus]).to eq(["", 0])
    expect(out.lines.size).to eq(1)
    expect(decision_of(out)["decision"]).to eq("behavior" => "deny", "message" => hint(:unbound, :compound))
    expect(out).not_to match(/updatedInput|updatedPermissions|interrupt/)
    expect(hang_guard_counts).to eq("pane:%99:s1" => 1)
  end

  it "never denies AskUserQuestion in an unbound pane" do
    out, err, status = session_event(tool: "AskUserQuestion")

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  it "prints nothing, and exits 0, when the permissions setting is broken and the hang guard is off" do
    write_config("agent:\n  permissions:\n    default: sometimes\n    rules: nope\n    hang_guard: \"off\"\n")

    out, _err, status = session_event

    expect([out, status.exitstatus]).to eq(["", 0])
  end

  it "shows the dialog in an unbound pane when a config file can't be parsed" do
    write_config("agent: [unclosed\n")

    out, _err, status = session_event

    expect([out, status.exitstatus]).to eq(["", 0])
  end

  it "shows the dialog for a person's own ask rule in an unbound pane" do
    write_config("agent:\n  permissions:\n    rules:\n      - {tool: Bash, action: ask}\n")

    out, err, status = session_event

    expect([out, err, status.exitstatus]).to eq(["", "", 0])
  end

  describe "in a pane bound to a live run" do
    it "denies twice under the step's attempt with the hint for the tool, then lets the dialog show" do
      bind_run

      first, = session_event(command: "ls | while read f; do echo \"$f\"; done")
      second, = session_event(tool: "AskUserQuestion")
      third, err, status = session_event

      expect(decision_of(first)["decision"]["message"]).to eq(hint(:bound, :compound))
      expect(decision_of(second)["decision"]["message"]).to eq(hint(:bound, :other))
      expect([third, err, status.exitstatus]).to eq(["", "", 0])
      expect(hang_guard_counts).to eq("run:wr_1:fix:1" => 2)
    end

    it "guards at the defaults when a config file can't be parsed, and a person's own ask rule too" do
      bind_run
      write_config("agent: [unclosed\n")
      broken, = session_event

      write_config("agent:\n  permissions:\n    rules:\n      - {tool: Bash, action: ask}\n")
      asked, = session_event

      expect(decision_of(broken)["decision"]["message"]).to eq(hint(:bound, :other))
      expect(decision_of(asked)["decision"]["behavior"]).to eq("deny")
    end

    it "lets the run's hang_guard: off win over the config" do
      write_config("agent:\n  permissions:\n    hang_guard: deny_with_hint\n")
      bind_run(hang_guard: "off")

      out, err, status = session_event

      expect([out, err, status.exitstatus]).to eq(["", "", 0])
    end

    it "treats a pane bound to a finished run as unbound" do
      bind_run(state: "completed")

      out, _err, _status = session_event(tool: "ExitPlanMode")
      bash, = session_event

      expect(out).to eq("")
      expect(decision_of(bash)["decision"]["behavior"]).to eq("deny")
      expect(hang_guard_counts).to eq("pane:%99:s1" => 1)
    end
  end

  it "answers Codex's request with the same reply and no reserved field" do
    write_config("agent:\n  permissions:\n    default: allow\n")

    out, _err, status = session_event("--agent", "codex")

    expect(status.exitstatus).to eq(0)
    expect(out.lines.size).to eq(1)
    expect(decision_of(out)["decision"]).to eq("behavior" => "allow")
  end
end
