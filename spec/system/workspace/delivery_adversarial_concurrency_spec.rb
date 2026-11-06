require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"

# Adversarial specs for T3 (reliable delivery to agents). Each example fails
# for the defect named in its description; none needs tmux, iTerm2, or a
# real clock.
RSpec.describe "T3 delivery: concurrency and liveness defects" do
  let(:tmpdir) { Dir.mktmpdir("ws-dc") }
  let(:error_output) { StringIO.new }
  let(:states) { [] }
  let(:coordinator_client) do
    Class.new do
      def initialize
        @sent = []
        @lock = Mutex.new
      end

      def report_status(payload)
        @lock.synchronize { @sent << payload }
        {"ok" => true}
      end

      def sent = @lock.synchronize { @sent.dup }
    end.new
  end

  after { FileUtils.remove_entry(tmpdir) }

  def delivery(status, message = "fake #{status}")
    Workspace::Tmux::Delivery.new(status: status, message: message)
  end

  # A tmux stand-in with the lookups the agent makes for the Claude pane;
  # +deliver+ runs the given block.
  def fake_tmux(&deliver)
    Class.new do
      def initialize(deliver) = @deliver = deliver

      def deliver(*args, **opts) = @deliver.call(*args, **opts)

      def capture_pane(*, **) = "stage one output"

      def session_name_for(name) = name

      def panes(*, **) = [0, 1]

      def find_pane_by_title(*, **) = 1
    end.new(deliver)
  end

  def command(ref, body)
    {"type" => "command", "workspace" => "myapp", "work_item_ref" => ref, "body" => body}
  end

  def build_agent(tmux:, stages:, pollers: [])
    pipeline_config = instance_double(Workspace::PipelineConfig)
    allow(pipeline_config).to receive(:stages_for).and_return(stages)
    pipeline_state = Workspace::PipelineState.new(pipeline_config: pipeline_config).tap { |built| states << built }
    config = instance_double(Workspace::Config, handoff_dir: File.join(tmpdir, "handoffs"))
    count = 0
    poller_class = Class.new do
      attr_reader :on_complete

      def start(on_error: nil, on_timeout: nil, &block)
        @on_complete = block
        self
      end

      def stop = nil
    end
    Workspace::Commands::Agent.new(
      config: config, tmux: tmux, work_coordinator_client: coordinator_client,
      pipeline_config: pipeline_config,
      pipeline_state: pipeline_state,
      signal_trapper: double("signals"), session_monitor_factory: ->(_name) {},
      sentinel_poller_factory: ->(**) { poller_class.new.tap { |p| pollers << p } },
      token_generator: -> { "tok-#{count += 1}" },
      clock: -> { Time.utc(2026, 9, 27) },
      retry_backoff: 0, current_name: "myapp", output: StringIO.new, error_output: error_output
    )
  end

  it "DC1: a slow deliver holds @state_lock, so an unrelated fail_pipeline stalls behind it" do
    entered = Queue.new
    gate = Queue.new
    ok = delivery(:submitted)
    slow_tmux = fake_tmux do |*_args, **_opts|
      entered << true
      gate.pop
      ok
    end
    agent = build_agent(tmux: slow_tmux, stages: nil)

    sender = Thread.new { agent.handle(command("WC-1", "hi"), StringIO.new) }
    other = nil
    begin
      expect(entered.pop(timeout: 2)).to be(true)
      # Stands in for another item's poller timing out while the paste is
      # being checked (up to ~7s per deliver in production).
      other = Thread.new { agent.fail_pipeline("WC-2", "timed out") }
      expect(other.join(0.5)).not_to be_nil, "fail_pipeline for WC-2 blocked on the lock held across deliver"
    ensure
      gate << true
      [sender, other].compact.each { |t| t.join(2) || t.kill }
    end
  end

  it "DC1: a work item failed while its hand-off is being typed stays failed" do
    entered = Queue.new
    gate = Queue.new
    ok = delivery(:submitted)
    tmux = fake_tmux do |_s, _p, text, **|
      if text.start_with?("You are the review stage")
        entered << true
        gate.pop
      end
      ok
    end
    pollers = []
    stages = [{pane_index: 1, role: "impl", timeout: nil}, {pane_index: 2, role: "review", timeout: nil}]
    agent = build_agent(tmux: tmux, stages: stages, pollers: pollers)
    agent.handle(command("WC-1", "do it"), StringIO.new)

    advancing = Thread.new { pollers.last.on_complete.call("stage one done") }
    begin
      expect(entered.pop(timeout: 2)).to be(true)
      agent.fail_pipeline("WC-1", "work-coordinator aborted the pipeline")
    ensure
      gate << true
      advancing.join(2) || advancing.kill
    end

    expect(states.last.current("WC-1")).to be_nil
    expect(coordinator_client.sent.map { |r| r["type"] }).not_to include("phase_change")
  end

  it "DC2: a pane whose output keeps moving reports a paste that never appeared as submitted" do
    now = [0.0]
    tmux = Workspace::Tmux.new(config: nil, clock: -> { now[0] }, sleeper: ->(s) { now[0] += s })
    frame = 0
    # A streaming agent (or one redrawing after deliver_urgent_steer's C-c):
    # every read differs, and "fix the bug" is never on screen.
    allow(tmux).to receive(:capture_screen) { "working #{frame += 1}" }
    allow(tmux).to receive(:tmux_load_buffer).and_return(true)
    allow(tmux).to receive(:tmux_paste_buffer).and_return([true, nil])
    allow(tmux).to receive(:system).and_return(true)

    result = tmux.deliver("myapp", "0.1", "fix the bug")

    expect(result.status).not_to eq(:submitted),
      "reported #{result.status} although the text never showed up on any screen read"
  end

  it "DC3: two separate processes use the same tmux paste buffer name, so concurrent sends can swap text" do
    script = <<~RUBY
      require "workspace"
      class BufferNamePrinter < Workspace::Tmux
        def capture_screen(_) = nil

        def system(*) = true

        def tmux_load_buffer(buf, _) = puts(buf) || false
      end
      tmux = BufferNamePrinter.new(config: nil)
      tmux.deliver("myapp", "0.1", "hi")
    RUBY
    lib = File.join(PROJECT_ROOT, "lib")
    names = 2.times.map do
      out, status = Open3.capture2(RbConfig.ruby, "-I", lib, "-e", script)
      expect(status).to be_success
      out.strip
    end

    expect(names.first).to start_with("ws_send_")
    expect(names.uniq.size).to eq(2), "both processes loaded tmux buffer #{names.first.inspect}"
  end

  it "DC4: a prompt that didn't land near the shared deadline is reported as 'still starting up', hiding the paste failure" do
    now = [0.0]
    tmux = instance_double(Workspace::Tmux)
    allow(tmux).to receive(:pane_details).and_return([{id: "%2", window: 0, index: 1, pid: 200, command: "claude"}])
    allow(tmux).to receive(:capture_screen).and_return(("─" * 20) + "\n❯ ")
    process_tree = instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([]))
    readiness = Workspace::AgentReadiness.new(tmux: tmux, process_tree: process_tree,
      clock: -> { now[0] }, sleeper: ->(s) { now[0] += s })
    allow(tmux).to receive(:deliver) do
      now[0] += Workspace::Tmux::LAND_TIMEOUT
      delivery(:not_landed, "pasted, but nothing changed in proj:0.1 within 2.0s")
    end
    # A headless launch over a session that is already running reaches the
    # prompt delivery with nothing else to start.
    allow(tmux).to receive_messages(session_name_for: "proj", sessions: ["proj"], custom_socket_option: nil,
      start_server: nil, rename_window: nil)
    state = Class.new(Hash) do
      def load = nil

      def save = nil
    end.new
    project_config = instance_double(Workspace::ProjectConfig, exists?: true)
    config = instance_double(Workspace::Config, state_dir: tmpdir)
    agent_ensurer = double("ensurer", call: double(ok?: true))
    launch = Workspace::Commands::Launch.new(state: state, iterm: double, window_manager: double, tmux: tmux,
      project_config: project_config, window_layout: double, config: config, pipeline_config: double,
      agent_ensurer: agent_ensurer, agent_readiness: readiness, prompt_timeout: 3,
      sleeper: ->(s) { now[0] += s }, clock: -> { now[0] }, output: StringIO.new, error_output: error_output)

    result = launch.call(["proj"], headless: true, prompts: {"proj" => "do it"}, prompt_timeout: 3)

    failure = result[:prompt_failures]["proj"]
    expect(failure).to include("nothing changed"), "reported #{failure.inspect}"
  end

  it "DC5: a queued steer acknowledged ok is dropped without telling the coordinator when it fails to land" do
    tmux = fake_tmux do |_s, _p, text, **|
      status = (text == "steer me") ? :not_landed : :submitted
      Workspace::Tmux::Delivery.new(status: status, message: "fake")
    end
    pollers = []
    stages = [{pane_index: 1, role: "impl", timeout: nil}, {pane_index: 2, role: "review", timeout: nil}]
    agent = build_agent(tmux: tmux, stages: stages, pollers: pollers)
    replies = StringIO.new

    agent.handle(command("WC-1", "do it"), StringIO.new)
    agent.handle({"type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-1", "body" => "steer me"}, replies)
    expect(JSON.parse(replies.string.lines.last)).to include("ok" => true)
    pollers.last.on_complete.call("stage one done")

    expect(coordinator_client.sent.map { |r| r["message"].to_s }).to include(a_string_matching(/steer/)),
      "the steer's failure went only to the daemon's stderr: #{error_output.string.inspect}"
  end
end
