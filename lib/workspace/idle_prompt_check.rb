module Workspace
  # The one reading of "the input box is empty and nothing is running" for a
  # pane: {TypingSafety} must pass on the pane's styled screen, so the prompt
  # is on screen and the input is empty (a suggestion counts as empty), and no
  # busy row may show near the box.
  #
  # A busy row is a spinner row, `esc to interrupt` or `Retrying in`, looked
  # for only in {ROWS_ABOVE} rows above the input box's opening rule. Below that
  # rule only the two wordings count: a custom status line cut short with an
  # ellipsis has a spinner row's shape. A pane displaying this wording, or a
  # transcript quoting it, higher up doesn't read busy. Claude Code draws a task
  # list between the spinner and the box, so the rows above reach past a long one.
  #
  # A pane whose turn has ended with background work left reads
  # `✻ Waiting for 1 background agent to finish` or `· 1 shell still running`,
  # with no ellipsis, and a sub-agent row has text after its ellipsis; neither
  # is busy. Anything else shaped like a spinner, a task row ending in an
  # ellipsis included, reads busy, which keeps the refusal.
  class IdlePromptCheck
    # One glyph, a verb of any spelling, the ellipsis, then nothing or a timer.
    # No `:`, so a `⎿  Tip: ...…` row is not one.
    SPINNER_ROW = /\A\s*\S\s+[^():]{1,60}…\s*(\(.*)?\z/

    # Words that only a running turn shows.
    BUSY_WORDS = /esc to interrupt|Retrying in/

    # Rows above the input box's opening rule that are searched: the spinner,
    # the `⎿  Tip:` lines under it and a task list.
    ROWS_ABOVE = 16

    # @param safety [Workspace::TypingSafety] the typed-text test
    # @param providers [Array<Workspace::AgentProvider>] the known agents
    def initialize(safety: TypingSafety.new, providers: AgentProvider.all)
      @safety = safety
      @providers = providers
    end

    # @param facts [Hash, nil] {Workspace::SessionMonitor#typing_facts}
    # @param styled_capture [String, nil] {Workspace::Tmux#capture_screen_styled}
    # @return [Hash, nil] nil when the box is empty and nothing is running, else
    #   `:reason` and `:message`: {TypingSafety}'s, or `turn_started` for a busy row
    def refusal(facts, styled_capture)
      screen = StyledScreen.parse(styled_capture)
      refused = @safety.check(facts, screen)
      return refused.slice(:reason, :message) if refused
      return nil unless busy_row?(screen.text, facts[:kind])

      {reason: "turn_started", message: "a spinner or another sign of a running turn shows above the input box"}
    end

    private

    def busy_row?(text, kind)
      pattern = @providers.find { |provider| provider.key == kind }.ready_pattern
      opening_rule = text[0...text.rindex(pattern)].count("\n")
      lines = text.tr("\u00a0", " ").split("\n", -1)
      above = lines[[opening_rule - ROWS_ABOVE, 0].max...opening_rule]
      above.any? { |row| row.match?(SPINNER_ROW) || row.match?(BUSY_WORDS) } ||
        lines[(opening_rule + 1)..].any? { |row| row.match?(BUSY_WORDS) }
    end
  end
end
