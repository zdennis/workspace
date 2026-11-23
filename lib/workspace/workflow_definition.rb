require "yaml"
require "digest"

module Workspace
  # One workflow definition: a YAML file of ordered steps, checked and turned
  # into the plain hash a run keeps a copy of. A step runs in the workspace's
  # agent pane; the way back to an earlier step is `on_fail: {goto, max}`, and
  # a step with no `on_fail` sends the run back to the step before it, at most
  # until the run's attempts are spent (an `on_fail: stop` stands for a person).
  #
  # Every problem in a file is collected and reported at once, with code
  # `invalid_workflow`, so a definition is fixed in one pass.
  class WorkflowDefinition
    # The current `schema_version`, and the one a definition without the key gets.
    SCHEMA_VERSION = "0.1"

    # Every `schema_version` a definition may name.
    SCHEMA_VERSIONS = %w[0.1].freeze

    # Old integer `schema_version` values, as written, read as the version they became.
    LEGACY_SCHEMA_VERSIONS = {"1" => "0.1"}.freeze

    # What `step done --code` accepts.
    CODE_PATTERN = /\A[a-z][a-z0-9_]{0,39}\z/

    # Why a report's code is refused for being one the engine sets itself; nil for any other. The one rule
    # `step done --code` and `workflow simulate`'s `code:` share.
    #
    # @param code [String, nil]
    # @return [String, nil] the sentence after "--code ", or nil when the code is allowed
    def self.engine_code_refusal(code)
      return nil unless code && Workspace::WorkflowEngine::ENGINE_CODES.include?(code)
      "#{code} is a word the engine sets itself (#{Workspace::WorkflowEngine::ENGINE_CODES.join(", ")}); choose another."
    end

    # Input names, as written in `{{inputs.NAME}}`.
    INPUT_PATTERN = /\A[a-z][a-z0-9_]*\z/

    TOP_KEYS = %w[schema_version id title description version use_when applies_to extends replace inputs include instructions max_attempts stall redeliver budget timeout timeout_action deny permissions hang_guard reviewers steps].freeze
    STEP_KEYS = %w[title prompt prompt_file include produces status gate guard require uses on_fail context timeout on_timeout max_attempts review after execution_mode].freeze

    # What a `fan_out` group step may hold. A group has no body of its own: its `fan_out:` is a mapping of sibling
    # step id to an ordinary step body, and the siblings are flattened into the steps list at the group's place,
    # each tagged `"group" => GROUP_ID` (the tag {WorkflowRun.step_scoped?} reads). `fan_out` is kept out of
    # {STEP_KEYS} so a step's unknown-key message reads as before; {#steps_from} routes a step holding it here.
    GROUP_KEYS = %w[title fan_out checkout on_fail execution_mode].freeze

    # How a group's siblings share the checkout; the first is the default.
    GROUP_CHECKOUTS = %w[shared shared-edit].freeze

    # How a group's siblings run: each as a sub-agent of the run's own pane, or each in its own author pane.
    EXECUTION_MODES = %w[subagents process_separation].freeze

    # The execution mode a group runs with when its definition does not say: each sibling as a sub-agent of the
    # run's own pane.
    DEFAULT_EXECUTION_MODE = "subagents"

    # Step keys a `fan_out` sibling may not hold, and why.
    SIBLING_REFUSALS = {
      "review" => "a fan_out sibling can't take review: yet (closing a review round's window closes every other review window of the run)",
      "uses" => "a fan_out sibling can't take uses: yet (a run holds one step's locks at a time, so a sibling's acquire would release the locks another sibling still needs)",
      "fan_out" => "a fan_out sibling can't hold a fan_out of its own (groups don't nest)",
      "import" => "a fan_out sibling can't import: a step yet; write the step in the group"
    }.freeze

    # What a step does past its `timeout`: raise the `timed_out` flag only, stop the agent, or fail the step.
    ON_TIMEOUT_ACTIONS = %w[warn interrupt fail].freeze
    DEFAULT_ON_TIMEOUT = "warn"
    INPUT_PATTERN_LIMIT = 300
    INPUT_KEYS = %w[description required pattern].freeze
    ON_FAIL_KEYS = %w[goto max context log_tail backoff except].freeze

    # The most entries an `on_fail` `except` list may hold, and the most characters of one.
    MAX_FAIL_EXCEPT = 8
    MAX_FAIL_EXCEPT_NAME = 60

    # The most seconds an `on_fail` `backoff` may be (one day), and the most lines a `log_tail` may be.
    MAX_BACKOFF = 24 * 3600
    MAX_LOG_TAIL = WorkflowLogTail::MAX_LINES
    GUARDS = %w[unchanged config].freeze
    STATUS_KEYS = %w[command run timeout report_code].freeze

    # How a step starts: in a new conversation, or in the one the pane has.
    CONTEXTS = %w[fresh continue].freeze

    # Attempts a run may make across all its steps before a failure stops it.
    DEFAULT_MAX_ATTEMPTS = 6

    # Times `workflow sweep` retries a step's undelivered line when the definition says nothing.
    DEFAULT_REDELIVER = 10

    # The most `redeliver` may be.
    MAX_REDELIVER = 10

    # What a `budget:` may hold, and the most tokens it may name.
    BUDGET_KEYS = %w[tokens action].freeze
    BUDGET_ACTIONS = %w[stop interrupt].freeze
    MAX_BUDGET_TOKENS = 1_000_000_000_000

    # What the run `timeout_action:` may be: hold the next attempt start (the default), or also interrupt the
    # step under way once `workflow sweep` sees the deadline pass.
    TIMEOUT_ACTIONS = %w[hold interrupt].freeze

    # The most seconds a run `timeout:` may name (365 days).
    MAX_RUN_TIMEOUT = 365 * 86_400

    # The kinds of ref `workflow start` can be given (`StartRef`'s kinds), which `applies_to:` may list.
    REF_KINDS = %w[jira github_pr github_issue branch].freeze

    # The most characters a `use_when:` line may hold.
    MAX_USE_WHEN = 200

    # The actions a workflow's `permissions:` rule may name: a definition only narrows, so never `allow`.
    PERMISSION_ACTIONS = %w[deny ask].freeze
    # Limits on a `deny:` list: patterns, their length, and `*` or `?` in one (a long run of wildcards makes a glob slow).
    MAX_DENY = 50
    MAX_DENY_LENGTH = PermissionRules::MAX_PATTERN_LENGTH
    MAX_DENY_WILDCARDS = PermissionRules::MAX_PATTERN_WILDCARDS

    # Seconds a `status:` check may run when it names no timeout.
    DEFAULT_CHECK_TIMEOUT = 20 * 60
    EXEC_DEFAULT_TIMEOUT = 5 * 60
    EXEC_MAX_TIMEOUT = 2 * 60 * 60

    # The `{{name}}` placeholders a prompt may use besides `{{inputs.NAME}}`.
    VARIABLES = %w[workspace branch artifacts run].freeze

    PLACEHOLDER = /\{\{\s*([^{}\s]+)\s*\}\}/
    private_constant :PLACEHOLDER

    # @return [String] the workflow's id (its file name without `.yml`)
    attr_reader :id

    # @return [String] where the definition was read from: "project", "global", "source:N" or "builtin" when
    #   the catalog resolved it, "file" or "stdin" when it was parsed outside one
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
    # @param parent_lookup [#call, nil] given a workflow id and `below:` (a source name or nil), answers the parent's "text", "path" and "source" (nil when there is none); needed only for `extends:`
    # @param chain [Array, nil] for {WorkflowExtends}: the id and file of each definition being read, outermost first
    # @param import_lookup [#call, nil] the lookup {WorkflowImports} finds a bare-name `import:` with, given a name and
    #   `layer:` (this definition's +source+); nil leaves each bare-name import not checked
    # @param confine_dir [String, nil] for a source or builtin definition: its layer directory, which every
    #   `PATH.yml#NAME` import must stay inside
    # @return [Workspace::WorkflowDefinition]
    # @raise [Workspace::Error] code `invalid_workflow`, with every problem in `details["problems"]`
    def self.parse(text, id:, source:, path:, base_dir: nil, parent_lookup: nil, chain: nil, import_lookup: nil, confine_dir: nil)
      new(text, id: id, source: source, path: path, base_dir: base_dir, parent_lookup: parent_lookup, chain: chain,
        import_lookup: import_lookup, confine_dir: confine_dir)
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
    # @param parent_lookup [#call, nil]
    # @param chain [Array, nil]
    # @param import_lookup [#call, nil]
    # @param confine_dir [String, nil]
    def initialize(text, id:, source:, path:, base_dir: nil, parent_lookup: nil, chain: nil, import_lookup: nil, confine_dir: nil)
      @text = text
      @base_dir = base_dir || (path && File.dirname(path))
      @id = id
      @source = source
      @path = path
      @sha256 = Digest::SHA256.hexdigest(text)
      @problems = []
      @notes = []
      @groups = {}
      @current_step = nil
      # Each file expands its own imports before extends: merges, so a parent's steps arrive already resolved.
      @step_imports = WorkflowImports.new(lookup: import_lookup, layer: source, base_dir: @base_dir, confine_dir: confine_dir)
      expanded = @step_imports.expand(load_yaml(text))
      extension = WorkflowExtends.new(id: id, source: source, lookup: parent_lookup, chain: chain || [[id, path || id]], import_lookup: import_lookup)
      @resolved_raw = extension.resolve(expanded)
      @parents = extension.parents
      @origins = extension.origins
      @notes = extension.notes + @step_imports.notes
      @unchecked = @step_imports.unchecked + extension.unchecked
      if @step_imports.failure.any? || extension.failure.any?
        # An import or the parent can't be used, so nothing else about this file can be judged.
        @problems = @step_imports.failure + extension.failure
      else
        @problems.concat(extension.problems)
        @data = build(@resolved_raw)
      end
      return if @problems.empty?
      raise Workspace::Error.new("Workflow '#{id}' #{path ? "(#{path})" : "(from stdin)"} is not valid:\n" + @problems.map { |problem| "  - #{problem}" }.join("\n"),
        code: "invalid_workflow", details: {"workflow" => id, "path" => path, "problems" => @problems})
    end

    # The mapping {#to_h} was checked from: the file's own, or, with `extends:`, the parent's laid under it (see {WorkflowExtends}).
    #
    # @return [Hash]
    attr_reader :resolved_raw

    # The workflows this one extends, nearest first, as read now.
    #
    # @return [Array<Hash{String=>String}>] each with "id", "source", "path" and "sha256" (of that file's text)
    attr_reader :parents

    # Where each step came from, for a definition that extends another: step id to the id of the workflow it was
    # inherited from (the nearest ancestor that defines it), or "own" for a step this file adds or replaces.
    # Empty without `extends:`. Not part of {#to_h}.
    #
    # @return [Hash{String=>String}]
    attr_reader :origins

    # The steps this file imports, one entry per importing step, as {WorkflowImports#imports} gives them. Empty
    # without `import:`, and never part of {#to_h}.
    #
    # @return [Array<Hash{String=>Object}>]
    def imports
      @step_imports.imports
    end

    # The digest a run records as `definition_sha256`: {#sha256} alone, or, for a definition that imports steps
    # or extends others, the digest of its own digest and its imports', then each parent's file digest and that
    # parent's imports', so a changed library step or parent at any depth is a changed definition. With no import in
    # the chain, the imports add nothing and the digest is the one recorded before imports existed.
    #
    # @return [String]
    def resolved_sha256
      import_digests = imports.map { |entry| entry["sha256"] }
      return @sha256 if @parents.empty? && import_digests.empty?
      parent_digests = @parents.flat_map { |parent| [parent["sha256"]] + parent["import_sha256s"] }
      Digest::SHA256.hexdigest(([@sha256] + import_digests + parent_digests).join("\n"))
    end

    # @return [Hash{String=>Object}] the checked definition with defaults filled in: "id",
    #   "title", "description", "inputs" (name to "description" and "required"), "include",
    #   "instructions", "max_attempts" and "steps", an ordered list where each step has "id",
    #   "title", "prompt", "include", "produces", "status" (nil, or "command" or "run" with
    #   "timeout" seconds), "gate", "guard" (nil, "unchanged" or "config"), "require" (a list of one-key proofs such as `{"commits" => 1}`), "uses", "on_fail" (nil, "stop", or "goto", "max", "context", and, only when set, "log_tail" and "backoff" seconds),
    #   "context" and "timeout" (seconds or nil); a `fan_out` group's siblings sit in "steps" at the group's place,
    #   each also with "group" (the group step's id) and "execution_mode" (the mode it runs with, its own or the
    #   group's), and only then is there "groups": group id to "title",
    #   "checkout", "on_fail" (`stop`, or the goto mapping a step's `on_fail` has), "steps" (its sibling ids, in order) and, only when the definition set it,
    #   "execution_mode"
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
      missing = steps.reject { |step| proof?(step) || @unchecked.include?(step["id"]) }.map do |step|
        {"code" => "step_without_proof", "step" => step["id"],
         "message" => "step #{step["id"]} has no produces, status, require or gate, so it passes on any turn end, even one that did nothing. Add produces: (a file it must write), require: (proofs about the repository), status: (a command that must pass) or gate: approve (a person approves it)."}
      end
      idle = steps.select { |step| step["timeout"].nil? && step["on_timeout"] != DEFAULT_ON_TIMEOUT }.map do |step|
        {"code" => "on_timeout_without_timeout", "step" => step["id"],
         "message" => "step #{step["id"]} sets on_timeout: #{step["on_timeout"]} but has no timeout:, so it never applies. Add timeout: (such as 2h) or remove on_timeout."}
      end
      unused_action = if @data.key?("timeout_action") && !@data.key?("timeout")
        [{"code" => "timeout_action_without_timeout",
          "message" => "timeout_action: #{@data["timeout_action"]} is set but the workflow has no timeout:, so it never applies. Add timeout: (such as 8h) or remove timeout_action."}]
      else
        []
      end
      missing + idle + retry_warnings + step_attempt_warnings + guard_after_commit_warnings + WorkflowReviewSpec.round_warnings(steps, @data["max_attempts"]) + WorkflowFanOutSpec.warnings(@data["groups"]) + @notes + unused_action
    end

    # Every project command a definition checks with: each step's `status: command:` and each `require: command:` not marked optional.
    #
    # @param data [Hash] {#to_h}
    # @return [Array<Hash{String=>String}>] each with "step" (the step id), "command" (`test` or `lint`) and "via" (`status` or `require`)
    def self.command_needs(data)
      data["steps"].flat_map do |step|
        roles = [[step.dig("status", "command"), "status"]]
        roles += Array(step["require"]).reject { |entry| entry["optional"] == true }.map { |entry| [entry["command"], "require"] }
        roles.select(&:first).map { |role, via| {"step" => step["id"], "command" => role, "via" => via} }
      end
    end

    # Whether the step +from+, or a later one, reads the workspace's plan: `implementation-plan`
    # in the step's `include` or in the definition's top-level `include` (which applies to every
    # step), or a `plan_status` entry in the step's `require`.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @param from [String, nil] a step id; an unknown or nil one counts every step
    # @return [Boolean]
    def self.reads_plan?(definition, from:)
      return false unless definition.is_a?(Hash)
      steps = Array(definition["steps"]).select { |step| step.is_a?(Hash) }
      return true if Array(definition["include"]).include?("implementation-plan") && steps.any?
      index = steps.index { |step| step["id"] == from } || 0
      steps.drop(index).any? do |step|
        Array(step["include"]).include?("implementation-plan") ||
          Array(step["require"]).any? { |entry| entry.is_a?(Hash) && entry.key?("plan_status") }
      end
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

    # The `use_when` of a definition hash: one line saying when to pick the workflow.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [String, nil] nil when unset, stored before the key existed, or a bad stored value
    def self.use_when(definition)
      value = definition.is_a?(Hash) ? definition["use_when"] : nil
      (value.is_a?(String) && !value.strip.empty? && value.length <= MAX_USE_WHEN && !value.match?(/[\r\n]/)) ? value : nil
    end

    # The `version` of a definition hash: the whole number its author gives to a revision of it.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Integer, nil] nil when unset, stored before the key existed, or a bad stored value
    def self.version(definition)
      value = definition.is_a?(Hash) ? definition["version"] : nil
      (value.is_a?(Integer) && value >= 1) ? value : nil
    end

    # The `applies_to` of a definition hash: the kinds of ref the workflow is for.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Array<String>] kinds from {REF_KINDS}; empty (applies to every ref) when unset, stored before
    #   the key existed, or a bad stored value
    def self.applies_to(definition)
      value = definition.is_a?(Hash) ? definition["applies_to"] : nil
      (value.is_a?(Array) && value.all? { |kind| REF_KINDS.include?(kind) }) ? value.uniq : []
    end

    # The `deny` of a definition hash: shell globs of Bash commands the run's agent may not run.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Array<String>] empty in a definition stored before the key existed or holding a bad value
    def self.deny(definition)
      value = definition.is_a?(Hash) ? definition["deny"] : nil
      return [] unless value.is_a?(Array) && value.size <= MAX_DENY
      (value.all? { |pattern| pattern.is_a?(String) && !pattern.strip.empty? }) ? value : []
    end

    # The `permissions` of a definition hash: rules that only narrow what a run's agent may do (`deny` or `ask`, never `allow`).
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Array<Hash>] rules as {PermissionRules.parse} returns them; empty in a definition stored before the key existed or holding a bad value
    def self.permissions(definition)
      value = definition.is_a?(Hash) ? definition["permissions"] : nil
      PermissionRules.parse(value, label: "permissions", actions: PERMISSION_ACTIONS)
    rescue ArgumentError
      []
    end

    # The `budget` of a definition hash: the tokens a run may use before the next attempt is held.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Hash{String=>Object}, nil] "tokens" and "action"; nil for a definition that declares none, one
    #   stored before the key existed, or a bad stored value
    def self.budget(definition)
      value = definition.is_a?(Hash) ? definition["budget"] : nil
      return nil unless value.is_a?(Hash) && value["tokens"].is_a?(Integer) && value["tokens"].between?(1, MAX_BUDGET_TOKENS)
      {"tokens" => value["tokens"], "action" => BUDGET_ACTIONS.include?(value["action"]) ? value["action"] : "stop"}
    end

    # The run `timeout` of a definition hash: the machine time a run may use before the next attempt is held.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Hash{String=>Object}, nil] "seconds" and "action" (`hold` unless stored `interrupt`); nil for a
    #   definition that declares none, one stored before the key existed, or a bad stored value
    def self.run_timeout(definition)
      value = definition.is_a?(Hash) ? definition["timeout"] : nil
      return nil unless value.is_a?(Numeric) && value.finite? && value > 0 && value <= MAX_RUN_TIMEOUT
      action = definition["timeout_action"]
      {"seconds" => value, "action" => TIMEOUT_ACTIONS.include?(action) ? action : TIMEOUT_ACTIONS.first}
    end

    # The `redeliver` of a definition hash: how many times `workflow sweep` retries a step's undelivered line.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Integer] 0 (no retry) in a definition stored before the key existed or holding a bad value
    def self.redeliver(definition)
      value = definition.is_a?(Hash) ? definition["redeliver"] : nil
      (value.is_a?(Integer) && value.between?(0, MAX_REDELIVER)) ? value : 0
    end

    # The `backoff` of a step's `on_fail`: seconds to wait before the retry starts.
    #
    # @param on_fail [Hash, nil] a step's `on_fail`, or one stored before the key existed
    # @return [Numeric, nil] seconds; nil unless a positive number up to a day
    def self.backoff(on_fail)
      value = on_fail.is_a?(Hash) ? on_fail["backoff"] : nil
      (value.is_a?(Numeric) && value.finite? && value > 0 && value <= MAX_BACKOFF) ? value : nil
    end

    # The `log_tail` of a step's `on_fail`: how many lines of the failed check's log the retry's prompt holds.
    #
    # @param on_fail [Hash, nil] a step's `on_fail`, or one stored before the key existed
    # @return [Integer, nil] nil unless a whole number from 1 to {MAX_LOG_TAIL}
    def self.log_tail(on_fail)
      value = on_fail.is_a?(Hash) ? on_fail["log_tail"] : nil
      (value.is_a?(Integer) && value.between?(1, MAX_LOG_TAIL)) ? value : nil
    end

    # The `on_fail` of a `fan_out` group.
    #
    # @param definition [Hash, nil] {#to_h}, or a stored run's definition
    # @param gid [String] the group's id
    # @return [String, Hash] `"stop"` when the key or the group is missing (a run stored before a group could goto)
    def self.group_on_fail(definition, gid)
      groups = definition.is_a?(Hash) ? definition["groups"] : nil
      group = groups.is_a?(Hash) ? groups[gid] : nil
      on_fail = group.is_a?(Hash) ? group["on_fail"] : nil
      on_fail.nil? ? "stop" : on_fail
    end

    # @return [Integer, nil] a step's own attempt cap, nil when it has none (an absent key counts as none)
    def self.step_max_attempts(step)
      value = step.is_a?(Hash) ? step["max_attempts"] : nil
      value.is_a?(Integer) ? value : nil
    end

    # The `reviewers` of a definition hash: the named reviewers a step's `review:` picks from.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Hash{String=>Hash}] name to "title", "prompt", "include" and "parallel"; empty for a definition that
    #   declares none, one stored before the key existed, or a bad stored value
    def self.reviewers(definition)
      value = definition.is_a?(Hash) ? definition["reviewers"] : nil
      return {} unless value.is_a?(Hash)
      value.select { |name, entry| name.is_a?(String) && entry.is_a?(Hash) }
    end

    # The `review` of a step hash: who reviews the step's work before it passes.
    #
    # @param step [Hash] a step of {#to_h}, or of a stored run's definition
    # @return [Hash{String=>Object}, nil] "from", "need", "must", "subject", "revision", "max_rounds", "timeout",
    #   "uses", "context" and "notify"; nil for a step with none, one stored before the key existed, or a bad stored value
    def self.review(step)
      value = step.is_a?(Hash) ? step["review"] : nil
      (value.is_a?(Hash) && value["from"].is_a?(Array) && value["from"].any?) ? value : nil
    end

    # Whether a step's review rounds are direct: its `review:` names exactly one reviewer and that reviewer names a
    # `model:`. A direct round's review pane, started on that model, writes the verdict from its own main thread
    # instead of through a sub-agent. The one test of it: the prompt, the round's `direct` slot and the pane's
    # binding all read it here.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @param step [Hash] a step of +definition+
    # @return [Boolean]
    def self.direct_review?(definition, step)
      from = review(step)&.dig("from")
      return false unless from.is_a?(Array) && from.size == 1
      model = reviewers(definition).dig(from.first, "model")
      model.is_a?(String) && !model.empty?
    end

    # The `fan_out` groups of a definition hash, from its steps' "group" tags (so a stored run's definition reads too).
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @return [Hash{String=>Array<String>}] group id to its sibling step ids, in step order; empty without groups
    def self.group_steps(definition)
      steps = definition.is_a?(Hash) ? Array(definition["steps"]) : []
      steps.each_with_object({}) do |step, found|
        next unless step.is_a?(Hash) && step["group"].is_a?(String) && !step["group"].empty?
        (found[step["group"]] ||= []) << step["id"]
      end
    end

    # Whether a definition's step entry is a fan_out sibling whose resolved `execution_mode` is `subagents`: it
    # runs as a sub-agent of the run's own pane, with no pane binding or pane slot of its own. The one test of
    # it: {WorkflowRun.pane_free?} reads a stored run's entries through this, and dispatch, the starter and the
    # attempt record read built entries through it. A run stored before the key existed has siblings without a
    # resolved mode, which read as today's per-pane behavior.
    #
    # @param step [Hash] one step entry of a definition's "steps" (built or stored)
    # @return [Boolean]
    def self.subagent_sibling?(step)
      step.is_a?(Hash) && step["group"].is_a?(String) && !step["group"].empty? && step["execution_mode"] == "subagents"
    end

    # The siblings of +step_id+'s `fan_out` group, in step order, read from the steps' "group" tags.
    #
    # @param definition [Hash] {#to_h}, or a stored run's definition
    # @param step_id [String, nil] a step id
    # @return [Array<String>, nil] nil for a step in no group, or one the definition does not have
    def self.siblings_of(definition, step_id)
      steps = definition.is_a?(Hash) ? Array(definition["steps"]) : []
      step = steps.find { |each| each.is_a?(Hash) && each["id"] == step_id }
      group = step && step["group"]
      (group.is_a?(String) && !group.empty?) ? group_steps(definition)[group] : nil
    end

    private

    # `guard: unchanged` compares HEAD to the run's starting commit, so it passes only while no step has
    # committed. A guarded step at or after the first step with `require: commits:` can never pass. A guarded
    # step before it passes the first time, but fails with `head_moved` when a later step's failure sends the
    # run back to it: through its `on_fail` goto, or the one-step-back loop a step with no `on_fail` takes.
    # Only `require: commits:` counts as committing, so a step that merely may commit is not guessed at.
    def guard_after_commit_warnings
      first_commit = steps.index { |step| Array(step["require"]).any? { |entry| entry.is_a?(Hash) && entry.key?("commits") } }
      return [] unless first_commit
      committer = steps[first_commit]["id"]
      ids = steps.map { |step| step["id"] }
      groups = @data["groups"] || {}
      steps.each_with_index.flat_map do |step, index|
        next [] unless step["guard"] == "unchanged"
        if index >= first_commit
          why = (index == first_commit) ? "it also commits" : "step #{committer} commits before it"
          [{"code" => "guard_unchanged_after_commit", "step" => step["id"],
            "message" => "step #{step["id"]} sets guard: unchanged, but #{why}, and guard: unchanged compares the checkout to where the run started, so this step always fails with head_moved. Use guard: config (it allows commits and checks only the project's config files), or remove the guard."}]
        else
          loopers = steps.each_with_index.filter_map do |later, later_index|
            next if later_index < first_commit
            on_fail = later["on_fail"]
            group_on_fail = groups.dig(later["group"], "on_fail") if later["group"]
            on_fail = group_on_fail if on_fail.nil? && group_on_fail.is_a?(Hash)
            target = if on_fail.is_a?(Hash)
              on_fail["goto"]
            elsif on_fail.nil?
              WorkflowTransitions.implicit_target(steps, later)
            end
            target_index = ids.index(target) if target
            later["id"] if target_index && target_index <= index
          end
          next [] if loopers.empty?
          [{"code" => "guard_unchanged_loop_back", "step" => step["id"],
            "message" => "step #{step["id"]} sets guard: unchanged, but #{loopers.join(", ")} (a step that commits, or follows one) can send the run back to it when #{(loopers.size > 1) ? "they fail" : "it fails"} once a commit has been made, through on_fail goto or the default one-step-back loop. The guard then sees the earlier commit and stops the run with head_moved instead of retrying. Use guard: config on #{step["id"]}, or set on_fail: stop (or a goto to a step that may change the checkout) on #{loopers.join(", ")}."}]
        end
      end
    end

    # Step caps that can't hold: the step an `on_fail` goes back to runs once and then once per
    # retry, so `max + 1` above its cap means a retry that can never start; and a step cap
    # above the run's `max_attempts` never applies, since the run cap is spent first.
    def step_attempt_warnings
      by_id = steps.to_h { |step| [step["id"], step] }
      loops = failing_positions.filter_map do |position|
        on_fail = position[:on_fail]
        cap = self.class.step_max_attempts(by_id[on_fail["goto"]]) or next
        next if on_fail["max"] + 1 <= cap
        {"code" => "on_fail_exceeds_step_attempts", "step" => position[:id],
         "message" => "#{position[:label]} sets on_fail max: #{on_fail["max"]}, which runs step #{on_fail["goto"]} up to #{on_fail["max"] + 1} times, but step #{on_fail["goto"]} sets max_attempts: #{cap}. Raise its max_attempts to #{on_fail["max"] + 1} or more, or lower max."}
      end
      loops += sibling_attempt_warnings
      run_cap = @data["max_attempts"]
      over = steps.filter_map do |step|
        cap = self.class.step_max_attempts(step)
        next if cap.nil? || cap <= run_cap
        {"code" => "step_attempts_exceed_run", "step" => step["id"],
         "message" => "step #{step["id"]} sets max_attempts: #{cap}, above the workflow's max_attempts: #{run_cap}, so the run stops first. Lower the step's cap or raise the workflow's."}
      end
      loops + over
    end

    # Every `on_fail` that loops back: a step's own, and a `fan_out` group's goto, which counts as one
    # failing position at the group's last sibling.
    def failing_positions
      found = steps.each_with_index.filter_map do |step, index|
        on_fail = step["on_fail"]
        {id: step["id"], label: "step #{step["id"]}", noun: "step", index: index, on_fail: on_fail} if on_fail.is_a?(Hash)
      end
      (@data["groups"] || {}).each do |gid, group|
        on_fail = group["on_fail"]
        next unless on_fail.is_a?(Hash)
        last = steps.rindex { |step| step["group"] == gid } or next
        found << {id: gid, label: "group #{gid}", noun: "group", index: last, on_fail: on_fail}
      end
      found
    end

    # A sibling with no `on_fail` of its own takes its group's goto, so a later round dispatches it
    # again: its cap must reach the group's `max + 1`, or once it is spent the group's next failure stops the run for a
    # person (`limit: step`) before `max` loops.
    def sibling_attempt_warnings
      (@data["groups"] || {}).flat_map do |gid, group|
        on_fail = group["on_fail"]
        next [] unless on_fail.is_a?(Hash)
        steps.filter_map do |step|
          next unless step["group"] == gid && step["on_fail"].nil?
          cap = self.class.step_max_attempts(step) or next
          next if cap >= on_fail["max"] + 1
          {"code" => "on_fail_exceeds_step_attempts", "step" => step["id"],
           "message" => "step #{step["id"]} takes group #{gid}'s on_fail max: #{on_fail["max"]}, which runs it up to #{on_fail["max"] + 1} times, but it sets max_attempts: #{cap}, so once it has run #{cap} times the group's next failure stops the run for a person instead of going back to #{on_fail["goto"]}. Raise its max_attempts to #{on_fail["max"] + 1} or more, or lower max."}
        end
      end
    end

    # An `on_fail` whose retries can never all start. The run spends one attempt per step it
    # delivers, so step N (1-based) fails for the first time on attempt N, and each retry
    # delivers the steps from `goto` to it again. Retry M starts only while the attempts made
    # are fewer than `max_attempts`, which happens at the earliest after N + (M - 1) * span
    # attempts. Other steps and their loops only add attempts, so without reviews this count is
    # a floor. A reviewed step counts every round it may use (`WorkflowReviewSpec.attempt_weight`,
    # a rejection costs an attempt), which makes the count a worst case: the message then says
    # "if every review round is used". The failing step itself fails before its review.
    def retry_warnings
      ids = steps.map { |step| step["id"] }
      failing_positions.filter_map do |position|
        on_fail = position[:on_fail]
        index = position[:index]
        noun = position[:noun]
        goto = ids.index(on_fail["goto"])
        first = steps[0...index].sum { |each| WorkflowReviewSpec.attempt_weight(each) } + 1
        span = steps[goto...index].sum { |each| WorkflowReviewSpec.attempt_weight(each) } + 1
        wanted = on_fail["max"]
        reviewed = steps[0...index].any? { |each| WorkflowReviewSpec.reviewed?(each) }
        needed = first + (wanted - 1) * span
        allowed = @data["max_attempts"]
        next if needed < allowed
        fits = (first < allowed) ? (allowed - first - 1) / span + 1 : 0
        message = if reviewed
          "#{position[:label]} sets on_fail max: #{wanted}, but max_attempts: #{allowed} lets only #{fits} of those retries start if every review round is used (the #{noun} then fails first on attempt #{first}, and each retry runs #{span} attempt#{"s" if span != 1} again). Raise max_attempts to #{needed + 1} or more, or lower max or the review max_rounds."
        else
          "#{position[:label]} sets on_fail max: #{wanted}, but max_attempts: #{allowed} lets only #{fits} of those retries start (the #{noun} fails first on attempt #{first} at the earliest, and each retry runs #{span} step#{"s" if span != 1} again). Raise max_attempts to #{needed + 1} or more, or lower max."
        end
        {"code" => "on_fail_exceeds_max_attempts", "step" => position[:id], "message" => message}
      end
    end

    # What makes a step's pass mean something: a file it must write, a command that must
    # pass, or a person's gate.
    PROOF_KEYS = %w[status gate require review].freeze

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
      @schema_version_text = top_scalar_text(text, "schema_version") if parsed.is_a?(Hash)
      return parsed if parsed.is_a?(Hash)
      problem "the file must be a YAML mapping"
      {}
    rescue Psych::Exception => e
      problem "the file is not valid YAML (#{e.message.lines.first.to_s.strip})"
      {}
    end

    # While a step is being built (+@current_step+), a problem of an imported step ends with where it came from,
    # and one of a step whose import couldn't be checked here is dropped: that step was never read.
    def problem(message)
      return nil if @current_step && @unchecked.include?(@current_step)
      suffix = @current_step && @step_imports.provenance(@current_step)
      @problems << (suffix ? "#{message} #{suffix}" : message)
      nil
    end

    def for_step(step_id)
      outer = @current_step
      @current_step = step_id
      yield
    ensure
      @current_step = outer
    end

    # A top-level key's value as written in the file, so a version such as `0.10` is never read as the Float 0.1.
    def top_scalar_text(text, key)
      root = Psych.parse(text)&.root
      return nil unless root.is_a?(Psych::Nodes::Mapping)
      found = root.children.each_slice(2).select { |k, v| k.is_a?(Psych::Nodes::Scalar) && k.value == key && v.is_a?(Psych::Nodes::Scalar) }
      found.last&.last&.value
    end

    def schema_version_from(raw)
      return SCHEMA_VERSION unless raw.key?("schema_version")
      value = raw["schema_version"]
      written = (value.is_a?(Numeric) && @schema_version_text) || value.inspect
      version = case value
      when String then value
      when Float then @schema_version_text
      when Integer then LEGACY_SCHEMA_VERSIONS[@schema_version_text]
      end
      return version if SCHEMA_VERSIONS.include?(version)
      problem "schema_version must be one of #{SCHEMA_VERSIONS.join(", ")}, got #{written}"
    end

    def build(raw)
      problem "import: works on a step, not on a whole workflow; to build on another workflow, use extends: ID" if raw.key?("import")
      unknown_keys(raw.except("import"), TOP_KEYS, "the workflow")
      schema_version_from(raw)
      problem "id must be #{id.inspect}, the name of its file, got #{raw["id"].inspect}" if raw.key?("id") && raw["id"] != id
      problem "the workflow id #{id.inspect} must be #{IdPatterns::WORKFLOW_ID_RULE}" unless IdPatterns::WORKFLOW_ID.match?(id)
      inputs = inputs_from(raw["inputs"])
      max_attempts = raw.fetch("max_attempts", DEFAULT_MAX_ATTEMPTS)
      unless max_attempts.is_a?(Integer) && max_attempts >= 1
        problem "max_attempts must be a whole number of 1 or more, got #{max_attempts.inspect}"
      end
      version = self.class.version(raw)
      if raw.key?("version") && version.nil?
        problem "version must be a whole number of 1 or more, got #{raw["version"].inspect[0, 40]}"
      end
      redeliver = raw.fetch("redeliver", DEFAULT_REDELIVER)
      unless redeliver.is_a?(Integer) && redeliver.between?(0, MAX_REDELIVER)
        problem "redeliver must be a whole number from 0 to #{MAX_REDELIVER}, got #{redeliver.inspect}"
      end
      instructions = text_or_nil(raw["instructions"], "instructions")
      placeholders(instructions, inputs, "instructions")
      budget = budget_from(raw["budget"])
      timeout = capped_duration_from(raw["timeout"], "timeout", MAX_RUN_TIMEOUT)
      timeout_action = raw.fetch("timeout_action", TIMEOUT_ACTIONS.first)
      problem "timeout_action must be #{TIMEOUT_ACTIONS.join(" or ")}, got #{timeout_action.inspect[0, 40]}" unless TIMEOUT_ACTIONS.include?(timeout_action)
      hang_guard = hang_guard_from(raw)
      reviewers = review_spec.reviewers(raw["reviewers"], inputs)
      steps = steps_from(raw["steps"], inputs)
      steps.each { |step| for_step(step["id"]) { review_spec.check([step], reviewers) } }
      WorkflowFanOutSpec.new(report: method(:problem)).check(steps, @groups)
      {
        "id" => id,
        "title" => text_or_nil(raw["title"], "title") || id,
        "description" => text_or_nil(raw["description"], "description"),
        "use_when" => use_when_from(raw["use_when"]),
        "applies_to" => applies_to_from(raw["applies_to"]),
        "inputs" => inputs,
        "include" => names(raw["include"], "include"),
        "instructions" => instructions,
        "max_attempts" => max_attempts,
        "stall" => duration_from(raw["stall"], "stall"),
        "redeliver" => redeliver,
        "deny" => deny_from(raw["deny"]),
        "permissions" => permissions_from(raw["permissions"]),
        "steps" => steps
      }.merge(version ? {"version" => version} : {})
        .merge(budget ? {"budget" => budget} : {})
        .merge(hang_guard.nil? ? {} : {"hang_guard" => hang_guard})
        .merge(reviewers.any? ? {"reviewers" => reviewers} : {})
        .merge(@groups.any? ? {"groups" => @groups} : {})
        .merge(timeout ? {"timeout" => timeout} : {})
        .merge(((timeout || raw.key?("timeout_action")) && TIMEOUT_ACTIONS.include?(timeout_action)) ? {"timeout_action" => timeout_action} : {})
    end

    def review_spec
      @review_spec ||= WorkflowReviewSpec.new(
        name_pattern: INPUT_PATTERN, report: method(:problem), prompt: method(:prompt_from),
        placeholders: method(:placeholders), text: method(:text_or_nil), names: method(:names),
        uses: method(:uses_from), context: method(:context_from), duration: method(:capped_duration_from)
      )
    end

    def unknown_keys(mapping, allowed, where)
      extra = mapping.keys.map(&:to_s) - allowed
      problem "#{where} has unknown key#{"s" if extra.size > 1} #{extra.join(", ")} (known: #{allowed.join(", ")})" if extra.any?
    end

    def budget_from(value)
      return nil if value.nil?
      unless value.is_a?(Hash)
        problem "budget must be a mapping like {tokens: 40000000, action: stop|interrupt}, got #{value.inspect[0, 60]}"
        return nil
      end
      unknown_keys(value, BUDGET_KEYS, "budget")
      tokens = value["tokens"]
      unless tokens.is_a?(Integer) && tokens.between?(1, MAX_BUDGET_TOKENS)
        problem "budget tokens must be a whole number from 1 to #{MAX_BUDGET_TOKENS}, got #{tokens.inspect[0, 40]}"
      end
      action = value.fetch("action", BUDGET_ACTIONS.first)
      problem "budget action must be #{BUDGET_ACTIONS.join(" or ")}, got #{action.inspect[0, 40]}" unless BUDGET_ACTIONS.include?(action)
      (tokens.is_a?(Integer) && BUDGET_ACTIONS.include?(action)) ? {"tokens" => tokens, "action" => action} : nil
    end

    def use_when_from(value)
      return nil if value.nil?
      text = text_or_nil(value, "use_when") or return nil
      if text.match?(/[\r\n]/) || text.length > MAX_USE_WHEN
        problem "use_when must be one line of at most #{MAX_USE_WHEN} characters"
        return nil
      end
      text
    end

    def applies_to_from(value)
      return [] if value.nil?
      unless value.is_a?(Array) && !value.empty?
        problem "applies_to must be a list of ref kinds (#{REF_KINDS.join(", ")}), got #{value.inspect[0, 60]}"
        return []
      end
      unknown = value.reject { |kind| REF_KINDS.include?(kind) }
      problem "applies_to has unknown kind#{"s" if unknown.size > 1} #{unknown.map { |kind| kind.inspect[0, 40] }.join(", ")} (known: #{REF_KINDS.join(", ")})" if unknown.any?
      unknown.any? ? [] : value.uniq
    end

    def deny_from(value)
      return [] if value.nil?
      unless value.is_a?(Array)
        problem "deny must be a list of shell-glob patterns, got #{value.inspect[0, 60]}"
        return []
      end
      problem "deny holds #{value.size} patterns, at most #{MAX_DENY}" if value.size > MAX_DENY
      value.each_with_index.filter_map do |pattern, index|
        where = "deny entry #{index + 1}"
        if !pattern.is_a?(String) || pattern.strip.empty?
          problem "#{where} must be a non-empty pattern, got #{pattern.inspect[0, 60]}"
        elsif pattern.length > MAX_DENY_LENGTH
          problem "#{where} is longer than #{MAX_DENY_LENGTH} characters"
        elsif pattern.count("*?") > MAX_DENY_WILDCARDS
          problem "#{where} has more than #{MAX_DENY_WILDCARDS} wildcards (* or ?)"
        else
          pattern
        end
      end
    end

    def permissions_from(value)
      PermissionRules.parse(value, label: "permissions", actions: PERMISSION_ACTIONS)
    rescue ArgumentError => e
      problem e.message
      []
    end

    def hang_guard_from(raw)
      return nil unless raw.key?("hang_guard")
      value = raw["hang_guard"]
      value = "off" if value == false
      return value if PermissionRules::HANG_GUARD_MODES.include?(value)
      problem "hang_guard must be one of #{PermissionRules::HANG_GUARD_MODES.join(", ")}, got #{value.inspect[0, 40]}"
      nil
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
      taken = ids.dup
      steps = []
      ids.each_with_index do |step_id, index|
        body = raw[raw.keys[index]]
        if body.is_a?(Hash) && body.key?("fan_out")
          steps.concat(group_from(step_id, body, taken, inputs, steps.reject { |step| step["group"] }.map { |step| step["id"] }))
        else
          earlier = steps.map { |step| step["id"] }
          steps << for_step(step_id) { step_from(step_id, body, earlier, inputs) }
        end
      end
      cross_group_gotos(steps)
      steps
    end

    # The siblings of one `fan_out` group step, flattened and tagged with the group's id; records the group's own
    # keys in @groups. A sibling's `earlier` is the siblings before it, so its goto stays inside the group.
    def group_from(group_id, raw, taken, inputs, earlier_ungrouped)
      where = "step #{group_id}"
      problem "step id #{group_id.inspect} must be #{IdPatterns::WORKFLOW_ID_RULE}" unless IdPatterns::WORKFLOW_ID.match?(group_id)
      if raw.key?("import")
        problem "#{where} is a fan_out group, which can't import: (an import is one step); to build on another workflow's steps, use extends: ID"
      end
      extra = raw.keys.map(&:to_s) - GROUP_KEYS - ["import"]
      if extra.any?
        problem "#{where} is a fan_out group, which has no body of its own: it takes only #{GROUP_KEYS.join(", ")}, got #{extra.join(", ")}"
      end
      on_fail = on_fail_from(raw.fetch("on_fail", "stop"), earlier_ungrouped, where, group_of: group_id) || "stop"
      checkout = raw.fetch("checkout", GROUP_CHECKOUTS.first)
      unless GROUP_CHECKOUTS.include?(checkout)
        problem "#{where}: checkout must be #{GROUP_CHECKOUTS.join(" or ")}, got #{checkout.inspect[0, 60]}"
        checkout = GROUP_CHECKOUTS.first
      end
      mode = raw["execution_mode"]
      unless mode.nil? || EXECUTION_MODES.include?(mode)
        problem "#{where}: execution_mode must be #{EXECUTION_MODES.join(" or ")}, got #{mode.inspect[0, 60]}"
        mode = nil
      end
      title = text_or_nil(raw["title"], "#{where}: title") || group_id
      bodies = raw["fan_out"]
      unless bodies.is_a?(Hash) && bodies.any?
        problem "#{where}: fan_out must be a mapping of sibling step id to step, with at least one step"
        return []
      end
      earlier = []
      siblings = bodies.map do |key, body|
        sibling_id = key.to_s
        problem "#{where}: fan_out step #{sibling_id} has the id of another step; step ids must be unique" if taken.include?(sibling_id)
        taken << sibling_id
        if body.is_a?(Hash)
          SIBLING_REFUSALS.each { |name, why| problem "step #{sibling_id} (in fan_out group #{group_id}): #{why}" if body.key?(name) }
          body = body.except(*SIBLING_REFUSALS.keys)
        end
        step = step_from(sibling_id, body, earlier.dup, inputs, group: group_id, group_mode: mode)
        if step["execution_mode"] == "subagents" && body.is_a?(Hash) && body.key?("timeout")
          problem "step #{sibling_id} (in fan_out group #{group_id}): a sibling that runs as a sub-agent of the run's pane can't take timeout: " \
            "(the pane agent schedules its siblings, so a sibling's wall clock can't be enforced); the run's own timeout: still applies"
        end
        earlier << sibling_id
        step.merge("group" => group_id)
      end
      @groups[group_id] = {"title" => title, "checkout" => checkout, "on_fail" => on_fail, "steps" => siblings.map { |step| step["id"] }}
      @groups[group_id]["execution_mode"] = mode if mode
      siblings
    end

    # A goto from a step outside every group into a group's sibling. Flattening puts the siblings in a later step's
    # `earlier`, so {#on_fail_from} accepts it; a sibling's own goto is already kept inside its group there.
    def cross_group_gotos(steps)
      group_of = steps.to_h { |step| [step["id"], step["group"]] }
      steps.each do |step|
        on_fail = step["on_fail"]
        next unless on_fail.is_a?(Hash) && step["group"].nil?
        target = group_of[on_fail["goto"]] or next
        for_step(step["id"]) do
          problem "step #{step["id"]}: on_fail goto #{on_fail["goto"]} goes into fan_out group #{target}, which a step outside the group can't do yet; name a step outside every group"
        end
      end
    end

    # +group_mode+ is the mode the sibling's fan_out group runs with (nil for a plain step): a sibling without its own
    # `execution_mode:` inherits it, and a plain step may not set the key at all — it always runs in its own pane.
    def step_from(step_id, raw, earlier, inputs, group: nil, group_mode: nil)
      where = "step #{step_id}"
      problem "step id #{step_id.inspect} must be #{IdPatterns::WORKFLOW_ID_RULE}" unless IdPatterns::WORKFLOW_ID.match?(step_id)
      unless raw.is_a?(Hash)
        problem "#{where} must be a mapping"
        raw = {}
      end
      # A resolved import has had its `import:` merged away; only a step whose import wasn't checked still holds it.
      unknown_keys(@unchecked.include?(step_id) ? raw.except("import") : raw, STEP_KEYS, where)
      problem "#{where}: after: only places a step added by a workflow that has extends:" if raw.key?("after")
      mode = raw["execution_mode"]
      unless mode.nil? || EXECUTION_MODES.include?(mode)
        problem "#{where}: execution_mode must be #{EXECUTION_MODES.join(" or ")}, got #{mode.inspect[0, 60]}"
        mode = nil
      end
      mode = (mode || group_mode || DEFAULT_EXECUTION_MODE).dup.freeze
      if group.nil?
        problem "#{where}: execution_mode only applies to a fan_out sibling; a step outside every group runs in its own pane" if raw.key?("execution_mode")
      elsif mode == "subagents" && raw.key?("context")
        problem "#{where}: a sibling that runs as a sub-agent of the run's pane can't set context: (it has no pane of its own; " \
          "the group's one delivery into the run pane is always fresh)"
      end
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
        "on_fail" => on_fail_from(raw["on_fail"], earlier, where, group: group),
        "context" => context_from(raw.fetch("context", "fresh"), "#{where}: context"),
        "timeout" => duration_from(raw["timeout"], "#{where}: timeout"),
        "on_timeout" => on_timeout_from(raw.fetch("on_timeout", DEFAULT_ON_TIMEOUT), where),
        "max_attempts" => step_attempts_from(raw["max_attempts"], where)
      }.merge(review_spec.review(raw["review"], where, inputs).then { |review| review ? {"review" => review} : {} })
        .merge(group ? {"execution_mode" => mode} : {})
    end

    def step_attempts_from(value, where)
      return nil if value.nil?
      return value if value.is_a?(Integer) && value >= 1
      problem "#{where}: max_attempts must be a whole number of 1 or more, got #{value.inspect}"
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

    def placeholders(text, inputs, where, extra: [])
      return unless text.is_a?(String)
      text.scan(PLACEHOLDER).flatten.uniq.each do |name|
        next if VARIABLES.include?(name) || extra.include?(name)
        next if name.start_with?("inputs.") && inputs.key?(name.delete_prefix("inputs."))
        known = (VARIABLES + extra + inputs.keys.map { |input| "inputs.#{input}" }).map { |v| "{{#{v}}}" }.join(", ")
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
        return problem("#{where}: status command must be one of #{CommandsConfig::ROLES.join(", ")}, got #{role.inspect}") unless CommandsConfig::ROLES.include?(role)
        return {"command" => role, "timeout" => timeout, "report_code" => report_code_from(value, where)}.compact
      end
      run = text_or_nil(value["run"], "#{where}: status run")
      return nil if run.nil?
      {"run" => run, "timeout" => timeout, "report_code" => report_code_from(value, where)}.compact
    end

    # The opt-in `report_code: true` of a `status:`: a failed check of such a step may take its failure
    # code from the log's last `code: <name>` line instead of the plain `check_failed` (the engine reads
    # it in {WorkflowEngine#reported_check_code}). `false` is accepted and means the same as leaving the
    # key out. Absent from the parsed step unless set to true.
    def report_code_from(value, where)
      return nil unless value.key?("report_code")
      return true if value["report_code"] == true
      return nil if value["report_code"] == false
      problem "#{where}: status report_code must be true or false, got #{value["report_code"].inspect}"
      nil
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
        if entry.is_a?(Hash) && entry.key?("exec")
          exec = exec_entry_from(entry, where, inputs)
          exec ? (next exec) : next
        end
        one_proof = entry.is_a?(Hash) && (entry.size == 1 || entry.keys.sort == %w[command optional])
        unless one_proof
          problem "#{where}: each require entry must be one proof such as commits: 1 (only command: may take optional: true beside it, only exec: may take timeout:), got #{entry.inspect[0, 60]}"
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

    # `exec: "program args"` with an optional `timeout:`, stored as `{"exec" => argv, "timeout" => seconds}`.
    def exec_entry_from(entry, where, inputs)
      label = "#{where}: require exec"
      if entry.key?("optional")
        problem "#{label} does not take optional:, which only command: does"
        return nil
      end
      extra = entry.keys - %w[exec timeout]
      unless extra.empty?
        problem "#{label} takes only timeout: beside it, got #{extra.map(&:inspect).join(", ")}"
        return nil
      end
      text = entry["exec"]
      unless text.is_a?(String) && text.valid_encoding?
        problem "#{label} must be a program and its arguments as one string, got #{text.inspect[0, 60]}"
        return nil
      end
      argv, split_problem = WorkflowArgv.split(text)
      ok = true
      if split_problem
        problem "#{label} #{split_problem}"
        ok = false
      else
        problems, = WorkflowArgv.problems(argv, inputs: inputs.keys)
        problems.each { |each| problem "#{label} #{each}" }
        ok = problems.empty?
      end
      timeout = EXEC_DEFAULT_TIMEOUT
      if entry.key?("timeout")
        if entry["timeout"].nil?
          problem "#{label} timeout must be a duration such as 10m, got nothing"
          timeout = nil
        else
          timeout = duration_from(entry["timeout"], "#{label} timeout")&.ceil
        end
      end
      if timeout && timeout > EXEC_MAX_TIMEOUT
        problem "#{label} timeout must be at most 2h, got #{entry["timeout"].inspect[0, 60]}"
        timeout = nil
      end
      (ok && timeout) ? {"exec" => argv, "timeout" => timeout} : nil
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

    def on_fail_from(value, earlier, where, group: nil, group_of: nil)
      return nil if value.nil?
      return "stop" if value == "stop"
      return problem("#{where}: on_fail must be stop, or a mapping with goto and max") unless value.is_a?(Hash)
      unknown_keys(value, ON_FAIL_KEYS, "#{where}: on_fail")
      goto = value["goto"].to_s
      if group_of && !earlier.include?(goto)
        problem "#{where}: a fan_out group's on_fail goto must name a step before the group that is in no group (#{earlier.empty? ? "there is none" : earlier.join(", ")}), got #{value["goto"].inspect}"
      elsif group && !earlier.include?(goto)
        problem "#{where}: on_fail goto must name an earlier step of its fan_out group #{group} (#{earlier.empty? ? "there is none" : earlier.join(", ")}); a sibling's goto can't leave the group (to go back further, put on_fail: goto on group #{group}), got #{value["goto"].inspect}"
      elsif !earlier.include?(goto)
        problem "#{where}: on_fail goto must name an earlier step (#{earlier.empty? ? "there is none" : earlier.join(", ")}), got #{value["goto"].inspect}"
      end
      max = value.fetch("max", 1)
      problem "#{where}: on_fail max must be a whole number of 1 or more, got #{max.inspect}" unless max.is_a?(Integer) && max >= 1
      context = value.key?("context") ? context_from(value["context"], "#{where}: on_fail context") : nil
      log_tail = nil
      if value.key?("log_tail")
        log_tail = value["log_tail"]
        unless log_tail.is_a?(Integer) && log_tail.between?(1, MAX_LOG_TAIL)
          problem "#{where}: on_fail log_tail must be a whole number from 1 to #{MAX_LOG_TAIL}, got #{log_tail.inspect}"
          log_tail = nil
        end
      end
      backoff = nil
      if value.key?("backoff")
        begin
          backoff = Duration.parse_capped(value["backoff"], max: MAX_BACKOFF)
        rescue ArgumentError => e
          problem "#{where}: on_fail backoff: #{e.message}"
        end
      end
      except = names(value["except"], "#{where}: on_fail except") if value.key?("except")
      if except
        except.each do |name|
          next if name.length <= MAX_FAIL_EXCEPT_NAME
          problem "#{where}: on_fail except #{name.inspect} is longer than #{MAX_FAIL_EXCEPT_NAME} characters"
        end
        problem "#{where}: on_fail except takes at most #{MAX_FAIL_EXCEPT} codes or causes, got #{except.size}" if except.size > MAX_FAIL_EXCEPT
      end
      {"goto" => goto, "max" => max, "context" => context, "log_tail" => log_tail, "backoff" => backoff,
       "except" => (except unless except.nil? || except.empty?)}.compact.merge("context" => context)
    end

    def context_from(value, where)
      return value if CONTEXTS.include?(value)
      problem "#{where} must be one of #{CONTEXTS.join(", ")}, got #{value.inspect}"
    end

    def capped_duration_from(value, where, max)
      return nil if value.nil?
      Duration.parse_capped(value, max: max)
    rescue ArgumentError => e
      problem "#{where}: #{e.message}"
    end

    def duration_from(value, where)
      return nil if value.nil?
      Duration.parse_positive(value)
    rescue ArgumentError => e
      problem "#{where}: #{e.message}"
    end
  end
end
