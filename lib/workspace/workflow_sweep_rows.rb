module Workspace
  # The result rows and idle thresholds a `workflow sweep` pass shares between {WorkflowSweep} (running, backoff and
  # undelivered steps) and {WorkflowReviewSweep} (review rounds and left-over review windows). Pure functions over a
  # stored run; nothing here reads a pane, a clock or a file.
  module WorkflowSweepRows
    # Seconds after an attempt starts during which an idle pane is not taken for one whose turn is over.
    IDLE_GRACE = WorkflowStatus::IDLE_GRACE

    # Seconds a pane must have been idle before the sweep treats its turn as over, on every branch.
    IDLE_FLOOR = WorkflowPanes::IDLE_FLOOR

    module_function

    # One row of a pass.
    #
    # A run draining a fan_out group yields one row per sibling under way, so several rows of a pass share a
    # "run_id" and only "step" tells them apart: a reader must not key rows on "run_id" alone.
    #
    # @param run [WorkflowRun]
    # @param outcome [String] see {WorkflowSweep#call}
    # @return [Hash{String=>Object}] "workspace", "outcome", "reason", "message", "run_id", "step", "attempt", "cause", "action"
    def row(run, outcome, reason: nil, message: nil, cause: nil, action: nil)
      {"workspace" => run.workspace, "outcome" => outcome, "reason" => reason, "message" => message, "run_id" => run.id,
       "step" => run.current, "attempt" => attempt_of(run), "cause" => cause, "action" => action}
    end

    # The engine's answer for a change the sweep tried, as a row: +done+ for a change made, else why none was.
    #
    # @param run [WorkflowRun]
    # @param outcome [Symbol] what the engine answered
    # @param done [String] the outcome of a change made
    # @return [Hash{String=>Object}]
    def engine_row(run, outcome, done, **rest)
      case outcome
      when :repeat then row(run, "nothing", reason: "already_recorded", **rest.except(:action))
      when :moved_on then row(run, "nothing", reason: "moved_on", **rest.except(:action), message: "the run moved on while it was being looked at; nothing was changed")
      when :busy then row(run, "nothing", reason: "busy", **rest.except(:action), message: "another process is changing the run; the next pass looks again")
      else row(run, done, **rest)
      end
    end

    # @param run [WorkflowRun]
    # @return [Integer, nil] the current step's last attempt
    def attempt_of(run)
      run.step(run.current)&.last_attempt&.n
    end
  end
end
