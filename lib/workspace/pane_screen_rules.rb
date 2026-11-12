module Workspace
  # The screen rules of {SessionMonitor}'s scan: what a pane's screen says
  # about the waits a hook can't end. A pane is the symbol-keyed Hash
  # {PaneEvents.new_pane} builds; a screen is the text a capture gave.
  #
  # Nothing here takes a lock, reads the clock or does I/O: the screens and
  # readings come in from {PaneScanner}, the time as +now+, and the monitor's
  # lock is held around every call. Each rule changes only the pane given.
  module PaneScreenRules
    # The key of the wait a matched screen opens in the pane's waits. Hooks
    # key theirs by agent id, so this never meets one.
    SCREEN_WAIT_KEY = "screen"
    private_constant :SCREEN_WAIT_KEY

    # The shortest permission dialog is 12 lines, so a tail this long can't reach above its top rule.
    READY_TAIL_LINES = 12
    private_constant :READY_TAIL_LINES

    # An AskUserQuestion menu draws a rule above its last row, so with the
    # cursor there it reads like the ready prompt.
    MENU_ROW_PATTERN = /─{3,}\n❯[ \t ]?\d+\. /
    private_constant :MENU_ROW_PATTERN

    module_function

    # Deny and Esc fire no hook. A bound permission wait ends when the ready
    # prompt is back at the bottom of the screen; trailing blank rows (inline
    # panes) are stripped first, and an empty capture says nothing.
    #
    # @param pane [Hash] the pane's record, changed in place
    # @param provider [Workspace::AgentProvider, nil] the agent found in the pane
    # @param screen [String] the pane's plain capture
    # @return [void]
    def end_answered_permission_waits(pane, provider, screen)
      return unless provider&.key == "claude" && provider.ready_pattern
      tail = screen.scrub.rstrip.lines.last(READY_TAIL_LINES).join
      return if tail.empty? || !provider.ready_pattern.match?(tail) || MENU_ROW_PATTERN.match?(tail)

      pane[:waits].select { |_, wait| wait[:tool] }.each do |agent_id, wait|
        pane[:waits].delete(agent_id)
        pane[:alerted_waits]&.delete(agent_id)
        # A differing request is newer than this wait, its dialog not yet drawn.
        requests = pane[:permission_requests]
        requests.delete(agent_id) if requests[agent_id] == wait.slice(:tool, :input)
      end
      nil
    end

    # Some agents stop on a screen before any hook can say so (Codex's
    # sign-in and folder trust). A provider's waiting screens put the pane
    # in `waiting` while one is shown, and take it out when it goes.
    #
    # @param pane [Hash] the pane's record, changed in place
    # @param provider [Workspace::AgentProvider, nil]
    # @param screen [String] the pane's plain capture; an empty one (a failed
    #   capture) changes nothing
    # @param now [Time] when a wait this opens began
    # @return [void]
    def screen_wait(pane, provider, screen, now)
      return if screen.empty?
      message = provider&.waiting_screen(screen)&.fetch(:message)
      hook_waiting = pane[:waits].keys.any? { |key| key != SCREEN_WAIT_KEY }
      if message && !hook_waiting
        wait = (pane[:waits][SCREEN_WAIT_KEY] ||= PaneEvents.resumed_wait(pane, SCREEN_WAIT_KEY, now: now))
        wait[:message] = message
        wait[:since] ||= now
      else
        pane[:waits].delete(SCREEN_WAIT_KEY)
        pane[:alerted_waits]&.delete(SCREEN_WAIT_KEY)
      end
      nil
    end

    # @param pane [Hash]
    # @return [Array] the ids of the pane's open question tools
    #   ({TypingSafety::QUESTION_TOOLS}), in the order they opened
    def question_tools(pane)
      pane[:open_tools].to_h.select { |_, tool| TypingSafety::QUESTION_TOOLS.include?(tool[:tool]) }.keys
    end

    # Esc on a question sends no hook, so a question tool stays open and the
    # wait its Notification opened stays too, for good. One screen reading of
    # {QuestionClosedCheck} held for {QuestionClosedCheck::HOLD} seconds, with
    # no hook event since, closes both. Anything else starts the wait over, a
    # tool that opened since included, and nothing is closed. With no
    # question tool open, the held reading is dropped.
    #
    # The turn ended with the Esc: as after a Stop, the idle notification that
    # comes later opens no wait. Only the main agent's wait goes; a
    # sub-agent's is its own.
    #
    # @param pane [Hash] the pane's record, changed in place
    # @param tools [Array] {.question_tools} for the pane
    # @param reading [String, nil] {QuestionClosedCheck#reading} of the pane's
    #   styled screen; nil proves nothing
    # @param now [Time]
    # @return [Boolean] whether the question was closed
    def hold_question(pane, tools, reading, now)
      if tools.empty?
        pane.delete(:question_screen)
        return false
      end

      held = pane[:question_screen]
      unless reading_held?(pane, held, tools, reading)
        pane[:question_screen] = reading && {tools: tools, reading: reading, since: now}
        return false
      end
      return false if now - held[:since] < QuestionClosedCheck::HOLD

      close_question(pane, tools)
      true
    end

    def reading_held?(pane, held, tools, reading)
      return false unless reading && held
      return false if pane[:last_event_at] && pane[:last_event_at] > held[:since]

      held[:tools] == tools && held[:reading] == reading
    end
    private_class_method :reading_held?

    def close_question(pane, tools)
      tools.each { |id| pane[:open_tools].delete(id) }
      pane[:waits].delete(nil)
      pane[:alerted_waits]&.delete(nil)
      pane[:permission_requests].delete(nil)
      pane[:turn_ended] = true
      pane.delete(:question_screen)
    end
    private_class_method :close_question
  end
end
