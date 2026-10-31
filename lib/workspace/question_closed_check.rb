require "digest"

module Workspace
  # Reads from a pane's screen whether Claude Code's question dialog is gone.
  # Esc on `AskUserQuestion` or `ExitPlanMode` sends no hook, so
  # {SessionMonitor} has only the screen to close the tool by.
  #
  # A screen counts only when it shows the normal input box whole: the opening
  # rule, the prompt with nothing typed, the closing rule on the very next row,
  # no busy row (see {IdlePromptCheck}), no dialog hint under the box, and no
  # selector row (`❯`) or numbered option under it either, which is how a dialog
  # drawn below an older empty box gives itself away.
  #
  # An open dialog can't show that. On Claude Code 2.1.316 every form was
  # captured (`spec/fixtures/claude_screens/question_*`): options, the free-text
  # row, multi-select, tabs, the Submit tab, previews with notes, `ExitPlanMode`,
  # short and narrow panes. `❯` can sit right under a rule there, but only on
  # `Chat about this`, which is never empty and has no rule below it; a free-text
  # row keeps its number; `ctrl+o` draws no prompt at all. While PreToolUse hooks
  # run before the dialog draws, the empty box shows with a spinner row over it,
  # so that moment is a busy row.
  #
  # Most captured forms print a hint (`Esc to cancel`, `ctrl+g to edit`,
  # `Review your answers`, `dialog waiting`), but not all, so the hints are one
  # of several tests rather than the only one. The rule right under the prompt,
  # the hints and the selector and numbered-row tests also cover a form not seen
  # yet. A screen that can't be proven to hold no dialog reads as nil.
  class QuestionClosedCheck
    # Seconds {SessionMonitor} wants one reading held, with no hook event,
    # before it closes the tool. The spinner stayed up for the whole of a 12s
    # PreToolUse hook and no frame without it was seen before the dialog, so
    # this only has to outlast a single redraw; 8s means two scans at the
    # default 10s poll.
    HOLD = 8

    RULE = /\A\s*─{3,}\s*\z/

    # Hints that captured dialogs print in their last rows, which the rows under
    # the input box never do. Not every dialog prints one.
    DIALOG_HINTS = /Esc to cancel|Enter to select|to navigate|ctrl\+g to edit|Review your answers|dialog waiting/

    # A dialog's selected option (`❯`, indented or not) or a numbered option
    # (`1.` then a space or the end of the row, so `1.2 GB free` is not one).
    # `[[:space:]]` also matches a non-breaking space.
    OPTION_ROW = /\A[[:space:]]*(❯|\d+\.([[:space:]]|\z))/

    # Fewest rows a pane must have for the absence of a busy row to prove
    # anything: on a shorter pane a spinner can be off screen, so its absence
    # proves nothing. The box is the opening rule, the prompt and the closing rule.
    MIN_ROWS = IdlePromptCheck::ROWS_ABOVE + 3

    # @param idle_check [Workspace::IdlePromptCheck] the box is empty and nothing runs
    # @param providers [Array<Workspace::AgentProvider>] the known agents
    def initialize(idle_check: IdlePromptCheck.new, providers: AgentProvider.all)
      @idle_check = idle_check
      @providers = providers
    end

    # @param kind [String] the pane's agent
    # @param styled_capture [String, nil] {Workspace::Tmux#capture_screen_styled}
    # @return [String, nil] a digest of the screen down to the box when it shows
    #   no dialog, to compare with a later reading; rows below the box aren't in
    #   it, so a status line that keeps moving doesn't count. nil when not proven
    def reading(kind, styled_capture)
      return nil unless styled_capture&.valid_encoding?
      return nil if @idle_check.refusal({kind: kind, state: "idle", open_tools: []}, styled_capture)

      text = StyledScreen.parse(styled_capture).text
      return nil if text.chomp.count("\n") + 1 < MIN_ROWS

      pattern = @providers.find { |provider| provider.key == kind }.ready_pattern
      lines = text.split("\n", -1)
      closing = text[0...text.rindex(pattern)].count("\n") + 2
      return nil unless lines[closing]&.match?(RULE)
      below = lines[(closing + 1)..]
      return nil if below.any? { |row| row.match?(DIALOG_HINTS) || row.match?(OPTION_ROW) }

      Digest::SHA256.hexdigest(lines[0..closing].join("\n"))
    rescue ArgumentError
      nil
    end
  end
end
