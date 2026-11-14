require "digest"

module Workspace
  # What a review round leaves for a person once its verdicts decide it: the engine's own `summary.md` in the
  # round's directory ({#write}: the revision judged, each reviewer's verdict, the rule and the outcome), which a
  # gate after a passing review names as its note ({WorkflowGateNote#find}), and one inbox item per run and step
  # ({#notify}, dedupe key `review:<run>:<step>`), updated and opened again by each round, linking the summary, unless
  # the step's `review.notify` is false. The name `summary` is reserved among reviewers ({WorkflowReviewSpec}) and
  # {ReviewWriteGuard} refuses `summary.md` to every reviewer, so the file is the engine's alone.
  #
  # {#write} runs under the run's lock, as the tally's reads do; {#notify} once the lock is given up
  # ({WorkflowRunChange::Context#after_lock}). Neither raises: a summary that can't be written is a `problem`, an inbox
  # that can't be written is no item.
  class WorkflowReviewSummary
    # How each tally outcome reads in the summary and the inbox item.
    OUTCOME_WORDS = {approved: "approved", rejected: "rejected", incomplete: "not decided", stale: "stale", review_guard: "checkout changed"}.freeze
    private_constant :OUTCOME_WORDS

    # @param inbox_for [#call, nil] given a workspace name, its {InboxStore}; nil posts no item
    # @param files [#directory_problem] checks the round's directory is a plain one ({WorkflowReviewTally::Files})
    def initialize(inbox_for: nil, files: WorkflowReviewTally::Files.new)
      @inbox_for = inbox_for
      @files = files
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
    # @return [Hash{String=>String}] "path" and "sha256" of what was written, or "problem"
    def write(run, round:, outcome:, decided:, reviews:, problem: nil)
      artifacts = run["artifacts_dir"]
      attempt = run["steps"][run["current"]]["attempts"].last["n"]
      return {"problem" => "the run has no artifacts directory"} unless artifacts.is_a?(String) && artifacts.start_with?("/") && round.is_a?(Integer)
      path = self.class.path(artifacts, run["current"], attempt, round)
      found = @files.directory_problem(artifacts, File.dirname(path))
      return {"problem" => "#{File.dirname(path)} is not a plain directory (#{found})"} if found
      text = summary_text(run, attempt, round, outcome, decided, reviews, problem)
      begin
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |file| file.write(text) }
      rescue Errno::EEXIST
        # A decision made again (its change re-run after a failure past the write) finds its own file: the text holds no
        # time, so the same decision writes the same bytes. Anything else there is not the engine's.
        return {"problem" => "#{path} was already there, and is not this round's summary, so it was not written"} unless same_file?(path, text)
      end
      {"path" => path, "sha256" => Digest::SHA256.hexdigest(text)}
    rescue SystemCallError, IOError => e
      {"problem" => "could not write #{path}: #{e.message}"}
    end

    # Upserts the run and step's review item, opening it again when it was resolved. Off when the step's
    # `review.notify` is false.
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
      @inbox_for.call(workspace).upsert({
        "type" => "review_request", "scope" => {"kind" => "workspace", "key" => workspace, "name" => workspace},
        "title" => "Workflow run #{run["id"]}: review of #{step}, round #{round}: #{OUTCOME_WORDS.fetch(outcome, outcome.to_s)}",
        "body" => "#{next_words(run, step, attempt)} #{path ? "The round's summary is #{path}." : "The round's summary could not be written: #{summary["problem"]}."} " \
          "`workspace workflow status #{run["id"]}` shows the run.",
        "source" => {"kind" => "workflow", "ref" => run["id"], "url" => nil},
        "dedupe_key" => "review:#{run["id"]}:#{step}",
        "created_by" => {"kind" => "cli", "pane" => nil, "session_id" => nil, "tmux_server" => nil},
        "links" => {"run_id" => run["id"], "step" => step, "attempt" => attempt, "round" => round, "summary" => path}, "expires_at" => nil, "note" => nil
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

    # What the run does now the round decided, as one sentence.
    def next_words(run, step, attempt)
      reason = run["reason"]
      code = reason.is_a?(Hash) ? reason["code"] : nil
      if code == "waiting_you" && reason.dig("details", "kind") == "gate" && run["current"] == step
        "Step #{step} waits at its gate: read the summary, then `workspace workflow approve #{run["id"]}` or `workspace workflow reject #{run["id"]} --note ...`."
      elsif code
        "The run stopped for a person (#{code})."
      elsif run["current"] == step && run.dig("steps", step, "attempts").to_a.last&.dig("n").to_i > attempt
        "Step #{step} runs again as a new attempt, told what the reviewers wrote."
      elsif WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
        "The run is #{run["state"]}."
      else
        "Step #{step} passed; the run went on."
      end
    end

    def summary_text(run, attempt, round, outcome, decided, reviews, problem)
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
      lines.join("\n") + "\n"
    end

    def one_line(value) = TerminalText.escape(value.to_s)
  end
end
