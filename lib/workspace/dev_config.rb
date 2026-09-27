module Workspace
  # Reads the `dev:` block (`up`, `ready`, `stop_timeout`) from a project's
  # YAML config, as written by `workspace config set`.
  #
  # Worktrees are not resolved here: callers pass the already-resolved
  # parent project name (see {WorkspaceLineage}), so this stays a plain
  # reader over {ProjectSettings}.
  class DevConfig
    DEFAULT_STOP_TIMEOUT = 20

    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Hash] :up [String, nil], :ready [String, nil], :stop_timeout [Numeric]
    # @raise [Workspace::Error] if a stored dev.stop_timeout isn't a valid duration
    def for_project(name)
      dev = @project_settings.load(name)["dev"] || {}
      {
        up: dev["up"],
        ready: dev["ready"],
        stop_timeout: dev.key?("stop_timeout") ? Duration.parse(dev["stop_timeout"]) : DEFAULT_STOP_TIMEOUT
      }
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.stop_timeout for '#{name}': #{e.message}"
    end
  end
end
