require "spec_helper"
require "tmpdir"
require "json"

# Just enough of a session monitor for the daemon to start.
class IdleSessionMonitor
  def start = nil

  def stop = nil

  def snapshot = {"panes" => []}

  def record(_message) = nil
end

RSpec.describe "Pipeline reliability adversarial concurrency" do
  # Hands callbacks to the spec instead of polling, so a spec decides when a
  # stage finishes and from which thread.
  let(:fake_poller_class) do
    Class.new do
      attr_reader :pane, :token, :on_complete, :on_error, :on_timeout

      def initialize(pane:, token:)
        @pane = pane
        @token = token
      end

      def start(on_error: nil, on_timeout: nil, &block)
        @on_complete = block
        @on_error = on_error
        @on_timeout = on_timeout
        self
      end

      def stop
        @stopped = true
      end
    end
  end

  # A real poller that remembers its thread so the spec can join it.
  let(:tracking_poller_class) do
    Class.new(Workspace::SentinelPoller) do
      attr_reader :poll_thread

      def start(...)
        @poll_thread = super
      end
    end
  end

  let(:status_client_class) do
    Class.new do
      attr_reader :reports

      def initialize(&hook)
        @reports = []
        @mutex = Mutex.new
        @hook = hook
      end

      def report_status(payload)
        @mutex.synchronize { @reports << payload }
        @hook&.call(payload)
        {"ok" => true}
      end
    end
  end

  # Under /tmp so the daemon socket path stays inside the 104-byte limit.
  let(:tmpdir) { Dir.mktmpdir("ws-pc", "/tmp") }
  let(:project_config_path) { File.join(tmpdir, "myapp.yml") }
  let(:state_path) { File.join(tmpdir, "state", "pipeline.json") }
  let(:tmux) { FakeTmux.new }
  let(:error_output) { StringIO.new }
  let(:output) { StringIO.new }
  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:project_config_path).with("myapp").and_return(project_config_path)
      allow(c).to receive(:handoff_dir).and_return(File.join(tmpdir, "handoffs"))
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(File.join(tmpdir, "workspace-myapp.sock"))
      allow(c).to receive(:prompt_queue_path).and_return(File.join(tmpdir, "prompt-queue.json"))
    end
  end
  let(:pipeline_config) { Workspace::PipelineConfig.new(config: config) }
  let(:pollers) { [] }
  let(:fake_factory) do
    lambda do |session_name:, pane:, token:, deadline:|
      fake_poller_class.new(pane: pane, token: token).tap { |p| pollers << p }
    end
  end
  let(:token_generator) do
    count = 0
    -> { "tok-#{count += 1}" }
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  def write_pipeline(panes)
    File.write(project_config_path, {"pipeline" => {"panes" => panes}}.to_yaml)
  end

  def build_agent(client:, pipeline_state:, factory: fake_factory, **extra)
    build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),

      config: config, tmux: tmux, work_coordinator_client: client,
      pipeline_config: pipeline_config, pipeline_state: pipeline_state,
      signal_trapper: Object.new, sentinel_poller_factory: factory,
      token_generator: token_generator, clock: -> { Time.utc(2026, 9, 27, 12) },
      retry_backoff: 0, current_name: "myapp", error_output: error_output, output: output, **extra)
  end

  def command(ref, dispatch_id)
    {"type" => "command", "workspace" => "myapp", "work_item_ref" => ref,
     "dispatch_id" => dispatch_id, "body" => "do the thing"}
  end

  def in_thread(&block)
    Thread.new(&block).tap { |t| expect(t.join(2)).not_to be_nil }
  end

  it "PC1: a stage whose hand-off raises (config edited mid-run) is failed, not left in flight with no watcher" do
    write_pipeline([{"role" => "research"}, {"role" => "implement"}])
    client = status_client_class.new
    state = Workspace::PipelineState.new(pipeline_config: pipeline_config)
    agent = build_agent(client: client, pipeline_state: state)
    agent.handle(command("WC-1", "d-1"))

    write_pipeline([{"role" => "research"}, {"role" => "implement", "timeout" => "soon-ish"}])
    in_thread { pollers.first.on_complete.call("research done") }

    # The poller that saw the sentinel has exited; nothing else will ever look.
    expect(client.reports.map { |r| r["type"] }).to include("error")
    expect(state.current("WC-1")).to be_nil
  end

  it "PC2: the next stage is armed before the finished stage's reports go out, so its task_complete is sequenced ahead of pipeline_advanced" do
    write_pipeline([{"role" => "research"}, {"role" => "implement"}])
    client = status_client_class.new do |payload|
      # Slow coordinator: while the stage-1 thread is still reporting, the
      # stage-2 poller (already armed) finds its sentinel.
      if payload["type"] == "phase_change" && pollers.size >= 2
        in_thread { pollers.last.on_complete.call("implemented") }
      end
    end
    state = Workspace::PipelineState.new(pipeline_config: pipeline_config)
    agent = build_agent(client: client, pipeline_state: state)
    agent.handle(command("WC-2", "d-1"))

    in_thread { pollers.first.on_complete.call("researched") }
    unless client.reports.any? { |r| r["type"] == "task_complete" }
      in_thread { pollers.last.on_complete.call("implemented") }
    end

    seq = client.reports.to_h { |r| [r["type"], r["sequence"]] }
    expect(seq.fetch("pipeline_advanced")).to be < seq.fetch("task_complete")
  end

  it "PC3: re-dispatching an in-flight work item leaves the old poller live while 'started' is reported, and its sentinel advances the new dispatch" do
    write_pipeline([{"role" => "research"}, {"role" => "implement"}])
    started = 0
    client = status_client_class.new do |payload|
      next unless payload["type"] == "status_update" && payload["message"].to_s.start_with?("Pipeline started")
      started += 1
      # The first dispatch's stage prints its (old-token) sentinel just now.
      in_thread { pollers.first.on_complete.call("old dispatch finished") } if started == 2
    end
    state = Workspace::PipelineState.new(pipeline_config: pipeline_config)
    agent = build_agent(client: client, pipeline_state: state)
    agent.handle(command("WC-3", "d-1"))
    agent.handle(command("WC-3", "d-2"))

    entry = state.current("WC-3")
    expect(entry).to include(dispatch_id: "d-2", pane_index: 0, sentinel_token: "tok-2")
    expect(tmux.sent_keys.map { |k| k[:pane] }).not_to include("0.1")
  end

  it "PC4: a narrow pane word-wrapping the echoed instruction ends the stage without the stage ever reporting" do
    token = "ab12cd34"
    wraps = [
      "When you are done, print a\nsingle line:\n  WORKSPACE_DONE:#{token}\n  <one-line summary>\n",
      "When you are done, print a single line:\n  WORKSPACE_DONE:#{token} <one-line\n  summary>\n"
    ]
    summaries = wraps.map do |pane_text|
      fake = Struct.new(:text) { def capture_pane(*, **) = text }.new(pane_text)
      completed = Queue.new
      poller = Workspace::SentinelPoller.new(tmux: fake, session_name: "myapp", pane: 0, token: token,
        poll_interval: 0.001, error_output: StringIO.new)
      thread = poller.start { |summary| completed << summary }
      result = begin
        completed.pop(timeout: 0.1)
      ensure
        poller.stop
        thread.join(1)
      end
      result
    end
    expect(summaries).to eq([nil, nil])
  end

  it "PC5: recovery drops a dead-pane item without the state lock while a re-armed poller advances another, and the shared temp file loses a write" do
    write_pipeline([{"role" => "research"}, {"role" => "implement"}])
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, JSON.generate(
      "WC-A" => {work_item_ref: "WC-A", workspace_name: "myapp", dispatch_id: "d-a", pane_index: 0,
                 phase: "research", sentinel_token: "tok-a"},
      "WC-B" => {work_item_ref: "WC-B", workspace_name: "myapp", dispatch_id: "d-b", pane_index: 7,
                 phase: "research", sentinel_token: "tok-b"}
    ))
    state = Workspace::PipelineState.new(pipeline_config: pipeline_config, state_path: state_path)
    tmux.captured_output = "WORKSPACE_DONE:tok-a finished while the agent was down\n"
    tmux.pane_indexes = [0, 1]

    real = []
    factory = lambda do |session_name:, pane:, token:, deadline:|
      tracking_poller_class.new(tmux: tmux, session_name: session_name, pane: pane, token: token,
        deadline: deadline, poll_interval: 0.001, error_output: StringIO.new).tap { |p| real << p }
    end

    # Two writers in persist at once meet at the rename.
    arrived = Queue.new
    rename_errors = Queue.new
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      if to == state_path
        arrived << 1
        deadline = Time.now + 0.5
        Thread.pass while arrived.size < 2 && Time.now < deadline
      end
      begin
        original.call(from, to)
      rescue SystemCallError => e
        rename_errors << e
        raise
      end
    end

    # The daemon's startup recovers the in-flight items before it serves.
    trapper = Class.new do
      attr_reader :handlers

      def initialize = @handlers = {}

      def trap(signal, &block) = @handlers[signal] = block
    end.new
    agent = build_agent(client: instance_double(Workspace::WorkCoordinatorClient, register: {"ok" => true}, deregister: nil,
      status_socket_path: nil, report_status: {"ok" => true}),
      pipeline_state: state, factory: factory, signal_trapper: trapper,
      session_monitor_factory: ->(_name) { IdleSessionMonitor.new })
    daemon = Thread.new { agent.call(name: "myapp") }
    begin
      wait_until = Time.now + 2
      Thread.pass until output.string.include?("ready") || !daemon.alive? || Time.now > wait_until
    ensure
      wait_until = Time.now + 1
      Thread.pass until real.size >= 2 || Time.now > wait_until
      trapper.handlers["TERM"]&.call
      daemon.join(2)
      daemon.kill
      real.each(&:stop)
      real.each { |p| p.poll_thread&.join(1) }
    end

    expect(rename_errors.size).to eq(0)
  end
end
