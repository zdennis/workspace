module Workspace
  # Reads the workflow to use when none is named: `workflows.by_ref.<kind>`,
  # then `workflows.default`.
  class WorkflowDefaults
    # @param config_resolver [Workspace::ConfigResolver]
    def initialize(config_resolver:)
      @config_resolver = config_resolver
    end

    # The stored workflow id for a kind of ref. See {#lookup}.
    #
    # @param kind [String] one of `ConfigSchema::WORKFLOW_REF_KINDS`
    # @param workspace [String, nil] the workspace whose layers are read
    # @return [String, nil] the stored workflow id, nil when neither key is set
    # @raise [KeyError] if the kind has no declared key
    def id_for(kind, workspace: nil)
      lookup(kind, workspace: workspace)&.fetch(:id)
    end

    # The stored workflow id for a kind of ref, with the config key that
    # answered. `workflows.by_ref.<kind>` wins over `workflows.default`; each
    # is read from the worktree, project and global files, the first that sets
    # it winning. With no workspace, only the global file is read. A project
    # or worktree file that can't be parsed is skipped for both keys, and the
    # global values are used. A global file that can't be parsed reads as
    # unset. A malformed value is returned as it is, for the catalog to refuse.
    #
    # @param kind [String] one of `ConfigSchema::WORKFLOW_REF_KINDS`
    # @param workspace [String, nil] the workspace whose layers are read
    # @param project [String, nil] the parent project, for a worktree whose name doesn't show it
    # @return [Hash, nil] `{id:, key:, scope:}`, where key is `workflows.by_ref.<kind>`
    #   or `workflows.default` and scope the layer that set it; nil when neither key is set
    # @raise [KeyError] if the kind has no declared key
    def lookup(kind, workspace: nil, project: nil)
      workspace.nil? ? read(kind, "", upto: "global") : read(kind, workspace, project: project)
    end

    private

    def read(kind, workspace, project: nil, upto: nil)
      view = @config_resolver.view(workspace: workspace, project: project, upto: upto)
      ["workflows.by_ref.#{kind}", "workflows.default"].each do |key|
        value = view.raw(key)
        return {id: value.to_s, key: key, scope: view.resolve(key).winner.layer.to_s} if value
      end
      nil
    rescue Workspace::ConfigParseError
      raise if upto
      read(kind, workspace, project: project, upto: "global")
    end
  end
end
