module Workspace
  # Joins {WorkflowStats}, {WorkflowCompare} and the stored run hashes of a workflow's newest runs into the sections
  # `workflow insights` prints: hot steps, recurring review rejections, failures, holds and effects. It reads the run
  # files and their `run_resumed` events through the loader and nothing else: never a reviewer's `path`, `summary` or
  # `pending_context`, an evidence file or a `summary.md`. Its output is counts, run ids, step ids, reviewer names and
  # codes only. A code or reviewer name comes from stored text, so it is cut to {MAX_CODE} characters and otherwise
  # left as it was read; the caller escapes it for a terminal.
  class WorkflowInsights
    # Runs read when the caller names no count.
    DEFAULT_RUNS = 20

    # Runs (read, not stored) needed before the rankings mean anything.
    MIN_RUNS = 3

    # Distinct runs a rejection key needs to be a theme; fewer make it an observation.
    THEME_MIN_RUNS = 3

    # Most pack names `effects` compares, by how many runs carry each.
    MAX_PACKS = 5

    # Longest code or reviewer name kept, in characters.
    MAX_CODE = 64

    # Reason codes that make a hold.
    HOLD_CODES = %w[budget_spent run_timed_out failed_check].freeze

    # @param loader [Workspace::WorkflowRunLoader]
    # @param stats [Workspace::WorkflowStats]
    # @param compare [Workspace::WorkflowCompare]
    def initialize(loader:, stats:, compare:)
      @loader = loader
      @stats = stats
      @compare = compare
    end

    # Reads the workflow's runs once, keeps the newest +runs+ and builds every section from them. Each run's resumes
    # are read once and shared by the stats and compare readers.
    #
    # @param workflow [String]
    # @param runs [Integer] how many of the newest runs to read
    # @param last [Numeric, nil] see {WorkflowRunLoader#load}
    # @param include [#call, nil] see {WorkflowRunLoader#load}
    # @return [Hash{String=>Object}] "runs" (read), "stored" (runs of this workflow before narrowing to +runs+),
    #   "unreadable" (stats' figure: the whole store's unreadable files plus runs of the wrong shape), "undated",
    #   "enough" (runs >= {MIN_RUNS}), "hot_steps" (stats' step rows plus "retry_run_ids", "resume_run_ids" and
    #   "token_run_ids"; ranked by retry runs, median, then tokens when enough), "themes" and "observations" (rows of
    #   "step", "reviewer", "verdict", "problem", "count" and "run_ids"; a theme spans {THEME_MIN_RUNS} distinct runs
    #   or more), "failures" and "holds" (rows of "step", "code", "count", "run_ids") and "effects" (compare results
    #   by "definition", "version" and each "pack:NAME")
    def read(workflow:, runs: DEFAULT_RUNS, last: nil, include: nil)
      loaded = @loader.load(workflow: workflow, last: last, include: include)
      stored = loaded["runs"].size
      narrowed = loaded.merge("runs" => loaded["runs"].first(runs))
      memo = {}
      resumes = ->(run) { memo[run.id] ||= @loader.resumes(run) }
      stats = @stats.read(workflow: workflow, loaded: narrowed, resumes: resumes)
      found = scan(narrowed["runs"], resumes)
      enough = stats["runs"] >= MIN_RUNS
      themes, observations = rejections(found[:rejections]).partition { |row| row["run_ids"].size >= THEME_MIN_RUNS }
      {"runs" => stats["runs"], "stored" => stored, "unreadable" => stats["unreadable"], "undated" => stats["undated"], "enough" => enough,
       "hot_steps" => hot_steps(stats["steps"], found, enough), "themes" => themes, "observations" => observations,
       "failures" => coded(found[:failures]), "holds" => coded(found[:holds]),
       "effects" => effects(workflow, narrowed, found[:packs], resumes)}
    end

    private

    def scan(runs, resumes)
      found = {retry: Hash.new { |h, k| h[k] = [] }, resume: Hash.new { |h, k| h[k] = [] }, token: Hash.new { |h, k| h[k] = [] },
               rejections: {}, failures: {}, holds: {}, packs: Hash.new(0)}
      runs.each do |stored|
        run = WorkflowRun.from_h(stored)
        one = one_run(run, resumes)
      rescue NoMethodError, TypeError, ArgumentError, Workspace::Error
        next
      else
        one[:retry].each { |step| found[:retry][step] << run.id }
        one[:resume].each { |step| found[:resume][step] << run.id }
        one[:token].each { |step| found[:token][step] << run.id }
        %i[rejections failures holds].each do |kind|
          one[kind].each { |key, count| add(found[kind], key, count, run.id) }
        end
        one[:packs].each { |name| found[:packs][name] += 1 }
      end
      found
    end

    def add(table, key, count, id)
      entry = (table[key] ||= {count: 0, run_ids: []})
      entry[:count] += count
      entry[:run_ids] << id unless entry[:run_ids].include?(id)
    end

    def one_run(run, resumes)
      one = {retry: [], resume: [], token: [], rejections: Hash.new(0), failures: Hash.new(0), holds: Hash.new(0), packs: []}
      one[:resume] = resumes.call(run).select { |step, count| step && count.positive? }.keys
      Array(run.reasons).grep(Hash).each { |reason| hold(one, run_step(reason), reason) }
      run.steps.each do |id, step|
        stored = Array(step.to_h["attempts"])
        attempts = step.attempts.each_with_index.select { |_, index| stored[index].is_a?(Hash) }.map(&:first)
        delivered = attempts.reject { |attempt| WorkflowStats.kind_of(attempt) == :not_delivered }
        one[:retry] << id if delivered.size > 1 || attempts.any?(&:retry_of)
        paid = attempts.select { |attempt| WorkflowStats.tokens_count?(run, id, attempts, attempt) }
        one[:token] << id if !paid.empty? && paid.all? { |attempt| WorkflowBudget.attempt_tokens(attempt) }
        attempts.each do |attempt|
          failure(one, id, attempt)
          Array(attempt.reasons).grep(Hash).each { |reason| hold(one, id, reason) }
          Array(attempt.rounds).grep(Hash).each { |round| review(one, id, round) }
          Array(attempt.packs).grep(Hash).each { |pack| name = pack_name(pack["ref"]) and one[:packs] << name }
        end
      end
      one[:packs] = one[:packs].uniq
      one
    end

    def run_step(reason) = reason["step"].is_a?(String) ? cut(reason["step"]) : nil

    def failure(one, step, attempt)
      code = cut(attempt.code)
      one[:failures][[cut(step), code]] += 1 if attempt.outcome == "failed" && code
    end

    def hold(one, step, reason)
      code = reason["code"]
      one[:holds][[cut(step), code]] += 1 if step && HOLD_CODES.include?(code)
    end

    def review(one, step, round)
      Array(round["reviews"]).grep(Hash).each do |row|
        reviewer = cut(row["reviewer"])
        next unless reviewer
        one[:rejections][[cut(step), reviewer, "reject", nil]] += 1 if row["verdict"] == "reject" && row["counted"] != false
        problem = cut(row["problem"])
        one[:rejections][[cut(step), reviewer, nil, problem]] += 1 if problem
      end
    end

    def cut(value) = (value.is_a?(String) && !value.empty?) ? value[0, MAX_CODE] : nil

    def pack_name(ref)
      name = ref.to_s.split("/", 2).last
      name if name&.match?(/\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,99}\z/)
    end

    def rejections(table)
      rows = table.map do |(step, reviewer, verdict, problem), entry|
        {"step" => step, "reviewer" => reviewer, "verdict" => verdict, "problem" => problem, "count" => entry[:count], "run_ids" => entry[:run_ids]}
      end
      rows.sort_by { |row| [-row["run_ids"].size, -row["count"], row["step"], row["reviewer"], row["verdict"].to_s, row["problem"].to_s] }
    end

    def coded(table)
      table.map { |(step, code), entry| {"step" => step, "code" => code, "count" => entry[:count], "run_ids" => entry[:run_ids]} }
        .sort_by { |row| [-row["run_ids"].size, -row["count"], row["step"], row["code"]] }
    end

    def hot_steps(rows, found, enough)
      rows = rows.map do |row|
        id = row["step"]
        row.merge("retry_run_ids" => found[:retry][id], "resume_run_ids" => found[:resume][id], "token_run_ids" => found[:token][id])
      end
      return rows unless enough
      rows.each_with_index.sort_by do |row, index|
        [-row["retry_run_ids"].size, -(row["median_seconds"] || -1), -(row.dig("tokens", "mean") || -1), index]
      end.map(&:first)
    end

    def effects(workflow, loaded, packs, resumes)
      names = packs.sort_by { |name, count| [-count, name] }.first(MAX_PACKS).map(&:first)
      %w[definition version].concat(names.map { |name| "pack:#{name}" }).to_h do |by|
        [by, @compare.read(workflow: workflow, by: by, loaded: loaded, resumes: resumes)]
      end
    end
  end
end
