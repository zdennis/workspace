require "spec_helper"

RSpec.describe "Workspace.build_agentd_parts" do
  let(:t0) { Time.utc(2026, 10, 30, 12, 0, 0) }
  let(:facts) do
    {kind: "claude", pane_pid: 100, agent_pid: 101, session_id: "s1", hooks: true,
     last_activity_at: Time.now - 3600, open_tools: 0, agents_running: 0}
  end
  let(:typing) { {kind: "claude", state: "idle", open_tools: []} }
  let(:monitor) do
    double("monitor").tap do |m|
      allow(m).to receive(:followup_facts) { facts }
      allow(m).to receive(:typing_facts) { typing }
      allow(m).to receive(:alert_handoff_stalled)
    end
  end
  let(:events) { [] }
  let(:event_log) do
    double("event_log").tap do |log|
      allow(log).to receive(:record) { |type:, project:, data:| events << [type, data] }
    end
  end
  let(:tmux) do
    FakeTmux.new(typing: true, screens: ["────────\n❯ \n"], details: [{id: "%5", window: 0, index: 1, pid: 100}])
  end
  let(:registry) { Workspace::RestartRegistry.new }
  let(:per_workspace) do
    {workspace: "ws", session_name: "ws", delivery_lock: Mutex.new, registry: registry, epoch_generator: -> { "wa-1" }, recovering: ->(_pane_id) { false }}
  end
  let(:options) do
    {tmux: tmux, config: Workspace::Config.new, work_coordinator_client: RecordingCoordinatorClient.new,
     pipeline_config: RecordingPipelineConfig.new, pipeline_state: RecordingPipelineState.new,
     session_monitor_factory: ->(_workspace) { monitor }, event_log: event_log}
  end

  def build(**given)
    Workspace.build_agentd_parts(**options, **given).call(**per_workspace)
  end

  def arm(parts)
    parts.handoff_watcher.arm(pane_id: "%5", sent_at: Time.now - 3600, interval: 1, max: 3, text: "follow up", sent_text: "save")
  end

  def ended_reasons
    events.select { |type, _| type == Workspace::EventLog::HANDOFF_WATCH_ENDED }.map { |_, data| data["reason"] }
  end

  def followup_outcomes
    events.select { |type, _| type == Workspace::EventLog::HANDOFF_FOLLOWUP }.map { |_, data| data["outcome"] }
  end

  it "returns a builder that makes a frozen AgentdParts with its thirteen members" do
    builder = Workspace.build_agentd_parts(**options)
    expect(builder).to respond_to(:call)

    parts = builder.call(**per_workspace)

    expect(parts).to be_a(Workspace::AgentdParts)
    expect(parts).to be_frozen
    expect(parts.members).to eq(%i[hook_event_log monitor restart_runner restart_desk plan_progress_watcher spine_owner_report
      spine_watcher status_desk queue_desk recovery_desk handoff_watcher pipeline_desk hook_fanout])
    expect(parts.monitor).to equal(monitor)
    expect(parts.restart_runner).to be_a(Workspace::RestartRunner)
    expect(parts.restart_desk).to be_a(Workspace::AgentdRestartDesk)
    expect(parts.status_desk).to be_a(Workspace::AgentStatusDesk)
    expect(parts.queue_desk).to be_a(Workspace::PromptQueueDesk)
    expect(parts.handoff_watcher).to be_a(Workspace::HandoffWatcher)
    expect(parts.pipeline_desk).to be_a(Workspace::PipelineDesk)
    expect(parts.hook_fanout).to be_a(Workspace::HookFanout)
    expect(parts.hook_event_log).to be_nil
    expect(parts.recovery_desk).to be_nil
  end

  it "builds the pipeline desk alone with pipeline_only, and puts a desk it is given in its member" do
    built = []
    only = Workspace.build_agentd_parts(**options, session_monitor_factory: ->(_workspace) { built << :monitor })
      .call(**per_workspace, pipeline_only: true)

    expect(only.pipeline_desk).to be_a(Workspace::PipelineDesk)
    expect(only.to_h.except(:pipeline_desk).values).to all(be_nil)
    expect(built).to be_empty
    expect(Workspace.build_agentd_parts(**options).call(**per_workspace, pipeline_desk: only.pipeline_desk).pipeline_desk).to equal(only.pipeline_desk)
  end

  it "puts what a part's factory builds in its member" do
    sentinels = %i[hook_event_log plan_progress_watcher spine_watcher spine_owner_report].to_h { |name| [name, Object.new] }
    factories = sentinels.to_h { |name, sentinel| [:"#{name}_factory", ->(_workspace) { sentinel }] }
    restart_runner = Object.new

    parts = build(**factories, restart_runner_factory: ->(_monitor) { restart_runner })

    sentinels.each { |name, sentinel| expect(parts[name]).to equal(sentinel) }
    expect(parts.restart_runner).to equal(restart_runner)
  end

  it "hands hook events through the fan-out to the parts built and the workflow nudger it is given" do
    nudger = RecordingNudger.new
    hook_log = RecordingHookLog.new
    allow(monitor).to receive(:record)
    parts = build(workflow_nudger: nudger, hook_event_log_factory: ->(_workspace) { hook_log })

    parts.hook_fanout.session_event({"type" => "session_event", "workspace" => "ws", "event" => "stop", "pane_id" => "%5"})

    expect(monitor).to have_received(:record)
    expect(hook_log.calls.size).to eq(1)
    expect(nudger.calls).to eq([[:turn_ended, "ws", "%5", {turn_started: nil, background: nil}]])
  end

  it "gives a replaced desk the keywords the builder passes" do
    seen = nil
    desk = Object.new
    build(agent_status_desk_factory: ->(**given) {
      seen = given
      desk
    })

    expect(seen).to include(workspace: "ws", session_name: "ws", session_monitor: monitor)
    expect(seen[:restarting].call("%5")).to be(false)
  end

  it "reads a pane's restart claim from the registry for the desks" do
    seen = nil
    build(agent_status_desk_factory: ->(**given) { seen = given })
    token = registry.claim_for_recovery("%5")

    expect(seen[:restarting].call("%5")).to be(true)
    registry.release("%5", token)
  end

  describe "the restart desk" do
    let(:registry) { RecordingRestartRegistry.new }
    let(:runner) { RecordingRestartRunner.new }
    let(:restart) { {"type" => "restart_agent", "workspace" => "ws", "pane" => "0.1", "prompt" => "carry on"} }

    before do
      allow(monitor).to receive(:pane_kind).and_return("claude")
      allow(monitor).to receive(:agent_pid).and_return(101)
      allow(monitor).to receive(:delivery_facts).and_return(nil)
    end

    it "finds the pane in the workspace's session, reads it through the context reader and runs it on the restart runner" do
      reader = RecordingContextReader.new
      parts = build(context_reader: reader, restart_runner_factory: ->(_monitor) { runner })
      reply = StringIO.new

      parts.restart_desk.handle(restart, reply)
      registry.workers.fetch("%5").call

      expect(JSON.parse(reply.string)).to include("ok" => true, "status" => "started", "pane" => "0.1", "pane_id" => "%5")
      expect(reader.calls).to eq([[:read, {pane_id: "%5", agent_pid: 101, current_session_id: nil, kind: "claude"}]])
      expect(runner.calls.first.drop(2)).to eq(["carry on", false, Workspace::AgentRestart::CONFIRM_TIMEOUT, nil, {run_id: nil}])
    end

    it "refuses every restart with no context reader" do
      reply = StringIO.new

      build.restart_desk.handle(restart, reply)

      expect(JSON.parse(reply.string)).to include("ok" => false, "error" => "context_unavailable")
    end
  end

  it "types a handoff follow-up through a PromptTyper by default" do
    parts = build
    expect(arm(parts)).to include(watching: true)

    parts.handoff_watcher.poll

    expect(followup_outcomes).to eq(["submitted"])
    expect(tmux.texts).to include("follow up")
  end

  it "gives a handoff watcher no typer with handoff_typer: nil" do
    parts = build(handoff_typer: nil)
    arm(parts)

    parts.handoff_watcher.poll

    expect(followup_outcomes).to eq(["raised"])
    expect(tmux.texts).to be_empty
  end

  it "types through the handoff_typer it is given" do
    typer = double("typer")
    allow(typer).to receive(:type).and_return(double("result", outcome: :submitted))
    parts = build(handoff_typer: typer)
    arm(parts)

    parts.handoff_watcher.poll

    expect(typer).to have_received(:type).with(hash_including(session_name: "ws", pane_id: "%5", text: "follow up"))
    expect(followup_outcomes).to eq(["submitted"])
  end

  it "ends a handoff watch plan_paused when plan_paused_for says the workspace's plan is paused" do
    asked = []
    parts = build(plan_paused_for: ->(workspace) {
      asked << workspace
      -> { true }
    })
    arm(parts)

    parts.handoff_watcher.poll

    expect(asked).to eq(["ws"])
    expect(ended_reasons).to eq(["plan_paused"])
    expect(followup_outcomes).to be_empty
  end

  it "never pauses a handoff watch when plan_paused_for is nil" do
    parts = build
    arm(parts)

    parts.handoff_watcher.poll

    expect(ended_reasons).to be_empty
  end
end
