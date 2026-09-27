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
    DEFAULT_IDLE_AFTER = 600

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

    # Parses and validates an idle alert threshold.
    #
    # @param value [String, Numeric] seconds, or a duration like "10m"
    # @return [Numeric] seconds, always greater than 0
    # @raise [ArgumentError] if value isn't a positive duration
    def self.parse_idle_after(value)
      Duration.parse_positive(value)
    end

    # Validates a notify command.
    #
    # @param value [String] the command, run through the shell
    # @return [String] the command, stripped
    # @raise [ArgumentError] if the command is blank
    def self.parse_notify(value)
      command = value.to_s.strip
      raise ArgumentError, "must not be blank" if command.empty?
      command
    end

    # @param workspace [String] the daemon's workspace name
    # @return [Hash] :notify [String, nil] the command to run, nil for none;
    #   :idle_after [Numeric] seconds before an idle agent pane alerts
    def for_workspace(workspace)
      name = project_name_for(workspace)
      alerts = @project_settings.load(name)
      alerts = alerts.is_a?(Hash) ? alerts["alerts"] : nil
      alerts = {} unless alerts.is_a?(Hash)
      {
        notify: setting(alerts, name, "notify", nil) { |value| self.class.parse_notify(value) },
        idle_after: setting(alerts, name, "idle_after", DEFAULT_IDLE_AFTER) { |value| self.class.parse_idle_after(value) }
      }
    end

    private

    def project_name_for(workspace)
      root = @project_config&.project_root_for(workspace)
      return workspace unless root && @lineage && File.directory?(root)
      @lineage.resolve(cwd: root).name
    rescue Workspace::Error
      workspace
    end

    def setting(alerts, name, key, default)
      return default unless alerts.key?(key)
      yield alerts[key]
    rescue ArgumentError => e
      fallback = default.nil? ? "no alerts will be sent" : "using #{default}s"
      @error_output.puts "Warning: invalid alerts.#{key} for '#{name}' (#{e.message}); #{fallback}."
      default
    end
  end
end
