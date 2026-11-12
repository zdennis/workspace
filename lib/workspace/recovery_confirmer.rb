module Workspace
  # The recovery desk's confirmation of what its entries say, run from the
  # monitor's scan: it marks again the panes that had failed when the desk
  # started ({#mark_failed_panes}), reads what a waiting entry's settle period
  # was waiting for ({#settle}), and picks up an attempt the daemon lost when it
  # restarted ({#reconcile}). Nothing is decided on a read that can't be made;
  # the next scan tries again.
  #
  # A clear, a give-up and a resolved item go through the callables it is given,
  # after the {AgentRecoveryStore#update} that decided them.
  class RecoveryConfirmer
    # Seconds after the failure before the transcript is read: Claude Code may
    # still recover by itself, and the error line may follow the hook.
    SETTLE = 30

    # Event log line for a finished attempt.
    ATTEMPT_EVENT = "agent_recovery_attempt"

    # @param workspace [String] the workspace the daemon serves; event lines go under it
    # @param store [Workspace::AgentRecoveryStore] the workspace's recovery entries
    # @param facts [Workspace::RecoveryFacts] reads the pane, the agent, the transcript and the ledger
    # @param session_monitor [Workspace::SessionMonitor] names a pane's kind and marks its failed turn
    # @param marker [Workspace::RecoveryStopMarker] says a stop is ours
    # @param clear [#call] given a pane id and the entry read, acts on a `:clear`
    # @param report_give_up [#call] given a pane id and the stored entry, reports a give-up
    # @param resolve [#call] given a session id, resolves its inbox item
    # @param event_log [Workspace::EventLog, nil] where an interrupted attempt is recorded
    # @param max_attempts [Integer] attempts after which a lost attempt gives up
    # @param clock [#now] time source
    def initialize(workspace:, store:, facts:, session_monitor:, marker:, clear:, report_give_up:, resolve:, event_log: nil,
      max_attempts: AgentRecoveryStore::MAX_ATTEMPTS, clock: Time)
      @workspace = workspace
      @store = store
      @facts = facts
      @session_monitor = session_monitor
      @marker = marker
      @clear = clear
      @report_give_up = report_give_up
      @resolve = resolve
      @event_log = event_log
      @max_attempts = max_attempts
      @clock = clock
      @unmarked = nil
    end

    # The monitor's failed-turn flag isn't persisted, so the panes failed when
    # this desk started are marked again. Marking does nothing for a pane the
    # monitor doesn't know yet, so those stay listed for the next scan. Only
    # the first call lists panes: a later failure's flag came from its hook,
    # and a prompt may have cleared it since.
    #
    # @param entries [Hash{String=>Hash}] the store's entries, as this scan read them
    # @return [void]
    def mark_failed_panes(entries)
      @unmarked ||= entries.select { |_, entry| failed_turn_stands?(entry) }.keys
      @unmarked = @unmarked.select { |pane_id| entries[pane_id] && failed_turn_stands?(entries[pane_id]) }
      @unmarked.reject! do |pane_id|
        known = !@session_monitor.pane_kind(pane_id).nil?
        @session_monitor.mark_turn_failed(pane_id) if known
        known
      end
      nil
    end

    # Reads what the settle period was waiting for, once {SETTLE} seconds have
    # passed since the failure. A transcript or ledger that can't be read yet is
    # left for the next scan.
    #
    # @param pane_id [String]
    # @param entry [Hash] the pane's waiting entry
    # @return [Hash, nil] the entry as it now stands; nil when it was cleared
    def settle(pane_id, entry)
      failed = RecoveryVerdicts.time_of(entry["failed_at"])
      return entry unless failed && @clock.now - failed >= SETTLE

      found = {}
      unless entry["last_turn_uuid"]
        record = @facts.transcript_error(entry)
        if record && !record["api_error"]
          @clear.call(pane_id, entry)
          return nil
        end
        found["last_turn_uuid"] = record["uuid"] if record
      end
      live = @facts.live_agent(pane_id) unless entry["agent_pid"]
      unless entry["cwd"]
        opened = @facts.ledger_session(pane_id)
        if opened.is_a?(Hash)
          if opened["session_id"] != entry["session_id"]
            @clear.call(pane_id, entry)
            return nil
          end
          found["cwd"] = opened["cwd"]
        end
      end
      found.compact!
      return entry if found.empty? && !live
      @store.update(pane_id) do |current|
        next unless RecoveryEntry.same_wait?(current, entry)
        current.merge!(found)
        RecoveryEntry.store_agent(current, live) if live && current["agent_pid"].nil?
      end
    end

    # Picks up an attempt the daemon lost by restarting: says so, then looks at
    # the pane. Nothing is decided on a pane or process table that can't be
    # read; the next scan tries again. A closed pane has no ledger to read:
    # `open_record` could only answer `:unreadable` for it, on every scan. It
    # keeps the marker, because that read can be wrong. `stopped` true with no
    # agent still resumes; {AgentRecoveryDesk#check} refuses if the ledger shows
    # a new agent came and went, and defers on a closed pane until the defer
    # limit ends it.
    #
    # @param pane_id [String] a pane whose entry is `attempting` and no claim holds
    # @return [void]
    def reconcile(pane_id)
      detail = @facts.pane_detail(pane_id)
      return if detail == :unknown
      if detail
        reading = @facts.agent(detail)
        return unless reading
        agent = reading.found
      else
        return unless @facts.tree
      end

      opened = detail && @facts.ledger_session(pane_id)
      return if opened == :unreadable

      open_session = opened&.fetch("session_id")
      seen = nil
      gave_up = false
      finished = false
      stored = @store.update(pane_id) do |entry|
        next unless entry["phase"] == "attempting"
        seen = entry.dup
        finished = entry["turn_completed"] == true || entry["resumed_elsewhere"] == true
        next entry.clear if finished
        gave_up = reconcile_entry(entry, open_session, agent)
      end
      return unless seen

      record_interrupted(pane_id, seen)
      # A live agent may still exit from our signal: its marker is left to expire.
      @marker.clear(seen["session_id"]) if detail && !agent
      @resolve.call(seen["session_id"]) if finished
      @report_give_up.call(pane_id, stored) if gave_up
      nil
    end

    private

    # Skips a `fresh_conversation` record: that pane holds a healthy agent.
    def failed_turn_stands?(entry)
      %w[waiting attempting].include?(entry["phase"]) ||
        (entry["phase"] == "gave_up" && entry["give_up_reason"] != "fresh_conversation")
    end

    # @return [Boolean] whether this gave up
    def reconcile_entry(entry, open_session, agent)
      failed = entry.delete("failed_during_attempt") == true
      %w[turn_completed attempt_session_id prompt_seen].each { |key| entry.delete(key) }
      if open_session && open_session != entry["session_id"]
        RecoveryEntry.give_up(entry, "fresh_conversation")
        return true
      end
      if failed && !RecoveryEntry::RETRYABLE_ERRORS.include?(entry["error"])
        RecoveryEntry.give_up(entry, "not_retryable")
        return true
      end

      RecoveryEntry.apply_read(entry, agent)
      entry["failed_at"] = AgentRecoveryStore.stamp(@clock.now) if failed
      if RecoveryEntry.agent_gone?(entry, agent)
        RecoveryEntry.give_up(entry, "unconfirmed")
        return true
      end
      RecoveryEntry.schedule_next(entry, max_attempts: @max_attempts, clock: @clock)
    end

    def record_interrupted(pane_id, entry)
      attempt = entry["attempts"].to_i
      data = {"attempt" => attempt, "session_id" => entry["session_id"], "pane_id" => pane_id, "error" => entry["error"],
              "mode" => (attempt == 1) ? "typed" : "restart", "outcome" => "interrupted"}
      @event_log&.record(type: ATTEMPT_EVENT, project: @workspace, data: data)
    end
  end
end
