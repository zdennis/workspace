require "yaml"

module Workspace
  # The script `workflow simulate` plays: what the fake agent does on each attempt of each step, and what
  # the checks and proofs the simulation never runs say. Read from YAML, checked against the workflow's
  # definition, and refused as `invalid_script` with every problem listed.
  #
  #   inputs: {task: "x"}
  #   steps:
  #     verify:
  #       - {check: fail, log: "2 failures", tokens: 40000}   # attempt 1
  #       - {check: fail}                                     # attempt 2
  #       - {}                                                # attempt 3 passes
  #
  # An attempt may `pause: true` (or `pause: "reason"`) the run while its step is running, before the agent's turn
  # ends, and `unpause: true` once the turn has ended; without `unpause` a paused run is where the simulation stops.
  #
  # A `fan_out` group's siblings are named under the group's id, in the group's step order, or each under its own id:
  #
  #   steps:
  #     checks:                       # a fan_out group
  #       lint: [{report: fail}]
  #       test: [{}]
  #
  # An attempt the script has no entry for does the plain thing: writes every `produces` file, reports
  # nothing, passes its check and proofs, approves its gate and uses no tokens.
  class WorkflowSimScript
    # The most attempts one step's list may hold.
    MAX_ATTEMPTS = 100

    # The longest script file read, in bytes.
    MAX_BYTES = 64 * 1024

    # The most problems an `invalid_script` error lists.
    MAX_PROBLEMS = 50

    TOP_KEYS = %w[inputs steps].freeze
    ATTEMPT_KEYS = %w[writes report summary code check log require gate note tokens reviews reruns unchanged revision_changes pause unpause].freeze
    REPORTS = %w[pass fail].freeze
    CHECKS = %w[pass fail timeout error].freeze
    PROOFS = %w[pass fail].freeze
    GATES = %w[approve reject].freeze
    MAX_TEXT = 4000
    MAX_TOKENS = 1_000_000_000

    # @return [Hash{String=>String}] the workflow's input values the script gives
    attr_reader :inputs

    # Reads and checks a script against a workflow.
    #
    # @param text [String] the script's YAML
    # @param definition [Hash{String=>Object}] a definition's `to_h`
    # @param source [String] the script's name, for the error message
    # @return [WorkflowSimScript]
    # @raise [Workspace::Error] code `invalid_script`, `details.problems` (up to {MAX_PROBLEMS}) and `details.count`
    def self.parse(text, definition:, source:)
      problems = []
      document = load(text, problems)
      script = new(document.is_a?(Hash) ? check(document, definition, problems) : {"inputs" => {}, "steps" => {}})
      problems << "the script must be a YAML mapping with the keys #{TOP_KEYS.join(" and ")}" unless document.is_a?(Hash) || !problems.empty?
      return script if problems.empty?
      listed = problems.first(MAX_PROBLEMS)
      shown = listed.map { |each| TerminalText.escape(each) }
      raise Workspace::Error.new("The script #{TerminalText.escape(source.to_s[0, 200]).inspect} has #{problems.size} problem#{"s" unless problems.size == 1}:\n  #{shown.join("\n  ")}",
        code: "invalid_script", details: {"script" => source.to_s[0, 200], "workflow" => definition["id"], "problems" => listed, "count" => problems.size})
    end

    def self.load(text, problems)
      if text.bytesize > MAX_BYTES
        problems << "the script is #{text.bytesize} bytes; the limit is #{MAX_BYTES}"
        return nil
      end
      unless text.valid_encoding?
        problems << "the script is not UTF-8 text"
        return nil
      end
      YAML.safe_load(text, permitted_classes: [], aliases: false)
    rescue Psych::Exception, ArgumentError => e
      problems << "the script is not valid YAML: #{e.message.lines.first.to_s.strip[0, 200]}"
      nil
    end
    private_class_method :load

    def self.check(document, definition, problems)
      steps = definition["steps"].to_h { |step| [step["id"], step] }
      (document.keys - TOP_KEYS).each { |key| problems << "unknown key #{key.to_s[0, 60].inspect} (keys: #{TOP_KEYS.join(", ")})" }
      inputs = check_inputs(document["inputs"], definition, problems)
      listed = document["steps"]
      groups = WorkflowDefinition.group_steps(definition)
      attempts = {}
      case listed
      when nil then nil
      when Hash
        listed.each do |id, entries|
          if groups.key?(id)
            check_group(id, groups, steps, entries, attempts, problems)
            next
          end
          step = steps[id]
          unless step
            named = groups.empty? ? "" : "; fan_out groups: #{groups.keys.join(", ")}"
            problems << "steps.#{id.to_s[0, 60]}: the workflow has no such step (steps: #{steps.keys.join(", ")}#{named})"
            next
          end
          problems << "steps.#{id}: the attempts are given twice, here and under steps.#{step["group"]}" if attempts.key?(id)
          attempts[id] = check_attempts(id, step, entries, problems)
        end
      else problems << "steps must be a mapping of step ids to lists of attempts"
      end
      {"inputs" => inputs, "steps" => attempts}
    end
    private_class_method :check

    # A `fan_out` group's entry: a mapping of its siblings to their attempt lists, in the group's step order (the order
    # the engine starts them in and the fake agent ends their turns in). A sibling may also be given at the top level
    # under its own id, as any step is; the two forms for one sibling are refused.
    def self.check_group(group, groups, steps, entries, attempts, problems)
      siblings = groups[group]
      return if entries.nil?
      unless entries.is_a?(Hash)
        problems << "steps.#{group} is a fan_out group: give a mapping of its siblings (#{siblings.join(", ")}) to lists of attempts"
        return
      end
      known = entries.keys.select { |id| siblings.include?(id) }
      entries.each_key do |id|
        next if siblings.include?(id)
        other = steps[id] && steps[id]["group"]
        problems << if other
          "steps.#{group}.#{id}: #{id} is a sibling of the fan_out group #{other}, not of #{group} (siblings: #{siblings.join(", ")})"
        else
          "steps.#{group}.#{id.to_s[0, 60]}: the fan_out group has no such sibling (siblings: #{siblings.join(", ")})"
        end
      end
      unless known == siblings.select { |id| known.include?(id) }
        problems << "steps.#{group}: siblings must be listed in the group's order (#{siblings.join(", ")}), not #{known.join(", ")}"
      end
      known.each do |id|
        problems << "steps.#{group}.#{id}: the attempts are given twice, here and under steps.#{id}" if attempts.key?(id)
        attempts[id] = check_attempts("#{group}.#{id}", steps[id], entries[id], problems)
      end
    end
    private_class_method :check_group

    def self.check_inputs(value, definition, problems)
      return {} if value.nil?
      unless value.is_a?(Hash)
        problems << "inputs must be a mapping of input names to values"
        return {}
      end
      value.each_with_object({}) do |(name, each), found|
        if !definition["inputs"].key?(name.to_s)
          problems << "inputs.#{name.to_s[0, 60]}: the workflow has no such input (inputs: #{definition["inputs"].keys.join(", ").then { |list| list.empty? ? "none" : list }})"
        elsif !(each.is_a?(String) || each.is_a?(Integer))
          problems << "inputs.#{name.to_s[0, 60]} must be a string or an integer"
        else
          found[name.to_s] = each.to_s
        end
      end
    end
    private_class_method :check_inputs

    def self.check_attempts(id, step, entries, problems)
      return [] if entries.nil?
      unless entries.is_a?(Array)
        problems << "steps.#{id} must be a list with one entry per attempt"
        return []
      end
      problems << "steps.#{id} has #{entries.size} attempts; the limit is #{MAX_ATTEMPTS}" if entries.size > MAX_ATTEMPTS
      entries.first(MAX_ATTEMPTS).each_with_index.map do |entry, index|
        where = "steps.#{id} attempt #{index + 1}"
        next {} if entry.nil?
        unless entry.is_a?(Hash)
          problems << "#{where} must be a mapping (use {} for an attempt with nothing special)"
          next {}
        end
        check_attempt(where, step, entry, problems)
        entry
      end
    end
    private_class_method :check_attempts

    def self.check_attempt(where, step, entry, problems)
      (entry.keys - ATTEMPT_KEYS).each { |key| problems << "#{where}: unknown key #{key.to_s[0, 60].inspect} (keys: #{ATTEMPT_KEYS.join(", ")})" }
      one_of(where, entry, "report", REPORTS, problems)
      one_of(where, entry, "check", CHECKS, problems)
      one_of(where, entry, "gate", GATES, problems)
      problems << "#{where}: check is set, and the step has no status: check" if entry.key?("check") && !step["status"]
      problems << "#{where}: gate is set, and the step has no gate:" if entry.key?("gate") && !step["gate"]
      problems << "#{where}: note is for a gate, and the step has no gate:" if entry.key?("note") && !step["gate"]
      %w[summary log note].each do |key|
        next unless entry.key?(key)
        problems << "#{where}: #{key} must be a string of at most #{MAX_TEXT} characters" unless entry[key].is_a?(String) && entry[key].size <= MAX_TEXT
      end
      if entry.key?("code")
        if !(entry["code"].is_a?(String) && WorkflowDefinition::CODE_PATTERN.match?(entry["code"]))
          problems << "#{where}: code must be lowercase letters, digits and underscores, starting with a letter, at most 40 characters"
        elsif (refusal = WorkflowDefinition.engine_code_refusal(entry["code"]))
          problems << "#{where}: code #{refusal}"
        end
      end
      # A pause holds the whole run, and the simulator pauses only at the cursor's step, which in a group is one sibling
      # of several at work: a sibling's own pause would not be played, so it is refused.
      problems << "#{where}: #{(entry.keys & %w[pause unpause]).join(" and ")} can't be set on a fan_out sibling" if step["group"] && (entry.key?("pause") || entry.key?("unpause"))
      check_pause(where, entry, problems)
      check_writes(where, step, entry, problems)
      check_reviews(where, step, entry, problems)
      check_require(where, step, entry, problems)
      if entry.key?("tokens") && !(entry["tokens"].is_a?(Integer) && entry["tokens"].between?(0, MAX_TOKENS))
        problems << "#{where}: tokens must be a whole number from 0 to #{MAX_TOKENS}"
      end
    end
    private_class_method :check_attempt

    def self.one_of(where, entry, key, allowed, problems)
      return unless entry.key?(key)
      problems << "#{where}: #{key} must be one of #{allowed.join(", ")}" unless allowed.include?(entry[key])
    end
    private_class_method :one_of

    def self.check_pause(where, entry, problems)
      if entry.key?("pause") && !(entry["pause"] == true || (entry["pause"].is_a?(String) && !entry["pause"].empty? && entry["pause"].size <= MAX_TEXT))
        problems << "#{where}: pause must be true or a non-empty reason of at most #{MAX_TEXT} characters (omit the key for no pause)"
      end
      return unless entry.key?("unpause")
      problems << "#{where}: unpause must be true" unless entry["unpause"] == true
      problems << "#{where}: unpause is set, and the attempt does not pause" unless entry.key?("pause")
    end
    private_class_method :check_pause

    def self.check_writes(where, step, entry, problems)
      return unless entry.key?("writes")
      unless entry["writes"].is_a?(Array) && entry["writes"].all?(String)
        problems << "#{where}: writes must be a list of file names the step produces"
        return
      end
      (entry["writes"] - step["produces"].to_a).each do |file|
        problems << "#{where}: writes #{file[0, 60].inspect}, which the step does not produce (produces: #{step["produces"].to_a.join(", ").then { |list| list.empty? ? "none" : list }})"
      end
    end
    private_class_method :check_writes

    def self.check_reviews(where, step, entry, problems)
      review = WorkflowDefinition.review(step)
      problems << "#{where}: reviews is set, and the step has no review:" if entry.key?("reviews") && !review
      problems << "#{where}: revision_changes is set, and the step has no review:" if entry.key?("revision_changes") && !review
      problems << "#{where}: revision_changes must be true or false" if entry.key?("revision_changes") && ![true, false].include?(entry["revision_changes"])
      %w[reruns unchanged].each { |key| problems << "#{where}: #{key} is set, and the step has no review:" if entry.key?(key) && !review }
      problems << "#{where}: unchanged must be true or false" if entry.key?("unchanged") && ![true, false].include?(entry["unchanged"])
      return unless review
      verdict_map(where, "reviews", entry["reviews"], review, problems) if entry.key?("reviews")
      return unless entry.key?("reruns")
      unless entry["reruns"].is_a?(Array)
        problems << "#{where}: reruns must be a list, one mapping of reviewers to #{WorkflowReviewTally::VERDICTS.join(" or ")} per rerun of the round's missing reviewers"
        return
      end
      entry["reruns"].each_with_index { |each, index| verdict_map(where, "reruns[#{index}]", each, review, problems) }
    end
    private_class_method :check_reviews

    def self.verdict_map(where, key, map, review, problems)
      unless map.is_a?(Hash)
        problems << "#{where}: #{key} must be a mapping of the step's reviewers to #{WorkflowReviewTally::VERDICTS.join(" or ")}"
        return
      end
      from = Array(review["from"])
      map.each do |name, verdict|
        problems << "#{where}: #{key} #{name.to_s[0, 60].inspect}: the step has no such reviewer (reviewers: #{from.join(", ").then { |list| list.empty? ? "none" : list }})" unless from.include?(name)
        problems << "#{where}: #{key} #{name.to_s[0, 60].inspect} must be one of #{WorkflowReviewTally::VERDICTS.join(", ")}, not #{verdict.to_s[0, 60].inspect}" unless WorkflowReviewTally::VERDICTS.include?(verdict)
      end
    end
    private_class_method :verdict_map

    def self.check_require(where, step, entry, problems)
      return unless entry.key?("require")
      unless entry["require"].is_a?(Hash)
        problems << "#{where}: require must be a mapping of the step's require: names to pass or fail"
        return
      end
      named = step["require"].to_a.map { |each| each.keys.first }
      entry["require"].each do |name, result|
        problems << "#{where}: require #{name.to_s[0, 60].inspect}: the step has no such proof (proofs: #{named.uniq.join(", ").then { |list| list.empty? ? "none" : list }})" unless named.include?(name)
        if name == "exec" && result.is_a?(Array)
          count = named.count("exec")
          if count != result.size
            problems << "#{where}: require exec lists #{result.size} #{(result.size == 1) ? "answer" : "answers"}, but the step has #{count} exec #{(count == 1) ? "entry" : "entries"} (one pass or fail per exec entry)"
          elsif !result.all? { |each| PROOFS.include?(each) }
            problems << "#{where}: require exec must list only #{PROOFS.join(", ")}"
          end
        else
          problems << "#{where}: require #{name.to_s[0, 60]} must be one of #{PROOFS.join(", ")}" unless PROOFS.include?(result)
        end
      end
    end
    private_class_method :check_require

    # @param data [Hash{String=>Object}] the checked script
    def initialize(data)
      @inputs = data["inputs"]
      @steps = data["steps"]
    end

    # @param step [String] a step id
    # @param number [Integer] the attempt's number, from 1
    # @return [Hash{String=>Object}] what the script says of that attempt; empty when it says nothing
    def attempt(step, number)
      @steps.fetch(step, [])[number - 1] || {}
    end
  end
end
