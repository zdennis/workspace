require "yaml"

module DemoCalculator
  # Token totals over a run's attempts, read from run-file hashes (string keys).
  module Tokens
    KINDS = {
      input: "input_tokens",
      output: "output_tokens",
      cache_creation: "cache_creation_input_tokens",
      cache_read: "cache_read_input_tokens"
    }.freeze

    # Adds every attempt's usage and every round's usage. A round that was delivered again has none and is skipped.
    # Returns the four totals plus :partial (some usage was nil) and :shared
    # (some attempt's usage is shared and the attempt it points to is not among the attempts, so it may be uncounted).
    def self.sum(attempts)
      attempts = Array(attempts)
      total = KINDS.keys.to_h { |kind| [kind, 0] }.merge(partial: false, shared: false)
      attempts.each do |attempt|
        if attempt["usage_shared"]
          total[:shared] = true unless counted_elsewhere?(attempt["usage_shared"], attempts)
          next
        end
        add(total, attempt["usage"])
        Array(attempt["rounds"]).each { |round| add(total, round["usage"]) unless round["ended"] == "redelivered" }
      end
      total
    end

    # True when the attempt a `usage_shared` points to (step and attempt number) is in the list and has usage of its own.
    def self.counted_elsewhere?(ref, attempts)
      attempts.any? do |other|
        other["step"] == ref["step"] && other["n"] == ref["attempt"] && !other["usage_shared"] && !other["usage"].nil?
      end
    end
    private_class_method :counted_elsewhere?

    def self.add(total, usage)
      if usage.nil?
        total[:partial] = true
        return
      end
      KINDS.each { |kind, key| total[kind] += usage[key].to_i }
    end
    private_class_method :add
  end

  # Prices token totals against a pricing hash.
  module Cost
    def self.load_pricing(path)
      YAML.safe_load_file(path)
    end

    # The cost in dollars, or nil when the model is not in the pricing table.
    def self.dollars(tokens, model, pricing)
      rates = (pricing["models"] || {})[model]
      return nil unless rates
      Tokens::KINDS.keys.sum { |kind| tokens[kind].to_i * rates[kind.to_s].to_f } / 1_000_000.0
    end

    # "≈$x.xx", or "?" when the model is not in the pricing table.
    def self.price(tokens, model, pricing)
      dollars = dollars(tokens, model, pricing)
      dollars ? format("≈$%.2f", dollars) : Fmt::UNKNOWN
    end
  end

  # Text for values that may be unknown, partial or never run.
  module Fmt
    UNKNOWN = "?".freeze
    NOT_RUN = "not run".freeze

    def self.value(value)
      value.nil? ? UNKNOWN : value.to_s
    end

    # Prefixes a total with ≥ when part of it is unknown; an unknown stays "?".
    def self.total(text, partial)
      (partial && text != UNKNOWN) ? "≥#{text}" : text
    end

    def self.not_run
      NOT_RUN
    end

    # "1h02m", "4m05s" or "9s"; "?" for nil.
    def self.duration(seconds)
      return UNKNOWN if seconds.nil?
      hours, rest = seconds.round.divmod(3600)
      minutes, secs = rest.divmod(60)
      if hours > 0 then format("%dh%02dm", hours, minutes)
      elsif minutes > 0 then format("%dm%02ds", minutes, secs)
      else format("%ds", secs)
      end
    end

    # A number with thousands separators; "?" for nil.
    def self.count(number)
      number.nil? ? UNKNOWN : number.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    # "≈$x.xx"; "?" for nil.
    def self.dollars(amount)
      amount.nil? ? UNKNOWN : format("≈$%.2f", amount)
    end
  end
end
