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

  let(:session_monitor_factory) do
    Workspace::SessionMonitorBuilder.new(
      tmux: tmux, logger: Workspace::Logger.new, error_output: error_output, scan_slots: nil,
      process_tree_factory: ->(**) { empty_process_tree }
    )
  end

  # The monitor's scan reads the process table; an empty one starts no ps.
  let(:empty_process_tree) do
    Class.new do
      def snapshot = Workspace::ProcessTree::Snapshot.new([])
    end.new
  end

  describe "starting the agent for a workspace" do
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
        wait_until { File.exist?(agent_socket_path) }
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
  end

  describe "waking workflow runs" do
    include_context "waking workflow runs"

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
  end
end
