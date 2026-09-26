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
        stop_timeout: dev.key?("stop_timeout") ? self.class.parse_duration(dev["stop_timeout"]) : DEFAULT_STOP_TIMEOUT
      }
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid dev.stop_timeout for '#{name}': #{e.message}"
    end

    DURATION_UNITS = {"" => 1, "s" => 1, "m" => 60, "h" => 3600}.freeze
    private_constant :DURATION_UNITS

    # Parses a duration string or number into seconds.
    # Supports: "20", "20s", "5m", "1h" (a plain number is seconds).
    #
    # @param value [String, Numeric] duration string or number
    # @return [Numeric] seconds
    # @raise [ArgumentError] if value isn't a recognized duration
    def self.parse_duration(value)
      match = /\A(\d+(?:\.\d+)?)\s*([smh]?)\z/i.match(value.to_s.strip)
      raise ArgumentError, "expected a duration like \"20\", \"20s\", \"5m\" or \"1h\", got #{value.inspect}" unless match
      match[1].to_f * DURATION_UNITS.fetch(match[2].downcase)
    end
  end
end
