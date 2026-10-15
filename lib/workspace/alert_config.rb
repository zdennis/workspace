module Workspace
  # Reads the `alerts:` block from a project's YAML config, as written by
  # `workspace config set alerts.notify <command>` and
  # `workspace config set alerts.idle_after <duration>`.
  #
  # The session-monitor daemon is named after its workspace, which for a
  # worktree is the worktree's own name, while `config set` stores settings
  # under the parent project. The workspace is therefore resolved to its
  # parent (through its tmuxinator root) before the settings are read.
  #
  # A bad stored value never stops the daemon: it falls back to the default
  # with a warning, since `config set` already rejects bad input.
  class AlertConfig
    # Seconds an agent pane may sit idle before the notify command runs.
    DEFAULT_IDLE_AFTER = ConfigSchema.default("alerts.idle_after")

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

    # Parses and validates an idle alert threshold.
    #
    # @param value [String, Numeric] seconds, or a duration like "10m"
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a positive duration
    def self.parse_idle_after(value)
      ConfigSchema.parse("alerts.idle_after", value)
    end

    # Validates a notify command.
    #
    # @param value [String] the command, run through the shell
    # @return [String] the command, stripped
    # @raise [ArgumentError] if the command is blank
    def self.parse_notify(value)
      ConfigSchema.parse("alerts.notify", value)
    end

    # @param workspace [String] the daemon's workspace name
    # @return [Hash] :notify [String, nil] the command to run, nil for none;
    #   :idle_after [Numeric] seconds before an idle agent pane alerts
    def for_workspace(workspace)
      alerts = load_alerts(workspace)
      {
        notify: setting(alerts, workspace, "notify"),
        idle_after: setting(alerts, workspace, "idle_after")
      }
    end

    private

    # Every stored `alerts.*` value, or {} when a config file can't be parsed.
    def load_alerts(workspace)
      view = view_for(workspace)
      %w[notify idle_after].to_h { |key| [key, view.raw("alerts.#{key}")] }
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} No alerts will be sent."
      {}
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

    def setting(alerts, workspace, key)
      schema_key = "alerts.#{key}"
      default = ConfigSchema.default(schema_key)
      return default if alerts[key].nil?
      ConfigSchema.parse(schema_key, alerts[key])
    rescue ArgumentError => e
      fallback = default.nil? ? "no alerts will be sent" : "using #{default}s"
      @error_output.puts "Warning: invalid alerts.#{key} for '#{workspace}' (#{e.message}); #{fallback}."
      default
    end
  end
end
