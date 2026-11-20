module Workspace
  # What a person can do about the rows of a `workflow sweep` pass, for `--json`'s `next_actions`. Every action
  # carries the row's reason (or, for a stall the pass recorded, its cause) as `why`.
  #
  # Rows that clear themselves, `refused` (the caller is the run's own pane), `failed` and closed orphan review
  # windows give none. `launch` needs a workspace name, so a row without one gets none; a row without a run id,
  # or whose run or pane cannot be read, gets none of the actions that name the run or its pane.
  class WorkflowSweepActions
    # @param store [WorkflowRunStore] reads a run for its limits and current step
    # @param panes [WorkflowPanes] finds the pane a `prompt` row waits on
    # @param status [WorkflowStatus] gives the needs of a spent budget or time limit ({WorkflowStatus#limit_needs})
    # @param clock [#call] gives the time a step's delivery is judged at
    def initialize(store:, panes:, status:, clock: -> { Time.now })
      @store = store
      @panes = panes
      @status = status
      @clock = clock
    end

    # @param rows [Array<Hash>] the sweep's result rows
    # @param run [String, nil] the run id the sweep was limited to
    # @param name [String, nil] the workspace the sweep was limited to
    # @return [Array<Hash>] actions as {NextAction.build} makes them; empty when nothing needs a person
    def call(rows, run:, name:)
      actions = rows.flat_map { |row| row_actions(row) }
      dry = rows.select { |each| each["outcome"] == "dry_run" }
      unless dry.empty?
        scope = if run then [run]
        elsif name then ["--name", name]
        else []
        end
        count = dry.size
        actions << NextAction.build("workflow sweep", *scope,
          why: "dry run: would make #{count} #{(count == 1) ? "change" : "changes"}; run without --dry-run to apply #{(count == 1) ? "it" : "them"}")
      end
      actions
    end

    private

    def row_actions(row)
      why = row["reason"] || row["cause"]
      id = row["run_id"]
      return [] unless id
      return scheduled_actions(id, row["cause"], row["step"]) if row["outcome"] == "recorded" && row["action"] == "infra_retry_scheduled"
      return recorded_actions(id, why, row["step"]) if row["outcome"] == "recorded"
      return [] unless row["outcome"] == "nothing"
      reason_actions(row, id, why)
    end

    # A stall the pass recorded with an automatic restart scheduled: nothing for a person to do but wait; the run's
    # status shows when the restart is due. A row of `infra_retries_exhausted` gets the stall's actions below.
    def scheduled_actions(id, cause, step)
      stored = lookup { @store.run(id) }
      info = stored && WorkflowEngine.infra_retry(WorkflowTransitions.at_step(stored.to_h, step), @clock.call)
      at = info&.fetch(:due) ? " at #{info[:due]}" : ""
      [NextAction.build("workflow status", id, why: "wait: the step restarts on its own (#{WorkflowStatus.infra_cause_words(cause)})#{at}; no action needed")]
    end

    # A recorded stall: resume or cancel, and for a gone pane or agent on a still-open attempt, a restart of the step.
    # `--restart-step` restarts the cursor's step, so a fan_out sibling off the cursor is offered none.
    def recorded_actions(id, why, step)
      stored = lookup { @store.run(id) }
      restart = if stored && WorkflowTransitions.at_step(stored.to_h, step).equal?(stored.to_h) && WorkflowStatus.restartable?(stored.to_h, now: @clock.call)
        [NextAction.build("workflow resume", id, "--restart-step", needs: @status.limit_needs(stored), why: why)]
      else
        []
      end
      [NextAction.build("workflow resume", id, why: why)] + restart + [NextAction.build("workflow cancel", id, why: why)]
    end

    def reason_actions(row, id, why)
      case row["reason"]
      when "paused"
        [NextAction.build("workflow unpause", id, why: why)]
      when "held"
        [NextAction.build("workflow resume", id, why: why)]
      when "budget_spent", "run_timed_out"
        stored = lookup { @store.run(id) }
        stored ? [NextAction.build("workflow resume", id, needs: @status.limit_needs(stored), why: why)] : []
      when "retry_blocked"
        stored = lookup { @store.run(id) }
        return [] unless stored
        [NextAction.build("workflow resume", id, needs: [NextAction.need("pane", "--pane")] + @status.limit_needs(stored), why: why),
          NextAction.build("workflow cancel", id, why: why)]
      when "workspace_stopped"
        (row["workspace"] && row["cause"] != "orphan_review_window") ? [NextAction.build("launch", row["workspace"], why: why)] : []
      when "prompt"
        pane = lookup { prompt_pane(id, row["step"]) }
        (row["workspace"] && pane) ? [NextAction.build("focus", row["workspace"], "--pane", pane, why: why)] : []
      else
        []
      end
    end

    # The pane a `prompt` row waits on: the review pane while a round is under way, else the run's own; a fan_out
    # sibling's row waits on the sibling's own pane.
    def prompt_pane(id, step = nil)
      stored = @store.run(id)
      return @panes.pane_of(id, step: step) if WorkflowRun.step_scoped?(stored.to_h, step)
      (stored.step(stored.current)&.state == "reviewing") ? @panes.review_pane_of(id) : @panes.pane_of(id)
    end

    # Only the store and pane reads are rescued, so a bug in building an action still shows.
    def lookup
      yield
    rescue Workspace::Error
      nil
    end
  end
end
