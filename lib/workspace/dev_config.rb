module Workspace
  # Reads the `dev:` block (`up`, `ready`, `stop_timeout`, `startup_timeout`,
  # `ready_timeout`, `kill_grace`) from a project's YAML config, as written by
  # `workspace config set`.
  #
  # Worktrees are not resolved here: callers pass the already-resolved
  # parent project name (see {WorkspaceLineage}), so this stays a plain
  # reader over {ProjectSettings}.
  class DevConfig
    DEFAULT_STOP_TIMEOUT = 20
    DEFAULT_STARTUP_TIMEOUT = 30
    DEFAULT_READY_TIMEOUT = 120
    # Largest accepted `dev.kill_grace`, in seconds (see {ProcessHolderStopper}).
    MAX_KILL_GRACE = 60

    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Hash] :up [String, nil], :ready [String, nil], :stop_timeout [Numeric],
    #   :startup_timeout [Numeric], :ready_timeout [Numeric], :kill_grace [Numeric]
    # @raise [Workspace::Error] if a stored duration key isn't a valid duration
    def for_project(name)
      dev = @project_settings.load(name)["dev"] || {}
      {
        up: dev["up"],
        ready: dev["ready"],
        stop_timeout: duration(dev, "stop_timeout", DEFAULT_STOP_TIMEOUT, name),
        startup_timeout: duration(dev, "startup_timeout", DEFAULT_STARTUP_TIMEOUT, name, require_positive: true),
        ready_timeout: duration(dev, "ready_timeout", DEFAULT_READY_TIMEOUT, name, require_positive: true),
        kill_grace: duration(dev, "kill_grace", ProcessHolderStopper::KILL_GRACE_SECONDS, name, max: MAX_KILL_GRACE)
      }
    end

    private

    def duration(dev, key, default, name, require_positive: false, max: nil)
      return default unless dev.key?(key)
      # Every branch raises ArgumentError on invalid input, caught below and
      # re-raised with context.
      if max
        Duration.parse_capped(dev[key], max: max)
      elsif require_positive
        Duration.parse_positive(dev[key])
      else
        Duration.parse(dev[key])
      end
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.#{key} for '#{name}': #{e.message}"
    end
  end
end
