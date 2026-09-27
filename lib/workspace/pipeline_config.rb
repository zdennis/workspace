require "yaml"

module Workspace
  # Reads per-project pipeline configuration from ~/.config/workspace/projects/<name>.yml.
  class PipelineConfig
    # @param config [Workspace::Config] path configuration
    def initialize(config:)
      @config = config
    end

    # A stage with no +timeout+ key waits for its sentinel for as long as it
    # takes, which is how every pipeline behaved before stages had deadlines.
    #
    # @param name [String] workspace name
    # @return [Array<Hash>, nil] stages as [{role:, pane_index:, timeout:}, ...],
    #   with +timeout+ in seconds or nil for none, or nil when the project has
    #   no pipeline configured
    # @raise [Workspace::Error] if a stage's timeout isn't a positive duration
    def stages_for(name)
      path = @config.project_config_path(name)
      return nil unless File.exist?(path)

      pipeline = YAML.safe_load_file(path)&.dig("pipeline")
      panes = pipeline && pipeline["panes"]
      return nil unless panes.is_a?(Array) && !panes.empty?

      panes.each_with_index.map do |pane, index|
        {role: pane["role"], pane_index: index, timeout: stage_timeout(pane, index, path)}
      end
    end

    # @param name [String] workspace name
    # @return [Boolean] whether the project runs a pipeline
    def pipeline?(name)
      !stages_for(name).nil?
    end

    private

    def stage_timeout(pane, index, path)
      return nil unless pane.is_a?(Hash) && pane.key?("timeout")
      Duration.parse_positive(pane["timeout"])
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid pipeline.panes[#{index}].timeout in #{path}: #{e.message}"
    end
  end
end
