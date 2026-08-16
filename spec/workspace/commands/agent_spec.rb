require "spec_helper"
require "tmpdir"
require "delegate"

# Captures the completion callback instead of polling tmux on a thread, so
# specs can decide exactly when a stage finishes.
class FakeSentinelPoller
  attr_reader :session_name, :pane, :on_complete, :on_error

  def initialize(session_name:, pane:)
    @session_name = session_name
    @pane = pane
  end

  def start(on_error: nil, &block)
    @on_complete = block
    @on_error = on_error
    self
  end

  def stop
    @stopped = true
  end

  def stopped? = !!@stopped
end

# Wraps a real client and refuses the first N status reports, so specs can watch
# what the agent does when a report goes unanswered.
class FlakyStatusClient < SimpleDelegator
  attr_reader :status_attempts

  def initialize(inner, failures:)
    super(inner)
    @failures = failures
    @status_attempts = []
  end

  def report_status(payload)
    @status_attempts << payload
    raise Workspace::Error, "connection refused" if @status_attempts.size <= @failures
    __getobj__.report_status(payload)
  end
end

RSpec.describe Workspace::Commands::Agent do
  # Unix socket paths cap at 104 bytes on macOS, so stay under /tmp directly.
  let(:tmpdir) { Dir.mktmpdir("ws-agent", "/tmp") }
  let(:wc_socket_path) { File.join(tmpdir, "work-coordinator.sock") }
  let(:wc_status_socket_path) { File.join(tmpdir, "work-coordinator-status.sock") }
  let(:agent_socket_path) { File.join(tmpdir, "workspace-myapp.sock") }
  let(:output) { StringIO.new }
  let(:error_output) { StringIO.new }
  let(:coordinator) do
    FakeWorkCoordinator.new(socket_path: wc_socket_path, status_socket_path: wc_status_socket_path)
  end

  # Config stub that routes all socket paths into the spec's tmpdir.
  let(:project_config_path) { File.join(tmpdir, "myapp.yml") }
  let(:tmux) { CLITestHelpers::FakeTmux.new }

  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(agent_socket_path)
      allow(c).to receive(:work_coordinator_socket).and_return(wc_socket_path)
      allow(c).to receive(:work_coordinator_status_socket).and_return(wc_status_socket_path)
      allow(c).to receive(:project_config_path).with("myapp").and_return(project_config_path)
      allow(c).to receive(:handoff_dir).and_return(File.join(tmpdir, "handoffs"))
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
    ->(session_name:, pane:) { FakeSentinelPoller.new(session_name: session_name, pane: pane).tap { |p| pollers << p } }
  end

  subject(:agent) do
    described_class.new(
      config: config,
      tmux: tmux,
      work_coordinator_client: client,
      pipeline_config: pipeline_config,
      pipeline_state: pipeline_state,
      epoch_generator: -> { "wa-TESTEPOCH" },
      signal_trapper: signal_trapper,
      sentinel_poller_factory: sentinel_poller_factory,
      retry_backoff: 0,
      output: output,
      error_output: error_output
    )
  end

  after do
    coordinator.stop
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  # Runs the agent in a thread, waits for readiness, yields, then shuts it down.
  def run_agent
    thread = Thread.new { agent.call(name: "myapp") }
    wait_until { output.string.include?("ready") || !thread.alive? }
    yield thread
  ensure
    signal_trapper.handlers["TERM"]&.call
    thread&.join(2)
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    sleep(0.01) until yield || Time.now > deadline
  end

  describe "starting the agent for a workspace" do
    it "listens on its own socket, registers with the coordinator, and reports ready" do
      coordinator.start

      run_agent do
        expect(File.socket?(agent_socket_path)).to be true
        expect(output.string).to include("workspace agent 'myapp' ready")

        registration = coordinator.last_registration
        expect(registration).to include(
          "type" => "register",
          "name" => "myapp",
          "socket" => agent_socket_path,
          "pipeline" => true,
          "epoch" => "wa-TESTEPOCH",
          "in_flight" => []
        )
      end
    end

    it "deregisters and removes its socket on shutdown" do
      coordinator.start

      run_agent { |thread| thread }

      wait_until { coordinator.deregistrations.any? }
      expect(coordinator.deregistrations.last).to eq("type" => "deregister", "name" => "myapp")
      expect(File.exist?(agent_socket_path)).to be false
    end

    it "reports clearly when the coordinator cannot be reached" do
      expect(agent.call(name: "myapp")).to be false
      expect(error_output.string).to include("Could not reach work-coordinator")
      expect(File.exist?(agent_socket_path)).to be false
    end

    it "reports clearly when the coordinator refuses the registration" do
      coordinator.reply = {"ok" => false, "error" => "already_registered"}
      coordinator.start

      expect(agent.call(name: "myapp")).to be false
      expect(error_output.string).to include("already_registered")
      expect(File.exist?(agent_socket_path)).to be false
    end
  end

  describe "receiving a command from the coordinator" do
    def send_command(overrides = {})
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    before { coordinator.start }

    it "starts the pipeline at the first stage when the workspace has one" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML

      run_agent do
        send_command
        wait_until { tmux.sent_keys.any? }

        expect(tmux.sent_keys.last).to include(
          session: "myapp", pane: 0, text: "/build add OAuth support"
        )
        expect(pipeline_state.current("WC-42")).to include(
          dispatch_id: "d-7a1", pane_index: 0, phase: "researcher"
        )
      end
    end

    it "delivers to the default pane when the workspace has no pipeline" do
      run_agent do
        send_command
        wait_until { tmux.sent_keys.any? }

        expect(tmux.sent_keys.last).to include(session: "myapp", pane: 0)
        expect(pipeline_state.in_flight_refs).to be_empty
      end
    end

    it "ignores a command addressed to another workspace and keeps serving its own" do
      run_agent do
        send_command("workspace" => "api", "work_item_ref" => "WC-50")
        send_command

        wait_until { tmux.sent_keys.any? }
        sleep 0.05

        expect(tmux.sent_keys.size).to eq(1)
        expect(tmux.sent_keys.last).to include(text: "/build add OAuth support")
        expect(pipeline_state.current("WC-50")).to be_nil
      end
    end

    it "drops unreadable input and keeps accepting later commands" do
      run_agent do
        UNIXSocket.open(agent_socket_path) { |s| s.puts("garbage") }
        send_command

        wait_until { tmux.sent_keys.any? }
        expect(tmux.sent_keys.last).to include(text: "/build add OAuth support")
      end
    end

    it "handles a command that the coordinator retried after the agent came up" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML

      run_agent do
        sleep 0.05
        send_command

        wait_until { tmux.sent_keys.any? }
        expect(tmux.sent_keys.last).to include(pane: 0, text: "/build add OAuth support")
        expect(pipeline_state.current("WC-42")).to include(pane_index: 0, phase: "researcher")
      end
    end
  end

  describe "running the pipeline" do
    def send_command(overrides = {})
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    before do
      coordinator.start
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
            - role: reviewer
          handoff: file_handoff
      YAML
    end

    it "hands the finished stage's output to the next stage and reports the advance" do
      tmux.captured_output = "research notes\nWORKSPACE_DONE: Initial research complete\n"

      run_agent do
        send_command
        wait_until { pollers.any? }
        expect(pollers.first.pane).to eq(0)

        pollers.first.on_complete.call("Initial research complete")

        handoff = File.join(tmpdir, "handoffs", "myapp-WC-42-handoff.txt")
        expect(File.read(handoff)).to include("research notes")
        expect(tmux.sent_keys.last).to include(session: "myapp", pane: 1)
        expect(tmux.sent_keys.last[:text]).to include(handoff)
        expect(tmux.sent_keys.last[:text]).to include("WORKSPACE_DONE:")
        expect(pollers.first).to be_stopped
        expect(pipeline_state.current("WC-42")).to include(pane_index: 1, phase: "implementer")
        expect(pollers.last.pane).to eq(1)

        wait_until { coordinator.status_messages.size >= 3 }
        expect(coordinator.status_messages[1]).to include(
          "type" => "phase_change", "message_id" => "m-2", "sequence" => 2,
          "workspace" => "myapp", "work_item_ref" => "WC-42", "phase" => "implementer"
        )
        expect(coordinator.status_messages[2]).to include(
          "type" => "pipeline_advanced", "message_id" => "m-3", "sequence" => 3,
          "from_pane" => 0, "to_pane" => 1
        )
      end
    end

    it "keeps advancing when the coordinator has gone away" do
      tmux.captured_output = "research notes\n"

      run_agent do
        send_command
        wait_until { pollers.any? }
        coordinator.stop

        pollers.first.on_complete.call("Initial research complete")

        expect(pipeline_state.current("WC-42")).to include(pane_index: 1, phase: "implementer")
        expect(tmux.sent_keys.last).to include(pane: 1)
        expect(pollers.last.pane).to eq(1)
      end
    end

    it "reports the work item complete when the final stage finishes" do
      tmux.captured_output = "review log\n"

      run_agent do
        send_command
        wait_until { pollers.any? }

        pollers.last.on_complete.call("research done")
        pollers.last.on_complete.call("implementation done")
        wait_until { coordinator.status_messages.size >= 5 }

        expect(pipeline_state.current("WC-42")).to include(pane_index: 2, phase: "reviewer")

        pollers.last.on_complete.call("PR #123 opened and all checks passed")

        wait_until { coordinator.status_messages.size >= 6 }
        expect(coordinator.status_messages.last).to include(
          "type" => "task_complete", "message_id" => "m-6", "sequence" => 6,
          "workspace" => "myapp", "work_item_ref" => "WC-42",
          "summary" => "PR #123 opened and all checks passed"
        )
        expect(pipeline_state.current("WC-42")).to be_nil
        expect(pollers.last).to be_stopped
      end
    end

    it "takes a work item out of the pipeline when its stage fails" do
      run_agent do
        send_command
        wait_until { pollers.any? }

        pollers.first.on_error.call("Claude pane exited unexpectedly")

        wait_until { coordinator.status_messages.any? { |m| m["type"] == "error" } }
        expect(coordinator.status_messages.last).to include(
          "type" => "error", "workspace" => "myapp", "work_item_ref" => "WC-42",
          "message" => "Claude pane exited unexpectedly"
        )
        expect(error_output.string).to include("WC-42 failed at pane 0: Claude pane exited unexpectedly")
        expect(pipeline_state.in_flight_refs).not_to include("WC-42")
        expect(pollers.first).to be_stopped
        expect(pollers.size).to eq(1)
      end
    end

    it "advances one work item without disturbing another in the same workspace" do
      run_agent do
        send_command
        wait_until { pollers.size == 1 }
        send_command("work_item_ref" => "WC-43", "dispatch_id" => "d-7a2")
        wait_until { pollers.size == 2 }

        pollers.first.on_complete.call("research done")

        expect(pipeline_state.current("WC-42")).to include(pane_index: 1, phase: "implementer")
        expect(pipeline_state.current("WC-43")).to include(pane_index: 0, phase: "researcher")
      end
    end
  end

  describe "reporting status" do
    def send_command(overrides = {})
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    before { coordinator.start }

    def write_pipeline_config
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML
    end

    it "reports that work has started" do
      write_pipeline_config

      run_agent do
        send_command
        wait_until { coordinator.status_messages.any? }

        expect(coordinator.status_messages.first).to include(
          "type" => "status_update", "message_id" => "m-1", "sequence" => 1,
          "workspace" => "myapp", "work_item_ref" => "WC-42",
          "message" => "Pipeline started at stage researcher (pane 0)"
        )
      end
    end

    it "reports that a command reached a workspace with no pipeline" do
      run_agent do
        send_command
        wait_until { coordinator.status_messages.any? }

        expect(coordinator.status_messages.first).to include(
          "type" => "status_update", "workspace" => "myapp", "work_item_ref" => "WC-42",
          "message" => "Command delivered to default pane"
        )
      end
    end

    it "reports notable progress mid-stage without touching the pane" do
      write_pipeline_config

      run_agent do
        send_command
        wait_until { pipeline_state.current("WC-42") }
        sent_before = tmux.sent_keys.size

        agent.report_progress("WC-42", "Running tests in pane 1")

        wait_until { coordinator.status_messages.size >= 2 }
        expect(coordinator.status_messages.last).to include(
          "type" => "status_update", "work_item_ref" => "WC-42",
          "message" => "Running tests in pane 1"
        )
        expect(tmux.sent_keys.size).to eq(sent_before)
        expect(pipeline_state.current("WC-42")).to include(pane_index: 0)
      end
    end

    it "ignores a progress report for a work item it is not tracking" do
      run_agent do
        agent.report_progress("WC-999", "nobody is listening")
        sleep 0.05
        expect(coordinator.status_messages).to be_empty
      end
    end
  end

  describe "reporting status the coordinator does not accept" do
    def send_command(overrides = {})
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    def write_pipeline_config
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML
    end

    context "when the first attempt goes unanswered" do
      let(:client) do
        FlakyStatusClient.new(
          Workspace::WorkCoordinatorClient.new(
            socket_path: wc_socket_path, status_socket_path: wc_status_socket_path
          ),
          failures: 1
        )
      end

      it "retries it as the same report rather than treating silence as success" do
        coordinator.start
        write_pipeline_config

        run_agent do
          send_command
          wait_until { coordinator.status_messages.any? }

          expect(client.status_attempts.size).to eq(2)
          expect(client.status_attempts[0]).to eq(client.status_attempts[1])
          expect(coordinator.status_messages.size).to eq(1)
          expect(coordinator.status_messages.first).to include("message_id" => "m-1", "sequence" => 1)
          expect(pipeline_state.current("WC-42")).to include(pane_index: 0)
        end
      end
    end

    it "gives up on a report the coordinator has no work item for" do
      coordinator.start
      write_pipeline_config

      run_agent do
        coordinator.reply = {"ok" => false, "error" => "unknown_work_item", "action" => "give_up"}
        send_command
        wait_until { pipeline_state.current("WC-42").nil? && coordinator.status_messages.any? }

        expect(coordinator.status_messages.size).to eq(1)
        expect(pipeline_state.current("WC-42")).to be_nil
      end
    end

    it "keeps reporting for other work items after one is given up on" do
      coordinator.start
      write_pipeline_config

      run_agent do
        coordinator.reply = {"ok" => false, "error" => "unknown_work_item", "action" => "give_up"}
        send_command
        wait_until { coordinator.status_messages.any? }
        coordinator.reply = {"ok" => true, "epoch" => "test-wc-epoch"}

        send_command("work_item_ref" => "WC-43", "dispatch_id" => "d-7a2")
        wait_until { coordinator.status_messages.size >= 2 }

        expect(coordinator.status_messages.last).to include("work_item_ref" => "WC-43")
        expect(pipeline_state.current("WC-43")).to include(pane_index: 0)
      end
    end

    it "aborts the pipeline when the coordinator says the work item is already finished" do
      coordinator.start
      write_pipeline_config

      run_agent do
        send_command
        wait_until { pollers.any? }
        coordinator.reply = {"ok" => false, "error" => "terminal_state", "action" => "abort_pipeline"}

        agent.report_progress("WC-42", "still working")
        wait_until { pipeline_state.current("WC-42").nil? }

        expect(pipeline_state.current("WC-42")).to be_nil
        expect(pollers.first).to be_stopped
        expect(error_output.string).to include("work-coordinator aborted the pipeline")
      end
    end

    it "keeps the pipeline running and replays reports after the coordinator comes back" do
      coordinator.start
      write_pipeline_config

      run_agent do
        send_command
        wait_until { pollers.any? }
        coordinator.stop

        agent.report_progress("WC-42", "buffered while the coordinator was down")

        expect(pipeline_state.current("WC-42")).to include(pane_index: 0)
        expect(pollers.first).not_to be_stopped

        restarted = FakeWorkCoordinator.new(
          socket_path: wc_socket_path,
          status_socket_path: wc_status_socket_path,
          reply: {"ok" => true, "epoch" => "test-wc-epoch-2"}
        )
        restarted.start
        begin
          agent.report_progress("WC-42", "after the coordinator came back")
          wait_until { restarted.status_messages.size >= 2 && restarted.registrations.any? }

          expect(restarted.status_messages.map { |m| m["message"] }).to eq([
            "after the coordinator came back",
            "buffered while the coordinator was down"
          ])
          expect(restarted.registrations.last).to include("name" => "myapp")
          expect(restarted.registrations.last["in_flight"]).to include(
            hash_including("work_item_ref" => "WC-42")
          )
        ensure
          restarted.stop
        end
      end
    end
  end

  describe "steering work in mid-pipeline" do
    def send_command(overrides = {})
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    def send_inject(overrides = {})
      message = {
        "type" => "inject",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "use Postgres not SQLite",
        "interrupt" => false
      }.merge(overrides)
      UNIXSocket.open(agent_socket_path) do |s|
        s.puts(message.to_json)
        JSON.parse(s.gets)
      end
    end

    before do
      coordinator.start
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML
    end

    it "holds a steer for the next stage without disturbing the running one" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        sent_before = tmux.sent_keys.size

        expect(send_inject).to eq("ok" => true, "queued_for_pane" => 1)
        expect(tmux.sent_keys.size).to eq(sent_before)

        pollers.first.on_complete.call("research done")

        expect(tmux.sent_keys.last).to include(pane: 1, text: "use Postgres not SQLite")
      end
    end

    it "interrupts the running stage for an urgent steer" do
      run_agent do
        send_command
        wait_until { pollers.any? }

        expect(send_inject("interrupt" => true)).to eq("ok" => true, "queued_for_pane" => 0)

        expect(tmux.sent_key_names.last).to include(session: "myapp", pane: 0, key: "C-c")
        expect(tmux.sent_keys.last).to include(pane: 0, text: "use Postgres not SQLite")
      end
    end

    it "refuses a steer for a work item that is not running" do
      run_agent do
        send_command("work_item_ref" => "WC-43", "dispatch_id" => "d-7a2")
        wait_until { pollers.any? }
        sent_before = tmux.sent_keys.size

        expect(send_inject).to eq("ok" => false, "error" => "no_active_pipeline")
        expect(tmux.sent_keys.size).to eq(sent_before)
      end
    end

    it "refuses a queued steer when there is no stage left to give it to" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        pollers.first.on_complete.call("research done")
        wait_until { pipeline_state.current("WC-42")&.[](:pane_index) == 1 }
        sent_before = tmux.sent_keys.size

        expect(send_inject).to eq("ok" => false, "error" => "no_next_stage")
        expect(tmux.sent_keys.size).to eq(sent_before)
      end
    end

    it "answers every inbound message so a caller never reads a bare EOF" do
      run_agent do
        expect(send_inject("workspace" => "api")).to eq("ok" => false, "error" => "wrong_workspace")
        expect(send_inject("type" => "nonsense")).to eq("ok" => false, "error" => "unknown_type")

        reply = UNIXSocket.open(agent_socket_path) do |s|
          s.puts("garbage")
          JSON.parse(s.gets)
        end
        expect(reply).to eq("ok" => false, "error" => "malformed_message")
      end
    end

    it "refuses a steer for a work item it has never seen" do
      run_agent do
        expect(send_inject("work_item_ref" => "WC-999")).to eq("ok" => false, "error" => "no_active_pipeline")
        expect(tmux.sent_keys).to be_empty
        expect(tmux.sent_key_names).to be_empty
      end
    end
  end

  describe "starting a second agent for the same workspace" do
    it "refuses to start and leaves the running agent untouched" do
      coordinator.start
      running = UNIXServer.new(agent_socket_path)
      accepter = Thread.new do
        loop { running.accept.close }
      rescue IOError, Errno::EBADF
        nil
      end

      expect(agent.call(name: "myapp")).to be false
      expect(error_output.string).to include("workspace agent 'myapp' is already running")
      expect(coordinator.registrations).to be_empty
      expect(File.socket?(agent_socket_path)).to be true

      running.close
      accepter.kill
    end
  end

  describe "starting after an unclean shutdown" do
    it "removes the stale socket and starts normally" do
      coordinator.start
      stale = UNIXServer.new(agent_socket_path)
      stale.close
      expect(File.socket?(agent_socket_path)).to be true

      run_agent do
        expect(output.string).to include("workspace agent 'myapp' ready")
        expect(coordinator.registrations.size).to eq(1)
      end
    end
  end
end
