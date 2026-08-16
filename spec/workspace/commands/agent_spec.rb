require "spec_helper"
require "tmpdir"

# Captures the completion callback instead of polling tmux on a thread, so
# specs can decide exactly when a stage finishes.
class FakeSentinelPoller
  attr_reader :session_name, :pane, :on_complete

  def initialize(session_name:, pane:)
    @session_name = session_name
    @pane = pane
  end

  def start(&block)
    @on_complete = block
    self
  end

  def stop
    @stopped = true
  end

  def stopped? = !!@stopped
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
    def send_command
      message = {
        "type" => "command",
        "workspace" => "myapp",
        "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1",
        "body" => "/build add OAuth support"
      }
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

        wait_until { coordinator.status_messages.size >= 2 }
        expect(coordinator.status_messages[0]).to include(
          "type" => "phase_change", "message_id" => "m-1", "sequence" => 1,
          "workspace" => "myapp", "work_item_ref" => "WC-42", "phase" => "implementer"
        )
        expect(coordinator.status_messages[1]).to include(
          "type" => "pipeline_advanced", "message_id" => "m-2", "sequence" => 2,
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
        wait_until { coordinator.status_messages.size >= 4 }

        expect(pipeline_state.current("WC-42")).to include(pane_index: 2, phase: "reviewer")

        pollers.last.on_complete.call("PR #123 opened and all checks passed")

        wait_until { coordinator.status_messages.size >= 5 }
        expect(coordinator.status_messages.last).to include(
          "type" => "task_complete", "message_id" => "m-5", "sequence" => 5,
          "workspace" => "myapp", "work_item_ref" => "WC-42",
          "summary" => "PR #123 opened and all checks passed"
        )
        expect(pipeline_state.current("WC-42")).to be_nil
        expect(pollers.last).to be_stopped
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
