require "spec_helper"

RSpec.describe Workspace::WorkflowRejection do
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:dispatch) { RecordingDispatch.new(appends: true) }
  let(:log_tail) { RecordingLogTail.new }

  subject(:rejection) { described_class.new(change: change, dispatch: dispatch, log_tail: log_tail) }

  def run_hash(review: {"from" => %w[skeptic builder], "need" => 2, "must" => ["skeptic"], "context" => "continue"})
    {"id" => "wr_1", "workspace" => "app", "worktree" => "/work", "artifacts_dir" => "/work/.workflow/wr_1", "state" => "running", "current" => "design",
     "pending_context" => ["from before"], "reason" => nil, "loops" => {},
     "definition" => {"id" => "flow", "steps" => [{"id" => "design", "produces" => [], "review" => review}]},
     "steps" => {"design" => {"state" => "failed", "review_rounds" => 2, "attempts" => [{"n" => 1}, {"n" => 2, "outcome" => "failed"}]}}}
  end

  let(:reviews) do
    [{"reviewer" => "skeptic", "verdict" => "reject", "counted" => true, "path" => "reviews/design.2.r2/skeptic.md"},
      {"reviewer" => "builder", "verdict" => "approve", "counted" => false, "path" => "reviews/design.2.r2/builder.md"}]
  end

  describe "#retry_for" do
    it "names the round and each verdict in one line, then each counted reviewer's write-up, with the review's context" do
      again = rejection.retry_for(run_hash, attempt: 2, round: 2, decided: {"need" => 2, "must" => ["skeptic"]}, reviews: reviews, max_rounds: 6)

      expect(again).to eq("step" => "design", "attempt" => 2, "round" => 2, "context" => "continue",
        "text" => "Review round 2 of 6 rejected the design step: need 2 of 2 with skeptic; got skeptic reject, builder no counted verdict. " \
                  "Address every reviewer's concern and say how.\n\nthe write-up at /work/.workflow/wr_1/reviews/design.2.r2/skeptic.md")
      expect(log_tail.calls).to eq([[:writeup, "/work/.workflow/wr_1/reviews/design.2.r2/skeptic.md"]])
    end

    it "falls back to the review's need and must when the tally counted none, and writes nothing" do
      before = run_hash

      again = rejection.retry_for(before, attempt: 2, round: 2, decided: {}, reviews: [], max_rounds: 6)

      expect(again["text"]).to start_with("Review round 2 of 6 rejected the design step: need 2 of 2 with skeptic; got skeptic no counted verdict, builder no counted verdict.")
      expect(before).to eq(run_hash)
      expect(change.events).to be_empty
    end
  end

  describe "#start" do
    it "adds the text to the pending context, writes review_retry and dispatches the step retry_of the rejected attempt" do
      given = run_hash
      again = {"step" => "design", "attempt" => 2, "round" => 2, "context" => "continue", "text" => "the verdicts"}
      context = Workspace::WorkflowRunChange::Context.new("engine", "test")

      run = rejection.start(given, again, rounds: {"rounds" => 2, "max_rounds" => 6}, ctx: context)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(run_hash)
      expect(run.pending_context).to eq(["from before", "the verdicts"])
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "review_rejected", context: "continue", budgeted: true, retry_of: {"text" => "the verdicts", "attempt" => 2}}]])
      expect(change.events).to eq([["wr_1", "review_retry", {"step" => "design", "attempt" => 2, "round" => 2, "rounds" => 2, "max_rounds" => 6}]])
      expect(context.delivery).to eq("step" => "design")
    end
  end
end
