require "time"
require "digest"

module Workspace
  # The reads of {SessionMonitor}'s scan: the session's pane list, the
  # process table, each pane's captures, and the event log's history read
  # back after a daemon restart. {#refresh} brings one pane's record up to
  # date from them and asks {PaneScreenRules} what its screen says.
  #
  # It holds no panes and takes no lock: the monitor lists the panes and
  # snapshots the process table through it outside its lock, then calls
  # {#refresh} for each pane while it holds its own lock.
  #
  # It owns the alert history read back after a restart: the last alerts
  # logged per pane, read with the state history and handed out at each
  # pane's first refresh. The marks that history restores are written
  # through {PaneAlerts}, the one writer of alert marks.
  class PaneScanner
    # @param tmux [Workspace::Tmux] pane listing and capture
    # @param process_tree [Workspace::ProcessTree] process table snapshots
    # @param session_name [String] tmux session to watch
    # @param providers [Array<Workspace::AgentProvider>] agents to recognize
    # @param detector [#call] finds the agent in a pane
    # @param question_check [Workspace::QuestionClosedCheck] reads whether a
    #   question dialog is gone from a pane's screen
    # @param idle_after [Numeric] seconds of unchanged output before idle
    # @param clock [#now] time source for a wait a screen opens
    # @param logger [Workspace::Logger] debug logger
    # @param error_output [IO] where a question closed from the screen is reported
    # @param event_log [Workspace::EventLog, nil] where each pane's last logged
    #   state and alerts are read back from; nil reads no history
    # @param project [String] the name events are recorded under
    def initialize(tmux:, process_tree:, session_name:, providers:, detector:, question_check:,
      idle_after:, clock:, logger:, error_output:, event_log:, project:)
      @tmux = tmux
      @process_tree = process_tree
      @session_name = session_name
      @providers = providers
      @detector = detector
      @question_check = question_check
      @idle_after = idle_after
      @clock = clock
      @logger = logger
      @error_output = error_output
      @event_log = event_log
      @project = project
      @history = nil
      @alert_history = {}
    end

    # @return [Array<Hash>] the session's panes, as {Tmux#pane_details} lists them
    def pane_details
      @tmux.pane_details(@session_name)
    end

    # @return [Workspace::ProcessTree::Snapshot]
    # @raise [Workspace::Error] when the process table can't be read
    def process_snapshot
      @process_tree.snapshot
    end

    # Reads each pane's last logged state, and its last idle alert and last
    # waiting alert per agent, from the event log. Read once, on the first
    # call; nothing in the log is worth failing a scan over.
    #
    # @return [void]
    def load_history
      @history ||= read_history
      nil
    end

    # Brings one pane's record up to date: its logged state taken up after a
    # restart, its tmux fields, the agent in it, its activity, and what its
    # screen says about a screen wait, an answered permission dialog and a
    # question closed by Esc.
    #
    # @param pane [Hash] the pane's record, changed in place
    # @param detail [Hash] the pane's row from {#pane_details}
    # @param tree [Workspace::ProcessTree::Snapshot] from {#process_snapshot}
    # @param now [Time] the scan's time
    # @return [void]
    def refresh(pane, detail, tree, now)
      load_history
      restore_state(pane, detail) if @history.key?(detail[:id])
      pane[:index] = detail[:index]
      pane[:title] = detail[:title]
      pane[:cwd] = detail[:cwd]
      pane[:pid] = detail[:pid]

      agent = @detector.call(command: detail[:command], pid: detail[:pid], tree: tree, providers: @providers)
      pane[:kind] = agent ? agent[:provider].key : "shell"
      pane[:label] = agent ? agent[:provider].label : detail[:command]
      pane[:agent_pid] = agent && agent[:pid]
      # Nobody is left to answer a prompt once the agent has exited.
      unless agent
        PaneEvents.clear_waiting(pane)
        pane[:permission_requests].clear
        pane.delete(:done)
      end

      screen = refresh_activity(pane, now)
      provider = agent && agent[:provider]
      PaneScreenRules.screen_wait(pane, provider, screen, @clock.now)
      PaneScreenRules.end_answered_permission_waits(pane, provider, screen)
      refresh_question(pane, now)
      nil
    end

    private

    def read_history
      return {} unless @event_log
      @alert_history = @event_log.latest_agent_alerts(@project)
      @event_log.latest_agent_states(@project)
    rescue => e
      @logger.debug { "session monitor: could not read state history (#{e.class}: #{e.message})" }
      {}
    end

    # Takes up a pane's logged state after a daemon restart. The pane's pid is
    # checked too, since a restarted tmux server hands out the same pane ids
    # again. An idle pane stays idle, and keeps the time it went idle, until
    # its output changes. A quiet stretch or a wait the last daemon already
    # alerted for counts as alerted, so a restart doesn't send its alert again.
    def restore_state(pane, detail)
      logged = @history.delete(detail[:id])
      alerts = @alert_history.delete(detail[:id]) || {}
      return unless logged["pane_pid"] == detail[:pid] && !PaneStates::GONE_STATES.include?(logged["state"])
      since = Time.iso8601(logged["since"].to_s)
      pane[:logged_state] = logged["state"]
      pane[:state_since] = since
      # Read back, not seen: {SessionMonitor#fresh_since} waits for this monitor's own evidence.
      pane[:restored_ready] = true if %w[done idle].include?(logged["state"])
      case logged["state"]
      when "done" then restore_done(pane, detail, since, logged["stop_reason"], alerts["idle"])
      when "idle" then restore_idle(pane, detail, since, alerts["idle"])
      when "waiting" then PaneAlerts.restore_waits(pane, detail[:pid], since, alerts["waiting"] || {})
      end
    rescue ArgumentError
      nil
    end

    # A done pane still alerts for its quiet stretch, so the stretch the last
    # daemon already alerted for is not alerted for again.
    def restore_done(pane, detail, since, stop_reason, alert)
      pane[:done] = {since: since, stop_reason: stop_reason || "end_turn"}
      at = PaneAlerts.logged_time(alert, detail[:pid], "idle_since")
      return unless at

      pane[:last_activity_at] = at
      PaneAlerts.mark(pane, PaneAlerts::IDLE, at)
      pane[:quiet_since_restore] = true
    end

    def restore_idle(pane, detail, since, alert)
      pane[:last_activity_at] = since - @idle_after
      pane[:quiet_since_restore] = true
      at = PaneAlerts.logged_time(alert, detail[:pid], "idle_since")
      PaneAlerts.mark(pane, PaneAlerts::IDLE, pane[:last_activity_at]) if at && (at - pane[:last_activity_at]).abs < 0.002
    end

    # Output is hashed rather than compared: a pane's scrollback is large, and
    # only the fact that it changed matters.
    def refresh_activity(pane, now)
      screen = @tmux.capture_pane(@session_name, pane[:index]).to_s
      digest = Digest::SHA256.hexdigest(screen)

      if pane[:digest] != digest
        # The first capture after a restart is new to this monitor, not to the
        # pane: a pane restored as idle stays idle until its output changes.
        first_since_restore = pane[:digest].nil? && pane.delete(:quiet_since_restore)
        pane[:digest] = digest
        pane[:digest_seen_at] = now
        pane.delete(:own_quiet_at)
        pane[:last_activity_at] = now unless first_since_restore
      elsif pane[:restored_ready] && !pane[:own_quiet_at] && now - pane[:digest_seen_at] >= @idle_after
        # Two of this monitor's own scans, idle_after apart, saw the same screen.
        pane[:own_quiet_at] = now
      end
      pane[:last_activity_at] ||= now
      screen
    end

    # The styled capture is made only for a pane with a question tool open.
    def refresh_question(pane, now)
      tools = PaneScreenRules.question_tools(pane)
      reading = tools.empty? ? nil : @question_check.reading(pane[:kind], question_capture(pane))
      log_question_closed(pane) if PaneScreenRules.hold_question(pane, tools, reading, now)
    end

    # A failed capture proves nothing, so it reads as no screen.
    def question_capture(pane)
      @tmux.capture_screen_styled(pane[:pane_id])
    rescue => e
      @logger.debug { "session monitor: question capture failed in #{pane[:pane_id]} (#{e.class}: #{e.message})" }
      nil
    end

    def log_question_closed(pane)
      @error_output.puts "workspace agent: question closed in #{pane[:pane_id]} of #{@session_name}: its dialog is gone from the screen"
    rescue
      nil
    end
  end
end
