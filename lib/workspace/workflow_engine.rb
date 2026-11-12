require "fileutils"
require "time"

module Workspace
  # Moves a workflow run from step to step. A run is a copy of its
  # definition plus where it stands, kept by {WorkflowRunStore}; every
  # method here makes one transition under the run's lock and returns.
  #
  # A step is done when the agent's turn ends in the bound pane
  # ({#turn_ended}), every file the step `produces:` exists, and its
  # `status:` check passes. `workspace step done` only adds the agent's own
  # report ({#report}); a report of `fail` fails the step at the turn's end.
  # A failed step follows its `on_fail: {goto, max}` while loops and the
  # run's `max_attempts` last; after that the run waits for a person.
  #
  # A run that is not moving has a `reason` that says why, one of
  # `waiting_lock`, `waiting_you`, `turn_ended_incomplete`,
  # `turn_ended_background` (a turn that ended with background tasks listed;
  # {WorkflowStatus} hides it) and `failed_check`. {WorkflowStatus} adds
  # `pane_gone`, which is read from tmux rather than stored. The one case
  # with no reason is a turn that ended without the daemon seeing it (an
  # interrupted turn, a daemon that was down): the step still reads
  # `running`, {WorkflowStatus} flags it `idle`, and {#resume} looks at it.
  #
  # Resources a step `uses:` are held by the run, taken before the step's
  # prompt is typed and given up at a gate, on a failure that stops the run,
  # and at the end.
  #
  # A resume that can't be carried out yet is parked ({#park}): a request
  # stored on the run as `parked`, not an attempt. No attempt is made and no
  # new resource taken until {#release_park}. Until then a turn's end, a tick
  # and a check's result decide nothing.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = WorkflowDispatch::KICK

    # The run id {#preflight} and {#render} compose a first step under, for a run that does not exist.
    PREVIEW_RUN_ID = WorkflowStarter::PREVIEW_RUN_ID

    # The words in `details.code` the engine sets itself; `step done --code` refuses them, so `code_source: agent` never carries one.
    ENGINE_CODES = WorkflowEvaluation::ENGINE_CODES

    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = WorkflowDispatch::PANE_GONE_CODES

    DELIVERY_WINDOW = WorkflowTransitions::DELIVERY_WINDOW

    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = WorkflowDecisions::PARK_SECONDS

    # How many times a released resume that could not be typed is parked again.
    # Each failed delivery is an attempt, and attempts count against `max_attempts`.
    PARK_RETRIES = WorkflowDispatch::PARK_RETRIES

    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = WorkflowDispatch::PARK_AGAIN_CODES

    REDELIVER_BACKOFF = WorkflowTransitions::REDELIVER_BACKOFF

    REDELIVER_CODES = WorkflowTransitions::REDELIVER_CODES

    REDELIVER_NEVER_REASONS = WorkflowTransitions::REDELIVER_NEVER_REASONS

    # The class methods below forward to {WorkflowTransitions}, which holds the rules.
    def self.attempts_made(run) = WorkflowTransitions.attempts_made(run)

    def self.attempts_spent?(run) = WorkflowTransitions.attempts_spent?(run)

    def self.attempt_allowance(run) = WorkflowTransitions.attempt_allowance(run)

    def self.extra_attempts_needed(run) = WorkflowTransitions.extra_attempts_needed(run)

    def self.starts_attempt?(run, from:, pane:) = WorkflowTransitions.starts_attempt?(run, from: from, pane: pane)

    def self.delivery(attempt, now) = WorkflowTransitions.delivery(attempt, now)

    def self.redelivery(run, now) = WorkflowTransitions.redelivery(run, now)

    def self.backoff(run, now) = WorkflowTransitions.backoff(run, now)

    def self.parked(run, now) = WorkflowTransitions.parked(run, now)

    def self.park_timeout_message(pane, checking: false) = WorkflowTransitions.park_timeout_message(pane, checking: checking)

    def self.wakeable?(run, now) = WorkflowTransitions.wakeable?(run, now)

    def self.lost_check?(run, now) = WorkflowTransitions.lost_check?(run, now)

    # The engine forwards each call to the phase that owns it; {Workspace.build_workflow_engine}
    # builds the phases over one shared {WorkflowRunChange} and hands them here.
    #
    # @param starter [Workspace::WorkflowStarter] preflight, render, check_plan and start
    # @param evaluation [Workspace::WorkflowEvaluation] a turn that ended, and the agent's report
    # @param decisions [Workspace::WorkflowDecisions] a person's commands on a run
    # @param recovery [Workspace::WorkflowRecovery] tick and the sweep's acts
    def initialize(starter:, evaluation:, decisions:, recovery:)
      @starter = starter
      @evaluation = evaluation
      @decisions = decisions
      @recovery = recovery
    end

    BACKGROUND_HOLD = WorkflowTransitions::BACKGROUND_HOLD

    # Checks everything `start` would refuse, and changes nothing. See {WorkflowStarter#preflight}.
    #
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step", "pane", "inputs" and "packs"
    # @raise [Workspace::Error] see {WorkflowStarter#preflight}
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      @starter.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, tree: tree, checkout: checkout)
    end

    # The instructions a step's agent would be sent for its first attempt. Writes nothing. See {WorkflowStarter#render}.
    #
    # @return [Hash{String=>Object}]
    # @raise [Workspace::Error, Workspace::UsageError] see {WorkflowStarter#render}
    def render(definition:, step:, workspace:, worktree:, inputs:)
      @starter.render(definition: definition, step: step, workspace: workspace, worktree: worktree, inputs: inputs)
    end

    # What `workflow check` runs for a step. Writes nothing. See {WorkflowStarter#check_plan}.
    #
    # @return [Hash{String=>Object}]
    # @raise [Workspace::Error] see {WorkflowStarter#check_plan}
    def check_plan(definition:, step:, worktree:)
      @starter.check_plan(definition: definition, step: step, worktree: worktree)
    end

    # Creates a run and starts its first step. See {WorkflowStarter#start}.
    #
    # @return [Hash{String=>Object}] the run after its first transition, or as created
    # @raise [Workspace::Error] see {WorkflowStarter#preflight}
    def start(definition:, workspace:, worktree:, inputs:, pane:, note: nil, dispatch: true)
      @starter.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, note: note, dispatch: dispatch).to_h
    end

    # The agent's turn ended in the run's pane: decides whether the current
    # step is done. A step with a `status:` check has it run here, outside
    # the run's lock, so a long check never blocks a `cancel`.
    #
    # @param run_id [String]
    # @param pane [String, nil] the pane the turn ended in; an event from a pane the
    #   run is not bound to changes nothing
    # @param turn_started [Time, nil] when the turn that ended began, when the daemon knows.
    #   A turn that began before the step's attempt did was already under way when the
    #   step's line was typed (a person talking to the agent at a gate), and its end
    #   decides nothing. Without it every end of a turn in the pane counts
    # @param background [Array<Hash>] the background tasks (`"id"`, `"type"`) the agent still listed when
    #   its turn ended. A step the files do not yet complete is then held (`turn_ended_background`) and
    #   not reported as stopped, since each task that ends starts another turn
    # @param stopped_at [Time, nil] when the turn's end was seen. One from before the attempt
    #   began can't be that attempt's own, even with no +turn_started+
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def turn_ended(run_id, pane: nil, turn_started: nil, stopped_at: nil, background: [])
      @evaluation.turn_ended(run_id, pane: pane, turn_started: turn_started, stopped_at: stopped_at, background: background).to_h
    end

    # Records what the agent says about its current attempt. See {WorkflowEvaluation#report}.
    #
    # @param run_id [String]
    # @param status [String] "pass" or "fail"
    # @param summary [String, nil] one line about the attempt
    # @param code [String, nil] a word the agent chose for why (stored; a failed step's `details.code`)
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported" (the stored
    #   report: "status", "summary", "code", "at")
    # @raise [Workspace::Error] code `step_not_running` when the run's step is not being worked on
    def report(run_id, status:, summary: nil, code: nil)
      reported = @evaluation.report(run_id, status: status, summary: summary, code: code)
      {"run_id" => reported.run_id, "step" => reported.step, "attempt" => reported.attempt, "reported" => reported.reported}
    end

    # Passes a gate: the run goes on to the step after the gated one. When the
    # gated step's first file names a note (`note: <file>`), the note's sha256
    # is recorded with the approval and named in the next step's instructions.
    # Every check runs under the run's lock, in this order: the gate is
    # waiting (at +step+ and +attempt+ when given), +guard+, then the note.
    # A refusal leaves the run file as it was.
    #
    # @param run_id [String]
    # @param note [String, nil] added to the next step's instructions
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param note_sha256 [String, nil] the note's sha256 the caller read; refused when it changed
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting` when the run is not at a gate (or not at
    #   +step+ and +attempt+), `stale_revision` when the note's sha256 is not +note_sha256+,
    #   `gate_note_unreadable` when the named note can't be read, or when +note_sha256+ is given
    #   and the gate names no note; and what +guard+ raises
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @decisions.approve(run_id, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard).to_h
    end

    # Turns a gate down: the gated step, or an earlier one, runs again with the note.
    #
    # @param run_id [String]
    # @param note [String] why, added to that step's instructions
    # @param to [String, nil] the step to run again; nil for the gated step
    # @param step [String, nil] the gated step the caller saw; refused when the run is elsewhere
    # @param attempt [Integer, nil] that step's attempt the caller saw (needs +step+)
    # @param guard [#call, nil] called with the stored run after the step checks; raises to refuse
    # @param extra_attempts [Integer, nil] added to the run's attempt allowance (see {#resume})
    # @param extra_tokens [Integer, nil] added to the run's token budget (see {#resume})
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `gate_not_waiting`; `attempts_spent` when the run has made all its
    #   attempts and +extra_attempts+ is not given; `budget_spent` when the token budget is used up and +extra_tokens+ does not cover it; `usage` when `to` is not the gated step or
    #   one before it; and what +guard+ raises
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil)
      @decisions.reject(run_id, note: note, to: to, step: step, attempt: attempt, guard: guard, extra_attempts: extra_attempts, extra_tokens: extra_tokens).to_h
    end

    # Gets a run that is not moving going again: asks for its lock again,
    # runs a failed or undelivered step again, looks again at a step whose
    # turn ended without its files or without the daemon seeing it, and
    # moves the run to another pane when its own is gone. A step an agent is
    # working on, and a check that is still running, are left alone. A resume
    # that acts takes over from a parked one; one that does nothing leaves it.
    #
    # @param run_id [String]
    # @param from [String, nil] start again at this step instead
    # @param note [String, nil] added to the next attempt's instructions
    # @param pane [String, nil] the pane to use from now on (when the old one is gone)
    # @param turn_over [Hash{String=>Object}, nil] "step" and "attempt": the pane's agent was
    #   seen to have ended its turn on that attempt, so the step, if the run is still on that
    #   attempt and it reads `running`, is decided now
    # @param extra_attempts [Integer, nil] raises the run's attempt allowance by this much, kept in the run
    #   (`extra_attempts`) and recorded as `attempts_extended`; applied only when the resume starts an attempt,
    #   whether or not the allowance was spent
    # @param extra_tokens [Integer, nil] raises the run's token budget by this much, kept in the run (`extra_tokens`)
    #   and recorded as `budget_extended`; applied only when the resume starts an attempt, whether or not the budget was spent
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was done
    # @raise [Workspace::Error] see {#refuse_resume}; code `attempts_spent` when the resume would start
    #   an attempt the run has none left for and +extra_attempts+ is not given; `budget_spent` likewise for the token budget and +extra_tokens+
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      resumed_h(@decisions.resume(run_id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens))
    end

    # Stores a resume for later, with the same arguments as {#resume}: no
    # attempt, no binding, no new lock. What the run already has stays, and
    # {#release_park} carries it out. A live park stays as it is, so repeating
    # the call can't extend the wait; one past its limit is replaced.
    #
    # @param run_id [String]
    # @param from [String, nil] see {#resume}
    # @param note [String, nil] see {#resume}; stored in the run, never in an event
    # @param pane [String, nil] see {#resume}
    # @param turn_over [Hash{String=>Object}, nil] see {#resume}
    # @param extra_attempts [Integer, nil] see {#resume}; applied when the park is released
    # @param extra_tokens [Integer, nil] see {#resume}; applied when the park is released
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when nothing was stored
    # @raise [Workspace::Error] see {#refuse_resume}; code `pane_has_run` for a +pane+ another run has;
    #   `attempts_spent` as {#resume}
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      resumed_h(@decisions.park(run_id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens))
    end

    # Carries out a parked resume, in one change with taking it off the run.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why, as a
    #   sentence) when the resume did nothing, its note kept for the next attempt
    # @raise [Workspace::Error] see {#resume}; the run stays parked
    def release_park(run_id, id)
      resumed_h(@decisions.release_park(run_id, id))
    end

    # Ends a park that can't be released, and leaves the run waiting for a
    # person. The step and what it holds stay, so a `running` step keeps its
    # attempt and a later resume decides it. A lock the run queued for is given
    # up, since the run would no longer use it. A run waiting at a gate keeps
    # its gate reason, so approve and reject stay open; the failure is in the
    # `resume_parked_ended` event.
    #
    # @param run_id [String]
    # @param id [String] the park's id; any other changes nothing
    # @param code [String] why, stored as the reason's `error`
    # @param message [String]
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def park_failed(run_id, id, code:, message:)
      @decisions.park_failed(run_id, id, code: code, message: message).to_h
    end

    # What {#resume} refuses, checked without changing anything, so a caller
    # can refuse before it starts a daemon or picks a pane.
    #
    # @param run [Hash{String=>Object}] a stored run that has not finished
    # @param from [String, nil] the step a resume would start again at
    # @return [void]
    # @raise [Workspace::Error] code `gate_waiting` for a run at a gate when no step is
    #   named (approve or reject it); `usage` for a step the workflow doesn't have
    def refuse_resume(run, from: nil)
      @decisions.refuse_resume(run, from: from)
    end

    # Ends a run: gives up its resources and frees its pane.
    #
    # @param run_id [String]
    # @param cause [String] who ended it: "cancel", or "kill" when its workspace was killed
    # @return [Hash{String=>Object}] the run afterwards
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def cancel(run_id, cause: "cancel")
      @decisions.cancel(run_id, cause: cause).to_h
    end

    # Ends every run of a workspace that was killed. See {WorkflowDecisions#workspace_killed}.
    #
    # @param workspace [String]
    # @return [Hash{String=>Array<String>}] "cancelled", the ids of the runs ended, and
    #   "failed", the ids of the runs that could not be
    def workspace_killed(workspace)
      @decisions.workspace_killed(workspace)
    end

    # The periodic look at a run nothing else will wake. See {WorkflowRecovery#tick}.
    #
    # @param run_id [String]
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id)
      @recovery.tick(run_id)&.to_h
    end

    # Seconds a pending interrupt claim holds before another sweep may take it over.
    INTERRUPT_CLAIM_SECONDS = WorkflowRecovery::INTERRUPT_CLAIM_SECONDS

    # The marks the sweep left on the run's current attempt; see {WorkflowTransitions.sweep_marks}.
    def self.sweep_marks(run) = WorkflowTransitions.sweep_marks(run)

    # Records a stall the sweep found. See {WorkflowRecovery#note_stall}.
    #
    # @return [Symbol] :recorded, :repeat, :moved_on or :busy
    # @raise [Workspace::Error] code `unknown_run` or `run_not_active`
    def note_stall(run_id, step:, attempt:, cause:, data: {})
      @recovery.note_stall(run_id, step: step, attempt: attempt, cause: cause, data: data)
    end

    # Records that the sweep put right a stall it noted. See {WorkflowRecovery#note_recovery}.
    #
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, step:, attempt:, cause:, action:)
      @recovery.note_recovery(run_id, step: step, attempt: attempt, cause: cause, action: action)
    end

    # Decides a step whose agent ended its turn unseen. See {WorkflowRecovery#recover}.
    #
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      @recovery.recover(run_id, turn_over: turn_over, cause: cause, data: data, fail_if_incomplete: fail_if_incomplete)
    end

    # Fails a step that ran past its `timeout:`. See {WorkflowRecovery#time_out}.
    #
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, step:, attempt:, elapsed:, timeout:)
      @recovery.time_out(run_id, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout)
    end

    # Types a step's line again after a delivery that failed. See {WorkflowRecovery#redeliver}.
    #
    # @return [Symbol] :redelivered, :waiting_lock, :not_delivered, :moved_on or :busy
    def redeliver(run_id, step:, attempt:)
      @recovery.redeliver(run_id, step: step, attempt: attempt)
    end

    # Starts an `on_fail` retry whose backoff is over. See {WorkflowRecovery#retry_backoff}.
    #
    # @return [Symbol] :retried, :blocked, :held, :moved_on or :busy
    def retry_backoff(run_id, step:, attempt:)
      @recovery.retry_backoff(run_id, step: step, attempt: attempt)
    end

    # Takes the right to interrupt a step past its `timeout:`. See {WorkflowRecovery#claim_interrupt}.
    #
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`]; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:)
      @recovery.claim_interrupt(run_id, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout)
    end

    # Ends a {#claim_interrupt}. See {WorkflowRecovery#interrupt_sent}.
    #
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true)
      @recovery.interrupt_sent(run_id, step: step, attempt: attempt, claim_at: claim_at, sent: sent, record: record)
    end

    private

    # The Hash a resume, a park and a park's release answer: the run, with "unchanged" when nothing was done.
    def resumed_h(resumed)
      resumed.unchanged ? resumed.run.to_h.merge("unchanged" => resumed.unchanged) : resumed.run.to_h
    end

    GUARD_TEXT = WorkflowTransitions::GUARD_TEXT
  end
end
