require "spec_helper"
require "tmpdir"
require "delegate"

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
  include_context "an agent daemon over a fake coordinator"

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

    context "with a fast socket poll" do
      let(:socket_poll_interval) { 0.1 }

      it "warns once while the coordinator is down, then announces the later registration" do
        run_agent do
          wait_until { error_output.string.include?("could not re-register with work-coordinator") }
          coordinator.start
          wait_until { error_output.string.include?("workspace agent: re-registered with work-coordinator") }
        end

        expect(error_output.string.scan("could not re-register with work-coordinator").size).to eq(1)
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

    it "answers a request for its own workspace in another case" do
      run_agent do
        expect(send_inject("workspace" => "MyApp", "work_item_ref" => "WC-999")).to eq("ok" => false, "error" => "no_active_pipeline")
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
      write_persisted_state(pane_index: 1)
      tmux.pane_indexes = [0, 1]

      run_agent do
        coordinator.reply = {"ok" => true, "epoch" => "wc-epoch-2"}
        agent.report_progress("WC-42", "still working")

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.size).to eq(2)
        expect(coordinator.registrations.last).to include("pipeline" => true)
      end
    end

    it "re-registers with pipeline: false when the workspace has no pipeline" do
      coordinator.start
      # no pipeline config written
      write_persisted_state(pane_index: 1)
      tmux.pane_indexes = [0, 1]

      run_agent do
        coordinator.reply = {"ok" => true, "epoch" => "wc-epoch-2"}
        agent.report_progress("WC-42", "still working")

        wait_until { coordinator.registrations.size >= 2 }
        expect(coordinator.registrations.size).to eq(2)
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

      unwired = build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),

        config: config, tmux: tmux, work_coordinator_client: client,
        pipeline_config: pipeline_config,
        epoch_generator: -> { "wa-TESTEPOCH" },
        signal_trapper: signal_trapper,
        sentinel_poller_factory: sentinel_poller_factory,
        retry_backoff: 0, output: output, error_output: error_output)
      thread = Thread.new do
        unwired.call(name: "myapp")
      ensure
        output.announce
      end
      output.wait_ready

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
    let(:socket_poll_interval) { 0.02 }

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

  describe "starting for a mixed-case workspace" do
    let(:migrations) { [] }
    let(:migration_result) { Workspace::NameMigration::Result.new(name: "myapp", from: "MyApp", renamed: [], warnings: ["MyApp: lock not renamed (busy)"]) }
    let(:name_migration) do
      double("name_migration").tap do |migration|
        allow(migration).to receive(:call_locked) do |name, wait:|
          migrations << [name, wait]
          migration_result
        end
      end
    end
    let(:running) { UNIXServer.new(agent_socket_path) }
    let(:accepter) do
      Thread.new do
        loop { running.accept.close }
      rescue IOError, Errno::EBADF
        nil
      end
    end

    subject(:agent) do
      build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),
        config: config, tmux: tmux, work_coordinator_client: client, pipeline_config: pipeline_config,
        pipeline_state: pipeline_state, signal_trapper: signal_trapper, name_migration: name_migration, output: output, error_output: error_output)
    end

    # A daemon already answers for the lowercase name, so the agent stops right after the rename.
    before do
      running
      accepter
    end

    after do
      running.close
      accepter.kill
    end

    it "renames without waiting for the startup lock, logs it, and runs under the lowercase name" do
      expect(agent.call(name: "MyApp")).to be false

      expect(migrations).to eq([["MyApp", false]])
      expect(error_output.string).to include("workspace agent: renamed workspace 'MyApp' to 'myapp'",
        "Warning: MyApp: lock not renamed (busy)", "workspace agent 'myapp' is already running")
    end

    it "runs under the lowercase name when the lock is held elsewhere or a daemon answers" do
      allow(name_migration).to receive(:call_locked).and_return(nil)

      expect(agent.call(name: "MyApp")).to be false

      expect(error_output.string).to include("workspace agent 'myapp' is already running")
      expect(error_output.string).not_to include("renamed")
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

  describe "building its session monitor" do
    let(:alert_config) { instance_double(Workspace::AlertConfig, for_workspace: {}) }
    let(:agentd_config) { instance_double(Workspace::AgentdConfig, poll_interval_for: 3600) }
    let(:ticks) { Queue.new }
    let(:lock_reaper) do
      QueueTickingLockReaper.new(ticks)
    end

    it "starts the monitor it is given, built from alert, scan and lock reaper settings" do
      builder = Workspace::SessionMonitorBuilder.new(tmux: tmux, logger: Workspace::Logger.new, error_output: error_output,
        alert_config: alert_config, agentd_config: agentd_config, lock_reaper: lock_reaper, ps_timeout: 5,
        scan_slots: Workspace::ScanSlotLimiter.new(dir: File.join(tmpdir, "slots")))
      configured = build_agentd(
        config: config, tmux: tmux, work_coordinator_client: client, pipeline_config: pipeline_config,
        pipeline_state: pipeline_state, signal_trapper: signal_trapper, session_monitor_factory: builder,
        output: output, error_output: error_output
      )
      thread = Thread.new do
        configured.call(name: "myapp")
      ensure
        output.announce
      end
      output.wait_ready
      wait_until { !ticks.empty? }

      expect(alert_config).to have_received(:for_workspace).with("myapp")
      expect(agentd_config).to have_received(:poll_interval_for).with("myapp")
    ensure
      signal_trapper.handlers["TERM"]&.call
      thread&.join(2)
    end
  end

  describe "#handle, before the daemon has started" do
    let(:coordinator_client) { instance_double(Workspace::WorkCoordinatorClient, report_status: {"ok" => true}) }
    let(:served) do
      build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),
        config: config, tmux: tmux, work_coordinator_client: coordinator_client,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state, current_name: "myapp",
        token_generator: token_generator, clock: -> { now }, retry_backoff: 0,
        output: output, error_output: error_output)
    end
    let(:reply) { StringIO.new }

    def replied = JSON.parse(reply.string.lines.last)

    it "delivers a command message to the Claude pane and answers on the client" do
      served.handle({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-1",
                     "dispatch_id" => "d-1", "body" => "do it"}, reply)

      expect(replied).to include("ok" => true)
      expect(tmux.sent_keys.map { |k| [k[:session], k[:pane]] }).to eq([["myapp", "0.1"]])
      expect(tmux.sent_keys.first[:text]).to include("do it")
    end

    describe "reply bytes" do
      def bytes_for(message) = StringIO.new.tap { |io| served.handle(message, io) }.string

      it "writes each reply with its keys in the order the clients have always read" do
        expect(bytes_for({"type" => "nonsense", "workspace" => "myapp"})).to eq(%({"ok":false,"error":"unknown_type"}\n))
        expect(bytes_for({"type" => "command", "workspace" => "other"})).to eq(%({"ok":false,"error":"wrong_workspace"}\n))
        expect(bytes_for({"type" => "version", "workspace" => "myapp"})).to eq(%({"ok":true,"version":"#{Workspace::VERSION}"}\n))
        expect(bytes_for({"type" => "session_event", "workspace" => "myapp", "event" => "stop"})).to eq(%({"ok":true}\n))
        expect(bytes_for({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18"}))
          .to eq(%({"ok":false,"error":"missing_prompt","message":"restart_agent needs a non-empty \\"prompt\\""}\n))
        expect(bytes_for({"type" => "inject", "workspace" => "myapp", "work_item_ref" => "WC-9", "body" => "x"}))
          .to eq(%({"ok":false,"error":"no_active_pipeline"}\n))
      end
    end

    it "drops a message addressed to another workspace" do
      served.handle({"type" => "command", "workspace" => "other", "work_item_ref" => "WC-1", "body" => "do it"}, reply)

      expect(replied).to eq("ok" => false, "error" => "wrong_workspace")
      expect(tmux.sent_keys).to be_empty
    end

    it "refuses a restart_agent message with no prompt on the same path" do
      served.handle({"type" => "restart_agent", "workspace" => "myapp", "pane" => "%18"}, reply)

      expect(replied).to include("ok" => false, "error" => "missing_prompt")
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

  describe "recording activity in the event log" do
    let(:recorded) { [] }
    let(:event_log) do
      events = recorded
      BlockEventLog.new { |type:, project:, data:| events << {type: type, project: project, data: data} }
    end
    let(:quiet_monitor) do
      QuietSessionMonitor.new
    end

    subject(:agent) do
      build_agentd(
        config: config, tmux: tmux, work_coordinator_client: client,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state,
        epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
        sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
        clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { quiet_monitor },
        event_log: event_log, output: output, error_output: error_output
      )
    end

    def send_command
      message = {"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-42",
                 "dispatch_id" => "d-7a1", "body" => "/build add OAuth support"}
      UNIXSocket.open(agent_socket_path) { |s| s.puts(message.to_json) }
    end

    # The dispatch and stage events, without the daemon's own start and stop.
    def activity = recorded.reject { |event| event[:type].start_with?("daemon_") }

    def types = activity.map { |event| event[:type] }

    before do
      coordinator.start
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
              timeout: 30m
            - role: implementer
      YAML
    end

    it "records the dispatch and each stage completion under the workspace's name" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        pollers.first.on_complete.call("research done")
        wait_until { pollers.size == 2 }
        pollers.last.on_complete.call("all done")
        wait_until { types.count("stage_completed") == 2 }
      end

      expect(activity.map { |e| e[:project] }.uniq).to eq(["myapp"])
      expect(activity[0]).to include(type: "dispatched",
        data: include("work_item_ref" => "WC-42", "dispatch_id" => "d-7a1", "stage" => "researcher", "pane" => 0, "delivery" => "submitted"))
      expect(activity[1][:data]).to include("pane" => 0, "next_stage" => "implementer", "next_pane" => 1, "summary" => "research done")
      expect(activity[2][:data]).to include("pane" => 1, "next_stage" => nil, "summary" => "all done")
    end

    it "records a stage that runs past its deadline as stage_timed_out" do
      run_agent do
        send_command
        wait_until { pollers.any? }
        pollers.first.on_timeout.call
        wait_until { types.include?("stage_timed_out") }
      end

      event = activity.find { |e| e[:type] == "stage_timed_out" }
      expect(event[:data]).to include("work_item_ref" => "WC-42", "pane" => 0, "message" => a_string_starting_with("timed out after 30m"))
    end

    it "records a command that never reached its pane as dispatch_failed" do
      tmux.delivery_status = :not_delivered

      run_agent do
        send_command
        wait_until { types.include?("dispatch_failed") }
      end

      expect(types).to eq(["dispatch_failed"])
      expect(activity.first[:data]).to include("work_item_ref" => "WC-42", "message" => "fake not_delivered")
    end
  end

  describe "recording daemon_started and daemon_stopped" do
    let(:recorded) { [] }
    let(:event_log) do
      events = recorded
      BlockEventLog.new { |type:, project:, data:| events << {type: type, project: project, data: data} }
    end
    let(:quiet_monitor) do
      QuietSessionMonitor.new
    end

    subject(:agent) do
      build_agentd(
        config: config, tmux: tmux, work_coordinator_client: client,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state,
        epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
        sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
        clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { quiet_monitor },
        event_log: event_log, output: output, error_output: error_output
      )
    end

    before { coordinator.start }

    it "records the start once the agent is ready, and the stop once it has shut down, with its pid" do
      run_agent do
        expect(recorded.map { |e| e[:type] }).to eq(["daemon_started"])
        expect(recorded.first).to eq({type: "daemon_started", project: "myapp", data: {"workspace" => "myapp", "daemon" => "agent", "pid" => Process.pid}})
      end

      expect(recorded.map { |e| e[:type] }).to eq(%w[daemon_started daemon_stopped])
      expect(recorded.last[:data]).to eq("workspace" => "myapp", "daemon" => "agent", "pid" => Process.pid)
    end

    it "records no stop for an agent that refused to start" do
      running = UNIXServer.new(agent_socket_path)
      accepter = Thread.new do
        loop { running.accept.close }
      rescue IOError, Errno::EBADF
        nil
      end

      expect(agent.call(name: "myapp")).to be false

      expect(recorded).to be_empty
    ensure
      running&.close
      accepter&.kill
    end
  end

  describe "waking workflow runs" do
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

    it "tells the nudger when the main agent's turn ends in a pane, after the monitor has the event" do
      run_agent do
        expect(send_event("stop")).to eq("ok" => true)

        # This daemon did not see the turn begin, so it names no start: the end counts, as it always did.
        expect(nudger.turns).to eq([["myapp", "%5", nil, nil]])
        expect(recorded_events).to eq(["stop"])
      end
    end

    it "passes the Stop's background tasks to the nudger" do
      run_agent do
        send_event("stop", background_tasks: [{"id" => "b1a2c3d4e", "type" => "shell"}])

        expect(nudger.turns).to eq([["myapp", "%5", nil, [{"id" => "b1a2c3d4e", "type" => "shell"}]]])
      end
    end

    it "tells the nudger when the turn that ended began: the pane's last prompt, whatever other panes and sub-agents did" do
      run_agent do
        send_event("user_prompt")
        send_event("user_prompt", pane_id: "%6")
        send_event("user_prompt", agent_id: "sub-1")
        send_event("stop")
        send_event("stop")

        expect(nudger.turns).to eq([["myapp", "%5", now, nil], ["myapp", "%5", now, nil]])
      end
    end

    it "forgets when a turn began once the pane's session ends, or a new one starts (a /clear)" do
      run_agent do
        %w[session_end session_start].each do |event|
          send_event("user_prompt")
          send_event(event)
          send_event("stop")
        end

        expect(nudger.turns).to eq([["myapp", "%5", nil, nil]] * 2)
      end
    end

    it "does not wake the nudger for a turn that failed" do
      run_agent do
        send_event("user_prompt")
        send_event("turn_failed", error: "rate_limit")

        expect(nudger.turns).to eq([])
        expect(recorded_events).to eq(%w[user_prompt turn_failed])
      end
    end

    it "says nothing for a sub-agent's stop, or for any other event" do
      run_agent do
        send_event("stop", agent_id: "sub-1")
        send_event("subagent_stop")
        send_event("user_prompt")
        send_event("session_start")

        expect(nudger.turns).to eq([])
        expect(recorded_events.size).to eq(4)
      end
    end

    context "with an agent recovery desk" do
      let(:desk_events) { [] }
      let(:scans) { [] }
      let(:built) { [] }
      let(:queue_built) { [] }
      let(:monitor) do
        QuietSessionMonitor.new(events: recorded_events)
      end
      let(:recovery_desk) do
        events = desk_events
        scan_log = scans
        Class.new do
          attr_accessor :holds, :raises

          define_method(:session_event) { |message| events << message["event"] }
          define_method(:scan) do
            scan_log << :recovery
            raise "recovery broke" if raises
          end
          define_method(:holding?) { |_pane_id| holds }
        end.new
      end
      let(:queue_desk) do
        scan_log = scans
        raising = -> { @queue_raises }
        Class.new do
          define_method(:session_event) { |_message| }
          define_method(:scan) do
            scan_log << :queue
            raise "queue broke" if raising.call
          end
        end.new
      end
      let(:factory) { ->(**args) { built << args && recovery_desk } }

      subject(:agent) do
        build_agentd(
          config: config, restart_registry: restart_registry, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          workflow_nudger: nudger,
          prompt_queue_desk_factory: ->(**args) { queue_built << args && queue_desk },
          agent_recovery_desk_factory: factory, output: output, error_output: error_output
        )
      end

      it "hands the desk the workspace, the monitor and the claim calls" do
        run_agent do
          expect(built.first).to include(workspace: "myapp", session_monitor: monitor)
          expect(built.first[:delivery_lock]).to be_a(Mutex)
          expect(built.first[:rebind_queue]).to respond_to(:call)
        end
      end

      it "passes every hook event to the desk, and the queue desk's recovering check reads the desk's holding?" do
        run_agent do
          send_event("turn_failed", error: "rate_limit")
          recovery_desk.holds = true

          expect(desk_events).to eq(["turn_failed"])
          expect(queue_built.first[:recovering].call("%5")).to be(true)
          recovery_desk.holds = nil
          expect(queue_built.first[:recovering].call("%5")).to be(false)
        end
      end

      it "answers false to the recovering check with no desk" do
        queue = []
        no_desk = build_agentd(
          config: config, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          prompt_queue_desk_factory: ->(**args) { queue << args && queue_desk },
          agent_recovery_desk_factory: ->(**) {}, output: output, error_output: error_output
        )
        thread = Thread.new do
          no_desk.call(name: "myapp")
        ensure
          output.announce
        end
        output.wait_ready

        expect(queue.first[:recovering].call("%5")).to be(false)
        expect(send_event("stop")).to eq("ok" => true)
      ensure
        signal_trapper.handlers["TERM"]&.call
        thread&.join(2)
      end

      it "ends a bound step on the typed message's stop and not on its turn_failed" do
        run_agent do
          send_event("user_prompt")
          send_event("stop")
          expect(nudger.turns).to eq([["myapp", "%5", now, nil]])

          send_event("user_prompt")
          send_event("turn_failed", error: "server_error")
          expect(nudger.turns.size).to eq(1)
          expect(desk_events).to eq(%w[user_prompt stop user_prompt turn_failed])
        end
      end

      it "runs both desks on a scan, and one raising does not stop the other" do
        run_agent do
          monitor.scan_now
          expect(scans).to eq(%i[queue recovery])

          scans.clear
          recovery_desk.raises = true
          monitor.scan_now
          expect(scans).to eq(%i[queue recovery])

          scans.clear
          recovery_desk.raises = false
          @queue_raises = true
          monitor.scan_now
          expect(scans).to eq(%i[queue recovery])
        end
      end

      it "registers the claiming thread, so shutting down kills an attempt worker" do
        run_agent do
          claim = built.first[:claim_restart]
          token = nil
          worker = Thread.new do
            token = claim.call("%5")
            sleep
          end
          wait_until { token }

          expect(token).to equal(worker)
          expect(built.first[:restarting].call("%5")).to be(true)
          expect(claim.call("%5")).to be_nil

          signal_trapper.handlers["TERM"].call
          worker.join(2)

          expect(worker.alive?).to be(false)
        end
      end

      it "refuses a claim once the daemon is shutting down, so no attempt escapes the shutdown sweep" do
        run_agent do
          claim = built.first[:claim_restart]
          signal_trapper.handlers["TERM"].call

          expect(Thread.new { claim.call("%5") }.value).to be_nil
          expect(built.first[:restarting].call("%5")).to be(false)
        end
      end

      it "releases only the claim it made" do
        run_agent do
          claim, release = built.first.values_at(:claim_restart, :release_restart)
          token = Thread.new { claim.call("%5") }.value
          release.call("%5", Object.new)
          expect(built.first[:restarting].call("%5")).to be(true)
          release.call("%5", token)
          expect(built.first[:restarting].call("%5")).to be(false)
        end
      end

      describe "the claim's real path" do
        def in_thread(&block) = Thread.new(&block).value

        it "refuses a free pane while shutting down, and writes nothing" do
          run_agent do
            claim = built.first[:claim_restart]
            signal_trapper.handlers["TERM"].call

            expect(in_thread { claim.call("%5") }).to be_nil
            expect(restart_registry.held?("%5")).to be(false)
          end
        end

        it "refuses a pane another claim holds, and leaves that claim alone" do
          run_agent do
            claim = built.first[:claim_restart]
            restart_registry.claim_pending("%5")
            expect(in_thread { claim.call("%5") }).to be_nil
            expect(restart_registry.held?("%5")).to be(true)

            held = restart_registry.claim_for_queue("%6")
            expect(in_thread { claim.call("%6") }).to be_nil
            restart_registry.release("%6", Object.new)
            expect(restart_registry.held?("%6")).to be(true)
            restart_registry.release("%6", held)
            expect(restart_registry.held?("%6")).to be(false)
          end
        end

        it "releases by the token's identity, so an old token can't end a newer claim" do
          run_agent do
            claim, release = built.first.values_at(:claim_restart, :release_restart)
            first = Thread.new { claim.call("%5") }.tap(&:join)
            old = first.value
            release.call("%5", old)
            expect(restart_registry.held?("%5")).to be(false)

            newer = in_thread { claim.call("%5") }
            release.call("%5", old)
            expect(restart_registry.held?("%5")).to be(true)
            expect(newer).not_to equal(old)

            release.call("%5", newer)
            expect(restart_registry.held?("%5")).to be(false)
          end
        end
      end

      it "rebinds the queue through the prompt queue store" do
        store = instance_double(Workspace::PromptQueueStore, rebind_agent: nil)
        allow(Workspace::PromptQueueStore).to receive(:new).with(path: config.prompt_queue_path("myapp")).and_return(store)

        run_agent do
          built.first[:rebind_queue].call("%5", 4242)
          expect(store).to have_received(:rebind_agent).with("%5", agent_pid: 4242)
        end
      end
    end

    context "with a spine owner report" do
      let(:turns) { [] }
      let(:reporter) do
        turns_seen = turns
        Class.new { define_method(:turn_ended) { |pane| turns_seen << pane } }.new
      end

      subject(:agent) do
        build_agentd(
          config: config, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          spine_owner_report_factory: ->(_name) { reporter }, output: output, error_output: error_output
        )
      end

      it "hands a main agent's stop to the report, and nothing else" do
        run_agent do
          send_event("stop")
          send_event("stop", agent_id: "sub-1")
          send_event("user_prompt")
          send_event("turn_failed", error: "rate_limit")

          Timeout.timeout(2) { sleep 0.01 until turns.size >= 1 }
          sleep 0.05
          expect(turns).to eq(["%5"])
        end
      end
    end

    context "with a hook event log" do
      let(:events_dir) { File.join(Dir.mktmpdir, ".events") }
      let(:built_for) { [] }

      subject(:agent) do
        build_agentd(
          config: config, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          hook_event_log_factory: ->(name) {
            built_for << name
            Workspace::HookEventLog.new(dir: events_dir, workspace: name, boot_id: "BOOT")
          },
          output: output, error_output: error_output
        )
      end

      after { FileUtils.remove_entry(File.dirname(events_dir)) }

      it "writes each forwarded event to the daemon's own file, after the monitor has it" do
        run_agent do
          send_event("tool_start", tool: "Bash", tool_use_id: "t1")
          send_event("stop")

          expect(recorded_events).to eq(%w[tool_start stop])
        end

        lines = File.readlines(File.join(events_dir, "myapp.jsonl")).map { |line| JSON.parse(line) }
        expect(built_for).to eq(["myapp"])
        expect(lines.map { |l| l.values_at("type", "workspace", "boot_id", "seq", "tool") }).to eq([["tool_started", "myapp", "BOOT", 1, "Bash"]])
      end
    end

    context "with a plan progress watcher" do
      let(:watcher) { instance_double(Workspace::PlanProgressWatcher, start: nil, stop: nil) }
      let(:built_for) { [] }

      subject(:agent) do
        build_agentd(
          config: config, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          plan_progress_watcher_factory: ->(name) {
            built_for << name
            watcher
          },
          output: output, error_output: error_output
        )
      end

      it "starts the workspace's watcher with the daemon and stops it on the way out" do
        run_agent do
          expect(built_for).to eq(["myapp"])
          expect(watcher).to have_received(:start)
          expect(watcher).not_to have_received(:stop)
        end

        expect(watcher).to have_received(:stop)
      end
    end

    context "with a spine watcher" do
      let(:watcher) { instance_double(Workspace::SpineWatcher, start: nil, stop: nil) }
      let(:built_for) { [] }

      subject(:agent) do
        build_agentd(
          config: config, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          spine_watcher_factory: ->(name) {
            built_for << name
            watcher
          },
          output: output, error_output: error_output
        )
      end

      it "starts the workspace's watcher with the daemon and stops it on the way out" do
        run_agent do
          expect(built_for).to eq(["myapp"])
          expect(watcher).to have_received(:start)
          expect(watcher).not_to have_received(:stop)
        end

        expect(watcher).to have_received(:stop)
      end
    end

    context "with a handoff watcher" do
      let(:watcher) do
        Class.new do
          attr_reader :armed, :seen, :started, :stopped
          attr_accessor :answer, :raise_on_event

          def initialize(recorded)
            @recorded = recorded
            @armed = []
            @seen = []
            @answer = {watching: true, reason: nil}
          end

          def start = @started = true

          def stop = @stopped = true

          def arm(**args) = (@armed << args) && @answer

          def session_event(message)
            raise "boom" if raise_on_event
            @seen << [message["event"], @recorded.call.dup]
          end
        end.new(-> { recorded_events })
      end
      let(:built) { [] }

      subject(:agent) do
        build_agentd(
          config: config, restart_registry: restart_registry, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          handoff_watcher_factory: ->(**args) {
            built << args
            watcher
          },
          agent_recovery_desk_factory: ->(**) { recovery_desk },
          output: output, error_output: error_output
        )
      end

      let(:recovery_desk) do
        Class.new do
          attr_accessor :holding

          def holding?(_pane_id) = holding
          def scan = nil
          def session_event(_message) = nil
        end.new
      end

      def send_message(message)
        UNIXSocket.open(agent_socket_path) do |socket|
          socket.puts({"type" => "handoff_watch", "workspace" => "myapp", "pane_id" => "%5", "sent_at" => "2026-09-27T11:59:00.123Z",
                       "interval" => 30, "max" => 10, "text" => "are you handing off?", "sent_text" => "save state"}.merge(message).to_json)
          JSON.parse(socket.gets)
        end
      end

      before do
        allow(tmux).to receive(:pane_details).and_return([{id: "%5", window: 0, index: 0, pid: 1}, {id: "%7", window: 1, index: 0, pid: 2}])
      end

      it "builds the watcher with the workspace, the monitor, the delivery lock and a restart check, and stops it on shutdown" do
        run_agent do
          expect(built.first).to include(workspace: "myapp", session_monitor: monitor)
          expect(built.first[:delivery_lock]).to be_a(Mutex)
          restart_registry.claim_pending("%5")
          expect(built.first[:restarting].call("%5")).to be(true)
          expect(watcher.stopped).to be_falsey
        end

        expect(watcher.stopped).to be(true)
      end

      it "holds a follow-up back while an API-error recovery holds the pane" do
        run_agent do
          recovery_desk.holding = true
          expect(built.first[:restarting].call("%5")).to be(true)
          recovery_desk.holding = false
          expect(built.first[:restarting].call("%5")).to be(false)
        end
      end

      it "arms the watch with the sent time as a Time and answers what the watcher said" do
        run_agent do
          expect(watcher.started).to be_falsey
          expect(send_message({})).to eq("ok" => true, "watching" => true, "reason" => nil)

          expect(watcher.armed).to eq([{pane_id: "%5", sent_at: Time.iso8601("2026-09-27T11:59:00.123Z"), interval: 30, max: 10,
                                        text: "are you handing off?", sent_text: "save state"}])
          expect(watcher.armed.first[:sent_at]).to be_a(Time)
          expect(watcher.started).to be(true)
        end
      end

      it "passes a refusal through, including invalid" do
        run_agent do
          watcher.answer = {watching: false, reason: "invalid"}
          expect(send_message({})).to eq("ok" => true, "watching" => false, "reason" => "invalid")
          watcher.answer = {watching: false, reason: "not_claude"}
          expect(send_message({})).to eq("ok" => true, "watching" => false, "reason" => "not_claude")
        end
      end

      it "takes a text of exactly 4,000 characters whole and refuses one longer, cutting nothing" do
        run_agent do
          expect(send_message("text" => "a" * 4_000)).to include("ok" => true)
          expect(watcher.armed.last[:text].length).to eq(4_000)

          %w[text sent_text].each do |key|
            expect(send_message(key => "a" * 4_001)).to include("ok" => false, "error" => "usage")
          end
          expect(watcher.armed.size).to eq(1)
        end
      end

      [
        {"pane_id" => nil}, {"pane_id" => "five"}, {"sent_at" => "yesterday"}, {"sent_at" => 5}, {"sent_at" => nil},
        {"interval" => 0}, {"interval" => "30"}, {"interval" => nil}, {"max" => 0}, {"max" => 1.5}, {"max" => "3"},
        {"text" => ""}, {"text" => "  "}, {"text" => nil}, {"text" => 7}, {"sent_text" => ""}, {"sent_text" => nil}
      ].each do |bad|
        it "refuses #{bad.inspect} as usage and keeps serving" do
          run_agent do
            expect(send_message(bad)).to include("ok" => false, "error" => "usage")
            expect(watcher.armed).to be_empty
            expect(File.socket?(agent_socket_path)).to be(true)
            expect(send_event("stop")).to eq("ok" => true)
          end
        end
      end

      it "refuses a pane that runs a pipeline stage and hands any other pane to the watcher, whatever its window" do
        pipeline_state.start(work_item_ref: "WC-1", workspace_name: "myapp", dispatch_id: "d-1", sentinel_token: "tok", deadline: nil)

        run_agent do
          expect(send_message({})).to include("ok" => false, "error" => "pipeline_stage", "work_item_ref" => "WC-1")
          expect(send_message("pane_id" => "%7")).to include("ok" => true, "watching" => true)
          expect(watcher.armed.map { |a| a[:pane_id] }).to eq(["%7"])
        end
      end

      context "with a real session monitor and watcher" do
        let(:real_monitor) do
          Class.new(Workspace::SessionMonitor) do
            def start
            end

            def stop
            end
          end.new(tmux: tmux, process_tree: nil, session_name: "workspace-myapp")
        end

        subject(:agent) do
          build_agentd(
            config: config, tmux: tmux, work_coordinator_client: client,
            pipeline_config: pipeline_config, pipeline_state: pipeline_state,
            epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
            sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
            clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { real_monitor },
            handoff_typer: nil, output: output, error_output: error_output
          )
        end

        it "answers not_scanned for a pane the monitor has not scanned, as every pane outside window 0 is" do
          run_agent do
            expect(send_message("pane_id" => "%7")).to eq("ok" => true, "watching" => false, "reason" => "not_scanned")
          end
        end
      end

      it "answers a pane tmux does not list through the watcher, which refuses it" do
        run_agent do
          watcher.answer = {watching: false, reason: "not_scanned"}
          expect(send_message("pane_id" => "%99")).to eq("ok" => true, "watching" => false, "reason" => "not_scanned")
        end
      end

      it "answers an unknown or stale message without ending the daemon" do
        run_agent do |thread|
          UNIXSocket.open(agent_socket_path) do |socket|
            socket.puts({"type" => "handoff_unwatch", "workspace" => "myapp"}.to_json)
            expect(JSON.parse(socket.gets)).to include("ok" => false, "error" => "unknown_type")
          end
          UNIXSocket.open(agent_socket_path) do |socket|
            socket.puts({"type" => "handoff_watch", "workspace" => "gone"}.to_json)
            expect(JSON.parse(socket.gets)).to include("ok" => false, "error" => "wrong_workspace")
          end
          expect(thread).to be_alive
          expect(File.socket?(agent_socket_path)).to be(true)
        end
      end

      it "shows a session event to the watcher before the monitor records it, and the reply stays {ok: true}" do
        run_agent do
          expect(send_event("session_start", source: "clear")).to eq("ok" => true)

          expect(watcher.seen).to eq([["session_start", []]])
          expect(recorded_events).to eq(["session_start"])
        end
      end

      it "still records the event and answers when the watcher raises" do
        watcher.raise_on_event = true

        run_agent do
          expect(send_event("stop")).to eq("ok" => true)
          expect(recorded_events).to eq(["stop"])
        end
      end
    end

    context "with an agent status desk" do
      let(:built) { [] }
      let(:release) { Queue.new }
      let(:desk) do
        Class.new do
          def initialize(release) = @release = release

          def post(message) = {"ok" => true, "summary" => message["summary"]}

          def request(message)
            @release.pop
            {"ok" => true, "request_id" => "sr-1", "pane_id" => message["pane_id"]}
          end
        end.new(release)
      end

      subject(:agent) do
        build_agentd(
          config: config, restart_registry: restart_registry, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          agent_status_desk_factory: ->(**args) {
            built << args
            desk
          },
          output: output, error_output: error_output
        )
      end

      def send_message(message)
        UNIXSocket.open(agent_socket_path) do |socket|
          socket.puts(message.merge("workspace" => "myapp").to_json)
          JSON.parse(socket.gets)
        end
      end

      it "builds the desk with the workspace, its session, the monitor, the delivery lock and a restart check" do
        run_agent do
          expect(built.size).to eq(1)
          expect(built.first).to include(workspace: "myapp", session_monitor: monitor, hook_event_log: nil)
          expect(built.first[:delivery_lock]).to be_a(Mutex)
          expect(built.first[:restarting].call("%5")).to be(false)
          restart_registry.claim_pending("%5")
          expect(built.first[:restarting].call("%5")).to be(true)
        end
      end

      it "answers a status post on the accept loop" do
        run_agent do
          expect(send_message("type" => "status_post", "pane_id" => "%5", "summary" => "hi")).to eq("ok" => true, "summary" => "hi")
        end
      end

      it "answers a status request from a worker, serving hook events meanwhile" do
        run_agent do
          reply = Thread.new { send_message("type" => "status_request", "pane_id" => "%5") }

          expect(send_event("stop")).to eq("ok" => true)
          release << :go
          expect(reply.value).to eq("ok" => true, "request_id" => "sr-1", "pane_id" => "%5")
        end
      end

      it "answers internal_error when the request raises, and keeps serving" do
        allow(desk).to receive(:request).and_raise(IOError, "tmux went away")

        run_agent do
          expect(send_message("type" => "status_request", "pane_id" => "%5"))
            .to eq("ok" => false, "error" => "internal_error", "message" => "tmux went away")
          expect(send_event("stop")).to eq("ok" => true)
        end
      end
    end

    context "with a prompt queue desk" do
      let(:built) { [] }
      let(:release) { Queue.new }
      let(:desk) do
        Class.new do
          attr_reader :events

          def initialize(release)
            @release = release
            @events = Queue.new
          end

          def session_event(message) = @events << message["event"]

          def scan = nil

          def interrupt_send(message) = {"ok" => true, "interrupted" => true, "pane_id" => message["pane_id"]}

          def send_prompt(message)
            @release.pop
            {"ok" => true, "queued" => true, "id" => "q1", "position" => 1, "pane_id" => message["pane_id"]}
          end
        end.new(release)
      end

      subject(:agent) do
        build_agentd(
          config: config, restart_registry: restart_registry, tmux: tmux, work_coordinator_client: client,
          pipeline_config: pipeline_config, pipeline_state: pipeline_state,
          epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
          sentinel_poller_factory: sentinel_poller_factory, token_generator: token_generator,
          clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
          prompt_queue_desk_factory: ->(**args) {
            built << args
            desk
          },
          output: output, error_output: error_output
        )
      end

      def send_message(message)
        UNIXSocket.open(agent_socket_path) do |socket|
          socket.puts(message.merge("workspace" => "myapp").to_json)
          JSON.parse(socket.gets)
        end
      end

      it "builds the desk with the workspace, the monitor, the delivery lock and a restart check" do
        run_agent do
          expect(built.first).to include(workspace: "myapp", session_monitor: monitor)
          expect(built.first[:delivery_lock]).to be_a(Mutex)
          expect(built.first[:restarting].call("%5")).to be(false)
          restart_registry.claim_pending("%5")
          expect(built.first[:restarting].call("%5")).to be(true)
        end
      end

      it "gives the desk a restart claim that refuses a held pane and releases only its own claim" do
        run_agent do
          claim, release = built.first.values_at(:claim_restart, :release_restart)

          token = claim.call("%5")
          expect(token).not_to be_nil
          expect(built.first[:restarting].call("%5")).to be(true)
          expect(claim.call("%5")).to be_nil
          release.call("%5", Object.new)
          expect(restart_registry.held?("%5")).to be(true)
          release.call("%5", token)
          expect(restart_registry.held?("%5")).to be(false)
        end
      end

      it "answers prompt_send from a worker, serving hook events meanwhile, and passes hook events on" do
        run_agent do
          reply = Thread.new { send_message("type" => "prompt_send", "pane_id" => "%5", "text" => "hi") }

          expect(send_event("stop")).to eq("ok" => true)
          expect(desk.events.pop).to eq("stop")
          release << :go
          expect(reply.value).to include("queued" => true, "id" => "q1", "pane_id" => "%5")
        end
      end

      it "answers prompt_interrupt_send from the desk's interrupt_send" do
        run_agent do
          expect(send_message("type" => "prompt_interrupt_send", "pane_id" => "%5", "text" => "hi"))
            .to eq("ok" => true, "interrupted" => true, "pane_id" => "%5")
        end
      end

      it "answers a Workspace::Error's code when the send raises, and keeps serving" do
        allow(desk).to receive(:send_prompt).and_raise(Workspace::Error, "queue file broken")

        run_agent do
          expect(send_message("type" => "prompt_send", "pane_id" => "%5", "text" => "hi"))
            .to eq("ok" => false, "error" => "error", "message" => "queue file broken")
          expect(send_event("stop")).to eq("ok" => true)
        end
      end
    end

    context "with a fast poll" do
      let(:socket_poll_interval) { 0.02 }
      let(:workflow_tick_passes) { 2 }

      it "has the nudger look at the workspace's runs on a timer" do
        run_agent do
          wait_until { nudger.ticks.size >= 2 }

          expect(nudger.ticks.uniq).to eq(["myapp"])
        end
      end

      context "with a tick only every 1000 passes" do
        let(:workflow_tick_passes) { 1000 }

        it "does not tick the nudger on the passes before that" do
          run_agent do
            5.times do
              File.unlink(agent_socket_path)
              wait_until { File.socket?(agent_socket_path) }
            end

            expect(nudger.ticks).to be_empty
          end
        end
      end
    end

    it "serves hook events as before with no nudger wired" do
      plain = build_agentd(
        config: config, tmux: tmux, work_coordinator_client: client,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state,
        epoch_generator: -> { "wa-TESTEPOCH" }, signal_trapper: signal_trapper,
        clock: -> { now }, retry_backoff: 0, session_monitor_factory: ->(_name) { monitor },
        output: output, error_output: error_output
      )
      thread = Thread.new do
        plain.call(name: "myapp")
      ensure
        output.announce
      end
      output.wait_ready

      expect(send_event("stop")).to eq("ok" => true)
    ensure
      signal_trapper.handlers["TERM"]&.call
      thread&.join(2)
    end
  end

  describe "the Claude pane lookup with configured names" do
    let(:claude_dev) { Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]}) }
    let(:label_details) do
      [{id: "%10", window: 0, index: 0, pid: 100, command: "zsh", title: "a"},
        {id: "%11", window: 0, index: 1, pid: 200, command: "claude-dev", title: "b"},
        {id: "%12", window: 0, index: 2, pid: 300, command: "zsh", title: "c"}]
    end
    let(:labels) { Workspace::AgentLabels.new(process_tree: instance_double(Workspace::ProcessTree, snapshot: Workspace::ProcessTree::Snapshot.new([]))) }
    let(:settings) { instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {}) }
    let(:configured) do
      Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings))
    end

    def build_agent(agent_commands)
      build_agentd(session_monitor_factory: default_session_monitor_builder(tmux: tmux, error_output: error_output),
        config: config, tmux: tmux, work_coordinator_client: client, pipeline_config: pipeline_config,
        pipeline_state: pipeline_state, agent_labels: labels, agent_commands: agent_commands, current_name: "myapp",
        output: output, error_output: error_output)
    end

    # The pane a command message is typed into.
    def pane_for_command(served)
      served.handle({"type" => "command", "workspace" => "myapp", "work_item_ref" => "WC-1", "body" => "go"}, StringIO.new)
      tmux.sent_keys.last[:pane]
    end

    before do
      allow(tmux).to receive(:panes).with("myapp", window: "0").and_return([0, 1, 2])
      allow(tmux).to receive(:find_pane_by_title).and_return(nil)
      allow(tmux).to receive(:pane_details).with("myapp", window: "0").and_return(label_details.rotate(1).each_with_index.map { |d, i| d.merge(index: i) })
    end

    it "asks AgentCommands for the detector of the current workspace and finds the claude-dev pane" do
      expect(pane_for_command(build_agent(configured))).to eq("0.0")
      expect(settings).to have_received(:load).with("myapp").at_least(:once)
    end

    it "falls back to pane 1 without AgentCommands" do
      expect(pane_for_command(build_agent(nil))).to eq("0.1")
    end
  end

  # IO#close raises ThreadError in real trap context, so the TERM handler must not
  # close @server on the thread the handler runs on. The fake trapper runs the
  # handler on an ordinary thread (the closest a spec gets to trap context); the
  # server spy records which thread closed it, so a regression to a direct close
  # in the handler fails here.
  it "closes the server off the thread the TERM handler runs on" do
    closes = []
    server_spy = Class.new(UNIXServer)
    server_spy.define_method(:close) do
      closes << Thread.current
      super()
    end
    stub_const("Workspace::Commands::Agent::UNIXServer", server_spy)

    thread = Thread.new { agent.call(name: "myapp") }
    output.wait_ready

    handler_thread = nil
    trap_thread = Thread.new do
      handler_thread = Thread.current
      signal_trapper.handlers["TERM"].call
    end
    trap_thread.join(2)
    thread.join(2)

    expect(trap_thread).not_to be_alive
    expect(thread).not_to be_alive
    expect(closes).not_to be_empty
    expect(closes.first).not_to eq(handler_thread)
  ensure
    thread&.kill
    thread&.join(1)
  end
end
