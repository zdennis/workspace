require "spec_helper"
require "tmpdir"
require "delegate"

# Captures the completion callback instead of polling tmux on a thread, so
# specs can decide exactly when a stage finishes.
class FakeSentinelPoller
  attr_reader :session_name, :pane, :token, :deadline, :on_complete, :on_error, :on_timeout

  def initialize(session_name:, pane:, token: nil, deadline: nil)
    @session_name = session_name
    @pane = pane
    @token = token
    @deadline = deadline
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
      token_generator: token_generator,
      clock: -> { now },
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
          "pipeline" => false,
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

    it "starts and keeps serving when the coordinator cannot be reached" do
      run_agent do
        expect(error_output.string).to include("Could not reach work-coordinator")
        expect(error_output.string).to include("work-coordinator unavailable; will keep retrying in the background")
        expect(File.socket?(agent_socket_path)).to be true
      end
    end

    it "starts and keeps serving when the coordinator refuses the registration" do
      coordinator.reply = {"ok" => false, "error" => "already_registered"}
      coordinator.start

      run_agent do
        expect(error_output.string).to include("already_registered")
        expect(File.socket?(agent_socket_path)).to be true
      end
    end

    context "when the workspace has a pipeline configured" do
      before do
        File.write(project_config_path, <<~YAML)
          pipeline:
            panes:
              - role: researcher
              - role: implementer
            handoff: file_handoff
        YAML
      end

      it "registers with pipeline: true" do
        coordinator.start

        run_agent do
          expect(coordinator.last_registration).to include("pipeline" => true)
        end
      end
    end

    context "when the workspace has no pipeline configured" do
      it "registers with pipeline: false" do
        coordinator.start

        run_agent do
          expect(coordinator.last_registration).to include("pipeline" => false)
        end
      end
    end
  end

  describe "a worktree workspace whose tmux session differs from its config name" do
    before do
      allow(tmux).to receive(:session_name_for).with("myapp").and_return("workspace-wt-myapp")
    end

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

    it "delivers a plain command to the tmux session, not the config name" do
      run_agent do
        send_command
        wait_until { tmux.sent_keys.any? }

        expect(tmux.sent_keys.last).to include(session: "workspace-wt-myapp")
      end
    end

    it "delivers the first pipeline stage to the tmux session" do
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

        expect(tmux.sent_keys.last).to include(session: "workspace-wt-myapp", pane: "0.0")
      end
    end

    it "arms the sentinel poller against the tmux session" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML

      run_agent do
        send_command
        wait_until { pollers.any? }

        expect(pollers.last.session_name).to eq("workspace-wt-myapp")
      end
    end

    it "checks pane liveness against the tmux session when recovering in-flight work" do
      pipeline_state.start(work_item_ref: "WC-1", workspace_name: "myapp",
        dispatch_id: "d-1", sentinel_token: "tok-old", deadline: nil)
      expect(tmux).to receive(:panes).with("workspace-wt-myapp").and_return([0, 1]).at_least(:once)

      run_agent { |thread| thread }
    end

    it "interrupts an urgent steer against the tmux session, not the config name" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML

      run_agent do
        send_command
        wait_until { pollers.any? }

        reply = UNIXSocket.open(agent_socket_path) do |s|
          s.puts({
            "type" => "inject",
            "workspace" => "myapp",
            "work_item_ref" => "WC-42",
            "dispatch_id" => "d-7a1",
            "body" => "use Postgres not SQLite",
            "interrupt" => true
          }.to_json)
          JSON.parse(s.gets)
        end

        expect(reply).to eq("ok" => true, "queued_for_pane" => 0)
        expect(tmux.sent_key_names.last).to include(session: "workspace-wt-myapp", pane: "0.0", key: "C-c")
        expect(tmux.sent_keys.last).to include(session: "workspace-wt-myapp", pane: "0.0", text: "use Postgres not SQLite")
      end
    end

    it "builds the session monitor against the tmux session, keeping the workspace name for alerts" do
      alert_config = instance_double(Workspace::AlertConfig)
      allow(alert_config).to receive(:for_workspace).with("myapp").and_return({})
      agent_for_worktree = described_class.new(
        config: config,
        tmux: tmux,
        work_coordinator_client: client,
        pipeline_config: pipeline_config,
        pipeline_state: pipeline_state,
        alert_config: alert_config,
        output: output,
        error_output: error_output
      )

      monitor = agent_for_worktree.send(:build_session_monitor, "myapp")

      expect(monitor.instance_variable_get(:@session_name)).to eq("workspace-wt-myapp")
      expect(alert_config).to have_received(:for_workspace).with("myapp")
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

        expect(tmux.sent_keys.last).to include(session: "myapp", pane: "0.0")
        expect(tmux.sent_keys.last[:text]).to start_with("/build add OAuth support\n\n")
        expect(pipeline_state.current("WC-42")).to include(
          dispatch_id: "d-7a1", pane_index: 0, phase: "researcher", sentinel_token: "tok-1"
        )
      end
    end

    it "tells the first stage how to signal it is done, with a token only it carries" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
      YAML

      run_agent do
        send_command
        wait_until { pollers.any? }

        expect(tmux.sent_keys.last[:text]).to eq(
          "/build add OAuth support\n\nWhen you are done, print a single line: WORKSPACE_DONE:tok-1 <one-line summary>"
        )
        expect(pollers.first.token).to eq("tok-1")
      end
    end

    it "does not add a completion instruction when there is no pipeline to watch it" do
      run_agent do
        send_command
        wait_until { tmux.sent_keys.any? }

        expect(tmux.sent_keys.last[:text]).not_to include("WORKSPACE_DONE")
      end
    end

    it "delivers to the default pane when the workspace has no pipeline" do
      run_agent do
        send_command
        wait_until { tmux.sent_keys.any? }

        expect(tmux.sent_keys.last).to include(session: "myapp", pane: "0.1")
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

    describe "reporting_instructions appended to the body" do
      it "omits the section when the field is absent (default pane)" do
        run_agent do
          send_command("body" => "do the thing")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(pane: "0.1", text: "do the thing")
        end
      end

      it "omits the section when the field is absent (pipeline pane)" do
        File.write(project_config_path, <<~YAML)
          pipeline:
            panes:
              - role: researcher
            handoff: file_handoff
        YAML

        run_agent do
          send_command("body" => "do the thing")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(pane: "0.0")
          expect(tmux.sent_keys.last[:text]).to start_with("do the thing\n\nWhen you are done")
          expect(tmux.sent_keys.last[:text]).not_to include("Status reporting")
        end
      end

      it "omits the section when reporting_instructions is nil" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => nil)
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(text: "do the thing")
        end
      end

      it "omits the section and does not raise when reporting_instructions is a non-String (e.g. 42)" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => 42)
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(text: "do the thing")
        end
      end

      it "omits the section when reporting_instructions is an empty string" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => "")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(text: "do the thing")
        end
      end

      it "omits the section when reporting_instructions is whitespace-only" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => "   \n  ")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(text: "do the thing")
        end
      end

      it "appends the section to the body (default pane) when reporting_instructions is a valid string" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => "run report --ref WC-1")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(
            pane: "0.1",
            text: "do the thing\n\nStatus reporting:\nrun report --ref WC-1"
          )
        end
      end

      it "appends the section to the body (pipeline pane) when reporting_instructions is a valid string" do
        File.write(project_config_path, <<~YAML)
          pipeline:
            panes:
              - role: researcher
            handoff: file_handoff
        YAML

        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => "run report --ref WC-1")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(pane: "0.0")
          expect(tmux.sent_keys.last[:text]).to start_with("do the thing\n\nStatus reporting:\nrun report --ref WC-1\n\n")
        end
      end

      it "strips surrounding whitespace from reporting_instructions before appending" do
        run_agent do
          send_command("body" => "do the thing", "reporting_instructions" => "  run report  \n")
          wait_until { tmux.sent_keys.any? }
          expect(tmux.sent_keys.last).to include(
            text: "do the thing\n\nStatus reporting:\nrun report"
          )
        end
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
        expect(tmux.sent_keys.last).to include(pane: "0.0")
        expect(tmux.sent_keys.last[:text]).to start_with("/build add OAuth support")
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
        expect(tmux.sent_keys.last).to include(session: "myapp", pane: "0.1")
        expect(tmux.sent_keys.last[:text]).to include(handoff)
        expect(tmux.sent_keys.last[:text]).to include("print a single line: WORKSPACE_DONE:tok-2 <one-line summary>")
        expect(pollers.last.token).to eq("tok-2")
        expect(pipeline_state.current("WC-42")).to include(sentinel_token: "tok-2")
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
        expect(tmux.sent_keys.last).to include(pane: "0.1")
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

    describe "with stage timeouts configured" do
      before do
        File.write(project_config_path, <<~YAML)
          pipeline:
            panes:
              - role: researcher
                timeout: 30m
              - role: implementer
              - role: reviewer
                timeout: 10m
        YAML
      end

      it "gives each stage the deadline its own config sets, and none where it sets none" do
        run_agent do
          send_command
          wait_until { pollers.any? }
          expect(pollers.first.deadline).to eq(now + 1800)
          expect(pipeline_state.current("WC-42")).to include(deadline_at: "2026-09-27T12:30:00.000Z")

          pollers.first.on_complete.call("research done")
          expect(pollers.last.deadline).to be_nil
          expect(pipeline_state.current("WC-42")).to include(deadline_at: nil)

          pollers.last.on_complete.call("implementation done")
          expect(pollers.last.deadline).to eq(now + 600)
        end
      end

      it "fails the work item and says so when a stage runs past its deadline" do
        run_agent do
          send_command
          wait_until { pollers.any? }

          pollers.first.on_timeout.call

          wait_until { coordinator.status_messages.any? { |m| m["type"] == "error" } }
          expect(coordinator.status_messages.last).to include(
            "type" => "error", "work_item_ref" => "WC-42",
            "message" => "timed out after 30m (deadline 2026-09-27T12:30:00Z): no WORKSPACE_DONE:tok-1 line"
          )
          expect(error_output.string).to include("WC-42 failed at pane 0: timed out")
          expect(pipeline_state.current("WC-42")).to be_nil
          expect(pollers.first).to be_stopped
        end
      end

      it "ignores a timeout from a watch that has since been replaced" do
        run_agent do
          send_command
          wait_until { pollers.size == 1 }
          send_command("dispatch_id" => "d-7a2")
          wait_until { pollers.size == 2 }

          pollers.first.on_timeout.call

          expect(pipeline_state.current("WC-42")).to include(sentinel_token: "tok-2")
          expect(coordinator.status_messages.map { |m| m["type"] }).not_to include("error")
        end
      end
    end

    it "ignores a completion from a watch that has since been replaced" do
      run_agent do
        send_command
        wait_until { pollers.size == 1 }
        # The coordinator re-sends the same work item; the first watch is retired.
        send_command("dispatch_id" => "d-7a2")
        wait_until { pollers.size == 2 }

        pollers.first.on_complete.call("late news from the old dispatch")

        expect(pipeline_state.current("WC-42")).to include(pane_index: 0, sentinel_token: "tok-2")
        expect(pollers.size).to eq(2)
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
          "message" => "Command delivered to myapp:0.1"
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

  describe "coordinator_restart notification" do
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

    it "buffers the next report immediately without hitting the coordinator" do
      coordinator.start
      write_pipeline_config

      run_agent do
        send_command
        wait_until { pollers.any? }

        UNIXSocket.open(agent_socket_path) do |s|
          s.puts({"type" => "coordinator_restart", "dispatch_id" => "d-test-1"}.to_json)
        end
        sleep 0.05

        coordinator.status_messages.clear
        agent.report_progress("WC-42", "after coordinator_restart")
        sleep 0.05

        expect(agent.instance_variable_get(:@pending_reports)).not_to be_empty
        expect(coordinator.status_messages).to be_empty
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

        expect(tmux.sent_keys.last).to include(pane: "0.1", text: "use Postgres not SQLite")
      end
    end

    it "interrupts the running stage for an urgent steer" do
      run_agent do
        send_command
        wait_until { pollers.any? }

        expect(send_inject("interrupt" => true)).to eq("ok" => true, "queued_for_pane" => 0)

        expect(tmux.sent_key_names.last).to include(session: "myapp", pane: "0.0", key: "C-c")
        expect(tmux.sent_keys.last).to include(pane: "0.0", text: "use Postgres not SQLite")
      end
    end

    it "refuses a steer aimed at a stage that has already finished" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        old_token = pipeline_state.current("WC-42")[:sentinel_token]
        pollers.first.on_complete.call("research done")
        wait_until { pipeline_state.current("WC-42")&.[](:pane_index) == 1 }
        sent_before = tmux.sent_keys.size

        expect(send_inject("interrupt" => true, "expected_token" => old_token))
          .to eq("ok" => false, "error" => "stale_token")
        expect(tmux.sent_keys.size).to eq(sent_before)
      end
    end

    it "accepts a steer naming the running stage's token" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        token = pipeline_state.current("WC-42")[:sentinel_token]

        expect(send_inject("interrupt" => true, "expected_token" => token))
          .to eq("ok" => true, "queued_for_pane" => 0)
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

  describe "surviving a restart" do
    let(:state_path) { File.join(tmpdir, "pipeline.json") }
    let(:pipeline_state) do
      Workspace::PipelineState.new(pipeline_config: pipeline_config, state_path: state_path)
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

    # What the previous agent process would have left on disk mid-stage.
    def write_persisted_state(pane_index: 1, **extra)
      File.write(state_path, JSON.pretty_generate(
        "WC-42" => {
          work_item_ref: "WC-42", workspace_name: "myapp",
          dispatch_id: "d-7a1", pane_index: pane_index, phase: "implementer"
        }.merge(extra)
      ))
    end

    it "re-arms the watch with the stage's persisted token so a sentinel printed while it was down still counts" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1, sentinel_token: "persisted-tok")
      tmux.pane_indexes = [0, 1]

      run_agent do
        expect(pollers.map(&:token)).to eq(["persisted-tok"])
      end
    end

    it "keeps the stage's persisted deadline rather than starting a new one" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1, sentinel_token: "persisted-tok", deadline_at: "2026-09-27T11:00:00.000Z")
      tmux.pane_indexes = [0, 1]

      run_agent do
        expect(pollers.first.deadline).to eq(Time.utc(2026, 9, 27, 11, 0, 0))
      end
    end

    it "watches for a tokenless sentinel when the state predates tokens" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1)
      tmux.pane_indexes = [0, 1]

      run_agent do
        expect(pollers.map(&:token)).to eq([nil])
        expect(pollers.first.deadline).to be_nil
        expect(pollers.first.pane).to eq(1)
      end
    end

    it "re-registers with its in-flight work when the coordinator restarted under it" do
      coordinator.start
      write_pipeline_config

      run_agent do
        send_command = {
          "type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42",
          "dispatch_id" => "d-7a1", "body" => "/build add OAuth support"
        }
        UNIXSocket.open(agent_socket_path) { |s| s.puts(send_command.to_json) }
        wait_until { pollers.any? }

        # The coordinator answering with an epoch we have not seen is the agent's
        # only signal that it is talking to a different process than it registered with.
        coordinator.reply = {"ok" => true, "epoch" => "wc-epoch-2"}
        agent.report_progress("WC-42", "still working")

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.last).to include("type" => "register", "name" => "myapp")
        expect(coordinator.registrations.last["in_flight"]).to include(
          hash_including("work_item_ref" => "WC-42", "dispatch_id" => "d-7a1")
        )
        expect(pollers.first).not_to be_stopped
        expect(pipeline_state.current("WC-42")).to include(pane_index: 0)
      end
    end

    it "re-registers with pipeline: true when the workspace has a pipeline" do
      coordinator.start
      write_pipeline_config

      run_agent do
        coordinator.reply = {"ok" => true, "epoch" => "wc-epoch-2"}
        agent.report_progress("WC-42", "still working")

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.last).to include("pipeline" => true)
      end
    end

    it "re-registers with pipeline: false when the workspace has no pipeline" do
      coordinator.start
      # no pipeline config written

      run_agent do
        coordinator.reply = {"ok" => true, "epoch" => "wc-epoch-2"}
        agent.report_progress("WC-42", "still working")

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.last).to include("pipeline" => false)
      end
    end

    it "picks work back up from disk and re-attaches to the pane that survived" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1)
      tmux.pane_indexes = [0, 1, 2]

      run_agent do
        expect(coordinator.last_registration["in_flight"]).to include(
          hash_including("work_item_ref" => "WC-42", "dispatch_id" => "d-7a1", "phase" => "implementer")
        )
        expect(pollers.map(&:pane)).to eq([1])
        expect(pipeline_state.current("WC-42")).to include(pane_index: 1)
      end
    end

    it "names only the deadline when a recovered stage times out, since its budget is not persisted" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1, sentinel_token: "persisted-tok", deadline_at: "2026-09-27T12:30:00.000Z")
      tmux.pane_indexes = [0, 1]

      run_agent do
        wait_until { pollers.any? }
        pollers.first.on_timeout.call

        wait_until { coordinator.status_messages.any? { |m| m["type"] == "error" } }
        expect(coordinator.status_messages.last).to include(
          "message" => "timed out (deadline 2026-09-27T12:30:00Z): no WORKSPACE_DONE:persisted-tok line"
        )
      end
    end

    it "treats a work item as lost when tmux cannot say whether its pane is there" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1)
      allow(tmux).to receive(:panes).and_raise(Workspace::Error, "tmux server not running")

      run_agent do
        expect(coordinator.last_registration["in_flight"]).to be_empty
        expect(pipeline_state.in_flight_refs).not_to include("WC-42")
      end
    end

    it "drops work whose pane did not survive rather than pretending it is running" do
      coordinator.start
      write_pipeline_config
      write_persisted_state(pane_index: 1)
      tmux.pane_indexes = [0, 2]

      run_agent do
        expect(coordinator.last_registration["in_flight"]).to be_empty
        expect(pipeline_state.in_flight_refs).not_to include("WC-42")
        expect(pollers).to be_empty
        expect(error_output.string).to include("WC-42 lost its pane (1)")
        expect(JSON.parse(File.read(state_path))).to be_empty
      end
    end

    it "keeps its own state at the config's path when none is injected" do
      allow(config).to receive(:pipeline_state_path).with("myapp").and_return(state_path)
      coordinator.start
      write_pipeline_config

      unwired = described_class.new(
        config: config, tmux: tmux, work_coordinator_client: client,
        pipeline_config: pipeline_config,
        epoch_generator: -> { "wa-TESTEPOCH" },
        signal_trapper: signal_trapper,
        sentinel_poller_factory: sentinel_poller_factory,
        retry_backoff: 0, output: output, error_output: error_output
      )
      thread = Thread.new { unwired.call(name: "myapp") }
      wait_until { output.string.include?("ready") || !thread.alive? }

      begin
        UNIXSocket.open(agent_socket_path) do |s|
          s.puts({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42",
                  "dispatch_id" => "d-7a1", "body" => "go"}.to_json)
        end
        wait_until { File.exist?(state_path) }

        expect(JSON.parse(File.read(state_path))).to include(
          "WC-42" => hash_including("pane_index" => 0, "phase" => "researcher")
        )
      ensure
        signal_trapper.handlers["TERM"]&.call
        thread.join(2)
      end
    end
  end

  describe "losing its socket while it is running" do
    # macOS sweeps old /tmp entries and a second agent start unlinks the path,
    # so the file can vanish under a perfectly healthy listener.
    before { stub_const("#{described_class}::SOCKET_POLL_INTERVAL", 0.02) }

    it "rebinds the socket so callers can reach it again" do
      coordinator.start

      run_agent do
        File.unlink(agent_socket_path)
        wait_until { File.socket?(agent_socket_path) }

        expect(File.socket?(agent_socket_path)).to be true

        UNIXSocket.open(agent_socket_path) do |s|
          s.puts({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42",
                  "dispatch_id" => "d-7a1", "body" => "still listening"}.to_json)
        end
        wait_until { tmux.sent_keys.any? }
        expect(tmux.sent_keys.last).to include(text: "still listening")
      end
    end

    it "re-registers with the coordinator so it knows the new socket is live" do
      coordinator.start

      run_agent do
        wait_until { coordinator.registrations.size >= 1 }
        File.unlink(agent_socket_path)

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.last).to include("type" => "register", "name" => "myapp",
          "socket" => agent_socket_path)
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

  describe "starting with a stage timeout it cannot read" do
    it "refuses to start, naming the bad setting" do
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
              timeout: whenever
      YAML

      expect { agent.call(name: "myapp") }
        .to raise_error(Workspace::Error, /pipeline\.panes\[0\]\.timeout/)
      expect(File.exist?(agent_socket_path)).to be(false)
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

  describe "wiring the lock reaper into its session monitor" do
    # Goes through the real (private) session monitor factory rather than
    # stubbing it, so dropping the `lock_reaper:` kwarg at either end of the
    # wiring (here or in Workspace.build_cli) fails this test.
    it "passes its lock_reaper to the session monitor it builds" do
      lock_reaper = instance_double(Workspace::LockReaper, tick: 3)
      agent_with_reaper = described_class.new(
        config: config,
        tmux: tmux,
        work_coordinator_client: client,
        pipeline_config: pipeline_config,
        pipeline_state: pipeline_state,
        lock_reaper: lock_reaper,
        output: output,
        error_output: error_output
      )

      monitor = agent_with_reaper.send(:build_session_monitor, "myapp")

      expect(monitor.reap_locks).to eq(3)
      expect(lock_reaper).to have_received(:tick)
    end

    it "passes its ps_timeout to the session monitor's process tree" do
      agent_with_timeout = described_class.new(
        config: config,
        tmux: tmux,
        work_coordinator_client: client,
        pipeline_config: pipeline_config,
        pipeline_state: pipeline_state,
        ps_timeout: 42,
        output: output,
        error_output: error_output
      )

      monitor = agent_with_timeout.send(:build_session_monitor, "myapp")

      expect(monitor.instance_variable_get(:@process_tree).instance_variable_get(:@timeout)).to eq(42)
    end

    it "gives the session monitor a notifier and idle threshold from the workspace's alert config" do
      alert_config = instance_double(Workspace::AlertConfig)
      allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: "say hi", idle_after: 900)
      notifier = instance_double(Workspace::Notifier)
      commands = []
      agent_with_alerts = described_class.new(
        config: config,
        tmux: tmux,
        work_coordinator_client: client,
        pipeline_config: pipeline_config,
        pipeline_state: pipeline_state,
        alert_config: alert_config,
        notifier_factory: ->(command) {
          commands << command
          notifier
        },
        output: output,
        error_output: error_output
      )

      monitor = agent_with_alerts.send(:build_session_monitor, "myapp")

      expect(commands).to eq(["say hi"])
      expect(monitor.instance_variable_get(:@notifier)).to be(notifier)
      expect(monitor.instance_variable_get(:@idle_alert_after)).to eq(900)
    end

    it "builds no notifier when the workspace has no notify command" do
      alert_config = instance_double(Workspace::AlertConfig, for_workspace: {notify: nil, idle_after: 600})
      agent_without = described_class.new(
        config: config,
        tmux: tmux,
        work_coordinator_client: client,
        pipeline_config: pipeline_config,
        pipeline_state: pipeline_state,
        alert_config: alert_config,
        notifier_factory: ->(_command) { raise "should not be built" },
        output: output,
        error_output: error_output
      )

      monitor = agent_without.send(:build_session_monitor, "myapp")

      expect(monitor.send_alerts).to eq([])
    end
  end

  describe "when text can't be delivered to a pane" do
    def send_message(message)
      UNIXSocket.open(agent_socket_path) do |s|
        s.puts(message.to_json)
        JSON.parse(s.gets)
      end
    end

    def send_command
      send_message("type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1", "body" => "/build add OAuth support")
    end

    def send_urgent_steer
      send_message("type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-42",
        "dispatch_id" => "d-7a1", "body" => "use Postgres", "interrupt" => true)
    end

    def use_pipeline
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
      YAML
    end

    before { coordinator.start }

    it "answers not_delivered and reports an error when a command never reaches the pane" do
      tmux.delivery_status = :not_landed

      run_agent do
        expect(send_command).to include("ok" => false, "error" => "not_delivered")

        wait_until { coordinator.status_messages.any? { |m| m["type"] == "error" } }
        expect(coordinator.status_messages.last).to include("type" => "error", "work_item_ref" => "WC-42")
        expect(coordinator.status_messages.last["message"]).to include("was not delivered")
        expect(error_output.string).to include("command for WC-42 was not delivered")
      end
    end

    it "does not start a pipeline whose first stage never got the command" do
      use_pipeline
      tmux.delivery_status = :failed

      run_agent do
        expect(send_command).to include("ok" => false, "error" => "not_delivered")

        expect(pipeline_state.current("WC-42")).to be_nil
        expect(pollers).to be_empty
      end
    end

    it "starts the stage with a warning when the text landed but may not have been submitted" do
      use_pipeline
      tmux.delivery_status = :unsubmitted

      run_agent do
        expect(send_command).to eq("ok" => true)
        wait_until { pollers.any? }

        expect(pipeline_state.current("WC-42")).to include(pane_index: 0)
        wait_until { coordinator.status_messages.size >= 2 }
        expect(coordinator.status_messages.last["message"]).to start_with("Warning: fake unsubmitted")
      end
    end

    it "warns, rather than errors, when a queued steer lands but shows :unsubmitted (unconfirmed)" do
      use_pipeline

      run_agent do
        send_command
        wait_until { pollers.any? }

        send_message("type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-42",
          "dispatch_id" => "d-7a1", "body" => "use Postgres", "interrupt" => false)

        allow(tmux).to receive(:deliver) do |session, pane, text, enter: true|
          status = (text == "use Postgres") ? :unsubmitted : :submitted
          Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
        end

        pollers.first.on_complete.call("research done")

        wait_until { coordinator.status_messages.any? { |m| m["message"].to_s.include?("Warning: queued steer") } }
        warning = coordinator.status_messages.find { |m| m["message"].to_s.include?("Warning: queued steer") }
        expect(warning).to include("type" => "status_update")
        expect(warning["message"]).to include("Warning: queued steer for pane 1: fake unsubmitted")
        expect(error_output.string).to include("queued steer for WC-42 to pane 1: fake unsubmitted")
      end
    end

    it "warns, rather than errors, when a queued steer lands but shows :unverified (unconfirmed)" do
      use_pipeline

      run_agent do
        send_command
        wait_until { pollers.any? }

        send_message("type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-42",
          "dispatch_id" => "d-7a1", "body" => "use Postgres", "interrupt" => false)

        allow(tmux).to receive(:deliver) do |session, pane, text, enter: true|
          status = (text == "use Postgres") ? :unverified : :submitted
          Workspace::Tmux::Delivery.new(status: status, message: "fake #{status}")
        end

        pollers.first.on_complete.call("research done")

        wait_until { coordinator.status_messages.any? { |m| m["message"].to_s.include?("Warning: queued steer") } }
        warning = coordinator.status_messages.find { |m| m["message"].to_s.include?("Warning: queued steer") }
        expect(warning).to include("type" => "status_update")
        expect(warning["message"]).to include("Warning: queued steer for pane 1: fake unverified")
        expect(error_output.string).to include("queued steer for WC-42 to pane 1: fake unverified")
      end
    end

    it "fails the work item when the next stage never gets its hand-off" do
      use_pipeline

      run_agent do
        send_command
        wait_until { pollers.any? }
        tmux.delivery_status = :not_landed

        pollers.first.on_complete.call("research done")

        wait_until { coordinator.status_messages.any? { |m| m["type"] == "error" } }
        expect(coordinator.status_messages.last["message"]).to include("could not hand off to the implementer stage")
        expect(pipeline_state.current("WC-42")).to be_nil
      end
    end

    it "answers an urgent steer with not_delivered or not_submitted" do
      use_pipeline

      run_agent do
        send_command
        wait_until { pollers.any? }

        tmux.delivery_status = :not_landed
        expect(send_urgent_steer).to include("ok" => false, "error" => "not_delivered")

        tmux.delivery_status = :unsubmitted
        expect(send_urgent_steer).to include("ok" => false, "error" => "not_submitted")
      end
    end
  end
end
