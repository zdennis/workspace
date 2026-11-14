require "spec_helper"

RSpec.describe Workspace::WorkflowTransitions do
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }

  def run_with(steps:, current: steps.keys.first, **fields)
    {"current" => current, "state" => "running", "steps" => steps, "definition" => {"max_attempts" => 3, "steps" => steps.keys.map { |id| {"id" => id} }}}.merge(fields)
  end

  def step(state, *attempts)
    {"state" => state, "attempts" => attempts}
  end

  describe ".delivery" do
    let(:started) { Time.utc(2026, 10, 4, 12, 0, 0) }

    it "says nothing for no attempt, or one with no mark" do
      expect(described_class.delivery(nil, started)).to be_nil
      expect(described_class.delivery({"started_at" => started.iso8601}, started)).to be_nil
    end

    it "is delivering up to the window, and unknown past it" do
      attempt = {"started_at" => started.iso8601(3), "delivery" => "delivering"}
      expect(described_class.delivery(attempt, started + described_class::DELIVERY_WINDOW)).to eq(:delivering)
      expect(described_class.delivery(attempt, started + described_class::DELIVERY_WINDOW + 1)).to eq(:unknown)
    end

    it "is unknown when the attempt's start can't be read" do
      expect(described_class.delivery({"started_at" => "garbled", "delivery" => "delivering"}, started)).to eq(:unknown)
      expect(described_class.delivery({"started_at" => nil, "delivery" => "delivering"}, started)).to eq(:unknown)
    end
  end

  describe "review rounds" do
    let(:started) { Time.utc(2026, 10, 4, 12, 0, 0) }
    let(:window) { described_class::DELIVERY_WINDOW }

    def round(**fields)
      {"round" => 1, "delivery" => "delivering", "started_at" => started.iso8601(3), "redeliveries" => 0}.merge(fields.transform_keys(&:to_s))
    end

    def reviewing(round_fields = {}, **fields)
      run_with(steps: {"plan" => step("reviewing", {"n" => 1, "outcome" => "checks_passed"}).merge("review" => round(**round_fields))}, **fields).tap do |run|
        run["definition"]["redeliver"] = 2
      end
    end

    it "is delivering within the window and, past it, while its holder is alive" do
      expect(described_class.round_delivery(round, started + window)).to eq(:delivering)
      holder = {"pid" => 41, "started_at" => "x"}
      expect(described_class.round_delivery(round(holder: holder), started + window + 1, alive: ->(found) { found == holder })).to eq(:delivering)
      expect(described_class.round_delivery(round(holder: holder), started + window + 1)).to eq(:delivering)
    end

    it "is unknown past the window with its holder gone or none recorded, and failed once a failure is stored" do
      expect(described_class.round_delivery(round(holder: {"pid" => 41}), started + window + 1, alive: ->(_) { false })).to eq(:unknown)
      expect(described_class.round_delivery(round, started + window + 1)).to eq(:unknown)
      expect(described_class.round_delivery(round(started_at: "garbled"), started)).to eq(:unknown)
      expect(described_class.round_delivery(round(delivery: "failed"), started)).to eq(:failed)
    end

    it "takes a holder stored with no start time for alive only within a multiple of the window, so a reused pid does not hold the mark for ever" do
      untimed = round(holder: {"pid" => 41, "started" => nil})
      limit = described_class::UNTIMED_HOLDER_LIMIT
      expect(limit).to eq(4 * window)

      expect(described_class.round_delivery(untimed, started + limit, alive: ->(_) { true })).to eq(:delivering)
      expect(described_class.round_delivery(untimed, started + limit + 1, alive: ->(_) { true })).to eq(:unknown)
      timed = round(holder: {"pid" => 41, "started" => "Sat Oct  4 11:59:00 2026"})
      expect(described_class.round_delivery(timed, started + limit + 1, alive: ->(_) { true })).to eq(:delivering)
    end

    it "says nothing for a delivered round or none" do
      expect(described_class.round_delivery(round(delivery: nil), started + window + 1)).to be_nil
      expect(described_class.round_delivery(nil, started)).to be_nil
    end

    it "is due for a lapsed or failed delivery while redeliveries last, exhausted after" do
      expect(described_class.round_redelivery(reviewing, started)).to be_nil
      expect(described_class.round_redelivery(reviewing, started + window + 1)).to eq(state: :due, round: 1, retries: 0, limit: 2, mark: :unknown, wait: 0)
      expect(described_class.round_redelivery(reviewing({delivery: "failed", redeliveries: 2}), started)).to eq(state: :exhausted, round: 1, retries: 2, limit: 2, mark: :failed, wait: 0)
    end

    it "waits out the undelivered line's backoff from a stored failure's time before a failed round is due" do
      failed = reviewing({delivery: "failed", redeliveries: 1, failure: {"code" => "agent_not_ready", "at" => started.iso8601}})
      backoff = described_class::REDELIVER_BACKOFF[1]

      expect(described_class.round_redelivery(failed, started + 10)).to include(state: :waiting, wait: backoff - 10)
      expect(described_class.round_redelivery(failed, started + backoff)).to include(state: :due, wait: 0)
      expect(described_class.round_redelivery(reviewing({delivery: "failed", failure: {"at" => "garbled"}}), started)).to include(state: :due)
    end

    it "is exhausted at once for a failure no delivery again gets past" do
      custom = reviewing({delivery: "failed", failure: {"code" => "review_custom_socket", "at" => started.iso8601}})

      expect(described_class.round_redelivery(custom, started)).to include(state: :exhausted, retries: 0, limit: 2)
    end

    it "leaves a lapsed round with a live holder alone, and is due once the holder is gone" do
      held = reviewing({holder: {"pid" => 41, "started" => "x"}})

      expect(described_class.round_redelivery(held, started + window + 1, alive: ->(_) { true })).to be_nil
      expect(described_class.round_redelivery(held, started + window + 1, alive: ->(_) { false })).to include(state: :due, mark: :unknown)
    end

    it "is nil for a stopped round, a parked run or a step not being reviewed" do
      expect(described_class.round_redelivery(reviewing({delivery: "failed"}, "reason" => {"code" => "review_incomplete"}), started)).to be_nil
      expect(described_class.round_redelivery(reviewing({delivery: "failed"}, "parked" => {"expires_at" => started.iso8601}), started)).to be_nil
      expect(described_class.round_redelivery(run_with(steps: {"plan" => step("running")}), started)).to be_nil
    end

    it "wakes a run whose round has to be delivered again, or stopped once its deliveries again are spent, as :review" do
      expect(described_class.wakeable?(reviewing, started)).to be_nil
      expect(described_class.wakeable?(reviewing, started + window + 1)).to eq(:review)
      expect(described_class.wakeable?(reviewing({delivery: "failed"}), started)).to eq(:review)
      expect(described_class.wakeable?(reviewing({delivery: "failed", redeliveries: 2}), started)).to eq(:review)
    end

    it "does not wake a round whose failure waits out its backoff, a stopped round, or a slow delivery whose holder lives" do
      waiting = reviewing({delivery: "failed", failure: {"code" => "agent_not_ready", "at" => started.iso8601}})
      expect(described_class.wakeable?(waiting, started + 1)).to be_nil
      expect(described_class.wakeable?(reviewing({delivery: "failed"}, "reason" => {"code" => "review_incomplete"}, "state" => "waiting"), started)).to be_nil
      held = reviewing({holder: {"pid" => 41, "started" => "x"}})
      expect(described_class.wakeable?(held, started + window + 1, alive: ->(_) { true })).to be_nil
      expect(described_class.wakeable?(held, started + window + 1)).to be_nil
      expect(described_class.wakeable?(held, started + window + 1, alive: ->(_) { false })).to eq(:review)
    end

    describe ".lost_round?" do
      let(:judging) { {delivery: nil, recompute: {"started_at" => started.iso8601, "try" => 1}} }

      it "is true only once a recompute's mark is older than the delivery window with nothing reported back" do
        expect(described_class.lost_round?(reviewing(judging), started + window)).to be(false)
        expect(described_class.lost_round?(reviewing(judging), started + window + 1)).to be(true)
      end

      it "is false for a round with no recompute, a stopped round, a parked run and a step not being reviewed" do
        late = started + window + 1
        expect(described_class.lost_round?(reviewing({delivery: nil}), late)).to be(false)
        expect(described_class.lost_round?(reviewing(judging, "reason" => {"code" => "review_stale"}), late)).to be(false)
        expect(described_class.lost_round?(reviewing(judging, "parked" => {"id" => "p"}), late)).to be(false)
        expect(described_class.lost_round?(run_with(steps: {"plan" => step("checking")}), late)).to be(false)
      end

      it "takes a mark with no readable start as lost" do
        expect(described_class.lost_round?(reviewing({recompute: {"started_at" => "garbled", "try" => 1}}), started)).to be(true)
      end

      it "wakes the run as :round once lost, and not before" do
        expect(described_class.wakeable?(reviewing(judging), started + window)).to be_nil
        expect(described_class.wakeable?(reviewing(judging), started + window + 1)).to eq(:round)
      end
    end

    it "starts no attempt on a resume of a step being reviewed" do
      expect(described_class.starts_attempt?(reviewing({delivery: nil}, "reason" => {"code" => "review_incomplete"}), from: nil, pane: nil)).to be(false)
      expect(described_class.starts_attempt?(reviewing, from: "plan", pane: nil)).to be(true)
    end

    it "starts no attempt but a round on a resume of a round the budget or timeout held" do
      %w[budget_hold timeout_hold].each do |key|
        held = reviewing({delivery: nil, started_at: nil}).merge(key => {"review_round" => 2}, "reason" => {"code" => "budget_spent"})
        expect(described_class.round_hold?(held)).to be(true)
        expect(described_class.starts_attempt?(held, from: nil, pane: "%0")).to be(false)
        expect(described_class.starts_round?(held, from: nil)).to be(true)
        expect(described_class.starts_round?(held, from: "plan")).to be(false)
      end
      attempt_hold = run_with(steps: {"plan" => step("failed")}).merge("budget_hold" => {"pane" => "%3"})
      expect(described_class.round_hold?(attempt_hold)).to be(false)
      expect(described_class.starts_attempt?(attempt_hold, from: nil, pane: nil)).to be(true)
    end

    it "starts a round on a resume of a stopped round, and not on a redelivery of a lapsed one or for another step" do
      expect(described_class.starts_round?(reviewing({delivery: nil}, "reason" => {"code" => "review_incomplete"}), from: nil)).to be(true)
      expect(described_class.starts_round?(reviewing({ended_at: "2026-10-04T12:05:00Z"}), from: nil)).to be(true)
      expect(described_class.starts_round?(reviewing({delivery: "failed"}), from: nil)).to be(false)
      expect(described_class.starts_round?(run_with(steps: {"plan" => step("failed")}), from: nil)).to be(false)
    end

    it "starts no round on a resume of a round waiting for its review.uses, which was allowed when it was reached" do
      waiting = reviewing({delivery: nil, held: "waiting_lock"}, "reason" => {"code" => "waiting_lock"})
      expect(described_class.starts_round?(waiting, from: nil)).to be(false)
      expect(described_class.starts_attempt?(waiting, from: nil, pane: nil)).to be(false)
    end

    it "leaves a live round alone and lets a stopped or lapsed one be acted on" do
      run = reviewing(delivery: nil)
      expect(described_class.left_alone(run, run["steps"]["plan"], nil, nil, started, -> { "%3" })).to eq("the review round of step plan is still running")
      stopped = reviewing({delivery: nil}, "reason" => {"code" => "review_incomplete"})
      expect(described_class.left_alone(stopped, stopped["steps"]["plan"], nil, nil, started, -> { "%3" })).to be_nil
      lapsed = reviewing
      expect(described_class.left_alone(lapsed, lapsed["steps"]["plan"], nil, nil, started + window + 1, -> { "%3" })).to be_nil
    end

    it "leaves a lapsed round alone while its holder lives, and lets it be acted on once the holder is gone" do
      held = reviewing({holder: {"pid" => 41, "started" => "x"}})
      later = started + window + 1

      expect(described_class.left_alone(held, held["steps"]["plan"], nil, nil, later, -> { "%3" }, alive: ->(_) { true })).to eq("the review round of step plan is still running")
      expect(described_class.left_alone(held, held["steps"]["plan"], nil, nil, later, -> { "%3" }, alive: ->(_) { false })).to be_nil
      expect(described_class.left_alone(held, held["steps"]["plan"], nil, nil, started, -> { "%3" }, alive: ->(_) { false })).to eq("the review round of step plan is still running")
    end
  end

  describe ".parked" do
    let(:run) { {"parked" => {"expires_at" => now.iso8601}} }

    it "is nil with no park" do
      expect(described_class.parked({}, now)).to be_nil
    end

    it "waits up to expires_at and is expired past it" do
      expect(described_class.parked(run, now)).to eq(:waiting)
      expect(described_class.parked(run, now + 1)).to eq(:expired)
    end

    it "reads an unreadable time as expired" do
      expect(described_class.parked({"parked" => {"expires_at" => "garbled"}}, now)).to eq(:expired)
      expect(described_class.parked({"parked" => {"expires_at" => nil}}, now)).to eq(:expired)
    end
  end

  describe ".wakeable?" do
    let(:lock_wait) { {"code" => "waiting_lock"} }
    let(:lost_check) do
      run_with(steps: {"verify" => step("checking", {"n" => 1, "check" => {"started_at" => "2026-10-04T10:00:00Z"}})})
    end

    it "answers :parked ahead of a lock wait" do
      expect(described_class.wakeable?(run_with(:steps => {"a" => step("waiting")}, "parked" => {"expires_at" => now.iso8601}, "reason" => lock_wait), now)).to eq(:parked)
    end

    it "answers :parked ahead of a lost check" do
      expect(described_class.wakeable?(lost_check.merge("parked" => {"expires_at" => now.iso8601}), now)).to eq(:parked)
    end

    it "still answers :lock and :check with no park" do
      expect(described_class.wakeable?(run_with(:steps => {"a" => step("waiting")}, "reason" => lock_wait), now)).to eq(:lock)
      expect(described_class.wakeable?(lost_check, now)).to eq(:check)
    end

    it "answers :background once a background hold is past its limit, and nil before" do
      hold = ->(seen) { run_with(:steps => {"a" => step("running")}, "reason" => {"code" => "turn_ended_background", "seen_at" => seen.iso8601}) }
      expect(described_class.wakeable?(hold.call(now - described_class::BACKGROUND_HOLD), now)).to be_nil
      expect(described_class.wakeable?(hold.call(now - described_class::BACKGROUND_HOLD - 1), now)).to eq(:background)
    end

    it "answers :backoff once a retry's wait is over" do
      waiting = run_with(:steps => {"a" => step("failed")}, "state" => "waiting", "backoff" => {"until" => now.iso8601, "to" => "a"})
      expect(described_class.wakeable?(waiting, now - 1)).to be_nil
      expect(described_class.wakeable?(waiting, now)).to eq(:backoff)
    end
  end

  describe "attempt counts" do
    let(:run) do
      run_with(:steps => {"a" => step("failed", {"n" => 1}, {"n" => 2, "redelivered" => true}), "b" => step("running", {"n" => 1})}, "extra_attempts" => 1)
    end

    it "counts attempts but those the sweep typed again" do
      expect(described_class.attempts_made(run)).to eq(2)
    end

    it "adds extra attempts to the definition's allowance" do
      expect(described_class.attempt_allowance(run)).to eq(4)
      expect(described_class.attempts_spent?(run)).to be(false)
      expect(described_class.extra_attempts_needed(run)).to eq(-1)
    end

    it "is never spent for a definition with no max_attempts" do
      expect(described_class.attempts_spent?(run.merge("definition" => {}))).to be(false)
    end
  end

  describe "step attempt counts" do
    let(:run) do
      run_with(steps: {"a" => step("failed", {"n" => 1}, {"n" => 2, "redelivered" => true}, {"n" => 3}), "b" => step("pending")}).tap do |run|
        run["definition"]["steps"].first["max_attempts"] = 2
        run["steps"]["a"]["extra_attempts"] = 1
      end
    end

    it "counts a step's attempts but those the sweep typed again" do
      expect(described_class.step_attempts_made(run, "a")).to eq(2)
      expect(described_class.step_attempts_made(run, "b")).to eq(0)
    end

    it "adds the step's extra attempts to its cap, and has no allowance without a cap" do
      expect(described_class.step_allowance(run, "a")).to eq(3)
      expect(described_class.step_allowance(run, "b")).to be_nil
    end

    it "is spent at the allowance, and never for a step with no cap or an old run" do
      expect(described_class.step_attempts_spent?(run, "a")).to be(false)
      run["steps"]["a"]["extra_attempts"] = 0
      expect(described_class.step_attempts_spent?(run, "a")).to be(true)
      expect(described_class.step_attempts_spent?(run, "b")).to be(false)
      expect(described_class.step_attempts_spent?(run.merge("definition" => {}), "a")).to be(false)
    end

    it "needs one more than the shortfall" do
      run["steps"]["a"]["extra_attempts"] = 0
      expect(described_class.step_extra_attempts_needed(run, "a")).to eq(1)
      expect(described_class.step_extra_attempts_needed(run, "b")).to be_nil
    end

    it "targets from, else a waiting retry's step, else the current step" do
      expect(described_class.target_step(run, from: "b")).to eq("b")
      expect(described_class.target_step(run.merge("backoff" => {"to" => "b"}))).to eq("b")
      expect(described_class.target_step(run)).to eq("a")
    end
  end

  describe "review round counts" do
    let(:run) do
      run_with(steps: {"a" => step("failed", {"n" => 1}), "b" => step("pending")}).tap do |run|
        run["definition"]["steps"].first["review"] = {"from" => %w[skeptic], "max_rounds" => 2}
        run["definition"]["steps"].last["review"] = {"from" => %w[skeptic]}
      end
    end

    it "allows a step its review's max_rounds, the default when the stored review names none, and nothing without a review" do
      expect(described_class.review_rounds_allowance(run, "a")).to eq(2)
      expect(described_class.review_rounds_allowance(run, "b")).to eq(Workspace::WorkflowReviewSpec::DEFAULT_MAX_ROUNDS)
      run["definition"]["steps"].last.delete("review")
      expect(described_class.review_rounds_allowance(run, "b")).to be_nil
    end

    it "is spent once the step's review_rounds reach its allowance, and never without a review" do
      expect(described_class.review_rounds_spent?(run, "a")).to be false
      run["steps"]["a"]["review_rounds"] = 2
      expect(described_class.review_rounds_spent?(run, "a")).to be true
      run["definition"]["steps"].first.delete("review")
      expect(described_class.review_rounds_spent?(run, "a")).to be false
    end
  end

  describe ".rejection_limit and .rounds_refuse_resume?" do
    let(:run) do
      run_with(steps: {"a" => step("failed", {"n" => 1}), "b" => step("pending")}).tap do |run|
        run["current"] = "a"
        run["definition"]["max_attempts"] = 5
        run["definition"]["steps"].first["review"] = {"from" => %w[skeptic], "max_rounds" => 2}
        run["steps"]["a"]["review_rounds"] = 1
      end
    end

    it "lets a rejected step try again with rounds and attempts left, and names the first limit spent: run, step, rounds" do
      expect(described_class.rejection_limit(run)).to eq("rounds" => 1, "max_rounds" => 2)
      run["steps"]["a"]["review_rounds"] = 2
      expect(described_class.rejection_limit(run)).to include("limit" => "rounds")
      run["definition"]["steps"].first["max_attempts"] = 1
      expect(described_class.rejection_limit(run)).to include("limit" => "step", "attempts" => 1, "max_attempts" => 1)
      run["definition"]["max_attempts"] = 1
      expect(described_class.rejection_limit(run)).to include("limit" => "run", "attempts" => 1, "max_attempts" => 1)
    end

    it "refuses a plain resume only once the rounds are spent, of a rejected step or a round that would start" do
      run["reason"] = {"code" => "review_rejected"}
      expect(described_class.rounds_refuse_resume?(run)).to be false
      run["steps"]["a"]["review_rounds"] = 2
      expect(described_class.rounds_refuse_resume?(run)).to be true
      run["reason"] = {"code" => "failed_check"}
      expect(described_class.rounds_refuse_resume?(run)).to be false
      run["steps"]["a"].merge!("state" => "reviewing", "review" => {"round" => 2, "ended_at" => "x"})
      run["reason"] = {"code" => "review_incomplete"}
      expect(described_class.rounds_refuse_resume?(run)).to be true
    end
  end

  describe ".starts_attempt?" do
    let(:running) { run_with(steps: {"a" => step("running")}) }

    it "starts one for --from, a failed step, or a running step given a pane" do
      expect(described_class.starts_attempt?(running, from: "a", pane: nil)).to be(true)
      expect(described_class.starts_attempt?(run_with(steps: {"a" => step("failed")}), from: nil, pane: nil)).to be(true)
      expect(described_class.starts_attempt?(running, from: nil, pane: "%1")).to be(true)
    end

    it "does not for a running step with no pane, a check, or a lock wait" do
      expect(described_class.starts_attempt?(running, from: nil, pane: nil)).to be(false)
      expect(described_class.starts_attempt?(run_with(steps: {"a" => step("checking")}), from: nil, pane: nil)).to be(false)
      expect(described_class.starts_attempt?(run_with(:steps => {"a" => step("waiting")}, "reason" => {"code" => "waiting_lock"}), from: nil, pane: nil)).to be(false)
    end
  end

  describe ".backoff" do
    let(:run) { run_with(:steps => {"a" => step("failed")}, "state" => "waiting", "backoff" => {"until" => (now + 120).iso8601, "to" => "a"}) }

    it "says how long a wait has left, then that it is due" do
      expect(described_class.backoff(run, now)).to include(state: :waiting, wait: 120, to: "a")
      expect(described_class.backoff(run, now + 120)).to include(state: :due, wait: 0)
    end

    it "is nil for a run that is not waiting or has no backoff" do
      expect(described_class.backoff(run.merge("state" => "running"), now)).to be_nil
      expect(described_class.backoff(run.except("backoff"), now)).to be_nil
    end
  end

  describe ".redelivery" do
    let(:run) do
      run_with(:steps => {"a" => step("waiting", {"n" => 1, "outcome" => "not_delivered", "ended_at" => now.iso8601})},
        "state" => "waiting", "reason" => {"code" => "waiting_you", "details" => {"kind" => "dispatch", "error" => "pane_busy"}})
        .tap { |each| each["definition"]["redeliver"] = 2 }
    end

    it "waits out the first backoff, then is due" do
      expect(described_class.redelivery(run, now)).to include(state: :waiting, wait: 60, retries: 0, limit: 2)
      expect(described_class.redelivery(run, now + 60)).to include(state: :due)
    end

    it "is nil for a code a retry could type twice" do
      run["reason"]["details"]["error"] = "not_delivered"
      expect(described_class.redelivery(run, now)).to be_nil
    end
  end

  describe ".sweep_marks" do
    let(:run) do
      run_with(:steps => {"a" => step("running", {"n" => 2})}, "sweep" => {"step" => "a", "attempt" => 2, "stalled" => {}})
    end

    it "gives the marks for the current attempt and nothing for another" do
      expect(described_class.sweep_marks(run)).to eq("step" => "a", "attempt" => 2, "stalled" => {})
      expect(described_class.sweep_marks(run.merge("sweep" => {"step" => "a", "attempt" => 1}))).to eq({})
    end
  end

  describe ".park_timeout_message" do
    it "names the pane, and adds the lost check only for a checking step" do
      expect(described_class.park_timeout_message("%5")).to start_with("the turn in pane %5 did not end within 1 hour")
      expect(described_class.park_timeout_message("%5")).not_to include("A check that finished")
      expect(described_class.park_timeout_message("%5", checking: true)).to end_with("resume the run to run it again.")
    end
  end

  describe ".fingerprint" do
    let(:run) { run_with(:steps => {"a" => step("running", {"n" => 1})}, "reason" => {"code" => "turn_ended_background", "since" => "t", "seen_at" => "u"}) }

    it "leaves out what a reader cannot see change" do
      other = run.merge("reason" => run["reason"].merge("seen_at" => "v", "details" => {"tasks" => []}))
      expect(described_class.fingerprint(other)).to eq(described_class.fingerprint(run))
    end

    it "changes with the step's state or a park" do
      expect(described_class.fingerprint(run)).not_to eq(described_class.fingerprint(run.merge("parked" => {})))
    end
  end

  describe ".sweep_target?" do
    let(:run) { run_with(steps: {"a" => step("running", {"n" => 1})}) }

    it "needs the step and attempt the sweep saw" do
      expect(described_class.sweep_target?(run, "a", 1, false, now)).to be(true)
      expect(described_class.sweep_target?(run, "b", 1, false, now)).to be(false)
      expect(described_class.sweep_target?(run, "a", 2, false, now)).to be(false)
    end

    it "for a running step needs no park and no reason, except an incomplete turn when allowed" do
      expect(described_class.sweep_target?(run, "a", 1, true, now)).to be(true)
      expect(described_class.sweep_target?(run.merge("parked" => {}), "a", 1, true, now)).to be(false)
      stopped = run.merge("reason" => {"code" => "turn_ended_incomplete"})
      expect(described_class.sweep_target?(stopped, "a", 1, true, now)).to be(false)
      expect(described_class.sweep_target?(stopped, "a", 1, :or_incomplete, now)).to be(true)
    end
  end

  describe ".left_alone" do
    let(:run) { run_with(steps: {"a" => step("running", {"n" => 1})}) }

    it "says an agent is working when nothing shows the turn over" do
      state = run["steps"]["a"]
      expect(described_class.left_alone(run, state, nil, nil, now, -> { "%1" })).to eq("an agent is working on step a")
      expect(described_class.left_alone(run, state, "%2", nil, now, -> { "%1" })).to be_nil
      expect(described_class.left_alone(run, state, nil, {"step" => "a", "attempt" => 1}, now, -> { "%1" })).to be_nil
    end

    it "names the bound pane while the line is still being delivered" do
      state = step("running", {"n" => 1, "delivery" => "delivering", "started_at" => now.iso8601})
      expect(described_class.left_alone(run, state, nil, nil, now, -> { "%1" })).to eq("step a's line is still being delivered to pane %1")
    end
  end

  describe ".budget_details" do
    it "names the run and step and takes the reading's counts, tokens and extra tokens" do
      reading = {"tokens" => 100, "action" => "hold", "extra_tokens" => 0, "allowance" => 100, "used" => 120, "counted" => 2, "uncounted" => 0,
                 "measured" => true, "spent" => true, "needed" => 21, "suggested" => 100_000}

      expect(described_class.budget_details({"id" => "wr_1", "current" => "plan"}, reading)).to eq("run_id" => "wr_1", "step" => "plan",
        "used" => 120, "allowance" => 100, "counted" => 2, "uncounted" => 0, "needed" => 21, "suggested" => 100_000, "tokens" => 100, "extra_tokens" => 0)
    end
  end

  describe ".stop_reason" do
    let(:details) { {"step" => "a", "attempt" => 1} }
    let(:stored) { {"code" => "turn_ended_incomplete", "since" => "2026-10-04T11:00:00Z", "details" => details} }

    it "keeps the stored since for the same stop" do
      expect(described_class.stop_reason(stored, nil, "turn_ended_incomplete", details, "2026-10-04T12:00:00Z")).to eq(stored)
    end

    it "is fresh for another attempt, or once a newer turn has started" do
      fresh = {"code" => "turn_ended_incomplete", "since" => "2026-10-04T12:00:00Z", "details" => {"step" => "a", "attempt" => 2}}
      expect(described_class.stop_reason(stored, nil, "turn_ended_incomplete", fresh["details"], fresh["since"])).to eq(fresh)
      expect(described_class.stop_reason(stored, Time.utc(2026, 10, 4, 11, 30), "turn_ended_incomplete", details, fresh["since"])).to include("since" => fresh["since"])
    end
  end

  describe ".after_failure" do
    let(:failure) { {"cause" => "check", "code" => "check_failed"} }

    def failed_run(on_fail, loops: {}, attempts: 1)
      run_with(steps: {"verify" => step("failed", *Array.new(attempts) { |index| {"n" => index + 1} })}).merge("loops" => loops).tap do |run|
        run["definition"]["steps"].first["on_fail"] = on_fail if on_fail
      end
    end

    it "stops a step with no on_fail" do
      expect(described_class.after_failure(failed_run(nil), failure)).to eq(kind: :stop)
    end

    it "loops back at once, counting the edge, while loops and attempts last" do
      run = failed_run({"goto" => "verify", "max" => 2}, loops: {"verify->verify" => 1})

      expect(described_class.after_failure(run, failure)).to eq(kind: :loop, edge: "verify->verify", to: "verify", count: 2, wait: nil)
    end

    it "carries the on_fail backoff as the wait" do
      run = failed_run({"goto" => "verify", "max" => 2, "backoff" => 30})

      expect(described_class.after_failure(run, failure)).to include(kind: :loop, wait: 30)
    end

    it "stops once the edge's loops are used up, or the run's attempts" do
      expect(described_class.after_failure(failed_run({"goto" => "verify", "max" => 1}, loops: {"verify->verify" => 1}), failure)).to eq(kind: :stop)
      expect(described_class.after_failure(failed_run({"goto" => "verify", "max" => 5}, attempts: 3), failure)).to eq(kind: :stop)
    end

    it "stops on a code or cause on_fail excepts" do
      expect(described_class.after_failure(failed_run({"goto" => "verify", "max" => 2, "except" => ["check_failed"]}), failure)).to eq(kind: :stop)
      expect(described_class.after_failure(failed_run({"goto" => "verify", "max" => 2, "except" => ["check"]}), failure)).to eq(kind: :stop)
    end
  end

  describe ".after_failure with a step cap" do
    let(:failure) { {"cause" => "check", "code" => "check_failed"} }

    def two_steps(cap, made, extra: 0)
      run = run_with(steps: {"implement" => step("passed", *Array.new(made) { |index| {"n" => index + 1} }), "verify" => step("failed", {"n" => 1})}, current: "verify")
        .merge("loops" => {})
      run["definition"]["max_attempts"] = 20
      run["definition"]["steps"][0]["max_attempts"] = cap
      run["definition"]["steps"][1]["on_fail"] = {"goto" => "implement", "max" => 5}
      run["steps"]["implement"]["extra_attempts"] = extra
      run
    end

    it "loops into a target with attempts left" do
      expect(described_class.after_failure(two_steps(2, 1), failure)).to include(kind: :loop, to: "implement")
    end

    it "stops, naming the step and limit, when the target's cap is spent" do
      expect(described_class.after_failure(two_steps(2, 2), failure)).to eq(kind: :stop, limit: :step, step: "implement")
    end

    it "loops again once extra attempts cover it" do
      expect(described_class.after_failure(two_steps(2, 2, extra: 1), failure)).to include(kind: :loop)
    end

    it "ignores a target with no cap" do
      expect(described_class.after_failure(two_steps(nil, 4), failure)).to include(kind: :loop)
    end
  end

  describe "accepting a guard stop" do
    def guard_stop(guard, cause: "guard") = {"code" => "failed_check", "details" => {"cause" => cause, "guard" => guard}}

    def stopped(reason, step_state: "failed", state: "waiting", base_sha: "a" * 40)
      run_with(steps: {"plan" => step(step_state, {"n" => 1})}).merge("state" => state, "reason" => reason, "base_sha" => base_sha)
    end

    it "names the guard of each guard stop a person may accept, no_commit with no base_sha too" do
      described_class::ACCEPTABLE_GUARDS.each do |guard|
        expect(described_class.acceptable_guard(stopped(guard_stop(guard)))).to eq(guard)
      end
      expect(described_class.acceptable_guard(stopped(guard_stop("no_commit"), base_sha: nil))).to eq("no_commit")
      expect(described_class::ACCEPTABLE_GUARDS).to match_array(Workspace::WorkflowGuard::CODES)
      expect(described_class.guard_acceptable?(Workspace::WorkflowRun.from_h(stopped(guard_stop("head_moved"))))).to be true
    end

    it "takes no other stop, a warning-only guard, a run not waiting or a step not failed" do
      expect(described_class.acceptable_guard(stopped({"code" => "failed_check", "details" => {"cause" => "check", "code" => "check_failed"}}))).to be_nil
      expect(described_class.acceptable_guard(stopped(guard_stop("config_changed")))).to be_nil
      expect(described_class.acceptable_guard(stopped({"code" => "waiting_you", "details" => {"cause" => "guard", "guard" => "head_moved"}}))).to be_nil
      expect(described_class.acceptable_guard(stopped(guard_stop("head_moved"), state: "running"))).to be_nil
      expect(described_class.acceptable_guard(stopped(guard_stop("head_moved"), step_state: "running"))).to be_nil
      expect(described_class.acceptable_guard(stopped(nil))).to be_nil
      expect(described_class.acceptable_guard(stopped({"code" => "failed_check", "details" => "garbled"}))).to be_nil
      expect(described_class.guard_acceptable?(stopped(nil))).to be false
    end

    it "words the line the next attempt reads before the note" do
      expect(described_class.guard_accepted_line("head_moved", "plan", "0123456789abcdef")).to eq("A person accepted the `head_moved` stop on `plan`; the guard now measures from HEAD `0123456789ab`.")
      expect(described_class.guard_accepted_line("no_commit", "plan", nil)).to eq("A person accepted the `no_commit` stop on `plan`; the checkout has no commit, so the guard has no HEAD to measure from.")
    end
  end

  describe "failure words and codes" do
    it "takes an agent's code, else the engine's" do
      expect(described_class.code_for("reported", "oops")).to eq("code" => "oops", "code_source" => "agent")
      expect(described_class.code_for("reported", nil)).to eq("code" => "reported", "code_source" => "engine")
    end

    it "builds a require failure without its nil fields" do
      failure = described_class.require_failure({"proof" => "commits", "detail" => "none", "code" => "require_commits"})
      expect(failure).to eq("cause" => "require", "require" => "commits", "detail" => "none", "code" => "require_commits", "code_source" => "engine")
    end

    it "words each cause" do
      expect(described_class.failure_text({"cause" => "timeout", "timeout" => 60, "elapsed" => 61})).to eq("the step ran past its 60 second time limit (61 seconds in)")
      expect(described_class.failure_text({"cause" => "guard", "guard" => "head_moved", "base_sha" => "a" * 40, "head" => "b" * 40})).to eq("HEAD moved from #{"a" * 12} to #{"b" * 12} since the run started")
      expect(described_class.failure_text({"cause" => "reported", "summary" => "no"})).to eq("its agent reported failure: no")
      expect(described_class.failure_text({"exit_code" => 2, "log" => "l"})).to eq("its check exited 2 (log: l)")
    end
  end
end
