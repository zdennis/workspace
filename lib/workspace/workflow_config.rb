module Workspace
  # Reads the global `workflows:` block, as written by `workspace config set`.
  class WorkflowConfig
    # @param project_settings [Workspace::ProjectSettings]
    def initialize(project_settings:)
      @project_settings = project_settings
    end

    # The packs every composed set of instructions starts with:
    # `workflows.defaults.include`, or `binding`, `orchestrator` and
    # `commits` when it is unset or holds a value `config set` would refuse.
    #
    # @return [Array<String>] pack names
    # @raise [Workspace::ConfigParseError] if the global config file can't be parsed
    def default_packs
      value = @project_settings.load_global.dig("workflows", "defaults", "include")
      value.nil? ? ConfigSchema::DEFAULT_PACKS : ConfigSchema.parse("workflows.defaults.include", value)
    rescue ArgumentError
      ConfigSchema::DEFAULT_PACKS
    end
  end
end
