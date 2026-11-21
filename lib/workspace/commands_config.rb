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

    # The command that sets a role's command once for a whole project, which the "command unset" hints offer
    # beside the workspace's own. Only offered for a worktree whose project is a workspace `--name` can name.
    #
    # @param role [String] `test` or `lint`
    # @param project [String] the project's name
    # @param workspace [String] the workspace that has no command
    # @param known [Boolean] whether the project is a workspace
    # @return [String, nil] nil when the workspace is the project or the project is not a workspace
    def self.project_scope_command(role, project, workspace:, known:)
      return nil if workspace == project || !known
      "workspace config set commands.#{role} \"COMMAND\" --name #{project}"
    end

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

    # The globs of `commands.test_files`, read through {ConfigResolver} like the
    # roles: the parent project's file, then the worktree's own over it. Not a
    # role, so {#for_project} leaves it out.
    #
    # @param workspace [String] a workspace or project name
    # @return [Array<String>] the globs; empty when unset or a stored value `config set` would refuse
    # @raise [Workspace::ConfigParseError] if a config file that is read can't be parsed
    def test_files(workspace)
      value = @config_resolver.view(workspace: workspace).raw("commands.test_files")
      value.nil? ? [] : ConfigSchema.parse("commands.test_files", value)
    rescue ArgumentError
      []
    end

    private

    def command(role, value)
      value.is_a?(String) ? ConfigSchema.parse("commands.#{role}", value) : nil
    rescue ArgumentError
      nil
    end
  end
end
