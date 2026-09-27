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
    # @raise [Workspace::Error] if a stage's timeout isn't a positive duration,
    #   or a stage's own text names the bare completion sentinel
    def stages_for(name)
      path = @config.project_config_path(name)
      return nil unless File.exist?(path)

      panes = panes_for(path)
      return nil unless panes.is_a?(Array) && !panes.empty?

      panes.each_with_index.map do |pane, index|
        check_literal_sentinel(pane, index, path)
        {role: pane["role"], pane_index: index, timeout: stage_timeout(pane, index, path)}
      end
    end

    # @param name [String] workspace name
    # @return [Boolean] whether the project runs a pipeline
    def pipeline?(name)
      !stages_for(name).nil?
    end

    # A `pipeline:` block with no (or empty) `panes:` never starts a pipeline
    # stage, which usually means the operator meant to list panes and didn't.
    #
    # @param name [String] workspace name
    # @return [Boolean] whether the project declares a pipeline block with no stages
    def declared_but_empty?(name)
      path = @config.project_config_path(name)
      return false unless File.exist?(path)

      pipeline = YAML.safe_load_file(path)&.dig("pipeline")
      return false unless pipeline.is_a?(Hash)

      panes = pipeline["panes"]
      !(panes.is_a?(Array) && !panes.empty?)
    end

    private

    def panes_for(path)
      pipeline = YAML.safe_load_file(path)&.dig("pipeline")
      pipeline && pipeline["panes"]
    end

    def stage_timeout(pane, index, path)
      return nil unless pane.is_a?(Hash) && pane.key?("timeout")
      Duration.parse_positive(pane["timeout"])
    rescue ArgumentError => e
      raise Workspace::Error, "Invalid pipeline.panes[#{index}].timeout in #{path}: #{e.message}"
    end

    # Workspace appends its own completion instruction to every stage dispatch
    # (see Commands::Agent#handle_command), carrying a per-dispatch token the
    # agent's poller watches for. A stage whose own text names the bare
    # marker — with nothing glued to it — tells the agent to print a line
    # that can never match, so the stage hangs until its timeout (or forever,
    # with none set).
    def check_literal_sentinel(pane, index, path)
      return unless pane.is_a?(Hash)

      field = pane.find { |_, value| value.is_a?(String) && bare_sentinel?(value) }
      return unless field

      key, = field
      role = pane["role"] || "pane #{index}"
      raise Workspace::Error, "pipeline.panes[#{index}].#{key} in #{path} (#{role}) names the bare " \
        "#{SentinelPoller::SENTINEL} marker; workspace appends its own completion instruction with a " \
        "per-dispatch token, so drop this stage's own marker text."
    end

    def bare_sentinel?(text)
      text.match?(/#{Regexp.escape(SentinelPoller::SENTINEL)}(?!\S)/o)
    end
  end
end
