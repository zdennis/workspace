require "spec_helper"

RSpec.describe Workspace::WorkflowReviewSweep do
  let(:now) { Time.utc(2026, 11, 10, 12, 0, 0) }
  let(:clock_at) { [now] }
  let(:panes) { FakeWorkflowPanes.new }
  let(:engine) { instance_double(Workspace::WorkflowEngine) }
  let(:pressed) { [] }
  let(:press_error) { [nil] }
  let(:interrupter) do
    lambda do |workspace, pane, keys|
      raise press_error.first if press_error.first
      pressed << [workspace, pane, keys]
    end
  end
  let(:pass) { {dry_run: false, allow: nil} }
  let(:claims) { [] }
  let(:confirms) { [] }

  subject(:sweep) { described_class.new(engine: engine, panes: panes, interrupter: interrupter, clock: -> { clock_at.first }) }

  before do
    allow(engine).to receive(:claim_round_interrupt) do |run_id, **args|
      claims << [run_id, args]
      [:claimed, "2026-11-10T12:00:00Z"]
    end
    allow(engine).to receive(:round_interrupt_sent) do |run_id, **args|
      confirms << [run_id, args]
      :recorded
    end
    allow(engine).to receive(:review_stalled).and_return(:evaluated)
    panes.bind(workspace: "app", pane: "%9", run_id: "wr_1", role: "reviewer")
    panes.bind(workspace: "app", pane: "%3", run_id: "wr_1")
  end

  # A run reviewing round 1 of step build in pane %9 (its author in %3), the round started +started+ seconds before
  # now with a 30 minute review timeout; +run+ adds the run's own fields (its `timeout`, say).
  def reviewing(started: 60, round: {}, definition: {}, **run)
    started_at = (now - started).utc.iso8601(3)
    Workspace::WorkflowRun.from_h({
      "id" => "wr_1", "workflow" => "flow", "workspace" => "app", "worktree" => "/w", "state" => "running", "current" => "build", "reason" => nil,
      "definition" => {"id" => "flow", "stall" => 1200, "redeliver" => 2,
                       "steps" => [{"id" => "build", "review" => {"from" => ["skeptic"], "need" => 1, "timeout" => 1800}}]}.merge(definition),
      "steps" => {"build" => {"state" => "reviewing", "review_rounds" => 1,
                              "attempts" => [{"n" => 1, "started_at" => (now - 7200).utc.iso8601, "ended_at" => (now - started).utc.iso8601, "outcome" => "checks_passed"}],
                              "review" => {"round" => 1, "delivery" => nil, "started_at" => started_at, "delivered_at" => started_at,
                                           "pane" => "%9", "window" => "@9", "server_pid" => "100", "redeliveries" => 0}.merge(round)}}
    }.merge(run))
  end

  def review_pane(state, idle_seconds: 0, kind: "claude")
    panes.rows["%9"] = {"pane_id" => "%9", "kind" => kind, "state" => state, "idle_seconds" => idle_seconds}
  end

  def author_pane(state)
    panes.rows["%3"] = {"pane_id" => "%3", "kind" => "claude", "state" => state, "idle_seconds" => 0}
  end

  def call(run) = sweep.call(run, run.step("build"), pass)

  def sent(cause) = {cause => {"state" => "sent", "at" => "2026-11-10T11:59:00Z"}}

  describe "a round past its review.timeout" do
    it "claims, presses the agent's interrupt keys in the review pane with the claim held, and confirms, under the cause review_timed_out" do
      review_pane("working")
      run = reviewing(started: 1801)

      row = call(run)

      expect(row).to include("outcome" => "interrupted", "cause" => "review_timed_out", "action" => "interrupt", "run_id" => "wr_1", "step" => "build", "attempt" => 1)
      expect(row["message"]).to include("review round 1 of step build is 1801 seconds in, past its 1800 second review timeout", "decided on its verdicts")
      expect(claims).to eq([["wr_1", {actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", elapsed: 1801.0, timeout: 1800, cause: "review_timed_out"}]])
      expect(pressed).to eq([["app", "%9", Workspace::AgentProvider.find("claude").interrupt_keys]])
      expect(confirms).to eq([["wr_1", {actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", claim_at: "2026-11-10T12:00:00Z", sent: true, cause: "review_timed_out"}]])
    end

    it "leaves a round still within its timeout alone" do
      review_pane("working")

      expect(call(reviewing(started: 1799))).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(claims + pressed).to be_empty
    end

    it "presses nothing once the round's keys went out, and says it waits for the turn's end" do
      review_pane("working")

      row = call(reviewing(started: 3600, round: {"sweep" => sent("interrupt")}))

      expect(row).to include("outcome" => "nothing", "reason" => "already_interrupted", "cause" => "review_timed_out")
      expect(claims + pressed).to be_empty
    end

    it "does not press a review pane that is not working, nor one with no interrupt key" do
      review_pane("idle", idle_seconds: 1)
      expect(call(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "not_working", "cause" => "review_timed_out")

      review_pane("working", kind: "nosuchagent")
      expect(call(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "no_interrupt_key")
      expect(claims + pressed).to be_empty
    end

    it "gives the claim back, pressing nothing, when the pane changed before the press" do
      review_pane("working")
      panes.on_row = -> { panes.rows["%9"] = panes.rows["%9"].merge("state" => "idle") if claims.any? }

      row = call(reviewing(started: 1801))

      expect(row).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "review_timed_out")
      expect(pressed).to be_empty
      expect(confirms.first.last).to include(sent: false)
    end

    it "presses nothing when the review pane is no longer bound to the run" do
      review_pane("working")
      panes.unbind("wr_1", role: "reviewer")

      expect(call(reviewing(started: 1801))).to include("reason" => "pane_changed")
      expect(pressed).to be_empty
    end

    it "reports a press that failed, given the claim back as not sent" do
      review_pane("working")
      press_error[0] = Workspace::Error.new("pane gone")

      row = call(reviewing(started: 1801))

      expect(row).to include("outcome" => "failed", "reason" => "interrupt_failed", "cause" => "review_timed_out")
      expect(confirms.first.last).to include(sent: false)
    end

    it "only reports on a dry run, and asks allow before it claims" do
      review_pane("working")
      expect(sweep.call(reviewing(started: 1801), reviewing(started: 1801).step("build"), {dry_run: true})).to include("outcome" => "dry_run", "action" => "interrupt", "cause" => "review_timed_out")

      refused = sweep.call(reviewing(started: 1801), reviewing(started: 1801).step("build"), {allow: ->(_run) { "a person is looking" }})
      expect(refused).to include("outcome" => "nothing", "reason" => "refused", "message" => "a person is looking")
      expect(claims + pressed).to be_empty
    end

    it "says a claim another sweep holds is already being interrupted, and passes the engine's other answers on" do
      review_pane("working")
      allow(engine).to receive(:claim_round_interrupt).and_return(:repeat, :moved_on)

      expect(call(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "already_interrupted")
      expect(call(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "moved_on")
      expect(pressed).to be_empty
    end

    it "decides a round whose turn is over past its timeout without waiting for the stall" do
      review_pane("idle", idle_seconds: 30)

      row = call(reviewing(started: 1801))

      expect(row).to include("outcome" => "evaluated", "cause" => "idle_turn_over")
      expect(pressed).to be_empty
    end
  end

  describe "the default stall the pass carries" do
    def call_with(default, run) = sweep.call(run, run.step("build"), pass.merge(default_stall: default))

    it "decides a round whose definition sets no stall once the pane has been idle for the default" do
      review_pane("idle", idle_seconds: 600)

      row = call_with(600, reviewing(definition: {"stall" => nil}))

      expect(row).to include("outcome" => "evaluated", "cause" => "idle_turn_over")
    end

    it "leaves the round alone while the idle time is under the default" do
      review_pane("idle", idle_seconds: 599)

      expect(call_with(600, reviewing(definition: {"stall" => nil}))).to include("outcome" => "nothing", "reason" => "reviewing")
    end

    it "lets the definition's stall win over the default" do
      review_pane("idle", idle_seconds: 700)

      expect(call_with(600, reviewing)).to include("outcome" => "nothing", "reason" => "reviewing")
    end

    it "never decides by idleness with the default off" do
      review_pane("idle", idle_seconds: 5000)

      expect(call_with(nil, reviewing(definition: {"stall" => nil}))).to include("outcome" => "nothing", "reason" => "reviewing")
    end

    it "takes a pass with no default as off" do
      review_pane("idle", idle_seconds: 5000)

      expect(call(reviewing(definition: {"stall" => nil}))).to include("outcome" => "nothing", "reason" => "reviewing")
    end
  end

  describe "the press's own checks" do
    it "never presses a pane bound to the run as its author, as after a tmux restart that reused the review pane's id" do
      review_pane("working")
      panes.unbind("wr_1", role: "reviewer")
      panes.bind(workspace: "app", pane: "%9", run_id: "wr_1")

      expect(call(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "pane_changed")
      expect(pressed).to be_empty
      expect(confirms.first.last).to include(sent: false)
    end

    it "presses a round whose line may have been typed and whose reviewer works past its timeout, instead of handing it to the tick" do
      review_pane("working")
      typed = {"delivery" => "failed", "delivered_at" => nil, "kick_at" => (now - 1790).utc.iso8601(3),
               "failure" => {"code" => "connection_failed", "message" => "daemon gone", "typed" => true, "at" => (now - 1700).utc.iso8601}}

      row = call(reviewing(started: 1801, round: typed))

      expect(row).to include("outcome" => "interrupted", "cause" => "review_timed_out")
      expect(pressed.map { |_, pane, _| pane }).to eq(["%9"])
    end

    it "hands a typed round within its timeout to the tick as before" do
      review_pane("working")
      allow(engine).to receive(:tick).and_return(nil)
      typed = {"delivery" => "failed", "delivered_at" => nil, "kick_at" => (now - 1600).utc.iso8601(3),
               "failure" => {"code" => "connection_failed", "message" => "daemon gone", "typed" => true, "at" => (now - 1500).utc.iso8601}}

      expect(call(reviewing(started: 1601, round: typed))).to include("cause" => "round_maybe_typed")
      expect(pressed).to be_empty
    end
  end

  describe "a review pane still at work after every due press" do
    # The longer of the definition's stall (1200) and the review's timeout (1800).
    let(:pressed_at) { (now - 1800).utc.iso8601 }

    it "says it waits for the turn's end until the longer of stall and review timeout has passed since the last press, then has the round decided" do
      review_pane("working")
      marks = {"sweep" => {"interrupt" => {"state" => "sent", "at" => (now - 1799).utc.iso8601}}}
      expect(call(reviewing(started: 3600, round: marks))).to include("outcome" => "nothing", "reason" => "already_interrupted")
      expect(engine).not_to have_received(:review_stalled)

      allow(engine).to receive(:review_stalled).and_return(:stopped)
      row = call(reviewing(started: 3600, round: {"sweep" => {"interrupt" => {"state" => "sent", "at" => pressed_at}}}))

      expect(row).to include("outcome" => "stopped", "cause" => "interrupt_unanswered", "action" => "evaluate")
      expect(row["message"]).to include("still works 1800 seconds after it was interrupted", "its window kept")
      expect(engine).to have_received(:review_stalled).with("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: "interrupt_unanswered", data: {"waited" => 1800})
    end

    it "waits the review's timeout once more when the definition has no stall, or a shorter one" do
      review_pane("working")
      marks = {"sweep" => {"interrupt" => {"state" => "sent", "at" => (now - 1200).utc.iso8601}}}

      expect(call(reviewing(started: 3600, round: marks, definition: {"stall" => nil}))).to include("reason" => "already_interrupted")
      expect(call(reviewing(started: 3600, round: marks))).to include("reason" => "already_interrupted")
    end

    it "is left for the next pass when the pane stopped working by the time it is read again" do
      review_pane("working")
      reads = []
      panes.on_row = lambda do
        reads << true
        panes.rows["%9"] = panes.rows["%9"].merge("state" => "idle") if reads.size == 2
      end

      row = call(reviewing(started: 3600, round: {"sweep" => {"interrupt" => {"state" => "sent", "at" => pressed_at}}}))

      expect(row).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "interrupt_unanswered")
      expect(engine).not_to have_received(:review_stalled)
    end
  end

  describe "a run past its timeout with timeout_action: interrupt while a round is reviewed" do
    let(:deadline) { {"timeout" => 3600, "timeout_action" => "interrupt"} }

    it "presses in the review pane under the cause run_timed_out, never the author's pane" do
      review_pane("working")
      author_pane("working")

      row = call(reviewing(started: 60, definition: deadline))

      expect(row).to include("outcome" => "interrupted", "cause" => "run_timed_out")
      expect(row["message"]).to include("the run has used 7200 seconds of its 3600 second time limit while review round 1 of step build is reviewed")
      expect(pressed.map { |_, pane, _| pane }).to eq(["%9"])
      expect(claims.first.last).to include(cause: "run_timed_out", round: 1, pane: "%9", elapsed: 7200, timeout: 3600)
    end

    it "presses nothing for timeout_action: hold" do
      review_pane("working")

      expect(call(reviewing(started: 60, definition: {"timeout" => 3600, "timeout_action" => "hold"}))).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(pressed).to be_empty
    end

    it "presses once for each cause when both are due on one round, the round's own first" do
      review_pane("working")

      first = call(reviewing(started: 1801, definition: deadline))
      second = call(reviewing(started: 1801, definition: deadline, round: {"sweep" => sent("interrupt")}))
      third = call(reviewing(started: 1801, definition: deadline, round: {"sweep" => sent("interrupt").merge(sent("run_interrupt"))}))

      expect([first, second, third].map { |each| [each["outcome"], each["cause"]] }).to eq(
        [%w[interrupted review_timed_out], %w[interrupted run_timed_out], %w[nothing review_timed_out]]
      )
      expect(claims.map { |_, args| args[:cause] }).to eq(%w[review_timed_out run_timed_out])
      expect(pressed.size).to eq(2)
    end
  end

  describe "a round whose review turn ended after the sweep interrupted it" do
    it "is decided at once as cause interrupted, the turn's end read again just before" do
      review_pane("idle", idle_seconds: 10)

      row = call(reviewing(started: 1900, round: {"sweep" => sent("interrupt")}))

      expect(row).to include("outcome" => "evaluated", "cause" => "interrupted", "action" => "evaluate")
      expect(engine).to have_received(:review_stalled).with("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: "interrupted", data: {"idle_for" => 10})
    end

    it "is left for the next pass when the pane no longer shows the turn over" do
      review_pane("idle", idle_seconds: 10)
      reads = []
      panes.on_row = lambda do
        reads << true
        panes.rows["%9"] = panes.rows["%9"].merge("state" => "working") if reads.size == 2
      end

      row = call(reviewing(started: 1900, round: {"sweep" => sent("interrupt")}))

      expect(row).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "interrupted")
      expect(engine).not_to have_received(:review_stalled)
    end
  end

  describe "a round whose review pane's turn failed on an API error" do
    let(:failed_pass) { pass.merge(turn_failed_after: 900) }

    def failed_pane(ago: 901)
      review_pane("idle", idle_seconds: ago)
      panes.rows["%9"] = panes.rows["%9"].merge("turn_failed" => true, "turn_failed_since" => (now - ago).utc.iso8601)
    end

    def call_failed(run, with: failed_pass) = sweep.call(run, run.step("build"), with)

    it "is decided on its verdicts as cause turn_failed once the turn stayed failed for the threshold, typing nothing" do
      failed_pane

      row = call_failed(reviewing(started: 1000))

      expect(row).to include("outcome" => "evaluated", "cause" => "turn_failed", "action" => "evaluate")
      expect(row["message"]).to include("failed on an API error 901 seconds ago")
      expect(engine).to have_received(:review_stalled).with("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9", cause: "turn_failed", data: {"since" => (now - 901).utc.iso8601})
      expect(pressed).to be_empty
    end

    it "names the failed turn and decides nothing before the threshold" do
      failed_pane(ago: 899)

      expect(call_failed(reviewing(started: 1000))).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(call_failed(reviewing(started: 1000))["message"]).to include("failed on an API error")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "decides nothing with the threshold off" do
      failed_pane

      expect(call_failed(reviewing(started: 1000), with: pass.merge(turn_failed_after: nil))).not_to include("cause" => "turn_failed")
      expect(call(reviewing(started: 1000))).not_to include("cause" => "turn_failed")
      expect(engine).not_to have_received(:review_stalled).with(anything, hash_including(cause: "turn_failed"))
    end

    it "counts a missing or unparseable turn_failed_since as not yet" do
      failed_pane
      panes.rows["%9"] = panes.rows["%9"].merge("turn_failed_since" => "garbage")
      expect(call_failed(reviewing(started: 1000))).to include("outcome" => "nothing", "reason" => "reviewing")

      panes.rows["%9"] = panes.rows["%9"].merge("turn_failed_since" => nil)
      expect(call_failed(reviewing(started: 1000))).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "leaves a time limit that is due to the decisions it had, below the threshold or with no parseable since" do
      failed_pane(ago: 100)
      expect(call_failed(reviewing(started: 1801))).to include("outcome" => "nothing", "reason" => "not_working", "cause" => "review_timed_out")

      panes.rows["%9"] = panes.rows["%9"].merge("turn_failed_since" => "garbage")
      expect(call_failed(reviewing(started: 1801))).to include("reason" => "not_working", "cause" => "review_timed_out")

      panes.rows["%9"] = panes.rows["%9"].merge("state" => "working")
      expect(call_failed(reviewing(started: 1801))).to include("outcome" => "interrupted", "cause" => "review_timed_out")
    end

    it "waits out the delivery grace" do
      failed_pane
      run = reviewing(started: 1000, round: {"delivered_at" => (now - 5).utc.iso8601(3)})

      expect(call_failed(run)).to include("outcome" => "nothing", "reason" => "reviewing")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "is left for the next pass when the pane no longer shows a failed turn by the time it is read again" do
      failed_pane
      reads = []
      panes.on_row = lambda do
        reads << true
        panes.rows["%9"] = panes.rows["%9"].merge("turn_failed" => false, "state" => "working") if reads.size == 2
      end

      row = call_failed(reviewing(started: 1000))

      expect(row).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "turn_failed")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "advances the run when the verdicts written are enough" do
      failed_pane
      allow(engine).to receive(:review_stalled).and_return(:evaluated)

      expect(call_failed(reviewing(started: 1000))).to include("outcome" => "evaluated", "cause" => "turn_failed")
    end

    it "stops the round review_incomplete when the verdicts fall short" do
      failed_pane
      allow(engine).to receive(:review_stalled).and_return(:stopped)

      expect(call_failed(reviewing(started: 1000))).to include("outcome" => "stopped", "cause" => "turn_failed")
    end

    it "only reports on a dry run" do
      failed_pane

      expect(call_failed(reviewing(started: 1000), with: failed_pass.merge(dry_run: true))).to include("outcome" => "dry_run", "cause" => "turn_failed")
      expect(engine).not_to have_received(:review_stalled)
    end
  end

  describe "a review pane at a dialog nobody answers" do
    let(:limit_pass) { pass.merge(permission_wait_limit: 3600, stops: []) }

    def iso(seconds_ago) = (now - seconds_ago).utc.iso8601

    # The review pane's row with +waits+ (`[agent_id, permission, seconds_ago]` each), quiet for +idle+ seconds.
    def review_waits(*waits, idle: nil)
      oldest = waits.map(&:last).max
      panes.rows["%9"] = {"pane_id" => "%9", "kind" => "claude", "state" => "waiting", "idle_seconds" => idle || oldest,
                          "waiting_reason" => (waits.any? { |each| each[1] }) ? "waiting_permission" : "waiting_prompt",
                          "waits" => waits.map { |id, permission, ago| {"agent_id" => id, "permission" => permission, "since" => iso(ago)} }}
    end

    def call_dialog(run, with: limit_pass) = sweep.call(run, run.step("build"), with)

    it "says how long it has waited before the limit and changes nothing" do
      review_waits([nil, true, 1200])

      row = call_dialog(reviewing(started: 1300))

      expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission")
      expect(row["message"]).to eq("review pane %9 has waited 20m at a permission dialog; review round 1 of step build is decided on its verdicts once it has waited 1h 0m (workflows.permission_wait_limit)")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "decides the round on its verdicts past the limit, once the pane is quiet, with the wait in the stall's data" do
      review_waits(["a1", true, 3700])

      row = call_dialog(reviewing(started: 3800))

      expect(row).to include("outcome" => "evaluated", "cause" => "permission_wait", "action" => "evaluate")
      expect(row["message"]).to include("waited 1h 1m at a permission dialog (limit 1h 0m)", "no reviewer runs again")
      expect(engine).to have_received(:review_stalled).with("wr_1", actor: "sweep", step: "build", attempt: 1, round: 1, pane: "%9",
        cause: "permission_wait", data: {"since" => iso(3700), "waited" => 3700, "limit" => 3600})
      expect(pressed).to be_empty
    end

    it "measures from the oldest unanswered wait, not an older question, and cuts downtime" do
      review_waits([nil, false, 3700], ["a1", true, 300])
      expect(call_dialog(reviewing(started: 3800))).to include("outcome" => "nothing", "reason" => "waiting_permission")

      review_waits(["a1", true, 3700])
      down = limit_pass.merge(stops: [{"since" => iso(3000), "until" => iso(1000)}])
      expect(call_dialog(reviewing(started: 3800), with: down)["message"]).to start_with("review pane %9 has waited 28m at")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "reads a round whose line may have been typed in its pane when that pane sits at a dialog, instead of handing it to the tick" do
      allow(engine).to receive(:tick).and_return(nil)
      review_waits(["a1", true, 3700])
      typed = {"delivery" => "failed", "delivered_at" => nil, "kick_at" => (now - 3790).utc.iso8601(3),
               "failure" => {"code" => "connection_failed", "message" => "daemon gone", "typed" => true, "at" => (now - 3780).utc.iso8601}}

      row = call_dialog(reviewing(started: 3800, round: typed))

      expect(row).to include("outcome" => "evaluated", "cause" => "permission_wait")
      expect(engine).not_to have_received(:tick)
    end

    it "names the first waiting screen that carries a message" do
      review_waits(["screen", false, 3700])
      panes.rows["%9"]["waits"] << {"agent_id" => "screen", "permission" => false, "since" => iso(3600), "message" => "sign in"}

      expect(call_dialog(reviewing(started: 3800))["message"]).to include("at a waiting screen (sign in) (limit 1h 0m)")
    end

    it "applies the limit to an agent's waiting screen" do
      review_waits(["screen", false, 3700])

      row = call_dialog(reviewing(started: 3800))

      expect(row).to include("outcome" => "evaluated", "cause" => "permission_wait")
      expect(engine).to have_received(:review_stalled).with("wr_1", hash_including(data: include("screen" => true)))
    end

    it "changes nothing while the pane has shown output within the quiet window" do
      review_waits(["a1", true, 3700], idle: 30)

      row = call_dialog(reviewing(started: 3800))

      expect(row).to include("outcome" => "nothing", "reason" => "waiting_permission", "cause" => "permission_wait")
      expect(row["message"]).to include("showed output 30 seconds ago (it must be quiet for 10m)")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "changes nothing when the wait closed or another opened before the change" do
      review_waits(["a1", true, 3700])
      reads = 0
      panes.on_row = -> do
        reads += 1
        review_waits(["a1", true, 10]) if reads == 2
      end

      expect(call_dialog(reviewing(started: 3800))).to include("outcome" => "nothing", "reason" => "pane_changed", "cause" => "permission_wait")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "only reports on a dry run, and leaves a refused run alone" do
      review_waits(["a1", true, 3700])

      expect(call_dialog(reviewing(started: 3800), with: limit_pass.merge(dry_run: true))).to include("outcome" => "dry_run", "cause" => "permission_wait", "action" => "evaluate")
      expect(call_dialog(reviewing(started: 3800), with: limit_pass.merge(allow: ->(_) { "own pane" }))).to include("outcome" => "nothing", "reason" => "refused")
      expect(engine).not_to have_received(:review_stalled)
    end

    it "never decides a round on a question to the person, nor with the limit off" do
      review_waits([nil, false, 90_000])
      expect(call_dialog(reviewing(started: 90_100))).to include("outcome" => "nothing", "reason" => "prompt")

      review_waits(["a1", true, 90_000])
      row = call_dialog(reviewing(started: 90_100), with: limit_pass.merge(permission_wait_limit: nil))
      expect(row["message"]).to end_with("; no limit is set (workflows.permission_wait_limit)")
      expect(engine).not_to have_received(:review_stalled)
    end
  end

  describe "#held_row" do
    it "names the round a person decides" do
      run = reviewing.to_h.merge("state" => "waiting", "reason" => {"code" => "review_incomplete"})

      expect(sweep.held_row(Workspace::WorkflowRun.from_h(run))).to include("outcome" => "nothing", "reason" => "held",
        "message" => "review round 1 of step build stopped (review_incomplete); a person decides it")
    end
  end

  describe "#orphan_rows" do
    let(:orphans) { instance_double(Workspace::WorkflowReviewOrphans) }
    subject(:sweep) { described_class.new(engine: engine, panes: panes, interrupter: interrupter, orphans: orphans, clock: -> { now }) }

    it "asks allow about the closable window's own run before closing it" do
      run = reviewing
      allow(orphans).to receive(:find).and_return([{session: "app", window: "@9", pane: "%9", run_id: "wr_1", step: "build", round: 1,
                                                    workspace: "app", run: run, why: "run_over", closable: true}])
      allow(orphans).to receive(:close)
      asked = []

      rows = sweep.orphan_rows(nil, nil, {allow: ->(each) { asked << each and "keep it" }})

      expect(asked).to eq([run])
      expect(rows).to contain_exactly(include("outcome" => "nothing", "reason" => "refused"))
      expect(orphans).not_to have_received(:close)
    end
  end
end
