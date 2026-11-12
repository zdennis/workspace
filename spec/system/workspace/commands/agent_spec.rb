require "spec_helper"
require "tmpdir"

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

  describe "surviving a restart" do
    let(:state_path) { File.join(tmpdir, "pipeline.json") }

    def write_pipeline_config
      File.write(project_config_path, <<~YAML)
        pipeline:
          panes:
            - role: researcher
            - role: implementer
          handoff: file_handoff
      YAML
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
