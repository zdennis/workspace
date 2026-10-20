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
  #    `ExitPlanMode`), whose menu a typed Enter would answer.
  # 4. The current screen shows the agent's input prompt (the pattern
  #    {AgentReadiness} waits for). A dialog replaces Claude Code's input box,
  #    so this also catches a permission prompt whose Notification hook
  #    hasn't arrived yet. `no_input_prompt` otherwise.
  # 5. The input line is empty, or shows only the agent's placeholder, so the
  #    text isn't appended to a person's draft (`input_not_empty`). For the
  #    check made after the text is pasted, the line must instead start with
  #    that text, or show Claude Code's `[Pasted text #N` placeholder for a
  #    long or multi-line paste (`input_changed` otherwise): a menu row or a
  #    draft there means Enter would answer or send something else.
  #
  # A `working` pane passes: Claude Code queues text typed during a turn.
  class TypingSafety
    # Tools that draw a menu the typed text would answer.
    QUESTION_TOOLS = %w[AskUserQuestion ExitPlanMode].freeze

    # What Claude Code shows in an empty input line.
    PLACEHOLDER = /\ATry "/

    # How much of the pasted text the input line must start with; the rest may wrap.
    PASTED_PREFIX = 24

    # @param providers [Array<Workspace::AgentProvider>] the known agents
    def initialize(providers: AgentProvider.all)
      @providers = providers
    end

    # @param facts [Hash, nil] {Workspace::SessionMonitor#typing_facts}
    # @param screen [String, nil] the pane's current screen
    # @param pasted [String, nil] the text already pasted, which the input
    #   line must then start with instead of being empty
    # @return [Hash, nil] nil when the pane can take text, else `:code`
    #   (`not_an_agent` or `pane_not_ready`), `:reason` and `:message`
    def check(facts, screen, pasted: nil)
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

      input = input_line(pattern, screen)
      return refusal("no_input_prompt", "#{provider.label}'s input prompt isn't on screen (a dialog may be open)") unless input
      if pasted
        unless input.start_with?(pasted[0, PASTED_PREFIX]) || input.match?(/\A#{Tmux::PASTE_PLACEHOLDER.source}/)
          return refusal("input_changed", "#{provider.label}'s input line doesn't start with the pasted text")
        end
      elsif !(input.empty? || input.match?(PLACEHOLDER))
        return refusal("input_not_empty", "#{provider.label}'s input line already holds text (a draft)")
      end
      nil
    end

    private

    # The text after the last input prompt on screen, stripped, or nil when
    # there is no prompt.
    def input_line(pattern, screen)
      return nil unless screen
      matches = screen.scan(/(?:#{pattern.source})([^\n]*)/)
      return nil if matches.empty?
      matches.last.first.gsub(/[[:space:] ]+/, " ").strip
    end

    def refusal(reason, message)
      {code: "pane_not_ready", reason: reason, message: message}
    end
  end
end
