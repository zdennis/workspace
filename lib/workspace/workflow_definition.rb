require "yaml"
require "digest"

module Workspace
  # One workflow definition: a YAML file of ordered steps, checked and turned
  # into the plain hash a run keeps a copy of. A step runs in the workspace's
  # agent pane; the only way back to an earlier step is `on_fail: {goto, max}`.
  #
  # Every problem in a file is collected and reported at once, with code
  # `invalid_workflow`, so a definition is fixed in one pass.
  class WorkflowDefinition
    # The only `schema_version` a definition may name.
    SCHEMA_VERSION = 1

    # Workflow and step ids: they become file names and binding fields.
    ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,39}\z/

    # Input names, as written in `{{inputs.NAME}}`.
    INPUT_PATTERN = /\A[a-z][a-z0-9_]*\z/

    TOP_KEYS = %w[schema_version id title description inputs include instructions max_attempts steps].freeze
    STEP_KEYS = %w[title prompt prompt_file include produces status gate uses on_fail context timeout].freeze
    INPUT_KEYS = %w[description required].freeze
    ON_FAIL_KEYS = %w[goto max context].freeze
    STATUS_KEYS = %w[command run timeout].freeze

    # How a step starts: in a new conversation, or in the one the pane has.
    CONTEXTS = %w[fresh continue].freeze

    # Attempts a run may make across all its steps before a failure stops it.
    DEFAULT_MAX_ATTEMPTS = 6

    # Seconds a `status:` check may run when it names no timeout.
    DEFAULT_CHECK_TIMEOUT = 20 * 60

    # The `{{name}}` placeholders a prompt may use besides `{{inputs.NAME}}`.
    VARIABLES = %w[workspace branch artifacts run].freeze

    PLACEHOLDER = /\{\{\s*([^{}\s]+)\s*\}\}/
    private_constant :PLACEHOLDER

    # @return [String] the workflow's id (its file name without `.yml`)
    attr_reader :id

    # @return [String] "builtin" or "global"
    attr_reader :source

    # @return [String] the file the definition was read from
    attr_reader :path

    # @return [String] hex SHA-256 of the file's text
    attr_reader :sha256

    # @param text [String] the file's YAML
    # @param id [String] the id the file is stored under
    # @param source [String] "builtin" or "global"
    # @param path [String] the file, for messages and for resolving `prompt_file:`
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `invalid_workflow`, with every problem in `details["problems"]`
    def self.parse(text, id:, source:, path:)
      new(text, id: id, source: source, path: path)
    end

    # Fills a text's placeholders. A placeholder with no value is left as written;
    # {.parse} has already refused the names no run can supply.
    #
    # @param text [String]
    # @param values [Hash{String=>String}] placeholder name (e.g. "inputs.task") to its value
    # @return [String]
    def self.render(text, values)
      # A value that came from outside tagged with another encoding (a branch name, a path,
      # with no UTF-8 locale) is read as UTF-8, so it can be joined with the text.
      text.gsub(PLACEHOLDER) { values.key?($1) ? values[$1].to_s.dup.force_encoding(Encoding::UTF_8).scrub : $& }
    end

    # @param text [String]
    # @param id [String]
    # @param source [String]
    # @param path [String]
    def initialize(text, id:, source:, path:)
      @id = id
      @source = source
      @path = path
      @sha256 = Digest::SHA256.hexdigest(text)
      @problems = []
      @data = build(load_yaml(text))
      return if @problems.empty?
      raise Workspace::Error.new("Workflow '#{id}' (#{path}) is not valid:\n" + @problems.map { |problem| "  - #{problem}" }.join("\n"),
        code: "invalid_workflow", details: {"workflow" => id, "path" => path, "problems" => @problems})
    end

    # @return [Hash{String=>Object}] the checked definition with defaults filled in: "id",
    #   "title", "description", "inputs" (name to "description" and "required"), "include",
    #   "instructions", "max_attempts" and "steps", an ordered list where each step has "id",
    #   "title", "prompt", "include", "produces", "status" (nil, or "command" or "run" with
    #   "timeout" seconds), "gate", "uses", "on_fail" (nil, or "goto", "max", "context"),
    #   "context" and "timeout" (seconds or nil)
    def to_h
      @data
    end

    # @return [Array<Hash>] the steps in the order they run
    def steps
      @data["steps"]
    end

    private

    # Definitions are UTF-8, whatever the locale of the process reading them.
    def load_yaml(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding?
        problem "the file is not valid UTF-8 text"
        return {}
      end
      parsed = YAML.safe_load(text)
      return parsed if parsed.is_a?(Hash)
      problem "the file must be a YAML mapping"
      {}
    rescue Psych::Exception => e
      problem "the file is not valid YAML (#{e.message.lines.first.to_s.strip})"
      {}
    end

    def problem(message)
      @problems << message
      nil
    end

    def build(raw)
      unknown_keys(raw, TOP_KEYS, "the workflow")
      version = raw.fetch("schema_version", SCHEMA_VERSION)
      problem "schema_version must be #{SCHEMA_VERSION}, got #{version.inspect}" unless version == SCHEMA_VERSION
      problem "id must be #{id.inspect}, the name of its file, got #{raw["id"].inspect}" if raw.key?("id") && raw["id"] != id
      problem "the workflow id #{id.inspect} must be lowercase letters, digits, '-' and '_'" unless ID_PATTERN.match?(id)
      inputs = inputs_from(raw["inputs"])
      max_attempts = raw.fetch("max_attempts", DEFAULT_MAX_ATTEMPTS)
      unless max_attempts.is_a?(Integer) && max_attempts >= 1
        problem "max_attempts must be a whole number of 1 or more, got #{max_attempts.inspect}"
      end
      instructions = text_or_nil(raw["instructions"], "instructions")
      placeholders(instructions, inputs, "instructions")
      {
        "id" => id,
        "title" => text_or_nil(raw["title"], "title") || id,
        "description" => text_or_nil(raw["description"], "description"),
        "inputs" => inputs,
        "include" => names(raw["include"], "include"),
        "instructions" => instructions,
        "max_attempts" => max_attempts,
        "steps" => steps_from(raw["steps"], inputs)
      }
    end

    def unknown_keys(mapping, allowed, where)
      extra = mapping.keys.map(&:to_s) - allowed
      problem "#{where} has unknown key#{"s" if extra.size > 1} #{extra.join(", ")} (known: #{allowed.join(", ")})" if extra.any?
    end

    def text_or_nil(value, where)
      return nil if value.nil?
      return value if value.is_a?(String) && !value.strip.empty?
      problem "#{where} must be text, got #{value.inspect[0, 60]}"
    end

    def names(value, where)
      return [] if value.nil?
      return value if value.is_a?(Array) && value.all? { |name| name.is_a?(String) && !name.strip.empty? }
      problem "#{where} must be a list of names, got #{value.inspect[0, 60]}"
      []
    end

    def inputs_from(raw)
      return {} if raw.nil?
      return problem("inputs must be a mapping of input name to its description") || {} unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(name, spec), inputs|
        name = name.to_s
        problem "input name #{name.inspect} must be lowercase letters, digits and '_', starting with a letter" unless INPUT_PATTERN.match?(name)
        spec = {} if spec.nil?
        unless spec.is_a?(Hash)
          problem "input #{name} must be a mapping with description and required"
          spec = {}
        end
        unknown_keys(spec, INPUT_KEYS, "input #{name}")
        required = spec.fetch("required", false)
        problem "input #{name}: required must be true or false" unless [true, false].include?(required)
        inputs[name] = {"description" => text_or_nil(spec["description"], "input #{name}: description"), "required" => required == true}
      end
    end

    def steps_from(raw, inputs)
      unless raw.is_a?(Hash) && raw.any?
        problem "steps must be a mapping of step id to step, with at least one step"
        return []
      end
      ids = raw.keys.map(&:to_s)
      ids.each_with_index.map { |step_id, index| step_from(step_id, raw[raw.keys[index]], ids.first(index), inputs) }
    end

    def step_from(step_id, raw, earlier, inputs)
      where = "step #{step_id}"
      problem "step id #{step_id.inspect} must be lowercase letters, digits, '-' and '_'" unless ID_PATTERN.match?(step_id)
      unless raw.is_a?(Hash)
        problem "#{where} must be a mapping"
        raw = {}
      end
      unknown_keys(raw, STEP_KEYS, where)
      prompt = prompt_from(raw, where)
      placeholders(prompt, inputs, "#{where}: prompt")
      {
        "id" => step_id,
        "title" => text_or_nil(raw["title"], "#{where}: title") || step_id,
        "prompt" => prompt,
        "include" => names(raw["include"], "#{where}: include"),
        "produces" => produces_from(raw["produces"], where),
        "status" => status_from(raw["status"], where),
        "gate" => gate_from(raw["gate"], where),
        "uses" => uses_from(raw["uses"], where),
        "on_fail" => on_fail_from(raw["on_fail"], earlier, where),
        "context" => context_from(raw.fetch("context", "fresh"), "#{where}: context"),
        "timeout" => duration_from(raw["timeout"], "#{where}: timeout")
      }
    end

    def prompt_from(raw, where)
      if raw.key?("prompt") == raw.key?("prompt_file")
        return problem("#{where} needs exactly one of prompt and prompt_file")
      end
      return text_or_nil(raw["prompt"], "#{where}: prompt") if raw.key?("prompt")
      file = raw["prompt_file"]
      return problem("#{where}: prompt_file must be a path") unless file.is_a?(String) && !file.strip.empty?
      full = File.expand_path(file, File.dirname(path))
      text = File.read(full, encoding: Encoding::UTF_8)
      return problem("#{where}: prompt_file #{full} is not valid UTF-8 text") unless text.valid_encoding?
      text.strip.empty? ? problem("#{where}: prompt_file #{full} is empty") : text
    rescue SystemCallError => e
      problem "#{where}: prompt_file #{full} can't be read (#{e.class})"
    end

    def placeholders(text, inputs, where)
      return unless text.is_a?(String)
      text.scan(PLACEHOLDER).flatten.uniq.each do |name|
        next if VARIABLES.include?(name)
        next if name.start_with?("inputs.") && inputs.key?(name.delete_prefix("inputs."))
        known = (VARIABLES + inputs.keys.map { |input| "inputs.#{input}" }).map { |v| "{{#{v}}}" }.join(", ")
        problem "#{where} uses {{#{name}}}, which nothing supplies (known: #{known})"
      end
    end

    # Paths under the run's artifacts directory, so a step can't name a file elsewhere.
    def produces_from(value, where)
      list = names(value, "#{where}: produces")
      list.each do |file|
        next unless file.start_with?("/", "~") || file.split("/").include?("..")
        problem "#{where}: produces #{file.inspect} must be a path under the run's artifacts directory"
      end
      list
    end

    def status_from(value, where)
      return nil if value.nil?
      value = {"run" => value} if value.is_a?(String)
      return problem("#{where}: status must be a command, {run: COMMAND} or {command: test|lint}") unless value.is_a?(Hash)
      unknown_keys(value, STATUS_KEYS, "#{where}: status")
      timeout = value.key?("timeout") ? duration_from(value["timeout"], "#{where}: status timeout") : DEFAULT_CHECK_TIMEOUT
      problem "#{where}: status timeout must be a duration such as 90 or 20m, got nothing" if value.key?("timeout") && value["timeout"].nil?
      if value.key?("command") == value.key?("run")
        return problem("#{where}: status needs exactly one of run and command")
      end
      if value.key?("command")
        role = value["command"]
        return {"command" => role, "timeout" => timeout} if CommandsConfig::ROLES.include?(role)
        return problem("#{where}: status command must be one of #{CommandsConfig::ROLES.join(", ")}, got #{role.inspect}")
      end
      run = text_or_nil(value["run"], "#{where}: status run")
      run && {"run" => run, "timeout" => timeout}
    end

    def gate_from(value, where)
      return nil if value.nil?
      return value if value == "approve"
      problem "#{where}: gate must be approve, got #{value.inspect}"
    end

    def uses_from(value, where)
      RunResources.names(value)
    rescue Workspace::UsageError => e
      problem "#{where}: #{e.message}"
      []
    end

    def on_fail_from(value, earlier, where)
      return nil if value.nil?
      return problem("#{where}: on_fail must be a mapping with goto and max") unless value.is_a?(Hash)
      unknown_keys(value, ON_FAIL_KEYS, "#{where}: on_fail")
      goto = value["goto"].to_s
      unless earlier.include?(goto)
        problem "#{where}: on_fail goto must name an earlier step (#{earlier.empty? ? "there is none" : earlier.join(", ")}), got #{value["goto"].inspect}"
      end
      max = value.fetch("max", 1)
      problem "#{where}: on_fail max must be a whole number of 1 or more, got #{max.inspect}" unless max.is_a?(Integer) && max >= 1
      context = value.key?("context") ? context_from(value["context"], "#{where}: on_fail context") : nil
      {"goto" => goto, "max" => max, "context" => context}
    end

    def context_from(value, where)
      return value if CONTEXTS.include?(value)
      problem "#{where} must be one of #{CONTEXTS.join(", ")}, got #{value.inspect}"
    end

    def duration_from(value, where)
      return nil if value.nil?
      Duration.parse_positive(value)
    rescue ArgumentError => e
      problem "#{where}: #{e.message}"
    end
  end
end
