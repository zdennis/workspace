module Workspace
  # Decides whether a pane can take typed text without it answering a dialog
  # or joining a half-written draft. A pane passes only when all of these hold:
  #
  # 1. A known coding agent runs there (a shell is `not_an_agent`; a pane the
  #    session monitor hasn't scanned is `unknown`), and its provider has a
  #    `ready_pattern` to check the screen with (`unsupported_agent`
  #    otherwise: without one a dialog can't be told from the input box).
  # 2. No wait is open: the monitor's restart state is `idle` or `working`,
  #    not `waiting` (a permission prompt or a question Notification).
  # 3. The main agent has no question tool running (`AskUserQuestion`,
  #    `ExitPlanMode`), whose menu a typed Enter would answer. Esc on one sends
  #    no hook; {SessionMonitor} closes the tool only on {QuestionClosedCheck}'s
  #    reading of the screen, so `open_tools` here stays the one test.
  # 4. The current screen shows the agent's input prompt (the pattern
  #    {AgentReadiness} waits for). A dialog replaces Claude Code's input box,
  #    so this also catches a permission prompt whose Notification hook
  #    hasn't arrived yet. `no_input_prompt` otherwise.
  # 5. The input box is empty (no text on the prompt row or on any row down to
  #    its closing rule, when that rule is on screen), or shows only the
  #    agent's placeholder, so the
  #    text isn't appended to a person's draft (`input_not_empty`). For the
  #    check made after the text is pasted, the whole input box must instead
  #    equal that text, or be exactly one Claude Code `[Pasted text #N]`
  #    placeholder for a long or multi-line paste (`input_changed` otherwise):
  #    a menu row or a draft there means Enter would answer or send something else.
  #    Given a {StyledScreen}, `Try "` is no placeholder (typed text can start
  #    with it); text drawn entirely faint (SGR 2) on every
  #    line of the input, with every one of those lines proven, is Claude
  #    Code's suggestion and counts as empty. Only the empty check reads
  #    styling; `pasted:` and `exact:` use the plain text, so faint text
  #    in the box counts as text and can only refuse.
  #
  # A `working` pane passes: Claude Code queues text typed during a turn.
  #
  # Every daemon delivery that reads the input line gets this through
  # {PromptTyper#check}, and {AgentRestart} through {IdlePromptCheck}.
  # {Tmux#deliver} and {PaneDispatch} never read the input line.
  class TypingSafety
    # Tools that draw a menu the typed text would answer.
    QUESTION_TOOLS = %w[AskUserQuestion ExitPlanMode].freeze

    # What Claude Code shows in an empty input line.
    PLACEHOLDER = /\ATry "/

    # Deliberately separate from Tmux::PASTE_PLACEHOLDER, which counts occurrences on a screen and is unanchored.
    # One paste placeholder, whitespace removed: `[Pasted text #N]` or `[Pasted text #N +M lines]`.
    PASTE_PLACEHOLDER_ONLY = /\A\[Pastedtext#\d+(\+\d+lines?)?\]\z/

    # @param providers [Array<Workspace::AgentProvider>] the known agents
    def initialize(providers: AgentProvider.all)
      @providers = providers
    end

    # @param facts [Hash, nil] {Workspace::SessionMonitor#typing_facts}
    # @param screen [String, StyledScreen, nil] the pane's current screen; a
    #   plain String carries no styling, so a suggestion on it reads as a draft
    # @param pasted [String, nil] the text already pasted, which the input
    #   box must then equal instead of being empty
    # @param exact [String, nil] text the whole input, however it wraps, must
    #   equal: no placeholder and no prefix count, so a person's draft can't
    #   read as this text. `input_changed` otherwise
    # @return [Hash, nil] nil when the pane can take text, else `:code`
    #   (`not_an_agent` or `pane_not_ready`), `:reason` and `:message`
    def check(facts, screen, pasted: nil, exact: nil)
      return refusal("unknown", "the session monitor hasn't seen this pane yet; try again in a few seconds") unless facts

      kind = facts[:kind]
      return {code: "not_an_agent", reason: "shell", message: "the pane is running a shell, not a coding agent"} if kind == "shell"
      provider = @providers.find { |p| p.key == kind }
      return refusal("unknown", "the session monitor hasn't identified the agent in this pane yet") unless provider
      pattern = provider.ready_pattern
      return refusal("unsupported_agent", "#{provider.label}'s screen can't be checked for an open dialog") unless pattern
      return refusal("waiting", "#{provider.label} is waiting on a permission prompt or a question") if facts[:state] == "waiting"
      return refusal("unknown", "the pane's state isn't known") unless %w[idle working].include?(facts[:state])

      question = (facts[:open_tools] & QUESTION_TOOLS).first
      return refusal("question_open", "#{provider.label} is showing #{question}, which typed text would answer") if question

      styled = screen if screen.is_a?(StyledScreen)
      screen = styled.text if styled
      input = input_line(pattern, screen)
      return refusal("no_input_prompt", "#{provider.label}'s input prompt isn't on screen (a dialog may be open)") unless input
      if exact
        unless squeeze(whole_input(pattern, screen)) == squeeze(exact)
          return refusal("input_changed", "#{provider.label}'s input isn't exactly the given text")
        end
      elsif pasted
        unless pasted_shown?(pattern, screen, pasted)
          return refusal("input_changed", "#{provider.label}'s input box doesn't hold exactly the pasted text")
        end
      elsif !empty_input?(pattern, screen, styled, input)
        return refusal("input_not_empty", "#{provider.label}'s input line already holds text (a draft)")
      end
      nil
    end

    private

    # Whether the whole input box holds the pasted text and nothing else, or
    # exactly one paste placeholder and nothing else (whitespace ignored, since
    # a wrapped line gains spaces). A draft before or after the paste, or a
    # placeholder the person typed ahead of a paste, makes the box differ and
    # refuses. Also refuses when the box's closing rule isn't on screen.
    def pasted_shown?(pattern, screen, pasted)
      last = screen.to_enum(:scan, pattern).map { Regexp.last_match }.last
      return false unless last.post_match.lines.any? { |line| closing_rule?(line) }

      box = squeeze(whole_input(pattern, screen))
      wanted = squeeze(pasted)
      !wanted.empty? && (box == wanted || box.match?(PASTE_PLACEHOLDER_ONLY))
    end

    # The text after the last input prompt on screen, stripped, or nil when
    # there is no prompt.
    def input_line(pattern, screen)
      return nil unless screen
      matches = screen.scan(/(?:#{pattern.source})([^\n]*)/)
      return nil if matches.empty?
      matches.last.first.gsub(/[[:space:] ]+/, " ").strip
    end

    # Whether the input is Claude Code's suggestion: at least one visible
    # character, all of them faint, on the prompt line and on any line down
    # to the closing rule, and every one of those lines proven.
    def suggestion?(pattern, styled)
      return false unless styled

      text = styled.text
      last = text.to_enum(:scan, pattern).map { Regexp.last_match }.last
      return false unless last

      line = text[0...last.end(0)].count("\n")
      newline = text.rindex("\n", last.end(0) - 1)
      column = last.end(0) - (newline ? newline + 1 : 0)
      lines = text.split("\n", -1)
      seen = false
      index = line
      while index < lines.size
        break if index > line && closing_rule?(lines[index])
        return false unless styled.proven?(index)

        lines[index].each_char.with_index do |char, position|
          next if index == line && position < column
          next if char.match?(/[[:space:]]/)
          return false unless styled.faint?(index, position)

          seen = true
        end
        index += 1
      end
      seen
    end

    # Whether the input box is empty. A suggestion drawn faint counts. Text on
    # any row between the prompt row and the closing rule is a draft, though
    # only when that rule is on screen; without one the prompt row decides.
    # `Try "` is the placeholder only on a plain String, which has no styling
    # to tell it from a typed draft.
    def empty_input?(pattern, screen, styled, input)
      return true if suggestion?(pattern, styled)

      last = screen.to_enum(:scan, pattern).map { Regexp.last_match }.last
      rows = last.post_match.lines.drop(1)
      if rows.any? { |row| closing_rule?(row) }
        return false if rows.take_while { |row| !closing_rule?(row) }.any? { |row| row.match?(/\S/) }
      end
      input.empty? || (!styled && input.match?(PLACEHOLDER))
    end

    # Everything from the last input prompt down to the rule that closes the box.
    def whole_input(pattern, screen)
      last = screen.to_enum(:scan, pattern).map { Regexp.last_match }.last
      last.post_match.lines.take_while { |line| !closing_rule?(line) }.join
    end

    def closing_rule?(line)
      line.match?(/\A\s*─{3,}\s*\z/)
    end

    # A wrapped line gains spaces, so spaces can't take part in the comparison.
    def squeeze(text)
      text.gsub(/[[:space:]]+/, "")
    end

    def refusal(reason, message)
      {code: "pane_not_ready", reason: reason, message: message}
    end
  end
end
