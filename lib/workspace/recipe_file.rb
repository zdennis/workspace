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
  module RecipeFile
    LIST_FIELDS = %w[plays packs agents skills].freeze
    FIELDS = (LIST_FIELDS + %w[agent_kind prompt description]).freeze

    # Most items in one list, and the longest prompt, in characters.
    MAX_ITEMS = 20
    MAX_PROMPT = 20_000

    ITEM = %r{\A([a-z]+/)?#{LibraryStore::NAME.source[2..-3]}\z}

    # @param text [String] the entry's body
    # @param ref [String] `recipe/name`, for the error
    # @return [Hash{String=>Object}] only the fields the recipe sets: the list fields as arrays of
    #   strings, `agent_kind`, `prompt` and `description` as strings
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
        problems << "the recipe sets nothing: give plays, packs, agents, skills, agent_kind or prompt" if problems.empty? && (fields.keys - ["description"]).empty?
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

    def self.known_kind(value, problems)
      known = AgentProvider.all.map(&:key)
      problems << "agent_kind '#{value[0, 40]}' is not one of #{known.join(", ")}" unless known.include?(value)
    end
    private_class_method :known_kind
  end
end
