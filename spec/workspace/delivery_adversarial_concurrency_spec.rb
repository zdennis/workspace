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

  after { FileUtils.remove_entry(tmpdir) }

  def delivery(status, message = "fake #{status}")
    Workspace::Tmux::Delivery.new(status: status, message: message)
  end

  def build_agent(tmux:, stages:, pollers: [])
    pipeline_config = instance_double(Workspace::PipelineConfig)
    allow(pipeline_config).to receive(:stages_for).and_return(stages)
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
    agent = Workspace::Commands::Agent.new(
      config: config, tmux: tmux, work_coordinator_client: double("wc"),
      pipeline_config: pipeline_config,
      pipeline_state: Workspace::PipelineState.new(pipeline_config: pipeline_config),
      signal_trapper: double("signals"),
      sentinel_poller_factory: ->(**) { poller_class.new.tap { |p| pollers << p } },
      token_generator: -> { "tok-#{count += 1}" },
      clock: -> { Time.utc(2026, 9, 27) },
      retry_backoff: 0, output: StringIO.new, error_output: error_output
    )
    agent.instance_variable_set(:@current_name, "myapp")
    allow(agent).to receive(:report)
    agent
  end

  it "DC1: a slow deliver holds @state_lock, so an unrelated fail_pipeline stalls behind it" do
    entered = Queue.new
    gate = Queue.new
    slow_tmux = Object.new
    ok = delivery(:submitted)
    slow_tmux.define_singleton_method(:deliver) do |*_args, **_opts|
      entered << true
      gate.pop
      ok
    end
    agent = build_agent(tmux: slow_tmux, stages: nil)
    allow(agent).to receive(:claude_pane_target).and_return("0.1")

    sender = Thread.new { agent.send(:handle_command, {"work_item_ref" => "WC-1", "body" => "hi"}) }
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
    tmux = Object.new
    ok = delivery(:submitted)
    tmux.define_singleton_method(:deliver) do |_s, _p, text, **|
      if text.start_with?("You are the review stage")
        entered << true
        gate.pop
      end
      ok
    end
    tmux.define_singleton_method(:capture_pane) { |*, **| "stage one output" }
    pollers = []
    stages = [{pane_index: 1, role: "impl", timeout: nil}, {pane_index: 2, role: "review", timeout: nil}]
    agent = build_agent(tmux: tmux, stages: stages, pollers: pollers)
    agent.send(:handle_command, {"work_item_ref" => "WC-1", "body" => "do it"})

    advancing = Thread.new { pollers.last.on_complete.call("stage one done") }
    begin
      expect(entered.pop(timeout: 2)).to be(true)
      agent.fail_pipeline("WC-1", "work-coordinator aborted the pipeline")
    ensure
      gate << true
      advancing.join(2) || advancing.kill
    end

    expect(agent.instance_variable_get(:@pipeline_state).current("WC-1")).to be_nil
    expect(agent).not_to have_received(:report).with(anything, hash_including("type" => "phase_change"))
  end

  it "DC2: a pane whose output keeps moving reports a paste that never appeared as submitted" do
    now = [0.0]
    tmux = Workspace::Tmux.new(config: nil, clock: -> { now[0] }, sleeper: ->(s) { now[0] += s })
    frame = 0
    # A streaming agent (or one redrawing after deliver_urgent_steer's C-c):
    # every read differs, and "fix the bug" is never on screen.
    allow(tmux).to receive(:capture_screen) { "working #{frame += 1}" }
    allow(tmux).to receive(:tmux_load_buffer).and_return(true)
    allow(tmux).to receive(:system).and_return(true)

    result = tmux.deliver("myapp", "0.1", "fix the bug")

    expect(result.status).not_to eq(:submitted),
      "reported #{result.status} although the text never showed up on any screen read"
  end

  it "DC3: two separate processes use the same tmux paste buffer name, so concurrent sends can swap text" do
    script = <<~RUBY
      require "workspace"
      tmux = Workspace::Tmux.new(config: nil)
      tmux.define_singleton_method(:capture_screen) { |_| nil }
      tmux.define_singleton_method(:system) { |*| true }
      tmux.define_singleton_method(:tmux_load_buffer) { |buf, _| puts(buf) || false }
      tmux.deliver("myapp", "0.1", "hi")
    RUBY
    lib = File.expand_path("../../lib", __dir__)
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
    allow(tmux).to receive(:capture_screen).and_return("│ > │")
    process_tree = instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([]))
    readiness = Workspace::AgentReadiness.new(tmux: tmux, process_tree: process_tree,
      clock: -> { now[0] }, sleeper: ->(s) { now[0] += s })
    allow(tmux).to receive(:deliver) do
      now[0] += Workspace::Tmux::LAND_TIMEOUT
      delivery(:not_landed, "pasted, but nothing changed in proj:0.1 within 2.0s")
    end
    launch = Workspace::Commands::Launch.new(state: double, iterm: double, window_manager: double, tmux: tmux,
      project_config: double, window_layout: double, config: double, pipeline_config: double,
      agent_readiness: readiness, prompt_timeout: 3, output: StringIO.new, error_output: error_output)

    failure = launch.send(:deliver_prompt, "proj", "proj", "do it", readiness.deadline_in(3), 3)

    expect(failure).to include("nothing changed"), "reported #{failure.inspect}"
  end

  it "DC5: a queued steer acknowledged ok is dropped without telling the coordinator when it fails to land" do
    tmux = Object.new
    tmux.define_singleton_method(:deliver) do |_s, _p, text, **|
      status = (text == "steer me") ? :not_landed : :submitted
      Workspace::Tmux::Delivery.new(status: status, message: "fake")
    end
    tmux.define_singleton_method(:capture_pane) { |*, **| "stage one output" }
    pollers = []
    stages = [{pane_index: 1, role: "impl", timeout: nil}, {pane_index: 2, role: "review", timeout: nil}]
    agent = build_agent(tmux: tmux, stages: stages, pollers: pollers)
    replies = []
    client = Object.new
    client.define_singleton_method(:puts) { |line| replies << JSON.parse(line) }

    agent.send(:handle_command, {"work_item_ref" => "WC-1", "body" => "do it"})
    agent.send(:handle_inject, {"work_item_ref" => "WC-1", "body" => "steer me"}, client)
    expect(replies.last).to include("ok" => true)
    pollers.last.on_complete.call("stage one done")

    expect(agent).to have_received(:report).with(anything, hash_including("message" => /steer/)),
      "the steer's failure went only to the daemon's stderr: #{error_output.string.inspect}"
  end
end
