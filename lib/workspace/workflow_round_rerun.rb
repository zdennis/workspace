require "time"

module Workspace
  # The part of a review round's life between its first start ({WorkflowProgress}) and its delivery
  # ({WorkflowReviewRound}): whether a round runs again, or does not run at all. Before a round after a rejected one
  # is delivered, its revision is computed with the lock given up ({#check_revision}); the very revision the
  # rejection judged means the author's retry changed nothing reviewed, and the round stops `review_no_change`
  # ({#stop_no_change}). An incomplete round whose missing verdicts each fell short on their own runs only those
  # reviewers again in the same round ({#rerun_names}, {#rerun}). Each round that ends, or a delivery of it that
  # lapses, adds its record to the reviewed attempt ({#with_round}), and each delivery stores the process that makes
  # it ({#hold}).
  #
  # The run-changing methods take the stored run, leave it as it is and return the run afterwards.
  class WorkflowRoundRerun
    # @param change [Workspace::WorkflowRunChange] changes the run under its lock and writes its history
    # @param store [Workspace::WorkflowRunStore] reads the run while a revision is computed with its lock given up
    # @param dispatch [Workspace::WorkflowDispatch] gives up the run's locks when a round stops for a person
    # @param attempt_record [Workspace::WorkflowAttemptRecord] records each round that ends ({WorkflowAttemptRecord#finish_round})
    # @param review_revision [#call, nil] given `run:`, `step:` and `stop_when:`, the revision of what a round judges
    #   now ({WorkflowReviewRevision}); nil computes none, so no round stops `review_no_change`
    # @param holder [#call, nil] answers the process that delivers a round ("pid", "started"); nil stores none
    # @param clock [#call] returns the current Time
    def initialize(change:, store:, dispatch:, attempt_record:, review_revision: nil, holder: nil, clock: -> { Time.now })
      @change = change
      @store = store
      @dispatch = dispatch
      @attempt_record = attempt_record
      @review_revision = review_revision
      @holder = holder
      @clock = clock
    end

    # Checks a round a change registered before it is delivered, with the lock given up. A round after a rejected one
    # ({WorkflowTransitions.rejected_revision}) has its revision computed: the revision the rejection judged stops it
    # `review_no_change` ({#stop_no_change}) under the lock, while the run still waits for that round
    # ({WorkflowTransitions.round_delivery_wanted?}); another one is the revision the delivery judges. Not for a rerun of
    # missing reviewers (it carries its round's revision) or a round a person's resume accepted the revision of.
    #
    # @param run_id [String]
    # @param review [Hash{String=>Object}] the round the change registered ("step", "attempt", "round", "revision")
    # @return [Hash{Symbol=>Object}] :run (the run afterwards) when the round stopped `review_no_change`; else
    #   :revision when one was computed; else empty
    def check_revision(run_id, review)
      return {} if !@review_revision || review["revision"]
      read = @store.run(run_id)
      round = read.step(review["step"])&.review
      return {} unless round.is_a?(Hash) && !round["accept_revision"] && WorkflowTransitions.round_delivery_wanted?(read, review)
      rejected = WorkflowTransitions.rejected_revision(read, review["step"])
      return {} unless rejected
      step = read.definition["steps"].find { |each| each["id"] == review["step"] }
      answer = @review_revision.call(run: read, step: step, stop_when: -> { !still_wanted?(run_id, review) })
      # A revision that can't be computed is the delivery's to report; it computes it again.
      return {} if answer[:problem] || !answer[:revision].is_a?(String)
      return {revision: answer[:revision]} unless answer[:revision] == rejected["revision"]
      stopped = false
      after = @change.call(run_id, actor: "engine") do |current|
        next unless WorkflowTransitions.round_delivery_wanted?(current, review)
        stopped = true
        stop_no_change(current, revision: answer[:revision], rejected: rejected)
      end
      stopped ? {run: after} : {}
    end

    # Stops a round about to judge the very revision the step's last decided round rejected: the author's retry
    # changed nothing reviewed. The round is not spent (the step's `review_rounds` goes back by one), nothing was
    # delivered, and the run stops for a person with `review_no_change`; the round stays named on the step
    # (`no_change`, its revision, no delivery) with its directory, so a resume delivers that same round, accepting the
    # revision ({WorkflowProgress#restart_review}), and `resume --from` or a cancel ends it with no record. The window
    # the rejected round kept stays.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on the round being delivered; left as it is
    # @param revision [String] the revision the round would judge
    # @param rejected [Hash{String=>Object}] the rejected round ("revision", "round", "attempt")
    # @return [WorkflowRun] the run afterwards
    def stop_no_change(run, revision:, rejected:)
      over(run) do |work|
        state = step_state(work)
        round = state["review"]
        details = {"step" => work["current"], "attempt" => state["attempts"].last["n"], "round" => round["round"], "revision" => revision,
                   "rejected_round" => rejected["round"], "rejected_attempt" => rejected["attempt"]}
        state["review_rounds"] = [state["review_rounds"].to_i - 1, 0].max
        state["review"] = round.except("holder").merge("delivery" => nil, "revision" => revision, "no_change" => true)
        event(work, "review_no_change", details)
        @dispatch.release(work)
        work["state"] = "waiting"
        work["reason"] = {"code" => "review_no_change", "since" => now_iso, "details" => details}
      end
    end

    # The reviewers of an incomplete round to run again in the same round ({WorkflowReviewTally.rerun_names}), while
    # the round has a delivery left under the definition's `redeliver`. None for a round the sweep interrupted for a
    # time limit ({WorkflowTransitions.round_interrupted}): its verdicts on disk decide it, or it stops for a person.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on the step being reviewed
    # @param round [Hash{String=>Object}, nil] the step's round
    # @param tally [Hash{Symbol=>Object}] the round's tally (:outcome, :reviews)
    # @return [Array<String>, nil] the names; nil when none is run again
    def rerun_names(run, round, tally)
      return nil unless tally[:outcome] == :incomplete && round.is_a?(Hash) && round["round"].is_a?(Integer)
      return nil if WorkflowTransitions.round_interrupted(round, @clock.call)
      return nil unless round["redeliveries"].to_i < WorkflowDefinition.redeliver(WorkflowRun.from_h(run).definition)
      names = WorkflowReviewTally.rerun_names(tally[:reviews])
      names.empty? ? nil : names
    end

    # Runs only +names+ again in the round, in its directory with its revision: the part that ran is recorded
    # (`ended: rerun`, with every row it read), the counted rows stay on the round as its `reviews`, one of its
    # `redeliveries` is spent, and the delivery is registered on +ctx+ with the round's revision, so the verdicts
    # already written still match it. The window the round ran in is cleared before the line is typed (`uncleared`);
    # the round's checkout snapshot and its `review.uses` stay as they were.
    #
    # @param run [WorkflowRun, Hash{String=>Object}] the stored run, on the step being reviewed; left as it is
    # @param reviews [Array<Hash>] the rows the round's tally read
    # @param names [Array<String>] the reviewers to run again ({#rerun_names})
    # @param ctx [Workspace::WorkflowRunChange::Context] gets the round to deliver
    # @return [WorkflowRun] the run afterwards
    def rerun(run, reviews:, names:, ctx:)
      over(run) do |work|
        state = step_state(work)
        round = state["review"]
        attempt = state["attempts"].last
        details = {"step" => work["current"], "attempt" => attempt["n"], "round" => round["round"]}
        event(work, "review_ended", details.merge("outcome" => "rerun"))
        ended = round.merge("delivery" => nil, "ended_at" => now_iso, "reviews" => reviews)
        state["attempts"][-1] = with_round(work, attempt, ended, "rerun")
        reruns = round["reruns"].to_i + 1
        redeliveries = round["redeliveries"].to_i + 1
        kept = reviews.select { |row| row.is_a?(Hash) && row["counted"] }
        # The rerun clears the window again, so the clear an earlier delivery made is not this rerun's: its own
        # `clear_from` is set as its line goes out. A delivery again of the same line keeps it, since the line an
        # earlier delivery typed after that clear may be the reviewers' turn.
        state["review"] = round.except("holder", "failure", "recompute", "delivered_at", "cleared_at", "clear_from", "kick_at", "ended_at", "recorded", "sweep")
          .merge("delivery" => "delivering", "started_at" => @clock.call.utc.iso8601(3), "redeliveries" => redeliveries, "reruns" => reruns,
            "rerun" => names, "pending" => names, "reviews" => kept, "uncleared" => true)
        hold(state["review"])
        work["state"] = "running"
        work["reason"] = nil
        event(work, "review_rerun", details.merge("reviewers" => names, "rerun" => reruns, "redelivery" => redeliveries))
        ctx.review(details.merge("revision" => round["revision"]).compact)
      end
    end

    # The attempt with the record of a round that ended (or a delivery of it that lapsed) added to its `rounds`:
    # {WorkflowAttemptRecord#finish_round} with how it ended, and the verdict rows the round read when there are any.
    # The verdict copies it made are added to the attempt's `evidence`, after what is there, never in its place.
    #
    # @param run [Hash{String=>Object}] the run being changed
    # @param attempt [Hash{String=>Object}] the reviewed attempt
    # @param round [Hash{String=>Object}] the round as it ended
    # @param how [String] how it ended (`ended`)
    # @return [Hash{String=>Object}] a new attempt
    def with_round(run, attempt, round, how)
      record = @attempt_record.finish_round(run: run, round: round).merge("ended" => how)
      copies = Array(record.delete("evidence"))
      record["reviews"] = round["reviews"] if round["reviews"] && !record.key?("reviews")
      attempt = attempt.merge("rounds" => Array(attempt["rounds"]) + [record])
      copies.empty? ? attempt : attempt.merge("evidence" => Array(attempt["evidence"]) + copies)
    end

    # Stores on +round+ the process that delivers it, so a redelivery leaves a slow delivery that is still alive alone.
    #
    # @param round [Hash{String=>Object}] the round being changed in place
    # @return [void]
    def hold(round)
      holder = @holder&.call
      holder.is_a?(Hash) ? round["holder"] = holder : round.delete("holder")
    end

    private

    def over(run)
      work = WorkflowRun.from_h(run).thawed
      yield work
      WorkflowRun.from_h(work)
    end

    # {WorkflowTransitions.round_delivery_wanted?} read from the store, for the revision command; a run that can't be read is still wanted.
    def still_wanted?(run_id, review)
      WorkflowTransitions.round_delivery_wanted?(@store.run(run_id), review)
    rescue Workspace::Error, SystemCallError
      true
    end

    def event(run, type, data) = @change.event(run, type, data)

    def step_state(run) = run["steps"].fetch(run["current"])

    def now_iso = @clock.call.utc.iso8601
  end
end
