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
  end
end
