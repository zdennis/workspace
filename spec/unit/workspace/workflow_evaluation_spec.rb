require "spec_helper"
require "tmpdir"

RSpec.describe Workspace::WorkflowEvaluation do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:dir) { Dir.mktmpdir("evaluation") }
  let(:artifacts) { File.join(dir, ".workflow", "wr_1") }
  let(:store) { RecordingRunStore.new }
  let(:change) { RecordingRunChange.new(store.runs) }
  let(:progress) { RecordingProgress.new }
  let(:panes) { RecordingWorkflowPanes.new(bound: {"wr_1" => "%3"}) }
  let(:checker) { RecordingChecker.new }
  let(:require_check) { RecordingRequire.new }
  let(:guard) { RecordingGuard.new }
  let(:commands) { RecordingCommandsConfig.new(test: "rake test") }
  let(:inbox) { RecordingInbox.new }

  after { FileUtils.rm_rf(dir) }

  def evaluation(**overrides)
    described_class.new(change: change, store: store, progress: progress, panes: panes, checker: checker, require_check: require_check,
      guard: guard, commands_config: commands, inbox_for: ->(_workspace) { inbox }, clock: -> { now }, **overrides)
  end

  def step(**overrides)
    {"id" => "plan", "produces" => ["plan.md"]}.merge(overrides)
  end

  def run_hash(definition_step: step, state: "running", **overrides)
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "project" => "app", "worktree" => dir, "artifacts_dir" => artifacts,
     "state" => "running", "current" => "plan", "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => nil,
     "definition" => {"id" => "flow", "max_attempts" => 5, "steps" => [definition_step]},
     "steps" => {"plan" => {"state" => state, "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00.000Z"}]}}}.merge(overrides)
  end

  def stored(hash = run_hash)
    store.runs["wr_1"] = hash
  end

  def produce(name = "plan.md", at: now)
    FileUtils.mkdir_p(artifacts)
    path = File.join(artifacts, name)
    File.write(path, "done\n")
    File.utime(at, at, path)
    path
  end

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def ctx = Workspace::WorkflowRunChange::Context.new("engine")

  describe "#report" do
    it "stores the agent's report on the attempt and answers a Reported value" do
      stored

      reported = evaluation.report("wr_1", actor: "agent", status: "fail", summary: "tests fail", code: "flaky")

      expect(reported).to be_a(described_class::Reported)
      expect(reported).to be_frozen
      expect(reported.to_h).to eq(run_id: "wr_1", step: "plan", attempt: 1,
        reported: {"status" => "fail", "summary" => "tests fail", "code" => "flaky", "at" => "2026-11-10T12:00:00Z"})
      expect(store.runs["wr_1"]["steps"]["plan"]["attempts"].last["reported"]).to eq(reported.reported)
      expect(change.events).to eq([["wr_1", "step_reported", {"step" => "plan", "attempt" => 1, "status" => "fail"}]])
    end

    it "leaves out a code the agent did not give" do
      stored

      expect(evaluation.report("wr_1", actor: "agent", status: "pass").reported).to eq("status" => "pass", "summary" => nil, "at" => "2026-11-10T12:00:00Z")
    end

    it "refuses a step that is not being worked on" do
      stored(run_hash(state: "passed"))

      expect { evaluation.report("wr_1", actor: "agent", status: "pass") }.to raise_error(Workspace::Error) { |error|
        expect(error.code).to eq("step_not_running")
        expect(error.details).to eq("run_id" => "wr_1", "step" => "plan", "state" => "passed")
      }
      expect(change.events).to be_empty
    end

    it "refuses a step being reviewed, since its attempt has ended" do
      stored(run_hash(state: "reviewing"))

      expect { evaluation.report("wr_1", actor: "agent", status: "pass") }.to raise_error(Workspace::Error) { |error| expect(error.code).to eq("step_not_running") }
    end
  end

  describe "#turn_ended" do
    it "decides nothing for a parked run, another pane, or a turn that began before the attempt" do
      stored(run_hash("parked" => {"id" => "p1"}))
      expect(evaluation.turn_ended("wr_1", actor: "agent")).to be_a(Workspace::WorkflowRun)
      stored
      evaluation.turn_ended("wr_1", actor: "agent", pane: "%9")
      evaluation.turn_ended("wr_1", actor: "agent", turn_started: Time.utc(2026, 11, 10, 10))
      evaluation.turn_ended("wr_1", actor: "agent", stopped_at: Time.utc(2026, 11, 10, 10))

      expect(store.runs["wr_1"]["reason"]).to be_nil
      expect(progress.calls).to be_empty
    end

    it "follows up a review round the passing step registered, once the change is done" do
      rounds = []
      stored
      produce
      progress = RecordingProgress.new(review: {"round" => 1})

      evaluation(progress: progress, review_round: ->(run_id, review) { rounds << [run_id, review] && nil }).turn_ended("wr_1", actor: "agent")

      expect(progress.calls).to eq([[:pass_step, "plan"]])
      expect(rounds).to eq([["wr_1", {"round" => 1}]])
    end

    it "holds the step on turn_ended_incomplete when a file it produces is missing" do
      stored

      run = evaluation.turn_ended("wr_1", actor: "agent", pane: "%3")

      expect(run.state).to eq("waiting")
      expect(run.reason).to eq("code" => "turn_ended_incomplete", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "plan", "attempt" => 1, "missing" => [File.join(artifacts, "plan.md")], "stale" => []})
      expect(run.step("plan").state).to eq("running")
    end

    it "counts a file an earlier attempt left as stale" do
      stored
      path = produce(at: Time.utc(2026, 11, 10, 10))

      expect(evaluation.turn_ended("wr_1", actor: "agent").reason["details"]).to include("missing" => [], "stale" => [path])
    end

    it "holds a turn that ended with background tasks on turn_ended_background" do
      stored

      run = evaluation.turn_ended("wr_1", actor: "agent", background: [{"id" => "b1", "type" => "bash"}])

      expect(run.reason).to include("code" => "turn_ended_background", "seen_at" => "2026-11-10T12:00:00Z")
      expect(run.reason["details"]["tasks"]).to eq([{"id" => "b1", "type" => "bash"}])
    end

    it "fails the step with the agent's word when it reported fail" do
      stored(run_hash.tap { |run| run["steps"]["plan"]["attempts"].last["reported"] = {"status" => "fail", "summary" => "no", "code" => "flaky"} })

      run = evaluation.turn_ended("wr_1", actor: "agent")

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "reported", "summary" => "no", "code" => "flaky", "code_source" => "agent"}]])
      expect(run.step("plan").state).to eq("failed")
    end

    it "passes a step with its files and no status check" do
      stored
      produce

      run = evaluation.turn_ended("wr_1", actor: "agent")

      expect(progress.calls).to eq([[:pass_step, "plan"]])
      expect(run.step("plan").state).to eq("passed")
      expect(checker.calls).to be_empty
    end

    it "runs the status check outside the lock and passes the step when it exits 0" do
      stored(run_hash(definition_step: step("status" => {"command" => "test", "timeout" => 60})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")

      run = evaluation.turn_ended("wr_1", actor: "agent")

      expect(change.calls.size).to eq(2)
      expect(checker.calls).to eq([[:call, {command: "rake test", cwd: dir, timeout: 60, log: log, env: Workspace::WorkflowCheck.env_for(run)}]])
      expect(checker.stop_answers).to eq([false])
      expect(commands.calls).to eq([[:for_project, "app"]])
      expect(run.step("plan").last_attempt.check).to eq("started_at" => "2026-11-10T12:00:00Z", "log" => log, "command" => "rake test",
        "ended_at" => "2026-11-10T12:00:00Z", "exit_code" => 0, "timed_out" => false)
      expect(change.events).to eq([["wr_1", "check_finished", {"step" => "plan", "attempt" => 1, "exit_code" => 0}]])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "fails the step on a failed check, with the code its log names when the step lets it" do
      stored(run_hash(definition_step: step("status" => {"run" => "make check", "report_code" => true})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "lots of output\ncode: plan_edited\n\n")
      checker = RecordingChecker.new(result: {exit_code: 1, timed_out: false, error: nil})

      evaluation(checker: checker).turn_ended("wr_1", actor: "agent")

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "check", "exit_code" => 1, "timed_out" => false, "log" => log,
                                                          "code" => "plan_edited", "code_source" => "check"}]])
    end

    it "keeps the engine's code when the log names one the engine hands out itself" do
      stored(run_hash(definition_step: step("status" => {"run" => "make check", "report_code" => true})))
      produce
      log = File.join(artifacts, "steps", "plan.1.check.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, "code: check_timed_out\n")

      evaluation(checker: RecordingChecker.new(result: {exit_code: 2, timed_out: false, error: nil})).turn_ended("wr_1", actor: "agent")

      expect(progress.calls.last[2]).to include("code" => "check_failed", "code_source" => "engine")
    end

    it "fails the step without running anything when the project's command is not set" do
      stored(run_hash(definition_step: step("status" => {"command" => "lint"})))
      produce

      evaluation(commands_config: RecordingCommandsConfig.new).turn_ended("wr_1", actor: "agent")

      expect(checker.calls).to be_empty
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "check", "timed_out" => false, "error" => "the project's lint command is not set",
                                                          "log" => File.join(artifacts, "steps", "plan.1.check.log"), "code" => "check_error", "code_source" => "engine"}]])
    end
  end

  describe "a step being reviewed" do
    let(:tally) { RecordingReviewTally.new(outcome: :approved, reviews: [{"reviewer" => "skeptic"}]) }
    let(:round) { {"round" => 1, "delivery" => nil, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "pending" => ["skeptic"], "redeliveries" => 0} }

    def reviewing(**overrides)
      run_hash(definition_step: step("review" => {"from" => ["skeptic"]}), state: "reviewing", **overrides).tap do |hash|
        hash["steps"]["plan"]["review"] = round
        hash["steps"]["plan"]["attempts"][0].merge!("ended_at" => "2026-11-10T11:20:00Z", "outcome" => "checks_passed")
      end
    end

    it "decides the round when the review pane's turn ends, through the tally" do
      stored(reviewing)

      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 31))

      expect(tally.calls).to eq([[:call, "wr_1", "plan", round]])
      expect(progress.calls).to eq([[:decide_review, "plan", {outcome: :approved, reviews: [{"reviewer" => "skeptic"}]}]])
      expect(store.runs["wr_1"]["steps"]["plan"]["state"]).to eq("passed")
    end

    describe "against the checkout the round began with" do
      let(:snapshot) { {"head" => "a" * 40, "tree_sha256" => "t" * 64} }
      let(:round) { super().merge("snapshot" => snapshot) }
      let(:progress) { Workspace::WorkflowProgress.new(change: change, store: store, dispatch: RecordingDispatch.new, attempt_record: RecordingAttemptRecord.new, panes: panes, log_tail: RecordingLogTail.new, clock: -> { now }) }

      it "goes on to the tally when nothing changed" do
        stored(reviewing)

        evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9")

        expect(guard.calls.map(&:first)).to eq([:round_check])
        expect(guard.calls.last[2]).to eq(snapshot)
        expect(tally.calls.size).to eq(1)
      end

      it "stops a changed checkout review_guard, the round recorded, with no tally, no loop and no round spent" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review_rounds"] = 1 })
        changed = RecordingGuard.new(round_found: {"changed" => ["tree"], "snapshot_head" => "a" * 40, "head" => "a" * 40})

        run = evaluation(review_tally: tally, guard: changed).turn_ended("wr_1", actor: "agent", pane: "%9")

        expect(tally.calls).to be_empty
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "review_guard")
        expect(run.reason["details"]).to include("step" => "plan", "attempt" => 1, "round" => 1, "changed" => ["tree"])
        plan = run.step("plan")
        expect(plan.state).to eq("reviewing")
        expect(plan.review_rounds).to eq(1)
        expect(plan.review).to include("recorded" => true)
        expect(plan.last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["review_guard"])
        expect(plan.last_attempt.to_h["outcome"]).to eq("checks_passed")
        expect(change.reviews).to be_empty
        expect(change.events.map { |each| each[1] }).to include("review_ended")
      end

      it "stops review_incomplete, not a pass, when the checkout can't be compared" do
        stored(reviewing)
        unread = RecordingGuard.new(round_found: {"unread" => ["tree"]})

        run = evaluation(review_tally: tally, guard: unread).turn_ended("wr_1", actor: "agent", pane: "%9")

        expect(tally.calls).to be_empty
        expect(run.reason["code"]).to eq("review_incomplete")
        expect(run.reason["details"]["problem"]).to include("tree unread")
      end

      it "checks before the revision is computed again" do
        stored(reviewing)
        changed = RecordingGuard.new(round_found: {"changed" => ["head"], "snapshot_head" => "a" * 40, "head" => "b" * 40})
        revision = RecordingReviewRevision.new({revision: "rev1", problem: nil})

        run = evaluation(review_tally: tally, guard: changed, review_revision: revision).turn_ended("wr_1", actor: "agent", pane: "%9")

        expect(revision.calls).to be_empty
        expect(change.review_ends).to be_empty
        expect(run.reason["code"]).to eq("review_guard")
      end
    end

    it "ignores a turn's end in the author's pane, a turn begun before the round, and a stopped round" do
      stored(reviewing)
      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%3")
      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent")
      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 29))
      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", stopped_at: Time.utc(2026, 11, 10, 11, 29))
      stored(reviewing("reason" => {"code" => "review_incomplete"}))
      evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9")

      expect(tally.calls).to be_empty
      expect(progress.calls).to be_empty
    end

    describe "in a window an earlier round left, being cleared for this one" do
      let(:round) { super().merge("clear_from" => "2026-11-10T11:40:00.000Z") }

      it "ignores the end of a turn a person had there before the clear, and one whose start is not known, costing no round" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review_rounds"] = 2 })

        evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 35), stopped_at: Time.utc(2026, 11, 10, 11, 41))
        evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", stopped_at: Time.utc(2026, 11, 10, 11, 41))

        expect(tally.calls).to be_empty
        expect(progress.calls).to be_empty
        expect(store.runs["wr_1"]["steps"]["plan"]).to include("state" => "reviewing", "review_rounds" => 2)
        expect(store.runs["wr_1"]["reason"]).to be_nil
      end

      it "ignores a turn begun once the clear was under way while the line is still being typed, no clear confirmed" do
        stored(reviewing)

        evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 40, 5))

        expect(tally.calls).to be_empty
        expect(store.runs["wr_1"]["reason"]).to be_nil
      end

      it "decides the round on the reviewers' turn, begun once the clear was under way, once the line was delivered" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review"]["delivered_at"] = "2026-11-10T11:40:10.000Z" })

        evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 40, 5))

        expect(tally.calls.size).to eq(1)
      end

      describe "for a round whose line may have been typed, waiting on a prompt in the review pane" do
        let(:typed) { {"code" => "connection_failed", "message" => "daemon gone", "at" => "2026-11-10T11:41:30Z", "typed" => true} }

        it "counts the reviewers' Stop once the person answers, the clear confirmed though the delivery never was" do
          stored(reviewing.tap do |hash|
            hash["steps"]["plan"]["review"].merge!("delivery" => "failed", "failure" => typed, "kick_at" => "2026-11-10T11:41:10.000Z",
              "cleared_at" => "2026-11-10T11:41:00.000Z")
          end)

          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 41, 20), stopped_at: Time.utc(2026, 11, 10, 11, 55))

          expect(tally.calls.size).to eq(1)
        end

        it "leaves such a Stop uncounted when neither the clear nor the delivery is known, for the sweep or the tick to judge" do
          stored(reviewing.tap do |hash|
            hash["steps"]["plan"]["review"].merge!("delivery" => "failed", "failure" => typed, "kick_at" => "2026-11-10T11:41:10.000Z")
          end)

          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 41, 20), stopped_at: Time.utc(2026, 11, 10, 11, 55))

          expect(tally.calls).to be_empty
          expect(store.runs["wr_1"]["reason"]).to be_nil
        end
      end

      describe "once the daemon confirmed the clear and the delivery was recorded" do
        let(:round) { super().merge("cleared_at" => "2026-11-10T11:41:00.000Z", "delivered_at" => "2026-11-10T11:42:00.000Z") }

        it "ignores a person's turn begun before the confirmed clear, though after the clear began" do
          stored(reviewing)

          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", turn_started: Time.utc(2026, 11, 10, 11, 40, 30))

          expect(tally.calls).to be_empty
        end

        it "counts a Stop with no known start (the daemon restarted during the round) that came after the delivery" do
          stored(reviewing)

          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", stopped_at: Time.utc(2026, 11, 10, 11, 50))

          expect(tally.calls.size).to eq(1)
        end

        it "leaves uncounted such a Stop from before the delivery, and one with no time at all" do
          stored(reviewing)

          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9", stopped_at: Time.utc(2026, 11, 10, 11, 41, 30))
          evaluation(review_tally: tally).turn_ended("wr_1", actor: "agent", pane: "%9")

          expect(tally.calls).to be_empty
        end
      end
    end

    it "takes a round as incomplete when no tally is set up" do
      stored(reviewing)

      evaluation.turn_ended("wr_1", actor: "agent", pane: "%9")

      expect(progress.calls.first[2]).to include(outcome: :incomplete, reviews: [])
    end

    it "follows up the next round a decision registers" do
      rounds = []
      stored(reviewing)
      decided = Class.new(RecordingProgress) do
        def decide_review(run, tally, ctx:)
          ctx.review({"round" => 2})
          super
        end
      end.new

      evaluation(progress: decided, review_tally: tally, review_round: ->(run_id, review) { rounds << [run_id, review] && nil }).turn_ended("wr_1", actor: "agent", pane: "%9")

      expect(rounds).to eq([["wr_1", {"round" => 2}]])
    end

    describe "with its revision computed again" do
      let(:round) { {"round" => 1, "delivery" => nil, "pane" => "%9", "started_at" => "2026-11-10T11:30:00.000Z", "pending" => ["skeptic"], "redeliveries" => 0, "revision" => "rev1"} }
      let(:progress) { Workspace::WorkflowProgress.new(change: change, store: store, dispatch: RecordingDispatch.new, attempt_record: RecordingAttemptRecord.new, panes: panes, log_tail: RecordingLogTail.new, clock: -> { now }) }

      def ended(revision, **overrides)
        evaluation(review_tally: tally, review_revision: revision, **overrides).turn_ended("wr_1", actor: "agent", pane: "%9")
      end

      it "computes it with the lock given up, and tallies an unchanged round" do
        stored(reviewing)
        revision = RecordingReviewRevision.new({revision: "rev1", problem: nil})

        run = ended(revision)

        expect(change.review_ends).to eq([{"step" => "plan", "attempt" => 1, "round" => 1, "try" => 1}])
        expect(revision.calls).to eq([[:call, "wr_1", "plan"]])
        expect(revision.stop_answers).to eq([false])
        expect(tally.calls.size).to eq(1)
        expect(run.current).to eq("plan")
        expect(run.step("plan").state).to eq("passed")
        expect(run.step("plan").to_h).not_to have_key("review")
      end

      it "stops a changed round as review_stale in the run's reasons, with no loop, no tally and no round spent" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review_rounds"] = 1 })

        run = ended(RecordingReviewRevision.new({revision: "rev2", problem: nil}))

        expect(tally.calls).to be_empty
        expect(run.state).to eq("waiting")
        expect(run.reason).to include("code" => "review_stale")
        expect(run.reason["details"]).to include("step" => "plan", "attempt" => 1, "round" => 1, "revision" => "rev1", "revision_now" => "rev2")
        plan = run.step("plan")
        expect(plan.state).to eq("reviewing")
        expect(plan.review_rounds).to eq(1)
        expect(plan.review).to include("recorded" => true).and(satisfy { |each| !each.key?("recompute") })
        expect(plan.last_attempt.to_h["rounds"].map { |each| each["ended"] }).to eq(["stale"])
        expect(change.reviews).to be_empty
        expect(change.events.map { |each| each[1] }).to include("review_ended")
      end

      it "stops review_incomplete with the problem when the revision can't be computed" do
        stored(reviewing)

        run = ended(RecordingReviewRevision.new({revision: nil, problem: "the review revision command exited 1"}))

        expect(tally.calls).to be_empty
        expect(run.reason["code"]).to eq("review_incomplete")
        expect(run.reason["details"]["problem"]).to eq("the round's revision could not be computed again: the review revision command exited 1")
      end

      it "drops a result for a round that moved on while it was computed (wanted_round?)" do
        stored(reviewing)
        stale_result = Class.new(RecordingReviewRevision) do
          attr_accessor :runs

          def call(run:, step:, stop_when: nil)
            runs["wr_1"]["steps"]["plan"]["review"]["round"] = 2
            super
          end
        end.new({revision: "rev2", problem: nil})
        stale_result.runs = store.runs

        run = ended(stale_result)

        expect(stale_result.stop_answers).to eq([true])
        expect(run.reason).to be_nil
        expect(tally.calls).to be_empty
        expect(store.runs["wr_1"]["steps"]["plan"]["review"]).to include("round" => 2, "recompute" => include("try" => 1))
      end

      it "drops a result whose try a later recompute replaced" do
        stored(reviewing)
        replaced = Class.new(RecordingReviewRevision) do
          attr_accessor :runs

          def call(run:, step:, stop_when: nil)
            runs["wr_1"]["steps"]["plan"]["review"]["recompute"]["try"] = 2
            super
          end
        end.new({revision: "rev1", problem: nil})
        replaced.runs = store.runs

        ended(replaced)

        expect(tally.calls).to be_empty
      end

      it "ignores the review pane's turn ending again while the recompute runs" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review"]["recompute"] = {"started_at" => "2026-11-10T11:59:00Z", "try" => 1} })
        revision = RecordingReviewRevision.new

        ended(revision)

        expect(revision.calls).to be_empty
        expect(change.review_ends).to be_empty
      end

      it "tries a lost recompute once more, then stops review_incomplete" do
        stored(reviewing.tap { |hash| hash["steps"]["plan"]["review"]["recompute"] = {"started_at" => "2026-11-10T11:00:00Z", "try" => 1} })
        work = evaluation(review_revision: RecordingReviewRevision.new)
        again = work.review_ended(store.runs["wr_1"], ctx: ctx)
        expect(again.step("plan").review["recompute"]).to eq("started_at" => "2026-11-10T12:00:00Z", "try" => 2)

        stopped = work.review_ended(again, ctx: ctx)

        expect(stopped.reason["code"]).to eq("review_incomplete")
        expect(stopped.reason["details"]["problem"]).to eq("the round's revision was computed again 2 times and none reported back")
        expect(stopped.step("plan").review).not_to have_key("recompute")
      end

      it "answers the run as stored when it was cancelled while the revision was computed" do
        stored(reviewing)
        ended_ids = []
        finished = RecordingRunChange.new(store.runs, finished: ended_ids)
        cancelling = Class.new(RecordingReviewRevision) do
          attr_accessor :ids

          def call(run:, step:, stop_when: nil)
            ids << "wr_1"
            super
          end
        end.new
        cancelling.ids = ended_ids

        run = evaluation(change: finished, review_tally: tally, review_revision: cancelling).turn_ended("wr_1", actor: "agent", pane: "%9")

        expect(run.step("plan").review["recompute"]).to include("try" => 1)
        expect(tally.calls).to be_empty
      end
    end
  end

  describe "#evaluate" do
    it "answers a new run and leaves the run given alone" do
      given = run_hash
      before = deep_copy(given)

      run = evaluation.evaluate(given, ctx: ctx)

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(given).to eq(before)
      expect(run.reason["code"]).to eq("turn_ended_incomplete")
    end

    it "drops the attempt's delivery mark and old proofs" do
      given = run_hash.tap { |run| run["steps"]["plan"]["attempts"].last.merge!("delivery" => "delivering", "proofs" => [{"index" => 0}]) }

      attempt = evaluation.evaluate(given, ctx: ctx).step("plan").last_attempt

      expect(attempt.delivery).to be_nil
      expect(attempt.proofs).to be_nil
    end

    it "fails a guarded step the guard finds changed" do
      guard = RecordingGuard.new(found: {"code" => "head_moved", "base_sha" => "a" * 40, "head" => "b" * 40})

      evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "unchanged")), ctx: ctx)

      expect(guard.calls.map(&:first)).to eq(%i[check config_change])
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "guard", "guard" => "head_moved", "base_sha" => "a" * 40, "head" => "b" * 40,
                                                          "code" => "head_moved", "code_source" => "engine"}]])
    end

    it "fails as a check error when the guard can't run" do
      guard = RecordingGuard.new
      allow(guard).to receive(:check).and_raise(IOError)

      evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "unchanged")), ctx: ctx)

      expect(progress.calls.last[2]).to eq("cause" => "check", "error" => "the guard could not run (IOError)", "code" => "check_error", "code_source" => "engine")
    end

    it "warns of a changed config once on the attempt, in its history and the inbox, and goes on" do
      guard = RecordingGuard.new(config: {"code" => "config_changed", "reading" => "r2"})
      produce

      run = evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "config")).merge("guard_config_seen" => "r1"), ctx: ctx)

      expect(guard.calls.last).to eq([:config_change, dir, {seen: "r1"}])
      expect(run.guard_config_seen).to eq("r2")
      expect(run.step("plan").last_attempt.warnings).to eq([{"code" => "config_changed", "at" => "2026-11-10T12:00:00Z",
                                                             "message" => "the repository's config, attributes or replace refs changed; the run went on"}])
      expect(change.events).to eq([["wr_1", "guard_warning", {"step" => "plan", "attempt" => 1, "code" => "config_changed", "inbox" => true}]])
      record, options = inbox.calls.last[1..]
      expect(record).to include("dedupe_key" => "workflow-guard:wr_1:config_changed", "links" => {"run_id" => "wr_1", "step" => "plan", "attempt" => 1})
      expect(options).to eq(reopen: true)
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "clears the reading warned of once the config is back at the base" do
      guard = RecordingGuard.new(config: {"code" => nil})

      run = evaluation(guard: guard).evaluate(run_hash(definition_step: step("guard" => "config")).merge("guard_config_seen" => "r1"), ctx: ctx)

      expect(run.to_h).not_to have_key("guard_config_seen")
      expect(inbox.calls).to be_empty
    end

    it "fails the step on an unmet require proof" do
      produce
      require_check = RecordingRequire.new(checks: [{"proof" => "commits", "code" => "require_commits", "detail" => "no commit", "required" => 1, "found" => 0}])

      evaluation(require_check: require_check).evaluate(run_hash(definition_step: step("require" => [{"commits" => 1}])), ctx: ctx)

      expect(require_check.calls).to eq([[:check, "plan", 1, {from: 0}]])
      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "require", "require" => "commits", "detail" => "no commit", "required" => 1, "found" => 0,
                                                          "code" => "require_commits", "code_source" => "engine"}]])
    end

    it "records a skipped proof as ended and checks on from the next entry" do
      produce
      require_check = RecordingRequire.new(checks: [{"skipped" => {"index" => 0, "proof" => "command", "skipped" => true}}, nil])

      run = evaluation(require_check: require_check).evaluate(run_hash(definition_step: step("require" => [{"command" => "lint"}, {"commits" => 1}])), ctx: ctx)

      expect(require_check.calls.map(&:last)).to eq([{from: 0}, {from: 1}])
      expect(run.step("plan").last_attempt.proofs).to eq([{"index" => 0, "proof" => "command", "skipped" => true,
                                                           "started_at" => "2026-11-10T12:00:00Z", "ended_at" => "2026-11-10T12:00:00Z"}])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "takes the step to checking for a proof that runs outside the lock, and registers it on the context" do
      produce
      pending = {"index" => 0, "proof" => "command", "token" => "t1", Workspace::WorkflowRequire::FACTS_KEY => {"head" => "abc"}}
      context = ctx

      run = evaluation(require_check: RecordingRequire.new(checks: [{"outside" => pending}])).evaluate(run_hash(definition_step: step("require" => [{"command" => "lint"}])), ctx: context)

      expect(run.step("plan").state).to eq("checking")
      expect(run.state).to eq("running")
      expect(run.step("plan").last_attempt.proofs).to eq([{"index" => 0, "proof" => "command", "token" => "t1", "started_at" => "2026-11-10T12:00:00Z"}])
      expect(context.check).to eq("step" => "plan", "attempt" => 1, "cwd" => dir, "proof" => pending)
      expect(progress.calls).to be_empty
    end
  end

  describe "#evaluate_accepted" do
    def accepted_run(definition_step: step("guard" => "unchanged"))
      run_hash(definition_step: definition_step, state: "failed").merge(
        "state" => "waiting", "reason" => {"code" => "failed_check", "since" => "2026-11-10T11:55:00Z", "details" => {"cause" => "guard", "guard" => "head_moved"}}
      ).tap do |run|
        run["steps"]["plan"]["attempts"][0].merge!("started_at" => "2026-11-10T11:00:00Z", "ended_at" => "2026-11-10T11:55:00Z", "outcome" => "failed", "code" => "head_moved")
      end
    end

    it "skips the guard and passes the step overridden once its files are there" do
      produce
      given = accepted_run
      before = deep_copy(given)

      run = evaluation.evaluate_accepted(given, ctx: ctx)

      expect(given).to eq(before)
      expect(guard.calls).to be_empty
      expect(progress.calls).to eq([[:pass_overridden, "plan"]])
      expect(run.step("plan").last_attempt.to_h).to include("guard_accepted" => "head_moved", "outcome" => "overridden")
    end

    it "stops on turn_ended_incomplete when a produces file is missing, and does not pass" do
      run = evaluation.evaluate_accepted(accepted_run, ctx: ctx)

      expect(run.reason).to include("code" => "turn_ended_incomplete")
      expect(run.state).to eq("waiting")
      expect(progress.calls).to be_empty
      expect(run.step("plan").last_attempt.to_h).to include("guard_accepted" => "head_moved", "outcome" => "failed")
    end

    it "fails the step on an unmet require: proof with the proof's code" do
      produce
      require_check = RecordingRequire.new(checks: [{"name" => "commits", "code" => "require_commits", "detail" => "no commits"}])

      evaluation(require_check: require_check).evaluate_accepted(accepted_run(definition_step: step("guard" => "unchanged", "require" => [{"commits" => 1}])), ctx: ctx)

      expect(progress.calls.map(&:first)).to eq([:fail_step])
      expect(progress.calls.first[2]).to include("code" => "require_commits")
    end

    it "registers the status check, and passes overridden only once finish_check sees it pass" do
      produce
      context = ctx
      definition_step = step("guard" => "unchanged", "status" => {"command" => "test", "timeout" => 60})

      run = evaluation.evaluate_accepted(accepted_run(definition_step: definition_step), ctx: context)

      expect(run.step("plan").state).to eq("checking")
      expect(context.check).to include("step" => "plan", "attempt" => 1, "command" => "rake test")
      expect(progress.calls).to be_empty

      store.runs["wr_1"] = run.thawed
      evaluation(progress: progress).finish_check("wr_1", context.check, "daemon")
      expect(progress.calls).to eq([[:pass_overridden, "plan"]])
    end

    it "fails the step with the check's code when finish_check sees the status check fail" do
      produce
      context = ctx
      run = evaluation.evaluate_accepted(accepted_run(definition_step: step("guard" => "unchanged", "status" => {"command" => "test", "timeout" => 60})), ctx: context)
      store.runs["wr_1"] = run.thawed

      evaluation(checker: RecordingChecker.new(result: {exit_code: 1, timed_out: false, error: nil})).finish_check("wr_1", context.check, "daemon")

      expect(progress.calls.map(&:first)).to eq([:fail_step])
      expect(progress.calls.first[2]).to include("cause" => "check", "code" => "check_failed")
    end
  end

  describe "a review round registered with a round rerun collaborator" do
    let(:review) { {"step" => "plan", "attempt" => 2, "round" => 2} }
    let(:rounds) { [] }
    let(:runner) { ->(run_id, pending) { rounds << [run_id, pending] && nil } }

    def follow(rerun)
      stored(run_hash(state: "reviewing"))
      context = ctx
      context.review(review)
      evaluation(review_round: runner, round_rerun: rerun).finish_follow_ups("wr_1", context, Workspace::WorkflowRun.from_h(store.runs["wr_1"]))
    end

    it "asks it about the round before the delivery, and delivers the round as registered when it answers nothing" do
      rerun = RecordingRoundRerun.new

      follow(rerun)

      expect(rerun.calls).to eq([[:check_revision, "wr_1", review]])
      expect(rounds).to eq([["wr_1", review]])
    end

    it "hands the delivery the revision it computed" do
      follow(RecordingRoundRerun.new({revision: "rev2"}))

      expect(rounds).to eq([["wr_1", review.merge("revision" => "rev2")]])
    end

    it "delivers nothing and answers the run it stopped" do
      stopped = Workspace::WorkflowRun.from_h(run_hash(:state => "reviewing", "reason" => {"code" => "review_no_change"}))

      result = follow(RecordingRoundRerun.new({run: stopped}))

      expect(rounds).to be_empty
      expect(result).to equal(stopped)
    end
  end

  describe "#finish_follow_ups" do
    let(:check) { {"step" => "plan", "attempt" => 1, "command" => "rake test", "timeout" => 60, "log" => File.join(artifacts, "c.log")} }

    it "answers the run as given when the change registered nothing, or did not run" do
      stored
      given = Workspace::WorkflowRun.from_h(run_hash)

      expect(evaluation.finish_follow_ups("wr_1", ctx, given)).to equal(given)
      expect(evaluation.finish_follow_ups("wr_1", nil, given)).to equal(given)
    end

    it "hands a registered review round to the round runner and answers the run it returns" do
      stored
      after = Workspace::WorkflowRun.from_h(run_hash.merge("note" => "after"))
      rounds = []
      runner = ->(run_id, review) { rounds << [run_id, review] && after }
      context = ctx
      context.review({"round" => 1})

      result = evaluation(review_round: runner).finish_follow_ups("wr_1", context, Workspace::WorkflowRun.from_h(run_hash))

      expect(rounds).to eq([["wr_1", {"round" => 1}]])
      expect(result).to equal(after)
    end

    it "keeps the run as given when the round runner answers nil, or when there is no runner" do
      stored
      given = Workspace::WorkflowRun.from_h(run_hash)
      context = ctx
      context.review({"round" => 1})

      expect(evaluation(review_round: ->(_id, _review) {}).finish_follow_ups("wr_1", context, given)).to equal(given)
      expect(evaluation.finish_follow_ups("wr_1", context, given)).to equal(given)
    end

    it "runs a registered check before a registered review round" do
      stored
      order = []
      context = ctx
      context.check(check)
      context.review({"round" => 1})
      subject = evaluation(review_round: ->(*) { order << :review && nil })
      allow(subject).to receive(:finish_check) { order << :check && Workspace::WorkflowRun.from_h(run_hash) }

      subject.finish_follow_ups("wr_1", context, Workspace::WorkflowRun.from_h(run_hash))

      expect(order).to eq(%i[check review])
    end

    it "closes a registered review window first, keeping the run, and closes nothing without a closer" do
      stored
      order = []
      context = ctx
      context.close_review({"step" => "plan", "round" => 1, "pane" => "%9"})
      context.review({"round" => 2})
      closer = ->(run_id, found) { order << [:close, run_id, found] && :ignored }
      given = Workspace::WorkflowRun.from_h(run_hash)

      result = evaluation(review_closer: closer, review_round: ->(*) { order << :review && nil }).finish_follow_ups("wr_1", context, given)

      expect(order).to eq([[:close, "wr_1", {"step" => "plan", "round" => 1, "pane" => "%9"}], :review])
      expect(result).to equal(given)
      expect(evaluation.finish_follow_ups("wr_1", context, given)).to equal(given)
    end
  end

  describe "#finish_check" do
    let(:pending) { {"index" => 0, "proof" => "command", "token" => "t1"} }
    let(:check) { {"step" => "plan", "attempt" => 1, "cwd" => dir, "proof" => pending} }

    def checking_run
      run_hash(definition_step: step("require" => [{"command" => "lint"}]), state: "checking").tap do |run|
        run["steps"]["plan"]["attempts"].last["proofs"] = [pending.merge("started_at" => "2026-11-10T11:30:00Z")]
      end
    end

    it "runs a proof, records its result, and goes on to the status check or the pass" do
      stored(checking_run)
      require_check = RecordingRequire.new(outside: {"record" => {"exit_code" => 0}, "unmet" => nil})

      run = evaluation(require_check: require_check).finish_check("wr_1", check, "daemon")

      expect(require_check.calls).to eq([[:run_outside, pending, {cwd: dir}], [:check, "plan", 1, {from: 1}]])
      expect(run.step("plan").last_attempt.proofs.last).to include("token" => "t1", "exit_code" => 0, "ended_at" => "2026-11-10T12:00:00Z")
      expect(change.events).to eq([["wr_1", "proof_finished", {"step" => "plan", "attempt" => 1, "proof" => "command", "passed" => true}]])
      expect(progress.calls).to eq([[:pass_step, "plan"]])
    end

    it "runs the review round a step registered when a proof chain ends in its pass" do
      rounds = []
      stored(checking_run)
      progress = RecordingProgress.new(review: {"round" => 1})
      require_check = RecordingRequire.new(outside: {"record" => {"exit_code" => 0}, "unmet" => nil})

      evaluation(progress: progress, require_check: require_check, review_round: ->(run_id, review) { rounds << [run_id, review] && nil }).finish_check("wr_1", check, "daemon")

      expect(rounds).to eq([["wr_1", {"round" => 1}]])
    end

    it "runs the review round a step registered when its status check passes" do
      rounds = []
      stored(checking_run.tap { |run| run["steps"]["plan"]["attempts"].last["check"] = {"started_at" => "2026-11-10T11:30:00Z", "log" => "/tmp/x.log"} })
      progress = RecordingProgress.new(review: {"round" => 1})
      status_check = {"step" => "plan", "attempt" => 1, "command" => "rake", "timeout" => 5, "log" => "/tmp/x.log", "cwd" => dir, "role" => "test"}

      evaluation(progress: progress, review_round: ->(run_id, review) { rounds << [run_id, review] && nil }).finish_check("wr_1", status_check, "daemon")

      expect(progress.calls).to eq([[:pass_step, "plan"]])
      expect(rounds).to eq([["wr_1", {"round" => 1}]])
    end

    it "fails the step on a proof found unmet outside the lock" do
      stored(checking_run)
      unmet = {"proof" => "command", "code" => "require_command", "detail" => "lint failed", "exit_code" => 1}

      evaluation(require_check: RecordingRequire.new(outside: {"record" => {"exit_code" => 1}, "unmet" => unmet})).finish_check("wr_1", check, "daemon")

      expect(progress.calls).to eq([[:fail_step, "plan", {"cause" => "require", "require" => "command", "detail" => "lint failed", "exit_code" => 1,
                                                          "code" => "require_command", "code_source" => "engine"}]])
    end

    it "drops a result the run moved on from" do
      stored(checking_run.merge("current" => "plan").tap { |run| run["steps"]["plan"]["state"] = "failed" })

      run = evaluation.finish_check("wr_1", check, "daemon")

      expect(run.step("plan").state).to eq("failed")
      expect(change.events).to be_empty
      expect(progress.calls).to be_empty
    end

    it "answers the stored run when it was cancelled while the check ran" do
      stored(checking_run)
      change = RecordingRunChange.new(store.runs, finished: ["wr_1"])

      run = evaluation(change: change).finish_check("wr_1", check, "daemon")

      expect(run).to eq(Workspace::WorkflowRun.from_h(checking_run))
      expect(store.calls.last).to eq([:run, "wr_1"])
    end

    it "tells the check to stop once the run no longer waits for it" do
      stored(checking_run.merge("state" => "cancelled").tap { |run| run["steps"]["plan"]["attempts"].last["check"] = {"started_at" => "2026-11-10T11:30:00Z", "log" => "/tmp/x.log"} })
      checker = RecordingChecker.new
      status_check = {"step" => "plan", "attempt" => 1, "command" => "rake", "timeout" => 5, "log" => "/tmp/x.log", "cwd" => dir, "role" => "test"}

      evaluation(checker: checker).finish_check("wr_1", status_check, "daemon")

      expect(checker.stop_answers).to eq([true])
    end
  end
end
