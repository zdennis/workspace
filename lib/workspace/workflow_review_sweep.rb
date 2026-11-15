require "time"

module Workspace
  # The rows of a {WorkflowSweep} pass for a run whose step reads `reviewing` (a review round), and for the review
  # windows no round uses. {WorkflowSweep} decides whether a run is a review's (and starts a missing daemon for it);
  # everything after that is here. Each change goes through {WorkflowEngine} under the run's lock for the step,
  # attempt and round the sweep read, so a turn's end, a resume or a cancel that got there first stands.
  #
  # For a round, in this order: one stopped for a person (any stored reason but `waiting_lock`) is left alone
  # ({#held_row}); one whose end was being judged when its process died is handed to {WorkflowEngine#tick} (cause
  # `lost_round`, {#lost_round}); then {#call}: a round waiting for its `review.uses` is left to {WorkflowEngine#tick};
  # a round whose delivery failed (after the backoff an undelivered line waits) or lapsed with its delivering process
  # gone is handed to {WorkflowEngine#tick}, which delivers it again or, its `redeliver` spent, stops it
  # `review_incomplete` (cause `round_undelivered`), unless its line may have been typed
  # ({WorkflowTransitions.typed_round?}): that one is read in its review pane as below, and past
  # {WorkflowTransitions.typed_wait_over?} handed to {WorkflowEngine#tick} (cause `round_maybe_typed`); a round still
  # being delivered is left alone; then the round's review pane is read, on positive evidence only
  # ({WorkflowPanes#review_pane_state}; a tmux that can't be read, or a round that recorded no tmux server, decides
  # neither gone nor restarted, and the daemon's pane row decides the rest): gone (cause `pane_gone`), its agent
  # exited to a shell (cause `agent_gone`), lost with a restarted tmux server (cause `server_restarted`, delivered
  # again in a new window, counted against `redeliver`), waiting for an answer (left alone), its turn over and idle
  # for the definition's `stall` or past a time limit (cause `idle_turn_over`), its turn over after the sweep
  # interrupted it (cause `interrupted`, decided at once), or at work past a time limit: the round's own
  # `review.timeout` ({WorkflowTransitions.round_timed_out?}, from the round's start; cause `review_timed_out`) or the
  # run's `timeout:` with `timeout_action: interrupt` (cause `run_timed_out`). For a time limit the interrupt is
  # claimed under the run's lock, the agent's interrupt keys pressed in the review pane with the lock given up (never
  # the author's pane), and the press confirmed under the lock, each cause once per delivery of the round in the
  # round's own marks ({WorkflowTransitions.round_sweep_marks}), the round cause first when both are due; the press
  # needs the pane still bound to the run as its reviewer. A round whose line may have been typed is pressed the same
  # way before it is handed to the tick. The turn the press ends is then decided as any review turn's end is: the
  # verdicts on disk count, and a round they leave short stops `review_incomplete` with its window kept for the
  # person, running no reviewer again. A pane still at work the longer of the definition's `stall` and the review's
  # timeout after every due press is decided on its verdicts too, stopping `review_incomplete` with its window kept
  # when they fall short (cause `interrupt_unanswered`; {WorkflowEngine#tick} decides it the same way with no sweep). A gone pane, a
  # gone agent and an idle turn are decided the same way. The idle turn is not told from one whose Stop listed
  # background tasks (the daemon's pane row does not carry them), so a reviewer that left a sub-agent running past
  # `stall` is decided on what it has written. Each writes `step_stalled` with the round.
  #
  # Review windows no round uses ({WorkflowReviewOrphans}: the run is over, or its round does not record the window)
  # are closed, one row each (outcome `closed`, cause `orphan_review_window`, {#orphan_rows}); a window of another
  # run store is left out, and one whose run this store does not have is reported (`nothing`, reason `unconfirmed`)
  # and never closed.
  class WorkflowReviewSweep
    # @param engine [Workspace::WorkflowEngine] makes every change to a run
    # @param panes [Workspace::WorkflowPanes] says what a review pane shows and whether it is the run's
    # @param interrupter [#call] presses keys in a pane (`workspace`, `pane`, `keys`); raises {Workspace::Error} when it can't
    # @param orphans [Workspace::WorkflowReviewOrphans, nil] finds and closes review windows no round uses; nil closes none
    # @param holder_alive [#call, nil] given a review round's delivery `holder`, whether that process still runs (nil
    #   takes every holder as alive, so a lapsed round with a holder is left alone)
    # @param clock [#call] returns the current Time
    def initialize(engine:, panes:, interrupter:, orphans: nil, holder_alive: nil, clock: -> { Time.now })
      @engine = engine
      @panes = panes
      @interrupter = interrupter
      @orphans = orphans
      @holder_alive = holder_alive
      @clock = clock
    end

    # The row of a round stopped for a person: a person decides it.
    #
    # @param run [WorkflowRun]
    # @return [Hash] a sweep row ({WorkflowSweep#call})
    def held_row(run)
      round = run.step(run.current)&.review
      what = if round.is_a?(Hash) && round["round"]
        "review round #{round["round"]} of step #{run.current}"
      else
        "the review of step #{run.current}"
      end
      WorkflowSweepRows.row(run, "nothing", reason: "held", message: "#{what} stopped (#{run.reason&.dig("code")}); a person decides it")
    end

    # The end of a review round was being judged and its process died before it reported back: not a stall. The
    # judging is handed to {WorkflowEngine#tick}, which runs it once more.
    #
    # @param run [WorkflowRun]
    # @param pass [Hash] the pass's `dry_run` and `allow`
    # @return [Hash] a sweep row
    def lost_round(run, pass)
      message = "the end of step #{run.current}'s review round was being judged and nothing reported back"
      return WorkflowSweepRows.row(run, "dry_run", message: message, cause: "lost_round", action: "judge_again") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return WorkflowSweepRows.row(run, "nothing", reason: "refused", message: refusal, cause: "lost_round") if refusal
      outcome = @engine.tick(run.id) ? :judged : :busy
      WorkflowSweepRows.engine_row(run, outcome, "judged_again", cause: "lost_round", message: message, action: "judge_again")
    end

    # The step reads `reviewing` with no stop for a person, and the daemon is running.
    #
    # @param run [WorkflowRun]
    # @param state [WorkflowRun::Step] the current step
    # @param pass [Hash] the pass's `dry_run` and `allow`
    # @return [Hash] a sweep row
    def call(run, state, pass)
      round = state.review
      unless round.is_a?(Hash) && round["round"]
        return WorkflowSweepRows.row(run, "nothing", reason: "reviewing", message: "step #{run.current} is being reviewed")
      end
      what = "review round #{round["round"]} of step #{run.current}"
      if run.reason
        return WorkflowSweepRows.row(run, "nothing", reason: "waiting_lock",
          message: "#{what} waits for a lock its review.uses names; it starts once the lock is free")
      end
      now = @clock.call
      # A round whose line may have been typed is read in its review pane like a delivered one: its pane, agent and
      # idle turn decide it, never a delivery again.
      typed = WorkflowTransitions.typed_round?(round, now, alive: @holder_alive)
      redelivery = typed ? nil : WorkflowTransitions.round_redelivery(run.to_h, now, alive: @holder_alive)
      return round_undelivered(run, what, round, redelivery, pass) if redelivery
      if round["delivery"] == "delivering" && !typed
        return WorkflowSweepRows.row(run, "nothing", reason: "delivering", message: "#{what} is still being delivered")
      end
      # Past the short wait, the engine's tick decides it from its pane (so a setup with only the sweep, no daemon
      # timer, decides it too); it still waits for a reviewer at work or a prompt. A reviewer at work past a time
      # limit is pressed first, as in a delivered round, through the round's own claim (below).
      if typed && WorkflowTransitions.typed_wait_over?(run.to_h, round, now) && !press_typed?(run, round, now)
        return typed_round(run, what, pass)
      end
      return WorkflowSweepRows.row(run, "nothing", reason: "reviewing", message: "the end of #{what} is being judged") if round["recompute"]
      pane = round["pane"]
      return WorkflowSweepRows.row(run, "nothing", reason: "reviewing", message: "#{what} is being reviewed") unless pane
      case @panes.review_pane_state(run.workspace, pane, round["server_pid"])
      when :gone
        return stall(run, round, pass, pane, "pane_gone", "review pane #{pane} of #{what} is gone, so nothing will end the round; " \
          "its verdicts are read now, and it stops for a person (review_incomplete) when they fall short")
      when :server_restarted
        return stall(run, round, pass, pane, "server_restarted",
          "the tmux server review pane #{pane} of #{what} was on was restarted; the round is delivered again in a new window")
      end
      # With no answer from tmux (unreachable, or no server recorded to rule out a reused pane id) nothing is decided
      # on the pane being gone or its server restarted; what the daemon's pane row shows still decides the rest.
      shown = @panes.pane_row(run.workspace, pane)
      return WorkflowSweepRows.row(run, "nothing", reason: "unknown", message: "the agent daemon did not say what review pane #{pane} shows") unless shown
      if WorkflowPanes.agent_gone_row?(shown)
        return stall(run, round, pass, pane, "agent_gone", "review pane #{pane} of #{what} shows a shell: its agent has exited; " \
          "its verdicts are read now, and it stops for a person (review_incomplete) when they fall short")
      end
      return WorkflowSweepRows.row(run, "nothing", reason: "prompt", message: "review pane #{pane} waits for an answer") if shown["state"] == "waiting"
      due = time_limits(run, round, now)
      if turn_over?(shown, round, now)
        idle_for = shown["idle_seconds"].to_i
        stall_after = WorkflowDefinition.stall(run.definition) || pass[:default_stall]
        if WorkflowTransitions.round_interrupted(round, now)
          return stall(run, round, pass, pane, "interrupted",
            "the review turn in pane #{pane} ended after the sweep interrupted it, and nothing decided #{what}", {"idle_for" => idle_for})
        end
        stalled = !stall_after.nil? && idle_for >= stall_after
        return WorkflowSweepRows.row(run, "nothing", reason: "reviewing", message: "#{what} is being reviewed") unless stalled || due.any?
        return stall(run, round, pass, pane, "idle_turn_over",
          "the review turn in pane #{pane} ended and nothing decided #{what} (idle for #{idle_for} seconds)", {"idle_for" => idle_for})
      end
      return WorkflowSweepRows.row(run, "nothing", reason: "reviewing", message: "#{what} is being reviewed") if due.empty?
      press_and_confirm(run, round, what, pass, shown, pane, due)
    end

    # The review windows no round uses, in the workspace looked at (every session when none is named), closed.
    #
    # @param run_id [String, nil] only that run's windows
    # @param workspace [String, nil] only that workspace's session
    # @param pass [Hash] the pass's `dry_run` and `allow`
    # @return [Array<Hash>] one row per window
    def orphan_rows(run_id, workspace, pass)
      return [] unless @orphans
      return [] if run_id && workspace.nil?
      @orphans.find(workspace: workspace).filter_map do |orphan|
        next if run_id && orphan[:run_id] != run_id
        orphan_row(orphan, pass)
      end
    end

    private

    def orphan_row(orphan, pass)
      message = "review window #{orphan[:window]} (pane #{orphan[:pane]}, round #{orphan[:round]} of step #{orphan[:step]}) is left over: #{WorkflowReviewOrphans::WHY.fetch(orphan[:why])}"
      base = {"workspace" => orphan[:workspace] || orphan[:session], "run_id" => orphan[:run_id], "step" => orphan[:step], "attempt" => nil, "cause" => "orphan_review_window"}
      unless orphan[:closable]
        return base.merge("outcome" => "nothing", "reason" => "unconfirmed", "action" => nil,
          "message" => "#{message}; it may be another state directory's, so it is left. Close it by hand (tmux kill-window -t #{orphan[:window]}) if it is left over")
      end
      return base.merge("outcome" => "dry_run", "reason" => nil, "message" => message, "action" => "close_window") if pass[:dry_run]
      # Only a window whose run this store has is closable, so the run is always there to ask about.
      refusal = pass[:allow]&.call(orphan[:run])
      return base.merge("outcome" => "nothing", "reason" => "refused", "message" => refusal, "action" => nil) if refusal
      return base.merge("outcome" => "closed", "reason" => nil, "message" => "#{message}; closed", "action" => "close_window") if @orphans.close(orphan)
      base.merge("outcome" => "failed", "reason" => "close_failed", "message" => "#{message}, and tmux could not close it", "action" => "close_window")
    end

    # A round whose line may have been typed, past the short wait: {WorkflowEngine#tick} judges it unless its review
    # pane shows a reviewer at work (until the review's timeout) or waiting for an answer.
    def typed_round(run, what, pass)
      message = "#{what} may have been typed before its delivery failed or lapsed; its verdicts are read once its review pane is done"
      return WorkflowSweepRows.row(run, "dry_run", message: message, cause: "round_maybe_typed", action: "evaluate") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return WorkflowSweepRows.row(run, "nothing", reason: "refused", message: refusal, cause: "round_maybe_typed") if refusal
      return WorkflowSweepRows.engine_row(run, :evaluated, "evaluated", cause: "round_maybe_typed", message: message, action: "evaluate") if @engine.tick(run.id)
      WorkflowSweepRows.row(run, "nothing", reason: "reviewing", cause: "round_maybe_typed",
        message: "#{what} may have been typed and its review pane is still at work or waiting for an answer (or another process is changing the run); the next pass looks again")
    end

    # A round whose line may have been typed, its review pane's agent at work past a time limit: read in its pane and
    # pressed, rather than handed to the tick.
    def press_typed?(run, round, now)
      return false unless round["pane"].is_a?(String) && time_limits(run, round, now).any?
      @panes.pane_row(run.workspace, round["pane"])&.fetch("state", nil) == "working"
    end

    # The review pane's turn is over, idle past the floor, and the round was delivered long enough ago that an idle
    # pane is not one the line has yet to reach.
    def turn_over?(shown, round, now)
      return false unless WorkflowPanes.turn_over?(shown, now) && shown["idle_seconds"].to_i >= WorkflowSweepRows::IDLE_FLOOR
      now - Time.iso8601((round["delivered_at"] || round["started_at"]).to_s) >= WorkflowSweepRows::IDLE_GRACE
    rescue ArgumentError
      false
    end

    # The time limits the round is past, the round's own first: [cause, seconds used, limit] each, for the round's
    # `review.timeout` and the run's `timeout:` when its `timeout_action` is `interrupt`.
    def time_limits(run, round, now)
      due = []
      if WorkflowTransitions.round_timed_out?(run.to_h, round, now)
        due << ["review_timed_out", WorkflowTransitions.round_elapsed(round, now), WorkflowTransitions.review_timeout(run.to_h)]
      end
      deadline = WorkflowDeadline.reading(run, now)
      due << ["run_timed_out", deadline["used"], deadline["limit"]] if deadline && deadline["spent"] && deadline["action"] == "interrupt"
      due
    end

    # Claims under the run's lock, presses in the review pane with it given up, confirms under it, for the first cause
    # in +due+ whose keys have not gone out for the round. The turn that ends is decided as any review turn's end is.
    def press_and_confirm(run, round, what, pass, shown, pane, due)
      marks = WorkflowTransitions.round_sweep_marks(round)
      cause, used, limit = due.find { |each, _, _| marks.dig(WorkflowTransitions::ROUND_INTERRUPT_KEYS.fetch(each), "state") != "sent" }
      return unanswered(run, round, what, pass, pane, due) unless cause
      message = if cause == "run_timed_out"
        "the run has used #{used.round} seconds of its #{limit} second time limit while #{what} is reviewed"
      else
        "#{what} is #{used.round} seconds in, past its #{limit} second review timeout"
      end
      unless shown["state"] == "working"
        return WorkflowSweepRows.row(run, "nothing", reason: "not_working", cause: cause, message: "#{message}, but review pane #{pane} does not show the agent working")
      end
      keys = AgentProvider.find(shown["kind"].to_s)&.interrupt_keys.to_a
      if keys.empty?
        return WorkflowSweepRows.row(run, "nothing", reason: "no_interrupt_key", cause: cause, message: "#{message}, and workspace knows no interrupt key for #{shown["kind"] || "this agent"}")
      end
      return WorkflowSweepRows.row(run, "dry_run", message: message, cause: cause, action: "interrupt") if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return WorkflowSweepRows.row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      ref = {step: run.current, attempt: WorkflowSweepRows.attempt_of(run), round: round["round"], pane: pane}
      claim, claim_at = @engine.claim_round_interrupt(run.id, **ref, elapsed: used, timeout: limit, cause: cause)
      unless claim == :claimed
        return WorkflowSweepRows.row(run, "nothing", reason: "already_interrupted", message: message, cause: cause) if claim == :repeat
        return WorkflowSweepRows.engine_row(run, claim, "interrupted", cause: cause, message: message, action: "interrupt")
      end
      unless still_working?(run, pane, shown)
        @engine.round_interrupt_sent(run.id, **ref, claim_at: claim_at, sent: false, cause: cause)
        return WorkflowSweepRows.row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows the agent working in this run; nothing was pressed", cause: cause)
      end
      failure = press(run, pane, keys)
      @engine.round_interrupt_sent(run.id, **ref, claim_at: claim_at, sent: failure.nil?, cause: cause)
      return WorkflowSweepRows.row(run, "failed", reason: "interrupt_failed", message: "could not interrupt review pane #{pane}: #{failure}", cause: cause, action: "interrupt") if failure
      WorkflowSweepRows.row(run, "interrupted", message: "#{message}; interrupted, and the round is decided on its verdicts once the review turn ends", cause: cause, action: "interrupt")
    end

    # Every due cause's keys went out and the pane still works: once {WorkflowTransitions.press_wait} (the longer of the
    # definition's `stall` and the review's timeout) has passed since the newest press
    # ({WorkflowTransitions.press_unanswered?}, the reading {WorkflowEngine#tick} also decides by), the round is decided
    # on the verdicts written and stops `review_incomplete` with its window kept when they fall short (cause
    # `interrupt_unanswered`), so it is never left waiting on a pane no press reaches.
    def unanswered(run, round, what, pass, pane, due)
      now = @clock.call
      unless WorkflowTransitions.press_unanswered?(run.to_h, round, now)
        return WorkflowSweepRows.row(run, "nothing", reason: "already_interrupted", cause: due.first.first,
          message: "#{what} was interrupted for its time limit; it is decided once the review turn ends")
      end
      waited = (now - WorkflowTransitions.round_last_press(round)).round
      stall(run, round, pass, pane, "interrupt_unanswered",
        "review pane #{pane} of #{what} still works #{waited} seconds after it was interrupted for its time limit; " \
        "the verdicts written decide it, else it stops for a person (review_incomplete), its window kept", {"waited" => waited})
    end

    # Read just before the press: the same agent still works in the review pane, and the pane is still the run's
    # review pane (bound as its reviewer, so an author's pane that took a reused pane id is never pressed).
    def still_working?(run, pane, shown)
      fresh = @panes.pane_row(run.workspace, pane)
      bound = @panes.bound_on(pane)
      !fresh.nil? && fresh["state"] == "working" && fresh["kind"] == shown["kind"] && bound &&
        bound[:run_id] == run.id && bound[:role] == "reviewer"
    end

    # nil once the keys are pressed; otherwise why they were not.
    def press(run, pane, keys)
      @interrupter.call(run.workspace, pane, keys)
      nil
    rescue Workspace::Error => e
      e.message.lines.first.to_s.strip
    end

    # A review round's delivery failed or lapsed ({WorkflowTransitions.round_redelivery}): the delivery again, or the
    # stop once it is spent, is {WorkflowEngine#tick}'s.
    def round_undelivered(run, what, round, info, pass)
      failure = round["failure"]
      how = failure.is_a?(Hash) ? "was not delivered (#{failure["code"]})" : "was not delivered and the process delivering it is gone"
      if info[:state] == :waiting
        return WorkflowSweepRows.row(run, "nothing", reason: "backoff", cause: "round_undelivered", message: "#{what} #{how}; it is delivered again (#{info[:retries] + 1} of #{info[:limit]}) in #{info[:wait]} seconds")
      end
      exhausted = info[:state] == :exhausted
      message = exhausted ? "#{what} #{how}, and it can't be delivered again (#{info[:retries]} of #{info[:limit]}); it stops for a person (review_incomplete)" : "#{what} #{how}; delivering it again (#{info[:retries] + 1} of #{info[:limit]})"
      action = exhausted ? "stop" : "redeliver"
      return WorkflowSweepRows.row(run, "dry_run", message: message, cause: "round_undelivered", action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return WorkflowSweepRows.row(run, "nothing", reason: "refused", message: refusal, cause: "round_undelivered") if refusal
      outcome = @engine.tick(run.id) ? :done : :busy
      WorkflowSweepRows.engine_row(run, outcome, exhausted ? "stopped" : "redelivered", cause: "round_undelivered", message: message, action: action)
    end

    # A round stalled in its review pane: the change is {WorkflowEngine#review_stalled}'s. A turn's end is read again just before it.
    def stall(run, round, pass, pane, cause, message, data = {})
      action = {"server_restarted" => "redeliver"}.fetch(cause, "evaluate")
      return WorkflowSweepRows.row(run, "dry_run", message: message, cause: cause, action: action) if pass[:dry_run]
      refusal = pass[:allow]&.call(run)
      return WorkflowSweepRows.row(run, "nothing", reason: "refused", message: refusal, cause: cause) if refusal
      if %w[idle_turn_over interrupted].include?(cause)
        fresh = @panes.pane_row(run.workspace, pane)
        unless fresh && WorkflowPanes.turn_over?(fresh, @clock.call) && fresh["idle_seconds"].to_i >= WorkflowSweepRows::IDLE_FLOOR
          return WorkflowSweepRows.row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows the review turn over; the next pass looks again", cause: cause)
        end
      elsif cause == "interrupt_unanswered"
        unless @panes.pane_row(run.workspace, pane)&.fetch("state", nil) == "working"
          return WorkflowSweepRows.row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows its agent working; the next pass looks again", cause: cause)
        end
      elsif cause == "agent_gone"
        unless WorkflowPanes.agent_gone_row?(@panes.pane_row(run.workspace, pane))
          return WorkflowSweepRows.row(run, "nothing", reason: "pane_changed", message: "review pane #{pane} no longer shows a shell; the next pass looks again", cause: cause)
        end
      end
      outcome = @engine.review_stalled(run.id, step: run.current, attempt: WorkflowSweepRows.attempt_of(run), round: round["round"], pane: pane, cause: cause, data: data)
      WorkflowSweepRows.engine_row(run, outcome, {evaluated: "evaluated", stopped: "stopped", redelivered: "redelivered"}.fetch(outcome, outcome.to_s), cause: cause, message: message, action: action)
    end
  end
end
