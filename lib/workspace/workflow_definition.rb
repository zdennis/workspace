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

    # The rule {ID_PATTERN} checks, in words, for messages.
    ID_RULE = "lowercase letters, digits, '-' and '_'"

    # Input names, as written in `{{inputs.NAME}}`.
    INPUT_PATTERN = /\A[a-z][a-z0-9_]*\z/

    TOP_KEYS = %w[schema_version id title description inputs include instructions max_attempts stall steps].freeze
    STEP_KEYS = %w[title prompt prompt_file include produces status gate guard require uses on_fail context timeout on_timeout].freeze

    # What a step does past its `timeout`: raise the `timed_out` flag only, stop the agent, or fail the step.
    ON_TIMEOUT_ACTIONS = %w[warn interrupt fail].freeze
    DEFAULT_ON_TIMEOUT = "warn"
    INPUT_PATTERN_LIMIT = 300
    INPUT_KEYS = %w[description required pattern].freeze
    ON_FAIL_KEYS = %w[goto max context].freeze
    GUARDS = %w[unchanged config].freeze
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

    # @return [String] the text the definition was parsed from, as given
    attr_reader :text

    # @param text [String] the file's YAML
    # @param id [String] the id the file is stored under
    # @param source [String] "builtin" or "global"
    # @param path [String, nil] the file, for messages and for resolving `prompt_file:`; nil for text with no file
    # @param base_dir [String, nil] the directory `prompt_file:` resolves against, else the directory of `path`
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `invalid_workflow`, with every problem in `details["problems"]`
    def self.parse(text, id:, source:, path:, base_dir: nil)
      new(text, id: id, source: source, path: path, base_dir: base_dir)
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
    # @param path [String, nil]
    # @param base_dir [String, nil]
    def initialize(text, id:, source:, path:, base_dir: nil)
      @text = text
      @base_dir = base_dir || (path && File.dirname(path))
      @id = id
      @source = source
      @path = path
      @sha256 = Digest::SHA256.hexdigest(text)
      @problems = []
      @data = build(load_yaml(text))
      return if @problems.empty?
      raise Workspace::Error.new("Workflow '#{id}' #{path ? "(#{path})" : "(from stdin)"} is not valid:\n" + @problems.map { |problem| "  - #{problem}" }.join("\n"),
        code: "invalid_workflow", details: {"workflow" => id, "path" => path, "problems" => @problems})
    end

    # @return [Hash{String=>Object}] the checked definition with defaults filled in: "id",
    #   "title", "description", "inputs" (name to "description" and "required"), "include",
    #   "instructions", "max_attempts" and "steps", an ordered list where each step has "id",
    #   "title", "prompt", "include", "produces", "status" (nil, or "command" or "run" with
    #   "timeout" seconds), "gate", "guard" (nil, "unchanged" or "config"), "require" (a list of one-key proofs such as `{"commits" => 1}`), "uses", "on_fail" (nil, or "goto", "max", "context"),
    #   "context" and "timeout" (seconds or nil)
    def to_h
      @data
    end

    # @return [Array<Hash>] the steps in the order they run
    def steps
      @data["steps"]
    end

    # Things a valid definition does that are probably a mistake. Never an error: the
    # definition still runs. A step with no proof passes on any turn end, so it is named.
    #
    # @return [Array<Hash{String=>String}>] each with "code" (`step_without_proof`), "step" (the step id) and "message"
    def warnings
      missing = steps.reject { |step| proof?(step) }.map do |step|
        {"code" => "step_without_proof", "step" => step["id"],
         "message" => "step #{step["id"]} has no produces, status, require or gate, so it passes on any turn end, even one that did nothing. Add produces: (a file it must write), require: (proofs about the repository), status: (a command that must pass) or gate: approve (a person approves it)."}
      end
      idle = steps.select { |step| step["timeout"].nil? && step["on_timeout"] != DEFAULT_ON_TIMEOUT }.map do |step|
        {"code" => "on_timeout_without_timeout", "step" => step["id"],
         "message" => "step #{step["id"]} sets on_timeout: #{step["on_timeout"]} but has no timeout:, so it never applies. Add timeout: (such as 2h) or remove on_timeout."}
      end
      missing + idle
    end

    # The `on_timeout` of a step hash. A definition stored before the key existed has none and reads as `warn`.
    #
    # @param step [Hash] a step of {#to_h}, or of a stored run's definition
    # @return [String] one of {ON_TIMEOUT_ACTIONS}
    def self.on_timeout(step)
      value = step.is_a?(Hash) ? step["on_timeout"] : nil
      ON_TIMEOUT_ACTIONS.include?(value) ? value : DEFAULT_ON_TIMEOUT
    end

    # The `stall` of a definition hash: seconds of silence that count as a stall; nil when unset, or in a definition stored before the key existed.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Numeric, nil] seconds; nil unless a positive number
    def self.stall(definition)
      value = definition.is_a?(Hash) ? definition["stall"] : nil
      (value.is_a?(Numeric) && value.finite? && value > 0) ? value : nil
    end

    private

    # What makes a step's pass mean something: a file it must write, a command that must
    # pass, or a person's gate.
    PROOF_KEYS = %w[status gate require].freeze

    def proof?(step)
      step["produces"].to_a.any? || PROOF_KEYS.any? { |key| Array(step[key]).any? }
    end

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
      problem "the workflow id #{id.inspect} must be #{ID_RULE}" unless ID_PATTERN.match?(id)
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
        "stall" => duration_from(raw["stall"], "stall"),
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
        pattern = input_pattern(spec["pattern"], name)
        inputs[name]["pattern"] = pattern if pattern
      end
    end

    # A pattern is a Ruby regexp source matched against the whole value (WorkflowEngine anchors it); it must compile and stay short.
    def input_pattern(value, name)
      return nil if value.nil?
      unless value.is_a?(String) && !value.empty?
        problem "input #{name}: pattern must be a non-empty regexp string"
        return nil
      end
      if value.length > INPUT_PATTERN_LIMIT
        problem "input #{name}: pattern is longer than #{INPUT_PATTERN_LIMIT} characters"
        return nil
      end
      Regexp.new("\\A(?:#{value})\\z")
      value
    rescue RegexpError => e
      problem "input #{name}: pattern does not compile (#{e.message[0, 120]})"
      nil
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
      problem "step id #{step_id.inspect} must be #{ID_RULE}" unless ID_PATTERN.match?(step_id)
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
        "guard" => guard_from(raw["guard"], where),
        "require" => require_from(raw["require"], where, inputs),
        "uses" => uses_from(raw["uses"], where),
        "on_fail" => on_fail_from(raw["on_fail"], earlier, where),
        "context" => context_from(raw.fetch("context", "fresh"), "#{where}: context"),
        "timeout" => duration_from(raw["timeout"], "#{where}: timeout"),
        "on_timeout" => on_timeout_from(raw.fetch("on_timeout", DEFAULT_ON_TIMEOUT), where)
      }
    end

    def prompt_from(raw, where)
      if raw.key?("prompt") == raw.key?("prompt_file")
        return problem("#{where} needs exactly one of prompt and prompt_file")
      end
      return text_or_nil(raw["prompt"], "#{where}: prompt") if raw.key?("prompt")
      file = raw["prompt_file"]
      return problem("#{where}: prompt_file must be a path") unless file.is_a?(String) && !file.strip.empty?
      return problem("#{where}: prompt_file #{file} is relative and the definition has no directory to resolve it against") unless @base_dir
      full = File.expand_path(file, @base_dir)
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

    def on_timeout_from(value, where)
      return value if ON_TIMEOUT_ACTIONS.include?(value)
      problem "#{where}: on_timeout must be #{ON_TIMEOUT_ACTIONS.join(", ")}, got #{value.inspect[0, 60]}"
      DEFAULT_ON_TIMEOUT
    end

    def gate_from(value, where)
      return nil if value.nil?
      return value if value == "approve"
      problem "#{where}: gate must be approve, got #{value.inspect}"
    end

    def guard_from(value, where)
      return nil if value.nil?
      return value if GUARDS.include?(value)
      problem "#{where}: guard must be #{GUARDS.join(" or ")}, got #{value.inspect}"
    end

    # A list of single-key mappings, each one proof of WorkflowRequire::PROOFS, kept as written, except that `command:` (which may carry `optional:`) is stored first, so every reader can take an entry's first pair as the proof.
    def require_from(value, where, inputs)
      return [] if value.nil?
      return problem("#{where}: require must be a list of proofs such as - commits: 1, got #{value.inspect[0, 60]}") || [] unless value.is_a?(Array)
      seen = []
      value.filter_map do |entry|
        one_proof = entry.is_a?(Hash) && (entry.size == 1 || entry.keys.sort == %w[command optional])
        unless one_proof
          problem "#{where}: each require entry must be one proof such as commits: 1 (only command: may take optional: true beside it), got #{entry.inspect[0, 60]}"
          next
        end
        optional = entry.key?("optional")
        if optional && ![true, false].include?(entry["optional"])
          problem "#{where}: require command optional must be true or false, got #{entry["optional"].inspect[0, 60]}"
          next
        end
        if entry.keys == ["optional"]
          problem "#{where}: optional: goes only beside command:, got #{entry.inspect[0, 60]}"
          next
        end
        name = optional ? "command" : entry.first.first
        wanted = entry[name]
        unless WorkflowRequire::PROOFS.include?(name)
          problem "#{where}: require #{name.inspect} is not a proof (known: #{WorkflowRequire::PROOFS.join(", ")})"
          next
        end
        problem "#{where}: require #{name} is listed twice" if seen.include?(name)
        seen << name
        next unless require_value_ok?(name, wanted, where, inputs)
        optional ? {"command" => wanted, "optional" => entry["optional"]} : entry
      end
    end

    def require_value_ok?(name, wanted, where, inputs)
      ok = case name
      when "commits" then wanted.is_a?(Integer) && wanted.between?(1, 1000)
      when "nonempty" then plain_relative_path?(wanted)
      when "plan_status" then PlanFile::STATUSES.include?(wanted)
      when "command" then CommandsConfig::ROLES.include?(wanted)
      when "inbox_item" then inbox_key_ok?(wanted, where, inputs)
      else wanted == true
      end
      return true if ok
      expected = {"commits" => "a whole number from 1 to 1000", "nonempty" => "a path under the run's artifacts directory",
                  "plan_status" => PlanFile::STATUSES.join(", "), "tracked_clean" => "true",
                  "command" => CommandsConfig::ROLES.join(" or "), "inbox_item" => "a dedupe key of 1 to 200 letters, digits and . _ : / # @ -, which may hold {{run}}, {{workspace}} and {{inputs.NAME}}",
                  "remote_unchanged" => "true"}.fetch(name)
      problem "#{where}: require #{name} must be #{expected}, got #{wanted.inspect[0, 60]}"
      false
    end

    # A string that renders to a valid dedupe key, holding only the placeholders the proof can fill in.
    def inbox_key_ok?(template, where, inputs)
      return false unless template.is_a?(String)
      names = template.scan(PLACEHOLDER).flatten.uniq
      known = ->(name) { WorkflowRequire::KEY_VARIABLES.include?(name) || (name.start_with?("inputs.") && inputs.key?(name.delete_prefix("inputs."))) }
      unknown = names.reject(&known)
      unknown.each { |name| problem "#{where}: require inbox_item uses {{#{name}}}, which it can't fill in (known: #{WorkflowRequire::KEY_VARIABLES.map { |v| "{{#{v}}}" }.join(", ")} and {{inputs.NAME}})" }
      return true if unknown.any? # already reported
      template.gsub(PLACEHOLDER, "x").match?(WorkflowRequire::KEY_PATTERN)
    end

    # A normal relative path: no control character (NUL included), no empty, `.` or `..` part (so no `a//b`,
    # `./x`, a leading or trailing `/`), no part with a leading or trailing space, and not starting with `~`.
    def plain_relative_path?(path)
      return false unless path.is_a?(String) && path.valid_encoding? && !path.empty?
      return false if path.match?(/[[:cntrl:]]/) || path.start_with?("~")
      path.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." || part != part.strip }
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
