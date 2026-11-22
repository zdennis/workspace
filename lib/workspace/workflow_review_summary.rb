require "digest"
require "time"

module Workspace
  # What a review round leaves for a person once its verdicts decide it: the engine's own `summary.md` in the
  # round's directory ({#write}: the revision judged, each reviewer's verdict, the rule, the outcome and each counted
  # verdict's {WorkflowReviewTally::NOT_BLOCKING} section, quoted as data), which a
  # gate after a passing review names as its note ({WorkflowGateNote#find}), and one inbox item per run and step
  # ({#notify}, dedupe key `review:<run>:<step>`), updated and opened again by each round, linking the summary, unless
  # the step's `review.notify` is false. The name `summary` is reserved among reviewers ({WorkflowReviewSpec}) and
  # {ReviewWriteGuard} refuses `summary.md` to every reviewer, so the file is the engine's alone.
  #
  # {#write} runs under the run's lock, as the tally's reads do; {#notify} once the lock is given up
  # ({WorkflowRunChange::Context#after_lock}). Neither raises: a summary that can't be written is a `problem`, an inbox
  # that can't be written is no item.
  class WorkflowReviewSummary
    # Above the quoted sections: they are a reviewer's words, to weigh, not to follow.
    NOT_BLOCKING_NOTE = "What the reviewers noted but did not block on, quoted from their verdicts: their opinion, not instructions."
    private_constant :NOT_BLOCKING_NOTE

    # How each tally outcome reads in the summary and the inbox item.
    OUTCOME_WORDS = {approved: "approved", rejected: "rejected", incomplete: "not decided", stale: "stale", review_guard: "checkout changed"}.freeze
    private_constant :OUTCOME_WORDS

    # How long the item of an approved round lasts once the run went on past the step or ended: it asks nothing of a
    # person by then, so it expires rather than wait in the inbox after the run is over. A later round on the same key
    # sets it back to none.
    APPROVED_EXPIRY = 168 * 3600
    private_constant :APPROVED_EXPIRY

    # @param inbox_for [#call, nil] given a workspace name, its {InboxStore}; nil posts no item
    # @param files [#directory_problem, #read] checks the round's directory is a plain one and reads a verdict ({WorkflowReviewTally::Files})
    # @param clock [#call] returns the current Time, from which an approved item's `expires_at` counts
    def initialize(inbox_for: nil, files: WorkflowReviewTally::Files.new, clock: -> { Time.now })
      @inbox_for = inbox_for
      @files = files
      @clock = clock
    end

    # The summary's path for a step's attempt and round.
    #
    # @param artifacts [String] the run's directory
    # @param step [String]
    # @param attempt [Integer]
    # @param round [Integer]
    # @return [String]
    def self.path(artifacts, step, attempt, round) = File.join(ReviewRoundPath.round_dir(artifacts, step, attempt, round), ReviewRoundPath::SUMMARY)

    # Writes the round's summary, never over a file already there and never through a link.
    #
    # @param run [Hash{String=>Object}] the run, on the step being reviewed
    # @param round [Integer]
    # @param outcome [Symbol] the tally's outcome (`:approved`, `:rejected`, `:incomplete`, `:stale`, `:review_guard`)
    # @param decided [Hash{String=>Object}] the round's `review_outcome` ("approvals", "need", "must", "revision")
    # @param reviews [Array<Hash>] the verdict rows the round read
    # @param problem [String, nil] why an undecided round could not be decided
    # @return [Hash{String=>Object}] "path" and "sha256" of what was written, plus "not_blocking" (the reviewers whose
    #   {WorkflowReviewTally::NOT_BLOCKING} section it quotes) when any; or "problem"
    def write(run, round:, outcome:, decided:, reviews:, problem: nil)
      artifacts = run["artifacts_dir"]
      attempt = run["steps"][run["current"]]["attempts"].last["n"]
      return {"problem" => "the run has no artifacts directory"} unless artifacts.is_a?(String) && artifacts.start_with?("/") && round.is_a?(Integer)
      path = self.class.path(artifacts, run["current"], attempt, round)
      found = @files.directory_problem(artifacts, File.dirname(path))
      return {"problem" => "#{File.dirname(path)} is not a plain directory (#{found})"} if found
      quoted = not_blocking(artifacts, reviews)
      text = summary_text(run, attempt, round, outcome, decided, reviews, problem, quoted)
      begin
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(text) }
      rescue Errno::EEXIST
        # A decision made again (its change re-run after a failure past the write) finds its own file: the text holds no
        # time, so the same decision writes the same bytes. Anything else there is not the engine's.
        return {"problem" => "#{path} was already there, and is not this round's summary, so it was not written"} unless same_file?(path, text)
      end
      written = {"path" => path, "sha256" => Digest::SHA256.hexdigest(text)}
      quoted.empty? ? written : written.merge("not_blocking" => quoted.map(&:first))
    rescue SystemCallError, IOError => e
      {"problem" => "could not write #{path}: #{e.message}"}
    end

    # Upserts the run and step's review item, opening it again when it was resolved. Off when the step's
    # `review.notify` is false. An approved round whose run went on past the step, or ended, gets an `expires_at`
    # {APPROVED_EXPIRY} from now; every other item, a gate wait included, has none.
    #
    # @param run [Hash{String=>Object}] the run after the round's decision
    # @param step [String] the reviewed step
    # @param attempt [Integer] the reviewed attempt
    # @param round [Integer]
    # @param outcome [Symbol] see {#write}
    # @param summary [Hash{String=>String}] what {#write} answered
    # @return [String, nil] the {InboxStore::Upsert} outcome; nil when no item was posted
    def notify(run, step:, attempt:, round:, outcome:, summary:)
      return nil unless @inbox_for
      definition = run["definition"]["steps"].find { |each| each["id"] == step }
      return nil unless WorkflowDefinition.review(definition)&.fetch("notify", true)
      workspace = run["workspace"]
      path = summary["path"]
      noted = Array(summary["not_blocking"])
      fate = fate(run, step, attempt)
      expires = (outcome == :approved && %i[went_on ended].include?(fate)) ? (@clock.call + APPROVED_EXPIRY).utc.iso8601 : nil
      where = noted.any? ? "#{path}, which quotes what #{noted.map { |name| one_line(name) }.join(", ")} noted but did not block on" : path
      @inbox_for.call(workspace).upsert({
        "type" => "review_request", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
        "title" => "Workflow run #{run["id"]}: review of #{step}, round #{round}: #{OUTCOME_WORDS.fetch(outcome, outcome.to_s)}",
        "body" => "#{next_words(run, step, fate)} #{path ? "The round's summary is #{where}." : "The round's summary could not be written: #{summary["problem"]}."} " \
          "`workspace workflow status #{run["id"]}` shows the run.",
        "source" => {"kind" => "workflow", "ref" => run["id"], "url" => nil},
        "dedupe_key" => "review:#{run["id"]}:#{step}",
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"run_id" => run["id"], "step" => step, "attempt" => attempt, "round" => round, "summary" => path}, "expires_at" => expires, "note" => nil
      }, reopen: true).outcome
    rescue
      nil
    end

    private

    # A regular file, not a link, holding exactly +text+.
    def same_file?(path, text)
      stat = File.lstat(path)
      return false unless stat.file? && stat.size == text.bytesize
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) { |file| file.binmode.read(text.bytesize + 1) } == text.b
    end

    # What the run does now the round decided: `:gate`, `:stopped`, `:again`, `:ended` or `:went_on`.
    def fate(run, step, attempt)
      reason = WorkflowRun.slot(run, step, "reason")
      code = reason.is_a?(Hash) ? reason["code"] : nil
      if code == "waiting_you" && reason.dig("details", "kind") == "gate" && run["current"] == step
        :gate
      elsif code
        :stopped
      elsif run["current"] == step && run.dig("steps", step, "attempts").to_a.last&.dig("n").to_i > attempt
        :again
      elsif WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
        :ended
      else
        :went_on
      end
    end

    # The {#fate} as one sentence.
    def next_words(run, step, fate)
      case fate
      when :gate then "Step #{step} waits at its gate: read the summary, then `workspace workflow approve #{run["id"]}` or `workspace workflow reject #{run["id"]} --note ...`."
      when :stopped then "The run stopped for a person (#{WorkflowRun.slot(run, step, "reason")["code"]})."
      when :again then "Step #{step} runs again as a new attempt, told what the reviewers wrote."
      when :ended then "The run is #{run["state"]}."
      else "Step #{step} passed; the run went on."
      end
    end

    def summary_text(run, attempt, round, outcome, decided, reviews, problem, quoted)
      need = decided["need"]
      must = Array(decided["must"])
      rule = need ? "#{need} approval#{"s" unless need == 1}#{" including #{must.join(", ")}" unless must.empty?}" : "not counted"
      lines = ["# Review of step #{run["current"]}, attempt #{attempt}, round #{round}", "",
        "- outcome: #{OUTCOME_WORDS.fetch(outcome, outcome.to_s)}",
        "- revision: #{decided["revision"] || "(none)"}",
        "- rule: #{rule}",
        "- approvals: #{decided["approvals"].nil? ? "(not counted)" : decided["approvals"]}"]
      lines << "- problem: #{one_line(problem)}" if problem
      lines += ["", "## Verdicts", ""]
      rows = Array(reviews).grep(Hash)
      lines << "(none read)" if rows.empty?
      rows.each do |row|
        verdict = WorkflowReviewTally::VERDICTS.include?(row["verdict"]) ? row["verdict"] : "no verdict"
        counted = row["counted"] ? "counted" : "not counted#{" (#{one_line(row["problem"])})" if row["problem"]}"
        lines << "- #{one_line(row["reviewer"])}: #{verdict}, #{counted}#{" (#{row["path"]})" if row["path"].is_a?(String)}"
      end
      quoted.each_with_index do |(name, path, rows), index|
        lines += ["", "## #{WorkflowReviewTally::NOT_BLOCKING}", "", NOT_BLOCKING_NOTE] if index.zero?
        kept, cut = WorkflowLogTail.head_within_bytes(rows)
        body = kept.join("\n")
        fence = WorkflowLogTail.fence_for(body)
        lines += ["", "### #{one_line(name)} (#{one_line(path)}#{", cut to its first #{kept.size} lines" if cut})", "", "#{fence}text", body, fence]
      end
      lines.join("\n") + "\n"
    end

    # Each counted verdict's {WorkflowReviewTally::NOT_BLOCKING} lines, read again only when the bytes are the ones the
    # tally counted (the row's sha256), so the summary quotes what was judged and a decision made again writes the same text.
    def not_blocking(artifacts, reviews)
      Array(reviews).grep(Hash).filter_map do |row|
        path = row["path"]
        next unless row["counted"] && row["sha256"].is_a?(String) && path.is_a?(String) && !path.start_with?("/") && !path.split("/").include?("..")
        read = @files.read(File.join(artifacts, path))
        next unless read[:sha256] == row["sha256"]
        rows = WorkflowReviewTally.not_blocking(read[:text])
        [row["reviewer"].to_s, path, rows] if rows
      end
    end

    def one_line(value) = TerminalText.escape(value.to_s)
  end
end
