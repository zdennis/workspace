module Workspace
  # Reads the `handoff:` block from a project's YAML config, as written by
  # `workspace config set handoff.threshold <pct>` (and the two prompt
  # override keys). Mirrors {AlertConfig}: a worktree's own workspace name
  # is resolved to its parent project first, since that's where `config set`
  # writes.
  #
  # A bad stored value never stops `workspace handoff check`: it falls back
  # to the default with a warning, since `config set` already rejects bad
  # input.
  class HandoffConfig
    # Context-usage percent that triggers a handoff, unless overridden.
    DEFAULT_THRESHOLD = ConfigSchema.default("handoff.threshold")

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

    # Parses and validates a handoff threshold.
    #
    # @param value [String, Numeric] a context-usage percent, 1..100
    # @return [Integer]
    # @raise [ArgumentError] if value isn't an integer percent in range
    def self.parse_threshold(value)
      ConfigSchema.parse("handoff.threshold", value)
    end

    # Validates a prompt template override. Only checked for blankness: the
    # placeholders it may use are documented, not enforced, same as any
    # other free-text config value.
    #
    # @param value [String]
    # @return [String]
    # @raise [ArgumentError] if value is blank
    def self.parse_prompt(value)
      ConfigSchema.parse("handoff.check_prompt", value)
    end

    # @param workspace [String] the calling workspace's name
    # @return [Hash] :threshold [Integer], :check_prompt [String], :resume_prompt [String]
    #   (unset keys give the schema default, which for the two prompts is the built-in text)
    def for_workspace(workspace)
      handoff = load_handoff(workspace)
      {
        threshold: setting(handoff, workspace, "threshold"),
        check_prompt: setting(handoff, workspace, "check_prompt"),
        resume_prompt: setting(handoff, workspace, "resume_prompt")
      }
    end

    # Whether the project asks for automatic handoff (`handoff.auto`): `start` and
    # `launch` then send the agent the `handoff` pack. Off unless the project's file
    # says `true`; a bad stored value or an unparseable file warns and counts as off.
    #
    # @param workspace [String] the workspace's name (a worktree reads its parent project's value)
    # @return [Boolean]
    def auto?(workspace)
      setting(load_handoff(workspace), workspace, "auto") == "true"
    end

    private

    # Every stored `handoff.*` value, or {} when a config file can't be parsed.
    def load_handoff(workspace)
      view = view_for(workspace)
      %w[threshold check_prompt resume_prompt auto].to_h { |key| [key, view.raw("handoff.#{key}")] }
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using handoff defaults."
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

    def setting(handoff, workspace, key)
      schema_key = "handoff.#{key}"
      default = ConfigSchema.default(schema_key)
      return default if handoff[key].nil?
      ConfigSchema.parse(schema_key, handoff[key])
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid handoff.#{key} for '#{workspace}' (#{e.message}); using #{default.inspect}."
      default
    end
  end
end
