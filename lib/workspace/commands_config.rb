module Workspace
  # Reads the `commands:` block (`test`, `lint`) from a project's YAML config,
  # as written by `workspace config set`. The keys name a role, so a preset or
  # an instruction pack can say "run the tests" and each project supplies the
  # command.
  #
  # Like {DevConfig}, each key is read through {ConfigResolver}.
  class CommandsConfig
    # The roles a project can give a command for.
    ROLES = %w[test lint].freeze

    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # @param workspace [String] a workspace or project name
    # @return [Hash{Symbol=>String, nil}] :test and :lint; nil for a command that
    #   is unset or holds a value `config set` would refuse
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def for_project(workspace)
      view = @config_resolver.view(workspace: workspace)
      ROLES.to_h { |role| [role.to_sym, command(role, view.raw("commands.#{role}"))] }
    end

    private

    def command(role, value)
      value.is_a?(String) ? ConfigSchema.parse("commands.#{role}", value) : nil
    rescue ArgumentError
      nil
    end
  end
end
