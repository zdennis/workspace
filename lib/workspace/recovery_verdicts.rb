module Workspace
  # The decisions {AgentRecoveryDesk#check} makes at each stage, over values it
  # has already read: an entry Hash, an agent Hash, a screen, a transcript
  # record, a ledger record, a Time. Nothing here reads a file, a process, a
  # pane or the clock, so the desk keeps its reads, in their order, and only
  # asks these what they mean.
  #
  # A method ending in `?` answers a Boolean; one ending in `_verdict` answers
  # +:defer+, +:clear+ or +:never+, or nil when the stage lets the check go on.
  module RecoveryVerdicts
    # Seconds with no sub-agent event after which a sub-agent still recorded as
    # running stops holding off an attempt: an outage can kill one before it
    # sends SubagentStop.
    SUBAGENT_QUIET = 600

    # What Claude Code shows while it is retrying by itself, or still working.
    BUSY_SCREEN = /Retrying in|esc to interrupt/

    module_function

    # @param entry [Hash] the stored entry
    # @param now [Time]
    # @return [Boolean] whether our last signal is recent enough that its
    #   SessionEnd may still be on the way
    def signalled_lately?(entry, now)
      signalled = time_of(entry["last_signal_at"])
      !signalled.nil? && now - signalled < AgentRecoveryStore::SIGNAL_HOLD
    end

    # @param entry [Hash]
    # @param started_at [String, nil] the ledger's last SessionStart of the entry's session
    # @return [Boolean] whether an agent of that session started after our signal
    def started_since_signal?(entry, started_at)
      signalled = time_of(entry["last_signal_at"])
      started = time_of(started_at)
      !signalled.nil? && !started.nil? && started > signalled
    end

    # @param command [String, nil] the resume line, nil when none can be built
    # @param entry [Hash]
    # @return [Boolean] whether that line may resume the entry's session
    def resumable?(command, entry)
      !command.nil? && entry["session_id"].to_s.match?(AgentResumeCommand::SESSION_ID)
    end

    # @param entry [Hash]
    # @param live [Hash] an agent read from the pane (+:pid+, +:started+)
    # @return [Boolean] whether it is the stored agent; a pid never read proves nothing
    def same_process?(entry, live)
      !entry["agent_pid"].nil? && live[:pid] == entry["agent_pid"] && live[:started] == entry["agent_started"]
    end

    # @param facts [Hash, nil] the monitor's delivery facts for the pane
    # @param time [Time]
    # @return [Boolean] whether a prompt came after +time+; true with no facts
    def prompt_after?(facts, time)
      return true unless facts
      prompt = facts[:last_user_prompt_at]
      !prompt.nil? && prompt.to_f > time.to_f
    end

    # @param entry [Hash]
    # @param now [Time]
    # @return [Boolean] whether the running sub-agents were heard from, or the
    #   turn failed, within {SUBAGENT_QUIET}
    def subagents_recent?(entry, now)
      latest = [time_of(entry["last_subagent_at"]), time_of(entry["failed_at"])].compact.max
      latest.nil? || now - latest < SUBAGENT_QUIET
    end

    # @param screen [String, nil] the screen once it stood still, nil when it didn't
    # @return [Boolean]
    def screen_busy?(screen)
      screen.nil? || BUSY_SCREEN.match?(screen)
    end

    # @param record [Hash, nil] the transcript's last turn record
    # @param entry [Hash]
    # @return [Symbol, nil] nil while the transcript still shows the stored failure
    def transcript_verdict(record, entry)
      return :defer unless record && entry["last_turn_uuid"]
      :clear unless record["api_error"] && record["uuid"] == entry["last_turn_uuid"]
    end

    # @param opened [Hash, nil, Symbol] the ledger's open session in the pane
    # @param entry [Hash]
    # @return [Symbol, nil] nil while that session is the stored one
    def session_verdict(opened, entry)
      return :defer unless opened.is_a?(Hash)
      (opened["session_id"] == entry["session_id"]) ? nil : :clear
    end

    # @param entry [Hash]
    # @return [Boolean] whether no attempt has been made, so the next is typed
    def first_attempt?(entry)
      entry["attempts"].to_i.zero?
    end

    # @param start_command [String, nil, Symbol] the pane's start command,
    #   +:gone+ when the pane can't be read
    # @return [Symbol, nil] nil when the pane had no start command, so the
    #   agent runs in a shell a resume line can reach
    def start_command_verdict(start_command)
      return :defer if start_command == :gone
      :never if start_command
    end

    # @param value [String, nil] an ISO 8601 time
    # @return [Time, nil]
    def time_of(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
