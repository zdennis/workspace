require "spec_helper"

RSpec.describe Workspace::WorkflowRoundRerun do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:dispatch) { RecordingDispatch.new }
  let(:attempt_record) { RecordingAttemptRecord.new }
  let(:review) { {"step" => "plan", "attempt" => 2, "round" => 2} }

  def rerun(review_revision: nil, holder: nil)
    described_class.new(change: change, store: store, dispatch: dispatch, attempt_record: attempt_record, review_revision: review_revision,
      holder: holder, clock: -> { now })
  end

  def after_rejection(round: {}, review: {"from" => %w[skeptic]})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "state" => "running", "current" => "plan", "reason" => nil,
     "artifacts_dir" => "/tmp/wr_1", "pending_context" => [], "loops" => {},
     "definition" => {"id" => "flow", "redeliver" => 2, "steps" => [{"id" => "plan", "produces" => ["plan.md"], "review" => review}]},
     "steps" => {"plan" => {"state" => "reviewing", "review_rounds" => 2,
                            "review" => {"round" => 2, "delivery" => "delivering", "started_at" => "2026-11-10T11:50:00.000Z"}.merge(round),
                            "attempts" => [{"n" => 1, "outcome" => "failed", "review_outcome" => {"round" => 1, "passed" => false, "revision" => "rev1"}},
                              {"n" => 2, "outcome" => "checks_passed"}]}}}
  end

  def ctx = Workspace::WorkflowRunChange::Context.new("engine")

  describe "#check_revision" do
    it "stops the round review_no_change when its revision is the one the rejection judged, under the lock" do
      store.runs["wr_1"] = after_rejection
      revision = RecordingReviewRevision.new({revision: "rev1", problem: nil})

      checked = rerun(review_revision: revision).check_revision("wr_1", review)

      expect(revision.calls).to eq([[:call, "wr_1", "plan"]])
      expect(checked[:run].reason).to include("code" => "review_no_change")
      expect(store.runs["wr_1"]["reason"]["details"]).to include("rejected_round" => 1, "rejected_attempt" => 1, "revision" => "rev1")
      expect(revision.stop_answers).to eq([false])
    end

    it "answers the computed revision when the author changed what the review reads" do
      store.runs["wr_1"] = after_rejection

      checked = rerun(review_revision: RecordingReviewRevision.new({revision: "rev2", problem: nil})).check_revision("wr_1", review)

      expect(checked).to eq(revision: "rev2")
      expect(change.calls).to be_empty
    end

    it "computes nothing for a round whose revision a person accepted, a rerun carrying its own, a first round, or with no revision reader" do
      revision = RecordingReviewRevision.new({revision: "rev1", problem: nil})
      store.runs["wr_1"] = after_rejection(round: {"accept_revision" => true})
      expect(rerun(review_revision: revision).check_revision("wr_1", review)).to eq({})
      store.runs["wr_1"] = after_rejection.tap { |hash| hash["steps"]["plan"]["attempts"].shift }
      expect(rerun(review_revision: revision).check_revision("wr_1", review)).to eq({})
      store.runs["wr_1"] = after_rejection
      expect(rerun(review_revision: revision).check_revision("wr_1", review.merge("revision" => "rev1"))).to eq({})
      expect(rerun.check_revision("wr_1", review)).to eq({})

      expect(revision.calls).to be_empty
    end

    it "leaves a revision it could not compute to the delivery" do
      store.runs["wr_1"] = after_rejection

      expect(rerun(review_revision: RecordingReviewRevision.new({revision: nil, problem: "exited 1"})).check_revision("wr_1", review)).to eq({})
    end

    it "stops nothing when the run moved on while the revision was computed" do
      store.runs["wr_1"] = after_rejection
      moving = Class.new do
        def initialize(runs) = @runs = runs

        def call(run:, step:, stop_when:)
          @runs["wr_1"]["reason"] = {"code" => "cancelled"}
          {revision: "rev1", problem: nil}
        end
      end.new(store.runs)

      expect(rerun(review_revision: moving).check_revision("wr_1", review)).to eq({})
      expect(store.runs["wr_1"]["steps"]["plan"]["review"]).not_to have_key("no_change")
    end
  end

  describe "#stop_no_change" do
    it "stops the run review_no_change without spending the round, keeping the round named for a resume" do
      delivering = after_rejection(round: {"holder" => {"pid" => 1}})

      run = rerun.stop_no_change(delivering, revision: "rev1", rejected: {"revision" => "rev1", "round" => 1, "attempt" => 1})

      state = run.step("plan")
      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "review_no_change", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 2, "round" => 2, "revision" => "rev1", "rejected_round" => 1, "rejected_attempt" => 1})
      expect(state.to_h["review_rounds"]).to eq(1)
      expect(state.review).to include("round" => 2, "delivery" => nil, "no_change" => true, "revision" => "rev1")
      expect(state.review).not_to have_key("holder")
      expect(dispatch.calls).to eq([[:release, "wr_1"]])
      expect(change.events.map { |event| event[1] }).to eq(%w[review_no_change])
      expect(delivering["steps"]["plan"]["review"]).to have_key("holder")
    end
  end

  describe "#rerun_names" do
    let(:rows) { [{"reviewer" => "a", "counted" => true}, {"reviewer" => "b", "counted" => false, "problem" => "missing"}] }

    it "names the reviewers whose verdicts fell short on their own while the round has a delivery left" do
      run = after_rejection(round: {"redeliveries" => 0})

      expect(rerun.rerun_names(run, run["steps"]["plan"]["review"], {outcome: :incomplete, reviews: rows})).to eq(%w[b])
    end

    it "names none for a decided round, one with no delivery left, or no reviewer to run again" do
      run = after_rejection
      round = run["steps"]["plan"]["review"]

      expect(rerun.rerun_names(run, round, {outcome: :rejected, reviews: rows})).to be_nil
      expect(rerun.rerun_names(run, round.merge("redeliveries" => 99), {outcome: :incomplete, reviews: rows})).to be_nil
      expect(rerun.rerun_names(run, round, {outcome: :incomplete, reviews: rows.first(1)})).to be_nil
    end

    it "names none for a round the sweep interrupted for a time limit, sent or pending" do
      run = after_rejection(round: {"redeliveries" => 0})
      round = run["steps"]["plan"]["review"]

      %w[sent pending].each do |state|
        interrupted = round.merge("sweep" => {"run_interrupt" => {"state" => state, "at" => "2026-11-10T11:59:30Z"}})
        expect(rerun.rerun_names(run, interrupted, {outcome: :incomplete, reviews: rows})).to be_nil
      end
      stale = round.merge("sweep" => {"run_interrupt" => {"state" => "pending", "at" => "2026-11-10T11:00:00Z"}})
      expect(rerun.rerun_names(run, stale, {outcome: :incomplete, reviews: rows})).to eq(%w[b])
    end
  end

  describe "#rerun" do
    it "records the part that ran, keeps the counted rows and registers the round's delivery with its revision" do
      rows = [{"reviewer" => "a", "counted" => true}, {"reviewer" => "b", "counted" => false}]
      given = after_rejection(round: {"revision" => "rev2", "cleared_at" => "x", "redeliveries" => 0})
      context = ctx

      run = rerun(holder: -> { {"pid" => 7} }).rerun(given, reviews: rows, names: %w[b], ctx: context)

      round = run.step("plan").review
      expect(round).to include("delivery" => "delivering", "redeliveries" => 1, "reruns" => 1, "rerun" => %w[b], "pending" => %w[b],
        "reviews" => [rows.first], "uncleared" => true, "holder" => {"pid" => 7})
      expect(round).not_to have_key("cleared_at")
      expect(run.step("plan").last_attempt.to_h["rounds"].last).to include("ended" => "rerun")
      expect(context.review).to eq("step" => "plan", "attempt" => 2, "round" => 2, "revision" => "rev2")
      expect(change.events.map { |event| event[1] }).to eq(%w[review_ended review_rerun])
    end
  end

  describe "#hold" do
    it "stores the delivering process, or drops one when there is none" do
      round = {"holder" => {"pid" => 1}}
      rerun.hold(round)
      expect(round).not_to have_key("holder")
      rerun(holder: -> { {"pid" => 2} }).hold(round)
      expect(round).to eq("holder" => {"pid" => 2})
    end
  end
end
