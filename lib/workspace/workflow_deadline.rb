require "time"

module Workspace
  # Reads how much of a run's `timeout:` is used, from the stored run and a time alone (no lock, no I/O).
  # A definition that declares `timeout: 8h` lets a run use 8 hours of machine time plus the run's
  # `extra_seconds`; {WorkflowEngine} checks it where a new attempt would start, so it stops the next
  # attempt and never a turn under way.
  #
  # The clock starts at the first attempt's `started_at`, or at an earlier `waiting_lock` entry when the run
  # waited for a lock first, and stops at the run's `ended_at` (else it runs to `now`). Only machine time
  # counts: the span is cut by every stored reason entry (an attempt's and the run's own, an open one running
  # to `now`) whose code is not in {MACHINE_CODES}, so a gate, a parked resume, a held budget or a failed
  # check waits on a person and costs nothing. A stop that is never stored, such as a permission prompt the
  # agent sits at, is not cut, so it counts; the docs say so.
  class WorkflowDeadline
    # Reasons that are the machine's own time and so still count against the timeout.
    MACHINE_CODES = %w[waiting_lock retry_backoff].freeze

    # `suggested` rounds the least `--extra-time` up to a multiple of this many seconds.
    ROUND_TO = 900

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param now [Time] where an open stretch ends
    # @return [Hash{String=>Object}, nil] nil unless the run's definition declares a `timeout` (a stored run from
    #   before the key, or a bad value, reads nil); else "timeout" and "action" (`hold` or `interrupt`),
    #   "extra_seconds", "limit" (timeout plus extra), "used" (seconds of machine time, three decimals),
    #   "spent" (used has reached the limit), "needed" (the least whole `--extra-time` seconds that lets an
    #   attempt start, nil unless spent) and "suggested" (needed rounded up to {ROUND_TO})
    def self.reading(run, now)
      run = WorkflowRun.from_h(run)
      timeout = WorkflowDefinition.run_timeout(run.definition)
      return nil unless timeout
      extra = run.extra_seconds.is_a?(Numeric) ? [run.extra_seconds, 0].max : 0
      limit = timeout["seconds"] + extra
      used = machine_seconds(run.to_h, now)
      spent = used >= limit
      needed = spent ? (used - limit).floor + 1 : nil
      {"timeout" => timeout["seconds"], "action" => timeout["action"], "extra_seconds" => extra, "limit" => limit,
       "used" => used.round(3), "spent" => spent, "needed" => needed,
       "suggested" => needed && (needed.fdiv(ROUND_TO).ceil * ROUND_TO)}
    rescue NoMethodError, TypeError
      nil
    end

    # @return [Float] seconds from the clock's start to its end, less the stretches a person's stop covers
    def self.machine_seconds(hash, now)
      attempts = hash["steps"].to_h.values.flat_map { |step| Array(step.is_a?(Hash) ? step["attempts"] : nil) }.grep(Hash)
      entries = Array(hash["reasons"]) + attempts.flat_map { |attempt| Array(attempt["reasons"]) }
      entries = entries.grep(Hash)
      starts = attempts.filter_map { |attempt| time(attempt["started_at"]) }
      starts += entries.select { |entry| entry["code"] == "waiting_lock" }.filter_map { |entry| time(entry["since"]) }
      origin = starts.min
      return 0.0 unless origin
      finish = time(hash["ended_at"]) || now
      return 0.0 unless finish > origin
      active_seconds(origin, finish, entries.reject { |entry| MACHINE_CODES.include?(entry["code"]) })
    end

    # @param origin [Time] where the span starts
    # @param finish [Time] where the span ends
    # @param stops [Array<Hash{String=>Object}>] reason entries with an ISO `since` and an optional `until`
    #   (an open entry runs to `finish`); each is clamped to the span, and one with an unreadable time is ignored
    # @return [Float] seconds from `origin` to `finish`, less the union of the stops
    def self.active_seconds(origin, finish, stops)
      spans = stops.filter_map do |entry|
        from = time(entry["since"]) or next
        to = entry["until"] ? time(entry["until"]) : finish
        next unless to
        from = [from, origin].max
        to = [to, finish].min
        [from, to] if to > from
      end
      (finish - origin) - union_length(spans)
    end

    def self.union_length(spans)
      total = 0.0
      reach = nil
      spans.sort.each do |from, to|
        from = [from, reach].max if reach
        next if reach && to <= reach
        total += to - from
        reach = to
      end
      total
    end

    def self.time(value)
      value.is_a?(String) ? Time.iso8601(value) : nil
    rescue ArgumentError
      nil
    end
    private_class_method :union_length, :time
  end
end
