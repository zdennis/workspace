require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "socket"

# Runs each hook event twice from the same freshly seeded HOME: once through the old path (the whole
# CLI, as `bin/workspace` ran it before the fast entry) and once through `bin/workspace`, which takes
# the fast entry for a plain `session-event` line. Both runs must leave the same stdout, stderr, exit
# code, daemon message and files under HOME (ledger, delivery log, lock store and its audit log,
# event log, run events, bindings, the fake tmux's call log).
#
# Masked: ISO 8601 timestamps (`<time>`), which name the moment of each run. Nothing else is: both
# runs share one HOME path, the fake agent's pid and the fake tmux's answers.
RSpec.describe "workspace session-event old path vs fast path" do
  def old_path_script = 'require "workspace"; Workspace.build_cli.run(ARGV)'

  def timestamp = /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)/n

  around do |example|
    Dir.mktmpdir("wsp", "/tmp") do |dir|
      @root = File.realpath(dir)
      @bin = File.join(@root, "bin")
      FileUtils.mkdir_p(@bin)
      write_fake_tmux
      write_route_shim
      File.symlink("/bin/sleep", File.join(@bin, "claude"))
      @agent_pid = Process.spawn(File.join(@bin, "claude"), "30")
      example.run
    ensure
      if @agent_pid
        begin
          Process.kill("KILL", @agent_pid)
        rescue Errno::ESRCH
          nil
        end
        Process.wait(@agent_pid)
      end
    end
  end

  def write_fake_tmux
    path = File.join(@bin, "tmux")
    File.write(path, <<~'SH')
      #!/bin/sh
      echo "$*" >> "$HOME/tmux.log"
      for a in "$@"; do last="$a"; done
      case " $* " in
        *" display-message "*)
          case "$last" in
            '#{session_name}') echo proj ;;
            '#{pid}') echo 4242 ;;
            '#{pane_pid}') echo "$FAKE_PANE_PID" ;;
            '#{session_name}:#{window_index}.#{pane_index}') echo proj:0.0 ;;
          esac ;;
        *" show-option "*) echo proj ;;
      esac
      exit 0
    SH
    File.chmod(0o755, path)
  end

  # Loaded into the new path through RUBYOPT: says at exit which entry served the call, so a
  # `fast?` that refused every line would show here instead of passing every row as the whole CLI.
  def write_route_shim
    File.write(File.join(@bin, "route_shim.rb"), <<~SHIM)
      at_exit do
        route = if defined?(Workspace::Doctor) then "full"
        elsif defined?(Workspace::CLI::SessionEventEntry) then "fast"
        else "none"
        end
        File.write(ENV.fetch("ROUTE_REPORT"), route)
      end
    SHIM
  end

  def home = @home ||= File.join(@root, "h")

  def work = File.join(home, "work")

  def state_dir = File.join(home, "state", "workspace")

  def env(pane)
    {"PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "HOME" => home, "TMUX_PANE" => pane, "FAKE_PANE_PID" => @agent_pid.to_s,
     "XDG_STATE_HOME" => File.join(home, "state"), "XDG_CONFIG_HOME" => File.join(home, ".config")}.compact
  end

  # Runs the block in this process against the throwaway HOME, for seeding.
  def with_home
    saved = %w[HOME XDG_STATE_HOME XDG_CONFIG_HOME].to_h { |key| [key, ENV[key]] }
    ENV.update(env(nil).slice("HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME"))
    yield Workspace::Config.new
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def bind(entry)
    FileUtils.mkdir_p(state_dir)
    File.write(File.join(state_dir, "bindings.json"), JSON.generate("%1" => {"session" => "proj", "server_pid" => "4242", "workspace" => "proj", "pane_id" => "%1"}.merge(entry)))
  end

  def reviewer
    bind("kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "fix", "attempt" => 1, "round" => 1, "artifacts" => File.join(home, "art"))
  end

  def verdict_path = File.join(home, "art", "reviews", "fix.1.r1", "verdict.md")

  def reflection_path = File.join(state_dir, ".workflows", "evidence", "wr_1", "reflection.md")

  def bound_run
    bind("kind" => "run", "id" => "wr_1")
    runs = File.join(state_dir, ".workflows", "runs")
    FileUtils.mkdir_p(runs)
    File.write(File.join(runs, "wr_1.json"), JSON.generate("id" => "wr_1", "workflow" => "investigate", "workspace" => "proj", "current" => "fix",
      "state" => "running", "definition" => {"deny" => ["git push*"], "steps" => [{"id" => "fix"}]}, "steps" => {"fix" => {"attempts" => []}}))
  end

  # Takes the edit lock for this spec process, a live agent other than the caller; with `as_caller`, for the identity the hook itself will find.
  def hold_edit_lock(as_caller: false, cwd: work, rev_parse: ->(*) {})
    with_home do |config|
      lineage = Workspace::WorkspaceLineage.new(rev_parse: rev_parse)
      namespace = Workspace::LockNamespace.new(config: config, lineage: lineage).resolve(cwd: cwd)
      liveness = Workspace::LockHolder.new
      identity = if as_caller
        pane_tmux = Struct.new(:pid) { def pane_pid(_pane) = pid }.new(@agent_pid)
        Workspace::LockHolder.new(tmux: pane_tmux, env: {"TMUX_PANE" => "%1"}).current.merge(worktree: work)
      else
        {kind: "agent", pid: Process.pid, started: liveness.start_time(Process.pid), pane: nil, worktree: cwd}
      end
      store = Workspace::LockStore.new(dir: namespace[:dir], liveness: liveness)
      expect(store.acquire("edit", identity: identity, waiter_pid: identity[:pid], waiter_started: identity[:started])[:status]).to eq(:acquired)
    end
  end

  def deny_rm_rule
    path = File.join(home, ".config", "workspace", "config.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "agent:\n  permissions:\n    rules:\n      - {tool: Bash, pattern: \"rm *\", action: deny}\n")
  end

  def repo = File.join(work, "repo")

  # A real repository, so both paths resolve the lock namespace through Git#path_of.
  def repo_edit_lock
    _out, err, status = Open3.capture3("git", "init", "-q", repo)
    expect(status).to be_success, err
    hold_edit_lock(cwd: repo, rev_parse: ->(dir, what) { Workspace::Git.new.path_of(dir, what) })
  end

  def bad_lock_settings
    with_home do |config|
      name = Workspace::WorkspaceLineage.new(rev_parse: ->(*) {}).resolve(cwd: work).name
      settings = File.join(config.workspace_config_dir, "projects", "#{name}.yml")
      FileUtils.mkdir_p(File.dirname(settings))
      File.write(settings, "locks:\n  ps_timeout: soon\n  reap_interval: often\n")
    end
  end

  def reset_home
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(work)
  end

  # A daemon at the workspace's socket that records the line it gets. `hung` accepts and never
  # reads or replies; the line is read from the socket's buffer once the hook has exited.
  def start_daemon(mode)
    return -> {} if mode == :none

    path = with_home { |config| config.agent_socket_path("proj") }
    server = UNIXServer.new(path)
    client = nil
    thread = Thread.new do
      client = server.accept
      next if mode == :hung

      line = client.gets
      client.write("{}\n")
      line
    end
    lambda do
      line = (mode == :hung) ? (thread.join(1) && client&.read_nonblock(65_536, exception: false)) : thread.join(1)&.value
      line.is_a?(String) ? line : nil
    ensure
      thread.kill
      client&.close
      server.close
    end
  end

  def mask(text) = text&.dup&.force_encoding(Encoding::BINARY)&.gsub(timestamp, "<time>")

  def files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: home).sort.filter_map do |relative|
      path = File.join(home, relative)
      [relative, mask(File.binread(path))] if File.file?(path) && !relative.match?(%r{(\A|/)\.git(/|\z)})
    end
  end

  def run_once(path, row)
    reset_home
    row[:seed]&.call(self)
    finish = start_daemon(row.fetch(:daemon, :record))
    command = (path == :old) ? [RbConfig.ruby, "-I", File.join(PROJECT_ROOT, "lib"), "-e", old_path_script, "--"] : [RbConfig.ruby, File.join(PROJECT_ROOT, "bin", "workspace")]
    payload = row[:payload].is_a?(String) ? row[:payload] : JSON.generate(row[:payload])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    report = File.join(@root, "route")
    FileUtils.rm_f(report)
    run_env = env(row.fetch(:pane, "%1"))
    run_env = run_env.merge("RUBYOPT" => "-r#{File.join(@bin, "route_shim.rb")}", "ROUTE_REPORT" => report) if path == :new
    out, err, status = Open3.capture3(run_env, *command, "session-event", *row.fetch(:args, []),
      stdin_data: payload, unsetenv_others: true, chdir: work)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    {stdout: mask(out), stderr: mask(err), exit: status.exitstatus, daemon: mask(finish.call), files: files, elapsed: elapsed,
     route: (path == :new) ? File.read(report) : nil}
  end

  def tool(hook, name, input = {}, extra = {})
    {"hook_event_name" => hook, "session_id" => "s1", "cwd" => work, "tool_name" => name, "tool_use_id" => "tu1", "tool_input" => input}.merge(extra)
  end

  # The envelope shape was captured from codex-cli 0.166.0 on 2026-11-23.
  def codex_tool(name, input)
    {"session_id" => "01a207bb-01cb-73a3-bb64-e19362a333ae", "turn_id" => "01a207bb-d21a-78c0-80dd-ceb38cc18f6b", "transcript_path" => "/t/rollout.jsonl",
     "cwd" => work, "hook_event_name" => "PreToolUse", "model" => "gpt-6.1-sol", "permission_mode" => "default", "tool_name" => name,
     "tool_input" => input, "tool_use_id" => "exec-96463e9a-506a-4125-b431-e6109c2d4a28"}
  end

  def self.event(hook, extra = {}) = {"hook_event_name" => hook, "session_id" => "s1", "transcript_path" => "/t/s1.jsonl"}.merge(extra)

  claude = [
    ["UserPromptSubmit", event("UserPromptSubmit", "prompt" => "fix it")],
    ["Stop", event("Stop", "stop_reason" => "end_turn", "background_tasks" => [{"id" => "b1", "type" => "local_bash"}])],
    ["StopFailure", event("StopFailure", "error" => "rate_limit")],
    ["SubagentStop", event("SubagentStop", "agent_id" => "sub1")],
    ["Notification", event("Notification", "message" => "Claude needs your permission", "notification_type" => "permission_prompt")],
    ["SessionStart", event("SessionStart", "source" => "startup")],
    ["SessionEnd", event("SessionEnd", "reason" => "logout")],
    ["PermissionRequest", event("PermissionRequest", "tool_name" => "Bash", "tool_input" => {"command" => "ls"})]
  ]
  codex = %w[SessionStart SessionEnd UserPromptSubmit Stop Interrupt SubagentStart SubagentStop PermissionRequest].map do |hook|
    [hook, event(hook, "agent_id" => (hook == "SubagentStart") ? "sub2" : nil, "agent_type" => "worker", "tool_name" => "Bash", "tool_input" => {"command" => "ls"}).compact]
  end

  rows = claude.map { |name, payload| {name: "Claude #{name}", payload: payload} } +
    codex.map { |name, payload| {name: "Codex #{name}", payload: payload, args: %w[--agent codex]} } +
    [
      {name: "Claude PreToolUse Read", payload: ->(t) { t.tool("PreToolUse", "Read", "file_path" => File.join(t.work, "a.rb")) }},
      {name: "Claude PreToolUse Agent as subagent_start", payload: ->(t) { t.tool("PreToolUse", "Agent", "description" => "look", "subagent_type" => "Explore") }},
      {name: "Claude PreToolUse Task as subagent_start", payload: ->(t) { t.tool("PreToolUse", "Task", "description" => "look", "subagent_type" => "Explore") }},
      {name: "Claude PostToolUse", payload: ->(t) { t.tool("PostToolUse", "Edit", {"file_path" => File.join(t.work, "a.rb")}, "tool_response" => {"success" => true}, "duration_ms" => 12.4) }},
      {name: "Claude PostToolUseFailure", payload: ->(t) { t.tool("PostToolUseFailure", "Bash", {"command" => "false"}, "duration_ms" => 3) }},
      {name: "Codex PreToolUse", args: %w[--agent=codex], payload: ->(t) { t.tool("PreToolUse", "Bash", "command" => "ls") }},
      {name: "Codex PostToolUse", args: %w[--agent=codex --workspace=proj], payload: ->(t) { t.tool("PostToolUse", "Bash", {"command" => "ls"}, "tool_response" => "ok") }},
      {name: "workflow deny: hit on Bash in a bound pane", delivers: false, exit: 2, seed: lambda(&:bound_run), payload: ->(t) { t.tool("PreToolUse", "Bash", "command" => "git push origin HEAD") }},
      {name: "Codex workflow deny: hit on a real Codex shell payload in a bound pane", args: %w[--agent codex], delivers: false, exit: 2, stderr: "denied by workflow",
       seed: lambda(&:bound_run), payload: ->(t) { t.codex_tool("Bash", "command" => "git push origin HEAD") }},
      {name: "workflow deny: miss on Bash in a bound pane", exit: 0, seed: lambda(&:bound_run), payload: ->(t) { t.tool("PreToolUse", "Bash", "command" => "git status") }},
      {name: "edit lock held by another live holder", delivers: false, exit: 2, seed: ->(t) { t.hold_edit_lock }, payload: ->(t) { t.tool("PreToolUse", "Edit", "file_path" => File.join(t.work, "a.rb")) }},
      {name: "edit lock held by another live holder, MultiEdit", delivers: false, exit: 2, seed: ->(t) { t.hold_edit_lock },
       payload: ->(t) { t.tool("PreToolUse", "MultiEdit", "file_path" => File.join(t.work, "a.rb"), "edits" => []) }},
      {name: "edit lock held by another live holder, Codex apply_patch", delivers: false, exit: 2, args: %w[--agent codex], seed: ->(t) { t.hold_edit_lock },
       payload: ->(t) { t.tool("PreToolUse", "apply_patch", "command" => "*** Begin Patch\n*** Add File: x.rb\n+puts 1\n*** End Patch\n") }},
      {name: "edit lock held by another live holder, cwd in a git repo", delivers: false, exit: 2, seed: lambda(&:repo_edit_lock),
       payload: ->(t) { t.tool("PreToolUse", "Edit", {"file_path" => File.join(t.repo, "a.rb")}, "cwd" => t.repo) }},
      {name: "edit lock held by the caller", exit: 0, seed: ->(t) { t.hold_edit_lock(as_caller: true) }, payload: ->(t) { t.tool("PreToolUse", "Edit", "file_path" => File.join(t.work, "a.rb")) }},
      {name: "review write guard deny", delivers: false, exit: 2, seed: lambda(&:reviewer), payload: ->(t) { t.tool("PreToolUse", "Write", "file_path" => File.join(t.work, "x.rb")) }},
      {name: "review write guard allows a sub-agent's verdict write", exit: 0, seed: lambda(&:reviewer),
       payload: ->(t) { t.tool("PreToolUse", "Write", {"file_path" => t.verdict_path}, "agent_id" => "sub1") }},
      {name: "reflection write guard deny", delivers: false, exit: 2, seed: ->(t) { t.bind("kind" => "reflection", "id" => "wr_1") },
       payload: ->(t) { t.tool("PreToolUse", "Write", "file_path" => File.join(t.work, "x.rb")) }},
      {name: "reflection write guard allows reflection.md", exit: 0, seed: ->(t) { t.bind("kind" => "reflection", "id" => "wr_1") },
       payload: ->(t) { t.tool("PreToolUse", "Write", "file_path" => t.reflection_path) }},
      {name: "Codex reflection write guard deny on a real apply_patch payload", args: %w[--agent codex], delivers: false, exit: 2, stderr: "reflection pane",
       seed: ->(t) { t.bind("kind" => "reflection", "id" => "wr_1") },
       payload: ->(t) { t.codex_tool("apply_patch", "command" => "*** Begin Patch\n*** Add File: foo.txt\n+hello\n*** End Patch") }},
      {name: "Codex reflection write guard allows apply_patch to reflection.md", args: %w[--agent codex], exit: 0, seed: ->(t) { t.bind("kind" => "reflection", "id" => "wr_1") },
       payload: ->(t) { t.codex_tool("apply_patch", "command" => "*** Begin Patch\n*** Add File: #{t.reflection_path}\n+hello\n*** End Patch") }},
      {name: "Claude PermissionRequest decided by a deny rule", decision: "deny", seed: lambda(&:deny_rm_rule),
       payload: event("PermissionRequest", "tool_name" => "Bash", "tool_input" => {"command" => "rm -rf x"})},
      {name: "Codex PermissionRequest decided by a deny rule", decision: "deny", args: %w[--agent codex], seed: lambda(&:deny_rm_rule),
       payload: event("PermissionRequest", "tool_name" => "Bash", "tool_input" => {"command" => "rm -rf x"})},
      {name: "no TMUX_PANE", delivers: false, pane: nil, payload: event("Stop")},
      {name: "daemon down", delivers: false, daemon: :none, payload: event("Stop")},
      {name: "bad JSON", delivers: false, payload: "{not json"},
      {name: "non-object JSON", delivers: false, payload: "[1, 2]"},
      {name: "invalid UTF-8", payload: "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"a\xFFb\"}".b},
      {name: "unknown agent", delivers: false, args: %w[--agent gemini], payload: event("Stop")}
    ]

  rows.each do |row|
    it "matches for #{row[:name]}" do
      row = row.merge(payload: row[:payload].call(self)) if row[:payload].is_a?(Proc)
      old, new = run_once(:old, row), run_once(:new, row)

      expect(old.except(:elapsed, :route)).to eq(new.except(:elapsed, :route))
      expect(old[:exit]).to eq(row.fetch(:exit, 0))
      expect(old[:daemon].nil?).to eq(!row.fetch(:delivers, true))
      expect(new[:route]).to eq(row[:name].match?(/SessionStart|SessionEnd|PermissionRequest/) ? "full" : "fast")
      expect(JSON.parse(old[:stdout]).dig("hookSpecificOutput", "decision", "behavior")).to eq(row[:decision]) if row[:decision]
      expect(old[:stderr]).to include(row[:stderr]) if row[:stderr]
    end
  end

  it "matches for a hung daemon, both paths finishing within two seconds of a plain run" do
    row = {daemon: :hung, payload: self.class.event("Stop")}
    baseline_old, baseline_new = run_once(:old, row.merge(daemon: :none)), run_once(:new, row.merge(daemon: :none))
    old, new = run_once(:old, row), run_once(:new, row)

    expect(old.except(:elapsed, :route)).to eq(new.except(:elapsed, :route))
    expect(new[:route]).to eq("fast")
    expect(old[:daemon]).to include('"event":"stop"')
    expect(old[:elapsed] - baseline_old[:elapsed]).to be < 2.0
    expect(new[:elapsed] - baseline_new[:elapsed]).to be < 2.0
  end

  it "matches for a socket path that cannot fit (a too-deep HOME), exiting 0 on both" do
    @home = File.join(@root, "d" * 90)
    row = {daemon: :none, args: %w[--workspace proj], payload: self.class.event("Stop")}
    old, new = run_once(:old, row), run_once(:new, row)

    expect(old.except(:elapsed, :route)).to eq(new.except(:elapsed, :route))
    expect(new[:route]).to eq("fast")
    expect([old[:exit], old[:stderr]]).to eq([0, "".b])
  end

  # Q7: the old path's build_cli warns about the bad keys on every call; the fast path reads
  # ps_timeout only for a lock check's process table and never reads reap_interval.
  it "differs only by the old path's two Warning lines for bad locks.ps_timeout and locks.reap_interval on a PreToolUse Read" do
    row = {seed: lambda(&:bad_lock_settings), payload: tool("PreToolUse", "Read", "file_path" => File.join(work, "a.rb"))}
    old, new = run_once(:old, row), run_once(:new, row)

    expect(old.except(:elapsed, :stderr, :route)).to eq(new.except(:elapsed, :stderr, :route))
    expect(new[:route]).to eq("fast")
    expect(old[:stderr]).to match(/\AWarning: invalid locks.ps_timeout for 'work' .*; using 5s.\nWarning: invalid locks.reap_interval for 'work' .*; using 30s.\n\z/)
    expect(new[:stderr]).to eq("")
  end
end
