module Workspace
  # The result rows and idle thresholds a `workflow sweep` pass shares between {WorkflowSweep} (running, backoff and
  # undelivered steps) and {WorkflowReviewSweep} (review rounds and left-over review windows). Pure functions over a
  # stored run; nothing here reads a pane, a clock or a file.
  module WorkflowSweepRows
    # Seconds after an attempt starts during which an idle pane is not taken for one whose turn is over.
    IDLE_GRACE = WorkflowStatus::IDLE_GRACE

    # Seconds a pane must have been idle before the sweep treats its turn as over, on every branch.
    IDLE_FLOOR = WorkflowPanes::IDLE_FLOOR

    # The wait key of an agent's waiting screen in a pane row's `waits` ({PaneScreenRules::SCREEN_WAIT_KEY}).
    SCREEN_WAIT = "screen"

    # The longest a pane must have shown no output before the sweep takes it to sit at a dialog: a real dialog prints
    # nothing, while a wait left by a sub-agent that is gone sits beside an agent that keeps working. A fixed window,
    # so a redraw (a resize, a status line) or a daemon restart, which starts the idle count again, only delays the stop.
    QUIET_WINDOW = 600

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

    # The waits in a pane row nobody in a workflow answers: permission dialogs and waiting screens, with a readable
    # `since` or not. A question to the person is not one.
    #
    # @param shown [Hash{String=>Object}] a pane row from the agent daemon
    # @return [Array<Hash{String=>Object}>]
    def unanswered_waits(shown)
      Array(shown["waits"]).grep(Hash).select { |wait| wait["permission"] || wait["agent_id"] == SCREEN_WAIT }
    end

    # What a pane row says about the dialog it waits at, for `workflows.permission_wait_limit`: nil when it waits
    # at none (a question to the person, or nothing). The age runs from the oldest unanswered wait's `since`, less
    # +stops+ (downtime), and is nil when no such `since` can be read.
    #
    # @param shown [Hash{String=>Object}] a pane row from the agent daemon
    # @param now [Time]
    # @param stops [Array<Hash{String=>Object}>] downtime spans
    # @return [Hash{Symbol=>Object}, nil] `:since` (the ISO text as written), `:age` (seconds), `:screen` (Boolean),
    #   `:what` (words for the dialog), `:waited` (words for its age)
    def dialog(shown, now, stops)
      waits = unanswered_waits(shown)
      return nil if waits.empty? && shown["waiting_reason"] != "waiting_permission"
      since = oldest_since(waits)
      age = since && [WorkflowDeadline.active_seconds(Time.iso8601(since), now, Array(stops)), 0].max
      screens = waits.select { |wait| wait["agent_id"] == SCREEN_WAIT }
      said = screens.find { |wait| wait["message"].is_a?(String) }
      what = if said then "a waiting screen (#{said["message"]})"
      elsif screens.any? then "a waiting screen"
      else "a permission dialog"
      end
      waited = age ? "has waited #{Duration.humanize(age.round)}" : "waits (for how long is unknown: the wait has no readable start)"
      {since: since, age: age, screen: screens.any?, what: what, waited: waited}
    end

    # The quiet window a dialog's pane must show before the sweep acts: {QUIET_WINDOW}, or the shortest of +bounds+.
    #
    # @param bounds [Array<Numeric, nil>] the limit, a timeout, the wait's age (nil ones left out)
    # @return [Numeric]
    def quiet_window(*bounds) = [*bounds, QUIET_WINDOW].compact.min

    # @param shown [Hash{String=>Object}, nil] a pane row
    # @param window [Numeric] seconds
    # @return [Boolean] whether the pane has shown no output for +window+ seconds
    def quiet?(shown, window)
      idle = shown && shown["idle_seconds"]
      idle.is_a?(Numeric) && idle >= window
    end

    # Read just before the change: the pane still waits at the same dialog (its oldest unanswered wait has the same
    # `since`) and is still quiet. An answered dialog, or a new one, is not the wait that ran out.
    #
    # @param fresh [Hash{String=>Object}, nil] the pane row read again
    # @param dialog [Hash{Symbol=>Object}] the {.dialog} first read
    # @param window [Numeric] the quiet window
    # @return [Boolean]
    def same_dialog?(fresh, dialog, window)
      !fresh.nil? && fresh["state"] == "waiting" && oldest_since(unanswered_waits(fresh)) == dialog[:since] && quiet?(fresh, window)
    end

    # The oldest `since` of +waits+ as written in the row, or nil when none can be read.
    def oldest_since(waits)
      waits.filter_map do |wait|
        at = begin
          Time.iso8601(wait["since"]) if wait["since"].is_a?(String)
        rescue ArgumentError
          nil
        end
        at && [at, wait["since"]]
      end.min_by(&:first)&.last
    end
    private_class_method :oldest_since
  end
end
