module Workspace
  # The writes a recovery entry gets from more than one part of the recovery
  # desk: the agent it stores, a give-up, a signal forgotten, the next attempt
  # scheduled, and the checks those writes share. Each write changes the entry
  # Hash it is given, in place, inside the caller's {AgentRecoveryStore#update},
  # and reads nothing but the entry and, where it says so, the clock.
  # {RecoveryIntake}, {RecoveryConfirmer} and {AgentRecoveryDesk} write through
  # these, so an entry is written one way whichever part writes it.
  module RecoveryEntry
    module_function

    # `agent_flags` describes the stored agent. A read of the same process
    # replaces them, and one that gave nil keeps them; any other process, or a
    # pid left blank, which can't be called the same process, gets exactly what
    # the read gave. No agent leaves them, for a `resume_only` once the process
    # is gone.
    #
    # @param entry [Hash] changed in place
    # @param live [Hash, nil] the agent read ({AgentStopper#find_agent}'s answer)
    # @return [void]
    def store_agent(entry, live)
      if live
        kept = entry["agent_flags"] if RecoveryVerdicts.same_process?(entry, live)
        entry["agent_flags"] = live[:flags] || kept
      end
      entry["agent_pid"] = live&.fetch(:pid)
      entry["agent_started"] = live&.fetch(:started)
    end

    # From the last read: an agent is ours to stop next time. An empty pane or a
    # failed read changes nothing, so `stopped` survives only where our signal
    # went out and no agent has come back since.
    #
    # @param entry [Hash] changed in place
    # @param live [Hash, nil, Symbol] the agent read; nil for none, +:unread+ when it couldn't be read
    # @return [void]
    def apply_read(entry, live)
      return unless live.is_a?(Hash)
      entry["stopped"] = false
      store_agent(entry, live)
    end

    # @param entry [Hash] changed in place
    # @param reason [String] the give-up reason
    # @return [void]
    def give_up(entry, reason)
      entry.merge!("phase" => "gave_up", "give_up_reason" => reason, "next_attempt_at" => nil, "defer_since" => nil)
    end

    # @param entry [Hash] changed in place
    # @return [void]
    def forget_signal(entry)
      entry["stopped"] = false
      entry["last_signal_at"] = nil
    end

    # Waits for the next attempt, or gives up once the attempts are used up.
    # The clock is read only when an attempt is scheduled.
    #
    # @param entry [Hash] changed in place
    # @param max_attempts [Integer] attempts after which the desk gives up
    # @param clock [#now]
    # @return [Boolean] whether this gave up, the attempts being used up
    def schedule_next(entry, max_attempts:, clock:)
      if entry["attempts"].to_i >= max_attempts
        give_up(entry, "attempts_exhausted")
        return true
      end
      next_at = AgentRecoveryStore.stamp(clock.now + AgentRecoveryStore.wait_before(entry["attempts"].to_i + 1))
      entry.merge!("phase" => "waiting", "next_attempt_at" => next_at, "last_turn_uuid" => nil, "defer_since" => nil)
      false
    end

    # @param entry [Hash]
    # @return [Boolean] whether nothing has been tried and no item waits on the
    #   entry, so it can go silently
    def unreported?(entry)
      entry["attempts"].to_i.zero? && entry["item_open"] != true
    end

    # Nothing is left to recover and no signal of ours explains why.
    #
    # @param entry [Hash]
    # @param live [Hash, nil, Symbol] the agent read; nil for none, +:unread+ when it couldn't be read
    # @return [Boolean]
    def agent_gone?(entry, live)
      live.nil? && entry["stopped"] != true
    end

    # Whether an entry is still the one a decision was made on: a hook may have
    # written between that read and this write.
    #
    # @param entry [Hash] the entry as it stands now
    # @param seen [Hash] the entry the decision read
    # @return [Boolean]
    def same_wait?(entry, seen)
      %w[phase session_id failed_at].all? { |key| entry[key] == seen[key] }
    end

    # The clock is read only for a signal time that parses.
    #
    # @param entry [Hash]
    # @param clock [#now]
    # @return [Boolean] whether our last signal is recent enough that its
    #   SessionEnd may still be on the way
    def signalled_lately?(entry, clock)
      signalled = RecoveryVerdicts.time_of(entry["last_signal_at"])
      !signalled.nil? && RecoveryVerdicts.signalled_lately?(signalled, clock.now)
    end
  end
end
