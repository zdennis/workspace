module Workspace
  # What a review round's rejection hands the step's next attempt: the retry ({#retry_for}: one line naming the round
  # and each verdict, then each counted reviewer's write-up as a fenced block, {WorkflowLogTail#writeup}), and its
  # start ({#start}: the text into the run's pending context, a `review_retry` history event written, the step dispatched
  # again as a new attempt `retry_of` the rejected one, with the step's `review.context`). Which limit stops a retry is
  # {WorkflowTransitions.rejection_limit}'s; {WorkflowProgress} decides the round and calls this, and stores the run's
  # `review_retry` key only when a limit stops the retry.
  class WorkflowRejection
    # @param change [Workspace::WorkflowRunChange] writes the run's history
    # @param dispatch [Workspace::WorkflowDispatch] starts the step again
    # @param log_tail [Workspace::WorkflowLogTail] reads each reviewer's write-up
    def initialize(change:, dispatch:, log_tail:)
      @change = change
      @dispatch = dispatch
      @log_tail = log_tail
    end

    # The retry of the rejected step, read from the round's verdict rows. Changes nothing.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the rejected step
    # @param attempt [Integer] the attempt the round rejected
    # @param round [Integer] the round that rejected it
    # @param decided [Hash{String=>Object}] the attempt's `review_outcome` ("need", "must")
    # @param reviews [Array<Hash>] the round's verdict rows ("reviewer", "verdict", "counted", "path" under the run's directory)
    # @param max_rounds [Integer] the step's rounds
    # @return [Hash{String=>Object}] "step", "attempt", "round", "context" (the step's `review.context`) and "text"
    def retry_for(run, attempt:, round:, decided:, reviews:, max_rounds:)
      run = WorkflowRun.from_h(run).to_h
      step = run["definition"]["steps"].find { |each| each["id"] == run["current"] }
      review = WorkflowDefinition.review(step) || {}
      {"step" => run["current"], "attempt" => attempt, "round" => round, "context" => review["context"],
       "text" => text(run, review, round, decided, Array(reviews), max_rounds)}
    end

    # Starts the retry {#retry_for} gave: its text goes to the run's pending context, `review_retry` is written, and
    # the step starts again as a new attempt ({WorkflowDispatch#dispatch}, held there as any attempt is).
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, at the rejected step; left as it is
    # @param again [Hash{String=>Object}] what {#retry_for} answered
    # @param rounds [Hash{String=>Object}] "rounds" and "max_rounds", for the history line
    # @param ctx [Workspace::WorkflowRunChange::Context]
    # @return [WorkflowRun] the run afterwards
    def start(run, again, rounds:, ctx:)
      work = WorkflowRun.from_h(run).thawed
      work["pending_context"] << again["text"]
      @change.event(work, "review_retry", "step" => work["current"], "attempt" => again["attempt"], "round" => again["round"],
        "rounds" => rounds["rounds"], "max_rounds" => rounds["max_rounds"])
      @dispatch.dispatch(work, ctx: ctx, cause: "review_rejected", context: again["context"], retry_of: {"text" => again["text"], "attempt" => again["attempt"]})
    end

    private

    def text(run, review, round, decided, reviews, max_rounds)
      from = Array(review["from"])
      need = decided["need"] || review["need"] || from.size
      must = Array(decided["must"] || review["must"])
      counted = reviews.select { |row| row.is_a?(Hash) && row["counted"] != false && row["verdict"] }
      got = from.map do |name|
        row = counted.find { |each| each["reviewer"] == name }
        "#{name} #{row ? row["verdict"] : "no counted verdict"}"
      end
      line = "Review round #{round} of #{max_rounds} rejected the #{run["current"]} step: need #{need} of #{from.size}" \
        "#{" with #{must.join(" and ")}" if must.any?}; got #{got.join(", ")}. Address every reviewer's concern and say how."
      writeups = counted.filter_map do |row|
        next unless row["path"].is_a?(String) && !row["path"].empty?
        @log_tail.writeup(File.expand_path(row["path"], run["artifacts_dir"]))
      end
      ([line] + writeups).join("\n\n")
    end
  end
end
