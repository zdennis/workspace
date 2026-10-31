module Workspace
  # Reads `agent.recovery.enabled` from a project's YAML config, as written by
  # `workspace config set agent.recovery.enabled <true|false>`. Mirrors
  # {AlertConfig}: the daemon is named after its workspace, which for a
  # worktree is the worktree's own name, while `config set` stores settings
  # under the parent project, so the workspace is resolved to its parent
  # first.
  #
  # A bad stored value never stops the daemon: it falls back to the default
  # with a warning, since `config set` already rejects bad input.
  class AgentRecoveryConfig
    # @param config_resolver [Workspace::ConfigResolver]
    # @param project_config [Workspace::ProjectConfig, nil] finds a workspace's
    #   root; nil reads settings under the workspace name as given
    # @param lineage [Workspace::WorkspaceLineage, nil] resolves that root to
    #   its parent project
    # @param error_output [IO] where a warning about an invalid value goes
    def initialize(config_resolver:, project_config: nil, lineage: nil, error_output: $stderr)
      @config_resolver = config_resolver
      @project_config = project_config
      @lineage = lineage
      @error_output = error_output
    end

    # @param workspace [String] the daemon's workspace name
    # @return [Boolean] whether API-error recovery is on; the schema default
    #   (true) when unset, invalid or a config file can't be parsed
    def enabled?(workspace)
      key = "agent.recovery.enabled"
      default = ConfigSchema.default(key)
      value = view_for(workspace).raw(key)
      return default if value.nil?
      ConfigSchema.parse(key, value) == "true"
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid #{key} for '#{workspace}' (#{e.message}); using #{default}."
      default
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using the default for #{key}."
      default
    end

    private

    # The parent project when the lineage resolved one, else nil so the resolver
    # splits a worktree name itself (it must never be handed the worktree's own name).
    def resolved_project(workspace)
      root = @project_config&.project_root_for(workspace)
      return nil unless root && @lineage && File.directory?(root)
      @lineage.resolve(cwd: root).name
    rescue Workspace::Error
      nil
    end

    def view_for(workspace)
      @config_resolver.view(workspace: workspace, project: resolved_project(workspace))
    end
  end
end
