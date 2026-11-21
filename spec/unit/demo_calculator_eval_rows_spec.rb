require "spec_helper"
require "json"
require File.join(PROJECT_ROOT, "script/demo_calculator/eval_rows")

RSpec.describe DemoCalculator::EvalRows do
  def fixture(name)
    JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/demo_calculator/runs/#{name}.json")))
  end

  def row_for(name, **extra)
    data = fixture(name)
    described_class.row(workflow: data["run"]["workflow"], run: data["run"], events: data["events"], totals: data["totals"], **extra)
  end

  it "fires every declared success-path feature on a plain pass" do
    row = row_for("plain_pass")
    expect(row[:features]).to eq("status" => "fired", "require" => "fired", "produces" => "fired", "guard" => "fired")
    expect(row).to include(attempts: 2, retries: 0, review_rounds: 0, wall: 600, active: 540, stopped: 60, head: "h2")
  end

  it "fires backoff only on a step_looped event with a backoff key, and counts retries per step" do
    row = row_for("backoff_loop")
    expect(row[:features]).to include("backoff" => "fired", "status" => "fired", "require" => "fired")
    expect(row).to include(attempts: 4, retries: 2, head: "h3")
  end

  it "leaves backoff armed when the step ran and never looped" do
    data = fixture("backoff_loop")
    row = described_class.row(workflow: "w", run: data["run"], events: [])
    expect(row[:features]["backoff"]).to eq("armed")
  end

  it "counts review rounds and fires review" do
    row = row_for("review_rejected_then_approved")
    expect(row[:features]).to eq("review" => "fired")
    expect(row).to include(review_rounds: 2, review_rounds_distinct: 2, attempts: 2, retries: 1)
  end

  it "does not count a redelivered round" do
    data = fixture("review_rejected_then_approved")
    step = data["run"]["steps"].values.find { |st| Array(st["attempts"]).any? { |a| Array(a["rounds"]).any? } }
    step["attempts"].first["rounds"] << {"round" => 1, "ended" => "redelivered"}
    row = described_class.row(workflow: "w", run: data["run"], events: [])
    expect(row).to include(review_rounds: 2, review_rounds_distinct: 2, attempts: 2, retries: 1)
  end

  it "counts a round with no ended key" do
    data = fixture("review_rejected_then_approved")
    step = data["run"]["steps"].values.find { |st| Array(st["attempts"]).any? { |a| Array(a["rounds"]).any? } }
    step["attempts"].first["rounds"] << {"round" => 3}
    row = described_class.row(workflow: "w", run: data["run"], events: [])
    expect(row[:review_rounds]).to eq(3)
  end

  it "marks review missed when the step ran with no rounds or events" do
    data = fixture("review_rejected_then_approved")
    data["run"]["steps"]["fix"]["attempts"].each { |a| a.delete("rounds") }
    row = described_class.row(workflow: "w", run: data["run"], events: [])
    expect(row[:features]["review"]).to eq("missed")
  end

  it "fires fan_out when every sibling has attempts, and misses it when one does not" do
    data = fixture("fan_out_shared")
    expect(row_for("fan_out_shared")[:features]).to include("fan_out" => "fired", "produces" => "fired")
    data["run"]["steps"]["finish_usage"]["attempts"] = []
    expect(described_class.features(data["run"], [])["fan_out"]).to eq("missed")
  end

  it "fires deny on command_denied and leaves budget and timeout armed" do
    row = row_for("command_denied")
    expect(row[:features]).to include("deny" => "fired", "budget" => "armed", "timeout" => "armed")
    expect(row[:denied]).to eq(1)
  end

  it "fires budget and timeout on their events" do
    data = fixture("command_denied")
    events = [{"type" => "budget_spent"}, {"type" => "run_timed_out"}]
    expect(described_class.features(data["run"], events)).to include("budget" => "fired", "timeout" => "fired", "deny" => "armed")
  end

  it "marks produces missed when the step ran and wrote no output, and keeps a nil usage out of the row" do
    row = row_for("missing_usage")
    expect(row[:features]).to eq("produces" => "missed")
    expect(row[:attempts]).to eq(1)
  end

  it "counts a guard violation event and still fires guard on the unchanged retry" do
    row = row_for("guard_violation")
    expect(row[:guard_violations]).to eq(1)
    expect(row[:features]["guard"]).to eq("fired")
  end

  it "marks guard missed when the head moved and no violation was recorded" do
    data = fixture("guard_violation")
    data["run"]["steps"]["verify"]["attempts"].pop
    expect(described_class.features(data["run"], [])["guard"]).to eq("missed")
  end

  it "gives ? for a feature whose step never ran" do
    data = fixture("plain_pass")
    data["run"]["steps"].each_value { |step| step["attempts"] = [] }
    expect(described_class.features(data["run"], []).values.uniq).to eq(["?"])
  end

  it "gives ? for run-level features when nothing ran" do
    data = fixture("command_denied")
    data["run"]["steps"] = {}
    expect(described_class.features(data["run"], []).values.uniq).to eq(["?"])
  end

  it "classifies expect-fail separately from require" do
    data = fixture("plain_pass")
    step = data["run"]["definition"]["steps"].first
    step["require"] = [{"exec" => "workspace step expect-fail --tests x"}]
    data["run"]["steps"]["implement"]["attempts"].first["proofs"] = [{"proof" => "command", "command" => "workspace step expect-fail --tests x", "exit_code" => 0}]
    expect(described_class.features(data["run"], [])).to include("expect_fail" => "fired")
    expect(described_class.features(data["run"], [])).not_to have_key("require")
  end

  it "ignores skipped proofs" do
    data = fixture("plain_pass")
    data["run"]["steps"]["implement"]["attempts"].first.merge!("outcome" => "failed", "proofs" => [{"proof" => "command", "skipped" => "command_unset"}])
    expect(described_class.features(data["run"], [])["require"]).to eq("missed")
  end

  it "computes the gap to the next run and nil without one" do
    first = fixture("plain_pass")["run"]
    second = fixture("backoff_loop")["run"].merge("started_at" => "2026-11-21T05:12:00Z")
    expect(described_class.row(workflow: "a", run: first, next_run: second)[:gap]).to eq(120)
    expect(described_class.row(workflow: "a", run: first)[:gap]).to be_nil
  end

  it "reports a nil time as nil, not zero, when totals are absent" do
    row = described_class.row(workflow: "a", run: fixture("plain_pass")["run"])
    expect([row[:wall], row[:active], row[:stopped]]).to all(be_nil)
  end

  it "takes the ending head from the last-ended attempt across steps" do
    expect(row_for("backoff_loop")[:head]).to eq("h3")
  end

  it "has no ending head when the last-ended attempt recorded none" do
    attempts = [
      {"ended_at" => "2026-11-21T05:00:00Z", "head" => {"after" => "old"}},
      {"ended_at" => "2026-11-21T05:10:00Z"}
    ]
    expect(described_class.ending_head(attempts)).to be_nil
  end

  it "gives a not run row for an item with no run" do
    row = described_class.row(workflow: "calc-05", run: nil)
    expect(row).to include(workflow: "calc-05", ran: false, attempts: "not run", gap: "not run", features: {})
  end

  it "builds rows for a list, with gaps only between runs and not run after the stop" do
    items = [
      {workflow: "a", run: fixture("plain_pass")["run"], totals: {"wall_seconds" => 1}},
      {workflow: "b", run: fixture("backoff_loop")["run"].merge("started_at" => "2026-11-21T05:11:00Z")},
      {workflow: "c", run: nil}
    ]
    rows = described_class.rows(items)
    expect(rows.map { |r| r[:ran] }).to eq([true, true, false])
    expect(rows[0][:gap]).to eq(60)
    expect(rows[1][:gap]).to be_nil
    expect(rows[2][:wall]).to eq("not run")
    expect(rows.first(2).map { |r| r[:final] }).to eq([false, true])
  end

  it "credits require from a passed attempt when the run file holds no proof for a commits entry" do
    data = fixture("plain_pass")
    data["run"]["definition"]["steps"].first["require"] = [{"commits" => 1}]
    attempt = data["run"]["steps"]["implement"]["attempts"].first.merge("proofs" => [], "outcome" => "passed")
    data["run"]["steps"]["implement"]["attempts"] = [attempt]
    expect(described_class.features(data["run"], [])["require"]).to eq("fired")
    data["run"]["steps"]["implement"]["attempts"] = [attempt.merge("outcome" => "failed")]
    expect(described_class.features(data["run"], [])["require"]).to eq("missed")
    failed = [{"type" => "step_failed", "cause" => "require", "step" => "implement"}]
    expect(described_class.features(data["run"], failed)["require"]).to eq("fired")
  end

  it "does not credit require from a passed attempt when the step's only entry is an exec" do
    data = fixture("plain_pass")
    data["run"]["definition"]["steps"].first["require"] = [{"exec" => ["ruby", "-e", "1"]}]
    data["run"]["steps"]["implement"]["attempts"].first.merge!("proofs" => [], "outcome" => "passed")
    expect(described_class.features(data["run"], [])["require"]).to eq("missed")
  end

  it "credits a stored proof to expect_fail by its require index, with no command on the proof" do
    data = fixture("plain_pass")
    data["run"]["definition"]["steps"].first["require"] = [{"commits" => 1}, {"exec" => ["workspace", "step", "expect-fail", "--", "t.rb"]}]
    data["run"]["steps"]["implement"]["attempts"].first.merge!("outcome" => "failed", "proofs" => [{"proof" => "exec", "program" => "workspace", "index" => 1, "exit_code" => 0}])
    features = described_class.features(data["run"], [])
    expect(features).to include("expect_fail" => "fired", "require" => "missed")
    data["run"]["steps"]["implement"]["attempts"].first["proofs"] = [{"proof" => "commits", "index" => 0, "exit_code" => 0}]
    expect(described_class.features(data["run"], [])).to include("expect_fail" => "missed", "require" => "fired")
  end

  it "counts the manual acts of a person, not the start or the dispatches that follow them" do
    person = ->(type, cause = nil) { {"type" => type, "actor" => "person", "cause" => cause} }
    events = [person.call("run_started", "start"), person.call("step_dispatching", "first"), person.call("run_resumed", "resume"),
      person.call("step_dispatching", "resume"), person.call("review_rounds_extended"), person.call("gate_approved"),
      {"type" => "run_resumed", "actor" => "daemon"}, {"type" => "run_cancelled", "actor" => "person"}]
    row = described_class.row(workflow: "a", run: fixture("plain_pass")["run"], events: events)
    expect(row[:manual]).to eq(4)
    expect(described_class.row(workflow: "a", run: nil)[:manual]).to eq("not run")
  end

  it "counts a person's attempts, budget and time extensions as manual, and a guard_accepted event as nothing" do
    events = %w[attempts_extended budget_extended time_extended guard_overridden guard_accepted].map { |type| {"type" => type, "actor" => "person"} }
    expect(described_class.row(workflow: "a", run: fixture("plain_pass")["run"], events: events)[:manual]).to eq(4)
  end

  describe "manual from inputs and asks" do
    let(:asks) { JSON.parse(File.read(File.join(PROJECT_ROOT, "spec/fixtures/demo_calculator/i03_asks.json"))) }
    let(:run) { fixture("plain_pass")["run"].merge("started_at" => "2026-11-21T08:53:24Z", "ended_at" => "2026-11-21T09:12:03Z") }

    it "counts attempts that asked for input or reported needs_input, once each" do
      run["steps"]["implement"]["attempts"] = [{"asked_input" => true}, {"status_report" => {"state" => "needs_input"}},
        {"asked_input" => true, "status_report" => {"state" => "needs_input"}}, {"status_report" => {"state" => "done"}}]
      row = described_class.row(workflow: "a", run: run)
      expect(row).to include(manual_inputs: 3, manual_events: 0, manual_asks: 0, manual: 3)
    end

    it "counts answered asks asked inside the window, not open ones or those from other items" do
      row = described_class.row(workflow: "a", run: run, asks: asks)
      expect(row).to include(manual_asks: 2, manual: 2)
    end

    it "attributes an ask by asked_at, even when it was answered after the item ended" do
      first = run.merge("started_at" => "2026-11-21T08:50:19Z", "ended_at" => "2026-11-21T08:51:13Z")
      expect(described_class.row(workflow: "a", run: first, asks: asks)[:manual_asks]).to eq(1)
    end

    it "gives manual as the sum of events, inputs and asks" do
      events = [{"type" => "gate_approved", "actor" => "person"}]
      run["steps"]["implement"]["attempts"] = [{"asked_input" => true}]
      row = described_class.row(workflow: "a", run: run, events: events, asks: asks)
      expect(row).to include(manual_events: 1, manual_inputs: 1, manual_asks: 2, manual: 4)
    end
  end

  describe "person_wait" do
    it "sums the person-caused waiting buckets and leaves out stalls, downtime and machine waits" do
      totals = {"stopped_seconds" => 100.0, "waiting_seconds" => {"waiting_agent_input" => 30.0, "failed_check" => 10.0, "stalled" => 40.0, "downtime" => 5.0}}
      row = described_class.row(workflow: "a", run: fixture("plain_pass")["run"], totals: totals)
      expect(row[:person_wait]).to eq(40.0)
    end

    it "counts a turn_ended_background or turn_ended_incomplete wait as 0, since no person is waited on" do
      totals = {"stopped_seconds" => 57.0, "waiting_seconds" => {"turn_ended_background" => 22.0, "turn_ended_incomplete" => 35.0}}
      expect(described_class.row(workflow: "a", run: fixture("plain_pass")["run"], totals: totals)[:person_wait]).to eq(0)
    end

    it "counts gate, paused and review stops as a person wait" do
      totals = {"stopped_seconds" => 100.0, "waiting_seconds" => {"gate" => 10.0, "paused" => 5.0, "review_rejected" => 3.0, "review_incomplete" => 2.0, "waiting_you" => 1.0}}
      expect(described_class.row(workflow: "a", run: fixture("plain_pass")["run"], totals: totals)[:person_wait]).to eq(21.0)
    end

    it "never exceeds stopped, and is nil without buckets" do
      totals = {"stopped_seconds" => 20.0, "waiting_seconds" => {"waiting_you" => 15.0, "waiting_agent_input" => 15.0}}
      expect(described_class.row(workflow: "a", run: fixture("plain_pass")["run"], totals: totals)[:person_wait]).to eq(20.0)
      expect(described_class.row(workflow: "a", run: fixture("plain_pass")["run"])[:person_wait]).to be_nil
    end
  end

  it "credits require from a step_failed event with cause require for that step only" do
    data = fixture("plain_pass")
    data["run"]["definition"]["steps"].first["require"] = [{"commits" => 1}]
    data["run"]["steps"]["implement"]["attempts"].first.merge!("proofs" => [], "outcome" => "failed")
    event = ->(step) { [{"type" => "step_failed", "cause" => "require", "step" => step}] }
    expect(described_class.features(data["run"], event.call("implement"))["require"]).to eq("fired")
    expect(described_class.features(data["run"], event.call("plan"))["require"]).to eq("missed")
  end
  describe "waits the trace mislabels" do
    let(:run) do
      {"id" => "r", "steps" => {"implement" => {"attempts" => [
        {"n" => 1, "outcome" => "failed", "ended_at" => "2026-11-21T18:37:51Z"},
        {"n" => 2, "outcome" => "not_delivered", "code" => "pane_busy", "ended_at" => "2026-11-21T18:38:03Z"},
        {"n" => 3, "outcome" => "passed", "redelivery" => 1, "ended_at" => "2026-11-21T18:44:13Z"}
      ]}}}
    end
    let(:stalled) { {"type" => "step_stalled", "step" => "implement", "attempt" => 2, "cause" => "undelivered", "ts" => "2026-11-21T18:43:19.000Z"} }

    it "does not count an undelivered dispatch's waiting_you as a person wait, and shows it as redelivery wait" do
      totals = {"wall_seconds" => 711.0, "active_seconds" => 394.0, "stopped_seconds" => 316.0, "waiting_seconds" => {"waiting_you" => 316.0}}
      row = described_class.row(workflow: "w", run: run, events: [stalled], totals: totals)
      expect(row).to include(person_wait: 0, stopped: 316.0, deliver_wait: 316.0)
    end

    it "keeps a person's waiting_you beside an undelivered one" do
      totals = {"stopped_seconds" => 400.0, "waiting_seconds" => {"waiting_you" => 400.0}}
      row = described_class.row(workflow: "w", run: run, events: [stalled], totals: totals)
      expect(row[:person_wait]).to eq(84.0)
    end

    it "counts turn_ended_background as active, not stopped" do
      totals = {"active_seconds" => 300.0, "stopped_seconds" => 30.0, "waiting_seconds" => {"turn_ended_background" => 30.0}}
      row = described_class.row(workflow: "w", run: run, totals: totals)
      expect(row).to include(stopped: 0.0, active: 330.0, background: 30.0, person_wait: 0)
    end

    it "reads a review round's redelivery wait from its events" do
      events = [{"type" => "review_delivery_failed", "step" => "plan", "round" => 1, "ts" => "2026-11-21T18:47:28.083Z"},
        {"type" => "review_started", "step" => "plan", "round" => 1, "again" => true, "ts" => "2026-11-21T18:48:34.083Z"}]
      totals = {"active_seconds" => 100.0, "stopped_seconds" => 0.0, "waiting_seconds" => {}}
      expect(described_class.row(workflow: "w", run: run, events: events, totals: totals)).to include(deliver_wait: 66.0, stopped: 0.0)
    end

    it "counts a round's redelivery wait from its first delivery, and reports the review part on its own" do
      events = [{"type" => "review_started", "step" => "plan", "round" => 1, "ts" => "2026-11-21T20:28:43.423Z"},
        {"type" => "review_delivery_failed", "step" => "plan", "round" => 1, "ts" => "2026-11-21T20:29:17.671Z"},
        {"type" => "review_started", "step" => "plan", "round" => 1, "again" => true, "ts" => "2026-11-21T20:30:25.803Z"},
        {"type" => "review_started", "step" => "plan", "round" => 2, "ts" => "2026-11-21T20:31:00.000Z"}]
      totals = {"active_seconds" => 400.0, "stopped_seconds" => 0.0, "waiting_seconds" => {}}
      row = described_class.row(workflow: "w", run: run, events: events, totals: totals)
      expect(row[:deliver_wait]).to be_within(0.001).of(102.38)
      expect(row[:review_deliver_wait]).to eq(row[:deliver_wait])
    end

    it "leaves deliver_wait and background nil when the trace totals are unknown" do
      expect(described_class.row(workflow: "w", run: run, events: [stalled], totals: {})).to include(deliver_wait: nil, background: nil)
    end

    it "does not count a not_delivered attempt as a retry" do
      expect(described_class.row(workflow: "w", run: run)).to include(attempts: 3, retries: 1)
    end
  end
end
