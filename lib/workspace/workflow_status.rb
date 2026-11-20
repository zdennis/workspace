require "time"

module Workspace
  # What `workflow status` shows for a run: its stored state, plus the two
  # things only a look outside the run file can tell. A step an agent should
  # be working on is `pane_gone` when its pane isn't there, and `waiting_you`
  # when the pane shows a permission prompt or the workspace has an open
  # `workspace ask` question from that pane. A step past its `timeout:` gets
  # the flag `timed_out`; nothing is stopped for it. A step that reads
  # `running` with no reason while its pane's agent is idle gets the flag
  # `idle`: its turn ended unseen, and `workflow resume` decides it. A step
  # whose line is still on its way to the agent gets the flag `delivering`;
  # one whose line was left on its way by a process that died, in a pane
  # whose agent has ended its turn, reads `waiting_you` with kind `delivery`:
  # nobody can tell whether the agent had the line.
  #
  # While a resume is parked ({WorkflowEngine#park}) the stored reason is not
  # shown, the flag is `parked` and `current` holds `parked`; only a person's
  # part (a prompt, a question) shows as a reason. Past the park's limit the
  # reason is `waiting_you`, `kind: dispatch`, `error: parked_timeout`, worked
  # out here, so it shows with no daemon to record it.
  #
  # Every reason carries `actions`, the commands that would resolve it, as
  # `{action, args, needs}` entries. With `needs` empty, `workspace <action>
  # <args...>` runs as written. Otherwise the caller supplies one value per
  # entry of `needs` (`name`, `flag`) and appends it after `args`: the flag
  # then the value, or `--` then the value when `flag` is null. No
  # placeholder is ever in `args`.
  #
  # A gate whose step's first file names a note (`note: <file>`, see
  # {WorkflowGateNote}) shows it as `gate_file` in the waiting reason's
  # details, hashed when status is read; once approved, the step's row
  # holds the hash approve recorded and `note_changed` when the note's
  # bytes differ now.
  class WorkflowStatus
    # One row of `workflow status`, as a frozen value over the Hash the `--json` document holds.
    #
    # Readers return the row's values as they are (a missing key reads nil), and {#to_h} gives
    # back the Hash it was made from, every key in its order, so a row survives a round trip
    # byte for byte. It never raises on a Hash with keys missing. {Workspace::InboxDerived},
    # {Workspace::Commands::Goal} and {Workspace::GoalState} read rows through it.
    class Row
      # @param row [Hash{String=>Object}, Row, nil] a row as {WorkflowStatus#runs} gives it
      # @return [Row]
      def self.from_h(row)
        row.is_a?(Row) ? row : new(row)
      end

      # @return [Hash{String=>Object}] the frozen Hash this row holds, as the `--json` row has it
      attr_reader :to_h

      # @param hash [Hash{String=>Object}, nil]
      def initialize(hash)
        @to_h = WorkflowRun.deep_freeze(hash.is_a?(Hash) ? hash : {})
        freeze
      end

      %w[id workflow title workspace state created_at pane current steps].each do |key|
        define_method(key) { to_h[key] }
      end

      # @return [Boolean]
      def ==(other)
        other.is_a?(Row) && to_h == other.to_h
      end
      alias_method :eql?, :==

      # @return [Integer]
      def hash
        [Row, to_h].hash
      end
    end

    # Seconds to wait for the workspace's agent daemon before going on without it.
    SNAPSHOT_TIMEOUT = 1.0

    # Seconds after an attempt starts during which an idle pane is not flagged `idle`.
    IDLE_GRACE = 30

    # Seconds a fresh turn_ended_incomplete stays hidden: a task that settled just before Stop restarts the turn on its own.
    INCOMPLETE_GRACE = 10

    # @param store [Workspace::WorkflowRunStore]
    # @param panes [Workspace::WorkflowPanes] says whether a run's pane is still there
    # @param snapshot_client [Workspace::AgentSnapshotClient] reads each pane's state from the daemon
    # @param ask_store_for [#call] returns the {Workspace::AskStore} of a workspace
    # @param gate_note [Workspace::WorkflowGateNote] finds and hashes the note a gate names
    # @param clock [#call] returns the current Time
    # @param snapshot_timeout [Numeric] seconds one daemon read may take
    # @param list_grace [Numeric] seconds a list's reads share past the timeout
    # @param downtime [Workspace::WorkflowDowntime, nil] its spans, read once for each document, are cut from the step,
    #   round and run clocks shown (nil: none)
    # @param live_usage [Workspace::WorkflowLiveUsage, nil] reads the running attempt's tokens so far (nil: none read)
    def initialize(store:, panes:, snapshot_client:, ask_store_for:, gate_note:, clock: -> { Time.now }, snapshot_timeout: SNAPSHOT_TIMEOUT, list_grace: LIST_GRACE,
      recovery_entry: ->(*) {}, downtime: nil, live_usage: nil)
      @live_usage = live_usage
      @downtime = downtime
      @snapshot_timeout = snapshot_timeout
      @list_grace = list_grace
      @store = store
      @gate_note = gate_note
      @panes = panes
      @snapshot_client = snapshot_client
      @ask_store_for = ask_store_for
      @clock = clock
      @recovery_entry = recovery_entry
    end

    # @param workspace [String, nil] only this workspace's runs
    # @param all [Boolean] finished runs too, after the ones still going
    # @return [Hash] "runs" (see {#run}) and "warnings" (strings): a run file that can't
    #   be read or shown is left out of "runs" and named in a warning
    def runs(workspace: nil, all: false)
      stored = @store.going + (all ? @store.finished : [])
      stored = stored.select { |run| run.workspace == workspace } if workspace
      present_all(stored)
    end

    # The runs of one project, active ones first, then finished ones. A run
    # belongs, active or finished, when its workspace is one of the project's
    # members, when its stored "project" is the project's name, or when its
    # workspace name has the project's name as its worktree prefix. The last
    # two keep the finished runs of a killed worktree and cover a project whose
    # name differs in case from its workspace names. Two projects with the same
    # name share the runs those two rules match.
    #
    # @param project [#name, #members] a {Workspace::ProjectCatalog::Project}
    # @return [Hash] "runs" and "warnings", as {#runs}
    def in_project(project)
      stored = (@store.going + @store.finished).select { |run| in_project?(run, project) }
      present_all(stored)
    end

    # Whether a stored run belongs to a project, by the rules {#in_project} lists.
    #
    # @param run [WorkflowRun, Hash] a stored run
    # @param project [#name, #members] a {Workspace::ProjectCatalog::Project}
    # @return [Boolean]
    def in_project?(run, project)
      run = WorkflowRun.from_h(run)
      project.members.filter_map(&:workspace).include?(run.workspace) || run.project == project.name ||
        WorkspaceName.split(run.workspace)&.first == project.name
    end

    # @param id [String] a run id
    # @return [Hash] "runs", holding the one run as "id", "workflow", "title", "workspace",
    #   "project", "worktree", "state", "created_at", "started_at", "ended_at", "current" ("step",
    #   "attempt", "state", "reason", "flags", and "parked" ("pane", "from", "requested_at",
    #   "expires_at") while a resume is parked), "steps" ("id", "title", "state", "attempts",
    #   "gate", "gate_file", "note_changed"), "base_sha", "pane", "task", "inputs", "loops", "artifacts_dir" and "events_path";
    #   and "warnings"
    # @raise [Workspace::Error] code `unknown_run`
    def run(id)
      warnings = []
      @stops = downtime_stops
      {"runs" => [present(@store.run(id), warnings)], "warnings" => warnings.uniq}
    ensure
      @stops = nil
    end

    # The needs a resume has when the run's token budget or time limit is used: the same hashes `workflow
    # status` puts on its own resume action.
    #
    # @param run [WorkflowRun]
    # @return [Array<Hash{String=>Object}>] `extra_tokens` and `extra_time` needs; empty when neither is spent
    def limit_needs(run)
      budget = WorkflowBudget.reading(run.to_h)
      deadline = WorkflowDeadline.reading(run.to_h, @clock.call, stops: stops)
      needs = []
      needs << NextAction.need("extra_tokens", "--extra-tokens", "min" => budget["needed"], "suggested" => budget["suggested"]) if budget && budget["spent"]
      needs << NextAction.need("extra_time", "--extra-time", "min" => deadline["needed"], "suggested" => deadline["suggested"]) if deadline && deadline["spent"]
      needs
    end

    # Whether `workflow resume --restart-step` applies: the step is running, its last attempt is still open and it
    # has an open `pane_gone` or `agent_gone` stall. A `pane_gone` reason over a closed attempt does not qualify, and a
    # fan_out sibling that runs as a sub-agent of the run's own pane has no pane of its own to restart.
    #
    # @param run [Hash{String=>Object}] a stored run
    # @param now [Time, nil] when given, a line still being typed ({WorkflowTransitions.delivery}) rules it out
    # @return [Boolean]
    def self.restartable?(run, now: nil)
      state = run.dig("steps", run["current"])
      return false unless state.is_a?(Hash) && state["state"] == "running"
      return false if WorkflowRun.pane_free?(run, run["current"])
      last = Array(state["attempts"]).last
      return false unless last.is_a?(Hash) && !last["ended_at"]
      return false if now && WorkflowTransitions.delivery(last, now) == :delivering
      WorkflowTransitions.open_stalls(run).intersect?(%w[pane_gone agent_gone])
    end

    # The stall causes an automatic restart handles, in the words a person reads.
    INFRA_CAUSE_WORDS = {"agent_gone" => "agent exited", "pane_gone" => "pane closed"}.freeze

    # Why an automatic restart gave up, in plain words; a code with no entry is shown as it is, escaped for a terminal.
    INFRA_REASON_WORDS = {
      "agent_kind_unsupported" => "only Claude Code agents restart on their own",
      "agent_waiting_sign_in" => "the new agent is waiting for sign-in",
      "agent_waiting_trust" => "the new agent is waiting for trust",
      "agent_waiting_approval" => "the new agent is waiting for approval",
      "agent_not_ready" => "the new agent never became ready",
      "no_session" => "the workspace's tmux session is gone",
      "spawn_failed" => "a new pane could not be started",
      "restart_refused" => "the restart was refused",
      "subagent_step_no_pane" => "the step runs as a sub-agent of the run's pane, which has no pane of its own to restart",
      "restart_error" => "the restart failed; see the run's events",
      "claim_lost" => "a restart began but never finished",
      "still_working" => "the agent was busy again",
      "attempts_spent" => "the step has no attempts left",
      "step_attempts_spent" => "the step has no attempts left",
      "budget_spent" => "the token budget is used",
      "run_timed_out" => "the run's time limit is used",
      "gate_waiting" => "a gate is waiting for approval",
      "run_paused" => "the run is paused"
    }.freeze

    # @param cause [String, nil] a stall cause (`agent_gone`, `pane_gone`)
    # @return [String] "agent exited", "pane closed", or the cause escaped
    def self.infra_cause_words(cause)
      INFRA_CAUSE_WORDS.fetch(cause.to_s) { TerminalText.escape(cause.to_s) }
    end

    # @param reason [String, nil] an automatic restart's give-up reason
    # @return [String] its plain words, or the code escaped
    def self.infra_reason_words(reason)
      INFRA_REASON_WORDS.fetch(reason.to_s) { TerminalText.escape(reason.to_s) }
    end

    private

    # The downtime spans the document being built was read with; one read for each document.
    def stops = @stops || downtime_stops

    def downtime_stops
      @downtime&.spans(@clock.call) || []
    end

    # Warns of unreadable run files, then shows each stored run; a malformed one is a warning.
    # "unreadable" counts the run files and runs left out.
    def present_all(stored)
      paths = @store.unreadable
      warnings = paths.map do |path|
        "The run file #{path} can't be read, so its run is not shown. What it held stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file."
      end
      malformed = 0
      # One daemon answer (or silence) per workspace for the whole list, asked in parallel under one deadline.
      @snapshots = prefetch_snapshots(stored)
      @stops = downtime_stops
      shown = stored.filter_map do |run|
        present(run, warnings)
      rescue KeyError, NoMethodError, TypeError, ArgumentError
        malformed += 1
        warnings << "Workflow run #{run.id} can't be shown: its run file is malformed. What it holds stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file."
        nil
      end
      {"runs" => shown, "warnings" => warnings.uniq, "unreadable" => paths.size + malformed}
    ensure
      @snapshots = nil
      @stops = nil
    end

    # Seconds all the daemon reads of one list share, past SNAPSHOT_TIMEOUT.
    LIST_GRACE = 0.25

    # Each workspace with a run whose pane will be looked at, read in its own thread; a daemon that has not
    # answered by the shared deadline reads as an error, as a refused connection would.
    def prefetch_snapshots(stored)
      names = stored.filter_map do |run|
        next if WorkflowRunStore::TERMINAL_STATES.include?(run.state)
        run.workspace if run.parked || %w[running checking].include?(run.step(run.current)&.state) || review_pane_of(run) || sibling_working?(run)
      end.uniq
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      deadline = clock.call + @snapshot_timeout + @list_grace
      threads = names.to_h do |name|
        thread = Thread.new do
          [:ok, @snapshot_client.fetch(name, timeout: @snapshot_timeout)]
        rescue Workspace::Error => e
          [:error, e]
        rescue
          [:error, Workspace::Error.new("The agent daemon for '#{name}' failed", code: "connection_failed")]
        end
        thread.report_on_exception = false
        [name, thread]
      end
      threads.to_h do |name, thread|
        finished = thread.join([deadline - clock.call, 0].max)
        thread.kill unless finished
        [name, finished ? thread.value : [:error, Workspace::Error.new("The agent daemon for '#{name}' did not answer in time", code: "connection_failed")]]
      end
    end

    # Whether a step of a fan_out group other than the cursor's is at work, so its pane is read too.
    def sibling_working?(run)
      WorkflowDefinition.group_steps(run.definition).values.flatten.any? { |id| %w[running checking].include?(run.step(id)&.state) }
    end

    def present(run, warnings)
      finished = WorkflowRunStore::TERMINAL_STATES.include?(run.state)
      view = step_view(run, finished, warnings)
      live = finished ? {} : sibling_views(run, view, warnings)
      groups = WorkflowDefinition.group_steps(run.definition)
      group_states = groups.transform_values { |ids| group_state(run, ids) }
      {
        "id" => run.id, "workflow" => run.workflow, "title" => run.title, "workspace" => run.workspace,
        "project" => run.project, "worktree" => run.worktree, "state" => group_shown_state(run, shown_state(run, view[:reason], view[:shown]), live),
        "created_at" => run.created_at, "started_at" => run.started_at, "ended_at" => run.ended_at,
        "cancelled_by" => run.cancelled_by,
        "current" => view[:current],
        "steps" => run.definition["steps"].map { |step| step_row(step, run.steps.fetch(step["id"]), run, group_states: group_states, live: live) },
        "base_sha" => run.base_sha, "pane" => view[:pane], "task" => run.task, "inputs" => run.inputs, "loops" => run.loops,
        "artifacts_dir" => run.artifacts_dir, "events_path" => @store.events_path(run.id),
        "guard_warnings" => guard_warnings(run)
      }.merge(budget_row(run)).merge(deadline_row(run)).merge(definition_row(run)).merge(groups_row(groups, group_states))
    end

    # The step the run's cursor is on, read as `workflow status` has always shown it: its pane, reason and `current`
    # hash. A step of a fan_out group reads its own pane and slots ({WorkflowRun.step_scoped?}), so the same reading
    # serves each sibling when the run is handed in with `current` on that sibling ({#sibling_views}).
    #
    # @return [Hash] :reason, :shown (the pane's daemon row), :pane, :current, :active (the step's agent is at work with
    #   nothing held) and :state (the step's state)
    def step_view(run, finished, warnings, daemon: true)
      state = run.steps.fetch(run.current)
      scoped = WorkflowRun.step_scoped?(run.to_h, run.current)
      own_pane = scoped ? run.pane_for(run.current) : run.pane
      pane = finished ? nil : (run.parked&.dig("pane") || bound_pane(run, scoped) || own_pane)
      working = !finished && %w[running checking].include?(state.state)
      # A reviewing step is not read from the author's pane, whose turn is over: while its round is live, the review
      # pane is read instead. A stopped or held round shows its stored reason.
      review_pane = finished ? nil : review_pane_of(run)
      daemon_warning(run, working || (!finished && round_live?(run)), warnings) unless finished || !daemon
      # What the pane shows matters only while an agent should be working in it, or a parked resume waits on
      # it; a run parked before its first step has no binding for `alive?` to find.
      shown = if (working && pane_alive?(run, scoped)) || (!finished && run.parked)
        pane_state(run.workspace, pane, warnings)
      elsif review_pane
        pane_state(run.workspace, review_pane, warnings)
      end
      reason = finished ? nil : reason_for(run, working, pane, shown, warnings, review_pane: review_pane)
      reason = with_gate_file(run, reason, warnings) if reason
      current = {"step" => run.current, "attempt" => state.last_attempt&.n, "state" => state.state,
                 "reason" => shown_reason(run, reason, review_pane || pane),
                 "flags" => finished ? [] : flags(run, state, reason, shown)}.merge(parked_row(run, pane)).merge(proofs_row(state)).merge(status_report_row(state))
        .merge(infra_retry_row(run, state, finished)).merge(finished ? {} : stuck_row(run, state, reason, shown, pane)).merge(finished ? {} : turn_failed_row(run, state, reason, shown, pane)).merge(finished ? {} : review_row(run, state)).merge(finished ? {} : refusal_row(run, state))
      {reason: reason, shown: shown, pane: pane, current: current, active: working && reason.nil?, state: state.state}
    end

    # The pane bound to a step of a group is its own; any other step reads the run's first author pane, as always.
    # A sibling that runs as a sub-agent of the run's own pane has no binding of its own: it reads the run's.
    def bound_pane(run, scoped)
      (scoped && !WorkflowRun.pane_free?(run.to_h, run.current)) ? @panes.pane_of(run.id, step: run.current) : @panes.pane_of(run.id)
    end

    def pane_alive?(run, scoped)
      (scoped && !WorkflowRun.pane_free?(run.to_h, run.current)) ? @panes.alive?(run.id, step: run.current) : @panes.alive?(run.id)
    end

    # The live reading of each fan_out sibling that is under way (not `pending`, and not `passed` unless it waits at a gate or holds a reason), by step id: the same
    # {#step_view} as the cursor's, taken with the run's `current` on that sibling. A paused or parked run shows none:
    # its pause or park is the run's, not a sibling's.
    def sibling_views(run, cursor_view, warnings)
      return {} if run.paused || run.parked
      WorkflowDefinition.group_steps(run.definition).values.flatten.each_with_object({}) do |id, found|
        # The one rule of a sibling under way, which the sweep, recovery and decisions share.
        next unless WorkflowTransitions.under_way?(run.to_h, id)
        found[id] = if id == run.current
          cursor_view
        else
          step_view(WorkflowRun.from_h(run.to_h.merge("current" => id)), false, warnings, daemon: false)
        end
      end
    end

    # The shown state of a run with fan_out siblings under way: `running` while any sibling's agent works with nothing
    # held, even when the stored state reads `waiting` for another sibling's hold; `waiting` when every sibling under
    # way is held and the stored state still says `running`. Any other run keeps the state it was given.
    def group_shown_state(run, base, live)
      return base if live.empty? || WorkflowRunStore::TERMINAL_STATES.include?(run.state)
      return "running" if live.values.any? { |view| view[:active] }
      return "waiting" if base == "running" && live.values.all? { |view| view[:reason] }
      base
    end

    # Where a fan_out group stands, derived from its siblings and the join's own rule for a group at rest
    # ({WorkflowTransitions.group_at_rest?}):
    #
    # - `passed`: every sibling passed and none is held (a gate waiting is `waiting`).
    # - `draining`: a sibling has failed and the join has not yet decided the group: another sibling is still at work
    #   or held, or a deferred failure move or a relay run is owed.
    # - `running`: a sibling is at work.
    # - `pending`: no sibling has started.
    # - `waiting`: nothing runs and a sibling is held (a gate, a hold, a backoff).
    # - `failed`: every sibling is at rest and one failed; the join waits for a person.
    def group_state(run, ids)
      hash = run.to_h
      states = ids.map { |id| hash.dig("steps", id, "state") }
      at_rest = WorkflowTransitions.group_at_rest?(hash, ids, @clock.call)
      return "passed" if states.all?("passed") && at_rest
      failed = states.include?("failed")
      moving = ids.any? { |id| WorkflowRun.slot(hash, id, "pending_move").is_a?(Hash) || WorkflowTransitions.relay_owed?(hash, id) }
      return "draining" if failed && (!at_rest || moving)
      return "running" if states.any? { |state| WorkflowTransitions::SIBLING_BUSY.include?(state) }
      return "pending" if states.all?("pending")
      return "waiting" unless at_rest
      failed ? "failed" : "pending"
    end

    # The `groups` of a run whose definition has fan_out groups: each group's derived state and its sibling ids.
    def groups_row(groups, group_states)
      return {} if groups.empty?
      {"groups" => groups.to_h { |id, steps| [id, {"state" => group_states[id], "steps" => steps}] }}
    end

    # The source and file a run's definition was read from at start, so status can say
    # where the workflow came from. Runs started before the run record carried these
    # have no path, and get no keys.
    def definition_row(run)
      return {} unless run.definition_path
      {"definition_source" => run.definition_source, "definition_path" => run.definition_path}
    end

    # What the guard warned of on any attempt, oldest first; the run went on past each.
    def guard_warnings(run)
      run.steps.flat_map do |id, state|
        state.attempts.flat_map do |attempt|
          Array(attempt.warnings).map { |each| each.merge("step" => id, "attempt" => attempt.n) }
        end
      end.sort_by { |each| each["at"].to_s }
    end

    # The token budget as it stands, only for a run whose definition declares one. `used` is a minimum: it leaves
    # out any ended attempt or review round whose `usage` is null (`uncounted`), and `minimum` says so.
    def budget_row(run)
      reading = WorkflowBudget.reading(run.to_h)
      return {} unless reading
      live = @live_usage&.reading(run, now: @clock.call)
      live_spent = live.is_a?(Integer) && reading["used"] + live >= reading["allowance"]
      {"budget" => reading.slice("tokens", "action", "extra_tokens", "allowance", "used", "counted", "uncounted", "estimated", "measured", "spent")
        .merge("minimum" => true, "live" => live, "live_spent" => live_spent)}
    end

    # The run timeout as it stands, only for a run whose definition declares one. `used` is machine time in
    # seconds (a gate, a parked resume and a held budget cost nothing); `limit` is the timeout plus `extra_seconds`;
    # `clock` is "active" once a heartbeat exists (downtime is cut from `used`), else "wall".
    def deadline_row(run)
      reading = WorkflowDeadline.reading(run.to_h, @clock.call, stops: stops)
      return {} unless reading
      {"deadline" => reading.slice("timeout", "action", "extra_seconds", "limit", "used", "spent")
        .merge("clock" => @downtime ? @downtime.clock_kind : "wall")}
    end

    # A step that reads running with no reason but is not moving: the sweep noted a stall on this attempt and
    # nothing has put it right (`code` `stalled`, `cause` the first cause, `since` its time), or its turn ended
    # unseen (`code` `idle`, `since` the turn's end, which the daemon must have given). Only for a running step
    # with no reason, no live park, no line still on its way and no hidden hold; a stall also only while the
    # pane is not working (a pane that can't be read leaves the stall standing). `actions` are a resume or a
    # cancel. Absent otherwise, and in runs stored before the sweep existed.
    def stuck_row(run, state, reason, shown, pane)
      return {} if reason || live_park?(run) || run.parked || state.state != "running"
      return {} if hidden_reason?(run.reason_for(run.current), shown) || WorkflowEngine.delivery(state.last_attempt&.to_h, @clock.call) == :delivering
      marks = WorkflowEngine.sweep_marks(run.to_h)
      recovered = marks["recovered"].is_a?(Hash) ? marks["recovered"] : {}
      open = marks["stalled"].is_a?(Hash) ? marks["stalled"].reject { |cause, _| recovered.key?(cause) } : {}
      cause, since = open.min_by { |_, time| time.to_s }
      if cause && !(shown && shown["state"] == "working")
        code = "stalled"
      elsif !cause && flags(run, state, reason, shown).include?("idle") && shown["main_turn_over_since"].is_a?(String)
        code = "idle"
        since = shown["main_turn_over_since"]
      else
        return {}
      end
      {"stuck" => {"code" => code, "cause" => cause, "since" => since.is_a?(String) ? since : nil,
                   "actions" => actions(run, {"code" => code, "details" => {}}, pane)}}
    end

    # The row's `infra_retry` for each state of {WorkflowTransitions.infra_retry}; an `:ended` mark shows nothing.
    INFRA_RETRY_STATES = {waiting: "scheduled", due: "scheduled", claimed: "restarting", stale_claim: "restarting", exhausted: "exhausted"}.freeze

    # Where the current attempt's automatic restart stands ({WorkflowTransitions.infra_retry}): `infra_retry` with `cause`,
    # `n` (this restart's number), `max`, `due` (ISO time or nil), `state` and `reason`. `state` is `scheduled` (waiting
    # or due, not yet claimed), `restarting` (claimed) or `exhausted` (given up; `reason` says why, `retries_spent` once
    # the restarts ran out). The value is nil for a finished run, a step that is not running, no mark, or an ended one
    # (its stall closed). It shows while the run is paused too, since a pause holds the restart. The stall's `code` stays `stalled`.
    def infra_retry_row(run, state, finished)
      info = (finished || state.state != "running") ? nil : WorkflowEngine.infra_retry(run.to_h, @clock.call)
      shown = info && INFRA_RETRY_STATES[info[:state]]
      {"infra_retry" => shown && {"cause" => info[:cause], "n" => info[:n], "max" => info[:max], "due" => info[:due], "state" => shown, "reason" => info[:reason]}}
    end

    # A running step whose pane shows an agent turn that ended on an API error: `turn_failed` with `since`, the
    # recovery `attempts` so far (nil with no recovery entry for the pane's session), `max_attempts` and `gave_up`.
    # The entry is trusted by {RecoveryEntry.trusted_for_failure}, the rule {WorkflowSweep} uses. Separate from `stuck`, which needs a sweep mark.
    def turn_failed_row(run, state, reason, shown, pane)
      return {} if reason || live_park?(run) || run.parked || state.state != "running"
      return {} unless shown.is_a?(Hash) && shown["turn_failed"]
      entry = @recovery_entry.call(run.workspace, shown["pane_id"] || pane)
      failed = RecoveryEntry.failed_turn(entry, shown)
      {"turn_failed" => {"since" => failed[:since], "attempts" => failed[:entry]&.dig("attempts"), "max_attempts" => AgentRecoveryStore::MAX_ATTEMPTS,
                         "gave_up" => failed[:gave_up]}}
    end

    # A continue line the pane refused as busy and a later tick will type again: `refusal` with `error`, `message`,
    # `reason` and `seen` as the attempt recorded them. Absent otherwise, and for runs stored before it was recorded.
    def refusal_row(run, state)
      refusal = state.last_attempt&.refusal
      (run.continue_pending_for(run.current) && refusal.is_a?(Hash)) ? {"refusal" => refusal} : {}
    end

    # The review round of a `reviewing` step, as `current.review` shows it (absent for any other step, and for a
    # reviewing step that stored no round): `round` and `max_rounds`, `need` and `must`, `approvals` and `pending`
    # (the reviewers with no verdict yet, from the verdict rows a stopped round read), `pane` and `window`, the
    # `delivery` mark, `started_at`, `stopped` (the round ended without deciding; a resume starts `next_round`),
    # `held` (the reason that kept a round from starting; `next_round` is then the round its release starts) and
    # `reviews`, each row with its `isolation`, and `refusal` (what a refused delivery saw; the key is absent otherwise).
    def review_row(run, state)
      round = state.review
      spec = review_spec(run)
      return {} unless state.state == "reviewing" && round.is_a?(Hash) && spec
      rows = Array(round["reviews"]).grep(Hash)
      decided = rows.select { |row| row["verdict"] }
      pending = rows.empty? ? Array(round["pending"] || spec["from"]) : spec["from"] - decided.map { |row| row["reviewer"] }
      # A resume of a stopped round starts the next one (of a round an unchanged revision stopped, that same round);
      # `rounds_spent` says that round is past the cap, so the engine refuses the resume (`review_rounds_spent`).
      next_round = if state.review_held? || round["no_change"] then round["round"]
      elsif state.review_stopped? then round["round"].to_i + 1
      end
      allowance = WorkflowTransitions.review_rounds_allowance(run.to_h, run.current)
      {"review" => {"round" => round["round"], "max_rounds" => allowance, "extra_rounds" => run.to_h.dig("steps", run.current, "extra_rounds").to_i, "need" => spec["need"], "must" => spec["must"],
                    "approvals" => decided.count { |row| row["verdict"] == "approve" }, "pending" => pending,
                    "pane" => round["pane"], "window" => round["window"], "delivery" => round["delivery"], "started_at" => round["started_at"],
                    "stopped" => state.review_stopped?, "held" => round["held"], "next_round" => next_round, "rerun" => (state.review_stopped? ? nil : round["rerun"]),
                    "rounds_spent" => !next_round.nil? && next_round > allowance,
                    "reviews" => rows.map { |row| REVIEW_ROW_KEYS.to_h { |key| [key, row[key]] } }}.merge((refusal = review_refusal(round)) ? {"refusal" => refusal} : {})}
    end

    # What a round whose delivery was refused as busy saw: `error`, `message`, `reason` and `seen`; nil for any other round.
    def review_refusal(round)
      failure = round["failure"]
      return nil if round["delivery"] != "failed" || !failure.is_a?(Hash) || !(failure["reason"] || failure["seen"])
      {"error" => failure["code"], "message" => failure["message"], "reason" => failure["reason"], "seen" => failure["seen"]}.compact
    end

    # The keys of a verdict row `current.review.reviews` shows, each null when the stored row lacks it.
    REVIEW_ROW_KEYS = %w[reviewer verdict revision counted problem isolation].freeze

    # The current step's `review:` settings from the run's stored definition; nil when it has none.
    def review_spec(run)
      WorkflowDefinition.review(run.definition["steps"].find { |step| step["id"] == run.current })
    end

    # The review pane of a round an agent should be working in; nil for any other run and step, and for a round
    # not delivered yet.
    def review_pane_of(run)
      round_live?(run) ? run.step(run.current).review["pane"] : nil
    end

    # Whether the current step is `reviewing` with a round under way and the run stores no reason ({WorkflowRun::Step#review_live?}),
    # or with a round whose delivery failed or lapsed after its line may have been typed into its review pane
    # ({WorkflowTransitions.typed_round?}): reviewers may be at work there, and a prompt in it waits for a person.
    def round_live?(run)
      return false unless run.reason_for(run.current).nil?
      step = run.step(run.current)
      return false unless step
      step.review_live? || typed_round_live?(step)
    end

    def typed_round_live?(step)
      round = step.review
      step.state == "reviewing" && round.is_a?(Hash) && round["pane"].is_a?(String) && !step.review_held? && !step.review_stopped? &&
        WorkflowTransitions.typed_round?(round, @clock.call)
    end

    # A live park, as `current` shows it; never its note.
    def parked_row(run, pane)
      return {} unless live_park?(run)
      {"parked" => run.parked.slice("from", "requested_at", "expires_at").merge("pane" => pane)}
    end

    def live_park?(run)
      WorkflowEngine.parked(run.to_h, @clock.call) == :waiting
    end

    # The stored state, except that a hidden turn_ended_incomplete leaves the run running.
    def shown_state(run, reason, shown)
      return "waiting" if reason && run.state == "running"
      return "running" if reason.nil? && hidden_reason?(run.reason_for(run.current), shown)
      run.state
    end

    # An approved gate's note file, as recorded, and whether its bytes changed since; `gate_note` is the text the person
    # gave to approve or reject (null when none, and for a run stored before it was shown).
    # A step that was ever reviewed adds `review_rounds`, the rounds it has spent.
    def step_row(step, state, run, group_states: {}, live: {})
      file = state.gate&.dig("file")
      {"id" => step["id"], "title" => step["title"], "state" => state.state, "attempts" => state.attempts.size,
       "gate" => state.gate&.dig("state"), "gate_note" => state.gate&.dig("note"), "gate_file" => file,
       "note_changed" => file ? WorkflowGateNote.sha256(file["path"]) != file["sha256"] : false}
        .merge(state.review_rounds ? {"review_rounds" => state.review_rounds} : {})
        .merge(step["group"] ? group_member_row(step, run, group_states, live[step["id"]]) : {})
    end

    # What a member of a fan_out group adds to its entry in `steps`: `group`, `group_state` ({#group_state}) and
    # `looping` (a deferred failure move or a relay run is owed it), and, while the sibling is under way, what
    # `current` shows of a step (`attempt`, `reason`, `flags`, and the optional keys), so each sibling reads on its own.
    def group_member_row(step, run, group_states, view)
      hash = run.to_h
      id = step["id"]
      looping = WorkflowRun.slot(hash, id, "pending_move").is_a?(Hash) || WorkflowTransitions.relay_owed?(hash, id)
      {"group" => step["group"], "group_state" => group_states[step["group"]], "looping" => looping}
        .merge(view ? view[:current].except("step", "state") : {})
    end

    # A waiting gate's reason names the note to read, hashed now; null when the gate names
    # none, and null with a warning (and `gate_file_error` `gate_note_unreadable`) when the note can't be read.
    def with_gate_file(run, reason, warnings)
      return reason unless reason["code"] == "waiting_you" && reason.dig("details", "kind") == "gate"
      error = nil
      file = begin
        @gate_note.find(run.to_h)
      rescue Workspace::Error => e
        raise unless e.code == "gate_note_unreadable"
        warnings << e.message
        error = e.code
        nil
      end
      reason.merge("details" => reason["details"].merge("gate_file" => file, "gate_file_error" => error))
    end

    # Nothing moves a run whose workspace has no agent daemon: no turn's end
    # is seen and no lock is asked for again, while it keeps what it holds.
    def daemon_warning(run, working, warnings)
      # A run that waits for a person needs no daemon until that person acts.
      return unless working || run.parked || %w[waiting_lock retry_backoff].include?(run.reason_for(run.current)&.dig("code"))
      return if @panes.daemon_running?(run.workspace)
      warnings << "Workflow run #{run.id} will not move: '#{run.workspace}' has no agent daemon running. It keeps the locks it holds " \
        "and its place in a queue. Launch the workspace and run `workspace workflow resume #{run.id}`, or end it with " \
        "`workspace workflow cancel #{run.id}`."
    end

    # The stored reason stands unless an agent should be working: then what
    # the pane shows comes first. A parked run hides it: the resume needs it,
    # and nobody has to act on it.
    def reason_for(run, working, pane, shown, warnings, review_pane: nil)
      return paused_reason(run) if run.paused
      case WorkflowEngine.parked(run.to_h, @clock.call)
      when :waiting then return waiting_on_person(run, pane, shown, warnings)
      when :expired then return gate_waiting?(run) ? run.reason_for(run.current) : park_timeout(run, pane)
      end
      stored = run.reason_for(run.current)
      # A live round has no stored reason (`round_live?`), so there is nothing to fall back to when the pane shows nothing.
      return review_prompt(run, review_pane, shown, warnings) if review_pane
      return stored unless working
      unless @panes.alive?(run.id)
        return {"code" => "pane_gone", "since" => stored&.fetch("since", nil) || run.steps.fetch(run.current).last_attempt&.started_at,
                "details" => {"step" => run.current, "pane" => pane, "workspace" => run.workspace}}
      end
      waiting_on_person(run, pane, shown, warnings) || lost_delivery(run, pane, shown) || hide_while_working(stored, shown)
    end

    # A pause comes before every other reason, a gate's `waiting_you` too; what it holds back shows as `details.held`.
    def paused_reason(run)
      pause = run.paused
      held = run.reason_for(run.current)
      {"code" => "paused", "since" => pause["since"], "by" => pause["by"], "text" => pause["text"]}.compact
        .merge(held ? {"details" => {"held" => held}} : {})
    end

    # The attempt's reported status (see {WorkflowReportedStatus}), only when it carries one.
    def status_report_row(state)
      report = WorkflowReportedStatus.shown(state.last_attempt&.status_report)
      report ? {"status_report" => report} : {}
    end

    # The current attempt's `require:` proofs that ran outside the run's lock, with their results and logs.
    def proofs_row(state)
      proofs = state.last_attempt&.proofs
      proofs ? {"proofs" => proofs} : {}
    end

    def gate_waiting?(run)
      run.step(run.current)&.gate_waiting? || false
    end

    # Worked out here, so a timeout shows even with no daemon to record it.
    def park_timeout(run, pane)
      checking = run.steps.fetch(run.current).state == "checking"
      {"code" => "waiting_you", "since" => run.parked["expires_at"],
       "details" => {"kind" => "dispatch", "step" => run.current, "pane" => pane, "workspace" => run.workspace, "error" => "parked_timeout",
                     "message" => WorkflowEngine.park_timeout_message(pane, checking: checking)}}
    end

    # A turn that ended with background tasks listed is held (turn_ended_background) and hidden. One that
    # ended while a sub-agent ran unlisted reads turn_ended_incomplete; once the pane is working again
    # the agent is still on it, so nobody has to act.
    def hide_while_working(stored, shown)
      hidden_reason?(stored, shown) ? nil : stored
    end

    # A held turn (background tasks listed) is hidden whatever the pane reads; an incomplete one while the pane works
    # and for its first INCOMPLETE_GRACE seconds.
    def hidden_reason?(stored, shown)
      return false unless stored
      return true if stored["code"] == "turn_ended_background"
      return false unless stored["code"] == "turn_ended_incomplete"
      (!!shown && shown["state"] == "working") || within_incomplete_grace?(stored["since"])
    end

    # A since that does not parse counts as old.
    def within_incomplete_grace?(since)
      !since.nil? && @clock.call - Time.iso8601(since) < INCOMPLETE_GRACE
    rescue ArgumentError
      false
    end

    def lost_delivery(run, pane, shown)
      attempt = run.steps.fetch(run.current).last_attempt&.to_h
      return nil unless WorkflowEngine.delivery(attempt, @clock.call) == :unknown && WorkflowPanes.turn_over?(shown, @clock.call)
      {"code" => "waiting_you", "since" => attempt["started_at"],
       "details" => {"kind" => "delivery", "step" => run.current, "attempt" => attempt["n"], "pane" => pane, "workspace" => run.workspace}}
    end

    # What a live round's review pane shows: a permission prompt, or an open question asked from that pane, holds the
    # run (`details.role` `reviewer`). Nothing else is shown; the round's own turn end decides it.
    def review_prompt(run, review_pane, shown, warnings)
      reason = waiting_on_person(run, review_pane, shown, warnings)
      reason&.merge("details" => reason["details"].merge("role" => "reviewer"))
    end

    def waiting_on_person(run, pane, shown, warnings)
      if shown && shown["state"] == "waiting"
        return {"code" => "waiting_you", "since" => shown["waiting_since"],
                "details" => {"kind" => "prompt", "step" => run.current, "pane" => pane, "message" => shown["waiting_message"]}}
      end
      # Only a question asked from the run's pane: another pane's question does not hold this run.
      ask = open_asks(run.workspace, warnings).find { |each| each["pane"] == pane }
      return nil unless ask
      {"code" => "waiting_you", "since" => ask["asked_at"],
       "details" => {"kind" => "ask", "step" => run.current, "ask" => ask["id"], "question" => ask["question"]}}
    end

    def pane_state(workspace, pane, warnings)
      snapshot = snapshot_for(workspace)
      Array(snapshot["panes"]).find { |each| each["pane_id"] == pane }
    rescue Workspace::Error
      warnings << "The agent daemon for '#{workspace}' did not answer, so a permission prompt in its panes would not show here."
      nil
    end

    # The daemon's snapshot of a workspace; while a list is built, the one read ahead (an error raised again).
    def snapshot_for(workspace)
      cached = @snapshots && @snapshots[workspace]
      return @snapshot_client.fetch(workspace, timeout: @snapshot_timeout) unless cached
      raise cached.last if cached.first == :error
      cached.last
    end

    # A question store that can't be read costs the `ask` reason, never the document.
    def open_asks(workspace, warnings)
      @ask_store_for.call(workspace).list(open_only: true)
    rescue Workspace::Error
      []
    rescue EncodingError, ArgumentError
      warnings << "The questions of '#{workspace}' could not be read (the file is not UTF-8 text), so an open question would not show here."
      []
    end

    def flags(run, state, reason, shown)
      flags = []
      timeout = run.definition["steps"].find { |step| step["id"] == run.current }["timeout"]
      started = state.last_attempt&.started_at
      # A reviewing step's attempt has ended, so the step timeout no longer runs.
      if timeout && started && !run.paused && %w[running checking].include?(state.state)
        # A start that is not a time makes the run malformed, as before; the clock itself is the sweep's.
        Time.iso8601(started)
        elapsed = WorkflowTransitions.step_elapsed(run.to_h, state.last_attempt&.to_h, @clock.call, stops: stops)
        flags << "timed_out" if elapsed && elapsed > timeout
      end
      flags << "timed_out" if round_timed_out?(run, state) && !run.paused
      flags << "delivering" if round_live?(run) && WorkflowTransitions.round_delivery(state.review, @clock.call) == :delivering
      delivering = WorkflowEngine.delivery(state.last_attempt&.to_h, @clock.call) == :delivering
      flags << "delivering" if delivering
      flags << "parked" if live_park?(run)
      flags << "paused" if run.paused
      # The agent is idle on a step that still reads as being worked on: its turn ended unseen.
      if state.state == "running" && reason.nil? && !delivering && !hidden_reason?(run.reason_for(run.current), shown) && WorkflowPanes.turn_over?(shown, @clock.call) && !within_idle_grace?(started)
        flags << "idle"
      end
      flags << "background_work" if run.reason_for(run.current)&.dig("code") == "turn_ended_background"
      flags
    end

    # A live review round past its `review.timeout`, counted from the round's start ({WorkflowTransitions.round_timed_out?},
    # the reading the sweep's interrupt takes).
    def round_timed_out?(run, state)
      round_live?(run) && WorkflowTransitions.round_timed_out?(run.to_h, state.review, @clock.call, stops: stops)
    end

    # A pane reads idle for a moment right after a dispatch, before the agent takes the prompt.
    def within_idle_grace?(started)
      !started.nil? && @clock.call - Time.iso8601(started) < IDLE_GRACE
    rescue ArgumentError
      false
    end

    # The reason as shown: its actions, and for a guard stop a resume can pass, what to put back first.
    def shown_reason(run, reason, pane)
      return nil unless reason
      shown = reason.merge("actions" => actions(run, reason, pane))
      hint = WorkflowTransitions.guard_recovery(run)
      hint ? shown.merge("recovery" => hint) : shown
    end

    def actions(run, reason, pane)
      build_actions(run, reason, pane).compact
    end

    # A `focus` needs a pane to name: with none it is left out.
    def build_actions(run, reason, pane)
      id = run.id
      cancel = NextAction.build("workflow cancel", id)
      # An action that starts an attempt is refused once the budget is spent, so it needs --extra-attempts (at
      # least "min"). A plain resume starts one only for some steps; with a named pane (a gone pane) for more.
      # "min" is the larger of the run's shortfall and the shortfall of the step the action would start an attempt of.
      limits = -> { limit_needs(run) }
      extra = lambda do |target|
        shortfalls = []
        shortfalls << WorkflowEngine.extra_attempts_needed(run.to_h) if WorkflowEngine.attempts_spent?(run.to_h)
        shortfalls << WorkflowTransitions.step_extra_attempts_needed(run.to_h, target) if WorkflowTransitions.step_attempts_spent?(run.to_h, target)
        (shortfalls.empty? ? [] : [NextAction.need("extra_attempts", "--extra-attempts", "min" => shortfalls.max)]) + limits.call
      end
      here = WorkflowTransitions.target_step(run.to_h)
      # A review round is not an attempt: a resume that starts one needs only the token and time limits.
      round = WorkflowTransitions.starts_round?(run.to_h, from: nil) ? limits.call : []
      plain = WorkflowEngine.starts_attempt?(run.to_h, from: nil, pane: nil) ? extra.call(here) : round
      with_pane = WorkflowEngine.starts_attempt?(run.to_h, from: nil, pane: "%0") ? extra.call(here) : round
      resume = NextAction.build("workflow resume", id, needs: plain)
      from = ->(step) { NextAction.build("workflow resume", id, "--from", step.to_s, needs: extra.call(step.to_s)) }
      focus = NextAction.build("focus", run.workspace, "--pane", pane) if pane
      restart = NextAction.build("workflow resume", id, "--restart-step", needs: extra.call(here)) if self.class.restartable?(run.to_h, now: @clock.call)
      return [NextAction.build("workflow unpause", id), cancel] if reason["code"] == "paused"
      # A held retry would block again on the same pane: the resume has to name another one.
      return [NextAction.build("workflow resume", id, needs: [NextAction.need("pane", "--pane")] + extra.call(here)), cancel] if run.backoff_for(run.current)&.dig("blocked") && run.state == "waiting"
      case reason["code"]
      when "waiting_lock"
        holder = reason.dig("details", "holder") || {}
        resource = reason.dig("details", "resource")
        [(NextAction.build("workflow status", holder["run_id"]) if holder["run_id"]),
          (NextAction.build("dev down", "--name", run.workspace) if holder["kind"] == "process"),
          (NextAction.build("lock status", resource, "--name", run.workspace) if resource.is_a?(String) && resource.match?(/\A[A-Za-z0-9][\w.-]*\z/)), cancel].compact
      when "waiting_you"
        case reason.dig("details", "kind")
        when "gate"
          at = ["--step", run.current, "--attempt", run.steps.fetch(run.current).last_attempt&.n.to_s]
          [NextAction.build("workflow approve", id, *at), NextAction.build("workflow reject", id, *at, needs: [NextAction.need("note", "--note")] + extra.call(run.current)), cancel]
        when "ask" then [NextAction.build("ask answer", reason.dig("details", "ask").to_s, "--name", run.workspace, needs: [NextAction.need("answer", nil)]), focus]
        when "prompt" then [focus]
        # Resume decides the step as a turn's end would; --from types the line again.
        when "delivery" then [focus, resume, from.call(reason.dig("details", "step")), cancel]
        else [resume, cancel]
        end
      when "turn_ended_incomplete", "waiting_agent_input" then [focus, resume, cancel]
      # A resume skips the wait and starts the retry now.
      when "retry_backoff" then [resume, cancel]
      when "budget_spent", "run_timed_out" then [resume, cancel]
      when "failed_check"
        # Only a no_commit with no base_sha can never pass; any other guard stop resumes once the checkout is put back.
        # A guard stop `resume --accept-guard` takes can also be accepted as it is, or accepted and the step run again
        # from a new baseline; the person writes the note (a `note` need, passed with `--note`).
        accept = WorkflowTransitions.guard_acceptable?(run) ? [NextAction.build("workflow resume", id, "--accept-guard", needs: [NextAction.need("note", "--note")]),
          NextAction.build("workflow resume", id, "--accept-guard", "--retry", needs: [NextAction.need("note", "--note")] + extra.call(here))] : []
        if WorkflowTransitions.guard_unrecoverable?(run)
          [cancel] + accept
        else
          [resume, from.call(reason.dig("details", "step"))] + accept + [cancel]
        end
      when "stalled", "idle" then [resume, restart, cancel]
      # A stopped round: a resume starts a fresh round (after a rejection stopped by an attempt limit, a new attempt);
      # `--from` runs the step again. With every round spent a resume needs `--extra-rounds` (`review_rounds_spent` without it).
      when *WorkflowTransitions::REVIEW_STOPS
        step = reason.dig("details", "step") || run.current
        # The resume then needs --extra-rounds, at least what lets one more round start.
        spent = WorkflowTransitions.rounds_refuse_resume?(run.to_h)
        rounds = NextAction.need("extra_rounds", "--extra-rounds", "min" => WorkflowTransitions.review_extra_rounds_needed(run.to_h, step)) if spent
        [(spent ? NextAction.build("workflow resume", id, needs: [rounds] + plain) : resume), from.call(step), cancel]
      when "pane_gone" then [NextAction.build("launch", run.workspace), NextAction.build("workflow resume", id, needs: with_pane), restart, cancel]
      else [cancel]
      end
    end
  end
end
