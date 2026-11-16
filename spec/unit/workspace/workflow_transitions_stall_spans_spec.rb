require "spec_helper"
require "json"
require "time"

RSpec.describe "Workspace stall spans on the run, step and round clocks" do
  let(:t0) { Time.utc(2026, 1, 1) }
  let(:transitions) { Workspace::WorkflowTransitions }
  let(:deadline) { Workspace::WorkflowDeadline }

  def at(hours)
    (t0 + hours * 3600).iso8601
  end

  def run_with(attempts, sweep: nil, other: [], timeout: 7200.0)
    hash = JSON.parse(File.read(File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_runs", "run_timed_out.json")))
    hash["definition"]["timeout"] = timeout
    hash.merge!("current" => "build", "state" => "running", "reason" => nil, "reasons" => [], "ended_at" => nil)
    hash["steps"] = {"build" => {"state" => "running", "attempts" => attempts}, "test" => {"state" => "passed", "attempts" => other}}
    hash["sweep"] = sweep if sweep
    hash
  end

  def attempt(n, started, **more)
    {"n" => n, "started_at" => at(started)}.merge(more.transform_keys(&:to_s))
  end

  def clocks(run, attempt, now, stops: [])
    round = {"round" => 1, "started_at" => attempt["started_at"]}
    [deadline.reading(run, now, stops: stops)["used"], transitions.step_elapsed(run, attempt, now, stops: stops),
      transitions.round_elapsed(run, round, now, stops: stops)]
  end

  %w[pane_gone agent_gone turn_failed].each do |cause|
    context "with a #{cause} stall entry" do
      it "stops every clock from the mark to the next attempt's started_at" do
        first = attempt(1, 0, stalls: [{"cause" => cause, "since" => at(1)}])
        run = run_with([first, attempt(2, 1.5)])

        expect(clocks(run, first, t0 + 3 * 3600)).to eq([9000.0, 9000.0, 9000.0])
      end

      it "stops every clock from the mark to its recovered until" do
        first = attempt(1, 0, stalls: [{"cause" => cause, "since" => at(1), "until" => at(1.5)}])

        expect(clocks(run_with([first]), first, t0 + 3 * 3600)).to eq([9000.0, 9000.0, 9000.0])
      end

      it "stops every clock from the mark to now while it is open" do
        first = attempt(1, 0, stalls: [{"cause" => cause, "since" => at(1)}])

        expect(clocks(run_with([first]), first, t0 + 3 * 3600)).to eq([3600.0, 3600.0, 3600.0])
      end
    end
  end

  it "cuts a turn_failed mark written straight into run['sweep'], open to now" do
    first = attempt(1, 0)
    run = run_with([first], sweep: {"step" => "build", "attempt" => 1, "stalled" => {"turn_failed" => at(1)}})

    expect(clocks(run, first, t0 + 3 * 3600)).to eq([3600.0, 3600.0, 3600.0])
  end

  it "ends a raw stalled mark at its matching recovered mark, not at now" do
    first = attempt(1, 0)
    run = run_with([first], sweep: {"step" => "build", "attempt" => 1, "stalled" => {"pane_gone" => at(1)}, "recovered" => {"pane_gone" => at(1.5)}})

    expect(clocks(run, first, t0 + 3 * 3600)).to eq([9000.0, 9000.0, 9000.0])
  end

  it "ignores raw sweep marks left from another attempt, and causes that are not stalls" do
    first = attempt(1, 0, stalls: [{"cause" => "server_restarted", "since" => at(1)}])
    run = run_with([first], sweep: {"step" => "build", "attempt" => 2, "stalled" => {"pane_gone" => at(1)}})

    expect(transitions.stall_spans(run, "build")).to eq([])
  end

  it "lists a stall once when the attempt entry and the raw mark agree" do
    first = attempt(1, 0, stalls: [{"cause" => "agent_gone", "since" => at(1), "until" => at(2)}])
    run = run_with([first], sweep: {"step" => "build", "attempt" => 1, "stalled" => {"agent_gone" => at(1)}, "recovered" => {"agent_gone" => at(2)}})

    expect(transitions.stall_spans(run, "build")).to eq([{"since" => at(1), "until" => at(2)}])
  end

  it "skips entries it can't read" do
    first = attempt(1, 0, stalls: [{"cause" => "pane_gone", "since" => "not a time"}, "junk", {"cause" => "pane_gone"}])

    expect(transitions.stall_spans(run_with([first]), "build")).to eq([])
    expect(transitions.stall_spans(run_with([first]), "missing")).to eq([])
  end

  it "cuts a downtime stop passed as stops:" do
    first = attempt(1, 0)

    expect(clocks(run_with([first]), first, t0 + 3 * 3600, stops: [{"since" => at(1), "until" => at(2)}])).to eq([7200.0, 7200.0, 7200.0])
  end

  it "cuts overlapping pause, stall and downtime spans once" do
    first = attempt(1, 0, reasons: [{"code" => "paused", "since" => at(1), "until" => at(2)}],
      stalls: [{"cause" => "pane_gone", "since" => at(1.5), "until" => at(2.5)}])
    stops = [{"since" => at(2), "until" => at(2.75)}]

    expect(clocks(run_with([first]), first, t0 + 3 * 3600, stops: stops)).to eq([4500.0, 4500.0, 4500.0])
  end

  it "lets every clock run again after a closed stall: 1h, a 30m stall, then 2h more is 3h, past a 2h timeout" do
    first = attempt(1, 0, stalls: [{"cause" => "turn_failed", "since" => at(1), "until" => at(1.5)}])
    run = run_with([first])
    now = t0 + 3.5 * 3600

    expect(clocks(run, first, now)).to eq([10_800.0, 10_800.0, 10_800.0])
    expect(deadline.reading(run, now)).to include("limit" => 7200.0, "spent" => true)
    expect(transitions.step_elapsed(run, first, now)).to be > 7200
  end

  it "ends an open stall at its attempt's ended_at" do
    first = attempt(1, 0, ended_at: at(2), stalls: [{"cause" => "agent_gone", "since" => at(1)}])

    expect(transitions.stall_spans(run_with([first]), "build")).to eq([{"since" => at(1), "until" => at(2)}])
    expect(clocks(run_with([first]), first, t0 + 3 * 3600)).to eq([7200.0, 7200.0, 7200.0])
  end

  it "cuts another step's stalls from the run clock but not from the current step's clocks" do
    first = attempt(1, 0)
    run = run_with([first], other: [attempt(1, 0, ended_at: at(2), stalls: [{"cause" => "pane_gone", "since" => at(1)}])])

    expect(clocks(run, first, t0 + 3 * 3600)).to eq([7200.0, 10_800.0, 10_800.0])
  end
end
