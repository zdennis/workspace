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
