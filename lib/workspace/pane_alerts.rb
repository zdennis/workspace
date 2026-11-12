require "time"

module Workspace
  # The alert rules of {SessionMonitor}: which alerts a pane has due, the
  # environment each one hands the notify command, the event logged once it
  # is sent, and the marks that keep one wait or one quiet stretch from
  # alerting twice. A pane is the symbol-keyed Hash {PaneEvents.new_pane}
  # builds.
  #
  # Nothing here takes a lock, reads the clock or does I/O. The monitor
  # works out what is due and sends it, then marks each alert sent by its
  # {Due#key}, +[pane_id, wait_key]+, on the pane it finds under that id
  # while it holds its lock again, and stores the marked pane {.mark}
  # answers under that id; no Hash is changed in place. The marks a restart
  # reads back from the event log are made here too ({.restore_waits},
  # {.logged_time} with {.mark}); {PaneScanner}
  # owns that read and the alert history it holds until each pane's first
  # refresh.
  module PaneAlerts
    # The +wait_key+ of a pane's quiet stretch. A wait's key is its agent
    # id, a String or nil (the main agent), so it never equals this.
    IDLE = :idle

    # One alert due: +key+ is +[pane_id, wait_key]+, +value+ what {.mark}
    # writes once it is sent (the wait's start, or the quiet stretch's),
    # +env+ the notify command's environment and +logged+ the `agent_alert`
    # event's data.
    Due = Data.define(:key, :value, :env, :logged)

    module_function

    # The alerts a pane has due. Each wait alerts on its own, so a second
    # agent in the pane starting to wait alerts even though the pane was
    # already waiting. With no wait, the pane alerts once per quiet stretch
    # past +idle_alert_after+, unless the activity is +stale+. Shell panes
    # never alert.
    #
    # @param pane [Hash]
    # @param now [Time]
    # @param session_name [String] the tmux session the alert names
    # @param idle_alert_after [Numeric, nil] seconds of idle before an idle
    #   alert; nil sends none
    # @param stale [Boolean] whether the last scan failed to capture the
    #   panes' output, which holds back idle alerts
    # @return [Array<Due>]
    def due(pane, now, session_name:, idle_alert_after:, stale:)
      return [] if PaneStates::NOT_AGENTS.include?(pane[:kind])

      unless pane[:waits].empty?
        return pane[:waits].reject { |_, wait| wait[:alerted] }.map do |agent_id, wait|
          Due.new(key: [pane[:pane_id], agent_id], value: wait[:since],
            env: env(pane, "waiting", now - wait[:since], wait[:message], session_name: session_name),
            logged: waiting_data(pane, agent_id, wait))
        end
      end

      return [] if stale || !idle_alert_after || !pane[:last_activity_at]
      idle_for = now - pane[:last_activity_at]
      return [] if idle_for < idle_alert_after || pane[:alerted_idle_since] == pane[:last_activity_at]
      [Due.new(key: [pane[:pane_id], IDLE], value: pane[:last_activity_at],
        env: env(pane, "idle", idle_for, nil, session_name: session_name),
        logged: idle_data(pane, pane[:last_activity_at]))]
    end

    # Marks one alert sent. {IDLE} marks the quiet stretch that began at
    # +value+. A wait key marks the wait open under it, if it is still the
    # one that began at +value+; a wait ended and begun again since is a new
    # wait and stays unmarked.
    #
    # @param pane [Hash] the pane the alert's key names, left unchanged
    # @param wait_key [Symbol, String, nil] {IDLE} or the wait's agent id
    # @param value [Time] the start of the wait or stretch
    # @return [Hash] the pane marked, a new Hash; +pane+ itself when there is
    #   nothing to mark
    def mark(pane, wait_key, value)
      if wait_key == IDLE
        pane.merge(alerted_idle_since: value)
      elsif (wait = pane[:waits][wait_key]) && wait[:since] == value
        pane.merge(waits: pane[:waits].merge(wait_key => wait.merge(alerted: true)))
      else
        pane
      end
    end

    # Remembers, per agent, each wait in the pane's logged waiting stretch
    # that the last daemon alerted for. The agent's next notification takes
    # that wait up again, already alerted, unless another hook event from
    # the agent ends it first. A notification that arrived before this first
    # scan is taken up here.
    #
    # @param pane [Hash] left unchanged
    # @param pane_pid [Integer] the pane's process now
    # @param stretch_since [Time] when the logged waiting stretch began
    # @param alerts [Hash{String, nil => Hash}] the last waiting alert logged
    #   per agent id
    # @return [Hash] the pane with the waits taken up, a new Hash; +pane+
    #   itself when there is nothing to take up
    def restore_waits(pane, pane_pid, stretch_since, alerts)
      alerts.reduce(pane) do |restored, (agent_id, alert)|
        waiting_since = logged_time(alert, pane_pid, "waiting_since")
        next restored unless waiting_since && waiting_since - stretch_since > -0.002
        if (wait = restored[:waits][agent_id])
          next restored if wait[:alerted]
          restored.merge(waits: restored[:waits].merge(agent_id => wait.merge(since: waiting_since, alerted: true)))
        else
          restored.merge(alerted_waits: (restored[:alerted_waits] || {}).merge(agent_id => waiting_since))
        end
      end
    end

    # @param alert [Hash, nil] a logged `agent_alert` event's data
    # @param pane_pid [Integer] the pane's process now
    # @param key [String] the time field to read
    # @return [Time, nil] the time logged under +key+ (to the millisecond) of
    #   an alert sent for this pane process, or nil
    def logged_time(alert, pane_pid, key)
      return nil unless alert && alert["pane_pid"] == pane_pid
      Time.iso8601(alert[key].to_s)
    rescue ArgumentError
      nil
    end

    # The notify command's environment. NUL bytes are taken out of every
    # value.
    #
    # @param pane [Hash]
    # @param alert [String] "waiting", "idle" or "handoff_stalled"
    # @param seconds [Numeric] how long the pane has waited or been idle
    # @param message [String, nil] the wait's message
    # @param session_name [String]
    # @param followups [Integer, nil] follow-ups sent, for "handoff_stalled"
    # @return [Hash{String => String}]
    def env(pane, alert, seconds, message, session_name:, followups: nil)
      where = "#{session_name} pane 0.#{pane[:index]} (#{pane[:label]})"
      text = if alert == "waiting"
        "#{where} is waiting#{": #{message}" if message}"
      elsif alert == "handoff_stalled"
        "#{where} has not handed off after #{followups} follow-ups"
      else
        "#{where} has been idle for #{Duration.humanize(seconds)}"
      end
      {
        "WORKSPACE_ALERT" => alert,
        "WORKSPACE_ALERT_WORKSPACE" => session_name,
        "WORKSPACE_ALERT_PANE" => "0.#{pane[:index]}",
        "WORKSPACE_ALERT_PANE_ID" => pane[:pane_id].to_s,
        "WORKSPACE_ALERT_KIND" => pane[:kind].to_s,
        "WORKSPACE_ALERT_SECONDS" => seconds.round.to_s,
        "WORKSPACE_ALERT_MESSAGE" => message.to_s,
        "WORKSPACE_ALERT_TEXT" => text
      }.transform_values { |value| value.delete("\0") }
    end

    # @param pane [Hash]
    # @param idle_since [Time]
    # @return [Hash] the `agent_alert` data of an idle alert
    def idle_data(pane, idle_since)
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "kind" => "idle",
       "idle_since" => idle_since.utc.iso8601(3)}
    end

    # @param pane [Hash]
    # @param agent_id [String, nil]
    # @param wait [Hash]
    # @return [Hash] the `agent_alert` data of a waiting alert
    def waiting_data(pane, agent_id, wait)
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "kind" => "waiting",
       "agent_id" => agent_id, "waiting_since" => wait[:since].utc.iso8601(3)}
    end
  end
end
