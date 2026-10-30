module Workspace
  # Reads whether a pane's agent confirmed a typed `/clear` with a
  # SessionStart hook event whose source is `clear`. {PromptQueueDesk} and
  # {AgentRestart} both judge a clear this way. The times compared (the
  # pane's SessionStart and prompt times, and the moment `/clear` was typed)
  # must come from one clock: the session monitor's.
  class ClearConfirmation
    # @param facts [Hash, nil] {Workspace::SessionMonitor#delivery_facts} for the pane
    # @param cleared_at [Time] when `/clear` was typed
    # @return [Array] `[:confirmed, started]` for a SessionStart with source
    #   `clear` at or after +cleared_at+; `[:voided, nil]` when a prompt was
    #   submitted in the pane after the clear and before that SessionStart (or
    #   with none yet), since a person typed meanwhile; else `[:pending, nil]`
    def self.check(facts, cleared_at)
      prompt = facts&.dig(:last_user_prompt_at)
      prompt = nil unless prompt && prompt >= cleared_at
      started = facts&.dig(:last_session_start)
      if started && started[:source] == "clear" && started[:at] >= cleared_at
        return (prompt && prompt < started[:at]) ? [:voided, nil] : [:confirmed, started]
      end
      prompt ? [:voided, nil] : [:pending, nil]
    end
  end
end
