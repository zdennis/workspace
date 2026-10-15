module Workspace
  # Reads `plan.stall_seconds` from a project's YAML config, as written by
  # `workspace config set plan.stall_seconds <duration>`: how long a plan's
  # owner pane may sit idle before the plan reads `stalled`.
  #
  # A bad stored value never stops `plan status`: it falls back to the default
  # with a warning, since `config set` already rejects bad input.
  class PlanConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param error_output [IO] where a warning about an invalid value goes
    def initialize(config_resolver:, error_output: $stderr)
      @config_resolver = config_resolver
      @error_output = error_output
    end

    # @param workspace [String] a workspace name; a worktree reads its parent project's value
    # @return [Numeric] seconds; the key's default when unset, invalid, or the config can't be parsed
    def stall_seconds_for(workspace)
      default = ConfigSchema.default("plan.stall_seconds")
      winner = @config_resolver.view(workspace: workspace).resolve("plan.stall_seconds").winner
      return default unless winner
      ConfigSchema.parse("plan.stall_seconds", winner.value)
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using #{default}s for plan.stall_seconds."
      default
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid plan.stall_seconds for '#{workspace}' (#{e.message}); using #{default}s."
      default
    end
  end
end
