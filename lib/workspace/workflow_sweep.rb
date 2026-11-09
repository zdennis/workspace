require "time"

module Workspace
  # One pass over the runs still going, acting on the ones that have stopped
  # without anything noticing. It needs no agent daemon: it reads the run files
  # and the panes, asks the daemon only for what a pane shows, and starts a
  # daemon that is not running.
  #
  # For a run whose step reads `running`, in this order:
  #
  # - the run's pane is gone: records `step_stalled` (cause `pane_gone`); the
  #   run keeps its checkout until someone resumes or cancels it
  # - the workspace's daemon is not running: starts it (`step_stalled` cause
  #   `daemon_down`, then `step_recovered` action `daemon_respawned`, written
  #   whenever a start succeeds and the recovery is not yet written) and goes no
  #   further for that run in this pass, since a new daemon's reading is not
  #   evidence; a start that fails is tried again on the next pass and recorded
  #   once. A workspace with no tmux session gets no daemon (`workspace_stopped`)
  # - the step is held (it has a reason), is still being delivered, or its pane
  #   waits for a person: left alone. The one exception is a step past its
  #   `timeout` with `on_timeout: fail` that is held on `turn_ended_incomplete`:
  #   it is failed (`step_timed_out`). A `turn_ended_background` hold has its own
  #   90-minute limit and is never touched
  # - the pane shows a shell where the agent was: records cause `agent_gone`
  # - the agent's turn is over (the daemon says so, read again just before the
  #   change, and idle for a few seconds) and the pane has been idle for the
  #   definition's `stall`, or the step is past its `timeout` and has
  #   `on_timeout` `interrupt` or `fail`, or the sweep interrupted it earlier:
  #   decides the step as {WorkflowEngine#resume} does when given the same proof
  #   (`step_stalled` cause `idle_turn_over`, `step_recovered` action
  #   `evaluated`); with `on_timeout: fail`, a decision that is a
  #   `turn_ended_incomplete` stop fails the step instead
  # - the agent is working and the step is past its `timeout`: `interrupt`
  #   claims the interrupt under the run's lock, presses the agent's interrupt
  #   keys with the lock given up, and confirms under the lock (action
  #   `interrupted`); `fail` does the same and then fails the step (action
  #   `failed`, `details.code` `step_timed_out`); `warn` does nothing, and writes
  #   nothing, as before
  #
  # For a run whose step waits on a line that was never delivered (`not_delivered`, a failure a later try can
  # get past), see {WorkflowEngine.redelivery}: once the backoff (1, 5, then 15 minutes after the failed attempt
  # ended) is over, the daemon is running and the pane shows an idle agent, the line is typed again
  # (`step_stalled` cause `undelivered`, `step_recovered` action `redelivered`, `redeliver` times at most, the
  # definition's key). A retried attempt does not count against `max_attempts`. When the retries run out the
  # run stays as it was, waiting for a person, and the sweep records `redelivery_exhausted` once.
  #
  # For a run whose failed step waits out an `on_fail` `backoff` ({WorkflowEngine.backoff}): before the time, nothing
  # (reason `backoff`, no stall is recorded); after it, the retry starts as a tick or a resume would start it
  # (outcome `retried`).
  #
  # A run with a live park, a step that is checking, or no step being worked
  # on is left alone, except that a missing daemon is started for it. Every
  # change goes through {WorkflowEngine} under the run's own lock, and only
  # when the run is still on the step and attempt the sweep read, so a resume
  # or a turn's end that got there first stands. A cause is recorded once for
  # each attempt, and a second pass finds the marks the first left.
  #
  # A small window remains: the pane is read, then the lock is taken, and an
  # agent that starts a new turn in between is not seen. The attempt check, the
  # idle floor and the second reading just before the change keep it to a
  # moment; a turn that begins after the check is decided as if it had ended.
  class WorkflowSweep
    # Seconds after an attempt starts during which an idle pane is not taken for one whose turn is over.
    IDLE_GRACE = WorkflowStatus::IDLE_GRACE

    # Seconds a pane must have been idle before the sweep treats its turn as over, on every branch.
    IDLE_FLOOR = 5

    # @param store [Workspace::WorkflowRunStore]
    # @param engine [Workspace::WorkflowEngine] makes every change to a run
    # @param panes [Workspace::WorkflowPanes] says whether a run's pane and daemon are there and what the pane shows
    # @param interrupter [#call] presses keys in a pane (`workspace`, `pane`, `keys`); raises {Workspace::Error} when it can't
    # @param clock [#call] returns the current Time
    def initialize(store:, engine:, panes:, interrupter:, clock: -> { Time.now })
      @store = store
      @engine = engine
      @panes = panes
      @interrupter = interrupter
      @clock = clock
    end

    # @param run [String, nil] only this run (a finished one is reported as such)
    # @param workspace [String, nil] only this workspace's runs
    # @param dry_run [Boolean] decide and report; change and press nothing
    # @param allow [#call, nil] given a stored run before the sweep changes it or presses keys in its pane;
    #   returns nil to go on or a sentence to leave the run alone
    # @return [Array<Hash>] one row per run looked at, and one `failed` row (`unreadable_run`) for each run file
    #   that can't be read when no run or workspace is named: "workspace", "outcome" (`nothing`, `recorded`,
    #   `evaluated`, `interrupted`, `timed_out`, `respawned`, `redelivered`, `retried`, `failed`, `dry_run`), "reason" (for a retry also `backoff`, `pane_busy`,
    #   `not_delivered`, `waiting_lock`), "message", "run_id",
    #   "step", "attempt", "cause", "action"
    # @raise [Workspace::Error] code `unknown_run` for a +run+ that does not exist
    def call(run: nil, workspace: nil, dry_run: false, allow: nil)
      runs = run ? [@store.run(run)] : @store.going
      runs = runs.select { |each| each.workspace == workspace } if workspace
      pass = {dry_run: dry_run, allow: allow, down: {}, daemons: {}}
      rows = runs.map { |each| sweep_run(each, pass) }
      rows += unreadable_rows unless run || workspace
      rows
    end

    private

    def unreadable_rows
      @store.unreadable.map do |path|
        {"workspace" => nil, "outcome" => "failed", "reason" => "unreadable_run", "run_id" => File.basename(path, ".json"), "step" => nil, "attempt" => nil,
         "cause" => nil, "action" => nil,
         "message" => "The run file #{path} can't be read, so its run is not looked at. What it held stays held: free a lock with `workspace lock clear NAME`, or delete the file."}
      end
    end

    # Asked once for each workspace in a pass, so every run of one that was down hears of it, though
    # the first run's pass has started the daemon by the time the next is looked at.
    def daemon_down?(workspace, pass)
      pass[:down].fetch(workspace) { pass[:down][workspace] = !@panes.daemon_running?(workspace) }
    end

    def sweep_run(run, pass)
      return row(run, "nothing", reason: "finished", message: "the run has ended") if WorkflowRunStore::TERMINAL_STATES.include?(run.state)
      state = run.steps.fetch(run.current)
      running = state.state == "running"
      backoff = WorkflowEngine.backoff(run.to_h, @clock.call)
      return sweep_backoff(run, backoff, pass) if backoff
      return blocked_row(run) if run.backoff&.dig("blocked") && run.state == "waiting"
      return budget_row(run) if run.budget_hold && run.state == "waiting"
      daemon_needed = running || state.state == "checking" || run.parked || run.reason&.dig("code") == "waiting_lock"
      if running && !@panes.alive?(run.id)
        pane = run.pane
        return note(run, pass, "pane_gone", "pane #{pane} is gone, so nothing will end this step. The run keeps its checkout until it is resumed (`workspace workflow resume #{run.id}`) or cancelled.", "pane" => pane)
      end
      redelivery = WorkflowEngine.redelivery(run.to_h, @clock.call)
      return sweep_undelivered(run, redelivery, pass) if redelivery
      return respawn(run, pass) if daemon_needed && daemon_down?(run.workspace, pass)
      return row(run, "nothing", reason: "parked", message: "a resume is parked; it is carried out when the pane's turn ends") if run.parked
      return row(run, "nothing", reason: "checking", message: "the step's check is running") if state.state == "checking"
      return row(run, "nothing", reason: "not_running", message: "no agent is working on step #{run.current} (#{state.state})") unless running
      sweep_running(run, state, pass)
    rescue Workspace::Error => e
      return row(run, "nothing", reason: "finished", message: "the run ended while it was being looked at") if e.code == "run_not_active"
      row(run, "failed", reason: e.code || "error", message: e.message.lines.first.to_s.strip)
    rescue KeyError, TypeError => e
      row(run, "failed", reason: "unreadable_run", message: "the run file is not shaped as a run is (#{e.class}: #{e.message.lines.first.to_s.strip})")
    rescue SystemCallError => e
      program = e.message[/ - (\S+)/, 1]
      row(run, "failed", reason: "tool_unavailable", message: "could not run #{program || "a program the sweep needs"}: #{e.message.lines.first.to_s.strip}. Put it on PATH.")
    end

    # The step failed and its `on_fail` retry waits out a `backoff`: not a stall. Once the time has come the retry
    # starts, as a tick or a resume would start it.
    def sweep_backoff(run, info, pass)
      what = "step #{run.current} failed; step #{info[:to]} starts again at #{info[:until]}"
      return row(run, "nothing", reason: "backoff", cause: "retry_backoff", message: "#{what} (in #{info[:wait]} seconds)") if info[:state] == :waiting
      message = "#{what}, and that time has passed"
      # A retry types a line, which only a running daemon's turn end follows up; the next pass retries after a respawn.
      return respawn(run, pass, notes: false) if daemon_down?(run.workspace, pass)
      return row(run, "dry_run", message: message, cause: "retry_backoff", action: "retry") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "retry_backoff") if refusal
      outcome = @engine.retry_backoff(run.id, step: run.current, attempt: attempt_of(run))
      return blocked_row(run) if outcome == :blocked
      return budget_row(run, cause: "retry_backoff", action: "retry") if outcome == :held
      engine_row(run, outcome, "retried", cause: "retry_backoff", message: message, action: "retry")
    end

    # The retry's wait is over but the token budget is used: not a failure, and the sweep cannot raise the budget.
    def budget_row(run, **rest)
      row(run, "nothing", reason: "budget_spent", message: "step #{run.current} was not started: the run's token budget is used. Resume it with --extra-tokens N (see `workspace workflow status #{run.id}`) or cancel it", **rest)
    end

    # The pane the retry would type into is no longer the run's. Not a failure: the sweep cannot fix it, and a person can.
    def blocked_row(run)
      row(run, "nothing", reason: "retry_blocked", cause: "retry_backoff", action: "retry",
        message: "the retry of step #{run.backoff&.dig("to")} is held: its pane is no longer the run's. Resume the run with --pane for another agent pane, or cancel it")
    end

    # The step waits on a line that was not delivered, and {WorkflowEngine.redelivery} says where a retry stands.
    def sweep_undelivered(run, info, pass)
      pane = run.pane
      what = "step #{run.current}'s line was not delivered to pane #{pane} (#{info[:code]})"
      case info[:state]
      when :exhausted
        return note(run, pass, "redelivery_exhausted", "#{what}, and it was retried #{info[:retries]} time#{"s" unless info[:retries] == 1}; resume the run (`workspace workflow resume #{run.id}`) once the pane is ready", "code" => info[:code], "retries" => info[:retries])
      when :waiting
        return row(run, "nothing", reason: "backoff", cause: "undelivered", message: "#{what}; retry #{info[:retries] + 1} of #{info[:limit]} in #{info[:wait]} seconds")
      end
      unless @panes.alive?(run.id)
        return note(run, pass, "pane_gone", "pane #{pane} is gone, so #{what} cannot be retried. The run keeps its checkout until it is resumed (`workspace workflow resume #{run.id}`) or cancelled.", "pane" => pane)
      end
      return respawn(run, pass) if daemon_down?(run.workspace, pass)
      shown = pane && @panes.pane_row(run.workspace, pane)
      return row(run, "nothing", reason: "unknown", cause: "undelivered", message: "#{what}; the agent daemon did not say what pane #{pane} shows") unless shown
      unless WorkflowPanes.turn_over?(shown, @clock.call) && shown["idle_seconds"].to_i >= IDLE_FLOOR
        return row(run, "nothing", reason: "pane_busy", cause: "undelivered", message: "#{what}; pane #{pane} is not idle, so nothing is typed. The next pass looks again")
      end
      message = "#{what}; typing it again (retry #{info[:retries] + 1} of #{info[:limit]})"
      return row(run, "dry_run", message: message, cause: "undelivered", action: "redeliver") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "undelivered") if refusal
      outcome = @engine.redeliver(run.id, step: run.current, attempt: attempt_of(run))
      case outcome
      when :not_delivered
        row(run, "nothing", reason: "not_delivered", cause: "undelivered", action: "redeliver", message: "#{message}, but it was not delivered again; the next retry waits out a longer backoff")
      when :waiting_lock
        row(run, "nothing", reason: "waiting_lock", cause: "undelivered", action: "redeliver", message: "#{message}, but the step is waiting for a lock it uses; it is typed when the lock is free")
      else engine_row(run, outcome, "redelivered", cause: "undelivered", message: message, action: "redeliver")
      end
    end

    # The step reads `running` and its pane is there.
    def sweep_running(run, state, pass)
      attempt = state.last_attempt
      return row(run, "nothing", reason: "no_attempt", message: "step #{run.current} reads running and has no attempt; resume the run") unless attempt
      begin
        started = Time.iso8601(attempt.started_at.to_s)
      rescue ArgumentError
        return row(run, "failed", reason: "unreadable_run", message: "the attempt has no readable start time")
      end
      elapsed = @clock.call - started
      step = run.definition["steps"].find { |each| each["id"] == run.current }
      timeout = step["timeout"]
      timed_out = timeout.is_a?(Numeric) && elapsed > timeout
      on_timeout = WorkflowDefinition.on_timeout(step)

      if run.reason
        return time_out(run, attempt, pass, elapsed, timeout, nil) if timed_out && on_timeout == "fail" && run.reason&.dig("code") == "turn_ended_incomplete"
        return row(run, "nothing", reason: "held", message: "step #{run.current} is held (#{run.reason&.dig("code")}); a person decides it")
      end
      return row(run, "nothing", reason: "delivering", message: "the step's line is still on its way to the pane") if WorkflowEngine.delivery(attempt.to_h, @clock.call) == :delivering
      pane = @panes.pane_of(run.id)
      shown = @panes.pane_row(run.workspace, pane)
      return row(run, "nothing", reason: "unknown", message: "the agent daemon did not say what pane #{pane} shows") unless shown
      if WorkflowPanes.agent_gone_row?(shown)
        return note(run, pass, "agent_gone", "pane #{pane} shows a shell: the agent has exited, so nothing will end this step. Resume the run to start it again.", "pane" => pane)
      end
      return row(run, "nothing", reason: "prompt", message: "pane #{pane} waits for an answer") if shown["state"] == "waiting"

      stall = WorkflowDefinition.stall(run.definition)
      idle_for = shown["idle_seconds"].to_i
      if WorkflowPanes.turn_over?(shown, @clock.call) && elapsed >= IDLE_GRACE && idle_for >= IDLE_FLOOR
        cause = if WorkflowEngine.sweep_marks(run.to_h).dig("interrupt", "state") == "sent" then "interrupted"
        elsif (stall && idle_for >= stall) || (timed_out && on_timeout != "warn") then "idle_turn_over"
        end
        return row(run, "nothing", reason: "idle", message: "the agent's turn is over; the step is decided once it has been idle for the definition's stall") unless cause
        return evaluate(run, attempt, pass, pane, shown, cause, idle_for, (timed_out && on_timeout == "fail") ? {"elapsed" => elapsed, "timeout" => timeout} : nil)
      end
      return row(run, "nothing", reason: "healthy", message: nil) unless timed_out
      return row(run, "nothing", reason: "timed_out", message: "step #{run.current} is past its #{timeout} second timeout (on_timeout: warn)") if on_timeout == "warn"
      return row(run, "nothing", reason: "not_working", message: "step #{run.current} is past its timeout, but pane #{pane} does not show the agent working") unless shown["state"] == "working"
      press_and_confirm(run, attempt, pass, shown, pane, elapsed, timeout, then_fail: on_timeout == "fail")
    end

    def note(run, pass, cause, message, data = {})
      return row(run, "nothing", reason: "already_recorded", message: message, cause: cause) if WorkflowEngine.sweep_marks(run.to_h).dig("stalled", cause)
      return row(run, "dry_run", message: message, cause: cause, action: "record") if pass[:dry_run]
      outcome = @engine.note_stall(run.id, step: run.current, attempt: attempt_of(run), cause: cause, data: data)
      engine_row(run, outcome, "recorded", cause: cause, message: message, action: "record")
    end

    # Starts the workspace's daemon. The run is not acted on again in this pass.
    def respawn(run, pass, notes: true)
      workspace = run.workspace
      message = "the agent daemon of '#{workspace}' is not running, so no turn's end is seen"
      unless @panes.session_live?(workspace)
        return row(run, "nothing", reason: "workspace_stopped", cause: "daemon_down", message: "#{message}, and the workspace has no tmux session, so none is started")
      end
      return row(run, "dry_run", message: message, cause: "daemon_down", action: "respawn_daemon") if pass[:dry_run]
      started = (pass[:daemons][workspace] ||= @panes.respawn_daemon(workspace))
      attempt = attempt_of(run)
      @engine.note_stall(run.id, step: run.current, attempt: attempt, cause: "daemon_down", data: {"workspace" => workspace}) if notes
      unless started[:ok]
        return row(run, "failed", reason: "daemon_not_started", cause: "daemon_down", action: "respawn_daemon",
          message: "#{message}, and it could not be started#{": #{started[:detail]}" if started[:detail]}")
      end
      @engine.note_recovery(run.id, step: run.current, attempt: attempt, cause: "daemon_down", action: "daemon_respawned") if notes
      row(run, "respawned", cause: "daemon_down", action: "respawn_daemon", message: "#{message}; it is running again, and the pane is read on the next pass")
    end

    def evaluate(run, attempt, pass, pane, shown, cause, idle_for, fail_if_incomplete)
      message = "the agent's turn ended and nothing decided step #{run.current} (idle for #{idle_for} seconds)"
      return row(run, "dry_run", message: message, cause: cause, action: "evaluate") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      # The proof is read again just before the change, so it is as fresh as the lock allows.
      fresh = @panes.pane_row(run.workspace, pane)
      unless fresh && fresh["kind"] == shown["kind"] && WorkflowPanes.turn_over?(fresh, @clock.call) && fresh["idle_seconds"].to_i >= IDLE_FLOOR
        return row(run, "nothing", reason: "pane_changed", message: "pane #{pane} no longer shows the agent's turn over; the next pass looks again", cause: cause)
      end
      outcome = @engine.recover(run.id, turn_over: {"step" => run.current, "attempt" => attempt.n}, cause: cause,
        data: {"idle_for" => idle_for}, fail_if_incomplete: fail_if_incomplete)
      engine_row(run, outcome, (outcome == :timed_out) ? "timed_out" : "evaluated", cause: cause, message: message, action: "evaluate")
    end

    # Claims under the run's lock, presses with it given up, confirms under it. For `fail` the confirmation is the failure itself.
    def press_and_confirm(run, attempt, pass, shown, pane, elapsed, timeout, then_fail:)
      message = "step #{run.current} is #{elapsed.round} seconds in, past its #{timeout} second timeout"
      action = then_fail ? "fail" : "interrupt"
      held = WorkflowEngine.sweep_marks(run.to_h)["interrupt"]
      return time_out(run, attempt, pass, elapsed, timeout, nil) if then_fail && held && held["state"] == "sent"
      keys = AgentProvider.find(shown["kind"].to_s)&.interrupt_keys.to_a
      if keys.empty?
        return row(run, "nothing", reason: "no_interrupt_key", cause: "timed_out", message: "#{message}, and workspace knows no interrupt key for #{shown["kind"] || "this agent"}")
      end
      return row(run, "dry_run", message: message, cause: "timed_out", action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "timed_out") if refusal
      step_ref = {step: run.current, attempt: attempt.n}
      claim, claim_at = @engine.claim_interrupt(run.id, **step_ref, elapsed: elapsed, timeout: timeout)
      unless claim == :claimed
        return row(run, "nothing", reason: "already_interrupted", message: message, cause: "timed_out") if claim == :repeat
        return engine_row(run, claim, "interrupted", cause: "timed_out", message: message, action: action)
      end
      unless still_working?(run, pane, shown)
        @engine.interrupt_sent(run.id, **step_ref, claim_at: claim_at, sent: false)
        return row(run, "nothing", reason: "pane_changed", message: "pane #{pane} no longer shows the agent working in this run; nothing was pressed", cause: "timed_out")
      end
      failure = press(run, pane, keys)
      @engine.interrupt_sent(run.id, **step_ref, claim_at: claim_at, sent: failure.nil?, record: !then_fail)
      return row(run, "failed", reason: "interrupt_failed", message: "could not interrupt pane #{pane}: #{failure}", cause: "timed_out", action: action) if failure
      return row(run, "interrupted", message: message, cause: "timed_out", action: action) unless then_fail
      time_out(run, attempt, pass, elapsed, timeout, "the agent was interrupted")
    end

    # Read just before the press: the same agent still works in the pane, and the pane is still this run's.
    def still_working?(run, pane, shown)
      fresh = @panes.pane_row(run.workspace, pane)
      !fresh.nil? && fresh["state"] == "working" && fresh["kind"] == shown["kind"] && @panes.run_on(pane) == run.id
    end

    def time_out(run, attempt, pass, elapsed, timeout, note)
      message = "step #{run.current} is #{elapsed.round} seconds in, past its #{timeout} second timeout#{" (#{note})" if note}"
      return row(run, "dry_run", message: message, cause: "timed_out", action: "fail") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return row(run, "nothing", reason: "refused", message: refusal, cause: "timed_out") if refusal
      outcome = @engine.time_out(run.id, step: run.current, attempt: attempt.n, elapsed: elapsed, timeout: timeout)
      engine_row(run, outcome, "timed_out", cause: "timed_out", message: message, action: "fail")
    end

    # nil once the keys are pressed; otherwise why they were not.
    def press(run, pane, keys)
      @interrupter.call(run.workspace, pane, keys)
      nil
    rescue Workspace::Error => e
      e.message.lines.first.to_s.strip
    end

    # The engine's answer for a change the sweep tried, as a row.
    def engine_row(run, outcome, done, **rest)
      case outcome
      when :repeat then row(run, "nothing", reason: "already_recorded", **rest.except(:action))
      when :moved_on then row(run, "nothing", reason: "moved_on", **rest.except(:action), message: "the run moved on while it was being looked at; nothing was changed")
      when :busy then row(run, "nothing", reason: "busy", **rest.except(:action), message: "another process is changing the run; the next pass looks again")
      else row(run, done, **rest)
      end
    end

    def attempt_of(run)
      run.step(run.current)&.last_attempt&.n
    end

    def row(run, outcome, reason: nil, message: nil, cause: nil, action: nil)
      {"workspace" => run.workspace, "outcome" => outcome, "reason" => reason, "message" => message, "run_id" => run.id,
       "step" => run.current, "attempt" => attempt_of(run), "cause" => cause, "action" => action}
    end
  end
end
