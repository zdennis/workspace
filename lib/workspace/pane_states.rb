module Workspace
  # The state rules of {SessionMonitor}: what state a pane is in, since when,
  # and what changed since the state last logged. A pane is the symbol-keyed
  # Hash {PaneEvents.new_pane} builds.
  #
  # Nothing here takes a lock, reads the clock or does I/O: the time comes in
  # as +now+, the seconds of unchanged output before idle as +idle_after+,
  # and the monitor calls these while it holds its own lock. Only
  # {.state_change} and {.gone_change} write, and only the pane's logged
  # state.
  module PaneStates
    # Kinds that are not a coding agent.
    NOT_AGENTS = ["shell", "unknown"].freeze

    # Logged states that mean the pane no longer has an agent.
    GONE_STATES = ["closed", "exited"].freeze

    module_function

    # @param pane [Hash]
    # @param idle_for [Numeric] seconds since the pane's output last changed
    # @param idle_after [Numeric] seconds of unchanged output before idle
    # @return [String] "waiting", "working" or "idle", by waits and activity
    def state_of(pane, idle_for, idle_after)
      return "waiting" unless pane[:waits].empty?
      (idle_for < idle_after) ? "working" : "idle"
    end

    # What `sessions` reports. A finished turn is "done" whatever the screen
    # or a late idle notification says; {.state_of} keeps going by activity
    # and waits.
    #
    # @param pane [Hash]
    # @param idle_for [Numeric]
    # @param idle_after [Numeric]
    # @return [String] "done", or {.state_of}
    def reported_state(pane, idle_for, idle_after)
      pane[:done] ? "done" : state_of(pane, idle_for, idle_after)
    end

    # The pane reports its longest wait, so the time shown is how long a
    # person has been keeping some agent in it waiting.
    #
    # @param pane [Hash]
    # @return [Hash, nil] the wait with the earliest +:since+
    def oldest_wait(pane)
      pane[:waits].values.min_by { |wait| wait[:since] }
    end

    # When the pane entered +state+: a wait from when it was raised, idle from
    # when the output had been quiet long enough, working from its last change.
    #
    # @param pane [Hash]
    # @param state [String] a state {.reported_state} answered
    # @param now [Time]
    # @param idle_after [Numeric]
    # @return [Time]
    def since_for(pane, state, now, idle_after)
      case state
      when "done" then pane[:done][:since]
      when "waiting" then oldest_wait(pane)[:since]
      when "idle" then pane[:last_activity_at] + idle_after
      else pane[:last_activity_at] || now
      end
    end

    # {SessionMonitor#fresh_since} for one pane.
    #
    # @param pane [Hash]
    # @param now [Time]
    # @param idle_after [Numeric]
    # @return [Time, nil]
    def fresh_since(pane, now, idle_after)
      return nil if NOT_AGENTS.include?(pane[:kind]) || !pane[:waits].empty?
      state = reported_state(pane, now - (pane[:last_activity_at] || now), idle_after)
      return nil unless %w[done idle].include?(state)
      return pane[:own_quiet_at] if pane[:restored_ready]
      return pane[:done][:since] if state == "done"
      pane[:last_activity_at] && pane[:last_activity_at] + idle_after
    end

    # @param pane [Hash]
    # @return [String, nil] the first thing that keeps the main agent's turn
    #   from being proven over, by the name {SessionMonitor#main_turn_evidence}
    #   gives it; nil when it is proven over
    def main_turn_missing(pane)
      return "not_claude" unless pane[:kind] == "claude"
      return "no_hooks" unless pane[:hook_kind] == "claude"
      return "no_stop_seen" unless pane[:main_stopped_at]
      return PaneEvents::MAIN_ACTIVITY.fetch(pane[:main_active_event]) if pane[:main_active_at]
      return "turn_failed" if pane[:turn_failed]
      return "waiting" unless pane[:waits].empty?
      "open_tool" unless pane[:open_tools].to_h.empty?
    end

    # The change to record when an agent pane's state differs from the one
    # last recorded, or nil. Keeps the pane's record up to date as it goes.
    #
    # @param pane [Hash] the pane's record; its logged state is changed in place
    # @param now [Time]
    # @param idle_after [Numeric]
    # @return [Hash, nil] the `agent_state` event data
    def state_change(pane, now, idle_after)
      return nil if pane[:kind] == "unknown"
      return gone_change(pane, "exited", now) if pane[:kind] == "shell"
      state = reported_state(pane, now - (pane[:last_activity_at] || now), idle_after)
      return nil if state == pane[:logged_state]
      mark_state(pane, state, since_for(pane, state, now, idle_after))
    end

    # @param pane [Hash] the pane's record; its logged state is changed in place
    # @param state [String] one of {GONE_STATES}
    # @param now [Time]
    # @return [Hash, nil] the `agent_state` event data, or nil when no state
    #   was logged or the pane is already gone
    def gone_change(pane, state, now)
      return nil if pane[:logged_state].nil? || GONE_STATES.include?(pane[:logged_state])
      mark_state(pane, state, now)
    end

    def mark_state(pane, state, since)
      pane[:logged_state] = state
      pane[:state_since] = since
      {"pane_id" => pane[:pane_id], "pane_pid" => pane[:pid], "index" => pane[:index],
       "kind" => pane[:kind], "state" => state, "since" => since.utc.iso8601(3),
       "stop_reason" => pane[:done] && pane[:done][:stop_reason]}.compact
    end
    private_class_method :mark_state
  end
end
