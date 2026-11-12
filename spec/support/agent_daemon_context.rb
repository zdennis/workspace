# The daemon setup the agent specs share: a fake work coordinator over sockets in a tmpdir, a
# config stub that routes every path there, a recording signal trapper, predictable stage tokens and
# a FakeSentinelPoller factory. A spec overrides `session_monitor_factory` to change the monitor.
RSpec.shared_context "an agent daemon over a fake coordinator" do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-agent", "/tmp") }
  let(:wc_socket_path) { File.join(tmpdir, "work-coordinator.sock") }
  let(:wc_status_socket_path) { File.join(tmpdir, "work-coordinator-status.sock") }
  let(:agent_socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:output) { ReadyAnnouncingOutput.new }
  let(:error_output) { StringIO.new }
  let(:coordinator) do
    FakeWorkCoordinator.new(socket_path: wc_socket_path, status_socket_path: wc_status_socket_path)
  end

  # Config stub that routes all socket paths into the spec's tmpdir.
  let(:project_config_path) { File.join(tmpdir, "myapp.yml") }
  let(:tmux) { FakeTmux.new }

  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(agent_socket_path)
      allow(c).to receive(:prompt_queue_path) { |name| File.join(tmpdir, "#{name}-prompt-queue.json") }
      allow(c).to receive(:work_coordinator_socket).and_return(wc_socket_path)
      allow(c).to receive(:work_coordinator_status_socket).and_return(wc_status_socket_path)
      allow(c).to receive(:project_config_path).with("myapp").and_return(project_config_path)
      allow(c).to receive(:handoff_dir).and_return(File.join(tmpdir, "handoffs"))
      allow(c).to receive(:state_dir).and_return(File.join(tmpdir, "state"))
    end
  end

  let(:client) do
    Workspace::WorkCoordinatorClient.new(
      socket_path: wc_socket_path,
      status_socket_path: wc_status_socket_path
    )
  end

  # Signal traps are process-global; specs record registrations instead.
  let(:signal_trapper) do
    Class.new do
      attr_reader :handlers

      def initialize
        @handlers = {}
      end

      def trap(signal, &block)
        @handlers[signal] = block
      end
    end.new
  end

  let(:pipeline_config) { Workspace::PipelineConfig.new(config: config) }
  let(:pipeline_state) { Workspace::PipelineState.new(pipeline_config: pipeline_config) }

  let(:pollers) { [] }
  let(:sentinel_poller_factory) do
    lambda do |session_name:, pane:, token:, deadline:|
      FakeSentinelPoller.new(session_name: session_name, pane: pane, token: token, deadline: deadline)
        .tap { |p| pollers << p }
    end
  end

  let(:now) { Time.utc(2026, 9, 27, 12, 0, 0) }

  # Predictable per-stage tokens: tok-1 for the first dispatch, tok-2 for the next.
  let(:token_generator) do
    count = 0
    -> { "tok-#{count += 1}" }
  end

  let(:restart_registry) { Workspace::RestartRegistry.new }
  let(:socket_poll_interval) { described_class::SOCKET_POLL_INTERVAL }
  let(:workflow_tick_passes) { described_class::WORKFLOW_TICK_PASSES }

  let(:session_monitor_factory) { default_session_monitor_builder(tmux: tmux, error_output: error_output) }

  subject(:agent) do
    build_agentd(session_monitor_factory: session_monitor_factory,
      config: config,
      restart_registry: restart_registry,
      tmux: tmux,
      work_coordinator_client: client,
      pipeline_config: pipeline_config,
      pipeline_state: pipeline_state,
      epoch_generator: -> { "wa-TESTEPOCH" },
      signal_trapper: signal_trapper,
      sentinel_poller_factory: sentinel_poller_factory,
      token_generator: token_generator,
      clock: -> { now },
      retry_backoff: 0,
      socket_poll_interval: socket_poll_interval,
      workflow_tick_passes: workflow_tick_passes,
      output: output,
      error_output: error_output)
  end

  after do
    coordinator.stop
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  # Runs the agent in a thread, waits for readiness, yields, then shuts it down.
  def run_agent
    thread = Thread.new do
      agent.call(name: "myapp")
    ensure
      output.announce
    end
    output.wait_ready
    yield thread
  ensure
    signal_trapper.handlers["TERM"]&.call
    thread&.join(2)
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    sleep(0.01) until yield || Time.now > deadline
    raise "timed out waiting after #{timeout}s" unless yield
  end
end
