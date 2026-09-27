require "spec_helper"
require "tmpdir"

class RestartMessageTmux < CLITestHelpers::FakeTmux
  attr_accessor :details

  def initialize
    super
    @details = [
      {id: "%17", window: 0, index: 0, pid: 1, command: "zsh", cwd: "/", title: ""},
      {id: "%18", window: 0, index: 1, pid: 2, command: "claude", cwd: "/", title: ""},
      {id: "%30", window: 1, index: 0, pid: 3, command: "claude", cwd: "/", title: ""}
    ]
  end

  def session_name_for(_config) = "workspace-wt-myapp"

  def pane_details(_session, window: "0")
    window.nil? ? @details : @details.select { |d| d[:window] == window.to_i }
  end
end

class RestartMessageMonitor
  attr_accessor :kinds

  def initialize = @kinds = {"%17" => "shell", "%18" => "claude"}
  def start = nil
  def stop = nil
  def snapshot = {"panes" => []}
  def pane_kind(id) = @kinds[id]
  def pane_state(_id) = "idle"
end

# Records what it was asked to do and finishes when the spec says so.
class GatedRestart
  attr_reader :calls, :built_with

  def initialize(result)
    @result = result
    @calls = Queue.new
    @gate = Queue.new
  end

  def build(**kwargs)
    @built_with = kwargs
    self
  end

  def call(**kwargs)
    @calls << kwargs
    @gate.pop
    @result
  end

  def finish = @gate << :go
end

