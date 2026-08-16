require "yaml"

module Workspace
  # Reads per-project pipeline configuration from ~/.config/workspace/projects/<name>.yml.
  class PipelineConfig
    # @param config [Workspace::Config] path configuration
    def initialize(config:)
      @config = config
    end

    # @param name [String] workspace name
    # @return [Array<Hash>, nil] stages as [{role:, pane_index:}, ...], or nil when
    #   the project has no pipeline configured
    def stages_for(name)
      path = @config.project_config_path(name)
      return nil unless File.exist?(path)

      pipeline = YAML.safe_load_file(path)&.dig("pipeline")
      panes = pipeline && pipeline["panes"]
      return nil unless panes.is_a?(Array) && !panes.empty?

      panes.each_with_index.map do |pane, index|
        {role: pane["role"], pane_index: index}
      end
    end

    # @param name [String] workspace name
    # @return [Boolean] whether the project runs a pipeline
    def pipeline?(name)
      !stages_for(name).nil?
    end
  end
end
