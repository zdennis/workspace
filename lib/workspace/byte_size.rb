module Workspace
  # Parses byte sizes for config values: a byte count or a number with a
  # KB, MB or GB suffix. Suffixes are binary (1KB is 1024 bytes).
  module ByteSize
    UNITS = {"" => 1, "b" => 1, "kb" => 1024, "mb" => 1024**2, "gb" => 1024**3}.freeze
    private_constant :UNITS

    # @param value [String, Integer] "5242880", "512KB", "1MB" or "1.5MB"
    # @return [Integer] bytes
    # @raise [ArgumentError] if value isn't a recognized size
    def self.parse(value)
      match = /\A(\d+(?:\.\d+)?)\s*([a-z]*)\z/i.match(value.to_s.strip)
      unit = match && UNITS[match[2].downcase]
      raise ArgumentError, "expected a size like \"5242880\", \"512KB\" or \"1MB\", got #{value.inspect}" unless unit
      (match[1].to_f * unit).round
    end

    # @param value [String, Integer] a size, as for {parse}
    # @param min [Integer] the smallest number of bytes accepted
    # @return [Integer] bytes, at least +min+
    # @raise [ArgumentError] if value isn't a size, or is below +min+
    def self.parse_at_least(value, min:)
      bytes = parse(value)
      raise ArgumentError, "must be at least #{humanize(min)}, got #{value.inspect}" if bytes < min
      bytes
    end

    # @param bytes [Integer]
    # @return [String] e.g. "64KB", "5MB"; plain bytes when not a whole KB
    def self.humanize(bytes)
      return "#{bytes / 1024**2}MB" if (bytes % 1024**2).zero?
      return "#{bytes / 1024}KB" if (bytes % 1024).zero?
      "#{bytes}B"
    end
  end
end
