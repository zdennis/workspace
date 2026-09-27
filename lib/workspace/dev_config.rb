module Workspace
  # Reads the `dev:` block (`up`, `ready`, `stop_timeout`, `startup_timeout`,
  # `ready_timeout`) from a project's YAML config, as written by
  # `workspace config set`.
  #
  # Worktrees are not resolved here: callers pass the already-resolved
  # parent project name (see {WorkspaceLineage}), so this stays a plain
  # reader over {ProjectSettings}.
  class DevConfig
    DEFAULT_STOP_TIMEOUT = 20
    DEFAULT_STARTUP_TIMEOUT = 30
    DEFAULT_READY_TIMEOUT = 120

    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Hash] :up [String, nil], :ready [String, nil], :stop_timeout [Numeric],
    #   :startup_timeout [Numeric], :ready_timeout [Numeric]
    # @raise [Workspace::Error] if a stored duration key isn't a valid duration
    def for_project(name)
      dev = @project_settings.load(name)["dev"] || {}
      {
        up: dev["up"],
        ready: dev["ready"],
        stop_timeout: duration(dev, "stop_timeout", DEFAULT_STOP_TIMEOUT, name),
        startup_timeout: duration(dev, "startup_timeout", DEFAULT_STARTUP_TIMEOUT, name, require_positive: true),
        ready_timeout: duration(dev, "ready_timeout", DEFAULT_READY_TIMEOUT, name, require_positive: true)
      }
    end

    private

    def duration(dev, key, default, name, require_positive: false)
      return default unless dev.key?(key)
      # Both branches raise ArgumentError on invalid input (plain parse or
      # positive-only parse), caught below and re-raised with context.
      require_positive ? Duration.parse_positive(dev[key]) : Duration.parse(dev[key])
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.#{key} for '#{name}': #{e.message}"
    end
  end
end
