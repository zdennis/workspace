require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::PipelineDesk do
  let(:tmpdir) { Dir.mktmpdir("pipeline-desk") }
  let(:stages) { [{pane_index: 1, role: "research", timeout: 1800}, {pane_index: 2, role: "implement", timeout: nil}] }
  let(:pipeline_config) { RecordingPipelineConfig.new(stages: {"myapp" => stages}) }
  let(:pipeline_state) { RecordingPipelineState.new(stages: stages) }
  let(:client) { RecordingCoordinatorClient.new }
  let(:tmux) { FakeTmux.new }
  let(:config) { instance_double(Workspace::Config, handoff_dir: File.join(tmpdir, "handoffs"), agent_socket_path: "/tmp/myapp.sock") }
  let(:epochs) { %w[wa-2 wa-3 wa-4] }
  let(:now) { Time.utc(2026, 11, 11, 12) }
  let(:pollers) { [] }
  let(:events) { [] }
  let(:error_output) { StringIO.new }
  let(:claude_pane) { -> { "0.3" } }

  subject(:desk) do
    count = 0
    described_class.new(workspace: "myapp", session_name: "myapp-session", tmux: tmux, config: config,
      pipeline_config: pipeline_config, pipeline_state: pipeline_state, client: client, delivery_lock: Mutex.new,
      sentinel_poller_factory: ->(**given) { RecordingSentinelPoller.new(**given).tap { |poller| pollers << poller } },
      stage_marks: ->(timeout) { ["tok-#{count += 1}", timeout && now + timeout] }, epoch_generator: -> { epochs.shift }, retry_backoff: 0,
      event_log: BlockEventLog.new { |type:, project:, data:| events << [type, project, data] }, error_output: error_output)
  end

  after { FileUtils.remove_entry(tmpdir) }

  def command(ref = "WC-1", **extra)
    {"type" => "command", "workspace" => "myapp", "work_item_ref" => ref, "dispatch_id" => "d-1", "body" => "do it"}.merge(extra.transform_keys(&:to_s))
  end

  def inject(ref = "WC-1", **extra)
    {"type" => "inject", "workspace" => "myapp", "work_item_ref" => ref, "body" => "steer"}.merge(extra.transform_keys(&:to_s))
  end

  def event_types = events.map(&:first)

  describe "#command" do
    it "types the body and the sentinel instruction into the first stage, starts the item and arms its watch" do
      reply = desk.command(command, claude_pane: claude_pane)

      expect(reply).to eq("ok" => true)
      expect(tmux.sent_keys.first).to include(session: "myapp-session", pane: "0.1",
        text: "do it\n\n#{Workspace::SentinelPoller.instruction("tok-1")}")
      expect(pipeline_state.current("WC-1")).to include(pane_index: 1, sentinel_token: "tok-1", dispatch_id: "d-1")
      expect(pollers.map { |poller| [poller.session_name, poller.pane, poller.token, poller.deadline] })
        .to eq([["myapp-session", 1, "tok-1", now + 1800]])
      expect(client.reports).to eq([{"message_id" => "m-1", "sequence" => 1, "workspace" => "myapp", "work_item_ref" => "WC-1",
                                     "type" => "status_update", "message" => "Pipeline started at stage research (pane 1)"}])
      expect(events).to eq([["dispatched", "myapp", {"work_item_ref" => "WC-1", "dispatch_id" => "d-1", "stage" => "research",
                                                     "pane" => 1, "delivery" => "submitted"}]])
    end

    it "frames the coordinator's reporting instructions after the body" do
      desk.command(command(reporting_instructions: "  run report  "), claude_pane: claude_pane)

      expect(tmux.texts.first).to start_with("do it\n\nStatus reporting:\nrun report\n\n")
    end

    it "types into the Claude pane, with no watch, when the workspace has no pipeline" do
      pipeline_config = RecordingPipelineConfig.new
      desk = described_class.new(workspace: "myapp", session_name: "myapp-session", tmux: tmux, config: config,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state, client: client, delivery_lock: Mutex.new,
        sentinel_poller_factory: ->(**) { raise "no watch" }, stage_marks: ->(_) { raise "no marks" }, epoch_generator: -> { "wa-1" }, retry_backoff: 0)

      expect(desk.command(command, claude_pane: claude_pane)).to eq("ok" => true)
      expect(tmux.sent_keys).to eq([{session: "myapp-session", pane: "0.3", text: "do it", enter: true}])
      expect(client.reports.map { |report| report["message"] }).to eq(["Command delivered to myapp-session:0.3"])
      expect(pipeline_state.in_flight_refs).to be_empty
    end

    it "drops the item, reports an error and answers not_delivered when the text never reached the pane" do
      tmux.statuses = [:failed]

      reply = desk.command(command, claude_pane: claude_pane)

      expect(reply).to include("ok" => false, "error" => "not_delivered")
      expect(pipeline_state.current("WC-1")).to be_nil
      expect(pollers).to be_empty
      expect(client.reports.last).to include("type" => "error", "message" => "command for WC-1 was not delivered to myapp: fake failed")
      expect(event_types).to eq(["dispatch_failed"])
    end

    it "starts the stage with a warning when the text may not have been submitted" do
      tmux.statuses = [:unsubmitted]

      expect(desk.command(command, claude_pane: claude_pane)).to eq("ok" => true)
      expect(client.reports.map { |report| report["message"] }).to eq(["Pipeline started at stage research (pane 1)", "Warning: fake unsubmitted"])
      expect(error_output.string).to include("workspace agent: WC-1: fake unsubmitted")
      expect(pollers.size).to eq(1)
    end
  end

  describe "a stage's watch" do
    before { desk.command(command, claude_pane: claude_pane) }

    it "hands the finished stage's output to the next stage when its sentinel is seen" do
      tmux.captured_output = "research notes"

      pollers.first.complete("research done")

      handoff = File.join(tmpdir, "handoffs", "myapp-WC-1-handoff.txt")
      expect(File.read(handoff)).to eq("research notes")
      expect(tmux.sent_keys.last).to include(pane: "0.2",
        text: "You are the implement stage. Context from the previous stage: #{handoff}\n#{Workspace::SentinelPoller.instruction("tok-2")}")
      expect(pipeline_state.current("WC-1")).to include(pane_index: 2, phase: "implement", sentinel_token: "tok-2")
      expect(client.reports.drop(1).map { |report| report.slice("type", "phase", "from_pane", "to_pane") })
        .to eq([{"type" => "phase_change", "phase" => "implement"}, {"type" => "pipeline_advanced", "from_pane" => 1, "to_pane" => 2}])
      expect(pollers.last.token).to eq("tok-2")
      expect(event_types.last).to eq("stage_completed")
    end

    it "reports the item complete after the last stage" do
      pollers.first.complete("research done")
      pollers.last.complete("all done")

      expect(pipeline_state.current("WC-1")).to be_nil
      expect(client.reports.last).to include("type" => "task_complete", "summary" => "all done")
      expect(pollers.last).to be_stopped
    end

    it "fails the item, naming its budget, when it runs past its deadline" do
      pollers.first.time_out

      expect(pipeline_state.current("WC-1")).to be_nil
      expect(client.reports.last["message"]).to start_with("timed out after 30m (deadline 2026-11-11T12:30:00Z)")
      expect(event_types.last).to eq("stage_timed_out")
    end

    it "fails the item when its poller gives up" do
      pollers.first.report_error("pane went away")

      expect(client.reports.last).to include("type" => "error", "message" => "pane went away")
      expect(error_output.string).to include("WC-1 failed at pane 1: pane went away")
    end

    it "fails the item when the hand-off never reaches the next stage" do
      tmux.statuses = [:failed]

      pollers.first.complete("research done")

      expect(pipeline_state.current("WC-1")).to be_nil
      expect(client.reports.last["message"]).to eq("could not hand off to the implement stage (pane 2): fake failed")
    end
  end

  describe "#inject" do
    it "refuses a steer for an item with no pipeline running" do
      expect(desk.inject(inject)).to include("ok" => false, "error" => "no_active_pipeline")
    end

    it "queues an ordinary steer for the next stage and types it after the hand-off" do
      desk.command(command, claude_pane: claude_pane)

      expect(desk.inject(inject)).to eq("ok" => true, "queued_for_pane" => 2)
      pollers.first.complete("research done")

      expect(tmux.sent_keys.last).to include(pane: "0.2", text: "steer")
    end

    it "interrupts the running stage for an urgent steer and types it there" do
      desk.command(command, claude_pane: claude_pane)

      expect(desk.inject(inject(interrupt: true))).to eq("ok" => true, "queued_for_pane" => 1)
      expect(tmux.sent_key_names.last).to eq(session: "myapp-session", pane: "0.1", key: "C-c")
      expect(tmux.sent_keys.last).to include(pane: "0.1", text: "steer")
    end

    it "refuses a steer aimed at a stage that has finished" do
      desk.command(command, claude_pane: claude_pane)

      expect(desk.inject(inject(expected_token: "tok-0"))).to include("ok" => false, "error" => "stale_token")
    end

    it "refuses an ordinary steer on the last stage" do
      desk.command(command, claude_pane: claude_pane)
      pollers.first.complete("research done")

      expect(desk.inject(inject)).to include("ok" => false, "error" => "no_next_stage")
    end
  end

  describe "#report_progress" do
    it "reports a status update for a tracked item without typing" do
      desk.command(command, claude_pane: claude_pane)
      typed = tmux.sent_keys.size

      desk.report_progress("WC-1", "tests running")

      expect(client.reports.last).to include("type" => "status_update", "message" => "tests running", "sequence" => 2)
      expect(tmux.sent_keys.size).to eq(typed)
    end

    it "reports nothing for an item it does not track" do
      desk.report_progress("WC-9", "nobody")

      expect(client.reports).to be_empty
    end
  end

  describe "#fail_pipeline" do
    it "stops the item's watch, drops it, logs and reports the failure" do
      desk.command(command, claude_pane: claude_pane)

      desk.fail_pipeline("WC-1", "aborted")

      expect(pollers.first).to be_stopped
      expect(pipeline_state.current("WC-1")).to be_nil
      expect(events.last).to eq(["stage_failed", "myapp", {"work_item_ref" => "WC-1", "pane" => 1, "message" => "aborted"}])
      expect(client.reports.last).to include("type" => "error", "message" => "aborted")
    end

    it "leaves the item alone for a watch that has been replaced" do
      desk.command(command, claude_pane: claude_pane)
      replaced = pollers.first
      desk.command(command, claude_pane: claude_pane)

      desk.fail_pipeline("WC-1", "late", watched_by: replaced)

      expect(pipeline_state.current("WC-1")).to include(sentinel_token: "tok-2")
    end
  end

  describe "#pipeline_ref_on" do
    it "names the item whose stage runs on the pane" do
      desk.command(command, claude_pane: claude_pane)

      expect(desk.pipeline_ref_on(1)).to eq("WC-1")
      expect(desk.pipeline_ref_on(2)).to be_nil
    end
  end

  describe "#recover_in_flight" do
    let(:pipeline_state) do
      RecordingPipelineState.new(stages: stages, entries: [
        {work_item_ref: "WC-1", workspace_name: "myapp", pane_index: 1, sentinel_token: "tok-9", deadline: now},
        {work_item_ref: "WC-2", workspace_name: "myapp", pane_index: 5, sentinel_token: "tok-8"}
      ])
    end

    it "re-arms the watch of a stage whose pane is alive and drops one whose pane died" do
      desk.recover_in_flight

      expect(pollers.map { |poller| [poller.pane, poller.token, poller.deadline] }).to eq([[1, "tok-9", now]])
      expect(pipeline_state.in_flight_refs).to eq(["WC-1"])
      expect(error_output.string).to include("WC-2 lost its pane (5) while the agent was down")
      expect(events).to eq([["stage_failed", "myapp", {"work_item_ref" => "WC-2", "pane" => 5, "message" => "lost its pane while the agent was down"}]])
    end
  end

  describe "#register" do
    it "registers the socket, epoch, pipeline flag and in-flight items, and answers true" do
      desk.command(command, claude_pane: claude_pane)

      expect(desk.register(socket: "/tmp/ws.sock", epoch: "wa-1")).to be(true)
      expect(client.registrations).to eq([{name: "myapp", socket: "/tmp/ws.sock", pipeline: true, epoch: "wa-1",
                                           in_flight: [{"work_item_ref" => "WC-1", "dispatch_id" => "d-1", "phase" => "research"}]}])
    end

    it "registers under a fresh epoch from its generator when given none" do
      expect(desk.register(socket: "/tmp/ws.sock")).to be(true)
      expect(client.registrations).to eq([{name: "myapp", socket: "/tmp/ws.sock", pipeline: true, epoch: "wa-2", in_flight: []}])
    end

    it "answers false and says why when the coordinator refuses" do
      client = RecordingCoordinatorClient.new(register_reply: {"ok" => false, "error" => "name taken"})
      desk = described_class.new(workspace: "myapp", session_name: "myapp-session", tmux: tmux, config: config,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state, client: client, delivery_lock: Mutex.new,
        sentinel_poller_factory: ->(**) {}, stage_marks: ->(_) {}, epoch_generator: -> { "wa-1" }, error_output: error_output)

      expect(desk.register(socket: "/tmp/ws.sock", epoch: "wa-1")).to be(false)
      expect(error_output.string).to eq("Could not register with work-coordinator: name taken\n")
    end
  end

  describe "#send_registration" do
    it "answers the coordinator's reply" do
      expect(desk.send_registration(socket: "/tmp/ws.sock", epoch: "wa-2")).to eq("ok" => true, "epoch" => "wc-1")
      expect(client.registrations.last).to include(epoch: "wa-2", pipeline: true, in_flight: [])
    end
  end

  describe "#deregister" do
    it "deregisters the workspace" do
      desk.register(socket: "/tmp/ws.sock", epoch: "wa-1")

      desk.deregister

      expect(client.calls.last).to eq([:deregister, "myapp"])
    end
  end

  describe "#stop_watches" do
    it "stops every stage watch" do
      desk.command(command, claude_pane: claude_pane)
      desk.command(command("WC-2"), claude_pane: claude_pane)

      desk.stop_watches

      expect(pollers).to all(be_stopped)
    end
  end

  describe "reporting" do
    it "retries a report the coordinator could not take" do
      client = RecordingCoordinatorClient.new(failures: 2)
      desk = described_class.new(workspace: "myapp", session_name: "myapp-session", tmux: tmux, config: config,
        pipeline_config: pipeline_config, pipeline_state: pipeline_state, client: client, delivery_lock: Mutex.new,
        sentinel_poller_factory: ->(**) { RecordingSentinelPoller.new(session_name: "s", pane: 1, token: "t", deadline: nil) },
        stage_marks: ->(_) { ["t", nil] }, epoch_generator: -> { "wa-1" }, retry_backoff: 0, error_output: error_output)

      desk.command(command, claude_pane: claude_pane)

      expect(client.reports.size).to eq(3)
      expect(client.reports.map { |report| report["message_id"] }.uniq).to eq(["m-1"])
      expect(error_output.string).to be_empty
    end

    it "stops the item's pipeline when the coordinator has no record of it" do
      client.replies = [{"ok" => true}, {"ok" => true, "action" => "give_up"}]
      desk.command(command, claude_pane: claude_pane)

      desk.report_progress("WC-1", "still going")

      expect(pipeline_state.current("WC-1")).to be_nil
      expect(pollers.first).to be_stopped
      expect(event_types.last).to eq("pipeline_dropped")
    end
  end

  describe "#coordinator_restarting" do
    it "holds every report from then on" do
      desk.command(command, claude_pane: claude_pane)

      desk.coordinator_restarting
      desk.report_progress("WC-1", "held")

      expect(client.reports.size).to eq(1)
      expect(error_output.string).to include("work-coordinator unreachable; holding status updates until it returns")
    end
  end

  describe "#re_register" do
    it "registers at the daemon's socket under a fresh epoch and answers true" do
      expect(desk.re_register).to be(true)
      expect(desk.re_register).to be(true)

      expect(client.registrations.map { |registration| registration.slice(:name, :socket, :epoch) })
        .to eq([{name: "myapp", socket: "/tmp/myapp.sock", epoch: "wa-2"}, {name: "myapp", socket: "/tmp/myapp.sock", epoch: "wa-3"}])
      expect(error_output.string).to be_empty
    end

    it "warns once while the coordinator cannot be reached, then says once that it re-registered" do
      client.register_failures = 2

      expect([desk.re_register, desk.re_register, desk.re_register, desk.re_register]).to eq([false, false, true, true])
      expect(error_output.string).to eq("workspace agent: could not re-register with work-coordinator: connection refused; will keep retrying\n" \
                                        "workspace agent: re-registered with work-coordinator\n")
    end

    it "warns once while the coordinator refuses, then says once that it re-registered" do
      client.register_reply = {"ok" => false, "error" => "name taken"}

      expect([desk.re_register, desk.re_register]).to eq([false, false])
      client.register_reply = {"ok" => true}
      expect(desk.re_register).to be(true)

      expect(error_output.string).to eq("workspace agent: work-coordinator refused re-registration: name taken; will keep retrying\n" \
                                        "workspace agent: re-registered with work-coordinator\n")
    end

    it "warns again after an outage that follows a registration" do
      client.register_failures = 1
      desk.re_register
      desk.re_register
      client.register_failures = 1
      desk.re_register

      expect(error_output.string.scan("could not re-register").size).to eq(2)
    end

    context "when the coordinator answers a report with reregister" do
      let(:client) { RecordingCoordinatorClient.new(failures: 3, replies: [{"ok" => true, "action" => "reregister", "epoch" => "wc-2"}, {"ok" => true}]) }

      it "re-registers and replays the held reports once the registration is taken" do
        desk.command(command, claude_pane: claude_pane)

        desk.report_progress("WC-1", "after the restart")

        expect(client.registrations.map { |registration| registration[:epoch] }).to eq(["wa-2"])
        expect(client.reports.map { |report| report["message_id"] }).to eq(%w[m-1 m-1 m-1 m-2 m-1])
      end

      it "keeps the held reports when the re-registration is refused, and warns once" do
        client.register_reply = {"ok" => false, "error" => "name taken"}
        desk.command(command, claude_pane: claude_pane)

        desk.report_progress("WC-1", "after the restart")

        expect(client.reports.map { |report| report["message_id"] }).to eq(%w[m-1 m-1 m-1 m-2])
        expect(error_output.string.scan("refused re-registration").size).to eq(1)
      end
    end
  end
end
