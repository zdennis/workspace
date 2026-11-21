require_relative "cost"
require_relative "eval_rows"

module DemoCalculator
  # The numbers and text of `eval`, built from rows and run hashes. Pure: reads nothing, spawns nothing.
  module EvalReport
    TIME_KEYS = %w[wall active stopped].freeze
    COUNT_KEYS = %w[attempts retries review_rounds].freeze
    TOKEN_KEYS = Tokens::KINDS.keys.map(&:to_s).freeze
    DASH = "–".freeze
    SHARED = "shared".freeze

    # Tokens, cost, models and agent versions of one run.
    #
    # @param run [Hash] a stored run
    # @param pricing [Hash] the parsed demo/pricing.yml
    # @return [Hash] `tokens` (the four kinds, `partial`, `shared`, `known`), `cost_usd` (Float or nil),
    #   `cost_partial`, `models`, `agent_versions`
    def self.usage(run, pricing)
      attempts = EvalRows.attempts(run)
      tokens = Tokens.sum(attempts)
      tokens[:all_shared] = !attempts.empty? && attempts.all? { |a| a["usage_shared"] }
      tokens[:known] = !tokens[:all_shared] && !(tokens[:partial] && Tokens::KINDS.keys.all? { |kind| tokens[kind].zero? })
      cost = 0.0
      priced = false
      cost_partial = tokens[:partial] || tokens[:shared]
      attempts.each do |attempt|
        next if attempt["usage_shared"]
        round_usage = attempt["usage"].nil? && Array(attempt["rounds"]).any? { |round| round["usage"] }
        next if attempt["usage"].nil? && !round_usage
        cost_partial = true if round_usage
        dollars = Cost.dollars(Tokens.sum([attempt]), attempt.dig("agent", "model"), pricing)
        dollars ? (cost += dollars) && (priced = true) : cost_partial = true
      end
      {tokens: tokens, cost_usd: priced ? cost : nil, cost_partial: cost_partial,
       models: attempts.filter_map { |a| a.dig("agent", "model") }.uniq.sort,
       agent_versions: attempts.filter_map { |a| a.dig("agent", "version") }.uniq.sort}
    end

    # The `totals` of eval.json over the rows that ran. Keys are the ones Compare reads; a value that is
    # unknown is nil, and `partial` lists the keys that are lower bounds.
    #
    # @param rows [Array<Hash>] EvalRows rows, each merged with its `usage` (see {usage})
    # @param acceptance_passed [Integer, nil] passing groups at the last run item
    # @param lint [Integer, nil] offenses at the last run item
    def self.totals(rows, acceptance_passed:, lint:)
      ran = rows.select { |row| row[:ran] }
      totals = {"items" => rows.size, "items_run" => ran.size}
      partial = []
      COUNT_KEYS.each { |key| totals[key] = ran.empty? ? nil : ran.sum { |row| row[key.to_sym] } }
      TIME_KEYS.each do |key|
        values = ran.map { |row| row[key.to_sym] }
        known = values.select { |v| v.is_a?(Numeric) }
        totals[key] = known.empty? ? nil : known.sum
        partial << key if !known.empty? && known.size < values.size
      end
      usages = ran.map { |row| row[:usage] }
      known = usages.select { |u| u[:tokens][:known] }
      TOKEN_KEYS.each { |key| totals[key] = known.empty? ? nil : known.sum { |u| u[:tokens][key.to_sym] } }
      lower = usages.any? { |u| u[:tokens][:partial] || u[:tokens][:shared] || !u[:tokens][:known] }
      partial.concat(TOKEN_KEYS) if lower && !known.empty?
      costs = usages.filter_map { |u| u[:cost_usd] }
      totals["cost_usd"] = costs.empty? ? nil : costs.sum
      partial << "cost_usd" if !costs.empty? && usages.any? { |u| u[:cost_partial] || u[:cost_usd].nil? }
      totals["acceptance_passed"] = acceptance_passed
      totals["lint"] = lint
      totals["partial"] = partial
      totals
    end

    # Per-row cells of the table, plus a totals row.
    #
    # @param rows [Array<Hash>] EvalRows rows merged with `usage`, `acceptance`, `item` (1-based) and `groups`
    # @return [String] the fixed-width table
    def self.table(rows, totals)
      header = %w[item state feat att retry rnd wall active stopped gap in out cache_w cache_r cost accept]
      body = rows.map { |row| row[:ran] ? ran_cells(row) : not_run_cells(row) }
      body << total_cells(totals)
      widths = header.each_index.map { |i| ([header[i]] + body.map { |cells| cells[i] }).map { |c| c.to_s.length }.max }
      lines = [header, *body].map { |cells| cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ").rstrip }
      lines.insert(1, widths.map { |w| "-" * w }.join("  "))
      lines.join("\n")
    end

    def self.ran_cells(row)
      tokens = row[:usage][:tokens]
      token_cell = lambda do |kind|
        next SHARED if tokens[:all_shared]
        tokens[:known] ? Fmt.total(Fmt.count(tokens[kind]), tokens[:partial] || tokens[:shared]) : Fmt::UNKNOWN
      end
      cost = Fmt.total(Fmt.dollars(row[:usage][:cost_usd]), row[:usage][:cost_partial])
      [row[:workflow], row[:state], features_cell(row[:features]), row[:attempts], row[:retries], row[:review_rounds],
        Fmt.duration(row[:wall]), Fmt.duration(row[:active]), Fmt.duration(row[:stopped]), Fmt.duration(row[:gap]),
        token_cell.call(:input), token_cell.call(:output), token_cell.call(:cache_creation), token_cell.call(:cache_read),
        cost, acceptance_cell(row[:acceptance], row[:item])]
    end

    def self.not_run_cells(row)
      [row[:workflow], row[:state].to_s.empty? ? Fmt::NOT_RUN : row[:state]] + [DASH] * 14
    end

    def self.total_cells(totals)
      partial = totals["partial"]
      lower = ->(key, text) { Fmt.total(text, partial.include?(key)) }
      ["total", "#{totals["items_run"]}/#{totals["items"]} run", "", Fmt.value(totals["attempts"]), Fmt.value(totals["retries"]),
        Fmt.value(totals["review_rounds"]),
        lower.call("wall", Fmt.duration(totals["wall"])), lower.call("active", Fmt.duration(totals["active"])),
        lower.call("stopped", Fmt.duration(totals["stopped"])), "",
        lower.call("input", Fmt.count(totals["input"])), lower.call("output", Fmt.count(totals["output"])),
        lower.call("cache_creation", Fmt.count(totals["cache_creation"])), lower.call("cache_read", Fmt.count(totals["cache_read"])),
        lower.call("cost_usd", Fmt.dollars(totals["cost_usd"])),
        totals["acceptance_passed"].nil? ? Fmt::UNKNOWN : totals["acceptance_passed"].to_s]
    end

    def self.features_cell(features)
      return Fmt::UNKNOWN if features.empty?
      counts = features.values.tally
      [["f", EvalRows::FIRED], ["a", "armed"], ["m", "missed"], ["?", Fmt::UNKNOWN]].filter_map do |mark, state|
        "#{counts[state]}#{mark}" if counts[state]
      end.join(" ")
    end

    def self.acceptance_cell(acceptance, item)
      return Fmt::UNKNOWN unless acceptance
      text = "#{acceptance[:passed].size}/#{item}"
      acceptance[:regressions].empty? ? text : "#{text} reg:#{acceptance[:regressions].join(",")}"
    end

    # The line under the table about standardrb.
    def self.lint_line(lint)
      "lint: #{lint[:offenses].nil? ? Fmt::UNKNOWN : "#{lint[:offenses]} offense#{"s" unless lint[:offenses] == 1}"} in demo/calculator" \
        "#{" at #{lint[:head][0, 12]}" if lint[:head]}"
    end

    # The line under the table about reads of the acceptance directory.
    def self.leak_line(leak)
      return "leak: #{Fmt::UNKNOWN}" unless leak
      counts = leak[:transcript].values
      known = counts.compact.sum
      unreadable = counts.count(&:nil?)
      "leak: hook #{leak[:hook]}, transcript #{counts.empty? ? Fmt::UNKNOWN : known}" \
        "#{" (#{unreadable} of #{counts.size} unreadable)" if unreadable > 0}"
    end
    private_class_method :ran_cells, :not_run_cells, :total_cells, :features_cell, :acceptance_cell
  end
end
