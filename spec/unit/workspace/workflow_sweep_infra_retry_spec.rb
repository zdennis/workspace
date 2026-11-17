require "spec_helper"

# Holds run hashes as the store would, and records what the sweep asks the engine.
class InfraRetryFakeEngine
  attr_reader :calls, :runs

  def initialize(clock)
    @clock = clock
    @runs = {}
    @calls = []
  end

  def going = @runs.values.map { |each| Workspace::WorkflowRun.from_h(each) }

  def run(id) = Workspace::WorkflowRun.from_h(@runs.fetch(id))

  def unreadable = []

  # Marks the stall once per attempt and, with +infra_retry+, schedules a restart or gives it up as the real engine does.
  def note_stall(run_id, actor:, step:, attempt:, cause:, data: {}, infra_retry: nil)
    @calls << [:note_stall, run_id, {cause: cause, infra_retry: infra_retry}]
    run = @runs.fetch(run_id)
    marks = (run["sweep"] ||= {"step" => step, "attempt" => attempt})
    return :repeat if marks.dig("stalled", cause)
    (marks["stalled"] ||= {})[cause] = @clock.call.utc.iso8601
    return :recorded unless infra_retry
    n = Workspace::WorkflowTransitions.infra_retries(run, step) + 1
    if n > infra_retry[:max]
      marks["infra_retry"] = {"cause" => cause, "n" => n - 1, "max" => infra_retry[:max], "given_up" => {"reason" => "retries_spent"}}
      return :exhausted
    end
    due = @clock.call + Workspace::WorkflowTransitions.infra_retry_wait(n)
    marks["infra_retry"] = {"cause" => cause, "n" => n, "max" => infra_retry[:max], "due" => due.utc.iso8601}
    :scheduled
  end

  # What a claimed retry's restart leaves: a new attempt, the count raised and no sweep marks for it.
  def restart(run_id)
    run = @runs.fetch(run_id)
    step = run["current"]
    attempts = run["steps"][step]["attempts"]
    attempts << {"n" => attempts.last["n"] + 1, "started_at" => @clock.call.utc.iso8601}
    (run["infra_retries"] ||= {})[step] = Workspace::WorkflowTransitions.infra_retries(run, step) + 1
    run.delete("sweep")
  end

  def due(run_id) = @runs.fetch(run_id).dig("sweep", "infra_retry", "due")

  def stall_calls = @calls.select { |each| each.first == :note_stall }

  def given_up(run_id) = @runs.fetch(run_id).dig("sweep", "infra_retry", "given_up")
end

# Counts the session reads.
class SessionCountingPanes < FakeWorkflowPanes
  attr_reader :session_reads

  def session_live?(workspace)
    (@session_reads ||= []) << workspace
    super
  end
end

