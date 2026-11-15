module Workspace
  # Reads the `workflows:` block, as written by `workspace config set`.
  class WorkflowConfig
    DEFAULT_STALL = 600

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

    # The idle time after which a step of a definition with no `stall:` counts
    # as stalled: `workflows.default_stall` from the global file, `600` when it
    # is unset, holds a value `config set` would refuse or the file can't be
    # parsed. `off` and `0` give nil.
    #
    # @return [Numeric, nil] seconds, or nil when the default is turned off
    def default_stall
      value = read("", upto: "global", key: "workflows.default_stall")
      value.nil? ? DEFAULT_STALL : ConfigSchema.parse("workflows.default_stall", value)
    rescue ArgumentError, Workspace::ConfigParseError
      DEFAULT_STALL
    end

    private

    def read(workspace, upto: nil, key: "workflows.defaults.include")
      @config_resolver.view(workspace: workspace, upto: upto).raw(key)
    rescue Workspace::ConfigParseError
      raise if upto
      read(workspace, upto: "global", key: key)
    end
  end
end
