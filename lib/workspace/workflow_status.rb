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

    # The guard codes a resume can't get past.
    FINAL_GUARDS = %w[no_commit head_moved hooks_changed hidden_changed].freeze

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
    def initialize(store:, panes:, snapshot_client:, ask_store_for:, gate_note:, clock: -> { Time.now }, snapshot_timeout: SNAPSHOT_TIMEOUT, list_grace: LIST_GRACE)
      @snapshot_timeout = snapshot_timeout
      @list_grace = list_grace
      @store = store
      @gate_note = gate_note
      @panes = panes
      @snapshot_client = snapshot_client
      @ask_store_for = ask_store_for
      @clock = clock
    end

    # @param workspace [String, nil] only this workspace's runs
    # @param all [Boolean] finished runs too, after the ones still going
    # @return [Hash] "runs" (see {#run}) and "warnings" (strings): a run file that can't
    #   be read or shown is left out of "runs" and named in a warning
    def runs(workspace: nil, all: false)
      stored = @store.active + (all ? @store.archived : [])
      stored = stored.select { |run| run["workspace"] == workspace } if workspace
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
      stored = (@store.active + @store.archived).select { |run| in_project?(run, project) }
      present_all(stored)
    end

    # Whether a stored run belongs to a project, by the rules {#in_project} lists.
    #
    # @param run [Hash] a stored run
    # @param project [#name, #members] a {Workspace::ProjectCatalog::Project}
    # @return [Boolean]
    def in_project?(run, project)
      project.members.filter_map(&:workspace).include?(run["workspace"]) || run["project"] == project.name ||
        WorkspaceName.split(run["workspace"])&.first == project.name
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
      {"runs" => [present(@store.find(id), warnings)], "warnings" => warnings}
    end

    private

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
      shown = stored.filter_map do |run|
        present(run, warnings)
      rescue KeyError, NoMethodError, TypeError, ArgumentError
        malformed += 1
        warnings << "Workflow run #{run["id"]} can't be shown: its run file is malformed. What it holds stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file."
        nil
      end
      @snapshots = nil
      {"runs" => shown, "warnings" => warnings.uniq, "unreadable" => paths.size + malformed}
    end

    # Seconds all the daemon reads of one list share, past SNAPSHOT_TIMEOUT.
    LIST_GRACE = 0.25

    # Each workspace with a run whose pane will be looked at, read in its own thread; a daemon that has not
    # answered by the shared deadline reads as an error, as a refused connection would.
    def prefetch_snapshots(stored)
      names = stored.filter_map do |run|
        next if WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
        run["workspace"] if run["parked"] || %w[running checking].include?(run.dig("steps", run["current"], "state"))
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

    def present(run, warnings)
      state = run["steps"].fetch(run["current"])
      finished = WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
      pane = finished ? nil : (run.dig("parked", "pane") || @panes.pane_of(run["id"]) || run["pane"])
      working = !finished && %w[running checking].include?(state["state"])
      daemon_warning(run, working, warnings) unless finished
      # What the pane shows matters only while an agent should be working in it, or a parked resume waits on
      # it; a run parked before its first step has no binding for `alive?` to find.
      shown = ((working && @panes.alive?(run["id"])) || (!finished && run["parked"])) ? pane_state(run["workspace"], pane, warnings) : nil
      reason = finished ? nil : reason_for(run, working, pane, shown, warnings)
      reason = with_gate_file(run, reason, warnings) if reason
      {
        "id" => run["id"], "workflow" => run["workflow"], "title" => run["title"], "workspace" => run["workspace"],
        "project" => run["project"], "worktree" => run["worktree"], "state" => shown_state(run, reason, shown),
        "created_at" => run["created_at"], "started_at" => run["started_at"], "ended_at" => run["ended_at"],
        "cancelled_by" => run["cancelled_by"],
        "current" => {"step" => run["current"], "attempt" => state["attempts"].last&.fetch("n", nil), "state" => state["state"],
                      "reason" => reason&.merge("actions" => actions(run, reason, pane)),
                      "flags" => finished ? [] : flags(run, state, reason, shown)}.merge(parked_row(run, pane)).merge(proofs_row(state))
            .merge(finished ? {} : stuck_row(run, state, reason, shown, pane)),
        "steps" => run["definition"]["steps"].map { |step| step_row(step, run["steps"].fetch(step["id"]), run) },
        "base_sha" => run["base_sha"], "pane" => pane, "task" => run["task"], "inputs" => run["inputs"], "loops" => run["loops"],
        "artifacts_dir" => run["artifacts_dir"], "events_path" => @store.events_path(run["id"]),
        "guard_warnings" => guard_warnings(run)
      }.merge(budget_row(run))
    end

    # What the guard warned of on any attempt, oldest first; the run went on past each.
    def guard_warnings(run)
      run["steps"].flat_map do |id, state|
        state["attempts"].flat_map do |attempt|
          Array(attempt["warnings"]).map { |each| each.merge("step" => id, "attempt" => attempt["n"]) }
        end
      end.sort_by { |each| each["at"].to_s }
    end

    # The token budget as it stands, only for a run whose definition declares one. `used` is a minimum: it leaves
    # out sub-agents and any ended attempt whose `usage` is null (`uncounted`), and `minimum` says so.
    def budget_row(run)
      reading = WorkflowBudget.reading(run)
      return {} unless reading
      {"budget" => reading.slice("tokens", "action", "extra_tokens", "allowance", "used", "counted", "uncounted", "measured", "spent")
        .merge("minimum" => true)}
    end

    # A step that reads running with no reason but is not moving: the sweep noted a stall on this attempt and
    # nothing has put it right (`code` `stalled`, `cause` the first cause, `since` its time), or its turn ended
    # unseen (`code` `idle`, `since` the turn's end, which the daemon must have given). Only for a running step
    # with no reason, no live park, no line still on its way and no hidden hold; a stall also only while the
    # pane is not working (a pane that can't be read leaves the stall standing). `actions` are a resume or a
    # cancel. Absent otherwise, and in runs stored before the sweep existed.
    def stuck_row(run, state, reason, shown, pane)
      return {} if reason || live_park?(run) || run["parked"] || state["state"] != "running"
      return {} if hidden_reason?(run["reason"], shown) || WorkflowEngine.delivery(state["attempts"].last, @clock.call) == :delivering
      marks = WorkflowEngine.sweep_marks(run)
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

    # A live park, as `current` shows it; never its note.
    def parked_row(run, pane)
      return {} unless live_park?(run)
      {"parked" => run["parked"].slice("from", "requested_at", "expires_at").merge("pane" => pane)}
    end

    def live_park?(run)
      WorkflowEngine.parked(run, @clock.call) == :waiting
    end

    # The stored state, except that a hidden turn_ended_incomplete leaves the run running.
    def shown_state(run, reason, shown)
      return "waiting" if reason && run["state"] == "running"
      return "running" if reason.nil? && hidden_reason?(run["reason"], shown)
      run["state"]
    end

    # An approved gate's note file, as recorded, and whether its bytes changed since; `gate_note` is the text the person
    # gave to approve or reject (null when none, and for a run stored before it was shown).
    def step_row(step, state, run)
      file = state.dig("gate", "file")
      {"id" => step["id"], "title" => step["title"], "state" => state["state"], "attempts" => state["attempts"].size,
       "gate" => state.dig("gate", "state"), "gate_note" => state.dig("gate", "note"), "gate_file" => file,
       "note_changed" => file ? WorkflowGateNote.sha256(file["path"]) != file["sha256"] : false}
    end

    # A waiting gate's reason names the note to read, hashed now; null when the gate names
    # none, and null with a warning (and `gate_file_error` `gate_note_unreadable`) when the note can't be read.
    def with_gate_file(run, reason, warnings)
      return reason unless reason["code"] == "waiting_you" && reason.dig("details", "kind") == "gate"
      error = nil
      file = begin
        @gate_note.find(run)
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
      return unless working || run["parked"] || %w[waiting_lock retry_backoff].include?(run.dig("reason", "code"))
      return if @panes.daemon_running?(run["workspace"])
      warnings << "Workflow run #{run["id"]} will not move: '#{run["workspace"]}' has no agent daemon running. It keeps the locks it holds " \
        "and its place in a queue. Launch the workspace and run `workspace workflow resume #{run["id"]}`, or end it with " \
        "`workspace workflow cancel #{run["id"]}`."
    end

    # The stored reason stands unless an agent should be working: then what
    # the pane shows comes first. A parked run hides it: the resume needs it,
    # and nobody has to act on it.
    def reason_for(run, working, pane, shown, warnings)
      case WorkflowEngine.parked(run, @clock.call)
      when :waiting then return waiting_on_person(run, pane, shown, warnings)
      when :expired then return gate_waiting?(run) ? run["reason"] : park_timeout(run, pane)
      end
      stored = run["reason"]
      return stored unless working
      unless @panes.alive?(run["id"])
        return {"code" => "pane_gone", "since" => stored&.fetch("since", nil) || run["steps"].fetch(run["current"])["attempts"].last&.fetch("started_at", nil),
                "details" => {"step" => run["current"], "pane" => pane, "workspace" => run["workspace"]}}
      end
      waiting_on_person(run, pane, shown, warnings) || lost_delivery(run, pane, shown) || hide_while_working(stored, shown)
    end

    # The current attempt's `require:` proofs that ran outside the run's lock, with their results and logs.
    def proofs_row(state)
      proofs = state["attempts"].last&.fetch("proofs", nil)
      proofs ? {"proofs" => proofs} : {}
    end

    def gate_waiting?(run)
      run.dig("steps", run["current"], "gate", "state") == "waiting"
    end

    # Worked out here, so a timeout shows even with no daemon to record it.
    def park_timeout(run, pane)
      checking = run["steps"].fetch(run["current"])["state"] == "checking"
      {"code" => "waiting_you", "since" => run["parked"]["expires_at"],
       "details" => {"kind" => "dispatch", "step" => run["current"], "pane" => pane, "workspace" => run["workspace"], "error" => "parked_timeout",
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
      attempt = run["steps"].fetch(run["current"])["attempts"].last
      return nil unless WorkflowEngine.delivery(attempt, @clock.call) == :unknown && WorkflowPanes.turn_over?(shown, @clock.call)
      {"code" => "waiting_you", "since" => attempt["started_at"],
       "details" => {"kind" => "delivery", "step" => run["current"], "attempt" => attempt["n"], "pane" => pane, "workspace" => run["workspace"]}}
    end

    def waiting_on_person(run, pane, shown, warnings)
      if shown && shown["state"] == "waiting"
        return {"code" => "waiting_you", "since" => shown["waiting_since"],
                "details" => {"kind" => "prompt", "step" => run["current"], "pane" => pane, "message" => shown["waiting_message"]}}
      end
      # Only a question asked from the run's pane: another pane's question does not hold this run.
      ask = open_asks(run["workspace"], warnings).find { |each| each["pane"] == pane }
      return nil unless ask
      {"code" => "waiting_you", "since" => ask["asked_at"],
       "details" => {"kind" => "ask", "step" => run["current"], "ask" => ask["id"], "question" => ask["question"]}}
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
      timeout = run["definition"]["steps"].find { |step| step["id"] == run["current"] }["timeout"]
      started = state["attempts"].last&.fetch("started_at", nil)
      if timeout && started && %w[running checking].include?(state["state"]) && @clock.call - Time.iso8601(started) > timeout
        flags << "timed_out"
      end
      delivering = WorkflowEngine.delivery(state["attempts"].last, @clock.call) == :delivering
      flags << "delivering" if delivering
      flags << "parked" if live_park?(run)
      # The agent is idle on a step that still reads as being worked on: its turn ended unseen.
      if state["state"] == "running" && reason.nil? && !delivering && !hidden_reason?(run["reason"], shown) && WorkflowPanes.turn_over?(shown, @clock.call) && !within_idle_grace?(started)
        flags << "idle"
      end
      flags << "background_work" if run.dig("reason", "code") == "turn_ended_background"
      flags
    end

    # A pane reads idle for a moment right after a dispatch, before the agent takes the prompt.
    def within_idle_grace?(started)
      !started.nil? && @clock.call - Time.iso8601(started) < IDLE_GRACE
    rescue ArgumentError
      false
    end

    def actions(run, reason, pane)
      build_actions(run, reason, pane).compact
    end

    # A `focus` needs a pane to name: with none it is left out.
    def build_actions(run, reason, pane)
      id = run["id"]
      cancel = action("workflow cancel", id)
      # An action that starts an attempt is refused once the budget is spent, so it needs --extra-attempts (at
      # least "min"). A plain resume starts one only for some steps; with a named pane (a gone pane) for more.
      spent = WorkflowEngine.attempts_spent?(run)
      extra = spent ? [need("extra_attempts", "--extra-attempts").merge("min" => WorkflowEngine.extra_attempts_needed(run))] : []
      budget = WorkflowBudget.reading(run)
      extra += [need("extra_tokens", "--extra-tokens").merge("min" => budget["needed"], "suggested" => budget["suggested"])] if budget && budget["spent"]
      plain = WorkflowEngine.starts_attempt?(run, from: nil, pane: nil) ? extra : []
      with_pane = WorkflowEngine.starts_attempt?(run, from: nil, pane: "%0") ? extra : []
      resume = action("workflow resume", id, needs: plain)
      from = ->(step) { action("workflow resume", id, "--from", step.to_s, needs: extra) }
      focus = action("focus", run["workspace"], "--pane", pane) if pane
      # A held retry would block again on the same pane: the resume has to name another one.
      return [action("workflow resume", id, needs: [need("pane", "--pane")] + extra), cancel] if run.dig("backoff", "blocked") && run["state"] == "waiting"
      case reason["code"]
      when "waiting_lock"
        holder = reason.dig("details", "holder") || {}
        resource = reason.dig("details", "resource")
        [(action("workflow status", holder["run_id"]) if holder["run_id"]),
          (action("dev down", "--name", run["workspace"]) if holder["kind"] == "process"),
          (action("lock status", resource, "--name", run["workspace"]) if resource.is_a?(String) && resource.match?(/\A[A-Za-z0-9][\w.-]*\z/)), cancel].compact
      when "waiting_you"
        case reason.dig("details", "kind")
        when "gate"
          at = ["--step", run["current"], "--attempt", run["steps"].fetch(run["current"])["attempts"].last&.fetch("n", nil).to_s]
          [action("workflow approve", id, *at), action("workflow reject", id, *at, needs: [need("note", "--note")] + extra), cancel]
        when "ask" then [action("ask answer", reason.dig("details", "ask").to_s, "--name", run["workspace"], needs: [need("answer", nil)]), focus]
        when "prompt" then [focus]
        # Resume decides the step as a turn's end would; --from types the line again.
        when "delivery" then [focus, resume, from.call(reason.dig("details", "step")), cancel]
        else [resume, cancel]
        end
      when "turn_ended_incomplete" then [focus, resume, cancel]
      # A resume skips the wait and starts the retry now.
      when "retry_backoff" then [resume, cancel]
      when "budget_spent" then [resume, cancel]
      when "failed_check"
        # A moved HEAD or changed hooks can't pass again, and base_sha is never re-recorded: only a new run goes on.
        if reason.dig("details", "cause") == "guard" && FINAL_GUARDS.include?(reason.dig("details", "guard"))
          [cancel]
        else
          [resume, from.call(reason.dig("details", "step")), cancel]
        end
      when "stalled", "idle" then [resume, cancel]
      when "pane_gone" then [action("launch", run["workspace"]), action("workflow resume", id, needs: with_pane), cancel]
      else [cancel]
      end
    end

    def action(name, *args, needs: [])
      {"action" => name, "args" => args, "needs" => needs}
    end

    def need(name, flag)
      {"name" => name, "flag" => flag}
    end
  end
end
