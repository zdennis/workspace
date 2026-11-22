require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowDispatch, "prewarm" do
  around do |example|
    Dir.mktmpdir("wf-dispatch-prewarm") do |dir|
      @dir = dir
      example.run
    end
  end

  # Stands in for WorkflowReviewRound's warm window: records each call; +close_warm+ answers the run it was given.
  let(:warm_class) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def close_warm(run)
        @calls << [:close_warm, run.id]
        run
      end

      def prewarm(run, step_id, attempt)
        @calls << [:prewarm, run.id, step_id, attempt]
        nil
      end
    end
  end
  let(:warm) { warm_class.new }
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:panes) { RecordingWorkflowPanes.new }
  let(:review) { {"from" => %w[skeptic], "need" => 1} }
  let(:steps) { [{"id" => "plan", "prompt" => "Plan.", "produces" => ["plan.md"], "review" => review}, {"id" => "build", "prompt" => "Build.", "produces" => []}] }

  def build_dispatch(prewarm: warm, panes: self.panes)
    described_class.new(change: change, store: store, resources: RecordingRunResources.new, panes: panes, prompt: RecordingWorkflowPrompt.new(text: "the instructions"),
      attempt_record: RecordingAttemptRecord.new, guard: instance_double(Workspace::WorkflowGuard), clock: -> { now }, prewarm: prewarm)
  end

  def run_hash(current: "plan", step_states: {})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => @dir, "state" => "waiting",
     "current" => current, "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => nil,
     "definition" => {"id" => "flow", "steps" => steps},
     "steps" => {"plan" => {"state" => "pending", "attempts" => []}, "build" => {"state" => "pending", "attempts" => []}}.merge(step_states)}
  end

  def ctx = Workspace::WorkflowRunChange::Context.new("engine", "test")

  describe "registration at #dispatch" do
    it "registers the follow-up for a step with review:, naming the attempt" do
      context = ctx
      build_dispatch.dispatch(run_hash, ctx: context, cause: "first")
      expect(context.prewarm).to eq("step" => "plan", "attempt" => 1)
    end

    it "registers none for a step with no review: while no other step keeps a warm window" do
      context = ctx
      build_dispatch.dispatch(run_hash(current: "build"), ctx: context, cause: "next_step")
      expect(context.delivery).to include("step" => "build")
      expect(context.prewarm).to be_nil
    end

    it "registers one for a step with no review: when another step keeps a warm window, so the follow-up closes it" do
      context = ctx
      plan = {"state" => "passed", "attempts" => [{"n" => 1}], "review_window" => {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true}}
      build_dispatch.dispatch(run_hash(current: "build", step_states: {"plan" => plan}), ctx: context, cause: "next_step")
      expect(context.prewarm).to eq("step" => "build", "attempt" => 1)
    end

    it "registers none without a prewarm collaborator" do
      context = ctx
      build_dispatch(prewarm: nil).dispatch(run_hash, ctx: context, cause: "first")
      expect(context.delivery).to include("step" => "plan")
      expect(context.prewarm).to be_nil
    end

    it "registers none for a fan_out sibling" do
      steps.replace([{"id" => "plan", "group" => "g", "prompt" => "Plan.", "produces" => [], "review" => review},
        {"id" => "build", "group" => "g", "prompt" => "Build.", "produces" => []}])
      context = ctx
      build_dispatch.dispatch(run_hash, ctx: context, cause: "first")
      expect(context.deliveries).not_to be_empty
      expect(context.prewarm).to be_nil
    end

    it "registers one for a fan_out sibling when another step keeps a warm window, so the follow-up closes it" do
      steps.replace([{"id" => "plan", "prompt" => "Plan.", "produces" => [], "review" => review},
        {"id" => "a", "group" => "g", "prompt" => "A.", "produces" => []}, {"id" => "b", "group" => "g", "prompt" => "B.", "produces" => []}])
      plan = {"state" => "passed", "attempts" => [{"n" => 1}], "review_window" => {"round" => 1, "window" => "@7", "pane" => "%7", "warm" => true}}
      hash = run_hash(current: "a", step_states: {"plan" => plan, "a" => {"state" => "pending", "attempts" => []}, "b" => {"state" => "pending", "attempts" => []}})
      context = ctx
      build_dispatch.dispatch(hash, ctx: context, cause: "next_step")
      expect(context.deliveries).not_to be_empty
      expect(context.prewarm).to include("step" => "a")
    end

    it "registers none for a step that could not start" do
      context = ctx
      build_dispatch.dispatch(run_hash.merge("worktree" => File.join(@dir, "gone")), ctx: context, cause: "first")
      expect(context.delivery).to be_nil
      expect(context.prewarm).to be_nil
    end
  end

  describe "#prewarm" do
    let(:delivery) { {"step" => "plan", "attempt" => 1, "workspace" => "app", "pane" => "%3", "text" => "Read it.", "fresh" => false, "worktree" => @dir, "cause" => "first"} }

    def delivering(attempt = {})
      run_hash(step_states: {"plan" => {"state" => "running", "attempts" => [{"n" => 1, "context" => [], "delivery" => "delivering"}.merge(attempt)]}}).merge("state" => "running")
    end

    it "closes other steps' warm windows, then opens the step's, once the author's line was typed" do
      store.runs["wr_1"] = delivering
      dispatch = build_dispatch
      dispatch.deliver("wr_1", delivery)

      dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})

      expect(warm.calls).to eq([[:close_warm, "wr_1"], [:prewarm, "wr_1", "plan", 1]])
    end

    it "opens none when the author's line was not typed, closing the others' still" do
      store.runs["wr_1"] = delivering
      dispatch = build_dispatch(panes: RecordingWorkflowPanes.new(kick: {ok: false, code: "pane_busy", message: "busy"}))
      dispatch.deliver("wr_1", delivery)
      expect(store.runs["wr_1"]["steps"]["plan"]["attempts"].last["outcome"]).to eq("not_delivered")

      dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})

      expect(warm.calls).to eq([[:close_warm, "wr_1"]])
    end

    it "opens none when the run is cancelled while the others' windows are closed" do
      store.runs["wr_1"] = delivering
      dispatch = build_dispatch
      dispatch.deliver("wr_1", delivery)
      runs = store.runs
      allow(warm).to receive(:close_warm) do |run|
        runs["wr_1"]["state"] = "cancelled"
        run
      end

      dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})

      expect(warm.calls).to be_empty
    end

    it "opens none while the line is still on its way" do
      store.runs["wr_1"] = delivering
      build_dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})
      expect(warm.calls).to eq([[:close_warm, "wr_1"]])
    end

    it "opens none for a line a pause kept untyped" do
      store.runs["wr_1"] = delivering.merge("paused" => {"at" => "2026-11-10T11:59:00Z"})
      dispatch = build_dispatch
      dispatch.deliver("wr_1", delivery)

      dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})

      expect(warm.calls).to eq([[:close_warm, "wr_1"]])
    end

    it "opens none when the run moved past the attempt" do
      store.runs["wr_1"] = run_hash(step_states: {"plan" => {"state" => "running", "attempts" => [{"n" => 1}, {"n" => 2}]}})
      build_dispatch.prewarm("wr_1", {"step" => "plan", "attempt" => 1})
      expect(warm.calls).to eq([[:close_warm, "wr_1"]])
    end

    it "opens none for a step with no review:" do
      store.runs["wr_1"] = run_hash(current: "build", step_states: {"build" => {"state" => "running", "attempts" => [{"n" => 1}]}})
      build_dispatch.prewarm("wr_1", {"step" => "build", "attempt" => 1})
      expect(warm.calls).to eq([[:close_warm, "wr_1"]])
    end

    it "does nothing without a prewarm collaborator" do
      store.runs["wr_1"] = run_hash(step_states: {"plan" => {"state" => "running", "attempts" => [{"n" => 1}]}})
      expect { build_dispatch(prewarm: nil).prewarm("wr_1", {"step" => "plan", "attempt" => 1}) }.not_to raise_error
      expect(warm.calls).to be_empty
    end
  end
end
