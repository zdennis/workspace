require "spec_helper"

RSpec.describe Workspace::WorkflowRecovery do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:store) { RecordingRunStore.new }
  let(:busy) { [] }
  let(:change) { RecordingRunChange.new(store.runs, busy: busy) }
  let(:dispatch) { RecordingDispatch.new }
  let(:progress) { RecordingProgress.new }
  let(:evaluation) { RecordingEvaluation.new(store.runs) }
  let(:clock_at) { [now] }

  let(:holder_alive) { nil }

  def recovery
    described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, holder_alive: holder_alive, clock: -> { clock_at.first })
  end

  # A step being reviewed, its round as given over a delivering round 1 that started an hour before +now+.
  def reviewing(round = {})
    run_hash(step_state: "reviewing").tap do |hash|
      hash["steps"]["build"]["review"] = {"round" => 1, "delivery" => "delivering", "started_at" => "2026-11-10T11:00:00Z", "redeliveries" => 0}.merge(round)
    end
  end

  def run_hash(state: "running", step_state: "running", reason: nil, attempt: {}, extra: {})
    {"id" => "wr_1", "workflow" => "flow", "workspace" => "app", "worktree" => "/work/app", "artifacts_dir" => "/work/app/.workflow/wr_1",
     "state" => state, "current" => "build", "pane" => "%3", "loops" => {}, "pending_context" => [], "reason" => reason,
     "definition" => {"id" => "flow", "max_attempts" => 5, "redeliver" => 2,
                      "steps" => [{"id" => "build", "produces" => [], "status" => {"command" => "rake", "timeout" => 60}}]},
     "steps" => {"build" => {"state" => step_state, "attempts" => [{"n" => 1, "started_at" => "2026-11-10T11:00:00Z"}.merge(attempt)]}}}.merge(extra)
  end

  def stored(hash = run_hash)
    store.runs[hash["id"]] = hash
  end

  def backoff_wait(until_at: "2026-11-10T11:59:00Z")
    {"until" => until_at, "to" => "build", "text" => "try again", "context" => []}
  end

  def undelivered
    run_hash(state: "waiting", step_state: "waiting",
      reason: {"code" => "waiting_you", "since" => "2026-11-10T11:00:05Z", "details" => {"kind" => "dispatch", "error" => "pane_busy"}},
      attempt: {"outcome" => "not_delivered", "ended_at" => "2026-11-10T11:00:05Z"})
  end

  def event_types = change.events.map { |_, type, data| [type, data] }

  describe "#tick" do
    it "starts the retry of a backoff that is over and answers a WorkflowRun" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait}))

      run = recovery.tick("wr_1", actor: "sweep")

      expect(run).to be_a(Workspace::WorkflowRun)
      expect(progress.calls).to eq([[:start_retry, "build", backoff_wait, {cause: "backoff_ended", proven: false, budgeted: true}]])
      expect(store.runs["wr_1"]).not_to have_key("backoff")
      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: true, actor: "sweep", cause: "tick"}]])
    end

    it "hands the actor it was given to the change, whether the daemon's advance or the sweep" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait}))

      recovery.tick("wr_1", actor: "daemon")

      expect(change.calls).to eq([[:call, "wr_1", {nonblocking: true, actor: "daemon", cause: "tick"}]])
    end

    it "asks again for the lock a run waits on" do
      stored(run_hash(state: "waiting", reason: {"code" => "waiting_lock", "details" => {}}))

      recovery.tick("wr_1", actor: "sweep")

      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "lock_ended", context: nil, budgeted: true, retry_of: nil}]])
      expect(change.deliveries).to eq([{"step" => "build"}])
    end

    it "decides a delivered round the sweep pressed and whose turn never ended, once the review timeout has passed since the press, with no sweep" do
      pressed = ->(at) { reviewing("delivery" => nil, "pane" => "%9", "sweep" => {"interrupt" => {"state" => "sent", "at" => at}, "run_interrupt" => {"state" => "sent", "at" => "2026-11-10T11:00:00Z"}}) }
      stored(pressed.call("2026-11-10T11:30:01Z"))

      expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
      expect(evaluation.calls).to be_empty

      stored(pressed.call("2026-11-10T11:30:00Z"))
      recovery.tick("wr_1", actor: "sweep")

      expect(evaluation.calls.first).to eq([:review_ended, "build"])
      expect(event_types.first).to eq(["step_stalled", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "cause" => "interrupt_unanswered", "waited" => 1800}])
    end

    it "leaves a delivered round whose press is still pending (never confirmed) to its turn's end" do
      stored(reviewing("delivery" => nil, "pane" => "%9", "sweep" => {"interrupt" => {"state" => "pending", "at" => "2026-11-10T10:00:00Z"}}))

      expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
      expect(evaluation.calls).to be_empty
    end

    it "asks again for the lock a review round waits on through the round's own start, never an author attempt" do
      stored(run_hash(state: "waiting", step_state: "reviewing", reason: {"code" => "waiting_lock", "details" => {"review_round" => 1}}))

      recovery.tick("wr_1", actor: "sweep")

      expect(progress.calls).to eq([[:restart_review, "build"]])
      expect(dispatch.calls).to be_empty
      expect(change.reviews).to eq([{"step" => "build"}])
    end

    it "turns a background hold that ran out into a turn_ended_incomplete stop" do
      hold = {"code" => "turn_ended_background", "since" => "2026-11-10T09:00:00Z", "seen_at" => "2026-11-10T10:00:00Z",
              "details" => {"step" => "build", "attempt" => 1, "missing" => ["out.md"], "tasks" => [{"id" => "t1"}], "other" => 1}}
      stored(run_hash(reason: hold))

      run = recovery.tick("wr_1", actor: "sweep")

      expect(run.reason).to eq("code" => "turn_ended_incomplete", "since" => "2026-11-10T12:00:00Z",
        "details" => {"step" => "build", "attempt" => 1, "missing" => ["out.md"], "background_tasks" => [{"id" => "t1"}]})
    end

    it "runs again a check that never reported back, the check outside the lock" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"kind" => "status"})
      stored(run_hash(step_state: "checking", attempt: {"check" => {"started_at" => "2026-11-10T11:00:00Z"}}))

      run = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now }).tick("wr_1", actor: "sweep")

      expect(run.id).to eq("wr_1")
      expect(evaluation.calls).to eq([[:evaluate, "build"], [:finish_check, "wr_1", {"kind" => "status"}]])
    end

    it "judges again the end of a review round whose recompute never reported back, the recompute outside the lock" do
      round = {"round" => 1, "pane" => "%9", "recompute" => {"started_at" => "2026-11-10T11:00:00Z", "try" => 1}}
      stored(run_hash(step_state: "reviewing").tap { |hash| hash["steps"]["build"]["review"] = round })

      run = recovery.tick("wr_1", actor: "sweep")

      expect(run.id).to eq("wr_1")
      expect(evaluation.calls).to eq([[:review_ended, "build"], [:review_end, "wr_1", {"step" => "build"}]])
    end

    it "leaves a review round's recompute alone while it may still report back" do
      round = {"round" => 1, "pane" => "%9", "recompute" => {"started_at" => "2026-11-10T11:59:00Z", "try" => 1}}
      stored(run_hash(step_state: "reviewing").tap { |hash| hash["steps"]["build"]["review"] = round })

      expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
      expect(evaluation.calls).to be_empty
    end

    it "follows up a review round the tick registered, outside the lock" do
      evaluation = RecordingEvaluation.new(store.runs, review: {"round" => 1})
      stored(run_hash(step_state: "checking", attempt: {"check" => {"started_at" => "2026-11-10T11:00:00Z"}}))

      described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now }).tick("wr_1", actor: "sweep")

      expect(evaluation.calls).to eq([[:evaluate, "build"], [:review_round, "wr_1", {"round" => 1}]])
    end

    describe "a review round to be delivered again" do
      let(:holder) { {"pid" => 41, "started" => "Tue Nov 10 11:00:00 2026"} }

      it "delivers a lapsed round again once its holder is gone, counting one redelivery" do
        alive = []
        recovery = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation,
          holder_alive: ->(found) { alive << found && false }, clock: -> { now })
        stored(reviewing("holder" => holder))

        run = recovery.tick("wr_1", actor: "sweep")

        expect(alive).to eq([holder])
        expect(progress.calls).to eq([[:redeliver_round, "build"]])
        expect(run.step("build").review).to include("delivery" => "delivering", "redeliveries" => 1)
        expect(change.reviews).to eq([{"step" => "build", "round" => 1}])
      end

      context "while the holder of a slow delivery lives" do
        let(:holder_alive) { ->(_found) { true } }

        it "leaves the round alone" do
          stored(reviewing("holder" => holder))

          expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
          expect(progress.calls).to be_empty
        end
      end

      it "delivers a failed round again once its backoff is over, and not before" do
        failure = {"code" => "agent_not_ready", "message" => "not ready", "at" => "2026-11-10T11:59:30Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure))

        expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
        clock_at.replace([now + 30])
        recovery.tick("wr_1", actor: "sweep")

        expect(progress.calls).to eq([[:redeliver_round, "build"]])
      end

      it "stops the round review_incomplete once its redeliveries reach the definition's redeliver, saying why" do
        failure = {"code" => "agent_not_ready", "message" => "not ready", "at" => "2026-11-10T11:00:00Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure, "redeliveries" => 2))

        recovery.tick("wr_1", actor: "sweep")

        decided = progress.calls.last
        expect(decided[0..1]).to eq([:decide_review, "build"])
        expect(decided[2]).to include(outcome: :incomplete, reviews: [])
        expect(decided[2][:problem]).to eq("the round could not be delivered: its delivery failed (agent_not_ready: not ready), and it was delivered again 2 times, its `redeliver` limit")
      end

      it "judges a round whose line may have been typed before the agent daemon went away, rather than delivering it again whole" do
        failure = {"code" => "connection_failed", "message" => "daemon gone", "at" => "2026-11-10T11:00:00Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure, "kick_at" => "2026-11-10T10:59:59.000Z", "pane" => "%9"))

        recovery.tick("wr_1", actor: "sweep")

        expect(evaluation.calls.first).to eq([:review_ended, "build"])
        expect(progress.calls).to be_empty
      end

      it "judges a round whose line may have been typed even once its redeliveries are spent, so a finished review counts" do
        stored(reviewing("holder" => holder, "kick_at" => "2026-11-10T11:00:01.000Z", "redeliveries" => 2))

        described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation,
          holder_alive: ->(_found) { false }, clock: -> { now }).tick("wr_1", actor: "sweep")

        expect(evaluation.calls.first).to eq([:review_ended, "build"])
        expect(progress.calls).to be_empty
      end

      describe "with a reader of the review pane" do
        let(:typed_failure) { {"code" => "connection_failed", "message" => "daemon gone", "at" => "2026-11-10T11:00:00Z", "typed" => true} }

        def with_panes(panes)
          described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, panes: panes, clock: -> { now })
        end

        let(:recent_failure) { typed_failure.merge("at" => "2026-11-10T11:59:00Z") }

        it "waits while the review pane's turn is not proven over, so a reviewer still at work is neither judged nor typed into" do
          stored(reviewing("delivery" => "failed", "failure" => recent_failure, "kick_at" => "2026-11-10T11:58:59.000Z", "pane" => "%9"))

          expect(with_panes(RecordingWorkflowPanes.new).tick("wr_1", actor: "sweep")).to be_nil
          expect(evaluation.calls + progress.calls).to be_empty
        end

        it "judges a round whose review pane shows a shell: its agent exited" do
          stored(reviewing("delivery" => "failed", "failure" => recent_failure, "kick_at" => "2026-11-10T11:58:59.000Z", "pane" => "%9"))
          shell = {"kind" => "shell", "idle_seconds" => Workspace::WorkflowPanes::AGENT_GONE_AFTER}

          with_panes(RecordingWorkflowPanes.new(rows: {"%9" => shell})).tick("wr_1", actor: "sweep")

          expect(evaluation.calls.first).to eq([:review_ended, "build"])
        end

        it "judges the round anyway once its wait passed the delivery window, whatever the pane shows (one that could not be read; a prompt is never judged by a wait)" do
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "pane" => "%9"))

          with_panes(RecordingWorkflowPanes.new).tick("wr_1", actor: "sweep")

          expect(evaluation.calls.first).to eq([:review_ended, "build"])
        end

        def claude_row(state, **rest) = {"kind" => "claude", "state" => state, "idle_seconds" => 0}.merge(rest)

        it "waits for a reviewer at work past its review timeout for the sweep's press, and stops the round review_incomplete only at twice that timeout with no press" do
          busy = RecordingWorkflowPanes.new(rows: {"%9" => claude_row("working")})
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T11:29:59.000Z", "started_at" => "2026-11-10T11:29:50.000Z", "pane" => "%9"))

          expect(with_panes(busy).tick("wr_1", actor: "sweep")).to be_nil
          expect(evaluation.calls + progress.calls).to be_empty

          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "started_at" => "2026-11-10T10:59:50.000Z", "pane" => "%9"))
          with_panes(busy).tick("wr_1", actor: "sweep")

          expect(evaluation.calls).to be_empty
          decided = progress.calls.last
          expect(decided[0..1]).to eq([:decide_review, "build"])
          expect(decided[2]).to include(outcome: :incomplete, reviews: [])
          expect(decided[2][:problem]).to include("still at work at twice the round's review timeout", "no workflow sweep interrupted it")
          expect(decided[2][:problem]).to include("a resume starts a fresh round and closes this window, stopping any reviewer still at work there")
        end

        it "keeps waiting for a reviewer at work the sweep interrupted, whose turn's end decides the round" do
          busy = RecordingWorkflowPanes.new(rows: {"%9" => claude_row("working")})
          pressed = {"interrupt" => {"state" => "sent", "at" => "2026-11-10T11:59:00Z"}}
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "started_at" => "2026-11-10T10:59:50.000Z",
            "pane" => "%9", "sweep" => pressed))

          expect(with_panes(busy).tick("wr_1", actor: "sweep")).to be_nil
          expect(evaluation.calls + progress.calls).to be_empty
        end

        it "decides a round whose review pane the sweep pressed and that still works on its verdicts first (interrupt_unanswered)" do
          stored(reviewing("delivery" => nil, "pane" => "%9", "window" => "@4", "server_pid" => "100"))

          outcome = recovery.review_stalled("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: "interrupt_unanswered", data: {"waited" => 1300})

          expect(outcome).to eq(:evaluated)
          expect(evaluation.calls.first).to eq([:review_ended, "build"])
          expect(progress.calls).to be_empty
          expect(event_types.first).to eq(["step_stalled", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "cause" => "interrupt_unanswered", "waited" => 1300}])
        end

        it "judges a typed round the sweep pressed whose pane still works once the longer of stall and review timeout has passed since the press" do
          busy = RecordingWorkflowPanes.new(rows: {"%9" => claude_row("working")})
          definition = reviewing["definition"].merge("stall" => 600)
          round = {"delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "started_at" => "2026-11-10T10:59:50.000Z", "pane" => "%9"}
          stored(reviewing(round.merge("sweep" => {"interrupt" => {"state" => "sent", "at" => "2026-11-10T11:30:01Z"}})).merge("definition" => definition))

          expect(with_panes(busy).tick("wr_1", actor: "sweep")).to be_nil
          expect(evaluation.calls + progress.calls).to be_empty

          stored(reviewing(round.merge("sweep" => {"interrupt" => {"state" => "sent", "at" => "2026-11-10T11:30:00Z"}})).merge("definition" => definition))
          with_panes(busy).tick("wr_1", actor: "sweep")

          expect(evaluation.calls.first).to eq([:review_ended, "build"])
          expect(progress.calls).to be_empty
          expect(event_types.first).to eq(["step_stalled", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "cause" => "interrupt_unanswered", "waited" => 1800}])
        end

        describe "when the verdicts read leave the round stopped for a person" do
          let(:evaluation) { RecordingEvaluation.new(store.runs, review_reason: {"code" => "review_incomplete"}) }

          it "answers :stopped for interrupt_unanswered" do
            stored(reviewing("delivery" => nil, "pane" => "%9", "window" => "@4", "server_pid" => "100"))

            outcome = recovery.review_stalled("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: "interrupt_unanswered", data: {"waited" => 1800})

            expect(outcome).to eq(:stopped)
            expect(evaluation.calls).to eq([[:review_ended, "build"]])
          end
        end

        it "waits for an agent daemon that can't be reached until the review's timeout, then judges the round" do
          down = RecordingWorkflowPanes.new(no_daemon: true)
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T11:50:00.000Z", "started_at" => "2026-11-10T11:49:50.000Z", "pane" => "%9"))

          expect(with_panes(down).tick("wr_1", actor: "sweep")).to be_nil

          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T11:29:59.000Z", "started_at" => "2026-11-10T11:29:50.000Z", "pane" => "%9"))
          with_panes(down).tick("wr_1", actor: "sweep")

          expect(evaluation.calls.first).to eq([:review_ended, "build"])
        end

        it "counts running sub-agents in an idle-looking pane as at work" do
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T11:50:00.000Z", "started_at" => "2026-11-10T11:49:50.000Z", "pane" => "%9"))

          expect(with_panes(RecordingWorkflowPanes.new(rows: {"%9" => claude_row("idle", "subagents" => [{"id" => "a"}])})).tick("wr_1", actor: "sweep")).to be_nil
        end

        it "never judges a review pane waiting for an answer by a wait, however long" do
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T09:00:00.000Z", "pane" => "%9"))

          expect(with_panes(RecordingWorkflowPanes.new(rows: {"%9" => claude_row("waiting")})).tick("wr_1", actor: "sweep")).to be_nil
          expect(evaluation.calls).to be_empty
        end

        it "judges a round with no daemon row for its pane once the short wait is over" do
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T11:50:00.000Z", "pane" => "%9"))

          with_panes(RecordingWorkflowPanes.new).tick("wr_1", actor: "sweep")

          expect(evaluation.calls.first).to eq([:review_ended, "build"])
        end

        it "answers nil, having done nothing, while a failed round waits out its backoff" do
          stored(reviewing("delivery" => "failed", "failure" => {"code" => "agent_not_ready", "message" => "x", "at" => "2026-11-10T11:59:50Z"}))

          expect(with_panes(RecordingWorkflowPanes.new).tick("wr_1", actor: "sweep")).to be_nil
        end

        it "waits the definition's stall on top of the delivery window" do
          at = (now - Workspace::WorkflowTransitions::DELIVERY_WINDOW - 30).utc.iso8601
          given = reviewing("delivery" => "failed", "failure" => typed_failure.merge("at" => at), "kick_at" => at, "pane" => "%9")
          given["definition"]["stall"] = 60
          stored(given)

          expect(with_panes(RecordingWorkflowPanes.new).tick("wr_1", actor: "sweep")).to be_nil
        end

        it "judges the round once the review pane's turn is proven over, or the pane is gone" do
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "pane" => "%9"))
          with_panes(RecordingWorkflowPanes.new(turn_over: ["%9"])).tick("wr_1", actor: "sweep")
          stored(reviewing("delivery" => "failed", "failure" => typed_failure, "kick_at" => "2026-11-10T10:59:59.000Z", "pane" => "%9"))
          gone = RecordingWorkflowPanes.new(gone: ["%9"])
          with_panes(gone).tick("wr_1", actor: "sweep")

          expect(gone.gone_checks).to eq([["%9", "app"]])
          expect(evaluation.calls.map(&:first).count(:review_ended)).to eq(2)
          expect(progress.calls).to be_empty
        end

        it "delivers a round whose line may have been typed again in a new window once tmux says its server restarted, as the sweep's server_restarted does" do
          stored(reviewing("delivery" => "failed", "failure" => recent_failure, "kick_at" => "2026-11-10T11:58:59.000Z", "pane" => "%9", "panes" => ["%9"],
            "window" => "@4", "server_pid" => "100"))
          restarted = RecordingWorkflowPanes.new(restarted: ["%9"], rows: {"%9" => claude_row("working")})

          with_panes(restarted).tick("wr_1", actor: "sweep")

          expect(restarted.calls).to include([:review_pane_state, "app", "%9", "100"])
          expect(evaluation.calls.map(&:first)).not_to include(:review_ended)
          expect(progress.calls).to eq([[:redeliver_round, "build", {new_server: true}]])
          expect(store.runs["wr_1"]["steps"]["build"]["review"]).not_to include("pane", "window", "server_pid")
        end
      end

      it "delivers again whole a round whose line was not confirmed (not_delivered): only a failure.typed says it went out" do
        failure = {"code" => "not_delivered", "message" => "no confirmation", "at" => "2026-11-10T11:00:00Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure, "kick_at" => "2026-11-10T10:59:59.000Z"))

        recovery.tick("wr_1", actor: "sweep")

        expect(progress.calls).to eq([[:redeliver_round, "build"]])
      end

      it "delivers again whole a round whose failure proves the line never went out, though it got as far as typing" do
        failure = {"code" => "pane_busy", "message" => "busy", "at" => "2026-11-10T11:00:00Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure, "kick_at" => "2026-11-10T10:59:59.000Z"))

        recovery.tick("wr_1", actor: "sweep")

        expect(progress.calls).to eq([[:redeliver_round, "build"]])
      end

      it "stops a round whose failure no delivery again gets past at once" do
        failure = {"code" => "review_custom_socket", "message" => "own socket", "at" => "2026-11-10T11:00:00Z"}
        stored(reviewing("delivery" => "failed", "failure" => failure))

        recovery.tick("wr_1", actor: "sweep")

        expect(progress.calls.last[2][:problem]).to include("which delivering it again cannot get past")
      end
    end

    it "answers nil for a run nothing wakes" do
      stored

      expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
      expect(progress.calls + dispatch.calls + evaluation.calls).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers nil" do
        stored(run_hash(state: "waiting", reason: {"code" => "waiting_lock", "details" => {}}))

        expect(recovery.tick("wr_1", actor: "sweep")).to be_nil
        expect(dispatch.calls).to be_empty
      end
    end
  end

  describe "#note_stall" do
    it "records a cause once for the attempt" do
      stored

      expect(recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone", data: {"pane" => "%3"})).to eq(:recorded)
      expect(recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone")).to eq(:repeat)

      expect(event_types).to eq([["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "pane_gone", "pane" => "%3"}]])
      expect(store.runs["wr_1"]["sweep"]).to eq("step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => "2026-11-10T12:00:00Z"}, "recovered" => {})
    end

    it "changes nothing once the run is on another attempt" do
      stored

      expect(recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: 2, cause: "pane_gone")).to eq(:moved_on)
      expect(change.events).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy" do
        stored

        expect(recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "pane_gone")).to eq(:busy)
      end
    end
  end

  describe "#note_recovery" do
    it "records the recovery only of a cause that was noted, and waits for the lock" do
      stored

      expect(recovery.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "daemon_down", action: "daemon_respawned")).to eq(:repeat)
      recovery.note_stall("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "daemon_down")
      expect(recovery.note_recovery("wr_1", actor: "sweep", step: "build", attempt: 1, cause: "daemon_down", action: "daemon_respawned")).to eq(:recorded)

      expect(event_types.last).to eq(["step_recovered", {"step" => "build", "attempt" => 1, "action" => "daemon_respawned", "cause" => "daemon_down"}])
      expect(change.calls.first).to eq([:call, "wr_1", {nonblocking: false, actor: "sweep", cause: "daemon_down"}])
    end
  end

  describe "#recover" do
    it "follows up a review round the recovered turn registered, outside the lock" do
      evaluation = RecordingEvaluation.new(store.runs, review: {"round" => 1})
      stored

      described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now })
        .recover("wr_1", actor: "sweep", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over")

      expect(evaluation.calls).to eq([[:evaluate, "build"], [:review_round, "wr_1", {"round" => 1}]])
    end

    it "decides a turn that ended unseen and runs the check it registers" do
      evaluation = RecordingEvaluation.new(store.runs, check: {"kind" => "status"})
      stored

      outcome = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now })
        .recover("wr_1", actor: "sweep", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over")

      expect(outcome).to eq(:evaluated)
      expect(evaluation.calls).to eq([[:evaluate, "build"], [:finish_check, "wr_1", {"kind" => "status"}]])
      expect(event_types.map(&:first)).to eq(%w[step_stalled step_recovered])
    end

    it "fails a step past its timeout when the decision is a turn_ended_incomplete stop" do
      evaluation = RecordingEvaluation.new(store.runs, reason: {"code" => "turn_ended_incomplete", "details" => {}})
      stored

      outcome = described_class.new(change: change, store: store, dispatch: dispatch, progress: progress, evaluation: evaluation, clock: -> { now })
        .recover("wr_1", actor: "sweep", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over", fail_if_incomplete: {"elapsed" => 900.4, "timeout" => 600})

      expect(outcome).to eq(:timed_out)
      expect(progress.calls).to eq([[:fail_step, "build", {"cause" => "timeout", "timeout" => 600, "elapsed" => 900, "code" => "step_timed_out", "code_source" => "engine"}]])
    end

    it "leaves a step that is no longer running alone" do
      stored(run_hash(step_state: "checking"))

      expect(recovery.recover("wr_1", actor: "sweep", turn_over: {"step" => "build", "attempt" => 1}, cause: "idle_turn_over")).to eq(:moved_on)
      expect(evaluation.calls).to be_empty
    end
  end

  describe "#review_stalled" do
    def delivered(round = {})
      reviewing({"delivery" => nil, "pane" => "%9", "window" => "@4", "server_pid" => "100"}.merge(round))
    end

    def stall(cause, **rest)
      recovery.review_stalled("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: cause, **rest)
    end

    it "decides a round whose review turn ended unseen as its turn's end would, writing step_stalled with the round" do
      stored(delivered)

      expect(stall("idle_turn_over", data: {"idle_for" => 1500})).to eq(:evaluated)
      expect(evaluation.calls).to eq([[:review_ended, "build"], [:review_end, "wr_1", {"step" => "build"}]])
      expect(event_types).to eq([["step_stalled", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "cause" => "idle_turn_over", "idle_for" => 1500}]])
    end

    it "reads the verdicts of a round whose review pane is gone or whose agent exited, as its turn's end would, so those written still count" do
      %w[pane_gone agent_gone].each do |cause|
        stored(delivered)

        expect(stall(cause)).to eq(:evaluated)
      end
      expect(evaluation.calls.map(&:first)).to eq(%i[review_ended review_end review_ended review_end])
      expect(progress.calls).to be_empty
    end

    it "delivers a round lost with a restarted tmux server again in a new window, counting it, and stops it once redeliver is spent" do
      stored(delivered)

      expect(stall("server_restarted")).to eq(:redelivered)
      expect(progress.calls).to eq([[:redeliver_round, "build", {new_server: true}]])
      expect(store.runs["wr_1"]["steps"]["build"]["review"]).not_to include("pane", "window", "server_pid")

      stored(delivered("redeliveries" => 2))
      expect(stall("server_restarted")).to eq(:stopped)
      expect(progress.calls.last[2][:problem]).to include("was restarted, and the round was delivered again 2 times")
    end

    it "changes nothing for a round that moved on: another round, another pane, still delivering, being judged, or stopped" do
      [delivered("round" => 2), delivered("pane" => "%8"), delivered("delivery" => "delivering"), delivered("recompute" => {"try" => 1}),
        delivered.merge("reason" => {"code" => "review_incomplete"})].each do |hash|
        stored(hash)
        expect(stall("pane_gone")).to eq(:moved_on)
      end
      expect(progress.calls).to be_empty
      expect(change.events).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy" do
        stored(delivered)

        expect(stall("pane_gone")).to eq(:busy)
      end
    end
  end

  describe "#time_out" do
    it "fails a step held on turn_ended_incomplete with step_timed_out" do
      stored(run_hash(reason: {"code" => "turn_ended_incomplete", "details" => {}}))

      expect(recovery.time_out("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)).to eq(:timed_out)

      expect(progress.calls).to eq([[:fail_step, "build", {"cause" => "timeout", "timeout" => 600, "elapsed" => 700, "code" => "step_timed_out", "code_source" => "engine"}]])
      expect(event_types).to eq([
        ["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "timed_out", "elapsed" => 700, "timeout" => 600}],
        ["step_recovered", {"step" => "build", "attempt" => 1, "action" => "failed", "cause" => "timed_out"}]
      ])
      stalled, recovered = event_types.map(&:last)
      expect(recovered["cause"]).to eq(stalled["cause"])
      expect(store.runs["wr_1"]["steps"]["build"]["state"]).to eq("failed")
    end
  end

  describe "#redeliver" do
    let(:dispatch) { RecordingDispatch.new(appends: true) }

    it "marks the failed attempt redelivered, starts a new one outside the budget and records the recovery" do
      stored(undelivered)

      expect(recovery.redeliver("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:redelivered)

      build = store.runs["wr_1"]["steps"]["build"]
      expect(build["attempts"].first).to include("redelivered" => true)
      expect(build["redelivery_pending"]).to eq(1)
      expect(dispatch.calls).to eq([[:dispatch, "wr_1", {cause: "redelivery", context: nil, budgeted: false, retry_of: nil}]])
      expect(event_types).to eq([["step_stalled", {"step" => "build", "attempt" => 1, "cause" => "undelivered", "code" => "pane_busy", "retry" => 1, "of" => 2}]])
      expect(store.events).to eq([["wr_1", "step_recovered", {"step" => "build", "attempt" => 1, "action" => "redelivered", "actor" => "sweep", "cause" => "redelivery", "from_state" => nil, "to_state" => nil}]])
    end

    context "when the line was refused again" do
      let(:dispatch) { RecordingDispatch.new }

      it "answers :not_delivered and records no recovery" do
        stored(undelivered)

        expect(recovery.redeliver("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:not_delivered)
        expect(store.events).to be_empty
      end
    end

    it "does nothing before the retry is due" do
      clock_at.replace([Time.utc(2026, 11, 10, 11, 0, 30)])
      stored(undelivered)

      expect(recovery.redeliver("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:moved_on)
      expect(dispatch.calls).to be_empty
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy" do
        stored(undelivered)

        expect(recovery.redeliver("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:busy)
      end
    end
  end

  describe "#retry_backoff" do
    it "starts a retry whose wait is over" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait}))

      expect(recovery.retry_backoff("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:retried)
      expect(progress.calls.map(&:first)).to eq([:start_retry])
    end

    it "answers :held when the retry is held on the token budget" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait, "budget_hold" => {"to" => "build"}}))

      expect(recovery.retry_backoff("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:held)
    end

    it "leaves a wait that is not over" do
      stored(run_hash(state: "waiting", step_state: "failed", reason: {"code" => "retry_backoff"}, extra: {"backoff" => backoff_wait(until_at: "2026-11-10T12:05:00Z")}))

      expect(recovery.retry_backoff("wr_1", actor: "sweep", step: "build", attempt: 1)).to eq(:moved_on)
      expect(progress.calls).to be_empty
    end
  end

  describe "#claim_interrupt and #interrupt_sent" do
    it "claims the interrupt once and records it sent" do
      stored

      outcome = recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)
      expect(outcome).to eq([:claimed, "2026-11-10T12:00:00Z"])
      expect(recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)).to eq(:repeat)

      expect(recovery.interrupt_sent("wr_1", actor: "sweep", step: "build", attempt: 1, claim_at: outcome.last, sent: true)).to eq(:recorded)
      expect(store.runs["wr_1"]["sweep"]["interrupt"]).to eq("state" => "sent", "at" => "2026-11-10T12:00:00Z")
      expect(event_types.map(&:first)).to eq(%w[step_stalled step_recovered])
    end

    it "keeps the run's own cause apart from the step's" do
      stored
      step_claim = recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)
      run_claim = recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 650, cause: "run_timed_out")
      expect(run_claim.first).to eq(:claimed)
      expect(recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 650, cause: "run_timed_out")).to eq(:repeat)

      expect(recovery.interrupt_sent("wr_1", actor: "sweep", step: "build", attempt: 1, claim_at: run_claim.last, sent: true, cause: "run_timed_out")).to eq(:recorded)
      marks = store.runs["wr_1"]["sweep"]
      expect(marks["run_interrupt"]["state"]).to eq("sent")
      expect(marks["interrupt"]["state"]).to eq("pending")
      expect(marks["stalled"].keys).to eq(%w[timed_out run_timed_out])
      expect(marks["recovered"].keys).to eq(%w[run_timed_out])
      expect(step_claim.first).to eq(:claimed)
    end

    it "lets a later sweep take over a pending claim past its hold" do
      stored
      recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)
      clock_at.replace([now + described_class::INTERRUPT_CLAIM_SECONDS + 1])

      expect(recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 761, timeout: 600)).to eq([:claimed, "2026-11-10T12:01:01Z"])
    end

    it "gives a claim back when the keys were not pressed, and leaves one taken over" do
      stored
      _, at = recovery.claim_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, elapsed: 700, timeout: 600)

      expect(recovery.interrupt_sent("wr_1", actor: "sweep", step: "build", attempt: 1, claim_at: "2026-11-10T11:00:00Z", sent: true)).to eq(:taken_over)
      expect(recovery.interrupt_sent("wr_1", actor: "sweep", step: "build", attempt: 1, claim_at: at, sent: false)).to eq(:released)
      expect(store.runs["wr_1"]["sweep"]).not_to have_key("interrupt")
    end
  end

  describe "#claim_round_interrupt and #round_interrupt_sent" do
    def delivered(round = {})
      reviewing({"delivery" => nil, "pane" => "%9", "window" => "@4", "server_pid" => "100"}.merge(round))
    end

    def claim(cause = "review_timed_out", **rest)
      recovery.claim_round_interrupt("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", elapsed: 1801, timeout: 1800, cause: cause, **rest)
    end

    def confirm(at, sent: true, cause: "review_timed_out")
      recovery.round_interrupt_sent("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", claim_at: at, sent: sent, cause: cause)
    end

    def round_marks = store.runs["wr_1"]["steps"]["build"]["review"]["sweep"]

    it "claims once on the round itself, records it sent, and writes step_stalled and step_recovered with the round" do
      stored(delivered)

      outcome = claim
      expect(outcome).to eq([:claimed, "2026-11-10T12:00:00Z"])
      expect(claim).to eq(:repeat)
      expect(confirm(outcome.last)).to eq(:recorded)

      expect(round_marks["interrupt"]).to eq("state" => "sent", "at" => "2026-11-10T12:00:00Z")
      expect(store.runs["wr_1"]).not_to have_key("sweep")
      expect(event_types).to eq([
        ["step_stalled", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "cause" => "review_timed_out", "elapsed" => 1801, "timeout" => 1800}],
        ["step_recovered", {"step" => "build", "attempt" => 1, "round" => 1, "pane" => "%9", "action" => "interrupted", "cause" => "review_timed_out"}]
      ])
    end

    it "keeps the round's cause and the run's apart, and never reads the reviewed attempt's own marks as the round's" do
      stored(delivered.merge("sweep" => {"step" => "build", "attempt" => 1, "run_interrupt" => {"state" => "sent", "at" => "2026-11-10T11:00:00Z"}, "stalled" => {"run_timed_out" => "x"}}))

      round_claim = claim
      run_claim = claim("run_timed_out")
      expect([round_claim.first, run_claim.first]).to eq(%i[claimed claimed])
      confirm(run_claim.last, cause: "run_timed_out")

      expect(round_marks["interrupt"]["state"]).to eq("pending")
      expect(round_marks["run_interrupt"]["state"]).to eq("sent")
      expect(round_marks["stalled"].keys).to eq(%w[review_timed_out run_timed_out])
      expect(event_types.map(&:first)).to eq(%w[step_stalled step_stalled step_recovered])
    end

    it "lets a later sweep take over a pending claim past its hold, and gives back one whose keys were not pressed" do
      stored(delivered)
      _, at = claim
      clock_at.replace([now + described_class::INTERRUPT_CLAIM_SECONDS + 1])
      _, later = claim

      expect(confirm(at)).to eq(:taken_over)
      expect(confirm(later, sent: false)).to eq(:released)
      expect(round_marks).not_to have_key("interrupt")
    end

    it "claims nothing for a round that moved on: another round, another pane, still delivering, being judged, or stopped" do
      [delivered("round" => 2), delivered("pane" => "%8"), delivered("delivery" => "delivering"), delivered("recompute" => {"try" => 1}),
        delivered.merge("reason" => {"code" => "review_incomplete"})].each do |hash|
        stored(hash)
        expect(claim).to eq(:moved_on)
      end
      expect(change.events).to be_empty
    end

    it "confirms a press on a round whose end is being judged by now, but not on one that ended" do
      stored(delivered)
      _, at = claim
      store.runs["wr_1"]["steps"]["build"]["review"]["recompute"] = {"try" => 1}
      expect(confirm(at)).to eq(:recorded)

      stored(delivered)
      _, at = claim
      store.runs["wr_1"]["steps"]["build"].delete("review")
      expect(confirm(at)).to eq(:moved_on)
    end

    context "when another process is changing the run" do
      let(:busy) { ["wr_1"] }

      it "answers :busy for the claim" do
        stored(delivered)

        expect(claim).to eq(:busy)
      end
    end
  end
end
