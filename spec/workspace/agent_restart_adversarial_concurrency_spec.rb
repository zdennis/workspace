require "spec_helper"
require "stringio"

# Adversarial concurrency/liveness specs for restart_agent. Each example
# documents one confirmed defect and fails against the current code.

# A pane whose screen never changes; deliveries are recorded.
class ConcurrencyRestartTmux
  attr_reader :delivered

  def initialize
    @delivered = []
  end

  def session_name_for(_name) = "workspace-wt-myapp"

  def capture_screen(_target) = "❯ "

  def pane_details(_session, window: "0")
    [{id: "%18", window: 0, index: 1, pid: 2, command: "claude", cwd: "/", title: ""}]
  end

  def deliver(session, target, text)
    @delivered << {session: session, target: target, text: text}
    Workspace::Tmux::Delivery.new(status: :submitted, message: "fake submitted")
  end

  def texts = @delivered.map { |d| d[:text] }
end

# A restart that runs until the spec opens its gate.
class ConcurrencyGatedRestart
  attr_reader :entered

  def initialize(result)
    @result = result
    @entered = Queue.new
    @gate = Queue.new
  end

  def build(**) = self

  def call(**)
    @entered << true
    @gate.pop
    @result
  end

  def finish = @gate << :go
end

# A client socket whose close blocks until released, so a spec can hold the
# worker between replying and releasing its pane.
class ConcurrencySlowCloseClient
  attr_reader :lines

  def initialize
    @lines = Queue.new
    @close_gate = Queue.new
  end

  def puts(line) = @lines << line

  def close = @close_gate.pop(timeout: 5)

  def release = @close_gate << :go
end

RSpec.describe Workspace::AgentRestart, "adversarial concurrency" do
  let(:now) { [0.0] }
  let(:tmux) { ConcurrencyRestartTmux.new }

  def build_restart(context_reader:, pipeline_ref: ->(_index) {}, pane_state: ->(_id) {},
    wall_clock: -> { Time.utc(2026, 9, 27, 12, 0, 30) })
    described_class.new(
      tmux: tmux, context_reader: context_reader, session_name: "workspace-wt-myapp",
      delivery_lock: Mutex.new, pipeline_ref: pipeline_ref, pane_state: pane_state,
      clock: -> { now[0] }, wall_clock: wall_clock,
      sleeper: ->(seconds) { now[0] += seconds },
      quiet_timeout: 5, quiet_for: 1, poll_interval: 0.5
    )
  end

  it "C1: re-checks the pipeline before typing /clear, so a stage started during the quiet wait isn't wiped" do
    reader = Object.new
    reader.define_singleton_method(:read) do |pane_id:, **|
      {pct: 50, error: nil, updated_at: "2026-09-27T12:00:00Z"}
    end
    # A pipeline stage was dispatched onto pane 0.1 while the restart waited
    # for the pane to go quiet (the daemon only checked at message time).
    restart = build_restart(context_reader: reader, pipeline_ref: ->(index) { (index == 1) ? "WC-7" : nil })

    result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md", confirm_timeout: 2)

    expect(tmux.texts).not_to include("/clear")
    expect(result).to include("ok" => false, "error" => "pane_in_pipeline")
  end

  it "C2: never counts a lower reading recorded in the same second but before /clear as confirming it" do
    readings = [{pct: 50, error: nil, updated_at: "2026-09-27T12:00:05Z"}]
    reader = Object.new
    reader.define_singleton_method(:read) { |pane_id:, **| readings.last }
    # Just before /clear is typed (same wall-clock second), the statusline
    # records a lower reading for the *old* conversation (e.g. a compaction
    # finishing). The /clear itself never takes effect.
    wall_clock = lambda do
      readings << {pct: 30, error: nil, updated_at: "2026-09-27T12:00:05Z"}
      Time.utc(2026, 9, 27, 12, 0, 5) + 0.9
    end
    restart = build_restart(context_reader: reader, wall_clock: wall_clock)

    result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md", confirm_timeout: 2)

    expect(tmux.texts).not_to include("Read HANDOFF.md")
    expect(result).to include("ok" => false, "error" => "clear_not_confirmed")
  end

  it "C3: doesn't type /clear while the session monitor reports the agent working on a still screen" do
    reader = Object.new
    reader.define_singleton_method(:read) do |pane_id:, **|
      {pct: 50, error: nil, updated_at: "2026-09-27T12:00:00Z"}
    end
    restart = build_restart(context_reader: reader, pane_state: ->(_id) { "working" })

    result = restart.call(pane_id: "%18", prompt: "Read HANDOFF.md", confirm_timeout: 2)

    expect(tmux.texts).to be_empty
    expect(result).to include("ok" => false, "error" => "pane_busy")
  end
