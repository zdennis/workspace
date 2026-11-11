module Workspace
  # The `reviewers:` and step `review:` parts of a workflow definition: reads, checks and fills the defaults of both,
  # and cross-checks a step's reviewers against the ones the workflow names. The definition is inert data here;
  # nothing in a run acts on it yet.
  #
  # A key that has a default (`need`, `must`, `max_rounds`, `timeout`, `uses`, `context`, `notify`, `parallel`) and is
  # written as null is a problem ("got nothing"), never the default. `subject` and `revision` written as null mean none,
  # as `title` and `description` do elsewhere in a definition.
  #
  # Every problem is handed to the `report` callable, so {WorkflowDefinition} collects them with its own.
  class WorkflowReviewSpec
    # What a top-level `reviewers:` entry may hold, and what a step's `review:` mapping may hold.
    REVIEWER_KEYS = %w[title prompt prompt_file include parallel].freeze
    REVIEW_KEYS = %w[from need must subject revision max_rounds timeout uses context notify].freeze

    # Review rounds a step gets when its `review:` names no `max_rounds`, and seconds a whole review turn gets.
    DEFAULT_MAX_ROUNDS = 6
    DEFAULT_TIMEOUT = 30 * 60

    # The most seconds a review `timeout:` may name (one day), and the most rounds `max_rounds:` may name.
    MAX_TIMEOUT = 24 * 3600
    MAX_ROUNDS = 50

    # The `{{review.NAME}}` placeholders a reviewer's prompt may use; `review.subject` also takes the others.
    VARIABLES = %w[review.subject review.revision review.round review.verdict_path review.previous].freeze

    # @param name_pattern [Regexp] what a reviewer name must match
    # @param report [#call] given a problem message
    # @param prompt [#call] given a mapping and its description, answers the text of its `prompt` or `prompt_file`
    # @param placeholders [#call] given text, the inputs, a description and `extra:` names, reports names nothing supplies
    # @param text [#call] given a value and a description, answers it as text, nil for none, reporting anything else
    # @param names [#call] given a value and a description, answers a list of names
    # @param uses [#call] given a value and a description, answers the lock names
    # @param context [#call] given a value and a description, answers a valid `context`
    # @param duration [#call] given a value, a description and a maximum, answers seconds or nil
    def initialize(name_pattern:, report:, prompt:, placeholders:, text:, names:, uses:, context:, duration:)
      @name_pattern = name_pattern
      @report = report
      @prompt = prompt
      @placeholders = placeholders
      @text = text
      @names = names
      @uses = uses
      @context = context
      @duration = duration
    end

    # A `reviewers:` mapping: each entry is a prompt (inline or from a file), packs and whether it runs in the parallel batch.
    #
    # @param raw [Object] the `reviewers:` value
    # @param inputs [Hash] the definition's inputs
    # @return [Hash{String=>Hash}] name to "title", "prompt", "include" and "parallel"
    def reviewers(raw, inputs)
      return {} if raw.nil?
      return problem("reviewers must be a mapping of reviewer name to its prompt") || {} unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(name, spec), reviewers|
        name = name.to_s
        where = "reviewer #{name}"
        problem "reviewer name #{name.inspect[0, 40]} must be lowercase letters, digits and '_', starting with a letter" unless @name_pattern.match?(name)
        unless spec.is_a?(Hash)
          problem "#{where} must be a mapping with prompt or prompt_file"
          spec = {}
        end
        unknown_keys(spec, REVIEWER_KEYS, where)
        prompt = @prompt.call(spec, where)
        problem "#{where}: prompt must be text, got nothing" if spec.key?("prompt") && spec["prompt"].nil?
        @placeholders.call(prompt, inputs, "#{where}: prompt", extra: VARIABLES)
        parallel = spec.fetch("parallel", true)
        problem "#{where}: parallel must be true or false, got #{shown(parallel)}" unless [true, false].include?(parallel)
        reviewers[name] = {
          "title" => @text.call(spec["title"], "#{where}: title") || name,
          "prompt" => prompt,
          "include" => @names.call(spec["include"], "#{where}: include"),
          "parallel" => parallel != false
        }
      end
    end

    # A step's `review:`: a bare list of reviewer names, or a mapping. Which reviewers exist is checked afterwards, by {#check}.
    #
    # @param value [Object] the `review:` value
    # @param where [String] "step ID"
    # @param inputs [Hash] the definition's inputs
    # @return [Hash, nil] "from", "need", "must", "subject", "revision", "max_rounds", "timeout", "uses", "context" and "notify"; nil for no review or a bad one
    def review(value, where, inputs)
      return nil if value.nil?
      value = {"from" => value} if value.is_a?(Array) && value.any?
      unless value.is_a?(Hash) && value.any?
        problem "#{where}: review must be a list of reviewer names or a mapping with from, got #{shown(value, 60)}"
        return nil
      end
      unknown_keys(value, REVIEW_KEYS, "#{where}: review")
      from = value["from"]
      from_valid = from.is_a?(Array) && from.any? && from.all? { |name| name.is_a?(String) && @name_pattern.match?(name) }
      problem "#{where}: review from must be a list of reviewer names, got #{shown(from, 60)}" unless from_valid
      if from_valid
        repeated = from.tally.select { |_, count| count > 1 }.keys
        problem "#{where}: review from lists #{repeated.join(", ")} more than once" if repeated.any?
      else
        from = []
      end
      must = list_of_names(value, "must", [], where)
      need = if value.key?("need")
        value["need"]
      elsif from_valid
        from.size
      end
      problem "#{where}: review need must be a whole number of 1 or more, got #{shown(need)}" if (value.key?("need") || from_valid) && !(need.is_a?(Integer) && need >= 1)
      max_rounds = value.fetch("max_rounds", DEFAULT_MAX_ROUNDS)
      unless max_rounds.is_a?(Integer) && max_rounds.between?(1, MAX_ROUNDS)
        problem "#{where}: review max_rounds must be a whole number from 1 to #{MAX_ROUNDS}, got #{shown(max_rounds)}"
      end
      timeout = if !value.key?("timeout")
        DEFAULT_TIMEOUT
      elsif value["timeout"].nil?
        problem "#{where}: review timeout must be a duration such as 90 or 30m, got nothing"
      else
        @duration.call(value["timeout"], "#{where}: review timeout", MAX_TIMEOUT)
      end
      notify = value.fetch("notify", true)
      problem "#{where}: review notify must be true or false, got #{shown(notify)}" unless [true, false].include?(notify)
      subject = @text.call(value["subject"], "#{where}: review subject")
      @placeholders.call(subject, inputs, "#{where}: review subject", extra: VARIABLES - ["review.subject"])
      uses = if value.key?("uses") && value["uses"].nil?
        problem "#{where}: review uses must be a lock name or a list of lock names, got nothing"
        []
      else
        @uses.call(value["uses"], "#{where}: review")
      end
      context = if value.key?("context") && value["context"].nil?
        problem "#{where}: review context must be one of fresh, continue, got nothing"
      else
        @context.call(value.fetch("context", "fresh"), "#{where}: review context")
      end
      {
        "from" => from,
        "need" => need,
        "must" => must,
        "subject" => subject,
        "revision" => @text.call(value["revision"], "#{where}: review revision"),
        "max_rounds" => max_rounds,
        "timeout" => timeout,
        "uses" => uses,
        "context" => context,
        "notify" => notify != false
      }
    end

    # The checks that need the whole definition: every named reviewer exists, and `need` and `must` fit `from`.
    #
    # @param steps [Array<Hash>] the built steps
    # @param reviewers [Hash] {#reviewers}'s answer
    # @return [void]
    def check(steps, reviewers)
      steps.each do |step|
        review = step["review"] or next
        from = review["from"]
        next if from.empty?
        where = "step #{step["id"]}"
        unknown = from.uniq - reviewers.keys
        problem "#{where}: review names unknown reviewer#{"s" if unknown.size > 1} #{unknown.join(", ")} (known: #{reviewers.keys.empty? ? "none, the workflow has no reviewers:" : reviewers.keys.join(", ")})" if unknown.any?
        must = review["must"].uniq
        outside = must - from
        problem "#{where}: review must lists #{outside.join(", ")}, which #{(outside.size > 1) ? "are" : "is"} not in from" if outside.any?
        need = review["need"]
        next unless need.is_a?(Integer)
        problem "#{where}: review need is #{need}, more than the #{from.size} reviewer#{"s" if from.size != 1} in from" if need > from.size
        problem "#{where}: review need is #{need}, fewer than the #{must.size} reviewers in must" if need < must.size
      end
    end

    private

    def problem(message)
      @report.call(message)
      nil
    end

    def shown(value, limit = 40)
      value.nil? ? "nothing" : value.inspect[0, limit]
    end

    def unknown_keys(mapping, allowed, where)
      extra = mapping.keys.map(&:to_s) - allowed
      problem "#{where} has unknown key#{"s" if extra.size > 1} #{extra.join(", ")} (known: #{allowed.join(", ")})" if extra.any?
    end

    # A list of reviewer names with none twice; a null or a non-list is a problem.
    def list_of_names(mapping, key, default, where)
      list = mapping.fetch(key, default)
      unless list.is_a?(Array) && list.all? { |name| name.is_a?(String) }
        problem "#{where}: review #{key} must be a list of reviewer names, got #{shown(list, 60)}"
        return []
      end
      repeated = list.tally.select { |_, count| count > 1 }.keys
      problem "#{where}: review #{key} lists #{repeated.join(", ")} more than once" if repeated.any?
      list
    end
  end
end
