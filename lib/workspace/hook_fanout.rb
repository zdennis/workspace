module Workspace
  # The agent daemon's fan-out of one workspace's hook events: each `session_event` goes to the parts that
  # follow it in one fixed order, and the session monitor's after-scan call goes to the desks. Holds when the
  # main agent's current turn began in each pane, for the workflow nudger.
  class HookFanout
    # @param workspace [String] the workspace served, named to the workflow nudger
    # @param monitor [Workspace::SessionMonitor] records each hook event
    # @param hook_log [Workspace::HookEventLog, nil] writes each hook event; nil writes none
    # @param handoff_watcher [Workspace::HandoffWatcher, nil] sees each hook event first; nil watches nothing
    # @param nudger [Workspace::WorkflowNudger, nil] wakes a workflow run when a turn ends in its pane; nil wakes none
    # @param owner_report [Workspace::SpineOwnerReport, nil] reports a stage owner's finished turn; nil reports nothing
    # @param desks [Array<#session_event, #scan>] the queue desk then the recovery desk, nil ones left out
    # @param clock [#call] returns the current Time, for when a turn began
    # @param spawn [#call] runs the given block on its own thread (the owner report's)
    # @param logger [Workspace::Logger] debug logger
    def initialize(workspace:, monitor:, hook_log: nil, handoff_watcher: nil, nudger: nil, owner_report: nil, desks: [],
      clock: -> { Time.now }, spawn: ->(&work) { Thread.new(&work) }, logger: Workspace::Logger.new)
      @workspace = workspace
      @monitor = monitor
      @hook_log = hook_log
      @handoff_watcher = handoff_watcher
      @nudger = nudger
      @owner_report = owner_report
      @desks = desks.compact
      @clock = clock
      @spawn = spawn
      @logger = logger
      # When the main agent's current turn began, by pane id, for the workflow nudger.
      @turn_starts = {}
    end

    # Hands one hook event to the handoff watcher, the monitor, the hook log, the nudger and the owner report
    # (the last two for the main agent only), then each desk. A desk that raises stops the ones after it.
    #
    # @param message [Hash] the `session_event` message
    # @return [void]
    def session_event(message)
      # Before the monitor records it: a /clear moves the pane's session_id there, and a poll
      # in the gap would end the watch session_changed, not carried_out.
      notify_handoff_watcher(message)
      @monitor.record(message)
      @hook_log&.record(message)
      nudge_workflow(message) if @nudger && message["agent_id"].nil?
      report_owner_finished(message) if @owner_report && message["agent_id"].nil?
      @desks.each { |desk| desk.session_event(message) }
    end

    # The session monitor's after-scan call: every desk scans, and one that raises does not stop the others.
    #
    # @return [void]
    def scan_desks
      @desks.each do |desk|
        desk.scan
      rescue => e
        @logger.debug { "agent: #{desk.class.name.split("::").last} scan failed (#{e.class}: #{e.message})" }
      end
    end

    private

    # Shows a hook event to the handoff watcher. A failure there is logged and costs the monitor nothing.
    def notify_handoff_watcher(message)
      @handoff_watcher&.session_event(message)
    rescue => e
      @logger.debug { "handoff watcher: #{e.class}: #{e.message}" }
    end

    # The main agent's turn ended: a workflow run bound to the pane decides
    # its step now. The run is told when that turn began (the prompt that
    # started it), so a turn already under way when the step's line was
    # typed does not decide the step; a turn whose start this daemon did
    # not see is sent without one.
    def nudge_workflow(message)
      pane_id = message["pane_id"]
      case message["event"]
      when "user_prompt" then @turn_starts[pane_id] = @clock.call
      # A new conversation: a prompt this daemon then fails to see leaves no start, so its turn's end counts.
      when "session_start", "session_end" then @turn_starts.delete(pane_id)
      when "stop" then @nudger.turn_ended(@workspace, pane_id, turn_started: @turn_starts[pane_id], background: message["background_tasks"])
      end
    end

    # The main agent's turn ended (the Stop hook): a stage the pane owns is reported as finished.
    def report_owner_finished(message)
      return unless message["event"] == "stop"
      pane_id = message["pane_id"]
      @spawn.call { @owner_report.turn_ended(pane_id) }
    end
  end
end
