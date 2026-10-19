module Workspace
  # Reads the global `codex.hooks.install` key, as written by
  # `workspace config set`: whether `start` installs workspace's hooks into
  # Codex's user-level `hooks.json`.
  #
  # A bad stored value never stops `start`: it falls back to the default with
  # a warning, since `config set` already rejects bad input.
  class HooksConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param error_output [IO] where a warning about an unusable value goes
    def initialize(config_resolver:, error_output: $stderr)
      @config_resolver = config_resolver
      @error_output = error_output
    end

    # @return [Boolean] `codex.hooks.install`, or its default (true) when
    #   unset, invalid or unreadable
    def codex_install?
      default = ConfigSchema.default("codex.hooks.install")
      value = @config_resolver.view(workspace: "", upto: "global").raw("codex.hooks.install")
      value.nil? ? default : ConfigSchema.parse("codex.hooks.install", value).to_s == "true"
    rescue Workspace::ConfigParseError, ArgumentError => e
      @error_output.puts "Warning: codex.hooks.install: #{e.message} Using #{default}."
      default
    end

    # @param provider [Workspace::AgentProvider]
    # @return [Boolean] whether `start` may install +provider+'s user-level hooks
    def install_user_hooks?(provider)
      (provider.key.to_s == "codex") ? codex_install? : true
    end
  end
end
