module Workspace
  # Reads the global `events:` block, as written by `workspace config set`.
  #
  # A bad stored value never stops the daemon: it falls back to the default
  # with a warning, since `config set` already rejects bad input.
  class EventsConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param error_output [IO] where a warning about an unusable value goes
    def initialize(config_resolver:, error_output: $stderr)
      @config_resolver = config_resolver
      @error_output = error_output
    end

    # @return [Integer] bytes at which a daemon's hook-event file rotates:
    #   `events.rotate_size`, or its default when unset, invalid or unreadable
    def rotate_size
      default = ConfigSchema.default("events.rotate_size")
      value = @config_resolver.view(workspace: "", upto: "global").raw("events.rotate_size")
      value.nil? ? default : ConfigSchema.parse("events.rotate_size", value)
    rescue Workspace::ConfigParseError, ArgumentError => e
      @error_output.puts "Warning: events.rotate_size: #{e.message} Using #{ByteSize.humanize(default)}."
      default
    end
  end
end
