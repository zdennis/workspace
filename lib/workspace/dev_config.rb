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

    # Parses a duration string or number into seconds.
    # Supports: "20s", "20" (plain number = seconds).
    #
    # @param value [String, Numeric] duration string or number
    # @return [Numeric] seconds
    # @raise [ArgumentError] if value isn't a recognized duration
    def self.parse_duration(value)
      str = value.to_s.strip
      case str
      when /\A(\d+(?:\.\d+)?)\s*s\z/i
        $1.to_f
      when /\A(\d+(?:\.\d+)?)\z/
        $1.to_f
      else
        raise ArgumentError, "expected a duration like \"20s\" or \"20\", got #{value.inspect}"
      end
    end
  end
end
