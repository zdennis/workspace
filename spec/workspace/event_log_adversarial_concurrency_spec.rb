require "tmpdir"
require "timeout"
require "rbconfig"

RSpec.describe "EventLog adversarial concurrency" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:event_log_file) { File.join(tmpdir, ".workspace-events.jsonl") }
  let(:state_file) { File.join(tmpdir, ".workspace-state.json") }
  let(:config) do
    Workspace::Config.new(workspace_dir: tmpdir).tap do |c|
      allow(c).to receive(:event_log_file).and_return(event_log_file)
      allow(c).to receive(:state_file).and_return(state_file)
    end
  end
  let(:errors) { StringIO.new }

  after { FileUtils.remove_entry(tmpdir) }

  # Starts a separate ruby process that appends one event, with HOME pointed
  # at the temp dir so its Config resolves the same log file. It touches
  # +marker+ just before appending. Returns its pid.
  def spawn_append(type, project, marker)
    lib = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      require "workspace"
      config = Workspace::Config.new(workspace_dir: ENV["HOME"])
      log = Workspace::EventLog.new(config: config)
      File.write(#{marker.inspect}, "")
      log.append(type: #{type.inspect}, project: #{project.inspect})
    RUBY
    env = {"HOME" => tmpdir, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"),
           "XDG_STATE_HOME" => File.join(tmpdir, "state"), "SKIP_SIMPLECOV" => "1"}
    Process.spawn(env, RbConfig.ruby, "-I", lib, "-e", script, err: File::NULL, out: File::NULL)
  end

  def wait_for_child(pid)
    Timeout.timeout(30) { Process.wait(pid) }
    $?
  rescue Timeout::Error
    Process.kill("KILL", pid)
    Process.wait(pid)
    raise
  end

  it "EC1: compact loses an event another process appends while it is rewriting the log" do
    event_log = Workspace::EventLog.new(config: config, error_output: errors)
    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
    marker = File.join(tmpdir, "appending")

    # Fires between compact reading the log and renaming the rewrite over it.
    # The other process appends in the background: compact holds the log's
    # lock here, so an append that waits for it can't finish until compact
    # returns. The pause gives the append time to land if nothing stops it.
    hook_logger = Object.new
    pid = nil
    spec = self
    hook_logger.define_singleton_method(:debug) do |&block|
      message = block.call
      if message.start_with?("event_log: compacting") && pid.nil?
        pid = spec.spawn_append("launched", "proj2", marker)
        Timeout.timeout(30) { sleep 0.01 until File.exist?(marker) }
        sleep 0.5
      end
    end

    begin
      Workspace::EventLog.new(config: config, error_output: errors, logger: hook_logger).compact
    ensure
      status = wait_for_child(pid) if pid
    end

    expect(status.success?).to be(true)
    expect(Workspace::EventLog.new(config: config, error_output: errors).reconstruct.keys).to include("proj2")
  end

  it "EC2: after a torn write with no trailing newline, the next valid event is lost on read" do
    whole = JSON.generate({"type" => "launched", "project" => "p0", "data" => {}})
    torn = '{"timestamp":"2026-09-27T00:00:00.000Z","type":"launch'
    File.write(event_log_file, "#{whole}\n#{torn}")
    event_log = Workspace::EventLog.new(config: config, error_output: errors)

    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})

    expect(event_log.reconstruct.keys).to include("proj1")
  end

  it "EC3: an activity event written before the first state load skips the state-file migration" do
    File.write(state_file, JSON.generate({"proj1" => {"unique_id" => "u1", "iterm_window_id" => 7}}))
    event_log = Workspace::EventLog.new(config: config, error_output: errors)

    # e.g. a lock wait or the agent daemon is the first thing to run after upgrade
    event_log.record(type: "lock_wait_started", project: "proj1", data: {"lock" => "devenv"})
    state = Workspace::State.new(config: config, event_log: event_log).load

    expect(state["proj1"]).to eq({"unique_id" => "u1", "iterm_window_id" => 7})
  end

  it "EC4: compaction keeps agent_state of panes and projects that are long gone, so the log never shrinks" do
    event_log = Workspace::EventLog.new(config: config, error_output: errors)
    event_log.append(type: "launched", project: "proj1", data: {"unique_id" => "u1"})
    event_log.record(type: "agent_state", project: "proj1",
      data: {"pane_id" => "%3", "pane_pid" => 4242, "kind" => "claude", "state" => "idle", "since" => "2026-01-01T00:00:00.000Z"})
    # The session is killed with its daemon; no "closed" is ever logged for %3.
    event_log.append(type: "killed", project: "proj1")

    event_log.compact

    expect(event_log.events.select { |e| e["type"] == "agent_state" }).to be_empty
  end

  describe "EC5" do
    let(:tmux) { instance_double(Workspace::Tmux) }
    let(:process_tree) { instance_double(Workspace::ProcessTree) }
    let(:snapshot) { instance_double(Workspace::ProcessTree::Snapshot) }
    let(:now) { Time.utc(2026, 9, 26, 12, 0, 0) }
    let(:clock) { class_double(Time, now: now) }
    let(:notifier) { instance_double(Workspace::Notifier, notify: :started) }
    let(:event_log) { Workspace::EventLog.new(config: config, error_output: errors, clock: clock) }

    before do
      allow(tmux).to receive(:pane_details).and_return([{id: "%2", index: 1, pid: 200, command: "node", cwd: "/p", title: "Claude"}])
      allow(process_tree).to receive(:snapshot).and_return(snapshot)
      allow(snapshot).to receive(:find_descendant).and_return({pid: 250, command: "claude", args: "claude"})
      allow(tmux).to receive(:capture_pane).and_return("output")
    end

    def monitor
      Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "proj",
        idle_after: 30, idle_alert_after: 60, clock: clock, notifier: notifier, event_log: event_log)
    end

    it "EC5: a daemon restart re-sends the idle alert the previous daemon already sent for the same quiet stretch" do
      first = monitor
      first.scan
      allow(clock).to receive(:now).and_return(now + 90)
      first.scan
      expect(first.send_alerts.size).to eq(1)

      allow(clock).to receive(:now).and_return(now + 120)
      restarted = monitor
      restarted.scan

      expect(restarted.send_alerts).to be_empty
    end
  end
end
