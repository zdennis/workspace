require "shellwords"

module Workspace
  # Turns the string of a `require: exec:` entry into an argument vector, checks it, and fills in its
  # placeholders. Pure functions: no shell is involved, so a value with spaces, quotes or `;` stays one argument.
  module WorkflowArgv
    # Same syntax as {WorkflowDefinition}'s `{{name}}`.
    PLACEHOLDER = /\{\{\s*([^{}\s]+)\s*\}\}/
    WHOLE = /\A\{\{\s*([^{}\s]+)\s*\}\}\z/

    # Placeholders that fill in one string. `inputs.NAME` is also a scalar, for each declared input.
    SCALARS = %w[checkout artifacts workspace branch run run.base_sha attempt.head_before].freeze

    # Placeholders that fill in a list of paths; each must be a whole argument.
    LISTS = %w[changed.files changed.tests run.changed.files].freeze

    # Splits a template like a shell would, without running one.
    # @param text [String]
    # @return [Array(Array<String>, String)] `[argv, nil]`, or `[nil, problem]` for an unbalanced quote or no words
    def self.split(text)
      argv = Shellwords.split(text.to_s)
      return [nil, "is empty"] if argv.empty?
      [argv, nil]
    rescue ArgumentError
      [nil, "has an unbalanced quote"]
    end

    # The list placeholders an argv uses as whole arguments after the program, spaces inside the braces allowed.
    # @param argv [Array<String>]
    # @return [Array<String>] names from {LISTS}, each once
    def self.list_names(argv)
      argv.drop(1).filter_map { |arg| arg.match(WHOLE)&.[](1) }.select { |name| LISTS.include?(name) }.uniq
    end

    # @param argv [Array<String>]
    # @param inputs [Array<String>] the declared input names, for `{{inputs.NAME}}`
    # @return [Array(Array<String>, Array<String>)] `[problems, warnings]`; a warning is a list placeholder with no
    #   `--` argument before it (a path starting with `-` would read as an option)
    def self.problems(argv, inputs:)
      problems = []
      warnings = []
      argv.each_with_index do |arg, index|
        names = arg.scan(PLACEHOLDER).flatten
        problems << "has an empty program (argument 1)" if index.zero? && arg.empty?
        if arg.gsub(PLACEHOLDER, "").match?(/\{\{|\}\}/)
          problems << "has a malformed placeholder in #{arg.inspect}; write {{name}} with no spaces around the name"
        end
        names.each do |name|
          next if known?(name, inputs)
          problems << "uses {{#{name}}}, which nothing supplies (known: #{known_list(inputs)})"
        end
        if index.zero?
          names.uniq.each { |name| problems << "has {{#{name}}} in the program (argument 1), which must be a fixed program" if known?(name, inputs) }
          next
        end
        next unless names.any? { |name| LISTS.include?(name) }
        whole = arg.match(WHOLE)
        if whole.nil?
          names.select { |name| LISTS.include?(name) }.uniq.each do |name|
            problems << "uses {{#{name}}} inside the word #{arg.inspect}; a list must be an argument of its own"
          end
        elsif !argv[1...index].include?("--")
          warnings << "{{#{whole[1]}}} has no `--` argument before it, so a path starting with `-` would read as an option"
        end
      end
      [problems.uniq, warnings.uniq]
    end

    # @param argv [Array<String>] a template that passed {.problems}
    # @param scalars [Hash{String=>String}] values by placeholder name (`inputs.NAME` included)
    # @param lists [Hash{String=>Array<String>}] items by list name; a missing or empty list adds no arguments
    # @return [Array<String>] the arguments; `~/` at the start of the program is expanded, nowhere else
    def self.render(argv, scalars:, lists:)
      out = argv.flat_map do |arg|
        whole = arg.match(WHOLE)
        if whole && LISTS.include?(whole[1])
          Array(lists[whole[1]]).map(&:to_s)
        else
          [substitute(arg, scalars)]
        end
      end
      out[0] = File.expand_path(out[0]) if out[0]&.start_with?("~/")
      out
    end

    def self.substitute(arg, scalars)
      used = arg.scan(PLACEHOLDER).flatten.select { |name| scalars.key?(name) }
      binary = !arg.valid_encoding? || used.any? { |name| !scalars[name].to_s.valid_encoding? }
      fill(arg, scalars, binary)
    rescue Encoding::CompatibilityError
      fill(arg, scalars, true)
    end

    def self.fill(arg, scalars, binary)
      arg = arg.b if binary
      arg.gsub(PLACEHOLDER) do
        text = scalars.key?($1) ? scalars[$1].to_s : $&
        binary ? text.b : text
      end
    end

    def self.known?(name, inputs)
      SCALARS.include?(name) || LISTS.include?(name) ||
        (name.start_with?("inputs.") && inputs.include?(name.delete_prefix("inputs.")))
    end

    def self.known_list(inputs)
      (SCALARS + LISTS + inputs.map { |i| "inputs.#{i}" }).map { |v| "{{#{v}}}" }.join(", ")
    end
    private_class_method :known?, :known_list, :substitute, :fill
  end
end
