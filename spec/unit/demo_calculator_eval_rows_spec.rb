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
end
