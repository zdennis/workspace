module Workspace
  # Types one prompt into a coding agent's pane the careful way: check the
  # pane with {TypingSafety}, paste the text without Enter, check again that
  # the input line now holds the text, and only then press Enter. The agent
  # daemon's deliveries that must never answer a dialog or join a person's
  # draft go through it: {AgentStatusDesk}'s status requests and
  # {PromptQueueDesk}'s queued prompts.
  #
  # After the paste, an input line showing Claude Code's
  # `[Pasted text #N +M lines]` ({Tmux::PASTE_PLACEHOLDER}) counts as the
  # pasted text, since a long or multi-line paste never shows its own first
  # characters there.
  #
  # The caller holds the daemon's delivery lock around {#type}, so no other
  # delivery types into the pane between the checks and Enter.
  class PromptTyper
    # What one {#type} did.
    #
    # * +outcome+ — +:refused+ (the first check failed; nothing typed),
    #   +:aborted+ (+before_paste+ said no; nothing typed), +:not_landed+ or
    #   +:failed+ (the paste never reached the pane; safe to type again),
    #   +:not_submitted+ (the text is or may be in the pane, Enter not
    #   confirmed), +:submitted+
    # * +code+, +reason+, +message+ — with +:refused+, the {TypingSafety}
    #   refusal; with +:not_submitted+, why Enter wasn't pressed or didn't take
    # * +delivery+ — the last {Tmux::Delivery}, when anything was pasted
    Result = Struct.new(:outcome, :code, :reason, :message, :delivery, keyword_init: true) do
      # @return [Boolean] whether the text may be in the pane, so typing it again could double it
      def landed?
        [:not_submitted, :submitted].include?(outcome)
      end
    end

    # @param tmux [Workspace::Tmux] screen reads and deliveries
    # @param session_monitor [Workspace::SessionMonitor, nil] pane facts
    # @param safety [Workspace::TypingSafety] the typed-text test
    # @param logger [Workspace::Logger] debug logger
    def initialize(tmux:, session_monitor:, safety: TypingSafety.new, logger: Workspace::Logger.new)
      @tmux = tmux
      @session_monitor = session_monitor
      @safety = safety
      @logger = logger
    end

    # Checks the pane as it is now.
    #
    # @param pane_id [String] tmux pane id
    # @param pasted [String, nil] text already pasted, which the input line must then hold
    # @return [Hash, nil] nil when the pane can take text, else the {TypingSafety#check} refusal
    def check(pane_id, pasted: nil)
      @safety.check(@session_monitor&.typing_facts(pane_id), @tmux.capture_screen(pane_id), pasted: pasted)
    end

    # Checks, pastes, checks again, presses Enter.
    #
    # @param session_name [String] the tmux session
    # @param target [String] the pane as "window.pane"
    # @param pane_id [String] the pane's id, for the checks
    # @param text [String] the prompt
    # @param before_paste [#call, nil] called after the first check passes and
    #   right before the paste; a false answer stops there with +:aborted+
    # @return [Result]
    def type(session_name:, target:, pane_id:, text:, before_paste: nil)
      refused = check(pane_id)
      return Result.new(outcome: :refused, code: refused[:code], reason: refused[:reason], message: refused[:message]) if refused
      return Result.new(outcome: :aborted) if before_paste && !before_paste.call

      pasted = @tmux.deliver(session_name, target, text, enter: false)
      @logger.debug { "prompt typer: pasted into #{session_name}:#{target}: #{pasted.status}" }
      return Result.new(outcome: pasted.status, message: pasted.message, delivery: pasted) unless pasted.landed?
      unless pasted.ok?
        return unsubmitted("it may not have arrived, so Enter was not pressed (#{pasted.message})", pasted)
      end

      changed = check(pane_id, pasted: text)
      return unsubmitted("Enter was not pressed: #{changed[:message]}", pasted, reason: changed[:reason]) if changed

      submitted = @tmux.deliver(session_name, target, "", enter: true)
      @logger.debug { "prompt typer: submitted in #{session_name}:#{target}: #{submitted.status}" }
      return unsubmitted(submitted.message, submitted) unless submitted.ok?
      Result.new(outcome: :submitted, delivery: submitted)
    end

    private

    def unsubmitted(message, delivery, reason: nil)
      Result.new(outcome: :not_submitted, reason: reason, message: message, delivery: delivery)
    end
  end
end