# The daemon's side of a restart_agent message: resolving the explicit pane,
# the checks made before replying, and handing the work to a worker thread.
RSpec.describe Workspace::Commands::Agent, "restart_agent" do
  let(:tmpdir) { Dir.mktmpdir("ws-restart", "/tmp") }
  let(:agent_socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:tmux) { RestartMessageTmux.new }
  let(:monitor) { RestartMessageMonitor.new }
  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(agent_socket_path)
      allow(c).to receive(:project_config_path).with("myapp").and_return(File.join(tmpdir, "myapp.yml"))
      allow(c).to receive(:pipeline_state_path).and_return(File.join(tmpdir, "pipeline.json"))
    end
  end
  let(:coordinator_client) do
    instance_double(Workspace::WorkCoordinatorClient, register: {"ok" => true, "epoch" => "e"},
      deregister: nil, status_socket_path: nil)
  end
  let(:pipeline_config) { Workspace::PipelineConfig.new(config: config) }
  let(:pipeline_state) { Workspace::PipelineState.new(pipeline_config: pipeline_config) }
  let(:context_reader) do
    instance_double(Workspace::ContextReader).tap do |reader|
      allow(reader).to receive(:read).and_return({pct: 42, error: nil, updated_at: "2026-09-27T12:00:00Z"})
    end
  end
  let(:restart) { GatedRestart.new({"ok" => true, "status" => "restarted", "pane_id" => "%18"}) }
  let(:signal_trapper) do
    Class.new do
      attr_reader :handlers

      def initialize = @handlers = {}

      def trap(signal, &block)
        @handlers[signal] = block
      end
    end.new
  end

  subject(:agent) do
    described_class.new(config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config, pipeline_state: pipeline_state, signal_trapper: signal_trapper,
      session_monitor_factory: ->(_name) { monitor }, context_reader: context_reader,
      agent_restart_factory: restart.method(:build), output: output, error_output: error_output)
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def run_agent
    thread = Thread.new { agent.call(name: "myapp") }
    deadline = Time.now + 2
    sleep(0.01) until output.string.include?("ready") || !thread.alive? || Time.now > deadline
    yield
  ensure
    restart.finish
    signal_trapper.handlers["TERM"]&.call
    thread&.join(2)
    thread&.kill
  end

  def send_restart(overrides = {})
    message = {"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18", "prompt" => "Read HANDOFF.md"}.merge(overrides)
    UNIXSocket.open(agent_socket_path) do |socket|
      socket.puts(message.to_json)
      JSON.parse(socket.gets)
    end
  end

  it "replies started at once and runs the restart on the named pane" do
    run_agent do
      reply = send_restart

      expect(reply).to eq("ok" => true, "status" => "started", "pane" => "0.1", "pane_id" => "%18", "context_pct" => 42)
      expect(restart.calls.pop(timeout: 2)).to eq(pane_id: "%18", prompt: "Read HANDOFF.md", force: false,
        confirm_timeout: Workspace::AgentRestart::CONFIRM_TIMEOUT)
      expect(restart.built_with).to include(session_name: "workspace-wt-myapp")
    end
  end

  it "keeps serving other messages while a restart runs" do
    run_agent do
      send_restart
      restart.calls.pop(timeout: 2)

      reply = UNIXSocket.open(agent_socket_path) do |socket|
        socket.puts({"type" => "sessions", "workspace" => "myapp"}.to_json)
        JSON.parse(socket.gets)
      end
      expect(reply).to eq("panes" => [])
    end
  end

  it "with wait, replies with the outcome once the restart finishes" do
    run_agent do
      waiter = Thread.new { send_restart("wait" => true, "timeout" => 5) }
      expect(restart.calls.pop(timeout: 2)).to include(confirm_timeout: 5)
      expect(waiter.join(0.1)).to be_nil

      restart.finish
      expect(waiter.value).to eq("pane" => "0.1", "ok" => true, "status" => "restarted", "pane_id" => "%18")
    end
  end

  it "prints a failed restart on stderr, since a caller that didn't wait can't hear it" do
    failing = GatedRestart.new({"ok" => false, "error" => "clear_not_confirmed", "message" => "usage did not drop"})
    agent_with_failure = described_class.new(config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config, pipeline_state: pipeline_state, signal_trapper: signal_trapper,
      session_monitor_factory: ->(_name) { monitor }, context_reader: context_reader,
      agent_restart_factory: failing.method(:build), output: output, error_output: error_output)
    thread = Thread.new { agent_with_failure.call(name: "myapp") }
    deadline = Time.now + 2
    sleep(0.01) until output.string.include?("ready") || Time.now > deadline

    send_restart
    failing.calls.pop(timeout: 2)
    failing.finish
    deadline = Time.now + 2
    sleep(0.01) until error_output.string.include?("usage did not drop") || Time.now > deadline

    expect(error_output.string).to include("restart_agent for pane 0.1: usage did not drop")
  ensure
    failing.finish
    signal_trapper.handlers["TERM"]&.call
    thread&.join(2)
    thread&.kill
  end

  it "stops a restart still running when the daemon shuts down, telling a waiting caller and stderr" do
    thread = Thread.new { agent.call(name: "myapp") }
    deadline = Time.now + 2
    sleep(0.01) until output.string.include?("ready") || Time.now > deadline
    waiter = Thread.new do
      UNIXSocket.open(agent_socket_path) do |socket|
        socket.puts({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18",
                     "prompt" => "go", "wait" => true}.to_json)
        socket.gets
      end
    end
    restart.calls.pop(timeout: 2)

    signal_trapper.handlers["TERM"].call
    expect(thread.join(3)).to be_truthy
    reply = JSON.parse(waiter.join(2)&.value.to_s)
    expect(reply).to include("ok" => false, "error" => "agent_stopped", "pane" => "0.1", "pane_id" => "%18")
    expect(reply["message"]).to include("stopped by shutdown", "nothing was typed")
    expect(error_output.string).to include("restart_agent for pane 0.1: stopped by shutdown")
  ensure
    thread&.kill
    waiter&.kill
  end

  it "builds a real AgentRestart by default, on the workspace's tmux session" do
    plain = described_class.new(config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config, context_reader: context_reader)

    built = plain.send(:build_agent_restart, session_name: "workspace-wt-myapp", delivery_lock: Mutex.new,
      pipeline_ref: ->(_) {}, pane_state: ->(_) {})
    expect(built).to be_a(Workspace::AgentRestart)
  end

  it "refuses a second restart on a pane while one is running" do
    run_agent do
      send_restart
      restart.calls.pop(timeout: 2)

      reply = send_restart
      expect(reply).to include("ok" => false, "error" => "restart_in_progress", "pane" => "0.1")
    end
  end

  {
    "%18" => "0.1",
    "0.1" => "0.1",
    "1" => "0.1",
    "workspace-wt-myapp:0.1" => "0.1",
    "myapp:0.1" => "0.1",
    "1.0" => "1.0"
  }.each do |spec, target|
    it "resolves pane #{spec.inspect} to #{target}" do
      monitor.kinds["%30"] = "claude"
      run_agent do
        expect(send_restart("pane" => spec)).to include("ok" => true, "pane" => target)
      end
    end
  end

  {
    nil => "missing_pane",
    "" => "missing_pane",
    "claude" => "bad_pane",
    "%99" => "no_such_pane",
    "0.7" => "no_such_pane",
    "other-session:0.1" => "wrong_session"
  }.each do |spec, error|
    it "refuses pane #{spec.inspect} with #{error} and types nothing" do
      run_agent do
        expect(send_restart("pane" => spec)).to include("ok" => false, "error" => error)
        expect(restart.calls).to be_empty
      end
    end
  end

  it "refuses a pane running a shell" do
    run_agent do
      expect(send_restart("pane" => "0.0")).to include("ok" => false, "error" => "not_an_agent", "pane" => "0.0")
    end
  end

  it "refuses a pane running an agent other than Claude Code" do
    monitor.kinds["%18"] = "codex"
    run_agent do
      reply = send_restart
      expect(reply).to include("ok" => false, "error" => "unsupported_agent", "pane" => "0.1")
      expect(reply["message"]).to include("Codex")
      expect(restart.calls).to be_empty
    end
  end

  it "lets through a pane the session monitor hasn't identified yet" do
    monitor.kinds["%18"] = "unknown"
    run_agent do
      expect(send_restart).to include("ok" => true, "status" => "started")
    end
  end

  it "refuses a missing prompt" do
    run_agent do
      expect(send_restart("prompt" => "  ")).to include("ok" => false, "error" => "missing_prompt")
    end
  end

  [0, 601, "30"].each do |timeout|
    it "refuses a timeout of #{timeout.inspect}" do
      run_agent do
        expect(send_restart("timeout" => timeout)).to include("ok" => false, "error" => "bad_timeout")
      end
    end
  end

  it "refuses a pane with no reading that the monitor hasn't identified as Claude, with the reason and fix" do
    monitor.kinds.delete("%18")
    allow(context_reader).to receive(:read).and_return({pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil})

    run_agent do
      reply = send_restart

      expect(reply).to include("ok" => false, "error" => "context_unknown",
        "reason" => Workspace::ContextReasons::NO_READING, "fix" => Workspace::ContextReasons::FIX_HINT)
      expect(restart.calls).to be_empty
    end
  end

  it "refuses when scrape mode can never confirm the /clear" do
    allow(context_reader).to receive(:read).and_return({pct: nil, error: Workspace::ContextReasons::NO_PATTERN, updated_at: nil})

    run_agent do
      expect(send_restart).to include("ok" => false, "error" => "context_unknown",
        "reason" => Workspace::ContextReasons::NO_PATTERN)
      expect(restart.calls).to be_empty
    end
  end

  it "accepts a Claude pane with no reading yet, since the new conversation's first render confirms the /clear" do
    allow(context_reader).to receive(:read).and_return({pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil})

    run_agent do
      expect(send_restart).to include("ok" => true, "status" => "started", "context_pct" => nil)
      restart.finish
    end
  end

  it "accepts a freshly cleared pane whose session hasn't reported usage yet" do
    allow(context_reader).to receive(:read).and_return({pct: nil, error: Workspace::ContextReasons::NO_READING_YET,
      updated_at: "2026-09-27T12:00:00Z", session_id: "s-1"})

    run_agent do
      expect(send_restart).to include("ok" => true, "status" => "started", "context_pct" => nil)
      restart.finish
    end
  end

  context "when a pipeline stage is running on the pane" do
    before do
      File.write(File.join(tmpdir, "myapp.yml"), <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML
      pipeline_state.start(work_item_ref: "WC-7", workspace_name: "myapp", dispatch_id: "d-1", sentinel_token: "t")
      pipeline_state.advance(work_item_ref: "WC-7", to_stage: {role: "implementer", pane_index: 1}, sentinel_token: "t2")
      allow(tmux).to receive(:panes).and_return([0, 1])
    end

    it "refuses without --force" do
      run_agent do
        reply = send_restart

        expect(reply).to include("ok" => false, "error" => "pane_in_pipeline", "work_item_ref" => "WC-7")
        expect(reply["message"]).to include("--force")
        expect(restart.calls).to be_empty
      end
    end

    it "restarts with force, and warns about the stage" do
      run_agent do
        reply = send_restart("force" => true)

        expect(reply).to include("ok" => true)
        expect(reply["warning"]).to include("WC-7")
        expect(restart.calls.pop(timeout: 2)).to include(force: true)
      end
    end
  end
end
