module Workspace
  # Reads the `dev:` block (`up`, `ready`, `stop_timeout`, `startup_timeout`,
  # `ready_timeout`, `kill_grace`) from a project's YAML config, as written by
  # `workspace config set`.
  #
  # Worktrees are not resolved here: callers pass the already-resolved
  # parent project name (see {WorkspaceLineage}), so this stays a plain
  # reader over {ProjectSettings}.
  class DevConfig
    DEFAULT_STOP_TIMEOUT = ConfigSchema.default("dev.stop_timeout")
    DEFAULT_STARTUP_TIMEOUT = ConfigSchema.default("dev.startup_timeout")
    DEFAULT_READY_TIMEOUT = ConfigSchema.default("dev.ready_timeout")
    # Largest accepted `dev.kill_grace`, in seconds (see {ProcessHolderStopper}).
    MAX_KILL_GRACE = ConfigSchema::MAX_KILL_GRACE

    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Hash] :up [String, nil], :ready [String, nil], :stop_timeout [Numeric],
    #   :startup_timeout [Numeric], :ready_timeout [Numeric], :kill_grace [Numeric]
    # @raise [Workspace::Error] if a stored duration key isn't a valid duration
    def for_project(name)
      build(@project_settings.load(name)["dev"] || {}, name)
    end

    # Whether the project has a dev environment to run: `dev.up` holds a command. Reads only
    # that key, so a bad duration elsewhere in the block does not matter.
    #
    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Boolean]
    # @raise [Workspace::ConfigParseError] if the project's config file can't be parsed
    def configured?(name)
      !block(name)["up"].to_s.strip.empty?
    end

    # Whether `start` and `launch` may send the built-in `dev` pack (`dev.instructions`).
    #
    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Boolean] false only when the project sets `dev.instructions` to false;
    #   unset, or a value `config set` would refuse, is true
    # @raise [Workspace::ConfigParseError] if the project's config file can't be parsed
    def instructions?(name)
      block(name)["instructions"].to_s != "false"
    end

    # Settings with every key unset, for callers that must still act when the
    # project config can't be read (e.g. `dev down`).
    #
    # @return [Hash] same shape as {#for_project}
    def defaults
      build({}, nil)
    end

    private

    def block(name)
      dev = @project_settings.load(name)["dev"]
      dev.is_a?(Hash) ? dev : {}
    end

    def build(dev, name)
      {
        up: dev["up"],
        ready: dev["ready"],
        stop_timeout: duration(dev, "stop_timeout", name),
        startup_timeout: duration(dev, "startup_timeout", name),
        ready_timeout: duration(dev, "ready_timeout", name),
        kill_grace: duration(dev, "kill_grace", name)
      }
    end

    def duration(dev, key, name)
      schema_key = "dev.#{key}"
      return ConfigSchema.default(schema_key) unless dev.key?(key)
      ConfigSchema.parse(schema_key, dev[key])
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.#{key} for '#{name}': #{e.message}"
    end
  end
end