end

RSpec.describe Workspace::Commands::Agent, "restart_agent adversarial concurrency" do
  let(:tmux) { ConcurrencyRestartTmux.new }
  let(:error_output) { StringIO.new }
  let(:config) { instance_double(Workspace::Config) }
  let(:coordinator_client) { instance_double(Workspace::WorkCoordinatorClient) }
  let(:pipeline_config) { Workspace::PipelineConfig.new(config: config) }
  let(:context_reader) do
    instance_double(Workspace::ContextReader).tap do |reader|
      allow(reader).to receive(:read).and_return({pct: 42, error: nil, updated_at: "2026-09-27T12:00:00Z"})
    end
  end
  let(:message) { {"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18", "prompt" => "go"} }

  def build_agent(factory)
    described_class.new(config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config, context_reader: context_reader,
      agent_restart_factory: factory, output: StringIO.new, error_output: error_output)
  end

  def reply_of(client)
    JSON.parse(client.string.lines.last)
  end

  def workers(agent)
    agent.instance_variable_get(:@restarts).values.grep(Thread)
  end

  def cleanup(agent, *gated)
    gated.each(&:finish)
    workers(agent).each { |t| t.join(2) || t.kill }
  end

  it "C4: releases the pane when the worker thread can't be started, instead of leaking :starting" do
    restart = ConcurrencyGatedRestart.new({"ok" => true, "status" => "restarted"})
    agent = build_agent(restart.method(:build))

    allow(Thread).to receive(:new).and_raise(ThreadError, "can't create Thread: Resource temporarily unavailable")
    expect { agent.send(:handle_restart_agent, message, StringIO.new) }.to raise_error(ThreadError)
    allow(Thread).to receive(:new).and_call_original

    client = StringIO.new
    agent.send(:handle_restart_agent, message, client)
    expect(reply_of(client)).to include("ok" => true, "status" => "started")
  ensure
    cleanup(agent, restart) if agent
  end

  it "C5: reports a restart stopped by shutdown on stderr, as the CLI promises for failures" do
    restart = ConcurrencyGatedRestart.new({"ok" => true, "status" => "restarted"})
    agent = build_agent(restart.method(:build))
    agent.send(:handle_restart_agent, message, StringIO.new)
    expect(restart.entered.pop(timeout: 2)).to be(true)

    # The worker may already have typed /clear; killing it now leaves the
    # pane cleared with no prompt, and nobody is told.
    agent.send(:stop_restarts)

    expect(error_output.string).to include("restart_agent for pane 0.1")
  ensure
    cleanup(agent, restart) if agent
  end

  it "C6: releases the pane before a waiting caller hears the outcome, so an immediate follow-up isn't refused" do
    done = Object.new
    done.define_singleton_method(:call) { |**| {"ok" => true, "status" => "restarted", "pane_id" => "%18"} }
    agent = build_agent(->(**) { done })
    waiting_client = ConcurrencySlowCloseClient.new

    expect(agent.send(:handle_restart_agent, message.merge("wait" => true), waiting_client)).to eq(:handed_off)
    outcome = waiting_client.lines.pop(timeout: 2)
    expect(JSON.parse(outcome)).to include("ok" => true, "status" => "restarted")

    # The caller has its "restarted" reply and immediately asks again.
    follow_up = StringIO.new
    agent.send(:handle_restart_agent, message, follow_up)
    expect(reply_of(follow_up)).to include("ok" => true, "status" => "started")
  ensure
    waiting_client&.release
    cleanup(agent) if agent
  end
end
