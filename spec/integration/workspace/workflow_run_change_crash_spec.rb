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

  class Crash < Exception # standard:disable Lint/InheritException
  end

  # One armed crash point at a time; it fires once, on the nth call whose info the match accepts, then disarms.
  # Points: :before_kick and :after_kick (info: the typed text), :record_event (the event type), :event_log (the
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

  # The shared SimPanes with a crash point either side of a kick, and, once `idle!`, a pane row that shows the
  # agent's turn long over, so a sweep acts on a running step.
  class Panes < SimpleDelegator
    def initialize(panes, points)
      super(panes)
      @points = points
      @idle_for = nil
    end

    def idle!(seconds)
      @idle_for = seconds
    end

    def kick(text: nil, **rest)
      @points.check!(:before_kick, text)
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

  # The run store with a crash point before each history line is written.
  class Store < Workspace::WorkflowRunStore
    def initialize(points:, **rest)
      super(**rest)
      @points = points
    end

    def record_event(id, type, data = {})
      @points.check!(:record_event, type)
      super
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
  # The fake agent's turns taken, by prompt file: it takes one for each line typed.
  let(:turns) { Hash.new(0) }

  # One engine over the run directory and the shared fakes; +points+ arms its crash points.
  # Mirrors WorkflowSimulator#play, its round_runner and drive/next_move/act: change this when they change.
  def build(points = RunChangeCrash::Points.new)
    store = RunChangeCrash::Store.new(points: points, dir: File.join(@dir, "state", "runs"), archive_dir: File.join(@dir, "state", "archive"),
      clock: clock, id_generator: -> { run_id })
    panes = RunChangeCrash::Panes.new(sim_panes, points)
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
end
