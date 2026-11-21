module Workspace
  # Reads and checks a list of permission rules, each `{tool, pattern, action}`:
  # the value of `agent.permissions.rules` in config and of a workflow's
  # `permissions:` key. Pure and depends on nothing outside `core/`.
  module PermissionRules
    # Limits on a pattern: its length, and `*` or `?` in one (a long run of
    # wildcards makes a glob slow). A workflow's `deny:` list shares them.
    MAX_PATTERN_LENGTH = 200
    MAX_PATTERN_WILDCARDS = 8

    # Actions from least to most restrictive: when layers disagree on a default, the later one wins.
    RESTRICTIVENESS = %w[allow ask deny].freeze

    # The keys a rule may hold.
    KEYS = %w[tool pattern action].freeze

    # @param actions [Array<String>] valid actions, e.g. each layer's `default`
    # @return [String, nil] the most restrictive of them (deny over ask over allow), nil for none
    def self.most_restrictive(actions)
      actions.max_by { |action| RESTRICTIVENESS.index(action) || -1 }
    end

    # @param value [Array<Hash>, nil] the stored rules; nil means none are set
    # @param label [String] what the list is called in an error message, e.g. "agent.permissions.rules"
    # @param actions [Array<String>] the actions a rule may name
    # @return [Array<Hash>] rules as `{"tool" =>, "pattern" =>, "action" =>}` with string keys; `pattern` only when given
    # @raise [ArgumentError] naming `label[i]` for a non-Hash entry, an unknown key, an empty tool, a bad action or a bad pattern,
    #   and for a value that is not an Array
    def self.parse(value, label:, actions: %w[allow ask deny])
      return [] if value.nil?
      raise ArgumentError, "#{label} must be a list of rules, got #{value.inspect[0, 60]}" unless value.is_a?(Array)
      value.each_with_index.map { |entry, index| parse_rule(entry, "#{label}[#{index}]", actions) }
    end

    def self.parse_rule(entry, where, actions)
      raise ArgumentError, "#{where} must be a mapping, got #{entry.inspect[0, 60]}" unless entry.is_a?(Hash)
      rule = entry.transform_keys(&:to_s)
      unknown = rule.keys - KEYS
      raise ArgumentError, "#{where} has unknown key #{unknown.first.inspect}; allowed: #{KEYS.join(", ")}" unless unknown.empty?
      tool = rule["tool"]
      raise ArgumentError, "#{where}.tool must be a non-empty string" if !tool.is_a?(String) || tool.strip.empty?
      raise ArgumentError, "#{where}.action must be one of #{actions.join(", ")}, got #{rule["action"].inspect[0, 60]}" unless actions.include?(rule["action"])
      parsed = {"tool" => tool, "action" => rule["action"]}
      if rule.key?("pattern")
        parsed["pattern"] = check_pattern(rule["pattern"], "#{where}.pattern")
      end
      parsed
    end
    private_class_method :parse_rule

    def self.check_pattern(pattern, where)
      raise ArgumentError, "#{where} must be a non-empty string, got #{pattern.inspect[0, 60]}" if !pattern.is_a?(String) || pattern.strip.empty?
      raise ArgumentError, "#{where} is longer than #{MAX_PATTERN_LENGTH} characters" if pattern.length > MAX_PATTERN_LENGTH
      raise ArgumentError, "#{where} has more than #{MAX_PATTERN_WILDCARDS} wildcards (* or ?)" if pattern.count("*?") > MAX_PATTERN_WILDCARDS
      pattern
    end
    private_class_method :check_pattern
  end
end
