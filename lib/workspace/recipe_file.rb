require "yaml"

module Workspace
  # The fields of a library `recipe` entry: what `start --recipe NAME` applies.
  # A recipe is YAML, either the whole file or the frontmatter between two `---`
  # lines (text after the closing line is notes and is ignored). It never
  # touches the disk and checks every field at once, so one error lists every
  # problem.
  #
  #   plays: [kickoff]
  #   packs: [review]
  #   agents: [reviewer]
  #   skills: [write-tests]
  #   agent_kind: codex
  #   prompt: Start at step 2.
  #
  # or, instead of those, a workflow to run:
  #
  #   workflow: rpiv
  #   workflow_inputs: {task: Add a retry}
  #   agent_kind: claude
  module RecipeFile
    LIST_FIELDS = %w[plays packs agents skills].freeze
    FIELDS = (LIST_FIELDS + %w[agent_kind prompt description workflow workflow_inputs]).freeze
    WORKFLOW_EXCLUDES = %w[plays packs agents skills prompt].freeze

    # Most items in one list, and the longest prompt, in characters.
    MAX_ITEMS = 20
    MAX_PROMPT = 20_000

    ITEM = %r{\A([a-z]+/)?#{IdPatterns::LIBRARY_NAME.source[2..-3]}\z}

    # @param text [String] the entry's body
    # @param ref [String] `recipe/name`, for the error
    # @return [Hash{String=>Object}] only the fields the recipe sets: the list fields as arrays of
    #   strings, `agent_kind`, `prompt`, `description` and `workflow` as strings, `workflow_inputs` as a
    #   Hash of strings to strings
    # @raise [Workspace::Error] code `invalid_recipe`, `details.problems` listing every problem
    def self.parse(text, ref:)
      data, problems = load(text)
      fields = {}
      if data
        (data.keys.map(&:to_s) - FIELDS).each do |key|
          problems << "unknown field '#{key.to_s[0, 40]}': one of #{FIELDS.join(", ")}"
        end
        data = data.transform_keys(&:to_s)
        LIST_FIELDS.each { |key| list(key, data[key], fields, problems) if data.key?(key) }
        string("agent_kind", data, fields, problems) { |v| known_kind(v, problems) }
        string("prompt", data, fields, problems) { |v| problems << "prompt is longer than #{MAX_PROMPT} characters" if v.length > MAX_PROMPT }
        string("description", data, fields, problems)
        workflow(data, fields, problems)
        inputs(data, fields, problems)
        combination(data, problems)
        problems << "the recipe sets nothing: give plays, packs, agents, skills, agent_kind, prompt or workflow" if problems.empty? && (fields.keys - ["description"]).empty?
      end
      return fields if problems.empty?
      raise Error.new("Recipe #{ref} is not valid: #{problems.join("; ")}.", code: "invalid_recipe",
        details: {"ref" => ref, "problems" => problems})
    end

    def self.load(text)
      body = text.to_s
      if body.start_with?("---\n", "---\r\n")
        body = body.split(/^---\s*$\r?\n?/, 3)[1].to_s
      end
      data = YAML.safe_load(body)
      return [nil, ["the recipe is empty"]] if data.nil?
      return [nil, ["the recipe must be a mapping of field names to values"]] unless data.is_a?(Hash)
      [data, []]
    rescue Psych::Exception => e
      [nil, ["the recipe is not valid YAML: #{e.message.lines.first.to_s.strip[0, 120]}"]]
    end
    private_class_method :load

    def self.list(key, value, fields, problems)
      items = value.is_a?(Array) ? value : [value]
      kind = key.chomp("s")
      bad = items.reject { |item| item.is_a?(String) && item.match?(ITEM) && [nil, kind].include?(item[%r{\A[a-z]+(?=/)}]) }
      if items.empty?
        problems << "#{key} must not be empty"
      elsif bad.any?
        problems << "#{key} must be names (lowercase letters, digits and hyphens, optionally #{kind}/name); not #{bad.first.inspect[0, 40]}"
      elsif items.length > MAX_ITEMS
        problems << "#{key} takes at most #{MAX_ITEMS} entries, not #{items.length}"
      else
        fields[key] = items.uniq
      end
    end
    private_class_method :list

    def self.string(key, data, fields, problems)
      return unless data.key?(key)
      value = data[key]
      unless value.is_a?(String) && !value.strip.empty?
        problems << "#{key} must be non-empty text"
        return
      end
      fields[key] = value
      yield value if block_given?
    end
    private_class_method :string

    def self.workflow(data, fields, problems)
      return unless data.key?("workflow")
      value = data["workflow"]
      if value.is_a?(String) && IdPatterns::WORKFLOW_ID.match?(value)
        fields["workflow"] = value
      else
        problems << "workflow must be a workflow id (#{IdPatterns::WORKFLOW_ID_RULE}, at most 40 characters); not #{value.inspect[0, 40]}"
      end
    end
    private_class_method :workflow

    def self.inputs(data, fields, problems)
      return unless data.key?("workflow_inputs")
      value = data["workflow_inputs"]
      unless value.is_a?(Hash) && !value.empty?
        problems << "workflow_inputs must be a non-empty mapping of input names to values"
        return
      end
      if value.length > MAX_ITEMS
        problems << "workflow_inputs takes at most #{MAX_ITEMS} entries, not #{value.length}"
        return
      end
      found = {}
      value.each do |name, item|
        unless name.is_a?(String) && WorkflowDefinition::INPUT_PATTERN.match?(name)
          problems << "workflow_inputs input name #{name.inspect[0, 40]} must be lowercase letters, digits and '_', starting with a letter"
          next
        end
        if item.is_a?(Float)
          problems << "workflow_inputs #{name} is a decimal number; quote it (\"1.50\") to keep it as text"
          next
        end
        unless [String, Integer, TrueClass, FalseClass].any? { |type| item.is_a?(type) }
          problems << "workflow_inputs #{name} must be text, a whole number, true or false"
          next
        end
        if item.is_a?(String) && item.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
          problems << "workflow_inputs #{name} holds a control character"
          next
        end
        text = item.to_s
        if text.length > MAX_PROMPT
          problems << "workflow_inputs #{name} is longer than #{MAX_PROMPT} characters"
          next
        end
        found[name] = text
      end
      fields["workflow_inputs"] = found if found.length == value.length
    end
    private_class_method :inputs

    def self.combination(data, problems)
      if data.key?("workflow")
        clash = WORKFLOW_EXCLUDES & data.keys
        problems << "workflow can't be combined with #{clash.join(", ")}: a workflow run takes none of them" if clash.any?
        kind = data["agent_kind"]
        problems << "agent_kind '#{kind.to_s[0, 40]}' can't be combined with workflow: only claude" if kind.is_a?(String) && kind != "claude" && AgentProvider.all.map(&:key).include?(kind)
      elsif data.key?("workflow_inputs")
        problems << "workflow_inputs needs workflow"
      end
    end
    private_class_method :combination

    def self.known_kind(value, problems)
      known = AgentProvider.all.map(&:key)
      problems << "agent_kind '#{value[0, 40]}' is not one of #{known.join(", ")}" unless known.include?(value)
    end
    private_class_method :known_kind
  end
end
