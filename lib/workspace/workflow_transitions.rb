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

    # How long a `turn_ended_background` hold lasts after the last Stop that listed tasks.
    BACKGROUND_HOLD = 90 * 60

    # Each guard code in words, for a failure or a warning.
    GUARD_TEXT = {
      "no_commit" => "the checkout had no commit to start from",
      "operation_in_progress" => "a git operation (merge, rebase, cherry-pick, revert or bisect) is in progress",
      "config_changed" => "the repository's config, attributes or replace refs changed",
      "hooks_changed" => "the repository's hooks changed since the run started",
      "hidden_changed" => "tracked files were hidden from git (assume-unchanged or skip-worktree) since the run started"
    }.freeze

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

    # Whether a resume would start a new attempt: `--from`, a run held for its token budget, a retry's wait, a step that failed or never
    # got its line, or a running step given a pane. Not a check or a turn left to decide (a failure there goes
    # through the `on_fail` budget), a passed step moving on, or a lock wait (the attempt was allowed when the
    # step was reached).
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param from [String, nil] the step a resume would start again at
    # @param pane [String, nil] the pane the resume would name
    # @return [Boolean]
    def self.starts_attempt?(run, from:, pane:)
      return true if from
      return true if run["budget_hold"].is_a?(Hash)
      return true if run["backoff"].is_a?(Hash) && run["backoff"]["to"].is_a?(String)
      return false if run.dig("reason", "code") == "waiting_lock"
      case run["steps"].fetch(run["current"])["state"]
      when "running" then !pane.nil?
      when "checking", "passed" then false
      else true
      end
    end

    # Where the line that starts an attempt stands. An attempt is stored as
    # `delivering` before its line is typed, outside the run's lock, and the
    # mark is cleared once the daemon answers or a turn's end shows the agent
    # had it. A mark older than {DELIVERY_WINDOW} was left by a process that
    # died while it waited: the line may or may not have reached the agent.
    #
    # @param attempt [Hash{String=>Object}, nil] a step's last attempt
    # @param now [Time]
    # @return [Symbol, nil] :delivering, :unknown, or nil when the line was delivered or never sent
    def self.delivery(attempt, now)
      return nil unless attempt && attempt["delivery"] == "delivering"
      (now - Time.iso8601(attempt["started_at"]) > DELIVERY_WINDOW) ? :unknown : :delivering
    rescue ArgumentError, TypeError
      :unknown
    end

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
      return nil if limit.zero? || run["parked"] || run["state"] != "waiting"
      reason = run["reason"]
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
      stored = run["backoff"]
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

    # Whether a run is one only a timer will wake: a resume is parked on it,
    # an `on_fail` retry's backoff is over,
    # it waits for a lock, its check was started and never reported back
    # (the process running it died), judged by the check's time limit plus a
    # minute, or it has been held for background tasks longer than
    # {BACKGROUND_HOLD}.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time]
    # @return [Symbol, nil] :parked, :backoff (a retry's wait is over), :lock, :background, :check, or nil
    def self.wakeable?(run, now)
      return :parked if run["parked"]
      return :backoff if backoff(run, now)&.fetch(:state) == :due
      return :lock if run.dig("reason", "code") == "waiting_lock"
      return :background if background_expired?(run["reason"], now)
      # A park that failed left its reason on a checking step: that run waits for a person's resume.
      :check if run["reason"].nil? && lost_check?(run, now)
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
      return true if run["reason"] || parked(run, now) == :expired
      attempt = state["attempts"].last
      # A `require:` proof outside the run's lock has its own start and limit; a run stored without `proofs` has neither.
      proof = Array(attempt&.dig("proofs")).find { |each| !each.key?("ended_at") }
      return now - Time.iso8601(proof["started_at"]) > WorkflowRequire.lost_after(proof) if proof
      started = attempt&.dig("check", "started_at")
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      timeout = step.dig("status", "timeout") || WorkflowDefinition::DEFAULT_CHECK_TIMEOUT
      started.nil? || now - Time.iso8601(started) > timeout + 60
    end

    # A hold with no readable `seen_at` has nothing to measure it by, so it counts as expired.
    def self.background_expired?(reason, now)
      return false unless reason && reason["code"] == "turn_ended_background"
      now - Time.iso8601(reason["seen_at"].to_s) > BACKGROUND_HOLD
    rescue ArgumentError
      true
    end
    private_class_method :background_expired?

    # The marks the sweep left on the run's current attempt: "stalled" and "recovered" (cause => time) and
    # "interrupt" (`state` `pending` or `sent`, and `at`). Empty once the run is on another step or attempt.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @return [Hash{String=>Object}]
    def self.sweep_marks(run)
      marks = run["sweep"]
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
      [run["state"], run["current"], shown_reason(run["reason"]), state["state"], state["attempts"].size, state.dig("gate", "state"), run.key?("parked")]
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
      return false unless run["current"] == step
      state = run["steps"].fetch(run["current"])
      last = state["attempts"].last
      return false unless last&.fetch("n", nil) == attempt
      return true unless running
      return false unless state["state"] == "running" && !run["parked"] && delivery(last, now) != :delivering
      run["reason"].nil? || (running == :or_incomplete && run.dig("reason", "code") == "turn_ended_incomplete")
    end

    # Why a resume does nothing for the step as it stands; nil when it acts.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param state [Hash] the current step's state
    # @param pane [String, nil] the pane the resume names
    # @param turn_over [Hash, nil] the turn's end seen (`step`, `attempt`)
    # @param now [Time]
    # @param bound_pane [#call] the run's bound pane, read only to word the refusal
    # @return [String, nil]
    def self.left_alone(run, state, pane, turn_over, now, bound_pane)
      case state["state"]
      when "running"
        # Another process is still typing this attempt's line; typing it again would start the step twice.
        if !pane && delivery(state["attempts"].last, now) == :delivering
          return "step #{run["current"]}'s line is still being delivered to pane #{bound_pane.call}"
        end
        # The turn's end counts only for the attempt it was seen on: the run may have moved on since.
        over = turn_over && turn_over["step"] == run["current"] && turn_over["attempt"] == state["attempts"].last&.fetch("n", nil)
        "an agent is working on step #{run["current"]}" unless pane || run["reason"] || over
      when "checking"
        "the check of step #{run["current"]} is still running" unless lost_check?(run, now)
      end
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

    # The `details` of a `budget_spent` refusal or hold.
    #
    # @param run [Hash] a stored run
    # @param reading [Hash] its {WorkflowBudget.reading}
    # @return [Hash]
    def self.budget_details(run, reading)
      {"run_id" => run["id"], "step" => run["current"]}.merge(reading.slice("used", "allowance", "counted", "uncounted", "needed", "suggested"))
        .merge("tokens" => reading["tokens"], "extra_tokens" => reading["extra_tokens"])
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
