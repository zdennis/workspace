require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "delegate"

# The harness for an engine that dies in the middle of a change: the parts the simulator plays a run with
# (WorkflowSimulator#play), assembled here so one crash point can be armed in them, and the in-memory fakes (pane,
# guard, attempt records, clock, inbox) shared with a fresh engine built on the same run directory afterwards.
module RunChangeCrash
  # Not a StandardError, so no bare `rescue` in the engine can swallow it, as a killed process is not swallowed.
  STALL = 600

  # Why a step line never typed is a failing crash point.
  NEVER_TYPED = "no tick types again the line of a `delivering` attempt that was never typed: WorkflowTransitions.redelivery " \
    "needs the attempt's outcome `not_delivered` (lib/workspace/workflow_transitions.rb:816-835), so the sweep's " \
    "idle_turn_over at the stall (lib/workspace/workflow_sweep.rb:565) ends the plan step `turn_ended_incomplete`"

  class Crash < Exception # standard:disable Lint/InheritException
  end

  # One armed crash point at a time; it fires once, on the nth call whose info the match accepts, then disarms.
  # Points: :before_kick and :after_kick (info: the typed text), :record_event (the event type), :recorded (the
  # event type and data, once written), :stored (the run, once a change has written it), :event_log (the
  # `workflow_changed` data), :alerts_marks and :alerts_fire (the run), :inbox (the item's dedupe key).
  class Points
    attr_reader :fired

    def arm(point, nth: 1, &match)
      @armed = {point: point, nth: nth, match: match || ->(_) { true }, seen: 0}
      self
    end

    def check!(point, info = nil)
      armed = @armed
      return unless armed && armed[:point] == point && armed[:match].call(info)
      armed[:seen] += 1
      return if armed[:seen] < armed[:nth]
      @armed = nil
      @fired = [point, info]
      raise Crash, "crashed at #{point}: #{info.inspect}"
    end
  end

  # The shared SimPanes with a crash point either side of a kick, refusals the daemon gives once each (+refusals+,
  # shared between engines: {code:, match:} on the typed text), and, once `idle!`, a pane row that shows the agent's
  # turn long over, so a sweep acts on a running step.
  class Panes < SimpleDelegator
    def initialize(panes, points, refusals)
      super(panes)
      @points = points
      @refusals = refusals
      @idle_for = nil
    end

    def idle!(seconds)
      @idle_for = seconds
    end

    def kick(text: nil, **rest)
      @points.check!(:before_kick, text)
      refusal = @refusals.find { |each| each[:match].call(text) }
      if refusal
        @refusals.delete(refusal)
        return {ok: false, code: refusal[:code], message: "refused by the crash spec"}
      end
      result = __getobj__.kick(text: text, **rest)
      @points.check!(:after_kick, text)
      result
    end

    def pane_row(workspace, pane)
      return __getobj__.pane_row(workspace, pane) unless @idle_for
      {"pane_id" => pane, "kind" => "claude", "state" => "idle", "idle_seconds" => @idle_for}
    end

    def session_live?(_workspace) = true
  end

  # The run store with a crash point before and after each history line is written, and after each change is stored.
  class Store < Workspace::WorkflowRunStore
    def initialize(points:, **rest)
      super(**rest)
      @points = points
    end

    def record_event(id, type, data = {})
      @points.check!(:record_event, type)
      written = super
      @points.check!(:recorded, [type, data])
      written
    end

    def change(id, **opts, &block)
      stored = super
      @points.check!(:stored, stored) if stored
      stored
    end
  end

  class EventLog
    attr_reader :lines

    def initialize(points)
      @points = points
      @lines = []
    end

    def record(type:, project:, data:)
      @points.check!(:event_log, data)
      @lines << {type: type, project: project, data: data}
    end
  end

  class Alerts
    def initialize(points)
      @points = points
    end

    def marks(run)
      @points.check!(:alerts_marks, run)
      nil
    end

    def fire(_before, run)
      @points.check!(:alerts_fire, run)
      nil
    end
  end

  # One workspace's inbox, kept in memory and shared between the engines; its points belong to whichever engine
  # posts, so `points=` hands it to the fresh one.
  class Inbox
    Upsert = Struct.new(:item, :outcome)
    attr_reader :items
    attr_accessor :points

    def initialize(points)
      @points = points
      @items = {}
    end

    def upsert(record, reopen: false)
      @points.check!(:inbox, record["dedupe_key"])
      outcome = @items.key?(record["dedupe_key"]) ? "updated" : "created"
      @items[record["dedupe_key"]] = record
      Upsert.new(record, outcome)
    end

    def list = @items.values
  end
