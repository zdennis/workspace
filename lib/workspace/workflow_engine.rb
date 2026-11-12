require "fileutils"
require "time"

module Workspace
  # Moves a workflow run from step to step. A run is a copy of its definition plus where it
  # stands, kept by {WorkflowRunStore}; every method makes one transition under the run's lock.
  #
  # A step is done when the agent's turn ends in the bound pane ({#turn_ended}), every file it
  # `produces:` exists, and its `status:` check passes. A failed step follows its
  # `on_fail: {goto, max}` while loops and `max_attempts` last; then the run waits for a person.
  # A run that is not moving has a `reason` (`waiting_lock`, `waiting_you`,
  # `turn_ended_incomplete`, `turn_ended_background`, `failed_check`); {WorkflowStatus} adds
  # `pane_gone`. A resume that can't be carried out yet is parked ({#park}) until {#release_park}.
  #
  # This class is the facade: each method forwards to the phase that owns it and turns the
  # phase's {WorkflowRun} or result value into the Hash callers read today.
  class WorkflowEngine
    # The one line typed into the pane; the instructions themselves are in the file.
    KICK = WorkflowDispatch::KICK
    # The run id {#preflight} and {#render} compose a first step under.
    PREVIEW_RUN_ID = WorkflowStarter::PREVIEW_RUN_ID
    # The words in `details.code` the engine sets itself; `step done --code` refuses them.
    ENGINE_CODES = WorkflowEvaluation::ENGINE_CODES
    # Restart errors that mean there is no pane to type into.
    PANE_GONE_CODES = WorkflowDispatch::PANE_GONE_CODES
    DELIVERY_WINDOW = WorkflowTransitions::DELIVERY_WINDOW
    # Seconds a parked resume waits for the turn to end.
    PARK_SECONDS = WorkflowDecisions::PARK_SECONDS
    # How many times a released resume that could not be typed is parked again.
    PARK_RETRIES = WorkflowDispatch::PARK_RETRIES
    # Delivery failures that a later try can get past.
    PARK_AGAIN_CODES = WorkflowDispatch::PARK_AGAIN_CODES
    REDELIVER_BACKOFF = WorkflowTransitions::REDELIVER_BACKOFF
    REDELIVER_CODES = WorkflowTransitions::REDELIVER_CODES
    REDELIVER_NEVER_REASONS = WorkflowTransitions::REDELIVER_NEVER_REASONS
    BACKGROUND_HOLD = WorkflowTransitions::BACKGROUND_HOLD
    # Seconds a pending interrupt claim holds before another sweep may take it over.
    INTERRUPT_CLAIM_SECONDS = WorkflowRecovery::INTERRUPT_CLAIM_SECONDS
    GUARD_TEXT = WorkflowTransitions::GUARD_TEXT

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
    def self.sweep_marks(run) = WorkflowTransitions.sweep_marks(run)

    # {Workspace.build_workflow_engine} builds the phases over one shared {WorkflowRunChange}.
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

    # Checks everything `start` would refuse, and changes nothing. See {WorkflowStarter#preflight}.
    # @return [Hash{String=>Object}] "workflow", "workspace", "project", "step", "pane", "inputs" and "packs"
    def preflight(definition:, workspace:, worktree:, inputs:, pane: nil, tree: worktree, checkout: nil)
      @starter.preflight(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, tree: tree, checkout: checkout)
    end

    # A step's first-attempt instructions; writes nothing. See {WorkflowStarter#render}.
    # @return [Hash{String=>Object}]
    def render(definition:, step:, workspace:, worktree:, inputs:)
      @starter.render(definition: definition, step: step, workspace: workspace, worktree: worktree, inputs: inputs)
    end

    # What `workflow check` runs for a step; writes nothing. See {WorkflowStarter#check_plan}.
    # @return [Hash{String=>Object}]
    def check_plan(definition:, step:, worktree:) = @starter.check_plan(definition: definition, step: step, worktree: worktree)

    # Creates a run and starts its first step. See {WorkflowStarter#start}.
    # @return [Hash{String=>Object}] the run after its first transition, or as created
    def start(definition:, workspace:, worktree:, inputs:, pane:, note: nil, dispatch: true)
      @starter.start(definition: definition, workspace: workspace, worktree: worktree, inputs: inputs, pane: pane, note: note, dispatch: dispatch).to_h
    end

    # The agent's turn ended in the run's pane: decides the current step. See {WorkflowEvaluation#turn_ended}.
    # @return [Hash{String=>Object}] the run afterwards
    def turn_ended(run_id, pane: nil, turn_started: nil, stopped_at: nil, background: [])
      @evaluation.turn_ended(run_id, pane: pane, turn_started: turn_started, stopped_at: stopped_at, background: background).to_h
    end

    # Records what the agent says about its current attempt. See {WorkflowEvaluation#report}.
    # @return [Hash{String=>Object}] "run_id", "step", "attempt" and "reported"
    def report(run_id, status:, summary: nil, code: nil)
      reported = @evaluation.report(run_id, status: status, summary: summary, code: code)
      {"run_id" => reported.run_id, "step" => reported.step, "attempt" => reported.attempt, "reported" => reported.reported}
    end

    # Passes a gate: the run goes on to the step after the gated one. See {WorkflowDecisions#approve}.
    # @return [Hash{String=>Object}] the run afterwards
    def approve(run_id, note: nil, step: nil, attempt: nil, note_sha256: nil, guard: nil)
      @decisions.approve(run_id, note: note, step: step, attempt: attempt, note_sha256: note_sha256, guard: guard).to_h
    end

    # Turns a gate down: the gated step, or an earlier one, runs again. See {WorkflowDecisions#reject}.
    # @return [Hash{String=>Object}] the run afterwards
    def reject(run_id, note:, to: nil, step: nil, attempt: nil, guard: nil, extra_attempts: nil, extra_tokens: nil)
      @decisions.reject(run_id, note: note, to: to, step: step, attempt: attempt, guard: guard, extra_attempts: extra_attempts, extra_tokens: extra_tokens).to_h
    end

    # Gets a run that is not moving going again. See {WorkflowDecisions#resume}.
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when nothing was done
    def resume(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      resumed_h(@decisions.resume(run_id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens))
    end

    # Stores a resume for later, with {#resume}'s arguments. See {WorkflowDecisions#park}.
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when nothing was stored
    def park(run_id, from: nil, note: nil, pane: nil, turn_over: nil, extra_attempts: nil, extra_tokens: nil)
      resumed_h(@decisions.park(run_id, from: from, note: note, pane: pane, turn_over: turn_over, extra_attempts: extra_attempts, extra_tokens: extra_tokens))
    end

    # Carries out the parked resume +id+. See {WorkflowDecisions#release_park}.
    # @return [Hash{String=>Object}] the run afterwards; with "unchanged" (why) when the resume did nothing
    def release_park(run_id, id) = resumed_h(@decisions.release_park(run_id, id))

    # Ends a park that can't be released; the run waits for a person. See {WorkflowDecisions#park_failed}.
    # @return [Hash{String=>Object}] the run afterwards
    def park_failed(run_id, id, code:, message:) = @decisions.park_failed(run_id, id, code: code, message: message).to_h

    # What {#resume} refuses, checked without changing anything. See {WorkflowDecisions#refuse_resume}.
    # @return [void]
    def refuse_resume(run, from: nil) = @decisions.refuse_resume(run, from: from)

    # Ends a run: gives up its resources and frees its pane. See {WorkflowDecisions#cancel}.
    # @return [Hash{String=>Object}] the run afterwards
    def cancel(run_id, cause: "cancel") = @decisions.cancel(run_id, cause: cause).to_h

    # Ends every run of a workspace that was killed. See {WorkflowDecisions#workspace_killed}.
    # @return [Hash{String=>Array<String>}] "cancelled" and "failed" run ids
    def workspace_killed(workspace) = @decisions.workspace_killed(workspace)

    # The periodic look at a run nothing else will wake. See {WorkflowRecovery#tick}.
    # @return [Hash{String=>Object}, nil] the run afterwards; nil when nothing was done
    def tick(run_id) = @recovery.tick(run_id)&.to_h

    # Records a stall the sweep found. See {WorkflowRecovery#note_stall}.
    # @return [Symbol] :recorded, :repeat, :moved_on or :busy
    def note_stall(run_id, step:, attempt:, cause:, data: {}) = @recovery.note_stall(run_id, step: step, attempt: attempt, cause: cause, data: data)

    # Records that the sweep put right a stall it noted. See {WorkflowRecovery#note_recovery}.
    # @return [Symbol] :recorded, :repeat, :moved_on
    def note_recovery(run_id, step:, attempt:, cause:, action:) = @recovery.note_recovery(run_id, step: step, attempt: attempt, cause: cause, action: action)

    # Decides a step whose agent ended its turn unseen. See {WorkflowRecovery#recover}.
    # @return [Symbol] :evaluated, :timed_out, :moved_on or :busy
    def recover(run_id, turn_over:, cause:, data: {}, fail_if_incomplete: nil)
      @recovery.recover(run_id, turn_over: turn_over, cause: cause, data: data, fail_if_incomplete: fail_if_incomplete)
    end

    # Fails a step that ran past its `timeout:`. See {WorkflowRecovery#time_out}.
    # @return [Symbol] :timed_out or :moved_on
    def time_out(run_id, step:, attempt:, elapsed:, timeout:) = @recovery.time_out(run_id, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout)

    # Types a step's line again after a failed delivery. See {WorkflowRecovery#redeliver}.
    # @return [Symbol] :redelivered, :waiting_lock, :not_delivered, :moved_on or :busy
    def redeliver(run_id, step:, attempt:) = @recovery.redeliver(run_id, step: step, attempt: attempt)

    # Starts an `on_fail` retry whose backoff is over. See {WorkflowRecovery#retry_backoff}.
    # @return [Symbol] :retried, :blocked, :held, :moved_on or :busy
    def retry_backoff(run_id, step:, attempt:) = @recovery.retry_backoff(run_id, step: step, attempt: attempt)

    # Takes the right to interrupt a step past its `timeout:`. See {WorkflowRecovery#claim_interrupt}.
    # @return [Array(Symbol, String), Symbol] [:claimed, the claim's `at`]; or :repeat, :moved_on or :busy
    def claim_interrupt(run_id, step:, attempt:, elapsed:, timeout:)
      @recovery.claim_interrupt(run_id, step: step, attempt: attempt, elapsed: elapsed, timeout: timeout)
    end

    # Ends a {#claim_interrupt}. See {WorkflowRecovery#interrupt_sent}.
    # @return [Symbol] :recorded, :released, :taken_over or :moved_on
    def interrupt_sent(run_id, step:, attempt:, claim_at:, sent:, record: true)
      @recovery.interrupt_sent(run_id, step: step, attempt: attempt, claim_at: claim_at, sent: sent, record: record)
    end

    private

    # The Hash a resume, a park and a park's release answer: the run, with "unchanged" when nothing was done.
    def resumed_h(resumed)
      resumed.unchanged ? resumed.run.to_h.merge("unchanged" => resumed.unchanged) : resumed.run.to_h
    end
  end
end
