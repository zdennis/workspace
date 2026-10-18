require "time"

module Workspace
  # Turns a parsed plan and what is known about its workspace into one `state`
  # and the row `plan status --json` reports, so no reader holds the rules.
  #
  # The state is the first of these that holds:
  #
  # 1. `empty`: the plan has no tasks (or there is no plan file)
  # 2. `done`: nothing is left, or `status: done`
  # 3. `paused`: `status: paused`
  # 4. `stopped`: the workspace has no live session
  # 5. `waiting`: the owner pane waits on a person, or a question is open
  # 6. `working`: the owner pane works
  # 7. `blocked`: every task left is blocked
  # 8. `stalled`: the owner pane has been idle longer than the stall limit
  # 9. `idle`
  #
  # A fact that is unknown (nil) never decides a state: a session that could
  # not be asked about is not `stopped`, and a pane that could not be read is
  # neither working nor idle.
  class PlanState
    # Seconds an owner pane may idle before the plan reads `stalled` (the default of `plan.stall_seconds`).
    DEFAULT_STALL_SECONDS = ConfigSchema.default("plan.stall_seconds")

    # The task states counted in `left`.
    LEFT_STATES = %w[todo in_progress blocked].freeze

    # @param clock [#call] returns the current Time
    def initialize(clock: -> { Time.now })
      @clock = clock
    end

    # @param plan [PlanFile] the parsed plan
    # @param session_live [Boolean, nil] whether the workspace's tmux session runs; nil when unknown
    # @param pane_state [String, nil] the owner pane's state (`working`, `idle`, `waiting`, ...); nil when unknown
    # @param pane_since [String, nil] ISO 8601 time the pane entered that state
    # @param open_asks [Integer] open `workspace ask` questions in the workspace
    # @param stall_seconds [Numeric] how long an idle owner pane may sit before `stalled`
    # @return [String] one of `empty`, `done`, `paused`, `stopped`, `waiting`, `working`, `blocked`, `stalled`, `idle`
    def derive(plan:, session_live: nil, pane_state: nil, pane_since: nil, open_asks: 0, stall_seconds: DEFAULT_STALL_SECONDS)
      counts = plan.counts
      return "empty" if counts["total"].zero?
      return "done" if counts["left"].zero? || plan.status == "done"
      return "paused" if plan.status == "paused"
      return "stopped" if session_live == false
      return "waiting" if pane_state == "waiting" || open_asks.positive?
      return "working" if pane_state == "working"
      return "blocked" if counts["blocked"] == counts["left"]
      return "stalled" if pane_state == "idle" && idle_longer_than?(pane_since, stall_seconds)
      "idle"
    end

    # One plan's row for `plan status --json`. The fields after `path` are null,
    # zero or empty when there is no plan file.
    #
    # @param workspace [String, nil] nil for a file read on its own
    # @param project [String, nil] the workspace's project; nil for a file read on its own
    # @param path [String] the plan's absolute path
    # @param plan [PlanFile, nil] nil when the file does not exist
    # @param session_live [Boolean, nil] see {#derive}
    # @param panes [Array<Hash>, nil] the agent daemon's pane rows (`pane_id`, `state`, `state_since`); nil when unknown
    # @param open_asks [Integer] see {#derive}
    # @param stall_seconds [Numeric] see {#derive}
    # @return [Hash]
    def row(workspace:, project:, path:, plan:, session_live: nil, panes: nil, open_asks: 0, stall_seconds: DEFAULT_STALL_SECONDS)
      return missing_row(workspace, project, path) unless plan

      owner = plan.owner_pane
      pane = owner && panes&.find { |candidate| candidate["pane_id"] == owner }
      warnings = plan.warnings.dup
      if owner && panes && !pane && session_live != false
        warnings << PlanFile.warning("owner_pane_unknown", nil, "owner_pane #{owner} is not a pane of this workspace's session.")
      end
      pane_state = pane && pane["state"]
      derived = derive(plan: plan, session_live: session_live, pane_state: pane_state, pane_since: pane && pane["state_since"],
        open_asks: open_asks, stall_seconds: stall_seconds)
      tasks = plan.tasks.map { |task| task_row(task, panes, session_live, warnings) }
      warnings = warnings.each_with_index.sort_by { |warning, i| [warning["line"] || Float::INFINITY, i] }.map(&:first)
      {"workspace" => workspace, "project" => project, "path" => path, "exists" => true, "title" => plan.title, "status" => plan.status,
       "state" => derived, "owner_pane" => owner, "pane_state" => pane_state, "updated_at" => plan.updated_at, "signature" => plan.signature,
       "counts" => plan.counts, "percent" => plan.percent, "current" => plan.current, "tasks" => tasks,
       "open_asks" => open_asks, "warnings" => warnings}
    end

    private

    # A task with its owner pane's state (`owner_state`, nil when unknown); an owner of a task
    # still left that the daemon does not list adds `task_owner_unknown` to +warnings+ (a done
    # task keeps its owner comment after the pane is gone, which is no problem).
    def task_row(task, panes, session_live, warnings)
      owner = task.owner
      pane = owner && panes&.find { |candidate| candidate["pane_id"] == owner }
      if owner && panes && !pane && session_live != false && LEFT_STATES.include?(task.state)
        warnings << PlanFile.warning("task_owner_unknown", task.line, "Task #{task.id || "on line #{task.line}"} is owned by #{owner}, which is not a pane of this workspace's session.")
      end
      task.to_h.merge("owner_state" => pane && pane["state"])
    end

    def missing_row(workspace, project, path)
      empty = PlanFile.parse("")
      {"workspace" => workspace, "project" => project, "path" => path, "exists" => false, "title" => nil, "status" => nil, "state" => "empty",
       "owner_pane" => nil, "pane_state" => nil, "updated_at" => nil, "signature" => nil, "counts" => empty.counts, "percent" => 0,
       "current" => nil, "tasks" => [], "open_asks" => 0, "warnings" => []}
    end

    def idle_longer_than?(since, limit)
      return false unless since
      @clock.call - Time.iso8601(since) > limit
    rescue ArgumentError
      false
    end
  end
end
