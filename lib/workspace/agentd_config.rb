module Workspace
  # Reads the `agentd:` block from a project's YAML config, as written by
  # `workspace config set agentd.poll_interval <duration>`. Mirrors
  # {AlertConfig}: the session-monitor daemon is named after its workspace,
  # which for a worktree is the worktree's own name, while `config set`
  # stores settings under the parent project, so the workspace is resolved
  # to its parent before the settings are read.
  #
  # A bad stored value never stops the daemon: it falls back to the default
  # with a warning, since `config set` already rejects bad input.
  class AgentdConfig
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

    # Parses and validates a scan interval.
    #
    # @param value [String, Numeric] seconds, or a duration like "45s"
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a positive duration
    def self.parse_poll_interval(value)
      ConfigSchema.parse("agentd.poll_interval", value)
    end

    # @param workspace [String] the daemon's workspace name
    # @return [Numeric] seconds between the session monitor's scans;
    #   {SessionMonitor::DEFAULT_POLL_INTERVAL} when unset or invalid
    def poll_interval_for(workspace)
      setting(load_poll_interval(workspace), workspace)
    end

    private

    # The stored `agentd.poll_interval`, or nil when unset or a config file can't be parsed.
    def load_poll_interval(workspace)
      view_for(workspace).raw("agentd.poll_interval")
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using the default poll interval."
      nil
    end

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

    def setting(value, workspace)
      schema_key = "agentd.poll_interval"
      default = ConfigSchema.default(schema_key)
      return default if value.nil?
      ConfigSchema.parse(schema_key, value)
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid agentd.poll_interval for '#{workspace}' (#{e.message}); using #{default}s."
      default
    end
  end
end
