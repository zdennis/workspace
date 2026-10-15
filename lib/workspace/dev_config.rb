module Workspace
  # Reads the `dev:` block (`up`, `ready`, `stop_timeout`, `startup_timeout`,
  # `ready_timeout`, `kill_grace`) from a project's YAML config, as written by
  # `workspace config set`.
  #
  # Each key is resolved on its own through {ConfigResolver}, so a key a worktree
  # may not override (`stop_timeout`, `kill_grace`) never follows another key
  # into a worktree's file. Callers pass the workspace name where they have it
  # (a worktree's config name), or a project name.
  class DevConfig
    DEFAULT_STOP_TIMEOUT = ConfigSchema.default("dev.stop_timeout")
    DEFAULT_STARTUP_TIMEOUT = ConfigSchema.default("dev.startup_timeout")
    DEFAULT_READY_TIMEOUT = ConfigSchema.default("dev.ready_timeout")
    # Largest accepted `dev.kill_grace`, in seconds (see {ProcessHolderStopper}).
    MAX_KILL_GRACE = ConfigSchema::MAX_KILL_GRACE

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param workspace [String] a workspace or project name
    # @return [Hash] :up [String, nil], :ready [String, nil], :stop_timeout [Numeric],
    #   :startup_timeout [Numeric], :ready_timeout [Numeric], :kill_grace [Numeric]
    # @raise [Workspace::Error] if a stored duration key isn't a valid duration
    def for_project(workspace)
      build(@config_resolver.view(workspace: workspace), workspace)
    end

    # Whether the project has a dev environment to run: `dev.up` holds a command. Reads only
    # that key, so a bad duration elsewhere in the block does not matter.
    #
    # @param workspace [String] a workspace or project name
    # @return [Boolean]
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def configured?(workspace)
      !view(workspace).raw("dev.up").to_s.strip.empty?
    end

    # Whether `start` and `launch` may send the built-in `dev` pack (`dev.instructions`).
    #
    # @param workspace [String] a workspace or project name
    # @return [Boolean] false only when `dev.instructions` is set to false;
    #   unset, or a value `config set` would refuse, is true
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def instructions?(workspace)
      view(workspace).raw("dev.instructions").to_s != "false"
    end

    # Whether the dev environment an agent started is stopped when that agent's session ends
    # (`dev.release_on_session_end`).
    #
    # @param workspace [String] a workspace or project name
    # @return [Boolean] false only when the key is set to false
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def release_on_session_end?(workspace)
      view(workspace).raw("dev.release_on_session_end").to_s != "false"
    end

    # Settings with every key unset, for callers that must still act when the
    # project config can't be read (e.g. `dev down`).
    #
    # @return [Hash] same shape as {#for_project}
    def defaults
      {
        up: nil,
        ready: nil,
        stop_timeout: DEFAULT_STOP_TIMEOUT,
        startup_timeout: DEFAULT_STARTUP_TIMEOUT,
        ready_timeout: DEFAULT_READY_TIMEOUT,
        kill_grace: ConfigSchema.default("dev.kill_grace")
      }
    end

    private

    def view(workspace) = @config_resolver.view(workspace: workspace)

    def build(view, workspace)
      {
        up: view.raw("dev.up"),
        ready: view.raw("dev.ready"),
        stop_timeout: duration(view, "stop_timeout", workspace),
        startup_timeout: duration(view, "startup_timeout", workspace),
        ready_timeout: duration(view, "ready_timeout", workspace),
        kill_grace: duration(view, "kill_grace", workspace)
      }
    end

    def duration(view, key, workspace)
      schema_key = "dev.#{key}"
      winner = view.resolve(schema_key).winner
      return ConfigSchema.default(schema_key) unless winner
      ConfigSchema.parse(schema_key, winner.value)
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.#{key} for '#{workspace}': #{e.message}"
    end
  end
end
