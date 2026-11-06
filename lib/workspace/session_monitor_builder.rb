# frozen_string_literal: true

module Workspace
  # Builds the {Workspace::SessionMonitor} an agent daemon runs for one
  # workspace from the daemon's settings. Alert and scan settings are read once,
  # when {#call} runs, so a change takes effect the next time the daemon starts.
  class SessionMonitorBuilder
    # @param tmux [Workspace::Tmux]
    # @param config [Workspace::Config] gives the state directory for the default scan slot limiter
    # @param logger [#debug]
    # @param error_output [IO]
    # @param agent_commands [Workspace::AgentCommands, nil] names the agent programs per workspace; nil knows only the providers' own
    # @param alert_config [Workspace::AlertConfig, nil]
    # @param agentd_config [Workspace::AgentdConfig, nil]
    # @param lock_reaper [Workspace::LockReaper, nil]
    # @param notifier_factory [#call] given a notify command, returns the notifier
    # @param ps_timeout [Numeric] limit for the process snapshot
    # @param event_log [Workspace::EventLog, nil]
    # @param context_reader [Workspace::ContextReader, nil]
    # @param label_reader [#call, nil]
    # @param task_store [Workspace::TaskStore, nil]
    # @param scan_slots [Workspace::ScanSlotLimiter, nil] nil builds one under the config's state directory
    # @param monitor_factory [#call] receives the monitor's keyword arguments (default +SessionMonitor.new+)
    # @param process_tree_factory [#call] receives +logger:+ and +timeout:+ (default +ProcessTree.new+)
    # @param scan_slots_factory [#call] receives +dir:+ and +logger:+ for the default limiter (default +ScanSlotLimiter.new+)
    def initialize(tmux:, config:, logger:, error_output:, notifier_factory:, ps_timeout:, agent_commands: nil,
      alert_config: nil, agentd_config: nil, lock_reaper: nil, event_log: nil, context_reader: nil,
      label_reader: nil, task_store: nil, scan_slots: nil, monitor_factory: SessionMonitor.method(:new),
      process_tree_factory: ProcessTree.method(:new), scan_slots_factory: ScanSlotLimiter.method(:new))
      @tmux = tmux
      @config = config
      @logger = logger
      @error_output = error_output
      @agent_commands = agent_commands
      @alert_config = alert_config
      @agentd_config = agentd_config
      @lock_reaper = lock_reaper
      @notifier_factory = notifier_factory
      @ps_timeout = ps_timeout
      @event_log = event_log
      @context_reader = context_reader
      @label_reader = label_reader
      @task_store = task_store
      @scan_slots = scan_slots
      @monitor_factory = monitor_factory
      @process_tree_factory = process_tree_factory
      @scan_slots_factory = scan_slots_factory
    end

    # @param name [String] the workspace name
    # @return [Workspace::SessionMonitor]
    def call(name)
      alerts = @alert_config&.for_workspace(name) || {}
      notifier = alerts[:notify] && @notifier_factory.call(alerts[:notify])
      @monitor_factory.call(
        tmux: @tmux,
        process_tree: @process_tree_factory.call(logger: @logger, timeout: @ps_timeout),
        session_name: @tmux.session_name_for(name),
        detector: @agent_commands&.detector(name) || AgentDetector.new,
        poll_interval: @agentd_config&.poll_interval_for(name) || SessionMonitor::DEFAULT_POLL_INTERVAL,
        logger: @logger,
        error_output: @error_output,
        lock_reaper: @lock_reaper,
        notifier: notifier,
        idle_alert_after: alerts[:idle_after],
        event_log: @event_log,
        project: name,
        context_reader: @context_reader,
        label_reader: @label_reader,
        task_reader: @task_store && ->(workspace) { @task_store.active_for(workspace) },
        scan_slots: @scan_slots || @scan_slots_factory.call(
          dir: File.join(@config.state_dir, "scan-slots"),
          logger: @logger
        )
      )
    end
  end
end
