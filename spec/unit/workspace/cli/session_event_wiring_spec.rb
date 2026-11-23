require "spec_helper"
require "stringio"
require "tmpdir"

RSpec.describe Workspace::CLI::SessionEventWiring do
  let(:tmpdir) { Dir.mktmpdir }
  let(:config) do
    instance_double(Workspace::Config, state_dir: tmpdir, pane_bindings_path: File.join(tmpdir, "bindings.json"),
      workflow_runs_dir: File.join(tmpdir, "runs"), workflow_archive_dir: File.join(tmpdir, "archive"),
      workflow_event_errors_path: File.join(tmpdir, "event-errors.log"))
  end
  let(:tmux) { double("tmux") }
  let(:event_log) { double("event_log") }
  let(:logger) { Workspace::Logger.new }
  let(:policy) { double("permission_policy_config") }
  let(:composer) { double("instruction_composer") }
  let(:executable) { "/opt/workspace/bin/workspace" }
  let(:streams) { {input: StringIO.new, output: StringIO.new, error_output: StringIO.new} }
  let(:base) do
    {config: config, tmux: tmux, logger: logger, env: {"TMUX_PANE" => "%1"}, event_log: event_log,
     permission_policy_config: policy, instruction_composer: composer, executable: executable}.merge(streams)
  end
  let(:built) { {} }

  after { FileUtils.rm_rf(tmpdir) }

  def capture_session_event
    allow(Workspace::Commands::SessionEvent).to receive(:new) { |**kwargs| built.merge!(kwargs) && :command }
  end

  def stub_new(klass, name)
    recorded = {}
    allow(klass).to receive(:new) { |**kwargs| recorded.merge!(kwargs) && double(name) }
    recorded
  end

  it "builds every collaborator itself when nothing is shared, and returns the command" do
    capture_session_event
    config_names = double("config_names", available_projects: [])

    command = described_class.build(**base, lineage: double("lineage"), process_tree: double("process_tree"), config_names: config_names)

    expect(command).to eq(:command)
    expect(built).to include(config: config, tmux: tmux, logger: logger, permission_policy_config: policy, instruction_composer: composer, **streams)
    expect(built).not_to have_key(:env)
    expect(built[:lock_idle_tracker]).to be_a(Workspace::LockIdleTracker)
    expect(built[:lock_enforcer]).to be_a(Workspace::LockEnforcer)
    expect(built[:workflow_deny]).to be_a(Workspace::WorkflowDeny)
    expect(built[:review_write_guard]).to be_a(Workspace::ReviewWriteGuard)
    expect(built[:reflection_write_guard]).to be_a(Workspace::ReflectionWriteGuard)
    expect(built[:session_ledger]).to be_a(Workspace::SessionLedger)
    expect(built[:pane_bindings]).to be_a(Workspace::PaneBindings)
    expect(built[:delivery_log]).to be_a(Workspace::DeliveryLog)
    expect(built[:workspace_for_session]).to be_a(Workspace::SessionWorkspace)
    expect(built[:dev_session_release]).to be_a(Workspace::DevSessionRelease)
    expect(built[:hang_guard_counter]).to be_a(Workspace::HangGuardCounter)
    expect(built[:command_pieces]).to be_a(Workspace::BashCommandPieces)
  end

  it "builds the hang guard counter at state_dir/hang-guard.json, and shares one command cutter with the deny tripwire" do
    capture_session_event
    counter = stub_new(Workspace::HangGuardCounter, "counter")
    deny = stub_new(Workspace::WorkflowDeny, "deny")

    described_class.build(**base, lineage: double("lineage"), process_tree: double("process_tree"), config_names: double("config_names"))

    expect(counter).to eq(path: File.join(tmpdir, "hang-guard.json"))
    expect(built[:command_pieces]).to be(deny[:command_pieces])
  end

  it "passes a given hang guard counter through to the command" do
    capture_session_event
    counter = double("hang_guard_counter")

    described_class.build(**base, lineage: double("lineage"), process_tree: double("process_tree"), config_names: double("config_names"),
      hang_guard_counter: counter)

    expect(built[:hang_guard_counter]).to be(counter)
  end

  it "gives one built pane_bindings and the given tmux to the bound run and both write guards" do
    capture_session_event
    bound_run = stub_new(Workspace::BoundRun, "bound_run")
    review = stub_new(Workspace::ReviewWriteGuard, "review")
    reflection = stub_new(Workspace::ReflectionWriteGuard, "reflection")
    deny = stub_new(Workspace::WorkflowDeny, "deny")
    holder = stub_new(Workspace::LockHolder, "lock_holder")
    process_tree = double("process_tree")

    described_class.build(**base, lineage: double("lineage"), process_tree: process_tree, config_names: double("config_names"))

    bindings = built[:pane_bindings]
    expect([bound_run[:pane_bindings], review[:pane_bindings], reflection[:pane_bindings]]).to all(be(bindings))
    expect([bound_run[:tmux], review[:tmux], reflection[:tmux], holder[:tmux]]).to all(be(tmux))
    expect([review[:event_log], reflection[:event_log], deny[:event_log]]).to all(be(event_log))
    expect(holder[:process_tree]).to be(process_tree)
    expect(holder[:run_liveness]).to be_a(Workspace::RunLiveness)
    expect(deny[:run_store]).to be_a(Workspace::WorkflowRunStore)
    expect(deny[:command_pieces]).to be_a(Workspace::BashCommandPieces)
  end

  it "uses the objects build_cli shares instead of building its own" do
    capture_session_event
    shared = {pane_bindings: double("pane_bindings"), lock_namespace: double("lock_namespace"), lock_holder: double("lock_holder"),
              bound_run: double("bound_run"), run_store: double("run_store"), session_ledger: double("session_ledger"),
              recovery_stop_marker: double("recovery_stop_marker"), delivery_log: double("delivery_log"),
              workspace_for_session: double("workspace_for_session", ambiguous?: true)}
    [Workspace::PaneBindings, Workspace::LockNamespace, Workspace::LockHolder, Workspace::BoundRun, Workspace::WorkflowRunStore,
      Workspace::SessionLedger, Workspace::RecoveryStopMarker, Workspace::DeliveryLog, Workspace::SessionWorkspace].each do |klass|
      expect(klass).not_to receive(:new)
    end
    tracker = stub_new(Workspace::LockIdleTracker, "tracker")
    enforcer = stub_new(Workspace::LockEnforcer, "enforcer")
    deny = stub_new(Workspace::WorkflowDeny, "deny")
    review = stub_new(Workspace::ReviewWriteGuard, "review")
    reflection = stub_new(Workspace::ReflectionWriteGuard, "reflection")
    release = stub_new(Workspace::DevSessionRelease, "release")

    described_class.build(**base, **shared)

    expect([tracker, enforcer].map { |kw| [kw[:lock_namespace], kw[:lock_holder]] }).to all(eq([shared[:lock_namespace], shared[:lock_holder]]))
    expect(deny).to include(bound_run: shared[:bound_run], run_store: shared[:run_store])
    expect([review[:pane_bindings], reflection[:pane_bindings], built[:pane_bindings]]).to all(be(shared[:pane_bindings]))
    expect(built).to include(session_ledger: shared[:session_ledger], delivery_log: shared[:delivery_log], workspace_for_session: shared[:workspace_for_session])
    expect(built[:session_ambiguous].call("proj")).to be(true)
    expect(release).to include(executable: executable, recovery_marker: shared[:recovery_stop_marker], config: config)
  end

  {lineage: :lock_namespace, process_tree: :lock_holder, config_names: :workspace_for_session}.each do |input, built_from_it|
    it "refuses to build without #{input} when #{built_from_it} is not given either" do
      inputs = {lineage: double("lineage"), process_tree: double("process_tree"), config_names: double("config_names")}.except(input)

      expect { described_class.build(**base, **inputs) }.to raise_error(ArgumentError, /needs #{input}: when #{built_from_it}: is not given/)
    end
  end

  it "records a session two configs claim in the delivery log it built" do
    capture_session_event
    allow(tmux).to receive(:session_option).and_return(nil)
    allow(tmux).to receive(:session_name_for).and_return("proj")

    described_class.build(**base, lineage: double("lineage"), process_tree: double("process_tree"),
      config_names: double("config_names", available_projects: %w[proj-a proj-b]))

    expect(built[:workspace_for_session].call("proj")).to eq("proj-a")
    expect(built[:session_ambiguous].call("proj")).to be(true)
    expect(File.read(File.join(tmpdir, "session-event.log"))).to include("ambiguous session=proj claimed by configs proj-a, proj-b; using proj-a")
  end
end
