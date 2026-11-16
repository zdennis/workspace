module Workspace
  # Reads the `workflows:` block, as written by `workspace config set`.
  class WorkflowConfig
    DEFAULT_STALL = 600
    DEFAULT_TURN_FAILED_AFTER = 1800
    DEFAULT_DOWNTIME_AFTER = 120

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

    # How long a pane whose agent turn ended on an API error may sit before
    # the sweep records its step as stalled with cause `turn_failed`:
    # `workflows.turn_failed_after` from the global file, `1800` when it is
    # unset, when it holds a value `config set` would refuse, or when the file
    # can not be parsed. `off` and `0` give nil.
    #
    # @return [Numeric, nil] seconds, or nil when the time threshold is turned off
    def turn_failed_after
      value = read("", upto: "global", key: "workflows.turn_failed_after")
      value.nil? ? DEFAULT_TURN_FAILED_AFTER : ConfigSchema.parse("workflows.turn_failed_after", value)
    rescue ArgumentError, Workspace::ConfigParseError
      DEFAULT_TURN_FAILED_AFTER
    end

    # How long the daemon's heartbeat may go unbeaten before the gap counts as
    # machine downtime: `workflows.downtime_after` from the global file, `120`
    # when it is unset, when it holds a value `config set` would refuse, or when
    # the file can not be parsed. Keep it well above the 15s daemon tick.
    #
    # @return [Numeric] seconds
    def downtime_after
      value = read("", upto: "global", key: "workflows.downtime_after")
      value.nil? ? DEFAULT_DOWNTIME_AFTER : ConfigSchema.parse("workflows.downtime_after", value)
    rescue ArgumentError, Workspace::ConfigParseError
      DEFAULT_DOWNTIME_AFTER
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
