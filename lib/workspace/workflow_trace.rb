require "digest"
require "time"

module Workspace
  # The trace of one workflow run: its events as ordered transition rows, with the states each row moved from and to.
  # Pure: it reads the values it is given and never touches the store or the clock but through +now:+.
  class WorkflowTrace
    # State a state-changing event type leaves its step (or the run) in; a type missing here is a marker row.
    STATE_OF = {
      "run_started" => "running", "run_resumed" => "running", "run_unpaused" => "running",
      "step_dispatching" => "running", "step_dispatched" => "running", "step_continued" => "running",
      "step_recovered" => "running", "step_retry_started" => "running", "step_interrupted" => "running",
      "step_looped" => "running", "gate_approved" => "running", "gate_rejected" => "running",
      "step_checks_passed" => "reviewing", "review_started" => "reviewing",
      "step_passed" => "passed", "step_failed" => "failed", "gate_waiting" => "waiting",
      "run_paused" => "paused", "run_completed" => "completed", "run_cancelled" => "cancelled",
      "run_timed_out" => "timed_out"
    }.freeze

    # Event types that end an attempt, so its tokens sit on the row.
    ATTEMPT_ENDS = %w[step_passed step_failed step_interrupted].freeze

    # Event types that end an attempt the run's own stop or restart cut short, when no ATTEMPT_ENDS row names it.
    RUN_ENDS = %w[run_cancelled run_timed_out run_resumed].freeze

    # @param run [WorkflowRun, Hash] the stored run
    # @param events [Array<Hash>] the run's events, each with `n`, `ts` and `type`, as the store reads them
    # @param event_errors [Array<Hash>] the run's event-errors log (placeholder for later parts)
    # @param now [Time] the reading time (placeholder for later parts)
    # @param stops [Array] the daemon's downtime spans (placeholder for later parts)
    # @return [Hash{Symbol=>Object}] frozen: `trace_id`, `transitions` (rows ordered by event `n`, with every key null
    #   when unknown, never 0), and the empty `spans`, `totals` and `warnings`
    def read(run, events, now:, event_errors: [], stops: [])
      run = WorkflowRun.new(run) unless run.is_a?(WorkflowRun)
      WorkflowRun.deep_freeze({
        trace_id: Digest::SHA256.hexdigest(run.id.to_s)[0, 32],
        transitions: transitions(run, events),
        spans: [],
        totals: {},
        warnings: []
      })
    end

    private

    def transitions(run, events)
      rows = []
      last_state = {}
      last_ts = {}
      current_attempt = {}
      ordered(events).each do |event, n|
        step = string(event["step"])
        scope = step
        attempt = integer(event["attempt"])
        current_attempt[step] = attempt if attempt && step
        attempt ||= current_attempt[step] if ATTEMPT_ENDS.include?(event["type"])
        from, to, derived = states(event, last_state[scope])
        last_state[scope] = to if to
        ts = string(event["ts"])
        rows << {
          n: n, ts: ts, kind: STATE_OF.key?(event["type"]) ? "transition" : "marker", type: event["type"],
          from: from, to: to, step: step, attempt: attempt, round: integer(event["round"]),
          cause: string(event["cause"]), actor: string(event["actor"]), duration_ms: duration(ts, last_ts[scope]),
          tokens: nil, exit_code: integer(event["exit_code"]), code: string(event["code"]),
          evidence: event["evidence"], derived: derived
        }
        last_ts[scope] = ts
      end
      place_tokens(run, rows)
    end

    def ordered(events)
      Array(events).grep(Hash).each_with_index.map { |event, index| [event, integer(event["n"]) || index + 1] }.each_with_index.sort_by { |(_, n), index| [n, index] }.map(&:first)
    end

    def states(event, previous)
      from = string(event["from_state"])
      to = string(event["to_state"])
      return [from, to, false] if from && to
      derived_to = STATE_OF[event["type"]]
      [from || (derived_to ? previous : nil), to || derived_to, true]
    end

    def duration(ts, previous)
      from = time(previous)
      to = time(ts)
      return nil unless from && to && to >= from
      ((to - from) * 1000).round
    end

    def time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end

    # Puts each attempt's tokens on the one row that ends it, and its evidence there when the event carries none.
    def place_tokens(run, rows)
      taken = {}
      run.steps.each do |step_id, step|
        step.attempts.each do |attempt|
          index = ending_row(rows, step_id, attempt, taken)
          next unless index
          taken[index] = true
          rows[index] = rows[index].merge(tokens: tokens(attempt), evidence: rows[index][:evidence] || attempt.evidence)
        end
      end
      rows
    end

    def ending_row(rows, step_id, attempt, taken)
      found = rows.each_index.find do |i|
        !taken[i] && rows[i][:step] == step_id && rows[i][:attempt] == attempt.n && ATTEMPT_ENDS.include?(rows[i][:type])
      end
      return found if found
      return nil unless attempt.ended_at
      rows.each_index.find do |i|
        !taken[i] && RUN_ENDS.include?(rows[i][:type]) && [nil, step_id].include?(rows[i][:step]) && later?(rows[i][:ts], attempt.ended_at)
      end
    end

    def later?(ts, ended_at)
      row = time(ts)
      ended = time(ended_at)
      row && ended && row >= ended - 1
    end

    def tokens(attempt)
      return nil unless WorkflowBudget.counted_attempt?(attempt)
      return nil unless WorkflowBudget.attempt_tokens(attempt)
      usages = [attempt.usage] + WorkflowBudget.rounds_of(attempt).map { |round| round["usage"] }
      in_key, out_key, cache_key = WorkflowBudget::COUNTED_KEYS
      {
        in: usages.sum { |usage| usage[in_key] || 0 },
        out: usages.sum { |usage| usage[out_key] || 0 },
        cache: usages.sum { |usage| usage[cache_key] || 0 }
      }
    end

    def string(value)
      (value.is_a?(String) && !value.empty?) ? value : nil
    end

    def integer(value)
      value.is_a?(Integer) ? value : nil
    end
  end
end
