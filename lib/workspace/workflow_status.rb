require "time"

module Workspace
  # What `workflow status` shows for a run: its stored state, plus the two
  # things only a look outside the run file can tell. A step an agent should
  # be working on is `pane_gone` when its pane isn't there, and `waiting_you`
  # when the pane shows a permission prompt or the workspace has an open
  # `workspace ask` question from that pane. A step past its `timeout:` gets
  # the flag `timed_out`; nothing is stopped for it. A step that reads
  # `running` with no reason while its pane's agent is idle gets the flag
  # `idle`: its turn ended unseen, and `workflow resume` decides it.
  #
  # Every reason carries `actions`, the commands that would resolve it, as
  # `{action, args, needs}` entries. With `needs` empty, `workspace <action>
  # <args...>` runs as written. Otherwise the caller supplies one value per
  # entry of `needs` (`name`, `flag`) and appends it after `args`: the flag
  # then the value, or `--` then the value when `flag` is null. No
  # placeholder is ever in `args`.
  class WorkflowStatus
    # Seconds to wait for the workspace's agent daemon before going on without it.
    SNAPSHOT_TIMEOUT = 1.0

    # @param store [Workspace::WorkflowRunStore]
    # @param panes [Workspace::WorkflowPanes] says whether a run's pane is still there
    # @param snapshot_client [Workspace::AgentSnapshotClient] reads each pane's state from the daemon
    # @param ask_store_for [#call] returns the {Workspace::AskStore} of a workspace
    # @param clock [#call] returns the current Time
    def initialize(store:, panes:, snapshot_client:, ask_store_for:, clock: -> { Time.now })
      @store = store
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
      warnings = @store.unreadable.map do |path|
        "The run file #{path} can't be read, so its run is not shown. What it held stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file."
      end
      stored = @store.active + (all ? @store.archived : [])
      stored = stored.select { |run| run["workspace"] == workspace } if workspace
      shown = stored.filter_map do |run|
        present(run, warnings)
      rescue KeyError, NoMethodError, TypeError, ArgumentError
        warnings << "Workflow run #{run["id"]} can't be shown: its run file is malformed. What it holds stays held: " \
          "free a lock with `workspace lock clear NAME`, or delete the file."
        nil
      end
      {"runs" => shown, "warnings" => warnings.uniq}
    end

    # @param id [String] a run id
    # @return [Hash] "runs", holding the one run as "id", "workflow", "title", "workspace",
    #   "project", "state", "created_at", "started_at", "ended_at", "current" ("step",
    #   "attempt", "state", "reason", "flags"), "steps" ("id", "title", "state", "attempts",
    #   "gate"), "pane", "task", "inputs", "loops", "artifacts_dir" and "events_path";
    #   and "warnings"
    # @raise [Workspace::Error] code `unknown_run`
    def run(id)
      warnings = []
      {"runs" => [present(@store.find(id), warnings)], "warnings" => warnings}
    end

    private

    def present(run, warnings)
      state = run["steps"].fetch(run["current"])
      finished = WorkflowRunStore::TERMINAL_STATES.include?(run["state"])
      pane = finished ? nil : (@panes.pane_of(run["id"]) || run["pane"])
      working = !finished && %w[running checking].include?(state["state"])
      daemon_warning(run, working, warnings) unless finished
      # What the pane shows matters only while an agent should be working in it.
      shown = (working && @panes.alive?(run["id"])) ? pane_state(run["workspace"], pane, warnings) : nil
      reason = finished ? nil : reason_for(run, working, pane, shown, warnings)
      {
        "id" => run["id"], "workflow" => run["workflow"], "title" => run["title"], "workspace" => run["workspace"],
        "project" => run["project"], "state" => (reason && run["state"] == "running") ? "waiting" : run["state"],
        "created_at" => run["created_at"], "started_at" => run["started_at"], "ended_at" => run["ended_at"],
        "cancelled_by" => run["cancelled_by"],
        "current" => {"step" => run["current"], "attempt" => state["attempts"].last&.fetch("n", nil), "state" => state["state"],
                      "reason" => reason&.merge("actions" => actions(run, reason, pane)),
                      "flags" => finished ? [] : flags(run, state, reason, shown)},
        "steps" => run["definition"]["steps"].map { |step| step_row(step, run["steps"].fetch(step["id"])) },
        "pane" => pane, "task" => run["task"], "inputs" => run["inputs"], "loops" => run["loops"],
        "artifacts_dir" => run["artifacts_dir"], "events_path" => @store.events_path(run["id"])
      }
    end

    def step_row(step, state)
      {"id" => step["id"], "title" => step["title"], "state" => state["state"], "attempts" => state["attempts"].size,
       "gate" => state.dig("gate", "state")}
    end

    # Nothing moves a run whose workspace has no agent daemon: no turn's end
    # is seen and no lock is asked for again, while it keeps what it holds.
    def daemon_warning(run, working, warnings)
      # A run that waits for a person needs no daemon until that person acts.
      return unless working || run.dig("reason", "code") == "waiting_lock"
      return if @panes.daemon_running?(run["workspace"])
      warnings << "Workflow run #{run["id"]} will not move: '#{run["workspace"]}' has no agent daemon running. It keeps the locks it holds " \
        "and its place in a queue. Launch the workspace and run `workspace workflow resume #{run["id"]}`, or end it with " \
        "`workspace workflow cancel #{run["id"]}`."
    end

    # The stored reason stands unless an agent should be working: then what
    # the pane shows comes first.
    def reason_for(run, working, pane, shown, warnings)
      stored = run["reason"]
      return stored unless working
      unless @panes.alive?(run["id"])
        return {"code" => "pane_gone", "since" => stored&.fetch("since", nil) || run["steps"].fetch(run["current"])["attempts"].last&.fetch("started_at", nil),
                "details" => {"step" => run["current"], "pane" => pane, "workspace" => run["workspace"]}}
      end
      waiting_on_person(run, pane, shown, warnings) || stored
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
      snapshot = @snapshot_client.fetch(workspace, timeout: SNAPSHOT_TIMEOUT)
      Array(snapshot["panes"]).find { |each| each["pane_id"] == pane }
    rescue Workspace::Error
      warnings << "The agent daemon for '#{workspace}' did not answer, so a permission prompt in its panes would not show here."
      nil
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
      # The agent is idle on a step that still reads as being worked on: its turn ended unseen.
      flags << "idle" if state["state"] == "running" && reason.nil? && WorkflowPanes.turn_over?(shown, @clock.call)
      flags
    end

    def actions(run, reason, pane)
      id = run["id"]
      cancel = action("workflow cancel", id)
      resume = action("workflow resume", id)
      focus = action("focus", run["workspace"], "--pane", pane.to_s)
      case reason["code"]
      when "waiting_lock"
        holder = reason.dig("details", "holder") || {}
        [(action("workflow status", holder["run_id"]) if holder["run_id"]),
          (action("dev down", "--name", run["workspace"]) if holder["kind"] == "process"), cancel].compact
      when "waiting_you"
        case reason.dig("details", "kind")
        when "gate" then [action("workflow approve", id), action("workflow reject", id, needs: [need("note", "--note")]), cancel]
        when "ask" then [action("ask answer", reason.dig("details", "ask").to_s, "--name", run["workspace"], needs: [need("answer", nil)]), focus]
        when "prompt" then [focus]
        else [resume, cancel]
        end
      when "turn_ended_incomplete" then [focus, resume, cancel]
      when "failed_check" then [resume, action("workflow resume", id, "--from", reason.dig("details", "step").to_s), cancel]
      when "pane_gone" then [action("launch", run["workspace"]), resume, cancel]
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
