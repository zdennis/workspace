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

    # The one key set every span carries, null where it does not apply.
    SPAN_KEYS = %i[span_id kind step attempt round started_at ended_at code outcome actor note tokens head_before head_after retry_of].freeze

    # The `code` of the spans that are not a stored reason: the waiting-time bucket each one counts under.
    SPAN_CODES = {"stall" => "stalled", "downtime" => "downtime", "gate" => "gate"}.freeze

    # Event types that end an attempt, so its tokens sit on the row.
    ATTEMPT_ENDS = %w[step_passed step_failed step_interrupted].freeze

    # Event types that end an attempt the run's own stop or restart cut short, when no ATTEMPT_ENDS row names it.
    RUN_ENDS = %w[run_cancelled run_timed_out run_resumed].freeze

    # @param run [WorkflowRun, Hash] the stored run
    # @param events [Array<Hash>] the run's events, each with `n`, `ts` and `type`, as the store reads them
    # @param event_errors [Array<Hash>] the run's event-errors log; a non-empty one gives an `events_lost` warning
    # @param now [Time] where an open stretch ends
    # @param stops [Array<Hash{String=>Object}>] the daemon's downtime spans (`since`, optional `until`)
    # @param warnings [Array<Hash>] warnings the caller already holds (the events reader's bad-line warnings), passed through
    # @return [Hash{Symbol=>Object}] frozen: `trace_id`, `transitions` (rows ordered by event `n`, with every key null
    #   when unknown, never 0), `spans` (kinds attempt, review_round, gate, wait, stall and downtime, each with a
    #   `span_id`), `totals` and `warnings`. In `totals`, `stopped_seconds` is `clock_seconds - active_seconds`, the
    #   exact time the clock stood still; the `waiting_seconds` buckets can overlap, so their sum can exceed it.
    #   `machine_waiting_seconds` (`waiting_lock`, `retry_backoff`) sits inside `active_seconds`. `clock_seconds`,
    #   `active_seconds`, `stopped_seconds` and both bucket hashes are null when the clock has no origin.
    def read(run, events, now:, event_errors: [], stops: [], warnings: [])
      run = WorkflowRun.new(run) unless run.is_a?(WorkflowRun)
      sorted = ordered(events)
      clock = clock_readable?(run)
      spans = spans(run, sorted.map(&:first), now, Array(stops).grep(Hash), clock)
      WorkflowRun.deep_freeze({
        trace_id: Digest::SHA256.hexdigest(run.id.to_s)[0, 32],
        transitions: transitions(run, sorted),
        spans: spans,
        totals: totals(run, spans, now, Array(stops).grep(Hash), clock),
        warnings: caller_warnings(warnings) + lost_warning(event_errors) + clock_warning(clock)
      })
    end

    # Gaps shorter than this many seconds are not printed as waits.
    WAIT_LINE_SECONDS = 60

    # The header of the `--table` grid.
    TABLE_HEADER = %w[N TS KIND STEP#ATTEMPT FROM TO ACTOR CAUSE DURATION TOKENS].freeze

    # Span kinds that print as a `waited` line.
    WAIT_KINDS = %w[gate wait stall downtime].freeze

    # The rows of `workflow trace --table`, one array of cells per transition row, `-` where a value is unknown.
    #
    # @param doc [Hash] what {#read} returns
    # @return [Array<Array<String>>] cells matching {TABLE_HEADER}
    def self.table_rows(doc)
      doc[:transitions].map do |row|
        [row[:n], row[:ts], row[:kind], step_label(row, "-"), row[:from], row[:to], row[:actor], row[:cause],
          row[:duration_ms] && duration_text(row[:duration_ms] / 1000.0), token_text(row[:tokens])].map { |cell| cell.nil? ? "-" : cell.to_s }
      end
    end

    # The text `workflow trace` prints: one line per transition row, a `waited` line where a long gate, wait, stall or
    # downtime span begins, then the totals. Unknown values print as `-` or are left out, never as 0. Pure; the lines
    # are not escaped for a terminal.
    #
    # @param doc [Hash] what {#read} returns
    # @return [Array<String>]
    def self.text_lines(doc)
      rows = doc[:transitions]
      waits = doc[:spans].select { |span| WAIT_KINDS.include?(span[:kind]) && wait_line?(span) }
        .sort_by { |span| [parse_time(span[:started_at]) || Time.at(0), span[:span_id].to_s] }
      lines = []
      pending = waits.dup
      rows.each do |row|
        at = parse_time(row[:ts])
        while (wait = pending.first) && at && parse_time(wait[:started_at]) < at
          lines << wait_text(pending.shift)
        end
        lines << row_text(row)
      end
      pending.each { |wait| lines << wait_text(wait) }
      lines << "" << "Totals"
      lines.concat(totals_lines(doc[:totals]))
    end

    def self.wait_line?(span)
      from = parse_time(span[:started_at])
      return false unless from
      to = parse_time(span[:ended_at])
      to.nil? || to - from > WAIT_LINE_SECONDS
    end

    def self.wait_text(span)
      from = parse_time(span[:started_at])
      to = parse_time(span[:ended_at])
      reason = span[:code] || span[:kind]
      "#{" " * 10}#{to ? "waited #{duration_text(to - from)}" : "waiting since #{clock_text(span[:started_at])}"} (#{reason})"
    end

    def self.row_text(row)
      label = step_label(row, row[:type].to_s)
      states = ((row[:from] || row[:to]) && row[:kind] == "transition") ? "#{row[:from] || "-"} -> #{row[:to] || "-"}" : row[:type]
      parts = ["#{clock_text(row[:ts])}  #{label} #{states}"]
      parts << "actor=#{row[:actor]}" if row[:actor]
      parts << "cause=#{row[:cause]}" if row[:cause]
      parts << duration_text(row[:duration_ms] / 1000.0) if row[:duration_ms]
      tokens = token_text(row[:tokens])
      parts << "#{tokens} tok" if tokens
      parts.join("  ")
    end

    def self.totals_lines(totals)
      lines = []
      lines << "wall:    #{duration_text(totals[:wall_seconds]) || "-"}"
      lines << "active:  #{duration_text(totals[:active_seconds]) || "-"}"
      lines << "stopped: #{duration_text(totals[:stopped_seconds]) || "-"}"
      waiting = totals[:waiting_seconds]
      if waiting.is_a?(Hash) && !waiting.empty?
        lines << "waiting: " + waiting.map { |code, seconds| "#{code} #{duration_text(seconds)}" }.join(", ") + " (reasons can overlap, so they can add up to more than stopped)"
      end
      machine = totals[:machine_waiting_seconds]
      if machine.is_a?(Hash) && !machine.empty?
        lines << "machine waiting (inside active): " + machine.map { |code, seconds| "#{code} #{duration_text(seconds)}" }.join(", ")
      end
      tokens = totals[:tokens] || {}
      lines << "tokens:  " + (tokens[:total] ? "#{token_text(tokens)} (in #{tokens[:in]}, out #{tokens[:out]}, cache #{tokens[:cache]})" : "-")
      lines << "loops:   #{loops_text(totals[:loops])}"
      lines << "attempts: #{totals[:attempts] || "-"}"
      lines
    end

    def self.loops_text(loops)
      return loops || "-" unless loops.is_a?(Hash)
      return "none" if loops.empty?
      loops.map { |edge, count| "#{edge} #{count}" }.join(", ")
    end

    def self.step_label(row, fallback)
      return fallback unless row[:step]
      row[:attempt] ? "#{row[:step]}##{row[:attempt]}" : row[:step]
    end

    def self.token_text(tokens)
      total = tokens && tokens[:total]
      return nil unless total
      format_tokens(total)
    end

    # A token count as short text: `950`, `20k`, `1.5M`. The one rule `workflow stats` and `workflow trace` share.
    #
    # @param count [Integer]
    # @return [String]
    def self.format_tokens(count)
      return count.to_s if count < 1000
      return "#{(count / 1000.0).round}k" if count < 999_500
      "#{(count / 1_000_000.0).round(1)}M"
    end

    def self.duration_text(seconds)
      return nil unless seconds
      whole = seconds.round
      if whole >= 3600 then "#{whole / 3600}h#{whole % 3600 / 60}m"
      elsif whole >= 600 then "#{whole / 60}m"
      else "#{whole}s"
      end
    end

    def self.parse_time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end

    def self.clock_text(ts)
      time = parse_time(ts)
      time ? time.utc.strftime("%H:%M:%S") : "--:--:--"
    end

    private

    # The events reader's warnings are plain strings; a Hash passes as it is.
    def caller_warnings(warnings)
      Array(warnings).filter_map do |warning|
        case warning
        when Hash then warning
        when String then {code: "event_line_skipped", message: warning}
        end
      end
    end

    # The deadline reader walks `steps` as a Hash; a stored run whose `steps` is anything else gets no clock figures.
    def clock_readable?(run)
      steps = run.to_h["steps"]
      steps.nil? || steps.is_a?(Hash)
    end

    def clock_warning(clock)
      return [] if clock
      [{code: "run_steps_unreadable", message: "The stored run's steps are not in the expected form, so the trace has no waiting reasons, stalls or clock figures."}]
    end

    def lost_warning(event_errors)
      errors = Array(event_errors).grep(Hash)
      return [] if errors.empty?
      types = errors.filter_map { |error| string(error["type"]) }.uniq
      [{code: "events_lost", message: "#{errors.size} event(s) could not be written to the history, so the trace may lack them.", count: errors.size, types: types}]
    end

    # The attempts of a step whose stored record is a Hash.
    def stored_attempts(step)
      stored = Array(step.to_h["attempts"])
      step.attempts.each_with_index.select { |_, i| stored[i].is_a?(Hash) }.map(&:first)
    end

    # An entry's `until` the clock cannot read is ignored by the clock; so is its span.
    def unreadable_until?(entry)
      entry["until"] && time(entry["until"]).nil?
    end

    def spans(run, events, now, stops, clock)
      counts = Hash.new(0)
      make = lambda do |kind, step, attempt, round, fields|
        index = counts[[step, attempt, round, kind]]
        counts[[step, attempt, round, kind]] += 1
        id = Digest::SHA256.hexdigest([run.id, step, attempt, round, kind, index].join("\0"))[0, 16]
        SPAN_KEYS.to_h { |key| [key, nil] }.merge(span_id: id, kind: kind, step: step, attempt: attempt, round: round).merge(fields)
      end
      out = []
      run.steps.each do |step_id, step|
        stored_attempts(step).each do |attempt|
          out << make.call("attempt", step_id, attempt.n, nil, started_at: string(attempt.started_at), ended_at: string(attempt.ended_at),
            outcome: string(attempt.outcome), code: string(attempt.code), head_before: head_of(attempt, "before"), head_after: head_of(attempt, "after"),
            tokens: tokens(attempt), retry_of: integer(attempt.retry_of))
          WorkflowBudget.rounds_of(attempt).each do |round|
            out << make.call("review_round", step_id, attempt.n, integer(round["round"]), started_at: string(round["started_at"]),
              ended_at: string(round["ended_at"]), tokens: usage_tokens(round["usage"]))
          end
        end
      end
      gates = gate_spans(events)
      gates.each { |gate| out << make.call("gate", gate[:step], gate[:attempt], nil, gate.except(:step, :attempt)) }
      (clock ? WorkflowDeadline.reason_entries(run.to_h) : []).each do |found|
        entry = found["entry"]
        next if gate_entry?(entry, string(found["step"]), gates)
        next if unreadable_until?(entry)
        out << make.call("wait", string(found["step"]), integer(found["attempt"]), nil, code: string(entry["code"]) || "unknown",
          started_at: string(entry["since"]), ended_at: string(entry["until"]))
      end
      run.steps.each_key do |step_id|
        WorkflowTransitions.stall_spans(run.to_h, step_id).each do |stall|
          next if unreadable_until?(stall)
          out << make.call("stall", step_id, nil, nil, code: SPAN_CODES["stall"], started_at: string(stall["since"]), ended_at: string(stall["until"]))
        end
      end
      stops.each do |stop|
        next if unreadable_until?(stop)
        out << make.call("downtime", nil, nil, nil, code: SPAN_CODES["downtime"], started_at: string(stop["since"]), ended_at: string(stop["until"]))
      end
      out
    end

    # A stored `waiting_you` entry never carries `details`, so it is the gate's wait when its step has a gate span (from
    # events) whose interval holds the entry's `since`, the span starting at most one second after it (event `ts` has one second).
    def gate_entry?(entry, step, gates)
      return false unless entry["code"] == "waiting_you"
      return true if entry.dig("details", "kind") == "gate"
      since = time(entry["since"]) or return false
      gates.any? do |gate|
        next false unless gate[:step] == step
        from = time(gate[:started_at]) or next false
        to = gate[:ended_at] ? time(gate[:ended_at]) : nil
        since >= from - 1 && (to.nil? || since <= to)
      end
    end

    def head_of(attempt, key)
      attempt.head.is_a?(Hash) ? string(attempt.head[key]) : nil
    end

    # Each `gate_waiting` opens a span the step's next `gate_approved` or `gate_rejected` closes; open while still waiting.
    def gate_spans(events)
      open = {}
      closed = []
      current_attempt = {}
      events.each do |event|
        step = string(event["step"])
        current_attempt[step] = integer(event["attempt"]) if step && integer(event["attempt"])
        case event["type"]
        when "gate_waiting"
          next unless step
          closed << open[step].merge(ended_at: string(event["ts"])) if open[step]
          open[step] = {step: step, attempt: integer(event["attempt"]) || current_attempt[step], started_at: string(event["ts"]), ended_at: nil,
            code: SPAN_CODES["gate"], actor: nil, note: nil}
        when "gate_approved", "gate_rejected"
          gate = open.delete(step)
          next unless gate
          closed << gate.merge(ended_at: string(event["ts"]), actor: string(event["actor"]), note: string(event["note"]))
        end
      end
      closed + open.values
    end

    def totals(run, spans, now, stops, clock)
      hash = run.to_h
      window = clock ? WorkflowDeadline.machine_window(hash, now) : nil
      clock_ms = window && ((window[1] - window[0]) * 1000).round
      active_ms = window && (WorkflowDeadline.machine_seconds(hash, now, stops: stops) * 1000).round
      counted = counted_attempts(run)
      {
        wall_seconds: wall_seconds(run, now),
        clock_seconds: clock_ms && clock_ms / 1000.0,
        active_seconds: active_ms && active_ms / 1000.0,
        stopped_seconds: window && (clock_ms - active_ms) / 1000.0,
        waiting_seconds: window ? buckets(spans, window) { |code| !WorkflowDeadline::MACHINE_CODES.include?(code) } : nil,
        machine_waiting_seconds: window ? buckets(spans, window) { |code| WorkflowDeadline::MACHINE_CODES.include?(code) } : nil,
        tokens: token_totals(counted),
        loops: run.loops,
        attempts: run.steps.sum { |_, step| stored_attempts(step).size }
      }
    end

    def wall_seconds(run, now)
      from = time(run.started_at) or return nil
      to = time(run.ended_at) || now
      (to >= from) ? (to - from).round(3) : nil
    end

    # Each bucket is the union of its spans clamped to the clock's window; one per code the block admits.
    def buckets(spans, window)
      origin, finish = window
      by_code = {}
      spans.each do |span|
        code = span[:code]
        next unless code && %w[wait gate stall downtime].include?(span[:kind]) && yield(code)
        from = time(span[:started_at]) or next
        to = span[:ended_at] ? time(span[:ended_at]) : finish
        next unless to
        from = [from, origin].max
        to = [to, finish].min
        (by_code[code] ||= []) << [from, to] if to > from
      end
      by_code.transform_values { |list| WorkflowDeadline.union_length(list).round(3) }
    end

    def counted_attempts(run)
      run.steps.flat_map do |id, step|
        attempts = stored_attempts(step)
        attempts.select { |attempt| WorkflowStats.tokens_count?(run, id, attempts, attempt) }
      end
    end

    def token_totals(counted)
      sums = counted.map { |attempt| WorkflowBudget.attempt_tokens(attempt) }
      return {total: nil, in: nil, out: nil, cache: nil} if counted.empty? || !sums.all?
      splits = counted.map { |attempt| tokens(attempt) }
      {total: sums.sum, in: splits.sum { |t| t[:in] }, out: splits.sum { |t| t[:out] }, cache: splits.sum { |t| t[:cache] }}
    end

    def transitions(run, sorted)
      rows = []
      last_state = {}
      last_ts = {}
      current_attempt = {}
      sorted.each do |event, n|
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

    def time(value) = self.class.parse_time(value)

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
      return nil if WorkflowStats.kind_of(attempt) == :not_delivered
      return nil unless WorkflowBudget.counted_attempt?(attempt)
      return nil unless WorkflowBudget.attempt_tokens(attempt)
      usages = [attempt.usage] + WorkflowBudget.rounds_of(attempt).map { |round| round["usage"] }
      split(usages, WorkflowBudget.attempt_tokens(attempt))
    end

    # One review round's tokens, from its own usage; nil when it has none readable.
    def usage_tokens(usage)
      total = WorkflowBudget.tokens_of(usage)
      total && split([usage], total)
    end

    def split(usages, total)
      in_key, out_key, cache_key = WorkflowBudget::COUNTED_KEYS
      {
        total: total,
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
