require_relative "cost"

module DemoCalculator
  # `eval --compare`: medians over the last K eval.json documents that scored
  # the same workflow definitions. Pure: takes parsed hashes (string keys),
  # reads nothing, spawns nothing.
  #
  # Each document's `totals` hash holds numbers, or nil when unknown:
  # attempts, retries, review_rounds_distinct (review_rounds in older files), wall, active, stopped (seconds),
  # input, output, cache_creation, cache_read, cost_usd (dollars),
  # acceptance_passed, lint (offenses). `totals["partial"]` may list metric
  # keys whose number is only a lower bound. Anything that is not a number
  # counts as unknown.
  module Compare
    MIN_RUNS = 3
    DEFAULT_LAST = 3

    # [totals key, column label, kind]
    METRICS = [
      ["attempts", "attempts", :count],
      ["retries", "retries", :count],
      ["review_rounds_distinct", "rounds", :count],
      ["wall", "wall", :seconds],
      ["active", "active", :seconds],
      ["stopped", "stopped", :seconds],
      ["input", "input tok", :count],
      ["output", "output tok", :count],
      ["cache_creation", "cache write tok", :count],
      ["cache_read", "cache read tok", :count],
      ["cost_usd", "cost", :dollars],
      ["acceptance_passed", "acceptance passed", :count],
      ["lint", "lint offenses", :count]
    ].freeze

    HEADER_FIELDS = %w[model agent_version base_sha workspace_sha price_date].freeze

    # Documents with a record stamp, oldest first.
    def self.load(docs)
      Array(docs).select { |doc| doc.is_a?(Hash) && stamp(doc) }.sort_by { |doc| stamp(doc) }
    end

    # What makes two runs comparable: the same items, model and agent version. A definition edit does
    # not split a group; {definition_status} says where one happened.
    def self.group_key(doc)
      [doc.dig("record", "definitions")&.keys&.sort, doc.dig("header", "model"), doc.dig("header", "agent_version")]
    end

    # The last `last` documents that share the newest's group_key, oldest first.
    def self.select(docs, last: DEFAULT_LAST)
      loaded = load(docs)
      return [] if loaded.empty?
      key = group_key(loaded.last)
      loaded.select { |doc| group_key(doc) == key }.last(last)
    end

    # {item id => true when its definition hash is not the same in every one of docs}.
    def self.definition_status(docs)
      ids = docs.flat_map { |doc| doc.dig("record", "definitions")&.keys.to_a }.uniq.sort
      ids.to_h { |id| [id, docs.map { |doc| doc.dig("record", "definitions", id) }.uniq.size > 1] }
    end

    # How many runs a comparison needs: MIN_RUNS, or fewer when `last` asks for fewer, never below 2.
    def self.needed(last)
      last.clamp(2, MIN_RUNS)
    end

    # Median of numbers; the mean of the two middle ones for an even count; nil for none.
    def self.median(numbers)
      sorted = numbers.sort
      return nil if sorted.empty?
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # {median:, min:, max:, known:, partial:} for one totals key across docs.
    # partial is true when any run lacks the value or marks it a lower bound.
    def self.stat(docs, key)
      values = docs.map { |doc| doc.dig("totals", key) || (doc.dig("totals", "review_rounds") if key == "review_rounds_distinct") }
      known = values.select { |v| v.is_a?(Numeric) }
      lower_bound = docs.any? { |doc| Array(doc.dig("totals", "partial")).include?(key) }
      {median: median(known), min: known.min, max: known.max, known: known.size,
       partial: known.size < docs.size || lower_bound}
    end

    # {totals key => stat} for every metric.
    def self.summary(docs)
      METRICS.to_h { |key, _label, _kind| [key, stat(docs, key)] }
    end

    # {field => {values: [...], differs: bool}} for the header fields, one value per run.
    def self.header(docs)
      HEADER_FIELDS.to_h do |field|
        values = docs.map { |doc| doc.dig("header", field) }
        [field, {values: values, differs: values.uniq.size > 1}]
      end
    end

    # The text of `eval --compare`: a header, then either the median table or,
    # with fewer than MIN_RUNS matching runs, just the runs.
    def self.render(docs, last: DEFAULT_LAST)
      chosen = select(docs, last: last)
      return "No eval runs to compare.\n" if chosen.empty?
      lines = header_lines(chosen) + [""]
      if chosen.size < needed(last)
        lines << "Only #{chosen.size} matching run#{"s" unless chosen.size == 1} (need #{needed(last)} for a comparison). Runs:"
        chosen.each { |doc| lines << "  #{stamp(doc)}  #{doc.dig("record", "branch") || Fmt::UNKNOWN}" }
      else
        lines << "Median [min–max] over #{chosen.size} runs (#{chosen.map { |d| stamp(d) }.join(", ")}):"
        lines.concat(table(chosen))
      end
      lines.join("\n") + "\n"
    end

    def self.header_lines(docs)
      fields = header(docs)
      differing = fields.select { |_f, info| info[:differs] }.keys
      lines = ["Runs: #{docs.size}"]
      HEADER_FIELDS.each do |field|
        info = fields[field]
        text = if info[:differs]
          "differs (#{info[:values].map { |v| Fmt.value(v) }.join(", ")})"
        else
          Fmt.value(info[:values].first)
        end
        lines << "  #{field}: #{text}"
      end
      lines << "  differing: #{differing.empty? ? "none" : differing.join(", ")}"
      definition_status(docs).each do |id, changed|
        lines << "  definition #{id}: #{changed ? "differs" : "same"}"
      end
      lines
    end

    def self.table(docs)
      stats = summary(docs)
      width = METRICS.map { |_k, label, _kind| label.size }.max
      METRICS.map do |key, label, kind|
        "  #{label.ljust(width)}  #{cell(stats[key], kind)}"
      end
    end

    # "median [min–max]" with ≥ when a value was left out; "?" when none known.
    def self.cell(stat, kind)
      return Fmt::UNKNOWN if stat[:known].zero?
      text = "#{format_value(stat[:median], kind)} [#{format_value(stat[:min], kind)}–#{format_value(stat[:max], kind)}]"
      Fmt.total(text, stat[:partial])
    end

    def self.format_value(number, kind)
      case kind
      when :dollars then Fmt.dollars(number)
      when :seconds then Fmt.duration(number)
      else (number == number.to_i) ? number.to_i.to_s : format("%.1f", number)
      end
    end

    def self.stamp(doc)
      doc.dig("record", "stamp")
    end

    private_class_method :group_key, :header_lines, :table, :cell, :format_value, :stamp
  end
end
