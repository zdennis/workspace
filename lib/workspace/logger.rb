module Workspace
  # Minimal debug logger for the workspace CLI.
  # When disabled (the default), debug calls are no-ops with zero overhead.
  # When enabled, writes timestamped messages to the configured output stream.
  #
  # Uses block form to avoid string interpolation when debug is off:
  #   @logger.debug { "Ran command: #{cmd}" }
  class Logger
    # @param output [IO] stream to write debug messages to
    # @param enabled [Boolean] whether debug logging is active
    def initialize(output: $stderr, enabled: false)
      @output = output
      @enabled = enabled
    end

    # @return [Boolean] whether debug logging is active
    def enabled?
      @enabled
    end

    # Enables debug logging at runtime (e.g. when --debug flag is parsed).
    #
    # @return [void]
    def enable!
      @enabled = true
    end

    # Logs a debug message. Accepts a block to defer string construction.
    #
    # @yield [] block that returns the message string
    # @param message [String, nil] message string (used if no block given)
    # @return [void]
    def debug(message = nil)
      return unless @enabled
      msg = block_given? ? yield : message
      @output.puts "[DEBUG] #{msg}"
    end
  end
end
