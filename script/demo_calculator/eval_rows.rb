require "time"
require_relative "cost"

module DemoCalculator
  # Per-item eval rows from stored run hashes (string keys), their event hashes
  # and `workflow trace --json` totals. Pure: reads nothing, spawns nothing.
  module EvalRows
    FIRED = "fired".freeze
    MISSED = "missed".freeze
    ARMED = "armed".freeze
    UNKNOWN = Fmt::UNKNOWN

    SUCCESS_PATH = %w[status require expect_fail produces guard review fan_out].freeze
    FAILURE_ONLY = %w[backoff deny budget timeout].freeze
    # Events a person causes after the start; the dispatches and review starts that follow them are not counted.
    MANUAL_TYPES = %w[run_resumed review_rounds_extended attempts_extended budget_extended time_extended run_cancelled gate_approved gate_rejected
      guard_overridden run_paused run_unpaused resume_parked].freeze
    # Trace waiting reasons that wait for a person: a question, a gate, a pause, a failed check or a review stop that needs
    # a resume. Anything else (turn_ended_background, turn_ended_incomplete, a stalled pane, downtime, a lock) is the machine's.
    PERSON_WAIT_CODES = %w[waiting_you waiting_agent_input gate paused failed_check review_rejected review_incomplete].freeze
    FEATURES = (SUCCESS_PATH + FAILURE_ONLY).freeze

    # Every attempt of the run, step order, each tagged with "step".
    def self.attempts(run)
      (run["steps"] || {}).flat_map do |id, step|
        Array(step["attempts"]).map { |attempt| attempt.merge("step" => id) }
      end
    end

    # Declared features: a hash of feature => [step ids] ([] for run-level ones),
    # read from the run's stored definition.
    def self.declared(definition)
      steps = Array(definition["steps"])
      found = Hash.new { |h, k| h[k] = [] }
      steps.each do |step|
        id = step["id"]
        found["status"] << id if step["status"]
        requires = Array(step["require"])
        found["expect_fail"] << id if requires.any? { |entry| expect_fail?(entry) }
        found["require"] << id if requires.any? { |entry| !expect_fail?(entry) }
        found["produces"] << id if Array(step["produces"]).any?
        found["guard"] << id if step["guard"]
        found["review"] << id if review?(step["review"])
        found["backoff"] << id if step["on_fail"].is_a?(Hash) && step["on_fail"]["backoff"]
      end
      groups = steps.filter_map { |step| step["group"] }.uniq
      found["fan_out"] = groups unless groups.empty?
      %w[deny budget timeout].each { |key| found[key] = [] if present?(definition[key]) }
      found
    end

    # feature => "fired" | "missed" | "armed" | "?" for each declared feature.
    def self.features(run, events)
      definition = run["definition"] || {}
      by_step = (run["steps"] || {}).transform_values { |step| Array(step["attempts"]) }
      declared(definition).to_h do |feature, step_ids|
        states = if step_ids.empty?
          [run_level(feature, by_step, events)]
        elsif feature == "fan_out"
          step_ids.map { |group| fan_out_state(definition, group, by_step) }
        else
          step_ids.map { |id| step_state(feature, id, by_step[id].to_a, events, definition) }
        end
        [feature, combine(states)]
      end
    end

    # One row for a run, or a "not run" row when run is nil.
    #   workflow: id; run: stored run hash or nil; events: its event hashes;
    #   totals: trace totals hash (wall_seconds, active_seconds, stopped_seconds);
    #   next_run: the following item's run hash, for the gap; final: true when no item follows.
    #   asks: the workspace's stored asks (string-key hashes); answered ones asked inside the run's window count as manual.
    def self.row(workflow:, run:, events: [], totals: nil, next_run: nil, final: false, asks: [])
      return not_run(workflow) unless run
      attempts = attempts(run)
      rounds = attempts.flat_map { |attempt| Array(attempt["rounds"]) }.reject { |round| round["ended"] == "redelivered" }
      totals = adjusted_totals(totals || {}, run, events)
      manual = manual_counts(run, attempts, events, asks)
      {
        workflow: workflow,
        run_id: run["id"],
        ran: true,
        state: run["state"],
        features: features(run, events),
        attempts: attempts.size,
        retries: (run["steps"] || {}).values.sum { |step| [Array(step["attempts"]).count { |a| a["outcome"] != "not_delivered" } - 1, 0].max },
        review_rounds: rounds.size,
        review_rounds_distinct: rounds.map { |round| round["round"] }.uniq.size,
        guard_violations: events.count { |e| e["type"] == "step_failed" && e["cause"] == "guard" },
        denied: events.count { |e| e["type"] == "command_denied" },
        wall: totals["wall_seconds"],
        active: totals["active_seconds"],
        stopped: totals["stopped_seconds"],
        person_wait: person_wait(totals),
        background: totals["background_seconds"],
        deliver_wait: totals["deliver_wait_seconds"],
        review_deliver_wait: totals["review_deliver_wait_seconds"],
        **manual,
        manual: manual.values.sum,
        gap: gap(run, next_run),
        final: final,
        definition_sha256: run["definition_sha256"],
        head: ending_head(attempts)
      }
    end

    # Person-caused counts: events a person made, attempts that asked for input, and answered asks
    # put by their `asked_at` inside the run's window. An open ask (the agent took its default) is not counted.
    def self.manual_counts(run, attempts, events, asks)
      started = parse(run["started_at"])
      ended = parse(run["ended_at"])
      {
        manual_events: events.count { |e| e["actor"] == "person" && MANUAL_TYPES.include?(e["type"]) },
        manual_inputs: attempts.count { |a| a["asked_input"] == true || a.dig("status_report", "state") == "needs_input" },
        manual_asks: Array(asks).count do |ask|
          at = (ask["status"] == "answered") ? parse(ask["asked_at"]) : nil
          at && started && at >= started && (ended.nil? || at <= ended)
        end
      }
    end

    # Seconds the run waited on a person: the trace's waiting buckets whose reason is in PERSON_WAIT_CODES,
    # less the undelivered-dispatch wait (see adjusted_totals), never more than `stopped` (buckets can overlap).
    # nil when the trace has no buckets.
    def self.person_wait(totals)
      buckets = totals["waiting_seconds"]
      return nil unless buckets.is_a?(Hash)
      sum = buckets.slice(*PERSON_WAIT_CODES).values.grep(Numeric).sum
      sum = [sum - totals["undelivered_seconds"].to_f, 0].max
      stopped = totals["stopped_seconds"]
      stopped.is_a?(Numeric) ? [sum, stopped].min : sum
    end

    # The trace totals with what is not a person's or a stop corrected from the run's events and attempts:
    # `background_seconds` (turn_ended_background: the agent's sub-agent is working) moves from stopped to active;
    # `undelivered_seconds` (a dispatch the pane refused, redelivered by the sweep: the machine's wait, though
    # the run reason says waiting_you) is the part of waiting_you that is not a person's; `deliver_wait_seconds`
    # adds the review rounds' redelivery waits, which the trace has no span for.
    def self.adjusted_totals(totals, run, events)
      step_wait, review_wait = deliver_waits(run, events)
      buckets = totals["waiting_seconds"]
      return totals.merge("undelivered_seconds" => step_wait) unless buckets.is_a?(Hash)
      stopped = totals["stopped_seconds"]
      active = totals["active_seconds"]
      background = buckets["turn_ended_background"]
      background = background.is_a?(Numeric) ? background : 0.0
      background = [background, stopped].min if background && stopped.is_a?(Numeric)
      totals.merge("background_seconds" => background,
        "stopped_seconds" => (stopped.is_a?(Numeric) && background) ? stopped - background : stopped,
        "active_seconds" => (active.is_a?(Numeric) && background) ? active + background : active,
        "undelivered_seconds" => [step_wait, buckets["waiting_you"].to_f].min,
        "deliver_wait_seconds" => step_wait + review_wait, "review_deliver_wait_seconds" => review_wait)
    end

    # [seconds of step dispatches the pane refused until the sweep redelivered them, seconds of review rounds
    # whose delivery failed until the round started again], from events: a `step_stalled` with cause `undelivered`
    # counts from the end of the attempt it names; a round whose delivery failed counts from its first `review_started`
    # (the first delivery's wait on the pane included) to the `review_started` that follows the last failure.
    def self.deliver_waits(run, events)
      step_wait = events.select { |e| e["type"] == "step_stalled" && e["cause"] == "undelivered" }.sum do |event|
        attempt = Array((run["steps"] || {}).dig(event["step"], "attempts")).find { |a| a["n"] == event["attempt"] }
        from = parse(attempt && attempt["ended_at"])
        to = parse(event["ts"])
        (from && to) ? [to - from, 0].max : 0
      end
      review_wait = events.select { |e| e["type"] == "review_delivery_failed" }.group_by { |e| [e["step"], e["round"]] }.sum do |(step, round), failures|
        starts = events.select { |e| e["type"] == "review_started" && e["step"] == step && e["round"] == round }
        last_failed = failures.filter_map { |e| parse(e["ts"]) }.max
        first_start = starts.filter_map { |e| parse(e["ts"]) }.min
        again = starts.filter_map { |e| parse(e["ts"]) }.select { |t| last_failed && t > last_failed }.min
        from = [first_start, failures.filter_map { |e| parse(e["ts"]) }.min].compact.min
        (from && again) ? [again - from, 0].max : 0
      end
      [step_wait, review_wait]
    end

    # Row for an item with no run (after the wait's stop point, or never started).
    def self.not_run(workflow)
      na = Fmt::NOT_RUN
      {workflow: workflow, run_id: nil, ran: false, state: na, features: {}, attempts: na, retries: na,
       review_rounds: na, review_rounds_distinct: na, guard_violations: na, denied: na, manual: na,
       manual_events: na, manual_inputs: na, manual_asks: na, definition_sha256: nil, wall: na, active: na, stopped: na, person_wait: na, background: na, deliver_wait: na, gap: na, head: na}
    end

    # Rows for items in order. Each item: {workflow:, run:, events:, totals:}.
    # The gap runs to the next item's run only when that item has one; without one the row is `final`.
    def self.rows(items, asks: [])
      items.each_with_index.map do |item, index|
        row(workflow: item[:workflow], run: item[:run], events: item[:events] || [], asks: asks,
          totals: item[:totals], next_run: items[index + 1]&.dig(:run), final: items[index + 1]&.dig(:run).nil?)
      end
    end

    # Seconds from this run's ended_at to the next run's started_at; nil if either is missing.
    def self.gap(run, next_run)
      ended = parse(run && run["ended_at"])
      started = parse(next_run && next_run["started_at"])
      (ended && started) ? started - ended : nil
    end

    # head.after of the attempt that ended last across steps; nil when that attempt has none.
    def self.ending_head(attempts)
      last = attempts.select { |a| parse(a["ended_at"]) }.max_by { |a| parse(a["ended_at"]) }
      last&.dig("head", "after")
    end

    def self.step_state(feature, id, attempts, events, definition)
      return UNKNOWN if attempts.empty?
      return backoff_state(id, events) if feature == "backoff"
      entries = Array(Array(definition["steps"]).find { |s| s["id"] == id }&.dig("require"))
      evidence = case feature
      when "status" then attempts.any? { |a| a.dig("check", "exit_code") }
      when "require" then attempts.any? { |a| proofs(a).any? { |p| !expect_fail_proof?(p, entries) } } ||
        checked_without_proof?(entries, attempts) ||
        events.any? { |e| e["type"] == "step_failed" && e["cause"] == "require" && e["step"] == id }
      when "expect_fail" then attempts.any? { |a| proofs(a).any? { |p| expect_fail_proof?(p, entries) } }
      when "produces" then attempts.any? { |a| Array(a["outputs"]).any? }
      when "guard"
        attempts.any? { |a| a["ended_at"] && a.dig("head", "before") && a.dig("head", "before") == a.dig("head", "after") } ||
          events.any? { |e| e["type"] == "step_failed" && e["cause"] == "guard" && e["step"] == id }
      when "review"
        attempts.any? { |a| Array(a["rounds"]).any? } ||
          events.any? { |e| e["type"] == "review_started" && e["step"] == id }
      end
      evidence ? FIRED : MISSED
    end

    # The run file keeps a proof only for `exec` entries, so a passed attempt is the evidence that the
    # step's other (`commits`...) entries were checked.
    def self.checked_without_proof?(entries, attempts)
      entries.any? { |entry| !expect_fail?(entry) && !(entry.is_a?(Hash) && entry.key?("exec")) } &&
        attempts.any? { |a| a["outcome"] == "passed" }
    end

    def self.backoff_state(id, events)
      looped = events.any? { |e| e["type"] == "step_looped" && e["from"] == id && e.key?("backoff") }
      looped ? FIRED : ARMED
    end

    def self.run_level(feature, by_step, events)
      return UNKNOWN if by_step.values.all?(&:empty?)
      types = {"deny" => %w[command_denied], "budget" => %w[budget_spent budget_hold],
               "timeout" => %w[run_timed_out]}.fetch(feature)
      (events.any? { |e| types.include?(e["type"]) }) ? FIRED : ARMED
    end

    def self.fan_out_state(definition, group, by_step)
      siblings = Array(definition["steps"]).select { |s| s["group"] == group }.map { |s| s["id"] }
      ran = siblings.count { |id| by_step[id].to_a.any? }
      return UNKNOWN if ran.zero?
      (ran == siblings.size) ? FIRED : MISSED
    end

    def self.combine(states)
      [FIRED, MISSED, ARMED].find { |s| states.include?(s) } || UNKNOWN
    end

    def self.proofs(attempt)
      Array(attempt["proofs"]).reject { |p| p["skipped"] }
    end

    # A stored proof names its `require` entry by 0-based `index` and has no command; an older proof carries `command`.
    def self.expect_fail_proof?(proof, entries)
      entry = proof["index"].is_a?(Integer) ? entries[proof["index"]] : nil
      entry ? expect_fail?(entry) : proof["command"].to_s.include?("step expect-fail")
    end

    def self.expect_fail?(entry)
      entry.to_s.include?("expect-fail")
    end

    def self.review?(value)
      value.is_a?(Hash) && Array(value["from"]).any?
    end

    def self.present?(value)
      !(value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?))
    end

    def self.parse(text)
      text && Time.parse(text)
    end

    private_class_method :manual_counts, :person_wait, :adjusted_totals, :deliver_waits, :step_state, :checked_without_proof?, :backoff_state, :run_level, :fan_out_state, :combine, :proofs,
      :expect_fail_proof?, :expect_fail?, :review?, :present?, :parse
  end
end
