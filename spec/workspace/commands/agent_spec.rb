require "spec_helper"
require "tmpdir"

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
  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_socket_path).with("myapp").and_return(agent_socket_path)
      allow(c).to receive(:work_coordinator_socket).and_return(wc_socket_path)
      allow(c).to receive(:work_coordinator_status_socket).and_return(wc_status_socket_path)
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

  subject(:agent) do
    described_class.new(
      config: config,
      tmux: CLITestHelpers::FakeTmux.new,
      work_coordinator_client: client,
      epoch_generator: -> { "wa-TESTEPOCH" },
      signal_trapper: signal_trapper,
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
