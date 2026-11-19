module Workspace
  # Reads how much of a run's token budget is used, from the stored run alone (no lock, no I/O). A definition
  # that declares `budget: {tokens: N}` is held to N tokens plus the run's `extra_tokens`; {WorkflowEngine}
  # checks it where a new attempt would start, so it stops the next attempt and never a turn under way.
  #
  # What counts is each attempt's (one still in progress is left out until it ends; one that was replaced without
  # ending, by a resume over it, counts when it has usage and is uncounted when it has none) `usage` ({WorkflowAttemptRecord}): `input_tokens`, `output_tokens` and
  # `cache_creation_input_tokens`. `cache_read_input_tokens` is left out, since a cache read re-reads context
  # already paid for and would make any long turn look huge. Sub-agents are counted: the recorded
  # `usage` includes each in-step sub-agent's own transcript. Each review round an attempt went through (its
  # `rounds`, every round that ended, decided or not) counts its own `usage`, the review pane's session with its
  # reviewer sub-agents; a round's verdict rows carry no usage, so nothing is counted twice, and a round whose
  # `usage` is null counts as one more `uncounted` (a round with no pane ran nothing and is left out). An attempt
  # whose `usage` is null (another agent than Claude Code, or a heavy attempt the transcript tail could not cover)
  # is `uncounted` too. `counted` and `uncounted` count ended attempts and review rounds, each with its own `usage`,
  # so the total is a minimum, never a figure that reads null as zero.
  #
  # An attempt whose `usage` is null but that the sweep interrupted for the budget counts the live figure its
  # `budget_interrupt` record holds (written by {WorkflowRecovery#claim_interrupt}, so it is stored data and
  # {.reading} stays pure), counted under `estimated` too. A readable `usage` always wins over the record (it means the
  # transcript tail reached the attempt's start, so it is the measured figure), so an attempt is never counted twice; a record whose `tokens` is not a non-negative Integer leaves the attempt uncounted. Without
  # it, a runaway attempt the transcript tail cannot cover would read uncounted and let the next attempt start.
  #
  # A run whose ended attempts and review rounds are all uncounted has a total of 0, which is under any budget, so its budget never
  # stops it; `measured` is false then, and status says the budget is not being measured. Stopping would mean
  # acting on a figure nobody has, and a budget that ends every non-Claude run after one attempt helps no one.
  class WorkflowBudget
    # The usage keys that make up the count.
    COUNTED_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens].freeze

    # `suggested` rounds the least `--extra-tokens` up to a multiple of this, so one more attempt fits.
    ROUND_TO = 100_000

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param live [Boolean] false when the attempt in progress is about to be replaced, so its tokens count too
    # @return [Hash{String=>Object}, nil] nil unless the run's definition declares a budget (a stored run from
    #   before the key, or a bad value, reads nil); else "tokens", "action", "extra_tokens", "allowance",
    #   "used" (a minimum), "counted" and "uncounted" (ended attempts and review rounds with and without a readable `usage`),
    #   "estimated" (how many of the counted attempts were counted from their `budget_interrupt` record),
    #   "measured" (false when nothing was counted but some attempt or round ended), "spent" (used has reached the allowance),
    #   "needed" (the least `--extra-tokens` that lets another attempt start, nil unless spent) and "suggested"
    def self.reading(run, live: true)
      run = WorkflowRun.from_h(run)
      budget = WorkflowDefinition.budget(run.definition)
      return nil unless budget
      raise TypeError, "a run's steps are a Hash" unless run.to_h["steps"].is_a?(Hash)
      extra = run.extra_tokens.is_a?(Integer) ? [run.extra_tokens, 0].max : 0
      allowance = budget["tokens"] + extra
      used = 0
      counted = 0
      uncounted = 0
      estimated = 0
      run.steps.each do |id, step|
        stored = Array(step.to_h["attempts"])
        # A reviewing step's attempt has ended (`checks_passed`) with its usage, so it counts.
        # Every live attempt is left out: the cursor's step, and each step of a group (siblings run at the same time).
        cursor = id == run.current || WorkflowRun.step_scoped?(run.to_h, id)
        running = (live && cursor && %w[running checking].include?(step.state)) ? step.attempts.last : nil
        step.attempts.each_with_index do |attempt, index|
          next unless stored[index].is_a?(Hash) && counted_attempt?(attempt) && !attempt.equal?(running)
          own = tokens_of(attempt.usage)
          if own.nil? && (own = interrupt_tokens(attempt))
            estimated += 1
          end
          ([own] + rounds_of(attempt).map { |round| tokens_of(round["usage"]) }).each do |tokens|
            if tokens
              used += tokens
              counted += 1
            else
              uncounted += 1
            end
          end
        end
      end
      spent = used >= allowance
      needed = spent ? used - allowance + 1 : nil
      {"tokens" => budget["tokens"], "action" => budget["action"], "extra_tokens" => extra, "allowance" => allowance,
       "used" => used, "counted" => counted, "uncounted" => uncounted, "estimated" => estimated, "measured" => !(counted.zero? && uncounted.positive?),
       "spent" => spent, "needed" => needed, "suggested" => needed && (needed.fdiv(ROUND_TO).ceil * ROUND_TO)}
    rescue NoMethodError, TypeError
      nil
    end

    # @param attempt [WorkflowRun::Attempt, Hash] a stored attempt
    # @return [Boolean] whether the attempt's tokens count toward a run: every attempt but one never delivered
    #   (no outcome counts too: a cancel, or a `resume --from`, ends an attempt without one). An `interrupted` attempt
    #   counts once; its retry is a separate attempt with its own usage
    def self.counted_attempt?(attempt)
      attempt = WorkflowRun::Attempt.from_h(attempt) unless attempt.is_a?(WorkflowRun::Attempt)
      attempt.outcome != "not_delivered"
    end

    # @param attempt [WorkflowRun::Attempt] a stored attempt
    # @return [Array<Hash>] its review rounds' records (each with its own `usage`); none for an attempt with no `rounds`.
    #   A round with no pane (one refused before it ran, or a delivery that lapsed before any pane opened) ran no
    #   agent: it used no tokens and is left out, never uncounted
    def self.rounds_of(attempt)
      Array(attempt.rounds).grep(Hash).select { |round| round["pane"].is_a?(String) && !round["pane"].empty? }
    end

    # The tokens an attempt and its review rounds used, by {.tokens_of}: nil when any of them has no readable `usage`.
    # Measured `usage` only: an attempt's `budget_interrupt` estimate is never read here, so `workflow stats` reports
    # what the transcripts recorded, while {.reading} falls back to the estimate to hold the budget.
    #
    # @param attempt [WorkflowRun::Attempt] a stored attempt
    # @return [Integer, nil]
    def self.attempt_tokens(attempt)
      sums = ([attempt.usage] + rounds_of(attempt).map { |round| round["usage"] }).map { |usage| tokens_of(usage) }
      sums.all? ? sums.sum : nil
    end

    # @param attempt [WorkflowRun::Attempt] a stored attempt
    # @return [Integer, nil] the `tokens` of its `budget_interrupt` record; nil with no record or one not that shape
    def self.interrupt_tokens(attempt)
      record = attempt.budget_interrupt
      tokens = record.is_a?(Hash) ? record["tokens"] : nil
      (tokens.is_a?(Integer) && tokens >= 0) ? tokens : nil
    end

    # @param usage [Object] an attempt's or a review round's stored `usage`
    # @return [Integer, nil] the tokens that count; nil for a null or a value that is not the recorded shape
    def self.tokens_of(usage)
      return nil unless usage.is_a?(Hash)
      values = COUNTED_KEYS.map { |key| usage.fetch(key, 0) }
      (values.all? { |value| value.is_a?(Integer) && value >= 0 }) ? values.sum : nil
    end
  end
end
