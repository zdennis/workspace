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
    HANG_GUARD_KEY = "agent.permissions.hang_guard"
    MAX_DENIES_KEY = "agent.permissions.hang_guard_max_denies"
    POLICY_KEYS = %w[rules default].freeze
    PERMISSION_KEYS = (POLICY_KEYS + %w[hang_guard hang_guard_max_denies]).freeze
    MALFORMED_NODE = "agent.permissions must be a mapping holding only rules, default, hang_guard and hang_guard_max_denies, not a dotted key or another key".freeze
    private_constant :DEFAULT_KEY, :RULES_KEY, :FINISHED, :MALFORMED_NODE, :HANG_GUARD_KEY, :MAX_DENIES_KEY, :POLICY_KEYS, :PERMISSION_KEYS

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

    # What a standing check finds in the permission settings: whether any is set, why they
    # are broken, and whether `default: allow` stands with no `deny` rule anywhere.
    #
    # @return [Hash] `{configured:, error:, allow_without_deny:}`; error is nil when the settings parse
    # @raise [Workspace::ConfigParseError] for a config file that can't be parsed
    def check(workspace:, project:)
      layers = scan(workspace, project)
      from_run = begin
        run_rules
      rescue => e
        return {configured: true, error: "the bound run's permissions: #{e.message}", allow_without_deny: false}
      end
      bad = layers.find { |layer| layer[:malformed] }
      return {configured: true, error: "#{bad[:source]} config: #{bad[:error]}", allow_without_deny: false} if bad
      configured = layers.any? { |layer| layer[:present] } || !from_run.empty?
      rules = layers.flat_map { |layer| layer[:rules] } + from_run
      default = PermissionRules.most_restrictive(layers.filter_map { |layer| layer[:default] })
      {configured: configured, error: nil, allow_without_deny: default == "allow" && rules.none? { |rule| rule["action"] == "deny" }}
    end

    # The hang guard's settings: the bound live run's definition `hang_guard` wins for the mode, then
    # the most specific config layer that sets each key. The cap is config only. A value that does not
    # parse, or any read error, gives the default for that setting.
    #
    # @param workspace [String]
    # @param project [String, nil]
    # @return [Hash] `{mode:, max_denies:}`: mode one of {PermissionRules::HANG_GUARD_MODES}, max_denies an Integer of 1 or more
    def hang_guard(workspace:, project:)
      data = @config_resolver.view(workspace: workspace, project: project, strict_global: true).data_by_layer(RULES_KEY)
      {mode: run_hang_guard || layered_setting(data, HANG_GUARD_KEY), max_denies: layered_setting(data, MAX_DENIES_KEY)}
    rescue => e
      @logger.debug { "hang guard: reading the defaults (#{e.class}: #{e.message})" }
      {mode: ConfigSchema.default(HANG_GUARD_KEY), max_denies: ConfigSchema.default(MAX_DENIES_KEY)}
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

    def run_hang_guard
      value = live_run&.definition&.then { |definition| definition.is_a?(Hash) ? definition["hang_guard"] : nil }
      value = "off" if value == false
      PermissionRules::HANG_GUARD_MODES.include?(value) ? value : nil
    rescue => e
      @logger.debug { "hang guard: could not read the run's setting (#{e.class}: #{e.message})" }
      nil
    end

    def layered_setting(data, name)
      key = ConfigSchema.key(name)
      leaf = name.split(".").last
      data.each_value do |content|
        next unless content.is_a?(Hash)
        permissions = content.dig("agent", "permissions")
        next unless permissions.is_a?(Hash) && !permissions[leaf].nil?
        begin
          return key.parse(permissions[leaf])
        rescue ArgumentError
          return key.default
        end
      end
      key.default
    end

    def scan_layer(layer, content)
      raise ArgumentError, "#{layer} config is not a mapping" unless content.is_a?(Hash)
      found = {source: layer, rules: [], default: nil, present: false, malformed: false}
      return found.merge(present: true, malformed: true, error: MALFORMED_NODE) if malformed_node?(content)

      permissions = (content["agent"] || {})["permissions"] || {}
      rules = permissions["rules"]
      default = permissions["default"]
      return found if rules.nil? && default.nil?
      found.merge(present: true,
        rules: rules.nil? ? [] : ConfigSchema.key(RULES_KEY).parse(rules),
        default: default.nil? ? nil : ConfigSchema.key(DEFAULT_KEY).parse(default))
    rescue ArgumentError => e
      raise unless content.is_a?(Hash)
      found.merge(present: true, malformed: true, error: e.message)
    end

    def malformed_node?(content)
      return true if content.keys.any? { |key| key.to_s.start_with?("agent.permissions") }
      agent = content["agent"]
      return false if agent.nil?
      return true unless agent.is_a?(Hash)
      return true if agent.keys.any? { |key| key.to_s.start_with?("permissions.") }
      permissions = agent["permissions"]
      return false if permissions.nil?
      !permissions.is_a?(Hash) || (permissions.keys - PERMISSION_KEYS).any?
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
