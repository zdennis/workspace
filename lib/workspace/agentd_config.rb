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
    # @param project_settings [Workspace::ProjectSettings]
    # @param project_config [Workspace::ProjectConfig, nil] finds a workspace's
    #   root; nil reads settings under the workspace name as given
    # @param lineage [Workspace::WorkspaceLineage, nil] resolves that root to
    #   its parent project
    # @param error_output [IO] where a warning about an invalid value goes
    def initialize(project_settings:, project_config: nil, lineage: nil, error_output: $stderr)
      @project_settings = project_settings
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
      name = project_name_for(workspace)
      agentd = load_agentd(name)
      agentd = {} unless agentd.is_a?(Hash)
      setting(agentd, name)
    end

    private

    def load_agentd(name)
      @project_settings.load(name)["agentd"]
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using the default poll interval."
      nil
    end

    def project_name_for(workspace)
      root = @project_config&.project_root_for(workspace)
      return workspace unless root && @lineage && File.directory?(root)
      @lineage.resolve(cwd: root).name
    rescue Workspace::Error
      workspace
    end

    def setting(agentd, name)
      schema_key = "agentd.poll_interval"
      default = ConfigSchema.default(schema_key)
      return default unless agentd.key?("poll_interval")
      ConfigSchema.parse(schema_key, agentd["poll_interval"])
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid agentd.poll_interval for '#{name}' (#{e.message}); using #{default}s."
      default
    end
  end
end
