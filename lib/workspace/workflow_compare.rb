module Workspace
  # Reads the runs of one workflow into groups by the definition they ran or the pack text their agent was sent,
  # and sets the groups side by side (`workflow compare`). It shows a direction and proves nothing: the tasks differ
  # between runs, and the result always carries {#warning}. It reads and writes nothing else.
  #
  # What a run counts under, from what the run file stored:
  # - `definition`: the run's `definition_sha256`, else the one `definition_sha256` its attempts agree on. A run
  #   with neither is in the `unknown` group.
  # - `pack:NAME`: the `sha256` of the pack (matched by its name, or its full `ref`) in the `packs` list that each
  #   delivered attempt recorded. A pack's text can change between attempts of one run: a run whose attempts
  #   saw more than one text is in the `mixed` group, never under either sha. A run whose delivered attempts
  #   recorded no `packs` list (stored before it existed), or no sha for the pack, is in the `unknown` group.
  #   A run whose attempts recorded `packs` without NAME did not use the pack and is counted apart in
  #   `without_pack`; a run with no delivered attempt in `no_attempts`. Neither is in any group, and a name that
  #   matches no run gives no groups, not an error: an archived run may simply not have kept it.
  #
  # Per group: `runs` (all of them), `first_try`, `settled`, `pass_first_percent` (`first_try` of `settled`, nil
  # with none settled), `running` (not settled, still going), `cancelled` (stopped by a person without a miss),
  # `stuck` (settled runs not ended: waiting on `failed_check` or `budget_spent` after a miss), `resumes`
  # (all `run_resumed` events) and `resumes_per_run`.
  #
  # A step is a miss when it has more than one delivered attempt (a rejected gate or a `resume --from` reran it,
  # or it looped) or its delivered attempt ended other than `passed` (in a `completed` run, one with no outcome too: it was passed over by a `resume --from` later step). A step with no delivered attempt, or one
  # delivered attempt still going, is not a miss; an attempt that never reached the agent is not delivered
  # ({WorkflowStats.kind_of}), so a redelivery is not a miss. A run is a first try when it completed with no miss.
  #
  # Settled runs are the denominator: every `completed` run; a `cancelled` run, and a run `waiting` on
  # `failed_check` or `budget_spent` (the reasons a run stops and needs a person, stored in its `reason` field
  # as `workflow status` reads it), that missed. A cancelled run with no miss, and any other run still going, is
  # in neither count, so an abandoned clean run or a run in progress is never a result. A stuck run counts as a
  # miss while it waits; a later resume can only move it to a completed miss, never to a first try. No run is
  # stored with state `failed` (the engine ends runs as `completed` or `cancelled`).
  class WorkflowCompare
    # Settled runs a group needs before the warning stops saying the sample is too small.
    MIN_SETTLED = 20

    # Reasons a run stops and waits for a person once its attempts are spent.
    STUCK = %w[failed_check budget_spent].freeze

    UNKNOWN = "unknown".freeze
    MIXED = "mixed".freeze

    SHA = /\A[0-9a-f]{64}\z/

    # @param loader [Workspace::WorkflowRunLoader] reads the runs and their resumes
    def initialize(loader:)
      @loader = loader
    end

    # The sentence every result carries. It only changes its first clause, so it stays true for a large sample.
    #
    # @param small [Boolean] a group has fewer than {MIN_SETTLED} settled runs, or there is only one group
    # @return [String]
    def self.warning(small)
      sentence = "tasks also differ between runs, so this shows a direction and does not prove a cause."
      small ? "Too few runs to call this a difference; #{sentence}" : sentence.sub(/\A[a-z]/, &:upcase)
    end

    # @param by [String] "definition" or "pack:NAME"
    # @return [Array(Symbol, String, nil)] :definition, or :pack and the name
    # @raise [Workspace::UsageError] for any other text
    def self.parse_by(by)
      return [:definition, nil] if by == "definition"
      name = by.to_s[/\Apack:(.+)\z/, 1]
      return [:pack, name] if name&.match?(/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,99}\z/)
      raise UsageError, "--by needs definition or pack:NAME (a pack name like plan-review), got #{by.to_s[0, 40].inspect}."
    end

    # @param workflow [String]
    # @param by [String] see {.parse_by}
    # @param last [Numeric, nil] see {WorkflowRunLoader#load}
    # @param include [#call, nil] see {WorkflowRunLoader#load}
    # @param loaded [Hash, nil] the answer of {WorkflowRunLoader#load}, when the caller has read it already
    # @return [Hash{String=>Object}] "by", "runs" (read), "matched" (in a group), "without_pack", "no_attempts",
    #   "unreadable" (files that are no run, plus runs of the wrong shape), "undated", "groups" and "warning"
    def read(workflow:, by:, last: nil, include: nil, loaded: nil)
      kind, name = self.class.parse_by(by)
      loaded ||= @loader.load(workflow: workflow, last: last, include: include)
      groups = {}
      counts = {"read" => 0, "without_pack" => 0, "no_attempts" => 0, "malformed" => 0}
      loaded["runs"].each do |run|
        key = (kind == :pack) ? pack_key(run, name) : definition_key(run)
        figures = figures_of(run)
      rescue NoMethodError, TypeError, ArgumentError, Workspace::Error
        counts["malformed"] += 1
      else
        counts["read"] += 1
        case key
        when :without then counts["without_pack"] += 1
        when :none then counts["no_attempts"] += 1
        else (groups[key] ||= []) << figures
        end
      end
      rows = groups.map { |sha, list| row(sha, list) }.sort_by { |each| [[UNKNOWN, MIXED].include?(each["sha"]) ? 1 : 0, -each["runs"], each["sha"]] }
      small = rows.size < 2 || rows.any? { |each| each["settled"] < MIN_SETTLED }
      {"by" => by, "runs" => counts["read"], "matched" => rows.sum { |each| each["runs"] }, "without_pack" => counts["without_pack"],
       "no_attempts" => counts["no_attempts"], "unreadable" => loaded["unreadable"] + counts["malformed"], "undated" => loaded["undated"],
       "groups" => rows, "warning" => self.class.warning(small)}
    end

    private

    def attempts_of(run)
      return [] unless run["steps"].is_a?(Hash)
      run["steps"].values.flat_map { |state| state.is_a?(Hash) ? Array(state["attempts"]).grep(Hash) : [] }
    end

    def delivered(run)
      attempts_of(run).reject { |attempt| WorkflowStats.kind_of(attempt) == :not_delivered }
    end

    def sha_of(value) = (value.is_a?(String) && value.match?(SHA)) ? value : UNKNOWN

    def definition_key(run)
      return run["definition_sha256"].then { |sha| sha_of(sha) } if run["definition_sha256"]
      shas = attempts_of(run).map { |attempt| attempt["definition_sha256"] }.compact.map { |sha| sha_of(sha) }.uniq
      (shas.size > 1) ? MIXED : (shas.first || UNKNOWN)
    end

    def pack_key(run, name)
      list = delivered(run)
      return :none if list.empty?
      recorded = list.select { |attempt| attempt["packs"].is_a?(Array) }
      return UNKNOWN if recorded.empty?
      found = recorded.flat_map { |attempt| attempt["packs"].grep(Hash).select { |pack| pack["ref"] == name || pack["ref"].to_s.split("/", 2).last == name } }
      return :without if found.empty?
      shas = found.map { |pack| sha_of(pack["sha256"]) }.uniq
      (shas.size > 1) ? MIXED : shas.first
    end

    # What one run adds to its group.
    def figures_of(run)
      missed = steps_of(run).any? { |attempts| missed?(attempts, run["state"] == "completed") }
      state = case run["state"]
      when "completed" then :settled
      when "cancelled" then missed ? :settled : :cancelled
      else (missed && STUCK.include?(run.dig("reason", "code"))) ? :stuck : :running
      end
      {state: state, first_try: run["state"] == "completed" && !missed, resumes: @loader.resumes(run).values.sum}
    end

    def steps_of(run)
      return [] unless run["steps"].is_a?(Hash)
      run["steps"].values.map { |state| state.is_a?(Hash) ? Array(state["attempts"]).grep(Hash) : [] }
    end

    # In a completed run an attempt with no outcome was passed over (a `resume --from` later step), not passed: a miss.
    # The engine has stored `outcome` on passed and failed attempts since it first wrote attempts, so an old run is not misread.
    def missed?(attempts, completed)
      delivered = attempts.reject { |attempt| WorkflowStats.kind_of(attempt) == :not_delivered }
      delivered.size > 1 || delivered.any? { |attempt| attempt["outcome"] != "passed" && (completed || !attempt["outcome"].nil?) }
    end

    def row(sha, list)
      settled = list.select { |each| %i[settled stuck].include?(each[:state]) }
      clean = settled.count { |each| each[:first_try] }
      resumes = list.sum { |each| each[:resumes] }
      {"sha" => sha, "runs" => list.size, "settled" => settled.size, "first_try" => clean,
       "pass_first_percent" => settled.empty? ? nil : (clean * 100.0 / settled.size).round,
       "running" => list.count { |each| each[:state] == :running }, "cancelled" => list.count { |each| each[:state] == :cancelled },
       "stuck" => list.count { |each| each[:state] == :stuck },
       "resumes" => resumes, "resumes_per_run" => resumes.fdiv(list.size).round(1)}
    end
  end
end
