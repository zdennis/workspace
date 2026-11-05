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

# A pane whose screen redraws on every read, as a background sub-agent's timer
# keeps it. Its box is what `styled` says. A delivery runs the hook events the
# real agent would answer it with on the next tick.
class MovingScreenTmux
  BOX = "#{"─" * 40}\n❯ \n#{"─" * 40}\n"

  attr_accessor :styled, :on_typing_check
  attr_reader :texts

  def initialize(after_delivery)
    @styled = BOX
    @frame = 0
    @texts = []
    @after_delivery = after_delivery
  end

  def pane_details(_session, window: "0")
    @on_typing_check&.call if window.nil?
    [{id: "%18", window: 0, index: 1, pid: 2, command: "claude", cwd: "/", title: ""}]
  end

  def capture_screen(_target) = "#{@frame += 1}s\n#{BOX}"

  def capture_pane(_session, _index) = "pane"

  def capture_screen_styled(_target) = @styled

  def deliver(_session, _target, text, **)
    @texts << text
    @after_delivery.call(text)
    Workspace::Tmux::Delivery.new(status: :submitted, message: "fake submitted")
  end
end

RSpec.describe "restart_agent with main activity after the Stop" do
  let(:clock) { Struct.new(:now).new(Time.utc(2026, 10, 31, 12, 0, 0)) }
  let(:ticks) { [] }
  let(:tmux) { MovingScreenTmux.new(method(:answer_delivery)) }
  let(:dir) { Dir.mktmpdir("moving-screen") }
  let(:transcript) { File.join(dir, "main.jsonl") }
  let(:snapshot) { Object.new }
  let(:process_tree) { instance_double(Workspace::ProcessTree, snapshot: snapshot) }
  let(:detector) { ->(**) { {provider: Workspace::AgentProvider.find("claude"), pid: 99} } }
  let(:monitor) do
    Workspace::SessionMonitor.new(tmux: tmux, process_tree: process_tree, session_name: "s", clock: clock, detector: detector)
  end
  let(:context_reader) do
    instance_double(Workspace::ContextReader, read: {pct: nil, error: Workspace::ContextReasons::NO_READING, updated_at: nil})
  end
  let(:bindings) { instance_double(Workspace::PaneBindings, binding_for: {"kind" => "run", "id" => "wr_1"}) }
  let(:agent) do
    factory = lambda do |**wired|
      Workspace::AgentRestart.new(tmux: tmux, context_reader: context_reader, clock: -> { clock.now.to_f }, wall_clock: -> { clock.now },
        sleeper: method(:tick), quiet_timeout: 30, **wired)
    end
    Workspace::Commands::Agent.new(config: instance_double(Workspace::Config), tmux: tmux,
      work_coordinator_client: instance_double(Workspace::WorkCoordinatorClient),
      pipeline_config: Workspace::PipelineConfig.new(config: instance_double(Workspace::Config)), context_reader: context_reader,
      pane_bindings: bindings, agent_restart_factory: factory, output: StringIO.new, error_output: StringIO.new).tap do |built|
      built.instance_variable_set(:@session_monitor, monitor)
    end
  end

  before do
    File.write(transcript, "")
    monitor.scan
    hook("user_prompt")
    write_record("assistant")
    clock.now += 1
    hook("stop")
    write_record("system", "subtype" => "stop_hook_summary")
  end

  after { FileUtils.remove_entry(dir) }

  def hook(name, extra = {})
    monitor.record({"event" => name, "pane_id" => "%18", "session_id" => "s1", "transcript_path" => transcript}.merge(extra))
  end

  def write_record(type, extra = {})
    stamp = (clock.now + 0.001).utc.iso8601(3)
    File.write(transcript, JSON.generate({"type" => type, "timestamp" => stamp}.merge(extra)) + "\n", mode: "a")
  end

  def tick(seconds)
    clock.now += seconds
    ticks.shift.call until ticks.empty?
    @at&.call
  end

  def answer_delivery(text)
    ticks << ((text == "/clear") ? -> { hook("session_start", "source" => "clear", "session_id" => "s2") } : -> { hook("user_prompt", "session_id" => "s2") })
  end

  # Runs the callable once, +seconds+ after the restart starts.
  def after_seconds(seconds, thing)
    start = clock.now
    done = false
    @at = lambda do
      next if done || clock.now - start < seconds
      done = true
      thing.call
    end
  end

  # Runs the callable once, under the delivery lock, right before the last check.
  def at_the_final_check(thing)
    done = false
    tmux.on_typing_check = lambda do
      next if done
      done = true
      thing.call
    end
  end

  def restart(run_id: nil)
    client = StringIO.new
    agent.send(:run_restart, {"pane" => "0.1", "pane_id" => "%18"}, "Read the plan", false, 30, client, run_id: run_id)
    JSON.parse(client.string.lines.last)
  end

  activity = {
    "a main tool starting" => [->(s) { s.hook("tool_start", "tool" => "Bash", "tool_use_id" => "t1") }, /main_tool_after_stop|turn_started/],
    "a main tool finishing" => [->(s) { s.hook("tool_use", "tool" => "Bash", "tool_use_id" => "t1") }, /main_tool_after_stop|turn_started/],
    "a prompt" => [->(s) { s.hook("user_prompt") }, /main_prompt_after_stop|turn_started/],
    "a sub-agent start" => [->(s) { s.hook("subagent_start", "tool" => "Agent") }, /subagent_start_after_stop|turn_started/],
    "a session start" => [->(s) { s.hook("session_start", "source" => "resume") }, /session_start_after_stop|turn_started/],
    "a queue-operation record" => [->(s) { s.write_record("queue-operation") }, %r{transcript_activity:queue-operation|turn_started}],
    "a user record" => [->(s) { s.write_record("user") }, %r{transcript_activity:user|turn_started}],
    "an assistant record" => [->(s) { s.write_record("assistant") }, %r{transcript_activity:assistant|turn_started}],
    "an api-request record" => [->(s) { s.write_record("api-request") }, %r{transcript_activity:api-request|turn_started}],
    "a record of a new type" => [->(s) { s.write_record("cost-v2") }, %r{transcript_activity:cost-v2|turn_started}],
    "a spinner row" => [->(s) { s.tmux.styled = "✽ Frosting… (2s)\n\n#{MovingScreenTmux::BOX}" }, /turn_started/],
    "a draft" => [->(s) { s.tmux.styled = "#{"─" * 40}\n❯ half a thought\n#{"─" * 40}\n" }, /input_not_empty/]
  }

  activity.each do |name, (act, proof)|
    {"early in the wait" => 1, "while the proof is held" => 4}.each do |moment, seconds|
      it "never types /clear after #{name} #{moment}" do
        after_seconds(seconds, -> { act.call(self) })

        reply = restart

        expect(tmux.texts).to be_empty
        expect(reply).to include("ok" => false, "error" => "pane_busy")
        expect(reply.dig("details", "proof_missing")).to match(proof)
      end
    end

    it "never types /clear after #{name} under the delivery lock" do
      at_the_final_check(-> { act.call(self) })

      reply = restart

      expect(tmux.texts).to be_empty
      expect(reply).to include("ok" => false, "error" => "pane_busy")
      expect(reply.dig("details", "proof_missing")).to match(proof)
    end
  end

  it "types /clear with no activity after the Stop, and warns of the background work" do
    reply = restart

    expect(tmux.texts).to eq(["/clear", "Read the plan"])
    expect(reply).to include("ok" => true, "status" => "restarted")
    expect(reply["warning"]).to include("background work in pane %18", "may be lost")
  end

  it "takes the Stop's own housekeeping and a sub-agent's tool for no activity" do
    after_seconds(1, lambda {
      write_record("system", "subtype" => "turn_duration")
      write_record("attachment")
      write_record("user", "isSidechain" => true)
      hook("tool_use", "agent_id" => "a1", "tool" => "Bash", "tool_use_id" => "t2")
    })

    expect(restart).to include("ok" => true, "status" => "restarted")
  end

  it "stops when the run was cancelled during the wait, with nothing typed" do
    after_seconds(1, -> { allow(bindings).to receive(:binding_for).and_return(nil) })

    expect(restart(run_id: "wr_1")).to include("ok" => false, "error" => "run_unbound")
    expect(tmux.texts).to be_empty
  end
end
