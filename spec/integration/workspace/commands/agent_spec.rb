require "spec_helper"
require "tmpdir"

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
end
