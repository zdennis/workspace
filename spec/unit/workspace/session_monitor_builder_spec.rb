require "spec_helper"

RSpec.describe Workspace::SessionMonitorBuilder do
  let(:tmux) do
    CLITestHelpers::FakeTmux.new.tap do |fake|
      fake.define_singleton_method(:session_name_for) { |name| "workspace-wt-#{name}" }
    end
  end
  let(:config) { instance_double(Workspace::Config, state_dir: "/state") }
  let(:error_output) { StringIO.new }
  let(:captured) { [] }
  let(:spy_factory) { ->(**kwargs) { captured << kwargs and :monitor } }
  let(:notifier_factory) { ->(_command) { raise "no notifier expected" } }
  let(:options) { {} }

  def builder(**overrides)
    described_class.new(tmux: tmux, config: config, logger: Workspace::Logger.new, error_output: error_output,
      notifier_factory: notifier_factory, ps_timeout: 10, monitor_factory: spy_factory,
      **options, **overrides)
  end

  def built(**overrides)
    builder(**overrides).call("myapp")
    captured.last
  end

  it "builds a real SessionMonitor by default" do
    monitor = described_class.new(tmux: tmux, config: config, logger: Workspace::Logger.new, error_output: error_output,
      notifier_factory: notifier_factory, ps_timeout: 10, scan_slots: instance_double(Workspace::ScanSlotLimiter)).call("myapp")

    expect(monitor).to be_a(Workspace::SessionMonitor)
  end

  it "monitors the tmux session and names the workspace" do
    expect(built).to include(session_name: "workspace-wt-myapp", project: "myapp", tmux: tmux)
  end

  it "passes its lock_reaper to the monitor" do
    lock_reaper = instance_double(Workspace::LockReaper, tick: 3)
    monitor = described_class.new(tmux: tmux, config: config, logger: Workspace::Logger.new, error_output: error_output,
      notifier_factory: notifier_factory, ps_timeout: 10, lock_reaper: lock_reaper,
      scan_slots: instance_double(Workspace::ScanSlotLimiter)).call("myapp")

    expect(monitor.reap_locks).to eq(3)
    expect(lock_reaper).to have_received(:tick)
  end

  it "builds the process tree with its ps_timeout" do
    trees = []
    factory = lambda do |**kwargs|
      trees << kwargs
      :tree
    end

    expect(built(process_tree_factory: factory)).to include(process_tree: :tree)
    expect(trees.last).to include(timeout: 10)
  end

  it "gives the monitor the workspace's configured scan interval" do
    agentd_config = instance_double(Workspace::AgentdConfig)
    allow(agentd_config).to receive(:poll_interval_for).with("myapp").and_return(45)

    expect(built(agentd_config: agentd_config)).to include(poll_interval: 45)
  end

  it "scans at the SessionMonitor default when no agentd config is wired" do
    expect(built).to include(poll_interval: Workspace::SessionMonitor::DEFAULT_POLL_INTERVAL)
  end

  it "gives the monitor a notifier and idle threshold from the workspace's alert config" do
    alert_config = instance_double(Workspace::AlertConfig)
    allow(alert_config).to receive(:for_workspace).with("myapp").and_return(notify: "say hi", idle_after: 900)
    notifier = instance_double(Workspace::Notifier)
    commands = []

    result = built(alert_config: alert_config, notifier_factory: ->(command) {
      commands << command
      notifier
    })

    expect(commands).to eq(["say hi"])
    expect(result).to include(notifier: notifier, idle_alert_after: 900)
    expect(alert_config).to have_received(:for_workspace).with("myapp")
  end

  it "builds no notifier when the workspace has no notify command" do
    alert_config = instance_double(Workspace::AlertConfig, for_workspace: {notify: nil, idle_after: 600})

    expect(built(alert_config: alert_config)).to include(notifier: nil, idle_alert_after: 600)
  end

  it "passes its scan_slots to the monitor" do
    scan_slots = instance_double(Workspace::ScanSlotLimiter)

    expect(built(scan_slots: scan_slots)).to include(scan_slots: scan_slots)
  end

  it "builds its default limiter under the config state dir when none is injected" do
    limiters = []
    factory = lambda do |**kwargs|
      limiters << kwargs
      :limiter
    end

    expect(built(scan_slots_factory: factory)).to include(scan_slots: :limiter)
    expect(limiters.last).to include(dir: File.join("/state", "scan-slots"))
  end

  describe "the configured agent names" do
    it "is built with the workspace's names, read when the monitor is made" do
      settings = instance_double(Workspace::ProjectSettings, load_global: {"agent" => {"commands" => {"claude" => "claude-dev"}}}, load: {})
      commands = Workspace::AgentCommands.new(config_resolver: Workspace::ConfigResolver.new(project_settings: settings))

      expect(built(agent_commands: commands)).to include(
        detector: Workspace::AgentDetector.new(aliases: {"claude" => ["claude-dev"]})
      )
    end

    it "knows only the providers' executables without AgentCommands" do
      expect(built).to include(detector: Workspace::AgentDetector.new)
    end
  end
end
