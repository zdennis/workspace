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
    DEFAULT_THRESHOLD = 11

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

    # Parses and validates a handoff threshold.
    #
    # @param value [String, Numeric] a context-usage percent, 1..100
    # @return [Integer]
    # @raise [ArgumentError] if value isn't an integer percent in range
    def self.parse_threshold(value)
      pct = Integer(value)
      raise ArgumentError, "must be between 1 and 100" unless pct.between?(1, 100)
      pct
    rescue ArgumentError, TypeError
      raise ArgumentError, "must be an integer between 1 and 100"
    end

    # Validates a prompt template override. Only checked for blankness: the
    # placeholders it may use are documented, not enforced, same as any
    # other free-text config value.
    #
    # @param value [String]
    # @return [String]
    # @raise [ArgumentError] if value is blank
    def self.parse_prompt(value)
      text = value.to_s
      raise ArgumentError, "must not be blank" if text.strip.empty?
      text
    end

    # @param workspace [String] the calling workspace's name
    # @return [Hash] :threshold [Integer], :check_prompt [String, nil],
    #   :resume_prompt [String, nil] (nil means "use the built-in default")
    def for_workspace(workspace)
      name = project_name_for(workspace)
      handoff = load_handoff(name)
      handoff = {} unless handoff.is_a?(Hash)
      {
        threshold: setting(handoff, name, "threshold", DEFAULT_THRESHOLD) { |value| self.class.parse_threshold(value) },
        check_prompt: setting(handoff, name, "check_prompt", nil) { |value| self.class.parse_prompt(value) },
        resume_prompt: setting(handoff, name, "resume_prompt", nil) { |value| self.class.parse_prompt(value) }
      }
    end

    private

    def load_handoff(name)
      @project_settings.load(name)["handoff"]
    rescue Workspace::ConfigParseError => e
      @error_output.puts "Warning: #{e.message} Using handoff defaults."
      nil
    end

    def project_name_for(workspace)
      root = @project_config&.project_root_for(workspace)
      return workspace unless root && @lineage && File.directory?(root)
      @lineage.resolve(cwd: root).name
    rescue Workspace::Error
      workspace
    end

    def setting(handoff, name, key, default)
      return default unless handoff.key?(key)
      yield handoff[key]
    rescue ArgumentError => e
      @error_output.puts "Warning: invalid handoff.#{key} for '#{name}' (#{e.message}); using #{default.inspect}."
      default
    end
  end
end
