module Workspace
  # Reads the permission rules and defaults that apply to one workspace, from the
  # global, project and worktree config files and the workflow run the calling
  # pane is bound to, and builds the {PermissionPolicy} that decides from them.
  #
  # It reads files only: no daemon call, no network and no process.
  #
  # Anything unexpected gives nil, which means "decide nothing": an unreadable or
  # unparseable file, a value a layer holds that does not parse (the global one
  # included), or a run that can't be read. It never returns an empty or partial
  # policy.
  class PermissionPolicyConfig
    DEFAULT_KEY = "agent.permissions.default"
    RULES_KEY = "agent.permissions.rules"
    FINISHED = %w[completed failed cancelled].freeze
    private_constant :DEFAULT_KEY, :RULES_KEY, :FINISHED

    # @param config_resolver [Workspace::ConfigResolver] reads each layer's file
    # @param bound_run [Workspace::BoundRun] names the run the calling pane is bound to
    # @param run_store [Workspace::WorkflowRunStore] reads that run and the definition it stores
    # @param logger [#debug] told why a read gave nothing
    def initialize(config_resolver:, bound_run:, run_store:, logger:)
      @config_resolver = config_resolver
      @bound_run = bound_run
      @run_store = run_store
      @logger = logger
    end

    # @param workspace [String]
    # @param project [String, nil] the parent project
    # @return [Workspace::PermissionPolicy, nil] nil when no layer sets either key and the run
    #   has no rules, and on any error
    def policy(workspace:, project:)
      layers = scan(workspace, project)
      from_run = run_rules
      return nil if layers.none? { |layer| layer[:present] } && from_run.empty?

      raise ArgumentError, "a config layer holds a malformed permissions setting" if layers.any? { |layer| layer[:malformed] }
      built = layers.reverse.filter_map { |layer| layer.slice(:source, :rules, :default) if layer[:present] }
      built << {source: "run", rules: from_run, default: nil} unless from_run.empty?
      PermissionPolicy.new(layers: built)
    rescue => e
      @logger.debug { "permission policy: no decision (#{e.class}: #{e.message})" }
      nil
    end

    # Whether the person configured a permission policy for this workspace, so a
    # request no decision came back for is a failure to look into. It reads key
    # presence only: a value that would not parse, a malformed parent node and a
    # config file that can't be parsed all count.
    #
    # @param workspace [String]
    # @param project [String, nil]
    # @return [Boolean] false only when presence could not be read at all
    def configured?(workspace:, project:)
      return true if scan(workspace, project).any? { |layer| layer[:present] }
      run_rules_present?
    rescue ConfigParseError => e
      @logger.debug { "permission policy: a config file can't be parsed, counted as configured (#{e.message})" }
      true
    rescue => e
      @logger.debug { "permission policy: could not read whether one is configured (#{e.class}: #{e.message})" }
      false
    end

    private

    # Each layer's own file, highest first, read raw and strictly (the global file too).
    #
    # @return [Array<Hash>] `{source:, rules:, default:, present:, malformed:}`: rules and default are parsed and
    #   present is whether the layer sets either key. A layer whose `agent` or `agent.permissions` node is not a
    #   mapping, or that holds a flat dotted `agent.permissions.*` key, is malformed (and present); its values are not parsed.
    # @raise [Workspace::ConfigParseError] for a file that can't be parsed
    def scan(workspace, project)
      view = @config_resolver.view(workspace: workspace, project: project, strict_global: true)
      data = view.data_by_layer(RULES_KEY)
      data.map { |layer, content| scan_layer(layer, content) }
    end

    def scan_layer(layer, content)
      raise ArgumentError, "#{layer} config is not a mapping" unless content.is_a?(Hash)
      found = {source: layer, rules: [], default: nil, present: false, malformed: false}
      return found.merge(present: true, malformed: true) if malformed_node?(content)

      permissions = (content["agent"] || {})["permissions"] || {}
      rules = permissions["rules"]
      default = permissions["default"]
      return found if rules.nil? && default.nil?
      found.merge(present: true,
        rules: rules.nil? ? [] : ConfigSchema.key(RULES_KEY).parse(rules),
        default: default.nil? ? nil : ConfigSchema.key(DEFAULT_KEY).parse(default))
    rescue ArgumentError
      raise unless content.is_a?(Hash)
      found.merge(present: true, malformed: true)
    end

    def malformed_node?(content)
      return true if content.keys.any? { |key| key.to_s.start_with?("agent.permissions") }
      agent = content["agent"]
      return false if agent.nil?
      return true unless agent.is_a?(Hash)
      return true if agent.keys.any? { |key| key.to_s.start_with?("permissions.") }
      permissions = agent["permissions"]
      return false if permissions.nil?
      !permissions.is_a?(Hash) || (permissions.keys - %w[rules default]).any?
    end

    # @return [Array<Hash>] the bound live run's `permissions:` rules; empty for no run or a finished one
    # @raise on any failure to read the run or its rules; unlike {WorkflowDefinition.permissions}, a bad value is never read as no rules
    def run_rules
      run = live_run
      return [] unless run
      definition = run.definition
      raise ArgumentError, "run definition is not a mapping" unless definition.is_a?(Hash)
      PermissionRules.parse(definition["permissions"], label: "permissions", actions: WorkflowDefinition::PERMISSION_ACTIONS)
    end

    def run_rules_present?
      value = live_run&.definition&.then { |definition| definition.is_a?(Hash) ? definition["permissions"] : nil }
      !value.nil? && value != []
    rescue => e
      @logger.debug { "permission policy: could not read the run's rules (#{e.class}: #{e.message})" }
      false
    end

    def live_run
      id = @bound_run.run_id_strict
      return nil unless id
      run = @run_store.run(id)
      FINISHED.include?(run.state) ? nil : run
    end
  end
end
