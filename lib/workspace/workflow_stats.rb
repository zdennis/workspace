require "time"

module Workspace
  # Reads the run files of one workflow, going and finished, into the per-step figures `workflow stats`
  # shows. It reads and writes nothing else: no lock, no daemon, no tmux. A run archived earlier shows only
  # what its file kept, and the archive holds the newest {WorkflowRunStore::ARCHIVE_LIMIT} runs, so a long
  # window may cover fewer runs than were made.
  #
  # An attempt is counted by its stored `outcome`:
  # - `passed` and `failed` are the attempts that ran and ended. `attempts` is `passed + failed`.
  # - `not_delivered` (and an attempt marked `redelivered`, which is an undelivered one typed again) never
  #   reached the agent, so it did no work: it is counted apart and left out of the pass counts, the median
  #   and the tokens.
  # - `unfinished` is any other attempt (no outcome yet because it is still going, or it was replaced
  #   without ending). It is counted apart and left out of everything else.
  #
  # `median_seconds` is the middle `ended_at - started_at` of the `passed` and `failed` attempts that have both
  # times. `resumes` counts the `run_resumed` events in the run's history, each on the step it resumed (the
  # `from` step of a `resume --from`, else the step the run stood at); one with neither is in
  # `unattributed_resumes`. A history is read for every run in the window; a resume does not say whether
  # it followed a failed delivery.
  #
  # Tokens follow {WorkflowBudget}: input, output and cache creation tokens of the main thread, never cache
  # reads or sub-agents. For each run, a step's figure is the sum over the attempts the budget counts: `passed`,
  # `failed` and also `unfinished` ones that ended without an outcome (a cancel, a `resume --from`), so the tokens
  # spent on a cancelled attempt are not lost; not an attempt still going, and not an undelivered one.
  # A run where any of those attempts has a null `usage` is `runs_uncounted` for that step, not a smaller
  # number; `mean` is over `runs_counted` only and is nil when there are none.
  class WorkflowStats
    # @param store [Workspace::WorkflowRunStore] reads the run files and their histories
    # @param clock [#call] returns the current Time
    # @param loader [Workspace::WorkflowRunLoader] the run loading shared with `workflow compare`
    def initialize(store:, clock: -> { Time.now }, loader: WorkflowRunLoader.new(store: store, clock: clock))
      @loader = loader
    end

    # @param workflow [String]
    # @param last [Numeric, nil] see {WorkflowRunLoader#load}
    # @param include [#call, nil] see {WorkflowRunLoader#load}
    # @param loaded [Hash, nil] the answer of {WorkflowRunLoader#load}, when the caller has read it already
    # @return [Hash{String=>Object}] "runs" (how many were read), "unreadable" (files that are no run, plus runs whose
    #   content was the wrong shape), "undated", "steps" (one row per step: "step", "attempts", "passed", "failed",
    #   "not_delivered", "unfinished", "median_seconds", "resumes", "tokens_from_unfinished" (attempts with no outcome whose tokens are in the mean), "tokens" => {"mean", "runs_counted", "runs_uncounted"})
    #   in the order of the newest run's definition then the others, and "unattributed_resumes"
    def read(workflow:, last: nil, include: nil, loaded: nil)
      loaded ||= @loader.load(workflow: workflow, last: last, include: include)
      rows = {}
      unattributed = 0
      malformed = 0
      used = 0
      first_ids = nil
      loaded["runs"].each do |stored|
        raise TypeError, "a run is a Hash" unless stored.is_a?(Hash) || stored.is_a?(WorkflowRun)
        run = WorkflowRun.from_h(stored)
        row_ids = step_ids(run)
        found = tally(run)
        resumes = @loader.resumes(run.to_h)
      rescue NoMethodError, TypeError, ArgumentError, Workspace::Error
        malformed += 1
      else
        used += 1
        first_ids ||= row_ids
        (row_ids + found.keys + resumes.keys).uniq.each { |id| rows[id] ||= blank(id) }
        found.each { |id, tallied| merge(rows[id], tallied) }
        resumes.each { |id, count| id ? rows[id]["resumes"] += count : unattributed += count }
      end
      steps = order(rows, first_ids || []).map { |row| finish(row) }
      {"runs" => used, "unreadable" => loaded["unreadable"] + malformed, "undated" => loaded["undated"], "steps" => steps, "unattributed_resumes" => unattributed}
    end

    # How one attempt counts: `:passed` and `:failed` by its stored outcome, `:not_delivered` for one that never
    # reached the agent (or was typed again), `:unfinished` for anything else.
    #
    # @param attempt [WorkflowRun::Attempt, Hash{String=>Object}]
    # @return [Symbol]
    def self.kind_of(attempt)
      attempt = WorkflowRun::Attempt.from_h(attempt) unless attempt.is_a?(WorkflowRun::Attempt)
      return :not_delivered if attempt.outcome == "not_delivered" || attempt.redelivered == true
      case attempt.outcome
      when "passed" then :passed
      when "failed" then :failed
      else :unfinished
      end
    end

    private

    def order(rows, first)
      (first + rows.keys).uniq.filter_map { |id| rows[id] }
    end

    def blank(id)
      {"step" => id, "attempts" => 0, "passed" => 0, "failed" => 0, "not_delivered" => 0, "unfinished" => 0,
       "durations" => [], "unfinished_tokens" => 0, "resumes" => 0, "token_sums" => [], "runs_uncounted" => 0}
    end

    def merge(row, tallied)
      %w[passed failed not_delivered unfinished].each { |key| row[key] += tallied[key] }
      row["durations"].concat(tallied["durations"])
      row["unfinished_tokens"] += tallied["unfinished_tokens"]
      case tallied["tokens"]
      when Integer then row["token_sums"] << tallied["tokens"]
      when :uncounted then row["runs_uncounted"] += 1
      end
    end

    def finish(row)
      counted = row["token_sums"]
      {"step" => row["step"], "attempts" => row["passed"] + row["failed"], "passed" => row["passed"], "failed" => row["failed"],
       "not_delivered" => row["not_delivered"], "unfinished" => row["unfinished"], "median_seconds" => median(row["durations"]),
       "resumes" => row["resumes"], "tokens_from_unfinished" => row["unfinished_tokens"],
       "tokens" => {"mean" => counted.empty? ? nil : counted.sum.fdiv(counted.size).round, "runs_counted" => counted.size, "runs_uncounted" => row["runs_uncounted"]}}
    end

    def median(values)
      return nil if values.empty?
      sorted = values.sort
      middle = sorted.size / 2
      value = sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]).fdiv(2)
      value.round
    end

    def step_ids(run)
      defined = Array(run.definition&.dig("steps")).grep(Hash).filter_map { |each| each["id"] if each["id"].is_a?(String) }
      (defined + run.steps.keys).uniq
    end

    # Per step id: counts, durations and the run's token figure (an Integer, :uncounted, or nil with nothing finished).
    def tally(run)
      run.steps.to_h do |id, step|
        stored = Array(step.to_h["attempts"])
        attempts = step.attempts.each_with_index.select { |_, index| stored[index].is_a?(Hash) }.map(&:first)
        t = {"passed" => 0, "failed" => 0, "not_delivered" => 0, "unfinished" => 0, "durations" => [], "unfinished_tokens" => 0}
        paid = []
        attempts.each do |attempt|
          kind = kind_of(attempt)
          t[kind.to_s] += 1
          if %i[passed failed].include?(kind)
            seconds = seconds_of(attempt)
            t["durations"] << seconds if seconds
          end
          paid << attempt if tokens_count?(run, id, attempts, attempt, kind)
        end
        t["unfinished_tokens"] = paid.count { |attempt| kind_of(attempt) == :unfinished && WorkflowBudget.tokens_of(attempt.usage) }
        sums = paid.map { |attempt| WorkflowBudget.tokens_of(attempt.usage) }
        t["tokens"] = if paid.empty? then nil
        elsif sums.all? then sums.sum
        else :uncounted
        end
        [id, t]
      end
    end

    # {WorkflowBudget}'s rule, so a run's tokens here match its budget's `used`: every attempt but a not_delivered one,
    # ended without an outcome too (a cancel or `resume --from`), but not the one still going. A redelivered attempt
    # did no work and is also left out.
    def tokens_count?(run, id, attempts, attempt, kind)
      return false unless WorkflowBudget.counted_attempt?(attempt.to_h) && kind != :not_delivered
      going = !WorkflowRunStore::TERMINAL_STATES.include?(run.state) && id == run.current && attempt.equal?(attempts.last) && attempt.outcome.nil?
      !going
    end

    def kind_of(attempt) = self.class.kind_of(attempt)

    def seconds_of(attempt)
      started = @loader.time_of(attempt.started_at)
      ended = @loader.time_of(attempt.ended_at)
      return nil unless started && ended && ended >= started
      ended - started
    end
  end
end
