module Workspace
  # Reads the `workflows:` block, as written by `workspace config set`.
  class WorkflowConfig
    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # The packs every composed set of instructions starts with:
    # `workflows.defaults.include`, or `binding`, `orchestrator` and
    # `commits` when it is unset or holds a value `config set` would refuse.
    # Read from the worktree, project and global files, the first that sets
    # it winning; with no workspace, from the global file alone. A project or
    # worktree file that can't be parsed is skipped: the global value is used
    # instead.
    #
    # @param workspace [String, nil] the workspace the packs are composed for
    # @return [Array<String>] pack names
    # @raise [Workspace::ConfigParseError] if the global config file can't be parsed
    def default_packs(workspace: nil)
      value = workspace.nil? ? read("", upto: "global") : read(workspace)
      value.nil? ? ConfigSchema::DEFAULT_PACKS : ConfigSchema.parse("workflows.defaults.include", value)
    rescue ArgumentError
      ConfigSchema::DEFAULT_PACKS
    end

    private

    def read(workspace, upto: nil)
      @config_resolver.view(workspace: workspace, upto: upto).raw("workflows.defaults.include")
    rescue Workspace::ConfigParseError
      raise if upto
      read(workspace, upto: "global")
    end
  end
end
