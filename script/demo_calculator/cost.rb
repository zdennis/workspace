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

    # Adds every attempt's usage and every round's usage.
    # Returns the four totals plus :partial (some usage was nil) and :shared
    # (some attempt's usage is counted under its fan-out group).
    def self.sum(attempts)
      total = KINDS.keys.to_h { |kind| [kind, 0] }.merge(partial: false, shared: false)
      Array(attempts).each do |attempt|
        if attempt["usage_shared"]
          total[:shared] = true
          next
        end
        add(total, attempt["usage"])
        Array(attempt["rounds"]).each { |round| add(total, round["usage"]) }
      end
      total
    end

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

    # "≈$x.xx", or "?" when the model is not in the pricing table.
    def self.price(tokens, model, pricing)
      rates = (pricing["models"] || {})[model]
      return Fmt::UNKNOWN unless rates
      dollars = Tokens::KINDS.keys.sum { |kind| tokens[kind].to_i * rates[kind.to_s].to_f } / 1_000_000.0
      format("≈$%.2f", dollars)
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
  end
end
