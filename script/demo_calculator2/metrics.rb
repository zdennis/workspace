require "set"
require "time"
require_relative "../demo_calculator/cost"

module DemoCalculator2
  # The numbers `eval` adds for calculator2, from stored run hashes and `workflow trace --json` documents.
  # Pure: reads nothing, spawns nothing.
  module Metrics
    ACCEPTANCE_STEP = "acceptance".freeze
    # Acceptance lines shorter than this are too common to show copying.
    MIN_LINE = 40

    # Seconds and tokens the run's review rounds took, which {.step_wall} and {.step_tokens} leave out.
    #
    # @param trace [Hash, nil] `workflow trace --json`
    # @return [Hash, nil] `wall` (Float seconds) and `tokens` (Integer, input + output + cache creation);
    #   nil when there is no trace or it has no spans, so a missing trace is not shown as no review
    def self.review(trace)
      return nil if Array(trace && trace["spans"]).empty?
      rounds = round_spans(trace)
      wall = rounds.sum do |span|
        started = time(span["started_at"])
        ended = time(span["ended_at"])
        (started && ended) ? ended - started : 0.0
      end
      counted = rounds.filter_map { |span| span.dig("tokens", "total") if span.dig("tokens", "total").is_a?(Numeric) }
      {wall: wall, tokens: counted.empty? ? nil : counted.sum}
    end

    # Tokens each step's attempts used, without the review rounds the attempts' spans also count. An attempt
    # span with no token count leaves its step out, as {.step_wall} does for a span with no end.
    #
    # @param trace [Hash, nil] `workflow trace --json`
    # @return [Hash{String => Integer}] step id => tokens, in first-seen order
    def self.step_tokens(trace)
      rounds = round_spans(trace)
      Array(trace && trace["spans"]).each_with_object({}) do |span, tokens|
        next unless span["kind"] == "attempt" && span["step"]
        own = span.dig("tokens", "total")
        next unless own.is_a?(Numeric)
        reviewed = rounds.select { |r| r["step"] == span["step"] && r["attempt"] == span["attempt"] }.filter_map { |r| r.dig("tokens", "total") if r.dig("tokens", "total").is_a?(Numeric) }.sum
        tokens[span["step"]] = tokens.fetch(span["step"], 0) + own - reviewed
      end
    end

    # How many review rounds have no attempt span of the same step and attempt to take their tokens out of: the
    # review row then counts tokens no step row has, and the rows still sum to the item's.
    #
    # @param trace [Hash, nil] `workflow trace --json`
    # @return [Integer]
    def self.unmatched_rounds(trace)
      attempts = Array(trace && trace["spans"]).select { |span| span["kind"] == "attempt" && span.dig("tokens", "total").is_a?(Numeric) }
      round_spans(trace).count { |r| attempts.none? { |a| a["step"] == r["step"] && a["attempt"] == r["attempt"] } }
    end

    # Tokens of a review round's sub-agents by the model each message ran on, from the sub-agent transcripts' lines.
    # A message written on several lines counts once, by its last line; only lines inside the window count.
    #
    # @param lines [Array<Hash>] parsed transcript lines
    # @param from [Time, nil] window start
    # @param to [Time, nil] window end
    # @return [Hash{String => Hash}] model => `{input:, output:, cache_creation:, cache_read:}`
    def self.usage_by_model(lines, from: nil, to: nil)
      messages = {}
      lines.each do |line|
        message = line["message"]
        next unless line["type"] == "assistant" && message.is_a?(Hash) && message["usage"].is_a?(Hash) && message["model"].is_a?(String)
        at = time(line["timestamp"])
        next if at && ((from && at < from) || (to && at > to))
        messages[message["id"] || messages.size] = message
      end
      messages.values.each_with_object({}) do |message, models|
        total = models[message["model"]] ||= DemoCalculator::Tokens::KINDS.keys.to_h { |kind| [kind, 0] }
        DemoCalculator::Tokens::KINDS.each { |kind, key| total[kind] += message["usage"][key].to_i }
      end
    end

    # Dollars to add to a run's cost for review sub-agents that ran on another model than the one their round was
    # priced at, and the models seen.
    #
    # @param by_model [Hash] see {.usage_by_model}
    # @param priced_model [String, nil] the model the round's tokens were priced at
    # @param pricing [Hash] the parsed demo/pricing.yml
    # @return [Hash] `dollars` (Float), `models` (Array) and `unpriced` (true when a model has no price)
    def self.model_shift(by_model, priced_model, pricing)
      shift = {dollars: 0.0, models: [], unpriced: false}
      by_model.each do |model, tokens|
        shift[:models] << model
        next if model == priced_model
        actual = DemoCalculator::Cost.dollars(tokens, model, pricing)
        base = DemoCalculator::Cost.dollars(tokens, priced_model, pricing)
        (actual && base) ? shift[:dollars] += actual - base : shift[:unpriced] = true
      end
      shift
    end

    # Seconds each step's attempts took, from the trace's attempt spans (an unended span adds nothing).
    #
    # @param trace [Hash, nil] `workflow trace --json`
    # @return [Hash{String => Float}] step id => seconds, in first-seen order
    def self.step_wall(trace)
      Array(trace && trace["spans"]).each_with_object({}) do |span, walls|
        next unless span["kind"] == "attempt" && span["step"]
        started = time(span["started_at"])
        ended = time(span["ended_at"])
        walls[span["step"]] = walls.fetch(span["step"], 0.0) + (ended - started) if started && ended
      end
    end

    # Seconds the run spent in machine waits (a lock, a retry backoff), which `active` counts, and wall and active without them and without the review rounds' redelivery waits
    # (which sit in `active` too; a dispatch redelivery is in `stopped`). `machine_wait` is the first part only; wall - machine_wait - review_deliver_wait = wall_ex_wait.
    #
    # @param row [Hash] has `wall` and `active`
    # @param totals [Hash, nil] `workflow trace --json` totals
    # @return [Hash] `machine_wait`, `wall_ex_wait`, `active_ex_wait`; nil where unknown
    def self.machine_wait(row, totals)
      buckets = totals && totals["machine_waiting_seconds"]
      return {machine_wait: nil, wall_ex_wait: nil, active_ex_wait: nil} unless buckets.is_a?(Hash)
      active = row[:active]
      wait = buckets.values.grep(Numeric).sum
      wait = [wait, active].min if active.is_a?(Numeric)
      less = wait + row[:review_deliver_wait].to_f
      minus = ->(value) { value.is_a?(Numeric) ? [value - less, 0].max : nil }
      {machine_wait: wait, wall_ex_wait: minus.call(row[:wall]), active_ex_wait: minus.call(row[:active])}
    end

    # The lines under the leak line that say what the possible hits were.
    #
    # @param classes [Hash, nil] see {DemoCalculator2::Checks#classify_possible}
    # @return [Array<String>]
    def self.possible_lines(classes)
      return [] unless classes
      lines = %i[hook transcript].map do |source|
        counts = classes[source]
        "possible hits (#{source}): " + Checks::CLASSES.map { |name| "#{counts[name]} #{name.to_s.tr("_", " ")}" }.join(", ")
      end
      classes[:near_misses].each { |miss| lines << "near-miss (#{miss[:source]}): #{miss[:command]}" }
      lines
    end

    # How far the critical path's parts may differ from the measured wall before the eval flags an error.
    PATH_TOLERANCE = 5
    # The harness polls every 15s, so it notices a drained lane up to that late; plus the tolerance.
    HARNESS_LAG_LIMIT = 20

    # The numbers of a lanes run that no single item has: wall, the sequential equivalent, the critical path, the waits
    # on it, lock waits per lane and the integration. A row needs `lane` ("A" or "B"), `goal`, `started_at` and `ended_at`
    # (ISO strings) to count; a part that cannot be worked out is nil.
    #
    # Wall runs from the earliest item start in either lane to the end of the integration. The critical path is the
    # 01-03 span (to the end of the fork goal), fork latency (to lane B's first start), the longer lane's tail from that start and
    # the integration (its recorded start to its end). A gap between the later lane's end and the integration's start is the delta.
    #
    # @param rows [Array<Hash>] both lanes' item rows
    # @param fork [Hash, nil] run.json's `fork` block (`goal`)
    # @param integration [Hash, nil] run.json's `integration` block (`started_at`, `ended_at`, `first_pass`, `conflict`, `integrate_run`)
    # @param integrate_attempts [Integer, nil] attempts of the integrate-branch run, when there was one
    # @param first_item_at [String, nil] when the harness saw lane A's first item start (run.json `lanes.first_item_at`): with the integration's
    #   recorded end it is a wall measured apart from the item rows the parts come from
    # @return [Hash] `wall`, `sequential`, `critical_path` (with `check`), `wall_net_of_waits`, `lock_waits`, `integration`
    def self.lanes(rows, fork:, integration:, integrate_attempts: nil, first_item_at: nil)
      ran = rows.select { |row| row[:ran] && time(row[:started_at]) && time(row[:ended_at]) }
      lane = ->(name) { ran.select { |row| row[:lane] == name }.sort_by { |row| time(row[:started_at]) } }
      a = lane.call("A")
      b = lane.call("B")
      integration ||= {}
      started = time(integration["started_at"])
      ended = time(integration["ended_at"])
      first = ran.map { |row| time(row[:started_at]) }.min
      wall = (first && ended) ? ended - first : nil
      walls = rows.select { |row| row[:ran] }.map { |row| row[:wall] }.grep(Numeric)
      integration_wall = (started && ended) ? ended - started : nil
      sequential = (walls.empty? || integration_wall.nil?) ? nil : walls.sum + integration_wall
      harness_wall = (time(first_item_at) && ended) ? ended - time(first_item_at) : nil
      path = critical_path(a, b, first, started, ended, fork && fork["goal"], harness_wall, fork && time(fork["at"]))
      {wall: wall, sequential: sequential, critical_path: path, wall_net_of_waits: net_of_waits(wall, a, b, path, fork && fork["goal"]),
       lock_waits: lock_waits(ran), integration: {
         wall: integration_wall, merge: integration["merge"], first_pass: integration["first_pass"], conflict: integration["conflict"],
         integrate_attempts: integrate_attempts, integrate_passed: integration.dig("integrate_run", "passed")
       }}
    end

    # @return [Hash, nil] `span`, `fork_latency`, `a_tail`, `b_tail`, `integration`, `slack`, `lane` (the longer one) and
    #   `harness_lag` (integration start less the later lane's end; `harness_lag_flagged` above HARNESS_LAG_LIMIT) and
    #   `check` (`sum`, `delta` against the harness's wall (nil without it), `fork_ordered`, `ok`: the parts add up to it within PATH_TOLERANCE, none is negative and the recorded fork time falls between the fork goal's end and lane B's first start); nil without both lanes and a fork goal
    def self.critical_path(a, b, first, started, ended, fork_goal, wall, fork_at = nil)
      fork_row = a.find { |row| row[:goal] == fork_goal }
      return nil if fork_row.nil? || b.empty? || first.nil? || started.nil? || ended.nil?
      fork_end = time(fork_row[:ended_at])
      b_start = time(b.first[:started_at])
      a_end = a.map { |row| time(row[:ended_at]) }.max
      b_end = b.map { |row| time(row[:ended_at]) }.max
      parts = {span: fork_end - first, fork_latency: b_start - fork_end, a_tail: a_end - b_start, b_tail: b_end - b_start, integration: ended - started, harness_lag: started - [a_end, b_end].max}
      longest = [parts[:a_tail], parts[:b_tail]].max
      sum = parts[:span] + parts[:fork_latency] + longest + parts[:harness_lag] + parts[:integration]
      # The parts come from the run files' timestamps; `wall` here is the harness's own (first item seen to integration end), so a
      # part that is wrong or missing shows as delta. Without the harness's start there is no delta and ok is an ordering check only.
      delta = wall && (sum - wall).abs
      # The one reading the parts do not share: the harness's own fork time must sit between the fork goal's end and lane B's first start.
      ordered = fork_at.nil? || fork_at.between?(fork_end - PATH_TOLERANCE, b_start + PATH_TOLERANCE)
      parts.merge(slack: (a_end - b_end).abs, lane: (a_end >= b_end) ? "A" : "B",
        harness_lag_flagged: parts[:harness_lag] > HARNESS_LAG_LIMIT,
        check: {sum: sum, delta: delta, fork_ordered: ordered, ok: (delta.nil? || delta <= PATH_TOLERANCE) && ordered && [parts[:span], parts[:fork_latency], longest, parts[:harness_lag], parts[:integration]].all? { |v| v >= 0 }})
    end

    # Wall less the machine, redelivery and person waits of the items on the critical path: lane A through the fork goal,
    # then the longer lane's.
    def self.net_of_waits(wall, a, b, path, fork_goal)
      return nil if wall.nil? || path.nil?
      cut = a.index { |row| row[:goal] == fork_goal }
      items = a.first(cut + 1) + ((path[:lane] == "A") ? a.drop(cut + 1) : b)
      waited = items.sum { |row| [row[:machine_wait], row[:deliver_wait], row[:person_wait]].grep(Numeric).sum }
      [wall - waited, 0].max
    end

    # @return [Hash{String => Hash}] per lane, the lock wait in seconds (`waiting_lock`) and whether it is nonzero (`flagged`)
    def self.lock_waits(ran)
      %w[A B].to_h do |name|
        seconds = ran.select { |row| row[:lane] == name }.sum { |row| row[:lock_wait].to_f }
        [name, {seconds: seconds, flagged: seconds > 0}]
      end
    end

    # What a run's reviewers and verify step caught: failed attempts of the verify step, and rejecting verdicts the
    # attempts kept.
    #
    # @param run [Hash] a stored run
    # @return [Hash] `verify_fixes` and `review_rejections`
    def self.catches(run)
      verify = Array(run.dig("steps", "verify", "attempts"))
      rejections = run.fetch("steps", {}).values.sum do |step|
        Array(step["attempts"]).sum { |attempt| Array(attempt["reviews"]).grep(Hash).count { |review| review["verdict"] == "reject" } }
      end
      {verify_fixes: verify.count { |attempt| attempt["outcome"] == "failed" }, review_rejections: rejections}
    end

    # The lines a lanes eval prints under the item tables.
    #
    # @param lanes [Hash] see {.lanes}
    # @param fork [Hash, nil]
    # @return [Array<String>]
    def self.lanes_lines(lanes, fork)
      fmt = DemoCalculator::Fmt
      duration = ->(value) {
        if value.nil?
          fmt::UNKNOWN
        else
          (value.negative? ? "-#{fmt.duration(-value)}" : fmt.duration(value))
        end
      }
      path = lanes[:critical_path]
      lines = ["wall: #{duration.call(lanes[:wall])}  sequential equivalent: #{duration.call(lanes[:sequential])}  wall net of waits: #{duration.call(lanes[:wall_net_of_waits])}"]
      if path
        lines << "critical path: 01-03 #{duration.call(path[:span])} + fork #{duration.call(path[:fork_latency])} + tail #{duration.call([path[:a_tail], path[:b_tail]].max)} + harness lag #{duration.call(path[:harness_lag])} " \
          "(lane #{path[:lane]}; A #{duration.call(path[:a_tail])}, B #{duration.call(path[:b_tail])}) + integration #{duration.call(path[:integration])} = #{duration.call(path[:check][:sum])}; slack #{duration.call(path[:slack])}"
        lines << "WARNING: the harness took #{duration.call(path[:harness_lag])} to start the integration after the later lane ended (more than #{HARNESS_LAG_LIMIT}s)" if path[:harness_lag_flagged]
        lines << "ERROR: the critical path differs from the harness's wall by #{duration.call(path[:check][:delta])} or has a negative part, or the recorded fork time is outside the fork goal's end and lane B's start: the eval is wrong or the run record is incomplete" unless path[:check][:ok]
      else
        lines << "critical path: #{fmt::UNKNOWN}#{" (fork goal #{fork["goal"]})" if fork}"
      end
      locks = lanes[:lock_waits].map { |name, wait| "#{name} #{duration.call(wait[:seconds])}" }.join(", ")
      lines << "lock waits: #{locks}#{" (nonzero: the test-db lock is back; check the definition's uses)" if lanes[:lock_waits].values.any? { |wait| wait[:flagged] }}"
      integration = lanes[:integration]
      yes_no = ->(value) {
        if value.nil?
          fmt::UNKNOWN
        else
          (value ? "yes" : "no")
        end
      }
      lines << "integration: merge #{integration[:merge] || fmt::UNKNOWN}, first pass #{yes_no.call(integration[:first_pass])}, conflict #{yes_no.call(integration[:conflict])}, " \
        "integrate run attempts #{integration[:integrate_attempts] || "-"}, took #{duration.call(integration[:wall])}"
      lines
    end

    LOOP_STEP = "implement".freeze

    # How the acceptance step went in one run, from its stored attempts.
    #
    # @param run [Hash] a stored run
    # @return [Hash] `attempts` (ended ones), `first_head` (the checkout the first attempt began on, or nil),
    #   `first_recorded` (whether that attempt's recorded outcome was passed; nil when it never ended) and `loops`
    #   (see {.loops})
    def self.acceptance(run)
      attempts = Array(run.dig("steps", ACCEPTANCE_STEP, "attempts"))
      ended = attempts.select { |a| a["outcome"] }
      head = attempts.first&.dig("head", "before")
      {attempts: ended.size, first_head: (head.is_a?(String) && !head.empty?) ? head : nil,
       first_recorded: ended.empty? ? nil : ended.first["outcome"] == "passed", loops: loops(run)}
    end

    # The times the run went back to implement after a failed acceptance attempt: one per failed acceptance attempt
    # that an attempt of implement follows before the next acceptance attempt starts. A retry of acceptance itself,
    # or an infra restart that adds another implement attempt inside the same pass, is not a second loop.
    #
    # @param run [Hash] a stored run
    # @return [Integer]
    def self.loops(run)
      events = run.fetch("steps", {}).flat_map do |id, state|
        next [] unless [ACCEPTANCE_STEP, LOOP_STEP].include?(id)
        Array(state["attempts"]).filter_map { |a| (t = time(a["started_at"])) && [t, id, a["outcome"]] }
      end.sort_by(&:first)
      count = 0
      failed = false
      events.each do |_, id, outcome|
        if id == ACCEPTANCE_STEP
          failed = outcome == "failed"
        elsif failed
          count += 1
          failed = false
        end
      end
      count
    end

    # The distinctive lines of some files: stripped, MIN_LINE long or more, not a comment.
    #
    # @param texts [Array<String>]
    # @return [Set<String>]
    def self.signature(texts)
      texts.flat_map(&:lines).map(&:strip).select { |l| l.length >= MIN_LINE && !l.start_with?("#") }.to_set
    end

    # The added lines of a diff (`git diff -U0`) that are also in the signature.
    #
    # @param diff [String]
    # @param signature [Set<String>]
    # @return [Array<String>] each copied line once
    def self.copied(diff, signature)
      added = diff.lines.select { |l| l.start_with?("+") && !l.start_with?("+++") }.map { |l| l[1..].strip }
      added.select { |l| signature.include?(l) }.uniq
    end

    # The paths of `git diff --name-status` that were added or changed (not deleted), under any rename or copy.
    def self.touched(name_status)
      name_status.lines.filter_map do |line|
        status, *paths = line.chomp.split("\t")
        paths.last if status && !status.start_with?("D") && paths.any?
      end
    end

    # The line under the table about the diff scan.
    def self.diff_line(diff)
      return "diff scan: #{DemoCalculator::Fmt::UNKNOWN}" unless diff
      "diff scan: #{diff[:paths].size} acceptance path#{"s" unless diff[:paths].size == 1} touched, #{diff[:copied].size} copied line#{"s" unless diff[:copied].size == 1}"
    end

    def self.round_spans(trace)
      Array(trace && trace["spans"]).select { |span| span["kind"] == "review_round" }
    end

    private_class_method :round_spans

    def self.time(text)
      text && Time.parse(text)
    rescue ArgumentError
      nil
    end
    private_class_method :time
  end
end
