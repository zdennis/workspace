# The setup the "waking workflow runs" agent specs share, on top of "an agent daemon over a fake
# coordinator": a QuietSessionMonitor recording each hook event's name, a nudger recording each
# turn_ended and tick, an agent built over both, +send_event+ (one session_event for pane %5 over the
# daemon's socket, answering its reply) and a started coordinator.
RSpec.shared_context "waking workflow runs" do
  let(:recorded_events) { [] }
  let(:monitor) do
    QuietSessionMonitor.new(events: recorded_events)
  end
  let(:nudger) do
    Class.new do
      attr_reader :turns, :ticks

      def initialize
        @turns = []
        @ticks = []
      end

      def turn_ended(workspace, pane, turn_started: nil, background: nil) = @turns << [workspace, pane, turn_started, background]

      def tick(workspace) = @ticks << workspace
    end.new
  end

  subject(:agent) do
    build_agentd(
      config: config, tmux: tmux, work_coordinator_client: client,
      pipeline_config: pipeline_config, pipeline_state: pipeline_state,
      epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
      sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
      clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
      workflow_nudger: nudger, socket_poll_interval: socket_poll_interval, workflow_tick_passes: workflow_tick_passes,
      output: output, error_output: error_output
    )
  end

  def send_event(event, **extra)
    message = {"type" => "session_event", "workspace" => "myapp", "event" => event, "pane_id" => "%5"}.merge(extra.transform_keys(&:to_s))
    UNIXSocket.open(agent_socket_path) do |socket|
      socket.puts(message.to_json)
      JSON.parse(socket.gets)
    end
  end

  before { coordinator.start }
end
