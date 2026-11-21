module Workspace
  # The workflow engine's rules that need no collaborator: what a stored run says about its attempts, deliveries,
  # parks, backoffs and sweep marks, and the words and codes of a failure. Every method is a class method over plain
  # values (a stored run Hash, a Time), reads no clock, store or process, and writes nothing.
  # {WorkflowEngine} keeps its class methods as forwarders to these.
  module WorkflowTransitions
    # Seconds after an attempt starts during which its line may still be on its
    # way: the daemon's answer to `restart_agent`, plus a minute to start it.
    DELIVERY_WINDOW = WorkflowPanes::REPLY_TIMEOUT + 60

    # Seconds the sweep waits after an undelivered attempt ended before retrying it; retry n uses entry n
    # (the last entry again past the end).
    REDELIVER_BACKOFF = [60, 300, 900].freeze

    # Delivery failures that prove the line never reached the pane, so typing it again cannot type it twice: the
    # pane was busy or the screen refused before anything was typed, a restart was already under way, or no daemon
    # socket could be opened. Not among them: `not_delivered` (a paste may have landed slowly), `connection_failed`
    # and `unreadable_reply` (the daemon may have typed it), a gone pane, a missing checkout or an unreadable pack.
    REDELIVER_CODES = %w[pane_busy restart_in_progress no_daemon].freeze

    # The daemon's `reason` for a failure that may have left the line in the input box; retrying could type it twice.
    REDELIVER_NEVER_REASONS = %w[prompt_unconfirmed].freeze

    # Seconds a pending interrupt claim holds before another sweep may take it over: the process that took it died
    # between the claim and the press. Past it a pending mark no longer counts as a press under way.
    INTERRUPT_CLAIM_SECONDS = 60

    # Seconds an infra retry's claim holds before another advance may take it over: longer than splitting a pane
    # plus the agent's readiness wait, so a claim younger than this is a restart under way.
    INFRA_RETRY_CLAIM_WINDOW = 180

    # How long a `turn_ended_background` hold lasts after the last Stop that listed tasks.
    BACKGROUND_HOLD = 90 * 60

    # Seconds after a review round's start for which a holder stored with no start time (its `ps` failed) is still
    # taken for a live process: by pid alone a reused pid would read alive for ever, so past this it reads gone.
    UNTIMED_HOLDER_LIMIT = 4 * DELIVERY_WINDOW

    # A review round's delivery failures no delivery again can get past: the round goes straight to its stop.
    ROUND_REDELIVER_NEVER = %w[review_custom_socket].freeze

    # A review round's delivery failures after which its line may have reached the review pane: the agent daemon
    # went away or gave no answer while it typed (an agent daemon restart), or the delivering process was stopped.
    # A delivery that knows it typed the line says so itself (`failure.typed`).
    ROUND_MAY_HAVE_TYPED = %w[connection_failed unreadable_reply delivery_interrupted].freeze

    # Each guard code in words, for a failure or a warning.
    GUARD_TEXT = {
      "no_commit" => "the checkout had no commit to start from",
      "operation_in_progress" => "a git operation (merge, rebase, cherry-pick, revert or bisect) is in progress",
      "config_changed" => "the repository's config, attributes or replace refs changed",
      "hooks_changed" => "the repository's hooks changed since the run started",
      "hidden_changed" => "tracked files were hidden from git (assume-unchanged or skip-worktree) since the run started"
    }.freeze

    # One of a step's {WorkflowRun::PER_STEP_KEYS} slots, by {WorkflowRun.slot}: the current step's unless +step+ is given.
    def self.slot(run, key, step = run["current"]) = WorkflowRun.slot(run, step, key)
    private_class_method :slot

    # {.slot} dug into as `run.dig(key, *path)` digs the run-level key, raising as it would on a value that can't be dug.
    def self.slot_dig(run, key, *path, step: run["current"]) = WorkflowRun.slot_dig(run, step, key, *path)
    private_class_method :slot_dig

    # @param run [Hash{String=>Object}] a stored run
    # @return [Integer] the attempts that count against the allowance: all but those the sweep typed again
    def self.attempts_made(run)
      run["steps"].values.sum { |each| each["attempts"].count { |earlier| !earlier["redelivered"] } }
    end

    # Whether the run has made all the attempts it is allowed, read from the stored run (the definition's
    # `max_attempts` plus `extra_attempts`); false for a run that does not say.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Boolean]
    def self.attempts_spent?(run)
      return false unless run.dig("definition", "max_attempts").is_a?(Integer)
      attempts_made(run) >= attempt_allowance(run)
    end

    # @param run [Hash{String=>Object}] a stored run with a definition
    # @return [Integer] the definition's `max_attempts` plus the run's `extra_attempts`
    def self.attempt_allowance(run)
      run["definition"]["max_attempts"] + run["extra_attempts"].to_i
    end

    # The least `--extra-attempts` that lets the attempt about to start fit.
    #
    # @param run [Hash{String=>Object}] a stored run with a definition
    # @return [Integer] attempts made minus the allowance, plus one (1 for a run exactly spent)
    def self.extra_attempts_needed(run)
      attempts_made(run) - attempt_allowance(run) + 1
    end

    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a step id
    # @return [Integer] the step's attempts that count against its own cap: all but those the sweep typed again
    def self.step_attempts_made(run, step)
      Array(run.dig("steps", step, "attempts")).count { |earlier| !earlier["redelivered"] }
    end

    # @param run [Hash{String=>Object}] a stored run with a definition
    # @param step [String] a step id
    # @return [Integer, nil] the step's `max_attempts` plus its `extra_attempts`; nil when it has no cap (an old run, or no key)
    def self.step_allowance(run, step)
      cap = WorkflowDefinition.step_max_attempts(run.dig("definition", "steps")&.find { |each| each["id"] == step })
      cap && cap + run.dig("steps", step, "extra_attempts").to_i
    end

    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a step id
    # @return [Boolean] whether the step has made all the attempts its own cap allows; false for a step with no cap
    def self.step_attempts_spent?(run, step)
      allowance = step_allowance(run, step)
      !allowance.nil? && step_attempts_made(run, step) >= allowance
    end

    # The least `--extra-attempts` that lets one more attempt of the step fit its own cap.
    #
    # @param run [Hash{String=>Object}] a stored run with a definition
    # @param step [String] a step id
    # @return [Integer, nil] attempts made minus the allowance, plus one; nil for a step with no cap
    def self.step_extra_attempts_needed(run, step)
      allowance = step_allowance(run, step)
      allowance && (step_attempts_made(run, step) - allowance + 1)
    end

    # The review rounds a step may spend in the run: its stored `review.max_rounds` ({WorkflowReviewSpec::DEFAULT_MAX_ROUNDS}
    # when the stored review names none) plus the step's `extra_rounds` (`resume --extra-rounds`).
    #
    # @param run [Hash{String=>Object}] a stored run with a definition
    # @param step [String] a step id
    # @return [Integer, nil] nil for a step with no `review:`
    def self.review_rounds_allowance(run, step)
      review = WorkflowDefinition.review(run.dig("definition", "steps")&.find { |each| each["id"] == step })
      return nil unless review
      base = review["max_rounds"].is_a?(Integer) ? review["max_rounds"] : WorkflowReviewSpec::DEFAULT_MAX_ROUNDS
      base + run.dig("steps", step, "extra_rounds").to_i
    end

    # The least `--extra-rounds` that lets one more round of the step start: rounds made minus the allowance, plus one.
    #
    # @param run [Hash{String=>Object}] a stored run with a definition
    # @param step [String] a step id
    # @return [Integer, nil] nil for a step with no `review:`
    def self.review_extra_rounds_needed(run, step)
      allowance = review_rounds_allowance(run, step)
      allowance && (run.dig("steps", step, "review_rounds").to_i - allowance + 1)
    end

    # Whether the step has spent every review round it may: its `review_rounds` (every round started in the run, by
    # any attempt, reached any way: a rejection's retry, a gate's reject, `resume --from`, an `on_fail` loop; never
    # reset) at its {.review_rounds_allowance}. False for a step with no `review:`.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a step id
    # @return [Boolean]
    def self.review_rounds_spent?(run, step)
      allowance = review_rounds_allowance(run, step)
      !allowance.nil? && run.dig("steps", step, "review_rounds").to_i >= allowance
    end

    # Whether a plain resume (no `--from`) is refused because the current step has spent its review rounds: the
    # resume would start a round past `max_rounds` (a stopped or held round of the step being reviewed), or run again a
    # step whose last round rejected it. {WorkflowDecisions} refuses it (`review_rounds_spent`) and {WorkflowStatus}
    # offers no plain resume then.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Boolean]
    def self.rounds_refuse_resume?(run)
      id = run["current"]
      return false unless review_rounds_spent?(run, id)
      state = run.dig("steps", id, "state")
      return true if state == "failed" && slot_dig(run, "reason", "code") == "review_rejected"
      state == "reviewing" && starts_round?(run, from: nil)
    end

    # What stops a rejected step from running again by itself: the run's `max_attempts` (`limit` "run"), then the
    # step's own (`limit` "step", both with `attempts` and `max_attempts`), then its `max_rounds` (`limit` "rounds").
    #
    # @param run [Hash{String=>Object}] a stored run, at the rejected step
    # @return [Hash{String=>Object}] `rounds` and `max_rounds`, and `limit` (with its counts) when one stops the retry
    def self.rejection_limit(run)
      id = run["current"]
      rounds = {"rounds" => run.dig("steps", id, "review_rounds").to_i, "max_rounds" => review_rounds_allowance(run, id)}
      if attempts_spent?(run)
        rounds.merge("limit" => "run", "attempts" => attempts_made(run), "max_attempts" => attempt_allowance(run))
      elsif step_attempts_spent?(run, id)
        rounds.merge("limit" => "step", "attempts" => step_attempts_made(run, id), "max_attempts" => step_allowance(run, id))
      elsif review_rounds_spent?(run, id)
        rounds.merge("limit" => "rounds")
      else
        rounds
      end
    end

    # The step a resume or reject would start an attempt of: `from` (`resume --from`, or the `to` of a
    # reject), else the step a waiting retry goes to, else the current step.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param from [String, nil]
    # @param step [String, nil] the step whose waiting retry is read; the current step unless given
    # @return [String]
    def self.target_step(run, from: nil, step: run["current"])
      from || slot_dig(run, "backoff", "to", step: step) || run["current"]
    end

    # Whether a resume would start a new attempt: `--from`, a run held for its token budget or its timeout before an
    # attempt, a retry's wait, a step that failed or never
    # got its line, or a running step given a pane. Not a check or a turn left to decide (a failure there goes
    # through the `on_fail` budget), a review round, held or not (its attempt has ended; a round is not an attempt), a passed
    # step moving on, or a lock wait (the attempt was allowed when the step was reached).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param from [String, nil] the step a resume would start again at
    # @param pane [String, nil] the pane the resume would name
    # @param step [String, nil] the step whose holds, wait and state are read; the current step unless given
    # @return [Boolean]
    def self.starts_attempt?(run, from:, pane:, step: run["current"])
      return true if from
      return false if round_hold?(run, step: step)
      return true if slot(run, "budget_hold", step).is_a?(Hash) || slot(run, "timeout_hold", step).is_a?(Hash)
      waiting = slot(run, "backoff", step)
      return true if waiting.is_a?(Hash) && waiting["to"].is_a?(String)
      return false if slot_dig(run, "reason", "code", step: step) == "waiting_lock"
      case run["steps"].fetch(step)["state"]
      when "running" then !pane.nil?
      when "checking", "reviewing", "passed" then false
      else true
      end
    end

    # Whether the run's token budget or timeout hold is of a review round (it records `review_round`): its release
    # starts that round, never an author attempt.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String, nil] the step whose holds are read; the current step unless given
    # @return [Boolean]
    def self.round_hold?(run, step: run["current"])
      [slot(run, "budget_hold", step), slot(run, "timeout_hold", step)].any? { |hold| hold.is_a?(Hash) && hold.key?("review_round") }
    end

    # Why a run waits for a person, or for nothing the clock will move: the one rule `workflow sweep` and
    # `workflow recover` share. A backoff that is only scheduled is no hold (a blocked one is); nor are a
    # `waiting_lock` reason and the `retry_backoff` reason that scheduled backoff sets. First match wins.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String, nil] the step whose holds, reason and gate are read; the current step unless given
    # @return [String, nil] `paused`, `retry_blocked`, `budget_hold`, `timeout_hold`, `round_held` (a reviewing step
    #   stopped with a reason), `reason`, `gate_waiting`, `parked`, or nil
    def self.held_reason(run, step: run["current"])
      return "paused" if run["paused"]
      waiting = run["state"] == "waiting"
      return "retry_blocked" if slot_dig(run, "backoff", "blocked", step: step) && waiting
      return "budget_hold" if slot(run, "budget_hold", step) && waiting
      return "timeout_hold" if slot(run, "timeout_hold", step) && waiting
      state = run.dig("steps", step) || {}
      reason = slot(run, "reason", step)
      reason = nil if reason.is_a?(Hash) && %w[waiting_lock retry_backoff].include?(reason["code"])
      return "round_held" if state["state"] == "reviewing" && reason
      return "reason" if reason
      return "gate_waiting" if state.dig("gate", "state") == "waiting"
      return "parked" if run["parked"]
      nil
    end

    # Whether a fan_out sibling is under way, as `workflow status` shows one: not `pending` (or without a state), and
    # not `passed` unless it waits at its gate or holds a reason.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a step id
    # @return [Boolean]
    def self.under_way?(run, step)
      state = run["steps"].is_a?(Hash) ? run["steps"][step] : nil
      return false unless state.is_a?(Hash) && state["state"].is_a?(String) && state["state"] != "pending"
      return true unless state["state"] == "passed"
      state.dig("gate", "state") == "waiting" || !slot(run, "reason", step).nil?
    end

    # The siblings of the fan_out group the run's cursor is in that are under way ({.under_way?}), in the group's
    # order; empty when the cursor's step is in no group.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Array<String>]
    def self.under_way_siblings(run)
      return [] unless WorkflowRun.step_scoped?(run, run["current"])
      entry = Array(run.dig("definition", "steps")).find { |each| each.is_a?(Hash) && each["id"] == run["current"] }
      Array(WorkflowDefinition.group_steps(run["definition"])[entry["group"]]).select { |id| under_way?(run, id) }
    end

    # +run+ read on +step+: a copy with the cursor on that step when it is a fan_out sibling with a stored state (so
    # every rule that reads the cursor's step reads that sibling's own step, pane and slots); +run+ itself for the
    # cursor's step, a step in no group, an unknown step or nil. The copy is shallow: its nested Hashes are +run+'s.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String, nil] a step id
    # @return [Hash{String=>Object}]
    def self.at_step(run, step)
      return run if step.nil? || step == run["current"] || !WorkflowRun.step_scoped?(run, step)
      return run unless run["steps"].is_a?(Hash) && run["steps"][step].is_a?(Hash)
      run.merge("current" => step)
    end

    # The views a reader that acts on one step at a time goes through: +run+ itself (its cursor's step) first, then
    # +run+ read on each other fan_out sibling under way ({.under_way_siblings}, {.at_step}). A run whose cursor is in
    # no group has the one view, +run+ itself.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Array<Hash{String=>Object}>]
    def self.step_views(run)
      [run] + (under_way_siblings(run) - [run["current"]]).map { |id| at_step(run, id) }
    end

    # Whether a resume would start a review round, which the token budget and the run's timeout are asked about as
    # an attempt's start is: a round the budget or timeout held, or a fresh round after one that stopped for a
    # person. Not `--from` (it starts an attempt), nor a round whose delivery failed or lapsed (delivered again as
    # the same round, which no limit holds back), nor a round waiting for its `review.uses` (`waiting_lock`: it was
    # allowed when it was reached, as a step's lock wait is).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param from [String, nil] the step a resume would start again at
    # @return [Boolean]
    def self.starts_round?(run, from:)
      return false if from
      return false if slot_dig(run, "reason", "code") == "waiting_lock"
      return true if round_hold?(run)
      state = run["steps"].fetch(run["current"])
      return false unless state["state"] == "reviewing"
      round = state["review"]
      !(round.is_a?(Hash) && slot(run, "reason").nil? && round["ended_at"].nil?)
    end

    # Where the line that starts an attempt stands. An attempt is stored as
    # `delivering` before its line is typed, outside the run's lock, and the
    # mark is cleared once the daemon answers or a turn's end shows the agent
    # had it. A mark older than {DELIVERY_WINDOW} was left by a process that
    # died while it waited: the line may or may not have reached the agent.
    # The window runs from the attempt's `delivering_since` when it has one (a
    # line a pause held, typed on the unpause), else from its start.
    #
    # @param attempt [Hash{String=>Object}, nil] a step's last attempt
    # @param now [Time]
    # @return [Symbol, nil] :delivering, :unknown, or nil when the line was delivered or never sent
    def self.delivery(attempt, now)
      return nil unless attempt && attempt["delivery"] == "delivering"
      (now - Time.iso8601(attempt["delivering_since"] || attempt["started_at"]) > DELIVERY_WINDOW) ? :unknown : :delivering
    rescue ArgumentError, TypeError
      :unknown
    end

    # Where the delivery of a review round stands. A round is stored `delivering` when it starts, under the run's
    # lock, and its delivery (window, agent, revision, typing) runs outside it and can outlast {DELIVERY_WINDOW}; so
    # time alone does not end the mark: past the window it still holds while the process that delivers it (its
    # `holder`, a pid and start time) is alive. A holder stored with no start time is judged by its pid only until
    # {UNTIMED_HOLDER_LIMIT}, since a reused pid would hold the mark for ever.
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @param now [Time]
    # @param alive [#call, nil] given the holder, whether that process still runs; nil takes a holder as alive
    # @return [Symbol, nil] :delivering, :failed (the delivering process stored a failure), :unknown (the mark lapsed
    #   with no live holder), or nil when the round was delivered or holds no delivery
    def self.round_delivery(round, now, alive: nil)
      return nil unless round.is_a?(Hash)
      return :failed if round["delivery"] == "failed"
      return nil unless round["delivery"] == "delivering"
      elapsed = now - Time.iso8601(round["started_at"].to_s)
      return :delivering unless elapsed > DELIVERY_WINDOW
      holder = round["holder"]
      return :unknown unless holder
      return :unknown if holder.is_a?(Hash) && holder["started"].nil? && elapsed > UNTIMED_HOLDER_LIMIT
      (alive.nil? || alive.call(holder)) ? :delivering : :unknown
    rescue ArgumentError, TypeError
      :unknown
    end

    # Where a review round that has to be delivered again stands: the current step is `reviewing` with no stored
    # reason and no park, and its round's delivery failed or lapsed ({.round_delivery}). Each delivery again by
    # {WorkflowRecovery#tick} spends one of the round's `redeliveries`, capped by the definition's `redeliver` (a
    # person's resume starts the count again). A stored failure waits out {REDELIVER_BACKOFF} from its `at` first,
    # as an undelivered line does; a lapsed mark is already past {DELIVERY_WINDOW}. A failure in
    # {ROUND_REDELIVER_NEVER} is exhausted at once.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @param alive [#call, nil] see {.round_delivery}
    # @return [Hash, nil] nil when no delivery again applies; else :state (`:due`, `:waiting` for the backoff or
    #   `:exhausted`), :round, :retries (spent), :limit, :mark (`:failed` or `:unknown`) and :wait (seconds left, 0 unless waiting)
    def self.round_redelivery(run, now, alive: nil)
      return nil if run["parked"] || slot(run, "reason")
      state = run.dig("steps", run["current"])
      return nil unless state.is_a?(Hash) && state["state"] == "reviewing"
      round = state["review"]
      # A round whose end is being judged (its revision computed again) is {.lost_round?}'s, not a delivery's.
      return nil if round.is_a?(Hash) && round["recompute"]
      mark = round_delivery(round, now, alive: alive)
      return nil unless %i[failed unknown].include?(mark)
      retries = round["redeliveries"].is_a?(Integer) ? round["redeliveries"] : 0
      limit = WorkflowDefinition.redeliver(run["definition"])
      info = {round: round["round"], retries: retries, limit: limit, mark: mark}
      return info.merge(state: :exhausted, wait: 0) if retries >= limit || ROUND_REDELIVER_NEVER.include?(round.dig("failure", "code"))
      wait = (mark == :failed) ? round_backoff(round, retries, now) : 0
      (wait > 0) ? info.merge(state: :waiting, wait: wait) : info.merge(state: :due, wait: 0)
    end

    # Whether a round whose delivery failed or lapsed ({.round_delivery}) may have had its line typed: the delivery got
    # as far as typing it (`kick_at`), and then lapsed with its process gone, failed after typing (`failure.typed`),
    # or failed in a way that does not prove the line never went out ({ROUND_MAY_HAVE_TYPED}). Its reviewers may
    # have written their verdicts, so the round is judged before it is delivered again.
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @param mark [Symbol, nil] what {.round_delivery} answered
    # @return [Boolean]
    def self.round_may_have_typed?(round, mark)
      return false unless round.is_a?(Hash) && round["kick_at"]
      return true if mark == :unknown
      failure = round["failure"]
      mark == :failed && failure.is_a?(Hash) && (failure["typed"] == true || ROUND_MAY_HAVE_TYPED.include?(failure["code"]))
    end

    # {.round_may_have_typed?} over the round's own delivery mark ({.round_delivery}).
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @param now [Time]
    # @param alive [#call, nil] see {.round_delivery}
    # @return [Boolean]
    def self.typed_round?(round, now, alive: nil)
      round_may_have_typed?(round, round_delivery(round, now, alive: alive))
    end

    # Whether a round whose line may have been typed has waited long enough for its reviewers that it is judged
    # whatever its review pane shows: {DELIVERY_WINDOW}, plus the definition's `stall` when set, from its failure
    # (else from when its line went out, `kick_at`), less +stops+. A time that can't be read has waited long enough.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}] the current step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.typed_wait_over?(run, round, now, stops: [])
      from = round.dig("failure", "at") || round["kick_at"]
      WorkflowDeadline.active_seconds(Time.iso8601(from.to_s), now, Array(stops)) >= DELIVERY_WINDOW + WorkflowDefinition.stall(run["definition"]).to_i
    rescue ArgumentError, TypeError
      true
    end

    # Whether a round whose line may have been typed, and whose review pane shows its agent at work, has run past the
    # review's own `timeout` ({.round_timed_out?}'s one reading, from the round's `started_at`). A start that can't be
    # read has run past it.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}] the current step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.typed_review_timed_out?(run, round, now, stops: [])
      elapsed = round_elapsed(run, round, now, stops: stops)
      elapsed.nil? || elapsed > review_timeout(run)
    end

    # The current step's `review.timeout` in seconds, {WorkflowReviewSpec::DEFAULT_TIMEOUT} when the stored review has
    # none. The one reading of a round's time limit: `workflow status`'s `timed_out` flag, the sweep's interrupt and
    # the wait for a round whose line may have been typed all take it, measured by {.round_elapsed}.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Numeric]
    def self.review_timeout(run)
      review = WorkflowDefinition.review(run.dig("definition", "steps")&.find { |each| each["id"] == run["current"] })
      (review && review["timeout"].is_a?(Numeric)) ? review["timeout"] : WorkflowReviewSpec::DEFAULT_TIMEOUT
    end

    # Seconds a review round has run, from its `started_at` (a delivery again, or a rerun of missing reviewers, starts
    # it again), less the spans the run was paused on its step ({.pause_spans}), the step's stalls ({.stall_spans})
    # and +stops+.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Float, nil] nil when the round holds no start that can be read
    def self.round_elapsed(run, round, now, stops: [])
      return nil unless round.is_a?(Hash) && round["started_at"]
      WorkflowDeadline.active_seconds(Time.iso8601(round["started_at"].to_s), now, step_stops(run, stops))
    rescue ArgumentError, TypeError
      nil
    end

    # Seconds an attempt of the current step has run, from its `started_at`, less the spans the run was paused on the
    # step ({.pause_spans}), the step's stalls ({.stall_spans}) and +stops+: the one reading of a step's `timeout`
    # clock, for the sweep and `workflow status`.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param attempt [Hash{String=>Object}, nil] the current step's attempt
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Float, nil] nil when the attempt holds no start that can be read
    def self.step_elapsed(run, attempt, now, stops: [])
      return nil unless attempt.is_a?(Hash) && attempt["started_at"]
      WorkflowDeadline.active_seconds(Time.iso8601(attempt["started_at"].to_s), now, step_stops(run, stops))
    rescue ArgumentError, TypeError
      nil
    end

    def self.step_stops(run, stops)
      pause_spans(run, run["current"]) + stall_spans(run, run["current"]) + Array(stops)
    end
    private_class_method :step_stops

    # Causes of a stall that stop the clocks while they last: nothing works on the step then.
    STALL_CAUSES = %w[pane_gone agent_gone turn_failed].freeze

    # The spans a step stood stalled ({STALL_CAUSES}): every attempt's `stalls` entries, plus the current attempt's
    # raw `stalled` sweep marks ({.sweep_marks}) when +step+ is the current one, each ended by its `recovered` mark.
    # A span ends at the earliest of its `until`, its attempt's `ended_at` and the first attempt `started_at` after
    # its `since` anywhere in the run; with none of them it is left open, to run to the clock's finish. Entries that
    # can't be read are skipped; the same span from both sources appears once.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String, nil] a step id
    # @return [Array<Hash{String=>Object}>] spans with `since` and an optional `until`, for {WorkflowDeadline.active_seconds}
    def self.stall_spans(run, step)
      state = run.dig("steps", step)
      attempts = state.is_a?(Hash) ? Array(state["attempts"]).grep(Hash) : []
      marks = attempts.flat_map do |attempt|
        Array(attempt["stalls"]).grep(Hash).filter_map do |entry|
          [attempt, entry["since"], entry["until"]] if STALL_CAUSES.include?(entry["cause"])
        end
      end
      if step == run["current"] && attempts.any?
        sweep = sweep_marks(run)
        stalled = sweep["stalled"].is_a?(Hash) ? sweep["stalled"] : {}
        recovered = sweep["recovered"].is_a?(Hash) ? sweep["recovered"] : {}
        STALL_CAUSES.each { |cause| marks << [attempts.last, stalled[cause], recovered[cause]] if stalled[cause] }
      end
      return [] if marks.empty?
      starts = run["steps"].to_h.values.grep(Hash).flat_map { |each| Array(each["attempts"]).grep(Hash) }
        .filter_map { |attempt| stall_time(attempt["started_at"]) }
      spans = marks.filter_map do |attempt, since, till|
        from = stall_time(since) or next
        ends = [till, attempt["ended_at"]].filter_map { |value| (at = stall_time(value)) && [at, value] }
        following = starts.select { |at| at > from }.min
        ends << [following, following.iso8601(6)] if following
        ends.empty? ? {"since" => since} : {"since" => since, "until" => ends.min_by(&:first).last}
      end
      spans.uniq
    end

    # The one rule for which stalls of the current attempt are open: the {STALL_CAUSES} marked in its sweep marks
    # ({.sweep_marks}) and not recovered, or whose `stalls` entry on the attempt has no `until` yet.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Array<String>] causes, in {STALL_CAUSES} order
    def self.open_stalls(run)
      marks = sweep_marks(run)
      stalled = marks["stalled"].is_a?(Hash) ? marks["stalled"] : {}
      recovered = marks["recovered"].is_a?(Hash) ? marks["recovered"] : {}
      attempt = run.dig("steps", run["current"], "attempts")&.last
      entries = attempt.is_a?(Hash) ? Array(attempt["stalls"]).grep(Hash) : []
      STALL_CAUSES.select do |cause|
        (stalled[cause] && !recovered.key?(cause)) || entries.any? { |entry| entry["cause"] == cause && !entry.key?("until") }
      end
    end

    # The one rule for where the current attempt's infra retry stands: the `infra_retry` sweep mark
    # ({.sweep_marks}) that schedules an automatic restart of a step whose pane or agent is gone. A mark with
    # `ended`, or whose `cause` is no longer among {.open_stalls} (given up or not), is `:ended`: it never
    # wakes, is never claimed and holds nothing. A given-up mark whose stall is open is `:exhausted`. A claimed
    # mark is `:claimed` while its claim is younger than {INFRA_RETRY_CLAIM_WINDOW}, `:stale_claim` after (by time alone; whether the claimant still runs
    # is the caller's to ask). Otherwise it is `:waiting` until its `due` time and `:due` from then. A `due` that
    # can't be read is taken from `scheduled_at` plus {REDELIVER_BACKOFF} entry `n - 1`, and as now when neither
    # can be read: a wait must not outlast what could be measured.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Hash, nil] nil when the current attempt has no mark; else :state (`:waiting`, `:due`, `:claimed`,
    #   `:stale_claim`, `:exhausted`, `:ended`), :cause, :n (this retry's number), :max, :due (ISO time, nil when
    #   unreadable), :wait (seconds left, 0 when due), :claimed_by (the claimant Hash, or nil), :released
    #   (the mark's release count, or nil) and :reason (the give-up's reason, or nil)
    def self.infra_retry(run, now)
      mark = sweep_marks(run)["infra_retry"]
      return nil unless mark.is_a?(Hash)
      n = mark["n"].is_a?(Integer) ? mark["n"] : 1
      given_up = mark["given_up"]
      stored_due = stall_time(mark["due"])
      due_at = stored_due || infra_retry_scheduled_due(mark["scheduled_at"], n)
      wait = due_at ? [(due_at - now).ceil, 0].max : 0
      info = {cause: mark["cause"], n: n, max: mark["max"], due: stored_due ? mark["due"] : due_at&.utc&.iso8601, wait: wait,
              claimed_by: mark["claimed_by"].is_a?(Hash) ? mark["claimed_by"] : nil,
              released: mark["released"].is_a?(Integer) ? mark["released"] : nil, reason: given_up.is_a?(Hash) ? given_up["reason"] : nil}
      state = if mark["ended"] || !open_stalls(run).include?(mark["cause"])
        :ended
      elsif given_up
        :exhausted
      elsif mark["claimed_at"]
        claimed = stall_time(mark["claimed_at"])
        (claimed && now - claimed < INFRA_RETRY_CLAIM_WINDOW) ? :claimed : :stale_claim
      else
        (wait > 0) ? :waiting : :due
      end
      info.merge(state: state)
    end

    def self.infra_retry_scheduled_due(scheduled_at, n)
      at = stall_time(scheduled_at) or return nil
      at + infra_retry_wait(n)
    end
    private_class_method :infra_retry_scheduled_due

    # The one rule for how long a step's infra retry +n+ waits after it is scheduled: {REDELIVER_BACKOFF} entry
    # `n - 1`, the last entry for every retry past it, the first for an +n+ below 1.
    #
    # @param n [Integer] the retry's number, from 1
    # @return [Integer] seconds
    def self.infra_retry_wait(n) = REDELIVER_BACKOFF[(n - 1).clamp(0, REDELIVER_BACKOFF.size - 1)]

    # How many infra retries a step has claimed since it last passed or a person last resumed the run.
    #
    # @param run [Hash{String=>Object}] a stored run (one stored before infra retries reads 0)
    # @param step [String] a step id
    # @return [Integer]
    def self.infra_retries(run, step)
      retries = run["infra_retries"]
      count = retries.is_a?(Hash) ? retries.fetch(step, 0) : 0
      count.is_a?(Integer) ? count : 0
    end

    def self.stall_time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end
    private_class_method :stall_time

    # The `paused` reason entries that stop a step's clocks (its attempts' timeout and its review rounds'): every
    # attempt's own, the run's own entries for that step, and the pause under way when the step is the current one
    # (an open entry runs to now). Other reasons are not stops here.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String, nil] a step id
    # @return [Array<Hash{String=>Object}>] entries with `since` and an optional `until`, for {WorkflowDeadline.active_seconds}
    def self.pause_spans(run, step)
      state = run.dig("steps", step)
      attempts = state.is_a?(Hash) ? Array(state["attempts"]).grep(Hash) : []
      entries = attempts.flat_map { |attempt| Array(attempt["reasons"]) }
      entries += Array(slot(run, "reasons", step)).grep(Hash).select { |entry| entry["step"] == step }
      spans = entries.grep(Hash).select { |entry| entry["code"] == "paused" }
      paused = run["paused"]
      spans << {"since" => paused["since"]} if paused.is_a?(Hash) && step == run["current"]
      spans
    end

    # Whether a review round has run past its `review.timeout` ({.review_timeout}, {.round_elapsed}); false for one
    # whose start can't be read.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}, nil] the current step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.round_timed_out?(run, round, now, stops: [])
      elapsed = round_elapsed(run, round, now, stops: stops)
      !elapsed.nil? && elapsed > review_timeout(run)
    end

    # The sweep mark each cause of an attempt's interrupt keeps its claim under, so each presses once: the step's
    # `timeout:`, the run's `timeout_action: interrupt` and the run's spent token budget.
    INTERRUPT_MARK_KEYS = {"timed_out" => "interrupt", "run_timed_out" => "run_interrupt", "budget_spent" => "budget_interrupt"}.freeze

    # The sweep's interrupt causes a review round's own marks (`review.sweep`) keep apart, each pressed once for the
    # round: its `review.timeout` and the run's `timeout_action: interrupt`.
    ROUND_INTERRUPT_KEYS = {"review_timed_out" => "interrupt", "run_timed_out" => "run_interrupt"}.freeze

    # The marks the sweep left on a review round ("interrupt" for its `review.timeout`, "run_interrupt" for the run's
    # deadline, each `state` `pending` or `sent` and `at`; "stalled" and "recovered", cause => time). Kept on the round
    # itself, so the reviewed attempt's own marks (its author's interrupt) never stand for the round's; a delivery of
    # the round again starts with none.
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @return [Hash{String=>Object}]
    def self.round_sweep_marks(round)
      marks = round.is_a?(Hash) ? round["sweep"] : nil
      marks.is_a?(Hash) ? marks : {}
    end

    # The cause the sweep interrupted a review round's pane for (`review_timed_out` first): its keys went out, or are
    # going out (a pending claim younger than {INTERRUPT_CLAIM_SECONDS}, so a turn the press ends before it is
    # confirmed reads the same; an older one was left by a sweep that died before it pressed); nil when it pressed
    # none. A round interrupted is decided on the verdicts already written: none is run again.
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @param now [Time]
    # @return [String, nil]
    def self.round_interrupted(round, now)
      marks = round_sweep_marks(round)
      ROUND_INTERRUPT_KEYS.find { |_, key| interrupt_mark_live?(marks[key], now) }&.first
    end

    # Whether the sweep's keys went out, or are going out, for the run's current attempt under any of
    # {INTERRUPT_MARK_KEYS}: one press serves every cause due on the attempt.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Boolean]
    def self.attempt_interrupt_held?(run, now)
      marks = sweep_marks(run)
      INTERRUPT_MARK_KEYS.values.any? { |key| interrupt_mark_live?(marks[key], now) }
    end

    # A mark that stands for a press: `sent`, or `pending` and younger than {INTERRUPT_CLAIM_SECONDS}.
    def self.interrupt_mark_live?(mark, now)
      return false unless mark.is_a?(Hash)
      return true if mark["state"] == "sent"
      mark["state"] == "pending" && now - Time.iso8601(mark["at"].to_s) < INTERRUPT_CLAIM_SECONDS
    rescue ArgumentError, TypeError
      false
    end
    private_class_method :interrupt_mark_live?

    # When the sweep's keys last went out for a review round: the newest `sent` mark of {ROUND_INTERRUPT_KEYS}. A
    # `pending` claim is not a press: a sweep that pressed and died before it confirmed leaves one, which reads as no
    # press once it is older than {INTERRUPT_CLAIM_SECONDS} ({.round_interrupted}), so a later sweep may press again
    # and a turn that ends meanwhile may run missing reviewers again. That is accepted rather than recording the press
    # before the keys go out, which would read a press that never happened as one.
    #
    # @param round [Hash{String=>Object}, nil] a step's `review`
    # @return [Time, nil] nil when no press was confirmed
    def self.round_last_press(round)
      marks = round_sweep_marks(round)
      ROUND_INTERRUPT_KEYS.values.filter_map do |key|
        mark = marks[key]
        next unless mark.is_a?(Hash) && mark["state"] == "sent"
        begin
          Time.iso8601(mark["at"].to_s)
        rescue ArgumentError
          nil
        end
      end.max
    end

    # How long a review pane the sweep pressed may go on working before its round is decided without its turn's end:
    # the longer of the definition's `stall` and the round's `review.timeout` ({.review_timeout}), so a short `stall`
    # never cuts short a review whose sub-agents still write.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Numeric]
    def self.press_wait(run)
      [WorkflowDefinition.stall(run["definition"]).to_i, review_timeout(run)].max
    end

    # Whether a review round the sweep pressed ({.round_last_press}) has gone {.press_wait} since its newest press
    # with no turn's end deciding it. Its verdicts then decide it, or it stops `review_incomplete`, whether or not a
    # sweep runs again ({WorkflowRecovery#tick}, and the sweep's `interrupt_unanswered`).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}, nil] the current step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.press_unanswered?(run, round, now, stops: [])
      last = round_last_press(round)
      !last.nil? && WorkflowDeadline.active_seconds(last, now, step_stops(run, stops)) >= press_wait(run)
    end

    # A delivered review round (its `delivery` null) that is the run's, undecided, not being judged and with no stop,
    # whose press is unanswered ({.press_unanswered?}): {.wakeable?}'s `:unanswered`, so a tick decides it when no
    # sweep comes back to it.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.unanswered_round?(run, now, stops: [])
      return false if run["parked"] || slot(run, "reason")
      state = run.dig("steps", run["current"])
      return false unless state.is_a?(Hash) && state["state"] == "reviewing"
      round = state["review"]
      return false unless round.is_a?(Hash) && round.key?("delivery") && round["delivery"].nil? && round["pane"].is_a?(String)
      return false if round["recompute"] || round["ended_at"]
      press_unanswered?(run, round, now, stops: stops)
    end

    # Whether a round whose line may have been typed, its review pane at work and never interrupted by the sweep, has
    # run past twice its `review.timeout` ({.round_elapsed}): the sweep presses at the first, so past the second no
    # sweep is coming and the round stops for a person. A start that can't be read has run past it.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param round [Hash{String=>Object}] the current step's `review`
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.typed_press_missed?(run, round, now, stops: [])
      elapsed = round_elapsed(run, round, now, stops: stops)
      elapsed.nil? || elapsed > 2 * review_timeout(run)
    end

    # Seconds left before a failed round's delivery again; a failure time that can't be read waits no longer.
    def self.round_backoff(round, retries, now)
      (Time.iso8601(round.dig("failure", "at").to_s) + REDELIVER_BACKOFF[[retries, REDELIVER_BACKOFF.size - 1].min] - now).ceil.clamp(0..)
    rescue ArgumentError, TypeError
      0
    end
    private_class_method :round_backoff

    # Where the sweep's retry of an undelivered line stands. The step must wait on a failed delivery (reason
    # `waiting_you`, kind `dispatch`, a code in {REDELIVER_CODES}), with no park, its last attempt ended
    # `not_delivered`, and the definition's `redeliver` above 0. Attempts the sweep already retried carry
    # `redelivered: true`, and do not count against `max_attempts`.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Hash, nil] nil when no retry applies; else :state (`:due`, `:waiting` for the backoff, `:exhausted`),
    #   :retries (done), :limit, :wait (seconds left), :code
    def self.redelivery(run, now)
      limit = WorkflowDefinition.redeliver(run["definition"])
      # A fan_out sibling waits on its own while the others keep the run `running`: its own step's state says so below.
      return nil if limit.zero? || run["parked"] || (run["state"] != "waiting" && !WorkflowRun.step_scoped?(run, run["current"]))
      reason = slot(run, "reason")
      details = reason.is_a?(Hash) ? reason["details"] : nil
      return nil unless reason.is_a?(Hash) && reason["code"] == "waiting_you" && details.is_a?(Hash) && details["kind"] == "dispatch"
      return nil unless REDELIVER_CODES.include?(details["error"]) && !REDELIVER_NEVER_REASONS.include?(details["reason"])
      state = run.dig("steps", run["current"])
      attempts = state.is_a?(Hash) ? state["attempts"] : nil
      last = attempts.is_a?(Array) ? attempts.last : nil
      return nil unless state["state"] == "waiting" && last.is_a?(Hash) && last["outcome"] == "not_delivered" && !last["redelivered"]
      # `redelivery` is set on an attempt the sweep started: a person's resume starts the count again.
      retries = last["redelivery"].is_a?(Integer) ? last["redelivery"] : 0
      info = {retries: retries, limit: limit, code: details["error"]}
      return info.merge(state: :exhausted, wait: 0) if retries >= limit
      wait = Time.iso8601(last["ended_at"].to_s) + REDELIVER_BACKOFF[[retries, REDELIVER_BACKOFF.size - 1].min] - now
      (wait > 0) ? info.merge(state: :waiting, wait: wait.ceil) : info.merge(state: :due, wait: 0)
    rescue ArgumentError, TypeError, NoMethodError
      nil
    end

    # Where an `on_fail` retry's wait stands. A step that failed with `on_fail: {backoff: ...}` stores `backoff` on
    # the run (`until`, `to`, `text`, `context`) and reads `waiting` with the reason `retry_backoff`; nothing is
    # held meanwhile (no attempt, binding or lock). The retry starts when the time has come: by {#tick}, by
    # `workflow sweep` ({#retry_backoff}), or at once by a person's resume.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Hash, nil] nil when the run waits out no backoff (an old run too); else :state (`:waiting` or
    #   `:due`), :wait (seconds left, 0 when due), :until (ISO time), :to (the step the retry goes back to)
    def self.backoff(run, now)
      stored = slot(run, "backoff")
      return nil unless stored.is_a?(Hash) && run["state"] == "waiting" && stored["to"].is_a?(String) && !stored["blocked"]
      # A time that can't be read is taken as over: a wait must not outlast what could be measured.
      wait = begin
        Time.iso8601(stored["until"].to_s) - now
      rescue ArgumentError
        0
      end
      {state: (wait > 0) ? :waiting : :due, wait: [wait.ceil, 0].max, until: stored["until"], to: stored["to"]}
    end

    # Where a run's parked resume stands.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :waiting, :expired (an unreadable time too), or nil with no park
    def self.parked(run, now)
      parked = run["parked"]
      return nil unless parked
      (now > Time.iso8601(parked["expires_at"])) ? :expired : :waiting
    rescue ArgumentError, TypeError
      :expired
    end

    # The one wording of a parked resume that ran out of time.
    #
    # @param pane [String] the pane the resume waited on
    # @param checking [Boolean] the step reads `checking`, so a check's result may have been thrown away
    # @return [String]
    def self.park_timeout_message(pane, checking: false)
      text = "the turn in pane #{pane} did not end within 1 hour, so nothing was typed. Any --from or --pane on that resume was not applied, " \
        "and a note is kept for the next attempt. Resume the run again. A step still running is decided as usual when its turn ends."
      return text unless checking
      "#{text} A check that finished while this was parked was not recorded; resume the run to run it again."
    end

    # Seconds a parked resume waits for its turn to end, and a `continue_pending` mark for its pane to prove idle.
    PARK_SECONDS = 3600

    # The one line typed into a pane whose turn `pause --interrupt` stopped, once the run is unpaused and the pane
    # is idle: the step and its instructions file, never the instructions again.
    CONTINUE_LINE = "Continue step %s. Your instructions are still in %s."

    # Whether a continue mark (`paused.interrupt` or `continue_pending`: "pane", "pid", "kind", "step", "attempt")
    # still names the run's current step and its open, `running` attempt. A mark for an attempt that ended, or a
    # step the run moved past, is ignored.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param mark [Hash{String=>Object}, nil]
    # @return [Boolean]
    def self.continue_mark?(run, mark)
      return false unless mark.is_a?(Hash) && mark["step"] == run["current"]
      state = run.dig("steps", run["current"])
      return false unless state.is_a?(Hash) && state["state"] == "running"
      attempt = Array(state["attempts"]).last
      attempt.is_a?(Hash) && attempt["n"] == mark["attempt"] && attempt["ended_at"].nil?
    end

    # Where the run's `continue_pending` mark stands: `:due` while it names the open attempt ({.continue_mark?}) and
    # its `since` is no more than {PARK_SECONDS} ago, `:expired` once it is older (or has no readable `since`), nil
    # when there is no mark or it names an attempt the run moved past.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :due, :expired or nil
    def self.continue_state(run, now)
      mark = slot(run, "continue_pending")
      return nil unless continue_mark?(run, mark)
      since = Time.iso8601(mark["since"].to_s)
      (now - since > PARK_SECONDS) ? :expired : :due
    rescue ArgumentError
      :expired
    end

    # @param run [Hash{String=>Object}] a stored run on the step the line is for
    # @return [String] {CONTINUE_LINE} for the run's current step and its last attempt's instructions file
    def self.continue_line(run)
      format(CONTINUE_LINE, run["current"], Array(run.dig("steps", run["current"], "attempts")).last&.fetch("prompt_file", nil))
    end

    # Whether a run is one only a timer will wake: a resume is parked on it,
    # an `on_fail` retry's backoff is over,
    # it waits for a lock, its check was started and never reported back
    # (the process running it died), judged by the check's time limit plus a
    # minute, it has been held for background tasks longer than
    # {BACKGROUND_HOLD}, or the end of its review round was being judged and
    # nothing reported back ({.lost_round?}), or its review round has to be
    # delivered again, or stopped once its deliveries again are spent ({.round_redelivery}), or its delivered
    # review round was pressed by the sweep and has not answered ({.unanswered_round?}), or a `continue_pending`
    # mark still names its open attempt ({.continue_state}): `:continue` while it is due (the tick types the continue
    # line once the pane proves idle), `:continue_expired` once it is older than {PARK_SECONDS} (the tick drops it).
    # A paused run is never woken, so a pending mark waits for the next unpause.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @param alive [#call, nil] given a review round's `holder`, whether it still runs (see {.round_delivery}); nil
    #   takes every holder as alive, so a lapsed round with a holder is not woken
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # A fan_out sibling's deferred failure move whose wait is over, in a group at rest ({.join_due}), wakes as :join:
    # the tick runs the group's join, which applies the move; the tick itself never starts it.
    #
    # @return [Symbol, nil] :parked, :continue, :continue_expired, :backoff (a retry's wait is over), :join, :infra_retry (a running step's infra retry is due or its claim is stale, {.infra_retry}), :lock, :background, :round, :unanswered, :review, :check, or nil
    def self.wakeable?(run, now, alive: nil, stops: [])
      return nil if run["paused"]
      return :parked if run["parked"]
      case continue_state(run, now)
      when :due then return :continue
      when :expired then return :continue_expired
      end
      return :backoff if backoff(run, now)&.fetch(:state) == :due
      return :join if join_due(run, now)
      return :infra_retry if infra_retry_wakes?(run, now)
      return :lock if slot_dig(run, "reason", "code") == "waiting_lock"
      return :background if background_expired?(slot(run, "reason"), now)
      # A park that failed left its reason on a checking step: that run waits for a person's resume.
      return :round if lost_round?(run, now, stops: stops)
      return :unanswered if unanswered_round?(run, now, stops: stops)
      return :review if %i[due exhausted].include?(round_redelivery(run, now, alive: alive)&.fetch(:state))
      :check if slot(run, "reason").nil? && lost_check?(run, now)
    end

    # The {.wakeable?} causes a fan_out sibling that is not the cursor's step wakes for, read on its own step: a
    # continue line, its infra retry, a background hold that ran out, a check that never reported back. The cursor's
    # step wakes for any cause.
    SIBLING_WAKES = %i[continue continue_expired infra_retry background check].freeze

    # {.wakeable?} for the cursor's step, else for the first other fan_out sibling under way ({.step_views}) that
    # wakes for one of {SIBLING_WAKES}.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @param alive [#call, nil] see {.wakeable?}
    # @param stops [Array<Hash{String=>Object}>] see {.wakeable?}
    # @return [Array(Symbol, Hash), nil] the cause and the run read on the step that wakes; nil when none does
    def self.step_wake(run, now, alive: nil, stops: [])
      cause = wakeable?(run, now, alive: alive, stops: stops)
      return [cause, run] if cause
      step_views(run).drop(1).each do |view|
        found = wakeable?(view, now, alive: alive, stops: stops)
        return [found, view] if SIBLING_WAKES.include?(found)
      end
      nil
    end

    # Whether the end of the current step's review round was being judged and nothing reported back: its revision
    # was being computed again with the lock given up (the round's `recompute` mark) and the mark is older than
    # {DELIVERY_WINDOW}, so the process doing it died. The sibling of {.lost_check?}, which stays `checking`-only.
    # A round stopped for a person (a stored reason) or a parked run is never lost.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Boolean]
    def self.lost_round?(run, now, stops: [])
      return false if run["parked"] || slot(run, "reason")
      state = run.dig("steps", run["current"])
      return false unless state.is_a?(Hash) && state["state"] == "reviewing"
      mark = state["review"].is_a?(Hash) ? state["review"]["recompute"] : nil
      return false unless mark.is_a?(Hash)
      WorkflowDeadline.active_seconds(Time.iso8601(mark["started_at"].to_s), now, Array(stops)) > DELIVERY_WINDOW
    rescue ArgumentError, TypeError
      true
    end

    # Whether nothing is left to report the current step's check: its process
    # died, or a park threw its result away (a park that ended left a reason
    # on the step, or one past its limit is still stored).
    #
    # @param run [Hash] the run file
    # @param now [Time]
    # @return [Boolean]
    def self.lost_check?(run, now)
      state = run["steps"].fetch(run["current"])
      return false unless state["state"] == "checking"
      return true if slot(run, "reason") || parked(run, now) == :expired
      attempt = state["attempts"].last
      # A `require:` proof outside the run's lock has its own start and limit; a run stored without `proofs` has neither.
      proof = Array(attempt&.dig("proofs")).find { |each| !each.key?("ended_at") }
      return now - Time.iso8601(proof["started_at"]) > WorkflowRequire.lost_after(proof) if proof
      started = attempt&.dig("check", "started_at")
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      timeout = step.dig("status", "timeout") || WorkflowDefinition::DEFAULT_CHECK_TIMEOUT
      started.nil? || now - Time.iso8601(started) > timeout + 60
    end

    # A running step whose infra retry is due, or whose claim is older than {INFRA_RETRY_CLAIM_WINDOW}.
    def self.infra_retry_wakes?(run, now)
      return false unless run.dig("steps", run["current"], "state") == "running"
      %i[due stale_claim].include?(infra_retry(run, now)&.fetch(:state))
    end
    private_class_method :infra_retry_wakes?

    # A hold with no readable `seen_at` has nothing to measure it by, so it counts as expired.
    def self.background_expired?(reason, now)
      return false unless reason && reason["code"] == "turn_ended_background"
      now - Time.iso8601(reason["seen_at"].to_s) > BACKGROUND_HOLD
    rescue ArgumentError
      true
    end
    private_class_method :background_expired?

    # The marks the sweep left on the run's current attempt: "stalled" and "recovered" (cause => time) and
    # "interrupt" (a step timeout's press) and "run_interrupt" (the run timeout's press) and "budget_interrupt" (the token budget's press), each `state` `pending`
    # or `sent` and `at`. Empty once the run is on another step or attempt.
    #
    # A fan_out sibling keeps its marks under its own step hash ({WorkflowRun.slots}), so two siblings the sweep acts
    # on in one pass keep apart; every other step keeps them at the run's top level.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Hash{String=>Object}]
    def self.sweep_marks(run)
      marks = WorkflowRun.slot(run, run["current"], "sweep")
      attempt = run.dig("steps", run["current"], "attempts")&.last&.fetch("n", nil)
      (marks.is_a?(Hash) && marks["step"] == run["current"] && marks["attempt"] == attempt) ? marks : {}
    end

    # Whether a reason is the hold for a turn that ended with background tasks listed.
    #
    # @param reason [Hash, nil] a run's `reason`
    # @return [Boolean]
    def self.hold?(reason)
      reason && reason["code"] == "turn_ended_background"
    end

    # A hold shows nothing that moves, so only its code and since count; its seen_at, tasks and missing change nothing a reader sees.
    #
    # @param reason [Hash, nil] a run's `reason`
    # @return [Hash, nil]
    def self.shown_reason(reason)
      hold?(reason) ? reason.slice("code", "since") : reason&.except("seen_at")
    end

    # What `workflow status` shows of a run's progress; a change in it is announced.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Array]
    def self.fingerprint(run)
      state = run["steps"].fetch(run["current"])
      [run["state"], run["current"], shown_reason(slot(run, "reason")), state["state"], state["attempts"].size, state.dig("gate", "state"), run.key?("parked")]
    end

    # Whether a sweep's view (step and attempt it saw) still describes the run, so the sweep may change it.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] the step the sweep saw
    # @param attempt [Integer, nil] that step's last attempt the sweep saw
    # @param running [Boolean, Symbol, nil] true or :or_incomplete when the step must be running and undecided
    # @param now [Time]
    # @return [Boolean]
    def self.sweep_target?(run, step, attempt, running, now)
      # A step that belongs to a group runs beside its siblings, so it need not be the cursor's step.
      return false unless run["current"] == step || WorkflowRun.step_scoped?(run, step)
      state = run["steps"].fetch(step)
      last = state["attempts"].last
      return false unless last&.fetch("n", nil) == attempt
      return true unless running
      return false unless state["state"] == "running" && !run["parked"] && delivery(last, now) != :delivering
      slot(run, "reason", step).nil? || (running == :or_incomplete && slot_dig(run, "reason", "code", step: step) == "turn_ended_incomplete")
    end

    # Why a resume does nothing for the step as it stands; nil when it acts.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param state [Hash] the current step's state
    # @param pane [String, nil] the pane the resume names
    # @param turn_over [Hash, nil] the turn's end seen (`step`, `attempt`)
    # @param now [Time]
    # @param bound_pane [#call] the run's bound pane, read only to word the refusal
    # @param alive [#call, nil] given a review round's delivery `holder`, whether it still runs (see {.round_delivery})
    # @return [String, nil]
    def self.left_alone(run, state, pane, turn_over, now, bound_pane, alive: nil)
      case state["state"]
      when "running"
        # Another process is still typing this attempt's line; typing it again would start the step twice.
        if !pane && delivery(state["attempts"].last, now) == :delivering
          return "step #{run["current"]}'s line is still being delivered to pane #{bound_pane.call}"
        end
        # The turn's end counts only for the attempt it was seen on: the run may have moved on since.
        over = turn_over && turn_over["step"] == run["current"] && turn_over["attempt"] == state["attempts"].last&.fetch("n", nil)
        "an agent is working on step #{run["current"]}" unless pane || slot(run, "reason") || over
      when "checking"
        "the check of step #{run["current"]} is still running" unless lost_check?(run, now)
      when "reviewing"
        # A round stopped for a person, or one whose delivery failed or lapsed (past the window with its holder gone),
        # is the resume's to act on.
        unless slot(run, "reason") || %i[failed unknown].include?(round_delivery(state["review"], now, alive: alive))
          "the review round of step #{run["current"]} is still running"
        end
      end
    end

    # Whether `workflow resume --restart-step` may close the step's open attempt as interrupted and start a new one.
    # Reads nothing but its arguments.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param state [Hash] the current step's state
    # @param now [Time]
    # @param bound [String] the bound pane: "gone", "shell", "failed", "idle", "busy" or "unknown"
    # @return [Workspace::Error, nil] the refusal to raise; nil when the restart may go ahead
    def self.restart_refusal(run, state, now, bound)
      last = state["attempts"]&.last
      ids = {"run_id" => run["id"], "step" => run["current"]}
      if state["state"] != "running" || last.nil? || last["ended_at"]
        return Workspace::Error.new("Step #{run["current"]} is #{state["state"]} and has nothing running to restart. " \
          "`workspace workflow resume #{run["id"]}` moves it on. Nothing was changed.",
          code: "no_open_attempt", details: ids.merge("state" => state["state"]))
      end
      if delivery(last, now) == :delivering
        return Workspace::Error.new("Step #{run["current"]}'s line is still being typed. Wait a few seconds, then run the command again. Nothing was changed.",
          code: "step_still_working", details: ids.merge("reason" => "delivering"))
      end
      return nil if %w[gone shell failed idle].include?(bound)
      return nil if bound == "unknown" && (open_stalls(run) & %w[pane_gone agent_gone]).any?
      Workspace::Error.new("The agent is still working on step #{run["current"]}. Wait for its turn to end, or interrupt it in its pane (Escape), then run the command again. Nothing was changed.",
        code: "step_still_working", details: ids.merge("reason" => (bound == "busy") ? "working" : "unknown"))
    end

    # The reason a turn's end leaves on a run: a fresh one, or the stored one when it is the same stop (same code,
    # step and attempt) and no new turn has started since, so its `since` holds.
    #
    # @param stored [Hash, nil] the run's current reason
    # @param turn_started [Time, nil]
    # @param code [String]
    # @param details [Hash]
    # @param since [String] ISO time for a fresh reason
    # @return [Hash]
    def self.stop_reason(stored, turn_started, code, details, since)
      fresh = {"code" => code, "since" => since, "details" => details}
      return fresh unless stored && stored["code"] == code && stored["since"]
      return fresh unless %w[step attempt].all? { |key| stored.dig("details", key) == details[key] }
      return fresh if turn_started && turn_started.to_i > Time.iso8601(stored["since"]).to_i
      fresh.merge("since" => stored["since"])
    end

    # Where a failed step goes, read once its failed attempt is stored: back along its `on_fail` (`to` its goto,
    # `count` the edge's loop count after this one, `wait` the backoff seconds or nil), or, when the step has none,
    # back to the step before it in the definition ({implicit_loop_stops?} and guard and unproven failures
    # excepted — a loop cannot fix them — and never past the first step, which stops for a person). `:stop` for a
    # person also when the loops or the run's attempts are used up, the goto step's own cap is spent (`limit: :step`,
    # `step:` the goto; only that step is checked, though a loop re-runs every step from it to the failing one), the
    # failure's code or cause is one of its `except:`, or the step says `on_fail: stop`
    # (so a run is never sent into a step that cannot pass against the same facts).
    #
    # @param run [Hash{String=>Object}] a stored run at the failed step
    # @param failure [Hash{String=>Object}] its "cause" and "code"
    # @param step [String] the failed step: the cursor's unless given. A fan_out sibling's failure names its own step,
    #   since the cursor names only the sibling dispatched last. A sibling with no `on_fail` of its own, in a group whose
    #   `on_fail` is a goto, is decided by its group ({.group_failure_move}).
    # @return [Hash{Symbol=>Object}] `{kind: :loop, edge:, to:, count:, wait:}`, a group move ({.group_failure_move})
    #   or `{kind: :stop}`
    def self.after_failure(run, failure, step: run["current"])
      step_id = step
      step = run["definition"]["steps"].find { |each| each["id"] == step_id }
      on_fail = step["on_fail"]
      if on_fail.nil? && grouped?(step) && WorkflowDefinition.group_on_fail(run["definition"], step["group"]).is_a?(Hash)
        return group_failure_move(run, step["group"], failure)
      end
      return implicit_failure_move(run, step, failure) if on_fail.nil?
      return {kind: :stop} if on_fail == "stop" || goto_excepted?(on_fail, failure)
      edge = "#{step["id"]}->#{on_fail["goto"]}"
      goto_stop(run, on_fail, edge) || goto_loop(run, on_fail, edge)
    end

    # @param on_fail [Hash{String=>Object}] a step's or a group's `on_fail` goto
    # @param failure [Hash{String=>Object}] a failure's "cause" and "code"
    # @return [Boolean] whether the failure's code or cause is one of the goto's `except:`
    def self.goto_excepted?(on_fail, failure)
      Array(on_fail["except"]).any? { |name| name == failure["code"] || name == failure["cause"] }
    end
    private_class_method :goto_excepted?

    # The stop a goto's limits call for: the edge's loops at `max` or the run's attempts spent (`{kind: :stop}`), or the
    # goto step's own cap spent (`limit: :step`, `step:` the goto), then the own cap of the first of +rerun+ that is spent
    # (`step:` that step); nil when the goto may loop.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param on_fail [Hash{String=>Object}] a step's or a group's `on_fail` goto
    # @param edge [String] the loop's edge
    # @param rerun [Array<String>] the steps besides the goto that the loop runs again and whose own caps it checks
    # @return [Hash{Symbol=>Object}, nil]
    def self.goto_stop(run, on_fail, edge, rerun: [])
      return {kind: :stop} if run["loops"].fetch(edge, 0) >= on_fail["max"] || attempts_made(run) >= attempt_allowance(run)
      spent = [on_fail["goto"], *rerun].find { |id| step_attempts_spent?(run, id) }
      {kind: :stop, limit: :step, step: spent} if spent
    end
    private_class_method :goto_stop

    # @param run [Hash{String=>Object}] a stored run
    # @param on_fail [Hash{String=>Object}] a step's or a group's `on_fail` goto
    # @param edge [String] the loop's edge
    # @return [Hash{Symbol=>Object}] `{kind: :loop, edge:, to:, count:, wait:}`, `count` the edge's loops after this one
    def self.goto_loop(run, on_fail, edge)
      {kind: :loop, edge: edge, to: on_fail["goto"], count: run["loops"].fetch(edge, 0) + 1, wait: WorkflowDefinition.backoff(on_fail)}
    end
    private_class_method :goto_loop

    # Where a sibling's failure goes under its group's `on_fail` goto, read as a step's explicit goto is
    # ({.after_failure}) on the edge `GROUP->STEP`: `:stop` when the failure's code or cause is one of its `except:`,
    # the edge's loops are used up, the run's attempts are spent, or the goto step's own cap is, or the own cap of a
    # sibling of the group (each runs again when the run comes back to the group; `limit: :step`, `step:` the first). It
    # never asks {.implicit_loop_stops?}, so a guard, unproven, `check_error` or `step_timed_out` failure loops, as under
    # a step's explicit `on_fail`. When the group already owes its move in this drain ({.group_move_owed?}), a failure
    # that is not excepted joins that move (`joined: true`) and is not checked against `max`, since the first failure
    # already counted the loop.
    #
    # @param run [Hash{String=>Object}] a stored run at the failed sibling
    # @param group [String] the sibling's fan_out group, whose `on_fail` is a goto
    # @param failure [Hash{String=>Object}] its "cause" and "code"
    # @return [Hash{Symbol=>Object}] `{kind: :loop, group:, edge:, to:, count:, wait:}`, `{kind: :loop, group:, joined: true}`
    #   or `{kind: :stop}` (with `limit: :step, step:` when the goto step's or a sibling's cap is spent)
    def self.group_failure_move(run, group, failure)
      on_fail = WorkflowDefinition.group_on_fail(run["definition"], group)
      return {kind: :stop} if goto_excepted?(on_fail, failure)
      return {kind: :loop, group: group, joined: true} if group_move_owed?(run, group)
      edge = "#{group}->#{on_fail["goto"]}"
      goto_stop(run, on_fail, edge, rerun: Array(WorkflowDefinition.group_steps(run["definition"])[group])) || goto_loop(run, on_fail, edge).merge(group: group)
    end
    private_class_method :group_failure_move

    # Whether a fan_out group already owes its `on_fail` goto in this drain: one of its siblings holds a `pending_move`
    # tagged with the group (`"group" => GROUP`).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param group [String] a fan_out group's id
    # @return [Boolean]
    def self.group_move_owed?(run, group)
      Array(WorkflowDefinition.group_steps(run["definition"])[group]).any? do |id|
        next false unless run.dig("steps", id).is_a?(Hash)
        move = slot(run, "pending_move", id)
        move.is_a?(Hash) && move["group"] == group
      end
    end

    # Whether a failure is one no loop can fix, read from the fail sites: a guard stop is the
    # checkout disagreeing with the run, an `unproven` require proof is one the engine could not
    # decide, `check_error` is the check or guard not having run at all, and `step_timed_out` the
    # step outliving its time. (`check_timed_out` loops: an agent's own code can hang a check.)
    #
    # @param failure [Hash{String=>Object}] a step failure's "cause" and "code"
    # @return [Boolean]
    def self.implicit_loop_stops?(failure)
      failure["cause"] == "guard" || failure["unproven"] == true || %w[check_error step_timed_out].include?(failure["code"])
    end

    # A step's first decided `require:` failure in the run ({.own_require_retry?}) runs the step itself again, told
    # why: its work is likely done but unproven (edited, not committed), and the step before has nothing new to give
    # it. A repeated require failure, and every other failure, goes back to the step before.
    # The step before is scoped by fan_out groups ({.implicit_target}): a sibling goes back only to the sibling before it
    # (the group's first sibling stops), and a step outside any group skips a group's siblings to the nearest step
    # before it that is in no group (none, for a group at the start, stops), so no implicit move crosses into or out of
    # a group.
    #
    # @param run [Hash{String=>Object}] a stored run at the failed step
    # @param step [Hash{String=>Object}] the failing step's definition
    # @param failure [Hash{String=>Object}] its "cause" and "code"
    # @return [Hash{Symbol=>Object}] `{kind: :loop, edge:, to:, count:, wait: nil}` or `{kind: :stop}`
    def self.implicit_failure_move(run, step, failure)
      return {kind: :stop} if implicit_loop_stops?(failure)
      self_edge = "#{step["id"]}->#{step["id"]}"
      if own_require_retry?(run, step, failure, self_edge)
        return {kind: :stop} if attempts_made(run) >= attempt_allowance(run)
        return {kind: :stop, limit: :step, step: step["id"]} if step_attempts_spent?(run, step["id"])
        return {kind: :loop, edge: self_edge, to: step["id"], count: 1, wait: nil}
      end
      prev = implicit_target(run["definition"]["steps"], step)
      return {kind: :stop} unless prev
      return {kind: :stop} if attempts_made(run) >= attempt_allowance(run)
      # The loop hands the failure to the step before and, once it passes, runs this step again,
      # so both its own cap and the one before's are checked.
      return {kind: :stop, limit: :step, step: step["id"]} if step_attempts_spent?(run, step["id"])
      return {kind: :stop, limit: :step, step: prev} if step_attempts_spent?(run, prev)
      edge = "#{step["id"]}->#{prev}"
      {kind: :loop, edge: edge, to: prev, count: run["loops"].fetch(edge, 0) + 1, wait: nil}
    end

    # Whether an implicit failure retries the failing step itself: a decided (never `unproven`) `require:` failure of a
    # step in no fan_out group, while its self edge (`ID->ID`) has no loop yet in the run.
    #
    # @param run [Hash{String=>Object}] a stored run at the failed step
    # @param step [Hash{String=>Object}] the failing step's definition
    # @param failure [Hash{String=>Object}] its "cause" and "code"
    # @param edge [String] the step's self edge
    # @return [Boolean]
    def self.own_require_retry?(run, step, failure, edge)
      failure["cause"] == "require" && !grouped?(step) && run["loops"].fetch(edge, 0).zero?
    end
    private_class_method :own_require_retry?

    # The step a failed step's implicit move goes back to: for a fan_out sibling, the sibling just before it (nil for
    # the group's first); for any other step, the nearest step before it that is in no group (nil when there is none).
    # In a definition with no groups this is always the step just before (nil for the first step).
    #
    # @param steps [Array<Hash{String=>Object}>] the stored definition's steps, in order
    # @param step [Hash{String=>Object}] the failing step's definition
    # @return [String, nil]
    def self.implicit_target(steps, step)
      index = steps.index { |each| each["id"] == step["id"] }
      return nil if index.to_i.zero?
      if grouped?(step)
        before = steps[index - 1]
        return (before["group"] == step["group"]) ? before["id"] : nil
      end
      steps[0...index].reverse.find { |each| !grouped?(each) }&.fetch("id")
    end

    # @param step [Hash{String=>Object}] a stored definition's step
    # @return [Boolean] whether the step is a fan_out sibling (it carries its group's id)
    def self.grouped?(step) = step["group"].is_a?(String) && !step["group"].empty?
    private_class_method :grouped?

    # Step states of a fan_out sibling whose agent is at work, or whose step a check or review round is deciding.
    SIBLING_BUSY = %w[running checking reviewing].freeze

    # The {WorkflowRun::PER_STEP_KEYS} slots that say nothing about whether a sibling owes an attempt: `reason` and
    # `reasons` are its stop and history ({.held_reason} reads the reason), `pending_context` is input for its next
    # attempt, `pending_move` has its own role in the join (owed only while its wait lasts, {.move_waits?}), and `sweep`
    # is the sweep's bookkeeping of what it saw and did, so a swept sibling still reads at rest.
    SIBLING_SLOTS_NOT_OWED = %w[reason reasons pending_context pending_move sweep].freeze

    # Every other {WorkflowRun::PER_STEP_KEYS} slot: one a sibling holds only while an attempt or a round is owed to
    # it (a retry wait, a continue line, a paused or lock-held dispatch, a review retry, a budget or timeout hold).
    # Derived, so a slot added to the run is owed until it is named in {SIBLING_SLOTS_NOT_OWED}.
    SIBLING_SLOTS_OWED = (WorkflowRun::PER_STEP_KEYS - SIBLING_SLOTS_NOT_OWED).freeze

    # Whether a fan_out sibling is at rest, as the join reads it: not at work ({SIBLING_BUSY}), not still to start
    # (`pending`), holding none of its {SIBLING_SLOTS_OWED} (read off its own step whatever the run's state, so a
    # sibling's budget hold counts while another sibling keeps the run `running`), not on a lock wait, not held by
    # anything {.held_reason} answers for (a gate waiting, a stored reason such as a pane gone, a pause, a park), and
    # not carrying a deferred failure move whose wait has yet to end. A deferred move with no wait, or one whose wait
    # has ended, is at rest: the join applies it.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a sibling's id
    # @param now [Time]
    # @param moves_due [Boolean] read every deferred move's wait as over (a stop in the drain drops the moves anyway)
    # @return [Boolean]
    def self.sibling_at_rest?(run, step, now, moves_due: false)
      state = run.dig("steps", step)
      return false unless state.is_a?(Hash)
      return false if SIBLING_BUSY.include?(state["state"]) || state["state"] == "pending"
      return false if held_reason(run, step: step)
      return false if SIBLING_SLOTS_OWED.any? { |key| !slot(run, key, step).nil? }
      return false if slot_dig(run, "reason", "code", step: step) == "waiting_lock"
      moves_due || !move_waits?(slot(run, "pending_move", step), now)
    end

    # @param run [Hash{String=>Object}] a stored run
    # @param steps [Array<String>] a fan_out group's sibling ids
    # @param now [Time]
    # @param moves_due [Boolean] see {.sibling_at_rest?}
    # @return [Boolean] whether every sibling is at rest ({.sibling_at_rest?})
    def self.group_at_rest?(run, steps, now, moves_due: false) = steps.all? { |id| sibling_at_rest?(run, id, now, moves_due: moves_due) }

    # Whether an attempt's failure move under +key+ (`move`, a sibling's own; `group_move`, its group's) was granted and
    # has not failed since.
    #
    # @param attempt [Hash{String=>Object}, nil]
    # @param key [String] "move" or "group_move"
    # @return [Boolean]
    def self.move_granted?(attempt, key = "move")
      move = attempt.is_a?(Hash) ? attempt[key] : nil
      move.is_a?(Hash) && !move.key?("failed")
    end

    # Whether a fan_out sibling stopped in its drain: it failed and its last attempt holds neither a granted move of its
    # own nor one of its group's ({.move_granted?}), so only a person moves it on.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a sibling's id
    # @return [Boolean]
    def self.sibling_stopped?(run, step)
      return false unless run.dig("steps", step, "state") == "failed"
      attempt = Array(run.dig("steps", step, "attempts")).last
      %w[move group_move].none? { |key| move_granted?(attempt, key) }
    end

    # Whether a deferred failure move (a sibling's `pending_move`) still waits out its backoff: its `until` is later
    # than +now+. A move with no `until` never waits; one whose `until` can't be read is taken as over.
    #
    # @param move [Hash{String=>Object}, nil]
    # @param now [Time]
    # @return [Boolean]
    def self.move_waits?(move, now)
      return false unless move.is_a?(Hash) && move["until"]
      Time.iso8601(move["until"].to_s) > now
    rescue ArgumentError
      false
    end

    # Whether the join owes a failed sibling its next run: the sibling's last attempt failed with a failure move that
    # was granted (its `move`, recorded when the move's loop was spent) and has since been applied (no `pending_move`
    # left), its application did not fail, and the run and the sibling still have an attempt left. This is the second
    # hop of the relay: the move ran the step it went back to, and now the failed sibling runs again, as a serial loop
    # runs the failing step again once the step it went back to passes.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param step [String] a sibling's id
    # @return [Boolean]
    def self.relay_owed?(run, step)
      state = run.dig("steps", step)
      return false unless state.is_a?(Hash) && state["state"] == "failed"
      return false unless move_granted?(Array(state["attempts"]).last)
      return false unless slot(run, "pending_move", step).nil?
      !attempts_spent?(run) && !step_attempts_spent?(run, step)
    end

    # The fan_out group whose deferred failure move a timer has to wake: a sibling carries a `pending_move` whose wait
    # has ended and its group is at rest, so the join ({WorkflowProgress#join}) applies it. Nil otherwise: a move
    # whose group is still at work is applied by the join that runs when the work ends.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [String, nil] the group's id
    def self.join_due(run, now)
      WorkflowDefinition.group_steps(run["definition"]).each do |group, ids|
        moving = ids.any? { |id| run.dig("steps", id).is_a?(Hash) && slot(run, "pending_move", id).is_a?(Hash) }
        return group if moving && group_at_rest?(run, ids, now)
      end
      nil
    end

    # The `details` of a `budget_spent` refusal or hold.
    #
    # @param run [Hash] a stored run
    # @param reading [Hash] its {WorkflowBudget.reading}
    # @param step [String, nil] the step the refusal or hold is of; the current step unless given
    # @return [Hash]
    def self.budget_details(run, reading, step: run["current"])
      {"run_id" => run["id"], "step" => step}.merge(reading.slice("used", "allowance", "counted", "uncounted", "estimated", "needed", "suggested"))
        .merge("tokens" => reading["tokens"], "extra_tokens" => reading["extra_tokens"])
    end

    # The `details` of a `run_timed_out` refusal or hold.
    #
    # @param run [Hash] a stored run
    # @param reading [Hash] its {WorkflowDeadline.reading}
    # @return [Hash]
    def self.deadline_details(run, reading)
      {"run_id" => run["id"], "step" => run["current"], "kind" => "timeout"}
        .merge(reading.slice("used", "limit", "needed", "suggested", "timeout", "extra_seconds"))
    end

    # The one code key of a failed step: an agent's word when it gave one, else the engine's.
    #
    # @param engine_code [String]
    # @param agent_code [String, nil]
    # @return [Hash{String=>String}] `code` and `code_source`
    def self.code_for(engine_code, agent_code)
      agent_code ? {"code" => agent_code, "code_source" => "agent"} : {"code" => engine_code, "code_source" => "engine"}
    end

    # The failure a step's unmet `require:` proof records.
    #
    # @param unmet [Hash{String=>Object}] the proof `WorkflowRequire#check` found unmet
    # @return [Hash{String=>Object}]
    def self.require_failure(unmet)
      {"cause" => "require", "require" => unmet["proof"], "detail" => unmet["detail"], "unproven" => unmet["unproven"],
       "required" => unmet["required"], "found" => unmet["found"], "base" => unmet["base"], "paths" => unmet["paths"],
       "reason" => unmet["reason"], "error" => unmet["error"], "exit_code" => unmet["exit_code"], "log" => unmet["log"], "program" => unmet["program"],
       "before" => unmet["before"], "after" => unmet["after"]}
        .compact.merge(code_for(unmet["code"], nil))
    end

    # Whether a run stopped on a guard that no resume can get past: `no_commit` with no `base_sha` recorded at the
    # run's start (an unborn branch), so every guarded step compares to a nil base. Any other guard stop (a moved
    # HEAD, changed hooks, hidden files, a `no_commit` with a base) passes again once the checkout is put back.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @return [Boolean]
    def self.guard_unrecoverable?(run)
      run = run.to_h
      reason = slot(run, "reason")
      return false unless reason.is_a?(Hash) && reason["code"] == "failed_check"
      details = reason["details"]
      details.is_a?(Hash) && details["cause"] == "guard" && details["guard"] == "no_commit" && run["base_sha"].to_s.empty?
    end

    # The reasons a review round stops the run with, the one list every reader of a stopped round matches against
    # (`review_custom_socket` and the other review codes are errors, not stops).
    REVIEW_STOPS = %w[review_incomplete review_rejected review_stale review_guard review_tampered review_rounds_spent review_no_change].freeze

    # The revision of the step's last decided round when that round rejected the step: the `review_outcome` of the
    # newest earlier attempt that has one, read only when it did not pass. A round about to judge this revision again
    # would judge what was rejected unchanged (`review_no_change`). Nil for a step whose last decided round passed,
    # with none decided, or for an outcome stored before it recorded its revision.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param step [String] a step id
    # @return [Hash{String=>Object}, nil] "revision", "round" and "attempt" of that rejected round
    def self.rejected_revision(run, step)
      attempts = run.to_h.dig("steps", step, "attempts")
      return nil unless attempts.is_a?(Array)
      decided = attempts[0...-1].reverse.find { |attempt| attempt.is_a?(Hash) && attempt["review_outcome"].is_a?(Hash) }
      outcome = decided && decided["review_outcome"]
      return nil unless outcome && outcome["passed"] == false && outcome["revision"].is_a?(String) && !outcome["revision"].empty?
      {"revision" => outcome["revision"], "round" => outcome["round"], "attempt" => decided["n"]}
    end

    # Whether the run still waits for the delivery of the round +pending+ names: {.round_waits?}, and the round's mark
    # `delivering` with its end not being judged (no `recompute`). The test every delivery that runs with the lock
    # given up makes before it writes back.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param pending [Hash{String=>Object}] "step", "attempt" and "round" of the delivery
    # @return [Boolean]
    def self.round_delivery_wanted?(run, pending)
      round = round_waits?(run, pending)
      round ? round["delivery"] == "delivering" && !round["recompute"] : false
    end

    # Whether the run still waits for the recompute of an ended round's revision +pending+ names: {.round_waits?}, and
    # the round's `recompute` mark that recompute's own try (a tick that took it for lost started another).
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param pending [Hash{String=>Object}] "step", "attempt", "round" and "try" of the recompute; a nil "try" is never wanted
    # @return [Boolean]
    def self.round_recompute_wanted?(run, pending)
      return false if pending["try"].nil?
      round = round_waits?(run, pending)
      round ? round.dig("recompute", "try") == pending["try"] : false
    end

    # The round when the run is still on the step, attempt and round +pending+ names, the step `reviewing`, with no
    # stop, no park and not ended; else nil.
    def self.round_waits?(run, pending)
      run = WorkflowRun.from_h(run)
      return nil if run.parked || run.reason_for(run.current) || WorkflowRunStore::TERMINAL_STATES.include?(run.state) || run.current != pending["step"]
      step = run.steps[pending["step"]]
      round = step&.review
      return nil unless step&.state == "reviewing" && step.last_attempt&.n == pending["attempt"] && round.is_a?(Hash) && round["round"] == pending["round"]
      round
    end
    private_class_method :round_waits?

    # The guard stops `workflow resume --accept-guard` takes: every guard that fails a step. `config_changed` is
    # only ever a warning, so it is not among them.
    ACCEPTABLE_GUARDS = %w[head_moved hooks_changed hidden_changed no_commit operation_in_progress tracked_changed].freeze

    # The guard a run is stopped by, when `resume --accept-guard` may take it: reason `failed_check` with a guard
    # cause in {ACCEPTABLE_GUARDS}, `no_commit` with no `base_sha` included.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @return [String, nil] the guard's code, nil for any other state or stop
    def self.acceptable_guard(run)
      run = run.to_h
      reason = slot(run, "reason")
      return nil unless run["state"] == "waiting" && reason.is_a?(Hash) && reason["code"] == "failed_check"
      details = reason["details"]
      return nil unless details.is_a?(Hash) && details["cause"] == "guard" && ACCEPTABLE_GUARDS.include?(details["guard"])
      state = run["steps"].is_a?(Hash) && run["steps"][run["current"]]
      (state.is_a?(Hash) && state["state"] == "failed") ? details["guard"] : nil
    end

    # Whether `resume --accept-guard` may take the run's stop; see {.acceptable_guard}.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @return [Boolean]
    def self.guard_acceptable?(run) = !acceptable_guard(run).nil?

    # The line put before the person's note in the next attempt's instructions once a guard stop is accepted.
    #
    # @param guard [String] the guard's code
    # @param step [String] the step it stopped
    # @param base_sha [String, nil] the run's base commit now; nil when the checkout has none
    # @return [String]
    def self.guard_accepted_line(guard, step, base_sha)
      return "A person accepted the `#{guard}` stop on `#{step}`; the checkout has no commit, so the guard has no HEAD to measure from." if base_sha.to_s.empty?
      "A person accepted the `#{guard}` stop on `#{step}`; the guard now measures from HEAD `#{base_sha[0, 12]}`."
    end

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run stopped on a guard
    # @return [String, nil] what to do before a resume can pass, nil for any other stop
    def self.guard_recovery(run)
      run = run.to_h
      details = slot_dig(run, "reason", "details")
      return nil unless slot_dig(run, "reason", "code") == "failed_check" && details.is_a?(Hash) && details["cause"] == "guard"
      return nil if guard_unrecoverable?(run)
      case details["guard"]
      when "head_moved" then "Move HEAD back to #{run["base_sha"].to_s[0, 12]} (save any work you want to keep, on a branch, first), then resume."
      when "hooks_changed" then "Restore the repository's hooks, then resume."
      when "hidden_changed" then "Clear the assume-unchanged or skip-worktree flags, then resume."
      when "no_commit" then "Check that the checkout has a commit, then resume."
      end
    end

    # @param failure [Hash{String=>Object}] a step's recorded failure
    # @return [String] the failure in words
    def self.failure_text(failure)
      if failure["cause"] == "timeout"
        "the step ran past its #{failure["timeout"]} second time limit (#{failure["elapsed"]} seconds in)"
      elsif failure["cause"] == "guard"
        case failure["guard"]
        when "head_moved" then "HEAD moved from #{failure["base_sha"].to_s[0, 12]} to #{failure["head"].to_s[0, 12]} since the run started"
        when "tracked_changed" then "tracked files changed since the run started (#{Array(failure["paths"]).join(", ")})"
        else GUARD_TEXT.fetch(failure["guard"], "the guard failed (#{failure["guard"]})")
        end
      elsif failure["cause"] == "require"
        "a required proof failed (#{failure["require"]}): #{failure["detail"]}"
      elsif failure["cause"] == "reported"
        "its agent reported failure#{": #{failure["summary"]}" if failure["summary"]}"
      elsif failure["timed_out"]
        "its check ran past its time limit (log: #{failure["log"]})"
      elsif failure["error"]
        "its check could not be run (#{failure["error"]})"
      else
        "its check exited #{failure["exit_code"].inspect} (log: #{failure["log"]})"
      end
    end
  end
end
