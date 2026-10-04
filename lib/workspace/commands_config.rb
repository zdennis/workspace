module Workspace
  # Reads the `commands:` block (`test`, `lint`) from a project's YAML config,
  # as written by `workspace config set`. The keys name a role, so a preset or
  # an instruction pack can say "run the tests" and each project supplies the
  # command.
  #
  # Like {DevConfig}, callers pass the already-resolved parent project name
  # (see {WorkspaceLineage}).
  class CommandsConfig
    # The roles a project can give a command for.
    ROLES = %w[test lint].freeze

    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # @param name [String] project name (already resolved to its parent, if a worktree)
    # @return [Hash{Symbol=>String, nil}] :test and :lint; nil for a command that
    #   is unset or holds a value `config set` would refuse
    # @raise [Workspace::ConfigParseError] if the project's config file can't be parsed
    def for_project(name)
      commands = @project_settings.load(name)["commands"]
      commands = {} unless commands.is_a?(Hash)
      ROLES.to_h { |role| [role.to_sym, command(role, commands[role])] }
    end

    private

    def command(role, value)
      value.is_a?(String) ? ConfigSchema.parse("commands.#{role}", value) : nil
    rescue ArgumentError
      nil
    end
  end
end
