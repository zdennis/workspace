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
    {workspace: "ws", session_name: "ws", delivery_lock: Mutex.new, registry: registry, recovering: ->(_pane_id) { false }}
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

  it "returns a builder that makes a frozen AgentdParts with its fourteen members" do
    builder = Workspace.build_agentd_parts(**options)
    expect(builder).to respond_to(:call)

    parts = builder.call(**per_workspace)

    expect(parts).to be_a(Workspace::AgentdParts)
    expect(parts).to be_frozen
    expect(parts.members).to eq(%i[hook_event_log monitor restart_runner restart_desk plan_progress_watcher spine_owner_report
      spine_watcher status_desk queue_desk recovery_desk handoff_watcher pipeline_desk work_queue_desk hook_fanout])
    expect(parts.monitor).to equal(monitor)
    expect(parts.restart_runner).to be_a(Workspace::RestartRunner)
    expect(parts.restart_desk).to be_a(Workspace::AgentdRestartDesk)
    expect(parts.status_desk).to be_a(Workspace::AgentStatusDesk)
    expect(parts.queue_desk).to be_a(Workspace::PromptQueueDesk)
    expect(parts.handoff_watcher).to be_a(Workspace::HandoffWatcher)
    expect(parts.pipeline_desk).to be_a(Workspace::PipelineDesk)
    expect(parts.hook_fanout).to be_a(Workspace::HookFanout)
    expect(parts.work_queue_desk).to be_a(Workspace::WorkQueueDesk)
    expect(parts.hook_event_log).to be_nil
    expect(parts.recovery_desk).to be_nil
  end

  it "opens an inbox item for an escalated permission request only when given a permission policy config" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ws.json")
      config = Workspace::Config.new
      allow(config).to receive(:inbox_path).with("workspace", "ws").and_return(path)
      allow(monitor).to receive(:record)
      request = {"event" => "permission_request", "pane_id" => "%5", "tool" => "Bash", "input" => "ls", "decision" => "ask"}

      build(config: config).hook_fanout.session_event(request)
      expect(File.exist?(path)).to be(false)

      build(config: config, permission_policy_config: double("policy_config", configured?: true)).hook_fanout.session_event(request)
      expect(JSON.parse(File.read(path)).first).to include("dedupe_key" => "permission:ws:%5:main")
    end
  end

  it "opens an item for an undecided request from a pane bound to a live run when no policy is configured" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ws.json")
      config = Workspace::Config.new
      allow(config).to receive(:inbox_path).with("workspace", "ws").and_return(path)
      allow(monitor).to receive(:record)
      entry = {"kind" => "run", "id" => "r1", "session" => "ws", "pane_slot" => "ws:1.0"}
      bindings = double("pane_bindings", binding_for: entry, stale?: false)
      allow(tmux).to receive_messages(session_name_for_pane: "ws", pane_slot: "ws:1.0", server_pid_for_pane: "1")
      request = {"event" => "permission_request", "pane_id" => "%5", "tool" => "Bash", "input" => "ls"}

      build(config: config, pane_bindings: bindings, permission_policy_config: double("policy_config", configured?: false)).hook_fanout.session_event(request)
      expect(JSON.parse(File.read(path)).first).to include("dedupe_key" => "permission:ws:%5:main")
    end
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

  it "hands a Stop through the fan-out to the monitor, the hook log and the workflow nudger with that log" do
    nudger = RecordingNudger.new
    hook_log = RecordingHookLog.new
    allow(monitor).to receive(:record)
    parts = build(workflow_nudger: nudger, hook_event_log_factory: ->(_workspace) { hook_log }, work_queue_desk_factory: ->(**) { RecordingWorkQueueDesk.new })

    parts.hook_fanout.session_event({"type" => "session_event", "workspace" => "ws", "event" => "stop", "pane_id" => "%5"})

    expect(monitor).to have_received(:record)
    expect(hook_log.calls.size).to eq(1)
    expect(nudger.calls).to eq([[:turn_ended, "ws", "%5", {turn_started: nil, background: nil, transcript_path: nil, hook_log: hook_log}]])
    expect(nudger.calls.first.last[:hook_log]).to equal(parts.hook_event_log)
  end

  it "ticks the workflow nudger through the fan-out with the workspace and the one hook log the parts hold" do
    nudger = RecordingNudger.new
    parts = build(workflow_nudger: nudger, hook_event_log_factory: ->(_workspace) { RecordingHookLog.new })

    parts.hook_fanout.tick

    expect(nudger.calls.map(&:first)).to eq([:tick])
    expect(nudger.calls.first[1]).to eq("ws")
    expect(nudger.calls.first.last[:hook_log]).to equal(parts.hook_event_log)
  end

  it "puts the work queue desk its factory builds in its member, and asks it for a pass once the Stop's advance exits and on each scan" do
    desk = RecordingWorkQueueDesk.new
    seen = nil
    nudger = RecordingNudger.new(woken: "wr_1")
    allow(monitor).to receive(:record)
    allow(monitor).to receive(:delivery_facts)
    parts = build(workflow_nudger: nudger, work_queue_desk_factory: ->(**given) { (seen = given) && desk })

    parts.hook_fanout.session_event({"type" => "session_event", "workspace" => "ws", "event" => "stop", "pane_id" => "%5"})
    expect(desk.calls).to be_empty
    nudger.exits.each(&:call)
    parts.hook_fanout.scan

    expect(seen).to eq(workspace: "ws")
    expect(parts.work_queue_desk).to equal(desk)
    expect(desk.calls).to eq(%i[turn_ended scan])
  end

  it "scans the desks, then the work queue desk" do
    order = []
    queue_desk = RecordingHookDesk.new(order: order, label: :queue_desk)
    recovery_desk = RecordingHookDesk.new(order: order, label: :recovery_desk)
    parts = build(prompt_queue_desk_factory: ->(**) { queue_desk }, agent_recovery_desk_factory: ->(**) { recovery_desk },
      work_queue_desk_factory: ->(**) { RecordingWorkQueueDesk.new(order: order) })

    parts.hook_fanout.scan

    expect(order).to eq([[:queue_desk, :scan], [:recovery_desk, :scan], [:work_queue_desk, :scan]])
  end

  it "reports a stage owner's finished turn to the owner report on a main agent's Stop" do
    report = RecordingOwnerReport.new
    allow(monitor).to receive(:record)
    parts = build(spine_owner_report_factory: ->(_workspace) { report }, work_queue_desk_factory: ->(**) { RecordingWorkQueueDesk.new })
    stop = {"type" => "session_event", "workspace" => "ws", "event" => "stop", "pane_id" => "%5"}

    parts.hook_fanout.session_event(stop.merge("agent_id" => "a1"))
    parts.hook_fanout.session_event(stop)
    deadline = Time.now + 2
    sleep 0.01 until report.calls.any? || Time.now > deadline

    expect(parts.spine_owner_report).to equal(report)
    expect(report.calls).to eq([[:turn_ended, "%5"]])
  end

  it "runs a main agent's Stop through the fan-out in the production order of its subscribers" do
    order = []
    nudger = RecordingNudger.new(order: order, woken: "wr_1")
    parts = build(session_monitor_factory: ->(_workspace) { RecordingHookMonitor.new(order: order) },
      workflow_nudger: nudger, hook_event_log_factory: ->(_workspace) { RecordingHookLog.new(order: order) },
      handoff_watcher_factory: ->(**) { RecordingHandoffWatcher.new(order: order) },
      spine_owner_report_factory: ->(_workspace) { RecordingOwnerReport.new(order: order) },
      prompt_queue_desk_factory: ->(**) { RecordingHookDesk.new(order: order, label: :queue_desk) },
      agent_recovery_desk_factory: ->(**) { RecordingHookDesk.new(order: order, label: :recovery_desk) },
      work_queue_desk_factory: ->(**) { RecordingWorkQueueDesk.new(order: order) })

    parts.hook_fanout.session_event({"type" => "session_event", "workspace" => "ws", "event" => "stop", "pane_id" => "%5"})
    deadline = Time.now + 2
    sleep 0.01 until order.include?([:owner_report, :turn_ended]) || Time.now > deadline

    # The owner report runs on its own thread, so only its place after the nudger is fixed.
    expect(order.reject { |entry| entry == [:owner_report, :turn_ended] }).to eq([[:handoff_watcher, :before_record], [:monitor, :record],
      [:hook_log, :record], [:nudger, :turn_ended], [:queue_desk, :session_event], [:recovery_desk, :session_event]])
    expect(order.index([:owner_report, :turn_ended])).to be > order.index([:nudger, :turn_ended])

    nudger.exits.each(&:call)
    expect(order.last).to eq([:work_queue_desk, :turn_ended])
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
