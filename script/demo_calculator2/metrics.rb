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
