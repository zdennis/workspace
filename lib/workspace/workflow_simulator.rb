require "delegate"
require "fileutils"
require "time"
require "tmpdir"

module Workspace
  # Plays a workflow through the real {WorkflowEngine} with a scripted fake agent ({WorkflowSimScript}),
  # to see how its loops, gates, retries and token budget behave without spending a run.
  #
  # The engine is the real one. Everything it touches outside itself is replaced: a run store, a checkout
  # and the artifacts in a temporary directory (removed afterwards), a pane that is only a name, locks that are
  # always free, a clock that only moves when a retry's wait is over, and the checks and proofs, which are never
  # run: the script says how each one comes out. No tmux, daemon, inbox, notifier, event log, task or lock
  # file is read or written, and nothing of the real run store.
  #
  # The fake agent acts when the engine says a step is waiting for it: it writes the step's files, reports if the
  # script says so, and ends its turn. The simulation ends when the run is finished, when it waits for a person
  # (a failed check, a spent budget, a missing file, a refusal), or after {MAX_ACTIONS} actions.
  class WorkflowSimulator
    # The most actions (agent turns, gate decisions, ended waits) one simulation takes.
    MAX_ACTIONS = 200

    # The pane the run is bound to; it exists only here.
    PANE = "%sim".freeze

    # The workspace the run is in.
    WORKSPACE = "simulation".freeze

    RUN_ID = "wr_simulated".freeze
    # Where the simulated time starts; it is the same every time so a transcript can be compared.
    START = Time.utc(2026, 1, 1)

    # @param engine_factory [#call] given the engine's collaborators as keywords, returns a {WorkflowEngine}
    # @param tmpdir [#call] as `Dir.mktmpdir`: given a prefix, yields a directory and removes it after
    # @param max_actions [Integer] the most actions played before the run is capped
    def initialize(engine_factory:, tmpdir: Dir.method(:mktmpdir), max_actions: MAX_ACTIONS)
      @max_actions = max_actions
      @engine_factory = engine_factory
      @tmpdir = tmpdir
    end

    # @param definition [Workspace::WorkflowDefinition]
    # @param script [Workspace::WorkflowSimScript]
    # @param inputs [Hash{String=>String}] the input values; they win over the script's
    # @return [Hash{String=>Object}] "workflow", "inputs" (as the run used them), "outcome" (`completed`, `failed`, `cancelled`, `stopped`
    #   or `capped`), "stopped" (the step, attempt and reason code when the run waits for a person),
    #   "capped", "max_actions", "actions", "run" (state, current step, reason code, loops), "steps"
    #   (each step's attempts: n, outcome, code), "budget" (the token reading, or nil) and "transitions" (the
    #   run's history: n, at (seconds into the simulation), type and the event's own keys)
    # @raise [Workspace::Error] the engine's refusals of a start (`input_required`, `invalid_input`, ...)
    def call(definition:, script:, inputs: {})
      @tmpdir.call("workspace-simulate") do |dir|
        play(definition, script, script.inputs.merge(inputs), dir)
      end
    rescue SystemCallError => e
      raise Workspace::Error.new("Workflow #{definition.to_h["id"]} can't be simulated: a file or directory it needs could not be made (#{e.class.name.split("::").last}), " \
        "for instance two `produces:` entries where one is a directory of the other.",
        code: "invalid_workflow", details: {"workflow" => definition.to_h["id"], "error" => e.class.name.split("::").last})
    end

    private

    def play(definition, script, inputs, dir)
      clock = SimClock.new
      store = WorkflowRunStore.new(dir: File.join(dir, "state", "runs"), archive_dir: File.join(dir, "state", "archive"),
        clock: clock, id_generator: -> { RUN_ID })
      panes = SimPanes.new
      guard = SimGuard.new
      records = SimRecords.new(WorkflowAttemptRecord.new(guard: guard, clock: clock))
      checkout = File.join(dir, "checkout")
      FileUtils.mkdir_p(checkout)
      engine = @engine_factory.call(store: store, resources: SimResources.new, composer: SimComposer.new, panes: panes, checker: SimChecker.new(script),
        commands_config: SimCommands.new, lineage: SimLineage.new, git: SimGit.new, guard: guard, excludes: SimExcludes.new, gate_note: SimGateNote.new,
        attempt_record: records, require_check: SimRequire.new(script), clock: clock)
      run = WorkflowRun.from_h(engine.start(definition: definition, workspace: WORKSPACE, worktree: checkout, inputs: inputs, pane: PANE))
      actions, capped = drive(engine, store, run.id, definition.to_h, script, clock, records)
      report(store, run.id, definition.to_h, clock, actions, capped)
    end

    # The fake agent and the fake person, one move at a time, until the run is finished or waits for a real person.
    def drive(engine, store, id, data, script, clock, records)
      actions = 0
      loop do
        run = store.run(id)
        return [actions, false] if WorkflowRunStore::TERMINAL_STATES.include?(run.state)
        return [actions, true] if actions >= @max_actions
        move = next_move(run)
        return [actions, false] unless move
        actions += 1
        begin
          act(move, engine, store, run, data, script, clock, records)
        rescue Workspace::Error => e
          store.record_event(id, "simulated_refused", "code" => e.code, "message" => e.message.lines.first.to_s.strip)
          return [actions, false]
        end
      end
    end

    def next_move(run)
      state = run.steps.fetch(run.current)
      backoff = run.backoff
      return :backoff if backoff.is_a?(Hash) && backoff["to"].is_a?(String) && !backoff["blocked"]
      return :gate if state.gate_waiting?
      :turn if state.state == "running" && run.reason.nil? && !run.parked
    end

    def act(move, engine, store, run, data, script, clock, records)
      id = run.id
      step = run.current
      case move
      when :backoff
        clock.advance_to(Time.iso8601(run.backoff["until"]))
        store.record_event(id, "simulated_wait", "step" => step, "until" => run.backoff["until"])
        engine.tick(id)
      when :gate
        number = run.step(step).last_attempt.n
        said = script.attempt(step, number)
        if said["gate"] == "reject"
          note = said["note"] || "rejected by the script"
          store.record_event(id, "simulated_person", "action" => "reject", "step" => step, "attempt" => number)
          engine.reject(id, note: note)
        else
          store.record_event(id, "simulated_person", "action" => "approve", "step" => step, "attempt" => number)
          engine.approve(id, note: said["note"])
        end
      when :turn
        turn(engine, store, run, data, script, records, clock)
      end
    end

    def turn(engine, store, run, data, script, records, clock)
      id = run.id
      step = run.current
      number = run.step(step).last_attempt.n
      said = script.attempt(step, number)
      definition = data["steps"].find { |each| each["id"] == step }
      files = said.key?("writes") ? said["writes"] : definition["produces"]
      files.each { |file| write(run, file, clock) }
      store.record_event(id, "simulated_agent", {"action" => "turn", "step" => step, "attempt" => number, "wrote" => files}.merge(said.slice("report", "summary", "code")))
      records.tokens[[step, number]] = said["tokens"].to_i
      engine.report(id, status: said["report"], summary: said["summary"], code: said["code"]) if said["report"]
      # The turn takes a second, so the next attempt starts after this one's files and an old file reads as stale.
      clock.advance(1)
      engine.turn_ended(id, pane: PANE)
    end

    def write(run, file, clock)
      path = File.join(run.artifacts_dir, file)
      return unless File.expand_path(path).start_with?(File.expand_path(run.artifacts_dir) + File::SEPARATOR)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "written by workflow simulate\n")
      File.utime(clock.call, clock.call, path)
    end

    def report(store, id, data, clock, actions, capped)
      run = store.run(id)
      events = store.events(id, limit: WorkflowRunStore::EVENTS_LIMIT)["events"]
      outcome = if capped then "capped"
      elsif WorkflowRunStore::TERMINAL_STATES.include?(run.state) then run.state
      else "stopped"
      end
      stopped = (outcome == "stopped") ? {"step" => run.current, "attempt" => run.step(run.current).last_attempt&.n, "reason" => run.reason&.dig("code")} : nil
      {"workflow" => data["id"], "inputs" => run.inputs, "outcome" => outcome, "stopped" => stopped, "capped" => capped, "max_actions" => @max_actions, "actions" => actions,
       "run" => {"state" => run.state, "current" => run.current, "reason" => run.reason&.dig("code"), "loops" => run.loops},
       "steps" => data["steps"].map { |step| {"id" => step["id"], "state" => run.step(step["id"]).state, "attempts" => run.step(step["id"]).attempts.map { |each| each.to_h.slice("n", "outcome", "code") }} },
       "budget" => WorkflowBudget.reading(run),
       "transitions" => events.map { |event| {"n" => event["n"], "at" => (Time.iso8601(event["ts"]) - START).round}.merge(event.except("n", "ts")) }}
    end

    # Simulated time: whole seconds, moving a second per agent turn and when a retry's wait is over.
    class SimClock
      def initialize
        @now = START
      end

      def call
        @now
      end

      def advance(seconds)
        @now += seconds
      end

      def advance_to(time)
        @now = time if time > @now
      end
    end

    # Locks that are always free and held by nobody.
    class SimResources
      def acquire(**)
        {status: :ok, released: [], acquired: [], handed_over: [], waiting: nil}
      end

      def release(**)
        []
      end
    end

    # The instructions without packs: what the engine writes to the prompt file is the workflow's and the step's own text.
    class SimComposer
      def compose(workflow:, step:, attempt:, **)
        text = [workflow["text"], step["text"], *attempt].compact.join("\n\n")
        {"text" => text, "packs" => []}
      end
    end

    # A pane that is only a name: bound to one run, always there, and it takes every line.
    class SimPanes
      def initialize
        @bound = {}
      end

      def bind(run_id:, pane:, **)
        @bound[run_id] = pane
      end

      def unbind(run_id)
        @bound.delete(run_id)
      end

      def run_on(pane)
        @bound.key(pane)
      end

      def pane_of(run_id)
        @bound[run_id]
      end

      def alive?(_run_id)
        true
      end

      def same_pane?(*)
        true
      end

      def pane_gone?(_pane)
        false
      end

      def identity(_run_id)
        nil
      end

      def kick(**)
        {ok: true}
      end
    end

    # Reads and checks nothing of a repository: there is none.
    class SimGuard
      def base(_worktree)
        {"base_sha" => nil, "base_guard" => nil}
      end

      def head(_worktree)
        nil
      end

      def check(*)
        nil
      end

      def config_change(*, **)
        nil
      end

      def remote_head(_worktree)
        {"unread" => "simulated"}
      end
    end

    class SimGit
      def worktree_branch(_path)
        "simulation"
      end
    end

    SimProject = Struct.new(:name, :git_common_dir)

    class SimLineage
      def resolve(cwd:)
        SimProject.new("simulation", nil)
      end
    end

    # Every project command is set, so a step that names `test` or `lint` has one to "run".
    class SimCommands
      def for_project(_name)
        {test: "simulated test", lint: "simulated lint"}
      end
    end

    class SimExcludes
      def add(*)
      end
    end

    class SimGateNote
      def notes_dir_of(_workspace)
        nil
      end

      def find(*)
        nil
      end
    end

    # Hands the real attempt record's work through, then sets the tokens the script gave the attempt.
    class SimRecords < SimpleDelegator
      attr_reader :tokens

      def initialize(record)
        super
        @tokens = {}
      end

      def finish(run:, step:, attempt:)
        __getobj__.finish(run: run, step: step, attempt: attempt)
        attempt["usage"] = {"input_tokens" => 0, "output_tokens" => @tokens.fetch([run["current"], attempt["n"]], 0)}
        attempt
      end
    end

    # A `status:` check that does not run: the script says how it ended.
    class SimChecker
      LOG = /\A(?<step>.+)\.(?<n>\d+)\.check\.log\z/

      def initialize(script)
        @script = script
      end

      def call(log:, **)
        found = LOG.match(File.basename(log))
        said = found ? @script.attempt(found[:step], found[:n].to_i) : {}
        FileUtils.mkdir_p(File.dirname(log))
        File.write(log, said.fetch("log", "simulated check\n"))
        case said.fetch("check", "pass")
        when "pass" then {exit_code: 0, timed_out: false}
        when "fail" then {exit_code: 1, timed_out: false}
        when "timeout" then {exit_code: nil, timed_out: true}
        else {exit_code: nil, timed_out: false, error: "the script says the check could not be run"}
        end
      end
    end

    # `require:` proofs that do not run: the script says which fail.
    class SimRequire
      def initialize(script)
        @script = script
      end

      def check(step:, attempt:, from: 0, **)
        said = @script.attempt(step["id"], attempt["n"]).fetch("require", {})
        execs = 0
        total = Array(step["require"]).count { |entry| entry.keys.first == "exec" }
        Array(step["require"]).each_with_index do |entry, index|
          name = entry.keys.first
          result = said[name]
          if name == "exec"
            result = result[execs] if result.is_a?(Array)
            execs += 1
          end
          next if index < from
          next unless result == "fail"
          detail = (name == "exec") ? "the script says exec entry #{execs} of #{total} fails" : "the script says the #{name} proof fails"
          return {"proof" => name, "index" => index, "code" => "require_#{name}", "detail" => detail, "unproven" => false}
        end
        nil
      end
    end
  end
end