# The sweep's side of an infra retry: which `pane_gone` and `agent_gone` stalls it asks the engine to schedule a
# restart for, and when it records that the restarts are spent. A fake engine keeps the run hashes in memory and
# answers as the real one does; fake panes and a mutable clock, so nothing starts a process.
RSpec.describe Workspace::WorkflowSweep, "infra retries" do
  let(:now) { [Time.utc(2026, 10, 4, 12, 0, 0)] }
  let(:engine) { InfraRetryFakeEngine.new(-> { now.first }) }
  let(:panes) { SessionCountingPanes.new }
  let(:max) { [2] }
  let(:reviews) { instance_double(Workspace::WorkflowReviewSweep, orphan_rows: []) }
  let(:sweep) do
    described_class.new(store: engine, engine: engine, panes: panes, interrupter: ->(*) {}, reviews: reviews,
      infra_retry_max: -> { max.first }, clock: -> { now.first })
  end

  def add_run(id, pane)
    engine.runs[id] = {"id" => id, "workspace" => "app", "state" => "running", "current" => "build", "pane" => pane,
                       "definition" => {"steps" => [{"id" => "build", "prompt" => "Build it."}]},
                       "steps" => {"build" => {"state" => "running", "attempts" => [{"n" => 1, "started_at" => (now.first - 600).utc.iso8601}]}}}
    panes.bind(workspace: "app", pane: pane, run_id: id)
  end

  def stand(cause, id = "wr_1", pane = "%5")
    case cause
    when "pane_gone" then panes.stale << id
    when "agent_gone" then panes.rows[pane] = {"pane_id" => pane, "kind" => "shell", "state" => "idle", "idle_seconds" => 120}
    end
  end

  def back(id = "wr_1", pane = "%5")
    panes.stale.delete(id)
    panes.rows[pane] = {"pane_id" => pane, "kind" => "claude", "state" => "working", "idle_seconds" => 0, "state_since" => now.first.utc.iso8601}
  end

  def only_row = sweep.call.tap { |rows| expect(rows.size).to eq(1) }.first

  %w[agent_gone pane_gone].each do |cause|
    context "for #{cause}" do
      it "schedules restart 1 due in 60s, restart 2 due in 300s, then records exhaustion once across passes" do
        add_run("wr_1", "%5")
        stand(cause)

        expect(only_row).to include("outcome" => "recorded", "cause" => cause, "action" => "infra_retry_scheduled")
        expect(engine.due("wr_1")).to eq("2026-10-04T12:01:00Z")
        expect(engine.stall_calls.last.last).to eq(cause: cause, infra_retry: {max: 2})

        now[0] += 60
        engine.restart("wr_1")
        back
        sweep.call
        stand(cause)
        expect(only_row).to include("action" => "infra_retry_scheduled")
        expect(engine.due("wr_1")).to eq("2026-10-04T12:06:00Z")

        now[0] += 300
        engine.restart("wr_1")
        back
        sweep.call
        stand(cause)
        row = only_row
        expect(row).to include("outcome" => "recorded", "cause" => cause, "action" => "infra_retries_exhausted")
        expect(row["message"]).to include("Its 2 automatic restarts are used up (#{Workspace::WorkflowStatus.infra_cause_words(cause)}); resume or cancel the run (limit: workflows.infra_retry.max).")
        expect(engine.stall_calls.last.last).to eq(cause: cause, infra_retry: {max: 2})
        expect(engine.given_up("wr_1")).to eq("reason" => "retries_spent")

        3.times do
          now[0] += 300
          expect(only_row).to include("outcome" => "nothing", "reason" => "already_recorded")
        end
        expect(engine.stall_calls.size).to eq(3)
        expect(engine.calls.map(&:first).uniq).to eq([:note_stall])
      end
    end
  end

  it "schedules nothing when the workspace has no tmux session" do
    add_run("wr_1", "%5")
    panes.session = false
    stand("agent_gone")

    expect(only_row).to include("outcome" => "recorded", "action" => "record")
    expect(engine.stall_calls.last.last).to eq(cause: "agent_gone", infra_retry: nil)
    expect(engine.given_up("wr_1")).to be_nil
  end

  it "schedules nothing and reads no session with workflows.infra_retry.max at 0" do
    max[0] = 0
    add_run("wr_1", "%5")
    stand("pane_gone")

    expect(only_row).to include("outcome" => "recorded", "action" => "record")
    expect(engine.stall_calls.last.last).to eq(cause: "pane_gone", infra_retry: nil)
    expect(panes.session_reads).to be_nil
  end

  it "schedules nothing for a turn that failed" do
    add_run("wr_1", "%5")
    panes.rows["%5"] = {"pane_id" => "%5", "kind" => "claude", "state" => "idle", "idle_seconds" => 1900, "turn_failed" => true,
                        "turn_failed_since" => (now.first - 1900).utc.iso8601}
    sweep = described_class.new(store: engine, engine: engine, panes: panes, interrupter: ->(*) {}, reviews: reviews,
      infra_retry_max: -> { 2 }, turn_failed_after: -> { 1800 }, clock: -> { now.first })

    expect(sweep.call.first).to include("outcome" => "recorded", "cause" => "turn_failed", "action" => "record")
    expect(engine.stall_calls.last.last).to eq(cause: "turn_failed", infra_retry: nil)
    expect(panes.session_reads).to be_nil
  end

  it "reads the session once for two runs of one workspace" do
    add_run("wr_1", "%5")
    add_run("wr_2", "%6")
    stand("agent_gone", "wr_1", "%5")
    stand("pane_gone", "wr_2", "%6")

    rows = sweep.call

    expect(rows.map { |row| row["action"] }).to eq(%w[infra_retry_scheduled infra_retry_scheduled])
    expect(panes.session_reads).to eq(["app"])
  end

  it "says on a dry run what it would do, and changes nothing" do
    add_run("wr_1", "%5")
    stand("agent_gone")

    row = sweep.call(dry_run: true).first

    expect(row).to include("outcome" => "dry_run", "action" => "infra_retry_scheduled")
    expect(row["message"]).to include("restarts on its own in 1m (")
    expect(engine.calls).to be_empty
  end
end
