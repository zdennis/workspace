module Workspace
  # Parses duration strings shared by dev/lock config and CLI options.
  module Duration
    UNITS = {"" => 1, "s" => 1, "m" => 60, "h" => 3600}.freeze
    private_constant :UNITS

    # Parses a duration string or number into seconds.
    # Supports: "20", "20s", "5m", "1h" (a plain number is seconds).
    #
    # @param value [String, Numeric] duration string or number
    # @return [Numeric] seconds
    # @raise [ArgumentError] if value isn't a recognized duration
    def self.parse(value)
      match = /\A(\d+(?:\.\d+)?)\s*([smh]?)\z/i.match(value.to_s.strip)
      raise ArgumentError, "expected a duration like \"20\", \"20s\", \"5m\" or \"1h\", got #{value.inspect}" unless match
      match[1].to_f * UNITS.fetch(match[2].downcase)
    end

    # Parses a duration string or number into seconds, requiring it be
    # greater than 0.
    #
    # @param value [String, Numeric] duration string or number
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a recognized duration, or isn't positive
    def self.parse_positive(value)
      seconds = parse(value)
      raise ArgumentError, "must be greater than 0, got #{value.inspect}" unless seconds.positive?
      seconds
    end

    # Parses a duration string or number into seconds, requiring it be
    # greater than 0 and no more than +max+ seconds.
    #
    # @param value [String, Numeric] duration string or number
    # @param max [Numeric] the largest number of seconds accepted
    # @return [Numeric] seconds, always in (0, max]
    # @raise [ArgumentError] if value isn't a recognized duration, isn't
    #   positive, or exceeds +max+
    def self.parse_capped(value, max:)
      seconds = parse_positive(value)
      raise ArgumentError, "must be greater than 0 and at most #{max}s, got #{value.inspect}" if seconds > max
      seconds
    end

    # Parses a duration string or number into seconds, requiring it fall
    # within [+min+, +max+] seconds, inclusive.
    #
    # @param value [String, Numeric] duration string or number
    # @param min [Numeric] the smallest number of seconds accepted
    # @param max [Numeric] the largest number of seconds accepted
    # @return [Numeric] seconds, always in [min, max]
    # @raise [ArgumentError] if value isn't a recognized duration, or falls
    #   outside [min, max]
    def self.parse_ranged(value, min:, max:)
      seconds = parse_positive(value)
      raise ArgumentError, "must be at least #{min}s and at most #{max}s, got #{value.inspect}" if seconds < min || seconds > max
      seconds
    end

    # Renders a non-negative number of seconds as a short, human-scale
    # duration: "45s", "12m", or "1h 30m". Rounds down to the minute once a
    # duration reaches a minute, since sub-minute precision doesn't matter at
    # that scale.
    #
    # @param seconds [Numeric] a non-negative number of seconds
    # @return [String] the rendered duration
    def self.humanize(seconds)
      total_minutes = (seconds / 60).to_i
      return "#{seconds.round}s" if total_minutes.zero?

      hours, minutes = total_minutes.divmod(60)
      hours.positive? ? "#{hours}h #{minutes}m" : "#{minutes}m"
    end
  end
end
