require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "socket"
require "digest"

# Loads only the fast session-event entry, under `ruby -w`, and drives each path that loads more
# files when it is first used: a guard's deny that records to the event log, a bound pane's Bash
# call that reads the run store, a lock check that reads the process table (and the project's
# `locks.ps_timeout`), a reviewer's verdict hash and Codex's apply_patch. Each guard rescues its own
# errors and allows the call, so every row checks the outcome, and the debug log is on to show any
# error a guard swallowed.
RSpec.describe "workspace session-event fast entry's require closure" do
  let(:entry_script) do
    <<~RUBY
      require "workspace/cli/session_event_entry"
      exit Workspace::CLI::SessionEventEntry.run(ARGV, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV)
    RUBY
  end

  around do |example|
    Dir.mktmpdir("wsc", "/tmp") do |dir|
      @home = File.realpath(dir)
      @work = File.join(@home, "work")
      @bin = File.join(@home, "bin")
      FileUtils.mkdir_p([@work, @bin])
      write_fake_tmux
      example.run
    ensure
      Process.kill("KILL", @agent_pid) if @agent_pid
      Process.wait(@agent_pid) if @agent_pid
    end
  end

  def state_dir = File.join(@home, "state", "workspace")

  def write_fake_tmux
    path = File.join(@bin, "tmux")
    File.write(path, <<~'SH')
      #!/bin/sh
      for a in "$@"; do last="$a"; done
      case " $* " in
        *" display-message "*)
          case "$last" in
            '#{session_name}') echo proj ;;
            '#{pid}') echo 4242 ;;
            '#{pane_pid}') echo "$FAKE_PANE_PID" ;;
            '#{session_name}:#{window_index}.#{pane_index}') echo proj:0.0 ;;
          esac ;;
        *" show-option "*) exit 1 ;;
      esac
      exit 0
    SH
    File.chmod(0o755, path)
  end

  def env(extra = {})
    {"PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "HOME" => @home, "TMUX_PANE" => "%1", "WORKSPACE_DEBUG" => "1",
     "XDG_STATE_HOME" => File.join(@home, "state"), "XDG_CONFIG_HOME" => File.join(@home, ".config")}.merge(extra)
  end

  # Runs the closure setup in this process against the throwaway HOME.
  def with_home
    saved = %w[HOME XDG_STATE_HOME XDG_CONFIG_HOME].to_h { |key| [key, ENV[key]] }
    ENV.update(env.slice("HOME", "XDG_STATE_HOME", "XDG_CONFIG_HOME"))
    yield Workspace::Config.new
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def session_event(payload, *args, extra_env: {})
    Open3.capture3(env(extra_env), RbConfig.ruby, "-w", "-I", File.join(PROJECT_ROOT, "lib"), "-e", entry_script, "--", "session-event", *args,
      stdin_data: JSON.generate(payload), unsetenv_others: true, chdir: @work)
  end

  def bind(entry)
    FileUtils.mkdir_p(state_dir)
    File.write(File.join(state_dir, "bindings.json"), JSON.generate("%1" => {"session" => "proj", "server_pid" => "4242", "workspace" => "proj", "pane_id" => "%1"}.merge(entry)))
  end

  def reviewer(extra = {})
    {"kind" => "run", "id" => "wr_1", "role" => "reviewer", "step" => "fix", "attempt" => 1, "round" => 1,
     "artifacts" => File.join(@home, "art")}.merge(extra)
  end

  def events
    path = File.join(@home, ".workspace-events.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def expect_clean(err)
    expect(err).not_to match(/NameError|NoMethodError|LoadError|uninitialized constant|failed \(/)
    expect(err.lines.grep(/warning:/).grep(/#{Regexp.escape(File.join(PROJECT_ROOT, "lib"))}/)).to eq([])
  end

  # Records the one line a daemon at the workspace's socket gets.
  def with_daemon(name)
    path = with_home { |config| config.agent_socket_path(name) }
    server = UNIXServer.new(path)
    lines = []
    thread = Thread.new do
      client = server.accept
      lines << client.gets
      client.write("{}\n")
      client.close
    end
    yield
    thread.join(2)
    lines.compact.map { |line| JSON.parse(line) }
  ensure
    thread&.kill
    server&.close
  end

  it "records a review write guard's deny in the event log" do
    bind(reviewer)

    out, err, status = session_event({"hook_event_name" => "PreToolUse", "tool_name" => "Write", "cwd" => @work, "tool_input" => {"file_path" => File.join(@work, "x.rb")}})

    expect([out, status.exitstatus]).to eq(["", 2])
    expect(err).to include("denied: this is a review pane for run wr_1, step fix, round 1")
    expect(events.map { |event| event["type"] }).to eq(["review_write_denied"])
    expect_clean(err)
  end

  it "denies a bound pane's Bash command its run's definition lists, reading the run store" do
    bind("kind" => "run", "id" => "wr_1")
    runs = File.join(state_dir, ".workflows", "runs")
    FileUtils.mkdir_p(runs)
    File.write(File.join(runs, "wr_1.json"), JSON.generate("id" => "wr_1", "workflow" => "investigate", "workspace" => "proj", "current" => "fix",
      "state" => "running", "definition" => {"deny" => ["git push*"], "steps" => [{"id" => "fix"}]}, "steps" => {"fix" => {"attempts" => []}}))

    out, err, status = session_event({"hook_event_name" => "PreToolUse", "tool_name" => "Bash", "cwd" => @work, "tool_input" => {"command" => "git push origin HEAD"}})

    expect([out, status.exitstatus]).to eq(["", 2])
    expect(err).to include('denied by workflow investigate, step fix: "git push*". Report this and stop.')
    expect(File.read(File.join(runs, "wr_1.events.jsonl"))).to include("command_denied")
    expect(events.map { |event| event["type"] }).to eq(["command_denied"])
    expect_clean(err)
  end

  it "denies an edit while another live agent holds the edit lock, reading the process table under the project's ps_timeout" do
    agent = File.join(@bin, "claude")
    File.symlink("/bin/sleep", agent)
    @agent_pid = Process.spawn(agent, "30")
    with_home do |config|
      lineage = Workspace::WorkspaceLineage.new(rev_parse: ->(*) {})
      namespace = Workspace::LockNamespace.new(config: config, lineage: lineage).resolve(cwd: @work)
      settings = File.join(config.workspace_config_dir, "projects", "#{lineage.resolve(cwd: @work).name}.yml")
      FileUtils.mkdir_p(File.dirname(settings))
      File.write(settings, "locks:\n  ps_timeout: 7s\n")
      liveness = Workspace::LockHolder.new
      started = liveness.start_time(Process.pid)
      identity = {kind: "agent", pid: Process.pid, started: started, pane: nil, worktree: @work}
      store = Workspace::LockStore.new(dir: namespace[:dir], liveness: liveness)
      expect(store.acquire("edit", identity: identity, waiter_pid: Process.pid, waiter_started: started)[:status]).to eq(:acquired)
    end

    out, err, status = session_event({"hook_event_name" => "PreToolUse", "tool_name" => "Edit", "cwd" => @work, "tool_input" => {"file_path" => File.join(@work, "a.rb")}},
      extra_env: {"FAKE_PANE_PID" => @agent_pid.to_s})

    expect([out, status.exitstatus]).to eq(["", 2])
    expect(err).to match(/edit lock/i)
    expect_clean(err)
  end

  it "hashes a reviewer's verdict file on PostToolUse and sends the hash to the daemon" do
    bind(reviewer)
    verdict = File.join(@home, "art", "reviews", "fix.1.r1", "verdict.md")
    FileUtils.mkdir_p(File.dirname(verdict))
    File.write(verdict, "approve\n")

    lines = with_daemon("proj") do
      _out, err, status = session_event({"hook_event_name" => "PostToolUse", "tool_name" => "Write", "cwd" => @work, "agent_id" => "sub1",
                                         "tool_input" => {"file_path" => verdict}, "tool_response" => {"success" => true}}, "--workspace", "proj")
      expect(status.exitstatus).to eq(0)
      expect_clean(err)
    end

    expect(lines.size).to eq(1)
    expect(lines.first.to_s).to include(Digest::SHA256.hexdigest("approve\n"))
  end

  it "reads the workspace from the session's tmuxinator config and records the undeliverable event in the delivery log" do
    config = File.join(@home, ".config", "tmuxinator", "workspace.proj.yml")
    FileUtils.mkdir_p(File.dirname(config))
    File.write(config, "name: proj\nroot: #{@work}\n")

    out, err, status = session_event({"hook_event_name" => "PostToolUse", "tool_name" => "Read", "tool_use_id" => "t1", "cwd" => @work,
                                      "tool_input" => {"file_path" => File.join(@work, "a.rb")}, "tool_response" => {}})

    expect([out, status.exitstatus]).to eq(["", 0])
    expect(File.read(File.join(state_dir, "session-event.log"))).to match(/\A\S+Z undeliverable event=tool_use workspace=proj pane=%1 /)
    expect_clean(err)
  end

  it "sends to a workspace whose socket path is too long for its name, under the hashed name" do
    name = "proj.worktree-#{"x" * 90}"

    lines = with_daemon(name) do
      _out, err, status = session_event({"hook_event_name" => "PostToolUse", "tool_name" => "Read", "tool_use_id" => "t1", "cwd" => @work,
                                         "tool_input" => {"file_path" => File.join(@work, "a.rb")}, "tool_response" => {}}, "--workspace", name)
      expect(status.exitstatus).to eq(0)
      expect_clean(err)
    end

    expect(with_home { |config| File.basename(config.agent_socket_path(name)) }).not_to include(name)
    expect(lines.size).to eq(1)
  end

  it "denies Codex's apply_patch in a review pane and summarises its PostToolUse" do
    bind(reviewer)
    patch = "*** Begin Patch\n*** Add File: x.rb\n+puts 1\n*** End Patch\n"

    out, err, status = session_event({"hook_event_name" => "PreToolUse", "tool_name" => "apply_patch", "cwd" => @work, "agent_id" => "sub1", "tool_input" => {"command" => patch}},
      "--agent", "codex")
    expect([out, status.exitstatus]).to eq(["", 2])
    expect(err).to include("a reviewer writes only its round's verdict files")
    expect_clean(err)

    lines = with_daemon("proj") do
      _out, err, status = session_event({"hook_event_name" => "PostToolUse", "tool_name" => "apply_patch", "cwd" => @work, "tool_input" => {"command" => patch}},
        "--agent=codex", "--workspace=proj")
      expect(status.exitstatus).to eq(0)
      expect_clean(err)
    end
    expect(lines.size).to eq(1)
    expect(lines.first.to_s).to include("apply_patch")
  end
end