end

# The rpiv-auto-approve-v2 preset over its golden script, driven through engines built as WorkflowSimulator#play builds
# them, so a later example can crash one engine at an armed point and recover the run with a fresh one.
RSpec.describe Workspace::WorkflowRunChange, "when the engine dies mid-change" do
  def sim = Workspace::WorkflowSimulator

  def run_id = sim::RUN_ID

  around do |example|
    Dir.mktmpdir("wf-crash") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:fixtures) { File.join(PROJECT_ROOT, "spec", "fixtures", "workflow_simulator_golden") }
  let(:golden) { JSON.parse(File.read(File.join(fixtures, "rpiv-auto-approve-v2.json"))) }
  let(:definition) { PresetSimulation.definition("rpiv-auto-approve-v2") }
  let(:script) { Workspace::WorkflowSimScript.parse(File.read(File.join(fixtures, "rpiv-auto-approve-v2.script.yml")), definition: definition.to_h, source: "golden.yml") }
  let(:checkout) { File.join(@dir, "checkout").tap { |path| FileUtils.mkdir_p(path) } }
  let(:clock) { sim::SimClock.new }
  let(:sim_panes) { sim::SimPanes.new }
  let(:guard) { sim::SimGuard.new }
  let(:records) { sim::SimRecords.new(Workspace::WorkflowAttemptRecord.new(guard: guard, clock: clock)) }
  let(:points) { RunChangeCrash::Points.new }
  let(:inbox) { RunChangeCrash::Inbox.new(points) }
  # The daemon refusals armed for a kick, shared between engines as the pane is.
  let(:refusals) { [] }
  # The fake agent's turns taken, by prompt file: it takes one for each line typed.
  let(:turns) { Hash.new(0) }

  # One engine over the run directory and the shared fakes; +points+ arms its crash points.
  # Mirrors WorkflowSimulator#play, its round_runner and drive/next_move/act: change this when they change.
  def build(points = RunChangeCrash::Points.new)
    store = RunChangeCrash::Store.new(points: points, dir: File.join(@dir, "state", "runs"), archive_dir: File.join(@dir, "state", "archive"),
      clock: clock, id_generator: -> { run_id })
    panes = RunChangeCrash::Panes.new(sim_panes, points, refusals)
    inbox.points = points
    engine = Workspace.build_workflow_engine(store: store, resources: sim::SimResources.new, composer: sim::SimComposer.new, panes: panes,
      checker: sim::SimChecker.new(script), commands_config: sim::SimCommands.new, lineage: sim::SimLineage.new, git: sim::SimGit.new, guard: guard,
      excludes: sim::SimExcludes.new, gate_note: sim::SimGateNote.new, attempt_record: records, require_check: sim::SimRequire.new(script, guard),
      exec_program: sim::SimExecProgram.new, review_round: round_runner(store), review_closer: ->(_run_id, _round) {},
      review_tally: Workspace::WorkflowReviewTally.new(proof: sim::SimVerdictProof.new), review_revision: sim::SimRevision.new(script),
      event_log: RunChangeCrash::EventLog.new(points), alerts: RunChangeCrash::Alerts.new(points), inbox_for: ->(_workspace) { inbox }, clock: clock)
    {engine: engine, store: store, panes: panes}
  end

  # The simulator's stand-in for a round's delivery (WorkflowSimulator#round_runner).
  def round_runner(store)
    lambda do |id, review|
      run = store.change(id) do |read|
        hash = read.thawed
        revision = review["revision"] || sim.revision_of(script, review["step"], review["attempt"])
        round = hash["steps"][hash["current"]]["review"]
        round.merge!("pane" => sim::REVIEW_PANE, "delivery" => nil, "revision" => revision, "packs" => [], "panes" => (Array(round["panes"]) | [sim::REVIEW_PANE]))
        round.delete("uncleared")
        Workspace::WorkflowRun.from_h(hash)
      end
      store.record_event(id, "review_delivered", review.slice("step", "attempt", "round").merge("pane" => sim::REVIEW_PANE, "window" => nil, "reused" => false))
      run
    end
  end

  def start(parts)
    parts[:engine].start(definition: definition, workspace: sim::WORKSPACE, worktree: checkout, inputs: PresetSimulation.inputs(definition), pane: sim::PANE, actor: "person")
  end

  # The fake agent, reviewers and clock, one move at a time, until the run ends or nothing is left to do.
  # @return [Integer] the moves made
  def drive(parts, max_moves: 60)
    moves = 0
    while moves < max_moves
      run = parts[:store].run(run_id)
      break if Workspace::WorkflowRunStore::TERMINAL_STATES.include?(run.state)
      move = next_move(run)
      break unless move
      moves += 1
      act(move, run, parts)
    end
    moves
  end

  def next_move(run)
    state = run.step(run.current)
    backoff = run.backoff_for(run.current)
    return :backoff if backoff.is_a?(Hash) && backoff["to"].is_a?(String) && !backoff["blocked"]
    return nil if run.reason_for(run.current) || run.parked
    return :review if state.state == "reviewing" && state.review.is_a?(Hash) && state.review["pane"] == sim::REVIEW_PANE
    prompt = state.last_attempt&.to_h&.dig("prompt_file")
    :turn if state.state == "running" && prompt && typed_lines[File.basename(prompt)] > turns[File.basename(prompt)]
  end

  def act(move, run, parts)
    engine = parts[:engine]
    step = run.current
    number = run.step(step).last_attempt.n
    case move
    when :backoff
      clock.advance_to(Time.iso8601(run.backoff_for(step)["until"]))
      engine.tick(run_id, actor: "daemon")
    when :review
      round = run.step(step).review
      rerun = round["reruns"].to_i
      said = rerun.zero? ? script.attempt(step, number).fetch("reviews", {}) : (Array(script.attempt(step, number)["reruns"])[rerun - 1] || {})
      dir = Workspace::ReviewRoundPath.round_dir(run.artifacts_dir, step, number, round["round"])
      said.each do |reviewer, verdict|
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{reviewer}.md"), Workspace::WorkflowReviewTally.header_lines(reviewer: reviewer, verdict: verdict, revision: round["revision"]).join("\n"))
      end
      clock.advance(1)
      engine.turn_ended(run_id, actor: "daemon", pane: sim::REVIEW_PANE)
    when :turn
      turns[File.basename(run.step(step).last_attempt.to_h["prompt_file"])] += 1
      said = script.attempt(step, number)
      files = said.key?("writes") ? said["writes"] : definition.to_h["steps"].find { |each| each["id"] == step }["produces"]
      files.each do |file|
        path = File.join(run.artifacts_dir, file)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "written by the crash spec\n")
        File.utime(clock.call, clock.call, path)
      end
      records.tokens[[step, number]] = said["tokens"].to_i
      engine.report(run_id, actor: "agent", status: said["report"], summary: said["summary"], code: said["code"]) if said["report"]
      clock.advance(1)
      engine.turn_ended(run_id, actor: "daemon", pane: run.pane_for(step) || sim::PANE)
    end
  end

  # What a restarted daemon and the sweep do for the run: a fresh engine on the same directory, the clock past the
  # delivery window and the default stall, the pane idle that long, then tick and sweep until a pass changes nothing.
  # A finished run gets no tick, as the daemon gives it none.
  # @return [Array(Hash, Integer)] the fresh engine's parts, and the passes that changed the run, its history or the lines typed (at most 6)
  def recover
    parts = build
    idle = Workspace::WorkflowTransitions::DELIVERY_WINDOW + RunChangeCrash::STALL + 1
    clock.advance(idle)
    parts[:panes].idle!(idle)
    reviews = Workspace::WorkflowReviewSweep.new(engine: parts[:engine], panes: parts[:panes], interrupter: ->(*) {}, clock: clock)
    sweep = Workspace::WorkflowSweep.new(store: parts[:store], engine: parts[:engine], panes: parts[:panes], interrupter: ->(*) {}, reviews: reviews,
      default_stall: -> { RunChangeCrash::STALL }, clock: clock)
    passes = 0
    6.times do
      before = seen(parts[:store])
      parts[:engine].tick(run_id, actor: "daemon") unless Workspace::WorkflowRunStore::TERMINAL_STATES.include?(parts[:store].run(run_id).state)
      sweep.call
      break if seen(parts[:store]) == before
      passes += 1
    end
    [parts, passes]
  end

  def seen(store)
    [store.run(run_id).to_h, store.events(run_id)["events"].size, sim_panes.kicks.size]
  end

  # The lines typed into the run's pane, by the prompt file each names (`<step>.<attempt>.prompt.md`).
  def typed_lines
    sim_panes.kicks.each_with_object(Hash.new(0)) do |kick, counts|
      file = kick[:text].to_s[/[^\s\/]+\.\d+\.prompt\.md/]
      counts[file] += 1 if file
    end
  end

  # The run as the golden transcript's "run" and "steps" show it.
  def final_state(store)
    run = store.run(run_id)
    {"run" => {"state" => run.state, "current" => run.current, "reason" => run.reason_for(run.current)&.dig("code"), "loops" => run.loops},
     "steps" => definition.to_h["steps"].map do |step|
       {"id" => step["id"], "state" => run.step(step["id"]).state, "attempts" => run.step(step["id"]).attempts.map { |each| attempt_row(each.to_h) }}
     end}
  end

  def attempt_row(attempt)
    row = attempt.slice("n", "outcome", "code")
    fresh = sim_panes.fresh_for(attempt["prompt_file"])
    row["fresh"] = fresh unless fresh.nil?
    reviews = attempt["reviews"] || Array(attempt["rounds"]).last&.dig("reviews")
    row["reviews"] = reviews.map { |each| each.slice("reviewer", "verdict", "counted", "problem") } if reviews.is_a?(Array)
    row
  end

  it "plays the golden script to the golden final state with one line typed per prompt file, and leaves recovery nothing to do" do
    parts = build(points)
    start(parts)
    drive(parts)

    expect(final_state(parts[:store])).to eq(golden.slice("run", "steps"))
    expect(points.fired).to be_nil
    expect(typed_lines.keys).to contain_exactly(*%w[research.1 plan.1 plan.2 implement.1 implement.2 verify.1 verify.2].map { |each| "#{each}.prompt.md" })
    expect(typed_lines.values.uniq).to eq([1])

    fresh, passes = recover
    expect(passes).to eq(0)
    expect(final_state(fresh[:store])).to eq(golden.slice("run", "steps"))
  end

  # The crash points of a step's delivery are armed at the plan step's first line: the first dispatch that comes out
  # of another step's pass (research's, in the same change), and the step with a review round and a `status:` check
  # after it, so a lost line there holds up the most that follows.
  def plan_line?(text) = text.to_s[/[^\s\/]+\.\d+\.prompt\.md/] == "plan.1.prompt.md"

  # The step_dispatched events recorded for the plan step's first attempt.
  def plan_dispatched_events(store)
    store.events(run_id)["events"].select { |each| each["type"] == "step_dispatched" && each["step"] == "plan" && each["attempt"] == 1 }
  end

  def plan_attempt(run) = run.step("plan")&.last_attempt&.to_h || {}

  # Plays the golden script until the armed point kills the engine. Then whatever the agents were already told goes
  # on (a turn's end reaches a fresh engine, as the daemon's nudge starts one), the daemon restarts and the sweep
  # runs ({#recover}), and the run is driven on to its end.
  # @return [Hash] :left (the plan step's last attempt as the crash left it), :store, :passes
  def crash_and_recover
    parts = build(points)
    expect {
      start(parts)
      drive(parts)
    }.to raise_error(RunChangeCrash::Crash)
    left = plan_attempt(parts[:store].run(run_id))
    dispatched = plan_dispatched_events(parts[:store])
    drive(build)
    fresh, passes = recover
    drive(fresh)
    {left: left, dispatched: dispatched, store: fresh[:store], passes: passes}
  end

  # The no-crash baseline of a plan line the daemon refuses once with +code+: the golden state, but for the plan
  # step's attempts. The refused attempt ends `not_delivered` with nothing typed, and the tick's `:redeliver` types
  # the line again as attempt 2, which plays the script's second plan attempt, as golden attempt 2 does.
  def refused_baseline(code)
    baseline = JSON.parse(JSON.generate(golden.slice("run", "steps")))
    plan = baseline["steps"].find { |each| each["id"] == "plan" }
    plan["attempts"] = [{"n" => 1, "outcome" => "not_delivered", "code" => code}, plan["attempts"].find { |each| each["n"] == 2 }]
    baseline
  end

  def refuse_plan_line(code) = refusals << {code: code, match: method(:plan_line?)}

  # The Measure: the baseline's final run and step state, no attempt the baseline lacks, at most one line typed per
  # prompt file.
  def expect_baseline(store, baseline)
    final = final_state(store)
    final["steps"].zip(baseline["steps"]).each do |step, base|
      expect(step["attempts"].map { |each| each["n"] } - base["attempts"].map { |each| each["n"] }).to eq([]), "#{step["id"]} has attempts the baseline lacks"
    end
    expect(final).to eq(baseline)
    expect(typed_lines.values.max).to eq(1)
  end

  # What the never-typed line leaves, asserted before the pending Measure so the Measure is pending for that reason
  # alone: the plan's first attempt is stuck `delivering` with no line typed, recovery types none, and the sweep holds
  # the run for a person.
  def expect_never_typed(result)
    expect(result[:left].slice("n", "delivery")).to eq("n" => 1, "delivery" => "delivering")
    expect(typed_lines["plan.1.prompt.md"]).to eq(0)
    expect(typed_lines.values.max.to_i).to be <= 1
    final = final_state(result[:store])
    expect(final["run"].slice("state", "current", "reason")).to eq("state" => "waiting", "current" => "plan", "reason" => "turn_ended_incomplete")
    expect(final["steps"].find { |each| each["id"] == "plan" }["attempts"]).to eq([{"n" => 1}])
  end

  # The tail B5, B6 and B8 share: one pass, the line never typed, and the pending Measure for that reason alone.
  def expect_untyped_then_pending(result, baseline)
    expect(result[:passes]).to eq(1)
    expect_never_typed(result)
    pending RunChangeCrash::NEVER_TYPED
    expect_baseline(result[:store], baseline)
  end

  it "B5: a crash after the store that started the plan step, before its line is delivered, leaves it untyped (1 pass)" do
    points.arm(:stored) { |run| plan_attempt(run).slice("n", "delivery") == {"n" => 1, "delivery" => "delivering"} }
    result = crash_and_recover

    expect_untyped_then_pending(result, golden.slice("run", "steps"))
  end

  it "B6: a crash inside the kick, before the plan line is typed, leaves it untyped (1 pass)" do
    points.arm(:before_kick) { |text| plan_line?(text) }
    result = crash_and_recover

    expect_untyped_then_pending(result, golden.slice("run", "steps"))
  end

  it "B7: a crash after the plan line is typed, before step_dispatched and the settle, ends at the golden state through the turn's end (0 passes)" do
    points.arm(:after_kick) { |text| plan_line?(text) }
    result = crash_and_recover

    expect(result[:left].slice("n", "delivery")).to eq("n" => 1, "delivery" => "delivering")
    expect(result[:dispatched]).to eq([])
    expect(result[:passes]).to eq(0)
    expect_baseline(result[:store], golden.slice("run", "steps"))
  end

  it "B8: a crash after step_dispatched records the refused plan line, before the settle, loses the pane_busy retry (1 pass)" do
    baseline = refused_baseline("pane_busy")
    refuse_plan_line("pane_busy")
    points.arm(:recorded) { |(type, data)| type == "step_dispatched" && data["step"] == "plan" && data["delivered"] == false }
    result = crash_and_recover

    expect_untyped_then_pending(result, baseline)
  end

  it "B10: a crash after the settle stored the refused plan line as not_delivered ends where the refusal alone does, through tick :redeliver (1 pass)" do
    baseline = refused_baseline("pane_busy")
    refuse_plan_line("pane_busy")
    points.arm(:stored) { |run| plan_attempt(run).slice("n", "outcome") == {"n" => 1, "outcome" => "not_delivered"} }
    result = crash_and_recover

    expect(result[:left].slice("n", "outcome", "code")).to eq("n" => 1, "outcome" => "not_delivered", "code" => "pane_busy")
    expect(result[:passes]).to eq(1)
    expect_baseline(result[:store], baseline)
  end

  it "B11: a run with no crash and the one-shot pane_busy refusal at plan.1 reaches the refused baseline" do
    refuse_plan_line("pane_busy")
    parts = build(points)
    start(parts)
    drive(parts)
    fresh, passes = recover
    drive(fresh)

    expect(points.fired).to be_nil
    expect(passes).to eq(1)
    expect_baseline(fresh[:store], refused_baseline("pane_busy"))
  end
end
