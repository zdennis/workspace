module Workspace
  # The writes a recovery entry gets from more than one part of the recovery
  # desk: the agent it stores, a give-up, a signal forgotten, the next attempt
  # scheduled, and the checks those writes share. Each write changes the entry
  # Hash it is given, in place, inside the caller's {AgentRecoveryStore#update},
  # and reads nothing but the entry and, where it says so, the clock.
  # {RecoveryIntake}, {RecoveryConfirmer} and {RecoveryOutcomes} write through
  # these, so an entry is written one way whichever part writes it.
  module RecoveryEntry
    # The `error` kinds that go on the attempt schedule; any other gives up at once.
    RETRYABLE_ERRORS = %w[server_error overloaded rate_limit unknown].freeze

    module_function

    # Applies one failed turn to an entry, inside the caller's {AgentRecoveryStore#update}.
    #
    # @param entry [Hash] the pane's entry, changed in place
    # @param session_id [String] the session that failed
    # @param error [String, nil] the error kind
    # @param transcript_path [String, nil] the hook's transcript path
    # @param live [Hash, nil] {AgentStopper#find_agent}'s answer, read before the update
    # @param max_attempts [Integer] attempts after which a failure gives up
    # @param clock [#now]
    # @return [Boolean] whether this gave up, which the caller reports after the update
    def apply_failure(entry, session_id, error, transcript_path, live, max_attempts:, clock:)
      same = entry["session_id"] == session_id
      if entry["phase"] == "attempting"
        if same
          entry["failed_during_attempt"] = true
          entry["error"] = error
        end
        return false
      end

      unless RETRYABLE_ERRORS.include?(error)
        return false if same && entry["phase"] == "gave_up" && entry["give_up_reason"] != "not_retryable"
        entry.clear unless same
        fill(entry, session_id, error, transcript_path)
        give_up(entry, "not_retryable")
        return true
      end

      return false unless transcript_path.is_a?(String) && !transcript_path.empty?
      entry.clear unless same
      if entry["phase"] == "gave_up"
        return false unless reopens?(entry, live)
        entry["stopped"] = false
        entry["last_signal_at"] = nil
        entry["give_up_reason"] = nil
        entry["item_open"] = true
        entry["item_error"] = entry["error"]
      end
      fill(entry, session_id, error, transcript_path)
      schedule_failure(entry, live, max_attempts: max_attempts, clock: clock)
    end

    # Whether a stopped entry's agent has been replaced. The stopped process
    # itself doesn't count: after a signal that didn't stop it, its late hooks
    # must not end the recovery, and a pid that was never read proves nothing.
    #
    # @param entry [Hash]
    # @param live [Hash, nil] the agent read
    # @return [Boolean]
    def agent_came_back?(entry, live)
      entry["stopped"] == true && %w[waiting watching].include?(entry["phase"]) && other_agent?(entry, live)
    end

    # A pid that was never read proves nothing.
    #
    # @param entry [Hash]
    # @param live [Hash, nil] the agent read
    # @return [Boolean] whether the agent read is another process than the stored one
    def other_agent?(entry, live)
      return false unless live && !entry["agent_pid"].nil?
      !RecoveryVerdicts.same_process?(entry, live)
    end

    # A retryable failure can follow a give-up that said nothing about the API
    # any more. An `unconfirmed` one needs a live agent: someone resumed the
    # session, and with no agent the failure is a late line from one that left.
    # The count is kept, so {AgentRecoveryStore::MAX_ATTEMPTS} still ends it.
    def reopens?(entry, live)
      entry["give_up_reason"] == "not_retryable" || (entry["give_up_reason"] == "unconfirmed" && !live.nil?)
    end

    def fill(entry, session_id, error, transcript_path)
      entry["session_id"] = session_id
      entry["error"] = error
      entry["transcript_path"] = transcript_path || entry["transcript_path"]
      entry["attempts"] = entry["attempts"].to_i
      entry["stopped"] = entry["stopped"] == true
    end

    # @return [Boolean] whether this gave up
    def schedule_failure(entry, live, max_attempts:, clock:)
      return true if schedule_next(entry, max_attempts: max_attempts, clock: clock)

      entry["failed_at"] = AgentRecoveryStore.stamp(clock.now)
      entry["draft_text"] = nil
      entry["stopped"] = false if agent_came_back?(entry, live)
      store_agent(entry, live) if live || entry["stopped"] != true
      false
    end
    private_class_method :reopens?, :fill, :schedule_failure

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
