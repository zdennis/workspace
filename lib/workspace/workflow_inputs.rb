# frozen_string_literal: true

module Workspace
  # Checks the inputs given to a workflow against its definition: no unknown names, every
  # required one present, every set value matching its `pattern:`. Pure: definition and
  # inputs in, the full set of input values (or a refusal) out.
  module WorkflowInputs
    INPUT_VALUE_LIMIT = 4096

    # @param data [Hash] the definition as a hash (`WorkflowDefinition#to_h`)
    # @param inputs [Hash, nil] the values given, keyed by name
    # @return [Hash{String=>String}] every declared input with its value ("" when unset)
    # @raise [UsageError] for an input the workflow does not declare
    # @raise [Workspace::Error] `input_required` or `invalid_input`
    def self.check(data, inputs)
      inputs = (inputs || {}).transform_keys(&:to_s)
      unknown = inputs.keys - data["inputs"].keys
      if unknown.any?
        raise UsageError, "Workflow #{data["id"]} has no input #{unknown.first.to_s[0, 60].inspect} " \
          "(inputs: #{data["inputs"].keys.join(", ").then { |list| list.empty? ? "none" : list }})."
      end
      missing = data["inputs"].select { |name, spec| spec["required"] && inputs[name].to_s.strip.empty? }
      if missing.any?
        raise Workspace::Error.new("Workflow #{data["id"]} needs input #{missing.keys.join(", ")}. Pass --input #{missing.keys.first}=VALUE.",
          code: "input_required",
          details: {"workflow" => data["id"], "inputs" => missing.map { |name, spec| {"name" => name, "description" => spec["description"]} }})
      end
      check_patterns(data, inputs)
      data["inputs"].keys.to_h { |name| [name, inputs[name].to_s] }
    end

    # Only a truly empty value is unset and passes; whitespace is checked like any other. A value too long, or one the pattern takes too long to judge, is a mismatch. The value is never echoed.
    def self.check_patterns(data, inputs)
      data["inputs"].each do |name, spec|
        pattern = spec["pattern"]
        value = inputs[name].to_s
        next if pattern.nil? || value.empty?
        next if value.length <= INPUT_VALUE_LIMIT && matches?(pattern, value)
        raise Workspace::Error.new("Input #{name} of workflow #{data["id"]} does not match its pattern #{pattern}.",
          code: "invalid_input", details: {"workflow" => data["id"], "input" => name, "pattern" => pattern})
      end
    end

    # Ruby 3.2 and later bound the match by time; older Rubies rely on the length cap alone.
    def self.matches?(pattern, value)
      source = "\\A(?:#{pattern})\\z"
      regexp = Regexp.respond_to?(:timeout) ? Regexp.new(source, timeout: 1) : Regexp.new(source)
      regexp.match?(value)
    rescue RegexpError
      false
    end

    private_class_method :check_patterns, :matches?
  end
end
