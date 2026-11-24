module Workspace
  # Reads `agent.claude.trust_checkout` from the global config file, as written by
  # `workspace config set --scope global agent.claude.trust_checkout <true|false>`.
  # The key is global only: a value in a project or worktree file is ignored.
  #
  # A bad stored value never stops a launch: it falls back to the default
  # (true) with a warning, since `config set` already rejects bad input.
  class ClaudeTrustConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param error_output [IO] where a warning about an invalid value goes
    def initialize(config_resolver:, error_output: $stderr)
      @config_resolver = config_resolver
      @error_output = error_output
    end

    # @param workspace [String] the workspace name
    # @return [Boolean] whether `launch`, `start` and `add` trust the checkout in
    #   Claude Code; the schema default (true) when unset, invalid or the global file can't be parsed
    def enabled?(workspace)
      key = "agent.claude.trust_checkout"
      default = ConfigSchema.default(key)
      value = @config_resolver.view(workspace: workspace).raw(key)
      return default if value.nil?
      ConfigSchema.parse(key, value) == "true"
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid #{key} for '#{workspace}' (#{e.message}); using #{default}."
      default
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using the default for #{key}."
      default
    end
  end
end
