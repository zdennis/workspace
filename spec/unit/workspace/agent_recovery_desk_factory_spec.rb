require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::AgentRecoveryDeskFactory do
  let(:tmpdir) { Dir.mktmpdir("ws-desk-factory") }
  let(:recovery_config) { instance_double(Workspace::AgentRecoveryConfig, enabled?: true) }
  let(:detector) { Workspace::AgentDetector.new }
  let(:agent_commands) { instance_double(Workspace::AgentCommands, kind: "claude", detector: detector) }
  let(:config) do
    instance_double(Workspace::Config).tap do |c|
      allow(c).to receive(:agent_recovery_path) { |name| File.join(tmpdir, "#{name}-recovery.json") }
      allow(c).to receive(:inbox_path) { |scope, name| File.join(tmpdir, "inbox-#{scope}-#{name}.json") }
    end
  end
  let(:built) { [] }
  let(:desk_class) do
    record = built
    recording_desk_class = Class.new do
      def initialize(record) = @record = record

      def new(**kwargs)
        @record << kwargs
        :desk
      end
    end
    recording_desk_class.new(record)
  end
  let(:session_monitor) { instance_double(Workspace::SessionMonitor) }
  let(:claim) { ->(_pane_id) {} }
  let(:given) do
    {workspace: "myapp", session_name: "workspace-myapp", session_monitor: session_monitor, delivery_lock: Mutex.new,
     event_log: nil, restarting: ->(_pane_id) { false }, claim_restart: claim, release_restart: ->(_id, _token) {},
     rebind_queue: ->(_id, _pid) {}}
  end

  after { FileUtils.remove_entry(tmpdir) }

  def factory(**overrides)
    described_class.new(tmux: instance_double(Workspace::Tmux), config: config, recovery_config: recovery_config,
      agent_commands: agent_commands, process_tree: instance_double(Workspace::ProcessTree),
      ledger: instance_double(Workspace::SessionLedger), resume_command: instance_double(Workspace::AgentResumeCommand),
      readiness: instance_double(Workspace::AgentReadiness), marker: instance_double(Workspace::RecoveryStopMarker),
      logger: Workspace::Logger.new, error_output: StringIO.new, desk_class: desk_class, **overrides)
  end

  it "builds a desk for a Claude Code workspace with recovery on" do
    expect(factory.call(**given)).to eq(:desk)

    expect(built.size).to eq(1)
    expect(built.last).to include(workspace: "myapp", session_name: "workspace-myapp", session_monitor: session_monitor,
      detector: detector, claim_restart: claim)
    expect(agent_commands).to have_received(:detector).with("myapp")
  end

  it "builds no desk when recovery is off for the workspace" do
    allow(recovery_config).to receive(:enabled?).with("myapp").and_return(false)

    expect(factory.call(**given)).to be_nil
    expect(built).to be_empty
  end

  it "builds no desk when the workspace's agent is not Claude Code" do
    allow(agent_commands).to receive(:kind).with("myapp").and_return("codex")

    expect(factory.call(**given)).to be_nil
    expect(built).to be_empty
  end

  it "points the desk's inbox at the workspace's own inbox, made when the desk asks for it" do
    factory.call(**given)

    inbox = built.last[:inbox].call
    expect(inbox).to be_a(Workspace::InboxStore)
    expect(config).to have_received(:inbox_path).with("workspace", "myapp")
  end

  it "hands the desk the transcript reader and stopper it was given" do
    transcript = Object.new
    stopper = Object.new
    factory(transcript: transcript, stopper: stopper).call(**given)

    expect(built.last).to include(transcript: transcript, stopper: stopper)
  end

  it "reads transcripts with a TranscriptSummary and stops agents with an AgentStopper by default" do
    factory.call(**given)

    expect(built.last[:transcript]).to be_a(Workspace::TranscriptSummary)
    expect(built.last[:stopper]).to be_a(Workspace::AgentStopper)
  end

  it "builds the real AgentRecoveryDesk by default" do
    real = described_class.new(tmux: instance_double(Workspace::Tmux), config: config, recovery_config: recovery_config,
      agent_commands: agent_commands, process_tree: instance_double(Workspace::ProcessTree),
      ledger: instance_double(Workspace::SessionLedger), resume_command: instance_double(Workspace::AgentResumeCommand),
      readiness: instance_double(Workspace::AgentReadiness), marker: instance_double(Workspace::RecoveryStopMarker),
      logger: Workspace::Logger.new, error_output: StringIO.new)

    expect(real.call(**given)).to be_a(Workspace::AgentRecoveryDesk)
  end
end
