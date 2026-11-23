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
  # check waits on a person and costs nothing. Every step's stalls ({WorkflowTransitions.stall_spans}: its pane
  # or agent gone, or a failed turn) and any `stops:` given (such as downtime) are cut too. A stop that is never
  # stored, such as a permission prompt the agent sits at, is not cut, so it counts; the docs say so. The run's
  # timeout acts on nothing while the pane waits at that dialog: {WorkflowSweep} stops such a step on its own limit
  # (`workflows.permission_wait_limit`), and its `permission_wait` stall cuts no clock.
  class WorkflowDeadline
    # Reasons that are the machine's own time and so still count against the timeout.
    MACHINE_CODES = %w[waiting_lock retry_backoff].freeze

    # `suggested` rounds the least `--extra-time` up to a multiple of this many seconds.
    ROUND_TO = 900

    # @param run [WorkflowRun, Hash{String=>Object}] a stored run
    # @param now [Time] where an open stretch ends
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Hash{String=>Object}, nil] nil unless the run's definition declares a `timeout` (a stored run from
    #   before the key, or a bad value, reads nil); else "timeout" and "action" (`hold` or `interrupt`),
    #   "extra_seconds", "limit" (timeout plus extra), "used" (seconds of machine time, three decimals),
    #   "spent" (used has reached the limit), "needed" (the least whole `--extra-time` seconds that lets an
    #   attempt start, nil unless spent) and "suggested" (needed rounded up to {ROUND_TO})
    def self.reading(run, now, stops: [])
      run = WorkflowRun.from_h(run)
      timeout = WorkflowDefinition.run_timeout(run.definition)
      return nil unless timeout
      extra = run.extra_seconds.is_a?(Numeric) ? [run.extra_seconds, 0].max : 0
      limit = timeout["seconds"] + extra
      used = machine_seconds(run.to_h, now, stops: stops)
      spent = used >= limit
      needed = spent ? (used - limit).floor + 1 : nil
      {"timeout" => timeout["seconds"], "action" => timeout["action"], "extra_seconds" => extra, "limit" => limit,
       "used" => used.round(3), "spent" => spent, "needed" => needed,
       "suggested" => needed && (needed.fdiv(ROUND_TO).ceil * ROUND_TO)}
    rescue NoMethodError, TypeError
      nil
    end

    # @param hash [Hash{String=>Object}] a stored run
    # @param now [Time] where an open stretch ends
    # @param stops [Array<Hash{String=>Object}>] more spans to cut (`since`, optional `until`), such as downtime
    # @return [Float] seconds from the clock's start to its end, less the stretches a person's stop covers, every
    #   step's stalls ({WorkflowTransitions.stall_spans}) and +stops+
    def self.machine_seconds(hash, now, stops: [])
      entries = reason_entries(hash).map { |found| found["entry"] }
      window = machine_window(hash, now) or return 0.0
      origin, finish = window
      stalls = hash["steps"].to_h.keys.flat_map { |step| WorkflowTransitions.stall_spans(hash, step) }
      active_seconds(origin, finish, entries.reject { |entry| MACHINE_CODES.include?(entry["code"]) } + stalls + Array(stops))
    end

    # @param hash [Hash{String=>Object}] a stored run
    # @return [Array<Hash{String=>Object}>] the run's own `reasons`, then each step's own `reasons` (a step that keeps
    #   its own slots, {WorkflowRun.step_scoped?}) and every attempt's `reasons` (Hash entries only),
    #   each as `{"entry" => the stored Hash, "step" => step id, "attempt" => attempt `n`}`; a run-owned or step-owned
    #   entry's step is its own `step` key and its attempt is nil
    def self.reason_entries(hash)
      own = Array(hash["reasons"]).grep(Hash).map { |entry| {"entry" => entry, "step" => entry["step"], "attempt" => nil} }
      owned = hash["steps"].to_h.flat_map do |id, step|
        mine = Array(step.is_a?(Hash) ? step["reasons"] : nil).grep(Hash).map { |entry| {"entry" => entry, "step" => entry["step"] || id, "attempt" => nil} }
        mine + Array(step.is_a?(Hash) ? step["attempts"] : nil).grep(Hash).flat_map do |attempt|
          Array(attempt["reasons"]).grep(Hash).map { |entry| {"entry" => entry, "step" => id, "attempt" => attempt["n"]} }
        end
      end
      own + owned
    end

    # @param hash [Hash{String=>Object}] a stored run
    # @param now [Time] where an open stretch ends
    # @return [Array(Time, Time), nil] the clock's `[origin, finish]` (see the class doc), nil when it has no origin or
    #   `finish` is not after `origin`
    def self.machine_window(hash, now)
      attempts = hash["steps"].to_h.values.flat_map { |step| Array(step.is_a?(Hash) ? step["attempts"] : nil) }.grep(Hash)
      starts = attempts.filter_map { |attempt| time(attempt["started_at"]) }
      starts += reason_entries(hash).map { |found| found["entry"] }.select { |entry| entry["code"] == "waiting_lock" }.filter_map { |entry| time(entry["since"]) }
      origin = starts.min or return nil
      finish = time(hash["ended_at"]) || now
      (finish > origin) ? [origin, finish] : nil
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

    # @param spans [Array<Array(Time, Time)>] spans, each `[from, to]`
    # @return [Float] seconds the union of the spans covers, overlaps counted once
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
    private_class_method :time
  end
end
